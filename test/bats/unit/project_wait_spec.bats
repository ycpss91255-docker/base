#!/usr/bin/env bats
#
# project_wait_spec.bats -- a compose network that cannot be recreated
# because the previous run's endpoint is still attached is a WAIT, not a
# failure.
#
# What it looked like before. A `just test` run was interrupted; the next
# one on the same worktree died before a single test ran:
#
#   Network base-21edffd44abe_default Removing
#   network:default Error response from daemon: error while removing
#     network: ... has active endpoints
#     (name:"base-21edffd44abe-ci-run-7f94f773082d")
#   error: recipe `default` failed on line 24 with exit code 1
#
# The gate reported `rc=1 not_ok=0`. Nothing failed; the previous run's
# container was still shutting down and still attached to the project
# network, so compose could neither remove nor recreate it. It cleared on
# its own about a minute later -- which is exactly what makes it worth
# handling rather than footnoting: a red gate with no failing test and no
# statement of what it was waiting for sends the reader hunting for a code
# defect.
#
# So the run asks first, and says what it finds. A container of THIS
# project that is on its way out is waited for, with a bounded window and
# a line naming it. One that never leaves fails the run naming the
# container and the verb that clears it, instead of handing over the
# daemon's raw text.
#
# OWNERSHIP IS EXACT, not a prefix. The listing filters on BOTH labels --
# docker's own `com.docker.compose.project`, which must equal the name
# this run is about to use, and the `base.checkout.path` compose.yaml
# stamps, which must equal this checkout. A network that carries neither
# is somebody else's and is never inspected, let alone waited for.
#
# A RUNNING container is not a wedge. Two runs sharing one project's
# network is the ordinary concurrent case and compose reuses the network
# happily; waiting for a live stack to end would be waiting for something
# that is not leaving.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC2154
  TEMP_DIR="$(mktemp -d)"
  export TEMP_DIR
  DOCKER_STUB_DIR="${TEMP_DIR}/stub"
  export DOCKER_STUB_DIR
  mkdir -p "${DOCKER_STUB_DIR}"

  BIN_DIR="${TEMP_DIR}/bin"
  mkdir -p "${BIN_DIR}"
  cat > "${BIN_DIR}/docker" <<'STUB'
#!/usr/bin/env bash
# A daemon whose answers are files:
#   net_ls              network ids `docker network ls` returns
#   endpoints.<id>      container names attached to that network
#   state.<name>        that container's State.Status
#   detach_after N      endpoints empty from inspect call N+1 onwards
#   fail_net_ls         `docker network ls` exits non-zero
_d="${DOCKER_STUB_DIR}"
printf '%s\n' "$*" >> "${_d}/calls"
case "${1:-}" in
  network)
    case "${2:-}" in
      ls)
        [[ -e "${_d}/fail_net_ls" ]] && exit 1
        cat "${_d}/net_ls" 2>/dev/null
        exit 0
        ;;
      inspect)
        _id="${!#}"
        _n="$(cat "${_d}/inspect_count" 2>/dev/null || printf '0')"
        _n=$(( _n + 1 ))
        printf '%s' "${_n}" > "${_d}/inspect_count"
        if [[ -e "${_d}/detach_after" ]] \
           && (( _n > $(cat "${_d}/detach_after") )); then
          exit 0
        fi
        cat "${_d}/endpoints.${_id}" 2>/dev/null
        exit 0
        ;;
    esac
    ;;
  inspect)
    _name="${!#}"
    cat "${_d}/state.${_name}" 2>/dev/null
    exit 0
    ;;
esac
exit 0
STUB
  chmod +x "${BIN_DIR}/docker"
  export PATH="${BIN_DIR}:${PATH}"

  PROJECT=base-d00dfeed1234
  CHECKOUT="${TEMP_DIR}/checkout"
  mkdir -p "${CHECKOUT}"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# _await runs the subject in a shell that has sourced test.sh, with the
# stubbed docker on PATH.
_await() {
  run bash -c "
    export PATH='${BIN_DIR}:'\"\${PATH}\"
    export DOCKER_STUB_DIR='${DOCKER_STUB_DIR}'
    export LOG_FORMAT=text
    source /source/script/test/test.sh
    declare -F _await_project_quiescent >/dev/null || exit 99
    _await_project_quiescent '${PROJECT}' '${CHECKOUT}'
  " 2>&1
}

