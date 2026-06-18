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
  # ── scalar keys ──────────────────────────────────────────────────
  [deploy.gpu_count]=_validate_gpu_count
  [deploy.gpu_runtime]=_validate_runtime
  [deploy.runtime]=_validate_runtime          # legacy alias (#481)
  [resources.shm_size]=_validate_shm_size
  [lifecycle.restart]=_validate_restart
  [build.target_arch]=_validate_target_arch
  [build.network]=_validate_build_network
  [network.network_name]=_validate_network_name
  [logging.driver]=_validate_log_driver
  [logging.max_size]=_validate_log_max_size
  [logging.max_file]=_validate_log_max_file
  [logging.compress]=_validate_log_compress
  [logging.local_path]=_validate_log_local_path
  [logging.wrapper_transcript]=_validate_wrapper_transcript
  [logging.wrapper_transcript_keep]=_validate_wrapper_transcript_keep
  [logging.wrapper_transcript_days]=_validate_wrapper_transcript_days
  # ── list keys (numbered suffix normalised to the trailing-_ prefix) ─
  [build.arg_]=_validate_env_kv
  [volumes.mount_]=_validate_mount
  [devices.device_]=_validate_mount
  [devices.cgroup_rule_]=_validate_cgroup_rule
  [environment.env_]=_validate_env_kv
  [network.port_]=_validate_port_mapping
  [additional_contexts.context_]=_validate_additional_context
  [security.cap_add_]=_validate_capability
  [security.cap_drop_]=_validate_capability
)

# ════════════════════════════════════════════════════════════════════
# SCHEMA_SECTIONS — the ordered list of setup.conf sections (#561).
#
# Single source for "which sections exist, in what order" (the order
# matches the setup.conf template headers). Consumers derive from this
# instead of hand-maintaining parallel section lists:
#   - setup.sh's _setup_known_section (via _schema_is_section)
#   - the TUI menu dispatch + CLI subcommand recognition
# so adding a section here makes it known/dispatchable without editing
# those call sites. Note some sections (image / gui / tmpfs) carry only
# free-form keys and so have no SCHEMA_VALIDATOR rows; the list is kept
# explicit rather than derived from the validator map so those sections
# are not dropped.
declare -ga SCHEMA_SECTIONS=(
  image build deploy lifecycle gui network security resources
  environment tmpfs devices volumes additional_contexts logging
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
# _schema_is_section <section>
#
# Returns 0 when <section> is one of the SCHEMA_SECTIONS, 1 otherwise.
# The single membership predicate consumers (setup.sh's
# _setup_known_section, the TUI dispatch) route through so the section
# list is not duplicated. Per-service [logging.<svc>] variants are NOT
# sections here -- that special case lives in _setup_known_section.
# ════════════════════════════════════════════════════════════════════
_schema_is_section() {
  local _s="${1-}"
  local _sec
  for _sec in "${SCHEMA_SECTIONS[@]}"; do
    [[ "${_sec}" == "${_s}" ]] && return 0
  done
  return 1
}

# ════════════════════════════════════════════════════════════════════
# _schema_section_keys <section> <outarray>
#
# Fills <outarray> with the registered key parts for <section>, derived
# from SCHEMA_VALIDATOR by canonical-key prefix. A scalar canonical key
# "<section>.<key>" yields "<key>"; a list key "<section>.<prefix>_"
# yields "<prefix>_" (trailing underscore kept). Free-form-only sections
# (image / gui / tmpfs) yield an empty array. Order is unspecified
# (associative-array iteration) -- callers that need a stable order sort.
# ════════════════════════════════════════════════════════════════════
_schema_section_keys() {
  local _section="${1-}"
  local -n _ssk_out="${2:?_schema_section_keys: missing out var}"
  _ssk_out=()
  local _canon
  for _canon in "${!SCHEMA_VALIDATOR[@]}"; do
    [[ "${_canon}" == "${_section}."* ]] && _ssk_out+=("${_canon#"${_section}".}")
  done
  return 0
}

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
