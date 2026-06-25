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
  # the base namespace scripts (completions.sh) are shellchecked too.
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
# Regression guards fordefault `test.sh` (no flag) must hit the
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
# --coverage-shard: sharded kcov matrix (ADR-00000008)
#
# The coverage matrix mirrors bats-unit's shards. _shard_unit_files is
# the shared round-robin primitive so coverage shard k covers the same
# unit slice the unit-test matrix runs; _run_coverage <n>/<total> kcov's
# that slice (+ integration on the last shard). main --coverage-shard
# plumbs COVERAGE_SHARD into the coverage service.
# ════════════════════════════════════════════════════════════════════

@test "_shard_unit_files: same shard index selects the same slice as _run_unit_shard's partition (#615)" {
  # The coverage matrix must mirror the unit matrix exactly: both go
  # through _shard_unit_files, so a given index yields one identical slice.
  run bash -c '
    source /source/script/test/test.sh
    _shard_unit_files 1/4
  '
  assert_success
  # Round-robin NR%4==0 over the sorted spec list: first match is the 4th
  # spec file; assert it returns at least one real unit spec path.
  assert_output --partial "test/bats/unit/"
  assert_output --partial "_spec.bats"
}

@test "_shard_unit_files: partition is exhaustive + disjoint across all shards of T (#615)" {
  # Union of every shard of 4 must equal the full sorted unit spec list,
  # with no file in two shards (round-robin invariant the merge relies on:
  # every unit slice runs exactly once across the matrix).
  run bash -c '
    source /source/script/test/test.sh
    all=$(find "${REPO_ROOT}/test/bats/unit" -maxdepth 1 -name "*_spec.bats" | sort)
    union=$( { _shard_unit_files 1/4; _shard_unit_files 2/4; \
               _shard_unit_files 3/4; _shard_unit_files 4/4; } | sort )
    [[ "${all}" == "${union}" ]] || { echo "MISMATCH"; exit 1; }
    # disjoint: total line count equals the full list count (no dupes)
    n_all=$(printf "%s\n" "${all}" | wc -l)
    n_union=$( { _shard_unit_files 1/4; _shard_unit_files 2/4; \
                 _shard_unit_files 3/4; _shard_unit_files 4/4; } | wc -l)
    [[ "${n_all}" -eq "${n_union}" ]] || { echo "DUPES"; exit 1; }
    echo OK
  '
  assert_success
  assert_output --partial "OK"
}

@test "_shard_unit_files: rejects an out-of-range shard spec (#615, #692)" {
  run bash -c '
    set -e
    source /source/script/test/test.sh
    _shard_unit_files 5/4
  '
  assert_failure
  assert_output --partial "Need 1<=n<=total"
}

@test "_shard_unit_files: rejects a no-slash shard spec (#692)" {
  run bash -c '
    set -e
    source /source/script/test/test.sh
    _shard_unit_files abc
  '
  assert_failure
  assert_output --partial "Expected <n>/<total>"
}

@test "_shard_unit_files: rejects a non-numeric shard spec (#692)" {
  run bash -c '
    set -e
    source /source/script/test/test.sh
    _shard_unit_files a/b
  '
  assert_failure
  assert_output --partial "Need 1<=n<=total"
}

@test "_shard_unit_files: dies ci_empty_shard when a valid shard matches no files (#692)" {
  # A round-robin slice can be empty when total greatly exceeds the spec
  # count: shard 100/100 selects NR%100==99, which no spec index hits.
  run bash -c '
    set -e
    source /source/script/test/test.sh
    _shard_unit_files 100/100
  '
  assert_failure
  assert_output --partial "No spec files matched"
}

