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
# `*.yaml` and every `*.yml` under the workflow directory whose `on:`
# mapping declares `workflow_call`, read through `workflow_files`, which
# is where that extension set is written and nowhere else -- so a
# reusable worker added tomorrow is covered the day it lands, and so is a
# job added to one.
#
# What this spec deliberately does NOT assert is WHICH scopes a job may
# name: publish-worker's jobs legitimately hold `packages: write` and
# release-worker's release job legitimately holds `contents: write`. The
# property here is that the grant is DECLARED rather than inherited.
#
# Which scopes each worker names is pinned as an EXACT per-job set in that
# worker's OWN spec, and the last test here is what holds that division to
# its word: for every DERIVED reusable worker it requires some other spec
# in the tree that APPLIES `yaml_permission_surface` to that very file --
# resolved from the call's own argument -- and names the worker that has
# none. The division was written here as a sentence three times before it
# was a guard. First as a promise about jobs: every grant outside
# build-worker.yaml was pinned by nothing, and widening one of them to
# `packages: write` passed the entire suite. Then as a promise about FILES
# backed by an enumeration of the four specs that happened to exist, where
# a fifth worker landing with an unpinned `contents: write` still passed.
# Then as two independent substring questions of one file -- does its text
# name the function, does its text name the worker -- which certified a
# worker whose surface the spec never reads: appending one call about
# build-worker.yaml to a spec that merely MENTIONS release-worker.yaml
# certified release-worker.yaml, and two of today's four workers sit one
# such line away. A sentence cannot be the guard, and neither can a pair of
# questions that never meet; the sentence names what the guard derives.

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
  #
  # It enumerates the directory through `workflow_files`, the same
  # enumeration the derived list is drawn from, rather than repeating the
  # extension glob: a second reading that disagreed about which FILES the
  # directory holds could not report a disagreement about which of them is
  # a worker.
  local _f _mentions _derived
  while IFS= read -r _f; do
    [[ -n "${_f}" ]] || continue
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
  done < <(workflow_files "${WORKFLOW_DIR}")
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

# Every `yaml_permission_surface` call site in the spec tree -- other than
# this file's own -- resolved to the workflow file it is applied TO.
# DERIVED twice over: `find` over the spec tree, so a per-worker spec
# written tomorrow counts the day it lands, and `spec_permission_surface_subjects`
# over each call's own ARGUMENT, so a spec that merely NAMES a worker
# somewhere in its text is not mistaken for one that pins it.
#
# The pair this replaces asked two independent substring questions of the
# same file -- does its text contain `yaml_permission_surface`, does its
# text contain the worker's path -- and certified the worker when both
# answered yes, whatever file the call was applied to. Two of today's four
# workers are named by a spec that reads no surface at all, so appending
# one call about worker A to that spec certified worker B.
#
# This file EXCLUDES ITSELF, and the reason is structural rather than
# textual. This spec reads the surface of EVERY derived worker, in a loop,
# to assert the COMPLEMENTARY property: that a job declares a grant, never
# which grant. Letting it answer "some spec reads this worker's surface"
# would answer the question with the one scan that deliberately pins no
# scope. On today's tree the exclusion changes no verdict -- the loop's
# argument is a loop variable, which resolves to `UNRESOLVED:` and pins
# nothing either way -- and that is exactly why it is written down: it is
# what keeps the property true if the loop is ever rewritten around a
# literal path.
#
# Statuses are pinned, never `|| true`: 0 is a spec with call sites, 1 is a
# spec that calls the surface nowhere, and anything else is a spec that
# could not be read -- emitted as a `BUG:` line so it fails the caller's
# assertion instead of quietly shrinking the certified population.
_pinned_surface_subjects() {
  local _spec _status
  while IFS= read -r _spec; do
    [[ -n "${_spec}" ]] || continue
    [[ "${_spec##*/}" != "${BATS_TEST_FILENAME##*/}" ]] || continue
    _status=0
    spec_permission_surface_subjects "${_spec}" || _status=$?
    case "${_status}" in
      0|1) ;;
      *) printf 'BUG: spec_permission_surface_subjects exited %s reading %s\n' \
             "${_status}" "${_spec}" ;;
    esac
  done < <(find "${SPEC_DIR}" -type f -name '*.bats' | sort)
}

