# Workflow Orchestration Exploration

Exploration of workflow orchestration tools for platform automation, scheduled jobs, and event-driven pipelines on Kubernetes.

## Goal

Deploy workflow orchestration to enable:

1. **YAML-first automation** — Define workflows as code, managed via Terraform/GitOps
2. **K8s-native execution** — Spawn pods for compute tasks, respect node selectors/resources
3. **Plugin ecosystem** — Pre-built integrations for Prometheus, Loki, OpenAI, Slack, AWS
4. **Observability integration** — Query metrics/logs, trigger on alerts, AI-assisted analysis
5. **Event-driven pipelines** — Respond to webhooks, schedules, file events, message queues
6. **Replace legacy tools** — Consolidate n8n, Windmill, cron jobs into unified platform

## Current State

| Capability               | Current Solution         | Gap                                    |
| ------------------------ | ------------------------ | -------------------------------------- |
| Durable workflows        | Temporal (Dokku)         | ✅ Solved (application layer)         |
| Visual automation        | n8n (Dokploy)            | ❌ UI-first, not IaC                   |
| Script workflows         | Windmill (Dokploy)       | ❌ Code-first, underutilized           |
| Scheduled jobs           | Cron (scattered)         | ❌ No visibility, no retry logic       |
| Platform automation      | Ansible (manual trigger) | ❌ No scheduling, no event triggers    |
| Alert → remediation      | Manual                   | ❌ No automated response               |

## Tool Landscape

### Evaluated Options

| Tool        | Config Style  | K8s Native | Plugins | Terraform | License        |
| ----------- | ------------- | ---------- | ------- | --------- | -------------- |
| Kestra      | YAML-first    | ✅         | 900+    | ✅        | Apache 2.0     |
| Argo        | K8s CRDs      | ✅         | ❌ DIY  | ⚠️        | Apache 2.0     |
| Temporal    | Code-first    | ⚠️         | ❌      | ❌        | MIT            |
| n8n         | UI/JSON       | ❌         | 400+    | ❌        | Fair-code      |
| Windmill    | Code-first    | ⚠️         | ⚠️      | ⚠️        | AGPL-3.0       |
| Airflow     | Python DAGs   | ✅         | ⚠️      | ⚠️        | Apache 2.0     |
| Prefect     | Python-first  | ⚠️         | ❌      | ❌        | Apache 2.0     |

### The Three-Layer Model

Different tools serve different abstraction layers:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          APPLICATION LAYER                                       │
│                                                                                  │
│   Temporal                                                                       │
│   • Durable execution for custom business logic                                 │
│   • Code-first (Go, Python, TypeScript, Java)                                   │
│   • Exactly-once semantics, survives crashes                                    │
│   • Use for: Payment flows, state machines, long-running processes              │
│                                                                                  │
├─────────────────────────────────────────────────────────────────────────────────┤
│                          AUTOMATION LAYER                                        │
│                                                                                  │
│   Kestra                                                                         │
│   • YAML-first workflow definition                                              │
│   • 900+ plugins for integrations                                               │
│   • Use for: Scheduled jobs, alert pipelines, AI workflows, platform glue       │
│                                                                                  │
├─────────────────────────────────────────────────────────────────────────────────┤
│                          INFRASTRUCTURE LAYER                                    │
│                                                                                  │
│   Argo Workflows                                                                 │
│   • K8s CRDs, pure Kubernetes native                                            │
│   • Full K8s RBAC, namespace isolation                                          │
│   • Use for: CI/CD pipelines, batch compute, multi-tenant workloads             │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Primary Choice: Kestra OSS

Kestra provides the best balance for platform automation:

### Why Kestra

| Requirement              | Kestra OSS                          |
| ------------------------ | ----------------------------------- |
| YAML-first               | ✅ Native                           |
| Terraform provider       | ✅ Official                         |
| K8s task execution       | ✅ Kubernetes runner                |
| Prometheus/Loki plugins  | ✅ Native                           |
| AI plugins               | ✅ OpenAI, Anthropic (Gemini free)  |
| Slack notifications      | ✅ Plugin                           |
| AWS integrations         | ✅ S3, SES, Lambda plugins          |
| Namespace organization   | ✅ Hierarchical                     |

### Kestra OSS vs Enterprise

