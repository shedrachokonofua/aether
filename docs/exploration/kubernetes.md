# Kubernetes Exploration

Exploration of a 3-node Talos Kubernetes cluster as a modern application platform.

## Goal

Deploy Kubernetes not for high availability (already solved via Proxmox HA + Ceph), but to unlock:

1. **Scale to zero** — Idle apps consume zero resources
2. **Multi-tenancy** — Safe, isolated self-service for peers
3. **FaaS / Eventing** — Serverless functions, event-driven patterns
4. **Service mesh** — Auto mTLS, identity-based authorization
5. **Platform primitives** — CRDs, operators, declarative everything
6. **Density** — Fewer VMs, fewer agents, better resource utilization

## Current State

| Capability               | Current Solution             | Gap                               |
| ------------------------ | ---------------------------- | --------------------------------- |
| HA                       | Proxmox HA + Ceph            | ✅ Solved                         |
| GitOps                   | GitLab CI + Ansible          | ✅ Solved                         |
| Identity                 | step-ca + Keycloak + OpenBao | ✅ Solved                         |
| Scale to zero            | ❌ VMs always on             | Workloads use resources when idle |
| Multi-tenancy            | ❌ Manual, no isolation      | Can't safely give peers access    |
| FaaS                     | ❌ N/A                       | No serverless functions           |
| Service-to-service authz | ❌ Trust network             | No identity-based policies        |

## Proposed Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           FOUNDATION (VMs - Proxmox HA)                          │
│                                                                                  │
│   Oracle:              Smith:              Niobe:                                │
│   ├── VyOS Router      ├── NFS Server      ├── Monitoring Stack                 │
│   ├── Gateway Stack    ├── PBS             │   (Prometheus, Grafana,            │
│   ├── Keycloak         ├── SeaweedFS       │    Loki, OTEL Gateway)             │
│   ├── step-ca          ├── Gaming Server   ├── Cockpit                          │
│   ├── OpenBao          └── Blockchain      └── Dev Workstation                  │
│   ├── AdGuard                                                                    │
│   └── IDS Stack        Neo:                Trinity:                              │
│                        └── GPU Workstation ├── Desktop VM (iGPU, Sunshine)      │
│                           (Ollama,ComfyUI, └── IoT Stack (USB)                  │
│                            rffmpeg)                                             │
│                                                                                  │
│   ────────────────────── Identity + Observability Layer ─────────────────────   │
└───────────────────────────────────────────────────────────────────────────┬─────┘
                                                                            │
                                        trusts (OIDC, certs)                │
                                                                            ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          KUBERNETES (3-node Talos on Ceph)                       │
