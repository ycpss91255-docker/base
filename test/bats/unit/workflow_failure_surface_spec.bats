#!/usr/bin/env bats
#
# workflow_failure_surface_spec.bats -- "a red check names the thing that
# is wrong, and nothing else turns red".
#
# why: Five properties of the workflow tree, four of them about what a
# reader learns from a failed run and the fifth about what the tree itself
# records. A cleanup sweep that reddens a build which
# succeeded, and a fork PR whose required check is red with no text
# distinguishing "we refuse to build fork code" from "the build broke",
# are both failures that carry no information -- and a reader who meets
# enough of them stops reading the ones that do. The rollup's silence on a
# doc-only run is the same defect inverted: an undifferentiated GREEN for
# "everything passed" and for "almost nothing ran". The absences are the
# fourth: nothing serialises the publishes that race for one rolling tag,
# nothing cancels a superseded PR's eight-shard matrix, and nothing bounds
# a hung buildx below GitHub's six-hour default. The fifth is an absence of
# a different kind: the default token grant of a workflow that declares
# none is a setting on a web page, so the tree carries no record of the
# posture its jobs run under and no diff can change it.
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

# _rollup_selected <VAR=value>...
#   Runs the lifted `Verify upstream jobs` step with every upstream job
#   reported `success`, a code change, a same-repo PR, and every other
#   env key the step declares (classify's per-job selections) set to
#   `true`; the arguments then override single entries. The env binding
#   for a classify output is looked up by the expression it reads, so the
#   test does not hard-code the variable name the step chooses.
_rollup_selected() {
  local _script="${BATS_TEST_TMPDIR}/rollup.sh" _var _status=0
  yaml_step_run "${SELF_WF}" ci-rollup 'Verify upstream jobs' > "${_script}"
  [ -s "${_script}" ] || return 2
  local -a _env=()
  while IFS= read -r _var; do
    [[ -n "${_var}" ]] || continue
    case "${_var}" in
      CODE_CHANGED) _env+=("CODE_CHANGED=true") ;;
      IS_FORK_PR) _env+=("IS_FORK_PR=false") ;;
      *_RESULT) _env+=("${_var}=success") ;;
      *) _env+=("${_var}=true") ;;
    esac
  done < <(_yaml_eval "${SELF_WF}" \
      '.jobs."ci-rollup".steps[]
         | select(.name == "Verify upstream jobs") | .env | keys | .[]') \
      || _status=$?
  [[ "${_status}" -eq 0 ]] || return 2
  [[ "${#_env[@]}" -ge 10 ]] || return 2
  env "${_env[@]}" "$@" bash "${_script}"
}

# _rollup_env_for <classify-output>
#   The `Verify upstream jobs` env key bound to
#   needs.classify.outputs.<classify-output>, or nothing. yq unescapes a
#   string literal before the regex sees it, so each regex escape is
#   doubled (`\\.`, `\\b`); a single `\b` would become a backspace.
_rollup_env_for() {
  _yaml_eval "${SELF_WF}" \
      '.jobs."ci-rollup".steps[]
         | select(.name == "Verify upstream jobs") | .env | to_entries[]
         | select(.value | test("needs\\.classify\\.outputs\\.'"${1}"'\\b"))
         | .key'
}

# why: The rollup accepted any `skipped` on a gated job. With
# CONFIG_GEN_RESULT=skipped and CODE_CHANGED=true the lifted step printed
# `config-gen: skipped` and exited 0 (base#1584 design, section 1), so a
# config-gen that never ran on a diff classify said it can affect would
# still turn the required check green. A skip may pass only when classify
# itself decided it: here classify selected config-gen, so the skip is a
# workflow bug and the rollup must fail.
@test "self-test: the rollup fails a config-gen skip that classify did not decide (base#1584)" {
  local _sel_var
  _sel_var="$(_rollup_env_for select_config_gen)"
  run _rollup_selected CONFIG_GEN_RESULT=skipped \
      "${_sel_var:-SELECT_CONFIG_GEN}=true"
  assert_failure 1
  assert_output --partial 'config-gen:       skipped'
  [ -n "${_sel_var}" ]
}

