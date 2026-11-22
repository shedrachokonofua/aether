# CI performance review (2026-11-21)

## Update, 2026-11-22: the main cause was a node, not the pipelines

The review below (2026-11-21) treated each job's duration as a property of the
job. It was not. The same job took far longer on `talos-neo` than elsewhere,
and 56% of jobs ran there. Everything in this section was found and done on
2026-11-22 and supersedes the "Result" and "Runner recommendation" sections
where they disagree.

### `talos-neo` ran on the `acpi_pm` clocksource for 16 days

- Kernel log: neo booted at 2026-11-06 12:11:29 UTC, switched to `tsc` at
  12:11:37, and at 12:12:05 the clocksource watchdog marked the TSC unstable
  ("skew is too large") and switched to `acpi_pm`. `tsc` was then gone from
  `available_clocksource`, so it could not be switched back without a reboot.
  On `acpi_pm` every clock read leaves the guest. This is the failure fixed on
  `talos-smith` in July (commit `b0350ba`); the `tsc=reliable` pin and the
  smith-only tripwire alert were both retired in August.
- Measured in throwaway CI jobs on neo: a clock read (`Date.now()`,
  `performance.now()`, `process.hrtime`) cost 9,200 to 10,900 ns before the
  reboot and 31 to 38 ns after it. The whole diagnostic job took 80 to 88 s
  before and 12 to 15 s after.
- Node CPU: neo's kernel CPU exceeded its user CPU in 378 of 381 hours after
  the demotion and in none of the 329 hours before it. No other node did so
  for more than an isolated hour in 30 days.
- Same commit, same tests (Orion 022ceef9, visual-QA shard 1): 46 min and 6
  failures on `talos-trinity`, 107 min and 52 failures on neo. 49 of the 52
  passed on trinity. 145 of the 169 failures in the neo run were the 50 ms
  long-task check, which measures elapsed time.
- Same jobs, the week before and the week after the demotion: on neo they
  took 0.63 times as long as on the other nodes before, and 1.20 times as
  long after. Turmeric's `caddy-build`, an unchanged workload, went from
  109 s to 298 s on neo.

neo was rebooted on 2026-11-22 at 09:53 UTC with Shedrach's approval
(`talosctl -n 10.0.3.17 reboot`): down 73 s, back on `tsc`, etcd in sync.
The durable `tsc=reliable` kernel argument was not re-added: `config/vm.yml`
records it as the suspect in three failed installer runs on smith. A new alert
covers every node instead (`talos-clocksource-regression`: kernel CPU above
user CPU for two hours; applied).

What the reboot cost, so the next one is cheaper:

- Five CI jobs died and were retried.
- Nextcloud stayed down until two pods were deleted: the server and
  task-worker were rescheduled to `talos-niobe` while `nextcloud-cron` held
  their shared ReadWriteOnce volume on neo.
- `deskplane-serve` could not pull its image anywhere: Aether pinned tag
  `666c1c2e`, and the registry had dropped it the day before, when a
  validation pipeline from this review pushed a sixth tag and the keep-5
  cleanup ran. The pod had been running from neo's image cache. Fixed by
  pinning `7ed9ae05` (the same control plane; the one commit between them
  touches only `mcp/`) and raising the registry's retention to 25 tags.
- Kata task pods stayed Pending for a while: neo's displaced pods filled
  trinity and smith, the only Kata nodes.

### Runner: eight concurrent jobs (applied)

Raised from four to eight on 2026-11-22 with Shedrach's approval, not the six
recommended below. Replaying the previous week's 4,230 jobs with neo's jobs
at half their duration gave a 95th-percentile wait of 13 minutes at four
slots, 83 s at six and 19 s at eight (a model: read the ratios). The first
quota chosen was too small: `limits.ephemeral-storage=320Gi` rejected pods
for about an hour (each job pod carries 33 to 35Gi, and a finishing pod
overlaps its successor). It is 400Gi now; seven jobs failed on it and were
retried.

### What the tests themselves waste, independent of the node

Comparing each Turmeric `rust-test` binary on trinity and on (slow) neo
separated the job into two parts. Ten binaries took the same time on both
machines, 877 of 1,404 s on trinity, so they are waiting on timers or doing
fixed duplicated work, not computing:

- `batch_quota.rs` is included as a module by `batch_quota_services.rs` and
  `quota_adapters_services.rs`, so its 29 tests run three times, about 130 s
  each.
- `runtime.rs` waits out four 30-second connection timeouts in a row.
- `symbolicate_services.rs`, `query_jobs.rs`, `retention.rs` and others sleep
  on real cache and expiry intervals.

The rest (`dedup.rs`, `isolation.rs`, `usage.rs`, `replay_services.rs`) scaled
three to four times with the node and is what neo's clock was costing.
Removing the fixed part and running isolated service stacks in parallel
inside one job is in progress on Turmeric branch `ci/fast-tests` (draft MR
!153); no result yet.

### Orion visual QA: several isolated stacks per job

`e2e/run.mjs` already isolates a run by port and database, so one job can run
several. Branch `p0/fast-qa` adds `e2e/ci-stacks.mjs`: every Playwright
project is split into three stacks balanced by measured spec time, 18 stacks
dealt to four jobs. No test or harness change.

| Shape | Node | One job | Failures in that job |
| --- | --- | ---: | --- |
| One stack per job, three jobs (before) | trinity | 46 min | 6 of 334 |
| One stack per job, three jobs (before) | neo on `acpi_pm` | 107 min | 52 of 334 |
| Four contiguous shards per job, three jobs | neo, healthy | 14.9 min (job 59188) | 9 of 349: 8 screenshot diffs, 1 failed request, no long tasks |
| Five balanced stacks per job, four jobs | neo, healthy | 10.2 min (first job of pipeline 16014) | 8 of 288: 6 screenshot diffs, 2 long tasks |

The four-job run had not finished when this was written, so there is no
full-suite figure. Under load the runner gives one project about two slots,
so four jobs do not all start together.

### Not done

- Capturing light and dark in one journey (halving the executions) cannot be
  proven against today's baselines for the Notes specs: their test data puts
  the Playwright project name in visible text. It needs those dark baselines
  re-recorded once.
- Testing visual states at component level instead of through full journeys.
- Reusing a result when the same inputs already passed.

## Result

CI used 18,900 runner slot-minutes last week on four slots. All four were busy
37% of the time and jobs waited 444 hours in total. Two jobs, Orion's visual
QA and Turmeric's Rust tests, are 45% of the slot time.

