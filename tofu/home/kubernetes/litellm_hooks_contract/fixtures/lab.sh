#!/bin/sh
# In-container orchestrator: copy the real litellm_hooks.py onto PYTHONPATH
# (mounted as aether_hooks.py in the pod), start the fake backends and the
# LiteLLM proxy from fixtures/config.yaml, then run the assertions.
set -eu

FIX=/src/litellm_hooks_contract/fixtures
PY="$(command -v python3 || command -v python)"

mkdir -p /tmp/hooks
cp /src/litellm_hooks.py /tmp/hooks/aether_hooks.py

export PYTHONPATH=/tmp/hooks
export MOIRA_DECIDE_URL=http://127.0.0.1:9000/decide
export LITELLM_MASTER_KEY=sk-contract-test
export PYTHONUNBUFFERED=1

"$PY" "$FIX/fake_backends.py" &
FAKE_PID=$!
litellm --config "$FIX/config.yaml" --port 4000 >/tmp/litellm.log 2>&1 &
LLM_PID=$!
trap 'kill $FAKE_PID $LLM_PID 2>/dev/null || true' EXIT

if ! "$PY" - <<'EOF'
import time, urllib.request
for _ in range(120):
    try:
        urllib.request.urlopen("http://127.0.0.1:4000/health/liveliness", timeout=1)
        break
    except Exception:
        time.sleep(0.5)
else:
    raise SystemExit(1)
EOF
then
  echo "FAIL: LiteLLM proxy did not become ready; log:" >&2
  cat /tmp/litellm.log >&2
  exit 1
fi

"$PY" "$FIX/test_contract.py"
