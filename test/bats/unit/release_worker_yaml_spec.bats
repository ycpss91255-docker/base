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
  run bash -c "sed -n '/name: Create release archive/,/name: Create GitHub Release/p' '${WF}' | sed -n '/run: |/,\$p' | grep -nF '\${{'"
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
