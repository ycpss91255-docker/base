#!/usr/bin/env bats
#
# Unit tests for downstream/script/docker/lib/transcript.sh (#606).
#
# The wrapper transcript tees a non-interactive verb's combined output to
# log/<verb>/<ts>-<traceid8>.log (ANSI stripped) with a per-verb
# latest.log symlink, an exit-code+duration closing line, retention, and
# an atexit registry that owns the single EXIT trap. Pure helpers are
# tested directly; the tee + EXIT-finalize is exercised end-to-end by
# running a tiny harness in a subshell.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  # shellcheck disable=SC1091
  source /source/downstream/script/docker/lib/log.sh
  # shellcheck disable=SC1091
  source /source/downstream/script/docker/lib/transcript.sh
  TMP_DIR="$(mktemp -d)"
  TRANSCRIPT_SH="/source/downstream/script/docker/lib/transcript.sh"
  LOG_SH="/source/downstream/script/docker/lib/log.sh"
  # The self-test runner exports WRAPPER_TRANSCRIPT=false globally (#622) so
  # other specs never write a log/ tree into the checkout. This spec is the
  # one that exercises the conf-based enable logic, so clear the env override
  # here and let each test set it explicitly.
  unset WRAPPER_TRANSCRIPT
}

teardown() { rm -rf "${TMP_DIR}"; }

# ── verb classification ─────────────────────────────────────────────

@test "_transcript_is_full_verb: the 5 non-interactive verbs are captured (#606)" {
  for _v in build setup stop prune upgrade; do
    run _transcript_is_full_verb "${_v}"
    assert_success
  done
}

@test "_transcript_is_full_verb: interactive verbs + unknown are NOT captured (#606)" {
  for _v in run exec setup_tui "" foo; do
    run _transcript_is_full_verb "${_v}"
    assert_failure
  done
}

@test "_transcript_is_interactive_verb: run/exec/setup_tui yes; full verbs + unknown no (#608)" {
  for _v in run exec setup_tui; do
    run _transcript_is_interactive_verb "${_v}"
    assert_success
  done
  for _v in build setup stop prune upgrade "" foo; do
    run _transcript_is_interactive_verb "${_v}"
    assert_failure
  done
}

@test "_transcript_is_capture_verb: every full + interactive verb captures; unknown does not (#608)" {
  for _v in build setup stop prune upgrade run exec setup_tui; do
    run _transcript_is_capture_verb "${_v}"
    assert_success
  done
  for _v in "" foo; do
    run _transcript_is_capture_verb "${_v}"
    assert_failure
  done
}

# ── filename + meta line ────────────────────────────────────────────

@test "_transcript_filename: <root>/log/<verb>/<ts>-<traceid8>.log (#606)" {
  run _transcript_filename /repo build 20260618T101112Z deadbeef
  assert_output "/repo/log/build/20260618T101112Z-deadbeef.log"
}

@test "_transcript_meta_line: formats an lnav-parseable level line (#606)" {
  _WRAPPER_VERB=build run _transcript_meta_line INFO "transcript_complete exit_code=0"
  assert_output --partial "[build] INFO"
  assert_output --partial "transcript_complete exit_code=0"
}

# ── trace id resolution ─────────────────────────────────────────────

@test "_transcript_resolve_traceid: inherits a well-formed TRACEPARENT trace_id (#606)" {
  local _tid=""
  TRACEPARENT="00-0123456789abcdef0123456789abcdef-aabbccddeeff0011-01" \
    _transcript_resolve_traceid _tid
  assert_equal "${_tid}" "0123456789abcdef0123456789abcdef"
  assert_equal "${_TRANSCRIPT_TRACE_SOURCE}" "inherited"
}

@test "_transcript_resolve_traceid: generates a 32-hex id when TRACEPARENT absent (#606)" {
  local _tid=""
  unset TRACEPARENT
  _transcript_resolve_traceid _tid
  [[ "${_tid}" =~ ^[0-9a-f]{32}$ ]]
  assert_equal "${_TRANSCRIPT_TRACE_SOURCE}" "generated"
}

