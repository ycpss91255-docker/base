#!/usr/bin/env bats
#
# why: The guard that keeps a whole-tree lint scan out of the coverage
# suite. base#1075 measured what one of them costs -- 331s of a 501s
# coverage shard, 66% of the critical path of the entire coverage matrix,
# in a single test that no shard count can split -- and a roster of the
# twenty-one that existed would be right until the twenty-second, so the
# rule is derived from the coverage pools, the compose mount and the
# assignment shape instead.
#
# Unit tests for script/test/drivers/spec_repo_root.sh -- the "a spec's
# REPO_ROOT is a fixture, never the live checkout" lint.
#
# Every case here drives a scratch REPO_ROOT, and there is deliberately no
# real-tree case: this is the lint whose whole subject is that a spec must
# not run a driver over the live tree, so one here would be the thing it
# refuses. The live tree is asserted by the `lint-static` group that runs
# this driver, which is the placement the lint exists to enforce.
#
# The refused text is never spelled literally in this file. The detector
# reads `<name>REPO_ROOT=<live root>` and this spec IS one of the files it
# scans, so a fixture written as a literal would make the shipped tree
# fail its own lint. Every fixture composes the two halves at run time.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). drivers/bats.sh comes first because the lint takes its scan
  # roots from _COVERAGE_FULL_SUITE_POOLS, the one definition of what the
  # coverage suite runs.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/bats.sh
  # shellcheck disable=SC1091
  source /source/script/test/drivers/spec_repo_root.sh

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/test/bats/unit" "${SCRATCH}/test/bats/integration"
  REPO_ROOT="${SCRATCH}"

  # The mount the fixtures point at. Composed, never written whole (see
  # the file header).
  MOUNT="/source"
  _write_compose "${MOUNT}"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _write_compose <target> -- write a compose.yaml binding the checkout at <target>.
_write_compose() {
  printf 'services:\n  ci:\n    volumes:\n      - .:%s\n    working_dir: %s\n' \
    "${1}" "${1}" > "${SCRATCH}/compose.yaml"
}

# _spec <relative-path> <line>... -- create a scanned spec fixture.
_spec() {
  local _rel="${1}"; shift
  mkdir -p "$(dirname "${SCRATCH}/${_rel}")"
  printf '%s\n' "$@" > "${SCRATCH}/${_rel}"
}

# _assign <name> <value> -- one assignment line, assembled rather than
# spelled, so this file never carries the literal the lint refuses.
_assign() {
  printf '  %s=%s' "${1}" "${2}"
}

# ════════════════════════════════════════════════════════════════════
# Violations
# ════════════════════════════════════════════════════════════════════

# why: The shape base#1075 measured: one assignment turns a fixture spec into a
# whole-tree lint run under kcov, and the report has to name the file and
# the line so the author can see which of the two it is
@test "_run_spec_repo_root: FAILS on a spec whose REPO_ROOT is the checkout mount, naming file and line" {
  _spec "test/bats/unit/x_spec.bats" \
    '@test "the real tree is clean" {' \
    "$(_assign REPO_ROOT "${MOUNT}")" \
    '  run _run_thing' \
    '}'
  run _run_spec_repo_root
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"test/bats/unit/x_spec.bats:2"* ]]
}

# why: A quoted value is the same assignment; the tree today writes it both ways,
# and a detector that read only one spelling would report half a tree clean
@test "_run_spec_repo_root: FAILS on the quoted spelling too" {
  _spec "test/bats/unit/x_spec.bats" \
    '@test "the real tree is clean" {' \
    "$(_assign REPO_ROOT "\"${MOUNT}\"")" \
    '}'
  run _run_spec_repo_root
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:2"* ]]
}

# why: The variable name is not the point -- pointing ANY tool's root at the
# checkout is. script/watch/pins.sh reads PIN_REPO_ROOT and walks the same
# tree for the same cost
@test "_run_spec_repo_root: FAILS on a prefixed *_REPO_ROOT, not just the bare name" {
  _spec "test/bats/unit/x_spec.bats" \
    '@test "the real markers parse" {' \
    "$(_assign PIN_REPO_ROOT "${MOUNT}")" \
    '}'
  run _run_spec_repo_root
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"PIN_REPO_ROOT"* ]]
}

