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
           [java.net InetAddress]
           [java.util Base64]
           [java.util.concurrent TimeUnit]))

(def usage-text
  "aether-scan — typed estate-scanner dispatcher (Kestra forced-command entrypoint)

Usage:
  aether-scan targets snapshot <run-id> <profile>
  aether-scan inventory-sync [<run-id>]
  aether-scan discover <run-id> <target-group>
  aether-scan merge-diff <run-id>
  aether-scan fingerprint <run-id> <service-artifact>
  aether-scan validate <run-id> <service-artifact> <approved-profile>
  aether-scan finalize <run-id>
  aether-scan ingest-validate <run-id> <approved-profile>
  aether-scan abandon <run-id> [reason-token]
  aether-scan reap-stale
  aether-scan worker discover <run-id> <target-group>
  aether-scan worker fingerprint <run-id> <service-artifact>
  aether-scan worker validate <run-id> <service-artifact> <approved-profile>
  aether-scan status <run-id> <stage> [target-group]
  aether-scan wait-stage <run-id> <stage> [target-group] [timeout-seconds]

Rejects caller-supplied shell, rates, templates, targets, and output paths.
discover/fingerprint/validate accept and detach; worker stages perform the work.
inventory-sync refreshes CT + DNS from baked synthetic_probe inventory (CT-only is report-only).
wait-stage polls on-guest status.json (avoids Kestra LoopUntil + SSH exitCode gaps).
ingest-validate reloads an on-disk validate-*.jsonl into ClickHouse without re-scanning.
abandon/reap-stale close orphan ClickHouse scan_runs rows.")

(def uuid-re
  #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

(def reason-token-re
  #"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")

(def ipv4-re
  #"^(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)$")

(def shdr-hostname-re
  #"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*\.shdr\.ch$")

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

(defn ipv4-literal? [s]
  (boolean (re-matches ipv4-re (str s))))

(defn canonicalize-hostname
  "Lowercase, trim trailing dot, reject wildcards / non-shdr.ch."
  [s]
  (when-not (str/blank? s)
    (let [n (-> (str s)
                str/lower-case
                (str/replace #"\.$" "")
                str/trim)]
      (when (and (not (str/starts-with? n "*."))
                 (re-matches shdr-hostname-re n))
        n))))

(defn canonicalize-path
  "Resolve symlinks for Nuclei -t paths. Nuclei 3.11 does not walk a -t
  argument that is itself a directory symlink (/etc/estate-scanner/nuclei-*)."
  [p]
  (when (and p (fs/exists? p))
    (try
      (.getCanonicalPath (io/file (str p)))
      (catch Exception _
        (str p)))))

(defn stable-identity-for
  "ipv4:<addr> for literals; dns:<fqdn> for hostnames."
  [host]
  (let [h (str host)]
    (if (ipv4-literal? h)
      (str "ipv4:" h)
      (str "dns:" (or (canonicalize-hostname h) (str/lower-case h))))))

(defn asset-id-for [address]
  (sha256-hex (stable-identity-for address)))

(defn service-id-for [address transport port]
  (sha256-hex (str address "|" transport "|" port)))

(defn finding-host-from-row
  "Prefer URL hostname so Nuclei SNI findings join dns: assets."
  [row]
  (or (some-> (:url row)
              (str/replace #"^https?://" "")
              (str/split #"/|:|]")
              first
              not-empty)
      (:host row)
      (:ip row)))

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

(defn load-run-manifest
  [cfg run-id]
  (let [path (str (:runs_dir cfg) "/" run-id "/targets.json")]
    (when (fs/exists? path)
      (try (json/parse-string (slurp path) true)
           (catch Exception _ nil)))))

(defn run-profile
  "Profile frozen in targets.json for this run (never invent discovery-common)."
  [cfg run-id]
  (or (:profile (load-run-manifest cfg run-id)) "unknown"))

(defn load-validate-evidence
  [cfg run-id]
  (let [path (str (:artifacts_dir cfg) "/" run-id "/validate-evidence.json")]
    (when (fs/exists? path)
      (try (json/parse-string (slurp path) true)
           (catch Exception _ nil)))))

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

(defn expand-cidr4
  "Expand IPv4 CIDR to host addresses (excludes network/broadcast for /24+)."
  [cidr]
  (let [[net prefix-s] (str/split cidr #"/")
        prefix (Integer/parseInt prefix-s)
        _ (when-not (<= 8 prefix 30)
            (die! (str "unsupported CIDR prefix: " cidr)))
        octets (mapv #(Integer/parseInt %) (str/split net #"\."))
        _ (when-not (= 4 (count octets))
            (die! (str "invalid IPv4 network: " cidr)))
        base (bit-or (bit-shift-left (nth octets 0) 24)
                     (bit-shift-left (nth octets 1) 16)
                     (bit-shift-left (nth octets 2) 8)
                     (nth octets 3))
        host-bits (- 32 prefix)
        size (bit-shift-left 1 host-bits)
        mask (bit-not (dec size))
        network (bit-and base mask)]
    (for [i (range 1 (dec size))]
      (let [addr (+ network i)]
        (str (bit-and (bit-shift-right addr 24) 0xff) "."
             (bit-and (bit-shift-right addr 16) 0xff) "."
             (bit-and (bit-shift-right addr 8) 0xff) "."
             (bit-and addr 0xff))))))

(defn discover-mode
  "Resolve Naabu port/rate policy from run profile + fragile-group caps."
  [cfg profile target-group]
  (let [profiles (:discover_profiles cfg)
        mode (or (get profiles (keyword profile))
                 (get profiles profile)
                 {:ports "top-100" :rate 100 :concurrency 10 :timeout 3 :retries 1})
        group-rates (:discover_group_rates cfg)
        group-cap (or (get group-rates (keyword target-group))
                      (get group-rates target-group))
        base-rate (int (or (:rate mode) 100))
        rate (int (if group-cap (min group-cap base-rate) base-rate))]
    (assoc mode :rate rate :profile profile)))

(defn hosts-for-discover
  "Declared hosts for group, or CIDR expansion for discover_cidrs groups."
  [cfg run-id target-group]
  (let [manifest (str (:runs_dir cfg) "/" run-id "/targets.json")
        cidrs (or (get (:discover_cidrs cfg) (keyword target-group))
                  (get (:discover_cidrs cfg) target-group))]
    (if (seq cidrs)
      {:hosts (->> cidrs (mapcat expand-cidr4) distinct sort vec)
       :provenance "cidr"}
      (let [hosts (->> (json/parse-string (slurp manifest) true)
                       :targets
                       (filter #(some #{target-group} (:target_groups %)))
                       (map :address)
                       (remove str/blank?)
                       sort
                       distinct
                       vec)]
        {:hosts hosts :provenance "declared"}))))

(defn naabu-port-args
  [{:keys [ports]}]
  (case (name (keyword ports))
    "all" ["-p" "-"]
    "top-1000" ["-top-ports" "1000"]
    "top-100" ["-top-ports" "100"]
    ["-top-ports" "100"]))

(defn write-discover-results!
  [cfg run-id target-group hosts open-rows & {:keys [provenance] :or {provenance "declared"}}]
  (let [ts (now-ch)
        ver (version-now)
        declared? (= provenance "declared")
        open-hosts (->> open-rows
                        (map #(or (:host %) (:ip %)))
                        (remove str/blank?)
                        distinct
                        vec)
        ;; Declared sweeps record the whole target list; CIDR sweeps only responders.
        asset-hosts (if declared? hosts open-hosts)
        assets (mapv (fn [address]
                       {:asset_id (asset-id-for address)
                        :stable_identity (stable-identity-for address)
                        :ipv4 address
                        :ipv6 nil
                        :dns_names []
                        :mac_address nil
                        :cloud_identity ""
                        :kubernetes_identity ""
                        :tailscale_identity ""
                        :declared (if declared? 1 0)
                        :provenance provenance
                        :owning_source_file (if declared? "config/vm.yml" "cidr-sweep")
                        :first_seen_at ts
                        :last_seen_at ts
                        :vantage_points ["estate-scanner"]
                        :version ver})
                     asset-hosts)
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
                            :declared (if declared? 1 0)
                            :unexpected (if declared? 0 1)
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

(defn resolve-a-record
  "Best-effort A lookup; returns dotted IPv4 string or nil."
  [hostname]
  (try
    (let [addrs (InetAddress/getAllByName (str hostname))]
      (->> addrs
           (map #(.getHostAddress %))
           (filter ipv4-literal?)
           first))
    (catch Exception _ nil)))

(defn fetch-ct-names!
  "Query fixed crt.sh URL with retries. Returns {:status :names}."
  [cfg]
  (let [curl (or (:curl cfg) "curl")
        url (or (:ct_query_url cfg) "https://crt.sh/?q=%25.shdr.ch&output=json")
        timeout-ms (long (or (:ct_timeout_ms cfg) 60000))
        timeout-s (max 5 (int (/ timeout-ms 1000)))
        attempts (long (or (:ct_retries cfg) 3))]
    (loop [n 1
           last-msg ""]
      (let [tmp (str "/tmp/estate-ct-" (System/currentTimeMillis) "-" n ".json")
            result
            (try
              (let [proc @(proc/process
                           [curl "-sS" "--max-time" (str timeout-s) "-o" tmp url]
                           {:out :string :err :string})
                    body (when (fs/exists? tmp) (slurp tmp))
                    err (str/trim (str (:err proc)))]
                (cond
                  (not (zero? (:exit proc)))
                  {:status "error" :names [] :message (str "curl exit " (:exit proc) " " err)}

                  (or (str/blank? body) (str/starts-with? (str/trim body) "<"))
                  {:status "error" :names [] :message (str "ct non-json body len="
                                                           (count (str body)))}

                  :else
                  (let [rows (try (json/parse-string body true)
                                  (catch Exception e {:parse-error (.getMessage e)}))]
                    (if (:parse-error rows)
                      {:status "error" :names [] :message (str "ct json parse failed: "
                                                               (:parse-error rows))}
                      (let [names (->> (if (sequential? rows) rows [])
                                       (mapcat (fn [row]
                                                 (let [nv (or (:name_value row)
                                                              (:common_name row) "")]
                                                   (str/split (str nv) #"[\s,]+"))))
                                       (map canonicalize-hostname)
                                       (remove nil?)
                                       distinct
                                       vec)]
                        {:status "ok" :names names
                         :message (str "ct names=" (count names))})))))
              (catch Exception e
                {:status "error" :names [] :message (.getMessage e)})
              (finally
                (fs/delete-if-exists tmp)))]
        (cond
          (= "ok" (:status result)) result
          (>= n attempts) (assoc result :message (str (:message result)
                                                      (when-not (str/blank? last-msg)
                                                        (str "; prior=" last-msg))))
          :else (do
                  (Thread/sleep (* 2000 n))
                  (recur (inc n) (:message result))))))))

(defn load-ct-last-good
  [inventory-dir]
  (let [path (str inventory-dir "/ct-last-good.json")]
    (when (fs/exists? path)
      (try
        (let [body (json/parse-string (slurp path) true)]
          {:names (or (:names body) [])
           :fetched_at (:fetched_at body)})
        (catch Exception _ nil)))))

(defn write-ct-last-good!
  [inventory-dir names]
  (let [path (str inventory-dir "/ct-last-good.json")
        tmp (str path ".tmp")]
    (fs/create-dirs inventory-dir)
    (spit tmp (str (json/generate-string
                    {:fetched_at (now-iso)
                     :names names}
                    {:pretty true})
                   "\n"))
    (fs/move tmp path {:replace-existing true})
    (try
      (fs/set-posix-file-permissions path "rw-rw-r--")
      (catch Exception _ nil))))

(defn inventory-sync!
  "Merge baked synthetic_probe inventory with CT; CT-only is report-only."
  [cfg run-id]
  (let [{:keys [inventory_declared inventory_dir inventory_revision
                inventory_max_names artifacts_dir]} cfg
        inv-dir (or inventory_dir "/var/lib/estate-scanner/inventory")
        max-n (long (or inventory_max_names 500))
        started-at (now-ch)
        declared-path (or inventory_declared "/etc/estate-scanner/inventory-declared.json")]
    (when-not (fs/exists? declared-path)
      (die! 1 (str "missing inventory-declared.json: " declared-path)))
    (fs/create-dirs inv-dir)
    (when run-id
      (require-run-id! run-id)
      (fs/create-dirs (str artifacts_dir "/" run-id))
      (write-status! cfg {:run-id run-id
                          :stage "inventory-sync"
                          :status "running"
                          :message "loading declared inventory + CT"}))
    (let [declared-doc (json/parse-string (slurp declared-path) true)
          rev (or (:inventory_revision declared-doc) inventory_revision "")
          declared-entries (or (:entries declared-doc) [])
          declared-by-name (into {} (map (fn [e] [(:name e) e]) declared-entries))
          ct (fetch-ct-names! cfg)
          last-good (load-ct-last-good inv-dir)
          ct-status (cond
                      (= "ok" (:status ct)) "ok"
                      (seq (:names last-good)) "last_known_good"
                      :else (or (:status ct) "error"))
          ct-names (if (= "ok" (:status ct))
                     (:names ct)
                     (or (:names last-good) []))
          _ (when (= "ok" (:status ct))
              (write-ct-last-good! inv-dir ct-names))
          ct-only (->> ct-names
                       (remove #(contains? declared-by-name %))
                       (take max-n)
                       vec)
          merged
          (vec
           (take max-n
                 (concat
                  (map (fn [e]
                         (let [name (:name e)
                               ipv4 (resolve-a-record name)]
                           (assoc e
                                  :kind "hostname"
                                  :ipv4 ipv4
                                  :address (or ipv4 "")
                                  :inventory_revision rev)))
                       declared-entries)
                  (map (fn [name]
                         (let [ipv4 (resolve-a-record name)]
                           {:name name
                            :kind "hostname"
                            :url ""
                            :provenance "ct"
                            :owning_source_file "crt.sh"
                            :namespace ""
                            :exposure ""
                            :criticality ""
                            :declared 0
                            :l7_scan_enabled 0
                            :ipv4 ipv4
                            :address (or ipv4 "")
                            :inventory_revision rev}))
                       ct-only))))
          scannable (->> merged (filter #(= 1 (int (or (:l7_scan_enabled %) 0)))) vec)
          current {:frozen_at (now-iso)
                   :inventory_revision rev
                   :ct_status ct-status
                   :ct_message (or (:message ct) "")
                   :declared_count (count declared-entries)
                   :ct_count (count ct-names)
                   :ct_only_count (count ct-only)
                   :scannable_count (count scannable)
                   :entry_count (count merged)
                   :entries merged}
          current-path (str inv-dir "/inventory-current.json")
          https-urls (->> scannable
                          (filter (fn [e]
                                    (let [allowed (set (map name (or (:inventory_l7_exposures cfg) [])))]
                                      (or (empty? allowed)
                                          (contains? allowed (str (:exposure e)))))))
                          (map :url)
                          (remove str/blank?)
                          distinct
                          vec)
          ts (now-ch)
          ver (version-now)
          assets (mapv (fn [e]
                         (let [name (:name e)
                               ipv4 (:ipv4 e)]
                           {:asset_id (asset-id-for name)
                            :stable_identity (stable-identity-for name)
                            :ipv4 ipv4
                            :ipv6 nil
                            :dns_names [name]
                            :mac_address nil
                            :cloud_identity ""
                            :kubernetes_identity ""
                            :tailscale_identity ""
                            :declared (int (or (:declared e) 0))
                            :provenance (or (:provenance e) "inventory")
                            :owning_source_file (or (:owning_source_file e) "")
                            :first_seen_at ts
                            :last_seen_at ts
                            :vantage_points ["estate-scanner"]
                            :version ver}))
                       merged)
          name-rows (mapv (fn [e]
                            {:name (:name e)
                             :declared (int (or (:declared e) 0))
                             :l7_scan_enabled (int (or (:l7_scan_enabled e) 0))
                             :provenance (or (:provenance e) "")
                             :ipv4 (:ipv4 e)
                             :url (or (:url e) "")
                             :exposure (or (:exposure e) "")
                             :inventory_revision rev
                             :observed_at ts
                             :version ver})
                          merged)
          observation {:observed_at ts
                       :inventory_revision rev
                       :source "inventory-sync"
                       :declared_count (count declared-entries)
                       :ct_count (count ct-names)
                       :scannable_count (count scannable)
                       :ct_only_count (count ct-only)
                       :ct_status ct-status
                       :payload (json/generate-string
                                 {:ct_only (mapv :name (filter #(zero? (int (or (:declared %) 0))) merged))
                                  :ct_message (or (:message ct) "")})
                       :version ver}]
      (spit current-path (str (json/generate-string current {:pretty true}) "\n"))
      (try
        (fs/set-posix-file-permissions current-path "rw-rw-r--")
        (catch Exception _ nil))
      (when (seq assets)
        (ch-insert! cfg "estate_scan.assets" assets))
      (when (seq name-rows)
        (ch-insert! cfg "estate_scan.inventory_names" name-rows))
      (ch-insert! cfg "estate_scan.inventory_observations" [observation])
      (when run-id
        (let [out-dir (str artifacts_dir "/" run-id)
              snap (str out-dir "/inventory-snapshot.json")
              https (str out-dir "/inventory-https.txt")]
          (fs/create-dirs out-dir)
          (spit snap (str (json/generate-string current {:pretty true}) "\n"))
          (spit https (str (str/join "\n" https-urls)
                           (when (seq https-urls) "\n")))
          (write-stage-artifact!
           cfg {:run-id run-id
                :stage "inventory-sync"
                :artifact-ref snap
                :status "succeeded"
                :started-at started-at
                :finished-at (now-ch)})))
      (let [summary {:stage "inventory-sync"
                     :status "succeeded"
                     :message (str "inventory rev=" (subs rev 0 (min 12 (count rev)))
                                   " declared=" (count declared-entries)
                                   " scannable=" (count scannable)
                                   " ct_only=" (count ct-only)
                                   " ct=" ct-status)
                     :declared_count (count declared-entries)
                     :scannable_count (count scannable)
                     :ct_only_count (count ct-only)
                     :ct_status ct-status
                     :inventory_revision rev}]
        (when run-id
          (write-status! cfg (assoc summary :run-id run-id)))
        (println (json/generate-string (cond-> summary
                                         run-id (assoc :run_id run-id))))))))

(defn load-inventory-https-urls
  "Scannable hostname URLs from run artifact or global inventory-current.
  Honors inventory_l7_exposures allowlist when set (default: all exposures)."
  [cfg run-id]
  (let [out-dir (str (:artifacts_dir cfg) "/" run-id)
        run-https (str out-dir "/inventory-https.txt")
        current (str (or (:inventory_dir cfg) "/var/lib/estate-scanner/inventory")
                     "/inventory-current.json")
        allowed (set (map name (or (:inventory_l7_exposures cfg) [])))
        exposure-ok? (fn [e]
                       (or (empty? allowed)
                           (contains? allowed (str (:exposure e)))))]
    (cond
      (and (fs/exists? run-https) (empty? allowed))
      (->> (str/split-lines (slurp run-https))
           (map str/trim)
           (remove str/blank?)
           vec)

      (fs/exists? current)
      (let [doc (try (json/parse-string (slurp current) true)
                     (catch Exception _ nil))]
        (->> (or (:entries doc) [])
             (filter #(= 1 (int (or (:l7_scan_enabled %) 0))))
             (filter exposure-ok?)
             (map :url)
             (remove str/blank?)
             distinct
             vec))

      (fs/exists? run-https)
      (->> (str/split-lines (slurp run-https))
           (map str/trim)
           (remove str/blank?)
           vec)

      :else [])))

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
    (let [profile (or (-> (try (json/parse-string (slurp manifest) true)
                               (catch Exception _ nil))
                          :profile)
                      "discovery-common")
          mode (discover-mode cfg profile target-group)
          {:keys [hosts provenance]} (hosts-for-discover cfg run-id target-group)
          port-label (name (keyword (:ports mode)))]
      (spit list-file (str (str/join "\n" hosts) (when (seq hosts) "\n")))
      (if (empty? hosts)
        (do
          (spit result-file "")
          (write-discover-results! cfg run-id target-group [] [] :provenance provenance)
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
                              :message "no targets for group"}))
        (let [naabu-cmd (into [naabu
                               "-list" list-file]
                              (concat (naabu-port-args mode)
                                      ["-scan-type" "syn"
                                       "-interface" "eth0"
                                       "-rate" (str (:rate mode))
                                       "-c" (str (:concurrency mode))
                                       "-timeout" (str (:timeout mode))
                                       "-retries" (str (:retries mode))
                                       "-json"
                                       "-silent"
                                       "-nc"]))
              ;; Stream to file — full-port scans are too large to buffer in memory.
              _ (spit result-file "")
              proc @(proc/process naabu-cmd {:out (io/file result-file)
                                             :err (io/file log-file)
                                             :in nil})
              finished-at (now-ch)
              out-text (slurp result-file)]
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
                    :profile profile
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
            (let [open-rows (parse-naabu-lines out-text)
                  open-count (count open-rows)]
              (write-discover-results! cfg run-id target-group hosts open-rows
                                       :provenance provenance)
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
                    :profile profile
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
                                                " " provenance " hosts (" port-label
                                                " @ " (:rate mode) "pps)")})))))))
)
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

(defn require-artifact-name! [cfg name]
  (when-not (re-matches #"[A-Za-z0-9][A-Za-z0-9._-]{0,127}" (str name))
    (die! "invalid service-artifact name"))
  (let [allowed (set (or (:approved_validate_artifacts cfg)
                         ["fingerprint.jsonl" "services-all.jsonl"
                          "services-changed.jsonl" "inventory-https.txt"
                          "validate-targets.txt"]))]
    (when-not (contains? allowed (str name))
      (die! (str "unapproved service-artifact name: " name)))))

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

(defn ch-query-or-throw!
  "Like ch-query! but throws ex-info on failure so callers can mark stage failed."
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
        (throw (ex-info (str "clickhouse query failed status=" (:status resp)
                             " body=" (str/trim (str (:body resp))))
                        {:status (:status resp) :body (:body resp)})))
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
        all-path (str out-dir "/services-all.jsonl")
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
    (spit all-path
          (str (str/join "\n" (map json/generate-string listeners))
               (when (seq listeners) "\n")))
    (spit changed-path
          (str (str/join "\n" (map json/generate-string changed))
               (when (seq changed) "\n")))
    (spit unchanged-path
          (str (str/join "\n" (map json/generate-string unchanged))
               (when (seq unchanged) "\n")))
    (write-stage-artifact!
     cfg {:run-id run-id :stage "merge-diff" :artifact-ref all-path
          :status "succeeded" :started-at started-at :finished-at (now-ch)})
    (write-status! cfg {:run-id run-id
                        :stage "merge-diff"
                        :status "succeeded"
                        :message (str (count changed) " new/changed of "
                                      (count listeners) " listeners"
                                      "; wrote services-all.jsonl + services-changed.jsonl"
                                      (if (seq changed)
                                        "; delta fingerprint available"
                                        "; full fingerprint still available via services-all"))})))

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

(defn parse-port
  [p]
  (cond
    (number? p) (int p)
    (string? p) (try (Integer/parseInt p) (catch Exception _ 0))
    :else 0))

(defn normalize-finding-host
  "Strip optional :port suffix from Nuclei host fields."
  [host]
  (let [h (str host)]
    (or (some-> (re-matches #"^([^:]+):\d+$" h) second)
        h)))

(defn accepted-finding-reason
  "Return suppression reason if (template,host,port,matcher) is declared accepted."
  [cfg template host port matcher]
  (let [host* (normalize-finding-host host)
        port* (long (or port 0))
        matcher* (str (or matcher ""))]
    (some (fn [rule]
            (let [r-template (str (:template_id rule))
                  r-host (normalize-finding-host (or (:host rule) ""))
                  r-port (long (or (:port rule) 0))
                  r-matcher (str (or (:matcher rule) ""))]
              (when (and (= r-template (str template))
                         (or (str/blank? r-host) (= r-host host*))
                         (or (zero? r-port) (= r-port port*))
                         (or (str/blank? r-matcher) (= r-matcher matcher*)))
                (or (:reason rule) "accepted"))))
          (or (:accepted_findings cfg) []))))

(defn write-findings!
  [cfg run-id nuclei-rows]
  (let [ts (now-ch)
        ver (version-now)
        {:keys [scanner_revision nuclei_templates_revision]} cfg
        findings
        (mapv (fn [row]
                (let [host-raw (finding-host-from-row row)
                      host (normalize-finding-host host-raw)
                      port (parse-port (:port row))
                      template (or (:template-id row) (:templateID row) (:template row) "unknown")
                      matcher (or (:matcher-name row) (:matcher_name row) "")
                      sev (normalize-severity (or (:severity row) (get-in row [:info :severity])))
                      sid (if (and host (pos? port))
                            (service-id-for host "tcp" port)
                            (sha256-hex (str "finding|" template "|" host)))
                      aid (if host (asset-id-for host) (sha256-hex "unknown-asset"))
                      reason (accepted-finding-reason cfg template host port matcher)
                      suppressed? (boolean reason)]
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
                   :state (if suppressed? "suppressed" "open")
                   :resolved_at (when suppressed? ts)
                   :scanner_revision scanner_revision
                   :nuclei_templates_revision nuclei_templates_revision
                   :exposure "internal"
                   :owner ""
                   :suppression_reason (or reason "")
                   :review_status ""
                   :version ver}))
              nuclei-rows)]
    (when (seq findings)
      (ch-insert! cfg "estate_scan.findings" findings))
    findings))

(defn resolve-absent-findings!
  "After a successful validate, resolve open findings for templates that were
  in scope this run but whose finding_key was not observed. Does not touch
  findings from templates outside the allowlist/catalog used today."
  [cfg run-id seen-keys in-scope-template-ids]
  (when (and (clickhouse-enabled? cfg) (set? seen-keys) (seq in-scope-template-ids))
    (let [scope (set (map str in-scope-template-ids))
          open-rows (ch-query-or-throw!
                     cfg
                     (str "SELECT finding_key, toString(run_id) AS run_id, asset_id, service_id, "
                          "template_id, matcher, toString(severity) AS severity, evidence, "
                          "first_seen_at, last_seen_at, scanner_revision, "
                          "nuclei_templates_revision, exposure, owner, "
                          "suppression_reason, review_status, version "
                          "FROM estate_scan.findings FINAL WHERE state = 'open'"))
          missing (filterv (fn [r]
                             (and (contains? scope (str (:template_id r)))
                                  (not (contains? seen-keys (str (:finding_key r))))))
                           open-rows)
          ts (now-ch)
          reason (str "resolved: absent from successful run " run-id)]
      (when (seq missing)
        (ch-insert!
         cfg "estate_scan.findings"
         (mapv (fn [r]
                 {:finding_key (str (:finding_key r))
                  :run_id (:run_id r)
                  :asset_id (:asset_id r)
                  :service_id (:service_id r)
                  :template_id (str (:template_id r))
                  :matcher (str (:matcher r))
                  :severity (normalize-severity (:severity r))
                  :evidence (str (:evidence r))
                  :first_seen_at (:first_seen_at r)
                  :last_seen_at ts
                  :state "resolved"
                  :resolved_at ts
                  :scanner_revision (str (:scanner_revision r))
                  :nuclei_templates_revision (str (:nuclei_templates_revision r))
                  :exposure (str (or (:exposure r) "internal"))
                  :owner (str (or (:owner r) ""))
                  :suppression_reason reason
                  :review_status (str (or (:review_status r) ""))
                  :version (inc (long (or (:version r) 0)))})
               missing)))
      (count missing))))

(defn nuclei-template-ids-under
  "Parse `id:` from nuclei YAML templates under dir (best-effort)."
  [dir]
  (if-not (and dir (fs/exists? dir))
    #{}
    (->> (file-seq (io/file (str dir)))
         (filter #(let [n (str %)]
                    (or (str/ends-with? n ".yaml") (str/ends-with? n ".yml"))))
         (keep (fn [f]
                 (try
                   (some->> (slurp f)
                            (re-find #"(?m)^id:\s*([A-Za-z0-9][A-Za-z0-9._-]*)")
                            second)
                   (catch Exception _ nil))))
         set)))

(defn coverage-ratio-from-evidence
  "Attempt completeness, not finding yield. Clean full scan => 1.0."
  [evidence]
  (cond
    (nil? evidence) 0.0
    (= "timeout" (:status evidence)) 0.0
    (= "failed" (:status evidence)) 0.0
    (#{"succeeded" "skipped_empty" "ingested"} (:status evidence)) 1.0
    :else 0.0))

(defn ingest-validate-results!
  "Re-ingest an existing validate-*.jsonl after a writer crash; does not re-run Nuclei."
  [cfg run-id profile]
  (let [{:keys [artifacts_dir scanner_revision nuclei_templates_revision]} cfg
        out-dir (str artifacts_dir "/" run-id)
        result-file (str out-dir "/validate-" profile ".jsonl")
        evidence-file (str out-dir "/validate-evidence.json")
        profile-label (run-profile cfg run-id)
        evidence (load-validate-evidence cfg run-id)
        rows (when (fs/exists? result-file) (parse-jsonl (slurp result-file)))
        url-count (long (or (:url_count evidence) (count rows) 0))]
    (when-not (seq rows)
      (die! 4 (str "no findings rows in " result-file)))
    (write-findings! cfg run-id rows)
    (write-scan-run!
     cfg {:run_id run-id
          :profile profile-label
          :vantage "estate-scanner"
          :scanner_revision scanner_revision
          :nuclei_templates_revision nuclei_templates_revision
          :status "running"
          :started_at (now-ch)
          :probe_count url-count
          :coverage_ratio 1.0})
    (write-status! cfg {:run-id run-id
                        :stage "validate"
                        :status "succeeded"
                        :message (str "ingested " (count rows) " findings from "
                                      result-file " (no nuclei re-run)")})
    (when-not (fs/exists? evidence-file)
      (spit evidence-file
            (str (json/generate-string
                  {:run_id run-id
                   :profile profile
                   :run_profile profile-label
                   :url_count url-count
                   :findings_count (count rows)
                   :status "ingested"
                   :scanner_revision scanner_revision
                   :nuclei_templates_revision nuclei_templates_revision}
                  {:pretty true})
                 "\n")))))

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
                scanner_revision fixture_url fixture_templates_dir
                validate_timeout_ms]} cfg
        out-dir (str artifacts_dir "/" run-id)
        artifact-path (str out-dir "/" artifact-name)
        list-file (str out-dir "/validate-nuclei-targets.txt")
        result-file (str out-dir "/validate-" profile ".jsonl")
        log-file (str out-dir "/validate-" profile ".log")
        evidence-file (str out-dir "/validate-evidence.json")
        templates-http (str templates_dir "/current/http")
        ;; Daily/weekly packs under /etc/estate-scanner/nuclei-{daily,weekly}.
        ;; Daily = curated files; weekly = catalog dirs + CVEs. Nuclei ≥3.6.2.
        daily-templates-dir (or (:nuclei_daily_templates_dir cfg)
                                "/etc/estate-scanner/nuclei-daily")
        weekly-templates-dir (or (:nuclei_weekly_templates_dir cfg)
                                 "/etc/estate-scanner/nuclei-weekly")
        nuclei-config "/etc/estate-scanner/nuclei-config.yaml"
        nuclei-profile (str "/etc/estate-scanner/nuclei-profiles/" profile ".yml")
                timeout-ms (long (or validate_timeout_ms 5400000))
        fixture (or fixture_url "http://127.0.0.1:18080/")
        fixture-dir (or fixture_templates_dir "/etc/estate-scanner/nuclei-fixtures")
        started-at (now-ch)
        started-ms (System/currentTimeMillis)
        profile-label (or (run-profile cfg run-id) profile)
        target-count (or (some-> (load-run-manifest cfg run-id) :targets count) 0)]
    (fs/create-dirs out-dir)
    (when-not (fs/exists? artifact-path)
      (write-status! cfg {:run-id run-id :stage "validate" :status "failed"
                          :message (str "missing artifact " artifact-name)})
      (System/exit 4))
    (when-not (fs/exists? templates-http)
      (write-status! cfg {:run-id run-id :stage "validate" :status "failed"
                          :message "missing pinned nuclei http templates"})
      (System/exit 4))
    (when-not (fs/exists? nuclei-profile)
      (write-status! cfg {:run-id run-id :stage "validate" :status "failed"
                          :message (str "missing nuclei profile " profile)})
      (System/exit 4))
    ;; Stale /tmp/nuclei* LevelDB dirs from killed runs make Nuclei walk /tmp
    ;; for minutes before loading templates.
    (doseq [p (fs/glob "/tmp" "nuclei*")]
      (try (fs/delete-tree p) (catch Exception _ nil)))
    ;; Fast canary before the long estate pass — proves findings ingest even if
    ;; the curated scan times out later.
    (when (and fixture (fs/exists? fixture-dir) (seq (fs/glob fixture-dir "*.yaml")))
      (let [fixture-list (str out-dir "/validate-fixture-targets.txt")
            fixture-out (str out-dir "/validate-fixture.jsonl")
            fixture-log (str out-dir "/validate-fixture.log")
            resolvers "/etc/estate-scanner/resolvers.txt"]
        (spit fixture-list (str fixture "\n"))
        (spit fixture-out "")
        (when nuclei
          (let [fproc (proc/process
                       (cond-> [nuclei "-l" fixture-list "-t" fixture-dir
                                "-severity" "medium,high,critical"
                                "-jsonl" "-nc" "-no-interactsh"
                                "-rate-limit" "10" "-c" "5" "-timeout" "5"]
                         (fs/exists? resolvers) (into ["-r" resolvers])
                         (fs/exists? nuclei-config) (into ["-config" nuclei-config]))
                       {:out (io/file fixture-out)
                        :err (io/file fixture-log)
                        ;; /dev/null — :in nil/:pipe leaves a reader blocked on PDCP/tty probes.
                        :in (io/file "/dev/null")
                        :extra-env {"TMPDIR" (str (or (:state_dir cfg)
                                                      "/var/lib/estate-scanner")
                                                  "/tmp")}})
                fdone (deref fproc 60000 :timeout)]
            (when (= fdone :timeout)
              (try (proc/destroy-tree fproc) (catch Exception _ nil)))
            (let [frows (parse-jsonl (slurp fixture-out))]
              (when (seq frows)
                (write-findings! cfg run-id frows)
                (write-status! cfg {:run-id run-id :stage "validate" :status "running"
                                    :message (str "fixture canary wrote " (count frows)
                                                  " finding(s); starting estate nuclei")})))))))
    (let [urls (->> (http-targets-from-artifact artifact-path)
                    (concat (load-inventory-https-urls cfg run-id))
                    distinct
                    (into [])
                    (#(if (and fixture (not (some #{fixture} %)))
                        (conj % fixture)
                        %)))
          ;; Persist the combined L7 target list for evidence / reruns.
          _ (spit (str out-dir "/validate-targets.txt")
                  (str (str/join "\n" urls) (when (seq urls) "\n")))
          existing-dirs (let [pack-dir (case profile
                                         "nuclei-daily" daily-templates-dir
                                         "nuclei-weekly" weekly-templates-dir
                                         nil)
                              resolved (canonicalize-path pack-dir)]
                          (if (and resolved
                                   (some #(str/ends-with? (str %) ".yaml")
                                         (file-seq (io/file resolved))))
                            [resolved]
                            []))
          fixture-dir-resolved (or (canonicalize-path fixture-dir) fixture-dir)
          fixture-ready? (and (fs/exists? fixture-dir-resolved)
                              (seq (fs/glob fixture-dir-resolved "*.yaml")))]
      (when (and (empty? existing-dirs) (not fixture-ready?))
        (write-status! cfg {:run-id run-id :stage "validate" :status "failed"
                            :message "no curated nuclei template dirs present"})
        (System/exit 4))
      (write-status! cfg {:run-id run-id :stage "validate" :status "running"
                          :message (str "nuclei " profile " on " (count urls) " URLs"
                                        (when fixture-ready? " incl fixture")
                                        (when (empty? existing-dirs) " (fixture-only)")
                                        (when (seq existing-dirs)
                                          (str " (" profile " allowlist)")))})
      (write-stage-artifact!
       cfg {:run-id run-id :stage "validate" :artifact-ref result-file
            :status "running" :started-at started-at})
      (if (empty? urls)
        (let [evidence {:run_id run-id
                        :profile profile
                        :run_profile profile-label
                        :url_count 0
                        :findings_count 0
                        :template_dirs existing-dirs
                        :fixture_url fixture
                        :fixture_included false
                        :duration_ms 0
                        :scanner_revision scanner_revision
                        :nuclei_templates_revision nuclei_templates_revision
                        :status "skipped_empty"}]
          (spit result-file "")
          (spit evidence-file (str (json/generate-string evidence {:pretty true}) "\n"))
          (write-stage-artifact!
           cfg {:run-id run-id :stage "validate" :artifact-ref result-file
                :status "succeeded" :started-at started-at :finished-at (now-ch)})
          (write-scan-run!
           cfg {:run_id run-id
                :profile profile-label
                :vantage "estate-scanner"
                :scanner_revision scanner_revision
                :nuclei_templates_revision nuclei_templates_revision
                :status "running"
                :started_at started-at
                :target_count target-count
                :probe_count 0})
          (write-status! cfg {:run-id run-id :stage "validate" :status "succeeded"
                              :message "no HTTP(S) targets in artifact; skipped nuclei"}))
        (do
          (spit list-file (str (str/join "\n" urls) "\n"))
          (when-not nuclei (die! 1 "nuclei path missing from runtime.json"))
          ;; L7 HTTP + reviewed profile. Wrapper HOME disables PDCP; -auth=false
          ;; and -r lab resolvers prevent CF-tunnel hangs for *.home.shdr.ch.
          ;; dns-shim answers Nuclei's hardcoded Google IPv6 resolvers.
          (let [resolvers "/etc/estate-scanner/resolvers.txt"
                nuclei-tmpdir (str (or (:state_dir cfg) "/var/lib/estate-scanner") "/tmp")
                _ (fs/create-dirs nuclei-tmpdir)
                template-args (concat (mapcat (fn [d] ["-t" d]) existing-dirs)
                                      (when fixture-ready? ["-t" fixture-dir-resolved]))
                cmd (cond-> (into [nuclei
                                   "-l" list-file]
                                  (concat template-args
                                          ["-tp" nuclei-profile
                                           "-rate-limit" "40"
                                           "-c" "5"
                                           "-timeout" "3"
                                           "-retries" "0"
                                           "-max-host-error" "15"
                                           "-jsonl"
                                           "-nc"
                                           "-silent"
                                           "-no-interactsh"]))
                      (fs/exists? resolvers) (into ["-r" resolvers])
                      (fs/exists? nuclei-config)
                      (into ["-config" nuclei-config]))
                _ (spit result-file "")
                proc (proc/process cmd {:out (io/file result-file)
                                        :err (io/file log-file)
                                        ;; /dev/null — :in nil/:pipe leaves a reader blocked on PDCP/tty probes.
                                        :in (io/file "/dev/null")
                                        :extra-env {"TMPDIR" nuclei-tmpdir}})
                finished (deref proc timeout-ms :timeout)
                timed-out? (= finished :timeout)
                _ (when timed-out?
                    (try (proc/destroy-tree proc) (catch Exception _ nil)))
                exit (if timed-out? 124 (or (:exit finished) 1))
                finished-at (now-ch)
                duration-ms (- (System/currentTimeMillis) started-ms)
                err-text (when (fs/exists? log-file) (slurp log-file))
                out-text (slurp result-file)
                no-templates? (or (str/includes? (str err-text) "no templates provided")
                                  (str/includes? (str err-text) "Could not run nuclei"))
                rows (parse-jsonl out-text)
                fixture-hits (count (filter (fn [row]
                                              (let [tid (str (or (:template-id row)
                                                                 (:templateID row)
                                                                 (:template row)
                                                                 ""))]
                                                (str/includes? tid "aether-estate-scan-fixture")))
                                            rows))
                ok? (and (not timed-out?) (zero? exit) (not no-templates?))
                evidence {:run_id run-id
                          :profile profile
                          :run_profile profile-label
                          :url_count (count urls)
                          :findings_count (count rows)
                          :fixture_url fixture
                          :fixture_included true
                          :fixture_hits fixture-hits
                          :template_dirs (cond-> existing-dirs
                                           fixture-ready? (conj fixture-dir))
                          :duration_ms duration-ms
                          :timed_out timed-out?
                          :nuclei_exit exit
                          :scanner_revision scanner_revision
                          :nuclei_templates_revision nuclei_templates_revision
                          :status (cond timed-out? "timeout"
                                        ok? "succeeded"
                                        :else "failed")}]
            (spit evidence-file (str (json/generate-string evidence {:pretty true}) "\n"))
            ;; Always persist whatever Nuclei emitted before exit/timeout.
            (let [written (write-findings! cfg run-id rows)
                  seen-keys (set (map :finding_key written))
                  in-scope (into #{}
                                 (mapcat nuclei-template-ids-under
                                         (cond-> existing-dirs
                                           fixture-ready? (conj fixture-dir))))]
              (when ok?
                ;; resolve-absent SELECTs findings; on CH error mark failed so
                ;; wait-stage does not hang on status=running until timeout.
                (try
                  (resolve-absent-findings! cfg run-id seen-keys in-scope)
                  (catch Exception e
                    (write-status! cfg {:run-id run-id :stage "validate" :status "failed"
                                        :message (str "resolve-absent failed: " (.getMessage e))})
                    (die! 6 (str "resolve-absent failed: " (.getMessage e)))))))
            (when-not ok?
              (write-stage-artifact!
               cfg {:run-id run-id :stage "validate" :artifact-ref result-file
                    :status "failed" :started-at started-at :finished-at finished-at
                    :error-code (cond timed-out? "nuclei_timeout"
                                      no-templates? "nuclei_no_templates"
                                      :else "nuclei_exit")
                    :error-message (str "nuclei exited " exit
                                        (when timed-out? "; timed out")
                                        (when no-templates? "; no templates loaded")
                                        "; partial findings=" (count rows))})
              (write-scan-run!
               cfg {:run_id run-id
                    :profile profile-label
                    :vantage "estate-scanner"
                    :scanner_revision scanner_revision
                    :nuclei_templates_revision nuclei_templates_revision
                    :status "failed"
                    :started_at started-at
                    :finished_at finished-at
                    :target_count target-count
                    :probe_count (count urls)
                    :error_count 1
                    :coverage_ratio (if timed-out? 0.0 0.0)
                    :error_code (if timed-out? "nuclei_timeout" "nuclei_exit")
                    :error_message (str "validate failed; see " log-file)})
              (write-status! cfg {:run-id run-id :stage "validate" :status "failed"
                                  :message (str "nuclei " profile " failed; see log")})
              (System/exit 5))
            (write-stage-artifact!
             cfg {:run-id run-id :stage "validate" :artifact-ref result-file
                  :status "succeeded" :started-at started-at :finished-at finished-at})
            ;; Stay running until finalize closes the lineage; probe_count = URLs.
            ;; coverage_ratio = attempt completeness (not finding yield).
            (write-scan-run!
             cfg {:run_id run-id
                  :profile profile-label
                  :vantage "estate-scanner"
                  :scanner_revision scanner_revision
                  :nuclei_templates_revision nuclei_templates_revision
                  :status "running"
                  :started_at started-at
                  :target_count target-count
                  :probe_count (count urls)
                  :coverage_ratio 1.0})
            (write-status! cfg {:run-id run-id :stage "validate" :status "succeeded"
                                :message (str "nuclei " profile ": " (count rows)
                                              " findings from " (count urls)
                                              " URLs (" duration-ms "ms)"
                                              (when (pos? fixture-hits)
                                                (str "; fixture hits=" fixture-hits)))})))))))

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
  (let [{:keys [scanner_revision nuclei_templates_revision]} cfg
        out-dir (str (:artifacts_dir cfg) "/" run-id)
        status-path (str (:runs_dir cfg) "/" run-id "/status.json")
        started-at (now-ch)
        prior (when (fs/exists? status-path)
                (try (json/parse-string (slurp status-path) true)
                     (catch Exception _ nil)))
        failed? (= "failed" (:status prior))
        profile (run-profile cfg run-id)
        evidence (load-validate-evidence cfg run-id)
        manifest (load-run-manifest cfg run-id)
        probe-count (long (or (:url_count evidence) (:probe_count evidence) 0))
        findings-count (long (or (:findings_count evidence) 0))
        target-count (long (or (some-> manifest :targets count) 0))
        coverage (coverage-ratio-from-evidence evidence)]
    (fs/create-dirs out-dir)
    (write-scan-run!
     cfg {:run_id run-id
          :profile profile
          :vantage "estate-scanner"
          :scanner_revision scanner_revision
          :nuclei_templates_revision nuclei_templates_revision
          :status (if failed? "failed" "succeeded")
          :started_at started-at
          :finished_at (now-ch)
          :target_count target-count
          :probe_count probe-count
          :coverage_ratio (if failed? 0.0 coverage)
          :error_code (if failed? (or (:status prior) "stage_failed") "")
          :error_message (if failed?
                           (or (:message prior) "prior stage failed")
                           "")})
    (write-stage-artifact!
     cfg {:run-id run-id :stage "finalize" :artifact-ref status-path
          :status (if failed? "failed" "succeeded")
          :started-at started-at :finished-at (now-ch)})
    (write-status! cfg {:run-id run-id
                        :stage "finalize"
                        :status (if failed? "failed" "succeeded")
                        :message (if failed?
                                   (str "finalize recorded failed run lineage profile=" profile)
                                   (str "finalize recorded succeeded run lineage profile="
                                        profile " urls=" probe-count
                                        " findings=" findings-count))})))

(defn abandon-run!
  "Mark a run cancelled in ClickHouse (orphan close)."
  [cfg run-id reason]
  (let [{:keys [scanner_revision nuclei_templates_revision]} cfg
        profile (run-profile cfg run-id)
        finished-at (now-ch)]
    (write-scan-run!
     cfg {:run_id run-id
          :profile profile
          :vantage "estate-scanner"
          :scanner_revision scanner_revision
          :nuclei_templates_revision nuclei_templates_revision
          :status "cancelled"
          :started_at finished-at
          :finished_at finished-at
          :error_code "abandoned"
          :error_message (or reason "abandoned")})
    (write-status! cfg {:run-id run-id
                        :stage "abandon"
                        :status "succeeded"
                        :message (str "cancelled orphan run: " (or reason "abandoned"))})))

(defn reap-stale-runs!
  "Close scan_runs stuck in accepted/running for >6h (caller must hold lock)."
  [cfg]
  (let [rows (ch-query!
              cfg
              (str "SELECT toString(run_id) AS run_id, status, profile "
                   "FROM estate_scan.scan_runs FINAL "
                   "WHERE status IN ('running', 'accepted') "
                   "AND started_at < now() - INTERVAL 6 HOUR"))
        n (count rows)]
    (doseq [{:keys [run_id]} rows]
      (abandon-run! cfg run_id "reaped-stale-gt-6h"))
    (println (json/generate-string {:stage "reap-stale"
                                    :status "succeeded"
                                    :reaped n
                                    :message (str "reaped " n " stale scan_runs")}))))

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

(defn wait-stage!
  "Block until status.json shows succeeded for stage (and optional group).
  Used by Kestra instead of LoopUntil — SSH non-zero exits drop exitCode outputs."
  [cfg run-id stage target-group timeout-seconds]
  (let [timeout-s (long (or timeout-seconds 1800))
        deadline (+ (System/currentTimeMillis) (* timeout-s 1000))
        status-file (str (:runs_dir cfg) "/" run-id "/status.json")]
    (loop []
      (let [now (System/currentTimeMillis)]
        (when (> now deadline)
          (println (json/generate-string
                    {:run_id run-id
                     :stage stage
                     :target_group (or target-group "")
                     :status "timeout"
                     :message (str "wait-stage timed out after " timeout-s "s")}))
          (System/exit 4))
        (if-not (fs/exists? status-file)
          (do (Thread/sleep 5000) (recur))
          (let [body (try (json/parse-string (slurp status-file) true)
                          (catch Exception _ nil))
                same-stage? (= stage (:stage body))
                same-group? (or (str/blank? (str target-group))
                                (= (str target-group) (str (:target_group body))))
                status (:status body)]
            (cond
              (and same-stage? same-group? (= "succeeded" status))
              (do (println (json/generate-string body))
                  (System/exit 0))

              (and same-stage? same-group? (= "failed" status))
              (do (println (json/generate-string body))
                  (System/exit 5))

              :else
              (do (Thread/sleep 5000) (recur)))))))))

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
            (require-artifact-name! cfg artifact-name)
            (with-lock! cfg #(fingerprint! cfg run-id artifact-name)))

          "validate"
          (let [[run-id artifact-name profile] rest]
            (when (or (nil? run-id) (nil? artifact-name) (nil? profile))
              (println usage-text)
              (System/exit 2))
            (require-run-id! run-id)
            (require-artifact-name! cfg artifact-name)
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
        (require-artifact-name! cfg artifact-name)
        (accept-fingerprint! cfg run-id artifact-name))

      "validate"
      (let [[_ run-id artifact profile] args]
        (when (or (nil? run-id) (nil? artifact) (nil? profile) (nth args 4 nil))
          (println usage-text)
          (System/exit 2))
        (require-run-id! run-id)
        (require-artifact-name! cfg artifact)
        (require-member! "profile" profile profiles)
        (accept-validate! cfg run-id artifact profile))

      "inventory-sync"
      (let [[_ run-id] args]
        (when (nth args 2 nil)
          (println usage-text)
          (System/exit 2))
        (when run-id
          (require-run-id! run-id))
        (with-lock! cfg #(inventory-sync! cfg run-id)))

      "finalize"
      (let [[_ run-id] args]
        (when (or (nil? run-id) (nth args 2 nil))
          (println usage-text)
          (System/exit 2))
        (require-run-id! run-id)
        (with-lock! cfg #(finalize! cfg run-id)))

      "ingest-validate"
      (let [[_ run-id profile] args]
        (when (or (nil? run-id) (nil? profile) (nth args 3 nil))
          (println usage-text)
          (System/exit 2))
        (require-run-id! run-id)
        (require-member! "profile" profile profiles)
        (with-lock! cfg #(ingest-validate-results! cfg run-id profile)))

      "abandon"
      (let [[_ run-id reason] args]
        (when (or (nil? run-id) (nth args 3 nil))
          (println usage-text)
          (System/exit 2))
        (require-run-id! run-id)
        ;; Kestra errors path must close CH even while a detached worker holds
        ;; the lock; do not wait for reap-stale. Leave the lock for the owner.
        (let [base (or reason "abandoned")
              final-reason (if (lock-held? cfg) (str base "-lock-held") base)]
          (when-not (re-matches reason-token-re final-reason)
            (die! "invalid abandon reason token"))
          (if (lock-held? cfg)
            (abandon-run! cfg run-id final-reason)
            (with-lock! cfg #(abandon-run! cfg run-id final-reason)))))

      "reap-stale"
      (let [[_] args]
        (when (nth args 1 nil)
          (println usage-text)
          (System/exit 2))
        (with-lock! cfg #(reap-stale-runs! cfg)))

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

      "wait-stage"
      (let [[_ run-id stage a3 a4] args]
        (when (or (nil? run-id) (nil? stage) (nth args 5 nil))
          (println usage-text)
          (System/exit 2))
        (require-run-id! run-id)
        (require-member! "stage" stage stages)
        (let [;; a3 may be target-group or timeout; a4 is timeout when group present
              group? (and a3 (contains? groups a3))
              target-group (when group? a3)
              timeout (cond
                        group? a4
                        a3 a3
                        :else "1800")]
          (when target-group
            (require-member! "target-group" target-group groups))
          (when-not (re-matches #"\d{1,5}" (str timeout))
            (die! "invalid wait-stage timeout seconds"))
          (let [t (Long/parseLong (str timeout))]
            (when (or (< t 30) (> t 28800))
              (die! "wait-stage timeout must be 30..28800"))
            (wait-stage! cfg run-id stage target-group t))))

      ("-h" "--help" "help")
      (println usage-text)

      (die! (str "rejecting unknown operation or shell fragment: " (first args))))))

(apply -main *command-line-args*)
