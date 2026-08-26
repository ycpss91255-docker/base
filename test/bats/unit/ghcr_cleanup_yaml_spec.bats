#!/usr/bin/env bats
#
# ghcr_cleanup_yaml_spec.bats — structural assertions for the
# `.github/workflows/ghcr-cleanup.yaml` workflow.
#
# This workflow DELETES package versions from a registry on a schedule.
# It cannot be exercised end to end from here: there is no local GHCR,
# and a real run's only honest test is a real run. What a spec CAN do is
# make the workflow's shape a gated invariant, so the ways this goes
# catastrophically wrong fail in CI instead of on ghcr.io.
#
# Four classes of assertion, in descending order of what they cost if
# they ever stop holding:
#
# 1. **The footgun.** `actions/delete-package-versions` with
#    `delete-only-untagged-versions` deletes the per-arch child
#    manifests of a LIVE tag, because it calls anything the packages
#    API reports as untagged a candidate without ever opening a
#    manifest. That breaks `docker pull <live tag>` with a 404. The spec
#    asserts that action never appears here, and that the manifest-aware
#    action is the one in use.
#
# 2. **The safety inputs.** `delete-untagged` is the only delete rule;
#    the tag-matching and partial-image rules stay off; `older-than`
#    keeps a retention window; `exclude-tags` preserves the tags
#    downstream consumers pin; `validate` reports a lost platform child
#    in the log. An edit that flips any of these is the edit this spec
#    exists to catch.
#
# 3. **Dry-run defaults.** Enforcement is opt-in via the
#    `GHCR_CLEANUP_ENFORCE` repository variable, so a scheduled run
#    deletes nothing until a human has read a dry run and enabled it.
#    An edit that hardcodes `dry-run: false` removes the whole rollout
#    safety net.
#
# 4. **Scope and pinning.** One package (`test-tools`), one owner, no
#    wildcard expansion; the action pinned to an immutable commit SHA
#    rather than a floating tag it does not control.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WF="/source/.github/workflows/ghcr-cleanup.yaml"
  [[ -f "${WF}" ]] || skip "ghcr-cleanup.yaml not at expected path"
}

# _code_lines -- the workflow with comment-only and blank lines dropped.
#
# The header comment names the unsafe action and its input on purpose, to
# say why they are absent. A naive `grep -F` over the whole file would
# therefore match the WARNING and report the footgun as present, so every
# must-not-appear assertion runs against this instead. Trailing comments
# on a real line (the `# v1.2.2` after the pin) survive, because that line
# is code.
_code_lines() {
  grep -vE '^[[:space:]]*(#|$)' "${WF}"
}

# _block <top-level-key> -- the body of a top-level mapping (`on`,
# `permissions`, `concurrency`), comment and blank lines dropped. The
# stripping matters: a comment paragraph sitting between two top-level
# keys is not indented-out by the terminator, so without it a block would
# carry the prose that follows it.
_block() {
  awk -v _key="^${1}:" '$0 ~ _key {flag=1; next} /^[a-z]/{flag=0} flag' "${WF}" \
    | grep -vE '^[[:space:]]*(#|$)'
}

# _with_block -- the `with:` mapping of the cleanup step, comments and
# blank lines stripped. Asserting against this rather than the whole file
# keeps a value that merely appears in the prose from satisfying a test
# about what the action is actually configured with.
_with_block() {
  awk '/^        with:$/{flag=1; next} /^[^ ]|^      - /{flag=0} flag' "${WF}" \
    | grep -vE '^[[:space:]]*(#|$)'
}

# _exclude_tags -- just the comma-separated value of `exclude-tags`, on
# one line, so a per-tag assertion can anchor on `,` and end-of-string
# instead of pattern-matching across a multi-line blob.
_exclude_tags() {
  _with_block | sed -n 's/^[[:space:]]*exclude-tags:[[:space:]]*//p'
}

# ── The footgun: the unsafe action must never appear ─────────────────

@test "ghcr-cleanup.yaml: never uses actions/delete-package-versions" {
  # That action's untagged filter reads the packages API and never opens
  # a manifest, so it collects the per-arch children a live tag
  # references and breaks the tag.
  run _code_lines
  assert_success
  refute_output --partial 'delete-package-versions'
}

@test "ghcr-cleanup.yaml: never sets delete-only-untagged-versions" {
  # The specific input that makes the unsafe action destructive. Named
  # separately so a swap back is caught even if the action moves.
  run _code_lines
  assert_success
  refute_output --partial 'delete-only-untagged-versions'
}

@test "ghcr-cleanup.yaml: uses the manifest-aware dataaxiom/ghcr-cleanup-action" {
  run grep -F 'uses: dataaxiom/ghcr-cleanup-action@' "${WF}"
  assert_success
}

# ── Action pinning ───────────────────────────────────────────────────

@test "ghcr-cleanup.yaml: pins the cleanup action to an immutable commit SHA" {
  # A floating tag on the one third-party action holding packages: write
  # over a package we publish means a moved tag hands deletion rights to
  # unreviewed code.
  run grep -E 'uses: dataaxiom/ghcr-cleanup-action@[0-9a-f]{40}( |$)' "${WF}"
  assert_success
}

@test "ghcr-cleanup.yaml: records the pinned action's version in a trailing comment" {
  # Keeps the SHA readable and is the form Dependabot rewrites on bump.
  run grep -E 'uses: dataaxiom/ghcr-cleanup-action@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+' "${WF}"
  assert_success
}

