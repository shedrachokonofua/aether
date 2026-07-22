#!/bin/bash
# Managed by Ansible (home_router). Do not edit by hand.
# VyOS task-scheduler entrypoint: dump running config -> redacting emitter ->
# vyos-exporter observations dir (existing OTel/ClickHouse push path). No
# inbound access, no login/ssh config touched.
set -eu
/opt/vyatta/bin/vyatta-op-cmd-wrapper show configuration commands \
  | /usr/bin/python3 /config/scripts/config-snapshot-emit.py /config/vyos-exporter/observations
