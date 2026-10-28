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
# The claim is held link by link, so no link can be left out silently:
#
#   table -> workflow   every ci-rollup need is attested or excluded, and an
#                       attested job's local command runs in CI's mode.
#   table -> plan       on every diff where CI's own `if:` gate runs a job,
#                       the plan carries that job's local command.
#   plan  -> run        the mirror executes exactly the plan, in order, and
#                       stops at the first red command.
#   plan  -> report     the coverage floor the plan runs reads the shard
#                       reports the coverage matrix actually writes.
#
# Mode is derived on both sides, never declared: text is `kcov` when it
# invokes script/test/test.sh in a mode that instruments (`--coverage`,
# `--coverage-shard`, `--coverage-local`, `--coverage-path`); every other
# mode, `--coverage-union-check` included, is `plain`. A CI job's text is
# its run lines. A local `just test <recipe>` command's text is that
# recipe's body in script/test/justfile.test, and a local
# `./script/ci/pre_pr_mirror.sh --<sub>` command's text is the body of the
# function the mirror dispatches <sub> to, so a recipe or a subcommand
# that stops instrumenting changes the local mode with it.

bats_require_minimum_version 1.5.0

MIRROR="/source/script/ci/pre_pr_mirror.sh"
# The mirror's local counterpart of CI's coverage matrix.
COVERAGE_MATRIX='./script/ci/pre_pr_mirror.sh --coverage-matrix'
JUSTFILE_TEST="/source/script/test/justfile.test"

# The only jobs (or matrix legs) the mirror may leave out. Each one is a
# thing no local machine can reproduce: there is no local arm64 runner,
# worker-selftest calls a reusable workflow only Actions can invoke, and
# classify / compute-shards compute CI's own gating and partition rather
# than a verdict on repo content.
ALLOWED_EXCLUSIONS="acceptance/arm64
classify
compute-shards
worker-selftest"

# Diffs whose classification is known, and the CI gates each one fires:
# `code` is classify's code_changed (anything outside doc/**, README.md,
# LICENSE, CONTEXT.md), `system` is system_relevant (script/ci/system_paths.sh).
PROBES="doc/test/TEST.md|
test/bats/unit/bashrc_spec.bats|code
compose.yaml|code system"

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WF="/source/.github/workflows/self-test.yaml"
  assert_spec_subject "${WF}" "base's own CI workflow, whose ci-rollup needs this spec reads"
  SCRATCH="$(mktemp -d)"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _require_mirror -- fail naming the gap when the mirror is not tracked here.
_require_mirror() {
  [[ -f "${MIRROR}" ]] || { fail "missing ${MIRROR}: the pre-PR mirror and its attested/excluded table are not tracked in this repo (base#1409)"; return 1; }
}

# _mirror_table -- the mirror's --table output, or a test failure naming why.
# Called through a command substitution, which does not inherit errexit, so
# every failure returns explicitly and every caller adds `|| return 1`.
_mirror_table() {
  _require_mirror || return 1
  local _out _status=0
  _out="$(bash "${MIRROR}" --table 2>&1)" || _status=$?
  [[ "${_status}" -eq 0 ]] || { fail "${MIRROR} --table exited ${_status}: ${_out}"; return 1; }
  [[ -n "${_out}" ]] || { fail "${MIRROR} --table printed nothing"; return 1; }
  printf '%s\n' "${_out}"
}

# _attested_cmd <table> <job> -- the local command the table attests <job> by.
_attested_cmd() {
  awk -F'\t' -v j="${2}" '$1 == "attested" && $2 == j {print $3; exit}' <<<"${1}"
}

# _floor_cmd <table> -- the `&&`-joined part of the coverage-gate command
# that runs the floor (coverage_gate.sh); empty when there is none.
_floor_cmd() {
  local _rest _part
  _rest="$(_attested_cmd "${1}" coverage-gate)"
  while [[ -n "${_rest}" ]]; do
    _part="${_rest%% && *}"
    [[ "${_part}" == "${_rest}" ]] && _rest="" || _rest="${_rest#* && }"
    [[ "${_part}" == *coverage_gate.sh* ]] && { printf '%s\n' "${_part}"; return 0; }
  done
}

# _rollup_needs -- ci-rollup's needs, one per line.
_rollup_needs() {
  local _out _status=0
  _out="$(yaml_job_needs "${WF}" ci-rollup)" || _status=$?
  [[ "${_status}" -eq 0 ]] || { fail "${_out}"; return 1; }
  [[ -n "${_out}" ]] || { fail "ci-rollup declares no needs: at all"; return 1; }
  printf '%s\n' "${_out}"
}

