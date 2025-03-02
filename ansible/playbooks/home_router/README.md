# Home Router

This playbook is for setting up and deploying the [VyOS](https://vyos.io/) router/firewall virtual machine that powers the home network. Although VyOS freely distributes ISO images on a rolling release basis, their QCOW2 cloud image is only available through a subscription. To work around this, I use a custom packer template to package the ISO into a cloud image along with some basic configuration. The cloud image is then used to provision the router VM on the Proxmox cluster.

## Usage

```bash
task provision:home:router
```

## Sub-Playbooks

### Provision VyOS Packer

This sets up a fedora VM with the necessary tools to pack the VyOS cloud image.

```bash
task ansible:playbook -- ./ansible/playbooks/home_router/provision_vyos_packer.yml
```

### Pack VyOS image

This clones the VyOS iso image and packer-vyos repository into the VyOS packer VM, builds the VyOS cloud image, and copies the image to the Proxmox cluster.

```bash
task ansible:playbook -- ./ansible/playbooks/home_router/pack_vyos.yml
```

### Provision Router

This provisions the VyOS router VM on the Proxmox cluster.

```bash
task ansible:playbook -- ./ansible/playbooks/home_router/provision_router.yml
```

### Apply network configuration

This applies the network configuration to the router.

```bash
task ansible:playbook -- ./ansible/playbooks/home_router/configure_router.yml
```

### Destroy VyOS Packer

This tears down the VyOS packer VM and deletes the disk.

```bash
task ansible:playbook -- ./ansible/playbooks/home_router/destroy_vyos_packer.yml
```
