#!/usr/bin/env python3
# Managed by Ansible (home_router). Do not edit by hand.
#
# Reads `show configuration commands` on stdin, REDACTS secret-bearing lines,
# and writes ONE NDJSON record atomically into the router-drift observations
# dir. A dedicated filelog receiver ships it (log.source=router_drift) to
# ClickHouse network.router_config_snapshots - a channel SEPARATE from the
# vyos-exporter's content-free vyos_observations stream.
#
# Fail-closed: if any secret-key line survives redaction without the
# <redacted> placeholder, emit a hash-only record (kind=
# router_config_snapshot_redaction_failed) instead of leaking content - the MV
# records status=redaction_failed so the failure is visible, not silent.
#
# Self-prune: delete-after-read handles the happy path; this also drops own
# snapshots older than RETAIN_DAYS so a wedged consumer can't fill /config.
import sys, os, json, hashlib, tempfile, datetime, re, glob, time

OBS_DIR = sys.argv[1] if len(sys.argv) > 1 else "/config/router-drift/observations"
RETAIN_DAYS = 3

# Lines whose tail is a secret; redaction replaces the tail with <redacted>.
SECRET_RE = re.compile(
    r'^(set .*?(?:authentication (?:password|username)|private-key|'
    r'pre-shared-secret|public-keys \S+ key)) .+$'
)


def redact(line: str) -> str:
    return SECRET_RE.sub(r'\1 <redacted>', line)


def redaction_failed(line: str) -> bool:
    # A secret-key line is only clean if it now ends with the placeholder.
    return bool(SECRET_RE.match(line)) and not line.endswith(' <redacted>')


lines = []
leaked = False
for raw in sys.stdin:
    line = raw.rstrip('\n')
    if not line.startswith('set '):
        continue
    red = redact(line)
    if redaction_failed(red):
        leaked = True
    lines.append(red)

cfg = '\n'.join(sorted(lines))
sha = hashlib.sha256(cfg.encode()).hexdigest()
now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'
instance = os.uname().nodename

if leaked:
    # Fail closed: never emit content we could not fully redact.
    rec = {"kind": "router_config_snapshot_redaction_failed", "timestamp": now,
           "source_instance": instance, "sha256": sha, "line_count": 0, "config": ""}
else:
    rec = {"kind": "router_config_snapshot", "timestamp": now,
           "source_instance": instance, "sha256": sha, "line_count": len(lines), "config": cfg}

os.makedirs(OBS_DIR, exist_ok=True)
# Self-prune: drop own stale snapshots (consumer-down safety).
cutoff = time.time() - RETAIN_DAYS * 86400
for old in glob.glob(os.path.join(OBS_DIR, 'router-config-*.ndjson')):
    try:
        if os.path.getmtime(old) < cutoff:
            os.remove(old)
    except OSError:
        pass

fd, tmp = tempfile.mkstemp(dir=OBS_DIR, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    f.write(json.dumps(rec) + '\n')
os.chmod(tmp, 0o644)  # filelog container reads as a mapped subuid
os.replace(tmp, os.path.join(OBS_DIR, f'router-config-{sha[:16]}.ndjson'))
print(f"emitted kind={rec['kind']} lines={rec['line_count']} sha256={sha[:16]}")
sys.exit(1 if leaked else 0)
