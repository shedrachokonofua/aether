# PaaS

Talos-based Kubernetes cluster is the application platform. Legacy
Dokku and Dokploy offerings have both been decommissioned; their
workloads were migrated onto Talos k8s.

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
