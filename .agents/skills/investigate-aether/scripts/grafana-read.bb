#!/usr/bin/env bb

(ns investigate-aether.grafana-read
  (:require [babashka.http-client :as http]
            [babashka.process :as proc]
            [cheshire.core :as json]
            [clojure.java.io :as io]
            [clojure.string :as str])
  (:import [java.net URLEncoder]
           [java.nio.charset StandardCharsets]))

(def default-grafana-url "https://grafana.home.shdr.ch")
(def request-timeout-ms 30000)
(def now (quot (System/currentTimeMillis) 1000))
(def default-start (- now 3600))
(def http-client
  (http/client {:follow-redirects :never
                :connect-timeout 10000}))

(defn fail! [message]
  (throw (ex-info message {})))

(defn repo-root! []
  (loop [directory (-> (or *file* (System/getProperty "babashka.file"))
                       io/file .getCanonicalFile .getParentFile)]
    (cond
      (nil? directory)
      (fail! "unable to locate the Aether repository root")

      (every? #(.exists (io/file directory %))
              ["flake.nix" "Taskfile.yml" "secrets/secrets.yml"])
      (.getCanonicalPath directory)

      :else
      (recur (.getParentFile directory)))))

(def repo-root (delay (repo-root!)))

(defn decrypt-secrets! []
  (let [path (str @repo-root "/secrets/secrets.yml")
        result (try
                 @(proc/process ["sops" "-d" "--output-type" "json" path]
                                {:dir @repo-root :out :string :err :string})
                 (catch Throwable _ nil))]
    (when-not result
      (fail! "sops is unavailable; run inside the Aether Nix shell"))
    (if (zero? (:exit result))
      (:out result)
      (fail! "unable to decrypt the Aether secrets file"))))

(defn load-grafana-token []
  (let [environment-token (some-> (System/getenv "GRAFANA_TOKEN") str/trim)]
    (if (and environment-token
             (not (str/blank? environment-token))
             (not= environment-token "null"))
      environment-token
      (let [secrets (try
                      (json/parse-string (decrypt-secrets!))
                      (catch clojure.lang.ExceptionInfo e (throw e))
                      (catch Throwable _
                        (fail! "decrypted Aether secrets are not valid JSON")))
            token (get secrets "grafana_sa_token")]
        (if (and token (not (str/blank? (str token))) (not= token "null"))
          (str token)
          (fail! "Grafana token is unavailable"))))))

