# Crossplane → tofu-native S3 migration (2026-07)

Executor plan. Written to be executed mechanically, phase by phase, by a
low-context agent. Every phase ends with a **Gate** — verification with an
expected result. If a gate fails and no remediation branch is given: **STOP,
report the exact command + output, do not improvise.**

## Background (read, don't re-derive)

- Crossplane upjet AWS providers (`provider-aws-s3` + `provider-aws-iam`) in
  the seven30 vcluster AND the aether host cluster hammer Ceph RGW via
  `s3.home.shdr.ch` at ~126 req/s idle. Root cause: Bucket resources never
  converge against RGW, so they hot-loop on the error path; `--poll=1h` alone
  does not fix this.
- Decision: move bucket/role provisioning to plain OpenTofu using the AWS
  provider pointed at RGW, authenticated keyless via STS. Crossplane stays for
  Keycloak only.
- Already proven by spike (2026-07-07): an STS-assumed non-root role under the
  seven30 RGW account can perform all IAM writes (CreateRole, PutRolePolicy,
  DeleteRole). `sts get-caller-identity` is NOT supported by RGW —
  `skip_requesting_account_id = true` is mandatory in the provider block.
- seven30 RGW account id: `RGW54357707893720224`.

## Global rules

- Repos: aether = `~/projects/aether`, seven30 infra = `~/projects/seven30/infra`.
- ALL commands run inside the dev shell: `nix develop --command bash -c '<cmd>'`
  from the repo root. Tools do not exist on the bare host.
- **No merge requests.** Commit directly to `main` and push.
- **seven30 applies go through CI**, never locally — every seven30 repo
  (infra and projects) already has a GitLab pipeline for its IaC. The CI
  templates run `tofu plan -out=plan.cache` and the manual `apply` job
  applies that cache — so TARGETING MUST BE BAKED INTO THE PLAN: create the
  pipeline explicitly with `TF_CLI_ARGS_plan` carrying the `-target` flags
  (pipeline variables become job env vars; tofu appends `TF_CLI_ARGS_plan`
  to `plan`). Never play the apply job of the auto-created push pipeline —
  its plan is untargeted. Full sequence (run from the repo in question so
  `:id` resolves to that project):

  ```bash
  glab auth status    # must be logged in to gitlab.home.shdr.ch; else STOP, ask user to run task login
  # 1. targeted pipeline (repeat -target=... inside the value as needed)
  PIPELINE=$(glab api -X POST projects/:id/pipeline \
    -f ref=main \
    -f 'variables[][key]=TF_CLI_ARGS_plan' \
    -f 'variables[][value]=-target=<addr1> -target=<addr2>' | jq -r .id)
  # sanity: variables must be attached; if empty, STOP and report
  glab api "projects/:id/pipelines/$PIPELINE/variables" | jq .
  # 2. wait for the plan job to succeed
  glab api "projects/:id/pipelines/$PIPELINE/jobs" \
    | jq -r '.[] | "\(.id)\t\(.name)\t\(.status)"'
  # 3. codex reviews the plan diff BEFORE apply — use the plan.txt ARTIFACT
  # (exact render of plan.cache, which is what apply executes), never the
  # job trace. TF_ROOT is `tofu` in the shared ci-templates; if the project
  # overrides TF_ROOT, adjust the artifact path accordingly.
  PLAN_JOB=$(glab api "projects/:id/pipelines/$PIPELINE/jobs" | jq -r '.[] | select(.name=="plan") | .id')
  glab api "projects/:id/jobs/$PLAN_JOB/artifacts/tofu/plan.txt" > /tmp/ci-plan.txt
  codex exec "Review this OpenTofu plan output. Expected scope: ONLY <the resources this phase says it touches>. Flag any resource outside that scope, any destroy not called for by the phase, and any secret value echoed in the diff. End with verdict: CLEAN or FINDINGS." < /tmp/ci-plan.txt
  # FINDINGS or out-of-scope changes -> STOP, do not play apply, report.
  # 4. only on CLEAN: play THIS pipeline's apply job
  JOB=$(glab api "projects/:id/pipelines/$PIPELINE/jobs" | jq -r '.[] | select(.name=="apply") | .id')
  glab api -X POST "projects/:id/jobs/$JOB/play" >/dev/null
  glab api "projects/:id/jobs/$JOB" | jq -r .status   # poll until success/failed
  # on failed: glab api "projects/:id/jobs/$JOB/trace", then STOP and report
  ```

- **aether tofu applies are local and targeted, with codex reviewing the
  plan before apply.** Never a bare `task tofu:apply`. Pattern (the repo
  already uses `task tofu:apply -- -target=...` elsewhere, e.g.
  `tofu:apply:gitlab-runner`):

  ```bash
  task tofu:plan -- -target=<addr1> -target=<addr2> -out=/tmp/phase.plan
  # render the SAVED plan (the exact bytes apply will execute), review that:
  tofu -chdir=tofu show -no-color /tmp/phase.plan > /tmp/phase-plan.txt
  codex exec "Review this OpenTofu plan output. Expected scope: ONLY <the resources this phase says it touches>. Flag anything out of scope, any uncalled-for destroy, any secret echoed. End with verdict: CLEAN or FINDINGS." < /tmp/phase-plan.txt
  # FINDINGS -> STOP and report. CLEAN -> apply the reviewed plan file verbatim:
  task tofu:apply -- /tmp/phase.plan
  ```

  Applying the saved plan file guarantees exactly the reviewed diff is what
  executes.
