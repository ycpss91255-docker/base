#!/usr/bin/env bats
#
# self_test_yaml_spec.bats — structural assertions for the
# `.github/workflows/self-test.yaml` workflow.
#
# Locks three cumulative invariants:
#
# 1. actionlint gate (original): an `actionlint` job runs
#    rhysd/actionlint via Docker against the workflows tree, and the
#    downstream jobs (test / acceptance / system) declare
#    `needs:` on actionlint so they cannot start until actionlint
#    passes.
#
# 2. P1 classifier + buildx GHA cache: a `classify` job emits
#    `code_changed` + `system_relevant` outputs based on PR diff
#    against the doc-only allow-list and system block-list; the
#    `test` job always runs (required check) but short-circuits to
#    SUCCESS on doc-only PRs; `acceptance` + `system` gate
#    via job-level `if:`. All three test-tools image builds use
#    docker/build-push-action with shared `scope=test-tools` GHA cache.
#
# 3. ci-rollup aggregator: a single `ci-rollup` job aggregates
#    [actionlint, classify, test, acceptance, system] under
#    `if: always`, treating SKIPPED as pass-equivalent for the two
#    conditionally-gated jobs (acceptance + system). Branch
#    protection requires only `ci-rollup`, so sub-jobs
#    shellcheck/hadolint, bats-unit/bats-integration) can join
#    its `needs:` without further branch-protection churn.
#
# why: Structural assertions for `.github/workflows/self-test.yaml`. Locks
# fourteen cumulative invariants:
#
# 1. **#305 actionlint gate** — `actionlint` job declared, runs
# `rhysd/actionlint` via Docker pinned to an explicit version (`x.y.z`);
# downstream jobs (`test`, `integration-e2e`, `system`) need it so the
# workflow-validator class of regression that wedged v0.26.0-rc1 (refs #297)
# is caught early.
#
# 2. **#317 P1 classifier + buildx GHA cache** — a `classify` job emits
# `code_changed` + `system_relevant` outputs from PR diff against the
# doc-only allow-list (`doc/**` + `README.md` + `LICENSE`) and system
# block-list (entrypoint.sh + compose + Dockerfile.example/.test-tools +
# wrappers + init/upgrade + `test/bats/system/**` + `.github/workflows/**`);
# the `test` job always runs (required check) but short-circuits to SUCCESS
# on doc-only PRs; `integration-e2e` and `system` gate via job-level `if:`;
# all three test-tools image builds use `docker/build-push-action` with
# shared `scope=test-tools` GHA cache.
#
# 3. **#317 P1 follow-up classifier hardening** — `classify` job is
# fail-open: `set -uo pipefail` (no `-e`) so transient diff/fetch errors
# don't crash the job and wedge every PR via the Q4 fail-closed chain.
# Explicit `git fetch origin` of the base ref with `--depth=200` before diff
# so fork PRs (where `actions/checkout@v6 fetch-depth: 0` only fetches the
# head branch) don't trip on missing `origin/<base>`.
#
# 4. **#317 P2 Obtain step + rolling tag fallback** — each of the 3
# downstream jobs (`test`, `integration-e2e`, `system`) precedes its
# test-tools provisioning with an `Obtain` step implementing the 3-layer
# fallback: PR touched `dockerfile/Dockerfile.test-tools` -> rebuild local;
# else `docker pull ghcr.io/ycpss91255-docker/test-tools:main` and re-tag;
# else fall back to a from-source rebuild. For `test` + `system` (which
# `docker compose run` test-tools), the buildx Build step gates on
# `steps.obtain.outputs.build_local == 'true'` so the hot path skips it and
# the cold path reuses P1's GHA cache. For `integration-e2e` (which `docker
# compose build`, whose `FROM ${TEST_TOOLS_IMAGE}` resolves against the host
# docker daemon), the buildx `driver: docker` override is preserved and the
# rebuild fallback is inlined as plain `docker build` — GHA cache is not
# available on this driver, accepted because the hot path is `docker pull
# :main` and cold path matches pre-P2 cost. `integration-e2e` additionally
# passes `TEST_TOOLS_IMAGE: test-tools:local` to `./build.sh test` so the
# wrapper script skips its own internal test-tools build, reusing the image
# populated by the Obtain step.
#
# 5. **#317 P3 system conditional + block-list expansion** — `system` job's
# job-level `if:` tightens from `code_changed == 'true'` (P1) to
# `system_relevant == 'true'` (the narrower output P1 already emitted but
# didn't consume). PRs that change pure lint / unit-test paths covered by
# `test` now skip the docker.sock-mounted compose run, saving ~3-5 min per
# such PR. The system block-list in `classify` is extended with
# `script/docker/setup.sh` + `script/docker/i18n.sh` +
# `script/docker/lib/**` + `script/docker/prune.sh` (gotcha-5): each affects
# `.env` / `compose.yaml` generation or wrapper behaviour that the compose
# service exercises end-to-end, so they must invalidate the system-skip
# optimization.
#
# 6. **#337 `ci-rollup` aggregator** — a single always-running (`if:
# always()`) `ci-rollup` job sits downstream of every PR check and collapses
# their results into one pass/fail signal that branch protection can
# require. The verifier shell step consumes every `${{ needs.<job>.result
# }}` and applies a 2-tier rule: `actionlint` / `classify` must be
# `success`; conditionally-gated jobs (`shellcheck` / `hadolint` /
# `bats-unit` / `bats-integration` / `coverage` / `integration-e2e` /
# `system`) may be `success` or `skipped` (their job-level `if:`
# legitimately skips on doc-only / non-system PRs per #317 P1/P3, #376,
# #377, #615). Adding sub-jobs (#377) to the rollup's `needs:` list becomes
# a workflow-internal change with no branch-protection update required.
#
# 7. **#376 ShellCheck + Hadolint dedicated jobs** — `shellcheck` runs on
# plain ubuntu-latest with the pre-installed binary (no buildx, no
# test-tools image, ~30s feedback on a regression) via `test.sh
# --shellcheck-only`. `hadolint` uses `hadolint/hadolint-action@v3.1.0` to
# lint `dockerfile/Dockerfile.example` + `dockerfile/Dockerfile.test-tools`
# (both template-owned; downstream Dockerfile.example consumers inherit the
# lint pass). Both gate on `needs.classify.outputs.code_changed == 'true'`
# so doc-only PRs SKIP them. Both join `ci-rollup`'s `needs:` list, and
# `release` also gates on them so a tag with a lint regression doesn't
# publish a Release.
#
# 8. **#377 Bats unit/integration split + Kcov coverage move** — the
# pre-#377 monolithic `test` job is fully removed and replaced by three
# sibling jobs: - `bats-unit` (matrix `shard: ['1/2', '2/2']`, `fail-fast:
# false`): each shard runs a round-robin partition of
# `test/bats/unit/*_spec.bats` via `test.sh --bats-unit-shard ${{
# matrix.shard }}`. Parallel execution drops PR wall-time from ~5min to
# ~2min. - `bats-integration`: runs `test/bats/integration/` via `test.sh
# --bats-integration`. Pulled out of the unit serial path so each unit shard
# sees only its share. - `coverage`: #377 gated it to main pushes only and
# kept it out of `ci-rollup`'s `needs:` (a non-gating metric). **Superseded
# by #615 (invariant 11): coverage is now a sharded kcov PR gate in the
# rollup.** The #377-era posture (main-only `if:`, "NOT in ci-rollup needs")
# is no longer asserted here.
#
# 9. **#579 integration-e2e runnability gate** — the e2e job drives build /
# run / exec / stop through the documented `just` entry points (not raw
# `script/*.sh`, so a broken container-ops justfile is caught) and ASSERTS
# the runnability contract instead of only running the steps: the
# in-container user equals the configured `USER_NAME` (catches the v0.41.0
# user-args `initial` bug), the detached container is still running (catches
# the entrypoint `set -u` insta-exit class), the wired ENTRYPOINT is
# `/entrypoint.sh`, the `~/work` mount is present and writable, and `just
# stop` removes both the container and the compose project network. `just`
# is installed via the `extractions/setup-just` action.
#
# `ci-rollup needs:` is `[actionlint, classify, shellcheck, hadolint,
# bats-unit, bats-integration, coverage, integration-e2e, system]` (9 jobs
# post-#615) — every PR-check job. `release needs:` updates from
# `[shellcheck, hadolint, test, integration-e2e, system]` → `[shellcheck,
# hadolint, bats-unit, bats-integration, integration-e2e, system]`.
# Post-#377 only `actionlint` + `classify` are hard-mandatory in
# `ci-rollup`'s verifier (the always-running `test` job no longer exists).
#
# 10. **#603 native arm64 e2e matrix** — `integration-e2e` runs as a static
# 2-entry `strategy.matrix` (`linux/amd64` -> `ubuntu-latest`, `linux/arm64`
# -> `ubuntu-24.04-arm`) with `fail-fast: false`, so the #579 runnability
# contract is verified on both arches via native runners (no QEMU),
# mirroring the platform->runner convention of build-worker / publish-worker
# / release-test-tools (#587). The job `runs-on: ${{ matrix.runner }}` and
# the Obtain step pulls `test-tools:main` for `${{ matrix.platform }}`
# (multi-arch post-#587) so the arm64 shard gets the arm64 variant.
# `ci-rollup` aggregates through `needs.integration-e2e.result` unchanged.
#
# 11. **#615 sharded kcov + coverage as an enforced PR gate (amends #377,
# ADR-00000008)** — `coverage` is no longer the #377 main-only metric. It
# now (a) runs as a kcov `strategy.matrix` (`shard: ['1/4', '2/4', '3/4',
# '4/4']`, `fail-fast: false`) MIRRORING the `bats-unit` matrix via `test.sh
# --coverage-shard ${{ matrix.shard }}` — each shard kcov's the same
# round-robin unit slice the unit-test matrix runs (integration on the last
# shard); (b) gates on `needs.classify.outputs.code_changed == 'true'` so it
# runs on PRs (not just main push); and (c) joins `ci-rollup`'s `needs:` +
# the verifier consumes `needs.coverage.result` (SKIPPED-as-pass for
# doc-only PRs), so a kcov failure blocks PR merge. The old `if: push && ref
# == refs/heads/main` and the "NOT in ci-rollup needs" posture are gone.
#
# > #710 self-hosted amendment: the per-shard external-SaaS upload + the >
# SaaS `project` branch-protection status are REMOVED (the repo moves to > a
# GitLab where that SaaS is unavailable and uploading coverage leaks >
# data). Each shard instead uploads its kcov report as a CI ARTIFACT >
# (`actions/upload-artifact`, keyed by `strategy.job-index`); a new >
# `coverage-gate` job downloads every shard artifact and runs >
# `script/test/drivers/coverage_gate.sh`, which MERGES the per-shard >
# cobertura reports into one line-weighted project rate and fails below >
# `COVERAGE_MIN`. `coverage-gate` joins `ci-rollup`'s `needs:`, so the >
# floor gates merge with no external SaaS. The gate script is asserted > in
# `coverage_gate_spec.bats`.
#
# 12. **#697 / #947 / #948 probe-and-rebuild against a `:main` that is not
# this checkout's** — CI rebuilds the tooling image only for a PR that
# touches `dockerfile/Dockerfile.test-tools`; every other PR pulls the
# rolling `:main`, which is republished only by a push to main touching that
# same file. Two ways the pulled image can fail to correspond to the
# checkout, and only one is loud. ABSENT: `release-test-tools` republishes
# concurrently with this workflow, so an Obtain step can fetch a
# pre-new-tool image (e.g. pre-kcov) mid-flight and the coverage shards
# fast-fail with `kcov: command not found`. STALE: the tool is present at
# the version the pin used to name — `shellcheck` / `hadolint` are lint
# GATES, so an older rule set does not fail, it under-reports, and the green
# check has examined something other than what the checkout asked for, while
# a `just` older than `ARG JUST_VERSION` reddens
# `test/bats/integration/just_runner_version_spec.bats` on a PR that touched
# nothing related. After the pull + `docker tag`, every `:main`-pulling
# Obtain step therefore runs `script/ci/probe_test_tools.sh`, which requires
# every tool in `REQUIRED_TOOLS` to be present AND every tool in
# `PINNED_TOOLS` to report the version this checkout pins (the two linters
# out of their release URLs in the Dockerfile, the runner through
# `dist/script/base/just-version.sh` — never restated). On any refusal it
# emits `build_local=true` so the existing buildx Build step rebuilds from
# `dockerfile/Dockerfile.test-tools` — self-correcting whatever the cause,
# with layer-1 (PR touched Dockerfile -> build) and layer-3 (pull failed ->
# build) intact. Applied to the five `build_local`-pattern obtain steps
# (`hadolint`, `bats-fragile`, `bats-integration`, `coverage`, `system`)
# since they pull the same tag and race identically, and asserted per job.
# The sixth `:main`-pulling step, `acceptance`, carries no probe and needs
# none: the probe is about the tools a job EXECUTES, and acceptance runs
# none of them -- it consumes the image only as the `FROM` base of the
# scaffolded consumer's test stage. It is ONE script rather than a loop
# pasted into each step because five copies is how the version blind spot
# survived: each copy asked `command -v` and none of them looked wrong. The
# guard used to be a `grep -c` == 5 over the whole workflow under the name
# "every `:main`-pulling Obtain step", which named an invariant that did not
# hold (there are six such steps) and was satisfied by any five occurrences
# wherever they sat.
#
# 13. **#677 CI double-run restructure (coverage = primary unit gate,
# weight-balanced shards, single `bats-fragile` job)** — after #686 unified
# the coverage job onto the same Alpine test-tools image, the 4-shard
# `bats-unit` matrix and the 4-shard `coverage` matrix ran the SAME ~1991
# unit specs twice per PR (8 parallel jobs), differing only by `COVERAGE=1`.
# The restructure: (a) the `coverage` matrix stays the PRIMARY unit gate
# (kcov over every non-fragile test; codecov upload + the #615/ADR-00000008
# project gate untouched); (b) the `bats-unit` matrix is replaced by a
# SINGLE `bats-fragile` job that runs ONLY the kcov-fragile specs the
# coverage matrix skips via `[ "${COVERAGE:-0}" = 1 ] && skip` — in PLAIN
# mode, so the delta is preserved with zero double-run. The fragile set is
# computed at RUNTIME (`test.sh --bats-fragile` -> `_fragile_unit_files`
# greps a line-anchored skip guard), so a new fragile-skip in a 10th file is
# picked up automatically; (c) `_shard_unit_files` replaces round-robin with
# greedy bin-packing by per-spec `@test` count (heaviest-first into the
# lightest shard) so the slowest coverage shard approaches `total/N`.
# `ci-rollup needs:` and `release needs:` swap `bats-unit` ->
# `bats-fragile`; `coverage` joins the `release` chain (it is now the
# primary unit gate). Every unit test still runs SOMEWHERE: non-fragile
# under coverage/kcov, the fragile files under `bats-fragile` (plain).
#
# 14. **#1009 the gate rosters are DERIVED from the job graph** — every
# assertion above about a `needs:` list named the roster it checked, so the
# roster and the assertion were two hand-kept copies of the same thing and
# adding a job updated neither. Three guards now read the roster out of the
# file instead: every job the workflow declares is named DIRECTLY in
# `ci-rollup`'s `needs:` (directly, because `if: always()` means it can only
# see its own needs, and a job reached through a failed one arrives as
# SKIPPED, which the tolerant bucket passes); every job `ci-rollup` needs is
# bound to a `*_RESULT` and compared in EXACTLY ONE of the two result loops
# (a needed job nothing compares is waited for and ignored); and `release`'s
# transitive `needs:` closure equals the set `ci-rollup` names, since the
# tag path does not go through `ci-rollup`. The two defects that motivated
# this land with it: `compute-shards` joins `ci-rollup` in the STRICT loop,
# and `coverage-gate` joins `release`'s `needs:` so a tag cannot cut a
# Release below `COVERAGE_MIN`. Because the roster prose in this blurb is
# hand-kept in exactly the way the guards forbid, the file -- not this
# paragraph -- is now the record of who needs whom.
#
# Grouped by concern:
#
# - `actionlint` job declared
#
# - `actionlint` step uses `rhysd/actionlint:<pinned-version>` Docker image
#
# - `classify` job declared with `code_changed` + `system_relevant` outputs
#
# - `classify` doc-only allow-list + system block-list + non-PR default
#
# - `bats-fragile`/`bats-integration`/`integration-e2e`/`system` declare
# `needs: [actionlint, classify]`
#
# - `bats-fragile`/`bats-integration` job-level `if: code_changed == 'true'`
# + no remaining monolithic `test:` job (#377, #677)
#
# - `integration-e2e` job-level `if: code_changed == 'true'` + `system`
# job-level `if: system_relevant == 'true'` (#317 P3 tightens)
#
# - `bats-fragile`/`bats-integration`/`system` use
# `docker/build-push-action@v6` with `scope=test-tools` GHA cache
#
# - `classify` fail-open (`set -uo pipefail`) + pre-fetch base ref (#317
# gotcha-1/2)
#
# - `bats-fragile` Obtain step pulls `:main` with 3-layer fallback + Build
# step gated on `build_local` (#317 P2 + #677)
#
# - `bats-integration` Obtain step + 3-layer fallback (#317 P2 + #377)
#
# - `integration-e2e` Obtain step + `TEST_TOOLS_IMAGE` env passthrough + no
# `driver: docker` pin (#317 P2)
#
# - `integration-e2e` native arm64 matrix (#603): amd64+arm64 native-runner
# matrix with `fail-fast: false`; shards `runs-on: ${{ matrix.runner }}`;
# Obtain pulls the matrix platform
#
# - `system` Obtain step with 3-layer fallback (#317 P2)
#
# - Obtain steps pre-fetch base ref (5 occurrences post-#377: classify + 4
# jobs, #317 P2 reuses P1 gotcha-2 fix)
#
# - `classify` system block-list extends to `setup.sh` + `i18n.sh` +
# `lib/**` + `prune.sh` (#317 P3 gotcha-5)
#
# - `ci-rollup` declared + `needs: [actionlint, classify, shellcheck,
# hadolint, bats-fragile, bats-integration, coverage, coverage-gate,
# integration-e2e, system]` + `if: always()` (#337 + #376 + #377 + #615 +
# #677 + #710)
#
# - `ci-rollup` DOES need `coverage` now (#615 amends #377)
#
# - `ci-rollup` verify step consumes every `needs.<job>.result` incl
# `coverage` + `coverage-gate` + SKIPPED treated as pass for conditional
# jobs + `success` required for hard-mandatory jobs (#337 + #376 + #377 +
# #615 + #677 + #710)
#
# - `shellcheck` job declared + `needs: [actionlint, classify]` + `if:
# code_changed == 'true'` + runs `test.sh --shellcheck-only` on plain
# ubuntu-latest with no buildx (#376)
#
# - `doc-counts` job declared + `needs: [actionlint, classify]` + runs
# `test.sh --doc-counts-only` on plain ubuntu-latest with no buildx +
# carries NO `code_changed` gate + is hard-mandatory in `ci-rollup` (#864)
#
# - `hadolint` job declared + `needs: [actionlint, classify]` + `if:
# code_changed == 'true'` + lints both template-owned Dockerfiles via
# `hadolint-action` (#376)
#
# - `bats-fragile` declared + is a single job (no shard matrix) + invokes
# `test.sh --bats-fragile` + no `bats-unit` matrix remains (#677)
#
# - `bats-integration` declared + invokes `test.sh --bats-integration`
# (#377)
#
# - `coverage` declared (#377) + runs on PRs via `if: code_changed ==
# 'true'` (not main-only) + primary kcov unit gate over `matrix.shard:
# ['1/4'..'4/4']` (greedy weight-balanced) + invokes `test.sh
# --coverage-shard ${{ matrix.shard }}` + uploads each shard report as a CI
# artifact (#615 + #677 + #710)
#
# - Self-hosted coverage (#710): NO codecov reference anywhere in the
# workflow + a `coverage-gate` job downloads the shard artifacts and runs
# `coverage_gate.sh`
#
# - `release` job needs `[shellcheck, hadolint, bats-fragile,
# bats-integration, coverage, integration-e2e, system]` before publishing a
# tag (#376 + #377 + #677)
#
# - Probe-and-rebuild against a stale/racing `:main`: `bats-fragile` +
# `coverage` Obtain probe for kcov and rebuild on a miss + `REQUIRED_TOOLS`
# list is extensible + all five `build_local` obtain steps carry the guard
# (#697)

