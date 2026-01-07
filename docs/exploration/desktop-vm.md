# Desktop VM Exploration

Exploration of a NixOS-based streamable desktop VM on Trinity with Intel iGPU passthrough.

## Goal

Deploy a persistent, streamable desktop environment that:

1. **Streams anywhere** — Moonlight client on laptop, tablet, phone, TV
2. **Declarative config** — NixOS for reproducible desktop environment
3. **Multi-distro dev** — Distrobox for Fedora/Ubuntu/Arch environments without VMs
4. **Hardware accelerated** — Intel Iris Xe for encoding (Sunshine) and graphics

## Why This Works Now

The iGPU was originally earmarked for Jellyfin transcoding. With the new architecture:

| Component            | Before                   | After                               |
| -------------------- | ------------------------ | ----------------------------------- |
| Jellyfin transcoding | Trinity iGPU (QSV)       | GPU Workstation (NVENC via rffmpeg) |
| Trinity iGPU         | Reserved for Media Stack | **Available for Desktop VM**        |

rffmpeg offloads transcoding to the RTX Pro 6000, which is faster anyway. The iGPU becomes free for desktop use.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      Desktop VM (Trinity - NixOS)                            │
│                                                                              │
│   Intel Iris Xe (i9-13900H) ─── PCI Passthrough                             │
│                                                                              │
│   ├── KDE Plasma / GNOME / Hyprland (switchable via flake)                  │
│   ├── Sunshine ──────────────────────────────────────────┐                  │
│   │   ├── H.264/HEVC/AV1 encoding via QSV                │                  │
│   │   └── Low-latency game streaming                     │                  │
│   │                                                      │                  │
│   ├── Distrobox                                          │                  │
│   │   ├── fedora (dnf-based dev)                         │                  │
│   │   ├── ubuntu (apt-based dev)                         │                  │
│   │   ├── arch (AUR access)                              │                  │
│   │   └── ... (any OCI image)                            │                  │
│   │                                                      │                  │
│   └── GUI Apps                                           │                  │
│       ├── Firefox, VS Code                               │                  │
│       └── Whatever else                                  │                  │
└──────────────────────────────────────────────────────────┼──────────────────┘
                                                           │
                                            Moonlight (NVENC/QSV stream)
                                                           │
                                                           ▼
                                            ┌──────────────────────────┐
                                            │   Clients (anywhere)     │
                                            │   ├── Laptop             │
                                            │   ├── Tablet             │
                                            │   ├── Phone              │
                                            │   └── TV                 │
                                            └──────────────────────────┘
```

## Resource Allocation

| Resource | Value                       | Notes                                      |
| -------- | --------------------------- | ------------------------------------------ |
| RAM      | 8GB                         | KDE/GNOME + browser + Distrobox containers |
| vCPU     | 8                           | Smooth desktop + encoding headroom         |
| GPU      | Intel Iris Xe (passthrough) | 96 EUs, QSV encoding                       |
| Storage  | 128GB                       | NixOS + Distrobox images                   |

## Intel Iris Xe Capabilities

| Codec | Encode | Decode | Notes                            |
| ----- | ------ | ------ | -------------------------------- |
| H.264 | ✅ QSV | ✅     | Universal client support         |
| HEVC  | ✅ QSV | ✅     | Better quality at same bitrate   |
| AV1   | ✅ QSV | ✅     | Best quality, newer clients only |
| VP9   | ❌     | ✅     | Decode only                      |

Sunshine will use QSV for encoding → low CPU usage, low latency.

## NixOS Configuration

### Base Desktop Module

```nix
# nix/hosts/trinity/desktop.nix
{ config, pkgs, lib, ... }:

{
  imports = [
    ../../modules/base.nix
    ../../modules/podman.nix
  ];

  # Intel iGPU (PCI passthrough from Proxmox)
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver     # VAAPI (Xe graphics)
      intel-compute-runtime  # OpenCL
      vpl-gpu-rt             # OneVPL (modern QSV)
    ];
  };

  # Sunshine game streaming
  services.sunshine = {
    enable = true;
    autoStart = true;
    capSysAdmin = true;
    openFirewall = true;
  };

  # Audio (required for streaming)
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };

  # Distrobox for multi-distro environments
  virtualisation.podman.enable = true;

  environment.systemPackages = with pkgs; [
    distrobox
    firefox
    kitty
    vscode
  ];

  # Auto-login (headless streaming setup)
  services.displayManager.autoLogin = {
    enable = true;
    user = "shdr";
  };

  # Firewall for Sunshine
  networking.firewall = {
    allowedTCPPorts = [ 47984 47989 47990 48010 ];
    allowedUDPPorts = [ 47998 47999 48000 48002 48010 ];
  };
}
```

### Desktop Environment Options

```nix
# nix/modules/desktop/kde.nix
{ config, pkgs, ... }:

{
  services.desktopManager.plasma6.enable = true;
  services.displayManager.sddm.enable = true;
  services.displayManager.defaultSession = "plasma";
}
```

```nix
# nix/modules/desktop/gnome.nix
{ config, pkgs, ... }:

{
  services.xserver.desktopManager.gnome.enable = true;
  services.xserver.displayManager.gdm.enable = true;
}
```

```nix
# nix/modules/desktop/hyprland.nix
{ config, pkgs, ... }:

