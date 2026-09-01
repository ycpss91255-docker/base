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
# property here is that the grant is DECLARED rather than inherited.
#
# Which scopes each worker names is pinned as an EXACT per-job set in that
# worker's OWN spec, and the last test here is what holds that division to
# its word: for every DERIVED reusable worker it requires some other spec
# in the tree that reads `yaml_permission_surface` for that very file, and
# names the worker that has none. The division was written here as a
# sentence twice already. The first time it was a promise about jobs and
# every grant outside build-worker.yaml was pinned by nothing -- widening
# one of them to `packages: write` passed the entire suite. The second time
# it was a promise about FILES, backed by an enumeration of the four specs
# that happened to exist, and a fifth worker landing with an unpinned
# `contents: write` still passed. A sentence cannot be the guard; the
# sentence names what the guard derives.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WORKFLOW_DIR="/source/.github/workflows"
  [[ -d "${WORKFLOW_DIR}" ]] || fail \
      "missing ${WORKFLOW_DIR} -- the workflow directory this spec scans. It is tracked, so it was moved or renamed: restore it or update the path here."
  SPEC_DIR="/source/test/bats"
  [[ -d "${SPEC_DIR}" ]] || fail \
      "missing ${SPEC_DIR} -- the spec tree this spec scans for per-worker permission pins. It is tracked, so it was moved or renamed: restore it or update the path here."
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
  if printf '%s\n' "${_files}" | grep 'BUG:' >/dev/null; then
    fail "reusable_workflow_files reported a failed scan: ${_files}"
  fi
  _count="$(printf '%s\n' "${_files}" | awk 'NF { n++ } END { print n + 0 }')"
  [[ "${_count}" -ge 4 ]] || fail \
      "expected at least the 4 reusable workers this repo ships, derived ${_count} from ${WORKFLOW_DIR} -- a scan over an empty population passes by saying nothing"
  printf '%s\n' "${_files}" \
      | grep -x -- "${WORKFLOW_DIR}/build-worker.yaml" >/dev/null || fail \
      "build-worker.yaml is missing from the derived reusable-worker list: either it stopped declaring on: workflow_call, or the derivation stopped seeing the directory"
  # A second reading, over the raw text rather than the parse: every
  # workflow whose CODE lines mention `workflow_call` at all must be in the
  # derived list, and nothing else may be. The derivation reads `on` as a
  # KEY, so it is blind in a way this is not -- an `on:` spelling it stopped
  # resolving would drop a worker out of the list silently, and the file
  # would still be sitting there with the word in it.
  local _f _mentions _derived
  for _f in "${WORKFLOW_DIR}"/*.yaml "${WORKFLOW_DIR}"/*.yml; do
    [[ -f "${_f}" ]] || continue
    _mentions=0
    code_grep -F -- 'workflow_call' "${_f}" >/dev/null || _mentions=$?
    [[ "${_mentions}" -eq 0 || "${_mentions}" -eq 1 ]] || fail \
        "grep exited ${_mentions} reading ${_f} -- a scan that could not read its input is not a scan that found nothing"
    _derived=1
    printf '%s\n' "${_files}" | grep -x -- "${_f}" >/dev/null || _derived=0
    if [[ "${_mentions}" -eq 0 && "${_derived}" -eq 0 ]]; then
      fail "${_f} names workflow_call in its code but is not in the derived reusable-worker list: the trigger derivation cannot see how this file spells 'on:', so every least-privilege scan below skips it"
    fi
    if [[ "${_mentions}" -eq 1 && "${_derived}" -eq 1 ]]; then
      fail "${_f} is in the derived reusable-worker list but its code lines never name workflow_call: the two readings disagree, and neither may be picked over the other"
    fi
  done
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
        # A surface the parser could not produce is reported, never
        # skipped: an unreadable worker is a worker nothing scanned.
        'BUG:'*)           printf '%s: %s\n' "${_file##*/}" "${_line}" ;;
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
  local _file _names _count _status
  while IFS= read -r _file; do
    [[ -n "${_file}" ]] || continue
    _status=0
    _names="$(yaml_job_names "${_file}")" || _status=$?
    if [[ "${_status}" -ne 0 ]]; then
      printf '%s: %s\n' "${_file##*/}" "${_names}"
      continue
    fi
    _count="$(printf '%s\n' "${_names}" | awk 'NF { n++ } END { print n + 0 }')"
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

