# Bug: intermittent NXDOMAIN for `logging-alv.googleapis.com` via estate DNS

**Status:** resolved (2026-07-22) · **Severity:** medium (one workload degraded; potential for others)
**Reported:** 2026-07-22 · **Reporter:** vigil rollout (cloud-audit)

## Summary

From inside the Talos cluster (and reproducibly from the router/Technitium
path), `logging-alv.googleapis.com` — the CNAME target Google serves for
`logging.googleapis.com` — intermittently resolves to **NXDOMAIN**. The
failure dominates (~75–90% of queries in a 7h window), with short recovery
windows. `8.8.8.8` resolves it consistently (216.239.32–38.174). The Mac's
resolver path also resolves it (to `192.178.192.x`, an as-yet-unidentified
answer range that nonetheless serves Google APIs fine — see "Open questions").

## Impact

`vigil`'s `gcp.audit` collector (Cloud Logging `entries:list`) fails on
transport in most loop iterations. Events still land eventually via cursor
re-entry + dedupe, but worst-case detection latency becomes hours instead of
the intended ~6 min. Anything else in the cluster calling Google Logging
(e.g. future log shippers, cloud SDKs) is presumably affected too.

## Evidence

7h of pod logs (`kubectl logs -n cloud-audit -l app.kubernetes.io/name=vigil`),
`gcp.audit` retries every 60s tick until a success commits the cursor:

| Hour (2026-07-22) | Failed ticks | Successful runs |
| --- | --- | --- |
| 02 (partial) | 19 | 5 |
| 03 | 47 | 2 |
| 04 | 29 | 6 |
| 05 | 37 | 5 |
| 06 | 24 | 7 |
| 07 | 44 | 2 |
| 08 | 24 | 7 |
| 09 (partial) | 16 | 0 |

Resolution checks (2026-07-18/22, all from the estate):

- In-cluster canary (`busybox nslookup logging.googleapis.com`):
  AAAA → `2607:f8b0:4023:1803::5f` (real Google), A → **NXDOMAIN**.
- In-cluster canary for the CNAME target:
  `nslookup logging-alv.googleapis.com` → **NXDOMAIN** (served by kube-dns
  10.96.0.10:53).
- Technitium `ns1` (`192.168.2.236`) directly: `logging-alv.googleapis.com`
  → empty/NXDOMAIN; `google.com` → fine; `storage.googleapis.com` → mix of
  real Google IPs and `192.178.192.x` answers.
- `8.8.8.8`: `logging-alv.googleapis.com` → `216.239.38.174`, `.36`, `.34`,
  `.32` (works).
- From the Mac (resolver `10.0.4.1`): everything resolves; Google API calls
  (STS, iamcredentials, Logging) succeed. Notably the Mac's answers for
  `*.googleapis.com` include `192.178.192.95/.207` — NOT Google IPs, yet
  those endpoints served Google APIs correctly.

Chain: pod → kube-dns (CoreDNS `forward . /etc/resolv.conf`) → Talos hostDNS
(`127.0.0.53`) → node nameserver (router `10.0.0.1`) → Technitium → upstream.

## Ruled out

- **vigil / its CNP.** Failures predate and persist independent of the
  `toFQDNs` policy; AWS/GCP token exchanges to `sts.googleapis.com` and
  `iamcredentials.googleapis.com` succeed from the same pod (only
  `logging.googleapis.com`'s CNAME target is affected).
- **Google outage.** `8.8.8.8` resolves and serves the name consistently.
- **Cilium/egress.** Failure is at DNS resolution, not TCP/TLS.

## Suspects (unverified)

1. Technitium (or its upstream — likely the ISP resolver) mishandles the
   `-alv-` name (rate-limit/anti-abuse domain pattern?) and serves NXDOMAIN.
2. The `192.178.192.0/24` answer range is part of the story (ISP
   proxy/DNS64/transparent Google cache?) — if that's a deliberate local
   rewrite somewhere, it may be missing `logging-alv`.

## Open questions

- What is `192.178.192.0/24`? Not Google space. It answered Google API TLS
  correctly from the Mac. Identify it (ISP-owned? Technitium feature?
  upstream DNS64/proxy?).
- Does Technitium log/forward `logging-alv.googleapis.com` to a specific
  upstream that NXDOMAINs it, and why?
- Are other `*-alv.googleapis.com` aliases (`logging`, and Google rotates
  these names) equally affected?

## Suggested fixes (owner's call)

- **Cluster stopgap:** CoreDNS stub zone forwarding `googleapis.com` to
  `8.8.8.8`/`1.1.1.1` (must go through the Talos machine-config path, not a
  live Corefile edit).
- **Estate fix:** address the Technitium/upstream chain so
  `logging-alv.googleapis.com` resolves for every client, not just the
  cluster — forward or rewrite as appropriate once the NXDOMAIN source is
  identified.

## References

- vigil pod: `cloud-audit/vigil-*` (logs above; `kubectl logs -n cloud-audit
  -l app.kubernetes.io/name=vigil | grep gcp.audit`)
- Technitium deployment: `ansible/roles/technitium_dns/`,
  `docs/networking.md` §DNS
