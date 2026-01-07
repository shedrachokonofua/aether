# Agentic Incident Response Exploration

AI-assisted diagnosis and remediation triggered by infrastructure alerts, with policy-as-code guardrails and human-in-the-loop approval.

## Goal

Transform alerts from "something is wrong" into "here's what's wrong and how to fix it":

1. **Alert triggers flow** — Grafana fires webhook, Kestra flow starts
2. **Agent diagnoses** — AIAgent queries Prometheus/Loki via MCP, correlates data
3. **Agent proposes fix** — Generates remediation with reasoning
4. **Policy validates** — OPA checks if action is allowed
5. **Human approves** — Admin reviews in Matrix or Kestra UI, approves/rejects
6. **Flow executes** — If approved, runs remediation sub-flow with audit trail

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
│   │                         Agent Orchestration                              │   │
│   │                                                                          │   │
│   │   ┌──────────────┐     ┌──────────────┐     ┌──────────────┐            │   │
│   │   │   Context    │     │   AIAgent    │     │   Policy     │            │   │
│   │   │   Tasks      │────►│   (Claude)   │────►│   Engine     │            │   │
│   │   │              │     │              │     │   (OPA)      │            │   │
│   │   └──────────────┘     └──────────────┘     └──────────────┘            │   │
│   │         │                     │                    │                     │   │
│   │         ▼                     ▼                    ▼                     │   │
│   │   ┌──────────────────────────────────────────────────────────────────┐  │   │
│   │   │                     MCP Tool Access                              │  │   │
│   │   │                                                                   │  │   │
│   │   │   Grafana MCP (Prometheus, Loki) · KestraFlow (Ansible)          │  │   │
│   │   └──────────────────────────────────────────────────────────────────┘  │   │
│   │                                                                          │   │
│   └──────────────────────────────────────────────────────────────────────────┘   │
│                                          │                                       │
│                                          ▼                                       │
│   ┌─────────────────────────────────────────────────────────────────────────┐   │
│   │                      Human-in-the-Loop                                   │   │
│   │                                                                          │   │
│   │   Matrix Bot ◄─────────── Pause Task ───────────► Kestra UI             │   │
│   │       │                       │                        │                 │   │
│   │       └───────── Resume API (approve/reject) ──────────┘                │   │
│   │                                                                          │   │
│   └──────────────────────────────────────────────────────────────────────────┘   │
│                                          │                                       │
│                                          ▼                                       │
│   ┌─────────────────────────────────────────────────────────────────────────┐   │
│   │                         Execution + Audit                                │   │
│   │                                                                          │   │
│   │   Kestra Logs ──► Loki       KestraFlow ──► Ansible ──► Target          │   │
│   │                                                                          │   │
│   └──────────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Why Kestra

Kestra provides all the primitives needed for this workflow, configured declaratively:

| Requirement           | Kestra Solution                     |
| --------------------- | ----------------------------------- |
| Alert webhook trigger | Native `Webhook` trigger            |
| AI agent with tools   | `AIAgent` task with MCP support     |
| Query Prometheus/Loki | MCP client → Grafana MCP server     |
| Human approval        | `Pause` task with `onResume` inputs |
| Execute remediation   | `KestraFlow` triggers sub-flows     |
| Policy checks         | HTTP task → OPA API                 |
| Audit logging         | Native execution logs → Loki        |
| IaC deployment        | Official Terraform provider         |

### Comparison with Temporal

| Aspect             | Temporal                   | Kestra                       |
| ------------------ | -------------------------- | ---------------------------- |
| Config style       | Code-first (Go/Python SDK) | YAML-first                   |
| Terraform provider | ❌ None                    | ✅ Official                  |
| AI agent support   | DIY                        | ✅ Native `AIAgent`          |
| MCP integration    | DIY                        | ✅ Built-in MCP clients      |
| Human tasks        | Signal-based (code)        | ✅ `Pause` with typed inputs |
| Prometheus/Loki    | DIY clients                | ✅ Via Grafana MCP           |
| Learning curve     | High                       | Low                          |
| Workers needed     | Yes (per language)         | No (built-in)                |

## Components

### Kestra AIAgent

