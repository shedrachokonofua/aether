# Software Studio — Seven30

3-person software studio. Workloads run on the existing Talos Kubernetes cluster under `seven30.xyz`. Clean separation from the homelab — `shdr.ch` is personal infrastructure, `seven30.xyz` is Seven30.

## Goal

Give co-founders full development capabilities (kubectl, GitLab, deploy apps) without exposing the homelab. Network-level isolation by default, auth as a second layer.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         TAILSCALE TAILNET                            │
│                                                                     │
│  You (s@shdr.ch)          Seven30 members (2 others)               │
│  ├── Full LAN access       ├── Home Gateway Tailscale IP only      │
│  └── Everything             └── Port 443 only                       │
│            │                           │                            │
└────────────┼───────────────────────────┼────────────────────────────┘
             │                           │
             ▼                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    HOME GATEWAY (Caddy)                              │
│                                                                     │
│  LAN (10.0.2.2:443)     Tailscale (100.x.y.z:443)    :9443        │
│  ├── gitlab.home.shdr.ch ├── gitlab.home.shdr.ch      (public)     │
│  ├── grafana.home.shdr.ch├── *.seven30.xyz            ├── *.shdr.ch│
│  ├── *.apps.home.shdr.ch ├── k8s.seven30.xyz          ├──seven30.xyz│
│  └── ... (everything)    └── Seven30 only             └──*.seven30.xyz│
│                                                                     │
│  default_bind 10.0.2.2                                             │
└──────────────┬──────────────────────────┬──────────────┬────────────┘
               │                          │              │
               ▼                          ▼              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    HOST CLUSTER (Talos, 3 nodes)                     │
│                                                                     │
│  Gateway API (10.0.3.19)                                           │
│  ├── Listener: *.apps.home.shdr.ch  (personal k8s apps)            │
│  └── Listener: *.seven30.xyz        (Seven30 k8s apps)             │
│                                                                     │
│  Platform:                  Personal:      Seven30 vcluster:       │
│  ├── Cilium                 ├── OpenWebUI   ├── Projects            │
│  ├── Knative                ├── Hubble UI   ├── Own namespaces      │
│  ├── Crossplane             └── Headlamp    ├── Own CRDs/Helm      │
│  └── vcluster operator                      └── All 3 = admin      │
└─────────────────────────────────────────────────────────────────────┘
```

## What Already Exists

| Component | Status | Details |
| --- | --- | --- |
| Cloudflare zone | Done | `seven30.xyz`, own account (`cloudflare.seven30` provider) |
| DNS wildcard | Done | `*.seven30.xyz` → public gateway IP (proxied) |
| Public Caddy | Done | `seven30.xyz, *.seven30.xyz` → home gateway `:9443` |
| Home Caddy `:9443` | Done | `seven30.xyz` → static landing page (`/srv/seven30`) |
| Tailscale SSO | Done | Phase 1 of `full-tailscale-integration.md` |
| Tailscale ACL | Done | Terraform-managed, deny-by-default |

## Access Model

Three layers, each tighter:

| Layer | Controls | Mechanism |
| --- | --- | --- |
| Network | Can they reach the IP at all | Tailscale ACL — Seven30 members → home gateway Tailscale IP `:443` only |
| Reverse proxy | Which services exist on that IP | Caddy `bind` — only Seven30 routes on Tailscale interface |
| Application | Who can use each service | Keycloak OIDC — GitLab and k8s apps authenticate via Keycloak |

### What Seven30 members can reach

| Service | Hostname | Via |
| --- | --- | --- |
| GitLab | `gitlab.home.shdr.ch` | Caddy (Tailscale) → GitLab VM |
| GitLab Registry | `registry.gitlab.home.shdr.ch` | Caddy (Tailscale) → GitLab VM |
| Seven30 apps (dev) | `*.seven30.xyz` | Caddy (Tailscale) → K8s VIP → Gateway API |
| vcluster kubectl | `k8s.seven30.xyz` | Caddy (Tailscale) → K8s VIP → vcluster API |

### What Seven30 members cannot reach

Everything else. Not "blocked by auth" — the services don't exist on the Tailscale interface. Connection refused, not 403.

---

## Tailscale

### ACL Changes

Add `group:seven30` to the existing ACL in `tailscale.tf`:

```hcl
resource "tailscale_acl" "tailnet_acl" {
  acl = jsonencode({
    groups : {
      "group:admin"   : [local.tailscale.user],
      "group:seven30" : [
        "member-a@example.com",
        "member-b@example.com",
      ],
    },
    tagOwners : {
      "tag:home-gateway"   : ["group:admin"],
      "tag:public-gateway" : ["group:admin"],
    },
    acls : [
      // Admin: full access
      {
        action : "accept",
        src : ["group:admin"],
        dst : ["*:*"],
      },
      // Home gateway: internal networks
      {
        action : "accept",
        src : ["tag:home-gateway"],
        dst : [
          "10.0.0.0/8:*",
          "192.168.0.0/16:*",
        ],
      },
      // Public gateway: home gateway Caddy public port only
      {
        action : "accept",
        src : ["tag:public-gateway"],
        dst : ["10.0.2.2:9443"],
      },
      // Seven30: home gateway Tailscale IP, port 443 only
      {
        action : "accept",
        src : ["group:seven30"],
        dst : ["tag:home-gateway:443"],
      },
    ],
    autoApprovers : {
      routes : {
        "10.0.0.0/8"     : ["tag:home-gateway"],
        "192.168.0.0/16" : ["tag:home-gateway"],
      },
    },
  })
}
```

### Split DNS

Seven30 members need to resolve studio-relevant hostnames:

```hcl
resource "tailscale_dns_split_nameservers" "seven30" {
  domain      = "seven30.xyz"
  nameservers = ["10.0.0.1"]  # AdGuard (via subnet route)
}

