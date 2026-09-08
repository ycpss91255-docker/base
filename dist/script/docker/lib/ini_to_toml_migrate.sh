#!/usr/bin/env bash
#
# ini_to_toml_migrate.sh - one-time INI-to-TOML migration for downstream repos.
#
# Converts the pre-ADR-37 INI config files to their TOML equivalents
# during the first init.sh resync after a base upgrade:
#
#   .setup.conf        -> setup.toml
#   .setup.conf.local  -> setup.local.toml
#   .env.local         -> .env.local.toml
#
# Each conversion is gated on the source file existing AND the target
# NOT existing, so the migration is idempotent: a repo that already has
# the TOML file (whether from a fresh bootstrap or a previous upgrade)
# is left alone. The original file is renamed to .bak for verification.
#
# ── Why HERE and not in upgrade.sh ─────────────────────────────────
#
# Same reasoning as _migrate_env_to_local, _migrate_legacy_setup_conf,
# and _migrate_smoke_tree: an upgrade is driven by the CONSUMER'S OWN
# vendored upgrade.sh, a copy that shipped before TOML support existed.
# init.sh is the one piece of CURRENT code the upgrade re-runs (Step 3
# resync), so the migration runs from the existing-repo resync path.
#
# ── Numbered-key -> array-of-tables mapping ────────────────────────
#
# The 8 INI numbered-key patterns become TOML arrays of tables:
#
#   [image]    rule_N = V          -> [[image.rules]]        rule = "V"
#   [build]    arg_N  = K=V        -> [[build.args]]         key/value split
#   [volumes]  mount_N = V         -> [[volumes]]            path = "V"
#   [tmpfs]    tmpfs_N = V         -> [[tmpfs]]              path = "V"
#   [devices]  device_N = V        -> [[devices]]            path = "V"
#   [network]  port_N  = H:C      -> [[network.ports]]      host/container
#   [security] cap_add_N = V       -> [[security.cap_add]]   cap = "V"
#              cap_drop_N = V      -> [[security.cap_drop]]  cap = "V"
#              security_opt_N = V  -> [[security.security_opt]] opt = "V"
#   [additional_contexts]
#              context_N = N=S     -> [[additional_contexts]] name/source
#
# Plus the special case:
#   [environment] env_N = K=V      -> [environment]          K = "V"

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_INI_TO_TOML_MIGRATE_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_INI_TO_TOML_MIGRATE_SOURCED=1

_ini_to_toml_migrate_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=dist/script/docker/lib/conf.sh
source "${_ini_to_toml_migrate_lib_dir}/conf.sh"
unset _ini_to_toml_migrate_lib_dir

# ── TOML value formatting ─────────────────────────────────────────────

# _ini_to_toml_format_value <value>
#
# Format a value for TOML output. Booleans and integers are emitted
# bare (matching the TOML template's style); everything else is
# double-quoted. Empty values become "".
_ini_to_toml_format_value() {
  local _v="$1"
  case "${_v}" in
    true|false) printf '%s' "${_v}" ;;
    '')         printf '""' ;;
    *[!0-9]*)
      # Escape embedded double quotes so the TOML stays valid.
      _v="${_v//\"/\\\"}"
      printf '"%s"' "${_v}"
      ;;
    *)          printf '%s' "${_v}" ;;
  esac
}

# ── Numbered-key detection ─────────────────────────────────────────────

# _ini_to_toml_is_numbered <section> <key>
#
# Return 0 if <key> is a numbered-key pattern for <section>.
_ini_to_toml_is_numbered() {
  local _s="$1" _k="$2"
  case "${_s}" in
    image)               [[ "${_k}" =~ ^rule_[0-9]+$ ]] ;;
    build)               [[ "${_k}" =~ ^arg_[0-9]+$ ]] ;;
    volumes)             [[ "${_k}" =~ ^mount_[0-9]+$ ]] ;;
    tmpfs)               [[ "${_k}" =~ ^tmpfs_[0-9]+$ ]] ;;
    devices)             [[ "${_k}" =~ ^device_[0-9]+$ ]] ;;
    network)             [[ "${_k}" =~ ^port_[0-9]+$ ]] ;;
    security)            [[ "${_k}" =~ ^(cap_add|cap_drop|security_opt)_[0-9]+$ ]] ;;
    additional_contexts) [[ "${_k}" =~ ^context_[0-9]+$ ]] ;;
    environment)         [[ "${_k}" =~ ^env_[0-9]+$ ]] ;;
    *) return 1 ;;
  esac
}

# ── Numbered-key -> AoT emission ──────────────────────────────────────

