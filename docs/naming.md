# Infrastructure naming ontology

This ontology currently governs the inter-site network and the services attached
to it. It separates stable identity from topology and implementation details.

## Identity hierarchy

Every attached service is identified from broadest to narrowest:

```text
fabric → site → host → service
```

| Dimension | Meaning | Example |
| --- | --- | --- |
| `fabric` | One routed connectivity domain | `aether` |
| `site` | One administrative or physical location in the fabric | `home`, `aws`, `gcp`, `oci` |
| `host` | One machine within a site | `router`, `link`, `vigilant`, `rama` |
| `service` | One workload running on a host | `node-exporter`, `wireguard-exporter`, `crowdsec` |

Identifiers use lowercase kebab case and match
`^[a-z0-9][a-z0-9-]{0,62}$`. Each identifier is local to its parent: a host is
unambiguous when paired with its site, and a service is unambiguous when paired
with its host.

## Identity is not topology

`home`, `aws`, and `gcp` are equal sites in `aether`. The current WireGuard
adjacency happens to be hub-and-spoke:

```text
                       home/router
                           │
gcp/vigilant ─── aws/link ─── oci/rama
                       (topology_role=hub)
```

The AWS site forwarding traffic does not make `aws` a parent of the other
sites. `hub` and `spoke` are values of `topology_role`; they are never site or
peer identifiers. A future routing change must not rename a site or host.

## Current site map

| Fabric | Site | Host | Topology role | Direct WireGuard peer sites |
| --- | --- | --- | --- | --- |
| `aether` | `home` | `router` | `spoke` | `aws` |
| `aether` | `aws` | `link` | `hub` | `home`, `gcp`, `oci` |
| `aether` | `gcp` | `vigilant` | `spoke` | `aws` |
| `aether` | `oci` | `rama` | `spoke` | `aws` |

WireGuard peer declarations use the remote `site` and `host` fields. Runtime
peer metrics retain the public key as the immutable protocol identity and add
`peer_site` and `peer_host` for human and query identity.

## Protocol locators

Stable identity is independent of platform-specific interface names. The Linux
site hosts use `wg-site`; the VyOS router uses its native `wg10` interface
identifier. Both represent the same `aether` fabric, and neither is a site,
host, or peer identity.

## Metrics naming

Prometheus job names describe the scrape scope and service, not a host or a
routing role:

| Job | Service coverage |
| --- | --- |
| `site-node-exporter` | `node-exporter` on hosts attached to `aether` |
| `site-wireguard-exporter` | `wireguard-exporter` on site-edge hosts |
| `site-crowdsec` | `crowdsec` on the AWS site-edge host |

Every series from these jobs carries:

```text
fabric="aether"
site="home|aws|gcp|oci"
host="<host-id>"
service="<service-id>"
topology_role="hub|spoke"
```

WireGuard peer series additionally carry `peer_site` and `peer_host`.
`topology_role` is descriptive metadata and must not be used to construct
identity.

## Prohibited identity shortcuts

Do not use these as identities:

- `offsite`: relative to the observer and therefore unstable.
- `cloud`: groups unlike sites and excludes `home` from the same fabric.
- `hub` or `spoke`: mutable topology roles.
- `aws-hub`, `home-vyos`, or similar composites: they mix site, host
  implementation, and topology.
- Public keys, addresses, and ports alone: protocol locators are not human
  identity.

## Authoritative declarations

- Site and peer identity: the `aether_identity` and `site_wireguard_peers`
  declarations in the home-router, public-gateway, uptime-monitor, and
  oci-dns playbooks.
- Site-fabric behavior: `ansible/roles/site_wireguard/`.
- Attached metric services: `ansible/roles/site_metrics_exporters/`.
- Prometheus labels and jobs:
  `ansible/playbooks/monitoring_stack/prometheus.yml.j2`.
- Reconciliation: `task configure:site-fabric` and
  `task configure:site-metrics`.
