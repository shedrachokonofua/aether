# Backup Stack

This playbook will configure the backup stack virtual machine. The backup stack is an debian LXC that hosts the following services:

- Proxmox Backup Server
- Sanoid
- Rclone

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

Adds proxmox backup server as a storage target to the proxmox cluster and creates a backup job.

```bash
task ansible:playbook -- ./ansible/playbooks/backup_stack/configure_proxmox_backups.yml
```
