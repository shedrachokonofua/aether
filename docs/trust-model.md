# Trust Model

This document describes the identity and trust architecture for the home infrastructure.

## Guiding Principles

1. **Minimize static secrets** — Credentials should be injected (JWT) or self-renewing (certs), never hardcoded
2. **Appropriate tools for each plane** — Keycloak for humans, PKI for machines
3. **Trust roots, not brokers** — Services trust step-ca or platform JWTs directly, no forced intermediaries
4. **Centralize identity, distribute authorization** — One CA, one human IdP, but services own their own policies

**The litmus test:** When adding an auth flow, ask: "Does this introduce a static secret?" If yes, see if another way is possible.

## Identity Planes

The system separates human and machine identity into distinct planes, each with its own lifecycle and authentication patterns.

| Plane   | Provider      | Subjects               | Auth Method          |
| ------- | ------------- | ---------------------- | -------------------- |
| Human   | Keycloak      | Users, admins          | OIDC, passwords, MFA |
| Machine | step-ca (PKI) | Services, runners, VMs | X.509 certificates   |

## Trust Hierarchy

```txt
                         ┌─────────────────────┐
                         │      step-ca        │
                         │   (Root of Trust)   │
                         └──────────┬──────────┘
                                    │
            ┌───────────────────────┼───────────────────────┐
            │                       │                       │
            ▼                       ▼                       ▼
     ┌─────────────┐         ┌─────────────┐         ┌─────────────┐
     │  Keycloak   │         │  AWS IAM    │         │   GitLab    │
     │ (Human IdP) │         │   Roles     │         │  (CI OIDC)  │
     └──────┬──────┘         │  Anywhere   │         └──────┬──────┘
            │                └──────┬──────┘                │
            ▼                       ▼                       ▼
      Human users              Machine-to-              CI job
      → UI access              cloud auth               identity
```

step-ca is the root of trust for the entire infrastructure:

- **Keycloak** — Human identity provider, issues OIDC tokens for users
- **AWS IAM Roles Anywhere** — Trusts step-ca certs for machine-to-cloud auth
- **GitLab** — Platform identity for CI jobs (JWT), step-ca trusts directly

All systems either use step-ca certificates directly or sit behind TLS-terminating proxies.

**Keycloak is for humans only.** Machine/service flows use certificates or platform JWTs.

Note: Keycloak currently runs HTTP behind Caddy (TLS terminated at proxy). Direct step-ca TLS for Keycloak is planned.

## Machine Identity

Machines authenticate using X.509 certificates issued by step-ca. Certificates are scoped by Common Name (CN) and Subject Alternative Names (SANs).

### Provisioners

| Provisioner       | Type   | Purpose                          | Status |
| ----------------- | ------ | -------------------------------- | ------ |
| machine-bootstrap | JWK    | Machine provisioning via Ansible | Active |
| keycloak          | OIDC   | Human auth → SSH/X.509 certs     | Active |
| sshpop            | SSHPOP | SSH certificate renewal          | Active |
| gitlab-ci         | OIDC   | GitLab CI job → certificates     | Active |

### Certificate Lifecycle

| Phase         | Mechanism                                  |
| ------------- | ------------------------------------------ |
| Initial issue | Ansible + machine-bootstrap provisioner    |
| Renewal       | `step ca renew --daemon` (systemd service) |
| Revocation    | `step ca revoke` (manual or automated)     |

### Machine Identity Examples

| Service       | CN                     | Use Cases                             |
| ------------- | ---------------------- | ------------------------------------- |
| OpenBao       | bao.home.shdr.ch       | AWS KMS auto-unseal, mTLS API         |
| GitLab Runner | runner-01.home.shdr.ch | Vault auth, GitLab Container Registry |

## Human Identity

Humans authenticate via Keycloak using OIDC. Keycloak handles:

- User management and authentication
- MFA enforcement
- Group/role mappings
- Session management

### Keycloak Configuration

| Setting                  | Value                                    |
| ------------------------ | ---------------------------------------- |
| Realm                    | aether                                   |
| SSO session idle timeout | 2h                                       |
| SSO session max lifespan | 12h                                      |
| Access token lifespan    | 5m                                       |
| Password policy          | length(12), notUsername                  |
| Features enabled         | token-exchange, admin-fine-grained-authz |

### OIDC Clients (Aether Realm)

| Client    | Purpose              | Token Use                                    |
| --------- | -------------------- | -------------------------------------------- |
| toolbox   | CLI authentication   | Device auth → SSH cert, Bao token, AWS creds |
| grafana   | Monitoring access    | Role mapping (grafana-editor/viewer)         |
| openwebui | AI chat interface    | Role mapping (openwebui-user)                |
| gitlab    | Code access          | User provisioning + group sync               |
| jellyfin  | Media streaming      | Role mapping (jellyfin-user)                 |
| openbao   | Secrets management   | User policies based on Keycloak groups       |
| step-ca   | Certificate requests | User → SSH/X.509 certs (public client)       |

## External Trust Relationships

### AWS IAM OIDC Identity Provider

AWS trusts Keycloak as an OIDC issuer, allowing token exchange for temporary AWS credentials.

**Identity Provider**: `aether-oidc`

- Trusts `https://auth.shdr.ch/realms/aether`
- Credentials via STS AssumeRoleWithWebIdentity

**Roles**:

| Role         | Who               | Permissions         |
| ------------ | ----------------- | ------------------- |
| aether-admin | Me (admin in SSO) | AdministratorAccess |

### AWS IAM Roles Anywhere (Machine Access)

