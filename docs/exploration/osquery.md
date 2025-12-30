# Fleet (osquery + MDM) Exploration

Exploration of Fleet for SQL-based querying across hosts and device management.

## Goal

Query system state across all hosts using SQL:

- Installed packages and versions
- Pending updates
- Running processes
- Open ports
- File integrity
- User accounts
- And more

## What is osquery?

osquery exposes the operating system as a relational database. Query anything with SQL:

```sql
-- Find all installed packages
SELECT name, version FROM rpm_packages;

-- Find listening ports
SELECT pid, port, address FROM listening_ports;

-- Find users with sudo access
SELECT * FROM sudoers;

-- Find files modified in last 24h
SELECT * FROM file WHERE mtime > (strftime('%s', 'now') - 86400);
```

## Architecture

osquery alone runs per-host. For centralized querying, add Fleet:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              Fleet Server                                │
│                     (Centralized query & management)                     │
│                                                                          │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │  Live Query: "SELECT name, version FROM rpm_packages            │   │
│   │               WHERE name LIKE '%openssl%'"                      │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                    │                                     │
│            ┌───────────────────────┼───────────────────────┐            │
│            ▼                       ▼                       ▼            │
│   ┌──────────────┐        ┌──────────────┐        ┌──────────────┐     │
│   │   osquery    │        │   osquery    │        │   osquery    │     │
│   │ gpu-workstation │     │   gitlab     │        │   dokploy    │     │
│   └──────────────┘        └──────────────┘        └──────────────┘     │
│                                                                          │
│   Results aggregated: All hosts, all packages, one view                 │
└─────────────────────────────────────────────────────────────────────────┘
```

## Components

### osquery (Agent)

Runs on each host, exposes OS as SQL tables.

| Table                           | Data                 |
| ------------------------------- | -------------------- |
| `rpm_packages` / `deb_packages` | Installed packages   |
| `listening_ports`               | Open network ports   |
| `processes`                     | Running processes    |
| `users`                         | User accounts        |
| `file`                          | File metadata        |
| `sudoers`                       | Sudo configuration   |
| `crontab`                       | Scheduled tasks      |
| `iptables`                      | Firewall rules       |
| `mounts`                        | Mounted filesystems  |
| `system_info`                   | OS, kernel, hardware |

Full table list: [osquery schema](https://osquery.io/schema)

### Fleet (Fleet Manager)

Open source osquery management. See [Fleet](https://fleetdm.com/).

| Feature                | Description                                   |
| ---------------------- | --------------------------------------------- |
| Live queries           | Run SQL across all hosts in real-time         |
| Scheduled queries      | Run nightly, store results                    |
| Policies               | Alert when query returns results              |
| Vulnerability scanning | Match installed packages against CVE database |
| Prometheus export      | `/metrics` endpoint for Grafana               |
| API                    | REST API for automation                       |
| Teams/RBAC             | Multi-user access control                     |

## Use Cases for Aether

### Package Visibility (Patch Management)

```sql
-- Pending updates (Fedora)
SELECT name, version FROM rpm_packages
WHERE name IN (SELECT name FROM rpm_package_updates);

-- Find vulnerable OpenSSL versions
SELECT * FROM rpm_packages WHERE name = 'openssl' AND version < '3.0.0';
```

### Security Auditing

```sql
-- Find all SUID binaries
SELECT * FROM suid_bin;

-- Users with shell access
SELECT username, shell FROM users WHERE shell NOT LIKE '%nologin%';

-- World-writable files
SELECT * FROM file WHERE mode LIKE '%7' AND directory = '/etc';
```

### Compliance

```sql
-- SSH config audit
SELECT * FROM ssh_configs;

-- Password policy
SELECT * FROM shadow WHERE password_status != 'P';
```

### Incident Response

```sql
-- Processes listening on unusual ports
SELECT p.name, p.pid, l.port
FROM processes p JOIN listening_ports l ON p.pid = l.pid
WHERE l.port NOT IN (22, 80, 443, 9090);

