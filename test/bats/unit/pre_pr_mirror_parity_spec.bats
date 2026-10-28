#!/usr/bin/env bats
#
# pre_pr_mirror_parity_spec.bats -- the local pre-PR mirror runs every job
# `ci-rollup` needs, in the mode CI runs it, or names why it cannot (base#1409).
#
# why: The pre-PR mirror attested "CI passed locally" while running the bats
# suite plain (CI's main unit gate is the kcov `coverage` matrix) and while
# skipping `system` and amd64 `acceptance` outright. A green stamp therefore
# said nothing about the jobs most likely to fail in CI. This spec pins the
# mirror's contract against the workflow itself, so a job added to
# `ci-rollup`'s `needs:` without a local counterpart fails `just test`
# instead of slipping past the stamp.
#
# The mirror is tracked at `script/ci/pre_pr_mirror.sh` and exposes:
#
#   --table   one TAB-separated line per required job:
#               attested<TAB><job><TAB><the local command run for it>
#               excluded<TAB><job>[/<leg>]<TAB><reason>
#   --plan    reads the changed paths (one per line) on stdin and prints the
#             commands the mirror would run for that diff, one per line.
#
# Mode is derived on both sides, never declared: a CI job is `kcov` when one
# of its run lines invokes a `--coverage*` mode of script/test/test.sh, and a
# local command is `kcov` when it is a `just test coverage` invocation.
# Everything else is `plain`.

bats_require_minimum_version 1.5.0

MIRROR="/source/script/ci/pre_pr_mirror.sh"

# The only jobs (or matrix legs) the mirror may leave out. Each one is a
# thing no local machine can reproduce: there is no local arm64 runner,
# worker-selftest calls a reusable workflow only Actions can invoke, and
# classify / compute-shards compute CI's own gating and partition rather
# than a verdict on repo content.
ALLOWED_EXCLUSIONS="acceptance/arm64
classify
compute-shards
worker-selftest"

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WF="/source/.github/workflows/self-test.yaml"
  assert_spec_subject "${WF}" "base's own CI workflow, whose ci-rollup needs this spec reads"
}

# _mirror_table -- the mirror's --table output, or a test failure naming why.
# Called through a command substitution, which does not inherit errexit, so
# every failure returns explicitly and every caller adds `|| return 1`.
_mirror_table() {
  [[ -f "${MIRROR}" ]] || { fail "missing ${MIRROR}: the pre-PR mirror and its attested/excluded table are not tracked in this repo (base#1409)"; return 1; }
  local _out _status=0
  _out="$(bash "${MIRROR}" --table 2>&1)" || _status=$?
  [[ "${_status}" -eq 0 ]] || { fail "${MIRROR} --table exited ${_status}: ${_out}"; return 1; }
  [[ -n "${_out}" ]] || { fail "${MIRROR} --table printed nothing"; return 1; }
  printf '%s\n' "${_out}"
}

# _rollup_needs -- ci-rollup's needs, one per line.
_rollup_needs() {
  local _out _status=0
  _out="$(yaml_job_needs "${WF}" ci-rollup)" || _status=$?
  [[ "${_status}" -eq 0 ]] || { fail "${_out}"; return 1; }
  [[ -n "${_out}" ]] || { fail "ci-rollup declares no needs: at all"; return 1; }
  printf '%s\n' "${_out}"
}

# _ci_mode <job> -- kcov when the job runs a --coverage* mode, else plain.
_ci_mode() {
  if yaml_job_lines "${WF}" "${1}" | grep -Eq 'test\.sh[^#]*--coverage'; then
    echo kcov
  else
    echo plain
  fi
}

# _local_mode <command> -- kcov for a `just test coverage` command, else plain.
_local_mode() {
  if [[ "${1}" =~ ^just[[:space:]]+test[[:space:]]+coverage([[:space:]]|$) ]]; then
    echo kcov
  else
    echo plain
  fi
}

@test "pre-PR mirror: every ci-rollup need is attested or excluded with a named reason (base#1409)" {
  local _table _needs _job _unclassified=""
  _table="$(_mirror_table)" || return 1
  _needs="$(_rollup_needs)" || return 1
  while IFS= read -r _job; do
    [[ -n "${_job}" ]] || continue
    if awk -F'\t' -v j="${_job}" '$1 == "attested" && $2 == j && $3 != "" {f=1} END {exit !f}' <<<"${_table}"; then
      continue
    fi
    if awk -F'\t' -v j="${_job}" '$1 == "excluded" && $2 == j && $3 != "" {f=1} END {exit !f}' <<<"${_table}"; then
      continue
    fi
    _unclassified+=" ${_job}"
  done <<<"${_needs}"
  [[ -z "${_unclassified}" ]] || fail "ci-rollup needs jobs the mirror neither attests nor excludes with a reason:${_unclassified}
table:
${_table}"
}

