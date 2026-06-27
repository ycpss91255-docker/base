#!/usr/bin/env bash
#
# setup_conf.sh - setup.conf accessors (template+repo section-replace merge).
#
# The readers setup.sh and the other libs use to query the effective
# setup.conf: the per-section merge loader (_load_setup_conf), the parse-once
# handle model (_setup_conf_handle / _setup_load_merged_full) feeding the
# _conf_get / _conf_list_sorted accessors in lib/conf.sh, the convenience
# scalar/list getters (_get_conf_value / _get_conf_list_sorted), and the
# [image]-rule applicators (_rule_prefix / _rule_suffix / _rule_basename) used
# by detect_image_name.
#
# Extracted from setup.sh (ADR-00000014, epic decompose-setup-sh). The low-level
# _parse_ini_section + the handle accessors live in lib/conf.sh; this file is the
# setup.conf-path-resolving layer above them. Calls into _SETUP_SCRIPT_DIR +
# _parse_ini_section + the conf.sh accessors, all resolved at call-time via the
# _lib.sh load order.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_SETUP_CONF_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_SETUP_CONF_SOURCED=1

# ════════════════════════════════════════════════════════════════════
# INI parser for setup.conf
#
# _parse_ini_section moved to lib/conf.sh in (PR-B) so init.sh
# can reach it via _lib.sh without sourcing setup.sh. The function
# stays callable from this file via the same name (_lib.sh sources
# conf.sh in the umbrella loader near setup.sh's top).
# ════════════════════════════════════════════════════════════════════

