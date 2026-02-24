# PaaS

Two platform-as-a-service offerings provide application deployment infrastructure.

## Kubernetes (Talos)

Talos-based Kubernetes cluster with Cilium networking, Gateway API ingress, and a growing platform layer.

### Platform Components

| Component      | Purpose                                               |
| -------------- | ----------------------------------------------------- |
| Cilium         | CNI, kube-proxy replacement, L2 LoadBalancer VIP      |
| Gateway API    | Cluster ingress via Cilium GatewayClass               |
| Ceph CSI       | RBD storage provisioning (default StorageClass)       |
| Knative        | Serverless/scale-to-zero serving                      |
| OTEL Collector | Cluster + node telemetry to external monitoring stack |
| Metrics Server | metrics.k8s.io for HPA/VPA, kubectl top, Headlamp     |
| Headlamp       | Kubernetes dashboard with OIDC auth                   |
| Hubble UI      | Cilium network observability UI                       |
| GitLab Agent   | CI/CD deploys via GitLab KAS tunnel                   |
| Crossplane     | Infrastructure control plane (Ceph RGW S3-compatible) |

### Access

- API: `https://10.0.3.20:6443` (Talos API VIP)
- Workload VIP: `10.0.3.19` (Cilium L2 LoadBalancer IP)
- Ingress wildcard: `*.apps.home.shdr.ch`
- Headlamp: `https://headlamp.apps.home.shdr.ch`
- Hubble UI: `https://hubble.apps.home.shdr.ch`

## Dokku

Multi-tenant PaaS running on Neo. Provides Heroku-like git-push deployment with Terraform support for infrastructure-as-code management.

| Component | Purpose                              |
| --------- | ------------------------------------ |
| Dokku     | Core PaaS platform (buildpacks, git) |
| Infisical | Secrets management integration       |
| Temporal  | Workflow orchestration               |

### Features

- Git push deployment
- Buildpack and Dockerfile support
- Let's Encrypt SSL certificates
- Terraform provider for declarative app management
- Plugin ecosystem (postgres, redis, etc.)

### Access

- SSH: `dokku@dokku.home.shdr.ch`
- Web: `*.dokku.home.shdr.ch`

## Dokploy

GUI-based PaaS running on Trinity. Provides a visual interface for deploying applications and third-party services.

### Deployed Services

| Service     | Purpose                      |
| ----------- | ---------------------------- |
| N8N         | Workflow automation          |
| Owntracks   | Location tracking            |
| Windmill    | Script/workflow platform     |
| Vaultwarden | Password manager (Bitwarden) |
| Affine      | Knowledge base / note-taking |

### Features

- Docker Compose deployment
- Git integration
- Automatic SSL via Caddy
- Database provisioning
- Backup integration

### Access

- Web: `dokploy.home.shdr.ch`

## Smallweb

Lightweight file-based personal cloud running on Trinity. Designed for simple static sites and lightweight applications.

### Features

- File-based deployment
- Automatic HTTPS
- Minimal resource footprint

### Access

- Web: `*.smallweb.home.shdr.ch`
