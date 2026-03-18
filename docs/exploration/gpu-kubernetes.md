# GPU Kubernetes Migration

Eliminate the GPU Workstation VM by moving all GPU workloads into the Kubernetes cluster via talos-neo.

## Goal

1. **Kill the GPU Workstation VM** — Delete the Fedora VM, its Ansible playbooks, and its Tofu config
2. **Replace Ollama + vLLM with llama-swap** — Single service managing llama-server (llama.cpp) processes with per-model profiles
3. **GPU in K8s** — talos-neo gets GPU passthrough, NVIDIA extensions, and all GPU workloads run as pods
4. **Kill ClearML and SwarmUI** — Not in use
5. **Enable future GPU transcoding** — Jellyfin gets native `nvidia.com/gpu` access, eliminating rffmpeg

## Current State

| Component | Details |
| --------- | ------- |
| GPU Workstation | Fedora VM on Neo, 32 cores, 64GB RAM, 1TB NVMe (local-lvm) |
| GPU | Nvidia RTX Pro 6000 (96GB VRAM), PCIe passthrough to GPU Workstation |
| talos-neo | K8s node on Neo, 8 cores, 16GB RAM, 64GB Ceph, no GPU (GPU Workstation averaged 11% RAM usage) |
| Inference | Ollama (Podman quadlet, 18 models) + vLLM (systemd, Qwen3.5-27B) |
| Management | Ansible (`gpu_workstation/`) + Tofu (`gpu_workstation.tf`) |

Current workloads on GPU Workstation:

| Workload | Runtime | GPU |
| -------- | ------- | --- |
| Ollama | Podman quadlet | yes |
| vLLM | systemd user unit (Python venv) | yes |
| ComfyUI | Podman quadlet | yes |
| SwarmUI | Podman quadlet | yes |
| Docling | Podman quadlet | yes |
| JupyterLab | Podman quadlet | yes |
| ClearML | Podman quadlet | no |
| TEI reranker | Podman quadlet | yes |

## Architecture

Kill the GPU Workstation VM, pass the GPU through to talos-neo instead. All Talos nodes bumped to 24GB RAM (GPU Workstation averaged 11% of 64GB).

### Before

```
Neo (128GB RAM, Ryzen 9 9950X, RTX Pro 6000)
├── gpu-workstation (Fedora)
│   32 cores, 64GB RAM, 1TB NVMe, GPU passthrough
│   └── Ollama, vLLM, ComfyUI, SwarmUI, Docling, JupyterLab, ClearML, TEI
└── talos-neo (Talos)
    8 cores, 16GB RAM, 64GB Ceph, no GPU
```

### After

```
Neo (128GB RAM, Ryzen 9 9950X, RTX Pro 6000)
└── talos-neo (Talos + NVIDIA extensions)
    32+ cores, 24GB RAM, Ceph + local NVMe, GPU passthrough
    └── llama-swap, ComfyUI, Docling, JupyterLab, TEI reranker (as K8s pods)
```

### LLM Serving Flow

```
Consumers (OpenWebUI, Bytebot, API clients)
    │
    ▼
LiteLLM Gateway (K8s, litellm.apps.home.shdr.ch)
    │
    ├── aether/* models → llama-swap (K8s Deployment, talos-neo)
    │                      └── llama-server processes (per-model GGUF)
    └── Cloud → OpenAI, Anthropic, OpenRouter
```

## Workload Migration

| Workload | K8s Resource | GPU | Notes |
| -------- | ------------ | --- | ----- |
| llama-swap (replaces Ollama + vLLM) | Deployment | yes | Always-on |
| TEI reranker | Deployment | yes | Always-on, light (~2-3GB VRAM) |
| Docling | Deployment | yes | Always-on, light |
| ComfyUI | Knative Service | yes | Scale-to-zero |
| JupyterLab | Knative Service | yes | Scale-to-zero, PVC for workspace |
| Jellyfin (future) | Deployment | yes | Media stack migration, replaces rffmpeg |

