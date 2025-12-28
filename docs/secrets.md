# Secrets

Three-tier encryption hierarchy for secrets at rest. SOPS uses OpenBao Transit as primary, with AWS KMS and Age as fallbacks.

## Architecture

```mermaid
flowchart TB
    subgraph Encryption["Encryption Tiers"]
        direction TB
        Transit["<b>OpenBao Transit</b><br/><i>Primary · Server-side encryption</i><br/><i>Key never leaves OpenBao</i>"]
        KMS["<b>AWS KMS</b><br/><i>Fallback · Cloud-managed</i><br/><i>Requires AWS credentials</i>"]
        Age["<b>Age</b><br/><i>Emergency · Air-gapped</i><br/><i>Works when everything is down</i>"]
    end

    SOPS[SOPS] --> Transit
    Transit -.->|fallback| KMS
    KMS -.->|fallback| Age

    style Transit fill:#d4f0e7,stroke:#6ac4a0
    style KMS fill:#d4e5f7,stroke:#6a9fd4
    style Age fill:#f0e4d4,stroke:#c4a06a
```

| Tier | Provider        | When Used                    | Key Location |
| ---- | --------------- | ---------------------------- | ------------ |
| 1    | OpenBao Transit | Normal operations            | Server-side  |
| 2    | AWS KMS         | OpenBao unavailable          | AWS managed  |
| 3    | Age             | Bootstrap, disaster recovery | Air-gapped   |

**Any tier can decrypt.** SOPS tries in order and uses the first available.

## OpenBao

Secrets management platform running as an LXC on Oracle.

| Setting     | Value                                              |
| ----------- | -------------------------------------------------- |
| URL         | https://bao.home.shdr.ch                           |
| Storage     | Integrated Raft                                    |
| TLS         | step-ca certificate with auto-renewal              |
| Auto-unseal | AWS KMS via IAM Roles Anywhere (certificate-based) |

### Secrets Engines

| Engine  | Path      | Purpose                        |
| ------- | --------- | ------------------------------ |
| Transit | `aether/` | SOPS encryption (AES256-GCM96) |

### Policies

| Policy  | Access                  | Assigned To             |
| ------- | ----------------------- | ----------------------- |
| `sops`  | Transit encrypt/decrypt | All authenticated users |
| `admin` | Full access             | Keycloak `admin` role   |

## SOPS Configuration

Defined in `.sops.yaml`:

| Pattern               | Description        |
| --------------------- | ------------------ |
| `secrets/*.yml`       | Main secrets       |
| `ansible/*vault*.yml` | Ansible vaults     |
| `*.enc.*`             | Any encrypted file |

## Recovery

The Age key is the master key for disaster recovery:

```
Age Key → decrypts → Recovery Keys → unseals → OpenBao → unlocks → Everything
```

**Keep the Age key backed up offline** (printed, USB in safe).

| Scenario                        | Solution                             |
| ------------------------------- | ------------------------------------ |
| OpenBao up, authenticated       | Normal workflow (`task login`)       |
| OpenBao up, need admin          | `task bao:root-token` → provide keys |
| OpenBao sealed, AWS available   | Auto-unseal on restart               |
| OpenBao sealed, AWS unavailable | Manual unseal with recovery keys     |
| OpenBao down, AWS available     | SOPS falls back to KMS               |
| Everything down                 | Age key to `config/age-key.txt`      |
