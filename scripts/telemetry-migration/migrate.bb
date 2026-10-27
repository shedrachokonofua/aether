#!/usr/bin/env bb
(require '[babashka.process :as process]
         '[clojure.java.io :as io])

;; Keep transport, nanosecond mapping and the transactional checkpoint in stdlib Python.
(let [script (str (io/file (.getParent (io/file *file*)) "migrate.py"))
      result (apply process/shell {:continue true} "python3" script *command-line-args*)]
  (System/exit (:exit result)))