**Killed:** ClearML, SwarmUI

## llama-swap

Replaces both Ollama and vLLM with a single service. llama-swap is an orchestration layer that manages llama-server (llama.cpp HTTP server) processes.

| Feature | Details |
| ------- | ------- |
| Model management | Per-model profiles with GGUF path, context size, GPU layers, batch size |
| TTL-based unloading | Each model has a configurable idle TTL; process killed when expired, VRAM freed |
| On-demand loading | Request for unloaded model spawns a new llama-server, waits for health, proxies |
| Concurrent models | With 96GB VRAM, keep 2-3 models hot simultaneously |
| API | OpenAI-compatible — LiteLLM routing just changes the endpoint |
| Container | Single image bundles llama-swap + llama-server binary |

Advantages over current setup:

- **Replaces two services** (Ollama + vLLM) with one
- **Per-model TTL** vs Ollama's global `OLLAMA_KEEP_ALIVE`
- **Direct GGUF management** vs Ollama's opaque blob storage
- **Per-model tuning** — context size, GPU layers, batch size per profile
- **Pin frequently-used models** — keep Qwen3.5-27B loaded indefinitely while rarely-used models unload after a minute

## Talos NVIDIA Support

Talos is immutable — no `apt install nvidia-drivers`. NVIDIA support comes via system extensions baked into the Talos image at build time.

### Talos Image Factory

Generate a custom Talos image with NVIDIA extensions:

```bash
curl -X POST https://factory.talos.dev/schematics \
  -H "Content-Type: application/json" \
  -d '{
    "customization": {
      "systemExtensions": {
        "officialExtensions": [
          "siderolabs/qemu-guest-agent",
          "siderolabs/nvidia-open-gpu-kernel-modules",
          "siderolabs/nvidia-container-toolkit"
        ]
      }
    }
  }'
```

| Schematic | Extensions | Used by |
| --------- | ---------- | ------- |
| `ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515` | qemu-guest-agent | talos-trinity, talos-niobe |
| `4b4a20194a021d632958bfdcbc0528fb7b62f9ca52f5cabdc35730d512f3a392` | qemu-guest-agent, nvidia-open-gpu-kernel-modules, nvidia-container-toolkit | talos-neo |

### Machine Config Patch (talos-neo only)

```yaml
machine:
  kernel:
    modules:
      - name: nvidia
      - name: nvidia_uvm
      - name: nvidia_drm
      - name: nvidia_modeset
  sysctls:
    net.core.bpf_jit_enable: "1"
```

### NVIDIA Device Plugin

Deploy the NVIDIA device plugin as a DaemonSet in K8s. Pods request GPU access via `nvidia.com/gpu: 1`.

### Time-Slicing

NVIDIA time-slicing is a K8s scheduling mechanism — advertise N virtual GPUs so N pods can schedule simultaneously. All pods share the full 96GB VRAM with no isolation (same as the current VM approach where all containers pass `nvidia.com/gpu=all`).

```yaml
sharing:
  timeSlicing:
    resources:
      - name: nvidia.com/gpu
        replicas: 8
```

With 96GB VRAM, contention is a non-issue. Worst-case peak (all workloads active simultaneously) fits well within budget.

## Proxmox VM Changes (talos-neo)

talos-neo needs GPU passthrough, which requires UEFI boot. This is a node-specific change in `talos_cluster.tf` using conditionals within the existing `for_each` — not a refactor.

### VM Config

| Setting | Current | After |
| ------- | ------- | ----- |
| cores | 8 | 32+ |
| memory | 16GB | 24GB |
| bios | seabios | ovmf |
| machine | (default) | q35 |
| hostpci | none | `0000:01:00.0` (RTX Pro 6000) |
| efi_disk | none | local-lvm, 4m |
| disk | 64GB Ceph | 64GB Ceph + local NVMe for models |