The [Kestra AI plugin](https://github.com/kestra-io/plugin-ai) provides an `AIAgent` task that orchestrates tool usage dynamically:

```yaml
- id: diagnose
  type: io.kestra.plugin.ai.agent.AIAgent
  provider:
    type: anthropic
    model: claude-sonnet-4-20250514
    apiKey: "{{ secret('ANTHROPIC_API_KEY') }}"
  systemPrompt: |
    You are an SRE assistant for Aether homelab infrastructure.

    Your role:
    1. Diagnose infrastructure issues using provided tools
    2. Propose specific, minimal remediation actions
    3. Explain your reasoning clearly for human review

    Guidelines:
    - Query systems to gather facts, don't assume
    - Prefer non-destructive actions when possible
    - Propose ONE focused fix, not multiple changes
    - Always explain what could go wrong
  tools:
    # Grafana MCP for observability queries
    - type: io.kestra.plugin.ai.mcp.SseMcpClient
      url: "{{ vars.grafana_mcp_url }}"
    # Trigger remediation sub-flows
    - type: io.kestra.plugin.ai.KestraFlow
      namespace: platform.remediation
      allowedFlows:
        - restart-service
        - rollback-config
        - scale-deployment
  prompt: |
    Alert: {{ inputs.alertname }}
    Instance: {{ inputs.instance }}
    Severity: {{ inputs.severity }}
    Summary: {{ inputs.summary }}

    Diagnose this issue and propose a remediation.
```

**Agent capabilities:**

| Tool Type              | Purpose                            | Pre-approval       |
| ---------------------- | ---------------------------------- | ------------------ |
| MCP (Grafana)          | Query Prometheus, Loki, dashboards | ✅                 |
| KestraFlow (read-only) | Dry-run Ansible playbooks          | ✅                 |
| KestraFlow (apply)     | Execute remediation                | ❌ (post-approval) |

### Grafana MCP Server

The existing Grafana MCP server provides tool access to:

- `query_prometheus` — PromQL queries
- `query_loki_logs` — LogQL queries
- `get_dashboard_by_uid` — Dashboard context
- `list_alert_rules` — Related alerts
- `search_dashboards` — Find relevant dashboards

The agent uses these tools to gather diagnostic context before proposing a fix.

### Policy Engine (OPA)

Open Policy Agent validates proposed actions before human review:

```rego
# policy/incident-response.rego

package aether.incident_response

import rego.v1

# Default deny
default allow := false

# Allow read-only actions always
allow if {
    input.action.type in ["query", "check", "get", "dry-run"]
}

# Allow service restarts for non-critical services
allow if {
    input.action.type == "restart-service"
    not input.action.target in critical_services
    input.alert.severity != "critical"
}

# Block destructive actions on infrastructure
deny[msg] if {
    input.action.type in ["delete", "destroy", "purge"]
    input.action.target_type == "vm"
    msg := "Cannot delete VMs via automated response"
}

# Require human approval for any state changes
require_approval if {
    input.action.type in ["restart-service", "rollback-config", "scale-deployment"]
}

# Rate limiting: max 5 auto-remediations per hour per service
deny[msg] if {
    count(recent_remediations[input.action.target]) > 5
    msg := sprintf("Rate limit exceeded for %s", [input.action.target])
}

# Critical services that always require human approval
critical_services := {
    "openbao",
    "step-ca",
    "keycloak",
    "postgresql",
    "monitoring-stack"
}
```

**Policy check as Kestra task:**

```yaml
- id: policy-check
  type: io.kestra.plugin.core.http.Request
  uri: "{{ vars.opa_url }}/v1/data/aether/incident_response"
  method: POST
  contentType: application/json
  body: |
    {
      "input": {
        "action": {{ outputs.diagnose.proposedAction | json }},
        "alert": {
          "name": "{{ inputs.alertname }}",
          "severity": "{{ inputs.severity }}",
          "instance": "{{ inputs.instance }}"
        }
      }
    }
```

### Human-in-the-Loop

Two approval interfaces, same Kestra Resume API:

#### Kestra UI (Primary)

The `Pause` task with `onResume` inputs creates a native approval interface:

```yaml
- id: wait-for-approval
  type: io.kestra.plugin.core.flow.Pause
  onResume:
    - id: approved
      description: "Approve the proposed remediation?"
      type: BOOLEAN
      defaults: false
    - id: reason
      description: "Reason for decision"
      type: STRING
      defaults: ""
    - id: modifications
      description: "Modifications to proposed action (JSON)"
      type: STRING
      defaults: "{}"
```

When paused, the execution shows in Kestra UI with a Resume button that prompts for the typed inputs.

#### Matrix Bot

For mobile/async approval, a Matrix bot monitors the `#incidents` room:

```
┌─────────────────────────────────────────────────────────────────┐
│ #incidents                                                       │
├─────────────────────────────────────────────────────────────────┤
│ 🚨 Aether Bot                                        10:34 AM   │
│ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│ INCIDENT: High CPU on gitlab-runner-01                          │
│                                                                  │
│ 📊 Context:                                                      │
│ • CPU at 98% for 12 minutes                                     │
│ • 3 stuck CI jobs in project infra/deploy                       │
│ • Last deploy: 47 minutes ago                                   │
│                                                                  │
│ 🔍 Diagnosis:                                                    │
│ Runner process consuming excessive CPU due to a build           │
│ loop in job #4521. The .gitlab-ci.yml has a recursive           │
│ script that's spawning processes indefinitely.                  │
│                                                                  │
│ 💡 Proposed Fix:                                                 │
│ 1. Cancel job #4521 via GitLab API                              │
│ 2. Restart gitlab-runner service                                │
│                                                                  │
│ ⚠️  Risk: In-progress jobs will be terminated                   │
│                                                                  │
│ [✅ Approve] [❌ Reject] [🔗 View in Kestra]                     │
│                                                                  │
│ Flow: incident-response • Execution: abc123 • Timeout: 30m      │
└─────────────────────────────────────────────────────────────────┘
```

The bot calls Kestra's Resume API:

```bash
# Resume with approval
curl -X POST "https://kestra.home.shdr.ch/api/v1/executions/{executionId}/resume" \
  -H "Content-Type: application/json" \
  -d '{"approved": true, "reason": "Looks correct", "modifications": "{}"}'
```

### Execution + Audit

All executions logged natively by Kestra, shipped to Loki:

```yaml
# Kestra internal storage → Loki
- id: audit-log
  type: io.kestra.plugin.core.log.Log
  message: |
    {
      "execution_id": "{{ execution.id }}",
      "flow": "{{ flow.id }}",
      "alert": {
        "name": "{{ inputs.alertname }}",
        "instance": "{{ inputs.instance }}",
        "severity": "{{ inputs.severity }}"
      },
      "diagnosis": {{ outputs.diagnose.response | json }},
      "policy_decision": {{ outputs['policy-check'].body | json }},
      "approval": {
        "approved": {{ outputs['wait-for-approval'].onResume.approved }},
        "reason": "{{ outputs['wait-for-approval'].onResume.reason }}"
      },
      "remediation": {
        "flow": "{{ outputs.diagnose.proposedFlow }}",
        "status": "{{ outputs['execute-remediation'].state }}"
      }
    }
```

## Complete Workflow

### Main Incident Response Flow

````yaml
id: incident-response
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
  opa_url: "http://opa.platform.svc:8181"
  matrix_webhook: "{{ secret('MATRIX_INCIDENT_WEBHOOK') }}"

tasks:
  # 1. Notify that incident is being processed
  - id: notify-start
    type: io.kestra.plugin.notifications.slack.SlackIncomingWebhook
    url: "{{ vars.matrix_webhook }}"
    payload: |
      {
        "text": "🔍 Investigating: {{ inputs.alertname }} on {{ inputs.instance }}"
      }

  # 2. AI Agent diagnoses the issue
  - id: diagnose
    type: io.kestra.plugin.ai.agent.AIAgent
    provider:
      type: anthropic
      model: claude-sonnet-4-20250514
      apiKey: "{{ secret('ANTHROPIC_API_KEY') }}"
    systemPrompt: |
      You are an SRE assistant for Aether homelab infrastructure.

      Your role:
      1. Diagnose infrastructure issues using the Grafana MCP tools
      2. Propose a specific, minimal remediation action
      3. Explain your reasoning clearly for human review

      Available remediation flows:
      - restart-service: Restart a systemd service
      - rollback-config: Rollback to previous config version
      - scale-deployment: Scale a deployment up/down
      - clear-disk-space: Clean up disk space on a host

      Guidelines:
      - Query Prometheus metrics and Loki logs to understand the issue
      - Check related dashboards for context
      - Prefer non-destructive actions
      - Propose ONE focused fix
      - Output a JSON block with your proposed action:
        ```json
        {
          "diagnosis": "summary of what's wrong",
          "evidence": ["list of findings"],
          "proposedFlow": "flow-name",
          "proposedInputs": {"key": "value"},
          "risk": "what could go wrong",
          "confidence": 0.0-1.0
        }
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

      Diagnose this issue and propose a remediation.

  # 3. Check policy
  - id: policy-check
    type: io.kestra.plugin.core.http.Request
    uri: "{{ vars.opa_url }}/v1/data/aether/incident_response"
    method: POST
    contentType: application/json
    body: |
      {
        "input": {
          "action": {{ outputs.diagnose.proposedAction | json }},
          "alert": {
            "name": "{{ inputs.alertname }}",
            "severity": "{{ inputs.severity }}",
            "instance": "{{ inputs.instance }}"
          }
        }
      }

  # 4. Check if policy allows (with or without approval)
  - id: check-policy-result
    type: io.kestra.plugin.core.flow.If
    condition: "{{ outputs['policy-check'].body.result.deny | length > 0 }}"
    then:
      - id: policy-denied
        type: io.kestra.plugin.notifications.slack.SlackIncomingWebhook
        url: "{{ vars.matrix_webhook }}"
        payload: |
          {
            "text": "❌ Policy denied action for {{ inputs.alertname }}:\n{{ outputs['policy-check'].body.result.deny | join('\n') }}"
          }
      - id: fail-policy
        type: io.kestra.plugin.core.execution.Fail
        message: "Policy denied: {{ outputs['policy-check'].body.result.deny }}"

  # 5. Send approval request to Matrix
  - id: request-approval
    type: io.kestra.plugin.notifications.slack.SlackIncomingWebhook
    url: "{{ vars.matrix_webhook }}"
    payload: |
      {
        "text": "🚨 *INCIDENT: {{ inputs.alertname }}*\n\n📊 *Context:*\n{{ outputs.diagnose.evidence | join('\n• ') }}\n\n🔍 *Diagnosis:*\n{{ outputs.diagnose.diagnosis }}\n\n💡 *Proposed Fix:*\nFlow: `{{ outputs.diagnose.proposedFlow }}`\nInputs: `{{ outputs.diagnose.proposedInputs | json }}`\n\n⚠️ *Risk:* {{ outputs.diagnose.risk }}\n\n🔗 [Approve/Reject in Kestra](https://kestra.home.shdr.ch/ui/executions/platform.incidents/incident-response/{{ execution.id }})\n\nExecution: {{ execution.id }} • Timeout: 30m"
      }

  # 6. Wait for human approval
  - id: wait-for-approval
    type: io.kestra.plugin.core.flow.Pause
    timeout: PT30M
    onResume:
      - id: approved
        description: "Approve the proposed remediation?"
        type: BOOLEAN
        defaults: false
      - id: reason
        description: "Reason for decision"
        type: STRING
        defaults: ""

  # 7. Execute or skip based on approval
  - id: handle-approval
    type: io.kestra.plugin.core.flow.If
    condition: "{{ outputs['wait-for-approval'].onResume.approved }}"
    then:
      - id: execute-remediation
        type: io.kestra.plugin.core.flow.Subflow
        flowId: "{{ outputs.diagnose.proposedFlow }}"
        namespace: platform.remediation
        inputs: "{{ outputs.diagnose.proposedInputs }}"
        wait: true
      - id: notify-success
        type: io.kestra.plugin.notifications.slack.SlackIncomingWebhook
        url: "{{ vars.matrix_webhook }}"
        payload: |
          {
            "text": "✅ Remediation complete for {{ inputs.alertname }}\nExecution: {{ execution.id }}"
          }
    else:
      - id: notify-rejected
        type: io.kestra.plugin.notifications.slack.SlackIncomingWebhook
        url: "{{ vars.matrix_webhook }}"
        payload: |
          {
            "text": "⏭️ Remediation rejected for {{ inputs.alertname }}\nReason: {{ outputs['wait-for-approval'].onResume.reason }}"
          }

  # 8. Audit log
  - id: audit-log
    type: io.kestra.plugin.core.log.Log
    level: INFO
    message: |
      INCIDENT_AUDIT: {
        "execution_id": "{{ execution.id }}",
        "alert": "{{ inputs.alertname }}",
        "instance": "{{ inputs.instance }}",
        "diagnosis": "{{ outputs.diagnose.diagnosis }}",
        "proposed_flow": "{{ outputs.diagnose.proposedFlow }}",
        "approved": {{ outputs['wait-for-approval'].onResume.approved }},
        "reason": "{{ outputs['wait-for-approval'].onResume.reason }}"
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
        "text": "❌ Incident response failed for {{ inputs.alertname }}\nExecution: {{ execution.id }}\nError: {{ error.message }}"
      }
````

### Remediation Sub-Flows

```yaml
# platform.remediation/restart-service
id: restart-service
namespace: platform.remediation

inputs:
  - id: host
    type: STRING
  - id: service
    type: STRING

tasks:
  - id: restart
    type: io.kestra.plugin.scripts.shell.Commands
    taskRunner:
      type: io.kestra.plugin.kubernetes.runner.Kubernetes
      namespace: jobs
    commands:
      - |
        ansible -i "{{ inputs.host }}," -m systemd \
          -a "name={{ inputs.service }} state=restarted" \
          --become
```

```yaml
# platform.remediation/rollback-config
id: rollback-config
namespace: platform.remediation

inputs:
  - id: host
    type: STRING
  - id: config_path
    type: STRING
  - id: service
    type: STRING

tasks:
  - id: rollback
    type: io.kestra.plugin.scripts.shell.Commands
    taskRunner:
      type: io.kestra.plugin.kubernetes.runner.Kubernetes
      namespace: jobs
    commands:
      - |
        ansible-playbook -i "{{ inputs.host }}," \
          playbooks/common/rollback-config.yml \
          -e "config_path={{ inputs.config_path }}" \
          -e "service={{ inputs.service }}"
```

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
  description  = "Incident response workflows"
}

resource "kestra_namespace" "remediation" {
  namespace_id = "platform.remediation"
  description  = "Remediation sub-flows"
}
```

### Flow Deployment

```hcl
resource "kestra_flow" "incident_response" {
  namespace = kestra_namespace.incidents.namespace_id
  flow_id   = "incident-response"
  content   = file("${path.module}/flows/incident-response.yml")
}

resource "kestra_flow" "restart_service" {
  namespace = kestra_namespace.remediation.namespace_id
  flow_id   = "restart-service"
  content   = file("${path.module}/flows/remediation/restart-service.yml")
}

resource "kestra_flow" "rollback_config" {
  namespace = kestra_namespace.remediation.namespace_id
  flow_id   = "rollback-config"
  content   = file("${path.module}/flows/remediation/rollback-config.yml")
}
```

### Secrets (via External Secrets → Kestra)

```hcl
# Kestra reads secrets from K8s secrets mounted as env vars
# ESO syncs from OpenBao → K8s Secret → Kestra pod

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
```

### Grafana Contact Point

```hcl
# Configure Grafana to send alerts to Kestra webhook

resource "grafana_contact_point" "kestra_incidents" {
  name = "kestra-incident-response"

  webhook {
    url = "https://kestra.home.shdr.ch/api/v1/executions/webhook/platform.incidents/incident-response/${random_password.webhook_key.result}"

    http_method = "POST"

    # Map Grafana alert labels to Kestra inputs
    settings = jsonencode({
      alertname = "{{ .Labels.alertname }}"
      instance  = "{{ .Labels.instance }}"
      severity  = "{{ .Labels.severity }}"
      summary   = "{{ .Annotations.summary }}"
    })
  }
}
```

## Integration with Existing Stack

### Alert → Kestra Flow

```yaml
# Grafana alerting rule with agentic label
- alert: HighCPU
  expr: avg(rate(node_cpu_seconds_total{mode!="idle"}[5m])) by (instance) > 0.9
  for: 5m
  labels:
    severity: warning
    agentic: "true" # Route to Kestra
  annotations:
    summary: "High CPU on {{ $labels.instance }}"
    runbook_url: "https://docs.home.shdr.ch/runbooks/high-cpu"
```

### Agent → Grafana MCP

The Grafana MCP server (already configured in `.cursor/mcp.json`) exposes:

- `mcp_grafana_query_prometheus` — PromQL instant/range queries
- `mcp_grafana_query_loki_logs` — LogQL queries
- `mcp_grafana_list_alert_rules` — See firing alerts
- `mcp_grafana_get_dashboard_by_uid` — Get dashboard context

The AIAgent connects via `SseMcpClient` to query these tools during diagnosis.

### Approval → Matrix

Matrix bot polls Kestra API for paused executions:

```python
async def check_pending_approvals():
    """Poll Kestra for paused incident-response executions."""
    resp = await kestra.get("/api/v1/executions", params={
        "namespace": "platform.incidents",
        "flowId": "incident-response",
        "state": "PAUSED"
    })

    for execution in resp.json():
        # Format and post to Matrix if not already notified
        if execution["id"] not in notified:
            await matrix.send_approval_request(execution)
            notified.add(execution["id"])

async def handle_reaction(event):
    """Handle Matrix reaction to approve/reject."""
    if event.content.relates_to.key == "✅":
        await kestra.post(f"/api/v1/executions/{execution_id}/resume", json={
            "approved": True,
            "reason": f"Approved by {event.sender}"
        })
    elif event.content.relates_to.key == "❌":
        await kestra.post(f"/api/v1/executions/{execution_id}/resume", json={
            "approved": False,
            "reason": f"Rejected by {event.sender}"
        })
```

## Example Scenarios

### Scenario 1: Disk Space Alert

```
Alert: DiskSpaceLow on media-stack (12% free)

Agent queries via MCP:
- query_prometheus: node_filesystem_avail_bytes{instance="media-stack"}
- query_loki_logs: {job="media-stack"} |= "disk" | json

Diagnosis:
"Container storage filled by completed downloads. The qBittorrent
download directory is on container storage instead of NFS mount."

Proposed:
{
  "proposedFlow": "clear-disk-space",
  "proposedInputs": {
    "host": "media-stack",
    "paths": ["/var/lib/containers/storage/downloads"],
    "min_age_days": 7
  },
  "risk": "May delete files not yet moved to NFS",
  "confidence": 0.85
}

Policy: Allowed (file operations, non-critical service)
Approval: Required (state change)
Human: Approved
Result: 15GB freed, alert resolved
```

### Scenario 2: Security Alert

```
Alert: SuricataHighSeverityAlert (severity 1)

Agent queries via MCP:
- query_loki_logs: {job="suricata"} | json | severity=1
- query_prometheus: suricata_alerts_total{severity="1"}

Diagnosis:
"ET EXPLOIT attempt from 10.0.4.15 (IoT VLAN) targeting internal service.
Source is smart-plug-03, which shouldn't have HTTP client capabilities."

Proposed:
{
  "proposedFlow": "block-host",
  "proposedInputs": {
    "ip": "10.0.4.15",
    "reason": "Suspected compromised IoT device",
    "duration": "24h"
  },
  "risk": "Smart plug will be unreachable",
  "confidence": 0.92
}

Policy: Allowed (security response)
Approval: Required (firewall modification)
Human: Approved with note "Also capture traffic first"
Result: Host blocked, incident logged for follow-up
```

### Scenario 3: Auto-Remediation (Policy Allows Skip Approval)

```
Alert: ServiceDown on caddy (gateway-stack)

Agent queries via MCP:
- query_loki_logs: {job="caddy"} |= "error"
- query_prometheus: up{job="caddy"}

Diagnosis:
"Caddy failed due to config syntax error at line 47.
Git shows config change 12 minutes ago."

Proposed:
{
  "proposedFlow": "rollback-config",
  "proposedInputs": {
    "host": "gateway-stack",
    "config_path": "/etc/caddy/Caddyfile",
    "service": "caddy"
  },
  "risk": "Reverts to previous config state",
  "confidence": 0.95
}

Policy: Allowed WITHOUT approval (config rollback to known-good state)
Action: Executed automatically
Result: Caddy restored, admin notified
```

## Deployment

### New Components

| Component   | Location              | Resources       | Notes                                        |
| ----------- | --------------------- | --------------- | -------------------------------------------- |
| Kestra      | K8s cluster           | 2GB RAM, 2 vCPU | Already planned in workflow-orchestration.md |
| OPA         | Sidecar or standalone | 256MB RAM       | Policy evaluation                            |
| Matrix Bot  | Messaging Stack       | 128MB RAM       | Approval interface (optional)                |
| Grafana MCP | Monitoring Stack      | 256MB RAM       | Already available                            |

### Kestra Deployment

See `workflow-orchestration.md` for full Kestra deployment. Key additions for incident response:

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

## Costs

| Item             | One-Time        | Ongoing                  |
| ---------------- | --------------- | ------------------------ |
| Kestra setup     | Already planned | Part of platform         |
| OPA policies     | 2-4 hours       | Evolves with stack       |
| Matrix bot       | 2-4 hours       | Minimal                  |
| Flow development | 4-8 hours       | Iterative                |
| Claude API       | —               | ~$0.01-0.05 per incident |

## Decision Factors

### Pros

- **Declarative** — Entire workflow defined in YAML, managed via Tofu
- **No custom code** — AIAgent + MCP handles agent logic
- **Unified platform** — Same system for all automation (see workflow-orchestration.md)
- **Native observability** — Kestra logs → Loki, metrics → Prometheus
- **Audit trail** — Full execution history in Kestra UI
- **Faster iteration** — Change YAML, redeploy via Tofu

### Cons

- **Kestra dependency** — Another platform component (but already planned)
- **MCP maturity** — Kestra MCP support is newer
- **Claude costs** — API usage per incident
- **Agent quality** — Diagnosis depends on prompt engineering

### When to Use

- Recurring incidents with diagnosable patterns
- After-hours monitoring with async approval
- Security incidents requiring fast triage
- When you want IaC-managed incident response

### When to Skip

- Very simple alerting is sufficient
- Don't trust AI-proposed changes
- Manual runbooks work well enough

## Open Questions

1. **MCP reliability** — Is Kestra's MCP client stable enough for production?
2. **Context window** — How much Prometheus/Loki data before hitting token limits?
3. **Feedback loop** — Track diagnosis accuracy for improvement?
4. **Escalation** — No approval in 30m → escalate how? (ntfy push?)
5. **Multi-approver** — Require 2 approvals for critical actions?
6. **Dry-run mode** — Diagnose-only for calibration period?

## Related Documents

- `workflow-orchestration.md` — Kestra deployment and platform automation
- `network-security.md` — Suricata/Wazuh for security context
- `../monitoring.md` — Grafana alerting stack
- `../communication.md` — Matrix/ntfy for notifications
- `../trust-model.md` — Identity for agent auth

## Status

**Exploration phase.** Depends on Kestra deployment from workflow-orchestration.md. Start with diagnosis-only (no execution) to calibrate agent quality.

## Implementation Phases

### Phase 0: Diagnosis Only (Recommended Start)

1. Deploy Kestra (per workflow-orchestration.md)
2. Create incident-response flow with AIAgent
3. Configure Grafana MCP connection
4. Trigger on alerts, generate diagnosis
5. Post to Matrix for human review
6. **No execution** — human takes manual action
7. Collect feedback on diagnosis quality

### Phase 1: Human-Approved Execution

1. Add OPA policy engine
2. Add `Pause` task for approval
3. Create remediation sub-flows
4. Enable execution after approval
5. Full audit logging

### Phase 2: Auto-Remediation

1. Identify safe auto-remediation patterns
2. Add OPA rules for auto-approval
3. Enable for specific alert types (config rollback, service restart)
4. Monitor for false positives

### Phase 3: Advanced

1. RAG pipeline for runbook context (Kestra AI plugin supports this)
2. Learn from past incidents (vector store)
3. Multi-agent for complex scenarios