# _ini_to_toml_emit_aot <section> <key> <value> <outvar>
#
# Append a TOML array-of-tables entry for a numbered key to <outvar>.
# Empty values (opt-out slots) are silently skipped.
_ini_to_toml_emit_aot() {
  local _s="$1" _k="$2" _v="$3"
  local -n _aot_out="$4"
  [[ -n "${_v}" ]] || return 0

  local _split_k _split_v
  case "${_s}" in
    image)
      _aot_out+=$'[[image.rules]]\n'
      _aot_out+="rule = \"${_v}\""$'\n\n'
      ;;
    build)
      _split_k="${_v%%=*}"
      _split_v="${_v#*=}"
      _aot_out+=$'[[build.args]]\n'
      _aot_out+="key = \"${_split_k}\""$'\n'
      _aot_out+="value = \"${_split_v}\""$'\n\n'
      ;;
    volumes)
      _aot_out+=$'[[volumes]]\n'
      _aot_out+="path = \"${_v}\""$'\n\n'
      ;;
    tmpfs)
      _aot_out+=$'[[tmpfs]]\n'
      _aot_out+="path = \"${_v}\""$'\n\n'
      ;;
    devices)
      _aot_out+=$'[[devices]]\n'
      _aot_out+="path = \"${_v}\""$'\n\n'
      ;;
    network)
      _split_k="${_v%%:*}"
      _split_v="${_v#*:}"
      _aot_out+=$'[[network.ports]]\n'
      _aot_out+="host = ${_split_k}"$'\n'
      _aot_out+="container = ${_split_v}"$'\n\n'
      ;;
    security)
      if [[ "${_k}" =~ ^cap_add_ ]]; then
        _aot_out+=$'[[security.cap_add]]\n'
        _aot_out+="cap = \"${_v}\""$'\n\n'
      elif [[ "${_k}" =~ ^cap_drop_ ]]; then
        _aot_out+=$'[[security.cap_drop]]\n'
        _aot_out+="cap = \"${_v}\""$'\n\n'
      elif [[ "${_k}" =~ ^security_opt_ ]]; then
        _aot_out+=$'[[security.security_opt]]\n'
        _aot_out+="opt = \"${_v}\""$'\n\n'
      fi
      ;;
    additional_contexts)
      _split_k="${_v%%=*}"
      _split_v="${_v#*=}"
      _aot_out+=$'[[additional_contexts]]\n'
      _aot_out+="name = \"${_split_k}\""$'\n'
      _aot_out+="source = \"${_split_v}\""$'\n\n'
      ;;
  esac
}

# ── Core converter ────────────────────────────────────────────────────

