#!/usr/bin/env bash
# Contract test for litellm_hooks.py (deployment_adapter, moira_router).
#
# Runs the REAL litellm_hooks.py inside the LiteLLM image pinned in
# ../litellm.tf (same literal, so a version bump re-runs this against the new
# image) with fake backends and a fake Moira, and asserts per-attempt request
# adaptation. Exit 0 = contract holds; non-zero = any assertion failed.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
kdir="$(dirname "$here")"

image="$(sed -n 's/^[[:space:]]*litellm_image[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$kdir/litellm.tf")"
[ -n "$image" ] || { echo "FAIL: litellm_image pin not found in $kdir/litellm.tf" >&2; exit 1; }
echo "pinned image (read from litellm.tf): $image"

started_colima=no
if ! docker info >/dev/null 2>&1; then
  echo "starting colima..."
  colima start
  started_colima=yes
fi

status=0
docker run --rm --entrypoint sh -v "$kdir:/src:ro" "$image" \
  -c "sh /src/litellm_hooks_contract/fixtures/lab.sh" || status=$?

if [ "$started_colima" = yes ]; then
  colima stop
fi
exit $status