- **Spike exception**: Phase 3's throwaway spike (`tofu-spike-rgw/`, local
  state, resources named `spike-*` only, deleted at the end of the phase) is
  the ONLY permitted local apply/destroy touching seven30 — it is not part
  of any real stack or pipeline. Nothing else is exempt.
- **Review every commit with codex before committing — staged diff only.**
  In the repo being committed, after staging exactly the files you intend
  to commit, run:

  ```bash
  git diff --staged --no-ext-diff | codex exec "Review this staged diff before commit. Flag bugs, broken YAML/HCL, leaked secrets, and contradictions with the crossplane->tofu S3 migration runbook. End with verdict: CLEAN or FINDINGS."
  ```

  This reviews only what will actually be committed. Do NOT use
  `codex review --uncommitted` as the commit gate — in a dirty repo it
  sweeps unrelated unstaged/untracked files. (Also, codex-cli 0.142.5
  rejects combining `--uncommitted`/`--commit` with a custom prompt;
  `codex exec "<prompt>"` with piped stdin is the supported shape.)

  (codex comes from the host node install, not flake.nix; it resolves inside
  the dev shell — verified codex-cli 0.142.5.) Fix anything it flags as a
  bug or a leaked secret before committing; if a finding is unclear or would
  change the plan's design, STOP and report instead of improvising. Style
  nits may be ignored.
- Never print secret values. Extract into shell vars, use, unset. If a command
  would echo a secret, redirect to /dev/null.
- Auth: run `task login:status` first in each repo. If SSH/AWS/Bao entries are
  expired, run `task login` (interactive — if that is impossible for you,
  STOP and ask the user to run it).
- Ansible from aether repo root:
  `export SSH_AUTH_SOCK=$HOME/.aether-toolbox/ssh/agent.sock ANSIBLE_CONFIG=ansible/ansible.cfg`
  then `ansible-playbook -i ansible/inventory/hosts.yml <playbook>`.
- kubectl in aether must show context `admin@aether-k8s`
  (`kubectl config current-context`). kubectl for the seven30 vcluster: run
  `task login` inside `~/projects/seven30/infra`, then plain `kubectl` there.
- Do not run formatters, linters, or unrelated test suites.

---

## Phase 0 — interim throttle (seven30/infra) [do first, 10 min]

Caps the flood while the migration lands.

1. Edit `~/projects/seven30/infra/tofu/crossplane.tf`. Find the
   `DeploymentRuntimeConfig` named `aws-slow-poll` (~line 151). Change:

   ```hcl
   args = ["--poll=1h"]
   ```

   to:

   ```hcl
   args = ["--poll=1h", "--max-reconcile-rate=1"]
   ```

2. Commit to main (`fix(crossplane): cap aws provider reconcile rate at 1/s`),
   push, then trigger the CI apply job (see Global rules).

3. **Gate**: within ~10 minutes RGW request rate must drop well below 126 req/s.
   From aether repo root:

   ```bash
   TOKEN=$(nix develop --command bash -c 'sops -d secrets/secrets.yml | yq -r .grafana_sa_token' | tail -1)
   curl -s -H "Authorization: Bearer $TOKEN" \
     'https://grafana.home.shdr.ch/api/datasources/proxy/uid/PBFA97CFB590B2093/api/v1/query?query=sum(rate(ceph_rgw_req%5B10m%5D))'
   ```

   Expected: value < 60 (was ~126). If unchanged after 15 min, check the
   provider pods restarted: `kubectl -n vc-seven30 get pods | grep provider-aws`
   (in the seven30 repo context) — pods should be < 15 min old. If they did not
   restart, report and stop.

---

## Phase 1 — unstick kestra-storage-s3 [15 min]

The Role MR `kestra-storage-s3` has been failing deletion since ≥ Jun 30. The
delete was already intended; complete it on both ends.

**RESOLVED 2026-07-09.** The stuck delete (`deletionTimestamp` set 2026-04-28,
`AsyncDeleteFailure` hot-loop) was because the RGW-side role still existed. Fix:
deleted the RGW role via CLI (`iam delete-role`; it had no inline policies) — the
provider's next reconcile then succeeded, released `finalizer.managedresource.crossplane.io`,
and GC'd the MR itself (no manual finalizer patch needed). Verified: RGW
`NoSuchEntity`, MR `NotFound`, provider `kestra-storage-s3` errors → 0.

1. In `~/projects/seven30/infra` (after `task login`):

   ```bash
   kubectl get roles.iam.aws.upbound.io kestra-storage-s3 -o jsonpath='{.metadata.deletionTimestamp}'
   ```

   Expect a timestamp (confirms delete was requested). Then remove finalizers:

   ```bash
   kubectl patch roles.iam.aws.upbound.io kestra-storage-s3 --type=merge -p '{"metadata":{"finalizers":null}}'
   ```

