#!/usr/bin/env bb

(ns scripts.gmail-oauth-reauth
  (:require [babashka.http-client :as http]
            [babashka.process :as proc]
            [cheshire.core :as json]
            [clojure.string :as str]
            [org.httpkit.server :as http-server])
  (:import [java.net URLDecoder URLEncoder]
           [java.security MessageDigest SecureRandom]
           [java.util Base64]))

;; Reauthorizes Mnemo's Gmail reader without putting a refresh token in shell
;; history, process arguments, terminal output, or a temporary plaintext file.
;; The only mutation is: sops set --value-stdin secrets/secrets.yml

(def repo-root
  (-> *file* java.io.File. .getParentFile .getParentFile .getCanonicalPath))

(def default-secrets-file (str repo-root "/secrets/secrets.yml"))
(def default-redirect-uri "http://127.0.0.1:8765")
(def authorization-endpoint "https://accounts.google.com/o/oauth2/v2/auth")
(def token-endpoint "https://oauth2.googleapis.com/token")
(def gmail-readonly-scope "https://www.googleapis.com/auth/gmail.readonly")
(def sops-refresh-token-index "[\"gmail\"][\"refresh_token\"]")

(defn fail [message]
  (throw (ex-info message {})))

(defn usage []
  (str "Usage: task gmail:reauth -- [options]\n\n"
       "Runs a local Gmail OAuth flow and writes only gmail.refresh_token with SOPS.\n\n"
       "Options:\n"
       "  --secrets-file PATH  SOPS file to update (default: " default-secrets-file ")\n"
       "  --redirect-uri URI   registered loopback callback (default: " default-redirect-uri ")\n"
       "  --timeout SECONDS    consent timeout (default: 300)\n"
       "  --no-open            print the authorization URL instead of opening it\n"
       "  --yes                continue when the encrypted secrets file is already dirty\n"))

(defn next-value [flag remaining]
  (or (first remaining) (fail (str flag " requires a value"))))

(defn positive-long! [value]
  (try
    (let [parsed (parse-long value)]
      (if (pos? parsed)
        parsed
        (fail "--timeout must be a positive integer")))
    (catch NumberFormatException _
      (fail "--timeout must be a positive integer"))))

(defn parse-args [args]
  (loop [remaining args
         opts {:secrets-file default-secrets-file
               :redirect-uri default-redirect-uri
               :timeout 300
               :no-open false
               :yes false}]
    (if (empty? remaining)
      opts
      (let [arg (first remaining)
            rest-args (rest remaining)]
        (case arg
          "--help" (do (println (usage)) (System/exit 0))
          "-h" (do (println (usage)) (System/exit 0))
          "--secrets-file" (recur (rest rest-args) (assoc opts :secrets-file (next-value arg rest-args)))
          "--redirect-uri" (recur (rest rest-args) (assoc opts :redirect-uri (next-value arg rest-args)))
          "--timeout" (recur (rest rest-args)
                              (assoc opts :timeout (positive-long! (next-value arg rest-args))))
          "--no-open" (recur rest-args (assoc opts :no-open true))
          "--yes" (recur rest-args (assoc opts :yes true))
          (fail (str "Unknown argument: " arg "\n\n" (usage))))))))

(defn command [args opts]
  @(proc/process args (merge {:out :string :err :string} opts)))

(defn decrypt-secrets! [secrets-file]
  (let [result (command ["sops" "--decrypt" "--output-type" "json" secrets-file] {:in nil})]
    (when-not (zero? (:exit result))
      (fail "SOPS could not decrypt the secrets file. Refresh Aether login/SOPS access and retry."))
    (try
      (json/parse-string (:out result) true)
      (catch Throwable _
        (fail "SOPS returned invalid JSON for the secrets file.")))))

(defn gmail-oauth-credentials! [secrets-file]
  (let [gmail (:gmail (decrypt-secrets! secrets-file))
        client-id (:client_id gmail)
        client-secret (:client_secret gmail)]
    (when-not (and (string? client-id) (seq client-id))
      (fail "Missing gmail.client_id in the decrypted SOPS file."))
    (when-not (and (string? client-secret) (seq client-secret))
      (fail "Missing gmail.client_secret in the decrypted SOPS file."))
    {:client-id client-id :client-secret client-secret}))

(defn url-decode [value]
  (URLDecoder/decode (or value "") "UTF-8"))

(defn url-encode [value]
  (URLEncoder/encode (str value) "UTF-8"))

