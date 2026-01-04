# Backup Stack

This playbook will configure the backup stack virtual machine. The backup stack is a Debian LXC that hosts the following services:

- Proxmox Backup Server
- Restic + Backrest (offsite S3 backups)

This playbook also configures ZFS snapshots and replication on Smith using sanoid and syncoid.

See [high-level overview](../../../docs/home.md#Backups) for more details.

## Usage

```bash
task configure:home:backup-stack
```

## Sub-Playbooks

### Configure Proxmox Backup Server

Installs Proxmox Backup Server and creates vm backup datastore

```bash
task ansible:playbook -- ./ansible/playbooks/backup_stack/configure_pbs.yml
```

### Configure proxmox cluster backups

Adds proxmox backup server as a storage target to the proxmox cluster and creates a backup job schedule.

```bash
task ansible:playbook -- ./ansible/playbooks/backup_stack/configure_proxmox_backups.yml
```

### Configure ZFS snapshots

Installs Sanoid and configures scheduled ZFS snapshots for all datasets.

```bash
task ansible:playbook -- ./ansible/playbooks/backup_stack/configure_zfs_snapshots.yml
```

### Configure offsite backups

Configures Restic and Backrest for offsite backups to S3. Uses IAM Roles Anywhere with step-ca certificates for authentication (no static credentials).

**Components:**

- **Restic** - Deduplicating backup program
- **Backrest** - Web UI and scheduler for Restic (runs on port 9898)
- **aws_signing_helper** - Fetches temporary AWS credentials via IAM Roles Anywhere

**Prerequisites:**

- step-ca certificate for `backup-stack.home.shdr.ch` in `/etc/step-ca/certs/`
- AWS Trust Anchor deployed (`aether-step-ca-trust` CloudFormation stack)
- Terraform applied with IAM role and Roles Anywhere profile

```bash
task ansible:playbook -- ./ansible/playbooks/backup_stack/configure_offsite_backups/site.yml
```

**Web UI:** `https://backrest.home.shdr.ch`
