#!/usr/bin/env bats
#
# workflow_failure_surface_spec.bats -- "a red check names the thing that
# is wrong, and nothing else turns red".
#
# why: Four properties of the workflow tree, each one about what a reader
# learns from a failed run. A cleanup sweep that reddens a build which
# succeeded, and a fork PR whose required check is red with no text
# distinguishing "we refuse to build fork code" from "the build broke",
# are both failures that carry no information -- and a reader who meets
# enough of them stops reading the ones that do. The rollup's silence on a
# doc-only run is the same defect inverted: an undifferentiated GREEN for
# "everything passed" and for "almost nothing ran". The absences are the
# fourth: nothing serialises the publishes that race for one rolling tag,
# nothing cancels a superseded PR's eight-shard matrix, and nothing bounds
# a hung buildx below GitHub's six-hour default.
#
# Every population here is DERIVED from the tree -- the workflow list from
# the directory, the reusable workers from `on: workflow_call`, the
# cleanup steps from what their `run:` invokes -- so the workflow, worker
# or sweep added tomorrow is scanned the day it lands. Each scan asserts
# what it walked before reading an empty result as a clean one.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WF_DIR=/source/.github/workflows
  BUILD_WF="${WF_DIR}/build-worker.yaml"
  SELF_WF="${WF_DIR}/self-test.yaml"
  assert_spec_subject_dir "${WF_DIR}" \
      "the workflow directory whose failure surface this spec scans"
  assert_spec_subject "${BUILD_WF}" "the reusable build worker"
  assert_spec_subject "${SELF_WF}" "base's own CI workflow"
}

# ── 1. a cleanup failure may not fail a job that succeeded ────────────