# _text_mode -- kcov when stdin invokes test.sh in an instrumenting mode.
_text_mode() {
  if grep -Eq 'test\.sh[^#]*--coverage(-shard|-local|-path)?([^-[:alnum:]]|$)'; then
    echo kcov
  else
    echo plain
  fi
}

# _ci_mode <job> -- the mode of the job's own run lines.
_ci_mode() {
  yaml_job_lines "${WF}" "${1}" | _text_mode
}

# _recipe_body <recipe> -- the body of a recipe in ${JUSTFILE_TEST}.
_recipe_body() {
  awk -v r="${1}" '
    $0 ~ "^" r "([[:space:]][^:]*)?:" {f=1; next}
    f && /^[^[:space:]#]/ {f=0}
    f' "${JUSTFILE_TEST}"
}

# _mirror_sub_body <--sub> -- the body of the function ${MIRROR}'s main
# dispatches <--sub> to; empty when it dispatches none.
_mirror_sub_body() {
  local _fn
  _fn="$(awk -v f="${1})" '$1 == f {print $2; exit}' "${MIRROR}")"
  [[ -n "${_fn}" ]] || return 0
  awk -v fn="${_fn}" '
    $0 ~ "^" fn "\\(\\) \\{" {f=1; next}
    f && /^}/ {f=0}
    f' "${MIRROR}"
}

# _local_mode <command> -- kcov when any `&&`-joined part instruments. A
# `just test [<recipe>]` part is read as the recipe it runs (no recipe is
# `default`), and a `./script/ci/pre_pr_mirror.sh --<sub>` part as the
# function that subcommand runs; an unknown recipe or subcommand is
# `unresolved`, which matches no CI mode.
_local_mode() {
  local _rest="${1}" _part _recipe _body _mode=plain
  while [[ -n "${_rest}" ]]; do
    _part="${_rest%% && *}"
    [[ "${_part}" == "${_rest}" ]] && _rest="" || _rest="${_rest#* && }"
    if [[ "${_part}" =~ ^just[[:space:]]+test([[:space:]]+([^[:space:]]+))? ]]; then
      _recipe="${BASH_REMATCH[2]:-default}"
      _body="$(_recipe_body "${_recipe}")"
      [[ -n "${_body}" ]] || { echo "unresolved"; return 0; }
      [[ "$(_text_mode <<<"${_body}")" == kcov ]] && _mode=kcov
    elif [[ "${_part}" =~ ^\./script/ci/pre_pr_mirror\.sh[[:space:]]+(--[[:alnum:]-]+) ]]; then
      _body="$(_mirror_sub_body "${BASH_REMATCH[1]}")"
      [[ -n "${_body}" ]] || { echo "unresolved"; return 0; }
      [[ "$(_text_mode <<<"${_body}")" == kcov ]] && _mode=kcov
    else
      [[ "$(_text_mode <<<"${_part}")" == kcov ]] && _mode=kcov
    fi
  done
  echo "${_mode}"
}

# _ci_gate <job> -- `code`, `system` or `always`, read from the job's own
# job-level `if:`; anything else is `unknown:<line>` so a new gate shape
# fails loudly rather than reading as ungated.
_ci_gate() {
  local _if
  _if="$(yaml_job_lines "${WF}" "${1}" | grep -E '^    if:' | head -n 1)"
  case "${_if}" in
    '') echo always ;;
    *"needs.classify.outputs.code_changed == 'true'"*) echo code ;;
    *"needs.classify.outputs.system_relevant == 'true'"*) echo system ;;
    *) echo "unknown:${_if}" ;;
  esac
}

# _make_mirror_repo -- a git repo holding a copy of the mirror and what it
# reads, at ${SCRATCH}/repo, with one base commit; prints that commit.
_make_mirror_repo() {
  local _r="${SCRATCH}/repo"
  mkdir -p "${_r}/script/ci" "${_r}/.github/workflows"
  cp "${MIRROR}" /source/script/ci/system_paths.sh "${_r}/script/ci/"
  cp "${WF}" "${_r}/.github/workflows/"
  git -C "${_r}" init -q
  git -C "${_r}" -c user.name=t -c user.email=t@t add -A
  git -C "${_r}" -c user.name=t -c user.email=t@t commit -q -m base
  git -C "${_r}" rev-parse HEAD
}

