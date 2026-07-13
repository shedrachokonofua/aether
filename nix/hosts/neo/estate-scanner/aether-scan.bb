#!/usr/bin/env bb
;; Estate-scanner typed dispatcher (Kestra forced-command entrypoint).
;; Paths/allowlists come from /etc/estate-scanner/runtime.json (Nix-owned).

(ns aether-scan
  (:require [babashka.fs :as fs]
            [babashka.process :as proc]
            [cheshire.core :as json]
            [clojure.java.io :as io]
            [clojure.string :as str])
  (:import [java.time Instant]))

(def usage-text
  "aether-scan — typed estate-scanner dispatcher (Kestra forced-command entrypoint)

Usage:
  aether-scan targets snapshot <run-id> <profile>
  aether-scan discover <run-id> <target-group>
  aether-scan merge-diff <run-id>
  aether-scan fingerprint <run-id> <service-artifact>
  aether-scan validate <run-id> <service-artifact> <approved-profile>
  aether-scan finalize <run-id>
  aether-scan status <run-id> <stage> [target-group]

Rejects caller-supplied shell, rates, templates, targets, and output paths.")

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

(defn parse-args [args]
  (if (seq args)
    (vec args)
    (let [raw (System/getenv "SSH_ORIGINAL_COMMAND")]
      (if (str/blank? raw)
        []
        (vec (str/split (str/trim raw) #"\s+"))))))

(defn require-run-id! [run-id]
  (when-not (re-matches #"[0-9a-fA-F-]{8,64}" (str run-id))
    (die! "invalid run-id")))

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
    (write-status! cfg {:run-id run-id
                        :stage "targets"
                        :status "succeeded"
                        :message "declared target snapshot frozen"})))

(defn discover-group!
  [cfg run-id target-group]
  (let [{:keys [runs_dir artifacts_dir naabu]} cfg
        dir (str runs_dir "/" run-id)
        out-dir (str artifacts_dir "/" run-id)
        manifest (str dir "/targets.json")
        list-file (str out-dir "/discover-" target-group "-hosts.txt")
        result-file (str out-dir "/discover-" target-group ".jsonl")
        log-file (str out-dir "/discover-" target-group ".log")]
    (fs/create-dirs dir)
    (fs/create-dirs out-dir)
    (when-not (fs/exists? manifest)
      (write-status! cfg {:run-id run-id
                          :stage "discover"
                          :target-group target-group
                          :status "failed"
                          :message "missing targets snapshot; run targets snapshot first"})
      (System/exit 4))
    (write-status! cfg {:run-id run-id
                        :stage "discover"
                        :target-group target-group
                        :status "running"
                        :message "discovery started"})
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
                     {:out :string :err :string})]
          (spit result-file (:out proc))
          (spit log-file (:err proc))
          (when-not (zero? (:exit proc))
            (write-status! cfg {:run-id run-id
                                :stage "discover"
                                :target-group target-group
                                :status "failed"
                                :message (str "naabu exited non-zero; see discover-" target-group ".log")})
            (System/exit 5))
          (let [open-count (->> (str/split-lines (:out proc))
                                (remove str/blank?)
                                count)]
            (write-status! cfg {:run-id run-id
                                :stage "discover"
                                :target-group target-group
                                :status "succeeded"
                                :message (str "discovered " open-count
                                              " open listeners across " (count hosts)
                                              " declared hosts (top-100)")})))))))

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
        (when (or (nil? run-id) (nil? target-group))
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
