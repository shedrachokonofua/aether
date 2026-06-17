#!/usr/bin/env bash
# =============================================================================
# Google WIF subject-token provider for task login
# =============================================================================
# Called by Google ADC (external_account + executable credential source) when
# OpenTofu/gcloud need a fresh Keycloak ID token for STS exchange.
#
# Resolution order:
#   1. Valid cached ID token (~5m Keycloak lifetime)
#   2. Refresh token grant (from task login SSO session)
#   3. Error JSON telling the caller to run task login

set -euo pipefail

CACHE_DIR="${AETHER_CACHE_DIR:-$HOME/.aether-toolbox}"
KEYCLOAK_URL="${KEYCLOAK_URL:-https://auth.shdr.ch}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-aether}"
KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-toolbox}"

TOKEN_FILE="$CACHE_DIR/google/keycloak-id-token.jwt"
REFRESH_FILE="$CACHE_DIR/google/keycloak-refresh-token"
OUTPUT_FILE="$CACHE_DIR/google/wif-token-cache.json"

jwt_payload() {
  local token="$1"
  echo "$token" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null
}

jwt_exp() {
  local token="$1"
  jwt_payload "$token" | jq -r '.exp // empty' 2>/dev/null
}

emit_error() {
  local code="$1"
  local message="$2"
  jq -n \
    --arg code "$code" \
    --arg message "$message" \
    '{version: 1, success: false, code: $code, message: $message}'
}

emit_success() {
  local id_token="$1"
  local exp="$2"
  jq -n \
    --arg id_token "$id_token" \
    --argjson expiration_time "$exp" \
    '{
      version: 1,
      success: true,
      token_type: "urn:ietf:params:oauth:token-type:id_token",
      id_token: $id_token,
      expiration_time: $expiration_time
    }'
}

write_response() {
  local response="$1"
  printf '%s\n' "$response"
  printf '%s\n' "$response" >"$OUTPUT_FILE"
  chmod 600 "$OUTPUT_FILE"
}

read_cached_id_token() {
  [[ -f "$TOKEN_FILE" ]] || return 1

  local token exp now
  token=$(<"$TOKEN_FILE")
  exp=$(jwt_exp "$token")
  now=$(date +%s)

  if [[ -z "$exp" || "$exp" -le $((now + 60)) ]]; then
    return 1
  fi

  emit_success "$token" "$exp"
}

refresh_id_token() {
  [[ -f "$REFRESH_FILE" ]] || return 1

  local refresh_token response id_token exp new_refresh
  refresh_token=$(<"$REFRESH_FILE")

  response=$(curl -sS -X POST "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=refresh_token" \
    -d "client_id=${KEYCLOAK_CLIENT_ID}" \
    -d "refresh_token=${refresh_token}" 2>&1) || return 1

  if ! echo "$response" | jq -e '.id_token' &>/dev/null; then
    return 1
  fi

  id_token=$(echo "$response" | jq -r '.id_token')
  exp=$(jwt_exp "$id_token")
  new_refresh=$(echo "$response" | jq -r '.refresh_token // empty')

  printf '%s' "$id_token" >"$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"

  if [[ -n "$new_refresh" ]]; then
    printf '%s' "$new_refresh" >"$REFRESH_FILE"
    chmod 600 "$REFRESH_FILE"
  fi

  emit_success "$id_token" "$exp"
}

main() {
  local response

  if response=$(read_cached_id_token); then
    write_response "$response"
    return 0
  fi

  if response=$(refresh_id_token); then
    write_response "$response"
    return 0
  fi

  write_response "$(emit_error "401" "Keycloak credentials expired. Run: task login")"
  return 1
}

main "$@"