# why: mutation-roster had no `if:` and sat in the rollup's hard-mandatory
# loop, so a PR whose diff cannot reach a roster spec still paid for the
# whole roster. The issue (base#1584) asks that a PR run only the checks
# its diff can affect, so a mutation-roster skip that classify decided
# (it did not select the job) must let the required check pass.
@test "self-test: the rollup accepts a mutation-roster skip that classify decided (base#1584)" {
  local _sel_var
  _sel_var="$(_rollup_env_for select_mutation_roster)"
  run _rollup_selected MUTATION_ROSTER_RESULT=skipped \
      "${_sel_var:-SELECT_MUTATION_ROSTER}=false"
  assert_success
  assert_output --partial 'mutation-roster:  skipped'
  [ -n "${_sel_var}" ]
}

# why: acceptance copies the whole checkout into the consumer
# (script/test/acceptance.sh:90, `cp -a "${_ACCEPTANCE_ROOT}/." ...`), so
# the map drops it only for a diff of `*_spec.bats` leaves (design row E1,
# base#1584). Such a diff still has code_changed=true, so a rollup that
# ties the acceptance skip to code_changed fails the very skip classify
# decided. A skip with select_acceptance=false must let the required
# check pass.
@test "self-test: the rollup accepts an acceptance skip that classify decided on a code change (base#1584)" {
  local _sel_var
  _sel_var="$(_rollup_env_for select_acceptance)"
  run _rollup_selected ACCEPTANCE_RESULT=skipped CODE_CHANGED=true \
      "${_sel_var:-SELECT_ACCEPTANCE}=false"
  assert_success
  assert_output --partial 'acceptance:       skipped'
  [ -n "${_sel_var}" ]
}

# why: shellcheck, hadolint and bats-fragile each run under
# `if: needs.classify.outputs.code_changed == 'true'` (self-test.yaml),
# so on a code change classify selected them and their skip is no
# decision. The rollup accepted any `skipped` for these three, so one
# that never ran on a code change still turned the required check green.
# The design (base#1584, section 2) ties each skip to its own gate
# output: for these three, code_changed=true makes the skip a failure.
@test "self-test: the rollup fails a shellcheck, hadolint or bats-fragile skip on a code change (base#1584)" {
  local _r
  for _r in SHELLCHECK HADOLINT BATS_FRAGILE; do
    run _rollup_selected CODE_CHANGED=true "${_r}_RESULT=skipped"
    if [[ "${status}" -ne 1 ]]; then
      echo "${_r}_RESULT=skipped with code_changed=true exited ${status}"
      return 1
    fi
  done
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

# ── 5. the repository default is not what holds the posture ───────────

# _triggerable_workflows_without_a_declared_default
#   One line per triggerable workflow whose top level declares no
#   `permissions:` MAPPING -- the workflows whose every job runs on
#   whatever the repository's Settings page currently says.
#
#   A mapping and not merely a present key: a blanket scalar is the same
#   shape whether it reads `read-all` or `write-all`, so a presence check
#   certifies nothing about the grant. The enumerated form is also the only
#   one the tree's other permission guards can read per scope.
_triggerable_workflows_without_a_declared_default() {
    local _f _tag _status
    while IFS= read -r _f; do
        [[ -n "${_f}" ]] || continue
        case "${_f}" in BUG:*) printf '%s\n' "${_f}" ; continue ;; esac
        _status=0
        _tag="$(_yaml_eval "${_f}" '.permissions | tag')" || _status=$?
        if [[ "${_status}" -ne 0 ]]; then
            printf '%s\n' "${_tag}"
            continue
        fi
        [[ "${_tag}" == '!!map' ]] || printf \
            '%s declares no top-level permissions mapping (its permissions key reads as %s), so every job in it that declares none of its own takes the repository default\n' \
            "${_f}" "${_tag}"
    done < <(_triggerable_workflows)
}