| Feature                     | OSS | Enterprise |
| --------------------------- | --- | ---------- |
| YAML workflows              | ✅  | ✅         |
| 900+ plugins                | ✅  | ✅         |
| Kubernetes task runner      | ✅  | ✅         |
| Terraform provider          | ✅  | ✅         |
| Namespace organization      | ✅  | ✅         |
| Task defaults               | ✅  | ✅         |
| Prometheus metrics          | ✅  | ✅         |
| SSO (OIDC)                  | ❌  | ✅         |
| RBAC                        | ❌  | ✅         |
| HashiCorp Vault backend     | ❌  | ✅         |
| Multi-tenancy               | ❌  | ✅         |
| Worker groups               | ❌  | ✅         |
| Audit logs                  | ❌  | ✅         |

### Workarounds for OSS Limitations

| Limitation        | Workaround                                          |
| ----------------- | --------------------------------------------------- |
| No SSO            | Caddy forward_auth → Keycloak                       |
| No Vault backend  | External Secrets Operator → K8s Secrets → env vars  |
| No RBAC           | Single admin (homelab acceptable)                   |
| No multi-tenancy  | Namespace organization for logical separation       |

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              Kubernetes Cluster                                  │
│                                                                                  │
│   ┌───────────────────────────────────────────────────────────────────────────┐ │
│   │                            Kestra                                          │ │
│   │                                                                            │ │
│   │   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                   │ │
│   │   │  Scheduler  │    │   Worker    │    │  Webserver  │                   │ │
│   │   └──────┬──────┘    └──────┬──────┘    └──────┬──────┘                   │ │
│   │          │                  │                  │                           │ │
│   │          └──────────────────┼──────────────────┘                           │ │
│   │                             │                                              │ │
│   │                             ▼                                              │ │
│   │                      ┌─────────────┐                                       │ │
│   │                      │  PostgreSQL │                                       │ │
│   │                      └─────────────┘                                       │ │
│   └───────────────────────────────────────────────────────────────────────────┘ │
│                                 │                                                │
│                    K8s Task Runner (spawns pods)                                │
│                                 │                                                │
│   ┌─────────────────────────────┼─────────────────────────────────────────────┐ │
│   │                             ▼                                              │ │
│   │   ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐               │ │
│   │   │ Job Pod │    │ Job Pod │    │ GPU Pod │    │ Job Pod │               │ │
│   │   │ (batch) │    │ (python)│    │(comfyui)│    │ (shell) │               │ │
│   │   └─────────┘    └─────────┘    └─────────┘    └─────────┘               │ │
│   │                                                                            │ │
│   │   K8s scheduler picks best node based on resources/selectors              │ │
│   └────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                  │
└──────────────────────────────────────────┬──────────────────────────────────────┘
                                           │
                              Network (plugins reach out)
                                           │
              ┌────────────────────────────┼────────────────────────────┐
              ▼                            ▼                            ▼
┌──────────────────────┐    ┌──────────────────────┐    ┌──────────────────────┐
│   Monitoring Stack   │    │      OpenBao         │    │    External APIs     │
│   (Prometheus, Loki) │    │   (via ESO → K8s)    │    │  (OpenAI, Slack...)  │
└──────────────────────┘    └──────────────────────┘    └──────────────────────┘
```

## Kestra Workflow Examples

### Scheduled Backup Pipeline

```yaml
id: backup-pipeline
namespace: platform.ops

tasks:
  - id: snapshot-databases
    type: io.kestra.plugin.scripts.shell.Commands
    taskRunner:
      type: io.kestra.plugin.kubernetes.runner.Kubernetes
      namespace: jobs
    commands:
      - pg_dumpall -h postgres.home.shdr.ch > /tmp/backup.sql
      - gzip /tmp/backup.sql

  - id: upload-to-s3
    type: io.kestra.plugin.aws.s3.Upload
    from: "{{ outputs['snapshot-databases'].outputFiles['backup.sql.gz'] }}"
    bucket: backups
    key: "db/{{ execution.startDate | date('yyyy-MM-dd') }}.sql.gz"

  - id: notify
    type: io.kestra.plugin.notifications.slack.SlackIncomingWebhook
    url: "{{ envs.SLACK_WEBHOOK }}"
    payload: |
      {"text": "✅ Database backup completed"}

triggers:
  - id: daily
    type: io.kestra.core.models.triggers.types.Schedule
    cron: "0 3 * * *"
```

### Alert-Driven Log Analysis with AI

```yaml
id: analyze-errors
namespace: platform.monitoring