# Assertions here read the workflow's CODE, via the comment-stripped views
# in test_helper.bash (code_grep / yaml_job_lines / yaml_top_lines) rather
# than the raw file. self-test.yaml is a heavily commented file whose prose
# names the very mechanisms this spec pins -- `docker tag`, `~/work`,
# `skipped` -- so a whole-file read is satisfied by the explanation of a
# thing instead of the thing. Where an assertion IS about the prose, it says
# so by reading yaml_job_text / _job_comments instead.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WF="/source/.github/workflows/self-test.yaml"
  assert_spec_subject "${WF}" \
      "base's own CI workflow this spec pins"
}

# _render_run_names <run_id> <run_attempt>
#
# Prints the workflow-level `env:` block as `KEY: VALUE` lines with the
# run-identity expressions resolved to the given identity. This is what
# lets a spec compare TWO runs of the same commit -- the thing a
# single-tenant GitHub-hosted runner can never exhibit, because nothing
# there shares a machine. Comment lines and blank lines are dropped so the
# comparison is over values only.
_render_run_names() {
  local _run_id="${1}" _attempt="${2}"
  yaml_top_lines "${WF}" env \
    | grep -E '^  [A-Za-z_][A-Za-z0-9_]*:' \
    | sed -e "s/\${{ *github\.run_id *}}/${_run_id}/g" \
          -e "s/\${{ *github\.run_attempt *}}/${_attempt}/g"
}

# _job_comments <job> -- the comment lines of one job block: the mirror of
# yaml_job_lines, for the rare assertion that is genuinely about what the
# workflow SAYS rather than what it does.
_job_comments() {
  yaml_job_text "${WF}" "${1}" | only_comments
}

# ── actionlint job declared ────────────────────────────────────

@test "self-test.yaml: declares actionlint job" {
  run code_grep -E '^  actionlint:' "${WF}"
  assert_success
}

@test "self-test.yaml: actionlint job runs rhysd/actionlint via Docker with pinned tag" {
  run code_grep -E 'rhysd/actionlint:[0-9]+\.[0-9]+\.[0-9]+' "${WF}"
  assert_success
}

# ── classify job declared with both outputs ────────────────────

@test "self-test.yaml: declares classify job (#317)" {
  run code_grep -E '^  classify:' "${WF}"
  assert_success
}

@test "self-test.yaml: classify job declares code_changed output (#317)" {
  run yaml_job_lines "${WF}" classify
  assert_success
  assert_output --partial 'code_changed: ${{ steps.diff.outputs.code_changed }}'
}

@test "self-test.yaml: classify job declares system_relevant output (#317)" {
  run yaml_job_lines "${WF}" classify
  assert_success
  assert_output --partial 'system_relevant: ${{ steps.diff.outputs.system_relevant }}'
}

@test "self-test.yaml: classify uses doc-only allow-list 'doc/**' + 'README.md' + 'LICENSE' + 'CONTEXT.md' (#317)" {
  run yaml_job_lines "${WF}" classify
  assert_success
  assert_output --partial "':!doc/**'"
  assert_output --partial "':!README.md'"
  assert_output --partial "':!LICENSE'"
  # CONTEXT.md is tracked at the repo root (domain glossary, pure docs) but is
  # not under doc/, so without this it would trip code_changed=true and run the
  # full suite for a glossary-only change.
  assert_output --partial "':!CONTEXT.md'"
}

@test "self-test.yaml: classify uses system block-list entrypoint + compose + Dockerfile + wrappers + init/upgrade + workflows (#317)" {
  run yaml_job_lines "${WF}" classify
  assert_success
  assert_output --partial "'script/entrypoint.sh'"
  assert_output --partial "'compose.yaml'"
  assert_output --partial "'dist/dockerfile/Dockerfile'"
  assert_output --partial "'dockerfile/Dockerfile.test-tools'"
  assert_output --partial "'dist/script/docker/wrapper/build.sh'"
  assert_output --partial "'dist/script/docker/wrapper/run.sh'"
  assert_output --partial "'dist/script/docker/wrapper/exec.sh'"
  assert_output --partial "'dist/script/docker/wrapper/stop.sh'"
  assert_output --partial "'test/bats/system/**'"
  assert_output --partial "'dist/script/base/init.sh'"
  assert_output --partial "'dist/script/base/upgrade.sh'"
  assert_output --partial "'.github/workflows/**'"
}

@test "self-test.yaml: classify defaults code_changed/system_relevant to true on non-PR events (#317)" {
  run yaml_job_lines "${WF}" classify
  assert_success
  # Both outputs branch to 'true' when EVENT_NAME != pull_request
  assert_output --partial '!= "pull_request"'
  assert_output --partial 'code_changed=true'
  assert_output --partial 'system_relevant=true'
}

@test "self-test.yaml: classify omits set -e to fail-open on diff errors (#317 gotcha-1)" {
  # The classifier must not abort the job on diff/fetch failure — the
  # `test` job needs classify as a gate, and aborting here would block all
  # PR merges (Q4 fail-closed chain). Verify `set -e` is not in effect by
  # asserting `set -uo pipefail` (not `set -euo pipefail`) is used.
  run yaml_job_lines "${WF}" classify
  assert_success
  assert_output --partial 'set -uo pipefail'
  refute_output --partial 'set -euo pipefail'
}

@test "self-test.yaml: classify pre-fetches base ref before diff (#317 gotcha-2)" {
  # actions/checkout `fetch-depth: 0` fetches the head branch's full
  # history but NOT the base ref. Fork PRs (and some squash-merged
  # histories) start without `origin/<base>` present locally; the
  # classifier must pre-fetch it explicitly, with failure being non-fatal
  # so the diff fall-through can still take over.
  run yaml_job_lines "${WF}" classify
  assert_success
  assert_output --partial 'git fetch origin'
  assert_output --partial '"${BASE_REF}:refs/remotes/origin/${BASE_REF}"'
  assert_output --partial '|| true'
}

# ── Downstream jobs gate on actionlint + classify ─

@test "self-test.yaml: bats-fragile job declares needs on actionlint AND classify (#677)" {
  run yaml_job_lines "${WF}" bats-fragile
  assert_success
  assert_output --partial 'needs: [actionlint, classify]'
}

@test "self-test.yaml: bats-integration job declares needs on actionlint AND classify (#377)" {
  run yaml_job_lines "${WF}" bats-integration
  assert_success
  assert_output --partial 'needs: [actionlint, classify]'
}

