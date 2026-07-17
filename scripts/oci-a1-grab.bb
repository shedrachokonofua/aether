#!/usr/bin/env bb

;; Claim an OCI VM.Standard.A1.Flex (Always-Free ARM) in ca-toronto-1 by retrying
;; `oci compute instance launch` until host capacity frees up ("Out of host
;; capacity" is the normal free-tier response, not a fault). Once it lands the box
;; is yours at $0 and can be imported into the tofu/oci module with no diff.
;;
;; It mirrors `tofu/oci/main.tf`'s `oci_core_instance.a1` EXACTLY so the launched
;; instance imports cleanly:
;;   shape VM.Standard.A1.Flex, 4 OCPU / 24 GB, latest Ubuntu 24.04 ARM image,
;;   subnet aether-public-subnet, public IP, hostname oci-a1, display aether-oci-a1,
;;   ssh key derived from secrets/oci_a1_private_key.pem (== tls_private_key.a1).
;;
;; Auth: uses the `oci` CLI profile (default oci-aether) with --auth security_token
;; (the browser session profile the repo mints today). A session token expires in
;; ~1h, so for a long unattended loop create an API-KEY profile (permanent) and run
;; with `--auth api_key` (or OCI_CLI_AUTH=api_key) - OR just rely on the built-in
;; self-renewal: on auth errors the loop re-mints the UPST via `login.bb --oci-renew`
;; (silent Keycloak refresh; valid within the SSO window: idle 2h / max 12h).
;;
;; Usage:
;;   nix develop -c scripts/oci-a1-grab.bb [opts]
;;     --ocpus N        OCPU count            (default 4;  free max 4)
;;     --mem N          memory GB             (default 24; free max 24)
;;     --interval N     seconds between tries (default 60)
;;     --max-attempts N stop after N tries    (default 0 = forever)
;;     --profile P      oci CLI profile       (default $OCI_CLI_PROFILE or oci-aether)
;;     --auth A         oci auth mode         (default $OCI_CLI_AUTH or security_token)
;;     --dry-run        discover + print the exact launch cmd, do NOT launch
;;     --help           this text
;;
;; Not end-to-end tested against a live launch (no capacity + expired token at
;; authoring time); the launch/retry path is exercised only when you run it.

(ns scripts.oci-a1-grab
  (:require [babashka.process :as proc]
            [cheshire.core :as json]
            [clojure.java.io :as io]
            [clojure.string :as str])
  (:import [java.time LocalTime]
           [java.time.format DateTimeFormatter]))

(def red "\u001b[0;31m")
(def green "\u001b[0;32m")
(def yellow "\u001b[1;33m")
(def blue "\u001b[0;34m")
(def dim "\u001b[2m")
(def nc "\u001b[0m")

(def script-dir
  (-> (or *file* (System/getProperty "babashka.file") ".")
      io/file .getParentFile .getCanonicalPath))
(def repo-root
  (-> script-dir io/file .getParentFile .getCanonicalPath))

(def key-file (str repo-root "/secrets/oci_a1_private_key.pem"))
(def ocid-file (str repo-root "/secrets/oci_a1_instance_ocid.txt"))
(def import-addr "module.oci[0].oci_core_instance.a1")

;; --- config (matches tofu/oci/main.tf) --------------------------------------
(def compartment-name "aether")
(def subnet-name "aether-public-subnet")
(def image-os "Canonical Ubuntu")
(def image-os-ver "24.04")
(def shape "VM.Standard.A1.Flex")
(def display-name "aether-oci-a1")
(def hostname-label "oci-a1")

(defn ts [] (.format (LocalTime/now) (DateTimeFormatter/ofPattern "HH:mm:ss")))
(defn log [color glyph msg]
  (println (str dim (ts) nc " " color glyph nc " " msg)))
(defn info [m] (log blue "\u2139" m))
(defn ok [m] (log green "\u2713" m))
(defn warn [m] (log yellow "\u26a0" m))
(defn err [m] (log red "\u2717" m))
(defn die! [m] (err m) (System/exit 1))

;; --- shell/oci helpers ------------------------------------------------------
(def call-timeout-ms
  (* 1000 (or (some-> (System/getenv "OCI_CALL_TIMEOUT") parse-long) 90)))

(defn run
  "Run a process with a hard wall-clock timeout; return {:ok? :out :err :exit}.
   On timeout the process tree is destroyed so an unattended loop never wedges."
  ([cmd] (run cmd 90000))
  ([cmd timeout-ms]
   (let [p (try (proc/process cmd {:out :string :err :string})
                (catch Throwable t t))]
     (if (instance? Throwable p)
       {:exit 127 :out "" :err (or (ex-message p) (str p)) :ok? false}
       (let [fut (future @p)
             res (deref fut timeout-ms ::timeout)]
         (if (= res ::timeout)
           (do (try (proc/destroy-tree p) (catch Throwable _ nil))
               (future-cancel fut)
               {:exit 124 :out "" :err (str "call timed out after " (quot timeout-ms 1000) "s") :ok? false})
           (assoc res :ok? (zero? (long (:exit res))))))))))

(defn oci
  "Invoke the oci CLI (profile + auth mode, JSON out) with bounded HTTP + process
   timeouts. Returns {:ok? bool :json parsed-response :err str :exit int}; use
   `oci-data` to reach the inner `data` payload."
  [profile auth args & [timeout-ms]]
  (let [cmd (concat ["oci"] args
                    ["--profile" profile "--auth" auth "--output" "json"
                     "--connection-timeout" "15" "--read-timeout" "60"])
        res (run cmd (or timeout-ms call-timeout-ms))
        parsed (when (:ok? res)
                 (try (let [o (str/trim (or (:out res) ""))]
                        (when-not (str/blank? o) (json/parse-string o true)))
                      (catch Throwable _ nil)))]
    (assoc res :json parsed)))

(defn oci-data
  "Unwrap the OCI response envelope: `{\"data\": <payload>}` -> <payload>."
  [res]
  (get-in res [:json :data]))

(defn ssh-pubkey []
  (when-not (.exists (io/file key-file))
    (die! (str "Missing key file: " key-file
               "\n  (tofu generates it via tls_private_key.a1 + local_file; run the oci apply once, or restore it.)")))
  (let [res (run ["ssh-keygen" "-y" "-f" key-file])]
    (when-not (:ok? res)
      (die! (str "Could not derive public key from " key-file ": " (str/trim (:err res)))))
    (str/trim (:out res))))

;; --- ~/.oci/config tenancy lookup -------------------------------------------
(defn oci-config-path []
  (or (System/getenv "OCI_CLI_CONFIG_FILE")
      (str (System/getProperty "user.home") "/.oci/config")))

(defn tenancy-ocid [profile]
  (let [path (oci-config-path)]
    (when-not (.exists (io/file path))
      (die! (str "No OCI config at " path " (run `oci session authenticate` or `oci setup config`).")))
    (loop [lines (str/split-lines (slurp path))
           in? false]
      (if-let [line (first lines)]
        (let [l (str/trim line)]
          (cond
            (re-matches #"\[.*\]" l) (recur (rest lines) (= l (str "[" profile "]")))
            (and in? (str/starts-with? l "tenancy")) (-> l (str/split #"=" 2) second str/trim)
            :else (recur (rest lines) in?)))
        (die! (str "Profile [" profile "] has no tenancy in " path))))))

;; --- error classification ---------------------------------------------------
(defn capacity-error? [s] (boolean (re-find #"(?i)out of (host )?capacity" (str s))))
(defn auth-error? [s]
  (boolean (re-find #"(?i)not authenticated|authorization failed|session.*(expired|not)|401|please run 'oci session'" (str s))))
(defn quota-error? [s]
  (boolean (re-find #"(?i)limitexceeded|quota|limit for this|exceed.*limit|maximum number" (str s))))
(defn rate-limit-error? [s]
  (boolean (re-find #"(?i)toomanyrequests|too many requests|\b429\b|rate.?limit" (str s))))
(defn timeout-error? [s] (boolean (re-find #"(?i)timed out|timeout" (str s))))

(defn renew-upst!
  "Re-mint the federated UPST via `login.bb --oci-renew` (cached Keycloak refresh
   token; silent, no browser). Works within the Keycloak SSO window (idle 2h /
   max 12h); each renewal resets the idle clock. Returns true on success."
  []
  (info "Renewing OCI UPST via Keycloak federation (login.bb --oci-renew)...")
  (let [r (run ["bb" (str repo-root "/scripts/login.bb") "--oci-renew"] 90000)]
    (if (:ok? r)
      (do (ok "UPST renewed.") true)
      (do (warn (str "UPST renewal failed: "
                     (let [s (str/trim (str (:out r) " " (:err r)))] (subs s 0 (min 300 (count s))))))
          false))))

(defn oci-read
  "Read-op oci call resilient to transient throttling: retries on 429/timeout with
   30s backoff, and renews the UPST once on an auth error. Returns the last result."
  [profile auth args]
  (loop [tries 6, renewed? false]
    (let [res (oci profile auth args)]
      (cond
        (:ok? res) res
        (and (auth-error? (:err res)) (not renewed?)
             (= profile "oci-aether") (= auth "security_token"))
        (do (renew-upst!) (recur tries true))
        (and (or (rate-limit-error? (:err res)) (timeout-error? (:err res))) (> tries 1))
        (do (warn (str "Transient OCI error (throttle/timeout) — backoff 30s (" (dec tries) " left)."))
            (Thread/sleep 30000)
            (recur (dec tries) renewed?))
        :else res))))

;; --- discovery --------------------------------------------------------------
(defn discover [profile auth]
  (info (str "Profile " profile " (auth " auth ") — resolving tenancy/compartment/AD/subnet/image..."))
  (let [tenancy (tenancy-ocid profile)
        comps (oci-read profile auth ["iam" "compartment" "list" "--compartment-id" tenancy "--all"])
        _ (when-not (:ok? comps)
            (if (auth-error? (:err comps))
              (die! (str "Not authenticated and renewal failed. Start a fresh 12h Keycloak window:\n"
                         "  task login -- --oci"))
              (die! (str "Failed to list compartments: " (str/trim (:err comps))))))
        comp (->> (oci-data comps)
                  (filter #(= compartment-name (:name %)))
                  (remove #(= "DELETED" (:lifecycle-state %)))
                  first :id)
        _ (when-not comp (die! (str "Compartment '" compartment-name "' not found under tenancy.")))
        ads (oci-read profile auth ["iam" "availability-domain" "list" "--compartment-id" tenancy])
        ad (some-> (oci-data ads) first :name)
        _ (when-not ad (die! "No availability domain found."))
        subnets (oci-read profile auth ["network" "subnet" "list" "--compartment-id" comp "--all"])
        subnet (->> (oci-data subnets)
                    (filter #(= subnet-name (:display-name %)))
                    first :id)
        _ (when-not subnet (die! (str "Subnet '" subnet-name "' not found (run the oci apply so the VCN/subnet exist).")))
        imgs (oci-read profile auth ["compute" "image" "list" "--compartment-id" tenancy
                                     "--operating-system" image-os
                                     "--operating-system-version" image-os-ver
                                     "--shape" shape
                                     "--sort-by" "TIMECREATED" "--sort-order" "DESC" "--all"])
        image (some-> (oci-data imgs) first :id)
        _ (when-not image (die! (str "No " image-os " " image-os-ver " image for " shape ".")))]
    (ok (str "compartment " (subs comp 0 (min 24 (count comp))) "…  AD " ad))
    (ok (str "subnet " (subs subnet 0 (min 24 (count subnet))) "…  image " (subs image 0 (min 24 (count image))) "…"))
    {:tenancy tenancy :comp comp :ad ad :subnet subnet :image image}))

;; --- launch -----------------------------------------------------------------
(defn launch-args [{:keys [comp ad subnet image]} ocpus mem pubkey]
  ["compute" "instance" "launch"
   "--availability-domain" ad
   "--compartment-id" comp
   "--shape" shape
   "--shape-config" (json/generate-string {:ocpus ocpus :memoryInGBs mem})
   "--image-id" image
   "--subnet-id" subnet
   "--assign-public-ip" "true"
   "--hostname-label" hostname-label
   "--display-name" display-name
   "--metadata" (json/generate-string {:ssh_authorized_keys pubkey})])

(defn print-success! [data]
  (let [id (:id data)
        ip (:public-ip data)]
    (ok "LANDED — launch accepted (instance provisioning)")
    (println)
    (println (str green "  OCID:  " nc (or id "?")))
    (println (str green "  IP:    " nc (or ip "(query: oci compute instance list-vnics --instance-id <ocid>)")))
    (when id (spit ocid-file (str id "\n")))
    (println (str dim "  (OCID written to " ocid-file ")" nc))
    (println)
    (info "Import into tofu (run in your `task tofu` dev-shell env — needs the Bao token + backend):")
    (println (str "  tofu import '" import-addr "' " (or id "<OCID>")))
    (info "Then verify no diff:  task tofu:plan   (module is already 4/24 to match)")))

(defn find-instance
  "Live (non-terminated) aether-oci-a1 instance data if one exists, else nil.
   Idempotency guard: a launch call can time out AFTER the server accepted it, and a
   stale prior run may already hold one - never launch a duplicate over it."
  [profile auth comp]
  (let [res (oci-read profile auth ["compute" "instance" "list" "--compartment-id" comp
                               "--display-name" display-name "--all"])]
    (when (:ok? res)
      (->> (oci-data res)
           (remove #(#{"TERMINATED" "TERMINATING"} (:lifecycle-state %)))
           first))))

;; --- main -------------------------------------------------------------------
(defn parse-opts [args]
  (loop [a args, m {:ocpus 4 :mem 24 :interval 60 :max-attempts 0 :rate-backoff 300
                    :profile (or (System/getenv "OCI_CLI_PROFILE") "oci-aether")
                    :auth (or (System/getenv "OCI_CLI_AUTH") "security_token")
                    :dry-run false :help false}]
    (if-let [x (first a)]
      (case x
        "--help" (recur (rest a) (assoc m :help true))
        "--dry-run" (recur (rest a) (assoc m :dry-run true))
        "--ocpus" (recur (drop 2 a) (assoc m :ocpus (parse-long (second a))))
        "--mem" (recur (drop 2 a) (assoc m :mem (parse-long (second a))))
        "--interval" (recur (drop 2 a) (assoc m :interval (parse-long (second a))))
        "--max-attempts" (recur (drop 2 a) (assoc m :max-attempts (parse-long (second a))))
        "--rate-backoff" (recur (drop 2 a) (assoc m :rate-backoff (parse-long (second a))))
        "--profile" (recur (drop 2 a) (assoc m :profile (second a)))
        "--auth" (recur (drop 2 a) (assoc m :auth (second a)))
        (do (warn (str "unknown arg: " x)) (recur (rest a) m)))
      m)))

(def help-text
  (str "oci-a1-grab — retry-launch an Always-Free A1.Flex until capacity lands.\n\n"
       "  nix develop -c scripts/oci-a1-grab.bb [--ocpus N] [--mem N] [--interval S]\n"
       "                                        [--max-attempts N] [--profile P] [--auth A] [--dry-run]\n\n"
       "Defaults: 4 OCPU / 24 GB (free max), 60s between tries, forever,\n"
       "          profile oci-aether, auth security_token.\n"
       "For unattended runs create an API-key oci profile and pass --auth api_key\n"
       "(session tokens expire in ~1h).\n"
       "On success it prints the OCID + the `tofu import " import-addr "` command.\n"))

(defn -main [& args]
  (let [{:keys [ocpus mem interval max-attempts profile auth dry-run help rate-backoff]} (parse-opts args)]
    (when help (println help-text) (System/exit 0))
    (when-not (:ok? (run ["oci" "--version"]))
      (die! "`oci` CLI not found — run inside `nix develop`."))
    (let [pubkey (ssh-pubkey)
          ctx (discover profile auth)
          largs (launch-args ctx ocpus mem pubkey)]
      (info (str "Target: " shape "  " ocpus " OCPU / " mem " GB  (Always-Free)"))
      (when dry-run
        (warn "--dry-run: not launching. Exact command:")
        (println (str "  oci " (str/join " " largs) " --profile " profile " --auth " auth))
        (System/exit 0))
      (when-let [existing (find-instance profile auth (:comp ctx))]
        (ok "An aether-oci-a1 instance already exists — treating as landed (import it).")
        (print-success! existing)
        (System/exit 0))
      (loop [n 1]
        (info (str "Attempt " n (when (pos? max-attempts) (str "/" max-attempts)) " — launching..."))
        (let [res (oci profile auth largs 240000)]
          (cond
            (:ok? res)
            (do (print-success! (oci-data res)) (System/exit 0))

            (capacity-error? (:err res))
            (if (and (pos? max-attempts) (>= n max-attempts))
              (die! (str "Out of host capacity; hit max-attempts (" max-attempts ") without landing."))
              (do (warn (str "Out of host capacity — retry in " interval "s (Toronto A1 is oversubscribed; normal)."))
                  (Thread/sleep (* 1000 interval))
                  (recur (inc n))))

            (auth-error? (:err res))
            (if (and (= profile "oci-aether") (= auth "security_token") (renew-upst!))
              (do (ok "Retrying with fresh UPST.") (recur n))
              (die! (str "Auth failed and UPST renewal failed. Start a fresh 12h Keycloak window:\n"
                         "  task login -- --oci\n"
                         (str/trim (:err res)))))

            (rate-limit-error? (:err res))
            (do (warn (str "Rate-limited by OCI (429 TooManyRequests) — backing off " rate-backoff "s. "
                           "The launch endpoint throttles aggressively; this is transient."))
                (Thread/sleep (* 1000 rate-backoff))
                (recur n))

            (quota-error? (:err res))
            (die! (str "Quota/limit error — you may already hold an A1 or exceed the free 4 OCPU/24 GB.\n"
                       (str/trim (:err res))))

            (timeout-error? (:err res))
            (if-let [existing (find-instance profile auth (:comp ctx))]
              (do (ok "Launch call timed out, but the instance exists — landed.")
                  (print-success! existing) (System/exit 0))
              (do (warn (str "Launch call timed out (no instance created) — retry in " interval "s."))
                  (Thread/sleep (* 1000 interval))
                  (recur (inc n))))

            :else
            (die! (str "Launch failed (not a capacity error — not retrying):\n"
                       (str/trim (:err res))))))))))

(apply -main *command-line-args*)
