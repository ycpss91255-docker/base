#!/usr/bin/env bats
#
# Unit tests for script/test/test.sh helper functions.
# Only helpers that can be exercised without a full CI run are covered here.
#
# NOTE: these tests confine PATH to MOCK_DIR *after* sourcing test.sh so that
# (a) `command -v bats` inside _install_deps always misses (bats lives in
#     /usr/bin in the CI container, which MOCK_DIR does not include), and
# (b) apt-get / git resolve to our mocks instead of the real binaries.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  create_mock_dir
  local _cmd
  for _cmd in grep date cat printf; do
    local _path
    _path="$(command -v "${_cmd}" 2>/dev/null)" && ln -sf "${_path}" "${MOCK_DIR}/${_cmd}"
  done
}

teardown() {
  cleanup_mock_dir
}

# ════════════════════════════════════════════════════════════════════
# _install_deps
# ════════════════════════════════════════════════════════════════════

@test "_install_deps: skips apt-get and git when bats is already installed" {
  mock_cmd "bats" 'exit 0'
  # These mocks must NOT be invoked; fail loudly if they are.
  mock_cmd "apt-get" 'echo "apt-get should not be called"; exit 1'
  mock_cmd "git" 'echo "git should not be called"; exit 1'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    _install_deps
  '
  assert_success
  refute_output --partial "should not be called"
}

@test "_install_deps: dies with clear error when apt-get update fails" {
  mock_cmd "apt-get" '
    if [[ "$1" == "update" ]]; then exit 42; fi
    exit 0'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    _install_deps
  '
  assert_failure
  assert_output --partial "ERROR"
  assert_output --partial "apt-get update failed"
}

@test "_install_deps: dies with clear error when apt-get install fails" {
  mock_cmd "apt-get" '
    case "$1" in
      update)  exit 0 ;;
      install) exit 100 ;;
      *)       exit 0 ;;
    esac'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    _install_deps
  '
  assert_failure
  assert_output --partial "ERROR"
  assert_output --partial "apt-get install failed"
}

@test "_install_deps: dies with clear error when git clone bats-mock fails" {
  mock_cmd "apt-get" 'exit 0'
  mock_cmd "git" '
    if [[ "$1" == "clone" ]]; then exit 128; fi
    exit 0'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    _install_deps
  '
  assert_failure
  assert_output --partial "ERROR"
  assert_output --partial "git clone bats-mock failed"
}

@test "_install_deps: happy path succeeds when bats absent and all deps install cleanly" {
  mock_cmd "apt-get" 'exit 0'
  mock_cmd "git" 'exit 0'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    _install_deps
  '
  assert_success
}

@test "_install_deps: rewrites sources.list when APT_MIRROR_DEBIAN differs from default" {
  local _log="${BATS_TEST_TMPDIR}/sed.log"
  # _install_deps gates the sed branch on `[[ -f /etc/apt/sources.list ]]`,
  # which is true on the previous kcov/kcov debian runner but FALSE on the
  # alpine test-tools image (no /etc/apt). Materialise the file once if
  # missing so this regression test is image-agnostic — the goal here is
  # to verify the sed substitution logic, not the file-existence guard
  # (the unset/default tests below already cover the no-op branch).
  if [[ ! -f /etc/apt/sources.list ]]; then
    mkdir -p /etc/apt
    : > /etc/apt/sources.list
  fi
  mock_cmd "sed" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "apt-get" 'exit 0'
  mock_cmd "git" 'exit 0'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    export APT_MIRROR_DEBIAN="mirror.twds.com.tw"
    _install_deps
  '
  assert_success
  assert [ -f "${_log}" ]
  run cat "${_log}"
  assert_output --partial "s|deb.debian.org|mirror.twds.com.tw|g"
}

@test "_install_deps: skips sources.list rewrite when APT_MIRROR_DEBIAN equals default" {
  mock_cmd "sed" 'echo "sed-should-not-be-called"; exit 1'
  mock_cmd "apt-get" 'exit 0'
  mock_cmd "git" 'exit 0'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    export APT_MIRROR_DEBIAN="deb.debian.org"
    _install_deps
  '
  assert_success
  refute_output --partial "sed-should-not-be-called"
}

