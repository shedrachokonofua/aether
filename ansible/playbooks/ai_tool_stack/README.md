# AI Tool Stack

This playbook configures the remaining AI tool stack virtual machine. The VM currently keeps LiteLLM in place while SearXNG and Firecrawl run in Kubernetes.

- LiteLLM: Unified LLM API proxy

## Usage

```bash
task configure:home:ai-tool-stack
```

## Sub-Playbooks

### Deploy LiteLLM

```bash
task ansible:playbook -- ./ansible/playbooks/ai_tool_stack/litellm/site.yml
```

### Kubernetes Services

SearXNG and Firecrawl are managed by OpenTofu in `tofu/home/kubernetes`.

Bytebot and MicroSandbox are decommissioned instead of migrated.
