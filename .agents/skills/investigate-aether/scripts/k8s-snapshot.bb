#!/usr/bin/env bb

(ns investigate-aether.k8s-snapshot
  (:require [babashka.process :as proc]
            [clojure.string :as str])
  (:import [java.time Instant ZoneOffset]
           [java.time.format DateTimeFormatter]))

(def resources
  ["deployments" "statefulsets" "daemonsets" "pods" "jobs" "cronjobs"
   "pvc" "httproutes"])

(def timestamp-formatter
  (-> (DateTimeFormatter/ofPattern "yyyy-MM-dd'T'HH:mm:ss'Z'")
      (.withZone ZoneOffset/UTC)))

(defn run-process [command options]
  (try
    @(proc/process command options)
    (catch Throwable t
      (binding [*out* *err*]
        (println (str "error: " (or (ex-message t) "command failed"))))
      {:exit 127 :out "" :err (or (ex-message t) "command failed")})))

(defn captured-process [command]
  (run-process command {:out :string :err :string}))

(defn inherited-process [command]
  (run-process command {:out :inherit :err :stdout}))

(defn -main [& args]
  (let [namespace (first args)
        configured-context (System/getenv "AETHER_KUBE_CONTEXT")
        expected-context (if (str/blank? configured-context)
                           "admin@aether-k8s"
                           configured-context)]
    (when (str/blank? namespace)
      (binding [*out* *err*]
        (println "Usage: k8s-snapshot.bb <namespace>"))
      (System/exit 2))

    (let [{:keys [exit out err]}
          (captured-process ["kubectl" "config" "current-context"])]
      (when-not (zero? exit)
        (binding [*out* *err*]
          (println (str "error: unable to read kubectl context"
                        (when-not (str/blank? err) (str ": " (str/trim err))))))
        (System/exit exit))

      (let [context (str/trim out)]
        (when-not (= context expected-context)
          (binding [*out* *err*]
            (println (str "error: kubectl context is " context
                          "; expected " expected-context))
            (println "Follow AGENTS.md before continuing."))
          (System/exit 1))

        (let [{namespace-exit :exit}
              (run-process ["kubectl" "get" "namespace" "--" namespace]
                           {:out :string :err :inherit})]
          (when-not (zero? namespace-exit)
            (System/exit namespace-exit)))

        (println (str "Context: " context))
        (println (str "Namespace: " namespace))
        (println (str "Collected: " (.format timestamp-formatter (Instant/now))))

        (doseq [resource resources]
          (println)
          (println (str "== " resource " =="))
          (flush)
          (inherited-process ["kubectl" "get" resource "-n" namespace "-o" "wide"]))

        (println)
        (println "== warning events ==")
        (flush)
        (inherited-process ["kubectl" "get" "events" "-n" namespace
                            "--field-selector" "type=Warning"
                            "--sort-by=.lastTimestamp"])
        (System/exit 0)))))

(apply -main *command-line-args*)