(def grafana-token (delay (load-grafana-token)))
(def grafana-url
  (delay
    (let [url (-> (or (System/getenv "GRAFANA_URL") default-grafana-url)
                  str/trim
                  (str/replace #"/+$" ""))]
      (if (re-matches #"https?://.+" url)
        url
        (fail! "GRAFANA_URL must be an HTTP or HTTPS URL")))))

(defn encode-component [value]
  (-> (URLEncoder/encode (str value) StandardCharsets/UTF_8)
      (str/replace "+" "%20")))

(defn proxy-path [uid suffix]
  (str "/api/datasources/proxy/uid/" (encode-component uid) suffix))

(defn parse-json! [body]
  (try
    (json/parse-string body true)
    (catch Throwable _ (fail! "Grafana returned invalid JSON"))))

(defn request-json!
  ([method path] (request-json! method path {}))
  ([method path {:keys [query-params body headers]}]
   (let [response
         (try
           (http/request
            (cond-> {:method method
                     :uri (str @grafana-url path)
                     :headers (merge {"Authorization" (str "Bearer " @grafana-token)}
                                     headers)
                     :client http-client
                     :timeout request-timeout-ms
                     :throw false}
              (some? query-params) (assoc :query-params query-params)
              (some? body) (assoc :body body)))
           (catch Throwable _
             (fail! (str "Grafana request failed for " path))))]
     (if (<= 200 (:status response) 299)
       (parse-json! (:body response))
       (fail! (str "Grafana returned HTTP " (:status response) " for " path))))))

(defn print-json! [value]
  (println (json/generate-string value {:pretty true})))

(defn require-arg [command args]
  (let [value (first args)]
    (if (and value (not (str/blank? value)))
      value
      (fail! (str command " requires an argument")))))

(defn uid-by-name [name]
  (or (:uid (request-json! :get
                           (str "/api/datasources/name/" (encode-component name))))
      (fail! (str "Grafana datasource not found: " name))))

(defn backend-data! [backend response]
  (if (= "success" (:status response))
    (:data response)
    (fail! (str backend " query failed"))))

(defn project [keys]
  (fn [values]
    (mapv #(select-keys % keys) values)))

(defn backend-result [backend]
  (fn [response]
    (:result (backend-data! backend response))))

(defn alert-group-key [alert]
  [(get-in alert [:labels :alertname])
   (get-in alert [:labels :severity])
   (get-in alert [:labels :namespace])])

(defn summarize-alerts [alerts include-deadman?]
  (->> alerts
       (filter #(or include-deadman?
                    (not= "DeadMansSwitch" (get-in % [:labels :alertname]))))
       (group-by alert-group-key)
       (sort-by key)
       (mapv (fn [[_ group]]
               (let [alert (first group)]
                 {:alertname (get-in alert [:labels :alertname])
                  :severity (get-in alert [:labels :severity])
                  :namespace (get-in alert [:labels :namespace])
                  :state (get-in alert [:status :state])
                  :count (count group)
                  :earliest (first (sort (keep :startsAt group)))})))))

(def read-only-clickhouse-prefix
  #"(?i)^(select|show|describe|desc|explain)\s+")

(defn prepare-clickhouse-sql [raw-sql]
  (let [sql (str/trim raw-sql)]
    (cond
      (str/blank? sql) (fail! "ClickHouse SQL must not be blank")
      (str/includes? sql ";") (fail! "ClickHouse SQL must be one statement")
      (some #(str/includes? sql %) ["--" "/*" "*/" "#"])
      (fail! "ClickHouse SQL comments are not allowed")
      (not (re-find read-only-clickhouse-prefix sql))
      (fail! "ClickHouse helper accepts SELECT, SHOW, DESCRIBE, DESC, or EXPLAIN only")
      :else sql)))

(defn epoch-millis [label value default-value]
  (let [seconds (try
                  (Long/parseLong (str (or value default-value)))
                  (catch Throwable _ (fail! (str label " must be epoch seconds"))))]
    (when (neg? seconds) (fail! (str label " must be non-negative")))
    (try
      (str (Math/multiplyExact seconds (long 1000)))
      (catch ArithmeticException _ (fail! (str label " is out of range"))))))

(defn clickhouse-result! [response]
  (let [result (get-in response [:results :A])]
    (when-not (map? result) (fail! "ClickHouse response is missing results.A"))
    (when-not (str/blank? (str (:error result)))
      (fail! "ClickHouse query failed"))
    result))

(defn target-summary [response]
  (mapv (fn [target]
          {:job (get-in target [:labels :job])
           :instance (get-in target [:labels :instance])
           :health (:health target)
           :lastScrape (:lastScrape target)
           :lastError (:lastError target)})
        (:activeTargets (backend-data! "Prometheus" response))))

(defn run-clickhouse! [args]
  (let [sql (prepare-clickhouse-sql (require-arg "clickhouse" args))
        [_ start end] args
        start-ms (epoch-millis "start_epoch" start default-start)
        end-ms (epoch-millis "end_epoch" end now)]
    (when (> (Long/parseLong start-ms) (Long/parseLong end-ms))
      (fail! "start_epoch must not be after end_epoch"))
    (let [uid (uid-by-name "ClickHouse")
          payload {:from start-ms
                   :to end-ms
                   :queries [{:datasource {:type "grafana-clickhouse-datasource"
                                           :uid uid}
                              :format 1
                              :rawSql sql
                              :refId "A"}]}
          response (request-json! :post "/api/ds/query"
                                  {:headers {"Content-Type" "application/json"}
                                   :body (json/generate-string payload)})]
      (print-json! (clickhouse-result! response)))))

(defn prom-range-params [args]
  (let [[query start end step] args]
    {:query (require-arg "prom-range" [query])
     :start (or start default-start)
     :end (or end now)
     :step (or step 30)}))

(defn loki-params [args]
  (let [[query start end limit] args]
    {:query (require-arg "loki" [query])
     :start (or start default-start)
     :end (or end now)
     :limit (or limit 200)
     :direction "backward"}))

(defn tempo-params [args]
  (let [[query start end limit] args]
    {:q (require-arg "tempo" [query])
     :start (or start default-start)
     :end (or end now)
     :limit (or limit 20)}))

(def command-specs
  [{:name "health" :usage "health" :path "/api/health"
    :decode #(select-keys % [:database :version :commit])}
   {:name "datasources" :usage "datasources" :path "/api/datasources"
    :decode (project [:name :type :uid :access :readOnly])}
   {:name "dashboards" :usage "dashboards [search]" :path "/api/search"
    :query #(hash-map :type "dash-db" :limit 200 :query (or (first %) ""))
    :decode (project [:title :uid :folderTitle :url])}
   {:name "alerts" :usage "alerts [--all]"
    :path "/api/alertmanager/grafana/api/v2/alerts"
    :decode-args #(summarize-alerts %1 (= "--all" (first %2)))}
   {:name "rules" :usage "rules" :path "/api/v1/provisioning/alert-rules"
    :decode (project [:title :uid :ruleGroup :folderUID :labels :noDataState :execErrState])}
   {:name "contact-points" :usage "contact-points"
    :path "/api/v1/provisioning/contact-points"
    :decode (project [:name :uid :type :disableResolveMessage])}
   {:name "prom" :usage "prom <promql>" :datasource "Prometheus"
    :path "/api/v1/query"
    :query #(hash-map :query (require-arg "prom" %))
    :decode (backend-result "Prometheus")}
   {:name "prom-range" :usage "prom-range <promql> [start_epoch end_epoch step]"
    :datasource "Prometheus" :path "/api/v1/query_range"
    :query prom-range-params :decode (backend-result "Prometheus")}
   {:name "prom-label" :usage "prom-label <label>" :datasource "Prometheus"
    :path #(str "/api/v1/label/" (encode-component (require-arg "prom-label" %)) "/values")
    :decode #(backend-data! "Prometheus" %)}
   {:name "prom-targets" :usage "prom-targets" :datasource "Prometheus"
    :path "/api/v1/targets" :query (constantly {:state "active"})
    :decode target-summary}
   {:name "loki-labels" :usage "loki-labels" :datasource "Loki"
    :path "/loki/api/v1/labels" :decode #(backend-data! "Loki" %)}
   {:name "loki-label" :usage "loki-label <label>" :datasource "Loki"
    :path #(str "/loki/api/v1/label/" (encode-component (require-arg "loki-label" %)) "/values")
    :decode #(backend-data! "Loki" %)}
   {:name "loki" :usage "loki <logql> [start_epoch end_epoch limit]"
    :datasource "Loki" :path "/loki/api/v1/query_range"
    :query loki-params :decode (backend-result "Loki")}
   {:name "tempo-services" :usage "tempo-services" :datasource "Tempo"
    :path "/api/v2/search/tag/resource.service.name/values" :decode :tagValues}
   {:name "tempo" :usage "tempo <traceql> [start_epoch end_epoch limit]"
    :datasource "Tempo" :path "/api/search" :query tempo-params
    :decode #(select-keys % [:traces :metrics])}
   {:name "tempo-trace" :usage "tempo-trace <trace-id>" :datasource "Tempo"
    :path #(str "/api/traces/" (encode-component (require-arg "tempo-trace" %)))}
   {:name "clickhouse" :usage "clickhouse <read-only-sql> [start_epoch end_epoch]"
    :run run-clickhouse!}])

(def commands (into {} (map (juxt :name identity) command-specs)))

(def usage
  (str/join
   "\n"
   (concat ["Usage: grafana-read.bb <command> [arguments]" "" "Commands:"]
           (map #(str "  " (:usage %)) command-specs)
           ["" "Set GRAFANA_TOKEN to avoid SOPS lookup. Run inside the Aether Nix shell."])))

(defn execute! [{:keys [run datasource method path query body decode decode-args]
                 :or {method :get decode identity}}
                args]
  (if run
    (run args)
    (letfn [(resolve-field [value]
              (if (fn? value) (value args) value))]
      (let [path (resolve-field path)
            query-params (resolve-field query)
            request-body (resolve-field body)
            path (if datasource (proxy-path (uid-by-name datasource) path) path)
            response (request-json! method path {:query-params query-params
                                                 :body request-body})]
        (print-json! (if decode-args
                       (decode-args response args)
                       (decode response)))))))

(defn -main [& argv]
  (let [[command & args] argv]
    (cond
      (nil? command)
      (do (println usage) (System/exit 2))

      (#{"help" "-h" "--help"} command)
      (println usage)

      :else
      (try
        (if-let [spec (get commands command)]
          (execute! spec args)
          (do
            (binding [*out* *err*] (println usage))
            (fail! (str "unknown command: " command))))
        (catch Throwable t
          (binding [*out* *err*]
            (println (str "error: " (or (ex-message t) "unexpected failure"))))
          (System/exit 1))))))

(apply -main *command-line-args*)