resource "tailscale_dns_split_nameservers" "home_shdr_ch" {
  domain      = "home.shdr.ch"
  nameservers = ["10.0.0.1"]
}
```

Both `*.seven30.xyz` and `gitlab.home.shdr.ch` resolve through AdGuard to the home gateway. Caddy on the Tailscale interface routes them.

> [!NOTE]
> The global nameserver (`10.0.0.1`) is already set for admin. Split DNS here ensures Seven30 members resolve these specific domains without getting resolution for everything else (e.g., `grafana.home.shdr.ch` resolving to an IP they can't reach anyway is a needless info leak).

### Security Analysis

**Q: Home gateway advertises `10.0.0.0/8` subnet routes. Can Seven30 members route through the gateway to reach internal IPs (Proxmox, k8s VIP, other VMs)?**

No. Tailscale ACLs are enforced regardless of subnet routing. `autoApprovers` just means the gateway doesn't need manual approval to advertise routes. A Seven30 member with `dst: ["tag:home-gateway:443"]` can reach the gateway's Tailscale IP on port 443. They cannot reach `10.0.0.0/8` because no ACL rule grants `group:seven30` access to those subnets. Subnet routes define *what the gateway can forward*, ACLs define *who is allowed to use those routes*.

**Q: Can a Seven30 member reach port 9443 on the home gateway?**

No. ACL says `:443` only. Even though `:9443` is the public ingress port, it's not in their ACL. Public access to Seven30 apps goes through Cloudflare → public Caddy → home Caddy `:9443`, which is a separate path entirely.

**Q: Can a Seven30 member see internal DNS names?**

With split DNS scoped to `seven30.xyz` and `home.shdr.ch` only — no. They won't resolve `grafana.home.shdr.ch` or `proxmox.home.shdr.ch`. Only `*.seven30.xyz` and `*.home.shdr.ch` go through your AdGuard, and even if they did resolve something, the ACL blocks the network path.

**Q: What if a Seven30 member's device is compromised?**

Attacker gets access to `tag:home-gateway:443`. They can reach Caddy on the Tailscale interface, which only serves Seven30 routes. Next layer is Keycloak auth. Blast radius: Seven30 apps + GitLab (behind OIDC). No access to homelab infra, no lateral movement.

**Q: Can Seven30 members talk to each other directly?**

No. No ACL rule allows `group:seven30` → `group:seven30`. They communicate through services on the home gateway. If you want direct P2P (e.g., for pair programming tools), add:
```hcl
{ action: "accept", src: ["group:seven30"], dst: ["group:seven30:*"] }
```

---

## Caddy Configuration

### Home Gateway Caddyfile Changes

**Global options** — lock existing routes to LAN:
```caddy
{
  default_bind 10.0.2.2
}
```

All existing routes continue to work on LAN unchanged.

**Seven30 routes** — Tailscale interface only:
```caddy
# =============================================================================
# Seven30 — Tailscale interface only
# =============================================================================

