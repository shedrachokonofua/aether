# Dokploy

This playbook is for configuring the [dokploy](https://dokploy.com) virtual machine. Dokploy is a fedora vm that hosts the dokploy service. It serves as a one-click docker container app store and deployment platform. The applications hosted on dokploy are relatively simple and not worth the effort of fully managing with IaC in a dedicated VM stack.

## Usage

```bash
task configure:home:dokploy
```
