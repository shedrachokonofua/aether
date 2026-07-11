# VM Capacity Investigation: monitoring-stack (qemu/1003)

**Host:** `10.0.2.3` (monitoring-stack) · **Proxmox ID:** `qemu/1003` · **Allocated:** 4 vCPU, 16.76 GiB RAM · **Investigation time:** 2026-07-05

---

## Verdict

**Genuinely under-provisioned — not a memory leak or runaway RSS growth.**

The VM is running a steady-state observability stack that saturates its allocation: CPU is chronically high with recent spikes well above 100% of 4 vCPU, while Proxmox-reported memory sits flat at ~99% for 7 days (+30 MiB). Inside the guest, **MemAvailable remains ~7.6 GiB (49%)** and total process RSS is ~8 GiB, so the 99% Proxmox figure reflects Linux page-cache retention and hypervisor accounting — not runaway anonymous memory growth.

**Primary pressure:** CPU (`otel_collector` + `loki` query load + `prometheus`). **Secondary:** RAM headroom for TSDB/query spikes, not a leak.

### Recommended sizing (not applied — investigation only)

| Resource | Current | Target | Rationale |
|----------|---------|--------|-----------|
| **vCPU** | 4 | **8** | 24h avg 63.7% (~2.5 cores); max 116%; otel_collector + loki routinely >90% of one core each |
| **RAM** | 16.76 GiB | **24 GiB** (32 GiB preferred) | Flat ~99% PVE utilization; prometheus RSS peaks to 3.99 GiB (7d max); stack RSS ~8 GiB + cache fills guest RAM from hypervisor view |

---

## Prometheus / Proxmox trends (via `http://10.0.2.3:9090`, instance `192.168.2.202`)

### CPU — `pve_cpu_usage_ratio{id="qemu/1003"}`

| Window | avg | max | min |
|--------|-----|-----|-----|
| **24h** | **63.7%** | 116.4% | 9.5% |
| **7d** | **44.9%** | 116.4% | 9.5% |

- **7d hourly trend:** 42.3% → 110.0% (+67.7 pp) — CPU load rising, not flat.
- **Instant at investigation:** ~81–101% (post-Ansible redeploy warmup).
- Interpretation: sustained multi-core load on 4 vCPU; peaks exceed 100% when multiple services spike concurrently.

### Memory — `pve_memory_usage_bytes{id="qemu/1003"}` (size = 17.18 GiB)

| Window | avg | max | min |
|--------|-----|-----|-----|
| **24h** | 16.95 GiB (98.7% of size) | 17.25 GiB (100.4%) | 16.70 GiB (97.2%) |
| **7d** | 16.93 GiB (98.6%) | 17.25 GiB | 16.55 GiB |

- **7d hourly delta:** 16.98 → 17.00 GiB (**+0.03 GiB**) — **flat-high, not growing**.
- Range over 7d: ~700 MiB swing — consistent with cache/working-set oscillation, not leak slope.

### Prometheus RSS — `process_resident_memory_bytes{job="prometheus"}`

| Window | avg | max | min |
|--------|-----|-----|-----|
| **24h** | 2.74 GiB | 3.93 GiB | 1.22 GiB |
| **7d** | 2.82 GiB | **3.99 GiB** | 1.22 GiB |

- **7d trend:** 2.60 → 2.41 GiB (**−0.18 GiB**) — no growth; dips include Ansible container recreates.

---

## True memory pressure (guest `/proc/meminfo`, `free`, `vmstat`)

| Metric | Value | Notes |
|--------|-------|-------|
| MemTotal | 15.6 GiB (16363652 kB) | |
| **MemAvailable** | **7.6–8.0 GiB (~49%)** | Kernel reports substantial reclaimable headroom |
| MemFree | 0.45–0.75 GiB | Normal when cache is warm |
| **Cached** | **6.3–6.6 GiB** | File cache — reclaimable |
| Buffers | 312 kB | Negligible |
| SReclaimable (Slab) | 1.09 GiB | Mostly reclaimable |
| **AnonPages (RSS-like)** | 7.1 GiB | Actual anonymous pressure |
| **Total process RSS (ps sum)** | **~8.0 GiB** | Matches anon footprint |
| SwapTotal / SwapFree | 8.0 GiB / 7.4 GiB | **~582–688 MiB swap used** |
| vmstat si/so (live 3×1s) | 0 / 0 | **No active swap thrashing** |
| Dirty | 21 MiB | Low |

