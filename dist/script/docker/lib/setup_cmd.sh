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
# Returns 0 when <section> is one of the known setup.toml section
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
# _setup_known_key <section> <key>
#
# Returns 0 when some reader consumes <section>.<key>, 1 otherwise. A
# key is known when it resolves to a SCHEMA_VALIDATOR entry (numbered
# list suffix and the per-service [logging.<svc>] spelling normalised by
# _schema_canonical_key), or when it is one of the free-form keys a
# reader takes through _conf_get_into without a validator (the
# pre-arg_N [build] named keys _setup_apply lifts into build args).
# <section> is a known non-stage section; see _setup_conf_check_known.
# ════════════════════════════════════════════════════════════════════
_setup_known_key() {
  local _section="${1-}" _key="${2-}"
  local _canon=""
  _schema_canonical_key "${_section}" "${_key}" _canon
  [[ -n "${_canon}" ]] && return 0
  case "${_section}.${_key}" in
    build.apt_mirror_ubuntu|build.apt_mirror_debian|build.tz) return 0 ;;
  esac
  return 1
}

# ════════════════════════════════════════════════════════════════════
# _setup_refuse_unknown_key <verb> <section> <key>
#
# Log the refusal `set` and `add` give a key _setup_known_key does not
# know, before anything is written (base#1374). The wording follows
# apply's apply_unknown_key message, so the operator sees the same
# terms whether the key is caught at write time or at apply time.
# Always returns 2, the code both callers give a refused spec.
# ════════════════════════════════════════════════════════════════════
_setup_refuse_unknown_key() {
  local _verb="${1:?"${FUNCNAME[0]}: missing verb"}"
  local _section="${2:?"${FUNCNAME[0]}: missing section"}"
  local _key="${3:?"${FUNCNAME[0]}: missing key"}"
  _log_err setup conf_unknown_key \
    "display=[setup] ${_verb}: unknown key ${_section}.${_key}; no reader reads it, so the default would apply instead. Fix the spelling" \
    "table=${_section}" "key=${_key}"
  return 2
}