# The population the per-worker-pin scan reads, asserted before it is read.
# The floor is DERIVED, not guessed: one surface CALL SITE per reusable
# worker is the minimum that can satisfy the property at all, so fewer call
# sites than derived workers is already a failure -- and zero of them,
# which is what a moved spec tree or a `find` that matched nothing would
# produce, would otherwise report "every worker is pinned".
_assert_surface_spec_population() {
  local _subjects _site_count _workers _worker_count
  _subjects="$(_pinned_surface_subjects)"
  if printf '%s\n' "${_subjects}" | grep 'BUG:' >/dev/null; then
    fail "the spec scan could not read part of ${SPEC_DIR}: ${_subjects}"
  fi
  _site_count="$(printf '%s\n' "${_subjects}" \
      | awk 'NF { n++ } END { print n + 0 }')"
  _workers="$(reusable_workflow_files "${WORKFLOW_DIR}")"
  _worker_count="$(printf '%s\n' "${_workers}" \
      | awk 'NF { n++ } END { print n + 0 }')"
  [[ "${_site_count}" -ge "${_worker_count}" ]] || fail \
      "found ${_site_count} yaml_permission_surface call site(s) under ${SPEC_DIR} for ${_worker_count} derived reusable worker(s) -- at most ${_site_count} of them can be pinned, and a scan over an empty spec list would have reported all of them clean"
}

# Print `<workflow>: <reason>` for every DERIVED reusable worker that no
# other spec applies `yaml_permission_surface` to -- the worker whose
# grants are bounded by nothing but the sentence at the top of this file.
#
# The match is on the worker's FULL path, and it is an EXACT line match on
# a RESOLVED subject rather than a substring of the spec's text: a
# substring match would let multi_distro_build_worker_yaml_spec.bats --
# whose subject's name ENDS with `build-worker.yaml` -- stand in as
# build-worker.yaml's pin. A spec whose call this cannot resolve reads here
# as "unpinned", which fails loudly and is fixed by naming the path.
#
# What a subject certifies is stated where it is derived
# (spec_permission_surface_subjects): a call-shaped, unquoted occurrence of
# the helper whose argument resolves to this file. Text that merely NAMES
# the worker -- in prose, in a string, in a heredoc fixture the spec writes
# -- is not one. What it does not certify is that the caller ASSERTS
# anything on the surface it reads: a call site is where a surface is READ,
# and that is the widest property this scan can honestly claim.
_reusable_workers_with_no_surface_spec() {
  local _file _subjects _status
  _subjects="$(_pinned_surface_subjects)"
  # Any BUG line the spec scan produced is reported HERE too, not only in
  # the population assertion: this function is what the test reads, and a
  # BUG line that reached only the assertion would leave the scan itself
  # answering over a population it knows is short.
  _status=0
  printf '%s\n' "${_subjects}" | grep 'BUG:' || _status=$?
  if [[ "${_status}" -gt 1 ]]; then
    printf 'BUG: grep exited %s scanning the resolved subjects\n' "${_status}"
  fi
  while IFS= read -r _file; do
    [[ -n "${_file}" ]] || continue
    case "${_file}" in
      'BUG:'*) printf '%s\n' "${_file}"; continue ;;
    esac
    _status=0
    printf '%s\n' "${_subjects}" | grep -Fx -- "${_file}" >/dev/null \
        || _status=$?
    case "${_status}" in
      0) ;;
      1) printf '%s: no spec applies yaml_permission_surface to this file, so which scopes its jobs name is pinned by nothing\n' \
             "${_file##*/}" ;;
      *) printf 'BUG: grep exited %s matching %s against the resolved subjects\n' \
             "${_status}" "${_file}" ;;
    esac
  done < <(reusable_workflow_files "${WORKFLOW_DIR}")
}

@test "reusable workers: every one of them has a spec reading its permission surface (#957)" {
  # The class-level half of the property. The two tests above assert that
  # every job of every reusable worker DECLARES a grant; WHICH scopes that
  # grant may name is deliberately left to each worker's own spec, and this
  # is what makes that delegation checkable rather than a claim in a
  # comment. A reusable worker added tomorrow with `contents: write` on
  # every job satisfies both tests above -- it declared, after all -- and
  # is named here until a spec reads ITS permission surface.
  #
  # The name says READING rather than PINNING on purpose. What this can
  # check is that some spec applies the surface to that file; that the spec
  # then ASSERTS the exact scope set is a property of the assertion, which
  # no scan over call sites can see. The wider name was the one a future
  # author would have read as a guarantee it does not give.
  _assert_reusable_worker_population
  _assert_surface_spec_population
  run _reusable_workers_with_no_surface_spec
  assert_success
  assert_output ''
}