Changes are on review branches in six repositories. **Nothing is merged and
no runner setting was changed.** If everything below landed, the estimated
saving is about 3,700 slot-minutes a week, a fifth of the total. These are
estimates from one or two real pipelines each, not measured weekly figures.

| Change | Repository | Estimated slot-min/week | State |
| --- | --- | ---: | --- |
| Visual QA runs only when its inputs change | Orion | 1,500 | Lint only; first proof is the next deploy-only push to `main` |
| No second merge-request pipeline when Cicada opens a merge request | Cicada (acts on Turmeric, Buyerfact, Cicada) | 790 | Tests pass locally; needs a Cicada release |
| Gate jobs merged, duplicate build removed, CPU limit 4 | Buyerfact | 600 | Two green pipelines |
| One pipeline per release commit (release recipe) | Orion | 270 | Not exercised; changes the release procedure |
| One compile for the four Rust images | Daimyo | 170 to 300 | Green on the branch-image path; the `main` path not run |
| CI image reused when its inputs are unchanged | Cicada | 200 | Green |
| `e2e` reuses the Caddy binary | Turmeric | 140 | Green |
| One Go job on a shared cache | Deskplane | 50 | **Not green**: flaky browser tests |

What did not improve:

- **Turmeric's `rust-test`, 22% of slot time.** Its time is in tests that
  share services and wait on them. Running them concurrently is unsafe and
  testing only affected crates saves 2%. One test was made faster (90 s of a
  32-minute job).
- **Orion's image build.** A registry layer cache was tried, was not faster,
  and was reverted.
- **Turmeric's `runtime-budget` release cache** was written but never read,
  because the two runs landed on different nodes.

Decisions for Shedrach:

1. Whether each branch lands. Three carry a judgement beyond CI mechanics:
   Orion's release recipe, Buyerfact dropping its one-job-per-script rule, and
   Deskplane running its Go suite once (under the race detector) instead of
   twice.
2. Orion's visual QA has failed in every run since 2026-11-20 and is allowed
   to fail. It costs 4,330 slot-minutes a week. Whether it should keep running
   on every `main` push in that state.
3. Deskplane's browser tests failed six of ten runs, five on tests that assert
   on real elapsed time. They need rewriting; the pipeline cannot fix them.
4. The runner: six concurrent jobs after the pipeline changes land, with job
   pods spread across nodes. Evidence and caveats below.
5. Protected container tags in GitLab, which would close the registry
   overwrite path that Cicada's audit already describes.

## Scope and method

All 121 GitLab projects were listed. Eleven created a pipeline between
2026-11-07 and 2026-11-21 18:30 UTC; the other 110 created none (one,
`so/pop-functions`, refused the pipelines API with 403 and is not counted
either way). Every number below is from those eleven.

- **Jobs and pipelines:** GitLab API (`/projects/:id/pipelines` and `/jobs`),
  6,426 jobs that started. `duration` is the time a job held a runner slot;
  `queued_duration` is the time it waited for one. "Slot-minutes" are summed
  `duration`.