(defn parse-query [query-string]
  (into {}
        (keep (fn [part]
                (let [[key value] (str/split part #"=" 2)]
                  (when (seq key)
                    [(url-decode key) (url-decode value)]))))
        (str/split (or query-string "") #"&")))

(defn query-string [params]
  (->> params
       (map (fn [[key value]] (str (url-encode key) "=" (url-encode value))))
       (str/join "&")))

(defn validate-redirect-uri! [redirect-uri]
  (let [match (re-matches #"http://127\.0\.0\.1:([1-9][0-9]{0,4})(/[^?#]*)?" redirect-uri)]
    (when-not match
      (fail "The callback must be an http://127.0.0.1:<port>/<path> loopback URI."))
    (let [port (parse-long (nth match 1))]
      (when-not (<= 1 port 65535)
        (fail "The callback URI must use a valid port."))
      {:port port :path (or (nth match 2) "/") :uri redirect-uri})))

(defn random-bytes [length]
  (let [bytes (byte-array length)]
    (.nextBytes (SecureRandom.) bytes)
    bytes))

(defn base64url [bytes]
  (-> (Base64/getUrlEncoder) .withoutPadding (.encodeToString bytes)))

(defn pkce-pair []
  (let [verifier (base64url (random-bytes 48))
        digest (.digest (MessageDigest/getInstance "SHA-256") (.getBytes verifier "UTF-8"))]
    {:verifier verifier :challenge (base64url digest)}))

(defn authorization-url [client-id redirect-uri state challenge]
  (str authorization-endpoint "?"
       (query-string {"client_id" client-id
                      "redirect_uri" redirect-uri
                      "response_type" "code"
                      "scope" gmail-readonly-scope
                      "access_type" "offline"
                      "prompt" "consent"
                      "state" state
                      "code_challenge" challenge
                      "code_challenge_method" "S256"})))

(defn html-response [status heading message]
  {:status status
   :headers {"content-type" "text/html; charset=utf-8"}
   :body (str "<!doctype html><html><body><h1>" heading "</h1><p>" message "</p></body></html>")})

(defn callback-handler [expected-path expected-state result]
  (fn [{:keys [uri query-string]}]
    (if (not= uri expected-path)
      (html-response 404 "Not found" "This listener only accepts the OAuth callback.")
      (let [params (parse-query query-string)
            returned-state (get params "state")
            oauth-error (get params "error")
            code (get params "code")]
        (cond
          (not= returned-state expected-state)
          (do (deliver result {:error "OAuth callback state did not match; authorization was not accepted."})
              (html-response 400 "Authorization rejected" "Return to the terminal and retry."))

          oauth-error
          (do (deliver result {:error (str "Google authorization failed: " oauth-error ".")})
              (html-response 400 "Authorization was not granted" "Return to the terminal and retry."))

          (not (seq code))
          (do (deliver result {:error "Google returned no authorization code."})
              (html-response 400 "Missing authorization code" "Return to the terminal and retry."))

          :else
          (do (deliver result {:code code})
              (html-response 200 "Gmail authorized" "You can close this tab and return to the terminal.")))))))

(defn browser-command [url]
  (case (System/getProperty "os.name")
    "Mac OS X" ["open" url]
    nil))

(defn open-browser! [url]
  (when-let [args (browser-command url)]
    (try
      (zero? (:exit (command args {:in nil})))
      (catch Throwable _ false))))

(defn wait-for-authorization! [{:keys [path port]} state timeout-seconds]
  (let [result (promise)
        stop-server (try
                      (http-server/run-server (callback-handler path state result)
                                              {:ip "127.0.0.1" :port port})
                      (catch Throwable _
                        (fail (str "Could not listen on 127.0.0.1:" port
                                   ". Choose a free registered callback port with --redirect-uri."))))]
    {:result result :stop-server stop-server}))

(defn exchange-code! [authorization-code client-id client-secret redirect-uri verifier]
  (let [response (try
                   (http/post token-endpoint
                              {:throw false
                               :timeout 30000
                               :form-params {"code" authorization-code
                                             "client_id" client-id
                                             "client_secret" client-secret
                                             "redirect_uri" redirect-uri
                                             "grant_type" "authorization_code"
                                             "code_verifier" verifier}})
                   (catch Throwable _
                     (fail "Could not reach Google's token endpoint; no SOPS changes were made.")))]
    (when-not (= 200 (:status response))
      (fail (str "Google rejected the token exchange (HTTP " (:status response)
                 "); no SOPS changes were made.")))
    (try
      (json/parse-string (:body response) true)
      (catch Throwable _
        (fail "Google returned an invalid token response; no SOPS changes were made.")))))

(defn durable-refresh-token! [token-response]
  ;; A value here is Google's explicit signal that this is a short-lived grant;
  ;; never replace Aether's production credential with another seven-day token.
  (when (contains? token-response :refresh_token_expires_in)
    (fail (str "Google issued a time-limited refresh token ("
               (:refresh_token_expires_in token-response)
               " seconds). Refusing to save it; confirm this OAuth client is In production.")))
  (let [refresh-token (:refresh_token token-response)
        granted-scope (:scope token-response)]
    (when-not (and (string? refresh-token) (seq refresh-token))
      (fail "Google did not return a refresh token. Confirm offline access and forced consent, then retry."))
    (when (and (string? granted-scope)
               (not (contains? (set (str/split granted-scope #"\s+")) gmail-readonly-scope)))
      (fail "Google did not grant gmail.readonly; refusing to save the token."))
    refresh-token))

(defn secrets-file-dirty? [secrets-file]
  (let [relative-path (str/replace secrets-file (str repo-root "/") "")
        result (command ["git" "diff" "--quiet" "--" relative-path] {:in nil})]
    (= 1 (:exit result))))

(defn confirm-dirty-secrets! [secrets-file assume-yes]
  (when (and (secrets-file-dirty? secrets-file) (not assume-yes))
    (print "The encrypted secrets file has local changes. Preserve and continue? [y/N] ")
    (flush)
    (when-not (contains? #{"y" "yes"} (some-> (read-line) str/trim str/lower-case))
      (fail "Cancelled before opening Google OAuth; no SOPS changes were made."))))

(defn save-refresh-token! [secrets-file refresh-token]
  ;; --value-stdin is deliberate: refresh tokens must not appear in ps output.
  (let [result (command ["sops" "set" "--value-stdin" secrets-file sops-refresh-token-index]
                        {:in (json/generate-string refresh-token)})]
    (when-not (zero? (:exit result))
      (fail "SOPS could not update gmail.refresh_token; no token value was printed.")))
  (when-not (= refresh-token (get-in (decrypt-secrets! secrets-file) [:gmail :refresh_token]))
    (fail "SOPS update verification failed; inspect the encrypted file before applying it.")))

(defn reauthorize! [{:keys [secrets-file redirect-uri timeout no-open yes]}]
  (when-not (.isFile (java.io.File. secrets-file))
    (fail (str "Secrets file does not exist: " secrets-file)))
  (when-not (pos? timeout)
    (fail "--timeout must be greater than zero."))

  (let [{:keys [path port uri]} (validate-redirect-uri! redirect-uri)
        _ (confirm-dirty-secrets! secrets-file yes)
        {:keys [client-id client-secret]} (gmail-oauth-credentials! secrets-file)
        {:keys [verifier challenge]} (pkce-pair)
        state (base64url (random-bytes 32))
        url (authorization-url client-id uri state challenge)
        {:keys [result stop-server]} (wait-for-authorization! {:path path :port port} state timeout)]
    (try
      (println "Opening Google OAuth consent for the configured Mnemo Gmail client.")
      (println "Using local loopback callback:" uri)
      (println "Desktop OAuth clients need no redirect-URI setup; Web clients must register this exact URI.")
      (when (or no-open (not (open-browser! url)))
        (println "Open this authorization URL in a browser on this machine:")
        (println url))
      (let [callback (deref result (* 1000 timeout) {:error "Timed out waiting for Google consent; no SOPS changes were made."})]
        (when-let [error (:error callback)]
          (fail error))
        (let [token-response (exchange-code! (:code callback) client-id client-secret uri verifier)
              refresh-token (durable-refresh-token! token-response)]
          (save-refresh-token! secrets-file refresh-token)
          (println "Saved a durable Gmail refresh token to encrypted SOPS key gmail.refresh_token.")
          (println "No token value was printed. Apply the targeted mnemo-env secret, then restart Mnemo.")))
      (finally
        (stop-server)))))

(defn -main [& args]
  (try
    (reauthorize! (parse-args args))
    (catch clojure.lang.ExceptionInfo error
      (binding [*out* *err*]
        (println "Error:" (ex-message error)))
      (System/exit 1))
    (catch Throwable _
      (binding [*out* *err*]
        (println "Error: Gmail OAuth reauthorization failed; no token value was printed."))
      (System/exit 1))))

(apply -main *command-line-args*)
