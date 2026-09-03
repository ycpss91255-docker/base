#!/usr/bin/env bats
#
# reclaim_wiring_spec.bats - the scoped reclaim runs by itself, at the
# verbs that END a compose project, and never changes their verdict.
#
# A chore that requires a human to remember it is not a handled chore: the
# collector this repo already shipped would have removed every one of the
# 417 orphaned networks measured on the development host, and it was never
# invoked. So the assertions here are about WIRING -- which verbs reclaim,
# which deliberately do not, and what a failing reclaim is allowed to do to
# the caller's exit status (nothing).
#
# `stop` is what a user reaches for when they are done with a project.
# `test` is where the litter is actually made: each throwaway copy of the
# tree mints a project of its own, and nobody runs `stop` in a copy they
# are about to delete. `system` and `smoke` drive compose directly rather
# than through test.sh's dispatcher, so they carry their own line.
#
# `build` / `run` / `start` / `exec` are NOT wired, and that is the whole
# point of the list: each of them BEGINS or CONTINUES a flow -- a build is
# followed by a run, an exec needs the container it attaches to -- so a
# reclaim there would be collecting a project that is about to be used.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  TESTSH=/source/script/test/test.sh
  STOPSH=/source/dist/script/docker/wrapper/stop.sh
  PRUNESH=/source/dist/script/docker/wrapper/prune.sh
  JUSTTEST=/source/script/test/justfile.test
  JUSTDOCKER=/source/dist/script/docker/justfile.docker
}

# ── `just test`: the verb that mints the litter ─────────────────────────────

@test "test.sh installs the reclaim as an EXIT handler on the direct-run path only" {
  # File scope, next to the `main "$@"` guard: a trap installed while the
  # specs have test.sh SOURCED would fire when the spec's own shell exits.
  run code_grep -E 'trap .*_test_exit_reclaim.* EXIT' "${TESTSH}"
  assert_success
}

@test "test.sh arms the reclaim where a compose project is actually minted" {
  run code_grep -F '_RECLAIM_ARMED=1' "${TESTSH}"
  assert_success
}

@test "a reclaim failure does not change the suite's verdict" {
  run bash -c '
    source /source/script/test/test.sh
    declare -F _test_exit_reclaim >/dev/null || exit 99
    _RECLAIM_ARMED=1
    _reclaim_orphan_projects() { return 1; }
    _reclaim_tool_tags() { return 1; }
    trap _test_exit_reclaim EXIT
    exit 7
  '
  [ "${status}" -eq 7 ]
}

@test "a reclaim failure does not turn a green run red" {
  run bash -c '
    source /source/script/test/test.sh
    declare -F _test_exit_reclaim >/dev/null || exit 99
    _RECLAIM_ARMED=1
    _reclaim_orphan_projects() { return 1; }
    _reclaim_tool_tags() { return 1; }
    trap _test_exit_reclaim EXIT
    exit 0
  '
  [ "${status}" -eq 0 ]
}

@test "a reclaim failure is reported rather than swallowed" {
  run bash -c '
    source /source/script/test/test.sh
    declare -F _test_exit_reclaim >/dev/null || exit 99
    _RECLAIM_ARMED=1
    _reclaim_orphan_projects() { return 1; }
    _reclaim_tool_tags() { return 1; }
    trap _test_exit_reclaim EXIT
    exit 0
  ' 2>&1
  assert_output --partial "reclaim"
}

@test "the reclaim still runs when the suite FAILED -- litter from a red run is litter" {
  run bash -c '
    source /source/script/test/test.sh
    declare -F _test_exit_reclaim >/dev/null || exit 99
    _RECLAIM_ARMED=1
    _reclaim_orphan_projects() { printf "ran-orphans\n"; }
    _reclaim_tool_tags() { printf "ran-tags\n"; }
    trap _test_exit_reclaim EXIT
    exit 3
  '
  [ "${status}" -eq 3 ]
  assert_output --partial "ran-orphans"
  assert_output --partial "ran-tags"
}

@test "a run that minted no compose project reclaims nothing" {
  # `test.sh --test-tools-image` is a pure query the system / smoke recipes
  # call before they build; it must not open a daemon connection.
  run bash -c '
    source /source/script/test/test.sh
    declare -F _test_exit_reclaim >/dev/null || exit 99
    _reclaim_orphan_projects() { printf "ran-orphans\n"; }
    _reclaim_tool_tags() { printf "ran-tags\n"; }
    trap _test_exit_reclaim EXIT
    exit 0
  '
  [ "${status}" -eq 0 ]
  refute_output --partial "ran-orphans"
}

# ── the other two litter-minting test flows ────────────────────────────────

@test "just test system reclaims when it is done, pass or fail" {
  run grep -F 'script/prune.sh --reclaim' "${JUSTTEST}"
  assert_success
  run grep -cF 'script/prune.sh --reclaim' "${JUSTTEST}"
  assert_output "2"
}

# ── `just stop`: what a user reaches for when they are done ────────────────

@test "stop.sh reclaims after the project comes down" {
  run code_grep -F '_reclaim_after_stop' "${STOPSH}"
  assert_success
}

@test "stop.sh's reclaim cannot fail the stop" {
  run code_grep -F '_reclaim_after_stop || true' "${STOPSH}"
  assert_success
}

# ── the verbs that are NOT wired, named so the omission is a decision ──────

@test "the verbs that BEGIN a flow do not reclaim" {
  local _v
  for _v in build run exec; do
    run code_grep -F '_reclaim_after' "/source/dist/script/docker/wrapper/${_v}.sh"
    assert_failure
  done
}

# ── the daemon-wide prune stays the explicit bigger hammer ─────────────────

@test "prune.sh exposes the scoped reclaim as its own mode" {
  run code_grep -F -- '--reclaim' "${PRUNESH}"
  assert_success
  run code_grep -F -- '--orphan-projects' "${PRUNESH}"
  assert_success
  run code_grep -F -- '--tool-tags' "${PRUNESH}"
}

@test "--all does not quietly acquire the scoped reclaim" {
  # --all is the daemon-wide hammer and stays exactly what it was:
  # networks + images + builder. Widening it here would make every
  # existing --all invocation start deleting on a different rule.
  run bash -c "sed -n '/--all)/,/;;/p' '${PRUNESH}' | grep -E 'DO_ORPHAN_PROJECTS|DO_TOOL_TAGS'"
  assert_failure
}

@test "the daemon-wide prune targets are untouched" {
  local _t
  for _t in DO_NETWORKS DO_IMAGES DO_VOLUMES DO_BUILDER; do
    run code_grep -F "${_t}=true" "${PRUNESH}"
    assert_success
  done
}

@test "the scoped reclaim is reachable through just, with no new namespace" {
  # ADR-00000011: docker is a namespace like the rest and prune is its
  # verb; the reclaim is a MODE of that verb, so `just docker prune
  # --reclaim` needs no new recipe, no new help table and no new
  # completion entry to be a first-class control surface.
  run grep -F './script/prune.sh {{args}}' "${JUSTDOCKER}"
  assert_success
}