{
  programs.hyprland.enable = true;
  services.greetd = {
    enable = true;
    settings.default_session = {
      command = "${pkgs.hyprland}/bin/Hyprland";
      user = "shdr";
    };
  };
}
```

### Flake Configurations

```nix
# nix/flake.nix (relevant section)
{
  nixosConfigurations = {
    # Minimal (Sunshine only, no DE bloat)
    desktop-minimal = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./hosts/trinity/desktop.nix
        # No DE - just Sunshine + apps
      ];
    };

    # KDE Plasma
    desktop-kde = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./hosts/trinity/desktop.nix
        ./modules/desktop/kde.nix
      ];
    };

    # GNOME
    desktop-gnome = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./hosts/trinity/desktop.nix
        ./modules/desktop/gnome.nix
      ];
    };

    # Hyprland (tiling WM)
    desktop-hyprland = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./hosts/trinity/desktop.nix
        ./modules/desktop/hyprland.nix
      ];
    };
  };
}
```

Switch between configurations without reinstalling:

```bash
sudo nixos-rebuild switch --flake .#desktop-kde
sudo nixos-rebuild switch --flake .#desktop-hyprland
```

## Distrobox Workflow

```bash
# Create persistent distro containers
distrobox create --name fedora --image fedora:41
distrobox create --name ubuntu --image ubuntu:24.04
distrobox create --name arch --image archlinux

# Enter any environment (full persistence)
distrobox enter fedora

# Export GUI apps to host
distrobox enter fedora -- distrobox-export --app code

# Apps appear in host application menu, run seamlessly
```

| Distro | Use Case                          |
| ------ | --------------------------------- |
| Fedora | DNF packages, RHEL-compat testing |
| Ubuntu | APT packages, Debian-compat       |
| Arch   | AUR access, bleeding edge         |
| Alpine | Minimal containers                |

All containers share `/home`, persist across reboots, and GUI apps integrate with the host desktop.

## Proxmox Configuration

### VM Settings

| Setting    | Value                                      |
| ---------- | ------------------------------------------ |
| Machine    | q35                                        |
| BIOS       | OVMF (UEFI)                                |
| CPU        | host                                       |
| Memory     | 8192 MB                                    |
| Cores      | 8                                          |
| PCI Device | Intel Iris Xe (All Functions, Primary GPU) |

### PCI Passthrough Setup

```bash
# /etc/modprobe.d/vfio.conf on Trinity Proxmox host
options vfio-pci ids=8086:a7a0  # Intel Iris Xe device ID
```

```bash
# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"
```

## Use Cases

| Scenario             | How                                                         |
| -------------------- | ----------------------------------------------------------- |
| Remote dev work      | Stream to laptop via Moonlight, use VS Code / IDEs with GUI |
| Couch browsing       | Stream to TV, use browser / media apps                      |
| Multi-distro testing | Distrobox containers, instant switch                        |
| Conference calls     | Stream desktop, run Zoom/Meet in browser                    |

## What This Is NOT For

| Use Case               | Better Option                           |
| ---------------------- | --------------------------------------- |
| Gaming                 | Gaming Server on Smith (RTX 1660 Super) |
| LLM inference          | GPU Workstation on Neo (RTX Pro 6000)   |
| Image generation       | GPU Workstation (ComfyUI/SwarmUI)       |
| Headless dev (SSH/CLI) | Dev Workstation (existing)              |

## Comparison to Alternatives

| Approach             | Pros                                    | Cons                   |
| -------------------- | --------------------------------------- | ---------------------- |
| **NixOS + Sunshine** | Declarative, reproducible, multi-config | Learning curve         |
| Fedora + Sunshine    | Familiar, easy setup                    | Drift, manual config   |
| Windows 11           | Native Sunshine, Office apps            | Non-declarative, bloat |

NixOS wins for reproducibility and the ability to declaratively switch between desktop environments.

## Implementation Steps

1. **Proxmox prep**

   - Enable IOMMU on Trinity host
   - Configure iGPU for passthrough
   - Create VM (8GB/8vCPU/128GB)

2. **NixOS install**

   - Boot NixOS ISO
   - Add to aether flake (`nix/hosts/trinity/desktop.nix`)
   - `nixos-install --flake .#desktop-kde`

3. **Sunshine setup**

   - Pair with Moonlight client
   - Configure streaming quality (1080p60 / 4K30)

4. **Distrobox setup**

   - Create initial containers (fedora, ubuntu, arch)
   - Export commonly used apps

5. **Iterate**
   - Try Hyprland: `nixos-rebuild switch --flake .#desktop-hyprland`
   - Add apps to config
   - Rollback if broken: `nixos-rebuild --rollback`

## Integration with Aether

| System      | Integration                           |
| ----------- | ------------------------------------- |
| Keycloak    | N/A (local desktop, no SSO needed)    |
| step-ca     | SSH certs for accessing other systems |
| Tailscale   | Access from outside home network      |
| NFS (Smith) | Mount media/documents if needed       |

## Status

**Exploration complete.** Ready to implement after iGPU freed from Media Stack (rffmpeg migration).

## Dependencies

- [ ] Deploy rffmpeg on GPU Workstation (frees iGPU)
- [ ] Move Media Stack to Kubernetes (no longer needs iGPU)
- [ ] NixOS flake structure in aether repo

## Related Documents

- `nixos.md` — NixOS migration strategy (Desktop VM fits phase 2.5)
- `kubernetes.md` — Media Stack migration (enables this)
- `../ai-ml.md` — GPU Workstation (rffmpeg host)
- `../hosts.md` — Trinity specs
