#!/usr/bin/env bash
#
# schema.sh — setup.conf validation registry + dispatcher (#560, epic #559).
#
# Single source of truth for "is this <section>.<key> = <value> valid?".
# Both setup.sh (the `set` / `add` subcommands, via _setup_validate_kv)
# and the TUI route their accept/reject decision through
# `_schema_validate`, so the two can no longer drift — the TUI can no
# longer accept input that setup.sh rejects, and vice versa.
#
# The registry only maps a canonical (section,key) to the NAME of the
# validator function; the validator bodies stay in _tui_conf.sh. This
# file sources _tui_conf.sh (idempotent via its own guard) so any
# consumer of schema.sh gets the validators without depending on
# _lib.sh's umbrella load order — mirrors how compose.sh /
# config_summary.sh pull in their lib deps.
#
# Style: Google Shell Style Guide.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_SCHEMA_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_SCHEMA_SOURCED=1

_schema_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=script/docker/lib/_tui_conf.sh
source "${_schema_dir}/_tui_conf.sh"
unset _schema_dir

# ════════════════════════════════════════════════════════════════════
# Registry
#
# Canonical key form:
#   scalar key -> "<section>.<key>"          (e.g. deploy.gpu_count)
#   list key   -> "<section>.<prefix>_"      (trailing underscore kept;
#                 the numbered suffix N is stripped before lookup, so
#                 network.port_1 / port_2 / ... all resolve to
#                 "network.port_")
#
# SCHEMA_VALIDATOR maps the canonical key to the validator function name.
# An unregistered key is free-form: _schema_validate accepts any value
# (matches setup.sh's historical default-accept behaviour).
# ════════════════════════════════════════════════════════════════════
declare -gA SCHEMA_VALIDATOR=(
  [deploy.gpu_count]=_validate_gpu_count
  [network.port_]=_validate_port_mapping
)

# SCHEMA_EMPTY records the per-key empty-value policy. Default (a key
# absent from this map) is "allow": an empty value clears the key and is
# always accepted. The exception is keys whose validator rejects empty by
# design — they are marked "validate" so the empty string is passed
# through to the validator (which rejects it).
declare -gA SCHEMA_EMPTY=(
  [deploy.gpu_count]=validate
)

# ════════════════════════════════════════════════════════════════════
# _schema_canonical_key <section> <key> <out_canon>
#
# Resolves (section,key) to its registry canonical key in <out_canon>,
# or the empty string when the key is free-form (not in the registry).
# Normalises per-service logging sections ([logging.<svc>] -> logging)
# and numbered list keys (port_3 -> port_).
# ════════════════════════════════════════════════════════════════════
_schema_canonical_key() {
  local _section="${1-}"
  local _key="${2-}"
  local -n _sck_out="${3:?_schema_canonical_key: missing out var}"

  # [logging.<svc>] per-service overrides share the [logging] key set.
  [[ "${_section}" == logging.* ]] && _section="logging"

  # Exact (scalar) match first.
  if [[ -v "SCHEMA_VALIDATOR[${_section}.${_key}]" ]]; then
    _sck_out="${_section}.${_key}"
    return 0
  fi

  # List match: strip a trailing _<digits> to the registered prefix.
  if [[ "${_key}" =~ ^(.+_)[0-9]+$ ]]; then
    local _pfx="${BASH_REMATCH[1]}"
    if [[ -v "SCHEMA_VALIDATOR[${_section}.${_pfx}]" ]]; then
      _sck_out="${_section}.${_pfx}"
      return 0
    fi
  fi

  _sck_out=""
  return 0
}

# ════════════════════════════════════════════════════════════════════
# _schema_validate <section> <key> <value>
#
# The single validation gate. Returns 0 when <value> is acceptable for
# <section>.<key>, non-zero otherwise. Free-form keys accept any value.
# ════════════════════════════════════════════════════════════════════
_schema_validate() {
  local _section="${1-}"
  local _key="${2-}"
  local _value="${3-}"

  local _canon
  _schema_canonical_key "${_section}" "${_key}" _canon

  # Free-form key: accept any value.
  [[ -z "${_canon}" ]] && return 0

  # Empty-value policy. Default "allow" (empty clears the key); only keys
  # marked "validate" delegate the empty string to their validator.
  local _policy="${SCHEMA_EMPTY[${_canon}]:-allow}"
  if [[ -z "${_value}" && "${_policy}" == "allow" ]]; then
    return 0
  fi

  "${SCHEMA_VALIDATOR[${_canon}]}" "${_value}"
}
