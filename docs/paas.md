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
| VPA Recommender | VPA recommendation engine only; updater/admission disabled |
| Goldilocks     | Resource request right-sizing dashboard for opt-in namespaces |
| Tetragon       | eBPF runtime security observability, observe-only      |
| Trivy Operator | Vulnerability/config/RBAC/security report generation   |
| Policy Reporter | UI and metrics for Kyverno and Trivy report results   |
| Kepler         | Node, pod, and container energy/efficiency metrics     |
| Headlamp       | Kubernetes dashboard with OIDC auth                   |
| Hubble UI      | Cilium network observability UI                       |
| GitLab Agent   | CI/CD deploys via GitLab KAS tunnel                   |
| Crossplane     | Infrastructure control plane (Ceph RGW S3-compatible) |
| Kestra OSS     | YAML automation plane and Inquest flow runtime         |
| HolmesGPT      | Read-only Kubernetes/Prometheus/Loki investigation agent |

Goldilocks is advisory only: it creates VPA objects with `updateMode: Off` in
namespaces labeled `goldilocks.fairwinds.com/enabled=true`. Resource changes
stay manual and flow back through OpenTofu. VPA reads live resource metrics from
metrics-server and uses Prometheus-backed cAdvisor history for restart/backfill
context.

Tetragon, Trivy Operator, Policy Reporter, and Kepler are observability/reporting
components only. They do not block admissions, mutate workloads, or enforce
runtime policy.

Trivy's node collector is configured with Talos-safe host paths and small scan
job requests so per-node scans can run on the ARM pool without hard arch pins.

### Access

- API: `https://10.0.3.20:6443` (Talos API VIP)
- Workload VIP: `10.0.3.19` (Cilium L2 LoadBalancer IP)
- Ingress wildcard: `*.home.shdr.ch`
- Headlamp: `https://headlamp.home.shdr.ch`
- Hubble UI: `https://hubble.home.shdr.ch`
- Goldilocks: `https://goldilocks.home.shdr.ch`
- Policy Reporter: `https://policy-reporter.home.shdr.ch`
- Kestra: `https://kestra.home.shdr.ch`

Kestra's platform resources are owned by
`tofu/home/kubernetes/kestra.tf`. The automated Grafana alert workflow is owned
by sibling `../inquest`: its flow IaC creates or updates GitLab incident issues
and calls Holmes for a human-verified RCA. See `docs/monitoring.md` for the
interactive and automated investigation boundaries.
