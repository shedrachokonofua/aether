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
  aether-scan worker discover <run-id> <target-group>
  aether-scan merge-diff <run-id>
  aether-scan fingerprint <run-id> <service-artifact>
  aether-scan validate <run-id> <service-artifact> <approved-profile>
  aether-scan finalize <run-id>
  aether-scan status <run-id> <stage> [target-group]

Rejects caller-supplied shell, rates, templates, targets, and output paths.
discover accepts and detaches; worker discover performs the scan.")

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
    ;; setsid -f: fork into a new session that survives SSH hangup.
    (let [proc @(proc/process
                 ["setsid" "-f"
                  aether-scan-bin "worker" "discover" run-id target-group]
                 {:out (io/file log-file)
                  :err :out
                  :in nil})]
      (when-not (zero? (:exit proc))
        (die! 1 (str "failed to detach discover worker; see " log-file))))
    ;; Brief settle so status.json exists for immediate pollers.
    (.sleep TimeUnit/MILLISECONDS 250)
    (write-status! cfg {:run-id run-id
                        :stage "discover"
                        :target-group target-group
                        :status "accepted"
                        :message (str "discover detached; worker log " log-file)})))

(defn stub!
  [cfg run-id stage message & {:keys [target-group]}]
  (write-status! cfg {:run-id run-id
                      :stage stage
                      :target-group target-group
                      :status "stubbed"
                      :message message}))

(defn print-status!
  [cfg run-id stage target-group]
  (let [status-file (str (:runs_dir cfg) "/" run-id "/status.json")]
    (if (fs/exists? status-file)
      (print (slurp status-file))
      (write-status! cfg {:run-id run-id
                          :stage stage
                          :target-group target-group
                          :status "missing"
                          :message "no status recorded for run"}))))

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
      (let [[_ stage run-id target-group] args]
        (when (or (not= stage "discover") (nil? run-id) (nil? target-group))
          (println usage-text)
          (System/exit 2))
        (require-run-id! run-id)
        (require-member! "target-group" target-group groups)
        (with-lock! cfg #(discover-group! cfg run-id target-group)))

      "merge-diff"
      (let [[_ run-id] args]
        (when-not run-id (println usage-text) (System/exit 2))
        (require-run-id! run-id)
        (stub! cfg run-id "merge-diff" "merge-diff not implemented yet"))

      "fingerprint"
      (let [[_ run-id] args]
        (when-not run-id (println usage-text) (System/exit 2))
        (require-run-id! run-id)
        (stub! cfg run-id "fingerprint" "fingerprint not implemented yet"))

      "validate"
      (let [[_ run-id _artifact profile] args]
        (when (or (nil? run-id) (nil? profile))
          (println usage-text)
          (System/exit 2))
        (require-run-id! run-id)
        (require-member! "profile" profile profiles)
        (stub! cfg run-id "validate"
               (str "validate not implemented yet; templates pinned at "
                    (:nuclei_templates_revision cfg))))

      "finalize"
      (let [[_ run-id] args]
        (when-not run-id (println usage-text) (System/exit 2))
        (require-run-id! run-id)
        (stub! cfg run-id "finalize" "finalize not implemented yet"))

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