inputs:
  - id: service
    type: STRING
  - id: timerange
    type: STRING
    defaults: "1h"

tasks:
  - id: query-errors
    type: io.kestra.plugin.loki.Query
    url: http://loki.home.shdr.ch:3100
    query: '{service="{{ inputs.service }}"} |= "error"'
    start: "{{ execution.startDate | dateAdd(-1, 'HOURS') }}"

  - id: ai-analysis
    type: io.kestra.plugin.openai.ChatCompletion
    apiKey: "{{ envs.OPENAI_API_KEY }}"
    model: gpt-4o
    messages:
      - role: system
        content: |
          You are an SRE assistant. Analyze these error logs and:
          1. Identify patterns and root causes
          2. Suggest remediation steps
          3. Rate severity (critical/high/medium/low)
      - role: user
        content: |
          Error logs from {{ inputs.service }}:
          {{ outputs['query-errors'].results | join('\n') }}

  - id: notify-if-critical
    type: io.kestra.core.tasks.flows.If
    condition: "{{ outputs['ai-analysis'].choices[0].message.content contains 'critical' }}"
    then:
      - id: alert
        type: io.kestra.plugin.notifications.slack.SlackIncomingWebhook
        url: "{{ envs.SLACK_WEBHOOK }}"
        payload: |
          {"text": "🚨 Critical errors in {{ inputs.service }}\n{{ outputs['ai-analysis'].choices[0].message.content }}"}

triggers:
  - id: webhook
    type: io.kestra.core.models.triggers.types.Webhook
    key: "{{ secret('WEBHOOK_KEY') }}"
```

### GPU Batch Job (ComfyUI)

```yaml
id: generate-images
namespace: platform.ai

inputs:
  - id: prompts
    type: ARRAY
    itemType: STRING

tasks:
  - id: generate
    type: io.kestra.core.tasks.flows.EachParallel
    value: "{{ inputs.prompts }}"
    tasks:
      - id: run-comfyui
        type: io.kestra.plugin.scripts.python.Script
        taskRunner:
          type: io.kestra.plugin.kubernetes.runner.Kubernetes
          namespace: gpu-jobs
          resources:
            limits:
              nvidia.com/gpu: 1
          nodeSelector:
            gpu: "true"
        script: |
          import requests
          # Call ComfyUI API on GPU workstation
          response = requests.post(
              "http://gpu-workstation.home.shdr.ch:8188/prompt",
              json={"prompt": "{{ taskrun.value }}"}
          )
          print(f"Generated: {response.json()}")

  - id: notify
    type: io.kestra.plugin.notifications.slack.SlackIncomingWebhook
    url: "{{ envs.SLACK_WEBHOOK }}"
    payload: |
      {"text": "🎨 Generated {{ inputs.prompts | length }} images"}
```

## Secrets Integration

### External Secrets Operator Flow

```
OpenBao
    │
    ├── External Secrets Operator (syncs periodically)
    │         │
    │         ▼
    │    K8s Secret (kestra-secrets)
    │         │
    │         ▼
    │    Kestra pod environment variables
    │         │
    │         └── {{ envs.SECRET_NAME }}
```

### Configuration

```yaml
# ExternalSecret pulls from OpenBao
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: kestra-secrets
  namespace: kestra
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: kestra-secrets
  data:
    - secretKey: SLACK_WEBHOOK
      remoteRef:
        key: secret/kestra
        property: slack_webhook
    - secretKey: OPENAI_API_KEY
      remoteRef:
        key: secret/kestra
        property: openai_key
```

## SSO Workaround

Caddy forward_auth protects Kestra UI via Keycloak:

```
User → Caddy → forward_auth → Keycloak
                    │
                    ▼ (authenticated)
               Kestra UI
