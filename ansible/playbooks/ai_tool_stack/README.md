# AI Tool Stack

This playbook will configure the AI tool stack virtual machine. The AI tool stack is a fedora vm that hosts the following applications deployed as podman quadlets:

- LiteLLM: Unified LLM API proxy
- SearXNG: Private metasearch engine
- Firecrawl: Web scraping and crawling API with MCP server
- Bytebot: AI desktop agent with containerized Linux environment
- MicroSandbox: KVM-based secure sandbox for AI agent code execution via MCP

## Usage

```bash
task configure:home:ai-tool-stack
```

## Sub-Playbooks

### Deploy LiteLLM

```bash
task ansible:playbook -- ./ansible/playbooks/ai_tool_stack/litellm/site.yml
```

### Deploy SearXNG

```bash
task ansible:playbook -- ./ansible/playbooks/ai_tool_stack/searxng/site.yml
```

### Deploy Firecrawl

```bash
task ansible:playbook -- ./ansible/playbooks/ai_tool_stack/firecrawl.yml
```

### Deploy Bytebot

```bash
task ansible:playbook -- ./ansible/playbooks/ai_tool_stack/bytebot.yml
```

### Deploy MicroSandbox

KVM-based sandbox for secure code execution. Requires nested virtualization (VM must have `/dev/kvm` available).
Builds the image locally from the official install script.

```bash
task ansible:playbook -- ./ansible/playbooks/ai_tool_stack/microsandbox/site.yml
```
