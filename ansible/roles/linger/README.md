# Linger

A simple role to manage systemd linger for users. Enabling linger allows user services to continue running after the user logs out, which is essential for running persistent podman containers via quadlets in user mode.

## Variables

- `linger_user`: User to configure linger for (default: current Ansible user)
- `linger_state`: Whether linger should be "enabled" or "disabled" (default: "enabled")

## Usage

```yaml
# playbook.yml
- name: Enable linger for ansible user
  hosts: home-gateway-stack
  roles:
    - linger

- name: Disable linger for user
  hosts: home-gateway-stack
  roles:
    - role: linger
      vars:
        linger_user: randomuser
        linger_state: disabled
```
