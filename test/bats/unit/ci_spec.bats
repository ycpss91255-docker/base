#!/usr/bin/env bats
#
# Unit tests for script/test/test.sh helper functions.
# Only helpers that can be exercised without a full CI run are covered here.
#
# NOTE: these tests confine PATH to MOCK_DIR *after* sourcing test.sh so
# the mocked binaries resolve instead of the real ones.

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
  assert_output --partial "sync-doc-counts.sh"
  assert_output --partial "init.sh"
  assert_output --partial "upgrade.sh"
  assert_output --partial "config/shell/terminator/setup.sh"
  assert_output --partial "config/shell/tmux/setup.sh"
  # the base namespace scripts (completions.sh) are shellchecked too.
  assert_output --partial "dist/script/base"
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

  # Every .sh under dist/script/docker/wrapper/ and lib/ must appear.
  for _f in /source/dist/script/docker/wrapper/*.sh /source/dist/script/docker/lib/*.sh; do
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
# Regression guards: default `test.sh` (no flag) must hit the alpine
# `ci` service; `--coverage` must hit the `coverage` service (which now
# shares the same test-tools image). Mock `docker` so the test captures
# the chosen service name + COVERAGE env without actually running
# compose.
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
# --coverage-shard: sharded kcov matrix (ADR-00000008, weight-balanced)
#
# Coverage is the primary unit gate. _shard_unit_files is the partition
# primitive: greedy weight-balanced bin-packing by per-spec @test count
# (heaviest-first into the lightest shard) so the slowest shard's load
# approaches total/N. _run_coverage <n>/<total> kcov's that slice (+
# integration on the last shard). main --coverage-shard plumbs
# COVERAGE_SHARD into the coverage service.
# ════════════════════════════════════════════════════════════════════

@test "_shard_unit_files: a single shard returns real unit spec paths (#615)" {
  run bash -c '
    source /source/script/test/test.sh
    _shard_unit_files 1/4
  '
  assert_success
  assert_output --partial "test/bats/unit/"
  assert_output --partial "_spec.bats"
}

@test "_shard_unit_files: partition is exhaustive + disjoint across all shards of T (#615, #724)" {
  # Union of every shard of 4 must equal the full sorted spec list (unit +
  # integration, folded into one pool), with no file in two shards (the
  # invariant the coverage-gate merge relies on: every spec runs exactly
  # once across the matrix).
  run bash -c '
    source /source/script/test/test.sh
    all=$(find "${REPO_ROOT}/test/bats/unit" "${REPO_ROOT}/test/bats/integration" \
            -name "*_spec.bats" | sort)
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

@test "_shard_unit_files: greedy weight-balance keeps no shard wildly above the @test average (#677)" {
  # The round-robin floor dumped the heaviest specs into one shard (~2x the
  # others). The greedy bin-packing must keep every shard's @test load
  # within a sane factor of the average (total/4); assert the heaviest
  # shard is at most ~1.5x the average so a single big spec can't pin it.
  run bash -c '
    source /source/script/test/test.sh
    total=$(grep -rhcE "^@test" "${REPO_ROOT}"/test/bats/unit/ | paste -sd+ | bc)
    avg=$(( total / 4 ))
    max=0
    for s in 1 2 3 4; do
      load=0
      while IFS= read -r f; do
        [[ -n "${f}" ]] || continue
        c=$(grep -cE "^@test" "${f}")
        load=$(( load + c ))
      done < <(_shard_unit_files "${s}/4")
      echo "shard ${s}/4 load=${load}"
      (( load > max )) && max=${load}
    done
    echo "avg=${avg} max=${max}"
    # heaviest shard must be < 1.5 * avg (round-robin floor was ~2x)
    (( max * 2 < avg * 3 )) || { echo "IMBALANCED"; exit 1; }
    echo BALANCED
  '
  assert_success
  assert_output --partial "BALANCED"
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

# ════════════════════════════════════════════════════════════════════
# _spec_weight: time-weighted shard partition (ADR-00000008 amend)
#
# The shard partition (greedy LPT in _shard_unit_files) weights each spec
# by RUNTIME, not `@test` count: equal-count specs of unequal duration
# imbalance the shards otherwise. Weight source is a timings file (seconds
# per spec basename) populated automatically from prior CI runs; a spec
# absent from it (new spec / no data yet) falls back to its `@test` count.
# ════════════════════════════════════════════════════════════════════

@test "_spec_weight: returns the recorded seconds from SHARD_WEIGHTS_FILE (#724)" {
  run bash -c '
    source /source/script/test/test.sh
    wf="${BATS_TEST_TMPDIR}/w.tsv"
    printf "%s\n" "12 foo_spec.bats" "3 bar_spec.bats" > "${wf}"
    SHARD_WEIGHTS_FILE="${wf}" _spec_weight "/any/path/foo_spec.bats"
  '
  assert_success
  assert_output "12"
}

@test "_spec_weight: falls back to @test count when the spec has no recorded time (#724)" {
  run bash -c '
    source /source/script/test/test.sh
    wf="${BATS_TEST_TMPDIR}/w.tsv"
    printf "%s\n" "12 other_spec.bats" > "${wf}"
    spec="${BATS_TEST_TMPDIR}/new_spec.bats"
    printf "@test \"a\" {\n:\n}\n@test \"b\" {\n:\n}\n" > "${spec}"
    SHARD_WEIGHTS_FILE="${wf}" _spec_weight "${spec}"
  '
  assert_success
  assert_output "2"
}

@test "_spec_weight: falls back to @test count when no SHARD_WEIGHTS_FILE is set (#724)" {
  run bash -c '
    source /source/script/test/test.sh
    spec="${BATS_TEST_TMPDIR}/c_spec.bats"
    printf "@test \"a\" {\n:\n}\n@test \"b\" {\n:\n}\n@test \"c\" {\n:\n}\n" > "${spec}"
    unset SHARD_WEIGHTS_FILE
    _spec_weight "${spec}"
  '
  assert_success
  assert_output "3"
}

@test "_spec_weight: reads the default repo weights file when SHARD_WEIGHTS_FILE is unset (#733)" {
  # CI restores the cached weights to ${REPO_ROOT}/test/bats/.shard-weights
  # (the mounted /source tree), so the in-container coverage run picks them up
  # WITHOUT any -e plumbing. Source only the driver so REPO_ROOT (readonly in
  # test.sh) can point at a tmpdir holding a controlled default weights file.
  run bash -c '
    REPO_ROOT="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${REPO_ROOT}/test/bats"
    printf "%s\n" "42 foo_spec.bats" > "${REPO_ROOT}/test/bats/.shard-weights"
    source /source/script/test/drivers/bats.sh
    unset SHARD_WEIGHTS_FILE
    _spec_weight "/any/path/foo_spec.bats"
  '
  assert_success
  assert_output "42"
}

@test "_shard_unit_files: partitions by recorded time when SHARD_WEIGHTS_FILE is set (#724)" {
  # Give ONE real spec a dominating runtime and everything else ~0; with 2
  # shards, greedy-LPT-by-time must isolate the heavy spec on its own shard.
  # Count-based weighting (which ignores SHARD_WEIGHTS_FILE) would not.
  run bash -c '
    source /source/script/test/test.sh
    specs=$(find "${REPO_ROOT}/test/bats/unit" -name "*_spec.bats" | sort)
    heavy=$(printf "%s\n" "${specs}" | head -1 | xargs -n1 basename)
    wf="${BATS_TEST_TMPDIR}/w.tsv"
    : > "${wf}"
    while IFS= read -r p; do
      [[ -n "${p}" ]] || continue
      b=$(basename "${p}")
      if [[ "${b}" == "${heavy}" ]]; then echo "100000 ${b}"; else echo "1 ${b}"; fi
    done <<< "${specs}" >> "${wf}"
    s1=$(SHARD_WEIGHTS_FILE="${wf}" _shard_unit_files 1/2 | grep -c .)
    s2=$(SHARD_WEIGHTS_FILE="${wf}" _shard_unit_files 2/2 | grep -c .)
    echo "s1=${s1} s2=${s2}"
    { [[ "${s1}" -eq 1 ]] || [[ "${s2}" -eq 1 ]]; } || { echo FAIL; exit 1; }
    echo OK
  '
  assert_success
  assert_output --partial "OK"
}

# ════════════════════════════════════════════════════════════════════
# _junit_to_timings: capture real per-spec-file kcov-mode runtime
#
# A coverage shard runs `kcov ... bats --report-formatter junit`, which
# emits one <testsuite name=<spec> time=<sec>> per FILE. _junit_to_timings
# turns that report into the `<seconds> <basename>` lines _spec_weight
# reads, so the NEXT run's partition weights by real runtime instead of
# the @test-count fallback. Seconds round to the nearest whole, floored at
# 1 so a sub-second spec still carries a non-zero LPT weight.
# ════════════════════════════════════════════════════════════════════

@test "_junit_to_timings: emits <seconds> <basename> per testsuite, rounded and floored at 1 (#733)" {
  run bash -c '
    source /source/script/test/test.sh
    xml="${BATS_TEST_TMPDIR}/report.xml"
    cat > "${xml}" <<EOF
<?xml version="1.0"?>
<testsuites time="3.6">
  <testsuite name="test/bats/unit/foo_spec.bats" tests="2" time="2.4">
    <testcase classname="x" name="a" time="1.2"/>
  </testsuite>
  <testsuite name="bar_spec.bats" tests="1" time="0.3">
    <testcase classname="x" name="b" time="0.3"/>
  </testsuite>
</testsuites>
EOF
    _junit_to_timings "${xml}"
  '
  assert_success
  # 2.4 -> 2; basename strips the path prefix
  assert_line "2 foo_spec.bats"
  # 0.3 rounds to 0 then floors to 1 (non-zero LPT weight)
  assert_line "1 bar_spec.bats"
}

@test "_junit_to_timings: ignores the <testsuites> root and a missing file is a no-op (#733)" {
  run bash -c '
    source /source/script/test/test.sh
    _junit_to_timings "/no/such/report.xml"
    echo "rc=$?"
  '
  assert_success
  assert_output "rc=0"
}

@test "_run_coverage: writes coverage/timings.tsv from the bats junit report (#733)" {
  # A coverage run records each spec FILE's real kcov-mode runtime so the
  # NEXT partition is time-balanced. Mock kcov to simulate the wrapped
  # `bats --report-formatter junit --output DIR` by dropping a report at the
  # requested dir; assert _run_coverage converts it into coverage/timings.tsv.
  # REPO_ROOT is redirected to a tmpdir so the real mounted /source/coverage
  # is never touched.
  run bash -c '
    # Source only the bats driver (test.sh makes REPO_ROOT readonly, which we
    # must redirect to a tmpdir here); the driver is a pure function library.
    REPO_ROOT="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${REPO_ROOT}/coverage" \
             "${REPO_ROOT}/test/bats/unit" "${REPO_ROOT}/test/bats/integration"
    source /source/script/test/drivers/bats.sh
    mkdir -p "${BATS_TEST_TMPDIR}/bin"
    cat > "${BATS_TEST_TMPDIR}/bin/kcov" <<"SH"
#!/usr/bin/env bash
outdir=""; prev=""
for a in "$@"; do [[ "${prev}" == "--output" ]] && outdir="${a}"; prev="${a}"; done
mkdir -p "${outdir}"
printf "%s\n" "<testsuites><testsuite name=\"mock_spec.bats\" time=\"4.0\"></testsuite></testsuites>" \
  > "${outdir}/report.xml"
exit 0
SH
    chmod +x "${BATS_TEST_TMPDIR}/bin/kcov"
    PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" _run_coverage >/dev/null 2>&1
    cat "${REPO_ROOT}/coverage/timings.tsv"
  '
  assert_success
  assert_output "4 mock_spec.bats"
}

@test "_shard_unit_files: integration specs are partitioned into the pool, not pinned to one shard (#724)" {
  # Previously ALL integration specs ran on the last shard (count-era). They
  # are now folded into the time-balanced pool so an integration spec lands
  # on exactly one shard (still kcov'd once across the matrix) but spread by
  # time.
  run bash -c '
    source /source/script/test/test.sh
    union=$( { _shard_unit_files 1/3; _shard_unit_files 2/3; _shard_unit_files 3/3; } )
    printf "%s\n" "${union}" | grep -q "/test/bats/integration/.*_spec.bats" \
      || { echo MISSING-INTEGRATION; exit 1; }
    echo OK
  '
  assert_success
  assert_output --partial "OK"
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

@test "_run_coverage: shard targets are individual spec files, never the whole integration dir (#724)" {
  # This supersedes the old last-shard rule: integration specs are folded
  # into the time-balanced pool, so a shard kcov's individual spec FILES
  # (unit + integration mixed) and the whole integration DIR is never a
  # target (which would re-cover all integration on one shard).
  mock_cmd "kcov" 'exit 0'
  mock_cmd "bats" 'exit 0'

  run bash -c '
    source /source/script/test/test.sh
    _run_coverage 2/2
  '
  assert_success
  refute_output --partial "integration suite (last shard)"
  refute_output --regexp 'cov-shard:.*/test/bats/integration/$'
  assert_output --partial "_spec.bats"
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

