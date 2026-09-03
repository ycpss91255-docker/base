#!/usr/bin/env bats
#
# release_test_tools_yaml_spec.bats — structural assertions for the
# `.github/workflows/release-test-tools.yaml` workflow.
#
# Locks the publish surface for the test-tools image consumed by every
# downstream Dockerfile.example (`FROM ${TEST_TOOLS_IMAGE} AS
# test-tools-stage`). The workflow has three publish modes; the first
# two ship behaviour that downstream CI depends on:
#
# 1. **Tag push (`v*`)** — multi-arch `:<version>` + `:latest`. Cuts
#    the release that downstream consumers pin via
#    `inputs.test_tools_version` on build-worker / publish-worker.
#
# 2. **Main push** (P2) — multi-arch `:main` rolling tag. The
#    template's own self-test.yaml pulls this in its Obtain step to
#    skip a from-source rebuild on every PR. The paths filter
#    restricts the trigger to commits that actually touched
#    Dockerfile.test-tools or this workflow, so most main-branch
#    merges don't churn GHCR.
#
# 3. **workflow_dispatch** — manual `:latest` republish. Bootstrap
#    path; kept un-filtered.
#
# Smoke test step uses `steps.tags.outputs.smoke` so it always pulls
# the tag the current trigger produced (rather than statically
# pulling :latest, which would leave a freshly-pushed :main
# unverified).
#
# why: Structural assertions for
# `.github/workflows/release-test-tools.yaml`. Locks the publish surface
# that downstream Dockerfile.example's `FROM ${TEST_TOOLS_IMAGE} AS
# test-tools-stage` depends on. The workflow has three publish modes:
#
# 1. **Tag push (`v*`)** — multi-arch `:<version>` + `:latest`. Cuts the
# release downstream consumers pin via `inputs.test_tools_version`. 2.
# **Main push** (#317 P2) — multi-arch `:main` rolling tag. Used by
# self-test.yaml's Obtain step to skip from-source rebuilds. Paths filter
# (gotcha 3) restricts to commits that touched
# `dockerfile/Dockerfile.test-tools` or this workflow. 3.
# **workflow_dispatch** — manual `:latest` republish, kept unfiltered for
# bootstrap.
#
# Smoke step uses `steps.tags.outputs.smoke` so it always pulls the tag the
# current trigger produced (rather than statically pulling `:latest`, which
# would leave a freshly-pushed `:main` unverified).
#
# Grouped by concern:
#
# - Triggers on `v*` tag push (existing)
#
# - Triggers on main push (#317 P2)
#
# - Main push trigger has `paths:` filter limiting to Dockerfile.test-tools
# + workflow self (#317 P2 gotcha-3)
#
# - Triggers on `workflow_dispatch` (existing)
#
# - Resolve tags step: 3 publish modes (`v*` + `main` + dispatch) emit
# correct tag sets and `smoke` output
#
# - Smoke step pulls trigger's tag via `steps.tags.outputs.smoke` (#317 P2)
#
# - Native-runner matrix (#587): drops `setup-qemu-action`; `compute-matrix`
# maps platforms to native runners; build shards run on `matrix.runner`;
# build per-platform + push by digest; `merge` job creates the manifest via
# `imagetools`
#
# - Declares `packages: write` permission

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WF="/source/.github/workflows/release-test-tools.yaml"
  assert_spec_subject "${WF}" \
      "the test-tools release workflow this spec pins"
}

# _resolve_tags_step -- the code lines of the "Resolve tags" step, up to the
# next step. Comment-stripped: the step's prose explains the three publish
# modes by NAME, so an unstripped block lets the explanation stand in for the
# branch that implements it.
_resolve_tags_step() {
  awk '/Resolve tags/{flag=1} /^      - name:/{ if (flag && !first) {first=1; next} else if (flag) {flag=0}} flag' "${WF}" \
    | strip_comments
}

# _smoke_step -- the code lines from the "Smoke test pushed image" step on.
_smoke_step() {
  awk '/Smoke test pushed image/{flag=1} flag' "${WF}" | strip_comments
}

# ── Trigger surface ──────────────────────────────────────────────────

@test "release-test-tools.yaml: triggers on tag push v* (existing)" {
  run yaml_top_lines "${WF}" on
  assert_success
  assert_output --partial 'tags:'
  assert_output --partial "'v*'"
}