-- Recently modified binaries
SELECT * FROM file WHERE path LIKE '/usr/bin/%' AND mtime > (strftime('%s', 'now') - 86400);
```

## Integration with Existing Stack

### Prometheus + Grafana

Fleet exposes `/metrics` endpoint:

```
fleet_hosts_total 15
fleet_hosts_online 14
fleet_scheduled_query_results{query="pending_updates"} 47
```

### Loki

Query results can be logged to Loki for historical analysis.

### Alerting

Fleet policies can trigger alerts:

- "Any host with OpenSSL < 3.0" → ntfy notification
- "New SUID binary detected" → alert

## vs Other Tools

| Tool                | Scope              | Centralized | Query Language |
| ------------------- | ------------------ | ----------- | -------------- |
| **osquery + Fleet** | Everything         | ✅          | SQL            |
| **Cockpit**         | Packages, services | Per-host UI | N/A            |
| **PatchMon**        | Packages only      | ✅          | N/A            |
| **Trivy**           | Containers, CVEs   | Per-scan    | N/A            |
| **Wazuh**           | HIDS, logs         | ✅          | Custom         |

osquery is broader — not just packages, but full system state queryable via SQL.

## MDM (Device Management)

Fleet has evolved beyond osquery into a full device management platform. See [Fleet MDM](https://fleetdm.com/device-management).

| Platform | osquery | MDM               | Notes                  |
| -------- | ------- | ----------------- | ---------------------- |
| Linux    | ✅      | ❌                | Servers/VMs only       |
| macOS    | ✅      | ✅                | Full MDM + osquery     |
| Windows  | ✅      | ✅                | Full MDM + osquery     |
| iOS      | ❌      | ✅                | MDM only, no osquery   |
| Android  | ❌      | ✅ (experimental) | Via Android Enterprise |

### Android MDM

Fleet supports Android via [Android Enterprise](https://fleetdm.com/guides/android-mdm-setup). Experimental but functional.

**Features:**

- Work profile management
- App deployment
- Configuration profiles
- Device inventory

**Requirements:**

- Android devices must be Play Protect certified
- Requires Android Enterprise connection (free with Google Workspace, Microsoft 365, or standalone)

### Use Cases for Personal Devices

MDM is overkill for personal laptops — you already control them. But osquery is useful for visibility:

| Device         | osquery | MDM | Recommendation                          |
| -------------- | ------- | --- | --------------------------------------- |
| MacBook        | ✅      | ❌  | osquery only                            |
| Windows laptop | ✅      | ❌  | osquery only                            |
| Linux laptop   | ✅      | ❌  | osquery only                            |
| Phones         | ❌      | ❌  | Just use apps (Tailscale, Immich, etc.) |

**osquery on laptops lets you:**

```sql
-- What's installed across all my machines?
SELECT hostname, name, version FROM programs;

-- Browser extensions installed
SELECT * FROM chrome_extensions;

-- Listening ports
SELECT * FROM listening_ports;

-- Disk encryption status
SELECT * FROM disk_encryption;
```

**When MDM makes sense:** Managing family/kids devices, shared laptops, or if you want automated enforcement. Skip for personal devices.

## Deployment

### Fleet Server

Deploy on Monitoring Stack:

```yaml
# Podman Quadlet
[Container]
Image=docker.io/fleetdm/fleet:latest
Environment=FLEET_MYSQL_ADDRESS=...
Environment=FLEET_REDIS_ADDRESS=...
PublishPort=8080:8080
```

Requires MySQL/MariaDB + Redis.

### osquery Agent

Add to `vm_monitoring_agent` role:

1. Install osquery package
2. Configure to connect to Fleet server
3. Enable osqueryd service

```yaml
# Example vars
osquery_enabled: true
fleet_server_url: "https://fleet.home.shdr.ch"
fleet_enroll_secret: "{{ secrets.fleet_enroll_secret }}"
```

## Costs

| Item           | One-Time                   | Ongoing                 |
| -------------- | -------------------------- | ----------------------- |
| Fleet server   | ~2 hours setup             | MySQL + Redis resources |
| osquery agents | Add to vm_monitoring_agent | ~50MB RAM per host      |
| Learning curve | SQL is familiar            | Minimal                 |

## Decision Factors

### Pros

- SQL interface to entire fleet — familiar, powerful
- Goes beyond packages — processes, ports, files, users
- Fleet is open source, active development
- Prometheus/Grafana integration
- Scheduled queries + policies for compliance

### Cons

- Another service (Fleet server + MySQL + Redis)
- Agents on every host
- Overkill if you only need package visibility

### When to Use

- You want deep visibility into system state
- Compliance/audit requirements
- Security investigations
- "What's running on my hosts?" across fleet

### When to Skip

- Only need package updates → Cockpit or custom script
- Only need container CVEs → Trivy
- Prefer simpler stack

## Open Questions

1. Deploy Fleet on Monitoring Stack or dedicated VM?
2. MySQL/MariaDB: new instance or share with existing?
3. Which scheduled queries to run by default?
4. Integrate with Wazuh (if exploring HIDS)?

## Status

**Exploration phase.** Powerful but adds complexity.

## Related Documents

- `patch-management.md` — Container CVEs, image updates, OS packages
- `../monitoring.md` — Existing observability stack
