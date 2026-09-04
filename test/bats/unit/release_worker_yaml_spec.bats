#!/usr/bin/env bats
#
# release_worker_yaml_spec.bats — structural assertions for the
# `.github/workflows/release-worker.yaml` reusable workflow's archive
# step.
#
# The archive step used to hardcode the payload as operands of one
# `cp -r`. `cp` aborts non-zero on a missing operand and the `run:` step is
# `bash -e`, so any consumer lacking one standard path lost its release at
# tag push -- twice, on a different path each time (first the root wrappers
# `build.sh` / `run.sh` / `exec.sh` / `stop.sh` / `setup_tui.sh` after they
# moved into `script/`, then `test/smoke/` after the smoke tree moved to
# `test/bats/smoke/`). Both times the fix was to re-edit the list to match
# base's own layout, which is what makes a base layout change a breaking
# change for every consumer shaped differently.
#
# The payload now lives in a declared manifest and is assembled by
# script/ci/release-archive.sh, host-testable under `just test` (the same
# split preflight.sh already uses in this file). These tests lock the
# workflow's half of that: the base checkout is version-matched to the
# worker, the archive step calls the script rather than reconstructing a
# path list, and caller input reaches the shell through `env:` instead of
# being interpolated into the run block. The payload's own behaviour is
# covered by release_archive_spec.bats (engine) and
# release_archive_contract_spec.bats (the real manifest).
#
# why: Structural assertions for `.github/workflows/release-worker.yaml`'s
# archive step. The step used to hardcode the payload as operands of one `cp
# -r`; `cp` aborts non-zero on a missing operand and the `run:` step is
# `bash -e`, so any consumer lacking one standard path lost its release at
# tag push -- twice, on a different path each time (#558, then #914), each
# fixed by re-editing the list to match base's own layout. The payload now
# lives in a declared manifest assembled by `script/ci/release-archive.sh`;
# these tests lock the workflow's half of that split (the payload's own
# behaviour is covered by `release_archive_spec.bats` and
# `release_archive_contract_spec.bats`).
#
# Grouped by concern:
#
# - No hardcoded payload path list survives in the workflow (#914)
#
# - Archive step delegates to the assembler + its declared manifest
#
# - Assembler is version-matched to the worker (`job_workflow_sha`, checkout
# path)
#
# - Caller input reaches the step via `env:`, never run-block interpolation
#
# - Every job's grant pinned as an exact per-job entry set, over the job
# list derived from the file (`preflight: contents: read`, `release:
# contents: write`)
#
# - The released version is RESOLVED (`script/ci/release-version.sh`) rather
# than read off `github.ref_name`, so the worker can be called directly by a
# downstream repo auto-releasing a merged dependency bump -- a run that has no
# tag ref to read (#829)

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WF="/source/.github/workflows/release-worker.yaml"
  assert_spec_subject "${WF}" \
      "the reusable release worker this spec pins"
}

# ── the payload is not reconstructed in the workflow ─────────────────────────

@test "release-worker.yaml: archive step names no hardcoded payload path list (#914)" {
  # A multi-operand `cp -r <path> <path> ... "${ARCHIVE_NAME}/"` is the
  # defect itself: `bash -e` plus one absent operand equals no release.
  run grep -nE '^[[:space:]]*cp -r ' "${WF}"
  if [ "${status}" -eq 0 ]; then
    echo "archive step still copies a hardcoded path list:"
    echo "${output}"
    return 1
  fi
}

@test "release-worker.yaml: archive step delegates to script/ci/release-archive.sh (#914)" {
  run code_grep -F 'script/ci/release-archive.sh' "${WF}"
  assert_success
}

@test "release-worker.yaml: archive step passes the declared payload manifest (#914)" {
  run code_grep -F 'script/ci/release/archive.manifest' "${WF}"
  assert_success
}

# ── the assembler is version-matched to the worker ───────────────────────────

@test "release-worker.yaml: release job checks out base at github.job_workflow_sha (#914)" {
  # Same rule the preflight job follows: the script the worker runs must
  # come from the SAME ref as the worker, or a consumer pinned to an old
  # tag would run today's assembler against yesterday's contract.
  run code_grep -c 'ref: ${{ github.job_workflow_sha }}' "${WF}"
  assert_success
  assert_output "2"
}

@test "release-worker.yaml: the base checkout the archive step runs is the one it reads (#914)" {
  # The checkout path and the script path must agree; a rename of one
  # without the other fails only at tag time.
  run code_grep -F 'path: .release-base' "${WF}"
  assert_success
  run code_grep -F '.release-base/script/ci/release-archive.sh' "${WF}"
  assert_success
}

# ── caller input reaches the shell through env, not interpolation ────────────

@test "release-worker.yaml: extra_files reaches the archive step via env (#914)" {
  run code_grep -F 'RELEASE_EXTRA_FILES: ${{ inputs.extra_files }}' "${WF}"
  assert_success
}

