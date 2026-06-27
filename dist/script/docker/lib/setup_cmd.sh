#!/usr/bin/env bash
#
# setup_cmd.sh - the `setup` user-facing subcommands.
#
# The set / show / list / add / remove / reset / apply / deploy verbs that
# setup.sh's main dispatches, plus their validation helpers
# (_setup_known_section, _setup_validate_kv). apply orchestrates the
# compose render (lib/compose_emit.sh) + env write; deploy drives the field
# bundle (lib/deploy.sh).
#
# Extracted from setup.sh (ADR-00000014, epic decompose-setup-sh). Calls into
# setup.sh-resident helpers (detection, resolvers, write_env, drift,
# _setup_msg, _SETUP_SCRIPT_DIR), the extracted deploy.sh / compose_emit.sh,
# and conf.sh / schema.sh; all resolve at call-time via the _lib.sh load order.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_SETUP_CMD_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_SETUP_CMD_SOURCED=1

# ════════════════════════════════════════════════════════════════════
# _setup_known_section <section>
#
# Returns 0 when <section> is one of the known setup.conf section
# names, 1 otherwise. Derives the base section list from the schema
# registry (SCHEMA_SECTIONS, via _schema_is_section) so adding a section
# there makes it known here without a parallel edit. The
# per-service [logging.<svc>] override is the one shape the registry
# does not model, so it stays an explicit special case.
# ════════════════════════════════════════════════════════════════════
_setup_known_section() {
  local _s="${1-}"
  _schema_is_section "${_s}" && return 0
  case "${_s}" in
    logging.?*)
      # Per-service override section [logging.<svc>] -- shape only;
      # `<svc>` must be non-empty (rejects `logging.` trailing-dot).
      # Caller decides whether <svc> matches a real Dockerfile stage.
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# ════════════════════════════════════════════════════════════════════
# _setup_validate_kv <section> <key> <value>
#
# Thin adapter over the shared validation registry. The accept /
# reject decision for every typed key now lives in lib/schema.sh's
# `_schema_validate`, which both this `set` / `add` path AND the TUI
# route through -- so the two can no longer drift. Free-form keys (not in
# the registry) accept any value; empty-value (clear-key) semantics and
# per-service [logging.<svc>] normalisation are handled there.
#
# Note: this unifies the rule set. Keys the TUI already validated but
# setup.sh historically accepted (build.target_arch / build.build_network
# / deploy.gpu_runtime + legacy runtime alias / network.name /
# devices.device_* / security.cap_add_* / cap_drop_*) are now rejected by
# `set` / `add` too.
# ════════════════════════════════════════════════════════════════════
_setup_validate_kv() {
  _schema_validate "${1-}" "${2-}" "${3-}"
}

# ════════════════════════════════════════════════════════════════════
# _setup_set
#
# Subcommand handler for `setup.sh set <section>.<key> <value>`.
# Validates section + (where applicable) value, then upserts via
# `_upsert_conf_value` from `_tui_conf.sh` so behaviour matches the
# TUI's Save path. Does NOT regenerate .env — the user invokes
# `apply` explicitly when they want the derived artifacts refreshed.
#
# Usage: _setup_set <section>.<key> <value> [--base-path PATH]
#                                           [--lang LANG] [-q|--quiet]
# ════════════════════════════════════════════════════════════════════
_setup_set() {
  local _base_path=""
  local _spec="" _value="" _have_value=0
  local _quiet=0

  while [[ $# -gt 0 ]]; do
    # Once <spec> is captured the next bare arg is the value, even if
    # it starts with '-' (e.g. `set deploy.gpu_count -1` exercises an
    # invalid value path that the validator must reject — not a flag).
    if [[ -n "${_spec}" && "${_have_value}" -eq 0 ]]; then
      case "$1" in
        --base-path|--lang|-q|--quiet|-h|--help)
          ;;
        *)
          _value="$1"; _have_value=1; shift
          continue
          ;;
      esac
    fi
    case "$1" in
      -h|--help)
        usage
        ;;
      --base-path)
        _base_path="${2:?"--base-path requires a value"}"
        shift 2
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "setup"
        shift 2
        ;;
      -q|--quiet)
        _quiet=1
        shift
        ;;
      --)
        shift
        if [[ $# -gt 0 && -z "${_spec}" ]]; then
          _spec="$1"; shift
        fi
        if [[ $# -gt 0 && "${_have_value}" -eq 0 ]]; then
          _value="$1"; _have_value=1; shift
        fi
        ;;
      -*)
        _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
        return 1
        ;;
      *)
        if [[ -z "${_spec}" ]]; then
          _spec="$1"
        elif [[ "${_have_value}" -eq 0 ]]; then
          _value="$1"; _have_value=1
        else
          _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
          return 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "${_spec}" || "${_have_value}" -eq 0 ]]; then
    _setup_msg usage set >&2
    return 1
  fi

  # Split <section>.<key>; the first '.' is the separator. The only
  # sub-section pattern is [logging.<svc>] (per-service override), so
  # `logging.<svc>.<key>` is split as section=`logging.<svc>`,
  # key=`<key>` (rightmost-dot). All other shapes use first-dot.
  if [[ "${_spec}" != *.* ]]; then
    _setup_msg usage set >&2
    return 1
  fi
  local _section _key
  if [[ "${_spec}" == logging.*.* ]]; then
    _section="${_spec%.*}"
    _key="${_spec##*.}"
  else
    _section="${_spec%%.*}"
    _key="${_spec#*.}"
  fi
  if [[ -z "${_section}" || -z "${_key}" ]]; then
    _setup_msg usage set >&2
    return 1
  fi

  if ! _setup_known_section "${_section}"; then
    _log_err setup conf_section_not_found "display=$(_setup_msg errors unknown_section): ${_section}" "section=${_section}"
    return 2
  fi

  if ! _setup_validate_kv "${_section}" "${_key}" "${_value}"; then
    _log_err setup conf_invalid_value "display=$(_setup_msg errors invalid_value): ${_section}.${_key} = ${_value}" "section=${_section}" "key=${_key}" "value=${_value}"
    return 2
  fi

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../../../.." && pwd -P)"
  fi

  # Writes target the per-repo override file (setup.conf). Bootstrap
  # as empty when missing — `set` records only the user's intent, never
  # copies template defaults wholesale.
  local _conf="${_base_path}/config/docker/setup.conf"
  if [[ ! -f "${_conf}" ]]; then
    : > "${_conf}"
  fi

  # Propagate writer refusal (e.g. a newline-bearing value) instead
  # of printing a misleading success message over a no-op / partial write.
  if ! _upsert_conf_value "${_conf}" "${_section}" "${_key}" "${_value}"; then
    _log_err setup conf_write_failed "display=$(_setup_msg errors invalid_value): ${_section}.${_key}" "section=${_section}" "key=${_key}"
    return 2
  fi

  if [[ "${_quiet}" -eq 0 ]]; then
    printf '[setup] set [%s] %s = %s\n' "${_section}" "${_key}" "${_value}"
    printf '[setup] file: %s\n' "${_conf}"
    printf "[setup] next: run 'just build' (auto-applies) or './setup.sh apply' to regenerate .env + compose.yaml\n"
  fi
}

