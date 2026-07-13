#!/usr/bin/env bb
(ns render-argos-baseline
  (:require [babashka.fs :as fs]
            [cheshire.core :as json]
            [clojure.edn :as edn]
            [clojure.string :as str]))

(defn fail! [message]
  (binding [*out* *err*] (println (str "baseline error: " message)))
  (System/exit 1))

(defn required-string [m key]
  (let [value (get m key)]
    (if (and (string? value) (not (str/blank? value)))
      value
      (fail! (str "missing non-empty " (name key))))))

(defn sort-flow [flow]
  (into (sorted-map) flow))

(let [[input output] *command-line-args*]
  (when (or (nil? input) (nil? output) (next (next *command-line-args*)))
    (fail! "usage: render-baseline.bb <baseline.edn> <baseline.json>"))
  (when-not (fs/regular-file? input)
    (fail! (str "input does not exist: " input)))
  (let [source (edn/read-string (slurp input))
        schema-version (:schema-version source)
        revision (required-string source :revision)
        generated-at (required-string source :generated-at)
        networks (:monitored-networks source)
        flows (:expected-flows source)]
    (when-not (= 1 schema-version)
      (fail! "schema-version must be 1"))
    (when-not (and (vector? networks) (seq networks) (every? string? networks))
      (fail! "monitored-networks must be a non-empty vector of strings"))
    (when-not (and (vector? flows) (every? map? flows))
      (fail! "expected-flows must be a vector of maps"))
    (let [document (array-map
                     "schemaVersion" schema-version
                     "revision" revision
                     "generatedAt" generated-at
                     "monitoredNetworks" (vec (sort networks))
                     "expectedFlows" (->> flows
                                          (map sort-flow)
                                          (sort-by #(get % :id))
                                          vec))]
      (fs/create-dirs (fs/parent output))
      ;; Cheshire preserves array-map insertion order; the trailing newline makes
      ;; output byte-stable for one checked-out Aether revision.
      (spit output (str (json/generate-string document {:pretty true}) "\n")))))
