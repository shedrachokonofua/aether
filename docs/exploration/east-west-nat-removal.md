# East-West NAT Removal: Real Source Identity on the Management Network

Plan to stop masquerading VLAN→management traffic so hosts on `192.168.2.0/24` see real
source IPs instead of the router's `192.168.2.231`. Today no management-net host can write
a meaningful source-IP rule about any VM — every cross-VLAN connection arrives as the same
address. This is the structural weakness that forced the journal-forwarder plan to reject
firewall-only authn; fixing it makes source identity work estate-wide and cheapens every
future authorization decision.

## Exact mechanism today

VyOS `nat source` rules in `ansible/playbooks/home_router/configure_router.yml:33-58`:

| Rule | Match | Action |
| --- | --- | --- |
| 100 | `10.0.0.0/16` → out `pppoe0` | masquerade (WAN — **unrelated, stays**) |
| 101 | `10.0.2.0/24` → out `eth0`, dst `192.168.2.0/24` | masquerade → `.231` |
| 103 | `10.0.3.0/24` → out `eth0`, dst `192.168.2.0/24` | masquerade → `.231` |
| 102 | `10.0.4.0/24` → out `eth0`, dst `192.168.2.0/24` | masquerade → `.231` |

Semantics (conntrack): SNAT applies only to connections **initiated from the VLAN side**;
replies are un-NATed automatically, and management-initiated connections are never
translated. Inter-VLAN traffic (`10.0.x ↔ 10.0.y`) never matches these rules — this change
touches only the VLAN→`192.168.2.0/24` direction.

**Why the masquerade exists**: management-net hosts default-gateway at the Bell Gigahub
(`192.168.2.1`), which has no route to `10.0.0.0/8`. A reply to a raw `10.0.2.3` source
would be sent to the Gigahub and die. Masquerading to `.231` keeps replies on-link to
VyOS's own leg of the segment — correctness at the price of erasing source identity.

**The fix** is therefore two-sided: give managed hosts a return route
(`10.0.0.0/8 via 192.168.2.231`), and stop translating traffic **only toward hosts that
have one** — VyOS NAT `exclude` rules evaluated before the masquerade make this per-host
and incrementally deployable.

## What already exists (half-built)

Return routes are deployed today in four inconsistent implementations, all hardcoding `.231`:

| Host(s) | Route | Mechanism | Persistence |
| --- | --- | --- | --- |
| niobe/trinity/oracle/smith/neo | `10.0.0.0/8` | `configure_proxmox_internal_routes.yml` | ✅ `/etc/network/if-up.d` hook |
| (same hosts, redundantly) | `10.0.0.0/8` | inline task in `configure_ceph_rgw.yml:86` | ❌ runtime only — retire |
| step-ca LXC | `10.0.0.0/8` | `step_ca/deploy_step_ca.yml:33-58` | ✅ NetworkManager dispatcher |
| adguard ×2 (NixOS) | `10.0.2.0/24` only | `nix/hosts/common/adguard-resolver.nix:227` (oneshot) | ✅ systemd unit |

Missing entirely: **backup-stack** (`.233`), **bazzite-builder** (`.234`). Special case:
**nfs** is dual-homed (`192.168.2.232` + `10.0.2.4`) — and
`network_file_server/configure_ip_routing.yml` already deletes its Gigahub default route,
so it likely defaults via the VyOS leg and replies to VLAN sources correctly today.
Verify in phase 0; the explicit `10.0.0.0/8 via 10.0.2.1` route is then defensive
hardening, not a gap fill.

Ephemeral: **vyos-packer** (`.230`) stays on the masquerade fallback deliberately — it is
a build-lifecycle VM, not worth route plumbing.

Never routable (no config management): Gigahub (`.1`), JetKVM (`.220`), rack switch
(`.221`), office switch (`.222`), UPS network card (`.223` — actively monitored from
VLAN 3 via `SERVICES-to-MGMT` rule 40), pi-switch (`.224`), MoCA/living-room devices
(unknown/DHCP — fallback by default). **These force the exclude-group design: wholesale
deletion of rules 101–103 is off the table; the masquerade stays as fallback, and anything
not explicitly in the exclude group is safe by construction.**

## Allowlist audit (what breaks / what doesn't)

