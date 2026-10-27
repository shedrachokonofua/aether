#!/usr/bin/env bb

(ns investigate-aether.grafana-read
  (:require [babashka.http-client :as http]
            [babashka.process :as proc]
            [cheshire.core :as json]
            [clojure.java.io :as io]
            [clojure.string :as str]))
(def default-grafana-url "https://grafana.home.shdr.ch")
(def request-timeout-ms 60000)
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
      (fail! "unable to decrypt the Aether secrets file (expired AWS/KMS credentials? run `task login`, or set GRAFANA_TOKEN to skip SOPS)"))))

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


(defn project [keys]
  (fn [values]
    (mapv #(select-keys % keys) values)))


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


(defn run-alert-history! [args]
  (let [hours (try
                (Long/parseLong (str (or (first args) "24")))
                (catch Throwable _ (fail! "alert-history takes hours (a positive integer)")))
        _ (when-not (pos? hours) (fail! "alert-history hours must be positive"))
        to-ms (* (long (/ (System/currentTimeMillis) 1000)) 1000)
        from-ms (- to-ms (* hours 3600 1000))
        annotations (request-json! :get "/api/annotations"
                                   {:query-params {:type "alert"
                                                   :from (str from-ms)
                                                   :to (str to-ms)
                                                   :limit "500"}})
        transitions (->> annotations
                         (keep (fn [a]
                                 (when-let [state (:newState a)]
                                   {:time (str (java.time.Instant/ofEpochMilli (:time a)))
                                    :alert (or (:alertName a) (:title a))
                                    :state state})))
                         (sort-by :time)
                         vec)
        fired (->> transitions
                   (filter #(str/includes? (:state %) "Alerting"))
                   (map :alert)
                   frequencies
                   (sort-by val >)
                   (mapv (fn [[alert n]] {:alert alert :fired n})))]
    (print-json! {:window-hours hours
                  :note (when (= 500 (count annotations))
                          "hit the 500-row cap; narrow the window for full coverage")
                  :fired-counts fired
                  :transitions transitions})))

(defn sql-quote [value]
  (str "'" (str/replace (str value) "'" "''") "'"))

(defn sql-limit [command value default-value]
  (let [n (try (Long/parseLong (str (or value default-value)))
               (catch Throwable _ (fail! (str command " limit must be a positive integer"))))]
    (when-not (<= 1 n 1000) (fail! (str command " limit must be between 1 and 1000")))
    n))

(defn decode-frames [result]
  (let [frames (:frames result)]
    (when-not (seq frames) (fail! "ClickHouse query returned no frames"))
    (mapv (fn [frame]
            (let [names (mapv (comp keyword :name) (get-in frame [:schema :fields]))
                  columns (get-in frame [:data :values])
                  rows (apply map vector columns)]
              (mapv (fn [row] (zipmap names row)) rows)))
          frames)))

(defn run-sql! [sql args]
  (let [[_ start end] args
        start-ms (epoch-millis "start_epoch" start default-start)
        end-ms (epoch-millis "end_epoch" end now)]
    (when (> (Long/parseLong start-ms) (Long/parseLong end-ms))
      (fail! "start_epoch must not be after end_epoch"))
    (let [payload {:from start-ms
                   :to end-ms
                   :queries [{:datasource {:type "grafana-clickhouse-datasource"
                                           :uid "clickhouse"}
                              :format 1
                              :rawSql sql
                              :refId "A"
                              :queryType "sql"
                              :editorType "sql"}]}
          response (request-json! :post "/api/ds/query"
                                  {:headers {"Content-Type" "application/json"}
                                   :body (json/generate-string payload)})]
      (decode-frames (clickhouse-result! response)))))

(defn run-clickhouse! [args]
  (print-json! (first (run-sql! (prepare-clickhouse-sql (require-arg "sql" args)) args))))

(defn run-logs! [args]
  (let [[term start end limit] args
        term (require-arg "logs" [term])
        limit (sql-limit "logs" limit 200)
        start-sec (or start default-start)
        end-sec (or end now)
        sql (str "SELECT Timestamp, ServiceName, SeverityText, Body FROM otel.otel_logs "
                 "WHERE Timestamp >= toDateTime(" start-sec ") AND Timestamp <= toDateTime(" end-sec ") "
                 "AND positionCaseInsensitive(Body, " (sql-quote term) ") > 0 "
                 "ORDER BY Timestamp DESC LIMIT " limit)]
    (print-json! (first (run-sql! sql [sql start end])))))

(defn run-traces! [args]
  (let [[selector start end limit] args
        selector (require-arg "traces" [selector])
        limit (sql-limit "traces" limit 20)
        start-sec (or start default-start)
        end-sec (or end now)
        by-trace? (re-matches #"(?i)[0-9a-f]{32}" selector)
        where (if by-trace?
                (str "lower(TraceId) = lower(" (sql-quote selector) ")")
                (str "ServiceName = " (sql-quote selector)))
        sql (str "SELECT Timestamp, TraceId, SpanId, ParentSpanId, SpanName, ServiceName, Duration, StatusCode "
                 "FROM otel.otel_traces WHERE Timestamp >= toDateTime(" start-sec ") "
                 "AND Timestamp <= toDateTime(" end-sec ") AND " where
                 " ORDER BY Timestamp DESC LIMIT " limit)]
    (print-json! (first (run-sql! sql [sql start end])))))

(defn run-kuma-history! [args]
  (let [hours (try
                (Long/parseLong (str (or (first args) "24")))
                (catch Throwable _ (fail! "kuma-history takes hours (a positive integer)")))
        _ (when-not (pos? hours) (fail! "kuma-history hours must be positive"))
        end-sec now
        start-sec (- end-sec (* hours 3600))
        sql (str "SELECT toUnixTimestamp64Milli(Timestamp) AS ts, Body FROM otel.otel_logs WHERE ServiceName = 'vigilant' "
                 "AND Timestamp >= toDateTime(" start-sec ") AND Timestamp <= toDateTime(" end-sec ") "
                 "AND position(Body, 'WARN:') > 0 AND position(Body, 'Monitor #') > 0 "
                 "ORDER BY Timestamp DESC LIMIT 500")
        rows (first (run-sql! sql [sql start-sec end-sec]))
        events (->> rows
                    (keep (fn [{:keys [ts Body]}]
                            (when-let [[_ monitor msg] (re-find #"Monitor #\d+ '([^']+)': \w+:?\s*(.*?)\s*\| Interval" (str Body))]
                              {:time (str (java.time.Instant/ofEpochMilli (long ts)))
                               :monitor monitor
                               :message (if (str/blank? msg) "timeout/no-response" msg)})))
                    (sort-by :time)
                    vec)]
    (print-json! {:window-hours hours
                  :source "Uptime Kuma monitor log (vigilant, otel.otel_logs)"
                  :failure-counts (->> events (map :monitor) frequencies
                                       (sort-by val >)
                                       (mapv (fn [[m n]] {:monitor m :failures n})))
                  :events events})))

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
   {:name "alert-history" :usage "alert-history [hours (default 24)]"
    :run run-alert-history!}
   {:name "kuma-history" :usage "kuma-history [hours (default 24)]"
    :run run-kuma-history!}
   {:name "rules" :usage "rules" :path "/api/v1/provisioning/alert-rules"
    :decode (project [:title :uid :ruleGroup :folderUID :labels :noDataState :execErrState])}
   {:name "contact-points" :usage "contact-points"
    :path "/api/v1/provisioning/contact-points"
    :decode (project [:name :uid :type :disableResolveMessage])}
   {:name "sql" :usage "sql <read-only-sql> [start_epoch end_epoch]"
    :run run-clickhouse!}
   {:name "logs" :usage "logs <body-substring> [start_epoch end_epoch limit]"
    :run run-logs!}
   {:name "traces" :usage "traces <trace-id|service-name> [start_epoch end_epoch limit]"
    :run run-traces!}])

(def commands (into {} (map (juxt :name identity) command-specs)))

(def usage
  (str/join
   "\n"
   (concat ["Usage: grafana-read.bb <command> [arguments]" "" "Commands:"]
           (map #(str "  " (:usage %)) command-specs)
           ["" "Set GRAFANA_TOKEN to avoid SOPS lookup. Run inside the Aether Nix shell."])))

(defn execute! [{:keys [run method path query body decode decode-args]
                 :or {method :get decode identity}}
                args]
  (if run
    (run args)
    (letfn [(resolve-field [value]
              (if (fn? value) (value args) value))]
      (let [path (resolve-field path)
            query-params (resolve-field query)
            request-body (resolve-field body)
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
