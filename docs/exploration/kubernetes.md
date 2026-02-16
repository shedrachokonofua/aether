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
7. **Infrastructure self-service** — S3, databases, auth clients via YAML

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
| Infrastructure vending   | ❌ Admin edits Tofu          | No self-service for S3/DB/auth    |

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
│   ├── talos-trinity — 16GB RAM, 8 vCPU, Control + Worker, 10.0.3.16            │
│   ├── talos-neo     — 16GB RAM, 8 vCPU, Control + Worker, 10.0.3.17            │
│   └── talos-niobe   — 16GB RAM, 8 vCPU, Control + Worker, 10.0.3.18            │
│                                                                                  │
│   Load Balancer VIP: 10.0.3.19 (Cilium L2, HA failover)                         │
│                                                                                  │
│   Platform Components:                                                           │
│   ├── Cilium (CNI, mTLS, L7 policies, Hubble)                                   │
│   ├── Gateway API (next-gen ingress)                                            │
│   ├── Knative Serving (scale to zero)                                           │
│   ├── Knative Eventing (event-driven)                                           │
│   ├── Knative Functions (FaaS)                                                  │
│   ├── Crossplane (infrastructure self-service)                                  │
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
| NUT Server   | Niobe (UPS VM)                  | Deployment         | ❌                             |
| Peanut       | Niobe (UPS VM)                  | Deployment         | ❌                             |
| Smallweb     | Trinity (LXC)                   | **Decommission**   | N/A (move to dev workstation)  |
| Coupe apps   | Niobe (VM)                      | Knative Services   | ✅                             |
| Dokku apps   | Neo (VM)                        | Knative Services   | ✅                             |
| Dokploy apps | Trinity (VM)                    | Knative Services   | ✅                             |
| Jellyfin     | Trinity (Media Stack)           | Deployment         | ❌ (rffmpeg → GPU Workstation) |
| MediaManager | Trinity (Media Stack)           | Knative Service    | ✅                             |
| qBittorrent  | Trinity (Media Stack)           | Deployment         | ❌ (SOCKS5 → rotating-proxy)   |
| Nuclei       | (new — see network-security.md) | CronJob            | ✅ (runs weekly)               |

**VMs eliminated:** AI Tool Stack, GitLab, Messaging Stack, UPS Stack, Coupe Sandbox, Dokku, Dokploy, Media Stack

**Notes:**

- Smallweb decommissioned (move to folder on dev workstation)

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

### Cilium L2 Load Balancing

Single cluster entry point via L2 announcements—no BGP required:

| Component     | IP        | Purpose                                   |
| ------------- | --------- | ----------------------------------------- |
| talos-trinity | 10.0.3.16 | Node                                      |
| talos-neo     | 10.0.3.17 | Node                                      |
| talos-niobe   | 10.0.3.18 | Node                                      |
| VIP           | 10.0.3.19 | LoadBalancer services (HA, auto-failover) |

```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: cluster-ingress
spec:
  interfaces: [eth0]
  loadBalancerIPs: true

---
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: ingress-pool
spec:
  blocks:
    - start: 10.0.3.19
      stop: 10.0.3.19
```

**VyOS sees 4 IPs** on VLAN 3 (3 nodes + 1 VIP). Pod network (10.244.0.0/16) is invisible—encapsulated in node-to-node VXLAN/Geneve traffic.

**HA failover**: If the node holding the VIP dies, another node sends a gratuitous ARP to claim it. Failover time ~2-5 seconds.

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
    - openwebui.apps.home.shdr.ch
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

### External Traffic Flow (Caddy → K8s)

K8s services use `*.apps.home.shdr.ch` subdomain for clean separation from VM-based services:

| Domain                | Target              | Services                                 |
| --------------------- | ------------------- | ---------------------------------------- |
| `*.home.shdr.ch`      | Gateway Stack (VMs) | Keycloak, step-ca, OpenBao, Grafana      |
| `*.apps.home.shdr.ch` | K8s VIP (10.0.3.60) | OpenWebUI, LiteLLM, GitLab, Knative apps |