| Surface | Finding |
| --- | --- |
| NFS exports (`network_file_server/configure_nfs.yml:5-18`) | `allowed_ips` are already `10.0.{2,3,4}.0/24` — clients mount via the `10.0.2.4` leg, un-NATed. Zero `.231` dependence; no change. |
| Repo-wide grep for `192.168.2.231` allowlists | Only route-via targets, VyOS's own listen addresses, and doc references — no ACL keyed on `.231` as a *source*. |
| VyOS zone firewall (`SERVICES-to-MGMT`, `TRUSTED-to-MGMT`, …) | Forward-hook rules match **pre-NAT** source addresses (`10.0.x`), so they are unaffected by removing SNAT. |
| Proxmox firewall | NICs carry `firewall=1` flags but no rule set is managed in-repo. **Verify live** that the datacenter/host firewall is disabled or has no `.231`-source rules before flipping. |
| Ceph mons/OSDs (VLAN 3 → `.201/.202/.204/.205`) | Ceph does no source-IP authz; hosts already have return routes. Flow becomes symmetric with real sources. |
| host-local firewalld/nftables on mgmt hosts | None managed in-repo; **verify live** per host in phase 0. |

## Rollout

### Phase 0 — live verification (read-only)

- `pve-firewall status` on all five hosts; confirm no `.231`-source rules anywhere.
- Confirm current routes: `ip route show 10.0.0.0/8` on all ten managed mgmt hosts.
- Snapshot long-lived VLAN→mgmt conntrack flows (`show conntrack table ipv4` filtered on
  `.231` translations) to know what re-establishes at flip time.

### Phase 1 — consolidate + complete return routes

One source of truth: template the gateway as `{{ vm.router.ip.gigahub }}` (config/vm.yml)
everywhere; kill the hardcoded `.231` literals across all four implementations.

1. New shared task file (or small role) `mgmt_internal_route`: if-up.d hook pattern from
   the Proxmox playbook, parameterized. Wired into the owning workflows so routes are never
   a manual step: `configure_proxmox_internal_routes.yml` (Proxmox, existing Taskfile
   path), `backup_stack/site.yml`, the bazzite-builder provisioning playbook
   (NetworkManager dispatcher variant, cf. step-ca), `step_ca/deploy_step_ca.yml`
   (refactor onto the shared file). **Gate**: phase 2 may not add a host to the exclude
   group until this has executed successfully against it.
2. nfs playbook: add `10.0.0.0/8 via {{ vm.nfs.gateway.vyos }}` on the VyOS leg.
3. NixOS: promote the adguard route oneshot into a small module option
   (`aether.mgmt-internal-route`), widen `10.0.2.0/24` → `10.0.0.0/8` for uniformity.
4. Retire the redundant inline route task in `configure_ceph_rgw.yml` (superseded).
5. Verify from a VLAN host: `ping`/`curl` each of the eleven, confirm replies.

### Phase 2 — VyOS exclude rules (the flip)

One member per host — never a range — so rollout and rollback stay per-host:

```text
set firewall group address-group MGMT-ROUTED-HOSTS address 192.168.2.201
set firewall group address-group MGMT-ROUTED-HOSTS address 192.168.2.202
set firewall group address-group MGMT-ROUTED-HOSTS address 192.168.2.203
set firewall group address-group MGMT-ROUTED-HOSTS address 192.168.2.204
set firewall group address-group MGMT-ROUTED-HOSTS address 192.168.2.205
set firewall group address-group MGMT-ROUTED-HOSTS address 192.168.2.232
set firewall group address-group MGMT-ROUTED-HOSTS address 192.168.2.233
set firewall group address-group MGMT-ROUTED-HOSTS address 192.168.2.234
set firewall group address-group MGMT-ROUTED-HOSTS address 192.168.2.235
set firewall group address-group MGMT-ROUTED-HOSTS address 192.168.2.236
set firewall group address-group MGMT-ROUTED-HOSTS address 192.168.2.237

set nat source rule 95 description 'No SNAT toward route-capable mgmt hosts'
set nat source rule 95 outbound-interface name eth0
set nat source rule 95 source address 10.0.0.0/16
set nat source rule 95 destination group address-group MGMT-ROUTED-HOSTS
set nat source rule 95 exclude
```

Rule 95 sorts before 101/102/103, so matching flows skip SNAT; everything else (UPS,
switches, Gigahub, JetKVM) falls through to the existing masquerade unchanged.