# ════════════════════════════════════════════════════════════════════
# _setup_conf_check_known <base_path>
#
# Refuse a setup.toml chain that carries a table no reader knows or a
# key in a known table no reader reads (base#1328). Before this, both
# passed `apply` with exit 0 and nothing said: `[deploy] gpu_cuont = "1"`
# generated `count: all`, the default, because no reader asks for
# `gpu_cuont`.
#
# Each TOML layer of the chain is read on its OWN, so the refusal names
# the file the operator has to edit -- the merged view no longer knows
# which layer a key came from. Every unknown entry is reported before
# returning, so one run lists them all. Returns 1 when any was found.
#
# An empty array (`[deploy] args = []`) has no row either; it is judged
# by the row its first entry would take (the bridge's --empty-families
# view), so a family its table does not read is refused like a key.
#
# Tables are judged from the layer's own table list (the bridge's
# --tables view), not only from its key/value rows: a table with no
# entry -- `[deploy2]` alone, or holding only `args = []` -- projects no
# row, and a row walk passed it with exit 0 (base#1328 review).
#
# A [stage:<name>] table, and anything under it, is not judged here:
# its keys already pass _validate_stage_override_key where the stage is
# emitted, which WARNs on a key outside the per-stage allowlist.
# ════════════════════════════════════════════════════════════════════
_setup_conf_check_known() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local -a _sck_layers=()
  _setup_conf_layers "${_base}" _sck_layers || return 1
  local _layer _i _sect _key _bad=0
  for _layer in "${_sck_layers[@]}"; do
    # `-e`: a directory or FIFO in a layer's place is refused by the load
    # below, not skipped as an absent layer (base#1400).
    [[ -e "${_layer}" && "${_layer}" == *.toml ]] || continue
    _conf_load_layers _SCK_CONF "${_layer}" || return 1
    local -n _sck_es=_SCK_CONF__es
    local -n _sck_k=_SCK_CONF__keys
    local -A _sck_reported=()
    local _sck_tables=""
    _sck_tables="$(toml_bridge_parse "${_layer}" --tables)" || return 1
    while IFS= read -r _sect; do
      [[ -z "${_sect}" || "${_sect}" == stage:* ]] && continue
      _setup_known_section "${_sect}" && continue
      [[ -n "${_sck_reported[${_sect}]:-}" ]] && continue
      _sck_reported[${_sect}]=1
      _log_err setup apply_unknown_table \
        "display=[setup] apply: ${_layer}: unknown table [${_sect}]; no reader knows it, so its settings would be dropped. Fix or remove the table" \
        "file=${_layer}" "table=${_sect}"
      _bad=1
    done <<< "${_sck_tables}"
    for (( _i = 0; _i < ${#_sck_k[@]}; _i++ )); do
      _sect="${_sck_es[_i]}"
      _key="${_sck_k[_i]}"
      [[ "${_sect}" == stage:* ]] && continue
      if ! _setup_known_section "${_sect}"; then
        [[ -n "${_sck_reported[${_sect}]:-}" ]] && continue
        _sck_reported[${_sect}]=1
        _log_err setup apply_unknown_table \
          "display=[setup] apply: ${_layer}: unknown table [${_sect}]; no reader knows it, so its settings would be dropped. Fix or remove the table" \
          "file=${_layer}" "table=${_sect}"
        _bad=1
      elif ! _setup_known_key "${_sect}" "${_key}"; then
        _log_err setup apply_unknown_key \
          "display=[setup] apply: ${_layer}: unknown key ${_sect}.${_key}; no reader reads it, so the default would apply instead. Fix the spelling or remove the key" \
          "file=${_layer}" "table=${_sect}" "key=${_key}"
        _bad=1
      fi
    done
    # An empty array declares a family with no entry, so it has no row
    # above, and a known table hid it: `[deploy] args = []` passed though
    # no reader consumes deploy.args (base#1328 review). The bridge names
    # the row its first entry would take, judged here like any row; an
    # unknown table was already reported by the table walk.
    local _sck_empty="" _path
    _sck_empty="$(toml_bridge_parse "${_layer}" --empty-families)" || return 1
    while IFS=$'\t' read -r _sect _key _path; do
      [[ -z "${_sect}" || "${_sect}" == stage:* ]] && continue
      _setup_known_section "${_sect}" || continue
      _setup_known_key "${_sect}" "${_key}" && continue
      _log_err setup apply_unknown_key \
        "display=[setup] apply: ${_layer}: unknown key ${_path}; no reader reads it, so the default would apply instead. Fix the spelling or remove the key" \
        "file=${_layer}" "table=${_sect}" "key=${_path#"${_sect}".}"
      _bad=1
    done <<< "${_sck_empty}"
    unset -n _sck_es _sck_k
    unset _sck_reported
  done
  (( _bad == 0 ))
}

# ════════════════════════════════════════════════════════════════════
# _setup_conf_key_origin <base_path> <section> <key> <outvar>
#
# Set <outvar> to the conf layer that decides <section>.<key>: the
# topmost layer of _setup_conf_layers that names it. Empty when no layer
# does (the reader's default applies). Used where a refusal has to name
# the file an operator must edit, not just the key (base#1270).
# ════════════════════════════════════════════════════════════════════
_setup_conf_key_origin() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local _want_sect="${2:?"${FUNCNAME[0]}: missing section"}"
  local _want_key="${3:?"${FUNCNAME[0]}: missing key"}"
  local -n _sko_out="${4:?"${FUNCNAME[0]}: missing outvar"}"
  _sko_out=""
  local -a _sko_layers=()
  _setup_conf_layers "${_base}" _sko_layers || return 1
  local _n _i _layer
  for (( _n = ${#_sko_layers[@]} - 1; _n >= 0; _n-- )); do
    _layer="${_sko_layers[_n]}"
    [[ -f "${_layer}" && "${_layer}" == *.toml ]] || continue
    _conf_load_layers _SKO_CONF "${_layer}" || return 1
    local -n _sko_es=_SKO_CONF__es
    local -n _sko_k=_SKO_CONF__keys
    for (( _i = 0; _i < ${#_sko_k[@]}; _i++ )); do
      if [[ "${_sko_es[_i]}" == "${_want_sect}" \
            && "${_sko_k[_i]}" == "${_want_key}" ]]; then
        _sko_out="${_layer}"
        unset -n _sko_es _sko_k
        return 0
      fi
    done
    unset -n _sko_es _sko_k
  done
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
# _setup_warn_inert <base_path> <section> <key>
#
# Store-time half of the inert-value diagnostics (the emit-time half lives
# at the corresponding gates in compose_emit.sh / deploy.sh, and both go
# through the same `_warn_*` function, so store-time and emit-time can
# never disagree about when a value is inert). Validation answers "is this
# value well formed?"; this answers the question the user actually asked,
# which is "will it do anything?".
#
# Three pairs of keys, each a question with two answerers where the loser
# used to be silent:
#
#   [network] port_*     vs [network] mode -- compose publishes ports only
#                           under bridge, and the template ships host (base#879)
#   [resources] shm_size vs [network] ipc  -- docker honours shm_size only
#                           when the container has its own IPC namespace,
#                           and the template ships ipc = host, so the only
#                           key in [resources] was inert by default
#                           (base#1094)
#   [network] network_name vs [network] mode -- compose joins a named
#                           network only under bridge, so mode wins
#                           (base#1094)
#
# Fires on BOTH moves that can create each mismatch: writing the dependent
# key while the deciding key already forbids it, and switching the deciding
# key while the dependent one is already configured. Any other key is a
# no-op, which is also why the merged view is read ONCE, after that gate:
# _setup_effective_full re-resolves the whole layer chain.
#
# Reads the MERGED view (template baseline <- repo override) so an unset
# `[network] mode` is judged by the default the emitter will actually use,
# not by the absence of a key.
#
# ONE function for the family rather than one per diagnostic: `set` and
# `add` each call it once, so a new member is a case label and a
# `_warn_*` line here, not a fourth call site at every entry point.
# ════════════════════════════════════════════════════════════════════
_setup_warn_inert() {
  local _base_path="${1-}" _section="${2-}" _key="${3-}"
  case "${_section}.${_key}" in
    network.mode|network.ipc|network.network_name|network.port_[0-9]*) ;;
    resources.shm_size) ;;
    *) return 0 ;;
  esac

  local -a _wpi_sections=() _wpi_keys=() _wpi_values=()
  _setup_effective_full "${_base_path}" _wpi_sections _wpi_keys _wpi_values

  # The defaults are the shipped template's, so a key the repo never set
  # is judged by the value the emitter will actually use.
  local _i _mode="host" _ipc="host" _net_name="" _shm="" _ports=""
  for (( _i=0; _i<${#_wpi_keys[@]}; _i++ )); do
    case "${_wpi_keys[_i]}" in
      network.mode)
        [[ -n "${_wpi_values[_i]}" ]] && _mode="${_wpi_values[_i]}"
        ;;
      network.ipc)
        [[ -n "${_wpi_values[_i]}" ]] && _ipc="${_wpi_values[_i]}"
        ;;
      network.network_name)
        _net_name="${_wpi_values[_i]}"
        ;;
      resources.shm_size)
        _shm="${_wpi_values[_i]}"
        ;;
      network.port_[0-9]*)
        [[ -n "${_wpi_values[_i]}" ]] && _ports+="${_wpi_values[_i]}"$'\n'
        ;;
    esac
  done

  _warn_ports_inert "${_ports}" "${_mode}"
  _warn_shm_size_inert "${_shm}" "${_ipc}"
  _warn_network_name_inert "${_net_name}" "${_mode}"
}

# ════════════════════════════════════════════════════════════════════
# _setup_write_target <base_path> <local_flag> <outvar>
#
# Resolve which file a write verb lands in: <base>/setup.toml by default,
# <base>/setup.local.toml when --local was passed. Bootstraps the file as
# empty when missing -- a write verb records only the user's intent, never a
# wholesale copy of template defaults. Announces the creation of the local
# override the first time, because a file that is gitignored and read by
# every later resolution should not appear without a word.
# ════════════════════════════════════════════════════════════════════
_setup_write_target() {
  local _base_path="${1:?}"
  local _is_local="${2:-0}"
  local -n _swt_out="${3:?}"

  if (( _is_local )); then
    _swt_out="$(_setup_conf_local_path "${_base_path}")"
  else
    _swt_out="${_base_path}/setup.toml"
  fi
  if [[ ! -f "${_swt_out}" ]]; then
    : > "${_swt_out}"
    if (( _is_local )); then
      _log_info setup conf_local_created \
        "display=[setup] created ${_swt_out} -- the gitignored per-worktree override. Every section it defines REPLACES the committed setup.toml's, on this machine only; 'setup.sh deploy' refuses to build a field bundle while it exists." \
        "file=${_swt_out}"
    fi
  fi
}

# ════════════════════════════════════════════════════════════════════
# _setup_warn_shadowed_write <base_path> <section> <is_local>
#
# The store-time half of "a write must land where the read path looks".
# When a write targets the COMMITTED setup.toml and setup.local.toml
# already defines that section, the write may be inert on this machine --
# so say so, by name.
#
# Stated as a possibility, not a certainty. Under ADR-00000037's merge a
# local table overrides only the keys it names, so a write to a key that
# layer does not mention DOES take effect here; a local array, which
# replaces whole, shadows every entry of its list. The granularity
# available at this call site is the SECTION -- _setup_conf_local_sections
# answers per section, and the key is not threaded through -- so the
# warning is section-granular and honest about it rather than precise and
# wrong. A key-precise warning is a separate change.
#
# It is a WARNING, not a refusal, and that asymmetry is deliberate -- the
# value is still the committed, shared setting CI and every other checkout
# use, so refusing would block a legitimate write on the grounds that one
# machine may not see its effect.
#
# No-op when the write already targets the local layer, and no-op for a
# section setup.local.toml does not define.
# ════════════════════════════════════════════════════════════════════
_setup_warn_shadowed_write() {
  local _base_path="${1-}" _section="${2-}" _is_local="${3:-0}"
  (( _is_local )) && return 0

  local -a _wsw_sections=()
  _setup_conf_local_sections "${_base_path}" _wsw_sections
  local _s _shadowed=0
  for _s in "${_wsw_sections[@]+"${_wsw_sections[@]}"}"; do
    [[ "${_s}" == "${_section}" ]] && { _shadowed=1; break; }
  done
  (( _shadowed )) || return 0

  local _local
  _local="$(_setup_conf_local_path "${_base_path}")"
  _log_warn setup conf_write_shadowed \
    "display=[setup] [${_section}] is also defined in ${_local}, which overrides the keys it names there and replaces whole any list it declares. This write may have no effect on this machine. It is still the committed value CI and every other checkout of this repo use -- pass --local to change what runs here instead." \
    "section=${_section}" "file=${_local}"
  return 0
}

# ════════════════════════════════════════════════════════════════════
# _setup_set
#
# Subcommand handler for `setup.sh set <section>.<key> <value>`.
# Validates section + (where applicable) value, then upserts via
# `_upsert_conf_value` from `_tui_conf.sh` so behaviour matches the
# TUI's Save path. Does NOT regenerate .env.generated — the user invokes
# `apply` explicitly when they want the derived artifacts refreshed.
#
# Usage: _setup_set <section>.<key> <value> [--base-path PATH]
#                                           [--lang LANG] [-q|--quiet]
# ════════════════════════════════════════════════════════════════════
_setup_set() {
  local _base_path=""
  local _spec="" _value="" _have_value=0
  local _quiet=0
  local _is_local=0

  while [[ $# -gt 0 ]]; do
    # Once <spec> is captured the next bare arg is the value, even if
    # it starts with '-' (e.g. `set deploy.gpu_count -1` exercises an
    # invalid value path that the validator must reject — not a flag).
    if [[ -n "${_spec}" && "${_have_value}" -eq 0 ]]; then
      case "$1" in
        --base-path|--lang|-q|--quiet|-h|--help|--local)
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
      --local)
        # Target the gitignored per-worktree override instead of the
        # committed setup.toml.
        _is_local=1
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

  # Split <section>.<key> through conf.sh's _conf_split_nskey, the one
  # owner of that rule (first-dot, except the [logging.<svc>] per-service
  # sub-section, which splits rightmost-dot). A dotless spec names no
  # key, which `set` cannot act on.
  local _section _key
  if ! _conf_split_nskey "${_spec}" _section _key \
     || [[ -z "${_section}" || -z "${_key}" ]]; then
    _setup_msg usage set >&2
    return 1
  fi

  if ! _setup_known_section "${_section}"; then
    _log_err setup conf_section_not_found "display=$(_setup_msg errors unknown_section): ${_section}" "section=${_section}"
    return 2
  fi

  # A key no reader reads is refused before the write (base#1374).
  if ! _setup_known_key "${_section}" "${_key}"; then
    _setup_refuse_unknown_key set "${_section}" "${_key}"
    return
  fi

  if ! _setup_validate_kv "${_section}" "${_key}" "${_value}"; then
    _log_err setup conf_invalid_value "display=$(_setup_msg errors invalid_value): ${_section}.${_key} = ${_value}" "section=${_section}" "key=${_key}" "value=${_value}"
    return 2
  fi

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../../../.." && pwd -P)"
  fi

  # Writes target the committed per-repo override (setup.toml) by
  # default; --local targets the gitignored setup.local.toml.
  local _conf=""
  _setup_write_target "${_base_path}" "${_is_local}" _conf

  # Propagate writer refusal (e.g. a newline-bearing value) instead
  # of printing a misleading success message over a no-op / partial write.
  if ! _upsert_conf_value "${_conf}" "${_section}" "${_key}" "${_value}"; then
    _log_err setup conf_write_failed "display=$(_setup_msg errors invalid_value): ${_section}.${_key}" "section=${_section}" "key=${_key}"
    return 2
  fi

  if [[ "${_quiet}" -eq 0 ]]; then
    printf '[setup] set [%s] %s = %s\n' "${_section}" "${_key}" "${_value}"
    printf '[setup] file: %s\n' "${_conf}"
    printf "[setup] next: run 'just docker build' (auto-applies) or 'just docker setup apply' to regenerate .env / .env.generated / compose.yaml\n"
  fi

  # Diagnostics, not chatter: --quiet drops the receipt, never a warning
  # that the value just stored will not take effect.
  _setup_warn_shadowed_write "${_base_path}" "${_section}" "${_is_local}"
  _setup_warn_inert "${_base_path}" "${_section}" "${_key}"
}

# ════════════════════════════════════════════════════════════════════
# _setup_dump_section <section> <keys_arrayvar> <values_arrayvar>
#
# Prints "<key> = <value>" for every entry of the flat
# <keys>/<values> namespace-key view whose OWNING section is exactly
# <section>, in array order. Returns 1 when it printed nothing, so the
# caller raises its own not-found error.
#
# The single place `show` and `list` decide section membership. It asks
# `_conf_split_nskey` rather than prefix-matching "<section>." because
# the prefix cannot tell section `logging` + key `web.driver` from
# section `logging.web` + key `driver`: both readers used to bind a
# per-service override to the parent [logging] block as well as its
# own, listing one value twice under two sections.
# ════════════════════════════════════════════════════════════════════
_setup_dump_section() {
  local _sds_section="${1-}"
  local -n _sds_keys="${2:?"${FUNCNAME[0]}: missing keys arrayvar"}"
  local -n _sds_values="${3:?"${FUNCNAME[0]}: missing values arrayvar"}"

  local _sds_i _sds_sect _sds_key _sds_printed=0
  for (( _sds_i=0; _sds_i<${#_sds_keys[@]}; _sds_i++ )); do
    _conf_split_nskey "${_sds_keys[_sds_i]}" _sds_sect _sds_key || continue
    [[ "${_sds_sect}" == "${_sds_section}" ]] || continue
    printf '%s = %s\n' "${_sds_key}" "${_sds_values[_sds_i]}"
    _sds_printed=1
  done
  (( _sds_printed == 1 ))
}

# ════════════════════════════════════════════════════════════════════
# _setup_show
#
# Subcommand handler for `setup.sh show <section>[.<key>]`. Reads
# <base-path>/setup.toml via `_load_setup_conf_full` so output stays
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

  # Same split rule as `set` / `remove` (conf.sh owns it); unlike those,
  # a dotless spec is legal here and means "show the whole section".
  #
  # The dotless case is recognised from the SPEC, not from the split's
  # status. The splitter has two ways to answer non-zero -- no dot, and
  # a registry it cannot read (base#1185) -- and the old `|| treat the
  # whole spec as a section` read both as the first. That turned a
  # refusal into `show` trying to dump a section named
  # `logging.web.driver` and reporting `conf_section_not_found` for it,
  # which names the wrong problem.
  local _section _key
  if [[ "${_spec}" == *.* ]]; then
    _conf_split_nskey "${_spec}" _section _key || return 2
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

  # show reads the resolved view of the whole chain (template baseline <-
  # repo override <- local override). This is what `apply` would produce, so
  # users see effective values without having to re-run apply after every
  # set/add/remove -- and see the local layer's values where it has any.
  local -a _ss_sections=() _ss_keys=() _ss_values=()
  _setup_effective_full "${_base_path}" _ss_sections _ss_keys _ss_values

  local _i _ns_key="${_section}.${_key}"
  if [[ -n "${_key}" ]]; then
    for (( _i=0; _i<${#_ss_keys[@]}; _i++ )); do
      if [[ "${_ss_keys[_i]}" == "${_ns_key}" ]]; then
        printf '%s\n' "${_ss_values[_i]}"
        return 0
      fi
    done
    # `logging.<svc>` reads as BOTH a `<section>.<key>` spec (the split
    # above) and a section name `_setup_known_section` accepts, so a
    # section the tool calls legal was unreadable: the key lookup for
    # `logging.web` fails and there was nowhere else to look. Fall back
    # to dumping the spec as a section, but only when it names a known
    # section that has entries -- a plain typo (`logging.drivr`) still
    # reports the key, not the section, as missing. `set` / `remove` /
    # `add` keep the plain split: they must name a key.
    if _setup_known_section "${_spec}" \
       && _setup_dump_section "${_spec}" _ss_keys _ss_values; then
      return 0
    fi
    _log_err setup conf_key_not_found "display=$(_setup_msg errors key_not_found): ${_ns_key}" "key=${_ns_key}"
    return 1
  fi

  # Whole-section dump -- membership lives in _setup_dump_section.
  if ! _setup_dump_section "${_section}" _ss_keys _ss_values; then
    _log_err setup conf_section_not_found "display=$(_setup_msg errors section_not_found): ${_section}" "section=${_section}"
    return 1
  fi
  return 0
}

# ════════════════════════════════════════════════════════════════════
# _setup_list
#
# Subcommand handler for `setup.sh list [<section>]`. Without an arg,
# prints the entire setup.toml (in on-disk order, comments stripped)
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

  # list reads the resolved view of the whole chain -- same rationale as
  # `show`. Reflects what `apply` would materialize.
  local -a _ll_sections=() _ll_keys=() _ll_values=()
  _setup_effective_full "${_base_path}" _ll_sections _ll_keys _ll_values

  # Membership goes through _setup_dump_section for the same reason as
  # `show`'s dump, and it matters more here: the old `"${_sect}."*`
  # prefix put `logging.web.driver` in BOTH the [logging] block (as
  # `web.driver`) and [logging.web], emitting one value twice, so this
  # dump -- documented above as pipeable -- round-tripped into the
  # dotted-key-in-[logging] file _write_setup_conf refuses to write.
  # An empty section still gets its header (dump returns 1, ignored).
  local _sect _first=1
  for _sect in "${_ll_sections[@]}"; do
    if (( _first )); then
      _first=0
    else
      printf '\n'
    fi
    printf '[%s]\n' "${_sect}"
    _setup_dump_section "${_sect}" _ll_keys _ll_values || true
  done
}

# ════════════════════════════════════════════════════════════════════
# _setup_entry_label <section> <key> <value> <outvar>
#
# The entry `add` / `remove` touched, named the way setup.toml spells it.
# A key of an array-backed list (`volumes.mount_N`, `network.port_N`,
# `devices.cgroup_rule_N`, ...) is the N-th `[[<path>]]` block, so it is
# named by that header and its fields, comma-joined and rendered by the
# writer's own `_conf_toml_aot_fields`:
# `[[volumes]] source = "/foo", target = "/bar"`. The `mount_N` name is
# the CLI address and no key of that name is in the file (base#1354).
# Any other key is a key of its table (`[environment] env_N = <value>`),
# and keeps that form; an empty <value> prints the key alone.
#
# The fallback only: add and remove print _setup_toml_entry_label's
# reading of the file first, because this rebuild from the flattened
# value cannot tell a `[[tmpfs]]` size field or a `[[devices]]` header
# apart from the default shape.
# ════════════════════════════════════════════════════════════════════
_setup_entry_label() {
  local _sel_s="${1-}" _sel_k="${2-}" _sel_v="${3-}"
  local -n _sel_out="${4:?"${FUNCNAME[0]}: missing outvar"}"
  local _sel_p="" _sel_n="" _sel_f=""
  if _conf_toml_aot_slot "${_sel_s}" "${_sel_k}" _sel_p _sel_n; then
    _conf_toml_aot_fields "${_sel_p}" "${_sel_v}" _sel_f
    _sel_out="[[${_sel_p}]]${_sel_f:+ ${_sel_f//$'\n'/, }}"
    return 0
  fi
  _sel_out="[${_sel_s}] ${_sel_k}${_sel_v:+ = ${_sel_v}}"
}

# ════════════════════════════════════════════════════════════════════
# _setup_toml_kv_render <text> <outvar>
#
# One `key = value` field of setup.toml, which may span lines, printed on
# one line in the value TOML reads. Returns 1, leaving <outvar> alone,
# while <text> still ends inside a string or an open `[` / `{`: the
# caller appends the next line and asks again.
#
#   path = """          ->  path = "/tmp/x"
#   /tmp/x"""
#
# A `"""` string becomes the basic string it equals: the newline right
# after the opener is dropped, a line-ending backslash folds the next
# line in with its leading whitespace, a newline inside is `\n`, a lone
# `"` is `\"`, and an escape the file wrote is kept as written. A `'''`
# literal string becomes the same basic string, its `\` and `"` escaped.
# Outside a string, a comment is dropped and a run of whitespace or
# newlines is one space. Without this, the field line alone was printed
# -- `path = """` -- and the value removed was never named (base#1354).
# ════════════════════════════════════════════════════════════════════
_setup_toml_kv_render() {
  local _tkr_t="${1-}"
  local -n _tkr_out="${2:?"${FUNCNAME[0]}: missing outvar"}"
  local _tkr_o="" _tkr_st=n _tkr_c="" _tkr_rest="" _tkr_ws=""
  local -i _tkr_i=0 _tkr_d=0 _tkr_q=0 _tkr_len=${#_tkr_t}
  while (( _tkr_i < _tkr_len )); do
    _tkr_c="${_tkr_t:_tkr_i:1}"
    case "${_tkr_st}" in
      n)
        case "${_tkr_c}" in
          '"'|"'")
            if [[ "${_tkr_t:_tkr_i:3}" == "${_tkr_c}${_tkr_c}${_tkr_c}" ]]; then
              # A multi-line string opens; both kinds print as basic.
              [[ "${_tkr_c}" == '"' ]] && _tkr_st=mb || _tkr_st=ml
              _tkr_o+='"'
              _tkr_i+=3
              [[ "${_tkr_t:_tkr_i:2}" == $'\r\n' ]] && _tkr_i+=1
              [[ "${_tkr_t:_tkr_i:1}" == $'\n' ]] && _tkr_i+=1
              continue
            fi
            [[ "${_tkr_c}" == '"' ]] && _tkr_st=b || _tkr_st=l
            _tkr_o+="${_tkr_c}"
            ;;
          '#')
            _tkr_rest="${_tkr_t:_tkr_i}"
            _tkr_rest="${_tkr_rest%%$'\n'*}"
            _tkr_i+=${#_tkr_rest}
            continue
            ;;
          ' '|$'\t'|$'\r'|$'\n')
            [[ "${_tkr_o}" == *' ' ]] || _tkr_o+=' '
            ;;
          '['|'{') _tkr_d+=1; _tkr_o+="${_tkr_c}" ;;
          ']'|'}') _tkr_d+=-1; _tkr_o+="${_tkr_c}" ;;
          *) _tkr_o+="${_tkr_c}" ;;
        esac
        ;;
      b)
        if [[ "${_tkr_c}" == "\\" ]]; then
          _tkr_o+="${_tkr_t:_tkr_i:2}"
          _tkr_i+=2
          continue
        fi
        [[ "${_tkr_c}" == '"' ]] && _tkr_st=n
        _tkr_o+="${_tkr_c}"
        ;;
      l)
        [[ "${_tkr_c}" == "'" ]] && _tkr_st=n
        _tkr_o+="${_tkr_c}"
        ;;
      mb|ml)
        if [[ "${_tkr_c}" == '"' && "${_tkr_st}" == mb ]] \
            || [[ "${_tkr_c}" == "'" && "${_tkr_st}" == ml ]]; then
          # A run of the delimiter: its last three close the string, up
          # to two before them are content.
          _tkr_q=0
          while [[ "${_tkr_t:_tkr_i+_tkr_q:1}" == "${_tkr_c}" ]]; do
            _tkr_q+=1
          done
          _tkr_i+=_tkr_q
          if (( _tkr_q >= 3 )); then
            _tkr_q+=-3
            _tkr_st=n
          fi
          while (( _tkr_q > 0 )); do
            [[ "${_tkr_c}" == '"' ]] && _tkr_o+='\"' || _tkr_o+="'"
            _tkr_q+=-1
          done
          [[ "${_tkr_st}" == n ]] && _tkr_o+='"'
          continue
        fi
        case "${_tkr_c}" in
          "\\")
            if [[ "${_tkr_st}" == ml ]]; then
              _tkr_o+="\\\\"
            else
              _tkr_rest="${_tkr_t:_tkr_i+1}"
              _tkr_ws="${_tkr_rest%%[!$' \t\r']*}"
              if [[ "${_tkr_rest:${#_tkr_ws}:1}" == $'\n' ]]; then
                # Line-ending backslash: drop it and the whitespace and
                # newlines after it.
                _tkr_ws="${_tkr_rest%%[!$' \t\r\n']*}"
                _tkr_i+=$(( 1 + ${#_tkr_ws} ))
                continue
              fi
              _tkr_o+="${_tkr_t:_tkr_i:2}"
              _tkr_i+=2
              continue
            fi
            ;;
          '"') _tkr_o+='\"' ;;
          $'\r') [[ "${_tkr_t:_tkr_i+1:1}" == $'\n' ]] || _tkr_o+='\r' ;;
          $'\n') _tkr_o+='\n' ;;
          *) _tkr_o+="${_tkr_c}" ;;
        esac
        ;;
    esac
    _tkr_i+=1
  done
  [[ "${_tkr_st}" == n ]] && (( _tkr_d <= 0 )) || return 1
  _tkr_o="${_tkr_o#"${_tkr_o%%[! ]*}"}"
  _tkr_out="${_tkr_o%"${_tkr_o##*[! ]}"}"
}