# _stub_bash <red-substring> -- a `bash` first on PATH that logs every
# `bash -c <command>` the mirror executes to ${SCRATCH}/ran and exits 1
# for a command containing <red-substring> (empty: none is red). Any
# other invocation is handed to the real bash.
_stub_bash() {
  local _real
  _real="$(command -v bash)"
  mkdir -p "${SCRATCH}/bin"
  cat > "${SCRATCH}/bin/bash" <<EOF
#!${_real}
if [[ "\${1:-}" == -c ]]; then
  printf '%s\n' "\${2}" >> "${SCRATCH}/ran"
  [[ -n "${1}" && "\${2}" == *"${1}"* ]] && exit 1
  exit 0
fi
exec "${_real}" "\$@"
EOF
  chmod +x "${SCRATCH}/bin/bash"
}

# _stub_docker <arch> -- a `docker` first on PATH whose `docker info`
# reports a daemon of <arch> (empty: the daemon is unreachable and `info`
# fails). Every other invocation succeeds and does nothing.
_stub_docker() {
  mkdir -p "${SCRATCH}/bin"
  cat > "${SCRATCH}/bin/docker" <<EOF
#!$(command -v bash)
if [[ "\${1:-}" == info ]]; then
  [[ -n "${1}" ]] || exit 1
  printf '%s\n' "${1}"
fi
exit 0
EOF
  chmod +x "${SCRATCH}/bin/docker"
}

@test "pre-PR mirror: every ci-rollup need is attested or excluded with a named reason (base#1409)" {
  local _table _needs _job _unclassified=""
  _table="$(_mirror_table)" || return 1
  _needs="$(_rollup_needs)" || return 1
  while IFS= read -r _job; do
    [[ -n "${_job}" ]] || continue
    awk -F'\t' -v j="${_job}" \
        '($1 == "attested" || $1 == "excluded") && $2 == j && $3 != "" {f=1} END {exit !f}' \
        <<<"${_table}" || _unclassified+=" ${_job}"
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

# why: The mode check stands on this classifier. Reading a command's spelling
# instead of the recipe it runs let a coverage recipe turned plain pass, and
# counting --coverage-union-check as kcov hid a real mode mismatch.
@test "pre-PR mirror: the mode classifier reads the recipe a just command runs, and union-check as plain (base#1409)" {
  # The classifier is what the mode check below stands on, so it is held to
  # the three readings the check must not get wrong.
  run _text_mode <<<'./script/test/test.sh --coverage-union-check coverage/timings.tsv'
  assert_output plain
  run _text_mode <<<"      ./script/test/test.sh --coverage-shard '1/4'"
  assert_output kcov
  printf '%s\n' 'default:' '    ./script/test/test.sh' '' \
      'coverage shard='"''"':' '    bats test/bats' > "${SCRATCH}/justfile.test"
  JUSTFILE_TEST="${SCRATCH}/justfile.test" run _local_mode 'just test coverage'
  assert_output plain
  JUSTFILE_TEST="${SCRATCH}/justfile.test" run _local_mode 'just test absent'
  assert_output unresolved
  # A mirror subcommand is read as the function it dispatches to.
  printf '%s\n' '_cov() {' '  ./script/test/test.sh --coverage-shard "$1"' '}' \
      '_lint() {' '  ./script/test/test.sh --lint' '}' \
      'main() {' '  case "${1:-}" in' '    --cov) _cov ;;' '    --lint) _lint ;;' \
      '  esac' '}' > "${SCRATCH}/mirror.sh"
  MIRROR="${SCRATCH}/mirror.sh" run _local_mode './script/ci/pre_pr_mirror.sh --cov'
  assert_output kcov
  MIRROR="${SCRATCH}/mirror.sh" run _local_mode './script/ci/pre_pr_mirror.sh --lint'
  assert_output plain
  MIRROR="${SCRATCH}/mirror.sh" run _local_mode './script/ci/pre_pr_mirror.sh --absent'
  assert_output unresolved
}

# why: A plain local run cannot attest a kcov CI job: specs that are red only
# under kcov stay green locally. This is the check that keeps the stamp
# measuring the same thing CI measures.
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

# why: The plan's gates were hand-written and drifted from the workflow:
# acceptance ran in CI on every code change and locally only on system paths.
# Reading each job's own if: gate makes such a drift red here.
@test "pre-PR mirror: every diff CI gates a job in plans that job's local command (base#1409)" {
  local _table _job _cmd _gate _probe _path _fires _plan _part _rest _missing=""
  _table="$(_mirror_table)" || return 1
  while IFS= read -r _probe; do
    _path="${_probe%%|*}"
    _fires="${_probe#*|}"
    _plan="$(bash "${MIRROR}" --plan <<<"${_path}")" || fail "--plan failed for ${_path}"
    while IFS=$'\t' read -r _job _cmd; do
      [[ -n "${_job}" ]] || continue
      _gate="$(_ci_gate "${_job}")"
      case "${_gate}" in
        always) ;;
        code|system) [[ " ${_fires} " == *" ${_gate} "* ]] || continue ;;
        *) _missing+="
  ${_job}: CI gate not recognised: ${_gate#unknown:}"; continue ;;
      esac
      _rest="${_cmd}"
      while [[ -n "${_rest}" ]]; do
        _part="${_rest%% && *}"
        [[ "${_part}" == "${_rest}" ]] && _rest="" || _rest="${_rest#* && }"
        grep -Fxq -- "${_part}" <<<"${_plan}" || _missing+="
  ${_path}: CI runs ${_job} (gate ${_gate}), the plan omits: ${_part}"
      done
    done < <(awk -F'\t' '$1 == "attested" {print $2 "\t" $3}' <<<"${_table}")
  done <<<"${PROBES}"
  [[ -z "${_missing}" ]] || fail "the plan skips jobs CI runs for the same diff:${_missing}"
}

