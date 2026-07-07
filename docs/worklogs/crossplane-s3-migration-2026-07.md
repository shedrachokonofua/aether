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
  (infra and projects) already has a GitLab pipeline for its IaC. After
  pushing to main the pipeline runs validate + plan automatically; the
  `apply` job is `when: manual`. Play it by job ID via the API (run from the
  repo in question so `:id` resolves to that project):

  ```bash
  glab auth status                                     # must be logged in to gitlab.home.shdr.ch
  PIPELINE=$(glab api 'projects/:id/pipelines?ref=main&per_page=1' | jq -r '.[0].id')
  glab api "projects/:id/pipelines/$PIPELINE/jobs" \
    | jq -r '.[] | "\(.id)\t\(.name)\t\(.status)"'     # wait until plan = success
  JOB=$(glab api "projects/:id/pipelines/$PIPELINE/jobs" | jq -r '.[] | select(.name=="apply") | .id')
  glab api -X POST "projects/:id/jobs/$JOB/play" >/dev/null
  # poll until success/failed:
  glab api "projects/:id/jobs/$JOB" | jq -r .status
  # on failed: glab api "projects/:id/jobs/$JOB/trace" for the log, then STOP and report
  ```

  If `glab auth status` fails, STOP and ask the user to run `task login` in
  the infra repo. Never run `task tofu:apply` locally for seven30.
- aether tofu applies remain local (`task tofu:plan` / `task tofu:apply`) —
  that is aether's normal workflow.
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
           "StringLike":   {"gitlab.home.shdr.ch:sub": "project_path:so/seven30/*"}
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
         {"Effect": "Allow", "Action": ["s3:*"], "Resource": "*"},
         {"Effect": "Allow", "Action": [
            "iam:CreateRole","iam:DeleteRole","iam:GetRole","iam:UpdateAssumeRolePolicy",
            "iam:PutRolePolicy","iam:DeleteRolePolicy","iam:GetRolePolicy","iam:ListRolePolicies",
            "iam:ListRoles","iam:ListAttachedRolePolicies","iam:AttachRolePolicy","iam:DetachRolePolicy"
          ], "Resource": "*"}
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
   run from `~/projects/seven30/infra` via `nix develop`):

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
   - Hard error (exit 1) on plan/apply/destroy → FAIL. Record output. Fallback
     decision is pre-made: migrate ONLY buckets to tofu and KEEP
     `provider-aws-iam` in Crossplane (it converges fine; measured ~2% of the
     flood). Report which call failed and stop this phase.

5. Cleanup: `tofu destroy -auto-approve` (expect: 3 destroyed — this also
   tests DeleteRole via the provider). Then `rm -rf tofu-spike-rgw/` and
   `unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN`.
   Verify no residue:
   `aws iam list-roles` (with root creds re-exported) must NOT contain
   `spike-tofu-role`; `aws s3api head-bucket --bucket spike-tofu-test` must 404.

---

## Phase 4 — migrate seven30 project resources [half day]

Only start after Phase 3 gate = PASS.

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

2. For EACH repo found, in this exact order:

   a. Set every S3/IAM MR to Orphan **first** (so nothing deletes real
      buckets later). Either edit the `kubectl_manifest` yaml_body to add
      `spec.deletionPolicy: Orphan` and apply, or patch live + in code:

      ```bash
      kubectl patch <kind>.<group> <name> --type=merge -p '{"spec":{"deletionPolicy":"Orphan"}}'
      ```

      Gate: `kubectl get <kind> <name> -o jsonpath='{.spec.deletionPolicy}'`
      → `Orphan` for every MR.

   b. Add the provider block from Phase 3 (plus any ignore_changes found) to
      the project's tofu, with `assume_role_with_web_identity` for CI:

      ```hcl
      provider "aws" {
        # ... same flags/endpoints as spike ...
        assume_role_with_web_identity {
          role_arn                = "arn:aws:iam::RGW54357707893720224:role/seven30-provisioner"
          session_name            = "tofu-${var.project_name}"
          web_identity_token_file = "/tmp/gitlab-oidc-token"
        }
      }
      ```

      and in `.gitlab-ci.yml` for the tofu jobs:

      ```yaml
      id_tokens:
        GITLAB_OIDC_TOKEN:
          aud: https://gitlab.home.shdr.ch
      before_script:
        - echo -n "$GITLAB_OIDC_TOKEN" > /tmp/gitlab-oidc-token
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

   d. Delete the `kubectl_manifest` resources from the project tofu, apply.
      The MRs disappear; RGW objects survive (Orphan). Gate: bucket still
      serves — `aws s3api head-bucket --bucket <name>` (provisioner creds)
      succeeds; the app using it still works.

   e. Commit + push each repo directly to main. No MRs. Apply via that
      repo's own CI pipeline (play the manual `apply` job — see Global
      rules; run glab from inside that repo). NOTE: the `tofu import` steps
      in (c) run against remote state, so run them locally BEFORE pushing —
      the CI apply then sees an already-converged plan.

   Special cases: `BucketWebsiteConfiguration` and `BucketPublicAccessBlock`
   MRs (if present in the vcluster) map to `aws_s3_bucket_website_configuration`
   and `aws_s3_bucket_public_access_block`. Same import-first flow.

3. Remove the AWS half of Crossplane from `~/projects/seven30/infra/tofu/crossplane.tf`:
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
   keep any non-AWS Crossplane usage. `task tofu:plan` from aether root,
   review that ONLY crossplane AWS items are destroyed, then `task tofu:apply`.
   Gate: `kubectl -n crossplane-system get pods | grep provider-aws` → nothing.

4. The orphaned static-site bucket/role are now unmanaged. Append a note to
   `docs/worklogs/crossplane-s3-migration-2026-07.md` (this file) under
   "Residue": bucket + role names, and that future changes to them go through
   the RGW accounts playbook or tofu-native (owner's choice later).

5. aether docs sweep (AGENTS.md rule): `grep -rn "crossplane" docs/ README.md`
   — update any statement claiming Crossplane manages S3. Commit + push.

---

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

---

## Completion checklist

- [ ] Phase 0: RGW idle rate < 60 req/s (interim)
- [ ] Phase 1: kestra-storage-s3 gone from vcluster AND RGW
- [ ] Phase 2: seven30-provisioner exists, playbook idempotent
- [ ] Phase 3: tofu plan clean against RGW (or documented fallback taken)
- [ ] Phase 4: seven30 buckets/roles tofu-managed, provider-aws-* gone from vcluster, RGW rate < 30 req/s
- [ ] Phase 5: host-cluster provider-aws-* gone, shdr.ch still 200
- [ ] Phase 6: neo RGW back (3/3 backends), caddy scrape alive
- [ ] DESIGN-0001 superseded note, aether docs swept
