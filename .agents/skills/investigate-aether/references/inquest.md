# Inquest Investigation Boundary

Inquest is the unattended alert pipeline in sibling `../inquest`:

```text
Grafana actionable-alert receiver -> Kestra alert-intake -> process-alert
  -> GitLab so/aether/incidents -> Holmes RCA comment -> human review
```

It complements this interactive skill; it does not replace independent
investigation.

## Source Ownership

| Concern | Authoritative source |
| --- | --- |
| Alert intake, fan-out, dedupe, issue updates, Holmes request | `../inquest/flows/` |
| Flow deployment | `../inquest/tofu/main.tf`, `../inquest/.gitlab-ci.yml` |
| Operator contract | `../inquest/README.md`, `../inquest/docs/operator.md` |
| Kestra runtime, credentials, and flow environment | `tofu/home/kubernetes/kestra.tf`, `tofu/home/openbao_so_ci.tf` |
| Holmes runtime and access | `tofu/home/kubernetes/holmesgpt.tf` |
| Grafana delivery | `ansible/playbooks/monitoring_stack/grafana/provisioning/alerting/contact-points.yml.j2` |

The dated dependency table and future phases in `../inquest/DESIGN.md` are
design history. Verify implemented behavior in flow code and current live state.

## Follow An Incident

1. Record the GitLab issue IID, Grafana fingerprint, alert name, and firing or
   resolved timestamps.
2. Read the issue timeline and identify which statements came from Grafana,
   Kestra, Holmes, or a human. Holmes output is untrusted analysis.
3. Match the fingerprint to the Grafana alert instance and the corresponding
   Kestra execution. Preserve the original alert time window.
4. Independently query Grafana and the relevant datasource, then Kubernetes,
   Fleet, Talos, SSH, or a service API only as the hypothesis requires.
5. Report whether the Holmes RCA is confirmed, contradicted, or not provable,
   and separate pipeline failures from the infrastructure incident.

## Read-Only Guardrails

- GET requests to Kestra and GitLab are investigation; triggering a webhook,
  retrying an execution, changing a flow, or editing an issue is mutation.
- Do not print the Kestra basic-auth password, Inquest GitLab token, or webhook
  key. Keep decrypted values in shell variables only.
- Current code, not design intent, defines behavior. In particular, do not
  claim rate limiting, delayed issue closure, or security-receiver delivery
  unless the corresponding flow and Aether routing declarations implement it.
