# VM Baseline Role

Sets hostname, timezone, and user linger on VMs.

## Features

- Sets system hostname using Ansible's `hostname` module
- Configures timezone using Ansible's `timezone` module
- Enables systemd linger for persistent user services
- Both modules handle cross-platform differences automatically

## Requirements

- Linux-based VM with systemd
- Root/sudo access

## Role Variables

| Variable                    | Default                    | Description                                       |
| --------------------------- | -------------------------- | ------------------------------------------------- |
| `vm_baseline_hostname`      | `{{ inventory_hostname }}` | Hostname to set                                   |
| `vm_baseline_timezone`      | `America/Toronto`          | Timezone to configure                             |
| `vm_baseline_enable_linger` | `true`                     | Enable linger for user (persistent user services) |
| `vm_baseline_linger_user`   | `{{ ansible_user_id }}`    | User to enable linger for                         |

## Example Playbook

```yaml
# Use defaults
- hosts: all
  roles:
    - vm_baseline

# Custom values
- hosts: dev
  roles:
    - role: vm_baseline
      vars:
        vm_baseline_hostname: dev.example.com
        vm_baseline_timezone: America/New_York

# With other roles
- hosts: all
  roles:
    - common
    - vm_baseline
    - monitoring_agent
```

## Verification

```bash
# Check hostname
hostname -f

# Check timezone
timedatectl show --property=Timezone --value
```
