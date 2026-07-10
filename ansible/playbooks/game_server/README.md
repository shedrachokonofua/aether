# Legacy Bazzite VM Workflow

The current game server is a Kubernetes workload declared in
`tofu/home/kubernetes/game_server.tf`. There is no `vm.game_server` entry in
`config/vm.yml`, so the old Bazzite VM provision/configure playbooks and their
aggregate `site.yml` are not a current deployment path.

The Bazzite builder declaration still exists as `bazzite_builder` in
`config/vm.yml`. These focused image-building playbooks remain available for
historical or future Bazzite image work:

```bash
task ansible:playbook -- game_server/provision_bazzite_builder.yml
task ansible:playbook -- game_server/build_bazzite_image.yml
task ansible:playbook -- game_server/destroy_bazzite_builder.yml
```

Do not run `game_server/site.yml`, `provision_game_server.yml`, or
`configure_game_server.yml` unless a complete VM declaration and migration plan
are intentionally reintroduced.
