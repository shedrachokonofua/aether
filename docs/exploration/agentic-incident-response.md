# Agentic Incident Response Exploration

AI-assisted diagnosis triggered by infrastructure alerts, with human-in-the-loop for all actions.

## Goal

Transform alerts from "something is wrong" into "here's what's wrong and how to fix it":

1. **Alert triggers flow** — Grafana fires webhook, Kestra flow starts
2. **Agent investigates** — AIAgent queries Prometheus, Loki, and Fleet (osquery)
3. **Agent explains** — Diagnosis with evidence posted to Matrix
4. **Human fixes** — Admin takes manual action based on diagnosis

No automated remediation. The agent investigates and explains; humans decide and act.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                        Agentic Incident Response                                 │
│                                                                                  │
│   ┌─────────────────────────────────────────────────────────────────────────┐   │
│   │                         Alert Trigger                                    │   │
│   │                                                                          │   │
│   │   Grafana Alert ──► Webhook ──► Kestra Flow                             │   │
│   │                                      │                                   │   │
│   └──────────────────────────────────────┼───────────────────────────────────┘   │
│                                          ▼                                       │
│   ┌─────────────────────────────────────────────────────────────────────────┐   │
│   │                         Agent Investigation                              │   │
│   │                                                                          │   │
│   │                      ┌──────────────┐                                    │   │
│   │                      │   AIAgent    │                                    │   │
│   │                      │   (Claude)   │                                    │   │
│   │                      └──────┬───────┘                                    │   │
│   │                             │                                            │   │
│   │         ┌───────────────────┼───────────────────┐                       │   │
│   │         ▼                   ▼                   ▼                       │   │
│   │   ┌───────────┐      ┌───────────┐      ┌───────────┐                   │   │
│   │   │ Grafana   │      │ Grafana   │      │  Fleet    │                   │   │
│   │   │ MCP       │      │ MCP       │      │  API      │                   │   │
│   │   │(Prometheus)│     │ (Loki)    │      │ (osquery) │                   │   │
│   │   └───────────┘      └───────────┘      └───────────┘                   │   │
│   │                                                                          │   │
│   │   Metrics            Logs               System State                     │   │
│   │   "when/how much"    "what happened"    "what's running now"            │   │
│   │                                                                          │   │
│   └──────────────────────────────────────────────────────────────────────────┘   │
│                                          │                                       │
│                                          ▼                                       │
│   ┌─────────────────────────────────────────────────────────────────────────┐   │
│   │                      Human-in-the-Loop                                   │   │
│   │                                                                          │   │
│   │   ┌─────────────────────────────────────────────────────────────────┐   │   │
│   │   │  Matrix #incidents                                               │   │   │
│   │   │                                                                   │   │   │
│   │   │  🔍 Diagnosis: High CPU on gitlab-runner-01                      │   │   │
│   │   │                                                                   │   │   │
│   │   │  Evidence:                                                        │   │   │
│   │   │  • osquery: process 'runner' at 98% CPU for 12 min               │   │   │
│   │   │  • Loki: "build loop detected" in job #4521 logs                 │   │   │
│   │   │  • Prometheus: CPU spike started 14 min ago                      │   │   │
│   │   │                                                                   │   │   │
│   │   │  Suggested fix: Cancel job #4521, restart runner service         │   │   │
│   │   │                                                                   │   │   │
│   │   └─────────────────────────────────────────────────────────────────┘   │   │
│   │                                                                          │   │
│   │   Human reads diagnosis → Human takes action manually                   │   │
│   │                                                                          │   │
│   └──────────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Why Kestra

Kestra provides all the primitives needed for this workflow, configured declaratively:

| Requirement           | Kestra Solution                 |
| --------------------- | ------------------------------- |
| Alert webhook trigger | Native `Webhook` trigger        |
| AI agent with tools   | `AIAgent` task with MCP support |
| Query Prometheus/Loki | MCP client → Grafana MCP server |
| Query system state    | HTTP task → Fleet API           |
| Notifications         | Slack/webhook → Matrix          |
| Audit logging         | Native execution logs → Loki    |
| IaC deployment        | Official Terraform provider     |

### Comparison with Temporal