# why: The posture is correct and nothing in the tree says so. Both the
# repo and the org report `default_workflow_permissions: read`, so the
# fourteen jobs of base's own CI workflow that declare no block of their
# own are read-only -- held entirely by a checkbox on a settings page,
# which no diff, no review and no spec can see. Flip it and those jobs get
# write on contents, packages, actions, issues and pull-requests, on a
# workflow that checks out fourteen times with a persisted token and then
# runs the whole suite and scaffolds a repo. The caller-token question is
# a different one, asked of the reusable workers in
# reusable_worker_permissions_spec.bats over exactly the complement of this
# population; this is the repository default, so it is asked here, of the
# workflows a trigger can start. Five of the six already declare one, so
# the exception was a house convention nothing enforced.
@test "workflows: every workflow a trigger can start declares its own default permission (#1116)" {
  local _n
  _n="$(_triggerable_workflows | awk 'END { print NR }')"
  [[ "${_n}" -ge 6 ]] || fail \
      "expected the tree's triggerable workflows, derived ${_n} -- the scan below would have read an empty set as a clean one"
  run _triggerable_workflows_without_a_declared_default
  assert_success
  assert_output ''
}

# why: A skip may pass only when classify decided it (base#1584). An empty
# selection is no decision: classify failed to write the output, or the
# step reads a name classify never emits. The design's rule is that every
# select_* left empty plus a skip of a job it gates fails the rollup, for
# each job the map selects (config-gen, mutation-roster, coverage and its
# coverage-gate, acceptance, system). The control run, with the same empty
# selections and no skip, must still pass, so the failure is the skip's.
@test "self-test: the rollup fails a skip of a selected job when every classify selection is empty (base#1584)" {
  local -a _empty=()
  local _var _r
  while IFS= read -r _var; do
    [[ -n "${_var}" ]] && _empty+=("${_var}=")
  done < <(_rollup_env_for 'select_[a-z_]+')
  run _rollup_selected "${_empty[@]}"
  assert_success
  for _r in CONFIG_GEN MUTATION_ROSTER COVERAGE COVERAGE_GATE \
            ACCEPTANCE SYSTEM; do
    run _rollup_selected "${_empty[@]}" "${_r}_RESULT=skipped"
    if [[ "${status}" -ne 1 ]]; then
      echo "${_r}_RESULT=skipped with empty selections exited ${status}"
      return 1
    fi
  done
}

# _rollup_skip_rows
#   The rollup's skip table, one `<job> <env-var>` line per row: the job
#   whose skip it may excuse and the env key holding the classify answer
#   that excuses it. Read from the lifted `Verify upstream jobs` step, so
#   the rows are the ones the rollup actually runs.
_rollup_skip_rows() {
  yaml_step_run "${SELF_WF}" ci-rollup 'Verify upstream jobs' \
    | sed -nE 's/^[[:space:]]*\$\{[A-Z_]+_RESULT:--\} \$\{([A-Z_]+):--\} ([a-z-]+)[[:space:]]*$/\2 \1/p'
}