```
Caddy (Gateway Stack VM)
    │
    ├── *.home.shdr.ch → existing VM backends
    │
    └── *.apps.home.shdr.ch → reverse_proxy 10.0.3.19
                                    │
                                    ▼
                          Cilium VIP (L2 announced, HA)
                                    │
                                    ▼
                          Gateway API (main-gateway)
                                    │
                                    ├── openwebui.apps.home.shdr.ch → Knative Service
                                    ├── litellm.apps.home.shdr.ch → Knative Service
                                    ├── gitlab.apps.home.shdr.ch → StatefulSet
                                    └── *.apps.home.shdr.ch → 404
```

**Adding k8s services**: Create HTTPRoute in cluster, done. No Caddy changes needed.

**DNS**: Add `*.apps.home.shdr.ch → Gateway IP` rewrite in AdGuard (Caddy handles routing to k8s VIP).

### Knative (Serverless)

| Component | Purpose                                        |
| --------- | ---------------------------------------------- |
| Serving   | Scale-to-zero HTTP services (default behavior) |
| Eventing  | Event routing, pub/sub, triggers               |
| Functions | FaaS via `func` CLI                            |

**Scale to zero is default** — deploy a Knative Service, it scales to zero after 60s idle. No config required.

**Note:** Knative traditionally bundles Kourier (lightweight Envoy-based ingress), but Cilium's Gateway API implementation handles ingress routing, making Kourier redundant.

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

### Crossplane (Infrastructure Self-Service)

Turns Kubernetes into a universal control plane for external infrastructure. Apps request resources via YAML, Crossplane provisions them.

| Feature           | Benefit                                           |
| ----------------- | ------------------------------------------------- |
| Managed Resources | S3 buckets, databases, DNS as k8s objects         |
| Compositions      | Abstract complex stacks into simple claims        |
| Self-healing      | Drift detection, automatic reconciliation         |
| GitOps-native     | Infrastructure defined alongside app code         |
| No static secrets | Credentials flow through k8s Secrets, not CI vars |

**Why Crossplane over Tofu for app-layer resources:**

| Tofu (Base Layer)            | Crossplane (Service Layer)        |
| ---------------------------- | --------------------------------- |
| Cluster, VMs, Ceph, Networks | S3 buckets, DBs, Keycloak clients |
| Run manually or in CI        | Runs continuously in k8s          |
| One-shot apply               | Reconciliation loop (self-heal)   |
| Platform engineer            | Developer self-service            |

**Providers:**

| Provider            | Manages                            |
| ------------------- | ---------------------------------- |
| provider-aws-s3     | Ceph RGW (S3-compatible), real AWS |
| provider-aws-iam    | Ceph RGW IAM roles/policies        |
| provider-sql        | PostgreSQL/MySQL databases         |
| provider-keycloak   | OIDC clients, realms, users        |
| provider-cloudflare | DNS records                        |
| provider-kubernetes | K8s resources (for compositions)   |

**Example: Static Site with Auth + DB**

Developer commits this to their app repo:

```yaml
# infra/bucket.yaml
apiVersion: s3.aws.upbound.io/v1beta1
kind: Bucket
metadata:
  name: my-portfolio-assets
spec:
  forProvider:
    acl: public-read
  providerConfigRef:
    name: ceph-rgw

---
# infra/keycloak-client.yaml
apiVersion: keycloak.crossplane.io/v1alpha1
kind: Client
metadata:
  name: my-portfolio-auth
spec:
  forProvider:
    clientId: portfolio
    realmId: aether
    publicClient: true
    standardFlowEnabled: true
    rootUrl: "https://portfolio.shdr.ch"
    validRedirectUris:
      - "https://portfolio.shdr.ch/*"
  providerConfigRef:
    name: keycloak

---
# infra/database.yaml
apiVersion: postgresql.sql.crossplane.io/v1alpha1
kind: Database
metadata:
  name: portfolio-db
spec:
  forProvider:
    owner: portfolio
  providerConfigRef:
    name: surrealdb
  writeConnectionSecretToRef:
    name: portfolio-db-creds
    namespace: projects
```

**GitLab CI deploys it:**

```yaml
deploy-infra:
  script:
    - kubectl apply -f infra/
    - kubectl wait --for=condition=Ready bucket/my-portfolio-assets
```

**Result:** S3 bucket, Keycloak client, and database provisioned. Connection details in k8s Secrets. No admin intervention, no static credentials in CI.