@test "pre-PR mirror: a system-relevant diff plans system and amd64 acceptance (base#1409)" {
  _require_mirror
  run bash "${MIRROR}" --plan <<<"compose.yaml"
  assert_success
  assert_line 'just test system'
  assert_line 'just test acceptance'
}

@test "pre-PR mirror: a code diff system_paths.sh does not match plans acceptance and kcov, not system (base#1409)" {
  _require_mirror
  run bash "${MIRROR}" --plan <<<"test/bats/unit/bashrc_spec.bats"
  assert_success
  refute_line 'just test system'
  assert_line 'just test acceptance'
  assert_line "${COVERAGE_MATRIX}"
}

@test "pre-PR mirror: a diff touching shell sources plans CI's whole coverage matrix (base#1409)" {
  _require_mirror
  run bash "${MIRROR}" --plan <<<"script/ci/reclaim.sh"
  assert_success
  assert_line "${COVERAGE_MATRIX}"
}

# _gen_shards <CI_SHARDS> -- the shard list compute-shards' `gen` step
# writes for that variable value, in the mirror's one-per-line form.
_gen_shards() {
  local _out="${SCRATCH}/gen.out" _script
  _script="$(awk '
    /^      - id: gen$/ {g=1; next}
    g && /^      - / {g=0}
    g && r {sub(/^          /, ""); print; next}
    g && /^        run: \|$/ {r=1}' "${WF}")"
  [[ -n "${_script}" ]] || { fail "compute-shards has no gen step run: block"; return 1; }
  : > "${_out}"
  # The step runs under the runner's plain bash, so it runs here without
  # the instrumentation kcov exports when this spec is itself under kcov:
  # kcov's BASH_ENV helper reads BASH_SOURCE, which `bash -c` leaves
  # unset, and the step's own `set -u` aborts on it before its first line.
  CI_SHARDS="${1}" GITHUB_OUTPUT="${_out}" \
      env -u BASH_ENV -u BASH_XTRACEFD -u KCOV_BASH_XTRACEFD -u LD_PRELOAD \
      bash -c "${_script}" >/dev/null 2>&1 \
      || { fail "compute-shards' gen step failed for CI_SHARDS='${1}'"; return 1; }
  sed -n 's/^shards=\[\(.*\)\]$/\1/p' "${_out}" | tr ',' '\n' | tr -d '"'
}

# why: The mirror ran the unsharded `just test coverage`, one serial kcov
# over the suite, while CI runs a matrix of weighted shards, each dealt
# into COVERAGE_JOBS concurrent kcov slices (base#1410, base#1414); a
# failure that only that shape produces passed the mirror and went red in
# CI (base#1409 landing review). The matrix the mirror runs is held to the
# matrix compute-shards computes from the same variable.
@test "pre-PR mirror: the coverage matrix is the one compute-shards computes for the same CI_SHARDS (base#1409)" {
  _require_mirror
  local _v _ci _local _diff=""
  for _v in '' 1 3 8 12 0 13 abc; do
    _ci="$(_gen_shards "${_v}")" || return 1
    [[ -n "${_ci}" ]] || fail "compute-shards' gen step wrote no shards for CI_SHARDS='${_v}'"
    _local="$(CI_SHARDS="${_v}" bash "${MIRROR}" --coverage-shards)" \
        || fail "--coverage-shards failed for CI_SHARDS='${_v}'"
    [[ "${_ci}" == "${_local}" ]] || _diff+="
  CI_SHARDS='${_v}': CI $(paste -sd' ' <<<"${_ci}"), mirror $(paste -sd' ' <<<"${_local}")"
  done
  [[ -z "${_diff}" ]] || fail "the mirror runs a different coverage matrix from CI:${_diff}"
}

