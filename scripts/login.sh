#!/bin/bash
# =============================================================================
# Aether Unified Login
# =============================================================================
# Single authentication flow using Keycloak device authorization grant.
# One browser popup to auth.shdr.ch, then automatic token exchange for:
#   - SSH certificate (step-ca OIDC provisioner)
#   - OpenBao (JWT auth backend)
#   - AWS (STS AssumeRoleWithWebIdentity)
#   - Google Cloud (Workload Identity Federation)
#   - Ceph RGW (STS AssumeRoleWithWebIdentity)
#
# Usage:
#   ./scripts/login.sh           # Full login (SSH + Bao + AWS + S3)
#   ./scripts/login.sh --ssh     # SSH certificate only
#   ./scripts/login.sh --bao     # OpenBao only
#   ./scripts/login.sh --aws     # AWS only
#   ./scripts/login.sh --google  # Google Cloud only
#   ./scripts/login.sh --s3      # Ceph S3 only
#   ./scripts/login.sh --no-ssh  # Skip SSH even if agent available
#   ./scripts/login.sh --status  # Check current auth status
#
# Environment:
#   AETHER_CACHE_DIR   - Where to store tokens (default: ~/.aether-toolbox)
#   AETHER_AWS_ROLE    - AWS role ARN to assume (default: auto-detect admin role)
#   AETHER_AWS_REGION  - AWS region (default: us-east-1)
#   AETHER_GOOGLE_WIF_AUDIENCE    - Google WIF audience (default: tf output)
#   AETHER_GOOGLE_SERVICE_ACCOUNT - Google service account email (default: tf output)
#   AETHER_GOOGLE_PROJECT         - Google project ID (default: tf output)
#   SSH_AUTH_SOCK      - SSH agent socket (auto-detected for SSH cert exchange)
#
# S3 Usage (after login):
#   rclone lsd ceph_rgw:                   # List Ceph RGW buckets
#   rclone ls ceph_rgw:bucket-name         # List files in bucket
#   rclone lsd aws:                    # List AWS S3 buckets
#   rclone copy file.txt ceph_rgw:bucket/  # Upload to Ceph RGW

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

KEYCLOAK_URL="https://auth.shdr.ch"
KEYCLOAK_REALM="aether"
KEYCLOAK_CLIENT_ID="toolbox"
OPENBAO_URL="https://bao.home.shdr.ch"
STEP_CA_URL="https://ca.shdr.ch"
CEPH_RGW_URL="https://s3.home.shdr.ch"
CEPH_RGW_ROLE="arn:aws:iam:::role/admin"
CACHE_DIR="${AETHER_CACHE_DIR:-$HOME/.aether-toolbox}"
AWS_REGION="${AETHER_AWS_REGION:-us-east-1}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# Helper Functions
# =============================================================================

log_info() { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1" >&2; }

ensure_deps() {
  local missing=()
  for cmd in curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required tools: ${missing[*]}"
    exit 1
  fi
}

ensure_cache_dir() {
  mkdir -p "$CACHE_DIR/bao"
  chmod 700 "$CACHE_DIR"
}

# =============================================================================
# Device Authorization Flow
# =============================================================================

# Start device authorization - returns device_code, user_code, verification_uri
device_auth_start() {
  local response
  response=$(curl -sS -X POST "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/auth/device" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "client_id=${KEYCLOAK_CLIENT_ID}" \
    -d "scope=openid profile email roles")

  if echo "$response" | jq -e '.error' &>/dev/null; then
    log_error "Device auth failed: $(echo "$response" | jq -r '.error_description // .error')"
    exit 1
  fi

  echo "$response"
}

# Poll for token - blocks until user completes auth or timeout
device_auth_poll() {
  local device_code="$1"
  local interval="${2:-5}"
  local expires_in="${3:-600}"

  local deadline=$(($(date +%s) + expires_in))

  while true; do
    if [[ $(date +%s) -gt $deadline ]]; then
      log_error "Device authorization timed out"
      exit 1
    fi

    local response
    response=$(curl -sS -X POST "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "client_id=${KEYCLOAK_CLIENT_ID}" \
      -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
      -d "device_code=${device_code}" 2>&1) || true

    if echo "$response" | jq -e '.access_token' &>/dev/null; then
      echo "$response"
      return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.error // empty')

    case "$error" in
      authorization_pending)
        sleep "$interval"
        ;;
      slow_down)
        interval=$((interval + 5))
        sleep "$interval"
        ;;
      expired_token)
        log_error "Device code expired. Please try again."
        exit 1
        ;;
      access_denied)
        log_error "Access denied by user."
        exit 1
        ;;
      *)
        log_error "Token exchange failed: $(echo "$response" | jq -r '.error_description // .error // "unknown error"')"
        exit 1
        ;;
    esac
  done
}