@test "_install_deps: skips sources.list rewrite when APT_MIRROR_DEBIAN unset" {
  mock_cmd "sed" 'echo "sed-should-not-be-called"; exit 1'
  mock_cmd "apt-get" 'exit 0'
  mock_cmd "git" 'exit 0'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    unset APT_MIRROR_DEBIAN
    _install_deps
  '
  assert_success
  refute_output --partial "sed-should-not-be-called"
}

# ════════════════════════════════════════════════════════════════════
# _run_shellcheck
#
# Regression guard: if someone adds a new shell script under script/ or
# config/ but forgets to wire it into _run_shellcheck, the list drifts
# out of sync with reality. These tests pin the expected invocations so
# that drift surfaces as a test failure.
# ════════════════════════════════════════════════════════════════════

@test "_run_shellcheck: invokes shellcheck against every expected script" {
  # Log each invocation to a capture file so we can inspect the set.
  local _log="${BATS_TEST_TMPDIR}/shellcheck.log"
  mock_cmd "shellcheck" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  # xargs needs a mock too — the real one would forward to the real
  # shellcheck binary (which lives in MOCK_DIR), so this is just a
  # belt-and-braces ensure PATH is honored.
  run bash -c '
    source /source/script/test/test.sh
    _run_shellcheck
  '
  assert_success

  assert [ -f "${_log}" ]
  run cat "${_log}"
  assert_output --partial "script/test/test.sh"
  assert_output --partial "init.sh"
  assert_output --partial "upgrade.sh"
  assert_output --partial "config/shell/terminator/setup.sh"
  assert_output --partial "config/shell/tmux/setup.sh"
  # #655: the base namespace scripts (completions.sh) are shellchecked too.
  assert_output --partial "downstream/script/base"
}

