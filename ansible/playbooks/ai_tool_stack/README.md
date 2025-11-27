# AI Tool Stack

This playbook will configure the AI tool stack virtual machine. The AI tool stack is a fedora vm that hosts the following applications deployed as podman quadlets:

- LiteLLM: Unified LLM API proxy
- SearXNG: Private metasearch engine
- Firecrawl: Web scraping and crawling API with MCP server
- OpenWebUI: Chat interface with web search, RAG, and tool integrations
- MCPO: MCP-to-OpenAPI bridge for tool server connections
- Bytebot: AI desktop agent with containerized Linux environment

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

### Deploy OpenWebUI

Deploys OpenWebUI and MCPO.

```bash
task ansible:playbook -- ./ansible/playbooks/ai_tool_stack/openwebui/site.yml
```

### Deploy Bytebot

```bash
task ansible:playbook -- ./ansible/playbooks/ai_tool_stack/bytebot.yml
```
