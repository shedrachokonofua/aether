# PaaS

Two platform-as-a-service offerings provide application deployment infrastructure.

## Dokku

Multi-tenant PaaS running on Neo. Provides Heroku-like git-push deployment with Terraform support for infrastructure-as-code management.

| Component | Purpose                              |
| --------- | ------------------------------------ |
| Dokku     | Core PaaS platform (buildpacks, git) |
| Infisical | Secrets management integration       |
| Temporal  | Workflow orchestration               |

### Features

- Git push deployment
- Buildpack and Dockerfile support
- Let's Encrypt SSL certificates
- Terraform provider for declarative app management
- Plugin ecosystem (postgres, redis, etc.)

### Access

- SSH: `dokku@dokku.home.shdr.ch`
- Web: `*.dokku.home.shdr.ch`

## Dokploy

GUI-based PaaS running on Trinity. Provides a visual interface for deploying applications and third-party services.

### Deployed Services

| Service     | Purpose                      |
| ----------- | ---------------------------- |
| N8N         | Workflow automation          |
| Owntracks   | Location tracking            |
| Windmill    | Script/workflow platform     |
| Vaultwarden | Password manager (Bitwarden) |
| Affine      | Knowledge base / note-taking |

### Features

- Docker Compose deployment
- Git integration
- Automatic SSL via Caddy
- Database provisioning
- Backup integration

### Access

- Web: `dokploy.home.shdr.ch`

## Smallweb

Lightweight file-based personal cloud running on Trinity. Designed for simple static sites and lightweight applications.

### Features

- File-based deployment
- Automatic HTTPS
- Minimal resource footprint

### Access

- Web: `*.smallweb.home.shdr.ch`
