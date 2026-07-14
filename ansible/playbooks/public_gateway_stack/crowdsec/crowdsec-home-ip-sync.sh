#!/usr/bin/env bash
set -euo pipefail

readonly allowlist_name="aether-home"
readonly state_file="/var/lib/crowdsec/aether-home-ip"

if (( EUID != 0 )); then
  exec sudo -n "$0" "${SSH_ORIGINAL_COMMAND:-}"
fi

request="${1:-}"
verb=""
current_ip=""
extra=""
read -r verb current_ip extra <<<"$request"

if [[ "$verb" != "sync" || -z "$current_ip" || -n "$extra" || "$request" != "sync $current_ip" ]]; then
  echo "expected: sync <IPv4 address>" >&2
  exit 64
fi

octets=()
IFS=. read -r -a octets <<<"$current_ip"
if [[ ${#octets[@]} -ne 4 ]]; then
  echo "invalid IPv4 address" >&2
  exit 65
fi
for octet in "${octets[@]}"; do
  if [[ ! "$octet" =~ ^[0-9]{1,3}$ ]] || (( 10#$octet > 255 )); then
    echo "invalid IPv4 address" >&2
    exit 65
  fi
done

if ! cscli allowlists inspect "$allowlist_name" >/dev/null 2>&1; then
  cscli allowlists create "$allowlist_name" --description "Trusted home WAN egress managed by Kestra"
fi

previous_ip=""
if [[ -f "$state_file" ]]; then
  previous_ip="$(<"$state_file")"
fi

if ! cscli allowlists check "$current_ip" | grep -q "is allowlisted"; then
  cscli allowlists add "$allowlist_name" "$current_ip" --comment "Home WAN egress managed by Kestra"
fi

if [[ -n "$previous_ip" && "$previous_ip" != "$current_ip" ]]; then
  cscli allowlists remove "$allowlist_name" "$previous_ip"
fi

state_tmp="$(mktemp "${state_file}.XXXXXX")"
printf '%s\n' "$current_ip" >"$state_tmp"
chmod 0600 "$state_tmp"
mv -f "$state_tmp" "$state_file"

if [[ "$previous_ip" == "$current_ip" ]]; then
  printf 'unchanged %s\n' "$current_ip"
else
  printf 'updated %s -> %s\n' "${previous_ip:-none}" "$current_ip"
fi
