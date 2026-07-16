#!/usr/bin/env bb

(ns scripts.login
  (:require [babashka.process :as proc]
            [cheshire.core :as json]
            [clojure.java.io :as io]
            [clojure.pprint :as pprint]
            [clojure.string :as str])
  (:import [java.net URI URLEncoder]
           [java.net.http HttpClient HttpClient$Redirect
            HttpRequest HttpRequest$BodyPublishers HttpResponse$BodyHandlers]
           [java.nio.charset StandardCharsets]
           [java.nio.file Files Paths]
           [java.nio.file.attribute PosixFilePermissions]
           [java.time Duration]))

(def red "\u001b[0;31m")
(def green "\u001b[0;32m")
(def yellow "\u001b[1;33m")
(def blue "\u001b[0;34m")
(def nc "\u001b[0m")

(def keycloak-url "https://auth.shdr.ch")
(def keycloak-realm "aether")
(def keycloak-client-id "toolbox")
(def openbao-url "https://bao.home.shdr.ch")
(def step-ca-url "https://ca.shdr.ch")
(def ceph-rgw-url "https://s3.home.shdr.ch")
(def ceph-rgw-role "arn:aws:iam:::role/admin")
(def aws-region-default "us-east-1")
(def aws-session-duration 43200)

(def script-dir
  (-> (or *file* (System/getProperty "babashka.file") ".")
      io/file
      .getParentFile
      .getCanonicalPath))

(def repo-root
  (-> script-dir io/file .getParentFile .getCanonicalPath))

(def cache-dir (delay (or (System/getenv "AETHER_CACHE_DIR")
                          (str (System/getProperty "user.home") "/.aether-toolbox"))))
(def aws-role-env (delay (System/getenv "AETHER_AWS_ROLE")))
(def aws-region (delay (or (System/getenv "AETHER_AWS_REGION") aws-region-default)))
(def google-audience-env (delay (System/getenv "AETHER_GOOGLE_WIF_AUDIENCE")))
(def google-service-account-env (delay (System/getenv "AETHER_GOOGLE_SERVICE_ACCOUNT")))
(def google-project-env (delay (System/getenv "AETHER_GOOGLE_PROJECT")))
(def ssh-auth-sock-env (delay (System/getenv "SSH_AUTH_SOCK")))
(def aether-ssh-auth-sock-env (delay (or (System/getenv "AETHER_SSH_AUTH_SOCK")
                                         (str @cache-dir "/ssh/agent.sock"))))
(def aether-ssh-agent-dir (delay (or (System/getenv "AETHER_SSH_AGENT_DIR")
                                     (str @cache-dir "/ssh"))))
(def debug? (= "1" (System/getenv "AETHER_DEBUG")))

(def http-client
  (-> (HttpClient/newBuilder)
      (.followRedirects HttpClient$Redirect/NORMAL)
      (.build)))

(defn ansi [color s]
  (str color s nc))

(defn now-seconds []
  (quot (System/currentTimeMillis) 1000))

(defn posix-file-perms [perm-string]
  (PosixFilePermissions/fromString perm-string))

(defn set-posix-perms! [path perm-string]
  (try
    (Files/setPosixFilePermissions (Paths/get (str path) (make-array String 0))
                                   (posix-file-perms perm-string))
    (catch Throwable _ nil)))

(defn ensure-dir! [path]
  (let [p (Paths/get (str path) (make-array String 0))]
    (Files/createDirectories p (make-array java.nio.file.attribute.FileAttribute 0))
    (set-posix-perms! path "rwx------")
    path))

(defn write-file! [path content]
  (let [f (io/file path)]
    (when-let [parent (.getParentFile f)]
      (ensure-dir! parent))
    (spit f content)
    (set-posix-perms! path "rw-------")
    path))

(defn exists? [path]
  (.exists (io/file path)))

(defn slurp-optional [path]
  (when (exists? path)
    (slurp path)))

(defn parse-json [s]
  (when (and s (not (str/blank? s)))
    (json/parse-string s true)))

(defn tf-outputs []
  (let [path (str repo-root "/secrets/tf-outputs.json")]
    (if-let [raw (slurp-optional path)]
      (try
        (parse-json raw)
        (catch Throwable _ {}))
      {})))

(defn tf-output [key]
  (get-in (tf-outputs) [key :value]))

(defn form-encode [pairs]
  (->> pairs
       (map (fn [[k v]]
              (str (URLEncoder/encode (str k) "UTF-8")
                   "="
                   (URLEncoder/encode (str v) "UTF-8"))))
       (str/join "&")))

(defn http-request! [{:keys [method url headers body timeout-ms]}]
  (let [builder (HttpRequest/newBuilder (URI/create url))]
    (when timeout-ms
      (.timeout builder (Duration/ofMillis (long timeout-ms))))
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
       :body (.body response)})))

(defn http-post-form! [url form-map]
  (http-request! {:method :post
                  :url url
                  :headers {"Content-Type" "application/x-www-form-urlencoded"}
                  :body (form-encode form-map)
                  :timeout-ms 30000}))

(defn http-post-json! [url payload]
  (http-request! {:method :post
                  :url url
                  :headers {"Content-Type" "application/json"}
                  :body (json/generate-string payload)
                  :timeout-ms 30000}))

(defn http-get! [url headers]
  (http-request! {:method :get
                  :url url
                  :headers headers
                  :timeout-ms 30000}))

(defn run-proc
  ([cmd] (run-proc cmd {}))
  ([cmd opts]
   (try
     (let [p (proc/process cmd (merge {:out :string :err :string} opts))
           res @p]
       (assoc res :ok? (zero? (long (:exit res)))))
     (catch Throwable t
       {:exit 127
        :out ""
        :err (or (ex-message t) (str t))
        :ok? false}))))