│                                                                                  │
│   Nodes:                                                                         │
│   ├── talos-1 (Trinity) — 16GB RAM, 8 vCPU, Control + Worker                    │
│   ├── talos-2 (Niobe)   — 16GB RAM, 8 vCPU, Control + Worker                    │
│   └── talos-3 (Neo)     — 16GB RAM, 8 vCPU, Control + Worker                    │
│                                                                                  │
│   Platform Components:                                                           │
│   ├── Cilium (CNI, mTLS, L7 policies, Hubble)                                   │
│   ├── Gateway API (next-gen ingress)                                            │
│   ├── Knative Serving (scale to zero)                                           │
│   ├── Knative Eventing (event-driven)                                           │
│   ├── Knative Functions (FaaS)                                                  │
│   ├── Kubero (PaaS layer — replaces Dokku + Dokploy)                            │
│   ├── OPA Gatekeeper (policy enforcement)                                       │
│   ├── Secrets Store CSI (OpenBao secrets as files)                              │
│   ├── cert-manager + step-ca issuer                                             │
│   ├── External Secrets Operator (OpenBao → k8s Secrets)                         │
│   ├── GitLab Agent (CI/CD)                                                      │
│   └── OTEL Collector DaemonSet (→ external monitoring)                          │
│                                                                                  │
│   Namespaces:                                                                    │
│   ├── infra (your infrastructure apps)                                          │
│   ├── projects (your side projects)                                             │
│   ├── peers-alice (Alice's apps, isolated)                                    │
│   ├── peers-bob (Bob's apps, isolated)                                        │
│   └── system (platform components)                                              │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## What Moves to Kubernetes

| Workload     | Current                         | K8s Resource       | Scale to Zero                  |
| ------------ | ------------------------------- | ------------------ | ------------------------------ |
| LiteLLM      | Neo (AI Tool Stack VM)          | Knative Service    | ✅                             |
| OpenWebUI    | Neo (AI Tool Stack VM)          | Knative Service    | ✅                             |
| SearXNG      | Neo (AI Tool Stack VM)          | Knative Service    | ✅                             |
| Firecrawl    | Neo (AI Tool Stack VM)          | Knative Service    | ✅                             |
| Bytebot      | Neo (AI Tool Stack VM)          | Knative Service    | ✅                             |
| GitLab       | Trinity (VM)                    | Helm (StatefulSet) | ❌ (needs to receive webhooks) |
| Synapse      | Niobe (Messaging VM)            | Helm (StatefulSet) | ❌ (needs federation)          |
| Element      | Niobe (Messaging VM)            | Knative Service    | ✅                             |
| Lute         | Smith (VM)                      | StatefulSet        | ❌                             |
| NUT Server   | Niobe (UPS VM)                  | Deployment         | ❌                             |
| Peanut       | Niobe (UPS VM)                  | Deployment         | ❌                             |
| Smallweb     | Trinity (LXC)                   | Knative Service    | ✅                             |
| Coupe apps   | Niobe (VM)                      | Knative Services   | ✅                             |
| Dokku apps   | Neo (VM)                        | Knative Services   | ✅                             |
| Dokploy apps | Trinity (VM)                    | Knative Services   | ✅                             |
| Jellyfin     | Trinity (Media Stack)           | Deployment         | ❌ (rffmpeg → GPU Workstation) |
| MediaManager | Trinity (Media Stack)           | Knative Service    | ✅                             |
| qBittorrent  | Trinity (Media Stack)           | Deployment         | ❌ (SOCKS5 → rotating-proxy)   |
| Nuclei       | (new — see network-security.md) | CronJob            | ✅ (runs weekly)               |

**VMs eliminated:** AI Tool Stack, GitLab, Messaging Stack, UPS Stack, Lute Stack, Coupe Sandbox, Dokku, Dokploy, Smallweb, Media Stack

**Note:** Lute Stack's 40GB RAM allocation is primarily for Redis vector/embedding index. In k8s, this would run as a StatefulSet with appropriately sized PVC and memory limits.

## What Stays as VMs

| Workload         | Host          | Why VM                              |
| ---------------- | ------------- | ----------------------------------- |
| VyOS Router      | Oracle        | Network infrastructure              |
| Gateway Stack    | Oracle        | Ingress to k8s, trust dependency    |
| Keycloak         | Oracle        | K8s OIDC auth depends on it         |
| step-ca          | Oracle        | K8s cert-manager depends on it      |
| OpenBao          | Oracle        | K8s External Secrets depends on it  |
| AdGuard          | Oracle        | DNS for k8s nodes                   |
| IDS Stack        | Oracle        | Span port from VyOS + Wazuh Manager |
| Monitoring Stack | Niobe         | Must alert when k8s is down         |
| Cockpit          | Niobe         | Manages Proxmox hosts               |
| Dev Workstation  | Trinity/Niobe | Better as VM for IDE                |
| GPU Workstation  | Neo           | GPU passthrough                     |
| Gaming Server    | Smith         | GPU passthrough                     |
| Desktop VM       | Trinity       | iGPU passthrough for Sunshine       |
| IoT Stack        | Niobe         | USB passthrough for Z-Wave/Thread   |
| NFS Server       | Smith         | Storage infrastructure              |
| PBS              | Smith         | Backup infrastructure               |
| SeaweedFS        | Smith         | S3 storage infrastructure           |
| Blockchain Stack | Smith         | Always-on, ~1TB storage             |

## Platform Components

### Cilium (Networking + Service Mesh)

Replaces kube-proxy and provides:

| Feature             | Benefit                                          |
| ------------------- | ------------------------------------------------ |
| eBPF-based CNI      | High performance, kernel-level                   |
| Automatic mTLS      | All pod-to-pod traffic encrypted, no app changes |
| L7 Network Policies | HTTP path/method-aware rules                     |
| AuthorizationPolicy | Identity-based "who can talk to who"             |
| Hubble              | Real-time network flow visualization             |

**No app changes needed** — Cilium handles mTLS transparently. Apps like OpenWebUI and LiteLLM think they're speaking plain HTTP while the wire is encrypted.

### Gateway API (Next-Gen Ingress)

Replaces legacy Ingress with more powerful routing:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: openwebui
spec:
  parentRefs:
    - name: main-gateway
  hostnames:
    - openwebui.home.shdr.ch
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api
      backendRefs:
        - name: openwebui-api
          port: 8080
      filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            add:
              - name: X-Request-ID
                value: "%REQ_ID%"
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: openwebui-frontend
          port: 3000
```

Traffic splitting, header manipulation, redirects — all declarative.

### Knative (Serverless)

| Component | Purpose                                        |
| --------- | ---------------------------------------------- |
| Serving   | Scale-to-zero HTTP services (default behavior) |
| Eventing  | Event routing, pub/sub, triggers               |
| Functions | FaaS via `func` CLI                            |

**Scale to zero is default** — deploy a Knative Service, it scales to zero after 60s idle. No config required.

### Kubero (PaaS Layer)

Heroku/Vercel-style PaaS that replaces both Dokku and Dokploy:

| Feature              | Dokku | Dokploy | Kubero              |
| -------------------- | ----- | ------- | ------------------- |
| Git push deploy      | ✅    | ✅      | ✅                  |
| Web UI               | ❌    | ✅      | ✅                  |
| Buildpacks           | ✅    | ❌      | ✅                  |
| Scale to zero        | ❌    | ❌      | ✅ (KEDA)           |
| Preview environments | ❌    | ❌      | ✅                  |
| Add-ons (PG, Redis)  | ✅    | ✅      | ✅                  |
| Docker Compose       | ❌    | ✅      | ⚠️ (templates/Helm) |

```bash
helm repo add kubero https://kubero-dev.github.io/kubero/
helm install kubero kubero/kubero
```

**Peer workflow:**

1. Login to Kubero UI (Keycloak SSO)
2. Create app, connect Git repo
3. Select buildpack or Dockerfile
4. Deploy → scales to zero when idle

**Migration approach:**

- Dokku apps → Kubero (git push, buildpacks)
- Dokploy apps with templates → Kubero templates
- Complex Docker Compose apps → Helm charts or case-by-case

### OPA Gatekeeper (Policy Enforcement)

Enforce rules at deploy time using Rego:

```yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sRequiredLabels
metadata:
  name: require-owner-label
spec:
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
  parameters:
    labels: ["owner"]
```

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8srequiredlabels
spec:
  crd:
    spec:
      names:
        kind: K8sRequiredLabels
      validation:
        openAPIV3Schema:
          properties:
            labels:
              type: array
              items:
                type: string
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8srequiredlabels
        violation[{"msg": msg}] {
          provided := {label | input.review.object.metadata.labels[label]}
          required := {label | label := input.parameters.labels[_]}
          missing := required - provided
          count(missing) > 0
          msg := sprintf("Missing required labels: %v", [missing])
        }
```

### Secrets Store CSI (OpenBao Integration)

Mount OpenBao secrets directly as files — never stored in etcd:

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: app-secrets
spec:
  provider: vault
  parameters:
    vaultAddress: https://bao.home.shdr.ch
    roleName: k8s-workloads
    objects: |
      - objectName: "api-key"
        secretPath: "secret/data/myapp"
        secretKey: "key"
```

Pod sees `/mnt/secrets/api-key` — fetched live from OpenBao, never in k8s etcd.

## Multi-Tenancy Model

### GitLab Groups → K8s Namespaces

```yaml
# .gitlab/agents/k8s-agent/config.yaml
ci_access:
  groups:
    - id: infra
      default_namespace: infra
    - id: projects
      default_namespace: projects
    - id: peers/alice
      default_namespace: peers-alice
    - id: peers/bob
      default_namespace: peers-bob
```

### Per-Namespace Isolation

```yaml
# ResourceQuota
apiVersion: v1
kind: ResourceQuota
metadata:
  name: quota
  namespace: peers-alice
spec:
  hard:
    requests.memory: 4Gi
    limits.memory: 8Gi
    pods: "20"

---
# Cilium Network Policy
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: isolate-namespace
  namespace: peers-alice
spec:
  endpointSelector: {}
  ingress:
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: peers-alice
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: ingress
```

### Peer Access via Keycloak OIDC

```yaml
# K8s API server config (Talos)
cluster:
  apiServer:
    extraArgs:
      oidc-issuer-url: https://auth.shdr.ch/realms/aether
      oidc-client-id: kubernetes
      oidc-username-claim: preferred_username
      oidc-groups-claim: groups
```

Peers run `kubectl` → browser opens → login via Keycloak → authorized to their namespace only.

## Observability (Hybrid)

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                        Monitoring Stack VM (Niobe)                               │
│                                                                                  │
│   OTEL Collector (Gateway) ◀──── OTLP ──── K8s OTEL Collectors                  │
│         │                                                                        │
│         ├──▶ Prometheus (metrics)                                               │
│         ├──▶ Loki (logs)                                                        │
│         └──▶ Tempo (traces)                                                     │
│                │                                                                 │
│                └──▶ Grafana                                                     │
└─────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────┐
│                              K8s Cluster                                         │
│                                                                                  │
│   OTEL Collector (DaemonSet)                                                    │
│   ├── kubeletstats receiver (node metrics)                                      │
│   ├── prometheus receiver (pod scraping)                                        │
│   ├── filelog receiver (container logs)                                         │
│   └── otlp receiver (traces from apps)                                          │
│         │                                                                        │
│         └──▶ OTLP export to Monitoring Stack VM                                 │
│                                                                                  │
│   Cilium Hubble (network observability)                                         │
│   └──▶ Hubble UI (service topology, flows)                                      │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Monitoring stays outside k8s** — can alert when k8s is down.

## CI/CD Integration

### GitLab Agent

```bash
# Install agent in k8s
helm install gitlab-agent gitlab/gitlab-agent \
  --namespace gitlab-agent \
  --create-namespace \
  --set config.token=<token> \
  --set config.kasAddress=wss://gitlab.home.shdr.ch/-/kubernetes-agent/
```

### Peer Workflow

```yaml
# Peer's .gitlab-ci.yml (using shared template)
include:
  - project: "infra/ci-templates"
    file: "knative-deploy.yml"
```

```yaml
# Or explicit deploy
deploy:
  script:
    - kn service apply $CI_PROJECT_NAME --image $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA
```

Push → build → deploy → scales to zero when idle.

### Knative Functions

```bash
# Create function
func create -l python my-function

# Deploy (builds, pushes, creates Knative Service)
func deploy --registry ghcr.io/alice

# Done — scales to zero automatically
```

## What's NOT Included

| Tool              | Why Not                                   |
| ----------------- | ----------------------------------------- |
| ArgoCD            | GitLab CI + `kubectl apply` is sufficient |
| Crossplane        | Tofu handles AWS/Cloudflare fine          |
| GPU Operator      | GPU workloads stay on VM (passthrough)    |
| Prometheus in k8s | Monitoring stays external                 |
| Dokku             | Replaced by Kubero                        |
| Dokploy           | Replaced by Kubero + Helm charts          |

## Resource Summary

### K8s Cluster

| Resource   | Allocation              |
| ---------- | ----------------------- |
| Nodes      | 3 (Trinity, Niobe, Neo) |
| Total RAM  | 48GB (16 + 16 + 16)     |
| Total vCPU | 24 (8 + 8 + 8)          |
| Storage    | Ceph RBD                |

### VMs Eliminated

| VM              | RAM Freed |
| --------------- | --------- |
| AI Tool Stack   | 8GB       |
| GitLab          | 8GB       |
| Messaging Stack | 2GB       |
| UPS Stack       | 2GB       |
| Lute Stack      | 40GB      |
| Coupe Sandbox   | 4GB       |
| Dokku           | 8GB       |
| Dokploy         | 16GB      |
| Smallweb        | 1GB       |
| Media Stack     | 4GB       |
| **Total**       | **~93GB** |

## Implementation Phases

### Phase 0: Prerequisites

- [ ] Complete Proxmox HA (ZFS replication)
- [ ] Deploy Ceph distributed storage
- [ ] Verify 10Gbps connectivity

### Phase 1: Cluster Bootstrap

- [ ] Provision 3 Talos VMs via Tofu
- [ ] Bootstrap Talos cluster
- [ ] Install Cilium CNI
- [ ] Verify cluster health

### Phase 2: Platform Components

- [ ] Install Gateway API CRDs
- [ ] Install Knative Serving + Kourier
- [ ] Install Knative Eventing
- [ ] Install Kubero (PaaS layer)
- [ ] Install OPA Gatekeeper
- [ ] Install Secrets Store CSI + Vault provider
- [ ] Install cert-manager + step-ca ClusterIssuer
- [ ] Install External Secrets Operator

### Phase 3: Observability + Security Scanning

- [ ] Deploy OTEL Collector DaemonSet
- [ ] Configure export to Monitoring Stack
- [ ] Enable Cilium Hubble
- [ ] Create k8s dashboards in Grafana
- [ ] Deploy Nuclei CronJob (weekly vulnerability scans, see `network-security.md`)

### Phase 4: GitLab Integration

- [ ] Register GitLab Agent
- [ ] Configure agent for group → namespace mapping
- [ ] Create CI templates for Knative deploys
- [ ] Test deploy from GitLab repo

### Phase 5: Workload Migration

- [ ] Migrate AI Tool Stack (LiteLLM, OpenWebUI, etc.)
- [ ] Migrate Messaging Stack
- [ ] Migrate Lute Stack
- [ ] Migrate Media Stack (rffmpeg → GPU Workstation for transcoding)
- [ ] Migrate Dokku/Dokploy apps
- [ ] Delete old VMs

### Phase 6: Multi-Tenancy

- [ ] Create peer namespaces
- [ ] Configure ResourceQuotas
- [ ] Configure NetworkPolicies
- [ ] Add Keycloak OIDC to k8s API
- [ ] Create peer Keycloak groups
- [ ] Test peer kubectl access

## Key Decisions

| Decision   | Choice                         | Rationale                                                         |
| ---------- | ------------------------------ | ----------------------------------------------------------------- |
| OS         | Talos Linux                    | Immutable, API-managed, secure                                    |
| CNI        | Cilium                         | mTLS, L7 policies, Hubble                                         |
| Ingress    | Gateway API + Caddy (external) | Gateway API is the new standard, keep Caddy as single entry point |
| PaaS       | Kubero                         | Replaces Dokku + Dokploy, git-push deploys, UI, scale-to-zero     |
| GitOps     | GitLab CI + kubectl            | Already have GitLab, no need for ArgoCD                           |
| Secrets    | Secrets Store CSI              | Secrets never in etcd                                             |
| Policy     | OPA Gatekeeper                 | Rego is powerful, industry standard                               |
| Monitoring | External (Niobe VM)            | Must work when k8s is down                                        |
| Identity   | Keycloak OIDC                  | Already have it, native k8s support                               |

## Value Summary

| Capability              | Before                        | After                             |
| ----------------------- | ----------------------------- | --------------------------------- |
| Idle app resources      | ~89GB RAM always used         | ~0GB (scale to zero)              |
| Peer access             | Manual, no isolation          | Self-service, isolated namespaces |
| Service-to-service auth | Trust network                 | mTLS + AuthorizationPolicy        |
| Functions               | N/A                           | Knative Functions                 |
| Event-driven            | N/A                           | Knative Eventing                  |
| Policy enforcement      | Manual review                 | OPA Gatekeeper (automated)        |
| Secrets in etcd         | Yes (External Secrets)        | No (CSI mount)                    |
| Agents per workload     | OTEL + Wazuh + osquery per VM | DaemonSets (3 total)              |

## Status

**Exploration complete.** Ready to implement after Ceph deployment.

## Related Documents

- `proxmox-ha.md` — Prerequisite HA setup
- `ceph.md` — Prerequisite distributed storage
- `nixos.md` — NixOS for foundational VMs (complementary)
- `desktop-vm.md` — Desktop VM using iGPU freed from Media Stack
- `network-security.md` — IDS Stack (Suricata + Wazuh on VM, Nuclei on K8s)
- `../trust-model.md` — Identity architecture (k8s integrates with this)
- `../monitoring.md` — Observability architecture (hybrid with k8s)