- **Two windows.** Per-project figures use each project's own observed span in
  the 14 days (some projects first ran a pipeline partway through; GitLab keeps
  Orion's pipelines only from 2026-11-14). Runner-wide figures use the last
  seven days, 2026-11-14 18:00 to 2026-11-21 18:30 UTC, the only span all the
  busy projects cover.
- **Pod resources:** ClickHouse through the read-only Grafana datasource:
  `container_cpu_usage_seconds_total`, `container_cpu_cfs_*_periods_total`,
  `container_memory_working_set_bytes`, `kube_pod_container_resource_requests`
  and `_limits` for namespace `gitlab-runner`. 5,414 of 5,445 job pods were
  matched one-to-one to a GitLab job by project id and start time (median
  difference between pod lifetime and job duration: 10 s).
- **Per-phase job time:** the `section_start`/`section_end` markers in job
  traces (pod start, clone, cache restore, script, cache upload), sampled from
  the three most recent successful runs of each job.

Samples and estimates are labelled where they appear. Nothing here is a
controlled benchmark: before/after pairs are real pipelines on different
commits under different queue conditions.

## Baseline

### Per project

| Project | Days observed | Pipelines run | Per day | Cancelled % | Failed % | Jobs run | Slot-min/week | Queue median s | Queue p95 s | Queue max s | Pipeline wall median min | Pipeline wall p95 min |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| so/turmeric | 13.5 | 469 | 34.7 | 19.4 | 41.6 | 3,508 | 7,502 | 87 | 1,937 | 6,637 | 51.9 | 128 |
| so/orion | 7 | 71 | 10.2 | 5.6 | 5.6 | 288 | 6,046 | 25 | 3,924 | 11,449 | 36.3 | 205 |
| seven30/scout | 0.2 | 13 | 61.2 | 15.4 | 30.8 | 49 | 2,163 | 153 | 1,252 | 1,909 | 6.1 | 23.7 |
| seven30/buyerfact | 13.6 | 188 | 13.9 | 0 | 17 | 1,674 | 1,460 | 73 | 819 | 3,426 | 13.5 | 40.6 |
| so/daimyo | 12.5 | 13 | 1 | 7.7 | 23.1 | 180 | 919 | 240 | 3,013 | 4,594 | 59.9 | 140 |
| so/cicada | 13.5 | 116 | 8.6 | 7.8 | 10.3 | 568 | 704 | 81 | 669 | 2,025 | 11.5 | 31.9 |
| so/deskplane | 5.6 | 3 | 0.5 | 0 | 0 | 30 | 173 | 264 | 1,402 | 1,932 | 104 | 387 |
| so/pharos | 5.5 | 20 | 3.7 | 15 | 5 | 80 | 126 | 3 | 223 | 373 | 5.5 | 19.6 |
| so/pop | 5.6 | 5 | 0.9 | 0 | 0 | 45 | 86 | 120 | 451 | 597 | 11.5 | 24.1 |

`seven30/scout` ran for the first time in the window on 2026-11-21, so its
weekly rate is an extrapolation from five hours and should be ignored.
"Failed %" is of pipelines that ran. Turmeric's 42% is mostly its automated
writers' work in progress: 79 of its 195 failed pipelines failed only on
`fmt`, `clippy`, `build` or the CI image.

### The runner over seven days

- 18,922 slot-minutes a week were used, 47% of the four slots' capacity. Turmeric
  used 7,780, Orion 6,014, Buyerfact 2,424, Cicada and Daimyo
  1,166 each.
- All four slots were busy in 36.8% of minutes. At least one job was
  waiting in 34.3% of minutes, and more than five in 19.4%.
- 4,324 jobs waited 444 hours in total: median 83 s, 90th percentile
  838 s, 95th percentile 1,596 s, longest 191 minutes.
- Capacity is not short on average; it is short in bursts. On 2026-11-18 all
  four slots were busy 88% of the day and a mean of 7.6 jobs were waiting.

### Where the slot time goes

| Project | Job | Runs (7d) | Median s | p95 s | Slot-min/week | Failed % | Share of slot time % |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| so/orion | visual-qa | 43 | 6,131 | 10,801 | 4,330 | 53.5 | 22.9 |
| so/turmeric | rust-test | 161 | 1,814 | 2,168 | 4,201 | 19.3 | 22.2 |
| so/turmeric | e2e | 158 | 752 | 924 | 1,901 | 7.6 | 10 |
| seven30/buyerfact | test | 144 | 569 | 750 | 1,306 | 6.9 | 6.9 |
| so/orion | visual-qa-baselines | 10 | 6,534 | 10,687 | 1,056 | 80 | 5.6 |
| so/turmeric | runtime-budget | 116 | 319 | 368 | 606 | 8.6 | 3.2 |
| seven30/buyerfact | test:e2e | 144 | 282 | 419 | 597 | 4.2 | 3.2 |
| so/orion | image-build | 67 | 542 | 650 | 515 | 7.5 | 2.7 |
| so/cicada | build:ci | 100 | 167 | 249 | 330 | 0 | 1.7 |
| so/cicada | test | 93 | 176 | 301 | 303 | 1.1 | 1.6 |
| so/turmeric | clippy | 198 | 80.3 | 140 | 295 | 18.2 | 1.6 |
| so/daimyo | rust-test | 10 | 1,274 | 2,432 | 235 | 20 | 1.2 |
| so/turmeric | build | 195 | 43.7 | 120 | 199 | 5.6 | 1.1 |
| so/cicada | ui | 93 | 121 | 186 | 196 | 8.6 | 1 |
| so/daimyo | build:daimyo-molecule | 5 | 2,582 | 3,010 | 192 | 20 | 1 |
| so/turmeric | caddy-build | 44 | 309 | 351 | 186 | 0 | 1 |

Two jobs, Orion's `visual-qa` and Turmeric's `rust-test`, are 45% of all slot
time. While all four slots were busy, `rust-test` held 23% of the occupied
slot-minutes and `visual-qa` 19%.

### Resource use against requests

Build container only, jobs longer than a minute, at least ten matched pods.
Every job requests 1 CPU and 2 GiB unless it overrides them.

| Project | Job | Pods matched | Median s | Average CPU cores | CPU limit | CFS periods throttled % | Memory request GiB | Peak memory p95 GiB | Peak memory max GiB |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| so/turmeric | clippy | 362 | 77.7 | 0.9 | 2 | 18.9 | 2 | 0.7 | 1.2 |
| so/turmeric | rust-test | 301 | 1,694 | 1.3 | 2 | 36.7 | 2 | 3.6 | 3.9 |
| so/turmeric | e2e | 298 | 754 | 1.1 | 2 | 46.0 | 2 | 2.7 | 3.5 |
| so/turmeric | runtime-budget | 211 | 335 | 1.9 | 3 | 65.5 | 2 | 2.3 | 3.2 |
| seven30/buyerfact | test | 186 | 498 | 1.8 | 2 | 94.6 | 2 | 1.8 | 1.9 |
| seven30/buyerfact | test:e2e | 181 | 203 | 1.1 | 2 | 39.8 | 2 | 1.8 | 1.9 |
| so/cicada | build:ci | 116 | 169 | 0.7 | 2 | 22.9 | 2 | 1.0 | 1.7 |
| so/cicada | clippy | 109 | 77.7 | 0.8 | 2 | 17.8 | 2 | 0.9 | 1.1 |
| so/cicada | test | 108 | 174 | 1.2 | 2 | 40.2 | 2 | 2.7 | 2.9 |
| so/cicada | ui | 106 | 137 | 1.3 | 2 | 69.1 | 2 | 1.0 | 2.4 |
| so/turmeric | build | 106 | 101 | 1.2 | 2 | 33.1 | 2 | 0.9 | 1.2 |
| so/turmeric | caddy-build | 102 | 293 | 1.6 | 2 | 85.1 | 2 | 0.4 | 1.1 |
| seven30/buyerfact | build:context | 70 | 68.4 | 0.5 | 2 | 14.6 | 2 | 1.1 | 1.4 |
| so/orion | image-build | 67 | 542 | 1.1 | 2 | 16.8 | 2 | 2.1 | 2.1 |
| so/orion | visual-qa | 43 | 6,131 | 1.4 | 2 | 29.1 | 2 | 2.1 | 2.3 |
| seven30/buyerfact | check | 26 | 71.0 | 0.6 | 2 | 89.3 | 2 | 1.6 | 1.6 |
| so/turmeric | build:turmeric | 20 | 678 | 1.1 | 2 | 14.5 | 2 | 3.8 | 3.9 |
| so/pharos | validate | 19 | 119 | 0.6 | 2 | 2.5 | 2 | 1.1 | 1.2 |
| so/pharos | test | 14 | 74.4 | 0.7 | 2 | 19.9 | 2 | 0.7 | 0.7 |
| so/pharos | build:image | 14 | 91.4 | 0.8 | 2 | 17 | 2 | 0.7 | 0.8 |
| so/daimyo | rust-test | 14 | 1,265 | 0.7 | 2 | 12.0 | 2 | 3.3 | 3.3 |
| so/cicada | build-image | 14 | 708 | 1.1 | 2 | 12 | 2 | 2.6 | 3.1 |
| so/daimyo | build | 13 | 221 | 0.8 | 2 | 13.1 | 2 | 2.9 | 3.2 |
| so/daimyo | rust-test-engine | 13 | 776 | 0.3 | 2 | 1.6 | 2 | 2.2 | 2.7 |
| so/daimyo | clippy | 13 | 219 | 0.8 | 2 | 6.3 | 2 | 1.9 | 2.0 |
| so/orion | postgres-test-image | 13 | 104 | 0.6 | 2 | 13.9 | 2 | 0.3 | 0.3 |
| seven30/scout | test:app | 11 | 126 | 0.2 | 2 | 1.0 | 2 | 0.4 | 0.4 |
| so/orion | visual-qa-baselines | 10 | 6,534 | 1.4 | 2 | 29.2 | 2 | 2.1 | 2.2 |

- 86.8% of jobs peaked at or under their 2 GiB request (50.4% under 0.5 GiB);
  the jobs above it are the Rust tests and image builds, and hold 44.1% of slot
  time. The highest peak was 3.9 GiB against the 4 GiB limit. No job in the
  14 days requested more memory than the default except Pop (4 GiB), so the
  comment in `gitlab_runner.values.yaml.tftpl` about a `rust-test` asking for
  6 CPU and 12 GiB is stale.
- Several jobs are held back by the 2-CPU limit, not by the node: Buyerfact
  `test` and `check`, Deskplane `test`, `validate` and `build:image`, and
  Turmeric `caddy-build` were throttled in 83% to 99% of scheduler periods.
- Job pods landed on `talos-neo` 56% of the time, `talos-trinity` 37%,
  `talos-smith` 7% and never on `talos-niobe`, whose memory is 99% requested by
  other workloads.

### Cache behaviour

- The job cache is a hostPath on whichever node the pod lands on. In 24 recent
  Turmeric `rust-test` runs the cargo cache was restored in 23, and 12 crates
  recompiled: with 22 runs a day the two busy nodes stay warm. Low-volume
  projects get no such guarantee.
- Restoring and re-uploading a cache is not free. Daimyo's `clippy` and
  `build` spent about 55 s restoring and 60 s uploading the cargo cache around
  100 s of work, and three jobs wrote the same key.
- Image builds start from an empty layer store in every pod. Projects that use
  a registry layer cache set a 24-hour expiry; Daimyo runs about one pipeline a
  day, so its dependency layer had usually expired.
- `/var/mnt/ci` on `talos-neo` had under 15 GiB free of 128 GiB on every day
  from 2026-11-07 to 2026-11-19 and reached zero on 2026-11-19. Since the
  seven-day cache prune it has stayed above 100 GiB free.

## Where the waste is, ranked

Slot-minutes are per week from the seven-day window unless a different span
is named. "Wall-clock" is what the item costs whoever is waiting for a result.

| # | Item | Slot-min/week | Wall-clock cost | Evidence |
| ---: | --- | ---: | --- | --- |
| 1 | Orion visual QA runs when nothing it tests changed, and reruns the same commit | 4,330 total; 1,536 on pushes that changed only `deploy/`, `docs/` or `README.md`; 1,272 on `dev/revamp` for commits `main` also ran | Three of the four slots for about 100 minutes per run; release 022ceef9 published its chart 205 minutes after the push | 15 of 22 `main` pipelines touched only those paths; 18 of 18 `dev/revamp` pipelines were for a commit also on `main` |
| 2 | Turmeric `rust-test` | 4,201 | 30 to 36 minutes per run, a median of six runs per merge request | 68 test binaries run one after another; the cache restores and only 12 crates recompile, so about 33 minutes is tests waiting on services and timeouts |
| 3 | Two merge-request pipelines for the first head of every merge request Cicada opens | 790 (Turmeric 515, Buyerfact 251, Cicada 27; 14-day spans) | Both run at once and compete for slots; Turmeric's benchmark needed a `resource_group` to survive it | 62 pairs created 0.1 to 0.7 s apart by the same bot: GitLab's own pipeline, then Cicada's `POST .../pipelines` |
| 4 | Turmeric `e2e` rebuilds Caddy and `runtime-budget` recompiles the release build every run | 1,901 and 606 in total; about 420 and 345 of it recoverable (estimates from job 58057: 161 s in xcaddy; job 58058: 189 s compiling 333 crates) | 2.7 and 3.2 minutes per run | 218 Go module downloads per `e2e`; `Compiling` 333 crates per `runtime-budget` |
| 5 | Buyerfact gate jobs throttled at 2 CPU and built twice | 1,306 (`test`) and 597 (`test:e2e`) in total | `test` 8 to 10 minutes | `test` throttled in 95% of scheduler periods; `build` runs alone and again inside `test:e2e` |
| 6 | Orion image build reinstalls both dependency sets every time | 515 | 9 to 10 minutes on the release path | `npm ci` 2 min and `npm ci --omit=dev` 1 min in every trace; 173 MB of screenshot baselines in the build context |
| 7 | Daimyo compiles its Rust workspace in four image jobs at once | 494 (14-day span) | All four slots for 27 to 43 minutes on each Rust change | 126 to 163 slot-minutes per pipeline across the four jobs; each job cooked the dependency layer itself |
| 8 | Cicada rebuilds its CI image on every pipeline | 330 | About three minutes before any other job can start (median 167 s, p95 249 s) | 100 runs in seven days, median 167 s, no change to its inputs in most |
| 9 | Deskplane compiles its Go code in four separate pods and reruns on timing flakes | 137 | 104 minutes median from push to finished pipeline, three pipelines | `validate`, `test` (twice: race, then coverage) and `build:device` each start cold; `test:mcp-browser` failed 3 of 6 runs before this work |
| 10 | Queue hops for jobs that do seconds of work | under 100 each | A second and third wait in line per pipeline; `ci:retag` waited a median 495 s | Turmeric and Buyerfact start two jobs of about 1 s each before anything else can run |

Items 1 and 2 are 45% of all slot time. Item 1 is mostly avoidable by running
the suite only when its inputs change. Item 2 is not: see Turmeric below.

## Changes

Nothing is merged. Every change is on a branch named below for review.

### Orion (`so/orion`, branch `ci/perf-2026-11`, not merged)

Commits `32ff5e72`, `55850761`, `69cd9366`, `0be4e9b7`. Net change against
`main`: `.gitlab-ci.yml`, `.dockerignore` and the release recipe in
`README.md`. The Dockerfile is unchanged.

| Change | What it removes | Evidence | Verified |
| --- | --- | --- | --- |
| `visual-qa` runs on `main`, merge requests and `p<N>/` branches only when `src/`, `e2e/`, `static/`, `scripts/`, `drizzle/`, `ops/postgres/`, the package files, root configs or the CI file change | 1,536 slot-minutes last week on 15 `main` pushes that changed only `deploy/`, `docs/` or `README.md`, release 5f6b20c1 among them | `e2e/run.mjs`, the specs and the app build read nothing under `deploy/` or `docs/`; `chart-check` still covers the chart | Lint only. A dry run cannot evaluate `changes`, so the first real proof is the first deploy-only push to `main` |
| `workflow:auto_cancel:on_new_commit: interruptible` | Up to 902 slot-minutes last week that ran after a newer pipeline existed on the same ref. GitLab's default cancels nothing once a non-interruptible job (the image build) has started | Only `visual-qa` is interruptible; image, chart and secret detection are not and still run for every commit | Lint only |
| `image-build` and `chart-check` get `needs: []`; `chart-check` is defined above `visual-qa` | The image no longer waits for the secret-detection stage (non-blocking by design); the chart check is queued ahead of the QA shards. In pipeline 15500 the image finished 85 minutes after the push and the chart published at 205 | Job order within a project follows creation order: 15500 started the three shards before `chart-check` | Branch pipelines 15643 and 15670: `image-build` and `chart-check` were pending from the start of the pipeline |
| Depth-1 clone for `image-build` | 33 to 44 s of clone per job | Two samples: 13 s (job 58271) and 23 s (58305) | Yes, two samples |
| `e2e/` out of the image build context | 173 MB of screenshot baselines copied into the builder on every build | Local builds with and without it: identical client CSS | Builds 58271 and 58305 passed without it. Time saved not measured separately |
| Release recipe: push `main` alone; push `p10/integrate` and `dev/revamp` with `-o ci.skip` | A second image build, scan and chart check on `dev/revamp` for every release (160 slot-minutes last week after the 2026-11-20 rule that stopped QA there; 1,432 including QA before it), and a visual-QA run on `p10/integrate` for a commit `main` then runs again (111 slot-minutes) | 18 of 18 `dev/revamp` pipelines last week were for a commit that also ran on `main` | Not exercised: it takes effect at the next release. This edits the release procedure and needs Shedrach's review as such |

**Tried and reverted: a registry layer cache for the image build.** The
dependency installs were split into their own stages and the build ran with
`--layers --cache-from/--cache-to`. A local build of both Dockerfiles showed
identical `node_modules`, `package.json` and migrations (28,247 files) and
identical client CSS, so the image was equivalent. It was not faster:

| Build | Job | Duration |
| --- | ---: | ---: |
| Before, median of 67 runs | | 541 s |
| Before, the three most recent | 57894, 57905, 57911 | 705, 647, 652 s |
| With cache, seeding run | 58271 | 1,277 s |
| With cache, every dependency layer pulled | 58305 | 651 s |

Pulling and committing the 1 GB `node_modules` layers costs what `npm ci`
costs. The Dockerfile is back to `main`'s and the two registry repositories
the test created (`so/orion/cache`, `so/orion/ci-perf-2026-11`) are deleted.

One side finding from the equivalence check: `docs/`, `deploy/` and `ops/`
cannot leave the build context without changing the shipped stylesheet.
Tailwind scans them, and two generated rules (`.table-cell` and a junk
`.[m:ss]` rule) exist only because of text in `docs/`.

Left for Shedrach:

- **Visual QA has failed in every run since it was split into shards on
  2026-11-20** (pipeline 15500: 262 passed, 50 failed in shard 1; 259 passed,
  59 failed in shard 2), with `allow_failure: true`. It is 4,330 slot-minutes
  a week and three slots for about 100 minutes per run. Running it less often
  is done above; whether a suite in this state should run on every `main`
  push at all is a gate decision and was not touched. The Coder release gate
  (`run-orion-gate.sh`) runs check, lint, vitest and build, not visual QA, so
  CI is the only place the suite runs.
- **Every branch publishes an image.** The registry holds one repository per
  branch slug, 69 of them, and feature-branch image builds cost 199
  slot-minutes last week. Nothing in Aether references a branch image
  (`orion.tf` pins `so/orion/main`); whether anything else pulls them was not
  established, so the job was left as is.

### Turmeric (`so/turmeric`, draft MR !152, branch `ci/perf-2026-11`)

Pipeline 15631 passed all thirteen jobs on commit `f4ab5eec`. A follow-up
commit, `3a43e84f`, is pushed with CI skipped: it passes lint and has never
run.

| Job | Before | After (15631) | Reading |
| --- | ---: | ---: | --- |
| `e2e` | median 779 s over the 24 most recent runs (624 to 933) | 546 s (job 58243) | Outside the spread. One sample |
| `rust-test` | median 2,142 s (1,513 to 3,357) | 1,928 s (job 58240) | Inside the spread. Not a measured saving |
| `runtime-budget` | median 339 s (260 to 414) | 335 s (58244) and 406 s on retry (58384) | No saving seen |

- **`e2e` reuses the Caddy binary** that `caddy-build` just built and checked,
  passed as an artifact, instead of running xcaddy again (161 s and 218 module
  downloads in baseline job 58057). The binary carries a hash of its inputs
  (`edge/caddy`, `deploy/ci`, the toolchain file, the CI file) and its own
  checksum; on any mismatch `e2e` builds it as before. This applies when
  `caddy-build` is in the pipeline, 53 times last week, about 140 slot-minutes
  a week (estimate). For the other `e2e` runs there is a node-local cache
  fallback that no pipeline has exercised yet.
- **`runtime-budget` has its own release-build cache.** The job compiles all
  333 crates in release mode on every run (189 s in job 58058) because the
  shared cache only ever holds the debug build. The cache was written but not
  yet read: the first run landed on `talos-trinity` and the retry on
  `talos-neo`, and the job cache is per node. The idea is unmeasured, not
  disproven. The benchmark command, CPU envelope and settle steps are
  untouched.
- **`rust-test`**: CPU limit 4 and memory limit 6 GiB (requests unchanged), and
  one test, `runtime_roles_reject_unreachable_postgres_before_serving`, starts
  its four roles at once instead of in turn, with the same assertions. That
  binary went from 120.5 s to 30.2 s. Nothing else in the job is a measured
  gain: the summed test time fell from 2,022 s to 1,799 s, but 107 s of that is
  one binary nobody changed. 65 test binaries reported the same pass, fail and
  ignore counts as baseline job 58054; the one binary missing (`replay_access`)
  does not exist at the branch's base commit.

`rust-test` is 22% of all slot time and this work did not find a way to make
it materially shorter without changing the tests themselves: see "Considered
and left alone". What remains is in the tests: `dedup.rs` (250 s),
`queries_services.rs` (118 to 226 s), `isolation.rs` (128 to 156 s) and
`usage.rs` (98 to 120 s) contain most of the eighteen tests that run for over a
minute each.

### Buyerfact (`seven30/buyerfact`, draft MR !104, branch `ci/perf-2026-11`, commit `fdf1cb13`)

Pipelines 15630 and 15666 passed all seven jobs. Nothing merged.

- `check` and `lint` share one job. Both scripts always run, either failure
  fails the job, and the job ends with the tail of each failed script's own
  output, sized to the 80 lines Cicada passes to the writer.
- The standalone `build` job is gone. It ran `bun run build`; `test:e2e` runs
  the identical command before Playwright, so the build is still a gate.
- `test` is the only writer of the bun cache; the other jobs restore it.
- CPU limit 4 (request unchanged) for `check`, `test` and `test:e2e`, and
  Vitest capped at four workers.
- `AGENTS.md` said "a CI job exists for each script". The change replaces that
  convention and updates the line. That is Shedrach's call at review.

| Job | Before (median of the 8 most recent) | After (pipeline 15666) | Scheduler periods throttled |
| --- | ---: | ---: | --- |
| `test` | 646.5 s | 411.6 s | 94.6% to 18.7% |
| `test:e2e` | 395.9 s | 359.4 s | 39.8% to 3.9% |
| `check` and `lint` | 58.9 s and 33.0 s | 42.1 s in one job | `check` 89.3% to 52.7% (two samples) |
| Whole pipeline | 1,291 slot-seconds, 9 pods | 922 slot-seconds, 7 pods | |

The after column is one pipeline; 15630 gave `test` 390 s and `test:e2e`
353 s. At 13.9 pipelines a day the difference is about 600 slot-minutes a
week. That is an estimate, and against the 14-day medians (`test` 498 s,
`test:e2e` 185 s) rather than the most recent runs it would be smaller:
`test:e2e` has slowed over the fortnight for reasons this change does not
address.

Left alone: the two-job image prelude (`ci:tag`, `build:ci`), about 15
slot-minutes a week plus one queue hop per pipeline. Merging it needs one
image with both a registry-copy tool and Buildah, which does not exist here.

### Cicada (`so/cicada`)

**CI image reuse** (draft MR !66, branch `ci/perf-2026-11`, commit `0705af3b`,
pipeline 15638 passed). `build:ci` rebuilt the CI image on every pipeline: 100
runs in seven days, median 167 s, and every other job waits for it. In a
merge-request pipeline it now compares the Dockerfile, `rust-toolchain.toml`
and `.dockerignore` with the default branch's and, when they are the same,
points this commit's tag at the default branch's image in the registry. A
missing image falls back to building. `main` and tag pipelines build from the
Dockerfile exactly as before and read nothing a merge request wrote. `fmt` now
runs as the first command of the `clippy` job.

| Job | Before (pipeline 15600) | After (pipeline 15638) |
| --- | ---: | ---: |
| `build:ci` | 148.0 s | 10.7 s |
| `fmt` | 11.1 s | in `clippy` |
| `clippy` | 129.2 s | 127.5 s |
| `test` | 284.6 s | 224.7 s |
| `ui` | 113.4 s | 171.1 s |
| Total | 11.4 slot-min, 5 pods | 8.9 slot-min, 4 pods |

Single samples on different commits. Only the `build:ci` difference is the
change; `test` and `ui` moved for unrelated reasons. At 87 merge-request pipelines last week that is roughly 200 slot-minutes a
week (estimate: 137 s times 87), and about two minutes off every pipeline's
critical path. The commit tag and the default-branch tag resolved to the same
digest in the validation run.

Residual risk, unchanged in kind: a merge-request job holds the registry
credential and could overwrite the default branch's commit tag that other
merge requests now reuse. The existing audit finding about the shared layer
cache describes the same class of exposure. Protected container tags would
close both; that is a GitLab setting for Shedrach to decide.

**Duplicate merge-request pipelines** (branch `fix/duplicate-mr-pipeline`,
commits `d01f003`, `fcceced`, `8fee3f1`, `bfbe258`; no merge request opened, no
pipeline run). When Cicada opens a merge request, GitLab creates a pipeline
for it and Cicada's reconciler, in the same pass, sees none yet and posts a
second one. Pairs created 0.1 to 0.7 s apart by the same bot user: 27 in
Turmeric, 29 in Buyerfact and 6 in Cicada in two weeks, each a full second
pipeline, about 790 slot-minutes a week. Turmeric's `resource_group` on its
benchmark and the comment beside it are a workaround for exactly this.

The fix: a head recorded less than ten seconds ago gets no fallback pipeline
yet; the reconciler wakes itself when the ten seconds are up and posts one
only if GitLab still shows none. A later head whose pipeline GitLab reports as
skipped (the writers push with CI skipped) is started at once, as before.

- Verified: `cargo test -p cicada-reconciler -p cicada --locked` against a
  throwaway Postgres 17 and NATS passes (22 tests in `skeleton`, including the
  new ones for the grace period, restart and skipped heads), `cargo clippy
  -D warnings` and `cargo fmt --check` pass.
- Not verified: that the new tests fail on `main` (read from the code, not
  run), the serve-loop wake (no test seam; by inspection), and the effect in
  production, which needs a Cicada release. Ten seconds is a margin over the
  observed gap, not a measured bound on how long GitLab takes.

### Daimyo (`so/daimyo`, draft MR !25, branch `ci/perf-2026-11`, commit `e2d9d8b`)

Merge-request pipeline 15633 passed after one retry (below). The image build
was validated through the documented opt-in branch-image path (job 58276),
which publishes only server and ctl by commit SHA; all four `:main` digests
were unchanged afterwards.

- **One job compiles the workspace once for all four Rust images.** Before,
  `build:daimyo-server`, `-sidecar`, `daimyoctl` and `-molecule` each ran in
  their own pod, each cooked the dependency layer (15m52s, 12m41s, 22m43s and
  12m42s in pipeline 14343) and each compiled the workspace for its one
  binary: 126 to 163 slot-minutes per pipeline, all four slots held for 27 to
  43 minutes, 3.4 such pipelines a week. Now one builder stage builds the four
  binaries and one job builds and pushes the four targets in turn (server
  first) against one local layer store. Image names, tags, entrypoints, users
  and ports are unchanged. The job's memory limit is 8 GiB (request
  unchanged): the old jobs peaked at 3.7 to 3.9 GiB of 4.