# =============================================================================
# Token Exchange Functions
# =============================================================================

decode_jwt() {
  local token="$1"
  echo "$token" | cut -d'.' -f2 | base64 -d 2>/dev/null | jq . 2>/dev/null || echo "(decode failed)"
}

exchange_for_aws() {
  local id_token="$1"
  local role_arn="${2:-}"

  # Debug: show token claims
  if [[ "${AETHER_DEBUG:-}" == "1" ]]; then
    log_info "ID Token claims:"
    decode_jwt "$id_token"
  fi

  log_info "Exchanging token for AWS credentials..."

  # Auto-detect role ARN if not provided
  if [[ -z "$role_arn" ]]; then
    # Try admin role first (most common for CLI users)
    role_arn="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "ACCOUNT"):role/aether-admin"

    # If we can't get account ID, we need to try assuming with the token
    # The role ARN is output by tofu, so we'll use a known pattern
    if [[ "$role_arn" == *"ACCOUNT"* ]]; then
      # Fall back to trying the known role pattern - AWS will tell us the account
      role_arn=""
    fi
  fi

  # Try to get credentials from tf-outputs if available
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local outputs_file="$script_dir/../secrets/tf-outputs.json"
  if [[ -z "$role_arn" ]] && [[ -f "$outputs_file" ]]; then
    role_arn=$(jq -r '.aws_admin_role_arn.value // empty' "$outputs_file" 2>/dev/null || true)
  fi

  # Last resort: hardcoded pattern (user may need to set AETHER_AWS_ROLE)
  if [[ -z "$role_arn" ]]; then
    role_arn="${AETHER_AWS_ROLE:-}"
    if [[ -z "$role_arn" ]]; then
      log_warn "Could not auto-detect AWS role ARN."
      log_warn "Set AETHER_AWS_ROLE environment variable or run 'task tofu:write-outputs' first."
      return 1
    fi
  fi

  if [[ "${AETHER_DEBUG:-}" == "1" ]]; then
    log_info "Using role ARN: $role_arn"
  fi

  local response
  response=$(aws sts assume-role-with-web-identity \
    --role-arn "$role_arn" \
    --role-session-name "aether-toolbox-$(date +%s)" \
    --web-identity-token "$id_token" \
    --duration-seconds 43200 \
    --region "$AWS_REGION" \
    2>&1) || {
      log_error "AWS token exchange failed: $response"
      return 1
    }

  # Extract credentials
  local access_key secret_key session_token expiration
  access_key=$(echo "$response" | jq -r '.Credentials.AccessKeyId')
  secret_key=$(echo "$response" | jq -r '.Credentials.SecretAccessKey')
  session_token=$(echo "$response" | jq -r '.Credentials.SessionToken')
  expiration=$(echo "$response" | jq -r '.Credentials.Expiration')

  # Write credentials to env file (plain KEY=VALUE for Docker --env-file compatibility)
  cat > "$CACHE_DIR/aws-env" <<EOF
AWS_ACCESS_KEY_ID=${access_key}
AWS_SECRET_ACCESS_KEY=${secret_key}
AWS_SESSION_TOKEN=${session_token}
AWS_REGION=${AWS_REGION}
AWS_DEFAULT_REGION=${AWS_REGION}
EOF
  chmod 600 "$CACHE_DIR/aws-env"

  # Also write to standard AWS credentials file for tools that prefer it
  # (may fail on NixOS if ~/.aws is managed differently - that's fine, aws-env works)
  {
    mkdir -p "$HOME/.aws" &&
    cat > "$HOME/.aws/credentials" <<EOF
[default]
aws_access_key_id = ${access_key}
aws_secret_access_key = ${secret_key}
aws_session_token = ${session_token}
EOF
    chmod 600 "$HOME/.aws/credentials"
  } 2>/dev/null || true

  log_success "AWS credentials cached (expires: $expiration)"
  return 0
}

