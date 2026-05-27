#!/usr/bin/env bats
#
# log_spec.bats - Tests for OTel-aligned log.sh (#423).
# Covers: 5 levels + JSON shape + TRACEPARENT parsing + body enum +
# legacy text fallback + scoped wrappers + _log_plain compat.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  LOG_SH="/source/script/docker/lib/log.sh"
}

# Helper: extract a JSON string field value via grep.
# Usage: json_field <field> <json_line>
json_field() {
  local key="${1}" json="${2}"
  echo "${json}" | grep -o "\"${key}\":\"[^\"]*\"" | head -1 | sed "s/\"${key}\":\"\(.*\)\"/\1/"
}

json_num_field() {
  local key="${1}" json="${2}"
  echo "${json}" | grep -o "\"${key}\":[0-9]*" | head -1 | sed "s/\"${key}\"://"
}

# ── JSON output for registered body ────────────────────────────────

@test "_log_info with registered body emits JSON to stdout" {
  run --separate-stderr bash -c "source ${LOG_SH}; _log_info setup env_regenerated"
  assert_success
  assert_equal "${stderr}" ""
  assert_line --partial '"severity_text":"INFO"'
  assert_line --partial '"body":"env_regenerated"'
}

@test "_log_err with registered body emits JSON to stderr" {
  run --separate-stderr bash -c "source ${LOG_SH}; _log_err setup conf_invalid_value"
  assert_success
  assert_equal "${output}" ""
  [[ "${stderr}" == *'"severity_text":"ERROR"'* ]]
}

@test "_log_warn with registered body emits JSON to stderr" {
  run --separate-stderr bash -c "source ${LOG_SH}; _log_warn setup xauth_rewrite_failed"
  assert_success
  [[ "${stderr}" == *'"severity_text":"WARN"'* ]]
}

@test "_log_debug with registered body emits JSON to stdout" {
  run --separate-stderr bash -c "source ${LOG_SH}; _log_debug build dry_run_cmd cmd='git push'"
  assert_success
  assert_line --partial '"severity_text":"DEBUG"'
}

@test "_log_fatal with registered body emits JSON to stderr" {
  run --separate-stderr bash -c "source ${LOG_SH}; _log_fatal init init_missing_required_arg arg=REPO_NAME"
  assert_success
  [[ "${stderr}" == *'"severity_text":"FATAL"'* ]]
}

# ── severity_number correctness ────────────────────────────────────

@test "_log_debug severity_number is 5" {
  run bash -c "source ${LOG_SH}; _log_debug build dry_run_cmd"
  assert_line --partial '"severity_number":5'
}

@test "_log_info severity_number is 9" {
  run bash -c "source ${LOG_SH}; _log_info setup env_regenerated"
  assert_line --partial '"severity_number":9'
}

@test "_log_warn severity_number is 13" {
  run --separate-stderr bash -c "source ${LOG_SH}; _log_warn setup xauth_rewrite_failed"
  [[ "${stderr}" == *'"severity_number":13'* ]]
}

@test "_log_err severity_number is 17" {
  run --separate-stderr bash -c "source ${LOG_SH}; _log_err setup conf_invalid_value"
  [[ "${stderr}" == *'"severity_number":17'* ]]
}

@test "_log_fatal severity_number is 21" {
  run --separate-stderr bash -c "source ${LOG_SH}; _log_fatal init init_missing_required_arg"
  [[ "${stderr}" == *'"severity_number":21'* ]]
}

# ── JSON schema shape ──────────────────────────────────────────────

@test "JSON contains required OTel fields" {
  run bash -c "source ${LOG_SH}; _log_info setup env_regenerated ws_path=/tmp"
  assert_success
  assert_line --partial '"timestamp":'
  assert_line --partial '"severity_text":'
  assert_line --partial '"severity_number":'
  assert_line --partial '"body":'
  assert_line --partial '"service.name":"setup"'
  assert_line --partial '"service.lang":"bash"'
  assert_line --partial '"code.filepath":'
  assert_line --partial '"code.lineno":'
  assert_line --partial '"thread.id":'
}

@test "JSON body matches the event name argument" {
  run bash -c "source ${LOG_SH}; _log_info setup env_regenerated"
  assert_line --partial '"body":"env_regenerated"'
}