2. Delete the RGW-side role. From aether repo root, inside
   `nix develop --command bash`:

   ```bash
   export AWS_ACCESS_KEY_ID=$(sops -d secrets/secrets.yml | yq -r .ceph.seven30_account_access_key)
   export AWS_SECRET_ACCESS_KEY=$(sops -d secrets/secrets.yml | yq -r .ceph.seven30_account_secret_key)
   export AWS_DEFAULT_REGION=us-east-1
   EP=https://s3.home.shdr.ch
   for p in $(aws --endpoint-url $EP iam list-role-policies --role-name kestra-storage-s3 --query 'PolicyNames[]' --output text); do
     aws --endpoint-url $EP iam delete-role-policy --role-name kestra-storage-s3 --policy-name "$p"
   done
   aws --endpoint-url $EP iam delete-role --role-name kestra-storage-s3
   unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
   ```

3. **Gate**: `kubectl get roles.iam.aws.upbound.io kestra-storage-s3` in the
   vcluster returns NotFound, and
   `aws --endpoint-url $EP iam get-role --role-name kestra-storage-s3` (with
   creds re-exported) returns NoSuchEntity. Also check provider logs quieted:
   the `Async delete callback failed` lines for kestra-storage-s3 stop
   appearing (`kubectl -n vc-seven30 logs deploy-or-pod of provider-aws-iam
   --since=10m | grep -c kestra` → 0).

---

## Phase 2 — seven30-provisioner role in aether [30 min]

Adds the keyless CI provisioner role. Belongs in
`ansible/playbooks/configure_ceph_rgw_accounts.yml` (RGW account bootstrap is
its job).

1. Read the existing `aether-admin` role section of that playbook (search for
   `aether-admin`; it is a 4-task pattern: check-exists → create-role →
   update-assume-role-policy → put-role-policy, around lines 660-720).
   Replicate that exact task pattern for a new role with these parameters,
   using the **seven30** account creds
   (`secrets.ceph.seven30_account_access_key` /
   `secrets.ceph.seven30_account_secret_key`) exactly as the existing seven30
   tasks in the same file do:

   - Role name: `seven30-provisioner`
   - Trust policy (define as a playbook var next to the existing trust-policy
     vars, following their style):

     ```json
     {
       "Version": "2012-10-17",
       "Statement": [{
         "Effect": "Allow",
         "Principal": {"Federated": "arn:aws:iam::RGW54357707893720224:oidc-provider/gitlab.home.shdr.ch"},
         "Action": "sts:AssumeRoleWithWebIdentity",
         "Condition": {
           "StringEquals": {"gitlab.home.shdr.ch:aud": "https://gitlab.home.shdr.ch"},
           "StringLike":   {"gitlab.home.shdr.ch:sub": "project_path:seven30/*"}
         }
       }]
     }
     ```

     If the playbook already holds the seven30 account id in a variable/fact,
     use that variable instead of the hardcoded id — but only if it is used
     the same way in an existing seven30 ARN in this file.

   - Inline permissions policy, name `provisioner`:

     ```json
     {
       "Version": "2012-10-17",
       "Statement": [
         {"Effect": "Allow", "Action": ["s3:*", "iam:*"], "Resource": "*"}
       ]
     }
     ```

2. Run the playbook (idempotent; all its tasks are check-then-create):

   ```bash
   ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/configure_ceph_rgw_accounts.yml
   ```

3. **Gate**: with seven30 account creds (as in Phase 1 step 2):
   `aws --endpoint-url https://s3.home.shdr.ch iam get-role --role-name seven30-provisioner`
   returns the role with the GitLab federated trust. Re-run the playbook once
   more: it must report zero changes for the new tasks (idempotency).

4. Commit + push aether (`feat(rgw): add seven30-provisioner role for keyless tofu CI`).

---

## Phase 3 — terraform-provider spike against RGW [45 min]

Validates the terraform AWS provider's refresh loop against RGW. This is the
last unknown. Throwaway — local state, deleted afterward.

1. Create `~/projects/seven30/infra/tofu-spike-rgw/main.tf` (NOT inside
   `tofu/` — it must not touch the real state):

   ```hcl
   terraform {
     required_providers {
       aws = { source = "hashicorp/aws", version = "~> 5.0" }
     }
   }

   provider "aws" {
     region                      = "us-east-1"
     s3_use_path_style           = true
     skip_credentials_validation = true
     skip_requesting_account_id  = true
     skip_region_validation      = true
     skip_metadata_api_check     = true
     endpoints {
       s3  = "https://s3.home.shdr.ch"
       iam = "https://s3.home.shdr.ch"
       sts = "https://s3.home.shdr.ch"
     }
   }

   resource "aws_s3_bucket" "spike" {
     bucket        = "spike-tofu-test"
     force_destroy = true
   }

   resource "aws_iam_role" "spike" {
     name = "spike-tofu-role"
     # NO tags argument — RGW does not support TagRole
     assume_role_policy = jsonencode({
       Version = "2012-10-17"
       Statement = [{
         Effect    = "Allow"
         Principal = { Federated = "arn:aws:iam::RGW54357707893720224:oidc-provider/gitlab.home.shdr.ch" }
         Action    = "sts:AssumeRoleWithWebIdentity"
         Condition = {
           StringEquals = { "gitlab.home.shdr.ch:aud" = "https://gitlab.home.shdr.ch" }
         }
       }]
     })
   }

   resource "aws_iam_role_policy" "spike" {
     name = "s3-scoped"
     role = aws_iam_role.spike.name
     policy = jsonencode({
       Version = "2012-10-17"
       Statement = [{
         Effect   = "Allow"
         Action   = "s3:*"
         Resource = ["arn:aws:s3:::spike-tofu-test", "arn:aws:s3:::spike-tofu-test/*"]
       }]
     })
   }
   ```