# _reclaim_steps
#   One `<file>|<job>|<step>|<continue-on-error>` line per step in the
#   workflow tree whose `run:` invokes the artifact sweep. Which steps
#   those are is read off what they RUN, not off their names: a sweep
#   added under another name is the one this scan exists to reach.
_reclaim_steps() {
    local _f _status
    while IFS= read -r _f; do
        [[ -n "${_f}" ]] || continue
        _status=0
        _yaml_eval "${_f}" '
            .jobs | to_entries | .[] | .key as $job
              | (.value.steps // []) | .[]
              | select(has("run")) | select(.run | contains("reclaim.sh"))
              | $job + "|" + (.name // "<unnamed>") + "|"
                + ((.["continue-on-error"] // false) | tostring)' \
            | sed "s|^|${_f}\||" || _status=$?
        [[ "${_status}" -eq 0 ]] \
            || printf 'BUG: could not read the steps of %s\n' "${_f}"
    done < <(workflow_files "${WF_DIR}")
}

# _reclaim_steps_that_can_fail_their_job
#   The subset of the above that would take a job down with them.
_reclaim_steps_that_can_fail_their_job() {
    local _line
    while IFS= read -r _line; do
        [[ -n "${_line}" ]] || continue
        case "${_line}" in
            BUG:*) printf '%s\n' "${_line}" ;;
            *'|true') ;;
            *) printf '%s\n' "${_line}" ;;
        esac
    done < <(_reclaim_steps)
}

# why: `if: always()` on a cleanup step ADDS a failure mode rather than
# swallowing one: the sweep runs after a build that passed, and its
# non-zero exit is the job's. Litter left behind is worth a warning; it is
# not worth a red build, and it is certainly not worth a red build whose
# log names a docker prune rather than the code under test.
@test "workflows: a cleanup sweep cannot fail the job it cleans up after (#1014)" {
  local _found
  _found="$(_reclaim_steps | awk 'END { print NR }')"
  [[ "${_found}" -ge 7 ]] || fail \
      "expected the tree's reclaim steps, derived ${_found} -- the scan below would have read an empty set as a clean one"
  run _reclaim_steps_that_can_fail_their_job
  assert_success
  assert_output ''
}

# ── 2. a fork PR's red says which red it is ───────────────────────────

# _aggregate <code_changed> <build_result> <is_fork_pr>
#   Runs build-worker's OWN aggregator step -- lifted out of the YAML, not
#   a copy of it -- against one `needs` shape.
_aggregate() {
  local _script="${BATS_TEST_TMPDIR}/aggregate.sh"
  yaml_step_run "${BUILD_WF}" docker-build 'Aggregate matrix result' \
      > "${_script}"
  [ -s "${_script}" ] || return 2
  env CODE_CHANGED="${1}" BUILD_RESULT="${2}" IS_FORK_PR="${3}" \
      bash "${_script}"
}

# why: A fork PR skips `build` under the same-repo guard, so the
# aggregator sees `skipped` and the required check is red forever. The
# posture is right -- untrusted code must not reach a self-hosted-eligible
# job -- but the run said nothing about it, so the contributor and the
# maintainer both read it as a broken build. self-test's rollup already
# prints the explanation for the identical case.
@test "build-worker: a fork PR's red explains the fork posture (#1014)" {
  run _aggregate true skipped true
  assert_failure
  assert_output --partial '::error::'
  assert_output --partial 'Fork PR'
  assert_output --partial 'same-repository branch'
}

# why: The other direction, so the message above cannot be bought by
# printing it on every red. A same-repo run whose matrix skipped is a
# workflow bug, not a refusal, and must not be described as one.
@test "build-worker: a same-repo skip is not reported as a fork refusal (#1014)" {
  run _aggregate true skipped false
  assert_failure
  refute_output --partial 'Fork'
  refute_output --partial 'fork'
}

# why: The two passes the aggregator owes, asserted so the message work
# above cannot quietly turn either into a failure: a doc-only PR short-
# circuits green (the required check still has to resolve), and a matrix
# that succeeded is a pass.
@test "build-worker: the aggregator still passes a doc-only PR and a green matrix (#1014)" {
  run _aggregate false skipped false
  assert_success
  run _aggregate true success false
  assert_success
}

# why: The cost of a concurrency group, paid where it lands. A cancelled
# run still executes an `if: always()` aggregator, so a superseded PR push
# arrives here as `cancelled` -- which is not a build failure and must not
# be reported as one. Asserted on the sentence only the cancelled branch
# prints, and against the generic one: the word `cancel` alone is bought
# by the result line the step echoes before any branch runs, so a test
# spelled that way stays green with the branch deleted.
@test "build-worker: a cancelled matrix reads as cancelled, not as a broken build (#1014)" {
  run _aggregate true cancelled false
  assert_failure
  assert_output --partial '::error::'
  assert_output --partial 'superseded by a newer push'
  refute_output --partial 'did not succeed'
}

# why: The third red, which nothing else pins. Delete it and a plain
# `failure` falls off the end of the script and exits 0 -- a failed matrix
# reported as a passed required check -- while the two reds above stay
# green. It has to say which red it is for the same reason they do: a
# build that failed is neither a fork refusal nor a superseded run.
@test "build-worker: a failed matrix is reported as a failed build (#1014)" {
  run _aggregate true failure false
  assert_failure
  assert_output --partial '::error::'
  assert_output --partial 'did not succeed'
  refute_output --partial 'superseded'
  refute_output --partial 'Fork PR'
}

# ── 3. the rollup says why it collapsed to skips ──────────────────────

# _gated_job <job>
#   Does <job> carry a job-level `if:`? Those are the jobs a doc-only PR
#   legitimately skips; the ones without it run on every PR, so a skip
#   there is a workflow bug and the rollup treats it as one. Read from the
#   file rather than listed here, so the roster cannot drift.
_gated_job() {
  _yaml_eval "${SELF_WF}" ".jobs.\"${1}\" | has(\"if\")" 2>/dev/null \
      | grep -Fxq true
}

# _rollup <code_changed> <result-for-the-gated-jobs>
#   Runs self-test's OWN rollup verifier -- lifted out of the YAML, not a
#   copy of it -- against one `needs` shape. The env names come from the
#   step's own `env:` block and each maps back to the job it reports, so a
#   renamed variable fails here instead of silently supplying an empty one.
#   Ungated jobs are reported as `success`: they run whatever the diff
#   said.
_rollup() {
  local _script="${BATS_TEST_TMPDIR}/rollup.sh" _var _job _status=0
  yaml_step_run "${SELF_WF}" ci-rollup 'Verify upstream jobs' > "${_script}"
  [ -s "${_script}" ] || return 2
  local -a _env=()
  while IFS= read -r _var; do
    [[ -n "${_var}" ]] || continue
    case "${_var}" in
      CODE_CHANGED) _env+=("CODE_CHANGED=${1}") ; continue ;;
      IS_FORK_PR) _env+=("IS_FORK_PR=false") ; continue ;;
    esac
    _job="$(printf '%s' "${_var%_RESULT}" | tr 'A-Z_' 'a-z-')"
    if _gated_job "${_job}"; then
      _env+=("${_var}=${2}")
    else
      _env+=("${_var}=success")
    fi
  done < <(_yaml_eval "${SELF_WF}" \
      '.jobs."ci-rollup".steps[]
         | select(.name == "Verify upstream jobs") | .env | keys | .[]') \
      || _status=$?
  [[ "${_status}" -eq 0 ]] || return 2
  [[ "${#_env[@]}" -ge 10 ]] || return 2
  env "${_env[@]}" bash "${_script}"
}