@test "release-test-tools.yaml: triggers on main push (#317 P2)" {
  run yaml_top_lines "${WF}" on
  assert_success
  assert_output --partial 'branches: [main]'
}

@test "release-test-tools.yaml: main push trigger has paths filter limiting to Dockerfile.test-tools + workflow self (#317 P2 gotcha-3)" {
  run yaml_top_lines "${WF}" on
  assert_success
  assert_output --partial 'paths:'
  assert_output --partial "'dockerfile/Dockerfile.test-tools'"
  assert_output --partial "'.github/workflows/release-test-tools.yaml'"
}

@test "release-test-tools.yaml: triggers on workflow_dispatch (existing)" {
  run yaml_top_lines "${WF}" on
  assert_success
  assert_output --partial 'workflow_dispatch:'
}

# ── Resolve tags step: 3 publish modes ───────────────────────────────

@test "release-test-tools.yaml: Resolve tags step handles v* tag push -> :<ver> + :latest" {
  run _resolve_tags_step
  assert_success
  assert_output --partial 'refs/tags/v*'
  assert_output --partial ':${ver}'
  assert_output --partial ':latest'
}

@test "release-test-tools.yaml: Resolve tags step handles main push -> :main rolling tag (#317 P2)" {
  run _resolve_tags_step
  assert_success
  assert_output --partial 'refs/heads/main'
  assert_output --partial ':main'
}

@test "release-test-tools.yaml: Resolve tags step emits a smoke output tracking the current trigger's tag (#317 P2)" {
  run _resolve_tags_step
  assert_success
  assert_output --partial 'smoke='
}

# ── Smoke test step ──────────────────────────────────────────────────

@test "release-test-tools.yaml: smoke step pulls the trigger's tag (not statically :latest) (#317 P2)" {
  # Avoids the regression where main push publishes :main but the
  # smoke step still pulls (and verifies) the stale :latest from the
  # previous tag.
  run _smoke_step
  assert_success
  assert_output --partial 'steps.tags.outputs.smoke'
}

# ── Native-runner matrix + push-by-digest + manifest merge ─────

@test "release-test-tools.yaml: drops docker/setup-qemu-action (native arm64 runner, #587)" {
  # Each arch builds on its native runner, so the QEMU emulation layer
  # is gone.
  run code_grep -F 'docker/setup-qemu-action' "${WF}"
  assert_failure
}

@test "release-test-tools.yaml: compute-matrix job maps platforms to native runners (#587)" {
  run code_grep -E '^  compute-matrix:' "${WF}"
  assert_success
  run code_grep -F 'ubuntu-24.04-arm' "${WF}"
  assert_success
  run code_grep -F 'ubuntu-latest' "${WF}"
  assert_success
}

@test "release-test-tools.yaml: build shards run on the matrix runner (#587)" {
  run code_grep -F 'runs-on: ${{ matrix.runner }}' "${WF}"
  assert_success
}

@test "release-test-tools.yaml: build shards build per-platform and push by digest (#587)" {
  # A single-arch build per shard pushed BY DIGEST (no tag); the tags
  # are applied by the merge job's manifest-list create. This is what
  # keeps the published tag a true multi-arch manifest instead of a
  # last-shard-wins single-arch overwrite.
  run code_grep -F 'platforms: ${{ matrix.platform }}' "${WF}"
  assert_success
  run code_grep -F 'push-by-digest=true' "${WF}"
  assert_success
}

@test "release-test-tools.yaml: merge job creates the multi-arch manifest via imagetools (#587)" {
  run code_grep -F 'docker buildx imagetools create' "${WF}"
  assert_success
}

@test "release-test-tools.yaml: declares packages: write permission for GHCR push" {
  run code_grep -E '^\s+packages:\s+write' "${WF}"
  assert_success
}

# ── Same-repository guard on the self-hosted-eligible build job ────────

@test "release-test-tools.yaml: the build job carries the same-repo guard (#766)" {
  # Self-hosted-eligible by the static rule: `runs-on: ${{ matrix.runner }}`
  # over a runtime-computed matrix. This workflow has no `pull_request`
  # trigger at all today, so the condition is inert -- it is here so that
  # adding one later cannot open the hole silently.
  run yaml_job_lines "${WF}" build
  assert_success
  assert_output --partial "github.event_name != 'pull_request' ||"
  assert_output --partial 'github.event.pull_request.head.repo.full_name == github.repository'
}