2. Get 1h creds by assuming `seven30-provisioner` (this also validates its
   policy). From aether repo root inside `nix develop --command bash`:

   ```bash
   export AWS_ACCESS_KEY_ID=$(sops -d secrets/secrets.yml | yq -r .ceph.seven30_account_access_key)
   export AWS_SECRET_ACCESS_KEY=$(sops -d secrets/secrets.yml | yq -r .ceph.seven30_account_secret_key)
   export AWS_DEFAULT_REGION=us-east-1
   CREDS=$(aws --endpoint-url https://s3.home.shdr.ch sts assume-role \
     --role-arn arn:aws:iam::RGW54357707893720224:role/seven30-provisioner \
     --role-session-name tofu-spike --output json)
   export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .Credentials.AccessKeyId)
   export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .Credentials.SecretAccessKey)
   export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .Credentials.SessionToken)
   ```

   NOTE: root creds are overwritten by the assumed creds — everything after
   this point runs as the provisioner role, which is the point.

3. In `tofu-spike-rgw/` (same shell, seven30 repo has `tofu` in its dev shell —
   run from `~/projects/seven30/infra` via `nix develop`). This local
   apply/destroy is the sanctioned Spike exception in Global rules — local
   state, `spike-*` resources only, never the real stack:

   ```bash
   tofu init
   tofu apply -auto-approve      # expect: 3 created
   tofu plan -detailed-exitcode  # THE test
   ```

4. **Gate** (three-way branch):
   - `plan` exit code 0 ("No changes") → PASS. Continue.
   - Exit code 2 (diff shown): record the exact diff. If the diff is only
     attribute-level churn on the same resources (phantom drift), add a
     `lifecycle { ignore_changes = [<those attributes>] }` block to the
     affected resource, re-run apply + plan. If clean now → PASS with note:
     these ignore_changes must be carried into Phase 4 resources.
   - Hard error (exit 1) on **plan or apply** → FAIL. Record output. Fallback
     decision is pre-made: migrate ONLY buckets to tofu and KEEP
     `provider-aws-iam` in Crossplane (it converges fine; measured ~2% of the
     flood). Report which call failed and stop this phase.
   - **Known exception (validated 2026-07-09, job 12970):** a hard error on
     `destroy` of `aws_iam_role` specifically — RGW returns `405` on
     `ListInstanceProfilesForRole` — is NOT a FAIL. Create/refresh/import all
     work; only provider-driven role *deletion* breaks. Proceed, and handle
     role removal per the Phase 4 role-destroy caveat. Any *other* destroy
     error IS a FAIL.

5. Cleanup: `tofu destroy -auto-approve` destroys the bucket, bucket_policy,
   and role_policy cleanly, then errors on the `aws_iam_role` destroy with the
   RGW `405` above (expected — role_policy destroys first in dependency order,
   so it is already gone). Remove the now-policy-less role via CLI, then drop
   the spike dir and creds:

   ```bash
   aws iam delete-role --role-name spike-tofu-role --endpoint-url https://s3.home.shdr.ch
   rm -rf tofu-spike-rgw/
   unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
   ```

   Verify no residue: `aws iam list-roles --endpoint-url https://s3.home.shdr.ch`
   (root creds re-exported) must NOT contain `spike-tofu-role`;
   `aws s3api head-bucket --bucket spike-tofu-test --endpoint-url https://s3.home.shdr.ch`
   must 404.

---

## Phase 4 — migrate seven30 project resources [half day]

Only start after Phase 3 gate = PASS.

**Phase 4 result (2026-07-11): all three seven30 app repos migrated tofu-native.**
Method per repo: `kubectl patch` the live MRs to `deletionPolicy: Orphan` -> `import {}`
blocks adopt the RGW objects into tofu state -> delete the `kubectl_manifest` wrappers
in the same apply. CI assumes `seven30-provisioner` via the shared `.rgw-assume-role`
(ci-templates.yml) + a `GITLAB_OIDC_TOKEN` id_token on the plan/apply jobs. Buckets +
roles guarded with `prevent_destroy`.

- **crucible** — `seven30-crucible-interviews` (+CORS) + 2 roles + 2 policies. Hardened
  after cutover: `force_destroy=false`, versioning enabled, `prevent_destroy`.
- **demo** (pipeline 3415) — `seven30-demo-uploads` + 2 roles + 2 policies. 5 imported,
  5 wrappers destroyed. Bucket data intact (57.4 KiB).
- **scout** (pipeline 3419) — `scout-raw-data` + `scout` + 2 roles + 2 policies. 6
  imported, 6 wrappers destroyed. Applied with `TF_CLI_ARGS_plan=-target=...` (12
  targets) to **exclude** 3 unrelated pending scout-dev drifts (grafana dashboard,
  kestra flow, scout ConfigMap) that had accumulated on main — those stay for scout's
  own next apply. Data intact (scout-raw-data 660 obj/290.5 MiB, scout 134.7 MiB).

