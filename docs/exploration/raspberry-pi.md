# Raspberry Pi Kubernetes Workers

Plan for adding Raspberry Pis and CM4-based boards to the existing Talos Kubernetes cluster as small ARM64 worker nodes.

> **Status (verified 2026-07-12): implemented.** `talos-mouse`,
> `talos-dozer`, `talos-tank`, and `talos-sparks` are declared as bare-metal
> ARM workers and are live `Ready` on Kubernetes v1.35.0 with
> `kubernetes.io/arch=arm64` and `aether.sh/node-pool=arm`. The implementation
> steps below are retained as historical design context, not pending work.

## Goal

Use the Pis as a low-power ARM worker pool for lightweight Kubernetes workloads while keeping the main x86/Talos VM cluster as the primary compute plane.

The Pis are not control-plane nodes, not Ceph storage nodes, and not a replacement for the main Proxmox-backed workers.

## Hardware

| Node           | Hardware       | RAM | Role                 | IP        | MAC               |
| -------------- | -------------- | --- | -------------------- | --------- | ----------------- |
| `tank`         | Pi 5           | 4GB | ARM worker           | 10.0.3.23 | D8:3A:DD:EE:47:E6 |
| `dozer`        | Pi 5           | 4GB | ARM worker           | 10.0.3.24 | 2C:CF:67:02:B6:2C |
| `mouse`        | Pi 4           | 4GB | ARM worker           | 10.0.3.25 | 2C:CF:67:AC:E1:EF |
| `sparks`       | CM4 Lite / Mini Base | 4GB | ARM worker | 10.0.3.26 | 2C:CF:67:78:73:CE |

`sparks` is a Raspberry Pi CM4 SKU `CM4104000`: 4GB RAM, Lite/no eMMC, with wireless. It is currently on a Mini Base carrier and boots from microSD. Longer-term, swap to a proper CM4 carrier (Waveshare Mini Base Board B or similar) when the Pi shelf goes into the main rack. CM4 PCIe is Gen2 x1 (~400MB/s ceiling), so storage stays modest: microSD or a small 2242 NVMe. Per the storage policy, this node is Ceph end-to-end and holds no local persistent state.

All ARM workers live on the Services VLAN:

| Setting | Value      |
| ------- | ---------- |
| VLAN    | 3          |
| Subnet  | 10.0.3.0/24 |
| Gateway | 10.0.3.1   |
| DNS     | 10.0.3.1   |

The DHCP range is `10.0.3.240-254`; the static Pi addresses are outside that range.

## Switch Ports

The Pis connect to the rack Pi switch on access ports in VLAN 3. The Pi switch uplinks to rack switch port 13.

| Pi switch port | Device     | VLAN | PVID | Tagged VLANs |
| -------------- | ---------- | ---- | ---- | ------------ |
| 1              | Rack uplink | 1    | 1    | 3            |
| 2              | ARM worker | 3    | 3    | none         |
| 3              | ARM worker | 3    | 3    | none         |
| 4              | ARM worker | 3    | 3    | none         |
| 5              | ARM worker | 3    | 3    | none         |

Pi switch management:

| Setting | Value                 |
| ------- | --------------------- |
| IP      | 192.168.2.224         |
| Domain  | pi-switch.home.shdr.ch |
| VLAN    | 1                     |

Rack switch side:

| Rack switch port | Device        | Untagged VLAN | Tagged VLANs |
| ---------------- | ------------- | ------------- | ------------ |
| 13               | Pi switch     | 1             | 3            |

For switch UIs that separate static VLAN membership from PVID:

- Set static VLAN 3 membership to `untagged` on Pi switch ports 2-5.
- Set static VLAN 3 membership to `tagged` on Pi switch uplink port 1.
- Set PVID `3` on Pi switch ports 2-5.
- Keep the uplink PVID as `1`.
- Add VLAN 3 as tagged on rack switch port 13 so VLAN 3 reaches VyOS.

## Talos Images

Use separate Talos Image Factory schematics for Pi 4/CM4 and Pi 5. The generic Raspberry Pi image works for Mouse/Pi 4; Pi 5 needs the official `rpi_5` overlay image.

### Pi 4 / CM4 Generic Image

| Setting      | Value |
| ------------ | ----- |
| Talos version | `v1.12.7` |
| Schematic ID | `ee21ef4a5ef808a9b7484cc0dda0f25075021691c8c09a276591eedb638ea1f9` |
| Asset        | `metal-arm64.raw.xz` |

Downloaded local files:

```text
/Users/shdrch/Downloads/talos-rpi-v1.12.7-metal-arm64.raw.xz
/Users/shdrch/Downloads/talos-rpi-v1.12.7-metal-arm64.raw
```

Official Talos docs for Raspberry Pi generic install:

```text
https://docs.siderolabs.com/talos/v1.12/platform-specific-installations/single-board-computers/rpi_generic
```

### Pi 5 Overlay Image

| Setting      | Value |
| ------------ | ----- |
| Talos version | `v1.12.7` |
| Schematic ID | `a636242df247ad4aad2e36d1026d8d4727b716a3061749bd7b19651e548f65e4` |
| Overlay      | `siderolabs/sbc-raspberrypi` |
| Overlay profile | `rpi_5` |
| Asset        | `metal-arm64.raw.xz` |

Pi 5 image URL:

```text
https://factory.talos.dev/image/a636242df247ad4aad2e36d1026d8d4727b716a3061749bd7b19651e548f65e4/v1.12.7/metal-arm64.raw.xz
```

Pi 5 installer image for Talos machine config:

```text
factory.talos.dev/installer/a636242df247ad4aad2e36d1026d8d4727b716a3061749bd7b19651e548f65e4:v1.12.7
```

Do not use the generic `rpi_generic` image for Pi 5. It can boot-loop with:

```text
installed OS does not indicate support for Raspberry Pi 5
```

## First Working Node: Mouse

The first successful node is `mouse`, a Raspberry Pi 4.

The microSD currently appears on the Mac as:

```text
/dev/disk4 (external, physical)
```

Flash command:

```bash
diskutil unmountDisk /dev/disk4
sudo dd if=/Users/shdrch/Downloads/talos-rpi-v1.12.7-metal-arm64.raw of=/dev/rdisk4 bs=4m conv=sync
diskutil eject /dev/disk4
```

During `dd`, press `Ctrl+T` on macOS to show progress.

After flashing:

1. Insert the microSD into the Pi 4 assigned to Mouse.
2. Plug Ethernet into VLAN 3.
3. Power it on.
4. Find its temporary DHCP address in `10.0.3.240-254`.
5. Apply the Talos worker config.

Mouse was first discovered on DHCP as `10.0.3.245`, then configured as:

```text
hostname: mouse
static IP: 10.0.3.25/24
gateway: 10.0.3.1
DNS: 10.0.3.1
interface: end0
install disk: /dev/mmcblk0
```

Dozer was first discovered on DHCP as `10.0.3.246`, then configured as:

```text
hostname: dozer
static IP: 10.0.3.24/24
gateway: 10.0.3.1
DNS: 10.0.3.1
interface: end0
install disk: /dev/mmcblk0
```

Tank was first discovered on DHCP as `10.0.3.247`, then configured as:

```text
hostname: tank
static IP: 10.0.3.23/24
gateway: 10.0.3.1
DNS: 10.0.3.1
interface: end0
install disk: /dev/mmcblk0
```

Sparks was first discovered on DHCP as `10.0.3.248`, then configured as:

```text
hostname: sparks
static IP: 10.0.3.26/24
gateway: 10.0.3.1
DNS: 10.0.3.1
interface: end0
install disk: /dev/mmcblk0
```

## Pi 5 Boot Note

The failed Pi 5 attempt used the generic Raspberry Pi image. The next Pi 5 attempt should use the official `rpi_5` overlay image above. If a Pi 5 still fails to boot with the overlay image, check/update the Pi EEPROM firmware before changing Talos versions.

Reference:

```text
https://rcwz.pl/2025-10-04-installing-talos-on-raspberry-pi-5/
```

That post is useful context, but it documents an older `v1.10.x` workaround using the community `ghcr.io/talos-rpi5` imager and a custom installer image. For this cluster, prefer the official `v1.12.7` `rpi_5` Image Factory overlay above.

Useful takeaways from the post:

- For NVMe installs, booting temporary Raspberry Pi OS and writing Talos to `/dev/nvme0n1` is a valid path.
- Check Pi boot order if using NVMe. A practical order is SD first, then NVMe, while installing.
- After writing Talos to NVMe, remove the temporary OS card and boot from NVMe.

Current plan is simpler because the first Pi 5 test is using microSD directly:

```bash
diskutil unmountDisk /dev/disk4
sudo dd if=/Users/shdrch/Downloads/talos-rpi5-v1.12.7-metal-arm64.raw of=/dev/rdisk4 bs=4m conv=sync
diskutil eject /dev/disk4
```

## Cluster Design

