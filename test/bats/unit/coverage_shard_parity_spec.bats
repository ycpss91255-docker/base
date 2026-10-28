#!/usr/bin/env bats
#
# coverage_shard_parity_spec.bats -- `just test coverage N/T` runs the
# shard CI runs as N/T (base#1410).
#
# why: a local coverage shard and CI's shard of the same name were two
# different runs. Three inputs decide a shard, and each differed:
#
#   1. The WEIGHTS. CI restores test/bats/.shard-weights from its cache
#      (compute-shards) and hands every shard the same blob; a checkout
#      has no such file (it is gitignored), so the local greedy-LPT
#      partition fell back to `@test` counts and put different specs in
#      shard N.
#   2. The weight KEY. A weight was recorded and looked up by spec
#      BASENAME, and five basenames name two specs each (a unit and an
#      integration spec): apk_mirror, init_existing_repo_signals,
#      init_installed_paths, test_tools_pins, upgrade. Neither spec of a
#      pair could carry its own runtime, and the union check could not
#      tell one of them from the other.
#   3. The JOB COUNT. A shard deals its specs into one kcov slice per job,
#      and the job count was `nproc` -- four on a hosted runner, 32 on a
#      workstation -- so the same specs ran in different slices.
#
# Measured with bats 1.13.0 (the test-tools image), and what the bats mock
# below reproduces: a junit <testsuite name> is the spec path RELATIVE TO
# THE FIRST TARGET'S DIRECTORY when the spec is under it, and the absolute
# path otherwise. `bats --recursive unit/ integration/` names
# unit/sub/x_spec.bats `sub/x_spec.bats` and integration/y_spec.bats
# `/source/test/bats/integration/y_spec.bats`; with file targets
# unit/sub/x, integration/y it names them `x_spec.bats` and the absolute
# path. So a junit name is not a spec identity on its own.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  create_mock_dir
  WF="/source/.github/workflows/self-test.yaml"
}

teardown() {
  cleanup_mock_dir
}

# ════════════════════════════════════════════════════════════════════
# Fixtures
# ════════════════════════════════════════════════════════════════════

# _make_parity_root
#   A throwaway repo root with both coverage pools, twenty specs, one of
#   them foldered, and one basename (apk_mirror_spec.bats) carried by a
#   unit AND an integration spec -- the shape the five real collisions
#   have. Echoes the root, which is always ${BATS_TEST_TMPDIR}/pool.
_make_parity_root() {
  local _root="${BATS_TEST_TMPDIR}/pool"
  mkdir -p "${_root}/test/bats/unit/sub" "${_root}/test/bats/integration"
  _put_spec() {
    local _f="${1}" _n="${2}" _i
    : > "${_f}"
    for (( _i = 0; _i < _n; _i++ )); do
      printf '@test "t%d" { true; }\n' "${_i}" >> "${_f}"
    done
  }
  _put_spec "${_root}/test/bats/unit/alpha_spec.bats" 1
  _put_spec "${_root}/test/bats/unit/beta_spec.bats" 3
  _put_spec "${_root}/test/bats/unit/sub/gamma_spec.bats" 5
  _put_spec "${_root}/test/bats/unit/apk_mirror_spec.bats" 2
  _put_spec "${_root}/test/bats/integration/apk_mirror_spec.bats" 4
  _put_spec "${_root}/test/bats/integration/delta_spec.bats" 7
  local _k
  for (( _k = 10; _k < 24; _k++ )); do
    _put_spec "${_root}/test/bats/unit/u${_k}_spec.bats" 1
  done
  printf '%s\n' "${_root}"
}