@test "JSON service.name matches the service argument" {
  run bash -c "source ${LOG_SH}; _log_info myservice env_regenerated"
  assert_line --partial '"service.name":"myservice"'
}

@test "JSON service.lang is bash" {
  run bash -c "source ${LOG_SH}; _log_info setup env_regenerated"
  assert_line --partial '"service.lang":"bash"'
}

@test "JSON custom attributes are included" {
  run bash -c "source ${LOG_SH}; _log_info setup env_regenerated ws_path=/tmp conf_hash=abc123"
  assert_success
  assert_line --partial '"ws_path":"/tmp"'
  assert_line --partial '"conf_hash":"abc123"'
}

# ── TRACEPARENT parsing ────────────────────────────────────────────

@test "JSON includes trace_id and span_id when TRACEPARENT is set" {
  run bash -c "
    export TRACEPARENT='00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01'
    source ${LOG_SH}
    _log_info setup env_regenerated
  "
  assert_success
  assert_line --partial '"trace_id":"0af7651916cd43dd8448eb211c80319c"'
  assert_line --partial '"span_id":"b7ad6b7169203331"'
}

@test "JSON omits trace_id when TRACEPARENT is unset" {
  run bash -c "unset TRACEPARENT; source ${LOG_SH}; _log_info setup env_regenerated"
  assert_success
  refute_line --partial '"trace_id"'
}

# ── Legacy text fallback (unregistered body) ───────────────────────

@test "_log_err with unregistered body falls back to text on stderr" {
  run --separate-stderr bash -c "source ${LOG_SH}; _log_err build 'something broke'"
  assert_success
  assert_equal "${output}" ""
  assert_equal "${stderr}" "[build] ERROR: something broke"
}

@test "_log_warn with unregistered body falls back to text on stderr" {
  run --separate-stderr bash -c "source ${LOG_SH}; _log_warn run 'deprecated flag'"
  assert_success
  assert_equal "${stderr}" "[run] WARNING: deprecated flag"
}

@test "_log_info with unregistered body falls back to text on stdout" {
  run --separate-stderr bash -c "source ${LOG_SH}; _log_info setup 'phase done'"
  assert_success
  assert_equal "${output}" "[setup] INFO: phase done"
  assert_equal "${stderr}" ""
}

@test "legacy text joins multi-token message with spaces" {
  run --separate-stderr bash -c "source ${LOG_SH}; _log_err build word1 word2 word3"
  assert_success
  assert_equal "${stderr}" "[build] ERROR: word1 word2 word3"
}

# ── LOG_STRICT_BODY rejection ──────────────────────────────────────

@test "LOG_STRICT_BODY=1 rejects unregistered body with exit 1" {
  run --separate-stderr bash -c "
    export LOG_STRICT_BODY=1
    source ${LOG_SH}
    _log_info setup 'not_a_real_event'
  "
  assert_failure
  [[ "${stderr}" == *"unregistered body"* ]]
}

@test "LOG_STRICT_BODY=1 accepts registered body" {
  run bash -c "
    export LOG_STRICT_BODY=1
    source ${LOG_SH}
    _log_info setup env_regenerated
  "
  assert_success
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
    _log_fatal init init_missing_required_arg arg=REPO_NAME
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

# ── FORCE_COLOR legacy text ────────────────────────────────────────

@test "_log_err FORCE_COLOR=1 legacy emits red bold ANSI" {
  run --separate-stderr bash -c "FORCE_COLOR=1 source ${LOG_SH}; FORCE_COLOR=1 _log_err build msg"
  assert_success
  assert_equal "${stderr}" $'\033[1;31m[build] ERROR:\033[0m msg'
}

@test "_log_warn FORCE_COLOR=1 legacy emits yellow ANSI" {
  run --separate-stderr bash -c "FORCE_COLOR=1 source ${LOG_SH}; FORCE_COLOR=1 _log_warn run msg"
  assert_success
  assert_equal "${stderr}" $'\033[33m[run] WARNING:\033[0m msg'
}

@test "NO_COLOR=1 legacy text omits ANSI" {
  run --separate-stderr bash -c "NO_COLOR=1 FORCE_COLOR=1 source ${LOG_SH}; NO_COLOR=1 FORCE_COLOR=1 _log_err build msg"
  assert_success
  assert_equal "${stderr}" "[build] ERROR: msg"
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