# why: A doc-only PR emits nine grey skips beside a green `ci-rollup`. A
# reviewer reading the checks list can see that; a reviewer reading only
# the required check sees an undifferentiated green, and the rollup's
# summary was identical for "everything passed" and "almost nothing ran".
# The classification the rollup already consumes is the answer, said out
# loud.
@test "self-test: the rollup names the doc-only classification it passed on (#1014)" {
  run _rollup false skipped
  assert_success
  assert_output --partial '::notice::'
  assert_output --partial 'doc-only'
}

# why: The opposite direction, so the notice cannot be bought by printing
# it always: a full run that passed everything is not a doc-only run and
# must not claim to be one.
@test "self-test: a full green run is not announced as doc-only (#1014)" {
  run _rollup true success
  assert_success
  refute_output --partial 'doc-only'
}

# ── 4. concurrency and timeouts ───────────────────────────────────────

# _triggerable_workflows
#   Every workflow that something other than a caller can start: it
#   declares a trigger besides `workflow_call`. These are the runs that
#   can pile up on one ref, so these are the runs a group has to order.
_triggerable_workflows() {
    local _f _keys _status
    while IFS= read -r _f; do
        [[ -n "${_f}" ]] || continue
        _status=0
        _keys="$(yaml_trigger_keys "${_f}")" || _status=$?
        if [[ "${_status}" -ne 0 ]]; then
            printf 'BUG: could not read the triggers of %s\n' "${_f}"
            continue
        fi
        _status=0
        printf '%s\n' "${_keys}" | grep -vFx 'workflow_call' >/dev/null \
            || _status=$?
        case "${_status}" in
            0) printf '%s\n' "${_f}" ;;
            1) ;;
            *) printf 'BUG: grep exited %s reading %s\n' "${_status}" "${_f}" ;;
        esac
    done < <(workflow_files "${WF_DIR}")
}

# _workflows_without_a_concurrency_group
#   One line per triggerable workflow declaring no `concurrency.group`.
_workflows_without_a_concurrency_group() {
    local _f _group _status
    while IFS= read -r _f; do
        [[ -n "${_f}" ]] || continue
        case "${_f}" in BUG:*) printf '%s\n' "${_f}" ; continue ;; esac
        _status=0
        _group="$(_yaml_eval "${_f}" '.concurrency.group // ""')" || _status=$?
        if [[ "${_status}" -ne 0 ]]; then
            printf '%s\n' "${_group}"
            continue
        fi
        [[ -n "${_group}" ]] || printf '%s declares no concurrency group\n' "${_f}"
    done < <(_triggerable_workflows)
}

