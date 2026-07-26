# Bug: rootless podman nests `runtime` cgroups on restart → systemd EBUSY, unit unstartable

Status: workaround documented (depth-first cgroup cleanup); root cause not fixed.
Found: 2026-07-26 during a routine Loki config deploy.

## Symptom

`systemctl --user restart loki.service` never comes back. Journal:

```
loki.service: Failed to spawn executor: Device or resource busy
loki.service: Failed with result 'resources'.
```

Unit enters `activating` forever; playbook waits time out.

## Root cause (mechanism, not origin)

Each podman restart of the container nests another `runtime` cgroup inside
the previous one instead of reusing/removing it:

```
/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice/loki.service/runtime/runtime/runtime/… (thousands deep)
```

The leaked tree is empty (`populated 0`, no procs) but pinned: even root
cannot `rmdir` the top (`EBUSY`) because children exist, and systemd
refuses to spawn the unit while its cgroup path is in this state. The
nesting accumulates across every crashloop/restart, so any service that
restarts often will eventually wedge the same way — Loki just got there
first.

## Workaround (verified 2026-07-26, twice)

```sh
sudo -i -u aether XDG_RUNTIME_DIR=/run/user/1000 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
  systemctl --user stop loki.service
CG=/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice/loki.service
find "$CG" -depth -type d -exec rmdir {} +
systemctl --user start loki.service   # starts cleanly
```

`daemon-reexec`, `reset-failed`, and stopping the unit alone do NOT clear
it. If the tree re-nests on the next restart, repeat.

## Investigation leads for the next agent

- Rootless podman version on monitoring-stack (`podman version`) vs known
  runc/crun cgroup-leak issues (crun <1.x nested-runtime-cgroup bugs).
- Check whether other long-restarted units on the box have nested
  `runtime/runtime/…` trees: `find /sys/fs/cgroup/user.slice -path '*runtime*runtime*'`.
- The unit had restart counter ≥13 from a crashloop (bad config value);
  the leak turns any crashloop into a wedge. A `Restart=` backoff cap
  would bound the nesting.
- If reproducible, capture `podman --log-level=debug` of a single
  restart cycle and file upstream (containers/podman or containers/crun).

## Impact note

While wedged, the otel collector's `otlphttp/loki` exporter errors; log
ingestion stalls. Prometheus-metrics alerting keeps working, so the box
is not blind, but every Loki-backed alert is (execErrState dependent).
