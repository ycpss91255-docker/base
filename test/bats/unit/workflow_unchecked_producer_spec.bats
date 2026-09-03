#!/usr/bin/env bats
#
# workflow_unchecked_producer_spec.bats -- "no workflow step reads a loop
# from a producer whose failure it cannot see".
#
# why: `while ... done < <(cmd)` hands the loop cmd's OUTPUT and never cmd's
# STATUS: a loop's exit status is its own. `set -e` cannot see the failure,
# and `pipefail` does not reach it either -- a process substitution is no
# pipeline. A producer that fails therefore delivers ZERO LINES, and zero
# lines is a plausible answer to nearly every question a CI step asks: no
# paths changed, no stages declared, no artifacts to reclaim. The step then
# does less work than it was asked to and reports success for it.
#
# This is not a hypothetical shape. build-worker.yaml's doc-only classifier
# read `git diff --name-only base...head` exactly this way, so a
# force-pushed base or a shallow clone missing the base commit read as "no
# code changed" and took the REQUIRED docker-build check green having built
# nothing. Nothing in the tree could have caught it: shellcheck never sees
# a workflow `run:` block (it is not a shell FILE), and every behavioural
# test of such a step asserts what it does when the producer WORKED.
#
# The rule: capture the producer's output and check its status, then read
# the loop from the variable. An unreadable answer is not an empty one.
#
# Scope is the `run:` blocks of .github/workflows only. Shell under script/
# and dist/ is a different case -- there strict mode is at file scope, the
# early-close-reader lint already owns the pipeline half of this family,
# and shellcheck reads the file. A workflow step is where none of that
# reaches.
#
# The population is DERIVED from the directory, so a workflow added
# tomorrow is scanned the day it lands, and the last two cases assert the
# scan actually walked something -- an empty scan passes a "nothing found"
# assertion for the wrong reason.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WF_DIR=/source/.github/workflows
  assert_spec_subject_dir "${WF_DIR}" \
      "the workflow directory whose run blocks this spec scans"
  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/wf"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _unchecked_producers <dir>
#   One `<file>: <line>` for every run-block CODE line under <dir> that
#   opens a redirect from a process substitution.
#
#   Comment lines are dropped before the match. Prose explaining the rule
#   -- this header, and the note beside the captured diff in
#   build-worker.yaml that names the construct it replaced -- must not be a
#   violation of it, or the explanation becomes unwritable.
_unchecked_producers() {
  local _dir="${1}" _f _blocks _code _line _status
  local _files
  _files="$(workflow_files "${_dir}")"
  while IFS= read -r _f; do
    [[ -n "${_f}" ]] || continue
    _status=0
    _blocks="$(yaml_run_blocks "${_f}")" || _status=$?
    if [[ "${_status}" -ne 0 ]]; then
      printf 'BUG: could not read the run blocks of %s\n' "${_f}"
      continue
    fi
    _code="$(printf '%s\n' "${_blocks}" | grep -v '^[[:space:]]*#')" || :
    while IFS= read -r _line; do
      case "${_line}" in
        *'< <('*) printf '%s: %s\n' "${_f}" "${_line}" ;;
      esac
    done <<< "${_code}"
  done <<< "${_files}"
}

# _wf <name> <run-body-line>... -- a one-job, one-step workflow fixture.
_wf() {
  local _name="${1}"; shift
  {
    printf 'name: %s\n' "${_name}"
    printf 'on: [push]\n'
    printf 'jobs:\n  only:\n    runs-on: ubuntu-latest\n    steps:\n'
    printf '      - name: The step\n        run: |\n'
    printf '          %s\n' "$@"
  } > "${SCRATCH}/wf/${_name}.yaml"
}

# ── The scan detects the shape ─────────────────────────────────