# ════════════════════════════════════════════════════════════════════
# _setup_show
#
# Subcommand handler for `setup.sh show <section>[.<key>]`. Reads
# <base-path>/setup.conf via `_load_setup_conf_full` so output stays
# aligned with the TUI's view of the file (preserves on-disk order,
# strips comments).
#
# Output:
#   show <section>.<key>  → single line with the value
#   show <section>        → "<key> = <value>" lines, on-disk order
# Returns 1 when the requested section or key is absent.
#
# Usage: _setup_show <section>[.<key>] [--base-path PATH] [--lang LANG]
# ════════════════════════════════════════════════════════════════════
_setup_show() {
  local _base_path=""
  local _spec=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        ;;
      --base-path)
        _base_path="${2:?"--base-path requires a value"}"
        shift 2
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "setup"
        shift 2
        ;;
      -*)
        _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
        return 1
        ;;
      *)
        if [[ -z "${_spec}" ]]; then
          _spec="$1"
        else
          _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
          return 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "${_spec}" ]]; then
    _setup_msg usage show >&2
    return 1
  fi

  local _section _key
  if [[ "${_spec}" == logging.*.* ]]; then
    # [logging.<svc>] sub-section: section is `logging.<svc>`, key is
    # the rightmost dot-delimited segment.
    _section="${_spec%.*}"
    _key="${_spec##*.}"
  elif [[ "${_spec}" == *.* ]]; then
    _section="${_spec%%.*}"
    _key="${_spec#*.}"
  else
    _section="${_spec}"
    _key=""
  fi

  if ! _setup_known_section "${_section}"; then
    _log_err setup conf_section_not_found "display=$(_setup_msg errors unknown_section): ${_section}" "section=${_section}"
    return 2
  fi

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../../../.." && pwd -P)"
  fi

  # show reads the merged view (template baseline ← repo override).
  # This is what `apply` would produce, so users see effective values
  # without having to re-run apply after every set/add/remove.
  local _repo_conf="${_base_path}/config/docker/setup.conf"
  local _tpl_conf="${_SETUP_SCRIPT_DIR}/../../../config/docker/setup.conf"
  local -a _ss_sections=() _ss_keys=() _ss_values=()
  _setup_load_merged_full "${_tpl_conf}" "${_repo_conf}" \
      _ss_sections _ss_keys _ss_values

  local _i _ns_key="${_section}.${_key}"
  if [[ -n "${_key}" ]]; then
    for (( _i=0; _i<${#_ss_keys[@]}; _i++ )); do
      if [[ "${_ss_keys[_i]}" == "${_ns_key}" ]]; then
        printf '%s\n' "${_ss_values[_i]}"
        return 0
      fi
    done
    _log_err setup conf_key_not_found "display=$(_setup_msg errors key_not_found): ${_ns_key}" "key=${_ns_key}"
    return 1
  fi

  # Whole-section dump.
  local _printed=0
  for (( _i=0; _i<${#_ss_keys[@]}; _i++ )); do
    if [[ "${_ss_keys[_i]}" == "${_section}."* ]]; then
      printf '%s = %s\n' "${_ss_keys[_i]#"${_section}".}" "${_ss_values[_i]}"
      _printed=1
    fi
  done
  if (( _printed == 0 )); then
    _log_err setup conf_section_not_found "display=$(_setup_msg errors section_not_found): ${_section}" "section=${_section}"
    return 1
  fi
  return 0
}

# ════════════════════════════════════════════════════════════════════
# _setup_list
#
# Subcommand handler for `setup.sh list [<section>]`. Without an arg,
# prints the entire setup.conf (in on-disk order, comments stripped)
# as INI-style sections separated by blank lines — suitable for piping
# into other tooling. With a <section> arg, behaves like `show`.
#
# Usage: _setup_list [<section>] [--base-path PATH] [--lang LANG]
# ════════════════════════════════════════════════════════════════════
_setup_list() {
  local _base_path=""
  local _spec=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        ;;
      --base-path)
        _base_path="${2:?"--base-path requires a value"}"
        shift 2
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "setup"
        shift 2
        ;;
      -*)
        _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
        return 1
        ;;
      *)
        if [[ -z "${_spec}" ]]; then
          _spec="$1"
        else
          _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
          return 1
        fi
        shift
        ;;
    esac
  done

  if [[ -n "${_spec}" ]]; then
    # list <section> aliases show <section> for now (B-2 keeps them
    # equivalent; future iterations may differentiate keys-only vs
    # keys+values).
    if [[ -n "${_base_path}" ]]; then
      _setup_show "${_spec}" --base-path "${_base_path}" --lang "${_LANG}"
    else
      _setup_show "${_spec}" --lang "${_LANG}"
    fi
    return $?
  fi

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../../../.." && pwd -P)"
  fi

  # list reads the merged view (template ← repo override) — same
  # rationale as `show`. Reflects what `apply` would materialize.
  local _repo_conf="${_base_path}/config/docker/setup.conf"
  local _tpl_conf="${_SETUP_SCRIPT_DIR}/../../../config/docker/setup.conf"
  local -a _ll_sections=() _ll_keys=() _ll_values=()
  _setup_load_merged_full "${_tpl_conf}" "${_repo_conf}" \
      _ll_sections _ll_keys _ll_values

  local _si _ki _sect _first=1
  for _sect in "${_ll_sections[@]}"; do
    if (( _first )); then
      _first=0
    else
      printf '\n'
    fi
    printf '[%s]\n' "${_sect}"
    for (( _ki=0; _ki<${#_ll_keys[@]}; _ki++ )); do
      if [[ "${_ll_keys[_ki]}" == "${_sect}."* ]]; then
        printf '%s = %s\n' "${_ll_keys[_ki]#"${_sect}".}" "${_ll_values[_ki]}"
      fi
    done
  done
}

# ════════════════════════════════════════════════════════════════════
# _setup_add
#
# Subcommand handler for `setup.sh add <section>.<list> <value>`.
# Finds the next available numeric suffix N (max-existing + 1, or 1
# when the section has no entries with that prefix) and writes
# `<list>_N = <value>` via `_upsert_conf_value`. Bootstraps setup.conf
# from the template default if absent so first-time users can `add`
# before they ever ran `apply`. Validators fire through
# `_setup_validate_kv` against the synthesized key, so e.g.
# `add volumes.mount` enforces the same `_validate_mount` that
# `set volumes.mount_3` does. Does NOT regenerate .env.
#
# Numbering uses max+1 (never fills gaps left by remove). Predictable
# for tooling; matches the TUI's `_edit_list_section` "next slot"
# behaviour.
#
# Usage: _setup_add <section>.<list> <value>
#                   [--base-path PATH] [--lang LANG]
# ════════════════════════════════════════════════════════════════════
_setup_add() {
  local _base_path=""
  local _spec="" _value="" _have_value=0
  local _quiet=0

  while [[ $# -gt 0 ]]; do
    # Once <spec> is captured, the next bare arg is the value, even if
    # it begins with '-' (e.g. negative numbers shouldn't be parsed as
    # flags). Same shape as _setup_set.
    if [[ -n "${_spec}" && "${_have_value}" -eq 0 ]]; then
      case "$1" in
        --base-path|--lang|-q|--quiet|-h|--help)
          ;;
        *)
          _value="$1"; _have_value=1; shift
          continue
          ;;
      esac
    fi
    case "$1" in
      -h|--help)
        usage
        ;;
      --base-path)
        _base_path="${2:?"--base-path requires a value"}"
        shift 2
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "setup"
        shift 2
        ;;
      -q|--quiet)
        _quiet=1
        shift
        ;;
      --)
        shift
        if [[ $# -gt 0 && -z "${_spec}" ]]; then
          _spec="$1"; shift
        fi
        if [[ $# -gt 0 && "${_have_value}" -eq 0 ]]; then
          _value="$1"; _have_value=1; shift
        fi
        ;;
      -*)
        _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
        return 1
        ;;
      *)
        if [[ -z "${_spec}" ]]; then
          _spec="$1"
        elif [[ "${_have_value}" -eq 0 ]]; then
          _value="$1"; _have_value=1
        else
          _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
          return 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "${_spec}" || "${_have_value}" -eq 0 ]]; then
    _setup_msg usage add >&2
    return 1
  fi

  if [[ "${_spec}" != *.* ]]; then
    _setup_msg usage add >&2
    return 1
  fi
  local _section="${_spec%%.*}"
  local _list="${_spec#*.}"
  if [[ -z "${_section}" || -z "${_list}" ]]; then
    _setup_msg usage add >&2
    return 1
  fi

  if ! _setup_known_section "${_section}"; then
    _log_err setup conf_section_not_found "display=$(_setup_msg errors unknown_section): ${_section}" "section=${_section}"
    return 2
  fi

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../../../.." && pwd -P)"
  fi
  # Writes target the per-repo override (setup.conf); bootstrap as
  # empty when missing — `add` records only the user's intent.
  local _conf="${_base_path}/config/docker/setup.conf"
  if [[ ! -f "${_conf}" ]]; then
    : > "${_conf}"
  fi

  # Scan keys[] for "<section>.<list>_<digits>". Pick the first slot
  # whose value is empty (reuses placeholder slots from the template
  # default, matches the TUI's `_edit_list_section` behaviour); fall
  # back to max+1 when every populated slot has content. Reads the
  # merged effective view (template ← repo override) so the new index
  # lands past any inherited template slot the user hasn't yet bumped.
  local -a _sects=() _keys=() _vals=()
  local -a _local_k=() _local_v=()
  local _tpl_conf="${_SETUP_SCRIPT_DIR}/../../../config/docker/setup.conf"
  _parse_ini_section "${_conf}" "${_section}" _local_k _local_v
  if (( ${#_local_k[@]} > 0 )); then
    # Override section present — replace strategy: only .local entries
    # exist for this section.
    local _li
    for (( _li=0; _li<${#_local_k[@]}; _li++ )); do
      _keys+=("${_section}.${_local_k[_li]}")
      _vals+=("${_local_v[_li]}")
    done
  elif [[ -f "${_tpl_conf}" ]]; then
    # Fall back to template baseline so max-suffix matches what the
    # merged view would produce.
    local -a _tpl_k=() _tpl_v=()
    _parse_ini_section "${_tpl_conf}" "${_section}" _tpl_k _tpl_v
    local _ti
    for (( _ti=0; _ti<${#_tpl_k[@]}; _ti++ )); do
      _keys+=("${_section}.${_tpl_k[_ti]}")
      _vals+=("${_tpl_v[_ti]}")
    done
  fi
  local _max=0 _empty_idx="" _i _k _suffix
  for (( _i=0; _i<${#_keys[@]}; _i++ )); do
    _k="${_keys[_i]}"
    if [[ "${_k}" == "${_section}.${_list}_"* ]]; then
      _suffix="${_k##*_}"
      if [[ "${_suffix}" =~ ^[0-9]+$ ]]; then
        if (( _suffix > _max )); then
          _max="${_suffix}"
        fi
        if [[ -z "${_empty_idx}" && -z "${_vals[_i]}" ]]; then
          _empty_idx="${_suffix}"
        fi
      fi
    fi
  done
  local _new_idx
  if [[ -n "${_empty_idx}" ]]; then
    _new_idx="${_empty_idx}"
  else
    _new_idx=$(( _max + 1 ))
  fi
  local _new_key="${_list}_${_new_idx}"

  if ! _setup_validate_kv "${_section}" "${_new_key}" "${_value}"; then
    _log_err setup conf_invalid_value "display=$(_setup_msg errors invalid_value): ${_section}.${_new_key} = ${_value}" "section=${_section}" "key=${_new_key}" "value=${_value}"
    return 2
  fi

  if ! _upsert_conf_value "${_conf}" "${_section}" "${_new_key}" "${_value}"; then
    _log_err setup conf_write_failed "display=$(_setup_msg errors invalid_value): ${_section}.${_new_key}" "section=${_section}" "key=${_new_key}"
    return 2
  fi

  if [[ "${_quiet}" -eq 0 ]]; then
    printf '[setup] add [%s] %s = %s\n' "${_section}" "${_new_key}" "${_value}"
    printf '[setup] file: %s\n' "${_conf}"
    printf "[setup] next: run 'just build' (auto-applies) or './setup.sh apply' to regenerate .env + compose.yaml\n"
  fi
}

# ════════════════════════════════════════════════════════════════════
# _setup_remove
#
# Two argument forms:
#   1) remove <section>.<key>           — delete that exact key
#   2) remove <section>.<list> <value>  — delete the FIRST key under
#      <section> matching `<list>_*` whose value equals <value>
#
# Form is selected by argc: a second positional arg switches to
# remove-by-value mode. Removes one entry per invocation; multiple
# matches keep the rest (call again to peel further). Preserves
# comments + ordering via `_write_setup_conf`. Does NOT regenerate
# .env. Does NOT renumber remaining keys (`_load_setup_conf_full`
# tolerates gaps, and downstream callers treat the prefix list as
# unordered).
#
# Usage: _setup_remove <section>.<key>            [--base-path] [--lang]
#        _setup_remove <section>.<list> <value>   [--base-path] [--lang]
# ════════════════════════════════════════════════════════════════════
_setup_remove() {
  local _base_path=""
  local _spec="" _value="" _have_value=0
  local _quiet=0

  while [[ $# -gt 0 ]]; do
    if [[ -n "${_spec}" && "${_have_value}" -eq 0 ]]; then
      case "$1" in
        --base-path|--lang|-q|--quiet|-h|--help)
          ;;
        *)
          _value="$1"; _have_value=1; shift
          continue
          ;;
      esac
    fi
    case "$1" in
      -h|--help)
        usage
        ;;
      --base-path)
        _base_path="${2:?"--base-path requires a value"}"
        shift 2
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "setup"
        shift 2
        ;;
      -q|--quiet)
        _quiet=1
        shift
        ;;
      --)
        shift
        if [[ $# -gt 0 && -z "${_spec}" ]]; then
          _spec="$1"; shift
        fi
        if [[ $# -gt 0 && "${_have_value}" -eq 0 ]]; then
          _value="$1"; _have_value=1; shift
        fi
        ;;
      -*)
        _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
        return 1
        ;;
      *)
        if [[ -z "${_spec}" ]]; then
          _spec="$1"
        elif [[ "${_have_value}" -eq 0 ]]; then
          _value="$1"; _have_value=1
        else
          _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
          return 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "${_spec}" || "${_spec}" != *.* ]]; then
    _setup_msg usage remove >&2
    return 1
  fi
  local _section _rest
  if [[ "${_spec}" == logging.*.* ]]; then
    _section="${_spec%.*}"
    _rest="${_spec##*.}"
  else
    _section="${_spec%%.*}"
    _rest="${_spec#*.}"
  fi
  if [[ -z "${_section}" || -z "${_rest}" ]]; then
    _setup_msg usage remove >&2
    return 1
  fi

  if ! _setup_known_section "${_section}"; then
    _log_err setup conf_section_not_found "display=$(_setup_msg errors unknown_section): ${_section}" "section=${_section}"
    return 2
  fi

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../../../.." && pwd -P)"
  fi
  # remove only operates on the per-repo override. If setup.conf
  # doesn't exist, there's nothing to remove (template baseline isn't
  # a removable input).
  local _conf="${_base_path}/config/docker/setup.conf"
  if [[ ! -f "${_conf}" ]]; then
    _log_err setup conf_key_not_found "display=$(_setup_msg errors key_not_found): ${_spec}" "key=${_spec}"
    return 1
  fi

  local -a _sects=() _keys=() _vals=()
  _load_setup_conf_full "${_conf}" _sects _keys _vals

  local _target_key="" _i
  if (( _have_value )); then
    # Remove-by-value: scan for first <section>.<rest>_* with matching value.
    for (( _i=0; _i<${#_keys[@]}; _i++ )); do
      if [[ "${_keys[_i]}" == "${_section}.${_rest}_"* ]] \
         && [[ "${_vals[_i]}" == "${_value}" ]]; then
        _target_key="${_keys[_i]#"${_section}".}"
        break
      fi
    done
    if [[ -z "${_target_key}" ]]; then
      _log_err setup conf_key_not_found "display=$(_setup_msg errors key_not_found): ${_section}.${_rest} = ${_value}" "key=${_section}.${_rest}" "value=${_value}"
      return 1
    fi
  else
    # Remove-by-key: assert <section>.<rest> exists.
    local _found=0
    for (( _i=0; _i<${#_keys[@]}; _i++ )); do
      if [[ "${_keys[_i]}" == "${_section}.${_rest}" ]]; then
        _found=1
        break
      fi
    done
    if (( ! _found )); then
      _log_err setup conf_key_not_found "display=$(_setup_msg errors key_not_found): ${_spec}" "key=${_spec}"
      return 1
    fi
    _target_key="${_rest}"
  fi

  # _write_setup_conf truncates dst before reading tpl, so when dst==src
  # we'd lose data. Stage current contents into a sibling temp file and
  # use that as the read source.
  local _tmp
  _tmp="$(mktemp "${_conf}.XXXXXX")"
  cp "${_conf}" "${_tmp}"
  local -a _empty_s=() _empty_k=() _empty_v=()
  _write_setup_conf "${_conf}" "${_tmp}" \
    _empty_s _empty_k _empty_v "${_section}.${_target_key}"
  rm -f "${_tmp}"

  if [[ "${_quiet}" -eq 0 ]]; then
    printf '[setup] remove [%s] %s\n' "${_section}" "${_target_key}"
    printf '[setup] file: %s\n' "${_conf}"
    printf "[setup] next: run 'just build' (auto-applies) or './setup.sh apply' to regenerate .env + compose.yaml\n"
  fi
}

# ════════════════════════════════════════════════════════════════════
# _setup_reset
#
# Subcommand handler for `setup.sh reset [--yes]`. Overwrites the
# repo's setup.conf with the template default, archiving the prior
# setup.conf to setup.conf.bak and the prior .env to .env.bak so the
# user has a one-shot rollback path. Mirrors what `build.sh
# --reset-conf` does today, but exposes it as a setup.sh subcommand
# for scripted use.
#
# Does NOT regenerate .env. The user invokes `apply` afterwards (or
# build/run will trigger auto-regen via drift detection on the next
# invocation, since the conf hash will have changed).
#
# Without --yes, refuses to proceed when stdin is not a TTY (safety
# guard so accidental pipeline invocations don't destroy state).
# With --yes, skips the confirmation regardless of TTY.
#
# Usage: _setup_reset [--yes] [--base-path PATH] [--lang LANG]
# ════════════════════════════════════════════════════════════════════
_setup_reset() {
  local _base_path=""
  local _yes=0
  local _quiet=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        ;;
      -y|--yes)
        _yes=1
        shift
        ;;
      -q|--quiet)
        _quiet=1
        shift
        ;;
      --base-path)
        _base_path="${2:?"--base-path requires a value"}"
        shift 2
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "setup"
        shift 2
        ;;
      *)
        _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
        return 1
        ;;
    esac
  done

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../../../.." && pwd -P)"
  fi

  # reset clears the per-repo override (setup.conf) so the next `apply`
  # rebuilds .env.generated + compose.yaml purely from the template
  # baseline. The workspace mount_1 is re-detected and re-written via the
  # bootstrap path on the next apply. The hand-authored .env workload
  # overlay is user-owned and intentionally left untouched by reset.
  local _conf="${_base_path}/config/docker/setup.conf"
  local _env="${_base_path}/.env.generated"
  local _tpl_conf="${_SETUP_SCRIPT_DIR}/../../../config/docker/setup.conf"
  if [[ ! -f "${_tpl_conf}" ]]; then
    _log_err setup conf_template_missing "display=template setup.conf not found at ${_tpl_conf}" "path=${_tpl_conf}"
    return 1
  fi

  if (( ! _yes )); then
    if [[ ! -t 0 ]]; then
      _log_err setup conf_reset_needs_yes "display=$(_setup_msg reset needs_yes)"
      return 1
    fi
    printf "[setup] %s [y/N]: " "$(_setup_msg reset confirm)"
    local _ans=""
    read -r _ans
    case "${_ans}" in
      y|Y|yes|YES) ;;
      *)
        _log_warn setup conf_reset_aborted "display=$(_setup_msg reset aborted)"
        return 1
        ;;
    esac
  fi

  # Backup the existing per-repo override and the .env snapshot.
  if [[ -f "${_conf}" ]]; then
    cp -f "${_conf}" "${_conf}.bak"
    rm -f "${_conf}"
  fi
  if [[ -f "${_env}" ]]; then
    cp -f "${_env}" "${_env}.bak"
  fi

  if [[ "${_quiet}" -eq 0 ]]; then
    _log_info setup conf_reset "display=$(_setup_msg reset "done")"
    printf '[setup] file: %s\n' "${_conf}"
    printf "[setup] next: run 'just build' (auto-applies) or './setup.sh apply' to regenerate .env + compose.yaml\n"
  fi
}

# ════════════════════════════════════════════════════════════════════
# _setup_apply
#
# Subcommand handler for `setup.sh apply`. Regenerates .env +
# compose.yaml from setup.conf + system detection. Other subcommands
# (set/add/remove/reset) intentionally do NOT regen — apply is the
# explicit gate.
#
# Usage: _setup_apply [-h|--help] [--base-path <path>] [--lang <code>]
# ════════════════════════════════════════════════════════════════════
_setup_apply() {
  local _base_path=""
  local _quiet=0
  # per-invocation overrides. Empty means "use setup.conf /
  # SETUP_GUI env / built-in default" per the documented resolution
  # order CLI > env > conf > default.
  local _gui_override=""        # --gui=auto|force|off
  local _no_x11_cookie=0        # --no-x11-cookie
  local _print_resolved=0       # --print-resolved

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        ;;
      --base-path)
        _base_path="${2:?"--base-path requires a value"}"
        shift 2
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "setup"
        shift 2
        ;;
      -q|--quiet)
        _quiet=1
        shift
        ;;
      --gui)
        _gui_override="${2:?"--gui requires a value (auto|force|off)"}"
        shift 2
        ;;
      --gui=*)
        _gui_override="${1#--gui=}"
        shift
        ;;
      --no-x11-cookie)
        _no_x11_cookie=1
        shift
        ;;
      --print-resolved)
        _print_resolved=1
        shift
        ;;
      *)
        _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
        return 1
        ;;
    esac
  done

  # Validate --gui value early so the user sees the error before we
  # spend cycles on detections.
  if [[ -n "${_gui_override}" ]]; then
    case "${_gui_override}" in
      auto|force|off) ;;
      *)
        _log_err setup gui_override_invalid "display=$(_setup_msg errors invalid_value): --gui = ${_gui_override} (expected auto|force|off)" "value=${_gui_override}"
        return 2
        ;;
    esac
  fi

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../../../.." && pwd -P)"
  fi

  _announce_template_default_fallback "${_base_path}"

  # A2 file roles: .env.generated is the derived interpolation
  # cache written by setup.sh; .env is the hand-authored workload
  # overlay (never touched here after the first-apply scaffold).
  local _env_file="${_base_path}/.env.generated"
  local _overlay_file="${_base_path}/.env"

  # Migrate a layout where .env WAS the cache: if no
  # .env.generated exists yet but .env carries the setup.sh auto-gen
  # marker, it is a stale cache, not a user overlay. Back it up and
  # promote it to .env.generated so the prior-values source below still
  # resolves; write_env regenerates it and a fresh overlay is scaffolded.
  if [[ ! -f "${_env_file}" && -f "${_overlay_file}" ]] \
      && grep -q '^SETUP_CONF_HASH=' "${_overlay_file}" 2>/dev/null; then
    cp -- "${_overlay_file}" "${_overlay_file}.bak"
    mv -- "${_overlay_file}" "${_env_file}"
  fi

  if [[ -f "${_env_file}" ]]; then
    set -o allexport
    # shellcheck disable=SC1090
    source "${_env_file}"
    set +o allexport
  fi

  # ── Detections ──
  local user_name="" user_group="" user_uid="" user_gid=""
  local hardware="" docker_hub_user="" gpu_detected="" gui_detected="" image_name=""
  local ws_path="${WS_PATH:-}"

  detect_user_info       user_name user_group user_uid user_gid
  detect_hardware        hardware
  detect_docker_hub_user docker_hub_user
  detect_gpu             gpu_detected
  detect_gui             gui_detected
  BASE_PATH="${_base_path}" detect_image_name image_name "${_base_path}"

  # ── Load setup.conf sections ──
  # Only the sections apply still consumes directly are loaded here:
  # [build] (build args / target_arch), [volumes] (WS_PATH + extra_volumes),
  # [security] (the propagation guard re-reads privileged), and
  # [additional_contexts]. Every docker/build scalar + list-string the
  # compose call needs (gpu / gui / network / devices / env / tmpfs /
  # ports / caps / shm / restart / dri / build_network) is resolved by the
  # shared _resolve_deploy_context below (S6b,), which loads its own
  # sections -- the same resolver the deploy generator uses, so the field
  # deploy can never drift from apply.
  local -a _build_k=() _build_v=() _vol_k=() _vol_v=() _sec_k=() _sec_v=()
  local -a _ac_k=() _ac_v=()
  _load_setup_conf "${_base_path}" "build"               _build_k _build_v
  _load_setup_conf "${_base_path}" "volumes"             _vol_k _vol_v
  _load_setup_conf "${_base_path}" "security"            _sec_k _sec_v
  _load_setup_conf "${_base_path}" "additional_contexts" _ac_k   _ac_v

  # Build args: each `[build] arg_N = KEY=VALUE` entry becomes a
  # compose build.arg. Empty VALUE means "do not override" — let
  # compose.yaml's `${VAR:-<default>}` fallback pick the Dockerfile
  # default (archive.ubuntu.com for APT, Asia/Taipei for TZ, etc.).
  local -a _build_args=()
  _get_conf_list_sorted _build_k _build_v "arg_" _build_args

  # Back-compat: repos that still have the old named-key schema
  # (apt_mirror_ubuntu = …, tz = …) keep working without having to
  # rewrite setup.conf. We lift those named keys into the arg_N list
  # at runtime; the TUI saves in the new format the next time the
  # user hits Save.
  if (( ${#_build_args[@]} == 0 )); then
    local _bc_v=""
    _get_conf_value _build_k _build_v "apt_mirror_ubuntu" "" _bc_v
    [[ -n "${_bc_v}" ]] && _build_args+=("APT_MIRROR_UBUNTU=${_bc_v}")
    _bc_v=""
    _get_conf_value _build_k _build_v "apt_mirror_debian" "" _bc_v
    [[ -n "${_bc_v}" ]] && _build_args+=("APT_MIRROR_DEBIAN=${_bc_v}")
    _bc_v=""
    _get_conf_value _build_k _build_v "tz" "" _bc_v
    [[ -n "${_bc_v}" ]] && _build_args+=("TZ=${_bc_v}")
  fi

  # Extract specific known values that write_env + the hardcoded
  # compose.yaml build.args block reference by name. Anything not in
  # the known set is emitted as a generic user-added arg.
  local apt_mirror_ubuntu="" apt_mirror_debian="" tz=""
  local -a _user_build_args=()
  local _arg _k _v
  for _arg in "${_build_args[@]}"; do
    [[ "${_arg}" != *=* ]] && continue
    _k="${_arg%%=*}"
    _v="${_arg#*=}"
    case "${_k}" in
      APT_MIRROR_UBUNTU) apt_mirror_ubuntu="${_v}" ;;
      APT_MIRROR_DEBIAN) apt_mirror_debian="${_v}" ;;
      TZ)                tz="${_v}" ;;
      *)                 _user_build_args+=("${_k}=${_v}") ;;
    esac
  done

  # TARGETARCH override: scalar `[build] target_arch` sits alongside
  # the arg_N list. Empty = let BuildKit auto-fill from host /
  # --platform (no --build-arg passed, no compose build.arg emitted).
  # Non-empty = pin the value for cross-build or explicit control.
  local target_arch=""
  _get_conf_value _build_k _build_v "target_arch" "" target_arch

  # Build-time network override: scalar `[build] network`. Empty =
  # docker default (bridge). Non-empty = passed as `build.network` in
  # compose.yaml and `--network <value>` to the auxiliary test-tools
  # docker build. Typical value: `host`, for hosts whose docker bridge
  # NAT is unusable (stripped embedded kernels, iptables:false).
  # ── Resolve conf-derived docker/build params via the shared layer ──
  # S6b: _resolve_deploy_context is the single conf resolution that
  # both apply and the deploy generator use, so the field deploy never
  # drifts from what apply produces for the same setup.conf. Its record is
  # unpacked into the existing locals below; the --gui / SETUP_GUI override,
  # the detection-dependent enabled booleans, the WS_PATH / mount_1
  # migration, and the device/volume validation stay apply-side.
  local -A _dctx=()
  _resolve_deploy_context "${_base_path}" _dctx
  local build_network="${_dctx[build_network]}"
  local gpu_mode="${_dctx[gpu_mode]}"
  local gpu_count="${_dctx[gpu_count]}"
  local gpu_caps="${_dctx[gpu_caps]}"
  local gpu_runtime_mode="${_dctx[gpu_runtime_mode]}"
  local gui_mode="${_dctx[gui_mode]}"
  local net_mode="${_dctx[net_mode]}"
  local ipc_mode="${_dctx[ipc_mode]}"
  local pid_mode="${_dctx[pid_mode]}"
  local network_name="${_dctx[network_name]}"
  local privileged="${_dctx[privileged]}"
  local restart_policy="${_dctx[restart_policy]}"
  local dri_groups_str="${_dctx[dri_groups_str]}"

  # resolution order CLI > env > conf > default. The shared resolver
  # returns the conf gui_mode; layer the --gui / SETUP_GUI override on top.
  if [[ -n "${_gui_override}" ]]; then
    gui_mode="${_gui_override}"
  elif [[ -n "${SETUP_GUI:-}" ]]; then
    case "${SETUP_GUI}" in
      auto|force|off) gui_mode="${SETUP_GUI}" ;;
    esac
  fi

  # ── WS_PATH + workspace mount ──
  #
  # mount_1 can be:
  #   - `${WS_PATH}:/home/${USER_NAME}/work` — portable form (default
  #     since v0.9.4). docker-compose resolves ${WS_PATH} from .env on
  #     each machine. setup.sh re-runs detect_ws_path locally.
  #   - absolute host path — user pinned a specific directory. Honored
  #     as long as the path exists on this machine.
  #   - stale absolute path (baked from another machine, path absent
  #     locally) — warn, auto-migrate mount_1 back to the portable
  #     ${WS_PATH} form, and re-detect locally.
  #   - empty — user opted out; skip the mount but still detect WS_PATH
  #     so .env remains populated.
  #
  # First-time bootstrap (no <repo>/setup.conf) copies the template and
  # writes mount_1 in the portable form.
  local _repo_conf="${_base_path}/config/docker/setup.conf"
  # The WS_PATH / mount_1 reconciliation state machine. Mutates
  # _vol_k / _vol_v in place (reloaded after any mount_1 rewrite) and
  # resolves ws_path (seeded above from ${WS_PATH:-}).
  _reconcile_workspace_path "${_base_path}" "${_repo_conf}" _vol_k _vol_v ws_path

  # shellcheck disable=SC2034  # populated via nameref by _get_conf_list_sorted
  local -a extra_volumes=()
  _get_conf_list_sorted _vol_k _vol_v "mount_" extra_volumes

  # S4: structured app-config channel. When the repo ships a
  # config/app/ dir, dev-bind it into the container at a fixed path so
  # structured runtime config (e.g. ros1_bridge bridge topics) is
  # editable on the host with edit + restart, no rebuild. Convention over
  # configuration: the directory's presence is the only switch (no
  # setup.conf knob). The deploy flow (S6) COPY-bakes the same dir into
  # the field image instead (immutable artifact, ADR-00000003).
  # Emitted through the regular mount path so per-stage mount_inherit and
  # the top-level volumes: classifier (a ./ bind) apply uniformly.
  if [[ -d "${_base_path}/config/app" ]]; then
    extra_volumes+=("./config/app:/opt/app/config")
  fi

  # ── [devices] device_* + cgroup_rule_* (from the shared resolver) ──
  local _devices_str="${_dctx[devices_str]}"
  local _cgroup_rule_str="${_dctx[cgroup_rule_str]}"

  # ── P2: propagation + privileged guard ──
  if [[ -n "${_devices_str}" ]]; then
    local _has_prop=false _d_check
    while IFS= read -r _d_check; do
      [[ -z "${_d_check}" ]] && continue
      if _device_has_propagation "${_d_check}"; then
        _has_prop=true
        break
      fi
    done <<< "${_devices_str}"
    if [[ "${_has_prop}" == true ]]; then
      local _priv_val=""
      _get_conf_value _sec_k _sec_v "privileged" "" _priv_val
      if [[ "${_priv_val}" != "true" ]]; then
        _log_warn setup conf_invalid_value \
          "display=device entry uses mount propagation but [security] privileged is not true. Device I/O may be blocked by cgroup."
      fi
    fi
  fi

  # ── P4: duplicate device/volume target path detection ──
  if [[ -n "${_devices_str}" ]]; then
    local _d_dup
    while IFS= read -r _d_dup; do
      [[ -z "${_d_dup}" ]] && continue
      _device_has_propagation "${_d_dup}" || continue
      local -a _dup_parts=()
      IFS=':' read -ra _dup_parts <<< "${_d_dup}"
      local _dup_target="${_dup_parts[1]}"
      local _ev
      for _ev in "${extra_volumes[@]}"; do
        local -a _ev_parts=()
        IFS=':' read -ra _ev_parts <<< "${_ev}"
        if [[ "${_ev_parts[1]}" == "${_dup_target}" ]]; then
          _log_warn setup conf_invalid_value \
            "display=duplicate target path '${_dup_target}': appears in both [devices] (with propagation) and [volumes]. The [devices] entry with propagation takes precedence."
          break
        fi
      done
    done <<< "${_devices_str}"
  fi

  # ── [environment] env_*, [tmpfs] tmpfs_*, [network] port_* + [security]
  # cap_add_* / cap_drop_* / security_opt_* (template-fallback applied) and
  # [resources] shm_size all come from the shared resolver. ──
  local _env_str="${_dctx[env_str]}"
  local _tmpfs_str="${_dctx[tmpfs_str]}"
  local _ports_str="${_dctx[ports_str]}"
  local _cap_add_str="${_dctx[cap_add_str]}"
  local _cap_drop_str="${_dctx[cap_drop_str]}"
  local _sec_opt_str="${_dctx[sec_opt_str]}"

  # ── Collect [additional_contexts] context_* ──
  # Each entry is `NAME=PATH`. Validation (NAME shape, PATH non-empty)
  # lives in `_validate_additional_context`; setup.sh trusts the parsed
  # values here and emits them verbatim into compose.yaml. Empty list
  # means no `additional_contexts:` block is emitted.
  local -a _ac_arr=()
  _get_conf_list_sorted _ac_k _ac_v "context_" _ac_arr
  local _additional_contexts_str=""
  (( ${#_ac_arr[@]} > 0 )) && _additional_contexts_str="$(printf '%s\n' "${_ac_arr[@]}")"

  # ── [resources] shm_size (only meaningful when ipc != host) ──
  local _shm_size="${_dctx[shm_size]}"

  # ── [logging] + [logging.<svc>] ──
  local _logging_global_str="" _logging_per_svc_str=""
  _collect_logging "${_base_path}" _logging_global_str _logging_per_svc_str

  # ── Resolve final enabled states ──
  local gpu_enabled_eff="" gui_enabled_eff=""
  _resolve_gpu "${gpu_mode}" "${gpu_detected}" gpu_enabled_eff
  _resolve_gui "${gui_mode}" "${gui_detected}" gui_enabled_eff

  # ── Compute hashes for drift detection ──
  local conf_hash=""
  _compute_conf_hash "${_base_path}" conf_hash
  # Dockerfile hash covers the stage-list projection only — adds /
  # removes / renames an `^FROM ... AS <stage>` line, but unrelated
  # `RUN apt-get install` edits do not trigger compose regen.
  local dockerfile_hash=""
  _compute_dockerfile_hash "${_base_path}" dockerfile_hash

  # Join user-added build args (newline-separated) for write_env.
  local _user_build_args_str=""
  if (( ${#_user_build_args[@]} > 0 )); then
    _user_build_args_str="$(printf '%s\n' "${_user_build_args[@]}")"
  fi

  # ── `--print-resolved`: dump effective state, do not touch
  # .env / compose.yaml / .gitignore. Output is machine-readable
  # `key=value` lines (one pair per line). Subsumes the dry-run
  # piece of base#230's `setup_resolve` MCP plan.
  if (( _print_resolved )); then
    printf 'USER_NAME=%s\n' "${user_name}"
    printf 'USER_GROUP=%s\n' "${user_group}"
    printf 'USER_UID=%s\n' "${user_uid}"
    printf 'USER_GID=%s\n' "${user_gid}"
    printf 'HARDWARE=%s\n' "${hardware}"
    printf 'DOCKER_HUB_USER=%s\n' "${docker_hub_user}"
    printf 'IMAGE_NAME=%s\n' "${image_name}"
    printf 'WS_PATH=%s\n' "${ws_path}"
    printf 'APT_MIRROR_UBUNTU=%s\n' "${apt_mirror_ubuntu}"
    printf 'APT_MIRROR_DEBIAN=%s\n' "${apt_mirror_debian}"
    printf 'TZ=%s\n' "${tz}"
    printf 'GPU_DETECTED=%s\n' "${gpu_detected}"
    printf 'GPU_MODE=%s\n' "${gpu_mode}"
    printf 'GPU_ENABLED=%s\n' "${gpu_enabled_eff}"
    printf 'GPU_COUNT=%s\n' "${gpu_count}"
    printf 'GPU_CAPABILITIES=%s\n' "${gpu_caps}"
    printf 'RUNTIME=%s\n' "${gpu_runtime_mode}"
    printf 'GUI_DETECTED=%s\n' "${gui_detected}"
    printf 'GUI_MODE=%s\n' "${gui_mode}"
    printf 'GUI_ENABLED=%s\n' "${gui_enabled_eff}"
    printf 'NETWORK_MODE=%s\n' "${net_mode}"
    printf 'IPC_MODE=%s\n' "${ipc_mode}"
    printf 'PID_MODE=%s\n' "${pid_mode}"
    printf 'PRIVILEGED=%s\n' "${privileged}"
    printf 'NETWORK_NAME=%s\n' "${network_name}"
    printf 'TARGET_ARCH=%s\n' "${target_arch}"
    printf 'BUILD_NETWORK=%s\n' "${build_network}"
    printf 'SSH_X11=%s\n' "$(_is_ssh_x11 && echo true || echo false)"
    printf 'X11_COOKIE_SKIP=%s\n' "$(( _no_x11_cookie ))"
    return 0
  fi

  # ── SSH X11 forwarding cookie rewrite ──
  # When the user is on an SSH X11 forward (`ssh -X` / `ssh -Y`),
  # rewrite their per-session cookie so libX11 inside the container
  # accepts it regardless of hostname. Also warn when [network] mode
  # is non-host because `localhost:N` (which SSH writes into DISPLAY)
  # only reaches the host's SSH X11 listener via host networking.
  #
  # `--no-x11-cookie` skips the rewrite for one invocation
  # (debug knob — `XAUTHORITY` stays at the host value the user's
  # SSH session already populated). GUI itself stays enabled per
  # `gui_enabled_eff`.
  local _ssh_x11_xauth=""
  if [[ "${gui_enabled_eff}" == "true" ]] && _is_ssh_x11 \
      && (( _no_x11_cookie == 0 )); then
    _ssh_x11_xauth="$(_setup_ssh_x11_cookie "${_base_path}")" || _ssh_x11_xauth=""
    if [[ "${net_mode}" != "host" ]]; then
      _log_warn setup ssh_x11_network_mismatch "display=SSH X11 forwarding detected but [network] mode = ${net_mode}; localhost:${DISPLAY##*:} from inside the container will not reach the host's SSH X11 listener. Set [network] mode = host in setup.conf to fix. See base#321." "mode=${net_mode}"
    fi
  fi

  # ── Generate artifacts ──
  write_env "${_env_file}" \
    "${user_name}" "${user_group}" "${user_uid}" "${user_gid}" \
    "${hardware}" "${docker_hub_user}" "${gpu_detected}" \
    "${image_name}" "${ws_path}" \
    "${apt_mirror_ubuntu}" "${apt_mirror_debian}" "${tz}" \
    "${net_mode}" "${ipc_mode}" "${pid_mode}" "${privileged}" \
    "${gpu_count}" "${gpu_caps}" \
    "${gui_detected}" "${conf_hash}" "${dockerfile_hash}" \
    "${network_name}" \
    "${_user_build_args_str}" \
    "${target_arch}" \
    "${build_network}" \
    "${_ssh_x11_xauth}"

  # Create the hand-authored .env workload overlay on first apply.
  # Idempotent: never overwrites an existing user-owned overlay.
  _scaffold_env_overlay "${_overlay_file}"

  local runtime_resolved=""
  _resolve_runtime "${gpu_runtime_mode}" runtime_resolved

  # Propagate generate_compose_yaml's exit explicitly: when sourced
  # (no `set -e`) a hard-error return from the stage validator
  # baseline collision / reserved-tag) would otherwise be swallowed
  # and apply would print "updated" with a half-written compose.yaml.
  generate_compose_yaml "${_base_path}/compose.yaml" "${image_name}" \
    "${gui_enabled_eff}" "${gpu_enabled_eff}" \
    "${gpu_count}" "${gpu_caps}" \
    extra_volumes "${network_name}" \
    "${_devices_str}" \
    "${_env_str}" "${_tmpfs_str}" "${_ports_str}" \
    "${_shm_size}" "${net_mode}" "${ipc_mode}" "${pid_mode}" \
    "${_cap_add_str}" "${_cap_drop_str}" "${_sec_opt_str}" \
    "${_cgroup_rule_str}" \
    "${_user_build_args_str}" \
    "${target_arch}" \
    "${build_network}" \
    "${runtime_resolved}" \
    "${_additional_contexts_str}" \
    "${_logging_global_str}" \
    "${_logging_per_svc_str}" \
    "${restart_policy}" \
    "${dri_groups_str}" \
    || return $?

  # S7: runtime.env retired. Under the A2 model its purpose
  # is superseded -- [environment] defaults are baked into the runtime
  # image as ENV (S3), and host-side standalone helpers source
  # .env.generated (resolved cache) + .env (overlay) instead.

  if [[ "${_quiet}" -eq 0 ]]; then
    _log_info setup env_regenerated "display=$(_setup_msg env "done")"
    printf "[setup] USER=%s (%s:%s)  GPU=%s/%s  GUI=%s/%s  IMAGE=%s  WS=%s\n" \
      "${user_name}" "${user_uid}" "${user_gid}" \
      "${gpu_enabled_eff}" "${gpu_mode}" \
      "${gui_enabled_eff}" "${gui_mode}" \
      "${image_name}" "${ws_path}"
  fi
}

# ════════════════════════════════════════════════════════════════════
# _setup_deploy [-h] [--base-path P] [--lang L] [--stage S]
#               [--output|-o F] [--dry-run] [-y|--yes] [-q|--quiet]
#
# S6d ofuser-facing entry for the self-contained field
# deploy bundle. Previews the resolved field launcher (every inlined
# docker-level flag -- the per-parameter review), asks for confirmation,
# then calls _generate_deploy_bundle (S6c) to build the immutable image
# and write the tar.xz bundle. `--dry-run` prints the build plan without
# building (and skips the prompt); `-y` skips the prompt; a non-tty shell
# without `-y` refuses (mirrors `reset`). Default stage is `runtime`;
# default output is <base>/deploy/<name>-<stage>.tar.xz.
#
# Note: the graphical per-param TUI page (setup_tui.sh) is an optional
# fast-follow -- this plain-text preview already surfaces every resolved
# flag and is script / CI friendly (the issue invited the lighter flow).
# ════════════════════════════════════════════════════════════════════
_setup_deploy() {
  local _base_path="" _stage="runtime" _output="" _yes=0 _quiet=0 _dry=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)     usage ;;
      --base-path)   _base_path="${2:?"--base-path requires a value"}"; shift 2 ;;
      --lang)        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"; _sanitize_lang _LANG "setup"; shift 2 ;;
      --stage)       _stage="${2:?"--stage requires a value"}"; shift 2 ;;
      --stage=*)     _stage="${1#--stage=}"; shift ;;
      --output|-o)   _output="${2:?"--output requires a value"}"; shift 2 ;;
      --output=*)    _output="${1#--output=}"; shift ;;
      --dry-run)     _dry=1; shift ;;
      -y|--yes)      _yes=1; shift ;;
      -q|--quiet)    _quiet=1; shift ;;
      *)
        _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
        return 1
        ;;
    esac
  done

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../../../.." && pwd -P)"
  fi
  if [[ ! -f "${_base_path}/Dockerfile" ]]; then
    _log_err setup deploy_no_dockerfile "display=[setup] deploy: no Dockerfile at ${_base_path}; cannot build the field image." "path=${_base_path}"
    return 1
  fi

  local _name=""
  BASE_PATH="${_base_path}" detect_image_name _name "${_base_path}"
  [[ -z "${_output}" ]] && _output="${_base_path}/deploy/${_name}-${_stage}.tar.xz"

  # Per-parameter review: generate the launcher to a temp file and print
  # it so the user sees every inlined docker-level flag before building.
  if (( ! _quiet )); then
    local _preview
    _preview="$(mktemp)"
    _generate_deploy_sh "${_base_path}" "${_stage}" "${_name}:${_stage}" "${_name}-${_stage}" "${_preview}"
    printf '[setup] deploy plan: stage=%s image=%s:%s bundle=%s\n' \
      "${_stage}" "${_name}" "${_stage}" "${_output}"
    printf '[setup] field launcher to be generated (review every flag):\n'
    sed 's/^/    /' "${_preview}"
    rm -f "${_preview}"
  fi

  # Confirmation: skipped on --dry-run / -y; a non-tty shell without -y
  # refuses rather than build silently (mirrors reset).
  if (( ! _dry )) && (( ! _yes )); then
    if [[ ! -t 0 ]]; then
      _log_err setup deploy_needs_yes "display=[setup] deploy: refusing to build without confirmation in a non-interactive shell; pass -y to proceed."
      return 1
    fi
    printf "[setup] build the field image and write %s? [y/N]: " "${_output}"
    local _ans=""
    read -r _ans
    case "${_ans}" in
      y|Y|yes|YES) ;;
      *)
        _log_warn setup deploy_aborted "display=[setup] deploy aborted."
        return 1
        ;;
    esac
  fi

  mkdir -p "$(dirname -- "${_output}")"
  local _rc=0
  if (( _dry )); then
    DRY_RUN=true _generate_deploy_bundle "${_base_path}" "${_stage}" "${_output}" || _rc=$?
  else
    _generate_deploy_bundle "${_base_path}" "${_stage}" "${_output}" || _rc=$?
  fi
  if (( _rc != 0 )); then
    _log_err setup deploy_failed "display=[setup] deploy: bundle generation failed (rc=${_rc})." "rc=${_rc}"
    return "${_rc}"
  fi

  if (( ! _quiet )) && (( ! _dry )); then
    _log_info setup deploy_done "display=[setup] deploy bundle written: ${_output}"
    printf "[setup] field flow: tar -xJf %s && docker load < image.tar && ./deploy.sh\n" \
      "$(basename -- "${_output}")"
  fi
  return 0
}