# ── Safety inputs ────────────────────────────────────────────────────

@test "ghcr-cleanup.yaml: enables delete-untagged as the delete rule" {
  run _with_block
  assert_success
  assert_output --partial 'delete-untagged: true'
}

@test "ghcr-cleanup.yaml: leaves the tagged-image delete rules off" {
  # delete-tags / delete-ghost-images / delete-partial-images /
  # delete-orphaned-images can all remove TAGGED versions. Absent means
  # the action's own false default applies.
  run _with_block
  assert_success
  refute_output --partial 'delete-tags:'
  refute_output --partial 'delete-ghost-images:'
  refute_output --partial 'delete-partial-images:'
  refute_output --partial 'delete-orphaned-images:'
}

@test "ghcr-cleanup.yaml: keeps a retention window via older-than" {
  # Without it, a cleanup overlapping a release deletes the by-digest
  # single-arch pushes before the merge job tags them.
  run _with_block
  assert_success
  assert_output --regexp 'older-than: [0-9]+ (day|days|week|weeks|month|months)'
}

@test "ghcr-cleanup.yaml: preserves the tags downstream consumers pin" {
  # The three tag shapes release-test-tools.yaml publishes: the two
  # moving tags and the immutable release series.
  run _exclude_tags
  assert_success
  assert_output --regexp '(^|,)latest(,|$)'
  assert_output --regexp '(^|,)main(,|$)'
  assert_output --regexp '(^|,)v\*(,|$)'
}

@test "ghcr-cleanup.yaml: enables the post-run multi-arch validate scan" {
  run _with_block
  assert_success
  assert_output --partial 'validate: true'
}

# ── Dry-run defaults ─────────────────────────────────────────────────

@test "ghcr-cleanup.yaml: dry-run is computed, never hardcoded false" {
  run _with_block
  assert_success
  refute_output --partial 'dry-run: false'
  assert_output --partial 'dry-run: ${{ steps.mode.outputs.dry-run }}'
}

@test "ghcr-cleanup.yaml: workflow_dispatch dry-run input defaults to true" {
  run _block on
  assert_success
  assert_output --partial 'dry-run:'
  assert_output --partial 'default: true'
}

@test "ghcr-cleanup.yaml: scheduled runs stay dry until GHCR_CLEANUP_ENFORCE opts in" {
  # Enforcement is opt-in, so forgetting the rollout review costs
  # continued sprawl rather than a broken tag.
  run grep -F 'vars.GHCR_CLEANUP_ENFORCE' "${WF}"
  assert_success
  run grep -F 'ENFORCE}" == "true"' "${WF}"
  assert_success
}

@test "ghcr-cleanup.yaml: a dispatch deletes only on a literal false, not on anything-but-true" {
  # Fail-safe rather than fail-open: the dispatch branch opts INTO
  # deleting on an exact `false` and treats every other value -- empty
  # included, which is what an input declaration change would produce --
  # as dry-run.
  run _code_lines
  assert_success
  assert_output --partial 'INPUT_DRY_RUN}" == "false"'
  refute_output --partial 'INPUT_DRY_RUN}" == "true"'
}

@test "ghcr-cleanup.yaml: resolves dry-run in a step, not an && || expression" {
  # `a && b || c` collapses to `c` when b is false -- which here is the
  # dispatch-with-dry-run-false branch, the one case where getting it
  # wrong deletes what nobody asked to delete.
  run grep -E '^[[:space:]]+id: mode$' "${WF}"
  assert_success
  run _code_lines
  assert_success
  refute_output --partial 'inputs.dry-run ||'
}

# ── Scope ────────────────────────────────────────────────────────────

@test "ghcr-cleanup.yaml: targets exactly the test-tools package" {
  run _with_block
  assert_success
  assert_output --partial 'package: test-tools'
  assert_output --partial 'owner: ycpss91255-docker'
}

@test "ghcr-cleanup.yaml: does not enable wildcard package expansion" {
  # expand-packages would let one edit widen this from base's own
  # package to every package in the org.
  run _code_lines
  assert_success
  refute_output --partial 'expand-packages'
}

# ── Trigger surface and permissions ──────────────────────────────────

@test "ghcr-cleanup.yaml: runs on a cron schedule" {
  run _block on
  assert_success
  assert_output --partial 'schedule:'
  assert_output --regexp "cron: '[0-9*]"
}

@test "ghcr-cleanup.yaml: cron avoids the top of the hour" {
  # GitHub delays scheduled runs that pile onto :00.
  run _code_lines
  assert_success
  refute_output --regexp "cron: '0 "
}

@test "ghcr-cleanup.yaml: supports manual workflow_dispatch" {
  run _block on
  assert_success
  assert_output --partial 'workflow_dispatch:'
}

@test "ghcr-cleanup.yaml: declares packages: write and no broader write scope" {
  run _block permissions
  assert_success
  assert_output --partial 'packages: write'
  assert_output --partial 'contents: read'
  refute_output --partial 'contents: write'
}

@test "ghcr-cleanup.yaml: serialises runs and never cancels one mid-delete" {
  run _block concurrency
  assert_success
  assert_output --partial 'group:'
  assert_output --partial 'cancel-in-progress: false'
}