@test "a project with nothing attached to its network is ready at once" {
  printf 'net1\n' > "${DOCKER_STUB_DIR}/net_ls"
  : > "${DOCKER_STUB_DIR}/endpoints.net1"
  _await
  assert_success
  refute_output --partial "waiting"
}

@test "a project with no network of its own at all is ready at once" {
  : > "${DOCKER_STUB_DIR}/net_ls"
  _await
  assert_success
  refute_output --partial "waiting"
}

@test "the listing is filtered by both labels, so only this checkout's project is looked at" {
  printf 'net1\n' > "${DOCKER_STUB_DIR}/net_ls"
  : > "${DOCKER_STUB_DIR}/endpoints.net1"
  _await
  assert_success
  run cat "${DOCKER_STUB_DIR}/calls"
  assert_output --partial "com.docker.compose.project=${PROJECT}"
  assert_output --partial "base.checkout.path=${CHECKOUT}"
}

@test "a container still detaching is waited for, and the wait says what it waits for" {
  printf 'net1\n' > "${DOCKER_STUB_DIR}/net_ls"
  printf '%s-ci-run-7f94f773082d\n' "${PROJECT}" > "${DOCKER_STUB_DIR}/endpoints.net1"
  printf 'removing\n' > "${DOCKER_STUB_DIR}/state.${PROJECT}-ci-run-7f94f773082d"
  printf '1\n' > "${DOCKER_STUB_DIR}/detach_after"
  _await
  assert_success
  assert_output --partial "${PROJECT}-ci-run-7f94f773082d"
  assert_output --partial "removing"
}

@test "a container that never detaches fails naming it and the verb that clears it" {
  printf 'net1\n' > "${DOCKER_STUB_DIR}/net_ls"
  printf '%s-ci-run-stuck\n' "${PROJECT}" > "${DOCKER_STUB_DIR}/endpoints.net1"
  printf 'exited\n' > "${DOCKER_STUB_DIR}/state.${PROJECT}-ci-run-stuck"
  BASE_PROJECT_WAIT=1s run bash -c "
    export PATH='${BIN_DIR}:'\"\${PATH}\"
    export DOCKER_STUB_DIR='${DOCKER_STUB_DIR}'
    export LOG_FORMAT=text
    source /source/script/test/test.sh
    _await_project_quiescent '${PROJECT}' '${CHECKOUT}'
  " 2>&1
  assert_failure
  assert_output --partial "${PROJECT}-ci-run-stuck"
  assert_output --partial "just test stop"
}

@test "the wedged run says no test failed, so the reader stops hunting for one" {
  printf 'net1\n' > "${DOCKER_STUB_DIR}/net_ls"
  printf '%s-ci-run-stuck\n' "${PROJECT}" > "${DOCKER_STUB_DIR}/endpoints.net1"
  printf 'exited\n' > "${DOCKER_STUB_DIR}/state.${PROJECT}-ci-run-stuck"
  BASE_PROJECT_WAIT=1s run bash -c "
    export PATH='${BIN_DIR}:'\"\${PATH}\"
    export DOCKER_STUB_DIR='${DOCKER_STUB_DIR}'
    export LOG_FORMAT=text
    source /source/script/test/test.sh
    _await_project_quiescent '${PROJECT}' '${CHECKOUT}'
  " 2>&1
  assert_failure
  assert_output --partial "no test ran"
}

@test "a running container is a concurrent run, not a wedge" {
  printf 'net1\n' > "${DOCKER_STUB_DIR}/net_ls"
  printf '%s-ci-run-live\n' "${PROJECT}" > "${DOCKER_STUB_DIR}/endpoints.net1"
  printf 'running\n' > "${DOCKER_STUB_DIR}/state.${PROJECT}-ci-run-live"
  _await
  assert_success
  refute_output --partial "waiting"
}

@test "an unreadable docker is not evidence of a wedge" {
  : > "${DOCKER_STUB_DIR}/fail_net_ls"
  _await
  assert_success
  assert_output --partial "could not"
}