| Aspect             | Temporal                   | Kestra                     |
| ------------------ | -------------------------- | -------------------------- |
| Config style       | Code-first (Go/Python SDK) | YAML-first                 |
| Terraform provider | ❌ None                    | ✅ Official                |
| AI agent support   | DIY                        | ✅ Native `AIAgent`        |
| MCP integration    | DIY                        | ✅ Built-in MCP clients    |
| Prometheus/Loki    | DIY clients                | ✅ Via Grafana MCP         |
| Learning curve     | High                       | Low                        |
| Workers needed     | Yes (per language)         | No (built-in)              |

## Components

### Kestra AIAgent

The [Kestra AI plugin](https://github.com/kestra-io/plugin-ai) provides an `AIAgent` task that orchestrates tool usage dynamically:

```yaml
- id: investigate
  type: io.kestra.plugin.ai.agent.AIAgent
  provider:
    type: anthropic
    model: claude-sonnet-4-20250514
    apiKey: "{{ secret('ANTHROPIC_API_KEY') }}"
  systemPrompt: |
    You are an SRE assistant for Aether homelab infrastructure.

    Your role:
    1. Investigate infrastructure issues using provided tools
    2. Gather evidence from metrics, logs, and system state
    3. Explain what's wrong and suggest fixes for the human to execute

    You have access to:
    - Prometheus (metrics): CPU, memory, disk, network, service health
    - Loki (logs): Application logs, system logs, error messages
    - Fleet/osquery (system state): Processes, ports, packages, users, files

    Guidelines:
    - Query multiple sources to build a complete picture
    - Be specific about what you found and where
    - Suggest concrete actions the human can take
    - You CANNOT execute fixes - only investigate and explain
  tools:
    # Grafana MCP for Prometheus and Loki
    - type: io.kestra.plugin.ai.mcp.SseMcpClient
      url: "{{ vars.grafana_mcp_url }}"
  prompt: |
    Alert: {{ inputs.alertname }}
    Instance: {{ inputs.instance }}
    Severity: {{ inputs.severity }}
    Summary: {{ inputs.summary }}

    Investigate this issue. Query metrics, logs, and system state to understand what's happening.
```

**Agent data sources:**

| Source     | What it provides                          | How accessed           |
| ---------- | ----------------------------------------- | ---------------------- |
| Prometheus | Time-series metrics, alerting context     | Grafana MCP            |
| Loki       | Logs, errors, stack traces                | Grafana MCP            |
| Fleet      | System state (processes, ports, packages) | HTTP task              |
| Wazuh      | Security events, FIM (file changed)       | Loki (alerts shipped)  |

If these aren't enough (e.g., need file contents), the agent requests the human to retrieve it.

The agent is read-only — it investigates and explains, but cannot execute any changes. If it needs information it can't access (file contents, etc.), it tells the human what to run.

### Grafana MCP Server

The existing Grafana MCP server provides tool access to:

- `query_prometheus` — PromQL queries for metrics
- `query_loki_logs` — LogQL queries for logs
- `get_dashboard_by_uid` — Dashboard context
- `list_alert_rules` — See what else is firing
- `search_dashboards` — Find relevant dashboards

### Fleet API (osquery)

Fleet provides SQL-based queries across all hosts. The agent uses HTTP tasks to query Fleet before investigation:

```yaml
- id: query-fleet
  type: io.kestra.plugin.core.http.Request
  uri: "{{ vars.fleet_url }}/api/v1/fleet/queries/run"
  method: POST
  headers:
    Authorization: "Bearer {{ secret('FLEET_API_TOKEN') }}"
  contentType: application/json
  body: |
    {
      "query": "SELECT pid, name, cmdline, resident_size, cpu_time FROM processes ORDER BY cpu_time DESC LIMIT 10",
      "selected": {
        "hosts": ["{{ inputs.instance }}"]
      }
    }
```

**Useful osquery tables for investigation:**

| Query                                                           | Purpose                    |
| --------------------------------------------------------------- | -------------------------- |
| `SELECT * FROM processes ORDER BY cpu_time DESC LIMIT 10`       | Top CPU consumers          |
| `SELECT * FROM listening_ports`                                 | What's listening where     |
| `SELECT * FROM rpm_packages WHERE name LIKE '%openssl%'`        | Package versions           |
| `SELECT * FROM file WHERE path = '/etc/caddy/Caddyfile'`        | File metadata (not content)|
| `SELECT * FROM logged_in_users`                                 | Who's logged in            |
| `SELECT * FROM last WHERE type = 7`                             | Recent logins              |

Fleet is read-only by design — perfect for investigation without risk.

### Human-in-the-Loop

The agent posts diagnosis to Matrix. Human reads and acts manually — no automated execution.

#### Matrix Notification

```
┌─────────────────────────────────────────────────────────────────┐
│ #incidents                                                       │
├─────────────────────────────────────────────────────────────────┤
│ 🔍 Aether Bot                                        10:34 AM   │
│ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│ INVESTIGATION: High CPU on gitlab-runner-01                     │
│                                                                  │
│ 📊 Evidence:                                                     │
│ • Prometheus: CPU at 98% for 12 min (spike started 10:22)       │
│ • osquery: process 'gitlab-runner' using 95% CPU                │
│ • osquery: 47 child processes spawned by runner                 │
│ • Loki: "build loop detected" in job #4521 logs                 │
│                                                                  │
│ 🔍 Diagnosis:                                                    │
│ Runner process in build loop. Job #4521 has a recursive         │
│ script spawning processes indefinitely. Started after           │
│ commit abc123 to infra/deploy 14 minutes ago.                   │
│                                                                  │
│ 💡 Suggested fix:                                                │
│ 1. Cancel job #4521: gitlab-ci cancel 4521                      │
│ 2. Restart runner: systemctl restart gitlab-runner              │
│ 3. Review commit abc123 in infra/deploy                         │
│                                                                  │
│ 🔗 Kestra: https://kestra.home.shdr.ch/ui/exec/abc123           │
│ 📊 Dashboard: https://grafana.home.shdr.ch/d/gitlab-runner      │
└─────────────────────────────────────────────────────────────────┘
```

No approval buttons, no automated execution. Human reads diagnosis, decides what to do, and does it themselves via SSH/Cockpit/UI.

#### Escalation Pattern

When the agent needs information it can't access (e.g., file contents), it requests help:

```
🔍 INVESTIGATION: ServiceDown on gateway-stack

## Diagnosis (75% confidence)
Config change likely caused Caddy crash.

## Evidence
- Loki: "parse error at line 47"
- osquery: caddy not running, was running 15 min ago
- Wazuh: /etc/caddy/Caddyfile modified 14 min ago (hash changed)

## Suggested Fix
Review and fix Caddyfile syntax error at line 47.

## ⚠️ Additional Info Needed
To confirm root cause, I need to see the actual config.
Run: ssh gateway-stack "sed -n '45,50p' /etc/caddy/Caddyfile"
```

The agent does 90% of the investigation with read-only access. Human fills gaps when needed.

### Audit Trail

All investigations logged to Loki via Kestra's native logging:

```yaml
- id: audit-log
  type: io.kestra.plugin.core.log.Log
  level: INFO
  message: |
    INCIDENT_INVESTIGATION: {
      "execution_id": "{{ execution.id }}",
      "alert": {
        "name": "{{ inputs.alertname }}",
        "instance": "{{ inputs.instance }}",
        "severity": "{{ inputs.severity }}"
      },
      "investigation": {{ outputs.investigate.response | json }},
      "notified": true
    }
```

The audit trail shows:
- What alert triggered investigation
- What the agent queried
- What diagnosis was produced
- When notification was sent

Human actions taken after notification are tracked in their respective systems (Cockpit, GitLab, etc.).

## Complete Workflow

### Incident Investigation Flow

```yaml
id: incident-investigation
namespace: platform.incidents

inputs:
  - id: alertname
    type: STRING
  - id: instance
    type: STRING
  - id: severity
    type: STRING
    defaults: "warning"
  - id: summary
    type: STRING
    defaults: ""
  - id: runbook_url
    type: STRING
    defaults: ""

variables:
  grafana_mcp_url: "http://grafana-mcp.monitoring-stack.svc:8080/sse"
  fleet_url: "http://fleet.monitoring-stack.svc:8080"
  matrix_webhook: "{{ secret('MATRIX_INCIDENT_WEBHOOK') }}"

tasks:
  # 1. Notify that investigation is starting
  - id: notify-start
    type: io.kestra.plugin.notifications.slack.SlackIncomingWebhook
    url: "{{ vars.matrix_webhook }}"
    payload: |
      {
        "text": "🔍 Investigating: {{ inputs.alertname }} on {{ inputs.instance }}"
      }

  # 2. Gather system state from Fleet/osquery
  - id: query-fleet-processes
    type: io.kestra.plugin.core.http.Request
    uri: "{{ vars.fleet_url }}/api/v1/fleet/queries/run"
    method: POST
    headers:
      Authorization: "Bearer {{ secret('FLEET_API_TOKEN') }}"
    contentType: application/json
    body: |
      {
        "query": "SELECT pid, name, cmdline, resident_size, cpu_time FROM processes ORDER BY cpu_time DESC LIMIT 15",
        "selected": {
          "hosts": ["{{ inputs.instance }}"]
        }
      }

  - id: query-fleet-ports
    type: io.kestra.plugin.core.http.Request
    uri: "{{ vars.fleet_url }}/api/v1/fleet/queries/run"
    method: POST
    headers:
      Authorization: "Bearer {{ secret('FLEET_API_TOKEN') }}"
    contentType: application/json
    body: |
      {
        "query": "SELECT p.name, p.pid, l.port, l.address, l.protocol FROM processes p JOIN listening_ports l ON p.pid = l.pid",
        "selected": {
          "hosts": ["{{ inputs.instance }}"]
        }
      }

  # 3. AI Agent investigates using all data sources
  - id: investigate
    type: io.kestra.plugin.ai.agent.AIAgent
    provider:
      type: anthropic
      model: claude-sonnet-4-20250514
      apiKey: "{{ secret('ANTHROPIC_API_KEY') }}"
    systemPrompt: |
      You are an SRE assistant for Aether homelab infrastructure.

      Your role:
      1. Investigate infrastructure issues using provided tools and context
      2. Gather evidence from metrics (Prometheus), logs (Loki), and system state (osquery)
      3. Explain what's wrong and suggest fixes for the human to execute

      You have pre-gathered osquery data:
      - Top processes by CPU: {{ outputs['query-fleet-processes'].body | json }}
      - Listening ports: {{ outputs['query-fleet-ports'].body | json }}

      Use the Grafana MCP tools to query Prometheus metrics and Loki logs.

      Guidelines:
      - Query multiple sources to build a complete picture
      - Be specific about what you found and where
      - Suggest concrete actions the human can take (commands, UI actions)
      - Include relevant links (dashboards, runbooks)
      - You CANNOT execute fixes - only investigate and explain

      Output format (use this structure):
      ```
      ## Diagnosis
      [1-2 sentence summary]

      ## Evidence
      - [source]: [finding]
      - [source]: [finding]

      ## Suggested Fix
      1. [specific action with command if applicable]
      2. [specific action with command if applicable]

      ## Links
      - [relevant dashboard/runbook URLs]
      ```
    tools:
      - type: io.kestra.plugin.ai.mcp.SseMcpClient
        url: "{{ vars.grafana_mcp_url }}"
    prompt: |
      Alert: {{ inputs.alertname }}
      Instance: {{ inputs.instance }}
      Severity: {{ inputs.severity }}
      Summary: {{ inputs.summary }}
      Runbook: {{ inputs.runbook_url }}

      Investigate this issue using Prometheus metrics and Loki logs.
      I've already gathered osquery data for processes and ports.

  # 4. Post diagnosis to Matrix
  - id: notify-diagnosis
    type: io.kestra.plugin.notifications.slack.SlackIncomingWebhook
    url: "{{ vars.matrix_webhook }}"
    payload: |
      {
        "text": "🔍 *INVESTIGATION: {{ inputs.alertname }} on {{ inputs.instance }}*\n\n{{ outputs.investigate.response }}\n\n🔗 Kestra: https://kestra.home.shdr.ch/ui/executions/platform.incidents/incident-investigation/{{ execution.id }}"
      }

  # 5. Audit log
  - id: audit-log
    type: io.kestra.plugin.core.log.Log
    level: INFO
    message: |
      INCIDENT_INVESTIGATION: {
        "execution_id": "{{ execution.id }}",
        "alert": "{{ inputs.alertname }}",
        "instance": "{{ inputs.instance }}",
        "severity": "{{ inputs.severity }}",
        "investigation": "completed",
        "notified": true
      }

triggers:
  - id: grafana-webhook
    type: io.kestra.core.models.triggers.types.Webhook
    key: "{{ secret('INCIDENT_WEBHOOK_KEY') }}"

errors:
  - id: notify-error
    type: io.kestra.plugin.notifications.slack.SlackIncomingWebhook
    url: "{{ vars.matrix_webhook }}"
    payload: |
      {
        "text": "❌ Investigation failed for {{ inputs.alertname }}\nExecution: {{ execution.id }}\nError: {{ error.message }}"
      }
```

That's it. No remediation flows, no approval gates, no OPA. The agent investigates and reports; you act.

## Tofu Configuration

### Provider Setup

```hcl
# tofu/home/kestra.tf

terraform {
  required_providers {
    kestra = {
      source  = "kestra-io/kestra"
      version = "~> 0.18"
    }
  }
}

provider "kestra" {
  url = "https://kestra.home.shdr.ch"
  # Auth via Keycloak OIDC handled by Caddy forward_auth
}
```

### Namespace

```hcl
resource "kestra_namespace" "incidents" {
  namespace_id = "platform.incidents"
  description  = "Incident investigation workflows"
}
```

### Flow Deployment

```hcl
resource "kestra_flow" "incident_investigation" {
  namespace = kestra_namespace.incidents.namespace_id
  flow_id   = "incident-investigation"
  content   = file("${path.module}/flows/incident-investigation.yml")
}
```

### Secrets

```hcl
resource "kestra_kv" "anthropic_key" {
  namespace = "platform"
  key       = "ANTHROPIC_API_KEY"
  value     = data.vault_generic_secret.kestra.data["anthropic_api_key"]
  type      = "SECRET"
}

resource "kestra_kv" "incident_webhook_key" {
  namespace = "platform"
  key       = "INCIDENT_WEBHOOK_KEY"
  value     = random_password.webhook_key.result
  type      = "SECRET"
}

resource "kestra_kv" "fleet_api_token" {
  namespace = "platform"
  key       = "FLEET_API_TOKEN"
  value     = data.vault_generic_secret.kestra.data["fleet_api_token"]
  type      = "SECRET"
}
```

### Grafana Contact Point

```hcl
# Configure Grafana to send alerts to Kestra webhook

resource "grafana_contact_point" "kestra_incidents" {
  name = "kestra-incident-investigation"

  webhook {
    url = "https://kestra.home.shdr.ch/api/v1/executions/webhook/platform.incidents/incident-investigation/${random_password.webhook_key.result}"

    http_method = "POST"

    # Map Grafana alert labels to Kestra inputs
    settings = jsonencode({
      alertname   = "{{ .Labels.alertname }}"
      instance    = "{{ .Labels.instance }}"
      severity    = "{{ .Labels.severity }}"
      summary     = "{{ .Annotations.summary }}"
      runbook_url = "{{ .Annotations.runbook_url }}"
    })
  }
}
```

## Integration with Existing Stack

### Alert → Kestra Flow

```yaml
# Grafana alerting rule routed to investigation
- alert: HighCPU
  expr: avg(rate(node_cpu_seconds_total{mode!="idle"}[5m])) by (instance) > 0.9
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "High CPU on {{ $labels.instance }}"
    runbook_url: "https://docs.home.shdr.ch/runbooks/high-cpu"
```

Route these alerts to the `kestra-incident-investigation` contact point.

### Agent → Grafana MCP

The Grafana MCP server exposes:

- `mcp_grafana_query_prometheus` — PromQL instant/range queries
- `mcp_grafana_query_loki_logs` — LogQL queries
- `mcp_grafana_list_alert_rules` — See what else is firing
- `mcp_grafana_get_dashboard_by_uid` — Get dashboard context
- `mcp_grafana_search_dashboards` — Find relevant dashboards

### Agent → Fleet API

Fleet's REST API allows osquery queries. The flow pre-queries common data (processes, ports) and passes results to the AIAgent as context. The agent can request additional queries if needed.

Key endpoints:
- `POST /api/v1/fleet/queries/run` — Run live query against hosts
- `GET /api/v1/fleet/hosts` — List hosts and their status
- `GET /api/v1/fleet/hosts/{id}` — Get host details including software inventory

### Notification → Matrix

The flow posts investigation results directly to Matrix via webhook. No approval mechanism needed — the human reads the diagnosis and decides what to do.

For ntfy push notifications on mobile, add a parallel notification task:

```yaml
- id: notify-ntfy
  type: io.kestra.plugin.core.http.Request
  uri: "https://ntfy.home.shdr.ch/incidents"
  method: POST
  headers:
    Title: "{{ inputs.alertname }} on {{ inputs.instance }}"
    Priority: "{{ inputs.severity == 'critical' ? 'urgent' : 'default' }}"
    Tags: "warning,investigation"
  body: "Investigation complete. Check Matrix for details."
```

## Example Scenarios

### Scenario 1: Disk Space Alert

```
Alert: DiskSpaceLow on media-stack (12% free)

Agent queries:
- Prometheus: node_filesystem_avail_bytes{instance="media-stack"}
- Loki: {job="media-stack"} |= "disk"
- osquery: SELECT path, size FROM file WHERE directory = '/var/lib/containers'

Matrix notification:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔍 INVESTIGATION: DiskSpaceLow on media-stack

## Diagnosis
Container storage filled by completed downloads sitting in
/var/lib/containers/storage/downloads instead of NFS mount.

## Evidence
- Prometheus: disk usage 88%, climbing 2%/hour for 6 hours
- osquery: downloads/ contains 47GB, oldest file 12 days
- Loki: no errors, qBittorrent healthy

## Suggested Fix
1. Move completed downloads to NFS:
   mv /var/lib/containers/storage/downloads/* /mnt/media/downloads/
2. Fix qBittorrent config to use NFS path directly
3. Consider cron job to prevent recurrence

## Links
- Dashboard: https://grafana.home.shdr.ch/d/media-stack
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Human action: SSH to media-stack, move files, update config
```

### Scenario 2: Security Alert

```
Alert: SuricataHighSeverityAlert (severity 1)

Agent queries:
- Loki: {job="suricata"} | json | severity=1
- Prometheus: suricata_alerts_total{severity="1"}
- osquery: SELECT * FROM listening_ports on affected host

Matrix notification:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔍 INVESTIGATION: SuricataHighSeverityAlert

## Diagnosis
ET EXPLOIT attempt from 10.0.4.15 (IoT VLAN) targeting
internal service on port 8080. Source is smart-plug-03.

## Evidence
- Suricata: 23 alerts in 5 minutes, signature ET EXPLOIT
- Source MAC: aa:bb:cc:dd:ee:ff (TP-Link Smart Plug)
- osquery: No unexpected processes on target host
- Target service (caddy) responding normally

## Suggested Fix
1. Block source temporarily:
   ssh router "nft add rule inet filter input ip saddr 10.0.4.15 drop"
2. Capture traffic for analysis:
   tcpdump -i br0 host 10.0.4.15 -w /tmp/iot-capture.pcap
3. Factory reset smart-plug-03 if confirmed compromised

## Links
- Suricata dashboard: https://grafana.home.shdr.ch/d/suricata
- IoT device inventory: https://fleet.home.shdr.ch/hosts?label=iot
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Human action: Block IP, capture traffic, investigate device
```

### Scenario 3: Service Crash (with escalation)

```
Alert: ServiceDown on caddy (gateway-stack)

Agent queries:
- Prometheus: up{job="caddy"}
- Loki: {job="caddy"} |= "error" | last 30m
- osquery: SELECT * FROM processes WHERE name = 'caddy'
- Wazuh (via Loki): {log_source="wazuh"} |= "Caddyfile"

Matrix notification:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔍 INVESTIGATION: ServiceDown on gateway-stack

## Diagnosis (85% confidence)
Caddy crashed due to config syntax error at line 47.
Config was modified 12 minutes ago.

## Evidence
- Prometheus: up=0 since 10:34, was up=1 continuously before
- Loki: "Error: parsing /etc/caddy/Caddyfile:47: unexpected token"
- osquery: caddy process not running
- Wazuh FIM: /etc/caddy/Caddyfile modified at 10:33 (hash changed)

## Suggested Fix
1. Fix the syntax error at line 47
2. Restart caddy: systemctl restart caddy

## ⚠️ Additional Info Needed
To see the actual error, run:
  ssh gateway-stack "sed -n '45,50p' /etc/caddy/Caddyfile"

Or validate the config:
  ssh gateway-stack "caddy validate --config /etc/caddy/Caddyfile"

## Links
- Caddy logs: https://grafana.home.shdr.ch/explore?datasource=loki&query={job="caddy"}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Human action: 
- Runs the suggested ssh command to see line 47
- Sees typo, fixes it
- Restarts caddy
- Alert resolves
```

## Deployment

### Components

| Component   | Location         | Resources       | Status            |
| ----------- | ---------------- | --------------- | ----------------- |
| Fleet       | Monitoring Stack | Already running | ✅ Deployed       |
| Grafana MCP | Monitoring Stack | 256MB RAM       | ✅ Available      |
| Kestra      | TBD              | 2GB RAM, 2 vCPU | Planned           |

No OPA, no remediation flows, no Matrix bot needed for this approach.

### Kestra Deployment

See `workflow-orchestration.md` for full Kestra deployment. Key additions for incident investigation:

```yaml
# Helm values additions
kestra:
  configuration:
    kestra:
      plugins:
        repositories:
          - id: kestra-ai
            type: MAVEN
            url: https://packages.kestra.io/maven

      # AI plugin config
      ai:
        anthropic:
          api-key: "${ANTHROPIC_API_KEY}"
```

### Fleet API Token

Generate a Fleet API token for Kestra to query osquery data:

```bash
# In Fleet UI: Settings → Users → Create API-only user
# Or via fleetctl:
fleetctl login
fleetctl user create --email kestra@aether.local --name "Kestra" --api-only
```

Store the token in OpenBao at `secret/kestra/fleet_api_token`.

## Costs

| Item             | One-Time          | Ongoing                  |
| ---------------- | ----------------- | ------------------------ |
| Kestra setup     | Part of platform  | Already planned          |
| Fleet setup      | Already deployed  | Running on monitoring VM |
| Flow development | 2-4 hours         | Iterative                |
| Claude API       | —                 | ~$0.01-0.05 per incident |

Simpler than before: no OPA to write policies for, no remediation flows to maintain, no Matrix bot to develop.

## Decision Factors

### Pros

- **Simple** — Investigation only, no execution complexity
- **Safe** — Read-only by design, can't break anything
- **Declarative** — Entire workflow in YAML, managed via Tofu
- **No custom code** — AIAgent + MCP + HTTP tasks
- **Human judgment** — You decide what actions to take
- **Audit trail** — Full investigation history in Kestra

### Cons

- **No automation** — Still need human to execute fixes
- **Kestra dependency** — Another platform component
- **MCP maturity** — Kestra MCP support is newer
- **Claude costs** — API usage per incident
- **Investigation quality** — Depends on prompt engineering

### When to Use

- You want better signal-to-noise on alerts
- "What's wrong?" takes time to figure out manually
- After-hours triage while you decide if it needs immediate action
- Learning how AI agents perform before trusting execution

### When to Skip

- Alerts are already clear enough
- You enjoy investigating manually
- Don't want to pay for Claude API calls

## Open Questions

1. **MCP reliability** — Is Kestra's MCP client stable enough for production?
2. **Context window** — How much Prometheus/Loki/osquery data before hitting token limits?
3. **Fleet query performance** — Live queries add latency; pre-query common data or query on-demand?
4. **Investigation quality** — How to track and improve diagnosis accuracy?
5. **Alert fatigue** — Which alerts should trigger investigation vs just notify?

## Related Documents

- `osquery.md` — Fleet deployment and osquery tables
- `workflow-orchestration.md` — Kestra deployment
- `network-security.md` — Suricata/Wazuh for security context
- `../monitoring.md` — Grafana alerting stack
- `../communication.md` — Matrix/ntfy for notifications

## Status

**Exploration phase.** Depends on Kestra deployment from workflow-orchestration.md. Fleet already deployed.

## Implementation

### Prerequisites

1. Deploy Kestra (per workflow-orchestration.md)
2. Verify Fleet is accessible from Kestra (already deployed)
3. Verify Grafana MCP server is accessible

### Steps

1. Create `platform.incidents` namespace in Kestra
2. Deploy `incident-investigation` flow via Tofu
3. Create Fleet API token, store in OpenBao
4. Configure Grafana contact point to trigger flow
5. Test with a manual alert trigger
6. Iterate on prompt based on investigation quality

### Future Options

If you later want automated execution:

1. Add remediation sub-flows (restart-service, rollback-config, etc.)
2. Add `Pause` task for approval before execution
3. Optionally add OPA for policy guardrails
4. Start with explicit approval for everything, relax over time

But start simple: investigate and notify. The human loop is the safest guardrail.
