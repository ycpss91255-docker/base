#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/errexit_bang.sh -- the "a `!`
# statement that is not last cannot fail its test" lint.
#
# bash exempts a pipeline prefixed with `!` from errexit (POSIX: the
# shell does not exit when the failing command is part of a `!`
# expression). Inside a bats test body -- a function run under `set -e`
# whose RETURN STATUS is the verdict -- that has one consequence: a
# `! <cmd>` line is an assertion only when it is the body's LAST
# statement, where its status becomes the body's. Anywhere else it is
# decoration: the command runs, the negation is computed, and the result
# is thrown away. The test goes on to pass.
#
# This tree has now paid for that twice in one review round
# (compose_watchdog_spec's WATCHDOG_INTERVAL half, and the inverted greps
# in dockerfile_migrate_spec / upgrade_spec before it), each time found by
# hand. The rule is mechanical, so it is a lint.
#
# Detection runs against a controlled temp REPO_ROOT so the spec is
# independent of the live tree's contents; a final case drives the REAL
# tree to prove it passes today. Shape mirrors
# early_close_reader_lint_spec.bats.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the function runs against a controlled scratch tree.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/errexit_bang.sh

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/test/bats/unit"
  REPO_ROOT="${SCRATCH}"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _write <relative-path> <line>... -- create a scanned-tree fixture file.
_write() {
  local _rel="${1}"; shift
  mkdir -p "$(dirname "${SCRATCH}/${_rel}")"
  printf '%s\n' "$@" > "${SCRATCH}/${_rel}"
}

# ════════════════════════════════════════════════════════════════════
# _run_errexit_bang: violations
# ════════════════════════════════════════════════════════════════════

@test "_run_errexit_bang: FAILS on a non-final bang statement, naming file and line (#956)" {
  # The compose_watchdog shape: two absence assertions, only the last of
  # which can fail.
  _write "test/bats/unit/x_spec.bats" \
    '@test "two absence checks" {' \
    '  ! grep -qF A "${_f}"' \
    '  ! grep -qF B "${_f}"' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"test/bats/unit/x_spec.bats:2"* ]]
  [[ "${output}" != *"x_spec.bats:3"* ]]
}

@test "_run_errexit_bang: FAILS on a bang statement buried mid-body (#956)" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "buried" {' \
    '  ! ovr_get some.key' \
    '  is_removed some.key' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:2"* ]]
}

@test "_run_errexit_bang: FAILS on a bang statement nested in a block (#956)" {
  # Still exempt, and still not the body's status.
  _write "test/bats/unit/x_spec.bats" \
    '@test "nested" {' \
    '  if [[ -n "${_x}" ]]; then' \
    '    ! grep -q A "${_f}"' \
    '  fi' \
    '  assert_success' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:3"* ]]
}

@test "_run_errexit_bang: FAILS on the FIRST line of a continued bang statement that is not last (#956)" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "continued" {' \
    '  ! grep -q A \' \
    '      "${_f}"' \
    '  assert_success' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:2"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_errexit_bang: what is NOT a violation
# ════════════════════════════════════════════════════════════════════

@test "_run_errexit_bang: PASSES when the bang statement is the body's last (#956)" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "final bang" {' \
    '  assert_success' \
    '  ! ovr_get some.key' \
    '}'
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
}

@test "_run_errexit_bang: PASSES when only comments and blanks follow the bang (#956)" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "trailing prose" {' \
    '  ! ovr_get some.key' \
    '  # the override was never written' \
    '' \
    '}'
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
}

@test "_run_errexit_bang: PASSES when the bang statement ends the body across a continuation (#956)" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "final continued bang" {' \
    '  ! grep -q A \' \
    '      "${_f}"' \
    '}'
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
}

@test "_run_errexit_bang: does not flag a bang that continues the previous line (#956)" {
  # `find ... \` / `! -name x` -- a find predicate, not a statement.
  _write "test/bats/unit/x_spec.bats" \
    '_libs() {' \
    '  find "${SRC}/lib" -name "*.sh" \' \
    '    ! -name "help.sh" | sort' \
    '}' \
    '@test "uses it" {' \
    '  _libs' \
    '}'
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
}