**Platform IAM + provider teardown (2026-07-11):** the seven30-account trust
anchors + base roles — `kestra-base` (+assume policy), `seven30-s3-admin`,
`seven30-s3-readonly`, and the `keycloak-seven30` (auth.shdr.ch/realms/seven30)
+ `k8s-seven30` OIDC providers — migrated to `infra/tofu/rgw_iam.tf` the same way
(orphan -> import -> delete wrappers, staged: migrate first, tear down second).
OIDC de-risk first: RGW **does** support `iam:GetOpenIDConnectProvider` /
`ListOpenIDConnectProviders`, so `aws_iam_openid_connect_provider` imports
cleanly (thumbprints hardcoded to RGW's stored case exactly — keycloak
lowercase, k8s uppercase — for a no-op import). Gotcha: an import-block `id`
**cannot be sensitive**, so the OIDC ARN uses a literal account, not
`${local.rgw_account_id}` (vault-sourced). Stage 2 then removed
`provider-aws-s3`/`-iam`, ProviderConfig `ceph-rgw`, the RGW-creds ESO, and the
slow-poll DeploymentRuntimeConfig from `crossplane.tf`; the auto-installed
`upbound-provider-family-aws` (no dependents, never in tofu) was removed live
with `kubectl delete provider.pkg.crossplane.io`. Result: **zero provider-aws in
the vcluster** (only `provider-keycloak` remains), zero `*.aws.upbound.io` CRDs,
and the idle ~37 req/s upjet-observe RGW traffic is gone. All 6 buckets / 10
roles / 4 OIDC providers verified intact; trust anchors unchanged (thumbprints +
client lists confirmed via `iam get-*`). CI gotcha: `glab -f "variables[][key]"`
can't set the pipeline `variables[]` array — for `TF_CLI_ARGS_plan` targeting,
set a **project** CI var (removed after) since infra's `changes`-gated builds run
on api-source pipelines but stay manual on push.

Data safety: before each cutover, buckets were snapshotted **server-side** (RGW->RGW
`aws s3 sync`, no bytes through the operator box) to `*-premig-bak` buckets
(`scout-raw-data-premig-bak`, `scout-premig-bak`, `seven30-demo-uploads-premig-bak`).
Delete these once the migrations are trusted.

Caveat (recurring): after each apply the Role MRs stick in `Terminating` — the
Crossplane finalizer won't clear because provider-aws hits `ReconcileError` doing a
final observe (RGW IAM `405` quirk), even though `Orphan` shouldn't touch the external
role. Cleared by `kubectl patch ... -p '{"metadata":{"finalizers":[]}}'` (Orphan means
the RGW role survives; verified all roles still present via `iam get-role`).

Gotcha: `glab api -f "variables[][key]=..."` and `--input` both silently drop the
`variables[]` array on pipeline-create — use `curl` with a JSON body + the glab token to
pass `TF_CLI_ARGS_plan`.

**Phase 3 result (2026-07-09, job 12970):** the keyless OIDC → CLI env-cred path creates all four resource types (bucket, bucket_policy, iam_role, iam_role_policy) against RGW, and the refresh plan is idempotent — **zero phantom drift**. The migration premise is validated end-to-end in CI. One caveat carried into step c below: role *destroy*.

1. Discover every Crossplane S3/IAM CRD declaration in seven30 repos:

   ```bash
   grep -rln 's3.aws.upbound.io\|iam.aws.upbound.io' ~/projects/seven30/*/tofu/ 2>/dev/null
   ```

   Also list live MRs in the vcluster (from infra repo, after `task login`):

   ```bash
   for r in buckets.s3.aws.upbound.io bucketpolicies.s3.aws.upbound.io \
            bucketwebsiteconfigurations.s3.aws.upbound.io bucketpublicaccessblocks.s3.aws.upbound.io \
            roles.iam.aws.upbound.io rolepolicies.iam.aws.upbound.io; do
     echo "== $r"; kubectl get $r -o name 2>/dev/null
   done
   ```

   **Discovered scope (local checkouts, 2026-07-09)** — grep of the CRD groups
   above across `~/projects/seven30/*/tofu/`. Re-verify against live MRs after
   `task login`; a repo may declare more than it has applied.

   | Repo | Buckets | Roles (each + RolePolicy) | Notes |
   |---|---|---|---|
   | `crucible` | `seven30-crucible-interviews` | `kestra-crucible-s3`, `seven30-crucible-s3` | also a **`BucketCorsConfiguration`** → `aws_s3_bucket_cors_configuration` (NOT covered by the Phase 3 smoke test — import + `tofu plan` this type carefully) |
   | `demo` | `seven30-demo-uploads` | `kestra-demo-s3`, `seven30-demo-s3` | — |
   | `scout` | `scout-raw-data`, `scout` | `seven30-scout-s3`, `kestra-scout-s3` | `~/projects/seven30/scout-latest/` is a **duplicate checkout of the same `seven30/scout.git`** (identical `storage.tf`) — migrate `scout` once; ignore `scout-latest`. |

   Platform-level IAM lives in `infra/tofu` and is outside the per-project loop
   above — handled in Phase 4 step 3, but **not as a blind teardown**:
   - Roles `seven30-s3-readonly`, `seven30-s3-admin` (`crossplane.tf`) and
     `kestra-base` (`kestra.tf`) — migrate/orphan like the project roles.
   - The `OpenIDConnectProvider`s `keycloak-seven30` (`auth.shdr.ch/realms/seven30`)
     and `k8s-seven30` (`k8s.seven30.xyz`) in `crossplane.tf` are **live RGW
     trust anchors** — for the *runtime* roles, not this migration's CI path:
     `seven30-s3-readonly`/`seven30-s3-admin` federate the Keycloak one
     (seven30-cli S3 access) and `kestra-base` federates the k8s one (Kestra
     pod IRSA). The migration's own `seven30-provisioner` trusts the separate
     `gitlab.home.shdr.ch` provider (Ansible playbook) — unaffected. Removing
     provider-aws without first importing these to tofu
     (`aws_iam_openid_connect_provider`) — or orphaning + documenting them —
     **breaks S3 CLI auth and Kestra role-chaining**. This type is **not**
     covered by the Phase 3 smoke test (same as CORS): import and `tofu plan`
     it explicitly before any teardown.
   - The `infra/tofu/roles.tf` `Role`s are `role.keycloak.crossplane.io`
     (Keycloak, not AWS) — leave them.