exchange_for_google() {
  local id_token="$1"
  local required="${2:-false}"

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local outputs_file="$script_dir/../secrets/tf-outputs.json"

  local audience="${AETHER_GOOGLE_WIF_AUDIENCE:-}"
  local service_account="${AETHER_GOOGLE_SERVICE_ACCOUNT:-}"
  local project_id="${AETHER_GOOGLE_PROJECT:-}"

  if [[ -f "$outputs_file" ]]; then
    if [[ -z "$audience" ]]; then
      audience=$(jq -r '.google_workload_identity_provider_audience.value // empty' "$outputs_file" 2>/dev/null || true)
    fi
    if [[ -z "$service_account" ]]; then
      service_account=$(jq -r '.google_tofu_service_account_email.value // empty' "$outputs_file" 2>/dev/null || true)
    fi
    if [[ -z "$project_id" ]]; then
      project_id=$(jq -r '.google_project_id.value // empty' "$outputs_file" 2>/dev/null || true)
    fi
  fi

  if [[ -z "$audience" || -z "$service_account" ]]; then
    local msg="Google WIF is not configured yet"
    if [[ "$required" == "true" ]]; then
      log_error "$msg. Set google.project_id, bootstrap/apply the google module, then run task tofu:write-outputs."
      return 1
    fi
    log_info "$msg; skipping Google credentials"
    return 0
  fi

  log_info "Writing Google Workload Identity Federation credentials..."

  local google_dir="$CACHE_DIR/google"
  mkdir -p "$google_dir"
  chmod 700 "$google_dir"

  local token_file="$google_dir/keycloak-id-token.jwt"
  local credentials_file="$google_dir/application-default-credentials.json"
  local impersonation_url="https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${service_account}:generateAccessToken"

  printf '%s' "$id_token" > "$token_file"
  chmod 600 "$token_file"

  jq -n \
    --arg audience "$audience" \
    --arg token_file "$token_file" \
    --arg impersonation_url "$impersonation_url" \
    '{
      type: "external_account",
      audience: $audience,
      subject_token_type: "urn:ietf:params:oauth:token-type:jwt",
      token_url: "https://sts.googleapis.com/v1/token",
      service_account_impersonation_url: $impersonation_url,
      credential_source: {
        file: $token_file
      }
    }' > "$credentials_file"
  chmod 600 "$credentials_file"

  cat > "$CACHE_DIR/google-env" <<EOF
GOOGLE_APPLICATION_CREDENTIALS=${credentials_file}
CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE=${credentials_file}
GOOGLE_CLOUD_PROJECT=${project_id}
GOOGLE_PROJECT=${project_id}
EOF
  chmod 600 "$CACHE_DIR/google-env"

  log_success "Google WIF credentials configured (service account: $service_account)"
  return 0
}