# _ini_to_toml_convert <ini_file> <toml_file>
#
# Read an INI file and write its TOML equivalent. Uses _ini_tokenize
# from conf.sh for parsing. Writes atomically via a temp file.
_ini_to_toml_convert() {
  local _ini="${1:?"${FUNCNAME[0]}: missing ini file"}"
  local _toml="${2:?"${FUNCNAME[0]}: missing toml file"}"

  local -a _sects=() _es=() _keys=() _vals=()
  _ini_tokenize "${_ini}" _sects _es _keys _vals

  local _result=""
  local _s _i _j

  for _s in ${_sects[@]+"${_sects[@]}"}; do
    # Separate scalar and numbered keys for this section.
    local -a _sc_keys=() _sc_vals=()
    local _aot_buf=""

    for (( _i = 0; _i < ${#_keys[@]}; _i++ )); do
      [[ "${_es[_i]}" == "${_s}" ]] || continue
      if _ini_to_toml_is_numbered "${_s}" "${_keys[_i]}"; then
        if [[ "${_s}" == "environment" ]]; then
          # env_N = K=V unpacks to direct KEY = "VALUE"
          [[ -n "${_vals[_i]}" ]] || continue
          _sc_keys+=("${_vals[_i]%%=*}")
          _sc_vals+=("${_vals[_i]#*=}")
        else
          _ini_to_toml_emit_aot "${_s}" "${_keys[_i]}" "${_vals[_i]}" _aot_buf
        fi
      else
        _sc_keys+=("${_keys[_i]}")
        _sc_vals+=("${_vals[_i]}")
      fi
    done

    # Emit section header + scalar keys.
    if (( ${#_sc_keys[@]} > 0 )); then
      if [[ "${_s}" == *:* ]]; then
        _result+="[\"${_s}\"]"$'\n'
      else
        _result+="[${_s}]"$'\n'
      fi
      for (( _j = 0; _j < ${#_sc_keys[@]}; _j++ )); do
        local _fk="${_sc_keys[_j]}"
        # Quote keys that contain dots (dotted keys in stage overrides).
        if [[ "${_fk}" == *.* ]]; then
          _fk="\"${_fk}\""
        fi
        _result+="${_fk} = $(_ini_to_toml_format_value "${_sc_vals[_j]}")"$'\n'
      done
      _result+=$'\n'
    fi

    # Emit array-of-tables entries (after the section's scalars).
    if [[ -n "${_aot_buf}" ]]; then
      _result+="${_aot_buf}"
    fi
  done

  # Atomic write via temp file.
  local _tmp="${_toml}.$$"
  printf '%s' "${_result}" > "${_tmp}"
  mv -f "${_tmp}" "${_toml}"
}

# ── Migration entry points ────────────────────────────────────────────

# _migrate_ini_to_toml <repo_root>
#
# Convert .setup.conf -> setup.toml and .setup.conf.local ->
# setup.local.toml. Each half is gated independently on
# [[ -f source && ! -f target ]].
_migrate_ini_to_toml() {
  local _root="${1:?"${FUNCNAME[0]}: missing repo_root"}"

  # .setup.conf -> setup.toml
  local _ini="${_root%/}/.setup.conf"
  local _toml="${_root%/}/setup.toml"
  if [[ -f "${_ini}" && ! -f "${_toml}" ]]; then
    _ini_to_toml_convert "${_ini}" "${_toml}"
    mv -- "${_ini}" "${_ini}.bak"
    _log_warn init ini_to_toml_migrated \
      "display=MIGRATION: .setup.conf -> setup.toml. The configuration format has been upgraded from INI to TOML (ADR-00000037). Your settings were converted and the original was backed up to .setup.conf.bak." \
      "path=${_toml}"
  fi

  # .setup.conf.local -> setup.local.toml
  local _ini_local="${_root%/}/.setup.conf.local"
  local _toml_local="${_root%/}/setup.local.toml"
  if [[ -f "${_ini_local}" && ! -f "${_toml_local}" ]]; then
    _ini_to_toml_convert "${_ini_local}" "${_toml_local}"
    mv -- "${_ini_local}" "${_ini_local}.bak"
    _log_warn init ini_to_toml_local_migrated \
      "display=MIGRATION: .setup.conf.local -> setup.local.toml. The per-instance override was converted from INI to TOML and the original was backed up to .setup.conf.local.bak." \
      "path=${_toml_local}"
  fi
}

# _migrate_env_local_to_toml <repo_root>
#
# Convert .env.local (flat KEY=VALUE) -> .env.local.toml (TOML with
# [environment] section). Gated on [[ -f .env.local && ! -f
# .env.local.toml ]].
_migrate_env_local_to_toml() {
  local _root="${1:?"${FUNCNAME[0]}: missing repo_root"}"
  local _env="${_root%/}/.env.local"
  local _toml="${_root%/}/.env.local.toml"

  [[ -f "${_env}" && ! -f "${_toml}" ]] || return 0

  local _result
  _result=$'[environment]\n'

  local _line _k _v
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    # Skip comments and blank lines.
    [[ -z "${_line}" || "${_line}" =~ ^[[:space:]]*# ]] && continue
    # Skip lines without =
    [[ "${_line}" == *=* ]] || continue
    _k="${_line%%=*}"
    _v="${_line#*=}"
    # Trim whitespace.
    _k="${_k#"${_k%%[![:space:]]*}"}"
    _k="${_k%"${_k##*[![:space:]]}"}"
    _v="${_v#"${_v%%[![:space:]]*}"}"
    _v="${_v%"${_v##*[![:space:]]}"}"
    [[ -n "${_k}" ]] || continue
    # Strip matching outer quotes (docker compose convention).
    if [[ "${_v}" =~ ^\"(.*)\"$ ]]; then
      _v="${BASH_REMATCH[1]}"
    elif [[ "${_v}" =~ ^\'(.*)\'$ ]]; then
      _v="${BASH_REMATCH[1]}"
    fi
    _result+="${_k} = \"${_v}\""$'\n'
  done < "${_env}"

  # Atomic write.
  local _tmp="${_toml}.$$"
  printf '%s' "${_result}" > "${_tmp}"
  mv -f "${_tmp}" "${_toml}"
  mv -- "${_env}" "${_env}.bak"
  _log_warn init env_local_to_toml_migrated \
    "display=MIGRATION: .env.local -> .env.local.toml. The per-instance env override was converted from flat KEY=VALUE to TOML (ADR-00000037) and the original was backed up to .env.local.bak." \
    "path=${_toml}"
}
