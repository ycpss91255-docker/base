#!/usr/bin/env bats
#
# kcov_trace_volume_spec.bats -- a test that builds a value past one pipe
# buffer must not run under kcov (base#1400).
#
# why: Under kcov every line bash runs is traced, values included. In a
# coverage shard (jobs=4) that trace reaches the job's stdout, so a test
# that builds a 1 MiB value writes single lines of up to 1 MiB of it.
# CI run 40470315196 (coverage 7/12) stopped about 64 KiB into such a
# line and stayed silent for 60 minutes until it was cancelled. Locally,
# with the CI image and a stdout reader that stops on lines over 64 KiB,
# kcov, the four bats workers and the test's bash all blocked in
# pipe_write and the shard never finished; skipping that one test under
# COVERAGE let the same shard pass. The test still runs in plain bats
# (the bats-fragile job runs every file carrying the skip guard), so
# nothing goes unrun.
#
# The rule is mechanical: a @test body that builds a value with
# `head -c N`, N over 65536 (one Linux pipe buffer), carries the kcov
# skip guard `[ "${COVERAGE:-0}" = 1 ] && skip`. The scan is one awk
# pass, so it costs nothing under kcov.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  TEMP_DIR="$(mktemp -d)"
  # Sizes held in variables: a literal `head -c` with a number in a test
  # body here would be a hit for the repo scan below.
  MIB=1048576
  PIPE_BUF_BYTES=65536
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# _unguarded_big_values <dir>
#   Print `file:line` for each `head -c N` (N > 65536) inside a @test body
#   that has no kcov skip guard, for every *.bats under <dir>.
_unguarded_big_values() {
  find "$1" -name '*.bats' -type f -print0 | sort -z | xargs -0 -r awk '
    FNR == 1 { inbody = 0 }
    /^@test / { inbody = 1; guarded = 0; n = 0; next }
    inbody && /^}/ {
      if (!guarded) for (i = 1; i <= n; i++) print hits[i]
      inbody = 0; next
    }
    inbody {
      if ($0 ~ /^[[:space:]]*\[ "\$\{COVERAGE:-0\}" = 1 \] &&[[:space:]]*skip/) guarded = 1
      line = $0
      while (match(line, /head -c [0-9]+/)) {
        size = substr(line, RSTART + 8, RLENGTH - 8) + 0
        if (size > 65536) hits[++n] = FILENAME ":" FNR
        line = substr(line, RSTART + RLENGTH)
      }
    }
  '
}

# _fixture_test <name> <line>...
#   Print a @test block named <name> whose body is the given lines. The
#   block is printed, not written literally here: bats rewrites every
#   `@test` line of a spec before running it, heredocs included, and a
#   literal fixture would also be a hit for the repo scan below.
_fixture_test() {
  local _name="$1"
  shift
  printf '%stest "%s" {\n' '@' "${_name}"
  printf '  %s\n' "$@"
  printf '}\n'
}

# why: The scan must find the construct it forbids, or a clean tree proves
# nothing.
@test "kcov trace volume: an unguarded 1 MiB value is reported" {
  _fixture_test "big" "_big=\"\$(head -c ${MIB} /dev/zero | tr '\\0' a)\"" \
    > "${TEMP_DIR}/a_spec.bats"
  run _unguarded_big_values "${TEMP_DIR}"
  assert_success
  assert_output "${TEMP_DIR}/a_spec.bats:2"
}

# why: The guard, and a value that fits in one pipe buffer, are both
# allowed: neither floods the shard's stdout.
@test "kcov trace volume: a guarded value and a 64 KiB value pass" {
  {
    _fixture_test "big but guarded" \
      '[ "${COVERAGE:-0}" = 1 ] && skip "1 MiB trace floods the kcov shard"' \
      "_big=\"\$(head -c ${MIB} /dev/zero | tr '\\0' a)\""
    _fixture_test "small" "_v=\"\$(head -c ${PIPE_BUF_BYTES} /dev/zero | tr '\\0' a)\""
  } > "${TEMP_DIR}/b_spec.bats"
  run _unguarded_big_values "${TEMP_DIR}"
  assert_success
  assert_output ""
}

# why: The repo's own bats trees hold no unguarded large value.
@test "kcov trace volume: no test in the repo builds an unguarded value past 64 KiB" {
  run _unguarded_big_values /source/test/bats
  assert_success
  assert_output ""
}