- **Checks share pods.** `fmt`, the two script tests, the Python tests and the
  TypeScript tests are one `quick-checks` job; every command still runs. A
  Rust-changing `main` pipeline starts 8 pods instead of 14.
- **One cargo-cache writer.** `rust-test` writes the cache; `build`, `clippy`
  and the engine tests only read it. Before, three jobs each spent about a
  minute re-uploading the same key.

| Work | Before (pipeline 13659) | After |
| --- | ---: | ---: |
| Server and ctl images | 2,079 s + 1,945 s = 67.1 slot-min, two slots | 2,797 s = 46.6 slot-min, one slot (job 58276) |
| `fmt`, scripts, Python, TypeScript | 91.3 s in four pods | 69.3 s in one |
| `clippy` | 203.5 s | 175.7 s |
| `build` | 216.6 s | 173.4 s |
| `rust-test` | 1,128 s | 1,362 s |
| `rust-test-engine` | 816 s | 1,062 s failed; 784 s on retry |

Single samples. The image job's trace shows one 13m24s dependency cook and
one 9m38s four-binary build. A `main` run also builds the molecule components
and pushes two more images; that was not run. Estimated at 67 to 86
slot-minutes against 126 to 163 before, which at 3.4 pipelines a week is
roughly 170 to 300 slot-minutes a week. Time to the server image did not
improve (about 39 minutes from job start, as before): the gain is three slots
left free for half an hour, not a faster image. The check and test jobs
together were not cheaper in this run (43.0 slot-minutes against 41.2): the
two Rust test jobs ran slower on a loaded runner and outweighed the rest.