(defn cmd-output [res]
  (let [out (str/trim (or (:out res) ""))
        err (str/trim (or (:err res) ""))]
    (cond
      (not (str/blank? out)) out
      (not (str/blank? err)) err
      :else "")))

(defn jwt-payload-json [token]
  (try
    (let [payload (second (str/split token #"\."))
          padded (case (mod (count payload) 4)
                   0 payload
                   2 (str payload "==")
                   3 (str payload "=")
                   1 (str payload "==="))
          decoded (String. (.decode (java.util.Base64/getUrlDecoder) padded) StandardCharsets/UTF_8)]
      (json/parse-string decoded true))
    (catch Throwable _ nil)))

(defn log-buf []
  (atom []))

(defn push-log! [buf line]
  (swap! buf conj line))

(defn log-lines! [buf color glyph msg]
  (let [lines (str/split-lines (str msg))]
    (if (seq lines)
      (do
        (push-log! buf (str (ansi color glyph) " " (first lines)))
        (doseq [line (rest lines)]
          (push-log! buf (str "  " line))))
      (push-log! buf (str (ansi color glyph) " " msg)))))

(defn make-logger []
  (let [buf (log-buf)]
    {:buf buf
     :info (fn [msg] (log-lines! buf blue "ℹ" msg))
     :success (fn [msg] (log-lines! buf green "✓" msg))
     :warn (fn [msg] (log-lines! buf yellow "⚠" msg))
     :error (fn [msg] (log-lines! buf red "✗" msg))}))

(defn print-log-buffer! [buf]
  (doseq [line @buf]
    (println line)))

(defn load-env-file [path]
  (when-let [raw (slurp-optional path)]
    (reduce
     (fn [m line]
       (if (or (str/blank? line) (str/starts-with? line "#"))
         m
         (let [idx (.indexOf line "=")]
           (if (neg? idx)
             m
             (let [k (subs line 0 idx)
                   v (subs line (inc idx))]
               (assoc m k v))))))
     {}
     (str/split-lines raw))))

(defn write-env-file! [path env-map]
  (let [content (->> env-map
                     (map (fn [[k v]] (str k "=" v)))
                     (str/join "\n"))]
    (write-file! path (str content "\n"))))

(defn update-rclone-sections! [path section-texts]
  (let [remove-names (set (keys section-texts))
        existing (or (slurp-optional path) "")
        lines (str/split-lines existing)
        filtered (loop [xs lines
                        skip? false
                        acc []]
                   (if (empty? xs)
                     acc
                     (let [line (first xs)]
                       (if-let [[_ section] (re-matches #"\[([^\]]+)\]" line)]
                         (let [keep? (not (contains? remove-names section))]
                           (recur (rest xs) (not keep?) (if keep? (conj acc line) acc)))
                         (recur (rest xs) skip? (if skip? acc (conj acc line)))))))]
    (when-let [parent (.getParentFile (io/file path))]
      (ensure-dir! parent))
    (with-open [w (io/writer path)]
      (when (seq filtered)
        (.write w (str (str/join "\n" filtered) "\n")))
      (when (seq filtered)
        (.write w "\n"))
      (doseq [[section body] section-texts]
        (.write w (str "[" section "]\n" body "\n\n"))))
    (set-posix-perms! path "rw-------")))

(defn usable-agent-socket [candidate]
  (when (and candidate (not (str/blank? candidate)) (.exists (io/file candidate)))
    (let [res (run-proc ["ssh-add" "-l"] {:extra-env {"SSH_AUTH_SOCK" candidate}})]
      (when (#{0 1} (:exit res))
        candidate))))

(defn selected-agent-socket []
  (or (usable-agent-socket @ssh-auth-sock-env)
      (usable-agent-socket @aether-ssh-auth-sock-env)))

(defn ensure-ssh-agent! [log]
  (if-let [sock (selected-agent-socket)]
    sock
    (do
      (ensure-dir! @aether-ssh-agent-dir)
      (when (and (exists? @aether-ssh-auth-sock-env)
                 (not (usable-agent-socket @aether-ssh-auth-sock-env)))
        (try
          (Files/deleteIfExists (Paths/get @aether-ssh-auth-sock-env (make-array String 0)))
          (catch Throwable _ nil)))
      (let [res (run-proc ["ssh-agent" "-a" @aether-ssh-auth-sock-env "-s"])]
        (if (:ok? res)
          (let [sock (or @aether-ssh-auth-sock-env)]
            ((:info log) (str "Started SSH agent at " sock))
            sock)
          (do
            ((:error log) (str "Failed to start SSH agent: " (cmd-output res)))
            nil))))))

(defn device-auth-start! [log]
  ((:info log) "Starting device authorization...")
  (let [res (http-post-form! (str keycloak-url "/realms/" keycloak-realm "/protocol/openid-connect/auth/device")
                             {"client_id" keycloak-client-id
                              "scope" "openid profile email roles"})]
    (when (not= 200 (:status res))
      (throw (ex-info (str "Device auth request failed: " (:status res) " " (or (:body res) ""))
                      {:status (:status res)})))
    (let [body (parse-json (:body res))]
      (when-let [err (:error body)]
        (throw (ex-info (str "Device auth failed: " (or (:error_description body) err))
                        {:body body})))
      body)))

(defn device-auth-poll! [log device-code interval expires-in]
  (let [deadline (+ (now-seconds) (long expires-in))]
    (loop [interval (long interval)]
      (when (> (now-seconds) deadline)
        (throw (ex-info "Device authorization timed out" {})))
      (let [res (http-post-form! (str keycloak-url "/realms/" keycloak-realm "/protocol/openid-connect/token")
                                 {"client_id" keycloak-client-id
                                  "grant_type" "urn:ietf:params:oauth:grant-type:device_code"
                                  "device_code" device-code})
            body (or (parse-json (:body res)) {})]
        (if (contains? body :access_token)
          body
          (case (str (:error body))
            "authorization_pending"
            (do
              (Thread/sleep (* 1000 interval))
              (recur interval))
            "slow_down"
            (do
              (Thread/sleep (* 1000 (+ interval 5)))
              (recur (+ interval 5)))
            "expired_token"
            (throw (ex-info "Device code expired. Please try again." {}))
            "access_denied"
            (throw (ex-info "Access denied by user." {}))
            (throw (ex-info (str "Token exchange failed: "
                                 (or (:error_description body) (:error body) "unknown error"))
                            {:body body}))))))))

(defn persist-keycloak-refresh-token! [token-response log]
  (let [refresh-token (:refresh_token token-response)]
    (if (str/blank? refresh-token)
      ((:warn log) "Keycloak did not return a refresh token; Google WIF will expire with the ID token (~5m)")
      (let [google-dir (str @cache-dir "/google")]
        (ensure-dir! google-dir)
        (write-file! (str google-dir "/keycloak-refresh-token") refresh-token)))))

(defn decode-jwt-for-debug [token]
  (if-let [claims (jwt-payload-json token)]
    (with-out-str (pprint/pprint claims))
    "(decode failed)"))

(defn exchange-for-aws! [id-token log]
  (when debug?
    ((:info log) "ID Token claims:")
    (doseq [line (str/split-lines (decode-jwt-for-debug id-token))]
      ((:info log) line)))
  ((:info log) "Exchanging token for AWS credentials...")
  (let [role-arn (or @aws-role-env (tf-output :aws_admin_role_arn))]
    (if (str/blank? role-arn)
      (do
        ((:warn log) "Could not auto-detect AWS role ARN.")
        ((:warn log) "Set AETHER_AWS_ROLE environment variable or run 'task tofu:write-outputs' first.")
        {:ok? false
         :skipped? false
         :failed? true
         :name :aws
         :summary "AWS: Failed"})
      (let [res (run-proc ["aws" "sts" "assume-role-with-web-identity"
                           "--role-arn" role-arn
                           "--role-session-name" (str "aether-toolbox-" (now-seconds))
                           "--web-identity-token" id-token
                           "--duration-seconds" (str aws-session-duration)
                           "--region" @aws-region])]
        (if (not (:ok? res))
          (do
            ((:error log) (str "AWS token exchange failed: " (cmd-output res)))
            {:ok? false :failed? true :name :aws})
          (let [body (parse-json (cmd-output res))
                access-key (get-in body [:Credentials :AccessKeyId])
                secret-key (get-in body [:Credentials :SecretAccessKey])
                session-token (get-in body [:Credentials :SessionToken])
                expiration (get-in body [:Credentials :Expiration])
                aws-env-path (str @cache-dir "/aws-env")
                aws-creds-path (str (System/getProperty "user.home") "/.aws/credentials")]
            (write-env-file! aws-env-path {"AWS_ACCESS_KEY_ID" access-key
                                           "AWS_SECRET_ACCESS_KEY" secret-key
                                           "AWS_SESSION_TOKEN" session-token
                                           "AWS_REGION" @aws-region
                                           "AWS_DEFAULT_REGION" @aws-region})
            (try
              (ensure-dir! (str (System/getProperty "user.home") "/.aws"))
              (write-file! aws-creds-path (str "[default]\n"
                                               "aws_access_key_id = " access-key "\n"
                                               "aws_secret_access_key = " secret-key "\n"
                                               "aws_session_token = " session-token "\n"))
              (catch Throwable _ nil))
            ((:success log) (str "AWS credentials cached (expires: " expiration ")"))
            {:ok? true
             :failed? false
             :name :aws
             :access-key access-key
             :secret-key secret-key
             :session-token session-token
             :expiration expiration
             :role-arn role-arn}))))))

(defn exchange-for-google! [id-token required? log]
  (let [audience (or @google-audience-env (tf-output :google_workload_identity_provider_audience))
        service-account (or @google-service-account-env (tf-output :google_tofu_service_account_email))
        project-id (or @google-project-env (tf-output :google_project_id))
        token-script (str script-dir "/google-wif-token.bb")]
    (cond
      (or (str/blank? audience) (str/blank? service-account))
      (let [msg "Google WIF is not configured yet"]
        (if required?
          (do
            ((:error log) (str msg ". Set google.project_id, bootstrap/apply the google module, then run task tofu:write-outputs."))
            {:ok? false :failed? true :name :google :required? true})
          (do
            ((:info log) (str msg "; skipping Google credentials"))
            {:ok? true :skipped? true :name :google :configured? false})))
      (not (.canExecute (io/file token-script)))
      (do
        ((:error log) (str "Google WIF token script missing or not executable: " token-script))
        {:ok? false :failed? true :name :google})
      :else
      (let [google-dir (str @cache-dir "/google")]
        (ensure-dir! google-dir)
        ((:info log) "Writing GCP Workload Identity Federation credentials...")
        (let [token-file (str google-dir "/keycloak-id-token.jwt")
              credentials-file (str google-dir "/application-default-credentials.json")
              token-cache-file (str google-dir "/wif-token-cache.json")
              impersonation-url (str "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/" service-account ":generateAccessToken")
              token-script (str script-dir "/google-wif-token.bb")]
          (write-file! token-file id-token)
          (write-file! credentials-file (json/generate-string
                                         {:type "external_account"
                                          :audience audience
                                          :subject_token_type "urn:ietf:params:oauth:token-type:jwt"
                                          :token_url "https://sts.googleapis.com/v1/token"
                                          :service_account_impersonation_url impersonation-url
                                          :credential_source {:executable {:command token-script
                                                                            :timeout_millis 30000
                                                                            :output_file token-cache-file}}}))
          (write-env-file! (str @cache-dir "/google-env")
                           {"GOOGLE_APPLICATION_CREDENTIALS" credentials-file
                            "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE" credentials-file
                            "GOOGLE_CLOUD_PROJECT" (or project-id "")
                            "GOOGLE_PROJECT" (or project-id "")
                            "GOOGLE_EXTERNAL_ACCOUNT_ALLOW_EXECUTABLES" "1"})
          (let [res (run-proc ["gcloud" "auth" "application-default" "print-access-token"]
                              {:extra-env {"GOOGLE_EXTERNAL_ACCOUNT_ALLOW_EXECUTABLES" "1"
                                     "GOOGLE_APPLICATION_CREDENTIALS" credentials-file
                                     "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE" credentials-file}})]
            (if (:ok? res)
              (do
                ((:success log) (str "GCP WIF credentials configured (service account: " service-account ")"))
                {:ok? true :failed? false :name :google :configured? true})
              (do
                ((:error log) "Google WIF credential exchange failed after login")
                {:ok? false :failed? true :name :google :configured? true}))))))))

(defn exchange-for-s3! [id-token log]
  ((:info log) "Exchanging token for Ceph S3 credentials...")
  (let [res (run-proc ["aws" "--no-sign-request" "sts" "assume-role-with-web-identity"
                       "--endpoint-url" ceph-rgw-url
                       "--role-arn" ceph-rgw-role
                       "--role-session-name" (str "aether-toolbox-" (now-seconds))
                       "--web-identity-token" id-token])]
    (if (not (:ok? res))
      (do
        ((:error log) (str "Ceph S3 token exchange failed: " (cmd-output res)))
        {:ok? false :failed? true :name :s3})
      (let [body (parse-json (cmd-output res))
            access-key (get-in body [:Credentials :AccessKeyId])
            secret-key (get-in body [:Credentials :SecretAccessKey])
            session-token (get-in body [:Credentials :SessionToken])
            expiration (get-in body [:Credentials :Expiration])
            s3-env-path (str @cache-dir "/s3-env")
            rclone-config (str (System/getProperty "user.home") "/.config/rclone/rclone.conf")]
        (write-env-file! s3-env-path {"S3_ACCESS_KEY_ID" access-key
                                      "S3_SECRET_ACCESS_KEY" secret-key
                                      "S3_SESSION_TOKEN" session-token
                                      "S3_ENDPOINT" ceph-rgw-url})
        (update-rclone-sections! rclone-config
                                 {"ceph_rgw" (str "type = s3\n"
                                                  "provider = Ceph\n"
                                                  "endpoint = " ceph-rgw-url "\n"
                                                  "access_key_id = " access-key "\n"
                                                  "secret_access_key = " secret-key "\n"
                                                  "session_token = " session-token)})
        ((:success log) (str "Ceph S3 credentials cached (expires: " expiration ")"))
        ((:info log) "  Use: rclone lsd ceph_rgw:")
        {:ok? true
         :failed? false
         :name :s3
         :access-key access-key
         :secret-key secret-key
         :session-token session-token
         :expiration expiration}))))

(defn exchange-for-bao! [access-token log]
  ((:info log) "Exchanging token for OpenBao credentials...")
  (letfn [(login [role]
            (http-post-json! (str openbao-url "/v1/auth/jwt/login")
                             {:jwt access-token
                              :role role}))]
    (let [admin-res (login "cli-admin")
          admin-body (parse-json (:body admin-res))
          final-body (if (get-in admin-body [:auth :client_token])
                       admin-body
                       (parse-json (:body (login "cli"))))]
      (if (not (get-in final-body [:auth :client_token]))
        (let [error (or (get-in final-body [:errors 0]) "unknown error")]
          ((:error log) (str "OpenBao token exchange failed: " error))
          {:ok? false :failed? true :name :bao})
        (let [token (get-in final-body [:auth :client_token])
              lease-duration (get-in final-body [:auth :lease_duration])
              policies (str/join ", " (get-in final-body [:auth :policies]))
              path (str @cache-dir "/bao/token")]
          (write-file! path (str token "\n"))
          ((:success log) (str "OpenBao token cached (policies: " policies ", expires: ~" lease-duration "s)"))
          {:ok? true
           :failed? false
           :name :bao
           :token token
           :lease-duration lease-duration
           :policies policies})))))

(defn exchange-for-ssh-cert! [id-token log]
  (if-let [sock (or (selected-agent-socket) (ensure-ssh-agent! log))]
    (if-not (:ok? (run-proc ["step" "--version"]))
      (do
        ((:warn log) "step CLI not available, skipping SSH certificate")
        {:ok? false :failed? true :name :ssh})
      (do
        ((:info log) "Exchanging token for SSH certificate...")
        (let [defaults-path (str (or (System/getenv "STEPPATH") (str (System/getProperty "user.home") "/.step")) "/config/defaults.json")]
          (when (not (exists? defaults-path))
            (let [roots-res (run-proc ["curl" "-sk" (str step-ca-url "/roots.pem")])]
              (when-let [fingerprint (and (:ok? roots-res)
                                          (let [fp-res (run-proc ["step" "certificate" "fingerprint" "-"]
                                                                 {:in (:out roots-res)})]
                                            (when (:ok? fp-res)
                                              (str/trim (cmd-output fp-res)))))]
                (run-proc ["step" "ca" "bootstrap" (str "--ca-url=" step-ca-url) (str "--fingerprint=" fingerprint) "--force"]
                          {:extra-env {"SSH_AUTH_SOCK" sock}}))))
          (let [res (run-proc ["step" "ssh" "login"
                               "--provisioner=toolbox"
                               (str "--token=" id-token)
                               (str "--ca-url=" step-ca-url)]
                              {:extra-env {"SSH_AUTH_SOCK" sock}})]
            (if (:ok? res)
              (do
                ((:success log) "SSH certificate added to agent")
                {:ok? true :failed? false :name :ssh :socket sock})
              (do
                ((:error log) (str "SSH certificate exchange failed: " (cmd-output res)))
                {:ok? false :failed? true :name :ssh})))))) 
    (do
      ((:warn log) "SSH agent not available, skipping SSH certificate")
      {:ok? false :skipped? true :name :ssh})))

(defn help-text []
  (str/join
   "\n"
   ["Usage: login.bb [--aws|--google|--bao|--s3|--oci|--ssh|--no-ssh|--status]"
    ""
    "Options:"
    "  --aws     Only get AWS credentials"
    "  --google  Only configure GCP WIF credentials"
    "  --bao     Only get OpenBao token"
    "  --s3      Only get Ceph S3 credentials"
    "  --oci     Only get OCI credentials (UPST via Keycloak federation)"
    "  --ssh     Only get SSH certificate"
    "  --no-ssh  Skip SSH certificate (even if agent available)"
    "  --status  Check current auth status"
    ""
    "S3 Usage (after login):"
    "  rclone lsd ceph_rgw:        List Ceph RGW buckets"
    "  rclone lsd aws:         List AWS S3 buckets"
    "  rclone copy f.txt ceph_rgw:b/ Upload to Ceph"
    ""
    "Environment:"
    "  AETHER_CACHE_DIR   Token cache directory (default: ~/.aether-toolbox)"
    "  AETHER_AWS_ROLE    AWS role ARN to assume"
    "  AETHER_AWS_REGION  AWS region (default: us-east-1)"
    "  AETHER_GOOGLE_WIF_AUDIENCE       Google WIF audience"
    "  AETHER_GOOGLE_SERVICE_ACCOUNT    Google service account email"
    "  AETHER_GOOGLE_PROJECT            Google project ID"]))

(defn ssh-status! []
  (if-let [sock (selected-agent-socket)]
    (let [res (run-proc ["ssh-add" "-L"] {:extra-env {"SSH_AUTH_SOCK" sock}})
          cert-line (first (filter #(str/includes? % "cert-v01@openssh.com")
                                   (str/split-lines (cmd-output res))))]
      (if cert-line
        (if-let [inspect (and (exists? (str (System/getProperty "user.home") "/.step"))
                              (run-proc ["step" "ssh" "inspect"] {:in (str cert-line "\n")}))]
          (let [details (cmd-output inspect)
                valid-to (second (re-find #"Valid:.*to ([0-9TZ:-]+)" details))
                principals (second (re-find #"Principals:\s*(.*)" details))]
            (if valid-to
              [(ansi green "✓") (str "Certificate loaded (principals: " (or principals "unknown") ", expires: " valid-to ")")]
              [(ansi green "✓") "Certificate loaded"]))
          [(ansi green "✓") "Certificate loaded"])
        [(ansi yellow "⚠") "No certificate in agent (use 'task login -- --ssh')"]))
    [(ansi blue "ℹ") "Agent not available (run: task login -- --ssh)"]))

;; --- OCI (Keycloak JWT -> UPST token-exchange) -------------------------------
(defn expand-home [p]
  (if (and p (str/starts-with? p "~"))
    (str (System/getProperty "user.home") (subs p 1))
    p))

(defn oci-profile-field
  "Read a field (e.g. security_token_file, key_file) from the [profile] section of ~/.oci/config."
  [profile field]
  (let [path (str (System/getProperty "user.home") "/.oci/config")]
    (when (.exists (io/file path))
      (loop [lines (str/split-lines (slurp path)) in? false]
        (if-let [line (first lines)]
          (let [l (str/trim line)]
            (cond
              (re-matches #"\[.*\]" l) (recur (rest lines) (= l (str "[" profile "]")))
              (and in? (str/starts-with? l field)) (-> (str/split l #"=" 2) second str/trim expand-home)
              :else (recur (rest lines) in?)))
          nil)))))

(defn exchange-for-oci!
  "Exchange the Keycloak JWT for an OCI User Principal Session Token (UPST) via the
   Identity Domain's token endpoint, and install it into the oci-aether profile so
   `oci --auth security_token` (and tofu) work with no OCI browser."
  [id-token required? log]
  (let [domain        (tf-output :oci_domain_url)
        client-id     (tf-output :oci_tokenexchange_client_id)
        client-secret (tf-output :oci_tokenexchange_client_secret)]
    (cond
      (or (str/blank? domain) (str/blank? client-id) (str/blank? client-secret))
      (let [msg "OCI federation not configured (module.oci federation not applied / no tf-outputs)"]
        (if required?
          (do ((:error log) (str msg ".")) {:ok? false :failed? true :name :oci})
          (do ((:info log) (str msg "; skipping OCI")) {:ok? true :skipped? true :name :oci :configured? false})))

      :else
      (let [token-file (oci-profile-field "oci-aether" "security_token_file")
            key-file   (oci-profile-field "oci-aether" "key_file")]
        (if (or (str/blank? token-file) (str/blank? key-file))
          (do ((:error log) "OCI profile 'oci-aether' not bootstrapped - run once: oci session authenticate --region ca-toronto-1 --profile-name oci-aether")
              {:ok? false :failed? true :name :oci})
          (do
            ((:info log) "Exchanging Keycloak token for OCI UPST...")
            (let [new-key  (str key-file ".new")
                  pub-file (str key-file ".pub")
                  gen (run-proc ["openssl" "genrsa" "-out" new-key "2048"])
                  _   (when (:ok? gen) (run-proc ["chmod" "600" new-key]))
                  pub (when (:ok? gen) (run-proc ["openssl" "rsa" "-in" new-key "-pubout" "-out" pub-file]))]
              (if-not (and (:ok? gen) pub (:ok? pub))
                (do (io/delete-file new-key true)
                    ((:error log) (str "OCI RSA keygen failed: " (cmd-output (or pub gen))))
                    {:ok? false :failed? true :name :oci})
                (let [public-b64 (->> (str/split-lines (slurp pub-file))
                                      (remove #(str/includes? % "-----"))
                                      (map str/trim)
                                      (str/join ""))
                      basic (.encodeToString (java.util.Base64/getEncoder)
                                             (.getBytes (str client-id ":" client-secret) StandardCharsets/UTF_8))
                      resp (try
                             (http-request!
                              {:method :post
                               :url (str domain "/oauth2/v1/token")
                               :headers {"Content-Type" "application/x-www-form-urlencoded"
                                         "Authorization" (str "Basic " basic)}
                               :body (form-encode [["grant_type" "urn:ietf:params:oauth:grant-type:token-exchange"]
                                                   ["requested_token_type" "urn:oci:token-type:oci-upst"]
                                                   ["subject_token_type" "jwt"]
                                                   ["subject_token" id-token]
                                                   ["public_key" public-b64]])
                               :timeout-ms 30000})
                             (catch Throwable t {:status 0 :body (str t)}))
                      body (try (parse-json (:body resp)) (catch Throwable _ {}))
                      upst (or (:token body) (:access_token body))]
                  (if (and (= 200 (:status resp)) (not (str/blank? upst)))
                    (do
                      (run-proc ["mv" new-key key-file])
                      (run-proc ["chmod" "600" key-file])
                      (write-file! token-file upst)
                      (io/delete-file pub-file true)
                      (let [check (run-proc ["oci" "iam" "region" "list" "--profile" "oci-aether"
                                             "--auth" "security_token" "--output" "json"])]
                        (if (:ok? check)
                          (do ((:success log) "OCI UPST minted (profile oci-aether, --auth security_token)")
                              {:ok? true :failed? false :name :oci :configured? true})
                          (do ((:error log) (str "OCI UPST minted but a test call failed: " (cmd-output check)))
                              {:ok? false :failed? true :name :oci}))))
                    (do (io/delete-file new-key true)
                        (io/delete-file pub-file true)
                        ((:error log) (str "OCI token-exchange failed (HTTP " (:status resp) "): "
                                           (let [b (str (:body resp))] (subs b 0 (min 400 (count b))))))
                        {:ok? false :failed? true :name :oci})))))))))))

(defn oci-status! []
  (let [token-file (oci-profile-field "oci-aether" "security_token_file")]
    (if (and token-file (.exists (io/file token-file)))
      (let [res (run-proc ["oci" "iam" "region" "list" "--profile" "oci-aether"
                           "--auth" "security_token" "--output" "json"])]
        (if (:ok? res)
          [(ansi green "✓") "Authenticated (UPST via Keycloak federation, profile oci-aether)"]
          [(ansi yellow "⚠") "UPST expired or invalid (run: task login)"]))
      [(ansi yellow "⚠") "Not authenticated (no cached UPST)"])))

(defn status-check! []
  (println)
  (println (ansi blue "=== Aether Auth Status ==="))
  (println)

  (println (ansi blue "SSH:"))
  (let [[prefix msg] (ssh-status!)]
    (println prefix msg))

  (println)
  (println (ansi blue "OpenBao:"))
  (if-let [token-path (slurp-optional (str @cache-dir "/bao/token"))]
    (try
      (let [res (http-get! (str openbao-url "/v1/auth/token/lookup-self")
                           {"X-Vault-Token" (str/trim token-path)})
            body (parse-json (:body res))]
        (if-let [data (:data body)]
          (println (ansi green (str "✓ Authenticated as: " (:display_name data)
                                    " (TTL: " (:ttl data) "s, policies: "
                                    (str/join ", " (:policies data)) ")")))
          (println (ansi yellow "⚠ Token expired or invalid"))))
      (catch Throwable _
        (println (ansi yellow "⚠ Token expired or invalid"))))
    (println (ansi yellow "⚠ Not authenticated (no cached token)")))

  (println)
  (println (ansi blue "AWS:"))
  (if-let [env (load-env-file (str @cache-dir "/aws-env"))]
    (let [res (run-proc ["aws" "sts" "get-caller-identity" "--no-cli-pager"] {:extra-env env})]
      (if (:ok? res)
        (let [identity (parse-json (cmd-output res))]
          (println (ansi green (str "✓ Authenticated as: " (:Arn identity) " (account: " (:Account identity) ")"))))
        (println (ansi yellow "⚠ Credentials expired or invalid"))))
    (println (ansi yellow "⚠ Not authenticated (no cached credentials)")))

  (println)
  (println (ansi blue "GCP:"))
  (if-let [env (load-env-file (str @cache-dir "/google-env"))]
    (let [project (or (get env "GOOGLE_CLOUD_PROJECT") "unknown")
          res (run-proc ["gcloud" "auth" "application-default" "print-access-token"] {:extra-env env})]
      (if (:ok? res)
        (println (ansi green (str "✓ Authenticated via WIF (project: " project ")")))
        (println (ansi yellow "⚠ WIF credentials expired or invalid (run: task login)"))))
    (println (ansi yellow "⚠ Not authenticated (no cached WIF credentials)")))

  (println)
  (println (ansi blue "Ceph S3:"))
  (if-let [env (load-env-file (str @cache-dir "/s3-env"))]
    (let [res (run-proc ["rclone" "lsd" "ceph_rgw:"])]
      (if (:ok? res)
        (println (ansi green (str "✓ Authenticated (endpoint: " (get env "S3_ENDPOINT") ")")))
        (println (ansi yellow "⚠ Credentials cached but may be expired"))))
    (println (ansi yellow "⚠ Not authenticated (no cached credentials)")))

  (println)
  (println (ansi blue "OCI:"))
  (let [[prefix msg] (oci-status!)]
    (println prefix msg))

  (println))

(defn print-summary! [results do-flags]
  (let [{:keys [do-ssh do-bao do-aws do-google do-s3 do-oci]} do-flags]
    (println)
    (println (ansi blue "=== Login Summary ==="))
    (when-not (:ssh-skipped? results)
      (cond
        (:ssh-ok? results) (println (ansi green "✓ SSH: Certificate added to agent"))
        (:ssh-attempted? results) (println (ansi red "✗ SSH: Failed"))))
    (when do-bao
      (if (:bao-ok? results)
        (println (ansi green (str "✓ Bao: Ready (token in " @cache-dir "/bao/token)")))
        (println (ansi red "✗ Bao: Failed"))))
    (when do-aws
      (if (:aws-ok? results)
        (println (ansi green (str "✓ AWS: Ready (creds in " @cache-dir "/aws-env)")))
        (println (ansi red "✗ AWS: Failed"))))
    (when do-google
      (cond
        (:google-ok? results)
        (if (:google-configured? results)
          (println (ansi green (str "✓ GCP: Ready (WIF config in " @cache-dir "/google-env)")))
          (println (ansi blue "ℹ GCP: Not configured")))
        :else
        (println (ansi red "✗ GCP: Failed"))))
    (when do-s3
      (if (:s3-ok? results)
        (println (ansi green "✓ Ceph RGW:  Ready (rclone remotes: ceph_rgw, aws)"))
        (println (ansi red "✗ Ceph RGW:  Failed"))))
    (when do-oci
      (cond
        (:oci-ok? results)
        (if (:oci-configured? results)
          (println (ansi green "✓ OCI: Ready (UPST via Keycloak federation, profile oci-aether)"))
          (println (ansi blue "ℹ OCI: Not configured")))
        :else
        (println (ansi red "✗ OCI: Failed"))))
    (println)))

(defn parse-args [args]
  (loop [xs args
         state {:do-aws true
                :do-google true
                :google-required? false
                :do-bao true
                :do-s3 true
                :do-oci true
                :oci-required? false
                :do-ssh :auto
                :status? false
                :help? false}]
    (if (empty? xs)
      state
      (case (first xs)
        "--aws" (recur (rest xs)
                       (assoc state
                              :do-google false
                              :do-bao false
                              :do-s3 false
                              :do-oci false
                              :do-ssh false))
        "--google" (recur (rest xs)
                          (assoc state
                                 :do-aws false
                                 :do-google true
                                 :google-required? true
                                 :do-bao false
                                 :do-s3 false
                                 :do-oci false
                                 :do-ssh false))
        "--bao" (recur (rest xs)
                       (assoc state
                              :do-aws false
                              :do-google false
                              :do-s3 false
                              :do-oci false
                              :do-ssh false))
        "--s3" (recur (rest xs)
                      (assoc state
                             :do-aws false
                             :do-google false
                             :do-bao false
                             :do-oci false
                             :do-ssh false))
        "--oci" (recur (rest xs)
                       (assoc state
                              :do-aws false
                              :do-google false
                              :do-bao false
                              :do-s3 false
                              :do-oci true
                              :oci-required? true
                              :do-ssh false))
        "--ssh" (recur (rest xs)
                       (assoc state
                              :do-aws false
                              :do-google false
                              :do-bao false
                              :do-s3 false
                              :do-oci false
                              :do-ssh true))
        "--no-ssh" (recur (rest xs) (assoc state :do-ssh false))
        "--status" (assoc state :status? true)
        "--help" (assoc state :help? true)
        "-h" (assoc state :help? true)
        (throw (ex-info (str "Unknown option: " (first xs)) {:code 1}))))))

(defn apply-rclone-aws-remote! []
  (let [aws-env-path (str @cache-dir "/aws-env")
        rclone-config (str (System/getProperty "user.home") "/.config/rclone/rclone.conf")]
    (when-let [env (load-env-file aws-env-path)]
      (let [aws-body (str "type = s3\n"
                          "provider = AWS\n"
                          "region = " (get env "AWS_REGION" @aws-region) "\n"
                          "access_key_id = " (get env "AWS_ACCESS_KEY_ID") "\n"
                          "secret_access_key = " (get env "AWS_SECRET_ACCESS_KEY") "\n"
                          "session_token = " (get env "AWS_SESSION_TOKEN"))]
        (update-rclone-sections! rclone-config {"aws" aws-body})))))

(defn run-login! [state]
  (when (:help? state)
    (println (help-text))
    (System/exit 0))
  (when (:status? state)
    (status-check!)
    (System/exit 0))

  (ensure-dir! @cache-dir)
  (ensure-dir! (str @cache-dir "/bao"))
  (ensure-dir! @aether-ssh-agent-dir)

  (let [auth-logger (make-logger)
        device (device-auth-start! auth-logger)
        device-code (:device_code device)
        user-code (:user_code device)
        verification-uri (or (:verification_uri_complete device) (:verification_uri device))
        interval (long (or (:interval device) 5))
        expires-in (long (or (:expires_in device) 600))]
    (print-log-buffer! (:buf auth-logger))
    (reset! (:buf auth-logger) [])
    (println)
    (println (ansi yellow "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"))
    (println (ansi yellow "  Open this URL in your browser:"))
    (println)
    (println (str "  " (ansi green verification-uri)))
    (println)
    (println (str "  " (ansi yellow "Code: ") (ansi green user-code)))
    (println (ansi yellow "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"))
    (println)
    (try
      (let [open-res (run-proc ["xdg-open" verification-uri])]
        (when-not (:ok? open-res)
          (let [mac-open (run-proc ["open" verification-uri])]
            (when-not (:ok? mac-open)
              nil))))
      (catch Throwable _ nil))
    ((:info auth-logger) "Waiting for browser authentication...")
    (print-log-buffer! (:buf auth-logger))
    (reset! (:buf auth-logger) [])
    (let [token-response (device-auth-poll! auth-logger device-code interval expires-in)
          access-token (:access_token token-response)
          id-token (:id_token token-response)]
      (persist-keycloak-refresh-token! token-response auth-logger)
      (print-log-buffer! (:buf auth-logger))
      (println)
      (println (ansi green "✓ Authentication successful!"))
      (println)
      (let [do-ssh-mode (:do-ssh state)
            do-bao (:do-bao state)
            do-aws (:do-aws state)
            do-google (:do-google state)
            do-s3 (:do-s3 state)
            do-oci (:do-oci state)
            google-required? (:google-required? state)
            oci-required? (:oci-required? state)
            ssh-logger (make-logger)
            bao-logger (make-logger)
            aws-logger (make-logger)
            google-logger (make-logger)
            s3-logger (make-logger)
            oci-logger (make-logger)
            ssh-fut (future (when (or (= do-ssh-mode true) (= do-ssh-mode :auto))
                              (exchange-for-ssh-cert! id-token ssh-logger)))
            bao-fut (future (when do-bao
                              (exchange-for-bao! access-token bao-logger)))
            aws-fut (future (when do-aws
                              (exchange-for-aws! id-token aws-logger)))
            google-fut (future (when do-google
                                 (exchange-for-google! id-token google-required? google-logger)))
            s3-fut (future (when do-s3
                             (exchange-for-s3! id-token s3-logger)))
            oci-fut (future (when do-oci
                              (exchange-for-oci! id-token oci-required? oci-logger)))
            ssh-res (when (or (= do-ssh-mode true) (= do-ssh-mode :auto)) @ssh-fut)
            bao-res (when do-bao @bao-fut)
            aws-res (when do-aws @aws-fut)
            google-res (when do-google @google-fut)
            s3-res (when do-s3 @s3-fut)
            oci-res (when do-oci @oci-fut)]
        (doseq [logger [ssh-logger bao-logger aws-logger google-logger s3-logger oci-logger]]
          (print-log-buffer! (:buf logger)))
        (when (and do-s3 (:ok? s3-res) (exists? (str @cache-dir "/aws-env")))
          (apply-rclone-aws-remote!))
        (let [results {:ssh-ok? (boolean (:ok? ssh-res))
                       :ssh-attempted? (boolean (or (= do-ssh-mode true) (= do-ssh-mode :auto)))
                       :ssh-skipped? (boolean (= do-ssh-mode false))
                       :bao-ok? (boolean (:ok? bao-res))
                       :aws-ok? (boolean (:ok? aws-res))
                       :google-ok? (boolean (:ok? google-res))
                       :google-configured? (boolean (:configured? google-res))
                       :s3-ok? (boolean (:ok? s3-res))
                       :oci-ok? (boolean (:ok? oci-res))
                       :oci-configured? (boolean (:configured? oci-res))}
              do-flags {:do-ssh do-ssh-mode
                        :do-bao do-bao
                        :do-aws do-aws
                        :do-google do-google
                        :do-s3 do-s3
                        :do-oci do-oci}]
          (print-summary! results do-flags)
          (when (or (and do-bao (not (:ok? bao-res)))
                    (and do-aws (not (:ok? aws-res)))
                    (and do-google (not (:ok? google-res)))
                    (and do-s3 (not (:ok? s3-res)))
                    (and do-oci (not (:ok? oci-res)))
                    (and (= do-ssh-mode true) (not (:ok? ssh-res))))
            (System/exit 1)))))))

(defn -main [& args]
  (try
    (let [state (parse-args args)]
      (if (:help? state)
        (do
          (println (help-text))
          (System/exit 0))
        (run-login! state)))
    (catch clojure.lang.ExceptionInfo e
      (binding [*out* *err*]
        (println (ansi red (ex-message e))))
      (System/exit (or (get (ex-data e) :code) 1)))
    (catch Throwable t
      (binding [*out* *err*]
        (println (ansi red (or (ex-message t) (str t)))))
      (System/exit 1))))

(apply -main *command-line-args*)
