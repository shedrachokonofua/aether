#!/usr/bin/env bash
# technitium-apply.sh — idempotent reconciliation of a Technitium DNS Server
# (v14) against declarative JSON config, via the local HTTP API.
#
# Usage: technitium-apply.sh <base-config.json> <host-overlay.json>
#
# Env:
#   TECHNITIUM_URL  API base (default http://127.0.0.1:5380)
#   SECRETS_DIR     directory holding admin.pass / api.token (default
#                   /var/lib/technitium-apply). Created 0700 if missing.
#
# Auth flow: reuse api.token if valid; else login with admin.pass; else login
# with the factory default admin/admin, immediately rotate the password to a
# generated (or pre-seeded) admin.pass, then mint a non-expiring API token.
#
# Overlay JSON is deep-merged over the base (settings merged key-wise; cluster
# only ever comes from the overlay):
#   { "settings": {...}, "cluster": { "mode": "primary"|"secondary", ... } }
#
# Every API response is checked: {"status":"ok"} passes, anything else fails
# the run except explicitly tolerated already-exists conditions.
set -euo pipefail

BASE_CONFIG=${1:?base config json required}
HOST_OVERLAY=${2:?host overlay json required}
TECHNITIUM_URL=${TECHNITIUM_URL:-http://127.0.0.1:5380}
SECRETS_DIR=${SECRETS_DIR:-/var/lib/technitium-apply}

command -v curl >/dev/null || { echo "curl required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

mkdir -p "$SECRETS_DIR" && chmod 700 "$SECRETS_DIR"
PASS_FILE="$SECRETS_DIR/admin.pass"
TOKEN_FILE="$SECRETS_DIR/api.token"

MERGED=$(jq -s '.[0] * .[1]' "$BASE_CONFIG" "$HOST_OVERLAY")

api() { # api <path> [curl args...] — GET with token unless overridden
  local path=$1; shift
  curl -fsS --max-time 30 "$@" "$TECHNITIUM_URL$path"
}

check() { # check <json> <context> [tolerate-regex]
  local resp=$1 ctx=$2 tolerate=${3:-}
  local status; status=$(jq -r '.status // "error"' <<<"$resp")
  [ "$status" = "ok" ] && return 0
  local msg; msg=$(jq -r '.errorMessage // .response.errorMessage // "unknown"' <<<"$resp")
  if [ -n "$tolerate" ] && grep -qiE "$tolerate" <<<"$msg"; then
    echo "  ~ $ctx: tolerated ($msg)"
    return 0
  fi
  echo "FAIL $ctx: $msg" >&2
  return 1
}

# --- wait for the API -------------------------------------------------------
for i in $(seq 1 60); do
  curl -fsS --max-time 3 "$TECHNITIUM_URL/api/user/session/get?token=invalid" >/dev/null 2>&1 && break
  # any HTTP response at all means the web service is up; curl -f fails on 4xx
  curl -sS --max-time 3 -o /dev/null "$TECHNITIUM_URL/" 2>/dev/null && break
  sleep 2
  [ "$i" = 60 ] && { echo "API never came up" >&2; exit 1; }
done

# --- authenticate -----------------------------------------------------------
TOKEN=""
if [ -s "$TOKEN_FILE" ]; then
  TOKEN=$(cat "$TOKEN_FILE")
  if ! api "/api/settings/get?token=$TOKEN" | jq -e '.status == "ok"' >/dev/null 2>&1; then
    TOKEN=""
  fi
fi

login() { # login <pass> -> session token or empty
  api "/api/user/login" --data-urlencode "user=admin" --data-urlencode "pass=$1" -G \
    | jq -r 'select(.status == "ok") | .token // empty'
}

if [ -z "$TOKEN" ]; then
  SESSION=""
  if [ -s "$PASS_FILE" ]; then
    SESSION=$(login "$(cat "$PASS_FILE")") || true
  fi
  if [ -z "$SESSION" ]; then
    # factory default — rotate immediately
    SESSION=$(login "admin") || true
    if [ -n "$SESSION" ]; then
      if [ ! -s "$PASS_FILE" ]; then
        head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32 > "$PASS_FILE"
        chmod 600 "$PASS_FILE"
      fi
      RESP=$(api "/api/user/changePassword" -G \
        --data-urlencode "token=$SESSION" \
        --data-urlencode "pass=admin" \
        --data-urlencode "newPass=$(cat "$PASS_FILE")")
      check "$RESP" "rotate admin password"
      echo "  + admin password rotated"
    fi
  fi
  [ -n "$SESSION" ] || { echo "cannot authenticate: no valid token, admin.pass, or factory default" >&2; exit 1; }
  RESP=$(api "/api/user/createToken" -G \
    --data-urlencode "user=admin" \
    --data-urlencode "pass=$(cat "$PASS_FILE")" \
    --data-urlencode "tokenName=aether-apply")
  check "$RESP" "create API token"
  jq -r '.token' <<<"$RESP" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  TOKEN=$(cat "$TOKEN_FILE")
  echo "  + API token minted"
fi

# --- settings ----------------------------------------------------------------
# Arrays -> comma-joined strings, scalars passed through; each becomes one
# form field on /api/settings/set.
SETTINGS_ARGS=()
while IFS=$'\t' read -r key value; do
  SETTINGS_ARGS+=(--data-urlencode "$key=$value")
done < <(jq -r '.settings | to_entries[] |
  [.key, (if (.value | type) == "array" then (.value | join(",")) else (.value | tostring) end)] | @tsv' <<<"$MERGED")

RESP=$(api "/api/settings/set" -G --data-urlencode "token=$TOKEN" "${SETTINGS_ARGS[@]}")
check "$RESP" "settings/set"
echo "  + settings applied"

# --- allowed / blocked zones -------------------------------------------------
for domain in $(jq -r '.allowedZones[]? // empty' <<<"$MERGED"); do
  RESP=$(api "/api/allowed/add" -G --data-urlencode "token=$TOKEN" --data-urlencode "domain=$domain")
  check "$RESP" "allowed/add $domain" "exist"
done
for domain in $(jq -r '.blockedZones[]? // empty' <<<"$MERGED"); do
  RESP=$(api "/api/blocked/add" -G --data-urlencode "token=$TOKEN" --data-urlencode "domain=$domain")
  check "$RESP" "blocked/add $domain" "exist"
done
echo "  + allowed/blocked zones applied"

# --- zones + records ---------------------------------------------------------
jq -c '.zones[]? // empty' <<<"$MERGED" | while read -r zone; do
  ZNAME=$(jq -r '.zone' <<<"$zone")
  RESP=$(api "/api/zones/create" -G --data-urlencode "token=$TOKEN" \
    --data-urlencode "zone=$ZNAME" --data-urlencode "type=Primary")
  check "$RESP" "zones/create $ZNAME" "already exists"
  jq -c '.records[]? // empty' <<<"$zone" | while read -r rec; do
    RESP=$(api "/api/zones/records/add" -G \
      --data-urlencode "token=$TOKEN" \
      --data-urlencode "zone=$ZNAME" \
      --data-urlencode "domain=$(jq -r '.domain' <<<"$rec")" \
      --data-urlencode "type=$(jq -r '.type' <<<"$rec")" \
      --data-urlencode "ttl=$(jq -r '.ttl // 60' <<<"$rec")" \
      --data-urlencode "ipAddress=$(jq -r '.ipAddress' <<<"$rec")" \
      --data-urlencode "overwrite=true")
    check "$RESP" "records/add $(jq -r '.domain' <<<"$rec")" "already exists"
  done
done
echo "  + zones and records applied"

# --- apps ----------------------------------------------------------------------
INSTALLED=$(api "/api/apps/list?token=$TOKEN")
jq -c '.apps[]? // empty' <<<"$MERGED" | while read -r app; do
  ANAME=$(jq -r '.name' <<<"$app")
  AURL=$(jq -r '.url' <<<"$app")
  if ! jq -e --arg n "$ANAME" '.response.apps[]? | select(.name == $n)' <<<"$INSTALLED" >/dev/null; then
    RESP=$(api "/api/apps/downloadAndInstall" -G \
      --data-urlencode "token=$TOKEN" \
      --data-urlencode "name=$ANAME" \
      --data-urlencode "url=$AURL")
    check "$RESP" "apps/install $ANAME"
    echo "  + installed app $ANAME"
  fi
  ACONFIG=$(jq -c '.config' <<<"$app")
  if [ "$ACONFIG" != "null" ]; then
    RESP=$(api "/api/apps/config/set" \
      --data-urlencode "token=$TOKEN" \
      --data-urlencode "name=$ANAME" \
      --data-urlencode "config=$ACONFIG")
    check "$RESP" "apps/config $ANAME"
  fi
done
echo "  + apps applied"

# --- cluster -------------------------------------------------------------------
CLUSTER_MODE=$(jq -r '.cluster.mode // empty' <<<"$MERGED")
if [ -n "$CLUSTER_MODE" ]; then
  CSTATE=$(api "/api/admin/cluster/get?token=$TOKEN" 2>/dev/null || echo '{}')
  ALREADY=$(jq -r '.response.initialized // .response.cluster.initialized // false' <<<"$CSTATE" 2>/dev/null || echo false)
  IN_CLUSTER=false
  if jq -e '.response | objects | (has("nodes") or has("clusterDomain"))' <<<"$CSTATE" >/dev/null 2>&1; then
    IN_CLUSTER=true
  fi
  if [ "$IN_CLUSTER" = "true" ] || [ "$ALREADY" = "true" ]; then
    echo "  ~ cluster already initialized; skipping"
  elif [ "$CLUSTER_MODE" = "primary" ]; then
    RESP=$(api "/api/admin/cluster/init" -G \
      --data-urlencode "token=$TOKEN" \
      --data-urlencode "clusterDomain=$(jq -r '.cluster.domain' <<<"$MERGED")" \
      --data-urlencode "primaryNodeIpAddress=$(jq -r '.cluster.nodeIp' <<<"$MERGED")")
    check "$RESP" "cluster/init" "already"
    echo "  + cluster initialized (primary)"
  elif [ "$CLUSTER_MODE" = "secondary" ]; then
    PRIMARY_PASS=${TECHNITIUM_PRIMARY_PASSWORD:?TECHNITIUM_PRIMARY_PASSWORD required for cluster join}
    RESP=$(api "/api/admin/cluster/initJoin" -G \
      --data-urlencode "token=$TOKEN" \
      --data-urlencode "secondaryNodeIpAddress=$(jq -r '.cluster.nodeIp' <<<"$MERGED")" \
      --data-urlencode "primaryNodeUrl=$(jq -r '.cluster.primaryUrl' <<<"$MERGED")" \
      --data-urlencode "primaryNodeIpAddress=$(jq -r '.cluster.primaryIp' <<<"$MERGED")" \
      --data-urlencode "primaryNodeUsername=admin" \
      --data-urlencode "primaryNodePassword=$PRIMARY_PASS" \
      --data-urlencode "ignoreCertificateErrors=true")
    check "$RESP" "cluster/initJoin" "already"
    echo "  + cluster joined (secondary)"
  fi
fi

echo "technitium-apply: done"