exchange_for_s3() {
  local id_token="$1"

  log_info "Exchanging token for Ceph S3 credentials..."

  local response
  response=$(aws --no-sign-request sts assume-role-with-web-identity \
    --endpoint-url "$CEPH_RGW_URL" \
    --role-arn "$CEPH_RGW_ROLE" \
    --role-session-name "aether-toolbox-$(date +%s)" \
    --web-identity-token "$id_token" \
    2>&1) || {
      log_error "Ceph S3 token exchange failed: $response"
      return 1
    }

  local access_key secret_key session_token expiration
  access_key=$(echo "$response" | jq -r '.Credentials.AccessKeyId')
  secret_key=$(echo "$response" | jq -r '.Credentials.SecretAccessKey')
  session_token=$(echo "$response" | jq -r '.Credentials.SessionToken')
  expiration=$(echo "$response" | jq -r '.Credentials.Expiration')

  # Write S3 credentials to env file
  cat > "$CACHE_DIR/s3-env" <<EOF
S3_ACCESS_KEY_ID=${access_key}
S3_SECRET_ACCESS_KEY=${secret_key}
S3_SESSION_TOKEN=${session_token}
S3_ENDPOINT=${CEPH_RGW_URL}
EOF
  chmod 600 "$CACHE_DIR/s3-env"

  # Configure rclone for Ceph RGW (named 'ceph')
  mkdir -p "$HOME/.config/rclone"
  local rclone_config="$HOME/.config/rclone/rclone.conf"

  # Remove existing ceph_rgw section if present
  if [[ -f "$rclone_config" ]]; then
    sed -i '/^\[ceph\]$/,/^\[/{ /^\[ceph\]$/d; /^\[/!d; }' "$rclone_config" 2>/dev/null || true
  fi

  # Add ceph_rgw remote for Ceph RGW
  cat >> "$rclone_config" <<EOF
[ceph_rgw]
type = s3
provider = Ceph
endpoint = ${CEPH_RGW_URL}
access_key_id = ${access_key}
secret_access_key = ${secret_key}
session_token = ${session_token}
EOF
  chmod 600 "$rclone_config"

  # Also configure 'aws' remote if AWS credentials exist
  if [[ -f "$CACHE_DIR/aws-env" ]]; then
    source "$CACHE_DIR/aws-env"
    # Remove existing aws section if present
    sed -i '/^\[aws\]$/,/^\[/{ /^\[aws\]$/d; /^\[/!d; }' "$rclone_config" 2>/dev/null || true
    cat >> "$rclone_config" <<EOF
[aws]
type = s3
provider = AWS
region = ${AWS_REGION}
access_key_id = ${AWS_ACCESS_KEY_ID}
secret_access_key = ${AWS_SECRET_ACCESS_KEY}
session_token = ${AWS_SESSION_TOKEN}
EOF
  fi

  log_success "Ceph S3 credentials cached (expires: $expiration)"
  log_info "  Use: rclone lsd ceph_rgw:"
  return 0
}

exchange_for_bao() {
  local access_token="$1"

  log_info "Exchanging token for OpenBao credentials..."

  # Try admin role first, fall back to cli role
  local role="cli-admin"
  local response
  response=$(curl -sS -X POST "${OPENBAO_URL}/v1/auth/jwt/login" \
    -H "Content-Type: application/json" \
    -d "{\"jwt\": \"${access_token}\", \"role\": \"${role}\"}" 2>&1) || true

  # Check if admin role worked
  if ! echo "$response" | jq -e '.auth.client_token' &>/dev/null; then
    # Fall back to regular cli role
    role="cli"
    response=$(curl -sS -X POST "${OPENBAO_URL}/v1/auth/jwt/login" \
      -H "Content-Type: application/json" \
      -d "{\"jwt\": \"${access_token}\", \"role\": \"${role}\"}" 2>&1) || true
  fi

  if ! echo "$response" | jq -e '.auth.client_token' &>/dev/null; then
    local error
    error=$(echo "$response" | jq -r '.errors[0] // "unknown error"')
    log_error "OpenBao token exchange failed: $error"
    return 1
  fi

  local token lease_duration policies
  token=$(echo "$response" | jq -r '.auth.client_token')
  lease_duration=$(echo "$response" | jq -r '.auth.lease_duration')
  policies=$(echo "$response" | jq -r '.auth.policies | join(", ")')

  # Write token to cache
  echo "$token" > "$CACHE_DIR/bao/token"
  chmod 600 "$CACHE_DIR/bao/token"

  local expires_at
  expires_at=$(date -d "+${lease_duration} seconds" 2>/dev/null || date -v "+${lease_duration}S" 2>/dev/null || echo "unknown")

  log_success "OpenBao token cached (policies: ${policies}, expires: ~${lease_duration}s)"
  return 0
}

