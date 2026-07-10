# Notifications Stack

This playbook configures the Fedora `notifications-stack` VM declared in
`config/vm.yml` and provisioned by `tofu/home/notifications_stack.tf`.

Current VM services:

- Apprise notification gateway
- ntfy push notifications
- Postfix relay through AWS SES
- VM OpenTelemetry monitoring agent

Matrix Synapse and its bridges moved to Talos Kubernetes and are declared in
`tofu/home/kubernetes/matrix.tf`. The old Matrix playbook and decommission
playbook remain only as migration history.

## Usage

```bash
task configure:notifications-stack
```

## Focused Configuration

```bash
task configure:notifications
task ansible:playbook -- notifications_stack/apprise.yml
task ansible:playbook -- notifications_stack/ntfy.yml
task ansible:playbook -- notifications_stack/hermes_bots.yml
```
