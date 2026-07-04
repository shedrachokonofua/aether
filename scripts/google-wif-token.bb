#!/usr/bin/env bb

(ns scripts.google-wif-token
  (:require [babashka.process :as proc]
            [cheshire.core :as json]
            [clojure.string :as str]
            [clojure.java.io :as io])
  (:import [java.util Base64]
           [java.nio.charset StandardCharsets]))

(def cache-dir (delay (or (System/getenv "AETHER_CACHE_DIR")
                          (str (System/getProperty "user.home") "/.aether-toolbox"))))
(def keycloak-url (delay (or (System/getenv "KEYCLOAK_URL") "https://auth.shdr.ch")))
(def keycloak-realm (delay (or (System/getenv "KEYCLOAK_REALM") "aether")))
(def keycloak-client-id (delay (or (System/getenv "KEYCLOAK_CLIENT_ID") "toolbox")))

(def token-file (delay (str @cache-dir "/google/keycloak-id-token.jwt")))
(def refresh-file (delay (str @cache-dir "/google/keycloak-refresh-token")))
(def output-file (delay (str @cache-dir "/google/wif-token-cache.json")))

(defn jwt-payload [token]
  (try
    (let [payload (second (str/split token #"\."))
          padded (case (mod (count payload) 4)
                   0 payload
                   2 (str payload "==")
                   3 (str payload "=")
                   1 (str payload "==="))
          decoded (String. (.decode (Base64/getUrlDecoder) padded) StandardCharsets/UTF_8)]
      (json/parse-string decoded true))
    (catch Throwable _ nil)))

(defn jwt-exp [token]
  (when-let [claims (jwt-payload token)]
    (:exp claims)))

(defn emit-error [code message]
  (json/generate-string
   {:version 1
    :success false
    :code code
    :message message}))

(defn emit-success [id-token exp]
  (json/generate-string
   {:version 1
    :success true
    :token_type "urn:ietf:params:oauth:token-type:id_token"
    :id_token id-token
    :expiration_time (long exp)}))

(defn write-response! [response]
  (println response)
  (let [parent-dir (.getParentFile (io/file @output-file))]
    (when parent-dir
      (.mkdirs parent-dir))
    (spit @output-file response)
    (try
      (.. (java.nio.file.Files/getPosixFilePermissions
           (java.nio.file.Paths/get @output-file (make-array String 0)))
          (toString))
      (catch Throwable _
        (try
          (.setReadable @output-file true false)
          (.setWritable @output-file true false)
          (catch Throwable _ nil))))))

(defn exists? [path]
  (.exists (io/file path)))

(defn read-cached-id-token []
  (when (exists? @token-file)
    (try
      (let [token (str/trim (slurp @token-file))
            exp (jwt-exp token)
            now (quot (System/currentTimeMillis) 1000)]
        (if (and exp (> exp (+ now 60)))
          (emit-success token exp)
          nil))
      (catch Throwable _ nil))))

(defn refresh-id-token []
  (when (exists? @refresh-file)
    (try
      (let [refresh-token (str/trim (slurp @refresh-file))
            res (proc/process ["curl" "-sS" "-X" "POST"
                              (str @keycloak-url "/realms/" @keycloak-realm "/protocol/openid-connect/token")
                              "-H" "Content-Type: application/x-www-form-urlencoded"
                              "-d" "grant_type=refresh_token"
                              "-d" (str "client_id=" @keycloak-client-id)
                              "-d" (str "refresh_token=" refresh-token)]
                        {:out :string :err :string})
            res-body @res]
        (if (zero? (:exit res-body))
          (try
            (let [body (json/parse-string (:out res-body) true)
                  id-token (:id_token body)
                  exp (jwt-exp id-token)
                  new-refresh (:refresh_token body)]
              (when id-token
                (spit @token-file id-token)
                (when new-refresh
                  (spit @refresh-file new-refresh))
                (emit-success id-token exp)))
            (catch Throwable _ nil))
          nil))
      (catch Throwable _ nil))))

(defn main []
  (let [response (or (read-cached-id-token)
                     (refresh-id-token)
                     (emit-error "401" "Keycloak credentials expired. Run: task login"))]
    (write-response! response)
    (if (str/includes? response "\"success\":true")
      (System/exit 0)
      (System/exit 1))))

(main)
