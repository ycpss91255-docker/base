#!/usr/bin/env bats
#
# coverage_workdir_isolation_spec.bats -- a driver test that starts a nested
# coverage driver never writes into a work dir the CALLER named.
#
# why: `_coverage_parallel_workdir` reuses an exported COVERAGE_LOCAL_WORKDIR
# and keeps it. A spec that starts a nested driver inherits it, so the nested
# run wrote into the parent's work dir and truncated the parent's log-1 to 0
# bytes: a test damaging the evidence of the run it belongs to, with a result
# that depends on the caller's environment (base#1420). The nested specs must
# not inherit it.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
}

# _run_nested <work>
#   The specs that start a nested coverage driver, run for real with
#   COVERAGE_LOCAL_WORKDIR exported to <work> -- the caller's environment
#   this hazard depends on.
_run_nested() {
  local _work="${1}"
  env -u BATS_TEST_TIMEOUT -u BASH_ENV -u BASH_XTRACEFD -u KCOV_BASH_XTRACEFD \
    -u LD_PRELOAD -u COVERAGE \
    COVERAGE_LOCAL_WORKDIR="${_work}" \
    bats --filter '_run_coverage' \
      "${BATS_TEST_DIRNAME}/ci_spec.bats" \
      "${BATS_TEST_DIRNAME}/coverage_shard_parity_spec.bats" \
      "${BATS_TEST_DIRNAME}/kcov_bash_instrumentation_spec.bats"
}

# why: the sentinel stands for the parent's evidence. Any write to the named
# dir, a truncated log-1 or a slice dir the nested run created, is the leak.
@test "nested driver tests leave a caller-named COVERAGE_LOCAL_WORKDIR untouched (base#1420)" {
  local _work="${BATS_TEST_TMPDIR}/parent-work"
  mkdir -p "${_work}"
  printf 'parent evidence\n' > "${_work}/log-1"

  run _run_nested "${_work}"

  [[ "$(cat "${_work}/log-1")" == "parent evidence" ]] \
    || fail "a nested driver test rewrote the parent's log-1: $(cat "${_work}/log-1")"
  local _extra
  _extra="$(find "${_work}" -mindepth 1 -not -name log-1)"
  [[ -z "${_extra}" ]] \
    || fail "a nested driver test wrote into the parent's work dir: ${_extra}"
}
