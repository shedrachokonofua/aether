#!/usr/bin/env bb

(ns scripts.aetherctl
  (:require [babashka.process :as proc]
            [cheshire.core :as json]
            [clojure.string :as str]
            [clojure.java.io :as io])
  (:import [java.net URI URLEncoder]
           [java.net.http HttpClient HttpClient$Redirect
            HttpRequest HttpRequest$BodyPublishers HttpResponse$BodyHandlers]
           [java.nio.charset StandardCharsets]))

(def http-client
  (-> (HttpClient/newBuilder)
      (.followRedirects HttpClient$Redirect/NORMAL)
      (.build)))

(def grafana-url "https://grafana.home.shdr.ch")
(def repo-root (delay (-> (or *file* ".") io/file .getParentFile .getParentFile .getCanonicalPath)))

(def red "\u001b[0;31m")
(def green "\u001b[0;32m")
(def yellow "\u001b[1;33m")
(def blue "\u001b[0;34m")
(def nc "\u001b[0m")

(defn ansi [color s]
  (str color s nc))

(defn http-request! [{:keys [method url headers body]}]
  (try
    (let [builder (HttpRequest/newBuilder (URI/create url))]
      (doseq [[k v] headers]
        (.header builder (name k) (str v)))
      (.method builder
               (str/upper-case (name method))
               (if body
                 (HttpRequest$BodyPublishers/ofString (str body))
                 (HttpRequest$BodyPublishers/noBody)))
      (let [request (.build builder)
            response (.send http-client request (HttpResponse$BodyHandlers/ofString))]
        {:status (.statusCode response)
         :body (.body response)}))
    (catch Throwable t
      {:status 500
       :body (str "Request failed: " (ex-message t))})))

(defn get-grafana-token []
  (try
    (let [res (proc/process ["bash" "-c" (str "sops -d " @repo-root "/secrets/secrets.yml | yq -o json")]
                           {:dir @repo-root :out :string :err :string})
          res-data @res]
      (if (zero? (:exit res-data))
        (try
          (let [parsed (json/parse-string (:out res-data) true)
                token (:grafana_sa_token parsed)]
            (if token token nil))
          (catch Throwable parse-err
            (binding [*out* *err*]
              (println (ansi red (str "✗ Failed to parse secrets JSON: " (ex-message parse-err)))))
            nil))
        (do
          (binding [*out* *err*]
            (println (ansi red "✗ Failed to read secrets")))
          nil)))
    (catch Throwable t
      (binding [*out* *err*]
        (println (ansi red (str "✗ Error reading token: " (ex-message t)))))
      nil)))

(defn get-datasources [token]
  (let [res (http-request! {:method :get
                            :url (str grafana-url "/api/datasources")
                            :headers {"Authorization" (str "Bearer " token)}})]
    (if (= 200 (:status res))
      (try
        (json/parse-string (:body res) true)
        (catch Throwable _
          nil))
      nil)))

(defn find-prometheus-datasource [datasources]
  (some (fn [ds]
          (when (and (= (:type ds) "prometheus")
                     (:uid ds))
            (:uid ds)))
        datasources))

(defn query-prometheus [token ds-uid query]
  (let [encoded-query (URLEncoder/encode query StandardCharsets/UTF_8)
        url (str grafana-url "/api/datasources/proxy/uid/" ds-uid "/api/v1/query?query=" encoded-query)
        res (http-request! {:method :get
                           :url url
                           :headers {"Authorization" (str "Bearer " token)}})]
    (if (= 200 (:status res))
      (try
        (json/parse-string (:body res) true)
        (catch Throwable _
          nil))
      nil)))

(defn format-target-status [target status]
  (if (= (str status) "1")
    (str "  " (ansi green "✓") " " target)
    (str "  " (ansi red "✗") " " target " (DOWN)")))

