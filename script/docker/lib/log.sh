#!/usr/bin/env bash
#
# log.sh - OTel-aligned 5-level JSON logger (#423).
#
# 5 functions: _log_debug, _log_info, _log_warn, _log_err, _log_fatal.
# API: _log_<level> <service> <body> [attr=val]...
#
# When <body> is a registered event (in log-events.txt), emits one JSON
# line per the OTel Logs Data Model. When <body> is NOT registered,
# falls back to legacy text output for backward compatibility (P2
# migrates all callers; P4 enables strict rejection via LOG_STRICT_BODY).
#
# Stream routing (matches OTel severity mapping):
#   _log_debug / _log_info -> stdout
#   _log_warn / _log_err / _log_fatal -> stderr
#
# TRACEPARENT env (W3C Trace Context) propagation:
#   When set, trace_id and span_id are extracted and included in JSON.
#   Scoped wrappers: _log_with_trace / _log_with_span.
#
# Refs: #423, OTel Logs Data Model, W3C Trace Context.

if [[ -n "${_DOCKER_LIB_LOG_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_LOG_SOURCED=1

readonly _LOG_LIB_DIR="${BASH_SOURCE[0]%/*}"
readonly _LOG_EVENTS_FILE="${_LOG_LIB_DIR}/log-events.txt"

# ── Event registry ─────────────────────────────────────────────────

_log_is_registered() {
  [[ -n "${1}" ]] && [[ -f "${_LOG_EVENTS_FILE}" ]] && \
    grep -v '^[[:space:]]*#' "${_LOG_EVENTS_FILE}" | grep -v '^[[:space:]]*$' | grep -Fxq "${1}" 2>/dev/null
}

# ── JSON helpers ───────────────────────────────────────────────────

_log_json_escape() {
  local s="${1}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  printf '%s' "${s}"
}

_log_emit_json() {
  local severity_text="${1}"
  local severity_number="${2}"
  local service="${3}"
  local body="${4}"
  shift 4

  local timestamp
  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%S.%NZ' 2>/dev/null \
    || date -u '+%Y-%m-%dT%H:%M:%SZ')"

  local trace_id="" span_id=""
  if [[ -n "${TRACEPARENT:-}" ]]; then
    IFS=- read -r _ trace_id span_id _ <<< "${TRACEPARENT}"
  fi

  local caller_file="${BASH_SOURCE[2]:-unknown}"
  local caller_line="${BASH_LINENO[1]:-0}"

  local attrs=""
  attrs+="\"service.name\":\"$(_log_json_escape "${service}")\""
  attrs+=",\"service.lang\":\"bash\""
  attrs+=",\"code.filepath\":\"$(_log_json_escape "${caller_file}")\""
  attrs+=",\"code.lineno\":${caller_line}"
  attrs+=",\"thread.id\":\"$$\""

  local kv
  for kv in "$@"; do
    local k="${kv%%=*}"
    local v="${kv#*=}"
    attrs+=",\"$(_log_json_escape "${k}")\":\"$(_log_json_escape "${v}")\""
  done

  local json="{"
  json+="\"timestamp\":\"${timestamp}\""
  json+=",\"severity_text\":\"${severity_text}\""
  json+=",\"severity_number\":${severity_number}"
  json+=",\"body\":\"$(_log_json_escape "${body}")\""
  if [[ -n "${trace_id}" ]]; then
    json+=",\"trace_id\":\"${trace_id}\""
    json+=",\"span_id\":\"${span_id}\""
  fi
  json+=",\"attributes\":{${attrs}}"
  json+="}"

  printf '%s\n' "${json}"
}

# ── Legacy text helpers (backward compat until P2) ─────────────────

_log_color_enabled() {
  local fd="${1:?_log_color_enabled requires fd}"
  [[ -z "${NO_COLOR:-}" ]] || return 1
  [[ -n "${FORCE_COLOR:-}" ]] && return 0
  test -t "${fd}"
}

_log_legacy_text() {
  local level="${1}" fd="${2}" tag="${3}"
  shift 3
  local label
  case "${level}" in
    ERROR)   label="ERROR" ;;
    WARN)    label="WARNING" ;;
    INFO)    label="INFO" ;;
    DEBUG)   label="DEBUG" ;;
    FATAL)   label="FATAL" ;;
  esac
  if [[ "${level}" == "ERROR" ]] && _log_color_enabled "${fd}"; then
    printf '\033[1;31m[%s] %s:\033[0m %s\n' "${tag}" "${label}" "$*" >&"${fd}"
  elif [[ "${level}" == "WARN" ]] && _log_color_enabled "${fd}"; then
    printf '\033[33m[%s] %s:\033[0m %s\n' "${tag}" "${label}" "$*" >&"${fd}"
  else
    printf '[%s] %s: %s\n' "${tag}" "${label}" "$*" >&"${fd}"
  fi
}