@test "self-test.yaml: acceptance job declares needs on actionlint AND classify (#317)" {
  run yaml_job_lines "${WF}" acceptance
  assert_success
  assert_output --partial 'needs: [actionlint, classify]'
}

@test "self-test.yaml: acceptance drives the container via just, not raw script/*.sh (#579)" {
  # A3: exercise the documented `just` entry points so a broken
  # container-ops justfile is caught (the user entry is just).
  run yaml_job_lines "${WF}" acceptance
  assert_success
  assert_output --partial 'just docker build'
  assert_output --partial 'just docker run -d'
  assert_output --partial 'just docker exec'
  assert_output --partial 'just docker stop'
  refute_output --partial './script/build.sh'
  refute_output --partial './script/run.sh'
  refute_output --partial './script/stop.sh'
}

@test "self-test.yaml: acceptance asserts the runnability contract (#579)" {
  # A1: the job must ASSERT results, not just run steps. Covers the
  # five-point contract: configured user (not initial/root), container
  # still running, wired ENTRYPOINT, usable workspace mount, and full
  # teardown (container + project network) on stop.
  #
  # The mount probe is asserted by the path the step actually builds, not
  # by the tilde form: `~` never appears in this job's code -- `just docker
  # exec` takes per-call argv, so the step spells the mount absolutely.
  # `~/work` occurs exactly once in the whole workflow, in the comment that
  # introduces point (4), which is what made the old assertion vacuous.
  run yaml_job_lines "${WF}" acceptance
  assert_success
  assert_output --partial 'USER_NAME'
  assert_output --partial '/entrypoint.sh'
  assert_output --partial 'work="/home/${USER_NAME}/work"'
  assert_output --partial 'just docker exec test -d "${work}"'
  assert_output --partial '_default'
}