# Every spec file in the tree -- other than this one -- whose code lines
# call `yaml_permission_surface`, i.e. every spec that pins what a
# workflow's jobs may name rather than merely that they name something.
# DERIVED with `find` over the spec tree, so a per-worker spec written
# tomorrow counts the day it lands.
#
# This file EXCLUDES ITSELF on purpose, and the exclusion is what makes the
# check honest: this spec reads `yaml_permission_surface` for every worker
# and names build-worker.yaml in its own population floor, so counting
# itself would let it certify every worker as pinned -- by itself, which
# asserts the opposite property (that a grant is declared, never which
# grant).
#
# grep's status is pinned: 0 is a match, 1 is a spec that does not read a
# surface, and anything else is a scan that could not read its input --
# emitted as a `BUG:` line so it fails the caller's assertion instead of
# being counted as "this spec pins nothing".
_specs_reading_a_permission_surface() {
  local _spec _status
  while IFS= read -r _spec; do
    [[ -n "${_spec}" ]] || continue
    [[ "${_spec##*/}" != "${BATS_TEST_FILENAME##*/}" ]] || continue
    _status=0
    code_grep -F -- 'yaml_permission_surface' "${_spec}" >/dev/null \
        || _status=$?
    case "${_status}" in
      0) printf '%s\n' "${_spec}" ;;
      1) ;;
      *) printf 'BUG: grep exited %s reading %s\n' "${_status}" "${_spec}" ;;
    esac
  done < <(find "${SPEC_DIR}" -type f -name '*.bats' | sort)
}

# The population the per-worker-pin scan reads, asserted before it is read.
# The floor is DERIVED, not guessed: one spec per reusable worker is the
# minimum that can satisfy the property at all, so fewer surface-reading
# specs than derived workers is already a failure -- and zero of them,
# which is what a moved spec tree or a `find` that matched nothing would
# produce, would otherwise report "every worker is pinned".
_assert_surface_spec_population() {
  local _specs _spec_count _workers _worker_count
  _specs="$(_specs_reading_a_permission_surface)"
  if printf '%s\n' "${_specs}" | grep 'BUG:' >/dev/null; then
    fail "the spec scan could not read part of ${SPEC_DIR}: ${_specs}"
  fi
  _spec_count="$(printf '%s\n' "${_specs}" \
      | awk 'NF { n++ } END { print n + 0 }')"
  _workers="$(reusable_workflow_files "${WORKFLOW_DIR}")"
  _worker_count="$(printf '%s\n' "${_workers}" \
      | awk 'NF { n++ } END { print n + 0 }')"
  [[ "${_spec_count}" -ge "${_worker_count}" ]] || fail \
      "found ${_spec_count} spec(s) reading a permission surface under ${SPEC_DIR} for ${_worker_count} derived reusable worker(s) -- at most ${_spec_count} of them can be pinned, and a scan over an empty spec list would have reported all of them clean"
}

# Print `<workflow>: <reason>` for every DERIVED reusable worker whose
# permission surface no other spec reads -- the worker whose grants are
# bounded by nothing but the sentence at the top of this file.
#
# The match is on the worker's FULL path rather than its basename: every
# per-worker spec addresses its subject as
# `/source/.github/workflows/<name>.yaml`, and a basename match would let
# multi_distro_build_worker_yaml_spec.bats -- whose subject's name ENDS
# with `build-worker.yaml` -- stand in as build-worker.yaml's pin. A spec
# that addresses its subject some other way reads here as "unpinned",
# which fails loudly and is fixed by naming the path; it cannot pass a
# worker nothing pins.
_reusable_workers_with_no_surface_spec() {
  local _file _specs _spec _pinned _status
  _specs="$(_specs_reading_a_permission_surface)"
  while IFS= read -r _file; do
    [[ -n "${_file}" ]] || continue
    case "${_file}" in
      'BUG:'*) printf '%s\n' "${_file}"; continue ;;
    esac
    _pinned=''
    while IFS= read -r _spec; do
      [[ -n "${_spec}" ]] || continue
      case "${_spec}" in
        'BUG:'*) printf '%s\n' "${_spec}"; continue ;;
      esac
      _status=0
      code_grep -F -- "${_file}" "${_spec}" >/dev/null || _status=$?
      case "${_status}" in
        0) _pinned="${_spec}"; break ;;
        1) ;;
        *) printf 'BUG: grep exited %s reading %s\n' "${_status}" "${_spec}" ;;
      esac
    done <<< "${_specs}"
    [[ -n "${_pinned}" ]] || printf \
        '%s: no spec reads yaml_permission_surface for this file, so which scopes its jobs name is pinned by nothing\n' \
        "${_file##*/}"
  done < <(reusable_workflow_files "${WORKFLOW_DIR}")
}

@test "reusable workers: every one of them has a spec pinning its grants (#957)" {
  # The class-level half of the property. The two tests above assert that
  # every job of every reusable worker DECLARES a grant; WHICH scopes that
  # grant may name is deliberately left to each worker's own spec, and this
  # is what makes that delegation checkable rather than a claim in a
  # comment. A reusable worker added tomorrow with `contents: write` on
  # every job satisfies both tests above -- it declared, after all -- and
  # is named here until a spec pins its surface.
  _assert_reusable_worker_population
  _assert_surface_spec_population
  run _reusable_workers_with_no_surface_spec
  assert_success
  assert_output ''
}
