# Home Network File Server

This playbook sets up the network file server LXC on Smith. See the
[storage overview](../../../docs/storage.md) for the current architecture.

## Components

- NFS Server
- SMB Server

## Usage

```bash
task provision:nfs
```

## Sub-Playbooks

### Configure ZFS

This configures the ZFS storage pools and datasets on Smith.

```bash
task ansible:playbook -- network_file_server/configure_zfs.yml
```

### Provision NFS LXC

This provisions the NFS LXC on Smith.

```bash
task ansible:playbook -- network_file_server/provision.yml
```

### Configure IP Routing

This removes the extra default ip route from the container if necessary to avoid routing issues and packet loss.

```bash
task ansible:playbook -- network_file_server/configure_ip_routing.yml
```

### Configure NFS

This configures the NFS server on the LXC and integrates it with the proxmox cluster.

```bash
task ansible:playbook -- network_file_server/configure_nfs.yml
```

### Configure SMB

This configures the SMB server on the LXC.

```bash
task ansible:playbook -- network_file_server/configure_smb.yml
```