# why: The acceptance job's `.Path` check is a runnability assertion only
# while the literal it compares against is the one the template's ENTRYPOINT
# names. Reading BOTH here, rather than remembering one, is what makes a
# move of the entry point fail in the local gate instead of on the CI-only
# acceptance matrix that `just test` cannot see
@test "self-test.yaml: acceptance pins the entry point the shipped Dockerfile wires (#945)" {
  # The `.Path` check is only a runnability assertion while the literal it
  # compares against is the literal the template's ENTRYPOINT names. Both
  # halves are read here rather than one of them remembered: base owns the
  # entry point (ADR-00000032), so moving it has to fail in the local gate
  # instead of on the acceptance matrix, which `just test` cannot see.
  local _wired
  _wired="$(sed -nE 's/^ENTRYPOINT \["([^"]+)".*/\1/p' \
    /source/dist/dockerfile/Dockerfile | head -n1)"
  [[ -n "${_wired}" ]] || fail "no uncommented ENTRYPOINT in the shipped Dockerfile"
  run yaml_job_lines "${WF}" acceptance
  assert_success
  assert_output --partial "\"\${path}\" != \"${_wired}\""
}

@test "self-test.yaml: acceptance exercises the remaining downstream just commands for real (#769)" {
  # Beyond the build/run -d/exec/stop core, the e2e must run each remaining
  # downstream verb with REAL execution (not --dry-run): the foreground run
  # variant, start (build + run), a real prune, an explicit setup re-run,
  # the base update check, and the base completions installer.
  run yaml_job_lines "${WF}" acceptance
  assert_success
  assert_output --partial 'just docker run id -un'
  assert_output --partial 'just docker start'
  assert_output --partial 'just docker prune --networks'
  assert_output --partial 'just docker setup apply'
  assert_output --partial 'just base update'
  assert_output --partial 'just base completions install'
}

@test "self-test.yaml: acceptance drives `just template new` end-to-end and asserts the consumer artifact (#785)" {
  # Coverage gap: new.sh is unit-tested in isolation,
  # but the `just template new <name>` RECIPE -- the template module
  # wiring + the consumer symlink chain that resolves it -- is exercised
  # nowhere. The acceptance job drives the REAL recipe in the scaffolded
  # consumer and asserts the produced consumer artifact
  # (script/local/<name>/ + its registration), i.e. from the consumer's
  # chair (UAT). Placed here, not as a bats spec, because a faithful
  # exercise needs the init.sh-scaffolded consumer this job already builds.
  run yaml_job_lines "${WF}" acceptance
  assert_success
  assert_output --partial 'just template new'
  assert_output --partial 'script/local/'
}

@test "self-test.yaml: acceptance documents setup-tui as intentionally out of scope (#769)" {
  # setup-tui is interactive (TUI); it stays covered by tui_spec and is
  # NOT driven for real in the e2e. The job must say so, and must not try
  # to invoke it.
  #
  # The two halves read different streams on purpose. "Says so" is a claim
  # about the PROSE, so it is asserted over the job's comment lines -- the
  # one shape where a comment is the right subject. "Does not invoke it" is
  # a claim about what the job RUNS, so it is asserted over the code lines;
  # over the whole block the refutation would be broken by the very comment
  # the first half demands.
  run _job_comments acceptance
  assert_success
  assert_output --partial 'setup-tui'
  run yaml_job_lines "${WF}" acceptance
  assert_success
  refute_output --partial 'just docker setup-tui'
}

@test "self-test.yaml: acceptance runs as a native-runner matrix over amd64 + arm64 (#603)" {
  # A2: verify the runnability contract on BOTH arches via native
  # runners (no QEMU), mirroring the platform->runner convention in
  # build-worker / publish-worker / release-test-tools.
  run yaml_job_lines "${WF}" acceptance
  assert_success
  assert_output --partial 'fail-fast: false'
  assert_output --partial 'linux/amd64'
  assert_output --partial 'ubuntu-latest'
  assert_output --partial 'linux/arm64'
  assert_output --partial 'ubuntu-24.04-arm'
}

@test "self-test.yaml: acceptance shards run on the matrix runner (#603)" {
  run yaml_job_lines "${WF}" acceptance
  assert_success
  assert_output --partial 'runs-on: ${{ matrix.runner }}'
}

@test "self-test.yaml: acceptance Obtain step pulls the matrix platform, not a hardcoded amd64 (#603)" {
  # On the arm64 shard the test-tools:main pull must fetch the arm64
  # variant (test-tools is multi-arch); a hardcoded
  # linux/amd64 would resolve the wrong arch for the downstream
  # FROM ${TEST_TOOLS_IMAGE} build.
  run yaml_job_lines "${WF}" acceptance
  assert_success
  assert_output --partial 'docker pull --platform ${{ matrix.platform }}'
  refute_output --partial 'docker pull --platform linux/amd64'
}

@test "self-test.yaml: system job declares needs on actionlint AND classify (#317)" {
  run yaml_job_lines "${WF}" system
  assert_success
  assert_output --partial 'needs: [actionlint, classify]'
}

# ── Conditional gating ───────────────────────────────────

@test "self-test.yaml: bats-fragile job-level if: gates on code_changed (#677)" {
  # bats-fragile replaces the bats-unit matrix; same job-level skip so
  # ci-rollup's SKIPPED=pass rule keeps doc-only PRs merge-able.
  run yaml_job_lines "${WF}" bats-fragile
  assert_success
  assert_output --partial "if: needs.classify.outputs.code_changed == 'true'"
}

@test "self-test.yaml: bats-integration job-level if: gates on code_changed (#377)" {
  run yaml_job_lines "${WF}" bats-integration
  assert_success
  assert_output --partial "if: needs.classify.outputs.code_changed == 'true'"
}

@test "self-test.yaml: no monolithic `test:` job remains after #377 split" {
  # a `test` job ran shellcheck + bats sequentially.
  # peeled shellcheck out, splits the rest into bats-unit
  # (matrix) + bats-integration. The old job is fully removed.
  run code_grep -E '^  test:' "${WF}"
  assert_failure
}

@test "self-test.yaml: acceptance job-level if: gates on code_changed (#317)" {
  run yaml_job_lines "${WF}" acceptance
  assert_success
  assert_output --partial "if: needs.classify.outputs.code_changed == 'true'"
}

@test "self-test.yaml: system job-level if: gates on system_relevant (#317 P3)" {
  # P1 shipped this with `code_changed` while the system_relevant
  # output was emitted-but-unused; P3 tightens to the narrower output so
  # PRs that change pure lint / unit-test paths (already covered by
  # `test`) don't burn the docker.sock-mounted compose run.
  run yaml_job_lines "${WF}" system
  assert_success
  assert_output --partial "if: needs.classify.outputs.system_relevant == 'true'"
  refute_output --partial "if: needs.classify.outputs.code_changed == 'true'"
}

@test "self-test.yaml: classify system block-list extends to setup.sh + i18n.sh + lib/** + prune.sh (#317 P3 gotcha-5)" {
  # setup.sh / lib/** drive .env + compose.yaml generation; i18n.sh
  # gates wrapper message output (smoke regressions surface in compose
  # logs); prune.sh is part of the wrapper family. All four indirectly
  # affect what the docker.sock-mounted compose service does, so they
  # must invalidate the system-skip optimization.
  run yaml_job_lines "${WF}" classify
  assert_success
  assert_output --partial "'dist/script/docker/wrapper/setup.sh'"
  assert_output --partial "'dist/script/docker/lib/i18n.sh'"
  assert_output --partial "'dist/script/docker/lib/**'"
  assert_output --partial "'dist/script/docker/wrapper/prune.sh'"
}

# why: A PR touching only `script/ci/**` or the build-worker fixture would
# otherwise skip the System self-test that consumes them -- and since the
# system job now picks its image via `script/ci/probe_test_tools.sh`, the
# directory is listed rather than the one subdirectory, so the next CI
# script cannot land outside the gate by omission
@test "self-test.yaml: classify system block-list covers the CI scripts + self-test fixture (#802, #947)" {
  # The worker-selftest job consumes script/ci/build_worker/** (its YAML
  # plumbing / output contract) and builds test/fixtures/build-worker/**, so
  # a PR touching ONLY those -- without a .github/workflows/** change -- must
  # still flip system_relevant=true and re-run the System self-test instead
  # of skipping it.
  #
  # The whole of script/ci/, not the worker subdirectory alone: the system
  # job now decides WHICH IMAGE it runs in via script/ci/probe_test_tools.sh,
  # so that script's behaviour is as load-bearing for it as the worker's is
  # for worker-selftest. Listing the directory rather than each file is what
  # keeps the next CI script from landing outside the gate by omission.
  run yaml_job_lines "${WF}" classify
  assert_success
  assert_output --partial "'script/ci/**'"
  assert_output --partial "'test/fixtures/build-worker/**'"
}

# ── buildx GHA cache on test-tools builds ────────────────
#
# These three assert the ACTION and its cache wiring, not the ref. The
# ref used to be spelled here as `@v6`, in three copies, which made a
# major bump a hand-edit in three test files as well as the workflow --
# and pinned only three of the eleven call sites, so the eight it did
# not name are how the tree ended up running v6 and v7 at once. Which
# ref they carry is the action-ref-agreement lint's question now, asked
# over every call site at once.

@test "self-test.yaml: bats-fragile job uses docker/build-push-action with GHA cache scope=test-tools (#677)" {
  run yaml_job_lines "${WF}" bats-fragile
  assert_success
  assert_output --partial 'uses: docker/build-push-action@'
  assert_output --partial 'cache-from: type=gha,scope=test-tools'
  assert_output --partial 'cache-to: type=gha,scope=test-tools,mode=max'
}

@test "self-test.yaml: bats-integration job uses docker/build-push-action with GHA cache scope=test-tools (#377)" {
  run yaml_job_lines "${WF}" bats-integration
  assert_success
  assert_output --partial 'uses: docker/build-push-action@'
  assert_output --partial 'cache-from: type=gha,scope=test-tools'
  assert_output --partial 'cache-to: type=gha,scope=test-tools,mode=max'
}

@test "self-test.yaml: system job uses docker/build-push-action with GHA cache scope=test-tools (#317)" {
  run yaml_job_lines "${WF}" system
  assert_success
  assert_output --partial 'uses: docker/build-push-action@'
  assert_output --partial 'cache-from: type=gha,scope=test-tools'
  assert_output --partial 'cache-to: type=gha,scope=test-tools,mode=max'
}

# ── P2: Obtain step + rolling tag fallback ──────────────────────

@test "self-test.yaml: bats-fragile job has Obtain step pulling :main with 3-layer fallback (#317 P2 + #677)" {
  # The re-tag is a one-line `FROM ... LABEL ...` build, NOT `docker tag`:
  # the pulled image has to carry this run's ownership label so reclaim can
  # tell whose it is, and `docker tag` cannot add a label. The step's own
  # comment says exactly that, in the words `docker tag` -- which is why the
  # old `--partial 'docker tag'` here asserted nothing: all six occurrences
  # of the string in this workflow are inside that one comment, repeated per
  # job, and none is code. Both halves are pinned against the code lines:
  # the mechanism that IS used, and the one that must not come back.
  run yaml_job_lines "${WF}" bats-fragile
  assert_success
  assert_output --partial 'Obtain the run-scoped test-tools image'
  assert_output --partial 'docker pull --platform linux/amd64'
  assert_output --partial 'ghcr.io/ycpss91255-docker/test-tools:main'
  assert_output --partial 'LABEL base.ci.run=%s'
  assert_output --partial 'docker build -q -t "${TEST_TOOLS_IMAGE}" -'
  refute_output --partial 'docker tag'
  assert_output --partial 'build_local=true'
  assert_output --partial 'build_local=false'
}

@test "self-test.yaml: bats-fragile Build step is gated on steps.obtain.outputs.build_local == 'true' (#317 P2 + #677)" {
  run yaml_job_lines "${WF}" bats-fragile
  assert_success
  assert_output --partial "steps.obtain.outputs.build_local == 'true'"
}

@test "self-test.yaml: bats-integration job has Obtain step + 3-layer fallback (#317 P2 + #377)" {
  run yaml_job_lines "${WF}" bats-integration
  assert_success
  assert_output --partial 'Obtain the run-scoped test-tools image'
  assert_output --partial 'ghcr.io/ycpss91255-docker/test-tools:main'
  assert_output --partial 'build_local=true'
  assert_output --partial 'build_local=false'
}

@test "self-test.yaml: acceptance job has Obtain step + TEST_TOOLS_IMAGE env passthrough (#317 P2)" {
  run yaml_job_lines "${WF}" acceptance
  assert_success
  assert_output --partial 'Obtain the run-scoped test-tools image'
  assert_output --partial 'ghcr.io/ycpss91255-docker/test-tools:main'
  # The value itself now comes from the workflow-level env block every job
  # inherits, so build.sh still skips its internal test-tools build
  # without the job restating a literal tag of its own.
  assert_output --partial '${TEST_TOOLS_IMAGE}'
}

@test "self-test.yaml: acceptance job keeps buildx driver: docker for host-daemon visibility (#317 P2)" {
  # `./build.sh test` -> `docker compose build` whose `FROM
  # ${TEST_TOOLS_IMAGE}` resolves against the host docker daemon, not
  # against buildx's docker-container store. Keep the docker driver
  # so `docker pull :main` + `docker tag` land where the subsequent
  # build can see them. Trade-off: layer-3 fallback rebuild here is
  # uncached (GHA cache requires docker-container), accepted because
  # the hot path is `docker pull :main` and the cold path matches
  # pre-P2 cost.
  run yaml_job_lines "${WF}" acceptance
  assert_success
  assert_output --partial 'driver: docker'
}

@test "self-test.yaml: system job has Obtain step with 3-layer fallback (#317 P2)" {
  run yaml_job_lines "${WF}" system
  assert_success
  assert_output --partial 'Obtain the run-scoped test-tools image'
  assert_output --partial 'ghcr.io/ycpss91255-docker/test-tools:main'
  assert_output --partial 'build_local=true'
  assert_output --partial 'build_local=false'
}

# ── Probe-and-rebuild against a stale / racing :main ────────────

# why: Named per job rather than counted: the fragile shard is one of the
# five that RUN the baked tools, so a `:main` that does not correspond to
# this checkout has to send it to a local rebuild, not into the suite
@test "self-test.yaml: bats-fragile Obtain probes the pulled :main and rebuilds on a miss (#697, #947)" {
  # release-test-tools republishes :main on a Dockerfile.test-tools change
  # concurrently with this run, so a freshly-baked tool (kcov) can be
  # absent from the :main we just pulled. After the pull+tag, the obtain
  # step must PROBE the image and, on a miss, fall back to building
  # locally (build_local=true) instead of running the suite against it.
  run yaml_job_lines "${WF}" bats-fragile
  assert_success
  assert_output --partial 'script/ci/probe_test_tools.sh'
  assert_output --partial 'build_local=true'
}

# why: The coverage shards are the ones that actually raced -- the
# kcov-not-found fast-fail is the incident this guard was written after --
# and they are also the job whose numbers a wrong alpine series quietly
# changes, so their obtain step is pinned on its own
@test "self-test.yaml: coverage Obtain probes the pulled :main and rebuilds on a miss (#697, #947)" {
  # The coverage shards are the ones that actually race (kcov-not-found
  # fast-fail). Same probe-and-rebuild guard as bats-fragile so a stale
  # :main self-corrects to a local rebuild.
  run yaml_job_lines "${WF}" coverage
  assert_success
  assert_output --partial 'script/ci/probe_test_tools.sh'
  assert_output --partial 'build_local=true'
}

# why: Keeps the copies from growing back: five inline copies of the loop
# is how the presence-only blind spot survived, because no single copy
# looked wrong, and a re-inlined loop is invisible to the probe's own spec
@test "self-test.yaml: the probe is ONE script, not a loop copied into every job (#947)" {
  # The probe used to be ~12 lines of inline bash repeated across five
  # obtain steps. Five copies is how the guard grew a blind spot nobody
  # could see from any one of them: each asked `command -v <tool>` --
  # presence, never version -- so a :main whose linters predate this
  # checkout's pins passed all five. The logic now lives in one script
  # with its own unit spec (probe_test_tools_spec.bats), and this test
  # keeps a copy from growing back beside it.
  run code_grep 'command -v ' "${WF}"
  assert_failure
  run code_grep 'REQUIRED_TOOLS=' "${WF}"
  assert_failure
}

@test "self-test.yaml: every job that RUNS the baked tools probes the pulled :main for them (#697)" {
  # The five build_local-pattern obtain steps (hadolint, bats-fragile,
  # bats-integration, coverage, system) pull the same :main tag and race
  # identically; each must probe + rebuild on a miss.
  #
  # Named per job, not counted. An earlier form asserted a
  # `grep -c` equal to 5 over the whole workflow, which is satisfied by
  # ANY five occurrences: deleting hadolint's guard and double-listing
  # coverage's keeps it green, and the count says nothing about which job
  # is covered. It also carried the wrong name -- there are SIX
  # :main-pulling Obtain steps, so as written the invariant it claimed was
  # false while the test was green.
  #
  # The sixth, `acceptance`, is deliberately not in this list and is not a
  # gap: the probe is about the tools a job EXECUTES, and acceptance
  # executes none of them. It consumes the image only as the `FROM` base of
  # the scaffolded consumer's test stage, so a :main missing kcov costs it
  # nothing. The honest invariant is the one this test now names -- every
  # job that runs the baked tools probes for them -- rather than every job
  # that pulls the tag.
  local _job
  for _job in hadolint bats-fragile bats-integration coverage system; do
    run yaml_job_lines "${WF}" "${_job}"
    assert_success
    assert_output --partial './script/ci/probe_test_tools.sh "${TEST_TOOLS_IMAGE}"'
    assert_output --partial 'build_local=true'
  done
}

# why: Presence is the dimension the tool roster can express and the
# version is not, so a `:main` published before a bump carries every
# required tool AND the wrong runner; the population is derived from the
# workflow so the sixth probing job cannot land outside the rule
@test "self-test.yaml: every job that probes :main compares the runner VERSION, not just presence (#948)" {
  # The population is DERIVED: every top-level job of this workflow whose
  # body invokes the probe. A roster typed here would be green on exactly
  # the sixth probing job somebody adds tomorrow.
  #
  # Why presence is not enough. The probe exists so a stale / racing
  # :main self-corrects to a local rebuild, and it used to answer only "is
  # the tool there?". test/bats/integration/just_runner_version_spec.bats
  # is deliberately fail-closed on a MISMATCH between the image's `just`
  # and ARG JUST_VERSION -- so a :main published before a version bump has
  # every required tool AND the wrong runner, passes a presence-only
  # probe, and reddens any PR that touched nothing related, for as long as
  # the republish takes. The probe has to see the version too.
  #
  # WHERE that comparison lives moved, and this test moved with it. It was
  # twelve lines inlined into each of the five obtain steps; it is now one
  # script (base#947), so the version dimension is asserted where the script
  # declares it -- `just` among the tools whose version is compared, not
  # merely found -- rather than five times over copies of one loop. The
  # compare itself, and the verdict it flips, are covered case by case in
  # probe_test_tools_spec.bats, which drives the real function bodies; what
  # this file is still the right place to state is that every job that
  # probes reaches THAT script and not a private re-implementation.
  local -a _jobs=() _probing=()
  mapfile -t _jobs < <(yaml_job_names "${WF}")
  [ "${#_jobs[@]}" -ge 10 ] \
    || fail "derived only ${#_jobs[@]} job(s) from ${WF} -- the roster reader is broken, so this test checked nothing"
  local _job _body
  for _job in "${_jobs[@]}"; do
    _body="$(yaml_job_lines "${WF}" "${_job}")"
    [[ "${_body}" == *'probe_test_tools.sh'* ]] || continue
    _probing+=("${_job}")
  done
  [ "${#_probing[@]}" -ge 5 ] \
    || fail "found ${#_probing[@]} probing job(s) among ${#_jobs[@]}; expected at least the five that run the baked tools -- the scan matched nothing, which is not a pass"

  # The script the five reach, read as the declaration it is. `just` has
  # to be a tool the probe REQUIRES (present) and one whose version it
  # COMPARES; requiring it alone is the presence-only probe this test is
  # named against.
  local _probe=/source/script/ci/probe_test_tools.sh
  assert_spec_subject "${_probe}" \
    "the CI-side probe every obtain step in this workflow calls"
  local _required _pinned
  _required="$(sed -n 's|^: "${REQUIRED_TOOLS:=\(.*\)}"$|\1|p' "${_probe}")"
  _pinned="$(sed -n 's|^: "${PINNED_TOOLS:=\(.*\)}"$|\1|p' "${_probe}")"
  [ -n "${_required}" ] && [ -n "${_pinned}" ] \
    || fail "could not read REQUIRED_TOOLS / PINNED_TOOLS out of ${_probe} -- the defaults moved, so this test compared nothing"
  [[ " ${_required} " == *' just '* ]] \
    || fail "the probe does not require 'just' (REQUIRED_TOOLS='${_required}'), so a :main without the runner is handed to the suite"
  [[ " ${_pinned} " == *' just '* ]] \
    || fail "the probe finds 'just' but never compares its version (PINNED_TOOLS='${_pinned}') -- a :main published before a version bump passes"
}

@test "self-test.yaml: only classify fetches the base ref; image jobs read its testtools_changed output (#734)" {
  # The "PR changed Dockerfile.test-tools" decision is computed ONCE in
  # classify (its checkout is fetch-depth: 0, so the three-dot merge-base
  # resolves). The 6 image jobs (hadolint, bats-fragile, bats-integration,
  # coverage, acceptance, system) used to repeat that diff on a
  # shallow (fetch-depth: 1) checkout where no merge-base is reachable, so it
  # reported every file as changed and rebuilt the image on EVERY PR. They now
  # read needs.classify.outputs.testtools_changed instead -- so `git fetch
  # origin` appears exactly once (classify).
  run code_grep -c 'git fetch origin' "${WF}"
  assert_success
  assert_output '1'
}

@test "self-test.yaml: classify emits testtools_changed from a full-history diff (#734)" {
  run yaml_job_lines "${WF}" classify
  assert_success
  assert_output --partial 'testtools_changed:'
  assert_output --partial "-- 'dockerfile/Dockerfile.test-tools'"
}

@test "self-test.yaml: image jobs gate the rebuild on classify's testtools_changed (#734)" {
  # Every job that rebuilds test-tools keys off the single classify output,
  # not its own shallow-checkout diff. One env wiring per image job (6).
  run code_grep -c 'TESTTOOLS_CHANGED: ${{ needs.classify.outputs.testtools_changed }}' "${WF}"
  assert_success
  assert_output '6'
}

# ── self-maintaining shard-weights cache (time-balanced partition) ──

@test "self-test.yaml: coverage shards restore the shard-weights cache before partitioning (#733)" {
  # The greedy-LPT partition weights specs by recorded kcov seconds; each
  # shard restores the cached weights to the in-repo path _spec_weight reads
  # by default, so every shard computes the identical (exhaustive + disjoint)
  # partition. A cache miss degrades to the @test-count fallback.
  run yaml_job_lines "${WF}" coverage
  assert_success
  assert_output --partial 'actions/cache/restore'
  assert_output --partial 'test/bats/.shard-weights'
  assert_output --partial 'shard-weights-'
}

@test "self-test.yaml: coverage-gate merges shard timings into the weights file (#733)" {
  # coverage-gate already downloads every shard artifact (cobertura), which
  # now also carries each shard's timings.tsv; it merges them into one
  # weights file via the gate driver's --merge-timings subcommand.
  run yaml_job_lines "${WF}" coverage-gate
  assert_success
  assert_output --partial '--merge-timings'
  assert_output --partial 'timings.tsv'
}

@test "self-test.yaml: coverage-gate saves the shard-weights cache only on push (#733)" {
  # Only authoritative main-push runs refresh the cache (stable runners);
  # PR runs read-only so PR-runner noise never poisons the shared weights.
  run yaml_job_lines "${WF}" coverage-gate
  assert_success
  assert_output --partial 'actions/cache/save'
  assert_output --partial "github.event_name == 'push'"
}

# ── ci-rollup aggregator ───────────────────────────────────────

@test "self-test.yaml: declares ci-rollup job (#337)" {
  run code_grep -E '^  ci-rollup:' "${WF}"
  assert_success
}

@test "self-test.yaml: ci-rollup needs every sibling PR-check job incl coverage (#337 + #376 + #377 + #615 + #677)" {
  # The aggregator waits on actionlint + classify + shellcheck +
  # hadolint + bats-fragile + bats-integration + coverage + acceptance
  # + system so its result reflects every PR check. (ADR-8)
  # adds `coverage` to the list — it is now the primary unit gate (a
  # sharded kcov PR gate), so a kcov failure must block PR merge; the
  # bats-unit matrix is replaced with a single bats-fragile job.
  #
  # `compute-shards` joins the list too: it is the producer the coverage
  # matrix reads its shard list from, so its failure skips BOTH coverage
  # and coverage-gate, and a rollup that does not name it collapses that
  # double skip into a green required check.
  run yaml_job_lines "${WF}" ci-rollup
  assert_success
  assert_output --partial 'needs: [actionlint, classify, shellcheck, doc-counts, lint-static, hadolint, bats-fragile, bats-integration, compute-shards, coverage, coverage-gate, acceptance, system, worker-selftest]'
}

@test "self-test.yaml: ci-rollup DOES need coverage now (#615 amends #377)" {
  # kept coverage out of the rollup (main-only metric); (ADR-8)
  # reverses that — the sharded kcov gate joins the rollup so a kcov
  # failure blocks merge. ci-rollup's SKIPPED=pass rule keeps doc-only
  # PRs merge-able even though coverage is now in `needs:`.
  run yaml_job_lines "${WF}" ci-rollup
  assert_success
  assert_output --partial 'needs.coverage.result'
  assert_output --partial ', coverage,'
}

@test "self-test.yaml: ci-rollup runs unconditionally via if: always() (#337)" {
  # Without `if: always` the rollup would skip when any upstream
  # need failed, masking the failure as SKIPPED — branch protection
  # treats SKIPPED as missing, so the merge gate would lift falsely.
  run yaml_job_lines "${WF}" ci-rollup
  assert_success
  assert_output --partial 'if: always()'
}

@test "self-test.yaml: ci-rollup verify step consumes every needs result incl coverage (#337 + #376 + #377 + #615)" {
  # The shell verifier must inspect each upstream's ${{ needs.<job>.result }}
  # to translate the parallel job graph into a single pass/fail signal.
  run yaml_job_lines "${WF}" ci-rollup
  assert_success
  assert_output --partial 'needs.actionlint.result'
  assert_output --partial 'needs.classify.result'
  assert_output --partial 'needs.shellcheck.result'
  assert_output --partial 'needs.hadolint.result'
  assert_output --partial 'needs.bats-fragile.result'
  assert_output --partial 'needs.bats-integration.result'
  assert_output --partial 'needs.compute-shards.result'
  assert_output --partial 'needs.coverage.result'
  assert_output --partial 'needs.coverage-gate.result'
  assert_output --partial 'needs.acceptance.result'
  assert_output --partial 'needs.system.result'
}

@test "self-test.yaml: ci-rollup treats SKIPPED as pass for conditionally-gated jobs (#337 + #377)" {
  # every PR-check job has a job-level `if:` gate that may
  # cause it to skip on doc-only / non-system PRs (the old
  # always-running `test` job no longer exists). The rollup must
  # collapse SKIPPED into pass for those, otherwise doc-only PRs
  # cannot merge.
  #
  # Asserted as the comparison, not as the word. `--partial 'skipped'` was
  # satisfied by the word inside the fork-PR `::error::` message a few
  # lines below -- a code line, so stripping comments does not help here:
  # deleting `|| "${r}" == "skipped"` outright left this green. The
  # membership half matters as much as the comparison: a job moved out of
  # the tolerant loop loses its skip tolerance without touching the
  # comparison at all.
  run yaml_job_lines "${WF}" ci-rollup
  assert_success
  assert_output --partial 'for r in "${SHELLCHECK_RESULT}" "${HADOLINT_RESULT}" \'
  assert_output --partial '"${ACCEPTANCE_RESULT}" "${SYSTEM_RESULT}" \'
  assert_output --partial '[[ "${r}" == "success" || "${r}" == "skipped" ]] || fail=1'
}

@test "self-test.yaml: ci-rollup requires hard-mandatory jobs to be success (#337 + #377)" {
  # actionlint + classify + doc-counts + lint-static are hard-mandatory:
  # they carry no `if:` gate, so SKIPPED there indicates a workflow bug,
  # not an intentional gate.
  #
  # Asserted as the strict comparison plus the membership of the strict
  # loop. `--partial 'success'` matched the word anywhere in the job --
  # every result echo, and the tolerant loop's own first disjunct -- so it
  # held whether or not a strict bucket existed at all. The strict line is
  # not a substring of the tolerant one (`"success"` is followed by ` ]]`
  # there, by ` ||` here), so this discriminates between them.
  run yaml_job_lines "${WF}" ci-rollup
  assert_success
  assert_output --partial 'for r in "${ACTIONLINT_RESULT}" "${CLASSIFY_RESULT}" \'
  assert_output --partial '"${DOC_COUNTS_RESULT}" "${LINT_STATIC_RESULT}" \'
  assert_output --partial '"${COMPUTE_SHARDS_RESULT}"; do'
  assert_output --partial '[[ "${r}" == "success" ]] || fail=1'
}

# why: compute-shards carries no `if:` gate, so a SKIPPED there is a
# workflow bug and not a conditional job declining to run. It is also the
# one job whose FAILURE is otherwise invisible: coverage needs it and
# coverage-gate needs coverage, and both of those sit in the rollup's
# skipped-tolerant bucket, so putting compute-shards in the tolerant bucket
# too leaves the required check green with the entire unit suite and the
# coverage floor never run.
@test "self-test.yaml: ci-rollup treats compute-shards as hard-mandatory, not SKIPPED-tolerant (#1009)" {
  # compute-shards emits the shard list the coverage matrix expands, and it
  # carries no `if:` gate -- so a SKIPPED there is a workflow bug, exactly
  # like doc-counts / lint-static. It is also the one job whose FAILURE is
  # otherwise invisible: coverage needs it, coverage-gate needs coverage,
  # and both sit in the rollup's skipped-tolerant bucket, so a
  # compute-shards failure used to leave the required check green with the
  # whole unit suite and the coverage floor unrun.
  run yaml_job_lines "${WF}" ci-rollup
  assert_success
  assert_output --partial 'needs.compute-shards.result'

  # In the strict loop ...
  run code_grep -A2 'for r in "${ACTIONLINT_RESULT}"' "${WF}"
  assert_success
  assert_output --partial 'COMPUTE_SHARDS_RESULT'

  # ... and NOT in the skipped-tolerant one. Read the tolerant loop alone:
  # asserting over the whole job would find the name in the strict loop and
  # pass whichever bucket it really sits in.
  run code_grep -A4 'for r in "${SHELLCHECK_RESULT}"' "${WF}"
  assert_success
  refute_output --partial 'COMPUTE_SHARDS_RESULT'
}

# ── The gate roster is DERIVED, not hand-kept ──────────────────
#
# Every assertion above this line names the roster it checks, which means
# the roster is written twice -- once in the workflow, once here -- and
# adding a job to the workflow updates neither. That is not a hypothetical:
# `compute-shards` shipped outside ci-rollup's `needs:` and `coverage-gate`
# outside release's, and each assertion above passed the whole time,
# because each one asserted the text that was there.
#
# So the three guards below take the roster from the FILE. The set of jobs
# comes from the `jobs:` mapping, the dependencies come from each job's
# `needs:`, and the two gates are compared against those rather than
# against a list a human maintains. A job added tomorrow is covered the day
# it lands.

# _result_var <job> -- the env var ci-rollup binds a job's result to.
# Derived from the job id (upper-case, dashes to underscores) rather than
# looked up in a table, so the mapping cannot drift from the naming the
# workflow already uses.
_result_var() {
  printf '%s_RESULT\n' "${1}" | tr 'a-z-' 'A-Z_'
}

# _rollup_loops -- ci-rollup's verify loops, one per line, as
# `<kind> <VAR>...`. The KIND is decided by the loop BODY's comparison --
# a body that also accepts "skipped" is the tolerant bucket, one that
# accepts "success" alone is the strict one -- not by which variable
# happens to be written first, so a loop reordered or renamed is still
# classified by what it actually does.
_rollup_loops() {
  yaml_job_lines "${WF}" ci-rollup | awk '
    /for r in / { collecting = 1; header = "" }
    collecting {
      header = header " " $0
      if ($0 ~ /; do[[:space:]]*$/) { collecting = 0; pending = header }
      next
    }
    pending != "" && /== "success"/ {
      kind = ($0 ~ /"skipped"/) ? "tolerant" : "strict"
      n = split(pending, parts, /[^A-Z_]+/)
      out = kind
      for (i = 1; i <= n; i++) {
        if (parts[i] ~ /_RESULT$/) { out = out " " parts[i] }
      }
      print out
      pending = ""
    }
  '
}

# _needs_closure <job> -- every job <job> transitively depends on, sorted,
# excluding <job> itself. This is what makes the tag path answerable: a
# release gate inherits a dependency through the job it names, so the
# comparable quantity is the closure and not the literal list.
#
# On a `needs:` entry naming a job the workflow does not declare, the
# parser's `BUG:` line is PROPAGATED and the walk stops with a non-zero
# status -- it is not queued as another job id. That entry is the
# rename/typo drift this spec exists to catch, and a `BUG:` line walked
# as an id yields a new, longer `BUG:` line every round, which the
# seen-set can never dedupe: the walk would run forever and hang the
# suite instead of failing it.
_needs_closure() {
  local -a _queue=("${1}")
  local -A _seen=()
  local _job _dep _deps _status
  while [ "${#_queue[@]}" -gt 0 ]; do
    _job="${_queue[0]}"
    _queue=("${_queue[@]:1}")
    [[ -z "${_seen[${_job}]:-}" ]] || continue
    _seen["${_job}"]=1
    _status=0
    _deps="$(yaml_job_needs "${WF}" "${_job}")" || _status=$?
    if [ "${_status}" -ne 0 ]; then
      printf '%s\n' "${_deps}"
      return 1
    fi
    while IFS= read -r _dep; do
      [[ -n "${_dep}" ]] || continue
      _queue+=("${_dep}")
    done <<<"${_deps}"
  done
  unset '_seen[${1}]'
  [ "${#_seen[@]}" -gt 0 ] || return 0
  printf '%s\n' "${!_seen[@]}" | sort
}

# _job_names -- the workflow's jobs, failing the test (rather than
# returning a short list) when the parse did not work.
_job_names() {
  local _names _status=0
  _names="$(yaml_job_names "${WF}")" || _status=$?
  [ "${_status}" -eq 0 ] || fail "${_names}"
  printf '%s\n' "${_names}"
}

# why: This is the guard that makes the merge gate's roster DERIVED rather
# than hand-kept, and it is the recurrence #1009 asks to close: adding a job
# to the workflow used to update neither ci-rollup's needs nor any
# assertion, so the new job gated nothing and every existing test stayed
# green. Directly and not transitively, because ci-rollup runs under
# `if: always()` and reads each upstream's `.result`: GitHub reports a job
# whose need failed as SKIPPED, and SKIPPED is pass-equivalent in the
# tolerant bucket, so a job reached only through another is invisible to it.
@test "self-test.yaml: every job the workflow declares is named directly in ci-rollup's needs (#1009)" {
  # Directly, not transitively. ci-rollup runs under `if: always()` and
  # reads each upstream's `.result`, so what it can SEE is its own `needs:`
  # -- and a dependency reached only through another job is invisible to
  # it in the worst case: GitHub reports a job whose need failed as
  # SKIPPED, and SKIPPED is pass-equivalent in the tolerant bucket. That is
  # how a compute-shards failure used to travel: coverage skipped,
  # coverage-gate skipped, required check green, unit suite and coverage
  # floor never run.
  #
  # ci-rollup and release are the two SINKS and so are exempt: nothing
  # aggregates the aggregator, and the tag path is checked separately
  # below.
  local -a _jobs=()
  mapfile -t _jobs < <(_job_names)
  [ "${#_jobs[@]}" -ge 14 ] \
    || fail "parsed ${#_jobs[@]} jobs out of the workflow; the jobs mapping did not read"

  local _needs _status=0
  _needs="$(yaml_job_needs "${WF}" ci-rollup)" || _status=$?
  [ "${_status}" -eq 0 ] || fail "${_needs}"

  local _job
  for _job in "${_jobs[@]}"; do
    case "${_job}" in
      ci-rollup | release) continue ;;
    esac
    grep -qxF -- "${_job}" <<<"${_needs}" \
      || fail "job '${_job}' is declared in self-test.yaml but ci-rollup does not name it in needs: -- its failure cannot reach the required check"
  done
}

# why: Joining `needs:` is only half a gate, so the guard above is not
# enough on its own. The rollup's verdict is the two loops over the
# `*_RESULT` variables: a job that is needed but compared in neither loop is
# waited for and then ignored, which is the same green as never having been
# needed, with a needs list that reads as correct. Exactly one bucket rather
# than at least one, because a variable in both is strict and tolerant at
# once. No pre-existing test caught a `*_RESULT` dropped from a loop.
@test "self-test.yaml: ci-rollup inspects every job it needs, in exactly one result bucket (#1009)" {
  # Joining `needs:` is half a gate. The rollup's verdict is the two loops
  # over the *_RESULT variables, so a job that is needed but named in
  # neither loop is waited for and then ignored -- the same green as not
  # being needed at all, with the needs list looking correct.
  local -a _loops=()
  mapfile -t _loops < <(_rollup_loops)
  [ "${#_loops[@]}" -eq 2 ] \
    || fail "expected a strict and a tolerant result loop in ci-rollup, parsed ${#_loops[@]}"

  local _rollup
  _rollup="$(yaml_job_lines "${WF}" ci-rollup)"

  local _needs _status=0
  _needs="$(yaml_job_needs "${WF}" ci-rollup)" || _status=$?
  [ "${_status}" -eq 0 ] || fail "${_needs}"

  local _job _var _line _hits
  while IFS= read -r _job; do
    [[ -n "${_job}" ]] || continue
    _var="$(_result_var "${_job}")"
    grep -qF -- "${_var}: \${{ needs.${_job}.result }}" <<<"${_rollup}" \
      || fail "ci-rollup needs '${_job}' but binds no ${_var} from needs.${_job}.result"
    _hits=0
    for _line in "${_loops[@]}"; do
      case " ${_line} " in
        *" ${_var} "*) _hits=$(( _hits + 1 )) ;;
      esac
    done
    [ "${_hits}" -eq 1 ] \
      || fail "ci-rollup needs '${_job}' but ${_var} appears in ${_hits} result loops (expected exactly 1) -- a needed job nothing compares is a job that gates nothing"
  done <<<"${_needs}"
}