# ── Core dispatch ──────────────────────────────────────────────────

_log_dispatch() {
  local severity_text="${1}" severity_number="${2}" fd="${3}"
  local service="${4:?_log_${severity_text,,} requires service}"
  local body="${5:-}"
  shift 5 2>/dev/null || shift 4

  if _log_is_registered "${body}"; then
    _log_emit_json "${severity_text}" "${severity_number}" \
      "${service}" "${body}" "$@" >&"${fd}"
  elif [[ "${LOG_STRICT_BODY:-}" == "1" ]]; then
    printf '[log] FATAL: unregistered body "%s" (service=%s, level=%s). Add to %s or fix the caller.\n' \
      "${body}" "${service}" "${severity_text}" "${_LOG_EVENTS_FILE}" >&2
    return 1
  else
    _log_legacy_text "${severity_text}" "${fd}" "${service}" "${body}" "$@"
  fi
}

# ── Public API ─────────────────────────────────────────────────────

_log_debug() { _log_dispatch DEBUG 5 1 "$@"; }
_log_info()  { _log_dispatch INFO  9 1 "$@"; }
_log_warn()  { _log_dispatch WARN 13 2 "$@"; }
_log_err()   { _log_dispatch ERROR 17 2 "$@"; }
_log_fatal() { _log_dispatch FATAL 21 2 "$@"; }

# ── _log_plain (deprecated, removed in P2+) ────────────────────────

_log_plain() {
  local tag="${1:?_log_plain requires tag}"
  local style="${2-}"
  shift 2
  local prefix="" suffix=""
  if _log_color_enabled 1 && [[ -n "${style}" ]]; then
    case "${style}" in
      bold) prefix=$'\033[1m'; suffix=$'\033[0m' ;;
      dim)  prefix=$'\033[2m'; suffix=$'\033[0m' ;;
    esac
  fi
  printf '[%s] %s%s%s\n' "${tag}" "${prefix}" "$*" "${suffix}"
}

# ── TRACEPARENT scoped wrappers ────────────────────────────────────

_log_with_trace() {
  local _prev_tp="${TRACEPARENT:-}"
  local _trace_id
  _trace_id="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  local _span_id
  _span_id="$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  export TRACEPARENT="00-${_trace_id}-${_span_id}-01"
  printf '[trace started: %s]\n' "${_trace_id}" >&2
  "$@"
  local _rc=$?
  if [[ -n "${_prev_tp}" ]]; then
    export TRACEPARENT="${_prev_tp}"
  else
    unset TRACEPARENT
  fi
  return "${_rc}"
}

_log_with_span() {
  local _span_name="${1:?_log_with_span requires span_name}"
  shift
  local _prev_tp="${TRACEPARENT:-}"
  local _trace_id=""
  if [[ -n "${_prev_tp}" ]]; then
    IFS=- read -r _ _trace_id _ _ <<< "${_prev_tp}"
  else
    _trace_id="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  fi
  local _span_id
  _span_id="$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  export TRACEPARENT="00-${_trace_id}-${_span_id}-01"
  "$@"
  local _rc=$?
  if [[ -n "${_prev_tp}" ]]; then
    export TRACEPARENT="${_prev_tp}"
  else
    unset TRACEPARENT
  fi
  return "${_rc}"
}