# _fake_test_sh <red-shard> -- a script/test/test.sh in the mirror repo.
# `--clean-coverage` removes coverage/, as the real one does. Any other
# call logs `<args> COVERAGE_JOBS=<v>` to ${SCRATCH}/shards, ADDS a file
# naming its shard to coverage/ (a real coverage run merges into what is
# there rather than emptying it), and exits 1 for <red-shard>.
_fake_test_sh() {
  mkdir -p "${SCRATCH}/repo/script/test"
  cat > "${SCRATCH}/repo/script/test/test.sh" <<FAKE
#!$(command -v bash)
if [[ "\${1}" == --clean-coverage ]]; then
  rm -rf coverage
  exit 0
fi
printf '%s COVERAGE_JOBS=%s\n' "\$*" "\${COVERAGE_JOBS-<unset>}" >> "${SCRATCH}/shards"
mkdir -p coverage && printf '%s\n' "\${2}" > "coverage/shard-\${2%%/*}"
[[ "\${2}" == "${1}" ]] && exit 1
exit 0
FAKE
  chmod +x "${SCRATCH}/repo/script/test/test.sh"
}

# why: The shard list alone proves nothing if each shard runs another
# command or slice count than CI's, or if one shard's tree carries another
# run's reports: a coverage run merges into whatever coverage/ holds, so
# the matrix carried earlier reports into every later shard and the floor
# read lines that shard never covered (base#1409 review round 10).
@test "pre-PR mirror: the coverage matrix runs each shard with CI's command and slice count, keeping each tree (base#1409)" {
  _require_mirror
  local _jobs _want="" _n
  run yaml_job_lines "${WF}" coverage
  assert_success
  assert_output --partial 'run: ./script/test/test.sh --coverage-shard ${{ matrix.shard }}'
  _jobs="$(grep -oE 'COVERAGE_JOBS:[[:space:]]*[0-9]+' <<<"${output}" | grep -oE '[0-9]+$')"
  [[ -n "${_jobs}" ]] || fail "the coverage job sets no COVERAGE_JOBS"
  _make_mirror_repo >/dev/null
  _fake_test_sh ""
  # An earlier run's report left in coverage/, as a real run leaves one.
  mkdir -p "${SCRATCH}/repo/coverage"
  printf 'stale\n' > "${SCRATCH}/repo/coverage/earlier-run"
  run env CI_SHARDS=3 bash "${SCRATCH}/repo/script/ci/pre_pr_mirror.sh" --coverage-matrix
  assert_success
  for _n in 1 2 3; do
    _want+="--coverage-shard ${_n}/3 COVERAGE_JOBS=${_jobs}"$'\n'
    # Each shard's tree holds that shard's report and nothing else: CI
    # runs every shard on a fresh checkout.
    run ls -A "${SCRATCH}/repo/coverage-shards/${_n}"
    assert_output "shard-${_n}"
  done
  [[ "$(cat "${SCRATCH}/shards")"$'\n' == "${_want}" ]] || fail "the matrix ran other shards than CI's
want:
${_want}ran:
$(cat "${SCRATCH}/shards")"
}

# why: A matrix that carried on past a red shard, or exited 0 after one,
# would hand the floor a matrix with a hole and stamp a green CI's
# coverage job would not give.
@test "pre-PR mirror: a red coverage shard stops the matrix red (base#1409)" {
  _require_mirror
  _make_mirror_repo >/dev/null
  _fake_test_sh 2/3
  run env CI_SHARDS=3 bash "${SCRATCH}/repo/script/ci/pre_pr_mirror.sh" --coverage-matrix
  assert_failure
  run grep -c . "${SCRATCH}/shards"
  assert_output 2
}

# why: Falling back to compute-shards' default of 8 when the variable
# cannot be read would run another matrix than the one CI_SHARDS sets and
# attest the coverage job.
@test "pre-PR mirror: an unreadable CI_SHARDS is a refusal, not a guessed matrix (base#1409)" {
  _require_mirror
  mkdir -p "${SCRATCH}/bin"
  printf '#!%s\nexit 1\n' "$(command -v bash)" > "${SCRATCH}/bin/gh"
  chmod +x "${SCRATCH}/bin/gh"
  run env -u CI_SHARDS PATH="${SCRATCH}/bin:${PATH}" bash "${MIRROR}" --coverage-shards
  assert_failure
  assert_output --partial 'cannot read the CI_SHARDS Actions variable'
  refute_output --regexp '^[0-9]+/[0-9]+$'
}