(defn status-command [token]
  (if-not token
    (binding [*out* *err*]
      (println (ansi red "✗ Failed to authenticate with Grafana"))
      (System/exit 1)))

  (println)
  (println (ansi blue "=== Cluster Status ==="))
  (println)

  (let [datasources (get-datasources token)]
    (if-not datasources
      (do
        (println (ansi red "✗ Failed to fetch datasources"))
        (System/exit 1))
      (let [prom-uid (find-prometheus-datasource datasources)]
        (if-not prom-uid
          (do
            (println (ansi red "✗ Prometheus datasource not found"))
            (System/exit 1))
          (do
            ;; Query up metric
            (println (ansi blue "Target Status:"))
            (when-let [up-result (query-prometheus token prom-uid "up == 0")]
              (let [results (get-in up-result [:data :result] [])]
                (if (seq results)
                  (doseq [result results]
                    (let [labels (:metric result)
                          target-name (or (:job labels) (str labels))]
                      (println (format-target-status target-name 0))))
                  (println (ansi green "✓ All targets up")))))

            (println)
            (println (ansi blue "Firing Alerts:"))
            (when-let [alerts-result (query-prometheus token prom-uid "ALERTS{alertstate=\"firing\"}")]
              (let [results (get-in alerts-result [:data :result] [])]
                (if (seq results)
                  (doseq [result results]
                    (let [labels (:metric result)
                          alert-name (:__name__ labels)
                          severity (or (:severity labels) "unknown")]
                      (println (str "  " (ansi yellow "⚠") " " alert-name " [" severity "]"))))
                  (println (ansi green "✓ No firing alerts")))))

            (println))))))
  (System/exit 0))

(defn backups-command [token]
  (if-not token
    (do
      (binding [*out* *err*]
        (println (ansi red "✗ Failed to authenticate with Grafana")))
      (System/exit 1)))

  (println)
  (println (ansi blue "=== Backup Health ==="))
  (println)

  (let [datasources (get-datasources token)]
    (if-not datasources
      (do
        (println (ansi red "✗ Failed to fetch datasources"))
        (System/exit 1))
      (let [prom-uid (find-prometheus-datasource datasources)]
        (if-not prom-uid
          (do
            (println (ansi red "✗ Prometheus datasource not found"))
            (System/exit 1))
          (do
            ;; First, discover what backup metrics exist
            (println (ansi blue "Searching for backup metrics..."))
            (when-let [metrics-result (query-prometheus token prom-uid "{__name__=~\"backrest.*|restic.*\"}")]
              (let [results (get-in metrics-result [:data :result] [])]
                (if (empty? results)
                  (println (ansi yellow "⚠ No backup metrics found (searched: backrest.*, restic.*)"))
                  (do
                    (println (ansi green "✓ Found backup metrics:"))
                    (doseq [result results]
                      (let [labels (:metric result)
                            metric-name (:__name__ labels)]
                        ;; Find unique metric names
                        (println (str "  - " metric-name))))

                    ;; Now query for recent successful backups
                    (println)
                    (println (ansi blue "Recent Backup Operations:"))

                    ;; Try backrest snapshot operations
                    (when-let [snapshot-result (query-prometheus token prom-uid "backrest_backup_total")]
                      (let [results (get-in snapshot-result [:data :result] [])]
                        (if (seq results)
                          (do
                            (println "  Backrest Snapshots:")
                            (doseq [result results]
                              (println (str "    " (first (vals (:metric result))) " backups completed"))))
                          (println "    No backrest snapshot data"))))

                    ;; Try backrest forget operations
                    (when-let [forget-result (query-prometheus token prom-uid "backrest_backup_restore_delta")]
                      (let [results (get-in forget-result [:data :result] [])]
                        (if (seq results)
                          (do
                            (println "  Backrest Forget Operations:")
                            (doseq [result results]
                              (println (str "    " result))))
                          nil)))

                    (println)
                    (println (ansi yellow "Note: Check Grafana dashboards for detailed backup metrics"))))))

            (println))))))
  (System/exit 0))

(defn help-text []
  (str/join
   "\n"
   ["Usage: aetherctl.bb <command>"
    ""
    "Commands:"
    "  status    Show cluster and ops health status"
    "  backups   Show backup health and recent operations"
    "  help      Show this help text"]))

(defn -main [& args]
  (let [cmd (first args)]
    (cond
      (or (nil? cmd) (= cmd "help") (= cmd "--help") (= cmd "-h"))
      (do
        (println (help-text))
        (System/exit 0))

      (= cmd "status")
      (let [token (get-grafana-token)]
        (status-command token))

      (= cmd "backups")
      (let [token (get-grafana-token)]
        (backups-command token))

      :else
      (do
        (binding [*out* *err*]
          (println (ansi red (str "✗ Unknown command: " cmd)))
          (println)
          (println (help-text)))
        (System/exit 1)))))

(apply -main *command-line-args*)