AWS trusts step-ca as an identity provider via IAM Roles Anywhere. The trust anchor is provisioned from step-ca's root certificate.

**Trust Anchor**: `aether-step-ca-trust`

- Provisioned via CloudFormation (`step_ca/cf/aws-trust-anchor.yaml`)
- Trusts any certificate issued by step-ca
- Individual roles scope access by certificate CN

**Roles**:

| Profile             | Role                | Trusted CN       | Permissions         |
| ------------------- | ------------------- | ---------------- | ------------------- |
| openbao-auto-unseal | openbao-auto-unseal | bao.home.shdr.ch | KMS Encrypt/Decrypt |

### Tailscale

Tailscale maintains its own identity plane for network access. Integration is via:

- OAuth clients for machine auth keys
- ACLs based on tags (not step-ca certs)

## OpenBao (Vault) Auth Methods

OpenBao supports multiple auth methods, bridging both identity planes:

| Auth Method     | Identity Plane | Use Case                                      |
| --------------- | -------------- | --------------------------------------------- |
| OIDC (Keycloak) | Human          | Interactive browser access (bao.home.shdr.ch) |
| JWT (Keycloak)  | Human          | CLI token exchange (`task login` → Bao token) |
| Cert            | Machine        | Service-to-Vault authentication               |
| Token           | N/A            | Bootstrap, automation (avoid in steady-state) |

### Policy Mapping

| Identity                         | Policy    | Access                               |
| -------------------------------- | --------- | ------------------------------------ |
| Keycloak group: `admins`         | admin     | Full access                          |
| Keycloak group: `developers`     | developer | KV read, limited dynamic creds       |
| Cert CN: `runner-*.home.shdr.ch` | ci        | CI secrets, deploy credentials       |
| Cert CN: `bao.home.shdr.ch`      | N/A       | Self (unseal only, no policy needed) |

## GitLab CI Identity

GitLab CI jobs receive JWT tokens (`CI_JOB_JWT`) that can be exchanged for short-lived credentials.

```txt
GitLab CI Job
     │
     ▼ CI_JOB_JWT (automatic, no secrets)
step-ca (gitlab-ci provisioner)
     │
     ▼ Short-lived certificate
     │
     ├──► OpenBao (cert auth)
     ├──► AWS (Roles Anywhere)
     └──► Internal services (mTLS)
```

step-ca trusts GitLab's OIDC issuer directly. No static secrets required — full JWT claims preserved.

### JWT Claims Available

| Claim         | Example      | Use Case                        |
| ------------- | ------------ | ------------------------------- |
| project_path  | infra/deploy | Scope by repository             |
| ref           | main         | Scope by branch                 |
| ref_protected | true         | Require protected branches      |
| environment   | production   | Scope by deployment environment |

### Integration Points

| Target  | Auth Flow                                      |
| ------- | ---------------------------------------------- |
| step-ca | JWT → cert directly (gitlab-ci provisioner)    |
| OpenBao | Cert auth, or JWT auth (trust GitLab directly) |
| AWS     | Cert → IAM Roles Anywhere                      |

## Credential Exchange

Certificates and tokens can be exchanged bidirectionally when needed, without static secrets.

```txt
                 ┌─────────────┐
                 │   step-ca   │
                 └──────┬──────┘
                        │
         ┌──────────────┴──────────────┐
         │                             │
         ▼                             ▼
  ┌─────────────┐               ┌─────────────┐
  │ Certificate │◄─────────────►│  Keycloak   │
  └─────────────┘               │    Token    │
                                └─────────────┘
```

| Exchange              | How                         | Use Case                                |
| --------------------- | --------------------------- | --------------------------------------- |
| Cert → Keycloak token | X.509 auth to Keycloak      | Service needs OIDC token for legacy app |
| Token → Cert          | OIDC provisioner in step-ca | Human/CI job needs certificate          |
| GitLab JWT → Cert     | OIDC provisioner in step-ca | CI job needs certificate                |

**Key insight:** The credential you have is the credential for the exchange. No bootstrap secrets needed.

## Security Properties

### No Static Secrets

| Component     | Traditional            | This Architecture                    |
| ------------- | ---------------------- | ------------------------------------ |
| AWS access    | IAM user + access keys | Certificate → Roles Anywhere         |
| Vault access  | Root token / AppRole   | Certificate auth / OIDC              |
| CI → step-ca  | Hardcoded token        | GitLab JWT → cert directly           |
| CI → services | Hardcoded credentials  | Cert (mTLS), JWT, or OpenBao secrets |
| M2M auth      | Client credentials     | Certificates (mTLS)                  |

### Blast Radius Containment

| Compromise          | Impact                     | Mitigation                             |
| ------------------- | -------------------------- | -------------------------------------- |
| Single machine cert | That machine's access only | CN-scoped policies, short TTLs         |
| Keycloak            | Human access (revocable)   | Machine plane unaffected               |
| step-ca             | Full compromise            | Air-gapped root, intermediate rotation |
| GitLab runner       | CI jobs on that runner     | Job-level identity isolates projects   |

## Recovery Procedures

### OpenBao Sealed + AWS Unreachable

1. Retrieve recovery keys from `secrets/openbao-recovery-keys.yml`
2. Manual unseal: `bao operator unseal` (requires 3 of 5 keys)
3. Restore AWS connectivity and re-seal to return to auto-unseal

### step-ca Compromise

1. Revoke intermediate certificate
2. Rotate root (if compromised)
3. Re-issue all machine certificates
4. Update AWS trust anchor

### Keycloak Compromise

1. Disable OIDC clients
2. Reset user passwords
3. Machine identity unaffected (separate plane)