2. For EACH repo found, in this exact order:

   a. Set every S3/IAM MR to Orphan **first** (so nothing deletes real
      buckets later). Either edit the `kubectl_manifest` yaml_body to add
      `spec.deletionPolicy: Orphan` and apply, or patch live + in code:

      ```bash
      kubectl patch <kind>.<group> <name> --type=merge -p '{"spec":{"deletionPolicy":"Orphan"}}'
      ```

      Gate: `kubectl get <kind> <name> -o jsonpath='{.spec.deletionPolicy}'`
      → `Orphan` for every MR.

   b. Add a plain env-cred AWS provider (same flags/endpoints as the Phase 3
      spike, NO `assume_role_with_web_identity` block). **Proven finding
      (local `tofu validate`, 2026-07-08):** terraform-provider-aws does client-side ARN
      validation and REJECTS RGW's non-12-digit account id
      (`RGW54357707893720224`) in an `assume_role_with_web_identity`
      block. The AWS CLI is lax on ARN format, so acquire creds via the CLI
      first, export them, then run tofu with the plain provider:

      ```hcl
      provider "aws" {
        region                      = "us-east-1"
        s3_use_path_style           = true
        skip_credentials_validation = true
        skip_requesting_account_id  = true
        skip_region_validation      = true
        skip_metadata_api_check     = true
        endpoints {
          s3  = "https://s3.home.shdr.ch"
          iam = "https://s3.home.shdr.ch"
          sts = "https://s3.home.shdr.ch"
        }
      }
      ```

      and in `.gitlab-ci.yml` for the tofu jobs (CLI assume-role → env creds
      → tofu; see the `validate-rgw-tofu` job in seven30/infra for the
      working reference):

      ```yaml
      variables:
        AWS_DEFAULT_REGION: us-east-1    # iam CLI needs a region; s3 infers from endpoint (job 12979)
      id_tokens:
        GITLAB_OIDC_TOKEN:
          aud: https://gitlab.home.shdr.ch
      before_script:
        - apk add --no-cache -q aws-cli    # opentofu image is alpine
        - |
          CREDS=$(aws sts assume-role-with-web-identity \
            --role-arn "arn:aws:iam::RGW54357707893720224:role/seven30-provisioner" \
            --role-session-name "tofu-${CI_PIPELINE_ID}" \
            --web-identity-token "$GITLAB_OIDC_TOKEN" \
            --endpoint-url https://s3.home.shdr.ch \
            --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
          export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | cut -f1)
          export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | cut -f2)
          export AWS_SESSION_TOKEN=$(echo "$CREDS" | cut -f3)
      ```

   c. Write `aws_s3_bucket` / `aws_s3_bucket_policy` / `aws_iam_role` /
      `aws_iam_role_policy` resources mirroring each CRD's forProvider fields
      (no `tags` anywhere). Import instead of create:

      ```bash
      tofu import aws_s3_bucket.<x> <bucket-name>
      tofu import aws_s3_bucket_policy.<x> <bucket-name>
      tofu import aws_iam_role.<x> <role-name>
      tofu import aws_iam_role_policy.<x> <role-name>:<policy-name>
      tofu plan   # must show no changes (or only known-ignorable diffs)
      ```

   **Role-destroy caveat (job 12970):** `tofu destroy` of `aws_iam_role` fails
   on RGW — the provider calls `ListInstanceProfilesForRole`, which RGW answers
   with `405`. Create / refresh / import all work; only provider-driven role
   *deletion* breaks (the same class of RGW limitation that stuck Crossplane on
   delete). Buckets, bucket_policy, and role_policy all destroy cleanly through
   tofu. Mitigation is two-part: (1) add `lifecycle { prevent_destroy = true }`
   to every `aws_iam_role` — this only blocks an accidental `tofu
   destroy`/replacement **while the block still exists**; it is not itself a
   deletion mechanism. (2) To actually decommission a role, **in this order**:
   first remove its `aws_iam_role_policy` block and apply (the inline policy
   destroys cleanly via tofu); then `tofu state rm aws_iam_role.<x>` (tofu stops
   managing the role and never issues the failing destroy); then remove the role
   block from the config; then delete the now-policy-less role out-of-band with
   `aws iam delete-role --role-name <x> --endpoint-url https://s3.home.shdr.ch`
   (proven in jobs 12948/12970). Skipping the `state rm` is the trap: the next
   `tofu plan` sees a role in state but not config, tries to destroy it, and
   hits the same `405`.

   d. Delete the `kubectl_manifest` resources from the project tofu, apply.
      The MRs disappear; RGW objects survive (Orphan). Gate: bucket still
      serves — `aws s3api head-bucket --bucket <name> --endpoint-url https://s3.home.shdr.ch` (provisioner creds)
      succeeds; the app using it still works.

   e. Commit + push each repo directly to main. No MRs. Apply via that
      repo's own CI pipeline (play the manual `apply` job — see Global
      rules; run glab from inside that repo). NOTE: the `tofu import` steps
      in (c) run against remote state, so run them locally BEFORE pushing —
      the CI apply then sees an already-converged plan.

   Special cases: `BucketWebsiteConfiguration` and `BucketPublicAccessBlock`
   MRs (if present in the vcluster) map to `aws_s3_bucket_website_configuration`
   and `aws_s3_bucket_public_access_block`. Same import-first flow.