gitlab.home.shdr.ch {
  bind {{ tailscale_ip }}
  reverse_proxy {{ vm.gitlab.ip }}:80
}

registry.gitlab.home.shdr.ch {
  bind {{ tailscale_ip }}
  reverse_proxy {{ vm.gitlab.ip }}:{{ vm.gitlab.ports.gitlab_registry }}
}

*.seven30.xyz {
  bind {{ tailscale_ip }}
  reverse_proxy 10.0.3.19 {
    header_up Host {http.request.host}
    header_up X-Real-IP {http.request.remote}
    header_up X-Forwarded-For {http.request.remote}
    header_up X-Forwarded-Proto {http.request.scheme}
  }
}

k8s.seven30.xyz {
  bind {{ tailscale_ip }}
  reverse_proxy https://10.0.3.19:{vcluster_nodeport} {
    transport http {
      tls_insecure_skip_verify
    }
  }
}
```

**`:9443` changes** — route Seven30 subdomains to k8s (root stays as landing page):
```caddy
:9443 {
  @seven30_root host seven30.xyz
  handle @seven30_root {
    root * /srv/seven30
    file_server
  }

  @seven30_apps host *.seven30.xyz
  handle @seven30_apps {
    reverse_proxy 10.0.3.19 {
      header_up Host {http.request.host}
      header_up X-Real-IP {http.request.header.X-Real-IP}
      header_up X-Forwarded-For {http.request.header.X-Forwarded-For}
      header_up X-Forwarded-Proto https
    }
  }

  # ... existing routes unchanged ...
}
```

**Notes:**
- `gitlab.home.shdr.ch` appears in the Caddyfile twice — LAN bind (existing) and Tailscale bind (new). Different `bind` addresses = distinct listeners.
- `k8s.seven30.xyz` is Tailscale-only — never on `:9443`, never public.

---

## Gateway API

Add `*.seven30.xyz` listener to the existing main gateway:

```terraform
resource "kubernetes_manifest" "main_gateway" {
  depends_on = [kubernetes_manifest.gateway_class]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = "main-gateway"
      namespace = "default"
      annotations = {
        "io.cilium/lb-ipam-ips" = var.workload_vip
      }
    }
    spec = {
      gatewayClassName = "cilium"
      listeners = [
        {
          name     = "http"
          protocol = "HTTP"
          port     = 80
          hostname = "*.apps.home.shdr.ch"
          allowedRoutes = {
            namespaces = { from = "All" }
          }
        },
        {
          name     = "seven30"
          protocol = "HTTP"
          port     = 80
          hostname = "*.seven30.xyz"
          allowedRoutes = {
            namespaces = { from = "All" }
          }
        }
      ]
    }
  }
}
```

Seven30 apps create HTTPRoutes with `*.seven30.xyz` hostnames. Same VIP (10.0.3.19), different listener.

---

## vcluster

### Why vcluster

Co-founders need to feel like they own their cluster. Namespace isolation is for untrusted tenants.

| Capability | Namespace isolation | vcluster |
| --- | --- | --- |
| Install own CRDs | No | Yes |
| Create namespaces | No | Yes |
| Install Helm charts | Partial | Full |
| Own RBAC | Restricted | Full |
| Break host cluster | Possible | No |

### Single shared vcluster

One vcluster named `seven30`. All 3 people have cluster-admin. Organize with namespaces inside:

```
vcluster: seven30 (host namespace: vc-seven30)
├── project-alpha   (joint project)
├── project-beta    (side project)
├── project-gamma   (side project)
└── shared          (shared DBs, caches)
```

### Resource overhead

~400MB RAM for the vcluster control plane (k3s API server + syncer). Pods run on host cluster nodes, no nested overhead.

### Knative integration

Knative Serving stays on the host cluster. vcluster syncs Knative CRDs (Service, Route, Configuration, Revision) to the host. Seven30 deploys Knative Services inside the vcluster; Knative controller on the host handles scale-to-zero and Gateway API routing.

### kubectl access

vcluster API server exposed as a NodePort or LoadBalancer on the k8s VIP. Caddy proxies it via `k8s.seven30.xyz` on Tailscale only. Kubeconfig:

```yaml
apiVersion: v1
kind: Config
clusters:
  - cluster:
      server: https://k8s.seven30.xyz
    name: seven30
