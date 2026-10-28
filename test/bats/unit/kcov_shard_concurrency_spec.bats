#!/usr/bin/env bats
#
# kcov_shard_concurrency_spec.bats -- a concurrent coverage shard measures
# what a serial run measures, and prints no trace of its own.
#
# why: A coverage shard runs its specs concurrently, and the instrument
# must not notice. kcov's bash engine reads coverage out of the xtrace
# stream (PS4 `kcov@${BASH_SOURCE}@${LINENO}@`), and every bash below one
# kcov traces into ONE pipe. musl bash writes a record over 1024 B as two
# writes (the body, then a lone newline), and no write over PIPE_BUF is
# atomic, so two traced processes writing at once interleave their
# records. kcov then credits only the first marker on a line -- the rest of
# the line's coverage is lost with every test green -- and echoes every
# marker-less line to its own stderr, which on CI is the step's output
# (base#1414). This spec is behavioural on purpose: it runs the REAL kcov
# through the driver's shard entry over a fixture tree, so it catches the
# defect however a future test builds its value, rather than scanning spec
# text for one way of building it. It replaces kcov_trace_volume_spec.bats.

bats_require_minimum_version 1.5.0

# _cov_lines <cobertura.xml>
#   Print the covered set, one `<basename>:<line>` per executed line, for
#   the fixture lib scripts (w<N>.sh) only, sorted. The basename, because
#   kcov names a file relative to its source root, which is lib/ in the
#   serial reference and the tree root in the shard. kcov writes one <class> per
#   source file and one <line number= hits=> per executable line.
_cov_lines() {
  awk '
    /<class / {
      _f = $0
      sub(/.*filename="/, "", _f)
      sub(/".*/, "", _f)
    }
    /<line / && _f ~ /(^|\/)w[0-9]+\.sh$/ {
      _n = $0; sub(/.*number="/, "", _n); sub(/".*/, "", _n)
      _h = $0; sub(/.*hits="/, "", _h);   sub(/".*/, "", _h)
      if (_h + 0 > 0) {
        _b = _f; sub(/.*\//, "", _b)
        print _b ":" _n
      }
    }
  ' "${1}" | LC_ALL=C sort -u
}

# _report <coverage-dir>
#   The report the coverage gate's collector reads for one shard: the
#   kcov-merged cobertura.xml when the run has one, else the single per-run
#   report (self-test.yaml's coverage-gate job applies the same rule).
_report() {
  local _dir="${1}" _xml
  if [[ -f "${_dir}/kcov-merged/cobertura.xml" ]]; then
    printf '%s\n' "${_dir}/kcov-merged/cobertura.xml"
    return 0
  fi
  _xml="$(find "${_dir}" -mindepth 2 -maxdepth 2 -name cobertura.xml | head -1)"
  [[ -n "${_xml}" ]] || return 1
  printf '%s\n' "${_xml}"
}

# _make_fixture <root>
#   A repo-shaped tree: four lib scripts that each trace 200 records of a
#   given width, four one-test specs that each run one of them, and a
#   ballast spec the weights file sends to the OTHER shard -- so shard 2/2
#   is the four heavy specs and is not the whole pool (a shard that is the
#   whole pool runs serial by policy and would not be concurrent at all).
#   w1/w2 trace records just over 1 KiB; w3/w4 trace a large value. Every
#   lib also traces a MULTI-LINE record: xtrace prints a `[[ ]]` operand
#   verbatim, newlines included, so the record's second and third lines
#   carry no `kcov@` marker even in a serial run. kcov v43 echoes those
#   lines to its stderr; the backported upstream 76bf685 does not
#   (dockerfile/kcov-76bf685.patch, base#1414).
#
#   Each spec first meets the others at a RENDEZVOUS when KCOV_RDV names a
#   directory: it drops its name there and waits, up to 30 s, until all
#   four names are present. Only specs that run at the same time can all
#   arrive, so a shard that ran its slices one after another fails there,
#   and the arrivals prove the overlap a `jobs=4` label only claims.
_make_fixture() {
  local _root="${1}"
  mkdir -p "${_root}/lib" "${_root}/test/bats/unit" \
           "${_root}/test/bats/integration" "${_root}/coverage"
  local _i _l _len
  for _i in 1 2 3 4; do
    case "${_i}" in
      1|2) _len=1100 ;;
      *)   _len=70000 ;;
    esac
    # The `$` here is fixture TEXT, expanded when the fixture runs.
    # shellcheck disable=SC2016
    {
      printf '#!/bin/bash\n'
      printf 'v=$(head -c %s /dev/zero | tr "\\0" Q)\n' "${_len}"
      for (( _l = 1; _l <= 200; _l++ )); do
        printf ': W%sL%s "$v"\n' "${_i}" "${_l}"
      done
      printf '%s\n' "m=\$'mlhead\\nMLCONT2\\nMLCONT3'" \
        '[[ "$m" == *nomatch* ]] || :'
    } > "${_root}/lib/w${_i}.sh"
    chmod +x "${_root}/lib/w${_i}.sh"
    # The test line is printed rather than written in the here-doc, so no
    # line of THIS file starts with the test keyword except its own tests.
    {
      printf '@test "w%s" {\n' "${_i}"
      sed "s/@N@/${_i}/g" <<'SPEC'
  if [[ -n "${KCOV_RDV:-}" ]]; then
    : > "${KCOV_RDV}/w@N@"
    local _end=$(( SECONDS + 30 ))
    until (( $(find "${KCOV_RDV}" -maxdepth 1 -type f -name 'w*' | wc -l) >= 4 )); do
      if (( SECONDS >= _end )); then
        : > "${KCOV_RDV}/timeout-w@N@"
        return 1
      fi
      sleep 0.1
    done
  fi
  bash "${BATS_TEST_DIRNAME}/../../../lib/w@N@.sh"
SPEC
      printf '}\n'
    } > "${_root}/test/bats/unit/w${_i}_spec.bats"
  done
  : > "${_root}/test/bats/integration/ballast_spec.bats"
  for (( _l = 1; _l <= 20; _l++ )); do
    printf '@test "b%s" { :; }\n' "${_l}" \
      >> "${_root}/test/bats/integration/ballast_spec.bats"
  done
  printf '%s\n' "1 w1_spec.bats" "1 w2_spec.bats" "1 w3_spec.bats" \
    "1 w4_spec.bats" "100 ballast_spec.bats" > "${_root}/weights"
}

setup_file() {
  export LOG_FORMAT=text
  command -v kcov >/dev/null || return 1

  local _bin="${BATS_FILE_TMPDIR}/bin"
  mkdir -p "${_bin}"
  # Four jobs whatever the host: a metered shard takes one job per core,
  # and on a one-core runner the run would be serial and the guard vacuous.
  printf '#!/bin/sh\necho 4\n' > "${_bin}/nproc"
  chmod +x "${_bin}/nproc"

  # The driver run: the shard entry CI runs, against the fixture tree.
  # `env -u` keeps an OUTER kcov's instrumentation (when this spec itself
  # runs under `just test coverage`) out of the nested one.
  # COVERAGE_LOCAL_WORKDIR keeps the slices' scratch -- each slice's raw
  # err-<i> -- so the stderr assertion reads what kcov wrote, not the
  # bounded tail the driver replays.
  local _par="${BATS_FILE_TMPDIR}/par"
  _make_fixture "${_par}"
  mkdir -p "${BATS_FILE_TMPDIR}/rdv"
  # A red run is recorded, not raised: setup_file stops at a failing
  # command, and the tests below are what say WHY the run was red.
  local _rc=0
  env -u BASH_ENV -u BASH_XTRACEFD -u KCOV_BASH_XTRACEFD -u LD_PRELOAD \
    PATH="${_bin}:${PATH}" REPO_ROOT="${_par}" \
    SHARD_WEIGHTS_FILE="${_par}/weights" \
    KCOV_RDV="${BATS_FILE_TMPDIR}/rdv" \
    COVERAGE_LOCAL_WORKDIR="${BATS_FILE_TMPDIR}/work" \
    bash -c '
      _die() { echo "DIE: $*"; exit 1; }
      source /source/script/test/drivers/bats.sh
      _run_coverage 2/2
    ' > "${BATS_FILE_TMPDIR}/par.out" 2>&1 || _rc=$?
  echo "${_rc}" > "${BATS_FILE_TMPDIR}/par.rc"

  # The serial reference: the same four specs under one kcov, one at a
  # time, so no two traced processes ever share the pipe. No KCOV_RDV: one
  # serial bats cannot meet itself.
  local _ser="${BATS_FILE_TMPDIR}/ser"
  _make_fixture "${_ser}"
  _rc=0
  env -u BASH_ENV -u BASH_XTRACEFD -u KCOV_BASH_XTRACEFD -u LD_PRELOAD \
    -u KCOV_RDV -u COVERAGE_LOCAL_WORKDIR \
    kcov --include-path="${_ser}/lib" "${_ser}/coverage" \
    bats "${_ser}"/test/bats/unit/w{1,2,3,4}_spec.bats \
    > "${BATS_FILE_TMPDIR}/ser.out" 2>&1 || _rc=$?
  echo "${_rc}" > "${BATS_FILE_TMPDIR}/ser.rc"
}

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  assert_spec_subject /source/script/test/drivers/bats.sh \
    "the test driver whose _run_coverage shard entry this spec runs"
  command -v kcov >/dev/null || \
    fail "no kcov in this image -- the coverage instrument this spec measures is missing."
  PAR="${BATS_FILE_TMPDIR}/par"
  SER="${BATS_FILE_TMPDIR}/ser"
}