# why: Without this the table and plan could claim a command the run never
# executes, and every other check in this file would still pass.
@test "pre-PR mirror: the run executes exactly the plan, in order (base#1409)" {
  _require_mirror
  local _base _want
  _base="$(_make_mirror_repo)"
  printf 'services: {}\n' > "${SCRATCH}/repo/compose.yaml"
  git -C "${SCRATCH}/repo" -c user.name=t -c user.email=t@t add -A
  git -C "${SCRATCH}/repo" -c user.name=t -c user.email=t@t commit -q -m change
  _want="$(bash "${SCRATCH}/repo/script/ci/pre_pr_mirror.sh" --plan <<<"compose.yaml")"
  _stub_bash ""
  _stub_docker x86_64
  run env PATH="${SCRATCH}/bin:${PATH}" "$(command -v bash)" \
      "${SCRATCH}/repo/script/ci/pre_pr_mirror.sh" --base "${_base}"
  assert_success
  [[ -f "${SCRATCH}/ran" ]] || fail "the mirror ran no command at all"
  [[ "$(cat "${SCRATCH}/ran")" == "${_want}" ]] || fail "the mirror ran something other than its plan
planned:
${_want}
ran:
$(cat "${SCRATCH}/ran")"
}

# why: The run read its plan from the stdin every planned command
# inherited, so the first command that drained stdin (`just test` in a real
# run) swallowed the rest of the plan; the mirror ran actionlint
# and `just test` only and still reported every planned command green
# (base#1409).
@test "pre-PR mirror: a planned command that reads stdin does not cut the plan short (base#1409)" {
  _require_mirror
  local _base _want
  _base="$(_make_mirror_repo)"
  printf 'services: {}\n' > "${SCRATCH}/repo/compose.yaml"
  git -C "${SCRATCH}/repo" -c user.name=t -c user.email=t@t add -A
  git -C "${SCRATCH}/repo" -c user.name=t -c user.email=t@t commit -q -m change
  _want="$(bash "${SCRATCH}/repo/script/ci/pre_pr_mirror.sh" --plan <<<"compose.yaml")"
  _stub_bash ""
  # Every `bash -c` drains its stdin before it exits, as `just test` did.
  sed -i 's|^  exit 0$|  cat >/dev/null; exit 0|' "${SCRATCH}/bin/bash"
  grep -q 'cat >/dev/null; exit 0' "${SCRATCH}/bin/bash" \
    || fail "the stub did not take the stdin-draining edit"
  _stub_docker x86_64
  run env PATH="${SCRATCH}/bin:${PATH}" "$(command -v bash)" \
      "${SCRATCH}/repo/script/ci/pre_pr_mirror.sh" --base "${_base}"
  assert_success
  [[ "$(cat "${SCRATCH}/ran")" == "${_want}" ]] || fail "a command that read stdin cut the plan short
planned:
${_want}
ran:
$(cat "${SCRATCH}/ran")"
}

# why: Rename detection made the mirror's diff report only a move's
# destination, so moving an unchanged file from dist/ into doc/ read as a
# doc-only diff and skipped coverage, system and acceptance, while CI's
# pathspec diffs see the removed source and run all three. diff.renames is
# forced on so a user config that turns it off cannot hide the gap.
@test "pre-PR mirror: a file moved from dist/ into doc/ plans what CI runs for the removed source (base#1409)" {
  _require_mirror
  local _base _want _missing=""
  mkdir -p "${SCRATCH}/repo/dist"
  seq 1 50 > "${SCRATCH}/repo/dist/notes.txt"
  _base="$(_make_mirror_repo)"
  mkdir -p "${SCRATCH}/repo/doc"
  git -C "${SCRATCH}/repo" mv dist/notes.txt doc/notes.txt
  git -C "${SCRATCH}/repo" -c user.name=t -c user.email=t@t commit -q -m move
  _stub_bash ""
  _stub_docker x86_64
  run env PATH="${SCRATCH}/bin:${PATH}" \
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=diff.renames GIT_CONFIG_VALUE_0=true \
      "$(command -v bash)" "${SCRATCH}/repo/script/ci/pre_pr_mirror.sh" --base "${_base}"
  assert_success
  for _want in "${COVERAGE_MATRIX}" 'just test system' 'just test acceptance'; do
    grep -Fxq -- "${_want}" "${SCRATCH}/ran" || _missing+=" '${_want}'"
  done
  [[ -z "${_missing}" ]] || fail "a dist/ -> doc/ move skipped:${_missing}
ran:
$(cat "${SCRATCH}/ran")"
}