# why: A subtree of the checkout is still the checkout: pointing a driver at
# dist/ walks real files at real cost, and an equality test would let the
# whole class through one character at a time
@test "_run_spec_repo_root: FAILS on a path UNDER the mount, not only the mount itself" {
  _spec "test/bats/unit/x_spec.bats" \
    '@test "the real dist tree is clean" {' \
    "$(_assign REPO_ROOT "${MOUNT}/dist")" \
    '}'
  run _run_spec_repo_root
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:2"* ]]
}

# why: The mount is one spelling of the live tree and ${REPO_ROOT} is the other:
# a host-direct run of this lint reads a worktree path, and a rule that knew
# only the container's would pass on it
@test "_run_spec_repo_root: FAILS on the live REPO_ROOT itself, not only the compose mount" {
  _spec "test/bats/unit/x_spec.bats" \
    '@test "the real tree is clean" {' \
    "$(_assign REPO_ROOT "${SCRATCH}")" \
    '}'
  run _run_spec_repo_root
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:2"* ]]
}

# why: The integration pool is half the coverage suite and costs the same under
# kcov; taking the pools from _COVERAGE_FULL_SUITE_POOLS is what makes a
# third pool covered the day it is added rather than the day someone notices
@test "_run_spec_repo_root: scans every coverage pool, integration included" {
  _spec "test/bats/integration/y_spec.bats" \
    '@test "the real tree is clean" {' \
    "$(_assign REPO_ROOT "${MOUNT}")" \
    '}'
  run _run_spec_repo_root
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"test/bats/integration/y_spec.bats"* ]]
}

# why: Each offender has to be listed, because a report that stops at the first
# turns one clean-up into N cycles -- the defect base#1059 measured in the
# lint phase itself
@test "_run_spec_repo_root: reports EVERY offender, not the first" {
  _spec "test/bats/unit/a_spec.bats" \
    '@test "one" {' "$(_assign REPO_ROOT "${MOUNT}")" '}'
  _spec "test/bats/unit/b_spec.bats" \
    '@test "two" {' "$(_assign REPO_ROOT "${MOUNT}")" '}'
  run _run_spec_repo_root
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"a_spec.bats"* ]]
  [[ "${output}" == *"b_spec.bats"* ]]
}

# why: The spelling THIS FILE teaches. Every one of the twenty-three cases
# base#1075 removed wrote the root as a literal, so a detector that reads
# literals was right about the tree it was written against -- and the file
# you are reading demonstrates the other spelling four lines at a time,
# because a fixture cannot carry the refused text. One hop of indirection
# is what the next author copies, and a value the same file resolves to the
# mount is the same whole-tree scan at the same cost.
@test "_run_spec_repo_root: FAILS when the root reaches the mount through a variable" {
  _spec "test/bats/unit/x_spec.bats" \
    '@test "the real tree is clean" {' \
    "$(_assign LIVE "${MOUNT}")" \
    '  REPO_ROOT="${LIVE}" run _run_thing' \
    '}'
  run _run_spec_repo_root
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"test/bats/unit/x_spec.bats:3"* ]]
}

# why: The same one character at a time as the literal case: a subtree of the
# checkout reached through the variable walks real files at real cost
@test "_run_spec_repo_root: FAILS on a path UNDER the mount reached through a variable" {
  _spec "test/bats/unit/x_spec.bats" \
    "$(_assign LIVE "${MOUNT}")" \
    '@test "the real dist tree is clean" {' \
    '  REPO_ROOT="${LIVE}/dist" run _run_thing' \
    '}'
  run _run_spec_repo_root
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x_spec.bats:3"* ]]
}

