# Backup Stack

This playbook will configure the backup stack virtual machine. The backup stack is an debian LXC that hosts the following services:

- Proxmox Backup Server
- Rclone

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

### Configure ZFS replication

Configures syncoid to replicate non-VM ZFS datasets from nvme to hdd.

```bash
task ansible:playbook -- ./ansible/playbooks/backup_stack/configure_zfs_replication.yml
```

### Configure offsite backups

Configures rclone for offsite backups to s3 and google drive.

```bash
task ansible:playbook -- ./ansible/playbooks/backup_stack/configure_offsite_backups/site.yml
```
