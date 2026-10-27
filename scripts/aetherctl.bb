#!/usr/bin/env bb

(ns scripts.aetherctl
  (:require [babashka.process :as proc]
            [cheshire.core :as json]
            [clojure.string :as str]
            [clojure.java.io :as io])
  (:import [java.net URI]
           [java.net.http HttpClient HttpClient$Redirect
            HttpRequest HttpRequest$BodyPublishers HttpResponse$BodyHandlers]))

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

(def clickhouse-ds {:type "grafana-clickhouse-datasource" :uid "clickhouse"})

(defn query-clickhouse [token sql]
  ;; ClickHouse SQL via Grafana /api/ds/query on the fixed uid `clickhouse`
  ;; (same pattern as scripts/router-drift.py); returns decoded row maps.
  (let [now-sec (quot (System/currentTimeMillis) 1000)
        payload (json/generate-string
                 {:from (str (* (- now-sec 3600) 1000))
                  :to (str (* now-sec 1000))
                  :queries [{:datasource clickhouse-ds
                             :format 1
                             :rawSql sql
                             :refId "A"
                             :queryType "sql"
                             :editorType "sql"}]})
        res (http-request! {:method :post
                            :url (str grafana-url "/api/ds/query")
                            :headers {"Authorization" (str "Bearer " token)
                                      "Content-Type" "application/json"}
                            :body payload})]
    (when (= 200 (:status res))
      (try
        (let [parsed (json/parse-string (:body res) true)
              result (get-in parsed [:results :A])]
          (when (str/blank? (str (:error result)))
            (let [frame (first (:frames result))
                  names (mapv (comp keyword :name) (get-in frame [:schema :fields]))
                  columns (get-in frame [:data :values])]
              (mapv (fn [row] (zipmap names row))
                    (apply map vector columns)))))
        (catch Throwable _
          nil)))))

(defn query-grafana-alerts [token]
  ;; ALERTS has no ClickHouse equivalent; use Grafana's own alert API.
  (let [res (http-request! {:method :get
                            :url (str grafana-url "/api/prometheus/grafana/api/v1/alerts")
                            :headers {"Authorization" (str "Bearer " token)}})]
    (when (= 200 (:status res))
      (try
        (get-in (json/parse-string (:body res) true) [:data :alerts])
        (catch Throwable _
          nil)))))

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

  ;; up == 0 → latest `up` gauge per series (5-minute lookback) in ClickHouse.
  (println (ansi blue "Target Status:"))
  (let [down (query-clickhouse
              token
              (str "SELECT ServiceName AS job, ResourceAttributes['service.instance.id'] AS instance, "
                   "argMax(Value, TimeUnix) AS value FROM otel.otel_metrics_gauge "
                   "WHERE MetricName = 'up' AND TimeUnix > now() - INTERVAL 5 MINUTE "
                   "GROUP BY job, instance HAVING value = 0 ORDER BY job, instance"))]
    (cond
      (nil? down) (println (ansi red "✗ ClickHouse query failed (datasource uid clickhouse)"))
      (seq down) (doseq [{:keys [job instance]} down]
                   (println (format-target-status (str job " " instance) 0)))
      :else (println (ansi green "✓ All targets up"))))

  (println)
  (println (ansi blue "Firing Alerts:"))
  (let [alerts (query-grafana-alerts token)
        firing (filter #(= "Alerting" (:state %)) alerts)]
    (cond
      (nil? alerts) (println (ansi red "✗ Failed to fetch Grafana alerts"))
      (seq firing) (doseq [alert firing]
                     (let [labels (:labels alert)
                           alert-name (or (:alertname labels) "unknown")
                           severity (or (:severity labels) "unknown")]
                       (println (str "  " (ansi yellow "⚠") " " alert-name " [" severity "]"))))
      :else (println (ansi green "✓ No firing alerts"))))
  (println)
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

  ;; Backup metrics in ClickHouse: aether_restic_* gauges (otel.otel_metrics_gauge).
  (println (ansi blue "Searching for backup metrics..."))
  (let [found (query-clickhouse
               token
               (str "SELECT DISTINCT MetricName AS metric FROM otel.otel_metrics_gauge "
                    "WHERE (MetricName LIKE 'aether_restic%' OR MetricName LIKE 'backrest%' "
                    "OR MetricName LIKE 'restic%') AND TimeUnix > now() - INTERVAL 1 HOUR "
                    "ORDER BY metric"))]
    (cond
      (nil? found) (println (ansi red "✗ ClickHouse query failed (datasource uid clickhouse)"))
      (empty? found) (println (ansi yellow "⚠ No backup metrics found (searched: aether_restic.*, backrest.*, restic.*)"))
      :else
      (do
        (println (ansi green "✓ Found backup metrics:"))
        (doseq [{:keys [metric]} found]
          (println (str "  - " metric)))
        (println)
        (println (ansi blue "Recent Backup Operations:"))
        (let [rows (query-clickhouse
                    token
                    (str "SELECT Attributes['host_name'] AS host, MetricName AS metric, "
                         "argMax(Value, TimeUnix) AS value FROM otel.otel_metrics_gauge "
                         "WHERE MetricName IN ('aether_restic_snapshot_last_success_timestamp_seconds', "
                         "'aether_restic_metrics_last_success_timestamp_seconds', "
                         "'aether_restic_metrics_generation_success', 'aether_restic_plan_check_success') "
                         "AND TimeUnix > now() - INTERVAL 1 HOUR GROUP BY host, metric ORDER BY host, metric"))]
          (if (seq rows)
            (doseq [{:keys [host metric value]} rows]
              (println (str "    " host " " metric " = " value)))
            (println "    No recent backup data")))
        (println)
        (println (ansi yellow "Note: Check Grafana dashboards for detailed backup metrics")))))
  (println)
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