# why: Resolution has to run in the file being scanned, not across the suite: a
# name that means the mount in one spec means a scratch dir in the next, and
# a rule that carried a name between files would accuse the second one
@test "_run_spec_repo_root: does NOT carry a variable's value between files" {
  _spec "test/bats/unit/a_spec.bats" \
    "$(_assign LIVE "${MOUNT}")" \
    '@test "reads one file" {' \
    '  run cat "${LIVE}/justfile"' \
    '}'
  _spec "test/bats/unit/b_spec.bats" \
    '@test "a driver over a fixture" {' \
    '  LIVE="${SCRATCH}"' \
    '  REPO_ROOT="${LIVE}" run _run_thing' \
    '}'
  run _run_spec_repo_root
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# ════════════════════════════════════════════════════════════════════
# What is not a violation
# ════════════════════════════════════════════════════════════════════

# why: The fixture form every other spec in this tree uses has to stay legal, and
# the count has to print: slack nobody can see is slack nobody closes
@test "_run_spec_repo_root: a fixture-rooted assignment is clean, and the count prints" {
  _spec "test/bats/unit/x_spec.bats" \
    '@test "a driver over a fixture" {' \
    '  REPO_ROOT="${SCRATCH}"' \
    '  run _run_thing' \
    '}'
  run _run_spec_repo_root
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
  [[ "${output}" == *"1 REPO_ROOT assignment"* ]]
}

# why: Every fix in this tree carries a comment spelling the bad form out -- this
# driver's own header does -- so prose about the rule must not be an
# accusation
@test "_run_spec_repo_root: a whole-line comment spelling the bad form out is not a violation" {
  _spec "test/bats/unit/x_spec.bats" \
    "#$(_assign REPO_ROOT "${MOUNT}") -- what this lint refuses" \
    '@test "a driver over a fixture" {' \
    '  REPO_ROOT="${SCRATCH}"' \
    '}'
  run _run_spec_repo_root
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# why: Reading one file under the mount is cheap, common, and not what makes a
# shard slow; a rule wide enough to flag it would flag the hundreds of
# single-file reads this suite is built from, which is how a lint gets muted
@test "_run_spec_repo_root: reading a file under the mount is not a violation" {
  _spec "test/bats/unit/x_spec.bats" \
    '@test "the table names this lint" {' \
    "  run grep -qx thing ${MOUNT}/script/test/test.sh" \
    '  REPO_ROOT="${SCRATCH}"' \
    '}'
  run _run_spec_repo_root
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# ════════════════════════════════════════════════════════════════════
# Non-vacuity: every way this could go green having checked nothing
# ════════════════════════════════════════════════════════════════════

# why: The blind-detector case, and the one that matters most: a renamed variable
# or a changed quoting convention would leave the scan matching nothing and
# printing clean over a tree full of whole-tree scans
@test "_run_spec_repo_root: DIES when no spec carries a REPO_ROOT assignment at all" {
  _spec "test/bats/unit/x_spec.bats" \
    '@test "nothing to see" {' \
    '  run true' \
    '}'
  run _run_spec_repo_root
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"vacuously"* ]]
}

# why: A relocated spec tree is the failure this repo keeps paying for: a lint
# that covers zero files and a green line that reads as a verdict over the
# suite. It asserts the DISTINGUISHING sentence and not the shared word:
# every non-vacuity die here says "vacuously", so a case that asserted only
# that stayed green with the guard it names deleted -- a different die fired
# and the test could not tell the two apart.
@test "_run_spec_repo_root: DIES when a pool holds no spec file" {
  run _run_spec_repo_root
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"nothing was scanned"* ]]
}

# why: The sixth way in, and the one furthest upstream: the pool table is what
# gives this lint its scope, so a rename in drivers/bats.sh that left it
# unset would make the scan cover nothing at all -- and an unset array under
# `set -u` reads as empty, not as an error
@test "_run_spec_repo_root: DIES when the coverage pool table is unset" {
  _spec "test/bats/unit/x_spec.bats" \
    '@test "a driver over a fixture" {' \
    '  REPO_ROOT="${SCRATCH}"' \
    '}'
  # A CHILD SHELL that never sources drivers/bats.sh, which is the only
  # state in which the table is absent: it declares the array `readonly`,
  # so nothing in this process can take it away again. That is also the
  # real shape of the failure -- a rename or a split in bats.sh leaving
  # this driver sourced with no table to read.
  run bash -c '
    set -uo pipefail
    export LOG_FORMAT=text
    source /source/dist/script/docker/lib/_lib.sh
    _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
    source /source/script/test/drivers/spec_repo_root.sh
    REPO_ROOT="${1}"
    _run_spec_repo_root
  ' _ "${SCRATCH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"_COVERAGE_FULL_SUITE_POOLS is unset"* ]]
}