exchange_for_ssh_cert() {
  local id_token="$1"

  # Check if SSH agent is available
  if [[ ! -S "${SSH_AUTH_SOCK:-}" ]]; then
    log_warn "SSH agent not available, skipping SSH certificate"
    log_info "  Use 'task ca:login' on host, or pass SSH_AUTH_SOCK to container"
    return 1
  fi

  # Check if step CLI is available
  if ! command -v step &>/dev/null; then
    log_warn "step CLI not available, skipping SSH certificate"
    return 1
  fi

  log_info "Exchanging token for SSH certificate..."

  # Bootstrap step-ca trust if needed (silent)
  if [[ ! -f "${STEPPATH:-$HOME/.step}/config/defaults.json" ]]; then
    local fingerprint
    fingerprint=$(curl -sk "${STEP_CA_URL}/roots.pem" | step certificate fingerprint - 2>/dev/null) || true
    if [[ -n "$fingerprint" ]]; then
      step ca bootstrap --ca-url="$STEP_CA_URL" --fingerprint="$fingerprint" --force &>/dev/null || true
    fi
  fi

  # Exchange ID token for SSH certificate
  # Use 'toolbox' provisioner which accepts tokens from the toolbox client (azp=toolbox)
  # ID token (not access token) because it contains required identity claims like 'sub'
  local output
  output=$(step ssh login \
    --provisioner=toolbox \
    --token="$id_token" \
    --ca-url="$STEP_CA_URL" \
    2>&1) || {
      log_error "SSH certificate exchange failed: $output"
      return 1
    }

  log_success "SSH certificate added to agent"
  return 0
}

# =============================================================================
# Status Check
# =============================================================================

check_status() {
  echo -e "\n${BLUE}=== Aether Auth Status ===${NC}\n"

  # Check step-ca SSH cert (most used day-to-day)
  echo -e "${BLUE}SSH:${NC}"
  if [[ -S "${SSH_AUTH_SOCK:-}" ]]; then
    # Check for certificates using step if available, fallback to ssh-add
    if command -v step &>/dev/null; then
      local cert_raw
      cert_raw=$(step ssh list --raw 2>/dev/null | grep -v '^ssh-' | head -1 || true)
      if [[ -n "$cert_raw" ]]; then
        local cert_details
        cert_details=$(echo "$cert_raw" | step ssh inspect 2>/dev/null || true)
        local valid_to principals
        valid_to=$(echo "$cert_details" | grep -oP 'Valid:.*to \K[0-9TZ:-]+' 2>/dev/null || true)
        principals=$(echo "$cert_details" | grep -oP 'Principals:\s*\K.*' 2>/dev/null | head -1 || true)
        if [[ -n "$valid_to" ]]; then
          log_success "Certificate loaded (principals: ${principals:-unknown}, expires: $valid_to)"
        else
          log_success "Certificate loaded"
        fi
      else
        log_warn "No certificate in agent (use 'task login' or 'task ca:login')"
      fi
    else
      # Fallback: check for cert-authority entries in ssh-add
      if ssh-add -L 2>/dev/null | grep -q 'cert-authority\|ssh-.*-cert'; then
        log_success "Certificate loaded (run 'step ssh list' for details)"
      else
        log_warn "No certificate in agent (use 'task login' or 'task ca:login')"
      fi
    fi
  else
    log_info "Agent not available in container (check on host with 'ssh-add -l')"
  fi

  # Check OpenBao
  echo -e "\n${BLUE}OpenBao:${NC}"
  if [[ -f "$CACHE_DIR/bao/token" ]]; then
    local token
    token=$(cat "$CACHE_DIR/bao/token")
    local lookup
    lookup=$(curl -sS -H "X-Vault-Token: $token" "${OPENBAO_URL}/v1/auth/token/lookup-self" 2>&1) || true

    if echo "$lookup" | jq -e '.data' &>/dev/null; then
      local display_name ttl policies
      display_name=$(echo "$lookup" | jq -r '.data.display_name')
      ttl=$(echo "$lookup" | jq -r '.data.ttl')
      policies=$(echo "$lookup" | jq -r '.data.policies | join(", ")')
      log_success "Authenticated as: $display_name (TTL: ${ttl}s, policies: $policies)"
    else
      log_warn "Token expired or invalid"
    fi
  else
    log_warn "Not authenticated (no cached token)"
  fi

  # Check AWS
  echo -e "\n${BLUE}AWS:${NC}"
  if [[ -f "$CACHE_DIR/aws-env" ]]; then
    set -a  # Auto-export variables
    source "$CACHE_DIR/aws-env"
    set +a
    if aws sts get-caller-identity --no-cli-pager &>/dev/null; then
      local identity
      identity=$(aws sts get-caller-identity --no-cli-pager 2>/dev/null)
      local arn account
      arn=$(echo "$identity" | jq -r '.Arn')
      account=$(echo "$identity" | jq -r '.Account')
      log_success "Authenticated as: $arn (account: $account)"
    else
      log_warn "Credentials expired or invalid"
    fi
  else
    log_warn "Not authenticated (no cached credentials)"
  fi

  # Check Google Cloud
  echo -e "\n${BLUE}Google Cloud:${NC}"
  if [[ -f "$CACHE_DIR/google-env" ]]; then
    local google_creds google_project
    google_creds=$(grep '^GOOGLE_APPLICATION_CREDENTIALS=' "$CACHE_DIR/google-env" | cut -d= -f2- || true)
    google_project=$(grep '^GOOGLE_CLOUD_PROJECT=' "$CACHE_DIR/google-env" | cut -d= -f2- || true)
    if [[ -n "$google_creds" && -f "$google_creds" ]]; then
      log_success "WIF credentials configured (project: ${google_project:-unknown})"
    else
      log_warn "Cached Google env exists but credential file is missing"
    fi
  else
    log_warn "Not authenticated (no cached WIF credentials)"
  fi

  # Check Ceph S3
  echo -e "\n${BLUE}Ceph S3:${NC}"
  if [[ -f "$CACHE_DIR/s3-env" ]]; then
    source "$CACHE_DIR/s3-env"
    # Try a simple list operation to verify credentials work
    if command -v rclone &>/dev/null && rclone lsd ceph_rgw: &>/dev/null; then
      log_success "Authenticated (endpoint: $S3_ENDPOINT)"
      log_info "  Use: rclone lsd ceph_rgw:"
    else
      log_warn "Credentials cached but may be expired"
    fi
  else
    log_warn "Not authenticated (no cached credentials)"
  fi

  echo ""
}

