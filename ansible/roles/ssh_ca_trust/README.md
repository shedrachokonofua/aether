# SSH CA Trust Role

Configures Linux hosts to trust SSH user certificates signed by the step-ca Certificate Authority.

## Architecture

**Automatic (via vm_baseline dependency):**

- All VMs/LXCs using `vm_baseline` role get `ssh_ca_trust` automatically

**Manual:**

- `baseline_machines.yml` — Proxmox hosts (no vm_baseline)
- `home_router/configure_router.yml` — VyOS router (native `trusted-user-ca`)
- `configure_ssh_ca_trust.yml` — Catch-up for machines + AWS public gateway

## What This Does

1. **Fetches the SSH User CA public key** from step-ca via SSH (runtime)
2. **Installs it** at `/etc/ssh/ca_user_key.pub`
3. **Configures sshd** with `TrustedUserCAKeys` to accept certs signed by the CA
4. **Sets up AuthorizedPrincipalsFile** to control which cert principals can log in as which users

## Variables

| Variable                 | Default                                  | Description                       |
| ------------------------ | ---------------------------------------- | --------------------------------- |
| `ssh_ca_host`            | `{{ vm.step_ca.ip }}`                    | step-ca host to fetch key from    |
| `ssh_ca_pubkey_remote`   | `/etc/step-ca/certs/ssh_user_ca_key.pub` | Path to CA key on step-ca         |
| `ssh_ca_pubkey_path`     | `/etc/ssh/ca_user_key.pub`               | Where to install CA key on target |
| `ssh_principals_dir`     | `/etc/ssh/auth_principals`               | Directory for principals files    |
| `ssh_ca_principals`      | `["admin"]`                              | Principals allowed (role-based)   |
| `ssh_ca_user_principals` | `{}`                                     | Per-user principal overrides      |

## Principal Mapping

By default, this role creates principals files for:

- The `ansible_user` for that host
- `root`

Both get the same principals from `ssh_ca_principals`.

### Override per-user:

```yaml
ssh_ca_user_principals:
  aether:
    - shdrch@shdr.ch
    - deploy@shdr.ch
  root:
    - shdrch@shdr.ch
```

## SSH Certificate Flow

1. User authenticates to Keycloak via step-ca OIDC
2. step-ca issues an SSH certificate with principals based on user's identity:
   - Email address (e.g., `shdrch@shdr.ch`)
   - Keycloak roles (e.g., `admin`, `grafana-admin`)
3. Certificate also includes **features** based on roles:
   - `admin` role → full access (PTY, port forwarding, agent forwarding)
   - Other roles → PTY only (no forwarding)
4. User SSHs to a host with the certificate
5. Host checks:
   - Certificate is signed by trusted CA (`TrustedUserCAKeys`)
   - Certificate principal matches an entry in `/etc/ssh/auth_principals/<username>`
6. Access granted with the certificate's allowed features

## Usage

```yaml
- hosts: all
  vars:
    ssh_ca_principals:
      - "{{ secrets.keycloak.shdrch_email }}"
  roles:
    - common # loads secrets
    - ssh_ca_trust
```

Or with additional principals:

```yaml
- hosts: production
  roles:
    - role: ssh_ca_trust
      vars:
        ssh_ca_principals:
          - "{{ secrets.keycloak.shdrch_email }}"
          - "{{ secrets.keycloak.oncall_email }}"
```

## VyOS Router

VyOS has native SSH CA support via `set service ssh trusted-user-ca`. This is configured directly in the playbook using VyOS's PKI subsystem:

```
set pki openssh step-ca public key <base64-key>
set pki openssh step-ca public type ssh-ed25519
set service ssh trusted-user-ca step-ca
```

VyOS doesn't use principals files — the certificate's principals are matched directly against the username being logged into. Ensure your SSH certificate includes the VyOS username (e.g., `aether`) as a principal.