```

```caddyfile
kestra.home.shdr.ch {
    forward_auth authelia:9091 {
        uri /api/verify?rd=https://auth.shdr.ch
        copy_headers Remote-User Remote-Groups
    }
    reverse_proxy kestra:8080
}
```

## Secondary Option: Argo Workflows

For K8s-native workloads requiring full RBAC and multi-tenancy:

### When to Use Argo

| Use Case                          | Why Argo                           |
| --------------------------------- | ---------------------------------- |
| CI/CD pipelines                   | CRDs, GitOps, Terraform            |
| Peer-accessible workflows         | K8s RBAC (namespace isolation)     |
| Heavy batch compute               | Full K8s control, node affinity    |
| When K8s-native purity matters    | Workflows ARE K8s resources        |

### Argo Workflow Example

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  name: batch-process
spec:
  entrypoint: main
  templates:
    - name: main
      dag:
        tasks:
          - name: extract
            template: run-job
            arguments:
              parameters:
                - name: cmd
                  value: "python extract.py"
          - name: transform
            dependencies: [extract]
            template: run-job
            arguments:
              parameters:
                - name: cmd
                  value: "python transform.py"
          - name: load
            dependencies: [transform]
            template: run-job
            arguments:
              parameters:
                - name: cmd
                  value: "python load.py"

    - name: run-job
      inputs:
        parameters:
          - name: cmd
      container:
        image: python:3.11
        command: [sh, -c]
        args: ["{{ inputs.parameters.cmd }}"]
        resources:
          requests:
            memory: "1Gi"
            cpu: "500m"
```

## Comparison: Kestra vs Argo

| Aspect              | Kestra                      | Argo                       |
| ------------------- | --------------------------- | -------------------------- |
| Config style        | YAML (proprietary)          | YAML (K8s CRDs)            |
| Plugin ecosystem    | 900+ built-in               | DIY (containers/scripts)   |
| Learning curve      | Low                         | Medium                     |
| Day-to-day effort   | Low (plugins)               | Higher (write scripts)     |
| K8s RBAC            | ❌ (workaround)             | ✅ Native                  |
| Multi-tenancy       | ❌                          | ✅ (namespaces)            |
| Best for            | Fast automation             | K8s-native pipelines       |

## What Gets Retired

| Tool     | Replacement             | Reason                              |
| -------- | ----------------------- | ----------------------------------- |
| n8n      | Kestra                  | YAML > UI, IaC-first                |
| Windmill | AI + IDE                | Underutilized, AI generates code    |
| Cron     | Kestra schedules        | Visibility, retry, monitoring       |

## What Stays

| Tool     | Layer       | Use Case                            |
| -------- | ----------- | ----------------------------------- |
| Temporal | Application | Durable business logic, state machines |
| Kestra   | Automation  | Platform glue, scheduled jobs, AI pipelines |
| Argo     | Infra       | K8s-native when RBAC/multi-tenant needed |

## Implementation Phases

### Phase 1: Deploy Kestra

- [ ] Add Kestra to kubernetes.md platform components
- [ ] Create Helm values for Kestra deployment
- [ ] Configure PostgreSQL backend
- [ ] Set up Caddy forward_auth for SSO
- [ ] Configure External Secrets for OpenBao integration
- [ ] Deploy and verify

### Phase 2: Migrate Workflows

- [ ] Migrate scheduled backup jobs from cron
- [ ] Create monitoring/alerting workflows
- [ ] Build AI analysis pipelines
- [ ] Set up GitLab CI trigger integration

### Phase 3: Retire Legacy

- [ ] Migrate any n8n workflows to Kestra
- [ ] Remove n8n from Dokploy
- [ ] Remove Windmill from Dokploy
- [ ] Document new workflow patterns

### Phase 4: Argo (Optional)

- [ ] Deploy Argo Workflows if multi-tenant/RBAC needs arise
- [ ] Create CI/CD pipeline templates
- [ ] Configure GitLab integration

## Key Decisions

| Decision       | Choice                  | Rationale                                    |
| -------------- | ----------------------- | -------------------------------------------- |
| Primary tool   | Kestra OSS              | YAML + plugins + K8s, best balance           |
| Secondary tool | Argo Workflows          | K8s-native when needed                       |
| SSO            | Caddy forward_auth      | Workaround for OSS limitation                |
| Secrets        | ESO → K8s Secrets       | OpenBao integration without enterprise       |
| n8n            | Retire                  | Kestra replaces with IaC approach            |
| Windmill       | Retire                  | AI + IDE makes it redundant                  |

## Related Documents

- `kubernetes.md` — K8s cluster where Kestra runs
- `agentic-incident-response.md` — Temporal for durable incident workflows
- `../trust-model.md` — Identity for secrets access
- `../monitoring.md` — Prometheus/Loki that Kestra queries
- `../paas.md` — Current n8n/Windmill/Dokku being retired

## Status

**Exploration complete.** Deploy Kestra as part of Kubernetes platform rollout. Argo available as secondary option for K8s-native requirements.