contexts:
  - context:
      cluster: seven30
      user: seven30
    name: seven30
current-context: seven30
users:
  - name: seven30
    user:
      token: <vcluster-generated-token>
```

---

## Keycloak

Seven30 members get Keycloak accounts in the `aether` realm. Used for GitLab OIDC, k8s app auth, and Tailscale SSO.

| Group | Members | Purpose |
| --- | --- | --- |
| `admin` | You | Homelab admin |
| `seven30` | You + 2 co-founders | GitLab + Seven30 app access |

---

## Project Management

No new tools. Just git.

- **Per-project repos** under `seven30` GitLab group — issues, MRs, wiki
- **`seven30` meta-repo** — shared docs, decisions, business tasks as issues

---

## Traffic Flows

### Dev (Tailscale)

```
Seven30 member → Tailscale → Home Gateway (100.x.y.z:443)
  → Caddy (Tailscale bind) → K8s VIP (10.0.3.19) → Gateway API → pod
```

### Prod (Internet)

```
User → Cloudflare (*.seven30.xyz) → Public Caddy (AWS)
  → Home Caddy (:9443) → K8s VIP (10.0.3.19) → Gateway API → pod
```

### kubectl

```
Seven30 member → Tailscale → Home Gateway (100.x.y.z:443)
  → Caddy (k8s.seven30.xyz) → K8s VIP → vcluster API