The engine-test failure: `a_launch_retried_through_capacity_refusals_mints_one_grant_set`
saw four launch attempts where it expects three. The job had passed in all 13
runs of the previous 14 days, the test and the job's configuration are
unchanged, and the same cache key was restored. The trace shows overlapping
capacity refusals and a second engine adopting the task; the test's 600 ms
lease against a 1.5 s simulated start could produce that under load. That is
an inference. The retry passed all 113 tests.

Equivalence of the images was checked from the registry only: identical
architecture, user, entrypoint, ports, environment and 18 base layers, and the
same 98,722,736-byte stripped server binary as job 55208. That is not proof of
identical behaviour. Only `daimyoctl` links the one crate that reads
`DAIMYO_GIT_SHA`, and both the old and new `cargo build` run at the workspace
root without `-p`, so feature resolution should be the same.

### Deskplane (`so/deskplane`, draft MR !2, branch `ci/perf-2026-11`, commit `c02b1049`)

**Not ready: the redesigned pipeline has not had a green run.** Its last
pipeline, 15679, failed on a browser timing test, as did 15635 and 15667 on
two other tests. The image jobs were correctly skipped each time.

What changed:

- One Go job vets, tests once with the race detector and atomic coverage, and
  builds the device binaries on a shared module and build cache. Before:
  `validate` 408 s, `test` 597 s (the suite twice: race, then coverage) and
  `build:device` 154 s, each compiling from cold. After: 481 s cold (one
  sample), 83.5 s warm (job 58310). The plain non-race run of the suite no
  longer exists; the same tests run once under `-race`. That is a judgement
  about what the second run added and needs Shedrach's review.