# why: The two guards above cover the PR path only. `release` does not go
# through ci-rollup -- ci-rollup is not in its `needs:` -- so the merge gate
# and the tag path were independent hand-kept lists of the same thing with
# nothing making them agree, and coverage-gate sat in one of them only. That
# left the coverage floor enforced on every PR and unenforced on the one
# path that publishes a Release, which is the half of #1009 no assertion
# about either roster could have found.
@test "self-test.yaml: the tag path requires exactly what the merge gate requires (#1009)" {
  # release does NOT go through ci-rollup -- ci-rollup is not in its
  # `needs:` -- so the two rosters are independent lists of the same thing,
  # and nothing made them agree. coverage-gate was in one and not the
  # other, which left the coverage floor enforced on PRs and unenforced on
  # the one path that publishes an artifact.
  #
  # Compared as SETS derived from the file: release's transitive closure
  # against the jobs ci-rollup names. Transitive on the release side
  # because a skipped or failed need there skips release itself, so a
  # dependency inherited through another job really is a gate; ci-rollup
  # needs the direct list for the reason the guard above states.
  #
  # Neither roster is read through a PIPELINE: bats leaves `pipefail` off
  # (`set +o pipefail`, probed in the harness), so `yaml_job_needs ... |
  # sort` reports SORT's status and the parser's `BUG:` line arrives as
  # data with a status of 0. The sort happens after the status is read.
  local _merge _tag _status=0
  _merge="$(yaml_job_needs "${WF}" ci-rollup)" || _status=$?
  [ "${_status}" -eq 0 ] || fail "${_merge}"
  _merge="$(sort <<<"${_merge}")"
  _status=0
  _tag="$(_needs_closure release)" || _status=$?
  [ "${_status}" -eq 0 ] || fail "${_tag}"

  # Non-vacuity: two empty sets are equal. Checked as EMPTINESS and not
  # by probing for a job by name -- the name to hand was `coverage-gate`,
  # the very job whose absence from a roster this test exists to detect,
  # so reintroducing that defect tripped the guard first and reported a
  # MISSING GATE as "the tag-path closure did not parse". That statement
  # is false (the closure parsed perfectly) and it points a maintainer at
  # yq instead of at the gate. A roster that genuinely failed to parse
  # already arrives as a non-zero status from the two calls above; what
  # is left for this guard is a roster that parsed to nothing.
  [ -n "${_merge}" ] || fail "ci-rollup declares no needs: at all"
  [ -n "${_tag}" ] || fail "release transitively requires nothing at all"

  [ "${_merge}" == "${_tag}" ] || fail "the tag path and the merge gate require different jobs.
ci-rollup requires:
${_merge}
release transitively requires:
${_tag}"
}