# why: Nothing in the tree orders anything. Every push to a PR branch
# starts a fresh eight-shard coverage matrix beside the one still running,
# and two main merges touching the test-tools Dockerfile run two
# unserialised publishes whose last writer is decided by arm64 queue time
# rather than by commit order -- which is how a rolling tag ends up
# pointing at the older build.
@test "workflows: every workflow a trigger can start declares a concurrency group (#1014)" {
  local _n
  _n="$(_triggerable_workflows | awk 'END { print NR }')"
  [[ "${_n}" -ge 3 ]] || fail \
      "expected the tree's triggerable workflows, derived ${_n} -- the scan below would have read an empty set as a clean one"
  run _workflows_without_a_concurrency_group
  assert_success
  assert_output ''
}

# _workflows_cancelling_unconditionally
#   One line per workflow whose `cancel-in-progress` is a bare `true`.
_workflows_cancelling_unconditionally() {
    local _f _cancel _status
    while IFS= read -r _f; do
        [[ -n "${_f}" ]] || continue
        case "${_f}" in BUG:*) printf '%s\n' "${_f}" ; continue ;; esac
        _status=0
        _cancel="$(_yaml_eval "${_f}" \
            '.concurrency["cancel-in-progress"] // "" | tostring')" \
            || _status=$?
        if [[ "${_status}" -ne 0 ]]; then
            printf '%s\n' "${_cancel}"
            continue
        fi
        [[ "${_cancel}" == "true" ]] \
            && printf '%s cancels every run in its group, not only a superseded PR\n' "${_f}"
    done < <(_triggerable_workflows)
    return 0
}

# why: Cancellation is only free where the cancelled run's verdict no
# longer matters. On a PR branch a superseded push replaces it; on a main
# push or a tag the run IS the record, and on the publish path a cancelled
# `imagetools create` is how a rolling tag loses an arch. So a group may
# cancel a pull_request and nothing else -- and an `if: always()`
# aggregator turns whatever it cancels into a red required check.
@test "workflows: no concurrency group cancels a run whose verdict is the record (#1014)" {
  run _workflows_cancelling_unconditionally
  assert_success
  assert_output ''
}

# _step_jobs_without_a_timeout
#   One `<workflow>: <job>` per job in the tree that runs steps of its own
#   and bounds none of them. A job that only `uses:` another workflow is
#   excluded: GitHub refuses `timeout-minutes` there, and the bound belongs
#   to the called workflow's own jobs.
_step_jobs_without_a_timeout() {
    local _f _status
    while IFS= read -r _f; do
        [[ -n "${_f}" ]] || continue
        _status=0
        _yaml_eval "${_f}" '
            .jobs | to_entries | .[]
              | select(.value | has("steps"))
              | select(.value | has("timeout-minutes") | not)
              | .key' \
            | sed "s|^|${_f}: |" || _status=$?
        [[ "${_status}" -eq 0 ]] \
            || printf 'BUG: could not read the jobs of %s\n' "${_f}"
    done < <(workflow_files "${WF_DIR}")
}

# why: A hung buildx burns GitHub's six-hour default before anyone sees
# it. The population is every workflow file, not the reusable workers
# alone: the workers were bounded first because a worker spends the
# CALLER's minutes, but the jobs that actually run a build here are
# self-test's eight-shard coverage matrix and its two-arch `acceptance`
# matrix, both self-hosted-eligible and both unbounded -- so the hazard the
# rule names lived entirely outside the set the rule scanned. The bound is
# per job rather than per workflow because that is the only place GitHub
# accepts one, and the roster is derived from the directory so the ninth
# workflow cannot land unbounded.
@test "workflows: every job that runs steps bounds them (#1014)" {
  local _n
  _n="$(workflow_files "${WF_DIR}" | awk 'END { print NR }')"
  [[ "${_n}" -ge 8 ]] || fail \
      "expected the tree's workflows, derived ${_n} -- the scan below would have read an empty set as a clean one"
  run _step_jobs_without_a_timeout
  assert_success
  assert_output ''
}
