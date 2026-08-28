#!/usr/bin/env bats
#
# Executable tests for `assert_spec_subject` (test/bats/unit/test_helper.bash),
# the fail-closed replacement for the `[[ -f "${SUBJECT}" ]] || skip` opening
# that 54 guards across this suite used to carry.
#
# Why this file exists at all: those guards were never tested against their
# own failure mode, which is precisely how a renamed workflow could turn 52
# assertions into `ok ... # skip` and still exit 0. The helper now decides
# fail-vs-skip for every one of them, so the decision itself needs a test --
# otherwise the fix reproduces the defect it replaces, one level up.
#
# Strategy: the outcome under test is a bats OUTCOME (not-ok vs ok-with-skip),
# which cannot be observed from inside the test that produces it. So each case
# writes a one-test spec into BATS_TEST_TMPDIR and runs `bats` over it,
# asserting on the TAP the inner run emits.
#
# The generated `@test` line is INDENTED on purpose: bats accepts leading
# whitespace, and the doc-count sync counts `^@test` per file, so a
# column-0 heredoc line would be counted as a test of this file and would
# earn a phantom catalogue row in doc/test/unit.md.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  INNER="${BATS_TEST_TMPDIR}/inner_spec.bats"
}

# _write_inner <path-argument-literal>
#   Emit a one-test spec whose body is a single assert_spec_subject call on
#   the given (already-quoted) path expression.
_write_inner() {
  local _arg="${1:?BUG: _write_inner expects a path expression}"
  cat > "${INNER}" <<INNER_EOF
#!/usr/bin/env bats
setup() {
  load "/source/test/bats/unit/test_helper"
}

  @test "inner: subject present" {
    assert_spec_subject ${_arg} "the artifact the inner spec asserts on"
  }
INNER_EOF
}

@test "assert_spec_subject: a present subject lets the test run to completion" {
  local _subject="${BATS_TEST_TMPDIR}/present.yaml"
  printf 'name: anything\n' > "${_subject}"
  _write_inner "\"${_subject}\""

  run bats "${INNER}"
  assert_success
  assert_output --partial "ok 1 inner: subject present"
  refute_output --partial "# skip"
}

@test "assert_spec_subject: a missing subject FAILS the test, it does not skip it" {
  # The whole point. A skip here is the defect: it reports a green run for a
  # spec that asserted nothing, which is indistinguishable from the artifact
  # having been deleted or renamed with nobody noticing.
  _write_inner "\"${BATS_TEST_TMPDIR}/absent.yaml\""

  run bats "${INNER}"
  assert_failure
  assert_output --partial "not ok 1 inner: subject present"
  refute_output --partial "# skip"
}

@test "assert_spec_subject: the failure names the missing path and what it was" {
  _write_inner "\"${BATS_TEST_TMPDIR}/absent.yaml\""

  run bats "${INNER}"
  assert_failure
  assert_output --partial "${BATS_TEST_TMPDIR}/absent.yaml"
  assert_output --partial "the artifact the inner spec asserts on"
}

@test "assert_spec_subject: refuses an empty path rather than passing vacuously" {
  # A guard called with an unset variable must be a loud bug, not a silent
  # pass -- `[[ -f "" ]]` is false, so an unguarded version would have
  # reported a missing subject for a caller typo instead of naming it.
  _write_inner '""'

  run bats "${INNER}"
  assert_failure
  assert_output --partial "BUG: assert_spec_subject expects a path"
}

@test "no spec opens with a fail-open '|| skip' existence guard" {
  # The repo-wide invariant this helper exists to hold. An existence check
  # answered with `skip` cannot tell "absent by design" from "renamed and
  # nobody noticed"; the remaining skips in the suite guard host / image
  # CAPABILITIES (command -v ...) or a mode-gated fixture, never the presence
  # of a tracked artifact, and each states its reason at the guard.
  run grep -rnE '^\s*\[\[ -f "[^"]*" \]\] \|\| skip' /source/test/bats/
  assert_failure
}