# why: The shard must be concurrent and must finish green, or the two
# assertions below would compare a run that never raced, or nothing. The
# label is the driver's claim; the rendezvous is the proof -- all four
# specs were running at the same moment, so their slices overlapped.
@test "kcov shard fixture: the driver ran the four heavy specs concurrently and passed" {
  run cat "${BATS_FILE_TMPDIR}/par.out"
  assert_output --partial "shard 2/2"
  assert_output --partial "jobs=4"
  assert_output --partial "w1_spec.bats"
  assert_output --partial "w4_spec.bats"
  refute_output --partial "ballast_spec.bats"
  run find "${BATS_FILE_TMPDIR}/rdv" -maxdepth 1 -type f -name 'timeout-*'
  assert_output ""
  run find "${BATS_FILE_TMPDIR}/rdv" -maxdepth 1 -type f -name 'w*'
  assert_equal "${#lines[@]}" 4
  run cat "${BATS_FILE_TMPDIR}/par.rc"
  assert_output "0"
  run cat "${BATS_FILE_TMPDIR}/ser.rc"
  assert_output "0"
}

# why: kcov echoes every marker-less trace line to its stderr, and on CI
# that stderr is the step's output -- megabyte lines a hosted runner masks
# at quadratic cost (base#1414). The fragments are not only the payload: a
# split record leaves a lone tail, and a multi-line record leaves lines of
# any length. So the assertion reads each slice's RAW stderr, not the
# bounded tail the driver replays, and admits 0 B of it; the driver's own
# output must also hold no line of 1 KiB or more.
@test "kcov shard: a concurrent shard's kcov writes no stderr, and no output line reaches 1 KiB" {
  local _err _bytes _total=0 _n=0 _report=""
  for _err in "${BATS_FILE_TMPDIR}"/work/err-*; do
    [[ -f "${_err}" ]] || continue
    _n=$(( _n + 1 ))
    _bytes="$(wc -c < "${_err}" | tr -d ' ')"
    _total=$(( _total + _bytes ))
    if (( _bytes > 0 )); then
      _report+="${_err##*/}: ${_bytes} B, first lines (cut to 120 B):
$(head -5 "${_err}" | LC_ALL=C cut -b 1-120)
"
    fi
  done
  (( _n == 4 )) || \
    fail "expected the raw stderr of 4 slices under ${BATS_FILE_TMPDIR}/work, found ${_n}; the driver did not keep its slice scratch."
  if (( _total > 0 )); then
    fail "the concurrent shard's slices wrote ${_total} B of stderr (bound: 0 B). kcov echoed marker-less trace lines -- pieces of interleaved or multi-line records (base#1414):
${_report}"
  fi
  local _longest
  _longest="$(awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' "${BATS_FILE_TMPDIR}/par.out")"
  (( _longest < 1024 )) || \
    fail "the driver printed a line of ${_longest} B (bound: < 1024 B) (base#1414)."
}