# why: review round 1 of base#1584 found select_mutation_roster and
# select_acceptance read only by ci-rollup: mutation-roster had no `if:`
# and acceptance gated on code_changed, so the skips the rollup was taught
# to excuse were skips classify could never cause, and a PR still paid
# for both jobs on every code change. A skip is a decision only when the
# job itself runs under the answer the rollup excuses it with. So for
# every row of the rollup's skip table, the job's own `if:` must read the
# same classify output the row's env key binds.
@test "self-test: every job whose skip the rollup excuses gates its own if: on the classify output that excuses it (base#1584)" {
  local _job _var _out _if _n=0 _bad=""
  while read -r _job _var; do
    [[ -n "${_job}" ]] || continue
    _n=$((_n + 1))
    _out="$(LP_V="${_var}" yq '.jobs."ci-rollup".steps[]
        | select(.name == "Verify upstream jobs") | .env[strenv(LP_V)]' \
        "${SELF_WF}" | sed -nE 's/.*needs\.classify\.outputs\.([a-z_]+).*/\1/p')"
    _if="$(LP_J="${_job}" yq '.jobs[strenv(LP_J)].if // ""' "${SELF_WF}")"
    if [[ -z "${_out}" || "${_if}" != *"needs.classify.outputs.${_out} "* ]]; then
      _bad+="${_job} (rollup excuses it with ${_var}=${_out:-?}, its if: is '${_if}')"$'\n'
    fi
  done < <(_rollup_skip_rows)
  [[ "${_n}" -ge 9 ]] || fail "expected the rollup's skip table, read ${_n} rows"
  [[ -z "${_bad}" ]] || fail "jobs whose skip classify can never cause:
${_bad}"
}

# why: the converse of the case above. A select_<job> output classify
# exposes but no job's `if:` reads selects nothing: the job runs on every
# PR whatever the map says (base#1584 review round 1). Every select_*
# output must be read by the `if:` of at least one job.
@test "self-test: every select_* output classify exposes is read by some job's if: (base#1584)" {
  local _o _n=0 _bad=""
  while IFS= read -r _o; do
    [[ -n "${_o}" ]] || continue
    _n=$((_n + 1))
    LP_O="needs.classify.outputs.${_o} " yq -e \
        '[.jobs[] | .if // "" | select(contains(strenv(LP_O)))] | length > 0' \
        "${SELF_WF}" >/dev/null || _bad+="${_o} "
  done < <(yq '.jobs.classify.outputs | keys | .[] | select(test("^select_"))' "${SELF_WF}")
  [[ "${_n}" -ge 3 ]] || fail "expected classify's select_* outputs, read ${_n}"
  [[ -z "${_bad}" ]] || fail "select_* outputs no job's if: reads: ${_bad}"
}

# why: review round 2 of base#1584 ran the lifted rollup step with every
# classify answer `true` and WORKER_SELFTEST_RESULT=skipped: it exited 0,
# while SYSTEM_RESULT=skipped under the same env exited 1. worker-selftest
# gates on system_relevant and sat in the skip-tolerant loop with no row in
# the skip table, and the row-by-row check above reads only rows that
# exist, so a gated job with no row passed it. This case starts from the
# jobs, not from the rollup's own lists: every job ci-rollup needs that
# carries an `if:` is skipped in turn on a run where classify selected
# everything, and the rollup must fail each one.
@test "self-test: the rollup fails the skip of every gated job it needs when classify selected everything (base#1584)" {
  local _job _var _n=0 _bad=""
  while IFS= read -r _job; do
    [[ -n "${_job}" ]] || continue
    LP_J="${_job}" yq -e '.jobs[strenv(LP_J)].if // "" | length > 0' \
        "${SELF_WF}" >/dev/null 2>&1 || continue
    _n=$((_n + 1))
    _var="$(LP_J="needs.${_job}.result" yq '.jobs."ci-rollup".steps[]
        | select(.name == "Verify upstream jobs") | .env | to_entries[]
        | select(.value | contains(strenv(LP_J))) | .key' "${SELF_WF}")"
    if [[ -z "${_var}" ]]; then
      _bad+="${_job} (no env key binds needs.${_job}.result)"$'\n'
      continue
    fi
    run _rollup_selected "${_var}=skipped"
    [[ "${status}" -eq 1 ]] \
      || _bad+="${_job} (${_var}=skipped with every classify answer true exited ${status})"$'\n'
  done < <(yq '.jobs."ci-rollup".needs[]' "${SELF_WF}")
  [[ "${_n}" -ge 10 ]] || fail "expected the gated jobs ci-rollup needs, read ${_n}"
  [[ -z "${_bad}" ]] || fail "gated jobs whose classify-selected skip the rollup passes:
${_bad}"
}