@test "_run_coverage: shard N/T kcov's only that unit slice, not the whole tree (#615)" {
  # No PATH override: _run_coverage shells out to find/sort/awk via
  # _shard_unit_files. mock_cmd already PREPENDS MOCK_DIR to PATH, so the
  # kcov + bats mocks win while the real coreutils stay reachable.
  local _log="${BATS_TEST_TMPDIR}/kcov.log"
  mock_cmd "kcov" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "bats" 'exit 0'

  run bash -c '
    source /source/script/test/test.sh
    _run_coverage 1/4
  '
  assert_success
  assert_output --partial "shard 1/4"

  run cat "${_log}"
  assert_success
  # kcov wraps bats over specific shard spec files, not the whole unit dir.
  assert_output --partial "_spec.bats"
  refute_output --partial "test/bats/unit/ bats"
}

@test "_run_coverage: last shard also kcov's the integration suite (#615)" {
  local _log="${BATS_TEST_TMPDIR}/kcov.log"
  mock_cmd "kcov" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "bats" 'exit 0'

  run bash -c '
    source /source/script/test/test.sh
    _run_coverage 4/4
  '
  assert_success
  assert_output --partial "integration suite (last shard)"

  run cat "${_log}"
  assert_success
  assert_output --partial "test/bats/integration/"
}

@test "_run_coverage: non-last shard does NOT kcov the integration suite (#615)" {
  local _log="${BATS_TEST_TMPDIR}/kcov.log"
  mock_cmd "kcov" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "bats" 'exit 0'

  run bash -c '
    source /source/script/test/test.sh
    _run_coverage 1/4
  '
  assert_success

  run cat "${_log}"
  assert_success
  refute_output --partial "test/bats/integration/"
}

@test "_run_coverage: no argument keeps the full-suite path (unit + integration) (#615)" {
  local _log="${BATS_TEST_TMPDIR}/kcov.log"
  mock_cmd "kcov" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "bats" 'exit 0'

  run bash -c '
    source /source/script/test/test.sh
    _run_coverage
  '
  assert_success
  assert_output --partial "full suite"

  run cat "${_log}"
  assert_success
  assert_output --partial "test/bats/unit/"
  assert_output --partial "test/bats/integration/"
}

@test "main --coverage-shard: routes to the coverage service with COVERAGE_SHARD set (#615)" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --coverage-shard 2/4
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial " coverage"
  assert_output --partial "COVERAGE=1"
  assert_output --partial "COVERAGE_SHARD=2/4"
}

@test "main --ci with COVERAGE=1 skips the lint phase (kcov image has no hadolint) (#615)" {
  # The coverage path runs in the kcov/kcov debian image, which bakes in
  # neither shellcheck nor hadolint. Running the lint phase there would
  # fail every coverage shard at _run_hadolint. Assert the --ci COVERAGE
  # path does NOT shell out to either linter.
  local _sc_log="${BATS_TEST_TMPDIR}/sc.log"
  local _hd_log="${BATS_TEST_TMPDIR}/hd.log"
  mock_cmd "shellcheck" 'printf "called\n" >> "'"${_sc_log}"'"; exit 0'
  mock_cmd "hadolint" 'printf "called\n" >> "'"${_hd_log}"'"; exit 0'
  mock_cmd "kcov" 'exit 0'
  mock_cmd "bats" 'exit 0'
  # bats already present so _install_deps short-circuits (no apt-get).

  run bash -c '
    source /source/script/test/test.sh
    COVERAGE=1 COVERAGE_SHARD=1/4 main --ci
  '
  assert_success
  assert [ ! -f "${_sc_log}" ]
  assert [ ! -f "${_hd_log}" ]
}

@test "main --coverage-shard + --bats-path is rejected (coverage mode guard) (#615)" {
  # --coverage-shard sets coverage mode, which the single-path guard
  # rejects (single-path is the fast no-kcov loop).
  run bash -c '
    source /source/script/test/test.sh
    main --coverage-shard 1/4 --bats-path test/bats/unit/ci_spec.bats
  '
  assert_failure
  assert_output --partial "cannot combine with --coverage"
}