```

---

## Scaling to Multiple Studios

If a second studio needs separate access (e.g., `otherstudio.dev`):

### Same-trust (both studios can see each other's routes)

Simplest. Add members to a shared group or create `group:otherstudio` with the same `dst: ["tag:home-gateway:443"]` rule. All studio routes live on the same Tailscale interface. Use Keycloak group-based auth to control which studio's apps each person can access.

- Network: shared (both reach same Caddy interface)
- Auth: separated (Keycloak groups per studio, `forward_auth` on routes)
- Isolation: application-layer only

### Different-trust (studios cannot see each other's routes)

Requires network-level separation. Options:

**Option A: Port-based isolation**

Each studio gets its own port on the home gateway:

```hcl
// Seven30
{ action: "accept", src: ["group:seven30"], dst: ["tag:home-gateway:443"] },
// Other studio
{ action: "accept", src: ["group:otherstudio"], dst: ["tag:home-gateway:8443"] },
```

Caddy binds each studio's routes to a different port on the Tailscale interface. Clean ACL separation. Downside: non-standard ports for the second studio (but only on the internal Tailscale path — public access through Cloudflare is standard `:443`).

**Option B: Separate proxy node**

Run a second Caddy instance (container or VM) with its own Tailscale identity and tag. Each studio targets a different tag:

```hcl
{ action: "accept", src: ["group:seven30"], dst: ["tag:seven30-proxy:443"] },
{ action: "accept", src: ["group:otherstudio"], dst: ["tag:otherstudio-proxy:443"] },
```

Full network isolation, standard ports, but more infrastructure to manage.

**Option C: Separate tailnet**

Nuclear option. Completely separate Tailscale tailnet per studio. Zero shared infrastructure. Only makes sense if studios are adversarial or have regulatory requirements.

### Recommendation

Start with Seven30 as the only studio. If a second one appears and trust is similar, go same-trust (shared Tailscale interface + Keycloak groups). If trust is different, port-based isolation is the least effort for real network separation.

---

## Implementation Phases

### Phase 0: Prerequisites

- [ ] Complete Tailscale gateway join (Phase 1 of `full-tailscale-integration.md`)
- [ ] Verify home gateway has Tailscale IP

### Phase 1: Caddy

- [ ] Add `default_bind 10.0.2.2` to Caddyfile global options
- [ ] Verify all existing LAN routes still work
- [ ] Add Seven30 routes bound to Tailscale interface
- [ ] Update `:9443` to route `*.seven30.xyz` subdomains to K8s VIP
- [ ] Test from Tailscale: Seven30 routes work, personal services unreachable

### Phase 2: Gateway API

- [ ] Add `*.seven30.xyz` listener to main gateway in `gateway.tf`
- [ ] Deploy test HTTPRoute with a Seven30 hostname
- [ ] Verify traffic from both Tailscale and public paths

### Phase 3: vcluster

- [ ] Create `tofu/home/kubernetes/vcluster.tf`
- [ ] Deploy vcluster (name: `seven30`, host namespace: `vc-seven30`)
- [ ] Configure CRD sync (HTTPRoute, Knative)
- [ ] Expose vcluster API (NodePort on k8s VIP)
- [ ] Wire `k8s.seven30.xyz` Caddy route
- [ ] Generate kubeconfig, verify kubectl works

### Phase 4: Onboarding

- [ ] Invite 2 co-founders to tailnet
- [ ] Add `group:seven30` ACL (scoped to `tag:home-gateway:443`)
- [ ] Configure split DNS for `seven30.xyz` + `home.shdr.ch`
- [ ] Create Keycloak accounts, add to `seven30` group
- [ ] Share kubeconfig
- [ ] Verify: GitLab works, kubectl works, Seven30 apps work
- [ ] Verify: Grafana/Jellyfin/Proxmox/personal apps unreachable

### Phase 5: First Project

- [ ] Create `seven30` group in GitLab
- [ ] Create `seven30` meta-repo
- [ ] Configure GitLab CI for vcluster deploys
- [ ] Deploy first project, verify at `app.seven30.xyz`
- [ ] Expose publicly (already wired — Cloudflare → Caddy → k8s)

---

## Key Decisions

| Decision | Choice | Rationale |
| --- | --- | --- |
| Studio domain | `seven30.xyz` | Already wired with Cloudflare + Caddy |
| Personal domain | `shdr.ch` / `home.shdr.ch` | Clean separation |
| Team size | 3 (you + 2 co-founders) | |
| Multi-tenancy | vcluster | Co-founders need full cluster experience |
| vcluster count | 1 shared | Same-trust, shared services trivial |
| Network access | Tailscale | Zero-trust overlay |
| Access isolation | Caddy bind + Tailscale ACL | Deny-by-default at network + proxy layer |
| DNS | Split DNS (scoped) | No info leak of internal service names |
| Ports | Standard :443 everywhere | Caddy per-interface bind |
| Project management | GitLab native | No new tools |
| Future studios | Port-based or auth-based | Depends on trust level |

## Related Documents

- `kubernetes.md` — Host cluster architecture, platform components
- `full-tailscale-integration.md` — Tailscale SSO, gateway auth, ACL structure
- `../trust-model.md` — Identity architecture (Keycloak, OIDC flows)
