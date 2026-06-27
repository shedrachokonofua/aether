---
name: gitlab
description: "GitLab REST API and git workflows on gitlab.home.shdr.ch — search projects, clone, branch, push, open/update MRs, check pipelines."
version: 1.0.0
author: aether
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [GitLab, Merge-Requests, Git, CI/CD, API]
    related_skills: []
    requires_toolsets: [terminal]
---

# GitLab (self-hosted)

Use GitLab REST API via `curl` and git over HTTPS. **Do not** use browser
automation for GitLab tasks.

Adapted from [vm0-ai/vm0-skills/gitlab](https://github.com/vm0-ai/vm0-skills)
for Hermes + `gitlab.home.shdr.ch`.

## Environment

Already injected by IaC (never print token values):

- `GITLAB_URL` — `https://gitlab.home.shdr.ch`
- `GITLAB_HOST` — `gitlab.home.shdr.ch`
- `GITLAB_TOKEN` — bot PAT (`read_api`, `read_repository`, `write_repository`)

API base: `"${GITLAB_URL}/api/v4"`

Auth header: `PRIVATE-TOKEN: ${GITLAB_TOKEN}`

Reload token in shell if missing:

```bash
if [ -z "${GITLAB_TOKEN:-}" ] && [ -f "${HERMES_HOME:-$HOME}/.env" ]; then
  GITLAB_TOKEN=$(grep '^GITLAB_TOKEN=' "${HERMES_HOME:-$HOME}/.env" | head -1 | cut -d= -f2- | tr -d '\n\r')
  export GITLAB_TOKEN
fi
export GITLAB_URL="${GITLAB_URL:-https://gitlab.home.shdr.ch}"
export GITLAB_HOST="${GITLAB_HOST:-gitlab.home.shdr.ch}"
```

### Helpers

```bash
urlencode() { python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

gitlab_json() {
  curl -fsS -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "$@"
}
```

When a command pipes curl to Python, wrap curl in `bash -c '...'` so env vars
survive the pipe.

## Verify auth

```bash
gitlab_json "${GITLAB_URL}/api/v4/user" \
  | python3 -c "import sys,json; u=json.load(sys.stdin); print(u['username'], u['id'])"
```

## Search and list projects

```bash
# By name (membership only)
curl -fsS -G -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  --data-urlencode "search=aether" \
  --data-urlencode "membership=true" \
  --data-urlencode "simple=true" \
  "${GITLAB_URL}/api/v4/projects" \
  | python3 -c "
import sys, json
for p in json.load(sys.stdin):
    print(f\"{p['id']:>6}  {p['path_with_namespace']}  ({p['default_branch']})\")"

# Project details by path (primary IaC repo: so/aether)
PROJECT_PATH="so/aether"
gitlab_json "${GITLAB_URL}/api/v4/projects/$(urlencode "$PROJECT_PATH")" \
  | python3 -c "import sys,json; p=json.load(sys.stdin); print(p['id'], p['web_url'], p['default_branch'])"
```

## Clone into workspace

Default clone root: `/workspace` (terminal cwd).

```bash
PROJECT_PATH="so/aether"
TARGET="/workspace/aether"
mkdir -p /workspace
git clone "https://oauth2:${GITLAB_TOKEN}@${GITLAB_HOST}/${PROJECT_PATH}.git" "$TARGET"
cd "$TARGET"
git fetch origin
```

Set remote if already cloned without token:

```bash
git remote set-url origin "https://oauth2:${GITLAB_TOKEN}@${GITLAB_HOST}/so/aether.git"
```

## Branch, commit, push

- Default base branch: `main` unless Shdrch says otherwise.
- Never push directly to `main` or `master`.
- Branch names: `feat/…`, `fix/…`, `docs/…`, `ci/…`.

```bash
cd /workspace/aether
git fetch origin
git checkout main && git pull origin main
git checkout -b feat/short-description
# edit files with write_file / patch
git add -A
git commit -m "feat: short description"
git push -u origin HEAD
export BRANCH=$(git branch --show-current)
PROJECT_PATH=$(git remote get-url origin | sed -E "s|.*${GITLAB_HOST}[:/]||; s|\\.git$||")
PROJECT_ID=$(gitlab_json "${GITLAB_URL}/api/v4/projects/$(urlencode "$PROJECT_PATH")" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
```

## List merge requests

```bash
PROJECT_PATH="so/aether"
curl -fsS -G -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  --data-urlencode "state=opened" \
  "${GITLAB_URL}/api/v4/projects/$(urlencode "$PROJECT_PATH")/merge_requests" \
  | python3 -c "
import sys, json
for mr in json.load(sys.stdin):
    print(f\"!{mr['iid']}  {mr['title']}  {mr['source_branch']} -> {mr['target_branch']}  {mr['web_url']}\")"
```

## Create merge request

After push:

```bash
curl -fsS -X POST -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  -H "Content-Type: application/json" \
  "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/merge_requests" \
  -d "$(python3 - <<PY
import json, os
print(json.dumps({
  "source_branch": os.environ["BRANCH"],
  "target_branch": "main",
  "title": "feat: short description",
  "description": "## Summary\\n- change\\n\\n## Test plan\\n- [ ] task tofu:plan",
  "remove_source_branch": True,
}))
PY
)" | python3 -c "import sys,json; mr=json.load(sys.stdin); print(mr['web_url'])"
```

Reply to Shdrch with the MR URL. Reuse the same branch/MR for follow-up commits.

## Update merge request

```bash
MR_IID=42
curl -fsS -X PUT -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  -H "Content-Type: application/json" \
  "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/merge_requests/${MR_IID}" \
  -d '{"title":"feat: updated title","description":"## Summary\\nUpdated"}'
```

## Check pipelines

```bash
MR_IID=42
gitlab_json "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/merge_requests/${MR_IID}/pipelines" \
  | python3 -c "
import sys, json
for p in json.load(sys.stdin):
    print(p['id'], p['status'], p.get('web_url',''))"
```

## Safety

- **Do not merge or approve MRs** unless Shdrch explicitly asks.
- **Do not delete** projects, branches, issues, or CI variables via API without confirmation.
- **Do not force-push** shared branches without confirmation.
- Prefer `GET`/`POST` MR create over destructive API calls.
