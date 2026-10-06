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
# A numbered INI key becomes the `[[array of tables]]` block the SHIPPED
# WRITER puts it in, and the conversion is DERIVED from that writer rather
# than listed here: _conf_toml_aot_slot says which array path a
# `<section>.<key>` belongs to, and _conf_toml_aot_fields renders the one
# block's body. Those are the same two functions `setup.sh set` / `add`
# write through, and the bridge's array spec is the other side of them.
#
# Why derived and not a table of its own. A converted file is read back by
# the bridge, and a field name only the converter knows reads back as an
# empty entry: a `[[volumes]]` block carrying `path` -- which is what a
# hand-written table here said -- loses every mount on the upgrade that
# converts the repo, silently, with the INI already renamed to .bak. The
# same holds for a numbered key with NO array home at all.
#
# What has no array home stays a quoted scalar under its own table, which
# is again what the writer does and what the runtime readers look for:
# `[environment] env_N`, `[security] cap_drop_N`, `[devices]
# cgroup_rule_N`. The direct-key `[environment] KEY = "V"` form the
# template documents is the D5 / D6 destination; until those readers land,
# `_conf_list_sorted ... environment env_` is what reads the section, so
# unpacking here would drop the variable.

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
# Format a value as the TOML scalar that reads back to the same bash
# string, by delegating to conf.sh's _conf_toml_scalar -- the renderer the
# shipped writers already use.
#
# Not a second implementation: this one escaped a double quote and nothing
# else, so an ordinary INI value carrying a backslash (a watchdog `pgrep`
# pattern, a Windows-style path) came out as an undefined TOML escape and
# made the WHOLE converted file unparseable -- after the INI had been
# renamed to .bak, so the only copy of the configuration was the broken
# one. _conf_toml_scalar escapes backslash, double quote and tab, keeps a
# boolean and an integer bare, and refuses to render a leading-zero
# number as a bare integer TOML would reject.
_ini_to_toml_format_value() {
  local _fv_out=""
  _conf_toml_scalar "${1-}" _fv_out
  printf '%s' "${_fv_out}"
}

# ── Numbered-key detection ─────────────────────────────────────────────

# _ini_to_toml_is_numbered <section> <key>
#
# Return 0 when <key> is a numbered key that HAS an array-of-tables home,
# asked of the shipped writer rather than re-matched here. A numbered key
# with no array home (`env_N`, `cap_drop_N`, `cgroup_rule_N`) answers 1 and
# is carried over as a scalar, which is where every reader looks for it.
#
# The out-variable names are prefixed, like every nameref target in this
# tree: _conf_toml_aot_slot has locals of its own called `_path` and
# `_idx`, and a nameref pointing at either of those names resolves to the
# callee's local instead of ours -- it comes back empty, and the key then
# reads as one with no array home.
_ini_to_toml_is_numbered() {
  local _itn_path="" _itn_idx=""
  _conf_toml_aot_slot "${1-}" "${2-}" _itn_path _itn_idx
}

# ── Numbered-key -> AoT emission ──────────────────────────────────────

# _ini_to_toml_emit_aot <section> <key> <value> <outvar>
#
# Append the one `[[array of tables]]` block a numbered key becomes to
# <outvar>. The path and the body both come from the shipped writer
# (_conf_toml_aot_slot / _conf_toml_aot_fields), so the field names are the
# ones the bridge's array spec reads back and there is no second spelling
# to drift.
#
# Empty values (opt-out slots) are silently skipped.
_ini_to_toml_emit_aot() {
  local _s="$1" _k="$2" _v="$3"
  local -n _aot_out="$4"
  [[ -n "${_v}" ]] || return 0

  local _eao_path="" _eao_idx="" _eao_fields=""
  _conf_toml_aot_slot "${_s}" "${_k}" _eao_path _eao_idx || return 0
  _conf_toml_aot_fields "${_eao_path}" "${_v}" _eao_fields
  [[ -n "${_eao_fields}" ]] || return 0

  _aot_out+="[[${_eao_path}]]"$'\n'
  _aot_out+="${_eao_fields}"$'\n\n'
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
        _ini_to_toml_emit_aot "${_s}" "${_keys[_i]}" "${_vals[_i]}" _aot_buf
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