@test "_run_shellcheck: picks up every .sh file in script/docker/" {
  local _log="${BATS_TEST_TMPDIR}/shellcheck.log"
  mock_cmd "shellcheck" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  run bash -c '
    source /source/script/test/test.sh
    _run_shellcheck
  '
  assert_success

  # Every .sh under downstream/script/docker/wrapper/ and lib/ must appear.
  for _f in /source/downstream/script/docker/wrapper/*.sh /source/downstream/script/docker/lib/*.sh; do
    run grep -F "${_f}" "${_log}"
    assert_success
  done
}

@test "_run_shellcheck: exits non-zero when shellcheck fails on any script" {
  # Simulate a lint violation on init.sh specifically.
  mock_cmd "shellcheck" '
    for _arg in "$@"; do
      if [[ "${_arg}" == *"/init.sh" ]]; then
        printf "SC0001: fake violation\n" >&2
        exit 1
      fi
    done
    exit 0'
  # Enable -e to mirror real CI invocation (test.sh sets it when run
  # directly; when sourced, the caller owns strict mode).
  run bash -c '
    set -e
    source /source/script/test/test.sh
    _run_shellcheck
  '
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# _run_via_compose / main routing
#
# Regression guards for #168: default `test.sh` (no flag) must hit the
# alpine `ci` service so the apt-install path is bypassed; `--coverage`
# must hit the kcov/kcov-based `coverage` service. Mock `docker` so
# the test captures the chosen service name + COVERAGE env without
# actually running compose.
# ════════════════════════════════════════════════════════════════════

@test "_run_via_compose: routes default mode to the ci service with COVERAGE=0" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    _run_via_compose ci 0
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial "compose"
  assert_output --partial "COVERAGE=0"
  assert_output --partial " ci"
  refute_output --partial "COVERAGE=1"
}

@test "_run_via_compose: routes coverage mode to the coverage service with COVERAGE=1" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    _run_via_compose coverage 1
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial "compose"
  assert_output --partial "COVERAGE=1"
  assert_output --partial " coverage"
}

@test "main: dispatches no-flag default to the ci service" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial " ci"
  assert_output --partial "COVERAGE=0"
}

@test "_run_tests: passes --jobs N when parallel is on PATH" {
  local _log="${BATS_TEST_TMPDIR}/bats.log"
  mock_cmd "parallel" 'exit 0'
  mock_cmd "nproc" 'echo 8'
  mock_cmd "bats" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    _run_tests
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial "--jobs 8"
}

@test "_run_tests: omits --jobs when parallel is absent (graceful fallback)" {
  local _log="${BATS_TEST_TMPDIR}/bats.log"
  # Intentionally NOT mocking `parallel` so command -v misses.
  mock_cmd "bats" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    _run_tests
  '
  assert_success
  assert_output --partial "serial"
  assert_output --partial "parallel not in PATH"

  run cat "${_log}"
  assert_success
  refute_output --partial "--jobs"
}

@test "main: dispatches --coverage to the coverage service" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --coverage
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial " coverage"
  assert_output --partial "COVERAGE=1"
}

# ════════════════════════════════════════════════════════════════════
# --bats-path / --filter single-path inner loop (#523)
# ════════════════════════════════════════════════════════════════════

@test "main --bats-path: dispatches a single spec to the ci service with BATS_FILE + BATS_ONLY=1" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --bats-path test/bats/unit/ci_spec.bats
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial " ci"
  assert_output --partial "BATS_FILE=test/bats/unit/ci_spec.bats"
  assert_output --partial "BATS_ONLY=1"
  refute_output --partial "COVERAGE=1"
}

@test "main --bats-path: accepts a directory" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --bats-path test/bats/unit/
  '
  assert_success
  run cat "${_log}"
  assert_output --partial "BATS_FILE=test/bats/unit/"
}

@test "main --bats-path: non-existent path dies with ci_bats_path_not_found" {
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --bats-path test/bats/unit/does_not_exist_spec.bats
  '
  assert_failure
  assert_output --partial "No such spec file or directory"
  refute_output --partial "docker should not be called"
}

@test "main --bats-path: test/bats/behavioural/ path dies with a clear hint" {
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --bats-path test/bats/behavioural/runtime_test_smoke_spec.bats
  '
  assert_failure
  assert_output --partial "ci-behavioural"
  refute_output --partial "docker should not be called"
}

@test "main --bats-path + --coverage is rejected (ci_bats_path_coverage)" {
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --bats-path test/bats/unit/ci_spec.bats --coverage
  '
  assert_failure
  assert_output --partial "cannot combine with --coverage"
}

@test "main --filter: dispatches with BATS_FILTER + BATS_ONLY=1 and no BATS_FILE" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --filter cap_add
  '
  assert_success
  run cat "${_log}"
  assert_output --partial "BATS_FILTER=cap_add"
  assert_output --partial "BATS_ONLY=1"
  assert_output --partial "BATS_FILE= "
}

@test "_run_bats_path: BATS_FILE runs bats on that path; BATS_FILTER appends -f" {
  local _log="${BATS_TEST_TMPDIR}/bats.log"
  mock_cmd "bats" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    BATS_FILE="test/bats/unit/ci_spec.bats" BATS_FILTER="shard" _run_bats_path
  '
  assert_success
  run cat "${_log}"
  assert_output --partial "test/bats/unit/ci_spec.bats"
  assert_output --partial "-f shard"
}

@test "_run_bats_path: filter-only runs bats across unit + integration" {
  local _log="${BATS_TEST_TMPDIR}/bats.log"
  mock_cmd "bats" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    BATS_FILE="" BATS_FILTER="cap_add" _run_bats_path
  '
  assert_success
  run cat "${_log}"
  assert_output --partial "test/bats/unit/"
  assert_output --partial "test/bats/integration/"
  assert_output --partial "-f cap_add"
}

# ════════════════════════════════════════════════════════════════════
# Dispatcher + per-tool driver structure (#650, ADR-00000011 #5)
#
# test.sh is the dispatcher; the per-tool execution lives in sourced
# driver libraries under script/test/drivers/. These guards pin the
# split so a future refactor can't silently re-inline a tool or drop a
# `source` line.
# ════════════════════════════════════════════════════════════════════

@test "drivers: bats.sh, shellcheck.sh and hadolint.sh driver files exist" {
  assert [ -f /source/script/test/drivers/bats.sh ]
  assert [ -f /source/script/test/drivers/shellcheck.sh ]
  # #650: hadolint joins the per-tool drivers so it runs in BOTH `just
  # test` and the CI hadolint job (local==CI single source).
  assert [ -f /source/script/test/drivers/hadolint.sh ]
}

@test "drivers: test.sh sources all per-tool drivers" {
  run grep -F 'source "${SCRIPT_DIR}/drivers/shellcheck.sh"' /source/script/test/test.sh
  assert_success
  run grep -F 'source "${SCRIPT_DIR}/drivers/hadolint.sh"' /source/script/test/test.sh
  assert_success
  run grep -F 'source "${SCRIPT_DIR}/drivers/bats.sh"' /source/script/test/test.sh
  assert_success
}

@test "drivers: the bats runners live in drivers/bats.sh, not test.sh" {
  # Each runner must be defined once (in the driver), and NOT re-inlined
  # back into the dispatcher.
  local _fn
  for _fn in _run_unit_tests _run_integration_tests _run_unit_shard \
             _run_bats_path _run_behavioural _run_coverage \
             _bats_args_with_label; do
    run grep -E "^${_fn}\(\) \{" /source/script/test/drivers/bats.sh
    assert_success
    run grep -E "^${_fn}\(\) \{" /source/script/test/test.sh
    assert_failure
  done
}

@test "drivers: _run_shellcheck lives in drivers/shellcheck.sh, not test.sh" {
  run grep -E '^_run_shellcheck\(\) \{' /source/script/test/drivers/shellcheck.sh
  assert_success
  run grep -E '^_run_shellcheck\(\) \{' /source/script/test/test.sh
  assert_failure
}

@test "drivers: _run_hadolint lives in drivers/hadolint.sh, not test.sh (#650)" {
  run grep -E '^_run_hadolint\(\) \{' /source/script/test/drivers/hadolint.sh
  assert_success
  run grep -E '^_run_hadolint\(\) \{' /source/script/test/test.sh
  assert_failure
}

@test "drivers: are sourced libraries (no top-level main invocation)" {
  run grep -E '^main "\$@"' /source/script/test/drivers/bats.sh
  assert_failure
  run grep -E '^main "\$@"' /source/script/test/drivers/shellcheck.sh
  assert_failure
  run grep -E '^main "\$@"' /source/script/test/drivers/hadolint.sh
  assert_failure
}

@test "drivers: _run_shellcheck also lints the driver files themselves" {
  local _log="${BATS_TEST_TMPDIR}/shellcheck.log"
  mock_cmd "shellcheck" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  run bash -c '
    source /source/script/test/test.sh
    _run_shellcheck
  '
  assert_success
  run cat "${_log}"
  assert_output --partial "script/test/drivers"
}

# ════════════════════════════════════════════════════════════════════
# _run_hadolint (#650, ADR-00000011)
#
# Single source of truth for the Dockerfiles + config the self-test
# lints. These guards pin the exact file list + config so the driver
# can't silently drift from the self-test.yaml hadolint job (which now
# runs THIS driver, not the hadolint-action).
# ════════════════════════════════════════════════════════════════════

@test "_run_hadolint: lints both template-owned Dockerfiles with the shared config" {
  local _log="${BATS_TEST_TMPDIR}/hadolint.log"
  mock_cmd "hadolint" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  run bash -c '
    source /source/script/test/test.sh
    _run_hadolint
  '
  assert_success

  assert [ -f "${_log}" ]
  run cat "${_log}"
  # Exactly the two Dockerfiles the CI hadolint job linted, with the
  # downstream/.hadolint.yaml config (single source of truth).
  assert_output --partial "--config /source/downstream/.hadolint.yaml"
  assert_output --partial "downstream/dockerfile/Dockerfile"
  assert_output --partial "dockerfile/Dockerfile.test-tools"
}

@test "_run_hadolint: invokes hadolint once per Dockerfile (no extra targets)" {
  local _log="${BATS_TEST_TMPDIR}/hadolint.log"
  mock_cmd "hadolint" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  run bash -c '
    source /source/script/test/test.sh
    _run_hadolint
  '
  assert_success
  # Two Dockerfiles in the list -> exactly two hadolint invocations.
  run grep -c -- '--config' "${_log}"
  assert_output '2'
}

@test "_run_hadolint: dies with a clear message when hadolint is absent" {
  # The host has no hadolint binary; the driver must fail loudly pointing
  # at the test-tools container path, not silently no-op.
  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    _run_hadolint
  '
  assert_failure
  assert_output --partial "hadolint not in PATH"
}

@test "_run_hadolint: exits non-zero when hadolint fails on any Dockerfile" {
  mock_cmd "hadolint" '
    for _arg in "$@"; do
      if [[ "${_arg}" == *"Dockerfile.test-tools" ]]; then
        printf "DL3000 fake violation\n" >&2
        exit 1
      fi
    done
    exit 0'
  run bash -c '
    set -e
    source /source/script/test/test.sh
    _run_hadolint
  '
  assert_failure
}