# ════════════════════════════════════════════════════════════════════
# _setup_toml_entry_label <file> <section> <key> <outvar>
#
# The array-of-tables entry `<section>.<key>` names, read from <file> as
# it stands: the header the file uses and the field lines it holds,
# comma-joined -- `[[tmpfs]] path = "/tmp/x", size = "64m"`. Returns 1,
# leaving <outvar> alone, when <file> is not TOML, the key is not an
# array slot, or the file holds no such block.
#
# Why not _setup_entry_label: that one rebuilds the entry from the
# flattened value, and the flattening is lossy. A `[[tmpfs]]` block with
# separate `path` and `size` reads back as `/tmp/x:size=64m` and was
# reprinted as one `path`; a `[[devices]]` block (the other spelling of
# `device_N`) was reprinted as `[[devices.bindings]]`, a table the file
# does not have (base#1354). Blocks are counted per header path, the
# same way the writer addresses them (`_conf_toml_aot_nskey`).
#
# A field whose value spans lines (a `"""` or `'''` string, an array
# split over lines) is gathered whole and printed on one line by
# _setup_toml_kv_render; its continuation lines are never read as fields
# or headers, so a header-shaped line inside a string counts no block.
# ════════════════════════════════════════════════════════════════════
_setup_toml_entry_label() {
  local _stel_f="${1-}" _stel_want="${2-}.${3-}"
  local -n _stel_out="${4:?"${FUNCNAME[0]}: missing outvar"}"
  [[ "${_stel_f}" == *.toml && -f "${_stel_f}" ]] || return 1
  local -A _stel_seen=()
  local _stel_line _stel_h _stel_p _stel_k _stel_in=0 _stel_hit=0
  local _stel_hdr="" _stel_fields="" _stel_buf="" _stel_r=""
  while IFS= read -r _stel_line || [[ -n "${_stel_line}" ]]; do
    # A continuation line of a value still open: part of that field.
    if [[ -n "${_stel_buf}" ]]; then
      _stel_buf+=$'\n'"${_stel_line}"
      _setup_toml_kv_render "${_stel_buf}" _stel_r || continue
      _stel_buf=""
      (( _stel_in )) && _stel_fields+="${_stel_fields:+, }${_stel_r}"
      continue
    fi
    _conf_toml_header_uncomment "${_stel_line}" _stel_h
    if [[ "${_stel_h}" =~ ^[[:space:]]*\[ ]]; then
      (( _stel_in )) && break
      [[ "${_stel_h}" =~ ^[[:space:]]*\[\[(.+)\]\][[:space:]]*$ ]] || continue
      _conf_header_name "${BASH_REMATCH[1]}" _stel_p
      _stel_seen["${_stel_p}"]=$(( ${_stel_seen["${_stel_p}"]:-0} + 1 ))
      _conf_toml_aot_nskey "${_stel_p}" "${_stel_seen["${_stel_p}"]}" _stel_k \
        || continue
      if [[ "${_stel_k}" == "${_stel_want}" ]]; then
        _stel_in=1
        _stel_hit=1
        _stel_hdr="[[${_stel_p}]]"
      fi
      continue
    fi
    _conf_is_kv_line "${_stel_line}" || continue
    # Only a line that can open a multi-line value is scanned; every
    # other field line is printed as written. Lines outside the wanted
    # block are scanned too, so their continuations are skipped.
    if [[ "${_stel_line}" == *[\[\{]* || "${_stel_line}" == *'"""'* \
          || "${_stel_line}" == *"'''"* ]]; then
      if ! _setup_toml_kv_render "${_stel_line}" _stel_r; then
        _stel_buf="${_stel_line}"
        continue
      fi
      _stel_line="${_stel_r}"
    fi
    (( _stel_in )) || continue
    _stel_line="${_stel_line#"${_stel_line%%[![:space:]]*}"}"
    _stel_line="${_stel_line%"${_stel_line##*[![:space:]]}"}"
    _stel_fields+="${_stel_fields:+, }${_stel_line}"
  done < "${_stel_f}"
  (( _stel_hit )) || return 1
  _stel_out="${_stel_hdr}${_stel_fields:+ ${_stel_fields}}"
}

# ════════════════════════════════════════════════════════════════════
# _setup_add
#
# Subcommand handler for `setup.sh add <section>.<list> <value>`.
# Finds the next available numeric suffix N (max-existing + 1, or 1
# when the section has no entries with that prefix) and writes
# `<list>_N = <value>` via `_upsert_conf_value`. Bootstraps setup.toml
# from the template default if absent so first-time users can `add`
# before they ever ran `apply`. Validators fire through
# `_setup_validate_kv` against the synthesized key, so e.g.
# `add volumes.mount` enforces the same `_validate_mount` that
# `set volumes.mount_3` does. Does NOT regenerate .env.generated.
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
  local _is_local=0

  while [[ $# -gt 0 ]]; do
    # Once <spec> is captured, the next bare arg is the value, even if
    # it begins with '-' (e.g. negative numbers shouldn't be parsed as
    # flags). Same shape as _setup_set.
    if [[ -n "${_spec}" && "${_have_value}" -eq 0 ]]; then
      case "$1" in
        --base-path|--lang|-q|--quiet|-h|--help|--local)
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
      --local)
        # Target the gitignored per-worktree override instead of the
        # committed setup.toml.
        _is_local=1
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

  # Same split rule as `set` / `show` / `remove`: conf.sh's
  # _conf_split_nskey is the one owner (first dot, except the
  # per-service [logging.<svc>] sub-section, which splits at the
  # rightmost). `add` names <section>.<list> rather than
  # <section>.<key>, but the question -- which section does this spec
  # name? -- is the same one, so it is asked in the same place.
  # Re-deriving it here is what sent `add logging.web.<list>` to the
  # parent [logging] block as a dotted `web.<list>_N` key. A dotless
  # spec names no list, which `add` cannot act on.
  local _section _list
  if ! _conf_split_nskey "${_spec}" _section _list \
     || [[ -z "${_section}" || -z "${_list}" ]]; then
    _setup_msg usage add >&2
    return 1
  fi

  if ! _setup_known_section "${_section}"; then
    _log_err setup conf_section_not_found "display=$(_setup_msg errors unknown_section): ${_section}" "section=${_section}"
    return 2
  fi

  # A family is judged by the row its first entry would take, as apply
  # judges an empty array, so a family no reader reads is refused before
  # the write instead of at the next apply (base#1374).
  if ! _setup_known_key "${_section}" "${_list}_1"; then
    _setup_refuse_unknown_key add "${_section}" "${_list}"
    return
  fi

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../../../.." && pwd -P)"
  fi
  # Writes target the committed per-repo override (setup.toml) by
  # default; --local targets the gitignored setup.local.toml.
  local _conf=""
  _setup_write_target "${_base_path}" "${_is_local}" _conf

  # Scan keys[] for "<section>.<list>_<digits>". Pick the first slot
  # whose value is empty (reuses placeholder slots from the template
  # default, matches the TUI's `_edit_list_section` behaviour); fall
  # back to max+1 when every populated slot has content. Reads the
  # merged effective view (template ← repo override) so the new index
  # lands past any inherited template slot the user hasn't yet bumped.
  # The read goes through the format-dispatching reader: on a TOML file
  # the numbered keys are `[[array of tables]]` blocks the bridge numbers
  # back, which the INI tokenizer cannot see, and a slot computed from
  # an empty view is always 1 -- every `add` would overwrite the first
  # entry instead of appending.
  # THE EFFECTIVE LIST, and it is a real merge of the layers AT OR BELOW
  # the write target. The paragraph above always claimed this; the code
  # under it was an if/elif that took the target file's OWN section
  # whenever that section had any key at all -- "replace strategy: only
  # .local entries exist for this section" -- which was true under the
  # pre-ADR-37 blanket section-replace and is not true now. Measured: a
  # repo `setup.toml` carrying only `[build] network = "host"` inherits
  # the template's three build arguments, and `add build.arg FOO=bar`
  # read the repo section, chose `arg_1`, and wrote an array of ONE --
  # which array-replace then made the whole effective list. The two
  # mirrors and the timezone were gone, from a command whose entire job
  # is to append.
  #
  # AT OR BELOW, not the whole chain: materialising a layer ABOVE the
  # target would copy it down. For a write to the committed `setup.toml`
  # the baseline is template + repo, so the operator's gitignored
  # `setup.local.toml` entries are never written into the file everyone
  # else gets.
  local -a _sects=() _keys=() _vals=()
  local -a _local_k=() _local_v=()
  _parse_conf_section "${_conf}" "${_section}" _local_k _local_v

  local -a _sa_layers=() _sa_below=()
  _setup_conf_layers "${_base_path}" _sa_layers
  if (( _is_local )); then
    _sa_below=("${_sa_layers[@]}")
  else
    _sa_below=("${_sa_layers[@]:0:${#_sa_layers[@]}-1}")
  fi
  # A FAILED READ IS NOT AN EMPTY LIST. Taken as one, the slot search
  # below finds no entry, picks index 1, and the write lands on top of
  # whatever is already there while reporting success -- an `add` that
  # overwrites. `_conf_load_layers` has already said what went wrong
  # (`conf_toml_merge_failed`: it refuses to report an empty
  # configuration as a loaded one), so this stops BEFORE any write
  # rather than restating the cause.
  if ! _conf_load_layers _SETUP_ADD_EFF "${_sa_below[@]}"; then
    _log_err setup conf_write_failed \
      "display=$(_setup_msg errors invalid_value): ${_section}.${_list} -- the effective configuration could not be read, so the slot to append at is unknown and nothing was written" \
      "section=${_section}" "key=${_list}"
    return 2
  fi
  local -n _sa_es=_SETUP_ADD_EFF__es
  local -n _sa_k=_SETUP_ADD_EFF__keys
  local -n _sa_v=_SETUP_ADD_EFF__vals
  local _ei
  for (( _ei=0; _ei<${#_sa_k[@]}; _ei++ )); do
    [[ "${_sa_es[_ei]}" == "${_section}" ]] || continue
    _keys+=("${_section}.${_sa_k[_ei]}")
    _vals+=("${_sa_v[_ei]}")
  done
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

  # MATERIALISE WHAT THIS LAYER WOULD OTHERWISE DROP, before appending.
  # An array is replaced whole by the highest layer that defines it
  # (ADR-00000037), so the moment this file declares one it owes the
  # FULL list -- an append that writes only the new entry is a
  # replacement of everything below. Each inherited entry the target
  # does not already carry is written first, at the index it holds in the
  # effective view, so the positions the list readers sort by are the
  # ones the merge produced.
  #
  # An empty effective entry is skipped: it is a cleared slot (the
  # workspace opt-out is exactly that) and writing it back as a value
  # would be inventing one. The slot keeps its position either way --
  # that is what the writer's field-less padding is for.
  #
  # EVERY index, not only the ones below the new one. When the new entry
  # REUSES an empty slot -- which is this function's documented
  # preference, so a template placeholder gets filled rather than
  # appended past -- the entries that matter sit AFTER it. A committed
  # array whose first block is empty and whose second is `KEEP=yes` lost
  # `KEEP=yes` entirely to `add --local`: the local layer declared an
  # array of one and replaced the whole inherited list. The loop stops
  # at `_max`, which is the highest index the effective view holds, and
  # skips `_new_idx` because that slot is the one being written below.
  local _mi _mval _mown _mj
  for (( _mi = 1; _mi <= _max; _mi++ )); do
    (( _mi == _new_idx )) && continue
    _mval=""
    for (( _mj=0; _mj<${#_keys[@]}; _mj++ )); do
      if [[ "${_keys[_mj]}" == "${_section}.${_list}_${_mi}" ]]; then
        _mval="${_vals[_mj]}"
        break
      fi
    done
    [[ -n "${_mval}" ]] || continue
    _mown=""
    for (( _mj=0; _mj<${#_local_k[@]}; _mj++ )); do
      if [[ "${_local_k[_mj]}" == "${_list}_${_mi}" ]]; then
        _mown="${_local_v[_mj]}"
        break
      fi
    done
    [[ "${_mown}" == "${_mval}" ]] && continue
    if ! _upsert_conf_value "${_conf}" "${_section}" "${_list}_${_mi}" "${_mval}" "${_CONF_ADD_TABLE_NOTE}"; then
      _log_err setup conf_write_failed "display=$(_setup_msg errors invalid_value): ${_section}.${_list}_${_mi}" "section=${_section}" "key=${_list}_${_mi}"
      return 2
    fi
  done

  if ! _upsert_conf_value "${_conf}" "${_section}" "${_new_key}" "${_value}" "${_CONF_ADD_TABLE_NOTE}"; then
    _log_err setup conf_write_failed "display=$(_setup_msg errors invalid_value): ${_section}.${_new_key}" "section=${_section}" "key=${_new_key}"
    return 2
  fi

  if [[ "${_quiet}" -eq 0 ]]; then
    # Read back from the file just written, so the line names the entry
    # as it landed there; a non-array key falls back to `[sect] key = v`.
    local _sa_label=""
    _setup_toml_entry_label "${_conf}" "${_section}" "${_new_key}" _sa_label \
      || _setup_entry_label "${_section}" "${_new_key}" "${_value}" _sa_label
    printf '[setup] add %s\n' "${_sa_label}"
    printf '[setup] file: %s\n' "${_conf}"
    printf "[setup] next: run 'just docker build' (auto-applies) or 'just docker setup apply' to regenerate .env / .env.generated / compose.yaml\n"
  fi

  # Same diagnostics as `set` -- `add network.port` is the other way in,
  # and an append to a shadowed section is just as inert as an assignment.
  _setup_warn_shadowed_write "${_base_path}" "${_section}" "${_is_local}"
  _setup_warn_inert "${_base_path}" "${_section}" "${_new_key}"
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
# .env.generated.
#
# RENUMBERING, for a TOML destination: it happens. This paragraph used to
# say the opposite -- "Does NOT renumber remaining keys
# (`_load_setup_conf_full` tolerates gaps, and downstream callers treat
# the prefix list as unordered)" -- and both halves are false here.
# `_conf_toml_aot_slot` maps `<section>.<prefix>_N` onto the N-th
# `[[path]]` block, so the array is dense by construction: conf.sh's
# writer header states that a removed entry COMPACTS the ones after it,
# and conf_toml_writer_spec's "a TOML rewrite with scalar, array, removed
# and new-section overrides parses and reads back" pins it -- what the
# fixture wrote as `mount_2` reads back as `mount_1`. Nor is the prefix
# list unordered: every reader of one sorts it by the numeric suffix
# (`_conf_list_sorted`).
#
# That matters for exactly one slot, and that one is REFUSED. The
# workspace bind is slot 1 of `[volumes]` and nothing else marks it, so
# `remove volumes.mount_1` on a TOML repo would compact whatever was slot
# 2 into the workspace position -- silently, when its source exists
# locally, because an absolute path that exists reads as a deliberately
# pinned workspace. `_write_setup_conf` declines that save before it
# builds the rewrite (`_wsc_refuse_ws_slot_move`), so the failure branch
# below reports it and the file is unchanged. It declines ONLY the case
# that promotes something: removing the one and only mount, or any mount
# above slot 1, still succeeds. To stop mounting a workspace the operator
# CLEARS mount_1 -- the published opt-out, which moves no other slot --
# and the refusal's message says so.
#
# base#1233 still carries how the workspace bind should be identified;
# the refusal contains the edit without answering that.
#
# For an INI destination the old paragraph was right: remaining keys keep
# their suffixes and a gap is tolerated.
#
# Usage: _setup_remove <section>.<key>            [--base-path] [--lang]
#        _setup_remove <section>.<list> <value>   [--base-path] [--lang]
# ════════════════════════════════════════════════════════════════════
_setup_remove() {
  local _base_path=""
  local _spec="" _value="" _have_value=0
  local _quiet=0
  local _is_local=0

  while [[ $# -gt 0 ]]; do
    if [[ -n "${_spec}" && "${_have_value}" -eq 0 ]]; then
      case "$1" in
        --base-path|--lang|-q|--quiet|-h|--help|--local)
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
      --local)
        # Target the gitignored per-worktree override instead of the
        # committed setup.toml.
        _is_local=1
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

  # Same split rule as `set` (conf.sh owns it): a dotless spec names no
  # key, and `remove` needs one.
  local _section _rest
  if ! _conf_split_nskey "${_spec}" _section _rest \
     || [[ -z "${_section}" || -z "${_rest}" ]]; then
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
  # remove operates on ONE layer: the committed setup.toml by default,
  # setup.local.toml under --local. If that file doesn't exist there is
  # nothing to remove -- neither the template baseline nor the other layer
  # is a removable input from here.
  local _conf="${_base_path}/setup.toml"
  (( _is_local )) && _conf="$(_setup_conf_local_path "${_base_path}")"
  if [[ ! -f "${_conf}" ]]; then
    _log_err setup conf_key_not_found "display=$(_setup_msg errors key_not_found): ${_spec}" "key=${_spec}"
    return 1
  fi

  # A layer that is there but cannot be parsed has already been reported
  # by the tokenizer (conf_toml_parse_failed); searching its empty
  # projection would add a false conf_key_not_found (base#1398).
  local -a _sects=() _keys=() _vals=()
  _load_setup_conf_full "${_conf}" _sects _keys _vals || return 1

  local _target_key="" _target_val="" _i
  if (( _have_value )); then
    # Remove-by-value: scan for first <section>.<rest>_* with matching value.
    for (( _i=0; _i<${#_keys[@]}; _i++ )); do
      if [[ "${_keys[_i]}" == "${_section}.${_rest}_"* ]] \
         && [[ "${_vals[_i]}" == "${_value}" ]]; then
        _target_key="${_keys[_i]#"${_section}".}"
        _target_val="${_vals[_i]}"
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
        _target_val="${_vals[_i]}"
        break
      fi
    done
    if (( ! _found )); then
      _log_err setup conf_key_not_found "display=$(_setup_msg errors key_not_found): ${_spec}" "key=${_spec}"
      return 1
    fi
    _target_key="${_rest}"
  fi

  # The entry's label is read BEFORE the write: afterwards the block is
  # gone, and rebuilding it from the flattened value names a different
  # entry (_setup_toml_entry_label's header says how).
  local _sr_label=""
  _setup_toml_entry_label "${_conf}" "${_section}" "${_target_key}" _sr_label \
    || _setup_entry_label "${_section}" "${_target_key}" "${_target_val}" _sr_label

  # _write_setup_conf truncates dst before reading tpl, so when dst==src
  # we'd lose data. Stage current contents into a sibling temp file and
  # use that as the read source.
  local _tmp
  _tmp="$(mktemp "${_conf}.XXXXXX")"
  cp "${_conf}" "${_tmp}"
  local -a _empty_k=() _empty_v=()
  # The writer's answer is READ. It was discarded, so a refusal -- the
  # rewrite did not parse, or the key it was told to remove is still
  # there -- printed the success lines below anyway, and the operator was
  # told a removal had happened that had not.
  if ! _write_setup_conf "${_conf}" "${_tmp}" \
      _empty_k _empty_v "${_section}.${_target_key}"; then
    rm -f "${_tmp}"
    _log_err setup conf_write_failed \
      "display=$(_setup_msg errors invalid_value): ${_section}.${_target_key} -- the writer declined and named why above; nothing was removed" \
      "section=${_section}" "key=${_target_key}"
    return 2
  fi
  rm -f "${_tmp}"

  if [[ "${_quiet}" -eq 0 ]]; then
    printf '[setup] remove %s\n' "${_sr_label}"
    printf '[setup] file: %s\n' "${_conf}"
    printf "[setup] next: run 'just docker build' (auto-applies) or 'just docker setup apply' to regenerate .env / .env.generated / compose.yaml\n"
  fi

  _setup_warn_shadowed_write "${_base_path}" "${_section}" "${_is_local}"
}

# ════════════════════════════════════════════════════════════════════
# _setup_reset
#
# Subcommand handler for `setup.sh reset [--yes]`. Overwrites the
# repo's setup.toml with the template default, archiving the prior
# setup.toml to setup.toml.bak and the prior .env to .env.bak so the
# user has a one-shot rollback path. Mirrors what `build.sh
# --reset-conf` does today, but exposes it as a setup.sh subcommand
# for scripted use.
#
# Does NOT regenerate .env.generated. The user invokes `apply` afterwards (or
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

  # reset clears the per-repo override (setup.toml) so the next `apply`
  # rebuilds .env / .env.generated / compose.yaml purely from the template
  # baseline. The workspace mount_1 is re-detected and re-written via the
  # bootstrap path on the next apply. `.env.local` is the operator's file
  # and is intentionally left untouched by reset.
  local _conf="${_base_path}/setup.toml"
  local _env="${_base_path}/.env.generated"
  local _tpl_conf="${_SETUP_SCRIPT_DIR}/../../../setup.toml"
  if [[ ! -f "${_tpl_conf}" ]]; then
    _log_err setup conf_template_missing "display=template setup.toml not found at ${_tpl_conf}" "path=${_tpl_conf}"
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
    printf "[setup] next: run 'just docker build' (auto-applies) or 'just docker setup apply' to regenerate .env / .env.generated / compose.yaml\n"
  fi
}

# ════════════════════════════════════════════════════════════════════
# _setup_apply_commit <stage_dir> <staged> <target> [<staged> <target>]...
#
# Move each staged file onto its target, as one unit (base#1270).
# Returns 0 when every target now holds its staged file. Otherwise every
# target is left as it was before the call and the return is non-zero:
#
#   - a target that exists and is not a regular file (a directory, a
#     symlink, a fifo) is refused before anything is moved: `mv` onto a
#     directory puts the file INSIDE it and still exits 0;
#   - every existing target is copied into <stage_dir>/prev first, and a
#     failed copy refuses before anything is moved;
#   - a move that fails, or that does not leave a regular file at the
#     target with the staged file gone, puts back every target the
#     earlier moves replaced (or removes it, where there was none).
#
# Return 1: refused or rolled back; the caller removes <stage_dir>.
# Return 2: a restore itself failed. The copies under <stage_dir>/prev
# are then the only record of the previous set, the error names them,
# and the caller must leave <stage_dir> in place.
# ════════════════════════════════════════════════════════════════════
_setup_apply_commit() {
  local _sac_stage="${1:?"${FUNCNAME[0]}: missing stage dir"}"
  shift
  local -a _sac_src=() _sac_dst=() _sac_had=()
  while (( $# >= 2 )); do
    _sac_src+=("$1")
    _sac_dst+=("$2")
    shift 2
  done
  local _sac_n="${#_sac_dst[@]}" _i _d

  for (( _i = 0; _i < _sac_n; _i++ )); do
    _d="${_sac_dst[_i]}"
    if [[ -L "${_d}" ]] || { [[ -e "${_d}" ]] && [[ ! -f "${_d}" ]]; }; then
      _log_err setup apply_output_unusable \
        "display=[setup] apply: ${_d} exists and is not a regular file; apply writes a regular file there. Move it aside and re-run. Nothing was written" \
        "path=${_d}"
      return 1
    fi
  done

  local _sac_prev="${_sac_stage}/prev"
  if ! mkdir -- "${_sac_prev}"; then
    _log_err setup apply_commit_failed \
      "display=[setup] apply: could not create ${_sac_prev} to hold the previous set; nothing was written" \
      "path=${_sac_prev}"
    return 1
  fi
  for (( _i = 0; _i < _sac_n; _i++ )); do
    _d="${_sac_dst[_i]}"
    _sac_had[_i]=0
    [[ -e "${_d}" ]] || continue
    if ! cp -p -- "${_d}" "${_sac_prev}/${_i}"; then
      _log_err setup apply_commit_failed \
        "display=[setup] apply: could not copy ${_d} aside before replacing it; nothing was written" \
        "path=${_d}"
      return 1
    fi
    _sac_had[_i]=1
  done

  local _sac_failed=-1
  for (( _i = 0; _i < _sac_n; _i++ )); do
    _d="${_sac_dst[_i]}"
    if [[ -d "${_d}" ]] \
        || ! mv -f -- "${_sac_src[_i]}" "${_d}" \
        || [[ -L "${_d}" || ! -f "${_d}" || -e "${_sac_src[_i]}" ]]; then
      _sac_failed="${_i}"
      break
    fi
  done
  (( _sac_failed < 0 )) && return 0

  # Roll back the failed move and every one before it, newest first.
  local -a _sac_lost=()
  local _j
  for (( _j = _sac_failed; _j >= 0; _j-- )); do
    _d="${_sac_dst[_j]}"
    if (( _sac_had[_j] )); then
      if [[ -d "${_d}" ]] || ! mv -f -- "${_sac_prev}/${_j}" "${_d}"; then
        _sac_lost+=("${_d}")
      fi
    elif [[ -L "${_d}" || -f "${_d}" ]]; then
      rm -f -- "${_d}" || _sac_lost+=("${_d}")
    fi
  done
  if (( ${#_sac_lost[@]} > 0 )); then
    _log_err setup apply_rollback_incomplete \
      "display=[setup] apply: could not move the new ${_sac_dst[_sac_failed]} into place, and could not restore ${_sac_lost[*]}; the previous files are in ${_sac_prev}, numbered in the order ${_sac_dst[*]}" \
      "path=${_sac_dst[_sac_failed]}" "prev=${_sac_prev}"
    return 2
  fi
  _log_err setup apply_commit_failed \
    "display=[setup] apply: could not move the new ${_sac_dst[_sac_failed]} into place; the previous files were restored and nothing was changed" \
    "path=${_sac_dst[_sac_failed]}"
  return 1
}

# ════════════════════════════════════════════════════════════════════
# _setup_apply
#
# Subcommand handler for `setup.sh apply`. Regenerates .env.generated +
# compose.yaml from setup.toml + system detection. Other subcommands
# (set/add/remove/reset) intentionally do NOT regen — apply is the
# explicit gate.
#
# Usage: _setup_apply [-h|--help] [--base-path <path>] [--lang <code>]
#                     [--local-conf <file>] [--output|-o <dir>]
#
# The devel half of ADR-00000036's parameterised generate API. `--output`
# names the directory the emitted set is written into and `--local-conf`
# names the file read as the conf chain's top layer, so an orchestrator
# calls this N times against ONE repo -- each call carrying that
# instance's parameters, each writing a complete set of its own, and none
# of them writing into the repo. `deploy` already named its own output
# directory; this is the stage that could only write where it read.
# ════════════════════════════════════════════════════════════════════
_setup_apply() {
  local _base_path=""
  local _quiet=0
  # Empty means the repo itself, which is every existing checkout. The
  # companion flags record that the option was SUPPLIED: `--output=` and
  # `--local-conf=` parse to the empty string, and reading that as "not
  # given" would turn both refusal contracts off from the command line --
  # an empty address falling back to the repo's own local layer, and an
  # empty output directory writing the set into the repo.
  local _output="" _output_set=0
  local _local_conf="" _local_conf_set=0
  # per-invocation overrides. Empty means "use setup.toml /
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
      --output|-o)
        _output="${2:?"--output requires a value"}"
        _output_set=1
        shift 2
        ;;
      --output=*)
        _output="${1#--output=}"
        _output_set=1
        shift
        ;;
      --local-conf)
        _local_conf="${2:?"--local-conf requires a value"}"
        _local_conf_set=1
        shift 2
        ;;
      --local-conf=*)
        _local_conf="${1#--local-conf=}"
        _local_conf_set=1
        shift
        ;;
      *)
        _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
        return 1
        ;;
    esac
  done

  # The addressed local layer, checked before anything is detected or
  # written: an address that cannot be read would otherwise leave the
  # chain one layer short, and a chain one layer short emits the template
  # defaults and reports success. Declared `local` so one call's
  # parameters cannot leak into the next one's.
  local _SETUP_CONF_LOCAL="${_SETUP_CONF_LOCAL:-}"
  if (( _local_conf_set )); then
    _setup_conf_local_check "${_local_conf}" || return 1
    _SETUP_CONF_LOCAL="${_local_conf}"
  fi

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

  # A table or key no reader knows is refused before anything is
  # written, naming the layer it is in (base#1328).
  _setup_conf_check_known "${_base_path}" || return 1

  # Where the emitted set goes. The repo itself with no --output, which is
  # every existing checkout and leaves that path byte-identical; otherwise
  # the directory the caller named, created if it is not there. A path
  # occupied by something that is not a directory is REFUSED up front: the
  # writes below would fail one at a time, after the detections and after
  # part of the set had been emitted, leaving a half-written bundle and a
  # caller told nothing useful.
  local _out_dir="${_base_path}"
  if (( _output_set )); then
    if [[ -z "${_output}" ]]; then
      _log_err setup apply_output_unusable \
        "display=[setup] apply: --output was given an empty path; refusing to fall back to writing the set into the repo" \
        "path="
      return 1
    fi
    if [[ -e "${_output}" && ! -d "${_output}" ]]; then
      _log_err setup apply_output_unusable \
        "display=[setup] apply: --output ${_output} exists and is not a directory; refusing to emit a partial set into it" \
        "path=${_output}"
      return 1
    fi
    if ! mkdir -p -- "${_output}" 2>/dev/null; then
      _log_err setup apply_output_unusable \
        "display=[setup] apply: --output ${_output} could not be created; refusing to report a generated set that was never written" \
        "path=${_output}"
      return 1
    fi
    _out_dir="$(cd -- "${_output}" && pwd -P)"
  fi

  # "The repo is not mutated by a call" is a property of the whole apply,
  # not of its writers: _reconcile_workspace_path rewrites
  # <repo>/setup.toml on first-time bootstrap and when mount_1 carries an
  # absolute path that is stale on this machine. Both are right for a
  # developer's own apply and wrong for an orchestrator's Nth call, which
  # must not race the other N-1 over one file.
  #
  # Two halves, because neither alone is both safe and complete.
  #
  # The bootstrap -- no <repo>/setup.toml at all -- is PREVENTED below,
  # before the reconciliation runs, by requiring the repo's own layer to
  # exist. That is the case an orchestrator actually hits (a fresh clone
  # it has not applied yet) and the only one where nothing can be done
  # after the fact: the file is already there.
  #
  # Everything else is DETECTED, by photographing the whole chain rather
  # than enumerating the two sites that write to it today -- a third one
  # added later would pass an enumeration forever, the declared-population
  # failure this tree keeps finding. The population is
  # _setup_conf_layers', so a new layer is covered the day it exists.
  #
  # Detected and refused, NOT rolled back. A rollback attributes every
  # write in the window to this call, and the window contains other
  # processes: a concurrent `setup set`, a plain apply, the operator
  # editing a layer, or an edit to the caller's own local file would all
  # be silently discarded by restoring the photograph. Refusing leaves the
  # change in place and says so; discarding someone else's write to
  # protect the repo from this one is the worse of the two.
  local -a _ap_chain=()
  local -A _ap_chain_pre=()
  if (( _output_set )); then
    _setup_conf_layers "${_base_path}" _ap_chain || return 1
    _setup_conf_chain_snapshot _ap_chain _ap_chain_pre
  fi

  # File roles under the one naming rule (the standard name is ours, a
  # suffix marks a local variant): `.env.generated` is the derived
  # interpolation cache, `.env` is the container-env defaults we ship, and
  # `.env.local` is the operator's overrides -- the only one of the three
  # this function never writes after scaffolding it.
  local _env_file="${_out_dir}/.env.generated"
  local _container_env_file="${_out_dir}/.env"
  local _env_local_file="${_out_dir}/.env.local"
  local _compose_file="${_out_dir}/compose.yaml"
  # The cache the prior values are read from. Normally `.env.generated`;
  # the legacy layout below reads it from `.env` instead.
  local _prior_env_file="${_env_file}"
  local _legacy_cache=0

  # Migrate a layout where .env WAS the cache: if no
  # .env.generated exists yet but .env carries the setup.sh auto-gen
  # marker, it is a stale cache, not a user overlay. Its values are the
  # prior values below; once the new set is committed it is backed up to
  # `.env.bak` and replaced by the regenerated `.env` and `.env.generated`.
  # Nothing is moved before then, so a refused apply leaves it as it was
  # (base#1270).
  if [[ ! -f "${_env_file}" && -f "${_container_env_file}" ]] \
      && grep -q '^SETUP_CONF_HASH=' "${_container_env_file}" 2>/dev/null; then
    _prior_env_file="${_container_env_file}"
    _legacy_cache=1
  fi

  if [[ -f "${_prior_env_file}" ]]; then
    set -o allexport
    # shellcheck disable=SC1090
    source "${_prior_env_file}"
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

  # ── Load setup.toml sections ──
  # Only the sections apply still consumes directly are read here:
  # [build] (build args / target_arch), [volumes] (WS_PATH + extra_volumes),
  # [security] (the propagation guard re-reads privileged), and
  # [additional_contexts]. Every docker/build scalar + list-string the
  # compose call needs (gpu / gui / network / devices / env / tmpfs /
  # ports / caps / shm / restart / dri / build_network) is resolved by the
  # shared _resolve_deploy_context below (S6b,), which loads its own
  # sections -- the same resolver the deploy generator uses, so the field
  # deploy can never drift from apply.
  #
  # Parse the merged conf ONCE into an opaque handle, then
  # read [build] / [security] / [additional_contexts] from it via the
  # _conf_get_into / _conf_list_sorted accessors -- replacing three
  # per-section _load_setup_conf calls that each re-tokenized the whole conf
  # (same merge precedence). [volumes] is NOT read from
  # this handle: _reconcile_workspace_path mutates its parallel arrays in
  # place and reloads them after a mount_1 rewrite (bootstrap / stale path),
  # so it keeps a dedicated single-section load that stays in sync with the
  # committed conf a handle built here would go stale against.
  _setup_conf_handle "${_base_path}" _APPLY_CONF
  local -a _vol_k=() _vol_v=()
  _load_setup_conf "${_base_path}" "volumes" _vol_k _vol_v

  # Build args: each `[build] arg_N = KEY=VALUE` entry becomes a
  # compose build.arg. Empty VALUE means "do not override" — let
  # compose.yaml's `${VAR:-<default>}` fallback pick the Dockerfile
  # default (archive.ubuntu.com for APT, Asia/Taipei for TZ, etc.).
  local -a _build_args=()
  _conf_list_sorted _APPLY_CONF build "arg_" _build_args

  # The old named-key schema (apt_mirror_ubuntu = …, tz = …) is lifted
  # into the arg_N list -- but ONLY when no layer of the chain supplies
  # arg_N at all, which is what the guard below says. The shipped
  # template always supplies [[build.args]], and an upper layer that
  # says nothing about the array inherits it, so from `apply` this
  # branch does not fire: a repo setup.toml still carrying the named
  # keys gets the template's build args, not its own named values.
  #
  # That is deliberately stated as what HAPPENS, not as a promise. These
  # keys are not on the deprecation schedule -- doc/deprecations.md lists
  # only `[deploy] runtime`, and only that pair gets the per-layer alias
  # precedence the merge applies. A repo on the pre-arg_N schema has to
  # move its values into [[build.args]].
  if (( ${#_build_args[@]} == 0 )); then
    local _bc_v=""
    _conf_get_into _APPLY_CONF build apt_mirror_ubuntu "" _bc_v
    [[ -n "${_bc_v}" ]] && _build_args+=("APT_MIRROR_UBUNTU=${_bc_v}")
    _bc_v=""
    _conf_get_into _APPLY_CONF build apt_mirror_debian "" _bc_v
    [[ -n "${_bc_v}" ]] && _build_args+=("APT_MIRROR_DEBIAN=${_bc_v}")
    _bc_v=""
    _conf_get_into _APPLY_CONF build tz "" _bc_v
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
  _conf_get_into _APPLY_CONF build target_arch "" target_arch

  # Build-time network override: scalar `[build] network`. Empty =
  # docker default (bridge). Non-empty = passed as `build.network` in
  # compose.yaml and `--network <value>` to the auxiliary test-tools
  # docker build. Typical value: `host`, for hosts whose docker bridge
  # NAT is unusable (stripped embedded kernels, iptables:false).
  # ── Resolve conf-derived docker/build params via the shared layer ──
  # S6b: _resolve_deploy_context is the single conf resolution that
  # both apply and the deploy generator use, so the field deploy never
  # drifts from what apply produces for the same setup.toml. Its record is
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
  # [lifecycle] restart is deploy-scoped: generate_compose_yaml routes it to
  # the deployable stage services only, never to devel (a devel container is
  # the interactive shell -- see _emit_restart_line / _is_deployable_stage).
  local restart_policy="${_dctx[restart_policy]}"
  local init="${_dctx[init]}"
  local watchdog_env_str="${_dctx[watchdog_env_str]}"
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
  # First-time bootstrap (no <repo>/setup.toml) copies the template and
  # writes mount_1 in the portable form.
  local _repo_conf="${_base_path}/setup.toml"
  # The WS_PATH / mount_1 reconciliation state machine. Mutates
  # _vol_k / _vol_v in place (reloaded after any mount_1 rewrite) and
  # resolves ws_path (seeded above from ${WS_PATH:-}).
  # Prevented, not detected: with no repo layer the reconciliation
  # bootstraps one from the template, and an --output call must not be the
  # thing that creates the repo's committed configuration. Checked against
  # the same `_repo_conf` the reconciliation is handed, so the two cannot
  # disagree about which file that is.
  if (( _output_set )) && [[ ! -f "${_repo_conf}" ]]; then
    _log_err setup apply_repo_conf_unsettled \
      "display=[setup] apply: there is no ${_repo_conf}, so this call would have to create the repo's committed configuration -- which an --output call must not do. Run 'setup apply' once without --output to settle the repo, then call again." \
      "path=${_repo_conf}"
    return 1
  fi

  _reconcile_workspace_path "${_base_path}" "${_repo_conf}" _vol_k _vol_v ws_path

  # The photograph is compared HERE, where the mutation happens, rather
  # than beside the writes -- `--print-resolved` returns further down and
  # writes no artifact at all, and so was the one supported combination
  # that got past a check placed there.
  if (( _output_set )); then
    if _setup_conf_chain_changed _ap_chain _ap_chain_pre; then
      _log_err setup apply_repo_conf_mutated \
        "display=[setup] apply: the configuration chain under ${_base_path} changed while this call ran, and an --output call must not change it. The change is LEFT IN PLACE rather than reverted -- it may be another process's -- so inspect it: a stale absolute [volumes] mount_1 is migrated to the portable form by any apply, and is warned about by name above. Settle the repo with 'setup apply' and call again." \
        "path=${_base_path}"
      return 1
    fi
  fi

  # shellcheck disable=SC2034  # populated via nameref by _get_conf_list_sorted
  local -a extra_volumes=()
  _get_conf_list_sorted _vol_k _vol_v "mount_" extra_volumes

  # S4: structured app-config channel. Every config/<component>/ the repo
  # ships is dev-bound into the container so structured runtime config
  # (ros1_bridge bridge topics, realsense yaml/udev, isaac's fastdds.xml)
  # is editable on the host with edit + restart, no rebuild. Convention
  # over configuration: a directory's presence is the only switch (no
  # setup.toml knob). The deploy flow (S6) COPY-bakes the SAME population
  # into the field image instead (immutable artifact, ADR-00000003) --
  # both halves read _collect_config_components (lib/deploy.sh), which is
  # what makes PRD invariant 8's "opposite means" agree on WHICH config.
  # Emitted through the regular mount path so per-stage mount_inherit and
  # the top-level volumes: classifier (a ./ bind) apply uniformly.
  #
  # This used to test one literal directory, `config/app`, which no
  # repo in the org has -- so the test was always false, nothing was
  # mounted, and nothing said so. _report_config_components now states the
  # outcome of every run that commits a set, including the empty one. It
  # is called after the commit, not here: its INFO lines go to stdout, and
  # a refused apply provisioned nothing and leaves stdout empty (base#1400).
  local -a _cfg_components=()
  local _cfg_component
  _collect_config_components "${_base_path}" _cfg_components
  for _cfg_component in ${_cfg_components[@]+"${_cfg_components[@]}"}; do
    extra_volumes+=("./config/${_cfg_component}:$(_config_component_target "${_cfg_component}")")
  done

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
      _conf_get_into _APPLY_CONF security privileged "" _priv_val
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
  _conf_list_sorted _APPLY_CONF additional_contexts "context_" _ac_arr
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

  # ── [project] name -> the resolved compose project name ──
  # Resolved ONCE, here, by the single producer in lib/compose.sh. It goes
  # into .env.generated as PROJECT_NAME, which is what BOTH the wrapper's
  # `-p` and the emitted `name: ${PROJECT_NAME}` read -- so the two cannot
  # be two computations that agree.
  local _project_name_conf="" _project_name_resolved=""
  local project_name="" project_name_pending=""
  _conf_get_into _APPLY_CONF project name "" _project_name_conf
  _resolve_project_name "${_project_name_conf}" "${docker_hub_user}" \
    "${image_name}" "${_base_path}" _project_name_resolved
  # What gets RECORDED is not always what just resolved: a checkout that
  # already runs under a name keeps it, and the resolved one is carried
  # beside it as pending until the wrapper can see the old project is
  # empty. Read from the FILE rather than from the `source` above, so an
  # inherited PROJECT_NAME in the environment cannot pose as a recorded
  # one -- and through `_recorded_project_name`, which also recognises the
  # older file shape that recorded no PROJECT_NAME key at all. Reading
  # that one as "fresh checkout" is what would let the rename land
  # silently on exactly the repos that are mid-migration.
  local _project_name_recorded=""
  _recorded_project_name "${_prior_env_file}" _project_name_recorded
  _carry_project_name "${_project_name_recorded}" "${_project_name_resolved}" \
    "${_project_name_conf}" project_name project_name_pending
  # A CONFIGURED rename is taken at once (see _carry_project_name), which
  # is the one path here that can leave a running stack behind: compose
  # cannot relabel a container, so anything still up under the old name
  # stops answering to this checkout's wrappers. Said out loud rather than
  # decided for the user -- setup.sh cannot ask the daemon whether there
  # is anything up, and this is the rename the user typed.
  if [[ -n "${_project_name_conf}" && -n "${_project_name_recorded}" \
        && "${_project_name_recorded}" != "${project_name}" ]]; then
    _log_warn setup project_name_reconfigured \
      "display=compose project renamed: '${_project_name_recorded}' -> '${project_name}' (from [project] name). Anything still under '${_project_name_recorded}' is no longer addressed by this checkout -- containers, and named volumes, which 'just docker stop' does not remove. Tear the old project down (or move its volumes) before renaming." \
      "from=${_project_name_recorded}" "to=${project_name}"
  fi

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
    printf 'PROJECT_NAME=%s\n' "${project_name}"
    # Only when a rename is waiting on an empty project; absent otherwise.
    if [[ -n "${project_name_pending}" ]]; then
      printf 'PROJECT_NAME_PENDING=%s\n' "${project_name_pending}"
    fi
    printf 'SSH_X11=%s\n' "$(_is_ssh_x11 && echo true || echo false)"
    printf 'X11_COOKIE_SKIP=%s\n' "$(( _no_x11_cookie ))"
    return 0
  fi

  # A [deploy] GPU key present but empty has no meaning the compose
  # emitter can render, and reached it as a bare positional-parameter
  # abort (base#1270). Refused here, before anything is written, naming
  # the key and the layer that set it.
  local _gk_key _gk_val _gk_file
  for _gk_key in gpu_count gpu_capabilities; do
    case "${_gk_key}" in
      gpu_count)        _gk_val="${gpu_count}" ;;
      gpu_capabilities) _gk_val="${gpu_caps}" ;;
    esac
    [[ -n "${_gk_val}" ]] && continue
    _setup_conf_key_origin "${_base_path}" deploy "${_gk_key}" _gk_file \
      || _gk_file=""
    _log_err setup apply_conf_value_empty \
      "display=[setup] apply: deploy.${_gk_key} is empty in ${_gk_file:-the configuration}; it needs a value. Set it or remove the line to take the default. Nothing was written" \
      "file=${_gk_file}" "table=deploy" "key=${_gk_key}"
    return 1
  done

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
    _ssh_x11_xauth="$(_setup_ssh_x11_cookie "${_out_dir}")" || _ssh_x11_xauth=""
    if [[ "${net_mode}" != "host" ]]; then
      _log_warn setup ssh_x11_network_mismatch "display=SSH X11 forwarding detected but [network] mode = ${net_mode}; localhost:${DISPLAY##*:} from inside the container will not reach the host's SSH X11 listener. Set [network] mode = host in setup.toml to fix. See base#321." "mode=${net_mode}"
    fi
  fi

  # ── Generate artifacts ──
  #
  # Staged (base#1270): every file of the set is written into a staging
  # directory inside the output directory and moved into place only after
  # every emitter has succeeded, so a refusal leaves the previous set
  # exactly as it was -- or, on a first apply, no set at all. Staging
  # inside the output directory keeps each move a rename on one filesystem.
  #
  # An existing `.env.local` is kept as it is and never staged, so the
  # commit's type check never sees it. Check it here instead: compose
  # reads it as an env file, so anything that does not resolve to a
  # regular file (a directory, a fifo) is refused before any work. A
  # symlink to a regular file is the operator's choice and is kept.
  if [[ -e "${_env_local_file}" && ! -f "${_env_local_file}" ]]; then
    _log_err setup apply_output_unusable \
      "display=[setup] apply: ${_env_local_file} exists and is not a regular file; compose reads it as an env file. Move it aside and re-run. Nothing was written" \
      "path=${_env_local_file}"
    return 1
  fi
  local _stage_dir
  if ! _stage_dir="$(mktemp -d "${_out_dir}/.setup-apply.XXXXXX" 2>/dev/null)"; then
    _log_err setup apply_output_unusable \
      "display=[setup] apply: could not create a staging directory in ${_out_dir}; nothing was written" \
      "path=${_out_dir}"
    return 1
  fi
  local _stg_env_file="${_stage_dir}/.env.generated"
  local _stg_container_env_file="${_stage_dir}/.env"
  local _stg_env_local_file="${_stage_dir}/.env.local"
  local _stg_compose_file="${_stage_dir}/compose.yaml"

  write_env "${_stg_env_file}" \
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
    "${_ssh_x11_xauth}" \
    "${project_name}" \
    "${project_name_pending}" \
    || { rm -rf -- "${_stage_dir}"; return 1; }

  # `.env`: the container-bound defaults, regenerated every apply. The
  # `[environment]` list and the [lifecycle] WATCHDOG_* block land here
  # rather than in compose's `environment:`, so `.env.local` can override
  # them (compose ranks `environment:` above `env_file`). `.env.generated`
  # is passed in as the interpolation source for `${VAR}` references,
  # which an env_file value would otherwise carry through literally.
  write_container_env "${_stg_container_env_file}" \
    "${_env_str}" "${watchdog_env_str}" "${_stg_env_file}" \
    || { rm -rf -- "${_stage_dir}"; return 1; }

  # `.env.local`: the operator's overrides. Created once, never rewritten.
  # Created eagerly because the generated compose lists it in `env_file:`
  # and compose fails the whole `up` on a missing env file. Staged only
  # when the output has none, so an existing one is never touched.
  if [[ ! -e "${_env_local_file}" ]]; then
    _scaffold_env_local "${_stg_env_local_file}" \
      || { rm -rf -- "${_stage_dir}"; return 1; }
  fi

  local runtime_resolved=""
  _resolve_runtime "${gpu_runtime_mode}" runtime_resolved

  # Propagate generate_compose_yaml's exit explicitly: when sourced
  # (no `set -e`) a hard-error return from the stage validator (baseline
  # collision / reserved-tag) would otherwise be swallowed and apply
  # would commit the staged set and print "updated". The content answers
  # for _compose_file; the bytes go to the staged copy (last argument).
  generate_compose_yaml "${_compose_file}" "${image_name}" \
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
    "${init}" \
    "${watchdog_env_str}" \
    "${_base_path}" \
    "${_stg_compose_file}" \
    || { local _gcy_rc=$?; rm -rf -- "${_stage_dir}"; return "${_gcy_rc}"; }

  # Every emitter succeeded: commit the set as one unit. The legacy
  # cache's backup is staged too, so it lands with the set or not at all.
  local -a _commit=()
  if (( _legacy_cache )); then
    if ! cp -- "${_container_env_file}" "${_stage_dir}/.env.bak"; then
      _log_err setup apply_commit_failed \
        "display=[setup] apply: could not back up the legacy cache ${_container_env_file}; nothing was written" \
        "path=${_container_env_file}"
      rm -rf -- "${_stage_dir}"
      return 1
    fi
    _commit+=("${_stage_dir}/.env.bak" "${_container_env_file}.bak")
  fi
  _commit+=("${_stg_env_file}" "${_env_file}")
  _commit+=("${_stg_container_env_file}" "${_container_env_file}")
  if [[ -e "${_stg_env_local_file}" ]]; then
    _commit+=("${_stg_env_local_file}" "${_env_local_file}")
  fi
  _commit+=("${_stg_compose_file}" "${_compose_file}")
  local _commit_rc=0
  _setup_apply_commit "${_stage_dir}" "${_commit[@]}" || _commit_rc=$?
  # On 2 the staging dir holds the only copy of the previous set.
  (( _commit_rc == 2 )) || rm -rf -- "${_stage_dir}"
  (( _commit_rc == 0 )) || return 1

  _report_config_components "${_base_path}" ${_cfg_components[@]+"${_cfg_components[@]}"}

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
# User-facing entry for the self-contained field-deploy FOLDER
# (ADR-00000023). Previews the fully-resolved compose.yaml (the field
# artifact -- every resolved param, no ${VAR}), asks for confirmation, then
# calls _generate_deploy_bundle to build the immutable image and assemble
# the bundle folder. `--dry-run` prints the plan without building (and skips
# the prompt); `-y` skips the prompt; a non-tty shell without `-y` refuses
# (mirrors `reset`). Default stage is `runtime`; default output is
# <base>/deploy/<name>-<stage>-<version>/ (version = git describe).
#
# Note: the graphical per-param TUI page (setup_tui.sh) is an optional
# fast-follow -- this plain-text preview already surfaces every resolved
# param and is script / CI friendly (the issue invited the lighter flow).
# ════════════════════════════════════════════════════════════════════
_setup_deploy() {
  local _base_path="" _stage="runtime" _output="" _yes=0 _quiet=0 _dry=0
  local _allow_local=0
  # ADR-00000036's other half for this stage: deploy already named its own
  # output directory, so an address for the chain's top layer is all it
  # was missing.
  local _local_conf="" _local_conf_set=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)     usage ;;
      --allow-local-override) _allow_local=1; shift ;;
      --local-conf)  _local_conf="${2:?"--local-conf requires a value"}"; _local_conf_set=1; shift 2 ;;
      --local-conf=*) _local_conf="${1#--local-conf=}"; _local_conf_set=1; shift ;;
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

  # The addressed local layer, checked before the stage is even looked at,
  # so an address that cannot be read never reaches a preview or a build.
  local _SETUP_CONF_LOCAL="${_SETUP_CONF_LOCAL:-}"
  if (( _local_conf_set )); then
    _setup_conf_local_check "${_local_conf}" || return 1
    _SETUP_CONF_LOCAL="${_local_conf}"
  fi

  # Stage eligibility, checked the moment the stage is known -- before the
  # repo is even located, so a forbidden stage can never reach a preview, a
  # build or a bundle. ADR-00000023 sec.4 / PRD invariant 8:
  # `deployable = not devel and not *-test`, shared with the compose
  # emitter as _is_deployable_stage so the rule has one definition.
  if ! _is_deployable_stage "${_stage}"; then
    _log_err setup deploy_stage_not_deployable "display=[setup] deploy: '${_stage}' is not a deployable stage; the development / test baseline (sys, devel-base, devel, devel-test, runtime-test, the legacy aliases base / test, and any *-test stage) is never a deploy target." "stage=${_stage}"
    return 1
  fi

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../../../.." && pwd -P)"
  fi
  if [[ ! -f "${_base_path}/Dockerfile" ]]; then
    _log_err setup deploy_no_dockerfile "display=[setup] deploy: no Dockerfile at ${_base_path}; cannot build the field image." "path=${_base_path}"
    return 1
  fi

  # PRD invariant: an artifact built for the field must not silently depend
  # on a config layer that is not under version control. setup.local.toml
  # is gitignored, so a bundle whose values came from it cannot be rebuilt
  # from a clean checkout and nothing in the bundle would say why. Refused
  # by default, BEFORE the preview and before any build side effect, so a
  # --dry-run reports the refusal too rather than previewing a plan that
  # would not be allowed to run.
  local -a _dep_local_sections=()
  _setup_conf_local_sections "${_base_path}" _dep_local_sections
  local _dep_local_list=""
  if (( ${#_dep_local_sections[@]} > 0 )); then
    _dep_local_list="${_dep_local_sections[*]}"
    local _dep_local_file
    _dep_local_file="$(_setup_conf_local_path "${_base_path}")"
    if (( ! _allow_local )); then
      _log_err setup deploy_local_override_refused \
        "display=[setup] deploy: ${_dep_local_file} is present and supplies section(s): ${_dep_local_list// /, }. It is gitignored, so a bundle built from it cannot be reproduced from a clean checkout. Remove it, or pass --allow-local-override to build anyway (the bundle's README records which sections came from it)." \
        "file=${_dep_local_file}" "sections=${_dep_local_list}"
      return 1
    fi
    _log_warn setup deploy_local_override_accepted \
      "display=[setup] deploy: --allow-local-override accepted; section(s) ${_dep_local_list// /, } come from the untracked ${_dep_local_file}. This bundle is NOT reproducible from a clean checkout; its README records the fact." \
      "file=${_dep_local_file}" "sections=${_dep_local_list}"
  fi

  local _name=""
  BASE_PATH="${_base_path}" detect_image_name _name "${_base_path}"
  local _version; _version="$(_resolve_deploy_version "${_base_path}")"
  local _image="${_name}:${_stage}-${_version}"
  [[ -z "${_output}" ]] && _output="${_base_path}/deploy/${_name}-${_stage}-${_version}"

  # Per-parameter review: render the resolved compose to a temp file and
  # print it so the user sees every resolved field param before building.
  if (( ! _quiet )); then
    local _preview
    _preview="$(mktemp)"
    local -A _pv_binds=() _pv_bind_modes=()
    _collect_deploy_binds "${_base_path}" "${_stage}" _pv_binds _pv_bind_modes \
      || { rm -f "${_preview}"; return 1; }
    _generate_resolved_compose "${_base_path}" "${_stage}" "${_image}" "${_name}-${_stage}" \
      "${_preview}" _pv_binds "" _pv_bind_modes
    printf '[setup] deploy plan: stage=%s image=%s bundle=%s\n' \
      "${_stage}" "${_image}" "${_output}"
    printf '[setup] resolved compose.yaml to be generated (review every param):\n'
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
    printf "[setup] field flow: copy %s to the target, then run ./deploy.sh up\n" \
      "$(basename -- "${_output}")"
  fi
  return 0
}