- MCP unit and browser tests share one job; both always run. 528 s (job
  58312) against 123 s and 550 s before.
- A merge-request pipeline that touches `mcp/` starts five pods before
  publishing instead of eight.
- Image publication still waits for the Go, chart and MCP checks. Device
  binaries are now available as artifacts before the MCP checks finish; that
  ordering change also needs review.
- `test_debug.py::test_console_error_from_click_is_in_action_envelope` now
  waits for the console error it asserts on (one containing `boom`) instead of
  any console error. The assertion is unchanged. It passed once afterwards.

The browser suite is the real cost. Ten runs in 14 days:

| Job | Result | Failed test |
| ---: | --- | --- |
| 53392 | Failed | INP outlier; console envelope |
| 53414 | Passed | |
| 56532 | Failed | INP outlier |
| 56835 | Passed | |
| 57994 | Failed | Fast INP (`48 < 16`) |
| 58038 | Passed | |
| 58219 | Passed | |
| 58260 | Failed | INP outlier |
| 58302 | Failed | Console envelope |
| 58312 | Failed | Fast INP (`32 < 24`) |

Six of ten failed, five of them on an INP test. Each failure costs a rerun of
about ten minutes and holds the image. The INP tests assert on real elapsed
time including paint. Raising the job's CPU limit reduced throttling (57.6% of
periods at 2 CPUs, 23.9% at 4, 0.35% at 8) but did not make them pass: the
run at 8 failed on the console test and the run at 4 on fast INP, and both
passing and failing runs at 2 CPUs were heavily throttled. The committed limit
is 4; the smallest sufficient value between 4 and 8 was not measured. These
tests need to stop depending on wall-clock time. That is a change to the
tests, not to the pipeline, and it was not attempted beyond the console test.