# _load_setup_conf <base_path> <section> <keys_outvar> <values_outvar>
#
# Merges per-repo setup.conf with template default, section-replace
# strategy: if per-repo setup.conf has the section, use its entries;
# otherwise fall back to the template's section. SETUP_CONF env var forces
# a specific file (skips the merge entirely).
#
# collapsed back to 2-file model. <repo>/setup.conf is the user
# override (committed, not gitignored, survives template upgrade because
# template subtree pull never touches it — it lives outside .base).
_load_setup_conf() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local _section="${2:?"${FUNCNAME[0]}: missing section"}"
  local -n _lsc_keys="${3:?"${FUNCNAME[0]}: missing keys outvar"}"
  local -n _lsc_values="${4:?"${FUNCNAME[0]}: missing values outvar"}"

  # If SETUP_CONF is set, only read from it (no merge)
  if [[ -n "${SETUP_CONF:-}" ]]; then
    _parse_ini_section "${SETUP_CONF}" "${_section}" _lsc_keys _lsc_values
    return 0
  fi

  local _self_dir="${_SETUP_SCRIPT_DIR}"
  local _template_conf="${_self_dir}/../../../config/docker/setup.conf"
  local _repo_conf="${_base}/config/docker/setup.conf"

  # Try per-repo setup.conf first; if the section exists there, use it.
  if [[ -f "${_repo_conf}" ]]; then
    local -a __lsc_k=() __lsc_v=()
    _parse_ini_section "${_repo_conf}" "${_section}" __lsc_k __lsc_v
    if (( ${#__lsc_k[@]} > 0 )); then
      _lsc_keys=("${__lsc_k[@]}")
      _lsc_values=("${__lsc_v[@]}")
      return 0
    fi
  fi

  # Fall back to template default
  _parse_ini_section "${_template_conf}" "${_section}" _lsc_keys _lsc_values
}

# _setup_conf_handle <base> <handle>
#
# Load the effective setup.conf into an opaque conf.sh <handle>: honours the
# SETUP_CONF override (single file, no merge), otherwise the template +
# per-repo section-replace merge (same precedence as _load_setup_conf, but as
# one queryable handle for the _conf_get / _conf_list_sorted accessors). The
# single place that resolves the template / repo / SETUP_CONF paths for the
# accessor readers.
_setup_conf_handle() {
  local _base="${1:?"${FUNCNAME[0]}: missing base"}"
  local _h="${2:?"${FUNCNAME[0]}: missing handle"}"
  if [[ -n "${SETUP_CONF:-}" ]]; then
    _conf_load "${SETUP_CONF}" "${_h}"
    return 0
  fi
  _conf_load_merged \
    "${_SETUP_SCRIPT_DIR}/../../../config/docker/setup.conf" \
    "${_base}/config/docker/setup.conf" \
    "${_h}"
}

# _setup_load_merged_full <template_path> <local_path> \
#                         <sections_outvar> <keys_outvar> <values_outvar>
#
# Returns the section-replace merged view of <template_path> overlaid by
# <local_path>: for each section present in .local, the template's
# entries for that section are replaced wholesale by .local's entries;
# sections .local omits keep template values.
#
# Output arrays mirror `_load_setup_conf_full` shape: sections list +
# parallel `<section>.<key>` and value arrays. Used by `show`/`list` so
# users see effective post-apply values without having to re-run apply
# after every set/add/remove.
#
# replaces direct reads of <base>/setup.conf in show/list, since
# setup.conf is now the materialized output of apply (potentially stale
# until the next apply).
_setup_load_merged_full() {
  local _tpl="${1:?}"
  local _loc="${2:?}"
  local -n _slm_sections="${3:?}"
  local -n _slm_keys="${4:?}"
  local -n _slm_values="${5:?}"

  _slm_sections=()
  _slm_keys=()
  _slm_values=()

  local -a _tpl_sects=() _tpl_keys=() _tpl_vals=()
  local -a _loc_sects=() _loc_keys=() _loc_vals=()
  if [[ -f "${_tpl}" ]]; then
    _load_setup_conf_full "${_tpl}" _tpl_sects _tpl_keys _tpl_vals
  fi
  if [[ -f "${_loc}" ]]; then
    _load_setup_conf_full "${_loc}" _loc_sects _loc_keys _loc_vals
  fi

  # Sections appearing only in template, in template order, then any
  # section in .local that template lacks.
  local _s
  for _s in "${_tpl_sects[@]}"; do
    _slm_sections+=("${_s}")
  done
  for _s in "${_loc_sects[@]}"; do
    local _seen=0 _e
    for _e in "${_slm_sections[@]}"; do
      [[ "${_e}" == "${_s}" ]] && { _seen=1; break; }
    done
    (( _seen )) || _slm_sections+=("${_s}")
  done

  # For each section in the union: if .local has it, copy .local's
  # entries (replace strategy); else copy template's entries.
  local _sec _i _ns
  for _sec in "${_slm_sections[@]}"; do
    local _local_has=0
    for _e in "${_loc_sects[@]}"; do
      [[ "${_e}" == "${_sec}" ]] && { _local_has=1; break; }
    done
    if (( _local_has )); then
      for (( _i=0; _i<${#_loc_keys[@]}; _i++ )); do
        _ns="${_loc_keys[_i]}"
        if [[ "${_ns}" == "${_sec}."* ]]; then
          _slm_keys+=("${_ns}")
          _slm_values+=("${_loc_vals[_i]}")
        fi
      done
    else
      for (( _i=0; _i<${#_tpl_keys[@]}; _i++ )); do
        _ns="${_tpl_keys[_i]}"
        if [[ "${_ns}" == "${_sec}."* ]]; then
          _slm_keys+=("${_ns}")
          _slm_values+=("${_tpl_vals[_i]}")
        fi
      done
    fi
  done
}

# _get_conf_value <keys_ref> <values_ref> <key> <default> <outvar>
#
# Returns the value for <key> in the parallel arrays; <default> if missing.
_get_conf_value() {
  local -n _gcv_keys="${1:?}"
  local -n _gcv_values="${2:?}"
  local _key="${3:?}"
  local _default="${4-}"
  local -n _gcv_out="${5:?}"

  local i
  for (( i=0; i<${#_gcv_keys[@]}; i++ )); do
    if [[ "${_gcv_keys[i]}" == "${_key}" ]]; then
      _gcv_out="${_gcv_values[i]}"
      return 0
    fi
  done
  _gcv_out="${_default}"
}

# _get_conf_list_sorted <keys_ref> <values_ref> <prefix> <outvar_array>
#
# Collects entries whose key starts with <prefix> (e.g. "mount_") and sorts
# by the numeric suffix. Returns VALUES in sorted order.
_get_conf_list_sorted() {
  local -n _gcls_keys="${1:?}"
  local -n _gcls_values="${2:?}"
  local _prefix="${3:?}"
  local -n _gcls_out="${4:?}"

  _gcls_out=()
  local -a __gcls_pairs=()
  local i __gcls_k __gcls_num
  for (( i=0; i<${#_gcls_keys[@]}; i++ )); do
    __gcls_k="${_gcls_keys[i]}"
    if [[ "${__gcls_k}" == "${_prefix}"* ]]; then
      __gcls_num="${__gcls_k#"${_prefix}"}"
      # Only numeric suffixes participate; empty values mean opt-out
      [[ "${__gcls_num}" =~ ^[0-9]+$ ]] || continue
      [[ -z "${_gcls_values[i]}" ]] && continue
      __gcls_pairs+=("${__gcls_num}:${_gcls_values[i]}")
    fi
  done

  # Sort by numeric prefix before ":"
  if (( ${#__gcls_pairs[@]} > 0 )); then
    local __gcls_sorted
    __gcls_sorted=$(printf '%s\n' "${__gcls_pairs[@]}" | sort -t: -k1,1n)
    while IFS= read -r __gcls_k; do
      _gcls_out+=("${__gcls_k#*:}")
    done <<< "${__gcls_sorted}"
  fi
}

# ════════════════════════════════════════════════════════════════════
# Rule applicators for [image] rules (used by detect_image_name)
# ════════════════════════════════════════════════════════════════════

_rule_prefix() {
  local _path="$1" _value="$2"
  local -a _parts=()
  IFS='/' read -ra _parts <<< "${_path}"
  local i _part _last=""
  for (( i=${#_parts[@]}-1; i>=0; i-- )); do
    _part="${_parts[i]}"
    [[ -z "${_part}" ]] && continue
    _last="${_part}"
    break
  done
  if [[ "${_last}" == "${_value}"* ]]; then
    echo "${_last#"${_value}"}"
  fi
}

_rule_suffix() {
  local _path="$1" _value="$2"
  local -a _parts=()
  IFS='/' read -ra _parts <<< "${_path}"
  local i _part
  for (( i=${#_parts[@]}-1; i>=0; i-- )); do
    _part="${_parts[i]}"
    [[ -z "${_part}" ]] && continue
    if [[ "${_part}" == *"${_value}" ]]; then
      echo "${_part%"${_value}"}"
      return
    fi
  done
}

_rule_basename() {
  local _path="$1"
  local -a _parts=()
  IFS='/' read -ra _parts <<< "${_path}"
  local i _part
  for (( i=${#_parts[@]}-1; i>=0; i-- )); do
    _part="${_parts[i]}"
    [[ -z "${_part}" ]] && continue
    echo "${_part}"
    return
  done
}
