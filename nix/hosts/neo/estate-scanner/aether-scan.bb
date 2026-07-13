#!/usr/bin/env bb
;; Estate-scanner typed dispatcher (Kestra forced-command entrypoint).
;; Paths/allowlists come from /etc/estate-scanner/runtime.json (Nix-owned).

(ns aether-scan
  (:require [babashka.fs :as fs]
            [babashka.http-client :as http]
            [babashka.process :as proc]
            [cheshire.core :as json]
            [clojure.java.io :as io]
            [clojure.string :as str])
  (:import [java.math BigInteger]
           [java.nio.charset StandardCharsets]
           [java.security MessageDigest]
           [java.time Instant]
           [java.util Base64]
           [java.util.concurrent TimeUnit]))

(def usage-text
  "aether-scan — typed estate-scanner dispatcher (Kestra forced-command entrypoint)

Usage:
  aether-scan targets snapshot <run-id> <profile>
  aether-scan discover <run-id> <target-group>
  aether-scan merge-diff <run-id>
  aether-scan fingerprint <run-id> <service-artifact>
  aether-scan validate <run-id> <service-artifact> <approved-profile>
  aether-scan finalize <run-id>
  aether-scan worker discover <run-id> <target-group>
  aether-scan worker fingerprint <run-id> <service-artifact>
  aether-scan worker validate <run-id> <service-artifact> <approved-profile>
  aether-scan status <run-id> <stage> [target-group]

Rejects caller-supplied shell, rates, templates, targets, and output paths.
discover/fingerprint/validate accept and detach; worker stages perform the work.")

(def uuid-re
  #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

(def aether-scan-bin
  (or (System/getenv "AETHER_SCAN_BIN")
      "/run/current-system/sw/bin/aether-scan"))

(defn die!
  ([code message]
   (binding [*out* *err*]
     (println (str "aether-scan: " message)))
   (System/exit code))
  ([message]
   (die! 2 message)))

(defn load-config []
  (let [path (or (System/getenv "AETHER_SCAN_CONFIG")
                 "/etc/estate-scanner/runtime.json")]
    (when-not (fs/exists? path)
      (die! 1 (str "missing runtime config: " path)))
    (json/parse-string (slurp path) true)))

(defn now-iso []
  (str (Instant/now)))

(defn now-ch []
  ;; ClickHouse DateTime64(3, 'UTC') via JSONEachRow accepts ISO-8601.
  (str (Instant/now)))

(defn version-now []
  (.toEpochMilli (Instant/now)))

(defn sha256-hex [s]
  (let [digest (MessageDigest/getInstance "SHA-256")
        bytes (.digest digest (.getBytes (str s) StandardCharsets/UTF_8))]
    (format "%064x" (BigInteger. 1 bytes))))

(defn asset-id-for [address]
  (sha256-hex (str "ipv4:" address)))

(defn service-id-for [address transport port]
  (sha256-hex (str address "|" transport "|" port)))

(defn parse-args [args]
  (if (seq args)
    (vec args)
    (let [raw (System/getenv "SSH_ORIGINAL_COMMAND")]
      (if (str/blank? raw)
        []
        (vec (str/split (str/trim raw) #"\s+"))))))

(defn require-run-id! [run-id]
  (when-not (re-matches uuid-re (str run-id))
    (die! "invalid run-id (expect UUID)")))

(defn require-member! [kind value allowed]
  (when-not (contains? allowed value)
    (die! (str "unknown or unapproved " kind ": " value))))

(defn write-status!
  [{:keys [runs_dir scanner_revision nuclei_templates_revision]}
   {:keys [run-id stage target-group status message]}]
  (let [dir (str runs_dir "/" run-id)
        status-file (str dir "/status.json")
        body {:run_id run-id
              :stage stage
              :target_group (or target-group "")
              :status status
              :message message
              :scanner_revision scanner_revision
              :nuclei_templates_revision nuclei_templates_revision
              :updated_at (now-iso)}]
    (fs/create-dirs dir)
    (spit status-file (str (json/generate-string body) "\n"))
    (println (json/generate-string body))
    body))

(defn with-lock! [{:keys [state_dir lock_file]} f]
  (fs/create-dirs state_dir)
  ;; babashka-unwrapped does not expose FileChannel/FileLock; use atomic create.
  (let [lock (io/file (str lock_file))]
    (when-not (.createNewFile lock)
      (die! 3 "another scan holds the exclusive lock"))
    (try
      (f)
      (finally
        (fs/delete-if-exists lock)))))

(defn lock-held? [{:keys [lock_file]}]
  (fs/exists? lock_file))

(defn clickhouse-password [{:keys [clickhouse_password_file]}]
  (when (and clickhouse_password_file (fs/exists? clickhouse_password_file))
    (str/trim (slurp clickhouse_password_file))))

(defn clickhouse-enabled? [cfg]
  (boolean (and (:clickhouse_url cfg)
                (:clickhouse_user cfg)
                (clickhouse-password cfg))))

(defn basic-auth-header [user password]
  (str "Basic "
       (.encodeToString
        (Base64/getEncoder)
        (.getBytes (str user ":" password) StandardCharsets/UTF_8))))

(defn ch-insert!
  "Insert JSONEachRow rows into ClickHouse. Soft-fails to stderr if CH is unset."
  [cfg table rows]
  (when (seq rows)
    (if-not (clickhouse-enabled? cfg)
      (binding [*out* *err*]
        (println "aether-scan: clickhouse writer not configured; skipping" table))
      (let [url (str (:clickhouse_url cfg)
                     "/?query="
                     (java.net.URLEncoder/encode
                      (str "INSERT INTO " table " FORMAT JSONEachRow")
                      StandardCharsets/UTF_8))
            body (str (str/join "\n" (map json/generate-string rows)) "\n")
            resp (http/post url
                            {:headers {"Authorization"
                                       (basic-auth-header (:clickhouse_user cfg)
                                                          (clickhouse-password cfg))
                                       "Content-Type" "application/json"}
                             :body body
                             :throw false})]
        (when-not (<= 200 (:status resp) 299)
          (die! 6 (str "clickhouse insert failed for " table
                       " status=" (:status resp)
                       " body=" (str/trim (str (:body resp))))))))))

(defn write-stage-artifact!
  [cfg {:keys [run-id stage target-group artifact-ref status started-at finished-at
               error-code error-message]}]
  (ch-insert!
   cfg "estate_scan.stage_artifacts"
   [{:run_id run-id
     :stage stage
     :target_group (or target-group "")
     :artifact_ref (or artifact-ref "")
     :status status
     :started_at (or started-at (now-ch))
     :finished_at finished-at
     :error_code (or error-code "")
     :error_message (or error-message "")
     :version (version-now)}]))

(defn write-scan-run!
  [cfg row]
  (ch-insert! cfg "estate_scan.scan_runs" [(merge {:error_code ""
                                                   :error_message ""
                                                   :finished_at nil
                                                   :target_count 0
                                                   :probe_count 0
                                                   :error_count 0
                                                   :timeout_count 0
                                                   :dropped_target_count 0
                                                   :coverage_ratio 0.0
                                                   :version (version-now)}
                                                  row)]))

(defn parse-naabu-lines [text]
  (->> (str/split-lines (or text ""))
       (remove str/blank?)
       (keep (fn [line]
               (try
                 (json/parse-string line true)
                 (catch Exception _ nil))))
       ;; Naabu can emit the same listener more than once; keep one row per ip:port.
       (group-by (fn [{:keys [host ip port protocol]}]
                   [(or host ip) (or protocol "tcp") port]))
       vals
       (map first)
       vec))

(defn write-discover-results!
  [cfg run-id target-group hosts open-rows]
  (let [ts (now-ch)
        ver (version-now)
        assets (mapv (fn [address]
                       {:asset_id (asset-id-for address)
                        :stable_identity (str "ipv4:" address)
                        :ipv4 address
                        :ipv6 nil
                        :dns_names []
                        :mac_address nil
                        :cloud_identity ""
                        :kubernetes_identity ""
                        :tailscale_identity ""
                        :declared 1
                        :provenance "declared"
                        :owning_source_file "config/vm.yml"
                        :first_seen_at ts
                        :last_seen_at ts
                        :vantage_points ["estate-scanner"]
                        :version ver})
                     hosts)
        services (mapv (fn [{:keys [host ip port protocol] :as row}]
                         (let [address (or host ip)
                               transport (or protocol "tcp")]
                           {:service_id (service-id-for address transport port)
                            :asset_id (asset-id-for address)
                            :run_id run-id
                            :transport transport
                            :port (int port)
                            :protocol transport
                            :product ""
                            :product_evidence (json/generate-string row)
                            :http_url ""
                            :tls_identity ""
                            :declared 1
                            :unexpected 0
                            :confidence 0.5
                            :first_seen_at ts
                            :last_seen_at ts
                            :resolved_at nil
                            :version ver}))
                       open-rows)]
    (when (seq assets)
      (ch-insert! cfg "estate_scan.assets" assets))
    (when (seq services)
      (ch-insert! cfg "estate_scan.services" services))))

(defn snapshot-targets!
  [cfg run-id profile]
  (let [{:keys [runs_dir artifacts_dir declared_targets
                scanner_revision nuclei_templates_revision]} cfg
        dir (str runs_dir "/" run-id)
        out-dir (str artifacts_dir "/" run-id)
        manifest (str dir "/targets.json")
        declared (json/parse-string (slurp declared_targets) true)
        body {:run_id run-id
              :profile profile
              :frozen_at (now-iso)
              :scanner_revision scanner_revision
              :nuclei_templates_revision nuclei_templates_revision
              :vantage "estate-scanner"
              :targets (:targets declared)}]
    (fs/create-dirs dir)
    (fs/create-dirs out-dir)
    (spit manifest (str (json/generate-string body {:pretty true}) "\n"))
    (fs/delete-if-exists (str out-dir "/targets.json"))
    (fs/create-sym-link (str out-dir "/targets.json") manifest)
    (write-scan-run!
     cfg {:run_id run-id
          :profile profile
          :vantage "estate-scanner"
          :scanner_revision scanner_revision
          :nuclei_templates_revision nuclei_templates_revision
          :status "accepted"
          :started_at (now-ch)
          :target_count (count (:targets declared))})
    (write-stage-artifact!
     cfg {:run-id run-id
          :stage "targets"
          :artifact-ref manifest
          :status "succeeded"
          :started-at (now-ch)
          :finished-at (now-ch)})
    (write-status! cfg {:run-id run-id
                        :stage "targets"
                        :status "succeeded"
                        :message "declared target snapshot frozen"})))

(defn discover-group!
  "Synchronous discovery worker. Called under the exclusive lock."
  [cfg run-id target-group]
  (let [{:keys [runs_dir artifacts_dir naabu scanner_revision
                nuclei_templates_revision]} cfg
        dir (str runs_dir "/" run-id)
        out-dir (str artifacts_dir "/" run-id)
        manifest (str dir "/targets.json")
        list-file (str out-dir "/discover-" target-group "-hosts.txt")
        result-file (str out-dir "/discover-" target-group ".jsonl")
        log-file (str out-dir "/discover-" target-group ".log")
        started-at (now-ch)]
    (fs/create-dirs dir)
    (fs/create-dirs out-dir)
    (when-not (fs/exists? manifest)
      (write-status! cfg {:run-id run-id
                          :stage "discover"
                          :target-group target-group
                          :status "failed"
                          :message "missing targets snapshot; run targets snapshot first"})
      (write-stage-artifact!
       cfg {:run-id run-id
            :stage "discover"
            :target-group target-group
            :status "failed"
            :started-at started-at
            :finished-at (now-ch)
            :error-code "missing_targets"
            :error-message "missing targets snapshot"})
      (System/exit 4))
    (write-status! cfg {:run-id run-id
                        :stage "discover"
                        :target-group target-group
                        :status "running"
                        :message "discovery started"})
    (write-scan-run!
     cfg {:run_id run-id
          :profile (or (-> (try (json/parse-string (slurp manifest) true)
                                (catch Exception _ nil))
                           :profile)
                       "discovery-common")
          :vantage "estate-scanner"
          :scanner_revision scanner_revision
          :nuclei_templates_revision nuclei_templates_revision
          :status "running"
          :started_at started-at})
    (write-stage-artifact!
     cfg {:run-id run-id
          :stage "discover"
          :target-group target-group
          :artifact-ref result-file
          :status "running"
          :started-at started-at})
    (let [hosts (->> (json/parse-string (slurp manifest) true)
                     :targets
                     (filter #(some #{target-group} (:target_groups %)))
                     (map :address)
                     (remove str/blank?)
                     sort
                     distinct
                     vec)]
      (spit list-file (str (str/join "\n" hosts) (when (seq hosts) "\n")))
      (if (empty? hosts)
        (do
          (spit result-file "")
          (write-discover-results! cfg run-id target-group [] [])
          (write-stage-artifact!
           cfg {:run-id run-id
                :stage "discover"
                :target-group target-group
                :artifact-ref result-file
                :status "succeeded"
                :started-at started-at
                :finished-at (now-ch)})
          (write-status! cfg {:run-id run-id
                              :stage "discover"
                              :target-group target-group
                              :status "succeeded"
                              :message "no declared targets for group"}))
        ;; Conservative defaults from estate-scanning.md; declared hosts only.
        (let [proc @(proc/process
                     [naabu
                      "-list" list-file
                      "-top-ports" "100"
                      "-scan-type" "syn"
                      "-interface" "eth0"
                      "-rate" "100"
                      "-c" "10"
                      "-timeout" "3"
                      "-retries" "1"
                      "-json"
                      "-silent"
                      "-nc"]
                     {:out :string :err :string})
              finished-at (now-ch)]
          (spit result-file (:out proc))
          (spit log-file (:err proc))
          (if-not (zero? (:exit proc))
            (do
              (write-stage-artifact!
               cfg {:run-id run-id
                    :stage "discover"
                    :target-group target-group
                    :artifact-ref result-file
                    :status "failed"
                    :started-at started-at
                    :finished-at finished-at
                    :error-code "naabu_exit"
                    :error-message (str "naabu exited " (:exit proc))})
              (write-scan-run!
               cfg {:run_id run-id
                    :profile "discovery-common"
                    :vantage "estate-scanner"
                    :scanner_revision scanner_revision
                    :nuclei_templates_revision nuclei_templates_revision
                    :status "failed"
                    :started_at started-at
                    :finished_at finished-at
                    :target_count (count hosts)
                    :error_code "naabu_exit"
                    :error_message (str "naabu exited " (:exit proc))})
              (write-status! cfg {:run-id run-id
                                  :stage "discover"
                                  :target-group target-group
                                  :status "failed"
                                  :message (str "naabu exited non-zero; see discover-"
                                                target-group ".log")})
              (System/exit 5))
            (let [open-rows (parse-naabu-lines (:out proc))
                  open-count (count open-rows)]
              (write-discover-results! cfg run-id target-group hosts open-rows)
              (write-stage-artifact!
               cfg {:run-id run-id
                    :stage "discover"
                    :target-group target-group
                    :artifact-ref result-file
                    :status "succeeded"
                    :started-at started-at
                    :finished-at finished-at})
              (write-scan-run!
               cfg {:run_id run-id
                    :profile (or (:profile (json/parse-string (slurp manifest) true))
                                 "discovery-common")
                    :vantage "estate-scanner"
                    :scanner_revision scanner_revision
                    :nuclei_templates_revision nuclei_templates_revision
                    :status "succeeded"
                    :started_at started-at
                    :finished_at finished-at
                    :target_count (count hosts)
                    :probe_count open-count
                    :coverage_ratio (if (pos? (count hosts))
                                      (float (/ (count (distinct (map #(or (:host %) (:ip %)) open-rows)))
                                               (count hosts)))
                                      0.0)})
              (write-status! cfg {:run-id run-id
                                  :stage "discover"
                                  :target-group target-group
                                  :status "succeeded"
                                  :message (str "discovered " open-count
                                                " open listeners across " (count hosts)
                                                " declared hosts (top-100)")}))))))))

(defn accept-discover!
  "Accept discover and detach via setsid so SSH/Kestra disconnect cannot kill it."
  [cfg run-id target-group]
  (when (lock-held? cfg)
    (die! 3 "another scan holds the exclusive lock"))
  (let [out-dir (str (:artifacts_dir cfg) "/" run-id)
        log-file (str out-dir "/discover-" target-group "-worker.log")]
    (fs/create-dirs out-dir)
    ;; Status first so a fast worker cannot be overwritten by a late "accepted".
    (write-status! cfg {:run-id run-id
                        :stage "discover"
                        :target-group target-group
                        :status "accepted"
                        :message (str "discover detached; worker log " log-file)})
    (let [proc @(proc/process
                 ["setsid" "-f"
                  aether-scan-bin "worker" "discover" run-id target-group]
                 {:out (io/file log-file)
                  :err :out
                  :in nil})]
      (when-not (zero? (:exit proc))
        (die! 1 (str "failed to detach discover worker; see " log-file))))))

(defn require-artifact-name! [name]
  (when-not (re-matches #"[A-Za-z0-9][A-Za-z0-9._-]{0,127}" (str name))
    (die! "invalid service-artifact name")))

(defn listener-key [{:keys [ip host port protocol]}]
  [(or ip host) (or protocol "tcp") (int port)])

(defn load-discover-listeners
  "Load and dedupe all discover-*.jsonl artifacts for a run."
  [out-dir]
  (->> (fs/glob out-dir "discover-*.jsonl")
       (map str)
       (remove #(str/includes? % "-worker"))
       (mapcat (fn [path]
                 (let [group (second (re-find #"discover-([A-Za-z0-9._-]+)\.jsonl$" path))]
                   (->> (parse-naabu-lines (slurp path))
                        (map #(assoc % :target_group group))))))
       (group-by listener-key)
       vals
       (map first)
       vec))

(defn ch-query!
  "Run a ClickHouse SELECT; returns parsed JSON rows or [] if writer unset."
  [cfg sql]
  (if-not (clickhouse-enabled? cfg)
    []
    (let [url (str (:clickhouse_url cfg)
                   "/?default_format=JSONEachRow&query="
                   (java.net.URLEncoder/encode sql StandardCharsets/UTF_8))
          resp (http/get url
                         {:headers {"Authorization"
                                    (basic-auth-header (:clickhouse_user cfg)
                                                       (clickhouse-password cfg))}
                          :throw false})]
      (when-not (<= 200 (:status resp) 299)
        (die! 6 (str "clickhouse query failed status=" (:status resp)
                     " body=" (str/trim (str (:body resp))))))
      (->> (str/split-lines (str (:body resp)))
           (remove str/blank?)
           (mapv #(json/parse-string % true))))))

(defn prior-listener-keys
  "Keys from the previous successful run's services (empty on first run)."
  [cfg run-id]
  (->> (ch-query!
        cfg
        (str "SELECT "
             "replaceOne(a.stable_identity, 'ipv4:', '') AS ip, "
             "s.port AS port, s.transport AS protocol "
             "FROM estate_scan.services AS s "
             "INNER JOIN estate_scan.assets AS a ON s.asset_id = a.asset_id "
             "WHERE s.run_id = ("
             "  SELECT run_id FROM estate_scan.scan_runs FINAL "
             "  WHERE status = 'succeeded' AND run_id != toUUID('" run-id "') "
             "  ORDER BY coalesce(finished_at, started_at) DESC LIMIT 1"
             ")"))
       (map (fn [{:keys [ip port protocol]}]
              [ip (or protocol "tcp") (int port)]))
       set))

(defn merge-diff!
  [cfg run-id]
  (let [out-dir (str (:artifacts_dir cfg) "/" run-id)
        started-at (now-ch)
        listeners (load-discover-listeners out-dir)
        prior-keys (prior-listener-keys cfg run-id)
        changed (filterv #(not (contains? prior-keys (listener-key %))) listeners)
        unchanged (filterv #(contains? prior-keys (listener-key %)) listeners)
        merge-path (str out-dir "/merge.json")
        changed-path (str out-dir "/services-changed.jsonl")
        unchanged-path (str out-dir "/services-unchanged.jsonl")
        body {:run_id run-id
              :merged_at (now-iso)
              :listener_count (count listeners)
              :changed_count (count changed)
              :unchanged_count (count unchanged)
              :fingerprint_needed (boolean (seq changed))
              :prior_baseline (if (seq prior-keys) "clickhouse" "none")}]
    (fs/create-dirs out-dir)
    (when (empty? listeners)
      (write-stage-artifact!
       cfg {:run-id run-id :stage "merge-diff" :artifact-ref merge-path
            :status "failed" :started-at started-at :finished-at (now-ch)
            :error-code "missing_discover" :error-message "no discover-*.jsonl artifacts"})
      (write-status! cfg {:run-id run-id :stage "merge-diff" :status "failed"
                          :message "no discover artifacts; run discover first"})
      (System/exit 4))
    (spit merge-path (str (json/generate-string body {:pretty true}) "\n"))
    (spit changed-path
          (str (str/join "\n" (map json/generate-string changed))
               (when (seq changed) "\n")))
    (spit unchanged-path
          (str (str/join "\n" (map json/generate-string unchanged))
               (when (seq unchanged) "\n")))
    (write-stage-artifact!
     cfg {:run-id run-id :stage "merge-diff" :artifact-ref changed-path
          :status "succeeded" :started-at started-at :finished-at (now-ch)})
    (write-status! cfg {:run-id run-id
                        :stage "merge-diff"
                        :status "succeeded"
                        :message (str (count changed) " new/changed of "
                                      (count listeners) " listeners"
                                      (if (seq changed)
                                        "; fingerprint needed"
                                        "; skip fingerprint"))})))

(defn http-candidate-urls
  "Build httpx probe URLs for a listener. Prefer https on 443/8443."
  [{:keys [ip host port]}]
  (let [address (or ip host)
        p (int port)]
    (cond
      (#{443 8443} p) [(str "https://" address ":" p)]
      (#{80 8000 8080 8081 8888 3000 9090 9200 5601} p)
      [(str "http://" address ":" p)]
      ;; Best-effort HTTP on other open ports; httpx fails fast on non-HTTP.
      :else [(str "http://" address ":" p)])))

(defn parse-jsonl [text]
  (->> (str/split-lines (or text ""))
       (remove str/blank?)
       (keep (fn [line]
               (try
                 (json/parse-string line true)
                 (catch Exception _ nil))))
       vec))

(defn write-fingerprint-results!
  [cfg run-id httpx-rows]
  (let [ts (now-ch)
        ver (version-now)
        services
        (mapv (fn [row]
                (let [address (or (first (:a row)) (:host row) (:ip row))
                      port (int (or (when (number? (:port row)) (:port row))
                                    (when (string? (:port row))
                                      (try (Integer/parseInt (:port row))
                                           (catch Exception _ nil)))
                                    0))
                      transport "tcp"
                      product (or (:webserver row)
                                  (some-> (:tech row) first)
                                  (when (:title row) (str "http-title:" (:title row)))
                                  "")
                      tls (or (some-> (:tls row) str) "")]
                  {:service_id (service-id-for address transport port)
                   :asset_id (asset-id-for address)
                   :run_id run-id
                   :transport transport
                   :port port
                   :protocol "http"
                   :product (str product)
                   :product_evidence (json/generate-string row)
                   :http_url (or (:url row) "")
                   :tls_identity (str tls)
                   :declared 1
                   :unexpected 0
                   :confidence (if (:failed row) 0.3 0.8)
                   :first_seen_at ts
                   :last_seen_at ts
                   :resolved_at nil
                   :version ver}))
              (filter #(and (or (first (:a %)) (:host %) (:ip %))
                            (pos? (int (or (when (number? (:port %)) (:port %))
                                          (when (string? (:port %))
                                            (try (Integer/parseInt (:port %))
                                                 (catch Exception _ 0)))
                                          0))))
                      httpx-rows))]
    (when (seq services)
      (ch-insert! cfg "estate_scan.services" services))))

(defn fingerprint!
  "HTTP/TLS normalize changed listeners with httpx (rate-limited)."
  [cfg run-id artifact-name]
  (let [{:keys [artifacts_dir httpx]} cfg
        out-dir (str artifacts_dir "/" run-id)
        artifact-path (str out-dir "/" artifact-name)
        list-file (str out-dir "/fingerprint-httpx-targets.txt")
        result-file (str out-dir "/fingerprint.jsonl")
        log-file (str out-dir "/fingerprint.log")
        started-at (now-ch)]
    (fs/create-dirs out-dir)
    (when-not (fs/exists? artifact-path)
      (write-status! cfg {:run-id run-id :stage "fingerprint" :status "failed"
                          :message (str "missing artifact " artifact-name)})
      (System/exit 4))
    (let [listeners (->> (parse-jsonl (slurp artifact-path)))
          urls (->> listeners (mapcat http-candidate-urls) distinct vec)]
      (write-status! cfg {:run-id run-id :stage "fingerprint" :status "running"
                          :message (str "fingerprinting " (count urls) " URLs")})
      (write-stage-artifact!
       cfg {:run-id run-id :stage "fingerprint" :artifact-ref result-file
            :status "running" :started-at started-at})
      (if (empty? urls)
        (do
          (spit result-file "")
          (write-stage-artifact!
           cfg {:run-id run-id :stage "fingerprint" :artifact-ref result-file
                :status "succeeded" :started-at started-at :finished-at (now-ch)})
          (write-status! cfg {:run-id run-id :stage "fingerprint" :status "succeeded"
                              :message "no HTTP candidates in artifact"}))
        (do
          (spit list-file (str (str/join "\n" urls) "\n"))
          (when-not httpx
            (die! 1 "httpx path missing from runtime.json"))
          (let [proc @(proc/process
                       [httpx
                        "-list" list-file
                        "-silent" "-json" "-nc"
                        "-timeout" "5"
                        "-threads" "10"
                        "-rate-limit" "25"
                        "-title" "-status-code" "-tech-detect"
                        "-web-server" "-ip"]
                       {:out :string :err :string})
                finished-at (now-ch)]
            (spit result-file (:out proc))
            (spit log-file (:err proc))
            (let [rows (parse-jsonl (:out proc))
                  hits (count rows)]
              (write-fingerprint-results! cfg run-id rows)
              (write-stage-artifact!
               cfg {:run-id run-id :stage "fingerprint" :artifact-ref result-file
                    :status "succeeded" :started-at started-at :finished-at finished-at})
              (write-status! cfg {:run-id run-id :stage "fingerprint" :status "succeeded"
                                  :message (str "fingerprinted " hits " HTTP(S) responses from "
                                                (count urls) " candidates"
                                                (when-not (zero? (:exit proc))
                                                  (str "; httpx exit " (:exit proc))))}))))))))

(defn accept-fingerprint!
  [cfg run-id artifact-name]
  (when (lock-held? cfg)
    (die! 3 "another scan holds the exclusive lock"))
  (let [out-dir (str (:artifacts_dir cfg) "/" run-id)
        log-file (str out-dir "/fingerprint-worker.log")]
    (fs/create-dirs out-dir)
    (write-status! cfg {:run-id run-id
                        :stage "fingerprint"
                        :status "accepted"
                        :message (str "fingerprint detached; worker log " log-file)})
    (let [proc @(proc/process
                 ["setsid" "-f"
                  aether-scan-bin "worker" "fingerprint" run-id artifact-name]
                 {:out (io/file log-file)
                  :err :out
                  :in nil})]
      (when-not (zero? (:exit proc))
        (die! 1 (str "failed to detach fingerprint worker; see " log-file))))))

(defn normalize-severity [s]
  (let [v (str/lower-case (str (or s "info")))]
    (if (#{"info" "low" "medium" "high" "critical"} v) v "info")))

(defn write-findings!
  [cfg run-id nuclei-rows]
  (let [ts (now-ch)
        ver (version-now)
        {:keys [scanner_revision nuclei_templates_revision]} cfg
        findings
        (mapv (fn [row]
                (let [host (or (:host row) (:ip row) (some-> (:url row) (str/replace #"^https?://" "") (str/split #"/|:|]") first))
                      port (int (or (:port row) 0))
                      template (or (:template-id row) (:templateID row) (:template row) "unknown")
                      matcher (or (:matcher-name row) (:matcher_name row) "")
                      sev (normalize-severity (:severity row))
                      sid (if (and host (pos? port))
                            (service-id-for host "tcp" port)
                            (sha256-hex (str "finding|" template "|" host)))
                      aid (if host (asset-id-for host) (sha256-hex "unknown-asset"))]
                  {:finding_key (sha256-hex (str template "|" host "|" port "|" matcher))
                   :run_id run-id
                   :asset_id aid
                   :service_id sid
                   :template_id (str template)
                   :matcher (str matcher)
                   :severity sev
                   :evidence (json/generate-string row)
                   :first_seen_at ts
                   :last_seen_at ts
                   :state "open"
                   :resolved_at nil
                   :scanner_revision scanner_revision
                   :nuclei_templates_revision nuclei_templates_revision
                   :exposure "internal"
                   :owner ""
                   :suppression_reason ""
                   :review_status ""
                   :version ver}))
              nuclei-rows)]
    (when (seq findings)
      (ch-insert! cfg "estate_scan.findings" findings))))

(defn http-targets-from-artifact
  "Build nuclei -l targets from fingerprint.jsonl or services-changed with URLs."
  [artifact-path]
  (let [rows (parse-jsonl (slurp artifact-path))]
    (->> rows
         (mapcat (fn [row]
                   (cond
                     (seq (:url row)) [(:url row)]
                     (and (:ip row) (:port row)) (http-candidate-urls row)
                     (and (:host row) (:port row)) (http-candidate-urls row)
                     :else [])))
         distinct
         vec)))

(defn validate!
  "Safe Nuclei validation against an HTTP(S) service artifact."
  [cfg run-id artifact-name profile]
  (let [{:keys [artifacts_dir templates_dir nuclei nuclei_templates_revision
                scanner_revision]} cfg
        out-dir (str artifacts_dir "/" run-id)
        artifact-path (str out-dir "/" artifact-name)
        list-file (str out-dir "/validate-nuclei-targets.txt")
        result-file (str out-dir "/validate-" profile ".jsonl")
        log-file (str out-dir "/validate-" profile ".log")
        templates (str templates_dir "/current")
        started-at (now-ch)]
    (fs/create-dirs out-dir)
    (when-not (fs/exists? artifact-path)
      (write-status! cfg {:run-id run-id :stage "validate" :status "failed"
                          :message (str "missing artifact " artifact-name)})
      (System/exit 4))
    (when-not (fs/exists? templates)
      (write-status! cfg {:run-id run-id :stage "validate" :status "failed"
                          :message "missing pinned nuclei templates"})
      (System/exit 4))
    (let [urls (http-targets-from-artifact artifact-path)]
      (write-status! cfg {:run-id run-id :stage "validate" :status "running"
                          :message (str "nuclei " profile " on " (count urls) " URLs")})
      (write-stage-artifact!
       cfg {:run-id run-id :stage "validate" :artifact-ref result-file
            :status "running" :started-at started-at})
      (if (empty? urls)
        (do
          (spit result-file "")
          (write-stage-artifact!
           cfg {:run-id run-id :stage "validate" :artifact-ref result-file
                :status "succeeded" :started-at started-at :finished-at (now-ch)})
          (write-status! cfg {:run-id run-id :stage "validate" :status "succeeded"
                              :message "no HTTP(S) targets in artifact; skipped nuclei"}))
        (do
          (spit list-file (str (str/join "\n" urls) "\n"))
          (when-not nuclei (die! 1 "nuclei path missing from runtime.json"))
          ;; Conservative: http(s) only, pinned templates, low rate, no interactsh.
          (let [severity (if (= profile "nuclei-weekly")
                           ["-s" "info,low,medium,high,critical"]
                           ["-s" "medium,high,critical"])
                proc @(proc/process
                       (into [nuclei
                              "-l" list-file
                              "-t" templates]
                             (concat severity
                                     ["-rate-limit" "25"
                                      "-c" "10"
                                      "-timeout" "5"
                                      "-retries" "1"
                                      "-jsonl"
                                      "-silent"
                                      "-nc"
                                      "-disable-update-check"
                                      "-no-interactsh"]))
                       {:out :string :err :string})
                finished-at (now-ch)
                rows (parse-jsonl (:out proc))]
            (spit result-file (:out proc))
            (spit log-file (:err proc))
            (write-findings! cfg run-id rows)
            (write-stage-artifact!
             cfg {:run-id run-id :stage "validate" :artifact-ref result-file
                  :status (if (zero? (:exit proc)) "succeeded" "succeeded")
                  :started-at started-at :finished-at finished-at
                  :error-code (when-not (zero? (:exit proc)) "nuclei_exit")
                  :error-message (when-not (zero? (:exit proc))
                                   (str "nuclei exit " (:exit proc)))})
            (write-scan-run!
             cfg {:run_id run-id
                  :profile profile
                  :vantage "estate-scanner"
                  :scanner_revision scanner_revision
                  :nuclei_templates_revision nuclei_templates_revision
                  :status "running"
                  :started_at started-at
                  :probe_count (count rows)})
            (write-status! cfg {:run-id run-id :stage "validate" :status "succeeded"
                                :message (str "nuclei " profile ": " (count rows)
                                              " findings from " (count urls) " URLs"
                                              (when-not (zero? (:exit proc))
                                                (str "; exit " (:exit proc))))})))))))

(defn accept-validate!
  [cfg run-id artifact-name profile]
  (when (lock-held? cfg)
    (die! 3 "another scan holds the exclusive lock"))
  (let [out-dir (str (:artifacts_dir cfg) "/" run-id)
        log-file (str out-dir "/validate-" profile "-worker.log")]
    (fs/create-dirs out-dir)
    (write-status! cfg {:run-id run-id
                        :stage "validate"
                        :status "accepted"
                        :message (str "validate detached; worker log " log-file)})
    (let [proc @(proc/process
                 ["setsid" "-f"
                  aether-scan-bin "worker" "validate" run-id artifact-name profile]
                 {:out (io/file log-file)
                  :err :out
                  :in nil})]
      (when-not (zero? (:exit proc))
        (die! 1 (str "failed to detach validate worker; see " log-file))))))

(defn finalize!
  [cfg run-id]
  (let [{:keys [artifacts_dir scanner_revision nuclei_templates_revision]} cfg
        out-dir (str artifacts_dir "/" run-id)
        status-path (str (:runs_dir cfg) "/" run-id "/status.json")
        started-at (now-ch)
        prior (when (fs/exists? status-path)
                (try (json/parse-string (slurp status-path) true)
                     (catch Exception _ nil)))
        failed? (= "failed" (:status prior))]
    (fs/create-dirs out-dir)
    (write-scan-run!
     cfg {:run_id run-id
          :profile "discovery-common"
          :vantage "estate-scanner"
          :scanner_revision scanner_revision
          :nuclei_templates_revision nuclei_templates_revision
          :status (if failed? "failed" "succeeded")
          :started_at started-at
          :finished_at (now-ch)})
    (write-stage-artifact!
     cfg {:run-id run-id :stage "finalize" :artifact-ref status-path
          :status (if failed? "failed" "succeeded")
          :started-at started-at :finished-at (now-ch)})
    (write-status! cfg {:run-id run-id
                        :stage "finalize"
                        :status (if failed? "failed" "succeeded")
                        :message (if failed?
                                   "finalize recorded failed run lineage"
                                   "finalize recorded succeeded run lineage")})))

(defn stub!
  [cfg run-id stage message & {:keys [target-group]}]
  (write-status! cfg {:run-id run-id
                      :stage stage
                      :target-group target-group
                      :status "stubbed"
                      :message message}))

(defn print-status!
  "Print compact status JSON. Exit 0 only when recorded stage matches and
  status is succeeded (Kestra poll tasks rely on this)."
  [cfg run-id stage target-group]
  (let [status-file (str (:runs_dir cfg) "/" run-id "/status.json")]
    (if-not (fs/exists? status-file)
      (do (write-status! cfg {:run-id run-id
                              :stage stage
                              :target-group target-group
                              :status "missing"
                              :message "no status recorded for run"})
          (System/exit 4))
      (let [body (try (json/parse-string (slurp status-file) true)
                      (catch Exception _
                        (die! 4 "status.json unreadable")))
            same-stage? (= stage (:stage body))
            same-group? (or (str/blank? (str target-group))
                            (= (str target-group) (str (:target_group body))))
            ok? (and same-stage? same-group? (= "succeeded" (:status body)))]
        (println (json/generate-string body))
        (when-not ok?
          (System/exit (if (= "failed" (:status body)) 5 4)))))))

(defn -main [& args]
  (let [cfg (load-config)
        args (parse-args args)
        profiles (set (:approved_profiles cfg))
        groups (set (:approved_target_groups cfg))
        stages (set (:approved_stages cfg))]
    (when (empty? args)
      (println usage-text)
      (System/exit 2))
    (case (first args)
      "targets"
      (let [[_ snapshot run-id profile] args]
        (when (or (not= snapshot "snapshot") (nil? run-id) (nil? profile) (nth args 4 nil))
          (println usage-text)
          (System/exit 2))
        (require-run-id! run-id)
        (require-member! "profile" profile profiles)
        (with-lock! cfg #(snapshot-targets! cfg run-id profile)))

      "discover"
      (let [[_ run-id target-group] args]
        (when (or (nil? run-id) (nil? target-group) (nth args 3 nil))
          (println usage-text)
          (System/exit 2))
        (require-run-id! run-id)
        (require-member! "target-group" target-group groups)
        (accept-discover! cfg run-id target-group))

      "worker"
      (let [[_ stage & rest] args]
        (case stage
          "discover"
          (let [[run-id target-group] rest]
            (when (or (nil? run-id) (nil? target-group))
              (println usage-text)
              (System/exit 2))
            (require-run-id! run-id)
            (require-member! "target-group" target-group groups)
            (with-lock! cfg #(discover-group! cfg run-id target-group)))

          "fingerprint"
          (let [[run-id artifact-name] rest]
            (when (or (nil? run-id) (nil? artifact-name))
              (println usage-text)
              (System/exit 2))
            (require-run-id! run-id)
            (require-artifact-name! artifact-name)
            (with-lock! cfg #(fingerprint! cfg run-id artifact-name)))

          "validate"
          (let [[run-id artifact-name profile] rest]
            (when (or (nil? run-id) (nil? artifact-name) (nil? profile))
              (println usage-text)
              (System/exit 2))
            (require-run-id! run-id)
            (require-artifact-name! artifact-name)
            (require-member! "profile" profile profiles)
            (with-lock! cfg #(validate! cfg run-id artifact-name profile)))

          (die! (str "unknown worker stage: " stage))))

      "merge-diff"
      (let [[_ run-id] args]
        (when (or (nil? run-id) (nth args 2 nil))
          (println usage-text)
          (System/exit 2))
        (require-run-id! run-id)
        (with-lock! cfg #(merge-diff! cfg run-id)))

      "fingerprint"
      (let [[_ run-id artifact-name] args]
        (when (or (nil? run-id) (nil? artifact-name) (nth args 3 nil))
          (println usage-text)
          (System/exit 2))
        (require-run-id! run-id)
        (require-artifact-name! artifact-name)
        (accept-fingerprint! cfg run-id artifact-name))

      "validate"
      (let [[_ run-id artifact profile] args]
        (when (or (nil? run-id) (nil? artifact) (nil? profile) (nth args 4 nil))
          (println usage-text)
          (System/exit 2))
        (require-run-id! run-id)
        (require-artifact-name! artifact)
        (require-member! "profile" profile profiles)
        (accept-validate! cfg run-id artifact profile))

      "finalize"
      (let [[_ run-id] args]
        (when (or (nil? run-id) (nth args 2 nil))
          (println usage-text)
          (System/exit 2))
        (require-run-id! run-id)
        (with-lock! cfg #(finalize! cfg run-id)))

      "status"
      (let [[_ run-id stage target-group] args]
        (when (or (nil? run-id) (nil? stage))
          (println usage-text)
          (System/exit 2))
        (require-run-id! run-id)
        (require-member! "stage" stage stages)
        (when target-group
          (require-member! "target-group" target-group groups))
        (print-status! cfg run-id stage target-group))

      ("-h" "--help" "help")
      (println usage-text)

      (die! (str "rejecting unknown operation or shell fragment: " (first args))))))

(apply -main *command-line-args*)