No push-to-image time exists for the final design. An earlier, tuning-only
pipeline (15624) produced its image 25.5 minutes after it was created, against
a 100-minute median before, but queue conditions differed and the comparison
proves little.

## Runner recommendation (not applied; needs Shedrach's approval)

**Recommendation: land the pipeline changes first, then raise the runner from
four to six concurrent jobs, and add a soft spread of job pods across nodes in
the same change. Keep eight as a later step, not a target.**

Evidence for six:

- *Room by requests.* Subtracting every non-CI pod's requests from each node's
  allocatable, hour by hour over 14 days, leaves room for this many default
  job pods (1.1 CPU, 2.1 GiB with the helper):

| Node | Unrequested memory p5 GiB | Unrequested memory median GiB | Unrequested CPU p5 | Unrequested CPU median | Default job pods that fit: minimum | p5 | median |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| talos-neo | 13.4 | 21.8 | 9.1 | 16.5 | 5 | 6 | 10 |
| talos-niobe | 0.6 | 0.7 | 2.4 | 2.7 | 0 | 0 | 0 |
| talos-smith | 9.5 | 19.2 | 2.2 | 6.4 | 1 | 2 | 5 |
| talos-trinity | -2.7 | 7.6 | 8.6 | 11.2 | 0 | 0 | 3 |

  Across the three nodes that take jobs the total was never below 7, at
  least 10 in 95% of hours, median 17. This is an estimate: it takes each
  pod's request from the hours it was running at least half the hour, which
  overcounts while pods are being replaced (hence the negative figure on
  `talos-trinity`).