@test "_run_errexit_bang: does not flag a bang outside any test body (#956)" {
  # File-scope helpers are not bats bodies; errexit there is the caller's
  # problem and this rule says nothing about it.
  _write "test/bats/unit/x_spec.bats" \
    '_helper() {' \
    '  ! grep -q A "${_f}"' \
    '  return 0' \
    '}' \
    '@test "t" {' \
    '  _helper' \
    '}'
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
}

@test "_run_errexit_bang: does not flag a commented-out bang (#956)" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "prose about the shape" {' \
    '  # ! grep -q A "${_f}" would be inert here' \
    '  assert_success' \
    '}'
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
}

# ════════════════════════════════════════════════════════════════════
# Population: a scan that found nothing is not a pass
# ════════════════════════════════════════════════════════════════════

@test "_run_errexit_bang: FAILS when the scan root is absent (#956)" {
  rm -rf "${SCRATCH}/test/bats"
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"test/bats"* ]]
}

@test "_run_errexit_bang: FAILS when the scan root holds no spec files (#956)" {
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
}

@test "_run_errexit_bang: FAILS when a test header the parser never opened exists (#956)" {
  # The population cross-check: every `@test` line in the tree must
  # correspond to a body the parser actually walked. A header whose brace
  # sits on the next line would otherwise make its whole body invisible
  # to the rule, and the lint would pass by not looking.
  _write "test/bats/unit/x_spec.bats" \
    '@test "brace on the next line"' \
    '{' \
    '  ! grep -q A "${_f}"' \
    '  assert_success' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"@test"* ]]
}

@test "_run_errexit_bang: FAILS on a violation in a bats tree outside test/bats (#956)" {
  # dist/test/bats/smoke/ is a SECOND live bats tree: `just test smoke`
  # runs it and the .base subtree ships it into every downstream repo. A
  # test body's return status is the verdict there exactly as it is under
  # test/bats, so a hand-listed scan root exempts it while the rule -- and
  # this lint's own name -- claim every bats body. The population is
  # DERIVED from the tree, not listed here.
  _write "test/bats/unit/x_spec.bats" \
    '@test "clean" {' \
    '  true' \
    '}'
  _write "dist/test/bats/smoke/shared/entrypoint.bats" \
    '@test "the entrypoint is installed" {' \
    '  ! test -e /entrypoint.sh' \
    '  true' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/test/bats/smoke/shared/entrypoint.bats:2"* ]]
}

# ════════════════════════════════════════════════════════════════════
# Allow region
# ════════════════════════════════════════════════════════════════════

@test "_run_errexit_bang: an allow region suppresses the finding (#956)" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "opted out" {' \
    '  # errexit-bang-lint: allow-begin -- reason' \
    '  ! grep -q A "${_f}"' \
    '  # errexit-bang-lint: allow-end' \
    '  assert_success' \
    '}'
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
}

@test "_run_errexit_bang: an unterminated allow region fails (#956)" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "opted out and never back in" {' \
    '  # errexit-bang-lint: allow-begin -- reason' \
    '  ! grep -q A "${_f}"' \
    '  assert_success' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unterminated"* ]]
}

@test "_run_errexit_bang: an unmatched allow-end fails (#956)" {
  _write "test/bats/unit/x_spec.bats" \
    '@test "closed a region it never opened" {' \
    '  # errexit-bang-lint: allow-end' \
    '  assert_success' \
    '}'
  run _run_errexit_bang
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unmatched"* ]]
}

# ════════════════════════════════════════════════════════════════════
# The real tree
# ════════════════════════════════════════════════════════════════════

@test "_run_errexit_bang: the real bats tree is clean (#956)" {
  REPO_ROOT=/source
  run _run_errexit_bang
  [ "${status}" -eq 0 ]
}