Existing nodes:

| Node            | Role                    | IP        |
| --------------- | ----------------------- | --------- |
| `talos-trinity` | control-plane + worker  | 10.0.3.16 |
| `talos-neo`     | control-plane + worker + Blackwell GPU | 10.0.3.17 |
| `talos-niobe`   | control-plane + worker  | 10.0.3.18 |
| `talos-smith`   | worker + Turing GPU     | 10.0.3.22 |

Raspberry Pis join as worker-only nodes:

| Node           | Role        | Pool  |
| -------------- | ----------- | ----- |
| `tank`         | worker only | `arm` |
| `dozer`        | worker only | `arm` |
| `mouse`        | worker only | `arm` |
| `sparks`       | worker only | `arm` |

Use labels:

```text
kubernetes.io/arch=arm64
aether.sh/node-pool=arm
aether.sh/hardware=rpi
```

Do not make the Pis control-plane nodes. Do not add them to etcd.

## Scheduling Policy

The Pis should accept small ARM-compatible workloads without requiring every workload to explicitly target them.

Policy shape:

- Prefer automatic scheduling, not explicit app-by-app node selection.
- Use Kubernetes' native `kubernetes.io/arch=arm64` label for architecture.
- Add `aether.sh/node-pool=arm` for scheduling policy and dashboards.
- Add `aether.sh/hardware=rpi` for Pi-specific limits.
- Use Kyverno later to prevent bad placements.

Kyverno policy goals:

- Only allow pods with small memory requests onto `aether.sh/node-pool=arm`.
- Target roughly `<=512Mi` memory request per container/pod class.
- Require CPU/memory requests for pods allowed on Pi nodes.
- Prevent heavy workloads from landing there.
- Prefer multi-arch or ARM-compatible images. Kubernetes itself cannot fully know image manifest compatibility before pull, so policy should be conservative and exception-based where needed.

Do not mark everything `amd64`. The default cluster can stay normal. The Pi pool is the special constrained pool.

## Kyverno Guardrails

Kyverno is installed in the repo as `tofu/home/kubernetes/kyverno.tf`. The active `arm-pool-guardrails` ClusterPolicy validates scheduler `Pod/binding` admission requests, because normal Pod create admission happens before Kubernetes has selected a node.

The policy should be admission guardrails, not manual scheduling. Normal workloads should not need to explicitly select Pi nodes. Instead, if a pod is going to run on ARM/Pi, it must satisfy the constraints.

### Labels

Apply these labels to all Pi nodes:

```text
aether.sh/node-pool=arm
aether.sh/hardware=rpi
kubernetes.io/arch=arm64
```

### Optional Initial Taint

Until policy is in place, optionally taint the Pi nodes:

```text
aether.sh/node-pool=arm:NoSchedule
```

Remove the taint once Kyverno guardrails are active. The final desired state is no explicit toleration requirement for normal tiny ARM-safe pods.

### Required Requests

Reject pods on the ARM pool if containers do not declare requests:

```text
resources.requests.cpu
resources.requests.memory
```

Reason: the scheduler can only keep Pi placement safe if it has real request data.

### Memory Ceiling

Reject pods on the ARM pool if any app container requests more than:

```text
512Mi memory
```

This keeps the Pi pool for tiny workloads. System DaemonSets can be exempted by namespace or label.

The Talos machine config also reserves extra kubelet headroom on ARM nodes:

```text
systemReserved.memory: 1Gi
evictionHard.memory.available: 256Mi
```

That makes the scheduler's ARM memory budget roughly 2.4-2.6Gi per 4GB board, or about 10Gi total across the four-node ARM pool. Treat 75% requested memory as the steady-state target and 90% as an alert threshold, not a normal operating point.

Initial exemptions:

```text
kube-system
istio-system
system
kyverno
```

Tune this after measuring real ARM node overhead over time.

### CPU Ceiling

Start with a soft planning ceiling of:

```text
500m CPU request per app container
```

Memory is the tighter constraint on 4GB Pis, so enforce memory first. Add CPU enforcement later if the Pis get noisy.

### ARM Image Safety

Kubernetes schedules before image pull, so it does not automatically know whether an image supports ARM64. Kyverno also cannot reliably inspect every remote image manifest without extra registry metadata plumbing.

Use a conservative allowlist policy for Pi-eligible workloads:

```text
aether.sh/arm-ok=true
```

Meaning:

- Pods with `aether.sh/arm-ok=true` may run on the ARM pool if requests are small.
- Normal application pods get this label from `aether-k8s-arch-labeler` when all images support `linux/arm64` and requests are small.
- DaemonSet-owned pods get this label from Kyverno so platform node agents can schedule on ARM automatically; the binding guardrails still enforce CPU/memory requests and the 512Mi memory ceiling.
- Pods without it are prevented from landing on `aether.sh/node-pool=arm`.

For normal application pods, this avoids explicit node selection while still preventing random amd64-only images from getting scheduled to Pi nodes. DaemonSets are handled as platform node agents and still have to pass the ARM resource guardrails.

### Rebalancing

Descheduler is installed as a suspended CronJob for the ARM node pool:

```text
aether.sh/node-pool=arm
```

The draft policy only uses `LowNodeUtilization`, protects PVC-backed pods, and
lets the default scheduler choose replacement placement after evicting eligible
stateless pods. It is intentionally suspended because descheduler eviction does
not guarantee the replacement pod lands on a different ARM node. Prefer
scheduler-time placement rules such as topology spread constraints for workloads
that need real distribution.

### Policy Set

Active Kyverno resources:

1. `require-requests-on-arm-pool`
   - Match pods assigned to nodes with `aether.sh/node-pool=arm`.
   - Require CPU and memory requests.

2. `limit-arm-pool-memory-requests`
   - Match pods assigned to ARM pool nodes.
   - Enforce max memory request of `512Mi` per app container.

3. `require-arm-ok-for-arm-pool`
   - Match pods assigned to ARM pool nodes.
   - Require `aether.sh/arm-ok=true` unless the namespace is exempt.

4. `arm-ok-daemonset-pods`
   - Label DaemonSet-owned pods with `aether.sh/arm-ok=true` automatically.
   - Keeps platform node agents from needing chart-specific ARM labels.

5. `label-arm-nodes`
   - Optional generate/mutate policy if node labels should be enforced from Kubernetes instead of Tofu/Talos bootstrap.

### Why This Shape

This keeps the day-to-day workflow simple:

- Developers do not have to choose nodes.
- The scheduler can use the Pis automatically.
- Bad fits are rejected before they become broken pods.
- The default amd64 cluster stays unmarked and normal.
- ARM/Pi constraints live at the pool boundary.

## Expected Capacity

Each Pi has 4GB RAM. After Talos, kubelet, CNI, CSI, service mesh/node agents, and system overhead, usable application memory is modest.

Planning estimate:

| Scope | Expected useful workload |
| ----- | ------------------------ |
| Per Pi | 5-8 tiny pods |
| All 3 Pis | 15-25 tiny pods |

Use `~15 pods total` as the conservative first target.

## Good Pi Workloads

Good candidates:

- tiny stateless services
- small controllers
- lightweight exporters
- simple web utilities
- ARM-compatible side services
- low-memory scale-to-zero workloads

Bad candidates:

- databases
- JVM-heavy services
- Ceph monitors/OSDs
- GPU workloads
- AI/media workloads
- anything with large memory spikes
- latency-sensitive storage-heavy workloads

## Storage

The Pis should consume existing Kubernetes storage through CSI:

- Ceph RBD for normal PVCs
- NFS CSI where appropriate

Do not run Ceph daemons on the Pis. Treat the Pi boot media as OS-only and replaceable.

## Implementation Steps

1. Flash `mouse` with the Talos Raspberry Pi ARM64 image.
2. Boot Mouse on VLAN 3 and find its DHCP IP.
3. Add repo support for bare-metal ARM Talos workers distinct from Proxmox VM Talos nodes.
4. Generate/apply worker config for Mouse:
   - hostname `mouse`
   - static IP `10.0.3.25/24`
   - gateway `10.0.3.1`
   - DNS `10.0.3.1`
   - worker-only
5. Verify:
   - `talosctl version`
   - `kubectl get nodes -o wide`
   - node labels include `kubernetes.io/arch=arm64`
6. Add `aether.sh/node-pool=arm` and `aether.sh/hardware=rpi` labels.
7. Let DaemonSets settle and inspect actual overhead.
8. Repeat for `tank` and `dozer` using the Pi 5 `rpi_5` overlay image.
9. Add Kyverno guardrails for small ARM-safe workloads.

## Open Questions

- Whether Pi 5 boot media is microSD or USB SSD long term.
- Whether to add a taint initially, such as `aether.sh/node-pool=arm:NoSchedule`, until Kyverno policy is in place.
- Whether service mesh/node-agent overhead is worth running on the Pi pool, or whether some DaemonSets should avoid ARM nodes.