**Trust Model Integration:**

GitLab CI uses OIDC to authenticate to Ceph RGW for S3 uploads — Crossplane provisions the IAM role, GitLab CI assumes it via `AssumeRoleWithWebIdentity`. Zero static secrets.

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              Trust Flow (No Static Secrets)                      │
│                                                                                  │
│   Developer                                                                      │
│       │                                                                          │
│       └── commits infra/*.yaml                                                  │
│                │                                                                 │
│                ▼                                                                 │
│   GitLab CI (kubectl apply)                                                     │
│       │                                                                          │
│       └── Crossplane provisions:                                                │
│               ├── S3 Bucket (Ceph RGW)                                          │
│               ├── IAM Role (trusts GitLab OIDC)                                 │
│               └── Keycloak Client (public, PKCE)                                │
│                                                                                  │
│   GitLab CI (next job)                                                          │
│       │                                                                          │
│       ├── Gets OIDC token from GitLab                                           │
│       ├── Assumes IAM Role via STS (AssumeRoleWithWebIdentity)                  │
│       └── Uploads to S3 with temp credentials                                   │
│                                                                                  │
│   Static App (browser)                                                          │
│       │                                                                          │
│       ├── Loads from S3 (public read)                                           │
│       └── Authenticates via Keycloak (PKCE)                                     │
└─────────────────────────────────────────────────────────────────────────────────┘
```

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
| GPU Operator      | GPU workloads stay on VM (passthrough)    |
| Prometheus in k8s | Monitoring stays external                 |
| Dokku             | Replaced by Knative Services              |
| Dokploy           | Replaced by Knative Services + Helm       |

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
| UPS Stack       | 1GB       |
| Coupe Sandbox   | 4GB       |
| Dokku           | 8GB       |
| Dokploy         | 16GB      |
| Media Stack     | 4GB       |
| **Total**       | **~51GB** |

**Notes:**

- Smallweb decommissioned (folder on dev workstation, not k8s)

## Talos Provisioning

### Why Talos

Talos Linux is an immutable, API-managed OS designed specifically for Kubernetes:

- **No SSH** — All management via `talosctl` API
- **No users** — No accounts to manage or compromise
- **No shell** — Minimal attack surface
- **Immutable** — OS is read-only, upgrades are atomic
- **API-driven** — Config applied via API, not cloud-init scripts

### Image Format

Talos doesn't provide traditional qcow2 cloud images. Instead, use the **nocloud** image from [Image Factory](https://factory.talos.dev/):

```hcl
# tofu/home/cloud_images.tf
resource "proxmox_virtual_environment_download_file" "talos_nocloud" {
  content_type = "iso"
  datastore_id = "cephfs"
  node_name    = "smith"
  url          = "https://factory.talos.dev/image/${local.talos_schematic}/${local.talos_version}/nocloud-amd64.raw.xz"
  file_name    = "talos-${local.talos_version}-nocloud.raw.img"
}

locals {
  talos_version   = "v1.11.0"
  # Default schematic, or custom with qemu-guest-agent extension
  talos_schematic = "376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba"
}
```

The nocloud image supports the same cloud-init disk pattern used for Fedora VMs — Talos reads `user-data` as its machine config.

### VM Configuration

Add Talos nodes to `config/vm.yml`:

```yaml
# config/vm.yml
talos_trinity:
  id: 1030
  name: "talos-trinity"
  node: "trinity"
  cores: 8
  memory: 16384
  disk_gb: 100
  ip: "10.0.3.16"
  gateway: "10.0.3.1"

talos_neo:
  id: 1031
  name: "talos-neo"
  node: "neo"
  cores: 8
  memory: 16384
  disk_gb: 100
  ip: "10.0.3.17"
  gateway: "10.0.3.1"

talos_niobe:
  id: 1032
  name: "talos-niobe"
  node: "niobe"
  cores: 8
  memory: 16384
  disk_gb: 100
  ip: "10.0.3.18"
  gateway: "10.0.3.1"
```

Static IPs are configured directly in the Talos machine config (via cloud-init disk), so no DHCP reservations needed.

### Tofu Implementation

Create `tofu/home/talos_cluster.tf`:

```hcl
terraform {
  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.7"
    }
  }
}

locals {
  talos_nodes = { for k, v in local.vm : k => v if startswith(k, "talos_") }
}

# Generate cluster secrets (certs, keys, tokens)
resource "talos_machine_secrets" "this" {}

# Generate per-node machine configuration with static IP
data "talos_machine_configuration" "node" {
  for_each = local.talos_nodes

  cluster_name     = "k8s"
  cluster_endpoint = "https://${local.vm.talos_trinity.ip}:6443"
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets

  config_patches = [
    yamlencode({
      cluster = {
        allowSchedulingOnControlPlanes = true
      }
      machine = {
        network = {
          hostname = each.value.name
          interfaces = [{
            interface = "eth0"
            addresses = ["${each.value.ip}/24"]
            routes = [{
              network = "0.0.0.0/0"
              gateway = each.value.gateway
            }]
          }]
        }
      }
    })
  ]
}

# Upload machine config as snippet (same pattern as vm_user_cloudinit)
resource "proxmox_virtual_environment_file" "talos_config" {
  for_each = local.talos_nodes

  content_type = "snippets"
  datastore_id = "cephfs"
  node_name    = "smith"

  source_raw {
    file_name = "${each.value.name}-talos.yml"
    data      = data.talos_machine_configuration.node[each.key].machine_configuration
  }
}

# Create VMs
resource "proxmox_virtual_environment_vm" "talos" {
  for_each = local.talos_nodes

  vm_id       = each.value.id
  name        = each.value.name
  node_name   = each.value.node
  description = "Talos Kubernetes Node"

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 3
  }

  disk {
    datastore_id = "ceph-vm-disks"
    file_id      = proxmox_virtual_environment_download_file.talos_nocloud.id
    size         = each.value.disk_gb
    interface    = "virtio0"
  }

  # Cloud-init disk with Talos machine config (includes static IP)
  initialization {
    datastore_id      = "ceph-vm-disks"
    user_data_file_id = proxmox_virtual_environment_file.talos_config[each.key].id
  }

  lifecycle {
    ignore_changes = [disk[0].file_id, initialization[0].user_data_file_id]
  }
}

# Bootstrap cluster (run once on first control plane)
resource "talos_machine_bootstrap" "this" {
  depends_on = [proxmox_virtual_environment_vm.talos]

  client_configuration = talos_machine_secrets.this.client_configuration
  endpoint             = local.vm.talos_trinity.ip
  node                 = local.vm.talos_trinity.ip
}

# Retrieve kubeconfig
data "talos_cluster_kubeconfig" "this" {
  depends_on = [talos_machine_bootstrap.this]

  client_configuration = talos_machine_secrets.this.client_configuration
  endpoint             = local.vm.talos_trinity.ip
  node                 = local.vm.talos_trinity.ip
}

# HA resource
resource "proxmox_virtual_environment_haresource" "talos" {
  for_each = proxmox_virtual_environment_vm.talos

  resource_id  = "vm:${each.value.vm_id}"
  state        = "started"
  group        = proxmox_virtual_environment_hagroup.ceph_workloads.group
  max_restart  = 3
  max_relocate = 2
}
```

### Provisioning Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ 1. tofu apply                                                               │
│    ├── Downloads Talos nocloud image                                        │
│    ├── Generates machine secrets (talos_machine_secrets)                    │
│    ├── Generates per-node configs with static IPs (talos_machine_config)    │
│    ├── Uploads configs as Proxmox snippets                                  │
│    ├── Creates VMs with cloud-init disk referencing snippets                │
│    └── VMs boot → read config (incl. static IP) → configure themselves     │
│                                                                             │
│ 2. talos_machine_bootstrap runs                                             │
│    └── First control plane bootstraps etcd + k8s                           │
│                                                                             │
│ 3. Other nodes join automatically                                           │
│    └── Cluster is ready                                                     │
│                                                                             │
│ 4. talos_cluster_kubeconfig retrieves kubeconfig                           │
│    └── kubectl works                                                        │
└─────────────────────────────────────────────────────────────────────────────┘
```

No DHCP required — static IPs are baked into the Talos machine config on the cloud-init disk.

### Why Combined Control Plane + Worker

For a 3-node homelab cluster:

| Separate CP/Worker        | Combined                |
| ------------------------- | ----------------------- |
| 3 CP + 1+ worker = 4+ VMs | 3 VMs total             |
| CP nodes sit idle         | All nodes run workloads |
| More resource overhead    | Better utilization      |
| Production pattern        | Homelab pattern         |

With `allowSchedulingOnControlPlanes: true`, all 3 nodes participate in both etcd quorum and workload scheduling. Only separate if you have strict isolation requirements or massive scale.

### Upgrades

After initial deployment, upgrades are API-driven:

```bash
# Upgrade Talos OS
talosctl upgrade --nodes 10.0.3.16 \
  --image factory.talos.dev/installer/${SCHEMATIC}:v1.12.0

# Upgrade Kubernetes
talosctl upgrade-k8s --nodes 10.0.3.16 --to 1.32.0
```

No SSH, no Ansible, no package managers. Just API calls.

## Implementation Phases

### Phase 0: Prerequisites

- [x] Complete Proxmox HA (ZFS replication)
- [x] Deploy Ceph distributed storage
- [x] Verify 10Gbps connectivity

### Phase 1: Cluster Bootstrap

- [x] Add Talos entries to `config/vm.yml`
- [x] Create `tofu/home/talos_cluster.tf`
- [x] Run `tofu apply` to provision cluster
- [x] Verify cluster health with `talosctl` and `kubectl`
- [x] Install Cilium CNI with L2 announcements enabled
- [x] Configure CiliumLoadBalancerIPPool (10.0.3.19)

### Phase 2: Platform Components

- [x] Install Gateway API CRDs
- [x] Install Knative Serving (uses Cilium Gateway API for ingress)
- [ ] Install Knative Eventing
- [x] Install Crossplane (Helm chart)
- [ ] Install Crossplane Providers (AWS/S3, Keycloak, SQL)
- [ ] Configure ProviderConfigs (Ceph RGW, Keycloak, SurrealDB)
- [ ] Install OPA Gatekeeper
- [ ] Install Secrets Store CSI + Vault provider
- [ ] Install cert-manager + step-ca ClusterIssuer
- [ ] Install External Secrets Operator

### Phase 3: Observability + Security Scanning

- [x] Deploy OTEL Collector DaemonSet
- [x] Configure export to Monitoring Stack
- [x] Deploy OTEL Collector Deployment (cluster metrics, events)
- [x] Enable Cilium Hubble
- [x] Expose Hubble UI via Gateway API
- [ ] Create k8s dashboards in Grafana
- [ ] Deploy Nuclei CronJob (weekly vulnerability scans, see `network-security.md`)

### Phase 4: GitLab Integration

- [x] Register GitLab Agent
- [ ] Configure agent for group → namespace mapping
- [ ] Create CI templates for Knative deploys
- [ ] Test deploy from GitLab repo

### Phase 5: Workload Migration

Migration order (low risk → high complexity):

1. [ ] **UPS Stack** — Simple, stateless UI (Peanut), validates platform
2. [ ] **Dokku apps** — Move to Knative Services
3. [ ] **Dokploy apps** — Move to Knative Services or Helm charts
4. [ ] **AI Tool Stack** — LiteLLM, OpenWebUI, SearXNG, Firecrawl, Bytebot (scale-to-zero)
5. [ ] **Media Stack** — Jellyfin, qBittorrent, \*arrs (rffmpeg → GPU Workstation)
6. [ ] **Messaging Stack** — Synapse (stateful), Element (stateless)
7. [ ] Delete old VMs

OpenWebUI migration notes:

- [x] OpenWebUI + MCPO migrated to Kubernetes (`tofu/home/kubernetes/openwebui.tf`)
- [x] Gateway API route: `openwebui.apps.home.shdr.ch`
- [x] Initial performance tuning for 4+ concurrent users (cache, streaming batch, thread pool, timeout tuning)
- [x] Data-plane upgrade: PostgreSQL + PGVector (single backend, no separate vector DB service)

**Deferred:**

- Smallweb decommissioned (move to dev workstation folder)
- GitLab migrates after messaging (most complex)

### Phase 6: Multi-Tenancy

- [ ] Create peer namespaces
- [ ] Configure ResourceQuotas
- [ ] Configure NetworkPolicies
- [ ] Add Keycloak OIDC to k8s API
- [ ] Create peer Keycloak groups
- [ ] Test peer kubectl access

## Key Decisions

| Decision     | Choice                         | Rationale                                                          |
| ------------ | ------------------------------ | ------------------------------------------------------------------ |
| OS           | Talos Linux                    | Immutable, API-managed, secure, no SSH                             |
| Image        | nocloud (not qcow2)            | Talos uses nocloud datasource, reads machine config from user-data |
| Provisioning | Tofu + Talos provider          | Same pattern as Fedora VMs, cloud-init disk with Talos config      |
| Node type    | Combined CP + Worker           | 3-node homelab doesn't need separate worker VMs                    |
| IP mgmt      | Static IP in Talos config      | Cloud-init disk includes network config, no DHCP needed            |
| CNI          | Cilium                         | mTLS, L7 policies, Hubble                                          |
| LB mode      | Cilium L2 Announcements        | Single VIP (10.0.3.19), HA failover, no BGP needed                 |
| Ingress      | Gateway API + Caddy (external) | Gateway API is the new standard, keep Caddy as single entry point  |
| PaaS         | Knative Serving                | Scale-to-zero, git-push via GitLab CI, replaces Dokku + Dokploy    |
| GitOps       | GitLab CI + kubectl            | Already have GitLab, no need for ArgoCD                            |
| Secrets      | Secrets Store CSI              | Secrets never in etcd                                              |
| Policy       | OPA Gatekeeper                 | Rego is powerful, industry standard                                |
| Monitoring   | External (Niobe VM)            | Must work when k8s is down                                         |
| Identity     | Keycloak OIDC                  | Already have it, native k8s support                                |
| Infra vend   | Crossplane                     | Self-service S3/DB/Keycloak, no static secrets, self-healing       |

## Value Summary

| Capability              | Before                        | After                             |
| ----------------------- | ----------------------------- | --------------------------------- |
| Idle app resources      | ~51GB RAM always used         | ~0GB (scale to zero)              |
| Peer access             | Manual, no isolation          | Self-service, isolated namespaces |
| Service-to-service auth | Trust network                 | mTLS + AuthorizationPolicy        |
| Functions               | N/A                           | Knative Functions                 |
| Event-driven            | N/A                           | Knative Eventing                  |
| Policy enforcement      | Manual review                 | OPA Gatekeeper (automated)        |
| Secrets in etcd         | Yes (External Secrets)        | No (CSI mount)                    |
| Agents per workload     | OTEL + Wazuh + osquery per VM | DaemonSets (3 total)              |
| Infrastructure vending  | Admin edits Tofu              | Self-service via Crossplane       |

## Status

**Exploration complete.** Ready to implement after Ceph deployment.

## Related Documents

- `proxmox-ha.md` — Prerequisite HA setup
- `ceph.md` — Prerequisite distributed storage
- `nixos.md` — NixOS for foundational VMs (complementary)
- `desktop-vm.md` — Desktop VM using iGPU freed from Media Stack
- `network-security.md` — IDS Stack (Suricata + Wazuh on VM, Nuclei on K8s)
- `../networking.md` — VLAN layout, VyOS firewall rules (k8s on VLAN 3)
- `../trust-model.md` — Identity architecture (k8s integrates with this)
- `../monitoring.md` — Observability architecture (hybrid with k8s)

## External References

- [Talos Image Factory](https://factory.talos.dev/) — Generate customized Talos images
- [Talos nocloud docs](https://docs.siderolabs.com/talos/v1.8/platform-specific-installations/cloud-platforms/nocloud/) — Cloud-init disk configuration
- [Talos Proxmox guide](https://www.talos.dev/v1.11/talos-guides/install/virtualized-platforms/proxmox/) — Official Proxmox installation
- [Talos Terraform provider](https://registry.terraform.io/providers/siderolabs/talos/latest/docs) — Tofu/Terraform provider
- [Crossplane Docs](https://docs.crossplane.io/) — Universal control plane
- [Upbound Marketplace](https://marketplace.upbound.io/) — Crossplane providers and configurations
- [provider-aws](https://marketplace.upbound.io/providers/upbound/provider-aws/) — AWS/S3-compatible resources
- [provider-keycloak](https://github.com/crossplane-contrib/provider-keycloak) — Keycloak clients, realms, users