### Tofu Changes

Surgical additions to `talos_cluster.tf` — ternaries and `dynamic` blocks keyed on `each.key == "talos_neo"`:

```hcl
machine    = each.key == "talos_neo" ? "q35" : null
bios       = each.key == "talos_neo" ? "ovmf" : "seabios"

dynamic "hostpci" {
  for_each = each.key == "talos_neo" ? [1] : []
  content {
    device   = "hostpci0"
    id       = "0000:01:00.0"
    pcie     = true
    rom_file = "rtx6000.rom"
  }
}

dynamic "efi_disk" {
  for_each = each.key == "talos_neo" ? [1] : []
  content {
    datastore_id = "local-lvm"
    file_format  = "raw"
    type         = "4m"
  }
}
```

Machine config uses a different install image for talos-neo:

```hcl
image = each.key == "talos_neo"
  ? "factory.talos.dev/installer/${local.talos_nvidia_schematic}:${local.talos_version}"
  : "factory.talos.dev/installer/${local.talos_schematic}:${local.talos_version}"
```

HA resource: talos-neo is pinned to Neo (GPU passthrough), set `max_relocate = 0`.

### Rebuild Scope

Only talos-neo is affected. The other two nodes are untouched:

1. `kubectl drain talos-neo`
2. etcd quorum maintained (2/3 nodes up)
3. Destroy talos-neo VM
4. Recreate with UEFI + GPU passthrough + larger resources
5. Boot with NVIDIA-enabled Talos image
6. Apply machine config — node rejoins cluster
7. `kubectl uncordon talos-neo`

## Storage

| Storage | Purpose | Type |
| ------- | ------- | ---- |
| Local NVMe | LLM models (GGUFs), SD models, LoRAs | Local PV with nodeAffinity to talos-neo |
| Ceph RBD | OS disk, general workload storage | StorageClass (default) |
| CephFS | Shared data (checkpoints, outputs, ComfyUI outputs) | PVC with CephFS StorageClass |

Models live on local NVMe for fast loading. GPU workloads are pinned to talos-neo anyway (only GPU node), so nodeAffinity is not a constraint.

## GPU Metrics

Replace `nvidia_gpu_exporter` (VM-based) with `dcgm-exporter` (K8s-native):

```
dcgm-exporter (DaemonSet on talos-neo, port 9400)
    │
    ▼
OTEL Collector (DaemonSet, prometheus receiver)
    │
    ▼
OTEL Gateway (Monitoring Stack VM, Niobe)
    │
    ▼
Prometheus → Grafana
```

Metrics: `dcgm_gpu_utilization`, `dcgm_fb_used`/`dcgm_fb_free` (VRAM), `dcgm_gpu_temp`, `dcgm_power_usage`, per-pod GPU metrics.

Existing GPU alert rules need metric name updates: `nvidia_smi_*` → `dcgm_*`.

## What Gets Deleted

| Item | Path |
| ---- | ---- |
| GPU Workstation VM | `tofu/home/gpu_workstation.tf` |
| GPU Workstation SSH key | `tofu/variables.tf` (partial) |
| GPU Workstation outputs | `tofu/outputs.tf`, `tofu/home/outputs.tf` (partial) |
| NVIDIA drivers playbook | `ansible/playbooks/gpu_workstation/nvidia.yml` |
| Ollama playbook | `ansible/playbooks/gpu_workstation/ollama.yml` |
| vLLM playbook | `ansible/playbooks/gpu_workstation/vllm.yml` |
| ComfyUI playbook | `ansible/playbooks/gpu_workstation/comfyui.yml` |
| SwarmUI playbook | `ansible/playbooks/gpu_workstation/swarmui.yml` |
| Docling playbook | `ansible/playbooks/gpu_workstation/docling.yml` |
| JupyterLab playbook | `ansible/playbooks/gpu_workstation/jupyter/` |
| ClearML playbook | `ansible/playbooks/gpu_workstation/clearml.yml` |
| Reranker playbook | `ansible/playbooks/gpu_workstation/reranker.yml` |
| Site playbook | `ansible/playbooks/gpu_workstation/site.yml` |
| VM config entry | `config/vm.yml` (gpu_workstation section) |
| Caddy reverse proxy | GPU Workstation routes in Caddyfile |
| Monitoring | `nvidia_gpu_exporter` on GPU Workstation |
| Neo Fedora image | `tofu/home/cloud_images.tf` (if no other Neo VMs need it) |