# _install_parity_mocks <kcov_log>
#   kcov: logs its argv, answers `--merge` with a merged report, otherwise
#   drops its own `--flag=value` options, leaves a report in its output
#   directory and runs the command it wraps. bats: writes the junit report
#   with the <testsuite name> rule measured above (header), one suite per
#   spec it walked, directory targets expanded the way --recursive does.
#   nproc reads 32 and `parallel` is present, so a job count derived from
#   the machine would be 32.
_install_parity_mocks() {
  local _log="${1}"
  mock_cmd "nproc" 'echo 32'
  mock_cmd "parallel" 'exit 0'
  mock_cmd "kcov" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    if [ "$1" = "--merge" ]; then
      mkdir -p "$2/kcov-merged" && printf "<coverage/>\n" > "$2/kcov-merged/cobertura.xml"
      exit 0
    fi
    while [ $# -gt 0 ]; do
      case "$1" in --*) shift ;; *) break ;; esac
    done
    mkdir -p "$1/kcov-merged" && printf "<coverage/>\n" > "$1/kcov-merged/cobertura.xml"
    shift
    exec "$@"'
  mock_cmd "bats" '
    _out=""
    _targets=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --output) _out="$2"; shift 2 ;;
        --report-formatter|--filter|--jobs) shift 2 ;;
        -*) shift ;;
        *) _targets+=("$1"); shift ;;
      esac
    done
    [ -n "${_out}" ] || exit 0
    _first="${_targets[0]%/}"
    if [ -d "${_first}" ]; then _base="${_first}"; else _base="$(dirname "${_first}")"; fi
    mkdir -p "${_out}"
    {
      printf "<testsuites>\n"
      for _t in "${_targets[@]}"; do
        if [ -d "${_t}" ]; then
          find "${_t%/}" -type f -name "*.bats" | LC_ALL=C sort
        else
          printf "%s\n" "${_t}"
        fi
      done | while IFS= read -r _f; do
        case "${_f}" in
          "${_base}"/*) _name="${_f#"${_base}"/}" ;;
          *) _name="${_f}" ;;
        esac
        printf "  <testsuite name=\"%s\" tests=\"1\" time=\"2.0\">\n  </testsuite>\n" "${_name}"
      done
      printf "</testsuites>\n"
    } > "${_out}/report.xml"
    exit 0'
}

# _driver_prelude
#   Source ONLY the bats driver, against the REPO_ROOT the caller's program
#   set first -- the throwaway root, spelled REPO_ROOT="${BATS_TEST_TMPDIR}/
#   pool" in each block so ci_spec's mounted-checkout guard reads it: test.sh
#   pins REPO_ROOT readonly at the mounted checkout, and these runners write
#   into ${REPO_ROOT}/coverage.
_driver_prelude() {
  printf '%s\n' \
    '_die() { printf "DIE %s\n" "$*" >&2; exit 1; }' \
    '_log_warn() { printf "WARN %s\n" "$*" >&2; }' \
    'unset SHARD_WEIGHTS_FILE COVERAGE_JOBS' \
    'source /source/script/test/drivers/bats.sh'
}

# _instrumented_runs <kcov_log>
#   The number of kcov processes that instrumented a slice (the merge is
#   not one).
_instrumented_runs() {
  grep -vc -- '^--merge' "${1}" || true
}

# ════════════════════════════════════════════════════════════════════
# 2. A weight belongs to a spec PATH, not a basename
# ════════════════════════════════════════════════════════════════════

# why: the five colliding basenames. Keyed by basename, the unit and the
# integration apk_mirror spec read the same line -- or, with the file
# written by path, neither line -- so the partition cannot place either by
# its own runtime.
@test "_spec_weight: two specs sharing a basename each read their own recorded seconds (base#1410)" {
  _make_parity_root >/dev/null
  run bash -c 'REPO_ROOT="${BATS_TEST_TMPDIR}/pool"
'"$(_driver_prelude)"'
printf "%s\n" "300 test/bats/unit/apk_mirror_spec.bats" \
  "7 test/bats/integration/apk_mirror_spec.bats" > "${BATS_TEST_TMPDIR}/w.tsv"
export SHARD_WEIGHTS_FILE="${BATS_TEST_TMPDIR}/w.tsv"
printf "unit=%s\n" "$(_spec_weight "${REPO_ROOT}/test/bats/unit/apk_mirror_spec.bats")"
printf "integration=%s\n" "$(_spec_weight "${REPO_ROOT}/test/bats/integration/apk_mirror_spec.bats")"'
  assert_success
  assert_line "unit=300"
  assert_line "integration=7"
}

# why: the writer half. The timings a run records ARE the next run's
# weights and the coverage-gate's run manifest, so they must name each
# spec by the path the partition and the inventory key on. The full run
# is handed two DIRECTORIES, so bats names the integration specs by
# absolute path and the foldered unit spec as `sub/...`.
@test "_run_coverage: a full run records every spec's timing under its repo-relative path (base#1410)" {
  local _log="${BATS_TEST_TMPDIR}/kcov.log"
  _make_parity_root >/dev/null
  _install_parity_mocks "${_log}"

  run bash -c 'REPO_ROOT="${BATS_TEST_TMPDIR}/pool"
'"$(_driver_prelude)"'
_run_coverage >/dev/null 2>&1 || exit 1
awk "{ print \$2 }" "${REPO_ROOT}/coverage/timings.tsv" | LC_ALL=C sort'
  assert_success
  local _want
  _want="$(cd "${BATS_TEST_TMPDIR}/pool" && find test/bats/unit test/bats/integration -type f -name '*.bats' | LC_ALL=C sort)"
  assert_output "${_want}"
}

# why: same as above for a shard, whose slices are handed FILES -- bats
# then names a spec under the first target's directory by its basename and
# every other one by absolute path.
@test "_run_coverage: a shard records each walked spec's timing under its repo-relative path (base#1410)" {
  local _log="${BATS_TEST_TMPDIR}/kcov.log"
  _make_parity_root >/dev/null
  _install_parity_mocks "${_log}"

  run bash -c 'REPO_ROOT="${BATS_TEST_TMPDIR}/pool"
'"$(_driver_prelude)"'
COVERAGE_JOBS=2 _run_coverage 1/2 >/dev/null 2>&1 || exit 1
echo WALKED
awk "{ print \$2 }" "${REPO_ROOT}/coverage/timings.tsv" | LC_ALL=C sort
echo PARTITION
_shard_unit_files 1/2 | sed "s|^${REPO_ROOT}/||" | LC_ALL=C sort'
  assert_success
  local _walked _partition
  _walked="$(sed -n '/^WALKED$/,/^PARTITION$/p' <<< "${output}" | sed '1d;$d')"
  _partition="$(sed -n '/^PARTITION$/,$p' <<< "${output}" | sed '1d')"
  assert [ -n "${_partition}" ]
  assert_equal "${_walked}" "${_partition}"
}

# why: the reader half of the manifest. With both apk_mirror specs keyed
# by one basename, a matrix that ran only the unit one read as complete;
# keyed by path, the integration one is the spec named as unrun.
@test "_coverage_union_gap: names the integration spec of a colliding basename that no shard ran (base#1410)" {
  run bash -c '
    source /source/script/test/test.sh
    _root="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${_root}/test/bats/unit" "${_root}/test/bats/integration"
    printf "@test \"a\" { :; }\n" > "${_root}/test/bats/unit/alpha_spec.bats"
    printf "@test \"a\" { :; }\n" > "${_root}/test/bats/unit/apk_mirror_spec.bats"
    printf "@test \"a\" { :; }\n" > "${_root}/test/bats/integration/apk_mirror_spec.bats"
    printf "%s\n" "1 test/bats/unit/alpha_spec.bats" \
      "1 test/bats/unit/apk_mirror_spec.bats" > "${BATS_TEST_TMPDIR}/m.tsv"
    _coverage_union_gap "${BATS_TEST_TMPDIR}/m.tsv" "${_root}"
  '
  assert_success
  assert_output "test/bats/integration/apk_mirror_spec.bats"
}

# ════════════════════════════════════════════════════════════════════
# 3. The job count per mode
# ════════════════════════════════════════════════════════════════════

# why: the control. The full suite is one serial kcov whatever the
# override says -- COVERAGE_JOBS is the SHARD slice count, and the full
# run's serial policy carries its own measurement (bats.sh).
@test "job count: a full coverage run stays one serial kcov under COVERAGE_JOBS (base#1410)" {
  local _log="${BATS_TEST_TMPDIR}/kcov.log"
  _make_parity_root >/dev/null
  _install_parity_mocks "${_log}"

  run bash -c 'REPO_ROOT="${BATS_TEST_TMPDIR}/pool"
'"$(_driver_prelude)"'
COVERAGE_JOBS=8 _run_coverage >/dev/null 2>&1'
  assert_success
  run _instrumented_runs "${_log}"
  assert_output "1"
}

# why: the hosted value is the default, so a workstation's shard N/T is
# dealt into the slices a GitHub-hosted runner (four cores) deals it into
# -- not into one slice per local core.
@test "job count: a shard defaults to the hosted runner's four slices, not nproc (base#1410)" {
  local _log="${BATS_TEST_TMPDIR}/kcov.log"
  _make_parity_root >/dev/null
  _install_parity_mocks "${_log}"

  run bash -c 'REPO_ROOT="${BATS_TEST_TMPDIR}/pool"
'"$(_driver_prelude)"'
_run_coverage 1/2 >/dev/null 2>&1'
  assert_success
  run _instrumented_runs "${_log}"
  assert_output "4"
}

# why: the override is the knob CI sets explicitly and a developer may
# set to reproduce a different runner.
@test "job count: COVERAGE_JOBS sets a shard's kcov slice count (base#1410)" {
  local _log="${BATS_TEST_TMPDIR}/kcov.log"
  _make_parity_root >/dev/null
  _install_parity_mocks "${_log}"

  run bash -c 'REPO_ROOT="${BATS_TEST_TMPDIR}/pool"
'"$(_driver_prelude)"'
COVERAGE_JOBS=2 _run_coverage 1/2 >/dev/null 2>&1'
  assert_success
  run _instrumented_runs "${_log}"
  assert_output "2"
}

# why: the host side. The container cannot see the host's intent unless
# the count crosses the compose boundary: `just test coverage N/T` says
# the hosted default out loud, and an ambient COVERAGE_JOBS (CI's) wins.
@test "job count: main --coverage-shard forwards COVERAGE_JOBS, the hosted default when unset (base#1410)" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'
  mock_cmd "nproc" 'echo 32'

  local _prog='
    source /source/script/test/test.sh
    _invalidate_coverage_head() { :; }
    _stamp_coverage_head() { :; }
    export PATH="'"${MOCK_DIR}"':${PATH}"
    main --coverage-shard 1/2
  '
  run env -u COVERAGE_JOBS -u SHARD_WEIGHTS_BLOB bash -c "${_prog}"
  assert_success
  run grep -o 'COVERAGE_JOBS=[^ ]*' "${_log}"
  assert_output "COVERAGE_JOBS=4"

  : > "${_log}"
  run env -u SHARD_WEIGHTS_BLOB COVERAGE_JOBS=2 bash -c "${_prog}"
  assert_success
  run grep -o 'COVERAGE_JOBS=[^ ]*' "${_log}"
  assert_output "COVERAGE_JOBS=2"
}

# why: CI must not lean on the runner's core count -- a self-hosted runner
# or a larger hosted SKU would silently re-slice every shard.
@test "self-test.yaml: the coverage shard step passes COVERAGE_JOBS and the weights blob to test.sh (base#1410)" {
  local _step
  _step="$(yaml_job_lines "${WF}" coverage \
    | awk '/- name: Run kcov coverage shard/ { on = 1; print; next }
           on && /^[[:space:]]*- name:/ { exit }
           on { print }')"
  assert [ -n "${_step}" ]
  run grep -E '^[[:space:]]+COVERAGE_JOBS: ' <<< "${_step}"
  assert_success
  run grep -F 'SHARD_WEIGHTS_BLOB: ${{ needs.compute-shards.outputs.weights }}' <<< "${_step}"
  assert_success
  run grep -F './script/test/test.sh --coverage-shard' <<< "${_step}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# 1. The local entry runs CI's partition
# ════════════════════════════════════════════════════════════════════

# why: ONE decoder. The blob compute-shards publishes is what reaches the
# container on both paths -- CI's (an ambient SHARD_WEIGHTS_BLOB) and the
# local one (`--shard-weights <file>`, encoded the way compute-shards
# encodes) -- and the in-container dispatch turns it into the weights the
# partition reads BEFORE it runs the shard. Same weights file, same shard,
# same spec list; and the list is not the `@test`-count fallback, or the
# comparison would hold with no weights reaching the run at all.
@test "parity: the local --shard-weights path and the compute-shards path run the same spec list (base#1410)" {
  # compute-shards encodes the restored file with `base64 -w0`; the CI
  # half below encodes the same way.
  run yaml_job_lines "${WF}" compute-shards
  assert_success
  assert_output --partial 'base64 -w0 < test/bats/.shard-weights'

  # A weights file over the real pool, keyed by repo-relative path: the
  # six lexically-first specs heavy, the rest light.
  local _wf="${BATS_TEST_TMPDIR}/weights" _i=0 _p
  : > "${_wf}"
  while IFS= read -r _p; do
    if (( _i < 6 )); then printf '5000 %s\n' "${_p}"; else printf '1 %s\n' "${_p}"; fi
    _i=$(( _i + 1 ))
  done < <(cd /source && find test/bats/unit test/bats/integration -type f -name '*.bats' | LC_ALL=C sort) >> "${_wf}"

  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'
  local _host='
    source /source/script/test/test.sh
    _invalidate_coverage_head() { :; }
    _stamp_coverage_head() { :; }
    export PATH="'"${MOCK_DIR}"':${PATH}"
    main --coverage-shard 2/3 "$@"
  '

  # Local: the weights file named on the command line.
  run env -u SHARD_WEIGHTS_BLOB bash -c "${_host}" _ --shard-weights "${_wf}"
  assert_success
  local _local_blob
  _local_blob="$(grep -o 'SHARD_WEIGHTS_BLOB=[^ ]*' "${_log}" || true)"
  assert [ -n "${_local_blob#SHARD_WEIGHTS_BLOB=}" ]

  # CI: the blob compute-shards published, in the shard's environment.
  : > "${_log}"
  run env SHARD_WEIGHTS_BLOB="$(base64 -w0 < "${_wf}")" bash -c "${_host}" _
  assert_success
  local _ci_blob
  _ci_blob="$(grep -o 'SHARD_WEIGHTS_BLOB=[^ ]*' "${_log}" || true)"
  assert_equal "${_local_blob}" "${_ci_blob}"

  # The container: the blob becomes the partition's weights.
  run env -u SHARD_WEIGHTS_FILE bash -c '
    source /source/script/test/test.sh
    _run_coverage() { _shard_unit_files "$1"; }
    _fix_permissions() { :; }
    COVERAGE=1 COVERAGE_SHARD=2/3 COVERAGE_PATH= COVERAGE_LOCAL_JOBS= \
      COVERAGE_JOBS=4 SHARD_WEIGHTS_BLOB="'"${_ci_blob#SHARD_WEIGHTS_BLOB=}"'" \
      BATS_ONLY=1 BATS_UNIT_SHARD= BATS_FRAGILE=0 BATS_INTEGRATION=0 \
      BATS_FILE= BATS_FILTER= LINT_ONLY=0 LINT_TOOL= PER_TEST_TIMEOUT= main --ci
  '
  assert_success
  local _ran
  _ran="$(grep -- '_spec\.bats$' <<< "${output}")"

  local _want _fallback
  _want="$(SHARD_WEIGHTS_FILE="${_wf}" bash -c '
    source /source/script/test/test.sh
    _shard_unit_files 2/3')"
  _fallback="$(SHARD_WEIGHTS_FILE="${BATS_TEST_TMPDIR}/no-such-weights" bash -c '
    source /source/script/test/test.sh
    _shard_unit_files 2/3')"
  assert [ "${_want}" != "${_fallback}" ]
  assert_equal "${_ran}" "${_want}"
}

# why: the fetch half of the local path. A job output cannot be
# downloaded after the run; an artifact can (`gh run download <run> -n
# shard-weights`), so compute-shards publishes the exact file it encoded.
@test "self-test.yaml: compute-shards uploads the weights it published as the shard-weights artifact (base#1410)" {
  run yaml_job_lines "${WF}" compute-shards
  assert_success
  assert_output --partial 'actions/upload-artifact'
  assert_output --regexp 'name: shard-weights($|[^-])'
}

# why: the `just` entry. `just test coverage N/T <weights>` is the
# operator's form of the local path above.
@test "justfile: coverage takes an optional weights file and forwards it as --shard-weights (base#1410)" {
  local _jf=/source/script/test/justfile.test
  run grep -E "^coverage shard='' weights='':$" "${_jf}"
  assert_success
  run grep -F -- '--shard-weights' "${_jf}"
  assert_success
  # The recipe comments stop saying the two shards differ.
  run grep -F 'different spec sets' "${_jf}"
  assert_failure
}
