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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="aether@10.0.2.1")
    ap.add_argument("--identity", default=None,
                    help="SSH private key (e.g. the CI drift-probe key); default uses the agent")
    ap.add_argument("--emit-declared", action="store_true",
                    help="print the rendered declared snapshot (EXACT/PREFIX/ALLOW/SECTION "
                         "lines) for /config/drift/declared.txt on the router - consumed by "
                         "the on-router drift-report.sh that Kestra's nightly probe runs")
    args = ap.parse_args()

    ctx = load_context()

    declared_exact: set[str] = set()      # fully rendered lines
    declared_secret_prefixes: set[str] = set()  # lines templating secrets.*: prefix up to the ref
    deletes: set[str] = set()

    for raw in declared_lines():
        if raw.startswith("delete "):
            deletes.add(norm(raw.removeprefix("delete ")))
            continue
        # Secret-templated lines never render; tf_outputs lines degrade to
        # prefix comparison when secrets/tf-outputs.json is absent (CI runner).
        if "secrets." in raw or ("tf_outputs." in raw and "tf_outputs" not in ctx):
            declared_secret_prefixes.add(norm(raw.split("{{", 1)[0]))
            continue
        rendered, complete = render(raw, ctx)
        if not complete:
            # Unresolvable ref = a play var this script does not know about.
            # Fail loudly rather than silently weakening the check.
            print(f"ERROR: unresolved variable in declared line: {raw}", file=sys.stderr)
            return 2
        declared_exact.add(norm(rendered))

    if args.emit_declared:
        managed = sorted({tuple(l.split()[1:3]) for l in declared_exact})
        for a, b in managed:
            print(f"SECTION {a} {b}")
        for a in UNDECLARED_ALLOWLIST:
            print(f"ALLOW {norm(a)}")
        for p in sorted(declared_secret_prefixes):
            print(f"PREFIX {p}")
        for l in sorted(declared_exact):
            print(f"EXACT {l}")
        return 0

    live = [norm(l) for l in live_lines(args.host, args.identity)]
    live_set = set(live)

    # Sections the playbook manages = first two tokens after `set`.
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

    # Declared-but-missing. Secret-prefix lines checked by prefix presence.
    missing = [l for l in sorted(declared_exact) if l not in live_set]
    for p in sorted(declared_secret_prefixes):
        if not any(l.startswith(p) for l in live):
            missing.append(f"{p}<secret> (no live line matches prefix)")

    drift = bool(undeclared or missing)
    print(f"router drift check: {args.host}")
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