## Implementation Phases

### Phase 1: Talos NVIDIA Image

- [ ] Generate NVIDIA schematic via Image Factory API
- [ ] Add `talos_nvidia_schematic` to `cloud_images.tf`
- [ ] Download NVIDIA-enabled Talos ISO for Neo

### Phase 2: Rebuild talos-neo

- [ ] Update `config/vm.yml` — increase talos-neo cores, memory, add disk
- [ ] Update `talos_cluster.tf` — add GPU passthrough conditionals, UEFI, efi_disk
- [ ] Add NVIDIA machine config patch (kernel modules)
- [ ] Drain talos-neo, destroy VM, `tofu apply` to recreate
- [ ] Verify node rejoins cluster, GPU visible via `nvidia-smi`

### Phase 3: K8s GPU Platform

- [ ] Deploy NVIDIA device plugin DaemonSet
- [ ] Configure time-slicing (8 replicas)
- [ ] Deploy dcgm-exporter DaemonSet
- [ ] Verify OTEL Collector scrapes GPU metrics
- [ ] Create local NVMe PV for model storage

### Phase 4: llama-swap + LiteLLM

- [ ] Deploy llama-swap Deployment with GPU and model volume
- [ ] Configure model profiles (migrate from Ollama model list)
- [ ] Update LiteLLM config — point `aether/*` routes to llama-swap K8s service
- [ ] Verify inference through LiteLLM → llama-swap → llama-server

### Phase 5: Remaining Workloads

- [ ] Deploy TEI reranker Deployment
- [ ] Deploy Docling Deployment
- [ ] Deploy ComfyUI Knative Service (with SD models from local NVMe PV)
- [ ] Deploy JupyterLab Knative Service (with PVC for workspace)
- [ ] Verify all workloads functional

### Phase 6: Cleanup

- [ ] Delete GPU Workstation VM
- [ ] Delete `tofu/home/gpu_workstation.tf` and related resources
- [ ] Delete `ansible/playbooks/gpu_workstation/`
- [ ] Remove GPU Workstation from `config/vm.yml`, Caddy, monitoring config
- [ ] Update GPU alert rules (`nvidia_smi_*` → `dcgm_*`)
- [ ] Update `docs/ai-ml.md` to reflect new architecture

## Key Decisions

| Decision | Choice | Rationale |
| -------- | ------ | --------- |
| NVIDIA in Talos | System extensions (Image Factory) | Immutability-aligned, no GPU Operator overhead |
| LLM serving | llama-swap | Replaces Ollama + vLLM, per-model tuning, direct GGUF |
| GPU sharing | Time-slicing | Scheduling mechanism only, 96GB VRAM makes contention moot |
| Model storage | Local NVMe PV | Fast model loading, GPU workloads pinned to neo anyway |
| GPU metrics | dcgm-exporter | K8s-native, feeds into existing OTEL pipeline |
| Rebuild scope | talos-neo only | Other nodes untouched, etcd quorum maintained |

## Related Documents

- `kubernetes.md` — K8s cluster architecture and workload migration plan
- `workflow-orchestration.md` — GPU batch job patterns (Kestra + ComfyUI)
- `../ai-ml.md` — Current AI/ML architecture (to be updated)
- `../monitoring.md` — Observability architecture (GPU metrics)
- `../hosts.md` — Neo hardware specs