# ── enabled / kill switch ───────────────────────────────────────────

@test "_transcript_enabled: true by default when no setup.conf (#606)" {
  FILE_PATH="${TMP_DIR}" run _transcript_enabled
  assert_success
}

@test "_transcript_enabled: false when wrapper_transcript = false (#606)" {
  mkdir -p "${TMP_DIR}/config/docker"
  printf '[logging]\nwrapper_transcript = false\n' > "${TMP_DIR}/config/docker/setup.conf"
  FILE_PATH="${TMP_DIR}" run _transcript_enabled
  assert_failure
}

@test "_transcript_enabled: WRAPPER_TRANSCRIPT=false env wins over conf=true (#622)" {
  mkdir -p "${TMP_DIR}/config/docker"
  printf '[logging]\nwrapper_transcript = true\n' > "${TMP_DIR}/config/docker/setup.conf"
  WRAPPER_TRANSCRIPT=false FILE_PATH="${TMP_DIR}" run _transcript_enabled
  assert_failure
}

@test "_transcript_enabled: WRAPPER_TRANSCRIPT=true env wins over conf=false (#622)" {
  mkdir -p "${TMP_DIR}/config/docker"
  printf '[logging]\nwrapper_transcript = false\n' > "${TMP_DIR}/config/docker/setup.conf"
  WRAPPER_TRANSCRIPT=true FILE_PATH="${TMP_DIR}" run _transcript_enabled
  assert_success
}

# ── atexit registry ─────────────────────────────────────────────────

@test "_atexit: registered callbacks run LIFO on exit (#606)" {
  run bash -c "
    source ${LOG_SH}; source ${TRANSCRIPT_SH}
    a() { printf 'a\n'; }; b() { printf 'b\n'; }
    _atexit a; _atexit b
  "
  assert_success
  # b registered last -> runs first.
  assert_line --index 0 "b"
  assert_line --index 1 "a"
}

# ── retention ───────────────────────────────────────────────────────

@test "_transcript_prune: keeps the N most recent, drops the rest (#606)" {
  local _d="${TMP_DIR}/log/build"
  mkdir -p "${_d}"
  local _i
  for _i in $(seq -w 1 25); do
    printf 'x\n' > "${_d}/2026010${_i}.log"
    touch -d "2026-01-01 00:00:${_i}" "${_d}/2026010${_i}.log" 2>/dev/null || true
  done
  _transcript_prune "${_d}" 20 3650
  run bash -c "ls ${_d}/*.log | wc -l"
  assert_output "20"
}

@test "_transcript_prune: drops files older than <days> regardless of count (#606)" {
  local _d="${TMP_DIR}/log/build"
  mkdir -p "${_d}"
  printf 'old\n' > "${_d}/old.log"; touch -d "60 days ago" "${_d}/old.log"
  printf 'new\n' > "${_d}/new.log"; touch -d "1 day ago" "${_d}/new.log"
  _transcript_prune "${_d}" 20 14
  assert [ ! -f "${_d}/old.log" ]
  assert [ -f "${_d}/new.log" ]
}

# ── end-to-end: tee + finalize ──────────────────────────────────────

_run_transcript_harness() {  # <verb> <extra-env...>
  local _verb="$1"; shift
  run bash -c "
    export _WRAPPER_VERB='${_verb}' FILE_PATH='${TMP_DIR}' ${*}
    source ${LOG_SH}; source ${TRANSCRIPT_SH}
    _transcript_begin
    printf 'plain stdout line\n'
    printf '\033[1;31mcolored\033[0m\n'
    printf 'to stderr\n' >&2
    exit 0
  "
}

@test "transcript: a full verb produces log/<verb>/<ts>-<id>.log with content (#606)" {
  _run_transcript_harness build
  assert_success
  # output still reaches the caller (tee is transparent)
  assert_output --partial "plain stdout line"
  local _f
  _f="$(ls "${TMP_DIR}/log/build/"*.log 2>/dev/null | head -n1)"
  assert [ -n "${_f}" ]
  run cat "${_f}"
  assert_output --partial "plain stdout line"
  assert_output --partial "to stderr"
}

