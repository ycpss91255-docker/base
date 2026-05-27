#!/usr/bin/env bats
#
# log_spec.bats - Tests for OTel-aligned log.sh (#423).
# Dual output: terminal = text (with timestamp + aligned level);
# LOG_JSON_FILE = structured JSON per OTel Logs Data Model.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  LOG_SH="/source/script/docker/lib/log.sh"
  JSON_FILE="${BATS_TEST_TMPDIR}/log.jsonl"
}

# ── Text output format (terminal) ──────────────────────────────────

@test "_log_info text output has timestamp + aligned level + tag" {
  run --separate-stderr bash -c "source ${LOG_SH}; _log_info setup 'phase done'"
  assert_success
  assert_equal "${stderr}" ""
  [[ "${output}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
  [[ "${output}" == *"[setup] INFO : phase done" ]]
}

@test "_log_err text output to stderr with timestamp" {
  run --separate-stderr bash -c "source ${LOG_SH}; _log_err build 'something broke'"
  assert_success
  assert_equal "${output}" ""
  [[ "${stderr}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
  [[ "${stderr}" == *"[build] ERROR: something broke" ]]
}

@test "_log_warn text output uses WARN (not WARNING)" {
  run --separate-stderr bash -c "source ${LOG_SH}; _log_warn run 'deprecated flag'"
  assert_success
  [[ "${stderr}" =~ 'WARN : deprecated flag'$ ]]
}

@test "_log_debug text output to stdout" {
  run --separate-stderr bash -c "source ${LOG_SH}; _log_debug build 'trace msg'"
  assert_success
  [[ "${output}" =~ 'DEBUG: trace msg'$ ]]
  assert_equal "${stderr}" ""
}

@test "_log_fatal text output to stderr" {
  run --separate-stderr bash -c "source ${LOG_SH}; _log_fatal init 'unrecoverable'"
  assert_success
  [[ "${stderr}" =~ 'FATAL: unrecoverable'$ ]]
}

@test "text levels are right-aligned to 5 chars" {
  run --separate-stderr bash -c "
    source ${LOG_SH}
    _log_info  setup 'i'
    _log_debug setup 'd'
  "
  assert_success
  [[ "${lines[0]}" =~ 'INFO : i'$ ]]
  [[ "${lines[1]}" =~ 'DEBUG: d'$ ]]
}

@test "text output joins multi-token message with spaces" {
  run --separate-stderr bash -c "source ${LOG_SH}; _log_err build word1 word2 word3"
  assert_success
  [[ "${stderr}" =~ 'ERROR: word1 word2 word3'$ ]]
}

@test "text output skips attr=val args in message" {
  run bash -c "source ${LOG_SH}; _log_info setup 'regen done' ws_path=/tmp conf_hash=abc"
  assert_success
  [[ "${output}" =~ 'INFO : regen done'$ ]]
  refute_line --partial "ws_path"
}

# ── Stream routing ─────────────────────────────────────────────────

@test "_log_info and _log_debug route to stdout" {
  run --separate-stderr bash -c "source ${LOG_SH}; _log_info setup msg1; _log_debug setup msg2"
  assert_success
  assert_equal "${stderr}" ""
  [[ "${output}" == *"msg1"* ]]
  [[ "${output}" == *"msg2"* ]]
}

@test "_log_warn _log_err _log_fatal route to stderr" {
  run --separate-stderr bash -c "
    source ${LOG_SH}
    _log_warn  setup w
    _log_err   setup e
    _log_fatal setup f
  "
  assert_success
  assert_equal "${output}" ""
  [[ "${stderr}" == *"WARN"* ]]
  [[ "${stderr}" == *"ERROR"* ]]
  [[ "${stderr}" == *"FATAL"* ]]
}

# ── JSON file output (LOG_JSON_FILE) ───────────────────────────────

@test "LOG_JSON_FILE receives JSON when set" {
  run bash -c "
    export LOG_JSON_FILE='${JSON_FILE}'
    source ${LOG_SH}
    _log_info setup 'regen done' ws_path=/tmp
  "
  assert_success
  [[ -f "${JSON_FILE}" ]]
  local json
  json="$(cat "${JSON_FILE}")"
  [[ "${json}" == *'"severity_text":"INFO"'* ]]
  [[ "${json}" == *'"body":"regen done"'* ]]
}

@test "JSON file contains OTel fields" {
  run bash -c "
    export LOG_JSON_FILE='${JSON_FILE}'
    source ${LOG_SH}
    _log_info setup env_regenerated ws_path=/tmp
  "
  assert_success
  local json
  json="$(cat "${JSON_FILE}")"
  [[ "${json}" == *'"timestamp":'* ]]
  [[ "${json}" == *'"severity_text":"INFO"'* ]]
  [[ "${json}" == *'"severity_number":9'* ]]
  [[ "${json}" == *'"body":"env_regenerated"'* ]]
  [[ "${json}" == *'"service.name":"setup"'* ]]
  [[ "${json}" == *'"service.lang":"bash"'* ]]
  [[ "${json}" == *'"code.filepath":'* ]]
  [[ "${json}" == *'"code.lineno":'* ]]
  [[ "${json}" == *'"thread.id":'* ]]
}

@test "JSON file contains custom attributes" {
  run bash -c "
    export LOG_JSON_FILE='${JSON_FILE}'
    source ${LOG_SH}
    _log_info setup env_regenerated ws_path=/tmp conf_hash=abc123
  "
  assert_success
  local json
  json="$(cat "${JSON_FILE}")"
  [[ "${json}" == *'"ws_path":"/tmp"'* ]]
  [[ "${json}" == *'"conf_hash":"abc123"'* ]]
}

@test "JSON severity_number: DEBUG=5 INFO=9 WARN=13 ERROR=17 FATAL=21" {
  run bash -c "
    export LOG_JSON_FILE='${JSON_FILE}'
    source ${LOG_SH}
    _log_debug build dry_run_cmd
    _log_info  setup env_regenerated
    _log_warn  setup xauth_rewrite_failed
    _log_err   setup conf_invalid_value
    _log_fatal init  init_missing_required_arg
  " 2>/dev/null
  assert_success
  local json
  json="$(cat "${JSON_FILE}")"
  [[ "${json}" == *'"severity_number":5'* ]]
  [[ "${json}" == *'"severity_number":9'* ]]
  [[ "${json}" == *'"severity_number":13'* ]]
  [[ "${json}" == *'"severity_number":17'* ]]
  [[ "${json}" == *'"severity_number":21'* ]]
}

@test "no JSON file written when LOG_JSON_FILE is unset" {
  run bash -c "unset LOG_JSON_FILE; source ${LOG_SH}; _log_info setup msg"
  assert_success
  [[ ! -f "${JSON_FILE}" ]]
}

@test "JSON file appends multiple entries" {
  run bash -c "
    export LOG_JSON_FILE='${JSON_FILE}'
    source ${LOG_SH}
    _log_info setup env_regenerated
    _log_err  setup conf_invalid_value
  " 2>/dev/null
  assert_success
  local count
  count="$(wc -l < "${JSON_FILE}")"
  [[ "${count}" -eq 2 ]]
}

# ── TRACEPARENT in JSON file ───────────────────────────────────────

@test "JSON includes trace_id and span_id when TRACEPARENT is set" {
  run bash -c "
    export TRACEPARENT='00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01'
    export LOG_JSON_FILE='${JSON_FILE}'
    source ${LOG_SH}
    _log_info setup env_regenerated
  "
  assert_success
  local json
  json="$(cat "${JSON_FILE}")"
  [[ "${json}" == *'"trace_id":"0af7651916cd43dd8448eb211c80319c"'* ]]
  [[ "${json}" == *'"span_id":"b7ad6b7169203331"'* ]]
}

@test "JSON omits trace_id when TRACEPARENT is unset" {
  run bash -c "
    unset TRACEPARENT
    export LOG_JSON_FILE='${JSON_FILE}'
    source ${LOG_SH}
    _log_info setup env_regenerated
  "
  assert_success
  local json
  json="$(cat "${JSON_FILE}")"
  [[ "${json}" != *'"trace_id"'* ]]
}

# ── Missing service is rejected ────────────────────────────────────

@test "_log_info with no args exits non-zero" {
  run -127 bash -c "source ${LOG_SH}; _log_info"
}

@test "_log_err with no args exits non-zero" {
  run -127 bash -c "source ${LOG_SH}; _log_err"
}

# ── _log_fatal does NOT auto-exit ──────────────────────────────────

@test "_log_fatal does not exit; caller controls exit" {
  run --separate-stderr bash -c "
    source ${LOG_SH}
    _log_fatal init 'unrecoverable' arg=REPO_NAME
    echo 'still running'
  "
  assert_success
  assert_equal "${output}" "still running"
}

# ── Scoped wrappers ────────────────────────────────────────────────

@test "_log_with_trace sets TRACEPARENT and restores prior value" {
  run bash -c "
    source ${LOG_SH}
    export TRACEPARENT='00-aaaa0000aaaa0000aaaa0000aaaa0000-bbbb0000bbbb0000-01'
    _log_with_trace bash -c 'echo \$TRACEPARENT' 2>/dev/null
    echo \"restored=\${TRACEPARENT}\"
  "
  assert_success
  assert_line --partial "00-"
  assert_line "restored=00-aaaa0000aaaa0000aaaa0000aaaa0000-bbbb0000bbbb0000-01"
}

@test "_log_with_trace without prior TRACEPARENT unsets on return" {
  run bash -c "
    unset TRACEPARENT
    source ${LOG_SH}
    _log_with_trace bash -c 'echo inside=\$TRACEPARENT' 2>/dev/null
    echo \"after=\${TRACEPARENT:-unset}\"
  "
  assert_success
  assert_line --partial "inside=00-"
  assert_line "after=unset"
}

@test "_log_with_span preserves trace_id from parent" {
  run bash -c "
    export TRACEPARENT='00-deadbeef00000000deadbeef00000000-1111111111111111-01'
    source ${LOG_SH}
    _log_with_span child_op bash -c 'echo \$TRACEPARENT'
    echo \"restored=\${TRACEPARENT}\"
  "
  assert_success
  assert_line --regexp "^00-deadbeef00000000deadbeef00000000-[0-9a-f]{16}-01$"
  assert_line "restored=00-deadbeef00000000deadbeef00000000-1111111111111111-01"
}

@test "_log_with_trace prints trace started message to stderr" {
  run --separate-stderr bash -c "source ${LOG_SH}; _log_with_trace true"
  assert_success
  [[ "${stderr}" == *"[trace started:"* ]]
}

# ── _log_plain backward compat ─────────────────────────────────────

@test "_log_plain writes tagged text to stdout (no style)" {
  run --separate-stderr bash -c "source ${LOG_SH}; _log_plain build '' 'plain text'"
  assert_success
  assert_equal "${output}" "[build] plain text"
  assert_equal "${stderr}" ""
}

@test "_log_plain with bold + FORCE_COLOR=1 wraps in ANSI bold" {
  run --separate-stderr bash -c "FORCE_COLOR=1 source ${LOG_SH}; FORCE_COLOR=1 _log_plain build bold 'header'"
  assert_success
  assert_equal "${output}" $'[build] \033[1mheader\033[0m'
}

@test "_log_plain with no tag exits non-zero" {
  run -127 bash -c "source ${LOG_SH}; _log_plain"
}

# ── _log_color_enabled ─────────────────────────────────────────────

@test "_log_color_enabled returns non-zero on non-TTY without overrides" {
  run bash -c "source ${LOG_SH}; _log_color_enabled 1"
  assert_failure
}

@test "_log_color_enabled returns 0 with FORCE_COLOR=1" {
  run bash -c "FORCE_COLOR=1 source ${LOG_SH}; FORCE_COLOR=1 _log_color_enabled 1"
  assert_success
}

@test "_log_color_enabled returns non-zero with NO_COLOR=1 + FORCE_COLOR=1" {
  run bash -c "NO_COLOR=1 FORCE_COLOR=1 source ${LOG_SH}; NO_COLOR=1 FORCE_COLOR=1 _log_color_enabled 1"
  assert_failure
}

# ── FORCE_COLOR text ───────────────────────────────────────────────

@test "_log_err FORCE_COLOR=1 emits red bold ANSI in text" {
  run --separate-stderr bash -c "FORCE_COLOR=1 source ${LOG_SH}; FORCE_COLOR=1 _log_err build msg"
  assert_success
  [[ "${stderr}" == *$'\033[1;31m'* ]]
  [[ "${stderr}" == *"ERROR"* ]]
  [[ "${stderr}" == *"msg"* ]]
}

@test "_log_warn FORCE_COLOR=1 emits yellow ANSI in text" {
  run --separate-stderr bash -c "FORCE_COLOR=1 source ${LOG_SH}; FORCE_COLOR=1 _log_warn run msg"
  assert_success
  [[ "${stderr}" == *$'\033[33m'* ]]
  [[ "${stderr}" == *"WARN"* ]]
}

@test "NO_COLOR=1 text omits ANSI" {
  run --separate-stderr bash -c "NO_COLOR=1 FORCE_COLOR=1 source ${LOG_SH}; NO_COLOR=1 FORCE_COLOR=1 _log_err build msg"
  assert_success
  [[ "${stderr}" != *$'\033['* ]]
  [[ "${stderr}" == *"ERROR: msg"* ]]
}

# ── Event registry ─────────────────────────────────────────────────

@test "log-events.txt is loaded and contains env_regenerated" {
  run bash -c "source ${LOG_SH}; _log_is_registered env_regenerated && echo yes"
  assert_output "yes"
}

@test "unregistered event returns false" {
  run bash -c "source ${LOG_SH}; _log_is_registered not_a_real_event || echo no"
  assert_output "no"
}

@test "log-events.txt comment lines are not registered as events" {
  run bash -c "source ${LOG_SH}; _log_is_registered '# setup.sh' || echo no"
  assert_output "no"
}

# ── lnav format file ──────────────────────────────────────────────

@test "log.lnav-format.json exists and contains format key" {
  local _f="/source/script/docker/lib/log.lnav-format.json"
  [[ -f "${_f}" ]]
  run grep -q '"ycpss91255_otel_log"' "${_f}"
  assert_success
}

@test "log.lnav-format.json declares json: true" {
  run grep -q '"json": true' /source/script/docker/lib/log.lnav-format.json
  assert_success
}