@test "main --ci with COVERAGE=1 skips the lint phase (lint is a separate matrix concern) (#615)" {
  # The coverage shards are a kcov-only concern; lint is measured by the
  # dedicated shellcheck/hadolint jobs. Running the lint phase once per
  # coverage shard would be wasted work, so COVERAGE=1 deliberately skips
  # it even though the shared test-tools image now ships both linters.
  # Assert the --ci COVERAGE path does NOT shell out to either.
  local _sc_log="${BATS_TEST_TMPDIR}/sc.log"
  local _hd_log="${BATS_TEST_TMPDIR}/hd.log"
  mock_cmd "shellcheck" 'printf "called\n" >> "'"${_sc_log}"'"; exit 0'
  mock_cmd "hadolint" 'printf "called\n" >> "'"${_hd_log}"'"; exit 0'
  mock_cmd "kcov" 'exit 0'
  mock_cmd "bats" 'exit 0'

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
# --bats-fragile: the kcov-fragile unit specs run in plain mode
#
# The coverage matrix is the primary unit gate but SKIPS the kcov-fragile
# tests (guarded by `[ "${COVERAGE:-0}" = 1 ] && skip`). The bats-fragile
# job runs exactly those spec files in plain mode so no unit test goes
# unrun. _fragile_unit_files computes the set at runtime (grep for the skip
# guard) so it self-maintains; these guards pin the contract.
# ════════════════════════════════════════════════════════════════════

@test "_fragile_unit_files: returns exactly the spec files with a kcov-skip guard (#677)" {
  # The runtime-computed set must equal an independent grep for the
  # line-anchored skip guard — a NEW fragile-skip in a 10th file is picked
  # up automatically. The anchor (leading whitespace + literal bracket)
  # excludes comments that merely mention the guard.
  run bash -c '
    source /source/script/test/test.sh
    want=$(grep -rlE "${_FRAGILE_GUARD_RE}" "${REPO_ROOT}/test/bats/unit" | sort)
    got=$(_fragile_unit_files | sort)
    [[ "${want}" == "${got}" ]] || { echo "MISMATCH"; printf "want:\n%s\ngot:\n%s\n" "${want}" "${got}"; exit 1; }
    echo OK
  '
  assert_success
  assert_output --partial "OK"
}

@test "_fragile_unit_files: every kcov-skipped file is in the fragile set (no unit test goes unrun) (#677)" {
  # Coverage skips a test only in files in the fragile set; this asserts
  # the inverse direction too — there is NO file containing a kcov-skip
  # guard that is missing from _fragile_unit_files. Together with the
  # coverage partition this proves every unit test runs SOMEWHERE.
  run bash -c '
    source /source/script/test/test.sh
    fragile=$(_fragile_unit_files | sort)
    while IFS= read -r f; do
      [[ -n "${f}" ]] || continue
      printf "%s\n" "${fragile}" | grep -qxF "${f}" \
        || { echo "MISSING: ${f}"; exit 1; }
    done < <(grep -rlE "${_FRAGILE_GUARD_RE}" "${REPO_ROOT}/test/bats/unit" | sort)
    echo OK
  '
  assert_success
  assert_output --partial "OK"
}

@test "_run_bats_fragile: runs bats over only the fragile spec files, not the whole unit tree (#677)" {
  local _log="${BATS_TEST_TMPDIR}/bats.log"
  mock_cmd "bats" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'

  run bash -c '
    source /source/script/test/test.sh
    _run_bats_fragile
  '
  assert_success
  assert_output --partial "kcov-fragile"

  run cat "${_log}"
  assert_success
  assert_output --partial "_spec.bats"
  # The whole-unit-dir target must NOT be passed (that is coverage's job).
  refute_output --partial "test/bats/unit/ "
}

@test "_run_bats_fragile: does NOT set COVERAGE=1 so the kcov-skip guards fall through (#677)" {
  # The fragile tests are precisely the ones coverage skips; running them
  # here in PLAIN mode (COVERAGE != 1) is the whole point. Run with
  # COVERAGE explicitly unset in the child shell and assert the runner
  # never turns it into 1.
  local _log="${BATS_TEST_TMPDIR}/bats.log"
  mock_cmd "bats" '
    printf "COVERAGE=[%s]\n" "${COVERAGE:-unset}" >> "'"${_log}"'"
    exit 0'

  run bash -c '
    unset COVERAGE
    source /source/script/test/test.sh
    _run_bats_fragile
  '
  assert_success
  run cat "${_log}"
  assert_output --partial "COVERAGE=[unset]"
  refute_output --partial "COVERAGE=[1]"
}

@test "main --bats-fragile: routes to the ci service with BATS_FRAGILE=1 + BATS_ONLY=1, no COVERAGE (#677)" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --bats-fragile
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial " ci"
  assert_output --partial "BATS_FRAGILE=1"
  assert_output --partial "BATS_ONLY=1"
  assert_output --partial "COVERAGE=0"
  refute_output --partial "COVERAGE=1"
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

@test "main --bats-path: test/bats/system/ path dies with a clear hint" {
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --bats-path test/bats/system/runtime_test_smoke_spec.bats
  '
  assert_failure
  assert_output --partial "ci-system"
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
             _run_bats_fragile _run_bats_path _run_system _run_coverage \
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
  # dist/.hadolint.yaml config (single source of truth).
  assert_output --partial "--config /source/dist/.hadolint.yaml"
  assert_output --partial "dist/dockerfile/Dockerfile"
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
# _system_setup prerequisite guards (drivers/bats.sh)
# ════════════════════════════════════════════════════════════════════
#
# _system_setup fails fast with two distinct _die calls when the
# system prerequisites are absent. The ci (non-system) test
# container has no docker.sock, so the socket guard is exercised against
# the real condition; the docker-CLI guard needs the socket to pass
# first, so a transient unix socket is created at the literal path the
# function probes.

@test "_system_setup: dies ci_no_docker_socket when /var/run/docker.sock is absent (#692)" {
  if [[ -S /var/run/docker.sock ]]; then
    skip "docker.sock present in this environment; socket guard not reachable"
  fi
  run bash -c '
    set -e
    source /source/script/test/test.sh
    _system_setup
  '
  assert_failure
  assert_output --partial "requires /var/run/docker.sock"
}

@test "_system_setup: dies ci_no_docker_cli when docker is not on PATH (#692)" {
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
    _system_setup
  '
  rm -f /var/run/docker.sock
  assert_failure
  assert_output --partial "requires docker CLI"
}
