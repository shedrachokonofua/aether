# IoT Management Stack

This playbook is for configuring the IoT management stack virtual machine. The IoT management stack is a fedora vm that hosts the following applications deployed as podman quadlets:

- Home Assistant

## Usage

```bash
task configure:iot
```

## Scenes

`scenes_aether.yml` holds the Ansible-managed room scenes (office on/off,
living room TV on/off, bedroom TV off, living room evening mood, everything
off). It deploys to `scenes_aether.yaml` and loads through `scene aether:` in
`ha_config.yml`; `scenes.yaml` stays reserved for scenes created in the HA UI.
Changing the file restarts Home Assistant. The scenes appear as
`scene.office_on`, `scene.office_off`, `scene.living_room_tv_on`,
`scene.living_room_tv_off`, `scene.bedroom_tv_off`,
`scene.living_room_evening_mood` and `scene.everything_off`.