Two mechanics constraints:

- **`vyos_config` is additive** — `set` lines never remove stale group members. The
  Ansible task for the group must lead with
  `delete firewall group address-group MGMT-ROUTED-HOSTS` then re-`set` every member from
  a templated list (rebuild-then-verify), and the play ends by asserting the rendered
  running config (`show configuration commands | match MGMT-ROUTED-HOSTS`) matches the
  list exactly.
- **Syntax is unverified in-repo** — no existing precedent for NAT `exclude` or NAT
  `destination group`. Phase 0 gate: enter configure mode on the running VyOS, build the
  complete candidate (group + rule 95), `commit` WITHOUT `save`, verify, then save — or
  discard on any surprise.

Incremental by construction: a host enters the group only after its route is verified;
rollback per host = remove it from the group (one command); full rollback = delete rule 95.

### Phase 3 — verification

- **Per-destination × per-VLAN matrix**, not a single sample: from one host on each of
  VLAN 2 (monitoring-stack), VLAN 3 (gitlab), VLAN 4 (a personal device), connect to every
  excluded destination (`.201-.205`, `.232-.237`) and confirm on the target (`ss -tn` /
  logs) that the observed peer is the real `10.0.x` source. Canonical example: curl
  `192.168.2.201:9100/metrics` from monitoring-stack → niobe sees `10.0.2.3`.
- Prometheus `proxmox-hosts-node`/`smart`/`ceph` targets stay `up` across the flip
  (existing conntrack entries keep their old translation until re-established — expect a
  mixed state for minutes, not breakage).
- UPS monitoring (VLAN 3 → `.223:80,161`) still works — proves the fallback masquerade path.
- Ceph health unchanged (VLAN 3 storage flows).
- journal-forwarder mTLS polls unaffected (source IP changes; TLS doesn't care).

### Phase 4 — docs + downstream simplifications

- `docs/networking.md`: NAT section rewritten (exclude-group design, fallback semantics,
  "new mgmt host = route + group membership" rule).
- [journal-forwarder.md](journal-forwarder.md): the NAT-collapse rationale becomes
  historical for routed hosts — mTLS remains justified by the L2-peer argument, but
  per-host `19531` firewall rules can now name `10.0.2.3` directly, and the VyOS pre-NAT
  rule workaround is obsolete.
- Every future mgmt-net service gets source-IP authz as a real option.

## Risks

- **Route missing on an excluded host** (fresh reinstall without the hook) = VLAN→host
  connections time out (SYN arrives, SYN-ACK dies at the Gigahub). Symptom is
  direction-specific: mgmt-initiated traffic still works. Mitigation: route deployment
  lives in each host's provisioning playbook + phase-1 verification; rollback is one
  group-member removal.
- **Conntrack staleness at flip**: established VLAN→mgmt flows keep the `.231` translation
  until they re-establish. Bounded by scrape/poll cycles; no action needed beyond patience.
- **VyOS syntax drift**: `exclude` + address-group range membership verified against the
  running VyOS version in phase 0, not assumed.
- **Asymmetric routing** is not introduced: both directions traverse VyOS (VLAN leg ↔ eth0
  leg), so zone policies and conntrack see complete flows.

## Decisions record

| Alternative | Rejected because |
| --- | --- |
| Delete rules 101–103 outright | Breaks every unmanaged device (UPS monitoring from VLAN 3, switch/JetKVM access) — they can never carry return routes |
| Routes on the Gigahub instead of hosts | Consumer ISP hardware; not configurable/managed, and would still hairpin traffic |
| Keep NAT, rely on mTLS everywhere instead | Cert-based authn works for services that speak TLS; source identity also fixes logs, rate-limits, exports, and plain-TCP services — orthogonal and cheaper per-service |
| Move mgmt-net stragglers into VLANs instead | Right long-term for bazzite-builder/adguard, but re-IP projects are heavy; this change is additive and unblocks source identity now |

## Related

- [journal-forwarder.md](journal-forwarder.md) — first victim of the NAT collapse; its
  network controls upgrade when this lands
- [monitoring-stack-nix.md](monitoring-stack-nix.md) — future exporter-plane mTLS pairs
  with (not replaces) source identity
- `../networking.md` — NAT/firewall sections to update at execution