# why: The rule bites, demonstrated over a fixture rather than the live
# tree -- the only occurrence in this repo was removed by the fix this
# spec accompanies, so without a fixture the scan would be asserting
# nothing and could not go red if it stopped matching.
@test "workflow run blocks: a loop fed by a process substitution is reported" {
  _wf offender \
    'while IFS= read -r f; do' \
    '  echo "${f}"' \
    'done < <(git diff --name-only base...head)'
  run _unchecked_producers "${SCRATCH}/wf"
  assert_success
  assert_output --partial 'offender.yaml'
  assert_output --partial 'done < <(git diff'
}

# why: The other half of a usable rule: the prescribed fix has to pass, or
# the lint tells authors what to stop doing without telling them what to
# write instead, and the first false positive is on the corrected code.
@test "workflow run blocks: capturing the producer and checking it is clean" {
  # The fix shape. The status is the assignment's, so `set -e` sees it and
  # the loop reads a value the step KNOWS it obtained.
  _wf checked \
    'if ! changed="$(git diff --name-only base...head)"; then' \
    '  exit 1' \
    'fi' \
    'while IFS= read -r f; do echo "${f}"; done <<< "${changed}"'
  run _unchecked_producers "${SCRATCH}/wf"
  assert_success
  assert_output ""
}

# why: This repo's own fix explains itself by quoting the construct it
# replaced, so a scan that cannot tell prose from code would make the
# explanation unwritable and push authors to delete the reasoning to get
# the lint green.
@test "workflow run blocks: a comment naming the shape is not the shape" {
  # The repo's own fix explains itself beside the capture, quoting the
  # construct it replaced. A scan that cannot tell prose from code makes
  # that explanation impossible to write.
  _wf prose \
    '# Read as `done < <(git diff ...)` the status would be the loop own.' \
    'changed="$(git diff --name-only base...head)"' \
    'echo "${changed}"'
  run _unchecked_producers "${SCRATCH}/wf"
  assert_success
  assert_output ""
}

# why: A pure `uses:` caller job contributes no run blocks, and this repo
# has several. If one aborted the walk the scan would report clean for the
# rest of the directory, which is the fail-open this whole spec exists to
# refuse.
@test "workflow run blocks: a job with no steps is scanned, not an error" {
  # A pure `uses:` caller job. It contributes no run blocks; it must not
  # abort the walk and take the rest of the directory with it.
  cat > "${SCRATCH}/wf/caller.yaml" <<'YAML'
name: caller
on: [push]
jobs:
  call:
    uses: ./.github/workflows/other.yaml
YAML
  run _unchecked_producers "${SCRATCH}/wf"
  assert_success
  assert_output ""
}

# ── The real tree ──────────────────────────────────────────────

# why: The rule applied to the live tree, over a population derived from
# the directory rather than listed here -- which is what makes a workflow
# added tomorrow scanned the day it lands instead of the day somebody
# remembers to add it.
@test "every workflow in this repo reads its producers checked" {
  run _unchecked_producers "${WF_DIR}"
  assert_success
  assert_output ""
}

# why: The non-vacuity case, and the one that keeps the live-tree case
# honest: an empty result satisfies "nothing found" whether the scan read
# every workflow or none of them, so the population and the run blocks it
# read are asserted rather than assumed.
@test "the scan really walked this repo's workflows, so a clean result means something" {
  # An empty result satisfies the case above whether the scan read every
  # workflow or none of them. Assert the population it walked and that the
  # blocks it read are the real ones.
  local _n=0 _f _all=""
  while IFS= read -r _f; do
    [[ -n "${_f}" ]] || continue
    _n=$(( _n + 1 ))
    _all+="$(yaml_run_blocks "${_f}")"
  done <<< "$(workflow_files "${WF_DIR}")"
  [ "${_n}" -ge 5 ] || {
    echo "only ${_n} workflow(s) walked"
    return 1
  }
  [ -n "${_all}" ]
  run yaml_run_blocks "${WF_DIR}/build-worker.yaml"
  assert_success
  assert_output --partial 'git diff --name-only'
}
