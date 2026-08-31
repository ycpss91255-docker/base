#!/usr/bin/env bats
#
# reusable_worker_permissions_spec.bats -- least privilege across EVERY
# reusable workflow in `.github/workflows/`, not one named file.
#
# A workflow that declares `on: workflow_call` runs its jobs under the
# CALLING repo's token. A job in such a workflow that declares no
# `permissions:` of its own therefore inherits whatever the caller granted
# workflow-wide -- a downstream repo's `contents: write`, or its
# `packages: write` -- for jobs that only ever read. Declaring a block is
# the only place base can bound a permission it does not own; the block
# caps the job at what it names (the caller may cap it lower, never the
# other way).
#
# The originating issue was filed against build-worker.yaml and fixed
# there. This spec exists because the guard that proved it was written as a
# loop over that file's five job names, which exempted the sibling worker
# next door:
# multi-distro-build-worker.yaml had three jobs and no `permissions:` line
# anywhere, and nothing was red. The population here is DERIVED -- every
# `*.yaml` under the workflow directory whose `on:` mapping declares
# `workflow_call` -- so a reusable worker added tomorrow is covered the day
# it lands, and so is a job added to one.
#
# What this spec deliberately does NOT assert is WHICH scopes a job may
# name: publish-worker's jobs legitimately hold `packages: write` and
# release-worker's release job legitimately holds `contents: write`. The
# exact-set assertions for one worker's grants live with that worker's
# spec (build_worker_yaml_spec.bats). The property here is that the grant
# is DECLARED rather than inherited.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WORKFLOW_DIR="/source/.github/workflows"
  [[ -d "${WORKFLOW_DIR}" ]] || fail \
      "missing ${WORKFLOW_DIR} -- the workflow directory this spec scans. It is tracked, so it was moved or renamed: restore it or update the path here."
}

# The reusable workers in the directory, derived from each file's `on:`
# mapping. Asserted before any scan reads its result, because "no worker
# leaks a permission" and "no worker was found" print the same empty
# output otherwise.
#
# The floor is four -- the reusable workers the repo ships today -- and
# build-worker.yaml is named because it is the file the originating issue
# was filed against; both are a floor, never a roster. Every assertion runs
# over whatever the derivation returns.
_assert_reusable_worker_population() {
  local _files _count
  _files="$(reusable_workflow_files "${WORKFLOW_DIR}")"
  _count="$(printf '%s\n' "${_files}" | awk 'NF { n++ } END { print n + 0 }')"
  [[ "${_count}" -ge 4 ]] || fail \
      "expected at least the 4 reusable workers this repo ships, derived ${_count} from ${WORKFLOW_DIR} -- a scan over an empty population passes by saying nothing"
  printf '%s\n' "${_files}" \
      | grep -x -- "${WORKFLOW_DIR}/build-worker.yaml" >/dev/null || fail \
      "build-worker.yaml is missing from the derived reusable-worker list: either it stopped declaring on: workflow_call, or the derivation stopped seeing the directory"
  if printf '%s\n' "${_files}" | grep 'BUG:' >/dev/null; then
    fail "reusable_workflow_files reported a failed scan: ${_files}"
  fi
}

# Print `<workflow>: <job>` for every job of every reusable worker that
# declares no permission ENTRY of its own -- no block, or an inline
# `permissions: read-all` that names no scope. Both leave the job running
# on a grant base does not control.
_jobs_inheriting_the_callers_grant() {
  local _file _line
  while IFS= read -r _file; do
    [[ -n "${_file}" ]] || continue
    while IFS= read -r _line; do
      case "${_line}" in
        *": <no entries>") printf '%s: %s\n' "${_file##*/}" "${_line%%:*}" ;;
      esac
    done < <(yaml_permission_surface "${_file}")
  done < <(reusable_workflow_files "${WORKFLOW_DIR}")
}

# Print `<workflow>` for every reusable worker the job derivation found no
# job in. A workflow with zero jobs is not a clean workflow, it is a file
# the extractor could not read -- and it would otherwise contribute
# silently nothing to the scan above.
_reusable_workers_with_no_jobs() {
  local _file _count
  while IFS= read -r _file; do
    [[ -n "${_file}" ]] || continue
    _count="$(yaml_job_names "${_file}" | awk 'END { print NR }')"
    [[ "${_count}" -gt 0 ]] || printf '%s\n' "${_file##*/}"
  done < <(reusable_workflow_files "${WORKFLOW_DIR}")
}

@test "reusable workers: every one of them yields at least one job (#957)" {
  # The guard for the guard. Every assertion in this file is "nothing came
  # back wrong", which an extractor that returns nothing at all satisfies
  # perfectly.
  _assert_reusable_worker_population
  run _reusable_workers_with_no_jobs
  assert_success
  assert_output ''
}

@test "reusable workers: no job inherits the caller's grant (#957)" {
  # The property the originating issue is about, over every reusable worker
  # rather than the one it happened to name. A job listed here runs under the
  # CALLING repo's whole token: whatever that repo granted its calling job
  # -- `contents: write` to cut a release, `packages: write` to publish --
  # reaches a job of base's that never asked for it.
  _assert_reusable_worker_population
  run _jobs_inheriting_the_callers_grant
  assert_success
  assert_output ''
}
