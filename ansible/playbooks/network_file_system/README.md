# Home Network File System

This playbook is for setting up the home network file system on Smith.

## Usage

```bash
task provision:home:nfs
```

## Sub-Playbooks

### Configure ZFS

This configures the ZFS storage pools and datasets on Smith.

```bash
task ansible:playbook -- ./ansible/playbooks/network_file_system/configure_zfs.yml
```

### Provision NFS LXC

This provisions the NFS LXC container on Smith.

```bash
task ansible:playbook -- ./ansible/playbooks/network_file_system/provision_nfs.yml
```

### Configure NFS

This configures the NFS server on the LXC container and integrates it with the proxmox cluster.

```bash
task ansible:playbook -- ./ansible/playbooks/network_file_system/configure_nfs.yml
```
