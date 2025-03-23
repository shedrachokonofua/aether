# Home Network File Server

This playbook is for setting up the home network file server on Smith. It is provisioned as a fedora LXC.

## Components

- NFS Server
- SMB Server

## Usage

```bash
task provision:home:nfs
```

## Sub-Playbooks

### Configure ZFS

This configures the ZFS storage pools and datasets on Smith.

```bash
task ansible:playbook -- ./ansible/playbooks/network_file_server/configure_zfs.yml
```

### Provision NFS LXC

This provisions the NFS LXC on Smith.

```bash
task ansible:playbook -- ./ansible/playbooks/network_file_server/provision.yml
```

### Configure NFS

This configures the NFS server on the LXC and integrates it with the proxmox cluster.

```bash
task ansible:playbook -- ./ansible/playbooks/network_file_server/configure_nfs.yml
```

### Configure Proxmox NFS

This adds the NFS storage backend to the proxmox cluster.

```bash
task ansible:playbook -- ./ansible/playbooks/network_file_server/configure_proxmox_nfs.yml
```
