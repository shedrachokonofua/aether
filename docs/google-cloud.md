# Google Cloud

Aether uses Google Cloud for an external uptime monitor, keyless OpenTofu
authentication, Google Maps Platform APIs consumed through LiteLLM, and spend
controls. The root module is enabled by the encrypted `google.project_id`
configuration. Its empty-value guard supports initial bootstrap; Google Cloud
is part of the current Aether architecture.

## Ownership

| Concern | Authoritative path |
| --- | --- |
| Root module and provider wiring | `tofu/main.tf` |
| Project, identity, APIs, and API key | `tofu/google/main.tf` |
| Uptime monitor VM | `tofu/google/uptime-monitor.tf` |
| Billing budget | `tofu/google/budget.tf` |
| Uptime monitor service configuration | `ansible/playbooks/uptime_monitor_stack/` |
| SSH inventory | `ansible/inventory/hosts.yml` |
| Login and credential caching | `scripts/login.bb`, `scripts/google-wif-token.bb` |

## Identity

The `aether-tofu` service account is impersonated through Google Workload
Identity Federation. The workload identity provider trusts Keycloak tokens from
the Aether realm with the `toolbox` audience and restricts impersonation to the
configured Keycloak email claim. No Google service-account key is stored in the
repository.

`task login` writes an external-account credential configuration and cached
environment under the Aether toolbox cache. OpenTofu tasks load that environment
automatically. Check it before provider work:

```bash
task login:status
task login -- --google    # refresh Google credentials only when required
```

The service account has the project roles declared in `tofu/google/main.tf` for
service enablement, API-key management, Compute Engine, IAM, and workload
identity administration. Treat that file, not this summary, as the permission
source of truth.

### First Bootstrap

Google WIF login cannot create the WIF resources it depends on. Bootstrap the
AWS remote backend first with pre-existing human AWS credentials, then use a
human Google Application Default Credential for the first root apply:

```bash
aws sts get-caller-identity
task bootstrap
gcloud auth application-default login
task tofu:plan
task tofu:apply
task tofu:write-outputs
```

Once the Google audience and service-account outputs exist, `task login` can
exchange Keycloak tokens for short-lived Google credentials. Do not create a
service-account JSON key to bridge bootstrap.

## Uptime Monitor

OpenTofu declares `aether-uptime-monitor`, an `e2-micro` Debian 12 Compute Engine
VM in `us-central1-a`. It uses the default VPC, a standard persistent disk, an
ephemeral public address, OS Config, and a generated ED25519 SSH key.

The public address is not the Ansible management endpoint. The inventory uses
the VM's Tailscale address exported from the root state. The scoped workflow:

```bash
task tofu:plan
task tofu:apply
task configure:uptime-monitor
```

The Ansible playbooks install and configure:

- Tailscale for management connectivity
- Uptime Kuma for external service checks and the monitoring dead-man push
- a Cloudflare Tunnel for HTTPS ingress

The Tailscale OAuth client and Cloudflare tunnel/DNS resources are owned by
`tofu/tailscale.tf` and `tofu/cloudflare.tf`, respectively. This is a split-owner
service; changing only the Google VM does not update its mesh identity or public
route.

## Google Maps Platform

The Google module enables the foundation services required by OpenTofu and the
Maps Platform APIs listed in `tofu/google/main.tf`. It creates the
`litellm-google-maps-mcp` API key with per-API restrictions. Optional server IP
restrictions are applied when `litellm_google_maps_allowed_ips` is populated.

The sensitive key is passed through the root module into the Kubernetes
LiteLLM configuration. Do not print it from state or duplicate it in docs or
unencrypted configuration.

## Budget

When the encrypted billing account ID is configured, OpenTofu declares a USD 1
project budget with notifications at 50, 90, and 100 percent. The budget is a
spend signal, not a hard cap; it does not disable services when crossed.

## Operational Checks

```bash
# Authentication and configured project
task login:status
gcloud auth list
gcloud config get-value project

# Declared Google-only changes still run from the root state
task tofu:plan -- -target='module.google[0]'

# Service configuration uses the Tailscale inventory address
task configure:uptime-monitor -- --check --diff
```

Targeting the Google module does not isolate parsing: OpenTofu still loads the
entire root configuration before planning. Use the target only to inspect a
known scope, and review the complete plan before applying.