# ════════════════════════════════════════════════════════════════════
# --bats-path / --filter single-path inner loop
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

@test "main: unknown option dies with ci_unknown_option (#692)" {
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --bogus
  '
  assert_failure
  assert_output --partial "Unknown option"
  refute_output --partial "docker should not be called"
}

@test "main: --hadolint without --lint dies (narrowing flag, not standalone) (#692)" {
  # `--hadolint` narrows --lint; standalone is the easy-to-make typo for
  # --hadolint-only. It must fail loudly, not silently no-op.
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --hadolint
  '
  assert_failure
  assert_output --partial "narrows --lint"
  refute_output --partial "docker should not be called"
}

@test "main --ci: unknown LINT_TOOL dies with ci_unknown_lint_tool (#692)" {
  run bash -c '
    source /source/script/test/test.sh
    LINT_ONLY=1 LINT_TOOL=bogus main --ci
  '
  assert_failure
  assert_output --partial "Unknown LINT_TOOL"
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
# Dispatcher + per-tool driver structure (ADR-00000011 #5)
#
# test.sh is the dispatcher; the per-tool execution lives in sourced
# driver libraries under script/test/drivers/. These guards pin the
# split so a future refactor can't silently re-inline a tool or drop a
# `source` line.
# ════════════════════════════════════════════════════════════════════

@test "drivers: bats.sh, shellcheck.sh and hadolint.sh driver files exist" {
  assert [ -f /source/script/test/drivers/bats.sh ]
  assert [ -f /source/script/test/drivers/shellcheck.sh ]
  # hadolint joins the per-tool drivers so it runs in BOTH `just
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
# _run_hadolint (ADR-00000011)
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

# ════════════════════════════════════════════════════════════════════
# _behavioural_setup prerequisite guards (drivers/bats.sh)
# ════════════════════════════════════════════════════════════════════
#
# _behavioural_setup fails fast with two distinct _die calls when the
# behavioural prerequisites are absent. The ci (non-behavioural) test
# container has no docker.sock, so the socket guard is exercised against
# the real condition; the docker-CLI guard needs the socket to pass
# first, so a transient unix socket is created at the literal path the
# function probes.

@test "_behavioural_setup: dies ci_no_docker_socket when /var/run/docker.sock is absent (#692)" {
  if [[ -S /var/run/docker.sock ]]; then
    skip "docker.sock present in this environment; socket guard not reachable"
  fi
  run bash -c '
    set -e
    source /source/script/test/test.sh
    _behavioural_setup
  '
  assert_failure
  assert_output --partial "requires /var/run/docker.sock"
}

@test "_behavioural_setup: dies ci_no_docker_cli when docker is not on PATH (#692)" {
  if [[ -S /var/run/docker.sock ]]; then
    skip "real docker.sock present; would proceed past the CLI guard to buildx"
  fi
  # Create a transient unix socket at the probed path so the socket guard
  # passes, then run with a PATH that omits docker to hit the CLI guard.
  perl -e 'use IO::Socket::UNIX; unlink "/var/run/docker.sock"; IO::Socket::UNIX->new(Type=>SOCK_STREAM, Local=>"/var/run/docker.sock", Listen=>1) or die $!;'
  local _clean="${BATS_TEST_TMPDIR}/nodocker"
  mkdir -p "${_clean}"
  local _cmd _src
  for _cmd in bash sh env cat printf date grep sed find sort awk mktemp \
              dirname basename id tr head tail cut wc rm mkdir ln cp test pwd; do
    _src="$(command -v "${_cmd}" 2>/dev/null)" && ln -sf "${_src}" "${_clean}/${_cmd}"
  done
  run env PATH="${_clean}" bash -c '
    set -e
    source /source/script/test/test.sh
    _behavioural_setup
  '
  rm -f /var/run/docker.sock
  assert_failure
  assert_output --partial "requires docker CLI"
}