# =============================================================================
# Main Login Flow
# =============================================================================

do_login() {
  local do_aws=true
  local do_google=true
  local google_required=false
  local do_bao=true
  local do_s3=true
  local do_ssh=auto  # auto = try if SSH agent available

  # Parse args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --aws)
        do_google=false
        do_bao=false
        do_s3=false
        do_ssh=false
        shift
        ;;
      --google)
        do_aws=false
        do_google=true
        google_required=true
        do_bao=false
        do_s3=false
        do_ssh=false
        shift
        ;;
      --bao)
        do_aws=false
        do_google=false
        do_s3=false
        do_ssh=false
        shift
        ;;
      --s3)
        do_aws=false
        do_google=false
        do_bao=false
        do_ssh=false
        shift
        ;;
      --ssh)
        do_aws=false
        do_google=false
        do_bao=false
        do_s3=false
        do_ssh=true
        shift
        ;;
      --no-ssh)
        do_ssh=false
        shift
        ;;
      --status)
        check_status
        exit 0
        ;;
      --help|-h)
        echo "Usage: $0 [--aws|--google|--bao|--s3|--ssh|--no-ssh|--status]"
        echo ""
        echo "Options:"
        echo "  --aws     Only get AWS credentials"
        echo "  --google  Only configure Google Cloud WIF credentials"
        echo "  --bao     Only get OpenBao token"
        echo "  --s3      Only get Ceph S3 credentials"
        echo "  --ssh     Only get SSH certificate"
        echo "  --no-ssh  Skip SSH certificate (even if agent available)"
        echo "  --status  Check current auth status"
        echo ""
        echo "S3 Usage (after login):"
        echo "  rclone lsd ceph_rgw:        List Ceph RGW buckets"
        echo "  rclone lsd aws:         List AWS S3 buckets"
        echo "  rclone copy f.txt ceph_rgw:b/ Upload to Ceph"
        echo ""
        echo "Environment:"
        echo "  AETHER_CACHE_DIR   Token cache directory (default: ~/.aether-toolbox)"
        echo "  AETHER_AWS_ROLE    AWS role ARN to assume"
        echo "  AETHER_AWS_REGION  AWS region (default: us-east-1)"
        echo "  AETHER_GOOGLE_WIF_AUDIENCE       Google WIF audience"
        echo "  AETHER_GOOGLE_SERVICE_ACCOUNT    Google service account email"
        echo "  AETHER_GOOGLE_PROJECT            Google project ID"
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        exit 1
        ;;
    esac
  done

  ensure_deps
  ensure_cache_dir

  # Start device authorization
  log_info "Starting device authorization..."
  local device_response
  device_response=$(device_auth_start)

  local device_code user_code verification_uri interval expires_in
  device_code=$(echo "$device_response" | jq -r '.device_code')
  user_code=$(echo "$device_response" | jq -r '.user_code')
  verification_uri=$(echo "$device_response" | jq -r '.verification_uri_complete // .verification_uri')
  interval=$(echo "$device_response" | jq -r '.interval // 5')
  expires_in=$(echo "$device_response" | jq -r '.expires_in // 600')

  echo ""
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${YELLOW}  Open this URL in your browser:${NC}"
  echo ""
  echo -e "  ${GREEN}${verification_uri}${NC}"
  echo ""
  echo -e "  ${YELLOW}Code: ${GREEN}${user_code}${NC}"
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  # Try to open browser automatically
  if command -v xdg-open &>/dev/null; then
    xdg-open "$verification_uri" 2>/dev/null &
  elif command -v open &>/dev/null; then
    open "$verification_uri" 2>/dev/null &
  fi

  log_info "Waiting for browser authentication..."

  # Poll for tokens
  local token_response
  token_response=$(device_auth_poll "$device_code" "$interval" "$expires_in")

  local access_token id_token
  access_token=$(echo "$token_response" | jq -r '.access_token')
  id_token=$(echo "$token_response" | jq -r '.id_token')

  log_success "Authentication successful!"
  echo ""

  # Exchange tokens (ordered by importance: SSH → Bao → AWS → Google → S3)
  local ssh_ok=true
  local ssh_skipped=false
  local bao_ok=true
  local aws_ok=true
  local google_ok=true
  local s3_ok=true

  # SSH: auto-detect or explicit (most used day-to-day)
  # Uses ID token (contains sub claim required by OIDC provisioner)
  if [[ "$do_ssh" == "auto" ]]; then
    if [[ -S "${SSH_AUTH_SOCK:-}" ]]; then
      exchange_for_ssh_cert "$id_token" || ssh_ok=false
    else
      ssh_skipped=true
    fi
  elif [[ "$do_ssh" == "true" ]]; then
    exchange_for_ssh_cert "$id_token" || ssh_ok=false
  else
    ssh_skipped=true
  fi

  if $do_bao; then
    exchange_for_bao "$access_token" || bao_ok=false
  fi

  if $do_aws; then
    exchange_for_aws "$id_token" || aws_ok=false
  fi

  if $do_google; then
    exchange_for_google "$id_token" "$google_required" || google_ok=false
  fi

  if $do_s3; then
    exchange_for_s3 "$id_token" || s3_ok=false
  fi

  # Summary (same order)
  echo ""
  echo -e "${BLUE}=== Login Summary ===${NC}"
  if ! $ssh_skipped; then
    if $ssh_ok; then
      log_success "SSH: Certificate added to agent"
    else
      log_error "SSH: Failed"
    fi
  elif [[ "$do_ssh" == "auto" ]]; then
    log_info "SSH: Skipped (no agent, use --ssh to require)"
  fi
  if $do_bao; then
    if $bao_ok; then
      log_success "Bao: Ready (token in $CACHE_DIR/bao/token)"
    else
      log_error "Bao: Failed"
    fi
  fi
  if $do_aws; then
    if $aws_ok; then
      log_success "AWS: Ready (creds in $CACHE_DIR/aws-env)"
    else
      log_error "AWS: Failed"
    fi
  fi
  if $do_google; then
    if $google_ok; then
      if [[ -f "$CACHE_DIR/google-env" ]]; then
        log_success "Google: Ready (WIF config in $CACHE_DIR/google-env)"
      else
        log_info "Google: Not configured"
      fi
    else
      log_error "Google: Failed"
    fi
  fi
  if $do_s3; then
    if $s3_ok; then
      log_success "Ceph RGW:  Ready (rclone remotes: ceph_rgw, aws)"
    else
      log_error "Ceph RGW:  Failed"
    fi
  fi
  echo ""

  # Only fail on explicit requests, not auto-detected SSH
  if ! $bao_ok || ! $aws_ok || ! $google_ok || ! $s3_ok; then
    exit 1
  fi
  if [[ "$do_ssh" == "true" ]] && ! $ssh_ok; then
    exit 1
  fi
}

# Run main
do_login "$@"