**Conclusion:** Proxmox 99% mem is **not** acute guest OOM pressure. Linux holds ~6.5 GiB file cache; hypervisor counts guest-used RAM near 100%. Swap use is modest and stable — not thrashing.

---

## OOM / pressure events

| Check | Result |
|-------|--------|
| `journalctl -k --since 24h/7d` OOM grep | **No OOM kills.** Only `systemd-oomd.socket` listen on Jul 04 boot |
| Container restarts | **Ansible pod recreate** Jul 04 11:59 and **Jul 05 09:11** (`recreate=True` on monitoring-stack pod) — planned deploy, not OOM |
| Host reboot | Jul 04 15:13 (brief prior boot 15:07–15:13) |

---

## Per-container memory & CPU (podman stats + ps RSS, post-restart snapshot)

| Container | Mem (limit 16.76 GiB) | CPU | RSS rank (ps) |
|-----------|----------------------|-----|---------------|
| **prometheus** | **2.95 GiB (17.6%)** | 23% | #2 ~1.86–2.69 GiB |
| **otel_collector** | **2.31 GiB (13.8%)** | **91%** | **#1 ~2.08–2.19 GiB** |
| clickhouse | 906 MiB (5.4%) | 18% | ~716 MiB |
| **loki** | 662 MiB (4.0%) | **103%** | ~584 MiB |
| grafana | 626 MiB (3.7%) | 3% | ~510 MiB |
| tempo | 147 MiB (0.9%) | 1% | ~163 MiB |
| fleet stack | ~240 MiB combined | low | mysqld ~118 MiB |

**Growth evidence:** Only prometheus has 7d Prometheus time-series (`process_resident_memory_bytes`); it **shrinks** over 7d. Other services lack historical container-level series in Prometheus (cadvisor metrics are cluster-scoped via otel_collector, not local podman names). Live RSS shows **stable plateaus**, not unbounded climb.

**CPU runaway (not mem leak):** `otel_collector` (K8s/cadvisor metric fan-in) and `loki` (heavy Grafana alert queries — Tetragon 12h `count_over_time` queries visible in logs) dominate CPU.

---

## Disk fill trajectory & retention risk

### Filesystem

| Mount | Size | Used | Avail | Use% |
|-------|------|------|-------|------|
| `/` (`/dev/vda4`) | 255 GiB | **164 GiB** | 90 GiB | **65%** |

### Data directory sizes

| Path / volume | Size | Retention config |
|---------------|------|------------------|
| `/home/aether/loki/data/chunks` | **126 GiB** | `retention_period: 90d`, compactor enabled |
| `prometheus_storage` volume | **21 GiB** | No explicit flag — **Prometheus default 15d** TSDB; blocks metric = 21.8 GiB |
| `clickhouse_storage` volume | **8.7 GiB** | System logs profile; no aggressive TTL found |
| `grafana_storage` | 298 MiB | dashboards/state |
| tempo | minimal on host | `block_retention: 168h` (7d); traces remote_write to prometheus |

### Trajectory / risk

- **Loki dominates disk (126 GiB / 164 GiB used).** With 90d retention and compactor enabled, size should **plateau** near retention equilibrium (~1.4 GiB/day ingest implied). **Medium risk:** if ingest grows, 90 GiB free buffer erodes over months.
- **Prometheus 21 GiB** on 15d default — stable if retention unchanged; WAL compaction runs normally (09:00 block write observed).
- **Root at 65%** — not imminently full, but Loki+Prom combine for **~147 GiB** of observability data; monitor Loki compactor delete lag.
- **No evidence of runaway disk leak** — growth aligns with configured retention, not unbounded tmp/log explosion.

---

## Summary table

| Question | Answer |
|----------|--------|
| Leak or under-provisioned? | **Under-provisioned (CPU primary, RAM secondary)** |
| Memory leak culprit? | **None** — 7d PVE mem delta +30 MiB; prometheus RSS −180 MiB |
| CPU runaway culprit? | **otel_collector** (metric pipeline) + **loki** (alert query load) |
| True mem pressure? | **No** — MemAvailable 49%, cache-heavy, swap not thrashing |
| Proxmox 99% mem meaning? | Guest keeps RAM as cache; hypervisor sees full allocation — **flat-high capacity signature** |
| Disk risk? | **Loki 126 GiB @ 90d retention** on 255 GiB disk (65% used); retention-bounded but largest growth vector |

---

*Investigation only — no resize or remediation applied.*