@test "a malformed wait window is named and the default is used, not the run refused" {
  printf 'net1\n' > "${DOCKER_STUB_DIR}/net_ls"
  : > "${DOCKER_STUB_DIR}/endpoints.net1"
  BASE_PROJECT_WAIT=banana run bash -c "
    export PATH='${BIN_DIR}:'\"\${PATH}\"
    export DOCKER_STUB_DIR='${DOCKER_STUB_DIR}'
    export LOG_FORMAT=text
    source /source/script/test/test.sh
    _await_project_quiescent '${PROJECT}' '${CHECKOUT}'
  " 2>&1
  assert_success
  assert_output --partial "banana"
}

# ── the wiring: the question is asked before compose is asked ─────────────

@test "a wedged project stops the dispatch before compose is called" {
  # Behaviour, not line order: with the wait refusing, _run_via_compose
  # must return non-zero having driven no compose command at all. A run
  # that reached compose anyway would emit the daemon's raw text again,
  # which is the whole defect.
  run bash -c "
    export PATH='${BIN_DIR}:'\"\${PATH}\"
    export DOCKER_STUB_DIR='${DOCKER_STUB_DIR}'
    export LOG_FORMAT=text
    source /source/script/test/test.sh
    _prepare_prev_release() { :; }
    _resolve_compose_project_name() { printf '${PROJECT}\n'; }
    _resolve_test_tools_image() { printf 'test-tools:deadbeef1234\n'; }
    _ensure_test_tools_image() { printf 'ensure-called\n'; }
    _residue_guard_available() { return 1; }
    _residue_forget() { :; }
    _await_project_quiescent() { return 1; }
    _run_via_compose ci 0
  " 2>&1
  assert_failure
  refute_output --partial "compose"
}

@test "a quiescent project lets the dispatch through" {
  run bash -c "
    export PATH='${BIN_DIR}:'\"\${PATH}\"
    export DOCKER_STUB_DIR='${DOCKER_STUB_DIR}'
    export LOG_FORMAT=text
    source /source/script/test/test.sh
    _prepare_prev_release() { :; }
    _resolve_compose_project_name() { printf '${PROJECT}\n'; }
    _resolve_test_tools_image() { printf 'test-tools:deadbeef1234\n'; }
    _ensure_test_tools_image() { :; }
    _residue_guard_available() { return 1; }
    _residue_forget() { :; }
    _await_project_quiescent() { return 0; }
    _run_via_compose ci 0
  " 2>&1
  assert_success
  run cat "${DOCKER_STUB_DIR}/calls"
  assert_output --partial "compose -p ${PROJECT}"
}

# ── the two flows that drive compose without the dispatcher ───────────────
#
# `just test system` and `just test smoke` do not go through
# _run_via_compose: each drives compose itself, against the SAME project
# the dispatcher uses. They already carry their own reclaim line for that
# reason; the same argument makes them carry their own wait. Without it,
# the flow that most often leaves a container behind (a system run
# interrupted mid-build) is the one flow that still meets the daemon's raw
# text on its next attempt.
#
# The flag is how they ask, so that the question has ONE implementation
# rather than a copy of the poll loop in each recipe body.

@test "test.sh --await-project answers for this checkout and exits" {
  printf 'net1\n' > "${DOCKER_STUB_DIR}/net_ls"
  : > "${DOCKER_STUB_DIR}/endpoints.net1"
  PATH="${BIN_DIR}:${PATH}" run bash /source/script/test/test.sh --await-project
  assert_success
}

@test "test.sh --await-project refuses when the project is still held" {
  printf 'net1\n' > "${DOCKER_STUB_DIR}/net_ls"
  printf 'someproject-ci-run-stuck\n' > "${DOCKER_STUB_DIR}/endpoints.net1"
  printf 'exited\n' > "${DOCKER_STUB_DIR}/state.someproject-ci-run-stuck"
  PATH="${BIN_DIR}:${PATH}" BASE_PROJECT_WAIT=1s \
    run bash /source/script/test/test.sh --await-project
  assert_failure
  assert_output --partial "someproject-ci-run-stuck"
  assert_output --partial "just test stop"
}

@test "system and smoke both ask before they build" {
  run grep -cF -- './script/test/test.sh --await-project' /source/script/test/justfile.test
  assert_output "2"
}
