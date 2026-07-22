#!/usr/bin/env python3
"""Bidirectional live-vs-IaC drift check for the VyOS home router.

Compares `show configuration commands` on the router against every
`vyos.vyos.vyos_config` line declared in
ansible/playbooks/home_router/configure_router.yml, both directions:

  MISSING    declared in IaC but absent live (a reverted hand-fix, a failed
             apply, or a task that never ran) - the rule-24 class.
  UNDECLARED live in a section the playbook manages but absent from IaC
             (a live patch that never got its follow-up commit) - the
             rule-30 class (hand-added 2025-12-21, undeclared for 7 months).

Variables are FULLY RENDERED from config/vm.yml + secrets/tf-outputs.json +
the play's static vars before comparing - a value edit inside a templated
line is drift (the ad-hoc prefix matching this replaces let rule 24's
source-address revert slip through). Lines templating `secrets.*` are
compared by prefix only (their values must not appear in output or logs).

Scope: only top-level config sections the playbook touches are checked in
the UNDECLARED direction, and image-baked/system-managed lines are
allowlisted below. Exit 0 clean, 1 drift, 2 error - fit for CI/cron.

Usage: nix develop --command ./scripts/router-drift.py [--host aether@10.0.2.1]
Needs the aether SSH cert (task login) in the agent, or run with
SSH_AUTH_SOCK=$HOME/.aether-toolbox/ssh/agent.sock.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PLAYBOOK = REPO / "ansible/playbooks/home_router/configure_router.yml"
VM_YML = REPO / "config/vm.yml"
TF_OUTPUTS = REPO / "secrets/tf-outputs.json"

# Static vars declared inline in the play (keep in sync with its `vars:`).
PLAY_VARS = {
    "aether_identity": {"fabric": "aether", "site": "home", "host": "router"},
    "site_wireguard_peer": {"site": "aws", "host": "link"},
}

# Live lines the playbook deliberately does not own. Prefix match, normalized
# (quotes stripped). Keep this list SHORT and justified.
UNDECLARED_ALLOWLIST = (
    "set interfaces ethernet eth0 address ",   # packer image (packer-vyos-configure.sh.j2)
    "set interfaces ethernet eth1 address ",   # packer image
    "set interfaces ethernet eth0 hw-id ",     # VyOS persists NIC identity
    "set interfaces ethernet eth1 hw-id ",
    "set interfaces ethernet eth2 hw-id ",
    "set system ipv6 disable-forwarding",      # migration companion of declared `ipv6 disable`
    "set system login user ",                  # image-baked admin user + keys
    "set system host-name ",                   # image
    "set service ntp ",                        # VyOS defaults
    "set system syslog ",                      # VyOS defaults
    "set system config-management ",           # commit-archive defaults
    "set system console ",                     # VyOS defaults
    "set system conntrack ",                   # VyOS defaults
)


def norm(line: str) -> str:
    """Normalize a config line for comparison: strip quotes, squeeze spaces."""
    return re.sub(r"\s+", " ", line.replace("'", "").replace('"', "")).strip()


def dotted(ctx: dict, path: str):
    cur = ctx
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def load_context() -> dict:
    import yaml  # provided by the dev shell's ansible toolchain

    ctx = {"vm": yaml.safe_load(VM_YML.read_text())}
    ctx.update(PLAY_VARS)
    if TF_OUTPUTS.exists():
        tf = json.loads(TF_OUTPUTS.read_text())
        ctx["tf_outputs"] = tf
    return ctx


VAR_RE = re.compile(r"\{\{\s*([a-zA-Z0-9_.]+)\s*\}\}")


def render(line: str, ctx: dict):
    """Render {{ dotted.path }} refs. Returns (rendered, fully_rendered)."""
    unresolved = False

    def sub(m: re.Match) -> str:
        nonlocal unresolved
        val = dotted(ctx, m.group(1))
        if val is None:
            unresolved = True
            return m.group(0)
        return str(val)

    return VAR_RE.sub(sub, line), not unresolved


# Live lines whose tails are secrets: never print their values. VyOS emits
# pppoe credentials, wireguard private keys, etc. in cleartext config dumps.
SENSITIVE_RE = re.compile(
    r"^(set .*?(?:authentication (?:password|username)|private-key|pre-shared-secret|public-keys \S+ key)) .+$"
)


def mask(line: str) -> str:
    return SENSITIVE_RE.sub(r"\1 <redacted>", line)


def is_sensitive(line: str) -> bool:
    return bool(SENSITIVE_RE.match(line))


def declared_lines() -> list[str]:
    """Every `- set ...` / `- delete ...` under vyos_config lines."""
    out = []
    for m in re.finditer(r"^\s+- ((?:set|delete) .+)$", PLAYBOOK.read_text(), re.M):
        out.append(m.group(1).strip())
    return out


def live_lines(host: str, identity: str | None) -> list[str]:
    env = dict(os.environ)
    env.setdefault("SSH_AUTH_SOCK", os.path.expanduser("~/.aether-toolbox/ssh/agent.sock"))
    cmd = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
    if identity:
        cmd += ["-i", identity, "-o", "IdentitiesOnly=yes",
                "-o", "StrictHostKeyChecking=accept-new"]
    # The drift-probe account force-runs this exact command; passing it is a
    # no-op there and required for the interactive aether account.
    cmd += [host, "/opt/vyatta/bin/vyatta-op-cmd-wrapper show configuration commands"]
    r = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=60)
    if r.returncode != 0:
        print(f"ERROR: cannot fetch live config from {host}: {r.stderr.strip()}", file=sys.stderr)
        sys.exit(2)
    return [l for l in r.stdout.splitlines() if l.startswith("set ")]


def _grafana_ch_query(grafana_url: str, ds_uid: str, sql: str) -> str:
    """Run one SQL via the Grafana ClickHouse datasource proxy (read-only SA
    token, env GRAFANA_SA_TOKEN); return the first column of the first row."""
    import json
    import urllib.request

    token = os.environ.get("GRAFANA_SA_TOKEN")
    if not token:
        print("ERROR: GRAFANA_SA_TOKEN not set (sops grafana_sa_token)", file=sys.stderr)
        sys.exit(2)
    payload = json.dumps({"queries": [{
        "refId": "A",
        "datasource": {"uid": ds_uid, "type": "grafana-clickhouse-datasource"},
        "rawSql": sql, "format": 1,
    }]}).encode()
    req = urllib.request.Request(
        f"{grafana_url}/api/ds/query", data=payload,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            frames = json.load(resp)["results"]["A"]["frames"]
        values = frames[0]["data"]["values"]
        if not values or not values[0]:
            print("ERROR: empty ClickHouse result", file=sys.stderr)
            sys.exit(2)
        return values[0][0]
    except (KeyError, IndexError, ValueError) as e:
        print(f"ERROR: unexpected ClickHouse/Grafana response: {e}", file=sys.stderr)
        sys.exit(2)


def clickhouse_live_lines(grafana_url: str, ds_uid: str, source_instance: str) -> list[str]:
    """Latest redacted LIVE config the router pushed to ClickHouse (no router
    access) — network.router_config_snapshots via the Grafana proxy."""
    sql = ("SELECT config FROM network.router_config_snapshots FINAL "
           f"WHERE source_instance = '{source_instance}' "
           "ORDER BY timestamp DESC LIMIT 1")
    return [l for l in _grafana_ch_query(grafana_url, ds_uid, sql).splitlines()
            if l.startswith("set ")]


def build_declared_from_repo(ctx):
    """(declared_exact, declared_secret_prefixes) rendered from the repo."""
    declared_exact: set[str] = set()
    declared_secret_prefixes: set[str] = set()
    for raw in declared_lines():
        if raw.startswith("delete "):
            continue
        if "secrets." in raw or ("tf_outputs." in raw and "tf_outputs" not in ctx):
            declared_secret_prefixes.add(norm(raw.split("{{", 1)[0]))
            continue
        rendered, complete = render(raw, ctx)
        if not complete:
            print(f"ERROR: unresolved variable in declared line: {raw}", file=sys.stderr)
            sys.exit(2)
        declared_exact.add(norm(rendered))
    return declared_exact, declared_secret_prefixes


def serialize_declared(declared_exact, declared_secret_prefixes) -> str:
    """EXACT/PREFIX lines — the structured declared snapshot published to CH.
    Keeps secret lines as PREFIX matches (not redacted content) so the compare
    is identical whether declared comes from the repo or ClickHouse."""
    out = [f"PREFIX {p}" for p in sorted(declared_secret_prefixes)]
    out += [f"EXACT {l}" for l in sorted(declared_exact)]
    return "\n".join(out)


def parse_declared(blob: str):
    declared_exact, declared_secret_prefixes = set(), set()
    for line in blob.splitlines():
        if line.startswith("EXACT "):
            declared_exact.add(line[6:])
        elif line.startswith("PREFIX "):
            declared_secret_prefixes.add(line[7:])
    return declared_exact, declared_secret_prefixes


def publish_declared_to_ch(blob: str, source_instance: str) -> None:
    """INSERT the declared snapshot into network.router_config_declared via the
    ClickHouse admin HTTP endpoint (env CH_URL/CH_USER/CH_ADMIN_PASSWORD).
    Runs where the repo+secrets already live (router apply), not in Kestra."""
    import base64, hashlib, json as _json, subprocess, urllib.request
    url = os.environ.get("CH_URL", "https://clickhouse.home.shdr.ch")
    user = os.environ.get("CH_USER", "aether")
    pw = os.environ.get("CH_ADMIN_PASSWORD")
    if not pw:
        print("ERROR: CH_ADMIN_PASSWORD not set (sops clickhouse.password)", file=sys.stderr)
        sys.exit(2)
    try:
        git_sha = subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                                 capture_output=True, text=True, cwd=str(REPO)).stdout.strip()
    except Exception:
        git_sha = "unknown"
    row = {
        "timestamp": __import__("datetime").datetime.now(__import__("datetime").timezone.utc)
            .strftime("%Y-%m-%d %H:%M:%S.%f")[:-3],
        "source_instance": source_instance, "git_sha": git_sha,
        "sha256": hashlib.sha256(blob.encode()).hexdigest(),
        "line_count": blob.count("\n") + 1 if blob else 0, "config": blob,
    }
    body = ("INSERT INTO network.router_config_declared "
            "(timestamp, source_instance, git_sha, sha256, line_count, config) "
            "FORMAT JSONEachRow\n" + _json.dumps(row)).encode()
    auth = base64.b64encode(f"{user}:{pw}".encode()).decode()
    req = urllib.request.Request(url, data=body, headers={"Authorization": f"Basic {auth}"})
    with urllib.request.urlopen(req, timeout=30):
        pass
    print(f"published declared snapshot: git={git_sha} sha256={row['sha256'][:16]} "
          f"({row['line_count']} lines) -> network.router_config_declared")


def clickhouse_declared_blob(grafana_url: str, ds_uid: str, source_instance: str) -> str:
    """Latest declared snapshot blob from CH via the read-only Grafana proxy."""
    sql = ("SELECT config FROM network.router_config_declared FINAL "
           f"WHERE source_instance = '{source_instance}' ORDER BY timestamp DESC LIMIT 1")
    return _grafana_ch_query(grafana_url, ds_uid, sql)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="aether@10.0.2.1")
    ap.add_argument("--identity", default=None,
                    help="SSH private key (e.g. the CI drift-probe key); default uses the agent")
    ap.add_argument("--clickhouse", action="store_true",
                    help="read LIVE config from the router's pushed snapshot in ClickHouse "
                         "via the Grafana proxy (no router access; needs env GRAFANA_SA_TOKEN)")
    ap.add_argument("--declared-source", choices=["repo", "clickhouse"], default="repo",
                    help="where DECLARED config comes from: repo (render, needs the tree) or "
                         "clickhouse (published snapshot; unattended, no repo)")
    ap.add_argument("--publish-declared", action="store_true",
                    help="render declared from repo and INSERT it to "
                         "network.router_config_declared (env CH_ADMIN_PASSWORD); then exit")
    ap.add_argument("--grafana-url", default="https://grafana.home.shdr.ch")
    ap.add_argument("--ch-datasource-uid", default="clickhouse")
    ap.add_argument("--source-instance", default="aether-home-router")
    args = ap.parse_args()

    if args.publish_declared:
        exact, prefixes = build_declared_from_repo(load_context())
        publish_declared_to_ch(serialize_declared(exact, prefixes), args.source_instance)
        return 0

    if args.declared_source == "clickhouse":
        declared_exact, declared_secret_prefixes = parse_declared(
            clickhouse_declared_blob(args.grafana_url, args.ch_datasource_uid, args.source_instance))
    else:
        declared_exact, declared_secret_prefixes = build_declared_from_repo(load_context())

    if args.clickhouse:
        live = [norm(l) for l in clickhouse_live_lines(
            args.grafana_url, args.ch_datasource_uid, args.source_instance)]
    else:
        live = [norm(l) for l in live_lines(args.host, args.identity)]
    live_set = set(live)

    managed = {tuple(l.split()[1:3]) for l in declared_exact}

    def is_declared(l: str) -> bool:
        if l in declared_exact:
            return True
        return any(l.startswith(p) for p in declared_secret_prefixes)

    undeclared = [
        l for l in live
        if tuple(l.split()[1:3]) in managed
        and not is_declared(l)
        and not any(l.startswith(a) for a in (norm(x) + " " if x.endswith(" ") else norm(x) for x in UNDECLARED_ALLOWLIST))
    ]

    missing = [l for l in sorted(declared_exact) if l not in live_set]
    for p in sorted(declared_secret_prefixes):
        if not any(l.startswith(p) for l in live):
            missing.append(f"{p}<secret> (no live line matches prefix)")

    drift = bool(undeclared or missing)
    print(f"router drift check: live={'clickhouse' if args.clickhouse else args.host} "
          f"declared={args.declared_source}")
    print(f"  declared lines: {len(declared_exact) + len(declared_secret_prefixes)}"
          f"  live lines: {len(live)}  managed sections: {len(managed)}")
    if undeclared:
        print(f"\nUNDECLARED (live only, {len(undeclared)}) - live patches needing IaC adoption or removal:")
        for l in undeclared:
            print(f"  + {mask(l)}")
    if missing:
        print(f"\nMISSING (IaC only, {len(missing)}) - reverted or never-applied declared config:")
        for l in missing:
            print(f"  - {l}")
    if not drift:
        print("  clean: live config and IaC agree.")
    return 1 if drift else 0


if __name__ == "__main__":
    sys.exit(main())
