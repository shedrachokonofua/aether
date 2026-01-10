#!/usr/bin/env bash
set -e
echo "Generating Wazuh certificates..."

# Create placeholder containers so DNS names resolve on the wazuh network
# These create DNS entries for wazuh.indexer, wazuh.manager, wazuh.dashboard
podman run -d --rm --name wazuh-indexer-placeholder --network=wazuh --hostname=wazuh.indexer alpine sleep 300 || true
podman run -d --rm --name wazuh-manager-placeholder --network=wazuh --hostname=wazuh.manager alpine sleep 300 || true  
podman run -d --rm --name wazuh-dashboard-placeholder --network=wazuh --hostname=wazuh.dashboard alpine sleep 300 || true

# Wait for DNS to propagate
sleep 2

# Run the official wazuh-certs-generator on wazuh network (DNS names resolve)
podman run --rm \
  --network=wazuh \
  -v /etc/wazuh-certs/certs.yml:/config/certs.yml:ro \
  -v /var/lib/wazuh-certs:/certificates \
  -e CERT_TOOL_VERSION=4.14 \
  docker.io/wazuh/wazuh-certs-generator:0.0.3

# Clean up placeholder containers
podman stop wazuh-indexer-placeholder wazuh-manager-placeholder wazuh-dashboard-placeholder 2>/dev/null || true

# Fix permissions - container UIDs need to read these
chmod 755 /var/lib/wazuh-certs
chmod 644 /var/lib/wazuh-certs/*.pem
chmod 600 /var/lib/wazuh-certs/*-key.pem /var/lib/wazuh-certs/*.key

echo "Certificates generated successfully"
ls -la /var/lib/wazuh-certs/