# why: The mirror classified the diff by matching `git diff --name-only`
# text against the pathspecs, and git quotes a non-ASCII name in that text
# under core.quotePath, so a change to only dist/<non-ASCII>.sh read as a
# quoted string that matched no pathspec and skipped `system`, while CI's
# pathspec diff sees the real file and runs it (base#1409 review round 5).
# core.quotePath is forced on so a user config that turns it off cannot
# hide the gap.
@test "pre-PR mirror: a change to only a non-ASCII dist/ path plans what CI runs for it (base#1409)" {
  _require_mirror
  local _base _want _missing=""
  _base="$(_make_mirror_repo)"
  mkdir -p "${SCRATCH}/repo/dist"
  printf 'true\n' > "${SCRATCH}/repo/dist/"$'\xe6\xb8\xac\xe8\xa9\xa6'".sh"
  git -C "${SCRATCH}/repo" -c user.name=t -c user.email=t@t add -A
  git -C "${SCRATCH}/repo" -c user.name=t -c user.email=t@t commit -q -m non-ascii
  _stub_bash ""
  _stub_docker x86_64
  run env PATH="${SCRATCH}/bin:${PATH}" \
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.quotePath GIT_CONFIG_VALUE_0=true \
      "$(command -v bash)" "${SCRATCH}/repo/script/ci/pre_pr_mirror.sh" --base "${_base}"
  assert_success
  for _want in "${COVERAGE_MATRIX}" 'just test system' 'just test acceptance'; do
    grep -Fxq -- "${_want}" "${SCRATCH}/ran" || _missing+=" '${_want}'"
  done
  [[ -z "${_missing}" ]] || fail "a non-ASCII dist/ change skipped:${_missing}
ran:
$(cat "${SCRATCH}/ran")"
}

# why: A mirror that carries on past a red command, or exits 0 after one,
# stamps a green it did not earn.
@test "pre-PR mirror: the run stops at the first red command and exits non-zero (base#1409)" {
  _require_mirror
  local _base
  _base="$(_make_mirror_repo)"
  printf 'services: {}\n' > "${SCRATCH}/repo/compose.yaml"
  git -C "${SCRATCH}/repo" -c user.name=t -c user.email=t@t add -A
  git -C "${SCRATCH}/repo" -c user.name=t -c user.email=t@t commit -q -m change
  _stub_bash "${COVERAGE_MATRIX}"
  _stub_docker x86_64
  run env PATH="${SCRATCH}/bin:${PATH}" "$(command -v bash)" \
      "${SCRATCH}/repo/script/ci/pre_pr_mirror.sh" --base "${_base}"
  assert_failure
  assert_output --partial "RED at: ${COVERAGE_MATRIX}"
  run tail -n 1 "${SCRATCH}/ran"
  assert_output "${COVERAGE_MATRIX}"
}

# why: CI runs `system` and amd64 `acceptance` on amd64 runners, and both
# build and run images for the daemon's own architecture. On an arm64
# daemon `just test acceptance` measured arm64 and the mirror still
# reported the amd64 leg green (base#1409 review round 3).
@test "pre-PR mirror: on an arm64 daemon the amd64 legs are reported not run, never green (base#1409)" {
  _require_mirror
  local _base _leg
  _base="$(_make_mirror_repo)"
  printf 'services: {}\n' > "${SCRATCH}/repo/compose.yaml"
  git -C "${SCRATCH}/repo" -c user.name=t -c user.email=t@t add -A
  git -C "${SCRATCH}/repo" -c user.name=t -c user.email=t@t commit -q -m change
  _stub_bash ""
  _stub_docker aarch64
  run env PATH="${SCRATCH}/bin:${PATH}" "$(command -v bash)" \
      "${SCRATCH}/repo/script/ci/pre_pr_mirror.sh" --base "${_base}"
  assert_failure 3
  refute_output --partial 'every planned command was green'
  for _leg in 'just test acceptance' 'just test system'; do
    assert_output --partial "NOT RUN: ${_leg} (CI runs it on an amd64 runner; the docker daemon here is aarch64)"
    grep -Fxq -- "${_leg}" "${SCRATCH}/ran" && fail "the mirror ran ${_leg} on an aarch64 daemon"
  done
  grep -Fxq -- "${COVERAGE_MATRIX}" "${SCRATCH}/ran" \
      || fail "the arch-neutral legs stopped running too: $(cat "${SCRATCH}/ran")"
}

# why: "cannot tell the daemon's arch" must not read as amd64.
@test "pre-PR mirror: with no reachable daemon the amd64 legs are reported not run (base#1409)" {
  _require_mirror
  local _base
  _base="$(_make_mirror_repo)"
  printf 'services: {}\n' > "${SCRATCH}/repo/compose.yaml"
  git -C "${SCRATCH}/repo" -c user.name=t -c user.email=t@t add -A
  git -C "${SCRATCH}/repo" -c user.name=t -c user.email=t@t commit -q -m change
  _stub_bash ""
  _stub_docker ""
  run env PATH="${SCRATCH}/bin:${PATH}" "$(command -v bash)" \
      "${SCRATCH}/repo/script/ci/pre_pr_mirror.sh" --base "${_base}"
  assert_failure 3
  refute_output --partial 'every planned command was green'
  assert_output --partial 'NOT RUN: just test acceptance (CI runs it on an amd64 runner; the docker daemon here is unknown)'
}