@test "transcript: the file is ANSI-stripped while the terminal keeps colour (#606)" {
  _run_transcript_harness build
  # the caller saw the raw ANSI...
  assert_output --partial $'\033[1;31m'
  local _f
  _f="$(ls "${TMP_DIR}/log/build/"*.log | head -n1)"
  # ...but the file has the escape stripped.
  run grep -F $'\033[' "${_f}"
  assert_failure
  run grep -F "colored" "${_f}"
  assert_success
}

@test "transcript: closing line carries the exit code + duration (#606)" {
  _run_transcript_harness build
  local _f
  _f="$(ls "${TMP_DIR}/log/build/"*.log | head -n1)"
  run grep -F "transcript_complete exit_code=0" "${_f}"
  assert_success
  assert_output --partial "duration="
}

@test "transcript: latest.log symlink points at the run's file (#606)" {
  _run_transcript_harness build
  assert [ -L "${TMP_DIR}/log/build/latest.log" ]
  run cat "${TMP_DIR}/log/build/latest.log"
  assert_output --partial "plain stdout line"
}

@test "transcript: wrapper_transcript=false is a complete no-op (no file) (#606)" {
  mkdir -p "${TMP_DIR}/config/docker"
  printf '[logging]\nwrapper_transcript = false\n' > "${TMP_DIR}/config/docker/setup.conf"
  _run_transcript_harness build
  assert_success
  assert_output --partial "plain stdout line"
  assert [ ! -d "${TMP_DIR}/log/build" ]
}

# ── #608: interactive verbs (orchestration capture + detach) ────────

@test "transcript: an interactive verb without detach full-captures (the run -d path) (#608)" {
  _run_transcript_harness run
  assert_success
  assert_output --partial "plain stdout line"
  local _f
  _f="$(ls "${TMP_DIR}/log/run/"*.log 2>/dev/null | head -n1)"
  assert [ -n "${_f}" ]
  run cat "${_f}"
  assert_output --partial "plain stdout line"
}

@test "transcript: _transcript_detach captures orchestration only, not the interactive session (#608)" {
  run bash -c "
    export _WRAPPER_VERB=exec FILE_PATH='${TMP_DIR}'
    source ${LOG_SH}; source ${TRANSCRIPT_SH}
    _transcript_begin
    printf 'orchestration phase\n'
    _transcript_detach
    printf 'interactive session output\n'
    exit 0
  "
  assert_success
  # both lines still reach the caller's terminal
  assert_output --partial "orchestration phase"
  assert_output --partial "interactive session output"
  local _f
  _f="$(ls "${TMP_DIR}/log/exec/"*.log 2>/dev/null | head -n1)"
  assert [ -n "${_f}" ]
  run cat "${_f}"
  assert_output --partial "orchestration phase"
  assert_output --partial "transcript_detached"
  refute_output --partial "interactive session output"
}

@test "transcript: _transcript_detach is a no-op when the transcript never began (#608)" {
  run bash -c "
    export _WRAPPER_VERB=build FILE_PATH='${TMP_DIR}'
    source ${LOG_SH}; source ${TRANSCRIPT_SH}
    _transcript_detach
    printf 'ok\n'
  "
  assert_success
  assert_output --partial "ok"
}

# ── wiring guards ───────────────────────────────────────────────────

@test "wiring: the 5 full verbs call _transcript_begin (#606)" {
  for _w in build stop prune setup; do
    run grep -qF '_transcript_begin' "/source/downstream/script/docker/wrapper/${_w}.sh"
    assert_success
  done
  run grep -qF '_transcript_begin' /source/upgrade.sh
  assert_success
}

@test "wiring: run/exec/setup_tui call both _transcript_begin and _transcript_detach (#608)" {
  for _w in run exec setup_tui; do
    run grep -qF '_transcript_begin' "/source/downstream/script/docker/wrapper/${_w}.sh"
    assert_success
    run grep -qF '_transcript_detach' "/source/downstream/script/docker/wrapper/${_w}.sh"
    assert_success
  done
}