3. Remove the AWS half of Crossplane from `~/projects/seven30/infra/tofu/crossplane.tf`.
   **Precondition — do NOT pull the provider first:** every platform AWS MR in
   `infra/tofu` (roles `seven30-s3-readonly`/`seven30-s3-admin`/`kestra-base`
   and the `keycloak-seven30`/`k8s-seven30` OIDC providers, per the step-1
   inventory) must already be handled — imported to tofu-native **or** set to
   `deletionPolicy: Orphan` and documented as unmanaged, exactly like the
   project resources in step 2. Removing the provider packages while any of
   these is still Crossplane-managed with the default Delete policy tears down
   live RGW roles and trust anchors. Only once no un-orphaned AWS MRs remain:
   delete the `provider-aws-s3` and `provider-aws-iam` Provider objects, the
   `aws-slow-poll` DeploymentRuntimeConfig, the `ceph-rgw` ProviderConfig(s),
   and the ESO ExternalSecret feeding `crossplane-ceph-rgw-creds`. Keep
   everything Keycloak. Commit, push, trigger the CI apply job.

4. **Gate**: `kubectl -n vc-seven30 get pods | grep provider-aws` → nothing
   (in host-cluster context: the vc-seven30 namespace loses those pods). RGW
   rate (Phase 0 gate query) drops to < 30 req/s.

5. Update `~/projects/seven30/infra/docs/designs/0001-s3-bucket-provisioning.md`:
   set frontmatter `status: superseded` and append a short section "2026-07:
   provisioning moved to tofu-native (AWS provider → RGW via
   seven30-provisioner STS role); Crossplane retained for Keycloak only.
   Reason: upjet reconcile loop vs RGW API surface." Commit + push.

---

## Phase 5 — aether host cluster cleanup [1-2 h]

1. Discover host-cluster MRs (aether repo, context `admin@aether-k8s`):

   ```bash
   for r in buckets.s3.aws.upbound.io bucketpolicies.s3.aws.upbound.io \
            bucketwebsiteconfigurations.s3.aws.upbound.io bucketpublicaccessblocks.s3.aws.upbound.io \
            roles.iam.aws.upbound.io; do echo "== $r"; kubectl get $r 2>/dev/null; done
   ```

   Expected: ~1 of each (the shdrch static-site set).

2. Orphan them all (same patch as Phase 4.2a), then delete the MRs
   (`kubectl delete <kind> <name>`). The RGW bucket/role survive untouched;
   the static site keeps serving via Caddy (path-style, no k8s dependency).
   Gate: `curl -sI https://shdr.ch` → 200.

3. Read `~/projects/aether/tofu/home/kubernetes/crossplane.tf` fully. Remove
   the AWS provider packages, ProviderConfig, and their credential plumbing —
   keep any non-AWS Crossplane usage. Discover the exact state addresses to
   target:

   ```bash
   nix develop --command bash -c 'tofu -chdir=tofu state list | grep -i crossplane | grep -i aws'
   ```

   Then run the targeted plan→codex→apply flow from Global rules with one
   `-target=` per address found. Expected plan scope: ONLY destroys of those
   crossplane AWS items — anything else in the plan is a FINDING (stop).
   Gate: `kubectl -n crossplane-system get pods | grep provider-aws` → nothing.