# why: kcov credits only the FIRST marker on an interleaved line, so a
# shared pipe loses lines that ran with every test green. The concurrent
# shard's covered set must equal a serial run's, line for line.
@test "kcov shard: a concurrent shard covers exactly the lines a serial run covers" {
  local _pr _sr
  _pr="$(_report "${PAR}/coverage")" || fail "the shard wrote no cobertura report under ${PAR}/coverage"
  _sr="$(_report "${SER}/coverage")" || fail "the serial reference wrote no cobertura report under ${SER}/coverage"
  _cov_lines "${_pr}" > "${BATS_TEST_TMPDIR}/par.lines"
  _cov_lines "${_sr}" > "${BATS_TEST_TMPDIR}/ser.lines"
  # Non-vacuous: the serial run saw every traced line of all four libs
  # (200 records, the two assignments and the multi-line test, per lib).
  run wc -l < "${BATS_TEST_TMPDIR}/ser.lines"
  assert_output "812"
  run comm -3 "${BATS_TEST_TMPDIR}/ser.lines" "${BATS_TEST_TMPDIR}/par.lines"
  if [[ -n "${output}" ]]; then
    fail "the concurrent shard's covered set differs from the serial run's ($(wc -l < "${BATS_TEST_TMPDIR}/par.lines") vs 812 lines); serial-only lines are left-aligned, shard-only lines indented:
$(printf '%s\n' "${output}" | head -40)"
  fi
}