@test "pre-PR mirror: only arm64 acceptance, classify, compute-shards and worker-selftest may be excluded (base#1409)" {
  local _table _job _bad=""
  _table="$(_mirror_table)" || return 1
  while IFS= read -r _job; do
    [[ -n "${_job}" ]] || continue
    grep -Fxq -- "${_job}" <<<"${ALLOWED_EXCLUSIONS}" || _bad+=" ${_job}"
  done < <(awk -F'\t' '$1 == "excluded" {print $2}' <<<"${_table}")
  [[ -z "${_bad}" ]] || fail "the mirror excludes jobs it is required to run locally:${_bad}"
}

@test "pre-PR mirror: every table entry names a job ci-rollup needs (base#1409)" {
  local _table _needs _job _stale=""
  _table="$(_mirror_table)" || return 1
  _needs="$(_rollup_needs)" || return 1
  while IFS= read -r _job; do
    [[ -n "${_job}" ]] || continue
    grep -Fxq -- "${_job%%/*}" <<<"${_needs}" || _stale+=" ${_job}"
  done < <(awk -F'\t' '$1 == "attested" || $1 == "excluded" {print $2}' <<<"${_table}")
  [[ -z "${_stale}" ]] || fail "the mirror table names jobs ci-rollup does not need:${_stale}"
}

@test "pre-PR mirror: every attested job runs locally in the mode CI runs it (plain vs kcov) (base#1409)" {
  local _table _job _cmd _ci _local _mismatch=""
  _table="$(_mirror_table)" || return 1
  grep -q $'^attested\t' <<<"${_table}" || fail "the mirror attests no job at all, so there is no mode to compare"
  while IFS=$'\t' read -r _job _cmd; do
    [[ -n "${_job}" ]] || continue
    _ci="$(_ci_mode "${_job}")"
    _local="$(_local_mode "${_cmd}")"
    [[ "${_ci}" == "${_local}" ]] || _mismatch+="
  ${_job}: CI ${_ci}, local ${_local} (${_cmd})"
  done < <(awk -F'\t' '$1 == "attested" {print $2 "\t" $3}' <<<"${_table}")
  [[ -z "${_mismatch}" ]] || fail "attested jobs whose local leg runs in a different mode from CI:${_mismatch}"
}

@test "pre-PR mirror: a system-relevant diff plans system and amd64 acceptance (base#1409)" {
  [[ -f "${MIRROR}" ]] || fail "missing ${MIRROR} (base#1409)"
  run bash "${MIRROR}" --plan <<<"compose.yaml"
  assert_success
  assert_line 'just test system'
  assert_line 'just test acceptance'
}

@test "pre-PR mirror: a diff system_paths.sh does not match plans neither system nor acceptance (base#1409)" {
  [[ -f "${MIRROR}" ]] || fail "missing ${MIRROR} (base#1409)"
  run bash "${MIRROR}" --plan <<<"test/bats/unit/bashrc_spec.bats"
  assert_success
  refute_line 'just test system'
  refute_line 'just test acceptance'
  assert_line --regexp '^just test coverage( |$)'
}

@test "pre-PR mirror: a diff touching shell sources plans the full kcov suite (base#1409)" {
  [[ -f "${MIRROR}" ]] || fail "missing ${MIRROR} (base#1409)"
  run bash "${MIRROR}" --plan <<<"script/ci/reclaim.sh"
  assert_success
  assert_line 'just test coverage'
}

@test "pre-PR mirror: no message points at the stale .claude/scripts/ location (base#1409)" {
  [[ -f "${MIRROR}" ]] || fail "missing ${MIRROR} (base#1409)"
  run grep -n '\.claude/scripts/' "${MIRROR}"
  assert_failure
}

@test "acceptance job: CI runs the amd64 acceptance steps through script/ci/acceptance.sh (base#1409)" {
  assert_spec_subject /source/script/ci/acceptance.sh \
      "the acceptance script the acceptance job and just test acceptance share"
  run yaml_job_lines "${WF}" acceptance
  assert_success
  assert_output --regexp 'run: (bash )?\./script/ci/acceptance\.sh'
}

@test "acceptance job: just test acceptance runs the same script CI runs (base#1409)" {
  local _recipe
  _recipe="$(awk '/^acceptance([[:space:]][^:]*)?:/{f=1; next} f && /^[^[:space:]#]/{f=0} f' \
      /source/script/test/justfile.test)"
  [[ -n "${_recipe}" ]] || fail "script/test/justfile.test declares no acceptance recipe"
  grep -Fq './script/ci/acceptance.sh' <<<"${_recipe}" \
      || fail "the acceptance recipe does not run ./script/ci/acceptance.sh:
${_recipe}"
}