# why: The guard above compares a transitive closure, so it is worth no
# more than the walk that computes it -- this is the test that keeps that
# one from being vacuous. `yaml_job_needs` answers an undeclared job id with
# a `BUG:` line and a non-zero status; a walk that reads the line and drops
# the status queues the diagnostic as another job id, and since each bogus
# id yields a new and longer line the seen-set never dedupes, the walk never
# ends. That turns exactly the roster drift this spec exists to catch -- a
# renamed job still named in a `needs:` entry -- into `just test` hanging
# with no TAP output and a container left spinning, which is the worst
# failure mode available to it.
@test "self-test.yaml: the closure walk reports a dangling needs: entry instead of walking forever (#1009)" {
  # The guard above compares a CLOSURE, so it is only as good as the walk
  # that computes it. `yaml_job_needs` answers a job id the file does not
  # declare with a `BUG:` line AND a non-zero status, because a `needs:`
  # entry naming a renamed job is a defect and not an absence. A walk that
  # reads the line and drops the status queues the diagnostic as if it were
  # a job id -- and each bogus id yields a NEW, longer `BUG:` line, so the
  # seen-set never dedupes it and the walk never ends. That turns exactly
  # the roster drift this spec exists to catch -- a rename or a typo in a
  # `needs:` entry -- into `just test` HANGING: no TAP output, no
  # diagnostic, and a container left spinning.
  #
  # Run against a fixture rather than the real workflow: the property is
  # about what the walk does with a dangling edge, and the workflow under
  # test must not have one. A status of 124 below is the timeout firing,
  # i.e. the walk is still unbounded.
  local _fixture="${BATS_TEST_TMPDIR}/dangling-needs.yaml"
  cat >"${_fixture}" <<'YAML'
jobs:
  root:
    needs: [present, renamed-away]
  present:
    runs-on: ubuntu-latest
YAML
  export -f _needs_closure yaml_job_needs _yaml_eval
  run env WF="${_fixture}" timeout 20 bash -c '_needs_closure root'
  [ "${status}" -ne 124 ] \
    || fail "the closure walk never terminated on a needs: entry naming a job the workflow does not declare"
  assert_failure
  assert_output --partial 'declares no job renamed-away'
}

# ── Fork PRs cannot make the rollup vacuously green ────────────

@test "self-test.yaml: ci-rollup fails a fork PR instead of reporting a partial run as green (#766)" {
  # The self-hosted guard's effect is a SKIP, and SKIPPED is
  # pass-equivalent in the conditionally-gated bucket above. worker-selftest
  # calls build-worker.yaml, whose `build` job carries the guard: on a fork
  # PR that job skips while the worker's other jobs succeed, so
  # needs.worker-selftest.result is `success` and the loop would collapse a
  # build that never ran into a green REQUIRED check -- for exactly the
  # untrusted PR. A required check is a claim the commit was fully tested;
  # on a fork PR that claim is false, so the rollup has to say so rather
  # than pass.
  run yaml_job_lines "${WF}" ci-rollup
  assert_success
  assert_output --partial 'IS_FORK_PR:'
  assert_output --partial "github.event.pull_request.head.repo.full_name != github.repository"
  assert_output --partial 'if [[ "${IS_FORK_PR}" == "true" ]]; then'
}

@test "self-test.yaml: the fork-PR branch is a hard failure, not an advisory note (#766)" {
  # An advisory warning next to a green required check is the vacuous
  # rollup with extra steps.
  #
  # Read through the shared comment-stripped view, like every sibling: the
  # claim is about what the branch RUNS, and the job's own paragraph
  # explains the hard failure in prose. Sliced by its own awk, this
  # assertion was satisfied by demoting `fail=1` to a comment inside the
  # branch -- which is exactly the advisory-note defect it refuses.
  local _rollup
  _rollup="$(yaml_job_lines "${WF}" ci-rollup)"
  run grep -A3 -F 'if [[ "${IS_FORK_PR}" == "true" ]]; then' <<<"${_rollup}"
  assert_success
  assert_output --partial 'fail=1'
}

@test "self-test.yaml: the self-hosted guard lint has a lint-static CI join (#766)" {
  # Belt to the _LINT_TOOLS completeness guard's braces: that check proves
  # SOME job names every lint, this one names the join the guard is meant
  # to have. A guard whose own CI job vanished would gate nothing.
  run yaml_job_lines "${WF}" lint-static
  assert_success
  assert_output --partial '- self-hosted-guard'
}

# why: The CI run on a watch/ branch IS the proposal's whole answer; a
# branches: filter here would leave every proposal green with zero checks
@test "self-test.yaml: pull_request is unfiltered, so a watch/ proposal gets the gate" {
  # The upstream-release watch opens its proposals on `watch/<tool>-<ver>`
  # branches, and the CI run this trigger starts on them IS the answer to
  # "does this version break us" -- the workflow's entire output. A
  # `branches:` list added here would leave every proposal with zero
  # checks, which reads as nothing-is-wrong.
  run awk '/^on:/{flag=1; next} /^[a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'pull_request:'
  run awk '/^  pull_request:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  refute_output --partial 'branches:'
  refute_output --partial 'branches-ignore:'
}

# why: A PR is the only moment pin-coverage can fire; with no CI join it
# would gate a local just test and nothing a reviewer ever sees
@test "self-test.yaml: the pin-coverage lint has a lint-static CI join" {
  # Same belt-and-braces as the self-hosted guard above. This one carries
  # more than usual: pin-coverage is what stops a third-party version from
  # being added with nothing watching it, so a PR is the only moment it can
  # fire. Without a CI job it would gate only a local `just test`.
  run awk '/^  lint-static:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial '- pin-coverage'
}

# ── System-level build-worker self-test ────────────────────────

@test "self-test.yaml: declares worker-selftest job that really invokes the shared build worker (#802)" {
  # System level (ADR-00000018): actually run base's OWN build-gate
  # (build-worker.yaml) end-to-end via a local reusable-workflow call, so a
  # semantic break in the worker turns this job red instead of surfacing
  # only when a downstream runs it in production. The `uses:` is the LOCAL
  # reusable-workflow reference (must stay actionlint-clean).
  run code_grep -E '^  worker-selftest:' "${WF}"
  assert_success
  run yaml_job_lines "${WF}" worker-selftest
  assert_success
  assert_output --partial 'uses: ./.github/workflows/build-worker.yaml'
}

@test "self-test.yaml: worker-selftest drives the worker with a minimal fixture repo (#802)" {
  # The point is to exercise the orchestration, not build a real image: the
  # worker is pointed at the trivial alpine fixture
  # (test/fixtures/build-worker/Dockerfile) via context_path, with the
  # required image_name input supplied.
  run yaml_job_lines "${WF}" worker-selftest
  assert_success
  assert_output --partial 'image_name: worker-selftest'
  assert_output --partial 'context_path: test/fixtures/build-worker'
}

@test "self-test.yaml: worker-selftest needs actionlint + classify and gates on system_relevant (#802)" {
  # Same upstream pattern as the system job: actionlint fires first, and the
  # narrower system_relevant output skips it on pure lint / unit / doc PRs
  # (any change to .github/workflows/** re-runs it via the block-list).
  run yaml_job_lines "${WF}" worker-selftest
  assert_success
  assert_output --partial 'needs: [actionlint, classify]'
  assert_output --partial "if: needs.classify.outputs.system_relevant == 'true'"
}

@test "self-test.yaml: ci-rollup consumes worker-selftest as a SKIPPED-tolerant gate (#802)" {
  # The System self-test joins the aggregator branch protection keys on, in
  # the success-or-skipped bucket (it skips on non-system PRs). ci-rollup
  # must list it in needs: and inspect its result.
  run yaml_job_lines "${WF}" ci-rollup
  assert_success
  assert_output --partial 'needs.worker-selftest.result'
  assert_output --partial ', worker-selftest]'

  # ...and be IN the tolerant bucket, which "consumes its result" does not
  # say: deleting the tolerant loop outright left the two assertions above
  # green. Same membership check the doc-counts / lint-static siblings make
  # against the strict loop.
  run code_grep -A4 'for r in "${SHELLCHECK_RESULT}"' "${WF}"
  assert_success
  assert_output --partial 'WORKER_SELFTEST_RESULT'
}

@test "self-test.yaml: release gate requires worker-selftest before publishing a tag (#802)" {
  # Acceptance criterion: the System job is part of the required gate before
  # a tag. release fires on tag push only; if the worker self-test fails the
  # tag must NOT produce a Release.
  run yaml_job_lines "${WF}" release
  assert_success
  assert_output --partial 'worker-selftest]'
}

# ── shellcheck + hadolint dedicated jobs ───────────────────────

@test "self-test.yaml: declares shellcheck job (#376)" {
  run code_grep -E '^  shellcheck:' "${WF}"
  assert_success
}

@test "self-test.yaml: shellcheck job needs actionlint + classify and gates on code_changed (#376)" {
  # Same upstream pattern as the test/acceptance jobs so the
  # actionlint workflow-validator gate still fires first, and the
  # doc-only short-circuit still skips lint runs.
  run yaml_job_lines "${WF}" shellcheck
  assert_success
  assert_output --partial 'needs: [actionlint, classify]'
  assert_output --partial "if: needs.classify.outputs.code_changed == 'true'"
}

@test "self-test.yaml: shellcheck job runs test.sh --shellcheck-only on plain ubuntu-latest (#376)" {
  # Goal: ~30s feedback on a shellcheck regression. Plain ubuntu-latest
  # ships shellcheck pre-installed so no apt-install / no buildx /
  # no test-tools image is needed — keeps the job cold-startup cost
  # near zero.
  run yaml_job_lines "${WF}" shellcheck
  assert_success
  assert_output --partial 'runs-on: ubuntu-latest'
  assert_output --partial './script/test/test.sh --shellcheck-only'
  # No buildx setup / no docker pull / no compose run in this job.
  refute_output --partial 'docker/setup-buildx-action'
  refute_output --partial 'docker pull'
}

@test "self-test.yaml: declares doc-counts job (#864)" {
  run code_grep -E '^  doc-counts:' "${WF}"
  assert_success
}

