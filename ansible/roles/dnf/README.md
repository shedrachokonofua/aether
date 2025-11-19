# DNF Role

This role manages DNF package manager on RHEL-based systems (Fedora, CentOS, RHEL, etc.).

## Features

- Always installs `python3-libdnf5` (required for Ansible dnf module)
- Configures automatic system updates via `dnf-automatic` (enabled by default)
- Fedora system-upgrade workflow (download + reboot) enabled by default
- Automatic updates include:
  - Automatic reboots when needed
  - Daily updates at 5am
  - Can be disabled by setting `dnf_enable_automatic_updates: false`

## Requirements

- RHEL-based system with DNF package manager
- systemd

## Role Variables

All variables have sensible defaults defined in `defaults/main.yml`:

| Variable                         | Default       | Description                                                                |
| -------------------------------- | ------------- | -------------------------------------------------------------------------- |
| `dnf_enable_automatic_updates`   | `true`        | Whether to enable automatic updates (set to false to disable)              |
| `dnf_automatic_update_type`      | `default`     | Type of updates to apply (`default` for all, `security` for security only) |
| `dnf_automatic_reboot`           | `when-needed` | Reboot policy: `never`, `when-needed`, or `when-changed`                   |
| `dnf_automatic_timer_oncalendar` | `05:00`       | Time to run updates (systemd calendar format)                              |
| `dnf_system_upgrade_enabled`     | `true`        | Whether to run `dnf system-upgrade` workflow on Fedora hosts               |
| `dnf_system_upgrade_releasever`  | `43`          | Target Fedora release version for the upgrade                              |

## Example Playbook

Default usage (installs libdnf5 AND configures automatic updates):

```yaml
- hosts: servers
  roles:
    - dnf # Installs libdnf5 and sets up automatic updates at 5am
```

Disable automatic updates (libdnf5 only):

```yaml
- hosts: servers
  roles:
    - role: dnf
      vars:
        dnf_enable_automatic_updates: false # Opt-out of automatic updates
```

Custom automatic update configuration:

```yaml
- hosts: servers
  roles:
    - role: dnf
      vars:
        dnf_enable_automatic_updates: true
        dnf_automatic_update_type: security # Security updates only
        dnf_automatic_timer_oncalendar: "03:00" # Run at 3am instead
        dnf_automatic_reboot: never # Don't auto-reboot
```

## Timer Management

By default, the role configures `dnf-automatic-install.timer` which applies updates automatically. To check the timer status:

```bash
systemctl status dnf-automatic-install.timer
systemctl list-timers dnf-automatic*
```

To manually trigger an update:

```bash
systemctl start dnf-automatic-install.service
```
