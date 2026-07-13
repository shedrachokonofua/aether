#!/usr/bin/env bb
;; Forward ProjectDiscovery's hardcoded Google IPv6 DNS (bound on lo) to the
;; lab resolver. Nuclei embeds 2001:4860:4860::8888/::8844 and hangs for minutes
;; when those are unreachable (no global IPv6 on the estate-scanner LXC).

(ns nuclei-dns-shim
  (:require [clojure.string :as str])
  (:import [java.net InetAddress InetSocketAddress DatagramSocket DatagramPacket]
           [java.util.concurrent Executors]))

(def listen-addrs
  (let [raw (or (System/getenv "ESTATE_DNS_SHIM_LISTEN")
                "2001:4860:4860::8888,2001:4860:4860::8844")]
    (->> (str/split raw #",")
         (map str/trim)
         (remove empty?)
         vec)))

(def upstream-host (or (System/getenv "ESTATE_DNS_SHIM_UPSTREAM") "10.0.2.1"))
(def upstream-port (Integer/parseInt (or (System/getenv "ESTATE_DNS_SHIM_UPSTREAM_PORT") "53")))

(defn serve!
  [listen-addr upstream-ip]
  (let [sock (DatagramSocket. (InetSocketAddress. (InetAddress/getByName listen-addr) 53))
        buf (byte-array 65535)]
    (binding [*out* *err*]
      (println (str "estate-nuclei-dns-shim listening on [" listen-addr "]:53 -> "
                    upstream-host ":" upstream-port)))
    (loop []
      (let [req (DatagramPacket. buf (alength buf))]
        (.receive sock req)
        (try
          (let [upstream (DatagramSocket.)
                payload (java.util.Arrays/copyOfRange
                         (.getData req) (.getOffset req)
                         (+ (.getOffset req) (.getLength req)))
                packet (DatagramPacket. payload (alength payload) upstream-ip upstream-port)
                resp-buf (byte-array 65535)
                resp (DatagramPacket. resp-buf (alength resp-buf))]
            (.setSoTimeout upstream 2000)
            (.send upstream packet)
            (.receive upstream resp)
            (.send sock (DatagramPacket. (.getData resp) (.getLength resp)
                                         (.getAddress req) (.getPort req)))
            (.close upstream))
          (catch Exception e
            (binding [*out* *err*]
              (println (.getMessage e))))))
      (recur))))

(defn -main [& _args]
  (let [upstream-ip (InetAddress/getByName upstream-host)
        pool (Executors/newFixedThreadPool (count listen-addrs))]
    (doseq [addr listen-addrs]
      (.submit pool ^Callable (fn [] (serve! addr upstream-ip))))
    ;; Park forever; systemd restarts on failure.
    (while true
      (Thread/sleep 3600000))))

(-main)
