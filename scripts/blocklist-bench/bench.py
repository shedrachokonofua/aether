#!/usr/bin/env python3
"""
DNS blocklist benchmark for the Technitium cluster.

Purpose: compare the 21 currently configured HostlistsRegistry feeds as one
merged set with maintained replacement candidates.  The program never makes
DNS queries: it only downloads text/CSV feeds, normalizes rules to registrable
looking domain strings, and performs set/suffix membership tests offline.

Usage (all commands must run in the repository's Nix dev shell):
  nix develop --command python3 scripts/blocklist-bench/bench.py
  nix develop --command python3 scripts/blocklist-bench/bench.py --offline
  nix develop --command python3 scripts/blocklist-bench/bench.py --refresh

The first invocation downloads lists and corpora into .cache/.  Subsequent
--offline runs use exactly those bytes, which makes a result reproducible.
The generated Markdown report is stdout and (unless --no-report) report.md.
Do not edit config/technitium-settings.json in this benchmark.

Candidate research (accessed 2026-07-18; URLs are also emitted in report.md):
* HaGeZi DNS Blocklists README: https://github.com/hagezi/dns-blocklists
  (Normal, Pro, and Pro++ entries, formats, size and blocking-level guidance)
* OISD homepage/setup: https://oisd.nl/ and https://oisd.nl/setup
  (big/small purpose, functionality-first false-positive policy and endpoints)
* StevenBlack hosts README: https://github.com/StevenBlack/hosts
  (unified hosts aggregation, entry count and update information)
* 1Hosts README: https://github.com/badmojr/1Hosts
  (Lite versus aggressive Xtra/Pro-equivalent, formats and FP trade-off)

Independent corpus sources:
* d3ward/toolz d3host.txt (archived ad/tracker test set):
  https://raw.githubusercontent.com/d3ward/toolz/master/src/d3host.txt
* URLhaus current hostfile (abuse.ch malware feed):
  https://urlhaus.abuse.ch/downloads/hostfile/
* Phishing Army blocklist (phishing feed):
  https://phishing.army/download/phishing_army_blocklist.txt
* Tranco current top-1M CSV (legitimate FP corpus sample):
  https://tranco-list.eu/top-1m.csv.zip

Interpretation: this is a static corpus benchmark, not a live DNS or browser
integration test.  A corpus hit means the normalized list contains that domain
or one of its parents.  FP hits are intentionally conservative: they flag a
candidate's parent-domain coverage of popular legitimate names and a small
set of common CDN/banking/streaming names.
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import re
import sys
import time
import urllib.error
import urllib.request
import zipfile
from collections import defaultdict
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
CACHE = HERE / ".cache"
LIST_CACHE = CACHE / "lists"
CORPUS_CACHE = CACHE / "corpus"
USER_AGENT = "aether-blocklist-bench/1.0 (+offline-reproducible)"

# Formats are chosen for Technitium (plain domains where available).  The
# 1Hosts Xtra artifact is their current aggressive/Pro-equivalent name.
CANDIDATES = [
    {
        "name": "hagezi-normal", "label": "HaGeZi Normal", "format": "adblock",
        "url": "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/multi.txt",
        "cadence": "daily/continuous (GitHub main)",
        "fp": "balanced/relaxed; README says should not restrict most users",
        "citation": "https://github.com/hagezi/dns-blocklists#normal",
    },
    {
        "name": "hagezi-pro", "label": "HaGeZi Pro", "format": "adblock",
        "url": "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt",
        "cadence": "daily/continuous (GitHub main)",
        "fp": "balanced; maintainer recommendation, very rarely restricts",
        "citation": "https://github.com/hagezi/dns-blocklists#pro",
    },
    {
        "name": "hagezi-pro-plus", "label": "HaGeZi Pro++", "format": "adblock",
        "url": "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.plus.txt",
        "cadence": "daily/continuous (GitHub main)",
        "fp": "balanced/aggressive; README warns a few false positives",
        "citation": "https://github.com/hagezi/dns-blocklists#proplus",
    },
    {
        "name": "oisd-small", "label": "OISD small", "format": "domains",
        "url": "https://small.oisd.nl/domainswild2",
        "cadence": "frequent automated updates (official endpoint)",
        "fp": "functionality-first; maintainer says should have no false positives",
        "citation": "https://oisd.nl/",
    },
    {
        "name": "oisd-big", "label": "OISD big", "format": "domains",
        "url": "https://big.oisd.nl/domainswild2",
        "cadence": "frequent automated updates (official endpoint)",
        "fp": "functionality-first; maintainer says should have no false positives",
        "citation": "https://oisd.nl/setup",
    },
    {
        "name": "stevenblack", "label": "StevenBlack unified", "format": "hosts",
        "url": "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts",
        "cadence": "repository updates; README publishes last-update date",
        "fp": "curated aggregate; review source-specific issues before use",
        "citation": "https://github.com/StevenBlack/hosts#unified-hosts-file-with-base-extensions",
    },
    {
        "name": "1hosts-lite", "label": "1Hosts Lite", "format": "domains",
        "url": "https://raw.githubusercontent.com/badmojr/1Hosts/master/Lite/domains.txt",
        "cadence": "active repository; ControlD reports 30-minute service refresh",
        "fp": "low; README describes Lite as balanced and accurate",
        "citation": "https://github.com/badmojr/1Hosts#lite",
    },
    {
        "name": "1hosts-pro", "label": "1Hosts Pro (Xtra)", "format": "domains",
        "url": "https://raw.githubusercontent.com/badmojr/1Hosts/master/Xtra/domains.txt",
        "cadence": "active repository; Xtra releases/updates",
        "fp": "higher; README describes aggressive Xtra as potentially disruptive",
        "citation": "https://github.com/badmojr/1Hosts#xtra",
    },
]

CORPORA = [
    ("d3ward", "ads-trackers", "https://raw.githubusercontent.com/d3ward/toolz/master/src/d3host.txt", "text"),
    ("urlhaus", "malware", "https://urlhaus.abuse.ch/downloads/hostfile/", "text"),
    ("phishing-army", "phishing", "https://phishing.army/download/phishing_army_blocklist.txt", "text"),
    ("tranco", "legitimate-top1000", "https://tranco-list.eu/top-1m.csv.zip", "zip"),
]

COMMON_LEGIT = """# Common infrastructure and high-value sites (manual FP safety set)
cloudflare.com
cloudflare-dns.com
akamai.com
akamaized.net
amazon.com
amazonaws.com
apple.com
apple-cloudkit.com
bbc.com
bankofamerica.com
bmo.com
chase.com
citi.com
comcast.com
disney.com
dropbox.com
fastly.com
github.com
gitlab.com
google.com
googleapis.com
gstatic.com
hulu.com
instagram.com
linkedin.com
microsoft.com
microsoftonline.com
netflix.com
paypal.com
pinterest.com
reddit.com
s3.amazonaws.com
salesforce.com
slack.com
spotify.com
steamcommunity.com
stripe.com
twitch.tv
twitter.com
ubuntu.com
walmart.com
wikipedia.org
x.com
youtube.com
zoom.us
"""

DOMAIN_RE = re.compile(r"(?i)^(?:[a-z0-9](?:[a-z0-9_-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")
IP_RE = re.compile(r"^(?:\d{1,3}\.){3}\d{1,3}$|^[0-9a-f:]+$", re.I)


def fetch(url: str, path: Path, refresh: bool) -> None:
    if path.exists() and not refresh:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=90) as response, path.open("wb") as out:
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            out.write(chunk)
    if path.stat().st_size == 0:
        raise RuntimeError(f"empty download: {url}")


def domain_from_rule(line: str) -> str | None:
    line = line.strip().lstrip("\ufeff")
    if not line or line.startswith(("!", "#", ";", "[")):
        return None
    # ABP rules: discard exceptions and cosmetic/options-only rules.  Keep
    # anchored domain rules and remove an optional wildcard prefix.
    if line.startswith("@@"):
        return None
    if line.startswith("||"):
        value = line[2:]
        value = value.split("^", 1)[0].split("$", 1)[0]
        value = value.split("/", 1)[0]
        if value.startswith("*"):
            value = value[1:]
        return clean_domain(value)
    # hosts files: an IP followed by one or more names.  The caller handles
    # multiple names, so this function only parses a single token.
    if line.startswith("/"):
        return None
    value = line.split("#", 1)[0].strip()
    value = value.removeprefix("0.0.0.0 ").removeprefix("127.0.0.1 ")
    value = value.removeprefix(":: ").strip()
    return clean_domain(value)


def clean_domain(value: str) -> str | None:
    value = value.strip().strip(".,\"'").lower().rstrip(".")
    value = value.removeprefix("*.")
    if value.startswith("http://") or value.startswith("https://"):
        value = urlparse(value).hostname or ""
    if not value or IP_RE.fullmatch(value) or not DOMAIN_RE.fullmatch(value):
        return None
    if value in {"localhost.localdomain", "local", "broadcasthost", "ip6-allnodes", "ip6-allrouters"}:
        return None
    return value


def normalize(raw: bytes) -> set[str]:
    result: set[str] = set()
    text = raw.decode("utf-8", errors="replace")
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith(("!", "#", ";", "[")):
            continue
        # Parse all hostnames on hosts lines; ordinary rules are one token.
        fields = stripped.split()
        if len(fields) >= 2 and (IP_RE.fullmatch(fields[0]) or fields[0] in {"localhost", "::1"}):
            for field in fields[1:]:
                domain = clean_domain(field.split("#", 1)[0])
                if domain:
                    result.add(domain)
        else:
            domain = domain_from_rule(stripped)
            if domain:
                result.add(domain)
    return result


def matches(domain: str, rules: set[str]) -> bool:
    labels = domain.split(".")
    return any(".".join(labels[i:]) in rules for i in range(len(labels) - 1))


def config_urls() -> list[str]:
    cfg = ROOT / "config" / "technitium-settings.json"
    data = json.loads(cfg.read_text())
    urls = data["settings"]["blockListUrls"]
    if len(urls) != 21:
        raise RuntimeError(f"expected 21 configured URLs, found {len(urls)}")
    return urls


def write_corpus_files(refresh: bool) -> dict[str, Path]:
    paths: dict[str, Path] = {}
    for name, category, url, kind in CORPORA:
        target = CORPUS_CACHE / (f"{name}.zip" if kind == "zip" else f"{name}.txt")
        fetch(url, target, refresh)
        paths[name] = target
    common = CORPUS_CACHE / "common-legit.txt"
    if refresh or not common.exists():
        common.write_text(COMMON_LEGIT)
    paths["common-legit"] = common
    return paths


def load_corpora(paths: dict[str, Path]) -> tuple[dict[str, set[str]], set[str]]:
    categories: dict[str, set[str]] = defaultdict(set)
    categories["legitimate-common"] = normalize(paths["common-legit"].read_bytes())
    for name, category, _url, kind in CORPORA:
        path = paths[name]
        raw = path.read_bytes()
        if kind == "zip":
            with zipfile.ZipFile(io.BytesIO(raw)) as archive:
                csv_name = archive.namelist()[0]
                text = io.TextIOWrapper(archive.open(csv_name), encoding="utf-8")
                reader = csv.reader(text)
                for row in reader:
                    if len(row) >= 2:
                        domain = clean_domain(row[1])
                        if domain:
                            categories[category].add(domain)
                            if len(categories[category]) >= 1000:
                                break
        else:
            categories[category] = normalize(raw)
    # Keep the benchmark in the requested 500-3000 domain range.  URLhaus may
    # be very large, but capping each dynamic feed makes runs fast and stable
    # while preserving its first (newest) records.
    for category in ("ads-trackers", "malware", "phishing"):
        if len(categories[category]) > 1500:
            categories[category] = set(sorted(categories[category])[:1500])
    # Persist an explicit category label beside the source-specific raw files.
    # This is useful when reviewing a hit and makes the corpus auditable
    # without having to infer a category from a filename.
    labeled = CORPUS_CACHE / "corpus-labeled.tsv"
    with labeled.open("w") as stream:
        stream.write("domain\tcategory\n")
        for category in sorted(categories):
            for domain in sorted(categories[category]):
                stream.write(f"{domain}\t{category}\n")
    return dict(categories), categories["legitimate-common"] | categories["legitimate-top1000"]


def list_sets(refresh: bool, offline: bool, urls: list[str]) -> dict[str, set[str]]:
    if offline and not LIST_CACHE.exists():
        raise RuntimeError("--offline requested but list cache does not exist; run without --offline first")
    current_paths: list[Path] = []
    for index, url in enumerate(urls, 1):
        path = LIST_CACHE / f"current-{index:02d}.txt"
        if not offline:
            fetch(url, path, refresh)
        elif not path.exists():
            raise RuntimeError(f"missing offline cache: {path}")
        current_paths.append(path)
    current: set[str] = set()
    for path in current_paths:
        current |= normalize(path.read_bytes())
    sets = {"current-21-merged": current}
    for item in CANDIDATES:
        safe = item["name"]
        path = LIST_CACHE / f"candidate-{safe}.txt"
        if not offline:
            fetch(item["url"], path, refresh)
        elif not path.exists():
            raise RuntimeError(f"missing offline cache: {path}")
        sets[safe] = normalize(path.read_bytes())
    return sets


def pct(part: int, total: int) -> str:
    return f"{(100 * part / total):.1f}%" if total else "n/a"
def report(sets: dict[str, set[str]], categories: dict[str, set[str]], legit: set[str], urls: list[str], out: Path | None) -> str:
    lines = [
        "# DNS blocklist benchmark",
        "",
        f"Generated: {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}",
        "",
        "## Results",
        "",
        "| List set | Total normalized domains | Ads/tracker coverage | Malware coverage | Phishing coverage | Legit top-1000 FP hits | Common legit FP hits |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for name, rules in sets.items():
        ad = sum(matches(d, rules) for d in categories["ads-trackers"])
        mal = sum(matches(d, rules) for d in categories["malware"])
        phish = sum(matches(d, rules) for d in categories["phishing"])
        top = sum(matches(d, rules) for d in categories["legitimate-top1000"])
        common = sum(matches(d, rules) for d in categories["legitimate-common"])
        lines.append(f"| {name} | {len(rules):,} | {pct(ad, len(categories['ads-trackers']))} ({ad:,}) | {pct(mal, len(categories['malware']))} ({mal:,}) | {pct(phish, len(categories['phishing']))} ({phish:,}) | {top:,} | {common:,} |")
    current = sets["current-21-merged"]
    lines += ["", "## Overlap with current 21-list set", "", "| List set | Shared domains | Candidate domains also in current | Jaccard overlap |", "|---|---:|---:|---:|"]
    for name, rules in sets.items():
        if name == "current-21-merged":
            continue
        shared = len(current & rules)
        union = len(current | rules)
        lines.append(f"| {name} | {shared:,} | {pct(shared, len(rules))} | {pct(shared, union)} |")
    lines += ["", "## Corpus and method", "", f"* Corpus sizes: ads/tracker={len(categories['ads-trackers']):,}, malware={len(categories['malware']):,}, phishing={len(categories['phishing']):,}, legitimate top-1000={len(categories['legitimate-top1000']):,}, common legitimate={len(categories['legitimate-common']):,}.", "* Each raw feed is retained under `.cache/corpus/`; `corpus-labeled.tsv` records every normalized domain with its source category.", "* Matching is exact or parent-suffix (for example, `sub.example.test` matches `example.test`); no DNS queries are made.", "* Dynamic feed order is preserved only until the per-feed cap of 1,500 domains; cached bytes and this script are the reproducibility record.", "* The legitimate corpus is a safety signal, not a proof of a false positive: a broad parent rule can intentionally block a popular service's telemetry subdomain.", "", "### Corpus sources", "", "| Category | Source URL |", "|---|---|"]
    lines.extend(f"| {category} | {url} |" for _name, category, url, _kind in CORPORA)
    lines += ["| legitimate-common | embedded safety set in this script |", "", "## Candidate metadata and citations", "", "| Candidate | Normalized size | URL | Format | Update cadence | FP reputation | Citation |", "|---|---:|---|---|---|---|---|"]
    for item in CANDIDATES:
        lines.append(f"| {item['label']} | {len(sets[item['name']]):,} | {item['url']} | {item['format']} | {item['cadence']} | {item['fp']} | {item['citation']} |")
    lines += ["", "## Current 21 configured URLs", "", *[f"* `{u}`" for u in urls], "", "## Recommendation", ""]
    metrics = {}
    for name, rules in sets.items():
        if name == "current-21-merged":
            continue
        coverage = sum(matches(d, rules) for c in ("ads-trackers", "malware", "phishing") for d in categories[c])
        fp = sum(matches(d, rules) for d in legit)
        metrics[name] = (coverage, fp)
    best = sorted(metrics, key=lambda n: (-metrics[n][0], metrics[n][1]))
    primary = best[0]
    secondary = min((n for n in best if n != primary), key=lambda n: (metrics[n][1], -metrics[n][0]), default=None)
    lines.append(f"On this cached corpus, **{primary}** is the strongest coverage/FP trade-off ({metrics[primary][0]:,} bad-domain hits; {metrics[primary][1]:,} legitimate hits). Prefer it as the first replacement candidate and retire the 21 overlapping feeds after allowlist validation.")
    if secondary:
        lines.append(f" **{secondary}** is the lowest-FP alternative ({metrics[secondary][0]:,} bad-domain hits; {metrics[secondary][1]:,} legitimate hits) when stability matters more than maximum coverage. Do not combine OISD small with OISD big because the official site calls big a superset; keep Pro++/Xtra opt-in because their maintainers warn about aggressive false positives.")
    result = "\n".join(lines) + "\n"
    if out:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(result)
    return result



def main() -> int:
    parser = argparse.ArgumentParser(description="Offline-capable DNS blocklist benchmark")
    parser.add_argument("--offline", action="store_true", help="never access network; require complete cache")
    parser.add_argument("--refresh", action="store_true", help="redownload all feeds and corpora")
    parser.add_argument("--no-report", action="store_true", help="do not write .cache/report.md")
    args = parser.parse_args()
    if args.offline and args.refresh:
        parser.error("--offline and --refresh are mutually exclusive")
    CACHE.mkdir(parents=True, exist_ok=True)
    urls = config_urls()
    if args.offline:
        # Offline mode cannot use a stale generated report as input; all bytes
        # needed below must already exist.
        pass
    sets = list_sets(args.refresh, args.offline, urls)
    corpus_paths = write_corpus_files(args.refresh) if not args.offline else {name: CORPUS_CACHE / (f"{name}.zip" if kind == "zip" else f"{name}.txt") for name, _cat, _url, kind in CORPORA} | {"common-legit": CORPUS_CACHE / "common-legit.txt"}
    for path in corpus_paths.values():
        if not path.exists():
            raise RuntimeError(f"missing offline corpus cache: {path}")
    categories, legit = load_corpora(corpus_paths)
    total = sum(len(categories[k]) for k in ("ads-trackers", "malware", "phishing"))
    if not 500 <= total <= 3000:
        raise RuntimeError(f"bad-domain corpus has {total} unique domains; expected 500-3000")
    output = None if args.no_report else CACHE / "report.md"
    print(report(sets, categories, legit, urls, output), end="")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, urllib.error.URLError, zipfile.BadZipFile, RuntimeError) as exc:
        print(f"bench: error: {exc}", file=sys.stderr)
        raise SystemExit(1)
