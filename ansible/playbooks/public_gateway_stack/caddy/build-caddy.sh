#!/bin/bash
# Build custom Caddy binary with CrowdSec and Cloudflare plugins
# Run this locally before deploying: ./build-caddy.sh

set -e

CADDY_VERSION="${CADDY_VERSION:-latest}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Building Caddy with plugins..."
echo "Output directory: $SCRIPT_DIR"

docker run --rm \
  -v "${SCRIPT_DIR}:/output" \
  caddy:builder \
  xcaddy build "$CADDY_VERSION" \
    --with github.com/caddy-dns/cloudflare \
    --with github.com/WeidiDeng/caddy-cloudflare-ip \
    --with github.com/hslatman/caddy-crowdsec-bouncer/http \
    --with github.com/hslatman/caddy-crowdsec-bouncer/appsec \
    --output /output/aether-public-gateway-caddy

echo "Built: $SCRIPT_DIR/aether-public-gateway-caddy"
echo "Size: $(du -h "$SCRIPT_DIR/aether-public-gateway-caddy" | cut -f1)"

