# Messaging Stack

This playbook will configure the messaging stack virtual machine. The messaging stack is a fedora vm that hosts the following applications deployed as podman quadlets:

- Apprise: Unified notification gateway API
- Matrix Synapse: Federated messaging server with Element web client
- Mautrix WhatsApp Bridge: Matrix bridge for WhatsApp messaging
- Mautrix Google Messages Bridge: Matrix bridge for Google Messages
- ntfy: Push notification server
- Postfix: SMTP relay using A WS SES

## Usage

```bash
task configure:home:messaging
```

## Sub-Playbooks

### Deploy Apprise Gateway

```bash
task ansible:playbook -- ./ansible/playbooks/messaging_stack/apprise.yml
```

### Deploy Matrix

```bash
task ansible:playbook -- ./ansible/playbooks/messaging_stack/matrix.yml
```

### Deploy ntfy

```bash
task ansible:playbook -- ./ansible/playbooks/messaging_stack/ntfy.yml
```

### Deploy Postfix Relay

```bash
task ansible:playbook -- ./ansible/playbooks/messaging_stack/postfix.yml
```