# why: The pools come from the coverage runner, so a pool it runs and this cannot
# find means the lint is scanning less than the suite runs -- silently, and
# in the safe-looking direction
@test "_run_spec_repo_root: DIES when a coverage pool is missing entirely" {
  rm -rf "${SCRATCH}/test/bats/integration"
  _spec "test/bats/unit/x_spec.bats" \
    '@test "a driver over a fixture" {' \
    '  REPO_ROOT="${SCRATCH}"' \
    '}'
  run _run_spec_repo_root
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"integration"* ]]
}

# why: The refused root is READ from compose.yaml rather than written down, so a
# missing file leaves the lint with no root to refuse -- which is a lint that
# accepts everything, not a lint with nothing to do
@test "_run_spec_repo_root: DIES when compose.yaml is gone" {
  rm -f "${SCRATCH}/compose.yaml"
  _spec "test/bats/unit/x_spec.bats" \
    '@test "a driver over a fixture" {' \
    '  REPO_ROOT="${SCRATCH}"' \
    '}'
  run _run_spec_repo_root
  [ "${status}" -ne 0 ]
  # Again the distinguishing sentence: the missing-bind die below also
  # names compose.yaml, so the filename alone did not separate them.
  [[ "${output}" == *"every root would be accepted"* ]]
}

# why: The same hole with the file present: a compose file that no longer binds
# the checkout leaves the mount unknown, and an unknown mount is one the scan
# cannot refuse
@test "_run_spec_repo_root: DIES when compose.yaml binds no checkout" {
  printf 'services:\n  ci:\n    image: x\n' > "${SCRATCH}/compose.yaml"
  _spec "test/bats/unit/x_spec.bats" \
    '@test "a driver over a fixture" {' \
    '  REPO_ROOT="${SCRATCH}"' \
    '}'
  run _run_spec_repo_root
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"bind"* ]]
}

# ════════════════════════════════════════════════════════════════════
# Wiring
# ════════════════════════════════════════════════════════════════════

# why: A lint nobody runs is a comment
@test "spec-repo-root: is a member of the lint phase's tool table" {
  # _LINT_TOOLS is the one table every lint-phase caller dispatches
  # through, and it is also what the self-test.yaml completeness guard
  # reads -- so membership here is what makes the CI join mandatory.
  #
  # PARSED, never sourced: sourcing test.sh drags in the whole lib chain,
  # which reads BASH_SOURCE unguarded, and under the kcov-instrumented
  # bash of the coverage shard that aborts.
  local _test_sh="/source/script/test/test.sh"
  assert_spec_subject "${_test_sh}" "the test runner whose _LINT_TOOLS table this lint joins"
  run awk '
    /^readonly _LINT_TOOLS=\(/ { inside = 1; next }
    inside && /^\)/            { inside = 0 }
    inside {
      sub(/#.*/, "")
      gsub(/[[:space:]]+/, "")
      if ($0 != "") print
    }
  ' "${_test_sh}"
  assert_success
  assert_line "spec-repo-root"
}

# why: One plain-runner lint group, no docker -- and exactly one, because none
# gates nothing and two pays twice
@test "spec-repo-root: has a lint-static CI join" {
  local _wf="/source/.github/workflows/self-test.yaml"
  assert_spec_subject "${_wf}" "the workflow whose lint-static groups this lint joins"
  local _hits
  _hits="$(lint_group_hits spec-repo-root "${_wf}")"
  [ "${_hits}" -eq 1 ] \
    || fail "the spec-repo-root lint is in ${_hits} lint-static groups; in none, the next whole-tree spec reaches main with nothing watching it"
}

# why: An unregistered event id is an anonymous exit: the log line carries no name
# a reader can look up
@test "spec-repo-root: its failure event id is registered" {
  run grep -qx 'ci_spec_repo_root' /source/dist/script/docker/lib/log-events.txt
  assert_success
}