@test "release-worker.yaml: no caller input is interpolated into the archive run block (#914)" {
  # `${{ inputs.* }}` expanded inside `run:` splices caller-controlled text
  # into the shell before bash sees it. Every input the step needs is bound
  # in `env:` instead.
  #
  # The block is taken from the PARSED document, not from a line window.
  # The window ran from one step's name to a neighbour's, so inserting any
  # step between the two dragged the neighbour's `env:` block --
  # legitimately `${{ ... }}` -- into the range, and a comment paragraph
  # belonging to the next step sat inside it either way. And it read
  # nothing when the step was renamed: an empty read reported a clean
  # block. Reading `.run` gives exactly the shell, and a step that is not
  # there fails here.
  local _body
  _body="$(RW_STEP='Create release archive' yq -r \
      '.jobs.release.steps[] | select(.name == strenv(RW_STEP)) | .run' \
      "${WF}")"
  [[ -n "${_body}" && "${_body}" != 'null' ]] || fail \
    "${WF} has no 'Create release archive' step in its release job -- it was renamed, and this assertion had nothing to read."
  run grep -nF '${{' <<< "${_body}"
  if [ "${status}" -eq 0 ]; then
    echo "caller input interpolated into the archive run block:"
    echo "${output}"
    return 1
  fi
}

# ── Per-job least privilege ──────────────────────────────────────────────────

@test "release-worker.yaml: every job's grant is pinned as an exact set (#957)" {
  # `contents: write` on `release` is the legitimate case here:
  # softprops/action-gh-release creates a GitHub Release, which is a write
  # to the repository's contents. `preflight` only validates the caller's
  # inputs, so it reads.
  #
  # Pinned as an exact SET rather than a presence check, because this is a
  # reusable workflow and both directions are failures: a scope the caller
  # did not grant fails their whole run before it starts, and a scope
  # nobody noticed being added is exactly the elevation this guard is
  # about. The job list is DERIVED from the file, so a third job is named
  # here on the day it lands, and a `BUG:` line from an unreadable file
  # fails this rather than passing it.
  run yaml_permission_surface "${WF}"
  assert_success
  assert_output 'preflight: contents: read
release: contents: write'
}

# ── the released version is resolved, not read off the ref ───────────────────

# why: The input that makes a direct call possible at all. A downstream repo
# cannot auto-release by pushing a tag -- an event created with the default
# GITHUB_TOKEN starts no workflow run -- so it calls this worker with the
# version it computed. Declared optional with an empty default, so every
# existing tag-triggered caller keeps working unchanged (#829).
@test "release-worker.yaml: version is an optional input with an empty default (#829)" {
  run bash -c "grep -A4 '^      version:' '${WF}' | grep -F 'required: false'"
  assert_success
  run bash -c "grep -A4 '^      version:' '${WF}' | grep -F 'default: \"\"'"
  assert_success
}

# why: The resolution is a tested script, not an expression in the YAML. Same
# split as the preflight validator and the archive assembler: the logic runs
# under `just test`, the workflow keeps the GITHUB_OUTPUT plumbing (#829).
@test "release-worker.yaml: the version is resolved by script/ci/release-version.sh (#829)" {
  run code_grep -F '.release-base/script/ci/release-version.sh' "${WF}"
  assert_success
}

# why: The caller's input reaches the resolver through `env:`, the same rule
# the archive step follows -- an input interpolated into a `run:` block is
# caller-controlled text spliced into the shell before bash sees it (#829).
@test "release-worker.yaml: the version input reaches the resolver via env (#829)" {
  run code_grep -F 'RELEASE_VERSION_INPUT: ${{ inputs.version }}' "${WF}"
  assert_success
}

# why: Without an explicit tag_name the release action falls back to the ref
# that started the run, so a direct call would try to publish a release for a
# BRANCH. The tag is the resolved version, whichever source it came from
# (#829).
@test "release-worker.yaml: the release is cut for the resolved version (#829)" {
  run code_grep -F 'tag_name: ${{ steps.version.outputs.version }}' "${WF}"
  assert_success
}

# why: The archive name and the release tag must be the one value. The step
# used to build the name from GITHUB_REF_NAME, which on a direct call is a
# branch name -- an archive called `<repo>-main` attached to a release tagged
# vX.Y.Z (#829).
@test "release-worker.yaml: the archive is named from the resolved version (#829)" {
  run code_grep -F 'VERSION: ${{ steps.version.outputs.version }}' "${WF}"
  assert_success
  run code_grep -F 'GITHUB_REF_NAME' "${WF}"
  assert_failure
}

# why: The #1012 shape: a decision about a version read off a ref that does
# not carry one. `contains(github.ref_name, "-")` is false for every branch,
# so a direct call cutting an RC would publish it as a full release -- and
# `publish-worker` defaults consumers to whatever the newest full release
# left. The flag comes from the resolver, which derived it from the version
# actually being released (#829, refs #1012).
@test "release-worker.yaml: prerelease is derived from the resolved version, not the ref (#829)" {
  run code_grep -F 'steps.version.outputs.prerelease' "${WF}"
  assert_success
  run code_grep -F 'contains(github.ref_name' "${WF}"
  assert_failure
}
