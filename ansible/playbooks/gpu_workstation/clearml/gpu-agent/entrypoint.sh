#!/bin/sh
echo "Waiting for ClearML API server..."
until curl -sf http://127.0.0.1:8008/debug.ping > /dev/null 2>&1; do
  echo "API not ready, waiting 5s..."
  sleep 5
done
echo "ClearML API server ready!"

export CLEARML_DOCKER_SKIP_GPUS_FLAG=1
exec python3 -m clearml_agent --config-file /root/.clearml/clearml.conf daemon \
  --docker "${CLEARML_AGENT_DEFAULT_BASE_DOCKER}" \
  --force-current-version \
  --queue "${CLEARML_AGENT_QUEUES:-default}"

