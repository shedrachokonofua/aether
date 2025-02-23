# Home Network

This playbook is for setting up the [VyOS](https://vyos.io/) router/firewall virtual machine that powers the home network. VyOS does not have a public cloud image(qcow2) available for download. They only freely distribute ISO images on a rolling release basis. This playbook automates the process of building a VyOS cloud image and deploying it to the Proxmox cluster.

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

### Provision VyOS Router

This provisions the VyOS router VM on the Proxmox cluster.

```bash
task ansible:playbook -- ./ansible/playbooks/home_router/provision_vyos_router.yml
```

### Apply VyOS configuration

This applies the network configuration to the router.

```bash
task ansible:playbook -- ./ansible/playbooks/home_router/configure_vyos.yml
```