# why: The floor read coverage/cobertura.xml, which kcov never writes, so a
# passing coverage run went red here and the system and acceptance legs after
# it never ran.
@test "pre-PR mirror: the coverage floor reads each shard's kcov-merged/cobertura.xml where the matrix keeps it (base#1409)" {
  local _table _floor _n
  _table="$(_mirror_table)" || return 1
  _floor="$(_floor_cmd "${_table}")"
  [[ -n "${_floor}" ]] || fail "the mirror's coverage-gate command runs no coverage_gate.sh"
  ln -s /source/script "${SCRATCH}/script"
  # The layout kcov leaves when more than one command reported into a
  # shard's coverage/: a per-command report and the merged one. Only the
  # merged one clears the floor, so reading the other is red.
  for _n in 1 2; do
    _make_report "${SCRATCH}/coverage-shards/${_n}/kcov-merged/cobertura.xml" 90
    _make_report "${SCRATCH}/coverage-shards/${_n}/bats.0123abcd/cobertura.xml" 10
  done
  run env COVERAGE_MIN=80 bash -c "cd '${SCRATCH}' && ${_floor}"
  assert_success
  # Every shard counts: a second shard whose own file sits below the floor
  # pulls the merged rate red (the merge is a per-line union, so the file
  # has to be one the first shard did not cover).
  _make_report "${SCRATCH}/coverage-shards/2/kcov-merged/cobertura.xml" 10 other.sh
  run env COVERAGE_MIN=80 bash -c "cd '${SCRATCH}' && ${_floor}"
  assert_failure
}

# why: A single kcov command leaves only its own <command>.<hash> report and
# no kcov-merged one; the floor must read that layout too.
@test "pre-PR mirror: the coverage floor reads a single kcov run's own report (base#1409)" {
  local _table _floor
  _table="$(_mirror_table)" || return 1
  _floor="$(_floor_cmd "${_table}")"
  [[ -n "${_floor}" ]] || fail "the mirror's coverage-gate command runs no coverage_gate.sh"
  ln -s /source/script "${SCRATCH}/script"
  _make_report "${SCRATCH}/coverage-shards/1/bats.0123abcd/cobertura.xml" 90
  run env COVERAGE_MIN=80 bash -c "cd '${SCRATCH}' && ${_floor}"
  assert_success
}

# why: Report selection written once in the workflow and once in the mirror
# is two rules that can disagree; one command run by both cannot.
@test "pre-PR mirror: CI's coverage-gate picks reports with the same command the mirror runs (base#1409)" {
  local _table _floor
  _table="$(_mirror_table)" || return 1
  _floor="$(_attested_cmd "${_table}" coverage-gate)"
  [[ "${_floor}" == *'coverage_gate.sh --run-dirs '* ]] \
      || fail "the mirror's coverage-gate command does not use coverage_gate.sh --run-dirs: ${_floor}"
  run yaml_job_lines "${WF}" coverage-gate
  assert_success
  assert_output --regexp 'run: bash \./script/test/drivers/coverage_gate\.sh --run-dirs '
}

# _make_report <path> <percent> [file] -- a one-file cobertura report at
# <percent> for [file] (default thing.sh).
_make_report() {
  local _i
  mkdir -p "$(dirname "${1}")"
  {
    echo '<?xml version="1.0" ?>'
    echo "<coverage lines-covered=\"${2}\" lines-valid=\"100\">"
    echo '  <packages><package name="p"><classes>'
    echo "  <class name=\"c\" filename=\"${3:-thing.sh}\"><lines>"
    for (( _i = 1; _i <= 100; _i++ )); do
      echo "    <line number=\"${_i}\" hits=\"$(( _i <= ${2} ? 1 : 0 ))\"/>"
    done
    echo '  </lines></class>'
    echo '  </classes></package></packages>'
    echo '</coverage>'
  } > "${1}"
}

@test "pre-PR mirror: no message points at the stale .claude/scripts/ location (base#1409)" {
  _require_mirror
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
  _recipe="$(_recipe_body acceptance)"
  [[ -n "${_recipe}" ]] || fail "script/test/justfile.test declares no acceptance recipe"
  grep -Fq './script/ci/acceptance.sh' <<<"${_recipe}" \
      || fail "the acceptance recipe does not run ./script/ci/acceptance.sh:
${_recipe}"
}
