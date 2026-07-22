#!/usr/bin/env python3
# Managed by Ansible (home_router). Do not edit by hand.
#
# Reads `show configuration commands` on stdin, REDACTS secret-bearing lines,
# and writes ONE NDJSON record atomically into the vyos-exporter observations
# dir. The existing filelog -> OTel -> network.ingest path ships it; the
# 17-router-config-snapshots MV routes it into network.router_config_snapshots.
# Secrets never leave the router - only `<redacted>` placeholders are emitted.
import sys, os, json, hashlib, tempfile, datetime, re

OBS_DIR = sys.argv[1] if len(sys.argv) > 1 else "/config/vyos-exporter/observations"
SECRET_RE = re.compile(
    r'^(set .*?(?:authentication (?:password|username)|private-key|'
    r'pre-shared-secret|public-keys \S+ key)) .+$'
)

lines = []
for raw in sys.stdin:
    line = raw.rstrip('\n')
    if not line.startswith('set '):
        continue
    lines.append(SECRET_RE.sub(r'\1 <redacted>', line))

cfg = '\n'.join(sorted(lines))
sha = hashlib.sha256(cfg.encode()).hexdigest()
rec = {
    "kind": "router_config_snapshot",
    "timestamp": datetime.datetime.now(datetime.timezone.utc)
        .strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z',
    "source_instance": os.uname().nodename,
    "sha256": sha,
    "line_count": len(lines),
    "config": cfg,
}

os.makedirs(OBS_DIR, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=OBS_DIR, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    f.write(json.dumps(rec) + '\n')
# mkstemp is 0600; the OTel filelog container reads as a mapped subuid, so the
# snapshot must be world-readable like the exporter's own observation files.
os.chmod(tmp, 0o644)
# .ndjson (not .tmp) is what the filelog receiver includes; rename is atomic.
os.replace(tmp, os.path.join(OBS_DIR, f'router-config-{sha[:16]}.ndjson'))
print(f'emitted {len(lines)} lines, sha256={sha[:16]}')