@test "self-test.yaml: doc-counts job runs test.sh --doc-counts-only on plain ubuntu-latest (#864)" {
  # The generated doc/test catalogue has a gate, and it lives in the
  # `just test` lint phase -- which NO CI job runs: the lint jobs narrow to
  # one tool and every bats job sets BATS_ONLY=1. This job is the CI half.
  # Pure bash + diff, so no buildx / test-tools image, same cold-start cost
  # as the shellcheck job.
  run yaml_job_lines "${WF}" doc-counts
  assert_success
  assert_output --partial 'needs: [actionlint, classify]'
  assert_output --partial 'runs-on: ubuntu-latest'
  assert_output --partial './script/test/test.sh --doc-counts-only'
  refute_output --partial 'docker/setup-buildx-action'
}

@test "self-test.yaml: doc-counts carries NO code_changed gate (#864)" {
  # Deliberately ungated, unlike its sibling lint jobs: the catalogue can
  # be broken by hand-editing doc/test/*.md, which classify scores as a
  # doc-only change. A code_changed gate would skip the gate on exactly
  # the PR that hand-edited a count.
  run yaml_job_lines "${WF}" doc-counts
  assert_success
  # Non-vacuity: an absent job yields an empty block, against which the
  # refute below would pass while asserting nothing.
  assert_output --partial './script/test/test.sh --doc-counts-only'
  # The gate form its sibling lint jobs use. Matching on that rather than
  # the bare word keeps the job's own comment (which explains WHY it is
  # ungated, and so names the gate) from satisfying the refutation.
  refute_output --partial 'if: needs.classify.outputs'
}

@test "self-test.yaml: ci-rollup treats doc-counts as hard-mandatory, not SKIPPED-tolerant (#864)" {
  # It has no `if:` gate, so SKIPPED means a workflow bug. It must sit in
  # the success-only loop with actionlint / classify, never in the
  # skipped-tolerated one. The success-only loop is the one whose body
  # compares against "success" alone; grep the two lines following the
  # ACTIONLINT/CLASSIFY loop header to see what else it iterates.
  run yaml_job_lines "${WF}" ci-rollup
  assert_success
  assert_output --partial 'needs.doc-counts.result'

  run code_grep -A2 'for r in "${ACTIONLINT_RESULT}"' "${WF}"
  assert_success
  assert_output --partial 'DOC_COUNTS_RESULT'
}

# ── lint-static matrix (the rest of the lint phase) ────────────

@test "self-test.yaml: declares lint-static job (#866)" {
  run code_grep -E '^  lint-static:' "${WF}"
  assert_success
}

@test "self-test.yaml: lint-static runs one matrix entry per host-direct lint on a plain runner (#866)" {
  # The lint phase runs the static lints no CI job ran: the issue-ref
  # comment lint, the ADR-numbering lint, the stale
  # config/docker/setup.conf path lint, the localized README sync lint and
  # the hardcoded home path lint.
  # Each is pure bash over the checkout, so a plain ubuntu-latest runner
  # can call it host-direct -- no buildx, no test-tools image. One matrix
  # entry each so the checks list names WHICH lint failed.
  run yaml_job_lines "${WF}" lint-static
  assert_success
  assert_output --partial 'needs: [actionlint, classify]'
  assert_output --partial 'runs-on: ubuntu-latest'
  # fail-fast off: one failing lint must not cancel the sibling entries,
  # or a branch fixes them one round-trip at a time.
  assert_output --partial 'fail-fast: false'
  assert_output --partial '- issueref'
  assert_output --partial '- adr-numbering'
  assert_output --partial '- adr-structure'
  assert_output --partial '- stale-setup-conf'
  assert_output --partial '- readme-sync'
  # The hardcoded-home-path lint joined the same matrix: it reads the
  # shipped image tree, so a plain runner can call it host-direct too.
  assert_output --partial '- home-literal'
  # Same for the unguarded-BASH_SOURCE lint: pure bash over dist/ + script/.
  assert_output --partial '- bash-source-guard'
  # And for the early-closing-reader pipeline lint, same trees, same shape.
  assert_output --partial '- early-close-reader'
  # And for the non-final bang-statement lint, over the bats tree.
  assert_output --partial '- errexit-bang'
  assert_output --partial './script/test/test.sh'
  refute_output --partial 'docker/setup-buildx-action'
  refute_output --partial 'docker pull'
}

@test "self-test.yaml: lint-static carries NO code_changed gate (#866)" {
  # Ungated on purpose, like doc-counts. Two of the matrix entries
  # are breakable by a change classify scores as doc-only: the
  # ADR-numbering lint reads doc/adr/ filenames, and the localized README
  # sync lint reads README.md + doc/readme/**. Gating on code_changed
  # would skip them on exactly the PR they exist to catch. A matrix
  # shares ONE job-level `if:`, so the gate would be all-or-nothing
  # anyway.
  run yaml_job_lines "${WF}" lint-static
  assert_success
  # Non-vacuity: an absent job yields an empty block, against which the
  # refute below would pass while asserting nothing.
  assert_output --partial '- readme-sync'
  refute_output --partial 'if: needs.classify.outputs'
}

@test "self-test.yaml: ci-rollup treats lint-static as hard-mandatory, not SKIPPED-tolerant (#866)" {
  # No `if:` gate, so SKIPPED means a workflow bug -- same contract as
  # doc-counts. It must sit in the success-only loop, never the
  # skipped-tolerated one.
  run yaml_job_lines "${WF}" ci-rollup
  assert_success
  assert_output --partial 'needs.lint-static.result'

  run code_grep -A2 'for r in "${ACTIONLINT_RESULT}"' "${WF}"
  assert_success
  assert_output --partial 'LINT_STATIC_RESULT'
}