- *Room by quota.* `limits.memory=56Gi` is the binding quota. A plain job pod
  carries 4.5 GiB of limits (build 4, helper 0.5), so twelve fit. A job with
  two service containers (Daimyo's tests) carries 8.5 GiB, so six fit. Six
  concurrent jobs cannot exceed the quota; eight can, if most are
  service-heavy. `limits.cpu=56` allows fourteen plain pods; Orion's three
  visual-QA shards take 24 of it.
- *Room by use.* Over seven days the busiest node, `talos-neo`, used 16.9 of
  its 32 cores at the 95th percentile, `talos-smith` 10.7 of 16, and
  `talos-trinity` 8.8 of 16. Job build containers average 0.3 to 1.9 cores.
- *Effect on waiting.* Replaying the week's 4,230 job arrivals and durations
  through a first-come queue: with five slots the total wait falls to
  28% of the four-slot figure, with six to 11%, with eight to 2%. If six
  slots made every job 15% slower through contention, six slots would still
  leave 18%. The model is rough: at four slots it predicts 715 hours of
  waiting where 444 were observed, because it keeps each job's arrival time
  fixed and GitLab does not serve strictly first-come. Read the ratios, not
  the hours.
- *The alternative.* The same replay at four slots without Orion's visual QA
  leaves 33%. Demand is the larger lever, which is why the pipeline changes
  come first.

Why not eight now: the minimum room by requests was 7 pods, the memory-limit
quota allows as few as six service-heavy pods, and `talos-neo` already takes
56% of jobs next to the Coder workspace, where a test gate hit 5-second
timeouts at a load average of 11 to 27 while CI was busy.

Spreading: add a preferred (not required) pod anti-affinity between job pods on
`kubernetes.io/hostname`, so concurrent jobs choose different nodes when they
can. The cost is cache locality: the job cache is per node, so a job is less
likely to land where its cache is warm. That cost is unmeasured. Check it
after the change by counting cache restores in job traces, as was done for
Turmeric's `rust-test` above (23 of 24 today). One data point from this work: two
consecutive runs of Turmeric's `runtime-budget` landed on `talos-trinity` and
then `talos-neo`, and the second found no cache.

`talos-niobe` is in the job affinity list but has taken no job in 14 days
because its memory is 99% requested. Either remove it from the list so the
configuration says what happens, or free memory on it; it is not capacity
today.

The `/ci` cache: no change. The seven-day prune added on 2026-11-19 holds
`talos-neo` above 100 GiB free. A shared object-store cache would remove the
dependence on node placement, but restoring Daimyo's cargo cache already takes
about 55 s from local disk; over the network it would be slower, and nothing
measured here says the trade is worth it.

The change itself, when approved, is two lines in
`tofu/home/kubernetes/gitlab_runner.values.yaml.tftpl` (`replicas: 6`, and the
anti-affinity block), the stale `rust-test` comment corrected, and
`docs/gitlab-k8s-runner.md` updated to match, applied with
`task tofu:apply:gitlab-runner`. Rollback is `replicas: 4`.

## Considered and left alone

- **Splitting Turmeric's `rust-test` into parallel jobs.** Each job starts its
  own Postgres, NATS, ClickHouse and MinIO, so a split is safe, but it buys
  wall-clock only when slots are free and costs slot-minutes (another cache
  restore, compile and service start per job). With the runner saturated it
  would make queues longer.
- **Running Turmeric's test binaries concurrently inside the job.** Unsafe:
  `chaccess/tests/quota.rs` and `isolation.rs` shrink a shared ClickHouse
  quota, `ingest/tests/publish.rs` and `replay_services.rs` delete the shared
  NATS stream, and `restricted_readers.rs` relies on Cargo running binaries one
  at a time.
- **Testing only the crates a merge request touches.** Measured on the 285
  merge-request `rust-test` runs: 67% touched an input that forces the full
  suite (`spec/`, `Cargo.lock`, `sdk/`, the CI file), and for the rest the
  crates are so interdependent that the affected set still carries 98% of the
  test time.
- **One job instead of two for the CI-image prelude** in Turmeric and
  Buyerfact (about 100 and 15 slot-minutes a week plus a queue hop). It needs
  one image holding both a registry-copy tool and Buildah.
- **Daimyo's `cargo build --workspace` job.** `clippy --all-targets` and
  `cargo test --workspace` compile the same code; whether the separate build
  adds anything is a gate question and it stays.
- **Daimyo's `tag-unchanged` job** does not give every `main` commit a complete
  image set: pipeline 13659 (job 53189) logged `no :main yet, skipped` for ten
  image names, and `rubric-grader` is missing from its list. Pre-existing, not
  caused or fixed here.
- **Path filters for docs-only commits.** Daimyo's workflow already skips
  them. Buyerfact runs everything on every merge request on purpose (Cicada
  lands on the pipeline result). Turmeric's merge-request jobs are already
  filtered by path.
- **Failure and retry rates.** GitLab reported no job as retried in the
  window; a failed pipeline is followed by a new push, not a retry. The cost of
  flaky tests therefore shows up as whole extra pipelines: Deskplane's browser
  tests above, and Turmeric's `runtime-budget`, which failed 28 of 211 runs.
  The second was not investigated.

## What went wrong during this work

- **The validation runs flooded the runner.** Six projects' validation
  pipelines were started within a few minutes of each other on four slots.
  Orion release pipeline 15578 had `chart-check` waiting about 13 minutes
  behind them. The pending validation jobs were cancelled, the release
  published, and the jobs were retried afterwards. One validation pipeline at a
  time would have avoided it.
- **Local image builds filled the workstation disk.** The Orion equivalence
  builds and a Rust build took the Mac to 195 MB free. The Docker build cache
  (5.8 GB, all from these builds), the images and the Rust output were removed;
  8.4 GB was free afterwards. The Nix store paths the Cicada dev shell
  downloaded remain.
- **A layer cache was assumed to help and did not** (Orion, above). It cost
  two extra image builds to find out.

## Verified and not verified

Verified by running it: every "after" figure with a job or pipeline number;
the Orion image equivalence (local builds); the Cicada reconciler tests.

Verified by lint only: Orion's `visual-qa` path filter and auto-cancel. They
act on `main`, merge requests and `p<N>/` branches, none of which the
validation branch is.

Estimates: every weekly saving. Each multiplies one or two measured runs by
last week's run counts. The queue replay behind the runner recommendation is
a model that overstates waiting at four slots by 70%.

Not established: whether anything pulls Orion's branch images; the smallest
CPU limit that stops Deskplane's browser job being throttled; how long GitLab
can take to create a merge-request pipeline (the Cicada fix allows ten
seconds); cache hit rates after job pods are spread across nodes.
