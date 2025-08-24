# Game Server

This playbook is for setting up and deploying the game server virtual machine. The game server is a [Bazzite](https://bazzite.gg/) VM that hosts game streaming services. Bazzite is a gaming-focused Fedora-based distribution that provides a Steam Deck-like gaming experience with pre-configured optimizations. The VM is configured with GPU passthrough for native graphics performance.

## Components

- Sunshine: Game streaming server for remote gaming access
- NVIDIA Drivers: Pre-installed with GPU passthrough support
- KDE Plasma Desktop: Configured with gaming-optimized settings
- Gaming utilities from Bazzite (Steam, Lutris, etc.)
- Emulators:
  - PS2: PCSX2
  - PS3: RPCS3
- NFS Mount: `/mnt/gaming` stores ROMs/firmware only (read‑mostly) for portability (multi-host, VM migration).

## Usage

```bash
task provision:home:game-server
```

## Sub-Playbooks

### Provision Bazzite Builder

This sets up a Fedora VM with the necessary tools to build the Bazzite image.

```bash
task ansible:playbook -- ./ansible/playbooks/game_server/provision_bazzite_builder.yml
```

### Build Bazzite Image

This builds a custom Bazzite cloud image using [bootc-image-builder](https://github.com/osbuild/bootc-image-builder). Since Bazzite doesn't provide cloud images suitable for Proxmox deployment, this playbook:

1. Uses the Bazzite OCI container image `ghcr.io/ublue-os/bazzite-deck-nvidia:stable` as the base
2. Adds cloud-init support via a custom Containerfile for automated VM provisioning
3. Converts the container into a bootable qcow2 disk image
4. Copies the resulting image to Proxmox for VM deployment

```bash
task ansible:playbook -- ./ansible/playbooks/game_server/build_bazzite_image.yml
```

### Provision Game Server

This provisions the game server VM on the Proxmox cluster using the custom Bazzite image.

```bash
task ansible:playbook -- ./ansible/playbooks/game_server/provision_game_server.yml
```

### Configure Game Server

This applies the gaming configuration including Sunshine setup, KDE settings, and auto-login.

```bash
task ansible:playbook -- ./ansible/playbooks/game_server/configure_game_server.yml
```

### Destroy Bazzite Builder

This tears down the Bazzite builder VM and deletes the disk.

```bash
task ansible:playbook -- ./ansible/playbooks/game_server/destroy_bazzite_builder.yml
```