# ── Pin agreement: the smoke step compares versions, it does not print them ──
#
# The smoke step ran `shellcheck --version` and `hadolint --version` and
# asserted exit 0. That catches a tool that vanished; it cannot catch a tool
# that is the wrong version, which is the failure that actually happened --
# a hadolint pin sat 3.8 years stale behind a green gate, and the gate was
# reading "the binary starts" as "the binary is what the Dockerfile asked
# for". The two are only the same claim while nothing goes wrong.
#
# The comparison has to DERIVE the expected version from the pin rather than
# restate it in YAML: a hardcoded expectation in the workflow is a second
# place to forget, and a bump that updates the Dockerfile and not the
# workflow would fail for the wrong reason -- or, worse, a bump that updates
# both would prove only that two literals match each other.
#
# `hadolint --version` prints the version as a bare number ("Haskell
# Dockerfile Linter 2.15.1") while the pin is a tag ("v2.15.1"), so the
# comparison is on the number with the leading v stripped. Asserting the
# stripping happens is part of the rule: without it the check would compare
# "v2.15.1" against a line that never contains it and fail every run, which
# is the shape of a check that gets deleted rather than fixed.

# why: The precondition the other five rest on -- with no checkout in the
# merge job there is no Dockerfile to read the pins out of, and the whole
# comparison degrades to the exit-0 check it replaced
@test "release-test-tools.yaml: merge job checks out the repo so the smoke step can read the pins (#947)" {
  run grep -n 'actions/checkout' "${WF}"
  assert_success
  # Two call sites: the build shards, and the merge job the smoke step
  # lives in. One means the smoke step is comparing against nothing.
  [[ "$(grep -c 'actions/checkout' "${WF}")" -ge 2 ]]
}

# why: The expectation has to come from the pin: a version literal in the
# workflow would be a second place to bump, and two literals agreeing prove
# only that somebody edited both
@test "release-test-tools.yaml: smoke step reads the shellcheck pin from the Dockerfile (#947)" {
  run _smoke_step
  assert_success
  assert_output --partial 'dockerfile/Dockerfile.test-tools'
  assert_output --regexp 'shellcheck/releases/download'
}

# why: The pin that sat 3.8 years stale behind an exit-0 check -- the
# concrete drift this whole step was rewritten for, so its half of the
# comparison is asserted separately from shellcheck's
@test "release-test-tools.yaml: smoke step reads the hadolint pin from the Dockerfile (#947)" {
  run _smoke_step
  assert_success
  assert_output --regexp 'hadolint/releases/download'
}

# why: Reading two numbers is not comparing them: holding the pin and
# running `<tool> --version` still passes for an image whose linters are
# years old, which is exactly the state that shipped
@test "release-test-tools.yaml: smoke step COMPARES the reported versions, not just exit 0 (#947)" {
  run _smoke_step
  assert_success
  # The shipped binary's own report is captured and matched against the
  # pin. A step that only ran `<tool> --version` would have neither.
  assert_output --regexp 'shellcheck --version'
  assert_output --regexp 'hadolint --version'
  assert_output --partial 'expected_sc'
  assert_output --partial 'expected_hd'
}

# why: A comparison whose mismatch branch only warns is not a gate -- the
# publish would go out with the wrong linters and a green log
@test "release-test-tools.yaml: smoke step fails loudly when a pin and a binary disagree (#947)" {
  run _smoke_step
  assert_success
  # An exit non-zero on mismatch, with both values in the message -- a
  # comparison whose failure branch only warns is not a gate.
  assert_output --regexp 'exit 1'
}

# why: The failure mode a moved release URL produces: an empty expectation
# compared against an empty reading agrees with itself, which is the shape
# of pass the whole step exists to refuse
@test "release-test-tools.yaml: smoke step refuses an unreadable pin rather than passing (#947)" {
  run _smoke_step
  assert_success
  # A grep that matched nothing must not compare "" against "" and call it
  # agreement. The step names the empty case explicitly.
  assert_output --partial 'could not read'
}