4. The orphaned static-site bucket/role are now unmanaged. Append a note to
   `docs/worklogs/crossplane-s3-migration-2026-07.md` (this file) under
   "Residue": bucket + role names, and that future changes to them go through
   the RGW accounts playbook or tofu-native (owner's choice later).

5. aether docs sweep (AGENTS.md rule): `grep -rn "crossplane" docs/ README.md`
   — update any statement claiming Crossplane manages S3. Commit + push.

---

## Residue (Phase 5 host cluster)

The aether host-cluster static-site set is now **unmanaged** (Crossplane MRs
orphaned + deleted 2026-07-11; RGW objects untouched, `shdr.ch` serves 200):
`static-site-24` (bucket + `-policy` + `-website` + `-public-access`) and role
`static-site-24-ci` (+ `-ci-policy`). Future changes go through the RGW-accounts
playbook or tofu-native (owner's choice). The bucket serves `shdr.ch` via the
public Caddy → RGW website endpoint, no k8s dependency.

**Provider-package teardown DONE (applied 2026-07-11, commit `5e96c13`).** Removed
`provider-aws-s3`/`-iam`, the `ceph-rgw` ProviderConfig, the `crossplane-aws-creds`
secret, and the wait timer from `tofu/home/kubernetes/crossplane.tf` (keycloak/helm
retained) via a targeted `task tofu:apply` of a saved plan that showed exactly those 5
destroys (codex-gated CLEAN). The auto-installed `upbound-provider-family-aws` (no
dependents, never in tofu) was then removed live with `kubectl delete
provider.pkg.crossplane.io`. Result: **zero provider-aws on the host cluster** — only
`provider-keycloak` remains, zero `*.aws.upbound.io` CRDs, `shdr.ch` still 200. (Note: a
transient DynamoDB state-lock cleared on a 30s retry; a stray staged-deletion of the
edited file was reconstructed from HEAD before commit.)

## Phase 6 — unrelated fixes discovered during the investigation [do last]

These are independent of the migration. Diagnose, report; **restarts need
explicit user approval first** (live-op on shared infra).

1. **RGW backend on neo is down** (`192.168.2.205:7480` refuses connections;
   Caddy runs on 2/3 backends).

   ```bash
   ssh root@192.168.2.205 'systemctl list-units "ceph-radosgw*" --all; systemctl status "ceph-radosgw@*" --no-pager -l | tail -30'
   ```

   Report status. If the unit is simply dead/failed → ask user for OK, then
   `systemctl restart <unit>`, then verify:
   `curl -s -o /dev/null -w "%{http_code}" http://192.168.2.205:7480/` → 200,
   and Caddy error logs stop showing dial errors to .205.

   **RESOLVED 2026-07-09 — stale; neo RGW is healthy.** Verified `rgw: 3 daemons
   active (3 hosts)`, `:7480` serving RADOS-backed S3, `radosgw-admin user list`
   works, mon quorum + 6/6 OSDs up. The Jul-4 19:57 daemon restart already fixed
   it; no action needed. (Cluster is `HEALTH_WARN` for unrelated reasons: osd.3
   slow BlueStore ops, a pending `require-osd-release tentacle`, 8 recent crashes.)

2. **Caddy metrics scrape dead since 2026-07-04 19:40Z**
   (`up{exported_job="caddy"}` absent; edge observability blind).
   The scrape path is: Caddy admin `:2019` on home-gateway-stack → an OTel
   collector prometheus receiver → `otel_collector:8889` → monitoring-stack
   Prometheus. Diagnose in order, report findings:

   ```bash
   ssh aether@10.0.2.2 'curl -s -o /dev/null -w "%{http_code}" localhost:2019/metrics'   # expect 200
   grep -rn "2019\|caddy" ~/projects/aether/ansible/playbooks/home_gateway_stack/ | grep -i "otel\|prometheus\|scrape"
   ssh aether@10.0.2.2 'systemctl --user list-units | grep -i otel; podman ps 2>/dev/null | grep -i otel'
   ```

   Likely fix: the gateway VM's otel collector container is down or lost its
   config on 2026-07-04. If a restart is the fix → user approval first, then
   restart, then gate: Prometheus query `up{exported_job="caddy"}` returns 1
   within 2 minutes.

   **RESOLVED 2026-07-09 — the scrape belongs on the *gateway VM* agent, not k8s.**
   Root cause: Jul-4 stripped the `caddy`/`unifi`/`rotating-proxy`
   `prometheus_scrape_configs` from the gateway `vm_monitoring_agent` (its live
   `otel-config.yml` was left scraping only `node:9100`); that agent is the only
   collector that can reach `localhost:2019`. Fix: re-applied the
   `home_gateway_stack` `vm_monitoring_agent` role (`--tags monitoring-agent
   --limit home-gateway-stack`, IaC — the restart is the role's handler, not an
   ad-hoc mutation) → `up{exported_job="caddy"}=1`, per-host metrics flowing. An
   earlier misplaced scrape on the k8s cluster collector (cannot route to
   `10.0.2.2:2019`) was reverted (`7f3fe0a` + targeted apply of
   `helm_release.otel_collector_deployment`).

---

## Completion checklist

- [ ] Phase 0: RGW idle rate < 60 req/s (interim)
- [x] Phase 1: kestra-storage-s3 gone from vcluster AND RGW (2026-07-09)
- [ ] Phase 2: seven30-provisioner exists, playbook idempotent
- [x] Phase 3: tofu create + refresh idempotent against RGW (job 12970; role-destroy caveat documented)
- [x] Phase 4: **complete (2026-07-11)** — ALL seven30 S3/IAM tofu-native (crucible/demo/scout apps + platform `kestra-base`/`seven30-s3-admin`/`seven30-s3-readonly` + `keycloak-seven30`/`k8s-seven30` OIDC anchors); provider-aws-s3/iam + family gone from vcluster, ProviderConfig/ESO removed, idle ~37 req/s observe traffic eliminated. server-side `*-premig-bak` backups taken
- [x] Phase 5: **complete (2026-07-11)** — host-cluster static-site MRs orphaned+deleted (RGW objects intact, `shdr.ch` 200); provider-aws-s3/iam + `ceph-rgw` ProviderConfig + creds secret removed via tofu (commit `5e96c13`) + family provider removed live. Only `provider-keycloak` remains, zero `*.aws.upbound.io` CRDs
- [x] Phase 6: neo RGW healthy (3/3, was already up); caddy scrape restored on gateway agent (`up=1`)
- [ ] DESIGN-0001 superseded note, aether docs swept
