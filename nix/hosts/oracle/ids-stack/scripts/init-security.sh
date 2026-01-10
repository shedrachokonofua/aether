#!/usr/bin/env bash
set -e
echo "Waiting for Wazuh Indexer to be ready..."

# Wait for indexer to be listening (up to 90 seconds)
for i in $(seq 1 90); do
  if podman exec wazuh-indexer curl -sk https://localhost:9200 >/dev/null 2>&1; then
    echo "Indexer is responding"
    break
  fi
  echo "Waiting... ($i/90)"
  sleep 1
done

# Give indexer a moment to fully initialize
sleep 5

# Wait for secrets to be available (vault-agent renders them)
echo "Waiting for secrets from OpenBao..."
for i in $(seq 1 60); do
  if [ -f /run/secrets/wazuh-indexer-password ] && [ -f /run/secrets/wazuh-dashboard-password ]; then
    echo "Secrets available"
    break
  fi
  echo "Waiting for secrets... ($i/60)"
  sleep 1
done

if [ ! -f /run/secrets/wazuh-indexer-password ]; then
  echo "WARNING: Secrets not available, using default passwords"
  ADMIN_PASS="admin"
  KIBANA_PASS="kibanaserver"
else
  ADMIN_PASS=$(cat /run/secrets/wazuh-indexer-password)
  KIBANA_PASS=$(cat /run/secrets/wazuh-dashboard-password)
fi

echo "Creating security config files with hashed passwords..."
# Generate hashes and create internal_users.yml entirely inside the container
# This avoids shell escaping issues with bcrypt's $ characters
podman exec -e OPENSEARCH_JAVA_HOME=/usr/share/wazuh-indexer/jdk \
  -e ADMIN_PASS="$ADMIN_PASS" \
  -e KIBANA_PASS="$KIBANA_PASS" \
  wazuh-indexer bash -c '
    HASH_TOOL=/usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh
    ADMIN_HASH=$($HASH_TOOL -p "$ADMIN_PASS" | tail -1)
    KIBANA_HASH=$($HASH_TOOL -p "$KIBANA_PASS" | tail -1)
    
    cat > /usr/share/wazuh-indexer/opensearch-security/internal_users.yml << EOFUSERS
_meta:
  type: "internalusers"
  config_version: 2

admin:
  hash: "$ADMIN_HASH"
  reserved: true
  backend_roles:
  - "admin"
  description: "Admin user"

kibanaserver:
  hash: "$KIBANA_HASH"
  reserved: true
  description: "Kibana server user"

kibanaro:
  hash: "\$2y\$12\$JJSXNfTowz7Uu5ttXfeYpeYE0arACvcwlPBStB1F.MI7f0U9Z4DGC"
  reserved: false
  backend_roles:
  - "kibanauser"
  - "readall"
  description: "Demo read-only user"
EOFUSERS
  '

# Create other missing security config files
podman exec wazuh-indexer bash -c 'cd /usr/share/wazuh-indexer/opensearch-security && cat > config.yml << "EOFCFG"
_meta:
  type: "config"
  config_version: 2
config:
  dynamic:
    authc:
      basic_internal_auth_domain:
        http_enabled: true
        transport_enabled: true
        order: 0
        http_authenticator:
          type: basic
          challenge: true
        authentication_backend:
          type: internal
EOFCFG
'
podman exec wazuh-indexer bash -c 'cd /usr/share/wazuh-indexer/opensearch-security && cat > tenants.yml << "EOFCFG"
_meta:
  type: "tenants"
  config_version: 2
EOFCFG
'
podman exec wazuh-indexer bash -c 'cd /usr/share/wazuh-indexer/opensearch-security && cat > nodes_dn.yml << "EOFCFG"
_meta:
  type: "nodesdn"
  config_version: 2
EOFCFG
'
podman exec wazuh-indexer bash -c 'cd /usr/share/wazuh-indexer/opensearch-security && cat > whitelist.yml << "EOFCFG"
_meta:
  type: "whitelist"
  config_version: 2
config:
  enabled: false
  requests: {}
EOFCFG
'
podman exec wazuh-indexer bash -c 'cd /usr/share/wazuh-indexer/opensearch-security && cat > allowlist.yml << "EOFCFG"
_meta:
  type: "allowlist"
  config_version: 2
config:
  enabled: false
  requests: {}
EOFCFG
'

echo "Running securityadmin..."
# Set OPENSEARCH_JAVA_HOME and provide 'which' shim (not present in minimal container)
podman exec -e OPENSEARCH_JAVA_HOME=/usr/share/wazuh-indexer/jdk wazuh-indexer \
  bash -c '
    which() { type -P "$1" 2>/dev/null; }
    export -f which
    export PATH=/usr/share/wazuh-indexer/jdk/bin:$PATH
    /usr/share/wazuh-indexer/plugins/opensearch-security/tools/securityadmin.sh \
      -cd /usr/share/wazuh-indexer/opensearch-security/ \
      -nhnv \
      -cacert /usr/share/wazuh-indexer/config/certs/root-ca.pem \
      -cert /usr/share/wazuh-indexer/config/certs/admin.pem \
      -key /usr/share/wazuh-indexer/config/certs/admin-key.pem \
      -p 9200 \
      -icl
  '

# Mark as initialized
touch /var/lib/wazuh-indexer/.security_initialized
echo "Security initialization complete"

