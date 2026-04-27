# GPU Kubernetes Migration

**Status:** Phase 6 cleanup is applied in Git — the GPU Workstation VM, its Ansible playbooks, and Tofu module are removed; GPU workloads run on **talos-neo** in Kubernetes.

## Goal

1. **Kill the GPU Workstation VM** — Delete the Fedora VM, its Ansible playbooks, and its Tofu config
2. **Replace Ollama + vLLM with llama-swap** — Single service managing llama-server (llama.cpp) processes with per-model profiles
3. **GPU in K8s** — talos-neo gets GPU passthrough, NVIDIA extensions, and all GPU workloads run as pods
4. **Kill ClearML and SwarmUI** — Not in use
5. **Enable future GPU transcoding** — Jellyfin gets native `nvidia.com/gpu` access, eliminating rffmpeg

## Current State

| Component | Details |
| --------- | ------- |
| GPU Workstation | **Removed** (Phase 6) |
| GPU | Nvidia RTX Pro 6000 — passthrough to **talos-neo** Talos VM |
| talos-neo | K8s control plane + GPU worker on Neo (see `config/vm.yml`) |
| Inference | **llama-swap** in-cluster (replaces Ollama + vLLM) |
| Management | Tofu K8s manifests under `tofu/home/kubernetes/`; LiteLLM remains on ai-tool-stack VM |

Workloads on **talos-neo** (Kubernetes):

| Workload | Runtime | GPU |
| -------- | ------- | --- |
| llama-swap | Deployment | yes |
| ComfyUI | Deployment | yes |
| Docling | Deployment | yes |
| JupyterLab | Deployment | yes |
| Speaches | Deployment | yes |
| OpenWebUI, SearXNG, Firecrawl, … | Deployments | varies |

**Removed:** SwarmUI, ClearML, Fedora gpu-workstation VM (and Caddy routes for those hostnames).

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

Metrics from **dcgm-exporter** use Prometheus names such as `DCGM_FI_DEV_GPU_TEMP`, `DCGM_FI_DEV_FB_USED`, `DCGM_FI_DEV_GPU_UTIL`, etc. (scraped via the in-cluster OTEL Collector).

Grafana alert rules in `ansible/playbooks/monitoring_stack/grafana/provisioning/alerting/rules.yml` use these DCGM metrics instead of the old `nvidia_smi_*` VM exporter series.

## Removed in Phase 6 (complete)

| Item | Path |
| ---- | ---- |
| GPU Workstation VM | `tofu/home/gpu_workstation.tf` (deleted) |
| GPU Workstation SSH key / outputs | `tofu/variables.tf`, `tofu/outputs.tf`, `tofu/home/outputs.tf` |
| Ansible playbooks | `ansible/playbooks/gpu_workstation/` (deleted) |
| VM config | `config/vm.yml` `gpu_workstation` block |
| Caddy | Direct `vm.gpu_workstation` upstreams; legacy `ollama` / ComfyUI / Docling / Jupyter → Gateway VIP; SwarmUI + ClearML blocks removed |
| Grafana VM dashboard overrides | Legend overrides that targeted `gpu-workstation` memory series |
| Docs | `docs/ai-ml.md` rewritten for K8s |

Apply **`tofu destroy` / `tofu apply`** in your environment to drop the Proxmox VM and refresh state after pulling these changes.

## Implementation Phases

### Phase 1: Talos NVIDIA Image ✅

- [x] Generate NVIDIA schematic via Image Factory API
- [x] Add `talos_nvidia_schematic` to `cloud_images.tf`
- [x] Download NVIDIA-enabled Talos ISO for Neo

### Phase 2: Rebuild talos-neo ✅

- [x] Update `config/vm.yml` — increase talos-neo cores, memory
- [x] Update `talos_cluster.tf` — add GPU passthrough conditionals, UEFI, efi_disk
- [x] Add NVIDIA machine config patch (kernel modules)
- [x] Drain talos-neo, destroy VM, `tofu apply` to recreate
- [x] Verify node rejoins cluster, GPU visible via `nvidia-smi`

### Phase 3: K8s GPU Platform ✅

- [x] Deploy NVIDIA device plugin DaemonSet
- [x] Configure time-slicing (8 replicas)
- [x] Deploy dcgm-exporter DaemonSet
- [x] Verify OTEL Collector scrapes GPU metrics
- [x] Local NVMe PV for model weights — `tofu/home/kubernetes/gpu_model_storage.tf`

### Phase 4: llama-swap + LiteLLM ✅

- [x] Deploy llama-swap Deployment with GPU + Ceph PVC (`llama_swap.tf`)
- [x] Configure Qwen3.5-27B Q8_0 + Qwen3.5-9B Q8_0 model profiles
- [x] Configure model variants via `setParamsByID` filters (`:code`, `:think`)
- [x] Expose via Gateway API (`llama-swap.apps.home.shdr.ch`)
- [x] Update LiteLLM config — all `aether/*` models → llama-swap credential
- [x] Remove all Ollama models and credentials from LiteLLM
- [x] Verify inference end-to-end (OpenWebUI → LiteLLM → llama-swap → llama-server)

### Phase 5: Remaining Workloads

- [x] Docling, ComfyUI, Jupyter — Terraform Deployments (`docling.tf`, `comfyui.tf`, `jupyter.tf`)
- [x] Reranker / embeddings — via llama-swap + LiteLLM (no separate TEI Deployment)
- [ ] Optional: Knative scale-to-zero migration for ComfyUI/Jupyter (currently always-on Deployments)
- [ ] Verify end-to-end for your model set

### Phase 6: Cleanup

- [x] Delete GPU Workstation VM (remove from Tofu; run apply/destroy in Proxmox)
- [x] Delete `tofu/home/gpu_workstation.tf` and related resources
- [x] Delete `ansible/playbooks/gpu_workstation/`
- [x] Remove GPU Workstation from `config/vm.yml`, Caddy, inventory, Taskfile
- [x] Update GPU alert rules to DCGM (`DCGM_FI_DEV_*` in Grafana provisioning)
- [x] Update `docs/ai-ml.md`

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
- `../ai-ml.md` — Current AI/ML architecture (Kubernetes + ai-tool-stack)
- `../monitoring.md` — Observability architecture (GPU metrics)
- `../hosts.md` — Neo hardware specs