@test "self-test.yaml: every lint the just test lint phase runs has a CI join (#866)" {
  # The anti-rot guard, and the answer to "which lints are CI-enforced":
  # script/test/test.sh's _LINT_TOOLS table is the one list of tools the
  # lint phase runs, and every entry in it must be named by a CI job --
  # a host-direct primitive (--<tool>-only), the in-container hadolint
  # job (--lint --hadolint), or a lint-static matrix entry (- <tool>).
  # Adding a lint to the phase without giving it a CI join fails HERE,
  # instead of quietly shipping a local-only rule.
  #
  # The claim is STATIC -- a table literal in one file versus job names
  # in another -- so the table is PARSED, never sourced. Sourcing
  # test.sh dragged in the whole lib chain, which reads BASH_SOURCE
  # unguarded; under the kcov-instrumented bash of the coverage shard
  # BASH_SOURCE is not populated for a sourced file, so the source
  # aborted and its stderr got parsed as if it were a lint name (the
  # same failure that hit setup_tui.sh). Parsing keeps the guard
  # running under coverage instead of skipping it there.
  local _test_sh="/source/script/test/test.sh"
  assert_spec_subject "${_test_sh}" \
      "the self-test dispatcher whose lint table this spec cross-checks"
  run awk '
    /^readonly _LINT_TOOLS=\(/ { inside = 1; next }
    inside && /^\)/            { inside = 0 }
    inside {
      sub(/#.*/, "")
      gsub(/[[:space:]]+/, "")
      if ($0 != "") print
    }
  ' "${_test_sh}"
  assert_success

  local -a _tools=()
  mapfile -t _tools <<<"${output}"
  # Non-vacuity: an empty / truncated table would make the loop below
  # assert nothing at all, which is the exact failure mode this test
  # exists to prevent. Pin both the size and the four lints this issue
  # wired.
  [ "${#_tools[@]}" -ge 13 ] \
    || fail "_LINT_TOOLS yielded ${#_tools[@]} entries; the table did not parse"
  local _t
  for _t in issueref adr-numbering adr-structure stale-setup-conf readme-sync \
    home-literal bash-source-guard i18n-orphan early-close-reader \
    changelog-entry; do
    printf '%s\n' "${_tools[@]}" | grep -qx -- "${_t}" \
      || fail "_LINT_TOOLS does not list '${_t}'"
  done

  for _t in "${_tools[@]}"; do
    code_grep -qE -- "--${_t}-only|--lint --${_t}|^ +- ${_t}\$" "${WF}" \
      || fail "lint '${_t}' runs in the just test lint phase but NO job in self-test.yaml runs it -- it would gate nothing on a PR"
  done
}

@test "self-test.yaml: declares hadolint job (#376)" {
  run code_grep -E '^  hadolint:' "${WF}"
  assert_success
}

@test "self-test.yaml: hadolint job needs actionlint + classify and gates on code_changed (#376)" {
  run yaml_job_lines "${WF}" hadolint
  assert_success
  assert_output --partial 'needs: [actionlint, classify]'
  assert_output --partial "if: needs.classify.outputs.code_changed == 'true'"
}

@test "self-test.yaml: hadolint job runs the driver, not the hadolint-action (#650)" {
  # ADR-00000011 local==CI single source: the hadolint job no
  # longer calls hadolint/hadolint-action with an inline Dockerfile +
  # config list (which would drift from what `just test` lints). It runs
  # the SAME driver (script/test/drivers/hadolint.sh via `test.sh --lint
  # --hadolint`) inside the test-tools image, so the Dockerfile list +
  # config live in ONE place (the driver) for both local + CI.
  run yaml_job_lines "${WF}" hadolint
  assert_success
  assert_output --partial './script/test/test.sh --lint --hadolint'
  # The driver image (test-tools) is obtained like the bats jobs.
  assert_output --partial 'Obtain the run-scoped test-tools image'
  # The inline action + its file/config args are gone (driver owns them).
  refute_output --partial 'hadolint/hadolint-action'
}

@test "self-test.yaml: release job gates on shellcheck + hadolint + bats-fragile + bats-integration + coverage + acceptance + system before publishing a tag (#376 + #377 + #677)" {
  # release fires on tag push only, but if any PR-check job fails the
  # tag should NOT produce a Release. The bats-unit matrix is replaced
  # with `bats-fragile` and `coverage` (now the primary unit gate) joins
  # the release chain.
  #
  # `coverage-gate` joins it too: it is the coverage FLOOR
  # (ADR-00000008), it was in ci-rollup but not here, and ci-rollup is not
  # a `needs:` of release -- so the one path that produces an artifact
  # users consume was the one path the floor did not gate.
  run yaml_job_lines "${WF}" release
  assert_success
  assert_output --partial 'needs: [shellcheck, doc-counts, lint-static, hadolint, bats-fragile, bats-integration, coverage, coverage-gate, acceptance, system, worker-selftest]'
}

@test "self-test.yaml: the release job assembles no source archive of its own (#924)" {
  # Every GitHub release already carries auto-generated source archives
  # (tarball_url / zipball_url) holding the FULL tracked tree. The job used
  # to hand-build a second pair from a hardcoded nine-operand `cp -r`, which
  # is a strictly worse subset: a tracked path that was never listed is
  # simply absent, with no error to notice, so the payload had silently lost
  # .version and the repo-root init.sh -- the two files the upgrade path
  # reads first. The operand list is also a release-time landmine: under
  # `bash -e` one absent operand fails the whole `cp`, and no Release is cut
  # at all.
  #
  # Read through the shared comment-stripped view: the prohibition is on
  # what the job RUNS, and the note that keeps the next person from
  # re-adding the step necessarily names the very construct it rules out.
  run yaml_job_lines "${WF}" release
  assert_success
  refute_output --partial 'Create release archive'
  refute_output --partial 'cp -r'
  refute_output --partial 'tar czf'
  refute_output --partial 'zip -r'
}

@test "self-test.yaml: the release upload attaches no hand-built asset (#924)" {
  # The other half of the same removal: leaving the upload glob behind keeps
  # a `files:` pattern that matches nothing, and action-gh-release turns an
  # unmatched pattern into a failed release. Asserted separately from the
  # assembly step so a half-done removal names WHICH half is left. Comments
  # are stripped for the same reason as above.
  run yaml_job_lines "${WF}" release
  assert_success
  refute_output --partial 'files:'
  refute_output --partial 'template-'
}

# why: The extraction has to live somewhere a spec can drive it AND somewhere
# that can exit non-zero; inline in the workflow it was neither. This is
# what stops it drifting back into a `run:` block where a no-match is a
# silent success.
@test "self-test.yaml: the release body is assembled by a script that can refuse (#926)" {
  # The inline awk this replaces printed everything between `## [<tag>]`
  # and the next `## [`, and nothing looked at the result. An awk that
  # matches nothing exits 0 and writes an EMPTY file, and
  # action-gh-release accepts an empty body_path, so a doc-only PR that
  # renamed one heading shipped a release whose whole body was the
  # autogenerated PR-title list -- green CI, no warning. The extraction
  # has to live somewhere a spec can drive it AND somewhere that exits
  # non-zero, which under `run:`'s `bash -e` fails the release.
  run yaml_job_lines "${WF}" release
  assert_success
  assert_output --partial 'script/release/release_notes.sh'
  refute_output --partial 'doc/changelog/CHANGELOG.md'
}

# why: With both sources the larger drowns the smaller: the measured v0.42.0
# body was 26,690 characters of which the curated part was five lines and
# the rest raw PR titles. The workflow input is the only place that choice
# is expressed, so it is the only place it can regress.
@test "self-test.yaml: the release page carries the curated notes alone (#926)" {
  # Passing a curated body AND `generate_release_notes: true` publishes
  # both, and the larger one wins by volume: the v0.42.0 body measured
  # 26,690 characters, of which the human-written part was the first five
  # lines and the rest was ~170 raw PR titles. Two sources, neither of
  # which is the release notes.
  run yaml_job_lines "${WF}" release
  assert_success
  assert_output --partial 'generate_release_notes: false'
  refute_output --partial 'generate_release_notes: true'
}

# ── bats-unit + bats-integration + coverage jobs ───────────────

@test "self-test.yaml: declares bats-fragile job (#677)" {
  run code_grep -E '^  bats-fragile:' "${WF}"
  assert_success
}

@test "self-test.yaml: bats-fragile is a single job (no shard matrix) (#677)" {
  # The 4-shard bats-unit matrix (which double-ran the same specs the
  # coverage matrix runs) is replaced with ONE plain job running only the
  # kcov-fragile specs the coverage matrix skips. No strategy.matrix here.
  run yaml_job_lines "${WF}" bats-fragile
  assert_success
  refute_output --partial 'strategy:'
  refute_output --partial 'matrix:'
  refute_output --partial 'shard:'
}

@test "self-test.yaml: bats-fragile invokes test.sh --bats-fragile (#677)" {
  run yaml_job_lines "${WF}" bats-fragile
  assert_success
  assert_output --partial './script/test/test.sh --bats-fragile'
}

@test "self-test.yaml: no bats-unit shard matrix remains after #677" {
  # The double-run bats-unit matrix is fully removed; coverage is the
  # primary unit gate and bats-fragile covers the kcov-skipped delta.
  run code_grep -E '^  bats-unit:' "${WF}"
  assert_failure
}

@test "self-test.yaml: declares bats-integration job (#377)" {
  run code_grep -E '^  bats-integration:' "${WF}"
  assert_success
}

@test "self-test.yaml: bats-integration invokes test.sh --bats-integration (#377)" {
  run yaml_job_lines "${WF}" bats-integration
  assert_success
  assert_output --partial './script/test/test.sh --bats-integration'
}

@test "self-test.yaml: declares coverage job (#377)" {
  run code_grep -E '^  coverage:' "${WF}"
  assert_success
}

@test "self-test.yaml: coverage now runs on PRs (gated on code_changed), not main-only (#615 amends #377)" {
  # restricted kcov to push-to-main (the serial 8-12min job was too
  # expensive for PRs). shards it so a PR shard is in the bats-unit
  # ballpark, and gates it on the same `code_changed` output as the other
  # PR-check jobs so PR coverage data exists for the gate. The old
  # push&&main-only `if:` is gone.
  run yaml_job_lines "${WF}" coverage
  assert_success
  assert_output --partial "if: needs.classify.outputs.code_changed == 'true'"
  refute_output --partial "if: github.event_name == 'push' && github.ref == 'refs/heads/main'"
}

@test "self-test.yaml: coverage runs as the primary kcov unit gate over a DYNAMIC shard matrix (#615 + #677 + #725)" {
  # Sharded kcov is the PRIMARY unit gate. The shard TOTAL is dynamic:
  # the matrix is built from compute-shards' JSON output via fromJSON, not a
  # hardcoded 1/4..4/4 list. fail-fast: false so one shard's failure doesn't
  # cancel the rest.
  run yaml_job_lines "${WF}" coverage
  assert_success
  assert_output --partial 'fail-fast: false'
  assert_output --partial 'shard: ${{ fromJSON(needs.compute-shards.outputs.shards) }}'
  refute_output --partial "shard: ['1/4', '2/4', '3/4', '4/4']"
  assert_output --partial 'compute-shards'
}

@test "self-test.yaml: compute-shards job emits a dynamic shard array from vars.CI_SHARDS (default 8, clamped) (#725)" {
  run yaml_job_lines "${WF}" compute-shards
  assert_success
  assert_output --partial 'shards: ${{ steps.gen.outputs.shards }}'
  assert_output --partial 'CI_SHARDS: ${{ vars.CI_SHARDS }}'
  assert_output --partial 'n="${CI_SHARDS:-8}"'
  assert_output --partial 'n > 12'
  assert_output --partial 'GITHUB_OUTPUT'
}

@test "self-test.yaml: coverage invokes test.sh --coverage-shard + uploads each shard report as a CI artifact (#710)" {
  # The kcov run is per-shard (--coverage-shard); each shard uploads its
  # kcov output (HTML + cobertura) as a CI artifact keyed by the shard
  # index, for the self-hosted coverage-gate to merge locally. No external
  # coverage-SaaS upload (the SaaS path is superseded by coverage_gate.sh).
  run yaml_job_lines "${WF}" coverage
  assert_success
  assert_output --partial './script/test/test.sh --coverage-shard ${{ matrix.shard }}'
  assert_output --partial 'actions/upload-artifact@v7'
  assert_output --partial 'name: coverage-shard-${{ strategy.job-index }}'
  assert_output --partial 'path: ./coverage'
}

@test "self-test.yaml: NO codecov reference anywhere in the workflow (#710)" {
  # The whole Codecov path (action, token, directory, per-shard flag) is
  # removed; coverage merge + gate is now self-hosted via coverage_gate.sh.
  run code_grep -i 'codecov' "${WF}"
  assert_failure
}

@test "self-test.yaml: declares a coverage-gate job that runs the self-hosted floor gate (#710)" {
  # The self-hosted coverage-floor gate: downloads every shard artifact
  # and runs coverage_gate.sh to merge the per-shard cobertura reports
  # into one line-weighted project rate, failing below COVERAGE_MIN. Joins
  # ci-rollup so the floor gates merge with no external SaaS.
  run code_grep -E '^  coverage-gate:' "${WF}"
  assert_success
  run yaml_job_lines "${WF}" coverage-gate
  assert_success
  assert_output --partial 'needs: [classify, coverage]'
  assert_output --partial "if: needs.classify.outputs.code_changed == 'true'"
  assert_output --partial 'actions/download-artifact@v8'
  assert_output --partial 'pattern: coverage-shard-*'
  assert_output --partial 'script/test/drivers/coverage_gate.sh'
}

@test "self-test.yaml: the system job supplies HOST_UID / HOST_GID to its bare compose run (#895)" {
  # The system job is the only one that drives `docker compose run`
  # directly instead of through test.sh, so it is the only one that has to
  # put the runner's ids in the environment compose interpolates. Without
  # them the service definition refuses to resolve.
  run yaml_job_lines "${WF}" system
  assert_success
  assert_output --partial 'HOST_UID="$(id -u)"'
  assert_output --partial 'HOST_GID="$(id -g)"'
  assert_output --partial 'docker compose run --rm ci-system'
}

# ── Run-scoped names ───────────────────────────────────────────
#
# The assertions below are made against the NAMING, not against an
# environment. `runs-on: ubuntu-latest` gives every job a fresh
# single-tenant VM, so no CI run can currently exhibit the collision these
# lock out; a test that passed only because jobs are isolated would prove
# nothing. Two renderings that differ ONLY by run identity are compared
# instead: if any name comes out equal, two jobs sharing a host share it.

@test "self-test.yaml: declares a workflow-level env block carrying the run identity (#900)" {
  run yaml_top_lines "${WF}" env
  assert_success
  assert_output --partial 'github.run_id'
  assert_output --partial 'github.run_attempt'
}

@test "self-test.yaml: every name the workflow creates differs between two concurrent runs (#900)" {
  local -a _a=() _b=()
  mapfile -t _a < <(_render_run_names 1001 1)
  mapfile -t _b < <(_render_run_names 1002 1)
  # test-tools tag + compose project + the key itself, at minimum.
  [ "${#_a[@]}" -ge 3 ] \
    || fail "expected at least 3 run-scoped names in the workflow env block, got ${#_a[@]}"
  [ "${#_a[@]}" -eq "${#_b[@]}" ]
  local _i
  for _i in "${!_a[@]}"; do
    [ "${_a[${_i}]}" != "${_b[${_i}]}" ] \
      || fail "name is CONSTANT across concurrent runs: ${_a[${_i}]}"
  done
}

@test "self-test.yaml: every name also differs between two attempts of ONE run (#900)" {
  # A re-run repeats the commit SHA and the checkout path, so a name keyed
  # to either is identical to the attempt that just left the leftovers
  # behind -- exactly when a stale artifact would be reused. run_attempt is
  # what separates them.
  local -a _a=() _b=()
  mapfile -t _a < <(_render_run_names 1001 1)
  mapfile -t _b < <(_render_run_names 1001 2)
  [ "${#_a[@]}" -ge 3 ]
  local _i
  for _i in "${!_a[@]}"; do
    [ "${_a[${_i}]}" != "${_b[${_i}]}" ] \
      || fail "name is CONSTANT across a re-run: ${_a[${_i}]}"
  done
}

@test "self-test.yaml: run identity is not a timestamp and not the commit SHA (#900)" {
  # A timestamp collides for two jobs that start in the same second and
  # cannot be traced back to a run; github.sha is shared by every job of a
  # run AND identical across re-runs. run_id + run_attempt are both in the
  # Actions UI, so a leftover names the run that made it.
  run yaml_top_lines "${WF}" env
  assert_success
  refute_output --partial 'github.sha'
  refute_output --partial 'date +'
}

@test "self-test.yaml: the run-scoped names come from ONE place, not per job (#900)" {
  # The fixed `test-tools:local` literal is what two jobs on one host used
  # to write over each other. No job may reintroduce it, and no job may
  # spell its own variant of the run-scoped tag either -- the workflow-level
  # env block is the single source every job inherits.
  run code_grep -F 'test-tools:local' "${WF}"
  assert_failure
  run code_grep -cE '^ +TEST_TOOLS_IMAGE:' "${WF}"
  assert_output '1'
  run code_grep -cE '^ +COMPOSE_PROJECT_NAME:' "${WF}"
  assert_output '1'
}

@test "self-test.yaml: the test-tools image every job builds carries the ownership label (#900)" {
  # The loaded test-tools image is the one artifact compose does not own,
  # so cleanup cannot ask compose "whose is this". Every path that puts it
  # in the runner's daemon -- the cached build, the inline build, the
  # pulled-and-retagged hot path -- stamps the run identity on it.
  run code_grep -c 'base.ci.run' "${WF}"
  assert_success
  [ "${output}" -ge 6 ] \
    || fail "expected the ownership label on every test-tools provisioning path, found ${output}"
}

@test "self-test.yaml: the acceptance scaffold is keyed to the run (#900)" {
  # The scaffolded consumer's directory basename becomes IMAGE_NAME, which
  # is what the image tag, the container name and the compose project are
  # all built from -- so one unique directory name makes all three unique.
  run yaml_job_lines "${WF}" acceptance
  assert_success
  assert_output --partial 'REPO_NAME="e2e_test-ci-${CI_RUN_KEY}"'
  # The throwaway probe network `just docker prune` is asserted against is
  # created by name: two concurrent runs creating one fixed name is a hard
  # failure ("network with name ... already exists"), not a silent share.
  # The `ci-` infix is not decoration -- it is the marker the age-based
  # backstop matches on, so every CI-created name has to carry it.
  assert_output --partial 'e2e_prune_probe-ci-${CI_RUN_KEY}'
  # Every leftover assertion is scoped to THIS run's artifacts; grepping
  # the bare `e2e_test` would read a concurrent run's container as this
  # run's leak.
  refute_output --partial "grep -q 'e2e_test'"
}

# ── Run-scoped cleanup ─────────────────────────────────────────
#
# A unique name per run means leftovers ACCUMULATE on a long-lived host
# instead of dying with the VM. Two layers cover each other: an exact
# per-run teardown that cannot run when the runner is killed, and an
# age-based sweep that cannot be precise. Both are ownership-scoped --
# the naive `docker system prune -a` would destroy a concurrent job's
# in-flight cache, which is the very thing the unique naming protects.

@test "self-test.yaml: every job that puts an image in the host daemon tears it down (#900)" {
  # The six docker-using jobs: hadolint, bats-fragile, bats-integration,
  # coverage, acceptance, system. Each one loads a test-tools image into
  # the runner's daemon, so each one has to hand it back.
  run code_grep -c 'script/ci/reclaim.sh' "${WF}"
  assert_success
  [ "${output}" -ge 6 ] \
    || fail "expected a reclaim step in every docker-using job, found ${output}"
  # Every reclaim step names the run it is allowed to remove.
  run code_grep -c -- '--run "\${CI_RUN_KEY}"' "${WF}"
  assert_success
  [ "${output}" -ge 6 ] \
    || fail "expected every reclaim step to be scoped to CI_RUN_KEY, found ${output}"
}

@test "self-test.yaml: teardown runs on failure too, not just on success (#900)" {
  # A job that fails halfway is the job most likely to have left something
  # behind, so the teardown cannot be conditional on the job passing.
  run code_grep -B2 'script/ci/reclaim.sh' "${WF}"
  assert_success
  assert_output --partial 'if: always()'
}

@test "self-test.yaml: cleanup is ownership-scoped, never a blanket prune (#900)" {
  # On a shared host `docker system prune -a` destroys a CONCURRENT job's
  # build cache and images. The naive fix for the leftover problem breaks
  # the thing the uniqueness was protecting.
  #
  # Asserted over the code lines: the prohibition is on the command a job
  # RUNS, and the rationale for it necessarily names the command it rules
  # out.
  run code_grep -E 'docker system prune|image prune -a|docker volume prune' "${WF}"
  assert_failure
}

@test "self-test.yaml: the age-based backstop uses a CI window, not the local defaults (#900)" {
  # prune.sh's defaults (networks 10m, images 24h) are tuned to a laptop.
  # A CI window has a hard floor instead: an artifact belonging to a LIVE
  # run can be as old as the longest a job may run, so anything shorter
  # than that ceiling deletes work in flight.
  run code_grep -c -- '--stale 12h' "${WF}"
  assert_success
  [ "${output}" -ge 6 ] \
    || fail "expected the CI-specific stale window on every reclaim step, found ${output}"
}
