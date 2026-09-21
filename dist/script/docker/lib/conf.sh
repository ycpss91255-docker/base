#!/usr/bin/env bash
#
# conf.sh - config read/write primitives for setup.toml (TOML) and the
# legacy INI file the frozen TUI still writes.
#
# The single shared home for setup.toml I/O:
#   _dump_conf_section    - emit key=value lines from one section
#   _load_setup_conf_full - parse every section into namespaced arrays
#   _conf_split_nskey     - split a namespaced key back into its halves
#   _parse_ini_section    - parse one section into flat arrays
#   _write_setup_conf     - rewrite from a template + overrides,
#                           preserving comments and ordering
#   _upsert_conf_value    - update/append a single key in place
#
# Sourced via _lib.sh (the umbrella loader) and directly by
# config_summary.sh and _tui_conf.sh. _parse_ini_section moved here
# from setup.sh in (PR-B); the full-file tokenizer + the writers
# moved here from _tui_conf.sh in so every INI read/write path
# shares one module instead of the core CLI reaching into the TUI lib.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_CONF_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_CONF_SOURCED=1

_conf_sh_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=dist/script/docker/lib/toml_bridge.sh
source "${_conf_sh_dir}/toml_bridge.sh"

# _dump_conf_section <file> <section>
#
# Emit key=value lines from the named INI section of <file>, skipping
# blank lines and comments. Stops at the next section header or EOF.
# Silent on missing file or missing section.
_dump_conf_section() {
  local _file="$1" _sec="$2"
  [[ -f "${_file}" ]] || return 0
  # Filter out empty values (`key =` / `key = `). An empty value means
  # "use the Docker / template default" and is noise in the summary.
  # Populated keys print as-is; cleared list slots (arg_N = / mount_N =)
  # are also hidden so they don't show up as blank rows.
  awk -v sec="[${_sec}]" '
    $0 == sec { in_sec=1; next }
    /^\[/ && in_sec { in_sec=0 }
    in_sec && /^[[:space:]]*#/ { next }
    in_sec && /^[[:space:]]*$/ { next }
    in_sec && /^[[:space:]]*[^#=]+=[[:space:]]*$/ { next }
    in_sec { print }
  ' "${_file}"
}

# ════════════════════════════════════════════════════════════════════
# INI reader (single-pass tokenizer + projections)
# ════════════════════════════════════════════════════════════════════

# _ini_tokenize <file> <sections_out> <entry_sections_out> <keys_out> <values_out>
#
# Single-pass INI tokenizer shared by the public readers below. Walks
# <file> once and populates four parallel-ish arrays:
#   sections[]        - unique section names, first-appearance order
#   entry_sections[i] - the section each key/value entry belongs to
#   keys[i]           - raw key, NOT namespaced (may contain '.', e.g.
#                       the per-stage override key `gui.mode`)
#   values[i]         - trimmed value
# entry_sections / keys / values are index-aligned (one slot per entry);
# sections[] is the deduped header list and is independent.
#
# Skips comments (#) and blank lines, trims key/value whitespace, and
# ignores key=value lines that appear before any section header. Keeping
# the section per entry (instead of pre-joining `<section>.<key>`) lets
# _parse_ini_section match sections exactly even when keys themselves
# contain '.', which a namespaced-string split cannot do unambiguously.
_ini_tokenize() {
  local _file="${1:?"${FUNCNAME[0]}: missing file"}"
  local -n _it_sections="${2:?"${FUNCNAME[0]}: missing sections outvar"}"
  local -n _it_entry_sects="${3:?"${FUNCNAME[0]}: missing entry-sections outvar"}"
  local -n _it_keys="${4:?"${FUNCNAME[0]}: missing keys outvar"}"
  local -n _it_values="${5:?"${FUNCNAME[0]}: missing values outvar"}"

  _it_sections=()
  _it_entry_sects=()
  _it_keys=()
  _it_values=()
  [[ -f "${_file}" ]] || return 0

  local __it_line __it_current="" __it_k __it_v
  local -A __it_seen=()
  while IFS= read -r __it_line || [[ -n "${__it_line}" ]]; do
    # Strip comments / blanks before trimming (comment marker may be
    # preceded by leading whitespace).
    [[ -z "${__it_line}" || "${__it_line}" =~ ^[[:space:]]*# ]] && continue

    # Trim surrounding whitespace.
    __it_line="${__it_line#"${__it_line%%[![:space:]]*}"}"
    __it_line="${__it_line%"${__it_line##*[![:space:]]}"}"
    [[ -z "${__it_line}" ]] && continue

    # Section header.
    if [[ "${__it_line}" =~ ^\[(.+)\]$ ]]; then
      __it_current="${BASH_REMATCH[1]}"
      if [[ -z "${__it_seen[${__it_current}]:-}" ]]; then
        _it_sections+=("${__it_current}")
        __it_seen[${__it_current}]=1
      fi
      continue
    fi

    # Require key = value inside a section.
    [[ -z "${__it_current}" || "${__it_line}" != *=* ]] && continue
    __it_k="${__it_line%%=*}"
    __it_v="${__it_line#*=}"
    __it_k="${__it_k#"${__it_k%%[![:space:]]*}"}"
    __it_k="${__it_k%"${__it_k##*[![:space:]]}"}"
    __it_v="${__it_v#"${__it_v%%[![:space:]]*}"}"
    __it_v="${__it_v%"${__it_v##*[![:space:]]}"}"

    _it_entry_sects+=("${__it_current}")
    _it_keys+=("${__it_k}")
    _it_values+=("${__it_v}")
  done < "${_file}"
}

# _toml_tokenize <file> <sections_out> <entry_sections_out> <keys_out> <values_out>
#
# TOML counterpart of _ini_tokenize. Calls the containerised bridge
# (toml_bridge_parse --kv) and populates the same four parallel arrays.
# Drop-in replacement for _ini_tokenize when the source is TOML.
_toml_tokenize() {
  local _file="${1:?"${FUNCNAME[0]}: missing file"}"
  local -n _tt_sections="${2:?"${FUNCNAME[0]}: missing sections outvar"}"
  local -n _tt_entry_sects="${3:?"${FUNCNAME[0]}: missing entry-sections outvar"}"
  local -n _tt_keys="${4:?"${FUNCNAME[0]}: missing keys outvar"}"
  local -n _tt_values="${5:?"${FUNCNAME[0]}: missing values outvar"}"

  _tt_sections=()
  _tt_entry_sects=()
  _tt_keys=()
  _tt_values=()
  [[ -f "${_file}" ]] || return 0

  local _tt_sect _tt_key _tt_val
  local -A _tt_seen=()
  while IFS=$'\t' read -r _tt_sect _tt_key _tt_val; do
    [[ -z "${_tt_sect}" ]] && continue
    if [[ -z "${_tt_seen[${_tt_sect}]:-}" ]]; then
      _tt_sections+=("${_tt_sect}")
      _tt_seen[${_tt_sect}]=1
    fi
    _tt_entry_sects+=("${_tt_sect}")
    _tt_keys+=("${_tt_key}")
    _tt_values+=("${_tt_val}")
  done < <(toml_bridge_parse "${_file}" --kv)
}

# _load_setup_conf_full <file> <sections_outvar> <keys_outvar> <values_outvar>
#
# Reads a config file into three parallel arrays:
#   sections[] — unique section names in first-appearance order
#   keys[i]    — "<section>.<key>" (namespaced)
#   values[i]  — trimmed value
#
# Comments and blank lines are skipped. Thin projection over the
# tokenizer that re-joins each entry's section and key. A `.toml` file
# goes through the bridge (_toml_tokenize), which numbers array-of-
# tables blocks back into the `<prefix>_N` keys this view speaks;
# anything else through _ini_tokenize -- the rule _conf_load applies.
_load_setup_conf_full() {
  local _file="${1:?"${FUNCNAME[0]}: missing file"}"
  local -n _lsf_sections="${2:?}"
  local -n _lsf_keys="${3:?}"
  local -n _lsf_values="${4:?}"

  _lsf_sections=()
  _lsf_keys=()
  _lsf_values=()
  [[ -f "${_file}" ]] || return 0

  local -a __lsf_s=() __lsf_es=() __lsf_k=() __lsf_v=()
  if [[ "${_file}" == *.toml ]]; then
    _toml_tokenize "${_file}" __lsf_s __lsf_es __lsf_k __lsf_v
  else
    _ini_tokenize "${_file}" __lsf_s __lsf_es __lsf_k __lsf_v
  fi

  local __lsf_i
  for (( __lsf_i = 0; __lsf_i < ${#__lsf_s[@]}; __lsf_i++ )); do
    _lsf_sections+=("${__lsf_s[__lsf_i]}")
  done
  for (( __lsf_i = 0; __lsf_i < ${#__lsf_k[@]}; __lsf_i++ )); do
    _lsf_keys+=("${__lsf_es[__lsf_i]}.${__lsf_k[__lsf_i]}")
    _lsf_values+=("${__lsf_v[__lsf_i]}")
  done
}

# _conf_split_nskey <nskey> <section_outvar> <key_outvar>
#
# Inverse of the join `_load_setup_conf_full` performs: split a
# "<section>.<key>" namespace key back into its two halves.
#
# The join is lossy -- either half may contain a dot -- so the split
# leans on the one rule the config schema fixes: the per-service
# `[logging.<svc>]` block is the only sub-sectioned name, so
# `logging.<svc>.<key>` splits at the RIGHTMOST dot and everything else
# splits at the first (`stage:headless.gui.mode` -> section
# `stage:headless`, key `gui.mode`).
#
# A dot-split PREFIX is not a substitute: `logging.` prefixes both
# `logging.max_size` and `logging.web.driver`, so prefix matching binds
# a per-service override to the parent `[logging]` section as well.
# Anything deciding which section an override key belongs to must ask
# here rather than re-derive it.
#
# Returns 1 with both outvars empty when <nskey> carries no dot, i.e. it
# names a section and no key.
_conf_split_nskey() {
  local _nskey="${1-}"
  local -n _csn_section="${2:?"${FUNCNAME[0]}: missing section outvar"}"
  local -n _csn_key="${3:?"${FUNCNAME[0]}: missing key outvar"}"

  _csn_section=""
  _csn_key=""
  [[ "${_nskey}" == *.* ]] || return 1

  if [[ "${_nskey}" == logging.*.* ]]; then
    _csn_section="${_nskey%.*}"
    _csn_key="${_nskey##*.}"
  else
    _csn_section="${_nskey%%.*}"
    _csn_key="${_nskey#*.}"
  fi
  return 0
}

# _parse_ini_section <file> <section> <keys_outvar> <values_outvar>
#
# Reads one section [<section>] from <file> into parallel flat arrays
# (raw keys, no namespace). Thin projection over _ini_tokenize keeping
# only entries whose owning section equals <section> EXACTLY.
#
# Exact matching is load-bearing: [logging] and [logging.web] are
# distinct sections, and per-stage sections carry dotted keys like
# `gui.mode` under [stage:NAME]. Because _ini_tokenize tracks the owning
# section per entry (rather than a lossy "<section>.<key>" string), both
# cases resolve correctly with no dot heuristics.
#
# Skips comments/blanks, trims whitespace, and preserves duplicate keys
# plus reopened sections in file order. Silent (empty arrays) on missing
# file or absent section.
_parse_ini_section() {
  local _file="${1:?"${FUNCNAME[0]}: missing file"}"
  local _section="${2:?"${FUNCNAME[0]}: missing section"}"
  local -n _pis_keys="${3:?"${FUNCNAME[0]}: missing keys outvar"}"
  local -n _pis_values="${4:?"${FUNCNAME[0]}: missing values outvar"}"

  _pis_keys=()
  _pis_values=()
  [[ -f "${_file}" ]] || return 0

  local -a __pis_s=() __pis_es=() __pis_k=() __pis_v=()
  _ini_tokenize "${_file}" __pis_s __pis_es __pis_k __pis_v

  local __pis_i
  for (( __pis_i = 0; __pis_i < ${#__pis_k[@]}; __pis_i++ )); do
    [[ "${__pis_es[__pis_i]}" == "${_section}" ]] || continue
    _pis_keys+=("${__pis_k[__pis_i]}")
    _pis_values+=("${__pis_v[__pis_i]}")
  done
}

# _parse_conf_section <file> <section> <keys_outvar> <values_outvar>
#
# Format-dispatching wrapper: TOML (.toml) files go through the
# containerised bridge (_toml_tokenize), everything else through the
# INI tokenizer (_ini_tokenize). Same output contract as
# _parse_ini_section -- parallel flat arrays of keys and values for
# the requested section.
#
# This is the function callers that need to read ONE section from a
# file of UNKNOWN format should use. _parse_ini_section stays for
# callers that know they have INI.
_parse_conf_section() {
  local _file="${1:?"${FUNCNAME[0]}: missing file"}"
  local _section="${2:?"${FUNCNAME[0]}: missing section"}"
  local -n _pcs_keys="${3:?"${FUNCNAME[0]}: missing keys outvar"}"
  local -n _pcs_values="${4:?"${FUNCNAME[0]}: missing values outvar"}"

  _pcs_keys=()
  _pcs_values=()
  [[ -f "${_file}" ]] || return 0

  local -a __pcs_s=() __pcs_es=() __pcs_k=() __pcs_v=()
  if [[ "${_file}" == *.toml ]]; then
    _toml_tokenize "${_file}" __pcs_s __pcs_es __pcs_k __pcs_v
  else
    _ini_tokenize "${_file}" __pcs_s __pcs_es __pcs_k __pcs_v
  fi

  local __pcs_i
  for (( __pcs_i = 0; __pcs_i < ${#__pcs_k[@]}; __pcs_i++ )); do
    [[ "${__pcs_es[__pcs_i]}" == "${_section}" ]] || continue
    _pcs_keys+=("${__pcs_k[__pcs_i]}")
    _pcs_values+=("${__pcs_v[__pcs_i]}")
  done
}

# ════════════════════════════════════════════════════════════════════
# Opaque accessor interface
# ════════════════════════════════════════════════════════════════════
#
# Callers load a file once into a named handle and query it by
# (section, key) via the accessor verbs below, without touching the
# parallel-array representation or the `<section>.<key>` namespacing rule.
# A "handle" is just a name prefix; _conf_load creates the backing global
# arrays (`<handle>__es` / `<handle>__keys` / `<handle>__vals` +
# `<handle>__sects`) so the accessors can find them by prefix.

# _conf_load <file> <handle>
#
# Tokenize <file> once into the global arrays backing <handle>. Safe to
# call on a missing file (yields an empty handle).
_conf_load() {
  local _file="${1:?"${FUNCNAME[0]}: missing file"}"
  local _h="${2:?"${FUNCNAME[0]}: missing handle"}"
  declare -g -a "${_h}__sects=()" "${_h}__es=()" "${_h}__keys=()" "${_h}__vals=()"
  local -n _cl_s="${_h}__sects" _cl_es="${_h}__es" _cl_k="${_h}__keys" _cl_v="${_h}__vals"
  if [[ "${_file}" == *.toml ]]; then
    _toml_tokenize "${_file}" _cl_s _cl_es _cl_k _cl_v
  else
    _ini_tokenize "${_file}" _cl_s _cl_es _cl_k _cl_v
  fi
}

# _conf_get <handle> <section> <key> [default]
#
# Echo the value for <section>.<key> from <handle>, or [default] (empty
# if omitted) when absent. Last occurrence wins (override semantics).
_conf_get() {
  local _h="${1:?"${FUNCNAME[0]}: missing handle"}"
  local _sec="${2:?"${FUNCNAME[0]}: missing section"}"
  local _key="${3:?"${FUNCNAME[0]}: missing key"}"
  local _def="${4-}"
  local -n _cg_es="${_h}__es" _cg_k="${_h}__keys" _cg_v="${_h}__vals"
  local _cg_i _cg_val="${_def}"
  for (( _cg_i = 0; _cg_i < ${#_cg_k[@]}; _cg_i++ )); do
    if [[ "${_cg_es[_cg_i]}" == "${_sec}" && "${_cg_k[_cg_i]}" == "${_key}" ]]; then
      _cg_val="${_cg_v[_cg_i]}"
    fi
  done
  printf '%s\n' "${_cg_val}"
}

# _conf_get_into <handle> <section> <key> <default> <outvar>
#
# Outvar variant of _conf_get: assign the value for <section>.<key> (or
# <default> when absent) to the caller's <outvar>, with no $() subshell.
# Same lookup + last-occurrence-wins semantics. Lets a hot resolver read many
# keys from one parsed handle without a fork per lookup.
_conf_get_into() {
  local _h="${1:?"${FUNCNAME[0]}: missing handle"}"
  local _sec="${2:?"${FUNCNAME[0]}: missing section"}"
  local _key="${3:?"${FUNCNAME[0]}: missing key"}"
  local _def="${4-}"
  local -n _cgi_out="${5:?"${FUNCNAME[0]}: missing outvar"}"
  local -n _cgi_es="${_h}__es" _cgi_k="${_h}__keys" _cgi_v="${_h}__vals"
  local _cgi_i
  _cgi_out="${_def}"
  for (( _cgi_i = 0; _cgi_i < ${#_cgi_k[@]}; _cgi_i++ )); do
    if [[ "${_cgi_es[_cgi_i]}" == "${_sec}" && "${_cgi_k[_cgi_i]}" == "${_key}" ]]; then
      _cgi_out="${_cgi_v[_cgi_i]}"
    fi
  done
}

# _conf_sections <handle>
#
# Echo the handle's section names (deduped, first-appearance order), one
# per line.
_conf_sections() {
  local _h="${1:?"${FUNCNAME[0]}: missing handle"}"
  local -n _cs_s="${_h}__sects"
  local _cs_i
  for (( _cs_i = 0; _cs_i < ${#_cs_s[@]}; _cs_i++ )); do
    printf '%s\n' "${_cs_s[_cs_i]}"
  done
}

# _conf_list <handle> <section>
#
# Echo the keys present in <section> from <handle>, one per line, in file
# order (duplicates preserved). Empty output for an absent section. Use to
# iterate list-style sections (e.g. volumes `mount_*`, environment `env_*`).
_conf_list() {
  local _h="${1:?"${FUNCNAME[0]}: missing handle"}"
  local _sec="${2:?"${FUNCNAME[0]}: missing section"}"
  local -n _ls_es="${_h}__es" _ls_k="${_h}__keys"
  local _ls_i
  for (( _ls_i = 0; _ls_i < ${#_ls_k[@]}; _ls_i++ )); do
    [[ "${_ls_es[_ls_i]}" == "${_sec}" ]] && printf '%s\n' "${_ls_k[_ls_i]}"
  done
  return 0
}

# _conf_load_layers <handle> <file>...
#
# Load the section-replace merge of an arbitrary-length layer chain into
# <handle>. Files are given in INCREASING precedence (baseline first, the
# most local override last): for each section, the entries come wholesale
# from the HIGHEST-precedence layer that defines it (>=1 entry); layers
# below contribute nothing to that section. Sections no layer above defines
# keep the layer that did. Section order is the order the layers introduced
# them, lowest layer first.
#
# Section-replace rather than per-key merge is the chain's one rule, and it
# is structural: eight of the sections are `<prefix>_N` ordered lists, and a
# per-key merge would assemble one ordered list out of several layers, would
# offer no way to REMOVE an item, and would require the author of an upper
# layer to know the highest N used by a layer they cannot see.
#
# Missing files are skipped (an absent layer contributes nothing), so callers
# pass the whole chain unconditionally.
_conf_load_layers() {
  local _h="${1:?"${FUNCNAME[0]}: missing handle"}"
  shift
  (( $# > 0 )) || { declare -g -a "${_h}__sects=()" "${_h}__es=()" "${_h}__keys=()" "${_h}__vals=()"; return 0; }

  # ── TOML path: type-aware merge via containerised bridge ──────────
  #
  # When every existing layer file is TOML, the merge (table key-level,
  # array-of-tables replace) runs in Python where the type information
  # is native (dict vs list).  ADR-37 sec. Merge semantics.
  local -a _cll_existing=()
  local _cll_all_toml=1
  local _cll_f
  for _cll_f in "$@"; do
    [[ -f "${_cll_f}" ]] || continue
    _cll_existing+=("${_cll_f}")
    [[ "${_cll_f}" == *.toml ]] || _cll_all_toml=0
  done
  if (( ${#_cll_existing[@]} > 0 && _cll_all_toml )); then
    declare -g -a "${_h}__sects=()" "${_h}__es=()" "${_h}__keys=()" "${_h}__vals=()"
    # shellcheck disable=SC2178  # namerefs to arrays, not scalar reassignment
    local -n _cll_ts="${_h}__sects" _cll_tes="${_h}__es" _cll_tk="${_h}__keys" _cll_tv="${_h}__vals"
    local _cll_sect _cll_key _cll_val
    local -A _cll_tseen=()
    # The bridge reports a failed merge with its exit status and an empty
    # stdout, and a process substitution puts that status out of reach: the
    # loop would read nothing, the handle would come back empty, and every
    # value would fall back to its default with nothing said -- a total
    # config failure wearing the shape of a config that says nothing.
    # Collecting the output first is what puts the status where it can be
    # acted on. An empty stdout from a SUCCESSFUL merge is still a success:
    # the herestring's single blank line is dropped by the guard below.
    local _cll_kv
    if ! _cll_kv="$(toml_bridge_merge --kv "${_cll_existing[@]}")"; then
      _log_err conf conf_toml_merge_failed \
        "display=_conf_load_layers: the TOML merge of ${_cll_existing[*]} failed; refusing to report an empty configuration as a loaded one"
      return 1
    fi
    while IFS=$'\t' read -r _cll_sect _cll_key _cll_val; do
      [[ -z "${_cll_sect}" ]] && continue
      if [[ -z "${_cll_tseen[${_cll_sect}]:-}" ]]; then
        _cll_ts+=("${_cll_sect}")
        _cll_tseen[${_cll_sect}]=1
      fi
      _cll_tes+=("${_cll_sect}")
      _cll_tk+=("${_cll_key}")
      _cll_tv+=("${_cll_val}")
    done <<< "${_cll_kv}"
    return 0
  fi

  # ── INI path: section-replace merge (existing logic) ──────────────

  # INI path: tokenize every layer up front into flat, layer-tagged arrays.
  # The per-layer arrays cannot be kept as separate named arrays without
  # eval, so each entry carries its layer index instead.
  local -a _cll_layer_of=() _cll_es=() _cll_keys=() _cll_vals=()
  local -a _cll_order=()
  local -A _cll_order_seen=()
  # _cll_owner[<section>] = highest layer index that defines the section.
  local -A _cll_owner=()

  local _cll_idx=0 _cll_file _cll_i _cll_s
  for _cll_file in "$@"; do
    local -a _cll_fs=() _cll_fes=() _cll_fk=() _cll_fv=()
    _ini_tokenize "${_cll_file}" _cll_fs _cll_fes _cll_fk _cll_fv
    for (( _cll_i = 0; _cll_i < ${#_cll_fk[@]}; _cll_i++ )); do
      _cll_layer_of+=("${_cll_idx}")
      _cll_es+=("${_cll_fes[_cll_i]}")
      _cll_keys+=("${_cll_fk[_cll_i]}")
      _cll_vals+=("${_cll_fv[_cll_i]}")
      _cll_owner["${_cll_fes[_cll_i]}"]="${_cll_idx}"
    done
    # Section ORDER follows first appearance across the chain, so a
    # section introduced by the baseline keeps its slot even when an
    # upper layer redefines it.
    for _cll_s in "${_cll_fs[@]+"${_cll_fs[@]}"}"; do
      [[ -n "${_cll_order_seen[${_cll_s}]:-}" ]] && continue
      _cll_order+=("${_cll_s}")
      _cll_order_seen["${_cll_s}"]=1
    done
    _cll_idx=$(( _cll_idx + 1 ))
  done

  # shellcheck disable=SC2178  # namerefs to arrays, not scalar reassignment
  declare -g -a "${_h}__sects=()" "${_h}__es=()" "${_h}__keys=()" "${_h}__vals=()"
  local -n _cll_ms="${_h}__sects" _cll_mes="${_h}__es" _cll_mk="${_h}__keys" _cll_mv="${_h}__vals"

  # A section header with no entries names no owner; it still exists as a
  # section but contributes nothing, matching the pre-chain behaviour.
  for _cll_s in "${_cll_order[@]+"${_cll_order[@]}"}"; do
    _cll_ms+=("${_cll_s}")
    local _cll_win="${_cll_owner[${_cll_s}]:-}"
    [[ -n "${_cll_win}" ]] || continue
    for (( _cll_i = 0; _cll_i < ${#_cll_keys[@]}; _cll_i++ )); do
      [[ "${_cll_es[_cll_i]}" == "${_cll_s}" ]] || continue
      [[ "${_cll_layer_of[_cll_i]}" == "${_cll_win}" ]] || continue
      _cll_mes+=("${_cll_s}"); _cll_mk+=("${_cll_keys[_cll_i]}"); _cll_mv+=("${_cll_vals[_cll_i]}")
    done
  done
  return 0
}

# _conf_load_merged <template_file> <repo_file> <handle>
#
# Two-layer form of _conf_load_layers, kept as the name the explicit
# template/repo call sites read by. Same section-replace semantics.
_conf_load_merged() {
  local _tpl="${1:?"${FUNCNAME[0]}: missing template file"}"
  local _repo="${2:?"${FUNCNAME[0]}: missing repo file"}"
  local _h="${3:?"${FUNCNAME[0]}: missing handle"}"
  _conf_load_layers "${_h}" "${_tpl}" "${_repo}"
}

# _conf_list_sorted <handle> <section> <prefix> <outvar_array>
#
# Collect entries in <section> whose key is "<prefix><N>" (numeric suffix),
# skip empty values (opt-out), sort by the numeric suffix, and return the
# VALUES in that order into <outvar_array>. The opaque-handle equivalent of
# setup.sh's _get_conf_list_sorted (which reads raw parallel arrays).
_conf_list_sorted() {
  local _h="${1:?"${FUNCNAME[0]}: missing handle"}"
  local _sec="${2:?"${FUNCNAME[0]}: missing section"}"
  local _prefix="${3:?"${FUNCNAME[0]}: missing prefix"}"
  local -n _cls_out="${4:?"${FUNCNAME[0]}: missing outvar"}"
  local -n _cls_es="${_h}__es" _cls_k="${_h}__keys" _cls_v="${_h}__vals"

  _cls_out=()
  local -a _cls_pairs=()
  local _cls_i _cls_num
  for (( _cls_i = 0; _cls_i < ${#_cls_k[@]}; _cls_i++ )); do
    [[ "${_cls_es[_cls_i]}" == "${_sec}" ]] || continue
    [[ "${_cls_k[_cls_i]}" == "${_prefix}"* ]] || continue
    _cls_num="${_cls_k[_cls_i]#"${_prefix}"}"
    [[ "${_cls_num}" =~ ^[0-9]+$ ]] || continue
    [[ -z "${_cls_v[_cls_i]}" ]] && continue
    _cls_pairs+=("${_cls_num}:${_cls_v[_cls_i]}")
  done

  if (( ${#_cls_pairs[@]} > 0 )); then
    local _cls_sorted _cls_line
    _cls_sorted="$(printf '%s\n' "${_cls_pairs[@]}" | sort -t: -k1,1n)"
    while IFS= read -r _cls_line; do
      _cls_out+=("${_cls_line#*:}")
    done <<< "${_cls_sorted}"
  fi
  return 0
}

# ════════════════════════════════════════════════════════════════════
# Config writers (comment-preserving)
# ════════════════════════════════════════════════════════════════════
#
# Both writers pick their output format from the destination's
# extension, the same rule the readers (_conf_load, _parse_conf_section)
# apply: a `.toml` destination gets TOML, anything else gets the legacy
# INI the frozen TUI still writes into its own file (ADR-00000037
# freezes setup_tui.sh until the migration completes, so that file must
# keep coming out byte-for-byte as before).
#
# TOML mode differs from INI mode in three ways and nothing else:
#
#   1. Values are rendered as TOML scalars: `true` / `false` and integers
#      stay bare, everything else is a quoted basic string (backslash and
#      double quote escaped). Keys that are not bare-key-safe (`gui.mode`
#      under a per-stage section) are quoted, and so is each dotted part
#      of a section header that is not (`["stage:headless"]`).
#   2. Numbered list keys (`mount_N`, `arg_N`, `rule_N`, `port_N`,
#      `device_N`, `tmpfs_N`, `context_N`, `cap_add_N`, `security_opt_N`)
#      are routed to the `[[array of tables]]` the bridge reads them back
#      from: the N-th `[[volumes]]` block IS `volumes.mount_N`. An array
#      is dense, so an entry that does not exist yet is appended after the
#      last block of its kind and takes the next index, and a removed
#      entry compacts the ones after it.
#   3. `[[...]]` headers are recognised as scope boundaries.
#
# The line-by-line walk is otherwise the same, which is what keeps the
# property both writers have always had: comments, blank lines and
# untouched lines are copied through verbatim.
#
# What has NO array-of-tables home yet stays a quoted scalar under its
# table (`[environment] env_N`, `cap_drop_N`, `cgroup_rule_N`): the
# bridge reads a table scalar back under its own name, so those keys
# round-trip as they are, and moving them is a reader-side change.

# _conf_toml_scalar <value> <outvar>
#
# Render a bash string as the TOML scalar the bridge reads back to the
# same string. Booleans and integers (no leading zeros, TOML refuses
# them) are bare; everything else is a basic string.
_conf_toml_scalar() {
  local _v="${1-}"
  local -n _cts_out="${2:?"${FUNCNAME[0]}: missing outvar"}"
  case "${_v}" in
    true|false) _cts_out="${_v}"; return 0 ;;
  esac
  if [[ "${_v}" =~ ^-?(0|[1-9][0-9]*)$ ]]; then
    _cts_out="${_v}"
    return 0
  fi
  _v="${_v//\\/\\\\}"
  _v="${_v//\"/\\\"}"
  _v="${_v//$'\t'/\\t}"
  _cts_out="\"${_v}\""
}

# _conf_toml_key <key> <outvar>
#
# A bare key when TOML allows one, a quoted key otherwise.
_conf_toml_key() {
  local _k="${1-}"
  local -n _ctk_out="${2:?"${FUNCNAME[0]}: missing outvar"}"
  if [[ "${_k}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    _ctk_out="${_k}"
  else
    _ctk_out="\"${_k//\"/\\\"}\""
  fi
}

# _conf_toml_header <section> <outvar>
#
# `[a.b]` with each dotted part quoted when it has to be:
# `logging.web` -> `[logging.web]`, `stage:headless` -> `["stage:headless"]`.
_conf_toml_header() {
  local _s="${1-}"
  local -n _cth_out="${2:?"${FUNCNAME[0]}: missing outvar"}"
  local -a _parts=()
  local _part _q _joined=""
  IFS=. read -r -a _parts <<< "${_s}"
  for _part in "${_parts[@]}"; do
    _conf_toml_key "${_part}" _q
    _joined+="${_joined:+.}${_q}"
  done
  _cth_out="[${_joined}]"
}

# _conf_header_name <raw> <outvar>
#
# The section name a header line carries, quotes and padding stripped:
# `"stage:headless"` -> `stage:headless`. The inverse of _conf_toml_header
# for every name the schema has.
_conf_header_name() {
  local _raw="${1-}"
  local -n _chn_out="${2:?"${FUNCNAME[0]}: missing outvar"}"
  _raw="${_raw//\"/}"
  _raw="${_raw#"${_raw%%[![:space:]]*}"}"
  _raw="${_raw%"${_raw##*[![:space:]]}"}"
  _chn_out="${_raw}"
}

# _conf_toml_aot_slot <section> <key> <path_outvar> <index_outvar>
#
# Where a numbered list key lives in TOML. Returns 0 with the
# array-of-tables path and the 1-based index when `<section>.<key>` is
# one of the numbered keys the bridge's array spec reads back (the
# conversion table of the TOML migration), 1 for everything else.
_conf_toml_aot_slot() {
  local _s="${1-}" _k="${2-}"
  local -n _cas_path="${3:?"${FUNCNAME[0]}: missing path outvar"}"
  local -n _cas_idx="${4:?"${FUNCNAME[0]}: missing index outvar"}"
  _cas_path=""
  _cas_idx=""
  local _prefix="" _path=""
  case "${_s}" in
    image)               _prefix=rule;    _path=image.rules ;;
    build)               _prefix=arg;     _path=build.args ;;
    network)             _prefix=port;    _path=network.ports ;;
    volumes)             _prefix=mount;   _path=volumes ;;
    tmpfs)               _prefix=tmpfs;   _path=tmpfs ;;
    devices)             _prefix=device;  _path=devices ;;
    additional_contexts) _prefix=context; _path=additional_contexts ;;
    security)
      case "${_k}" in
        cap_add_*)      _prefix=cap_add;      _path=security.cap_add ;;
        security_opt_*) _prefix=security_opt; _path=security.security_opt ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
  [[ "${_k}" =~ ^${_prefix}_([0-9]+)$ ]] || return 1
  _cas_path="${_path}"
  _cas_idx="${BASH_REMATCH[1]}"
  return 0
}

# _conf_toml_aot_nskey <path> <index> <outvar>
#
# The inverse: the `<section>.<prefix>_N` key the N-th `[[<path>]]` block
# is known by on the shell side. Returns 1 for a path the bridge has no
# array spec for, which the writers then copy through untouched.
_conf_toml_aot_nskey() {
  local _p="${1-}" _n="${2-}"
  local -n _can_out="${3:?"${FUNCNAME[0]}: missing outvar"}"
  _can_out=""
  case "${_p}" in
    image.rules)           _can_out="image.rule_${_n}" ;;
    build.args)            _can_out="build.arg_${_n}" ;;
    network.ports)         _can_out="network.port_${_n}" ;;
    security.cap_add)      _can_out="security.cap_add_${_n}" ;;
    security.security_opt) _can_out="security.security_opt_${_n}" ;;
    volumes)               _can_out="volumes.mount_${_n}" ;;
    tmpfs)                 _can_out="tmpfs.tmpfs_${_n}" ;;
    devices)               _can_out="devices.device_${_n}" ;;
    additional_contexts)   _can_out="additional_contexts.context_${_n}" ;;
    *) return 1 ;;
  esac
  return 0
}

# _conf_toml_aot_fields <path> <value> <outvar>
#
# The body of one `[[<path>]]` block for a numbered-key value, as the
# bridge's array spec serialises it back: `KEY=VALUE` splits into
# key / value, `host:container` into host / container, a mount into
# source / target / mode, and a bare entry is its one field. Lines are
# newline-joined, no trailing newline.
_conf_toml_aot_fields() {
  local _p="${1-}" _v="${2-}"
  local -n _caf_out="${3:?"${FUNCNAME[0]}: missing outvar"}"
  local _a _b _c
  _caf_out=""
  case "${_p}" in
    image.rules)
      _conf_toml_scalar "${_v}" _a
      _caf_out="rule = ${_a}"
      ;;
    build.args|additional_contexts)
      _conf_toml_scalar "${_v%%=*}" _a
      if [[ "${_v}" == *=* ]]; then _conf_toml_scalar "${_v#*=}" _b; else _b='""'; fi
      if [[ "${_p}" == build.args ]]; then
        _caf_out="key = ${_a}"$'\n'"value = ${_b}"
      else
        _caf_out="name = ${_a}"$'\n'"source = ${_b}"
      fi
      ;;
    network.ports)
      _conf_toml_scalar "${_v%%:*}" _a
      if [[ "${_v}" == *:* ]]; then _conf_toml_scalar "${_v#*:}" _b; else _b='""'; fi
      _caf_out="host = ${_a}"$'\n'"container = ${_b}"
      ;;
    security.cap_add)
      _conf_toml_scalar "${_v}" _a
      _caf_out="cap = ${_a}"
      ;;
    security.security_opt)
      _conf_toml_scalar "${_v}" _a
      _caf_out="opt = ${_a}"
      ;;
    volumes)
      local _rest=""
      _conf_toml_scalar "${_v%%:*}" _a
      _caf_out="source = ${_a}"
      if [[ "${_v}" == *:* ]]; then
        _rest="${_v#*:}"
        _conf_toml_scalar "${_rest%%:*}" _b
        _caf_out+=$'\n'"target = ${_b}"
        if [[ "${_rest}" == *:* ]]; then
          _conf_toml_scalar "${_rest#*:}" _c
          _caf_out+=$'\n'"mode = ${_c}"
        fi
      fi
      ;;
    tmpfs|devices)
      _conf_toml_scalar "${_v}" _a
      _caf_out="path = ${_a}"
      ;;
  esac
}

# _conf_fmt_kv <toml> <key> <value> <outvar>
#
# One `key = value` line in the destination's format.
_conf_fmt_kv() {
  local _toml="${1-0}" _k="${2-}" _v="${3-}"
  local -n _cfk_out="${4:?"${FUNCNAME[0]}: missing outvar"}"
  if (( _toml )); then
    local _fk _fv
    _conf_toml_key "${_k}" _fk
    _conf_toml_scalar "${_v}" _fv
    _cfk_out="${_fk} = ${_fv}"
  else
    _cfk_out="${_k} = ${_v}"
  fi
}

# _conf_fmt_header <toml> <section> <outvar>
#
# One `[section]` header line in the destination's format.
_conf_fmt_header() {
  local _toml="${1-0}" _s="${2-}"
  local -n _cfh_out="${3:?"${FUNCNAME[0]}: missing outvar"}"
  if (( _toml )); then
    _conf_toml_header "${_s}" _cfh_out
  else
    _cfh_out="[${_s}]"
  fi
}

# _conf_is_kv_line <line>
#
# True for a line that carries a `key = value` pair: not blank, not a
# comment (a `#` as the FIRST non-blank character, the rule the readers
# apply, so an inline `#` is part of the value), and has an `=`.
_conf_is_kv_line() {
  local _line="${1-}" _trimmed
  _trimmed="${_line#"${_line%%[![:space:]]*}"}"
  [[ -n "${_trimmed}" && "${_trimmed}" != \#* && "${_line}" == *=* ]]
}

# _conf_line_key <line> <outvar>
#
# The key a `key = value` line carries, trimmed and with TOML quotes
# stripped (`"gui.mode" = ...` -> `gui.mode`).
_conf_line_key() {
  local _line="${1-}" _k
  local -n _clk_out="${2:?"${FUNCNAME[0]}: missing outvar"}"
  _k="${_line%%=*}"
  _k="${_k#"${_k%%[![:space:]]*}"}"
  _k="${_k%"${_k##*[![:space:]]}"}"
  _k="${_k#\"}"
  _k="${_k%\"}"
  _clk_out="${_k}"
}

# ── _write_setup_conf's flush helpers ─────────────────────────────────
#
# Called from _write_setup_conf only. They read its walk state (the
# `__override` / `__emitted` / `__removed` / `__aot_of` / `__aot_idx_of`
# maps, `__toml`, and `_out`) through bash's dynamic scope rather than
# taking a dozen namerefs each; nothing else may call them.

# _wsc_flush_scalars <section>
#
# Append the not-yet-emitted scalar overrides of <section> (added keys
# with no template line). Which section an override key belongs to is
# _conf_split_nskey's question. A `"${__current}."*` prefix match
# answers it wrongly for the one sub-sectioned name: `logging.web.driver`
# prefixes `logging.` too, so it was flushed into `[logging]` as a bogus
# `web.driver = ...` line on top of the `[logging.web]` line it belongs
# to.
_wsc_flush_scalars() {
  local _sect="${1}"
  local __ovk __ovk_sect __ovk_key __kv
  for __ovk in "${!__override[@]}"; do
    _conf_split_nskey "${__ovk}" __ovk_sect __ovk_key || continue
    [[ "${__ovk_sect}" == "${_sect}" && -z "${__emitted[${__ovk}]:-}" ]] || continue
    [[ -n "${__aot_of[${__ovk}]:-}" ]] && continue
    [[ -n "${__removed[${__ovk}]+x}" ]] && { __emitted[${__ovk}]=1; continue; }
    _conf_fmt_kv "${__toml}" "${__ovk_key}" "${__override[${__ovk}]}" __kv
    printf '%s\n' "${__kv}" >> "${_out}"
    __emitted[${__ovk}]=1
  done
}

# _wsc_flush_aot <path> <where>
#
# Append the not-yet-emitted array-of-tables overrides of <path> as new
# `[[<path>]]` blocks, in index order so the array the bridge numbers
# back matches the order the caller meant. <where> is `boundary` when
# the next line out is a header (each block is followed by a blank
# line, the way the template spaces its blocks) or `eof` (each block is
# preceded by one).
_wsc_flush_aot() {
  local _path="${1}" _where="${2:-eof}"
  local __ovk __fields _entry
  local -a _pending=()
  for __ovk in "${!__aot_of[@]}"; do
    [[ "${__aot_of[${__ovk}]}" == "${_path}" && -z "${__emitted[${__ovk}]:-}" ]] || continue
    [[ -n "${__removed[${__ovk}]+x}" ]] && { __emitted[${__ovk}]=1; continue; }
    _pending+=("${__aot_idx_of[${__ovk}]} ${__ovk}")
  done
  (( ${#_pending[@]} > 0 )) || return 0
  while IFS= read -r _entry; do
    [[ -n "${_entry}" ]] || continue
    __ovk="${_entry#* }"
    _conf_toml_aot_fields "${_path}" "${__override[${__ovk}]}" __fields
    if [[ "${_where}" == boundary ]]; then
      printf '[[%s]]\n%s\n\n' "${_path}" "${__fields}" >> "${_out}"
    else
      printf '\n[[%s]]\n%s\n' "${_path}" "${__fields}" >> "${_out}"
    fi
    __emitted[${__ovk}]=1
  done < <(printf '%s\n' "${_pending[@]}" | sort -n -k1,1)
}

# _write_setup_conf <dst_file> <template_src> <keys_ref> <values_ref> [<removed_keys>]
#
# The section list is NOT a parameter. It was one, and it was never read:
# the body bound it and then silenced the unused-nameref warning, so every
# caller passed an array to satisfy a slot that carried nothing. Section
# ORDER comes from the template being copied, which is where it has always
# come from. A positional slot nothing reads is a slot every caller can
# still get wrong (base#994).
#
# Copies <template_src> to <dst_file> line-by-line. `key = value` lines
# whose namespaced key `<section>.<key>` appears in the overrides arrays
# are replaced with `key = <override>`. Keys present in the space-
# separated <removed_keys> argument are dropped entirely (line removed).
# Comments, blank lines and untouched keys are preserved verbatim.
#
# Extra override entries that do not correspond to any template line
# (e.g. Add rule_5 / mount_5) are appended to the end of their section.
#
# TOML destination: see the section comment above. A numbered list key
# addresses the N-th `[[...]]` block of its kind (replaced in place,
# dropped when removed, appended after the last block when new).
_write_setup_conf() {
  local _dst="${1:?}"
  local _tpl="${2:?}"
  local -n _wsc_keys="${3:?}"
  local -n _wsc_values="${4:?}"
  local _removed_keys="${5:-}"

  [[ -f "${_tpl}" ]] || return 1

  local __toml=0
  [[ "${_dst}" == *.toml ]] && __toml=1

  local -A __override=()
  local -A __emitted=()
  local -A __removed=()
  local i
  for (( i=0; i<${#_wsc_keys[@]}; i++ )); do
    __override["${_wsc_keys[i]}"]="${_wsc_values[i]}"
  done
  for i in ${_removed_keys}; do
    __removed["${i}"]=1
  done
  # setup_tui's `_commit_and_setup` passes the same path for dst
  # and tpl when the per-repo file already exists. Truncating dst before
  # reading from tpl (the original `: > "${_dst}"` followed by `done <
  # "${_tpl}"`) collapses the read to zero lines under that aliasing and
  # silently destroys the user's config. Slurp the template into memory
  # first so the subsequent truncate-and-rewrite is safe regardless of
  # whether dst and tpl are distinct files.
  local -a __tpl_lines=()
  while IFS= read -r __line || [[ -n "${__line}" ]]; do
    __tpl_lines+=("${__line}")
  done < "${_tpl}"

  # Write to a sibling temp file and atomically `mv` it over _dst at the
  # very end. The previous in-place `: > "${_dst}"` truncated the user's
  # config FIRST, opening a data-loss window: any append failing after the
  # truncate (disk full / mid-write error) left setup.toml truncated with
  # no rollback. The temp+mv pattern means a mid-write failure leaves the
  # original _dst untouched. Guard mktemp so a failed temp creation
  # (read-only dir / no inodes) bails before touching _dst.
  local _out
  if ! _out="$(mktemp "${_dst}.XXXXXX" 2>/dev/null)" || [[ -z "${_out}" || ! -f "${_out}" ]]; then
    _log_err conf conf_write_tmp_failed "display=_write_setup_conf: cannot create temp file next to ${_dst}; destination left unchanged" "file=${_dst}"
    return 1
  fi

  # TOML: which override keys are array-of-tables entries, and how many
  # blocks of each kind the template already has. The count is what
  # tells the walk it is leaving the LAST block of a kind, which is where
  # new entries of that kind are appended so the array stays in order.
  local -A __aot_of=() __aot_idx_of=() __aot_total=() __aot_seen=()
  local __ovk __ovk_sect __ovk_key __p __n
  if (( __toml )); then
    for __ovk in "${!__override[@]}"; do
      _conf_split_nskey "${__ovk}" __ovk_sect __ovk_key || continue
      if _conf_toml_aot_slot "${__ovk_sect}" "${__ovk_key}" __p __n; then
        __aot_of["${__ovk}"]="${__p}"
        __aot_idx_of["${__ovk}"]="${__n}"
      fi
    done
    for __line in "${__tpl_lines[@]}"; do
      if [[ "${__line}" =~ ^[[:space:]]*\[\[(.+)\]\][[:space:]]*$ ]]; then
        _conf_header_name "${BASH_REMATCH[1]}" __p
        __aot_total["${__p}"]=$(( ${__aot_total["${__p}"]:-0} + 1 ))
      fi
    done
  fi

  # Walk state: __current is the table whose scalar keys are in scope;
  # __aot_cur the array-of-tables path whose block is in scope (one of
  # the two is always empty); __aot_skip says what to do with the body of
  # the current block: 0 copy, 1 drop (removed), 2 drop its key lines
  # (replaced, the new fields already written).
  local __current="" __aot_cur="" __aot_skip=0 __nskey __raw __rest __hdr __kv __fields
  : > "${_out}"
  for __line in "${__tpl_lines[@]}"; do
    if (( __toml )) && [[ "${__line}" =~ ^[[:space:]]*\[\[(.+)\]\][[:space:]]*$ ]]; then
      _conf_header_name "${BASH_REMATCH[1]}" __p
      if [[ -n "${__current}" ]]; then
        _wsc_flush_scalars "${__current}"
        printf '\n' >> "${_out}"
        __current=""
      fi
      if [[ -n "${__aot_cur}" && "${__aot_cur}" != "${__p}" ]] \
         && (( ${__aot_seen[${__aot_cur}]:-0} >= ${__aot_total[${__aot_cur}]:-0} )); then
        _wsc_flush_aot "${__aot_cur}" boundary
      fi
      __aot_cur="${__p}"
      __aot_seen["${__p}"]=$(( ${__aot_seen["${__p}"]:-0} + 1 ))
      __aot_skip=0
      if _conf_toml_aot_nskey "${__p}" "${__aot_seen["${__p}"]}" __nskey; then
        if [[ -n "${__removed[${__nskey}]+x}" ]]; then
          __emitted[${__nskey}]=1
          __aot_skip=1
          continue
        fi
        printf '%s\n' "${__line}" >> "${_out}"
        if [[ -n "${__override[${__nskey}]+x}" ]]; then
          _conf_toml_aot_fields "${__p}" "${__override[${__nskey}]}" __fields
          printf '%s\n' "${__fields}" >> "${_out}"
          __emitted[${__nskey}]=1
          __aot_skip=2
        fi
        continue
      fi
      printf '%s\n' "${__line}" >> "${_out}"
      continue
    fi
    if [[ "${__line}" =~ ^[[:space:]]*\[(.+)\][[:space:]]*$ ]]; then
      # Taken before the flushes below: the TOML renderers match
      # patterns of their own, and BASH_REMATCH is one global.
      __raw="${BASH_REMATCH[1]}"
      # Flush not-yet-emitted overrides belonging to the section we are
      # about to leave (those are "added" keys with no template line).
      if [[ -n "${__current}" ]]; then
        _wsc_flush_scalars "${__current}"
        # Separate appended keys from the next section header with a blank line
        printf '\n' >> "${_out}"
      fi
      if [[ -n "${__aot_cur}" ]] \
         && (( ${__aot_seen[${__aot_cur}]:-0} >= ${__aot_total[${__aot_cur}]:-0} )); then
        _wsc_flush_aot "${__aot_cur}" boundary
      fi
      __aot_cur=""
      __aot_skip=0
      if (( __toml )); then
        _conf_header_name "${__raw}" __current
      else
        __current="${__raw}"
      fi
      printf '%s\n' "${__line}" >> "${_out}"
      continue
    fi
    if (( __aot_skip == 1 )); then
      continue
    fi
    if (( __aot_skip == 2 )) && _conf_is_kv_line "${__line}"; then
      continue
    fi
    if [[ -z "${__line}" || "${__line}" =~ ^[[:space:]]*# ]]; then
      printf '%s\n' "${__line}" >> "${_out}"
      continue
    fi
    if [[ -n "${__current}" && "${__line}" == *=* ]]; then
      _conf_line_key "${__line}" __rest
      __nskey="${__current}.${__rest}"
      if [[ -n "${__removed[${__nskey}]+x}" ]]; then
        __emitted[${__nskey}]=1
        continue
      fi
      if [[ -n "${__override[${__nskey}]+x}" ]]; then
        _conf_fmt_kv "${__toml}" "${__rest}" "${__override[${__nskey}]}" __kv
        printf '%s\n' "${__kv}" >> "${_out}"
        __emitted[${__nskey}]=1
        continue
      fi
    fi
    printf '%s\n' "${__line}" >> "${_out}"
  done

  # Flush leftovers belonging to the final section / final block kind
  if [[ -n "${__current}" ]]; then
    _wsc_flush_scalars "${__current}"
  fi
  if [[ -n "${__aot_cur}" ]]; then
    _wsc_flush_aot "${__aot_cur}" eof
  fi

  # TOML: array-of-tables entries whose kind the template has no block of
  # yet (the first `[[volumes]]` of a repo). Walked in caller order so the
  # kinds appear in the order the caller named them; within a kind, in
  # index order.
  local _wsc_i
  if (( __toml )); then
    for (( _wsc_i = 0; _wsc_i < ${#_wsc_keys[@]}; _wsc_i++ )); do
      __p="${__aot_of[${_wsc_keys[_wsc_i]}]:-}"
      [[ -n "${__p}" ]] || continue
      _wsc_flush_aot "${__p}" eof
    done
  fi

  # Append NEW sections — overrides whose `<section>.<key>` namespace
  # references a section never seen in the template. Per-stage
  # `[stage:NAME]` sections are the typical case: template's
  # setup.toml carries no per-repo stage overrides, so the first time
  # a user adds `[stage:headless]` via TUI Save the section is brand
  # new and would otherwise be silently dropped here.
  #
  # Section-name extraction goes through `_conf_split_nskey`, the one
  # place that owns the `<section>.<key>` split rule --
  # `stage:headless.gui.mode` → section=stage:headless, key=gui.mode,
  # and `logging.web.driver` → section=logging.web, key=driver, so a
  # per-service logging override the template never mentions gets a
  # `[logging.web]` section of its own instead of being folded into the
  # parent `[logging]`.
  local -A __template_sections=()
  local __l
  for __l in "${__tpl_lines[@]}"; do
    if [[ "${__l}" =~ ^[[:space:]]*\[(.+)\][[:space:]]*$ ]]; then
      if (( __toml )); then
        _conf_header_name "${BASH_REMATCH[1]}" __p
        __template_sections["${__p}"]=1
      else
        __template_sections["${BASH_REMATCH[1]}"]=1
      fi
    fi
  done

  # Walk override keys in the order the caller provided them so new
  # sections appear in user-input order (predictable for tests + Save
  # output diffs). Bash associative-array iteration is unspecified. In
  # TOML mode a key already emitted (an array-of-tables entry) does not
  # open a section: an empty `[image]` under `[[image.rules]]` is a
  # header nothing asked for.
  local -a __new_section_order=()
  local -A __new_section_seen=()
  local __ns_sect __ns_key
  for (( _wsc_i = 0; _wsc_i < ${#_wsc_keys[@]}; _wsc_i++ )); do
    (( __toml )) && [[ -n "${__emitted[${_wsc_keys[_wsc_i]}]:-}" ]] && continue
    _conf_split_nskey "${_wsc_keys[_wsc_i]}" __ns_sect __ns_key || continue
    if [[ -z "${__template_sections[${__ns_sect}]:-}" ]] \
       && [[ -z "${__new_section_seen[${__ns_sect}]:-}" ]]; then
      __new_section_order+=("${__ns_sect}")
      __new_section_seen[${__ns_sect}]=1
    fi
  done

  # Emit each new section + its keys (skip emitted / removed entries
  # so re-saves don't double-write).
  local __ns
  for __ns in "${__new_section_order[@]}"; do
    _conf_fmt_header "${__toml}" "${__ns}" __hdr
    printf '\n%s\n' "${__hdr}" >> "${_out}"
    for (( _wsc_i = 0; _wsc_i < ${#_wsc_keys[@]}; _wsc_i++ )); do
      local __key="${_wsc_keys[_wsc_i]}"
      _conf_split_nskey "${__key}" __ns_sect __ns_key || continue
      [[ "${__ns_sect}" == "${__ns}" ]] || continue
      [[ -n "${__emitted[${__key}]:-}" ]] && continue
      [[ -n "${__removed[${__key}]+x}" ]] && continue
      _conf_fmt_kv "${__toml}" "${__ns_key}" "${_wsc_values[_wsc_i]}" __kv
      printf '%s\n' "${__kv}" >> "${_out}"
      __emitted[${__key}]=1
    done
  done

  # Atomically replace _dst only after the full rewrite succeeded. A
  # failed mv (e.g. _dst on a read-only mount) is surfaced rather than
  # leaving a stray temp file silently behind: remove the orphan temp,
  # log an actionable error, and bail with the original _dst untouched.
  mv "${_out}" "${_dst}" || {
    rm -f "${_out}"
    _log_err conf conf_write_mv_failed "display=_write_setup_conf: could not replace ${_dst}; destination left unchanged" "file=${_dst}"
    return 1
  }
}

# ════════════════════════════════════════════════════════════════════
# Single-key upsert (used by setup.sh for WS_PATH writeback)
# ════════════════════════════════════════════════════════════════════

# _upsert_conf_value <file> <section> <key> <value>
#
# Updates the given key's value within the given section in-place,
# preserving all other content. If the key does not exist under the
# section, appends it to the end of the section. If the section does
# not exist, appends a new section + key at end of file.
#
# TOML file: a numbered list key addresses the N-th `[[...]]` block of
# its kind -- replaced in place when it exists, appended after the last
# block of that kind (or at the end of the file when there is none)
# when it does not.
_upsert_conf_value() {
  local _file="${1:?}"
  local _section="${2:?}"
  local _key="${3:?}"
  local _value="${4-}"

  [[ -f "${_file}" ]] || { _log_err conf conf_upsert_file_missing "display=_upsert_conf_value: file missing: ${_file}"; return 1; }

  # A value (or key) bearing a newline would be written by the
  # `printf '%s = %s\n'` lines below as multiple physical lines, leaving
  # an orphan, un-keyed line that corrupts the file on the next read. The
  # scalar validators are line-anchored (`.*$` matches up to a newline)
  # so a newline-bearing value can pass validation upstream; refuse it
  # here at the writer sink so every caller (set / add / TUI / WS_PATH)
  # is protected.
  if [[ "${_key}" == *$'\n'* || "${_value}" == *$'\n'* ]]; then
    _log_err conf conf_upsert_newline_rejected "display=_upsert_conf_value: refusing newline-bearing key/value"
    return 1
  fi

  # Guard the temp-file creation. An unchecked `mktemp` failure (read-only
  # dir / no inodes) leaves _tmp empty, the per-line `>> ""` writes
  # silently no-op, and the final `mv "" "${_file}"` either aborts under
  # set -e with no actionable message or, worse, truncates the user's
  # config. Bail BEFORE touching the original file so a failed write is
  # never destructive.
  local _tmp
  if ! _tmp="$(mktemp "${_file}.XXXXXX" 2>/dev/null)" || [[ -z "${_tmp}" || ! -f "${_tmp}" ]]; then
    _log_err conf conf_upsert_tmp_failed "display=_upsert_conf_value: cannot create temp file next to ${_file}; original left unchanged" "file=${_file}"
    return 1
  fi

  local __toml=0
  [[ "${_file}" == *.toml ]] && __toml=1

  local __aot_path="" __aot_n=""
  if (( __toml )) && _conf_toml_aot_slot "${_section}" "${_key}" __aot_path __aot_n; then
    _conf_toml_upsert_aot "${_file}" "${_tmp}" "${__aot_path}" "${__aot_n}" "${_value}"
  else
    _conf_upsert_scalar "${_file}" "${_tmp}" "${__toml}" "${_section}" "${_key}" "${_value}"
  fi

  # Atomically replace _file only after the rewrite succeeded. A failed
  # mv (e.g. _file on a read-only mount) removes the orphan temp, logs an
  # actionable error, and bails with the original _file untouched.
  mv "${_tmp}" "${_file}" || {
    rm -f "${_tmp}"
    _log_err conf conf_upsert_mv_failed "display=_upsert_conf_value: could not replace ${_file}; original left unchanged" "file=${_file}"
    return 1
  }
}

# _conf_upsert_scalar <src> <dst> <toml> <section> <key> <value>
#
# The scalar half of _upsert_conf_value: rewrite <src> into <dst> with
# `<section>.<key>` set. A `[[...]]` header ends the section's scope
# like a `[...]` one does, so an appended key lands inside its table.
_conf_upsert_scalar() {
  local _src="${1:?}" _dst="${2:?}" _toml="${3:?}"
  local _section="${4:?}" _key="${5:?}" _value="${6-}"

  local __line __current="" __raw __rest __kv __hdr
  local __matched=0 __in_sect=0 __sect_found=0
  _conf_fmt_kv "${_toml}" "${_key}" "${_value}" __kv
  while IFS= read -r __line || [[ -n "${__line}" ]]; do
    if [[ "${__line}" =~ ^[[:space:]]*\[(.+)\][[:space:]]*$ ]]; then
      __raw="${BASH_REMATCH[1]}"
      # Leaving target section without finding key → append key before next section
      if (( __in_sect && !__matched )); then
        printf '%s\n' "${__kv}" >> "${_dst}"
        __matched=1
      fi
      __in_sect=0
      if (( _toml )) && [[ "${__raw}" == \[* ]]; then
        # `[[...]]`: an array-of-tables block, no table's scalar scope
        __current=""
      else
        if (( _toml )); then
          _conf_header_name "${__raw}" __current
        else
          __current="${__raw}"
        fi
        if [[ "${__current}" == "${_section}" ]]; then
          __in_sect=1
          __sect_found=1
        fi
      fi
      printf '%s\n' "${__line}" >> "${_dst}"
      continue
    fi
    # A line is a comment when `#` is its FIRST non-blank character --
    # the rule `_ini_tokenize` (the canonical reader) applies, so an
    # inline `#` is part of the value, not a comment marker. The guard
    # used to skip any line containing a space-then-hash as well, which
    # fired on a VALUE carrying one (a lifecycle.watchdog_check shell
    # command, an [environment] entry): the existing key never matched,
    # the in-place replace was skipped, and a second `key = ...` was
    # appended at the section end. Reads are last-wins, so the duplicate
    # corrupted the file without changing behaviour.
    if (( __in_sect )) && _conf_is_kv_line "${__line}"; then
      _conf_line_key "${__line}" __rest
      if [[ "${__rest}" == "${_key}" ]]; then
        printf '%s\n' "${__kv}" >> "${_dst}"
        __matched=1
        continue
      fi
    fi
    printf '%s\n' "${__line}" >> "${_dst}"
  done < "${_src}"

  # Still in target section at EOF and key not matched → append
  if (( __in_sect && !__matched )); then
    printf '%s\n' "${__kv}" >> "${_dst}"
    __matched=1
  fi

  # Section not found at all → append new section + key
  if (( !__sect_found )); then
    _conf_fmt_header "${_toml}" "${_section}" __hdr
    printf '\n%s\n%s\n' "${__hdr}" "${__kv}" >> "${_dst}"
  fi
}

# _conf_toml_upsert_aot <src> <dst> <path> <index> <value>
#
# The array-of-tables half of _upsert_conf_value: rewrite <src> into
# <dst> with the <index>-th `[[<path>]]` block carrying <value>. The
# block's key lines are replaced, its comments and blank lines kept.
# When the file has fewer blocks than <index>, the new block goes after
# the last one of that kind -- an array is dense, so it takes the next
# index -- or at the end of the file when there is none.
_conf_toml_upsert_aot() {
  local _src="${1:?}" _dst="${2:?}" _path="${3:?}" _index="${4:?}" _value="${5-}"

  local __fields
  _conf_toml_aot_fields "${_path}" "${_value}" __fields

  local __line __p __total=0 __seen=0 __in_block=0 __replacing=0 __matched=0
  while IFS= read -r __line || [[ -n "${__line}" ]]; do
    if [[ "${__line}" =~ ^[[:space:]]*\[\[(.+)\]\][[:space:]]*$ ]]; then
      _conf_header_name "${BASH_REMATCH[1]}" __p
      [[ "${__p}" == "${_path}" ]] && __total=$(( __total + 1 ))
    fi
  done < "${_src}"

  while IFS= read -r __line || [[ -n "${__line}" ]]; do
    if [[ "${__line}" =~ ^[[:space:]]*\[\[(.+)\]\][[:space:]]*$ ]]; then
      _conf_header_name "${BASH_REMATCH[1]}" __p
      if (( __in_block && !__matched && __seen == __total )); then
        printf '[[%s]]\n%s\n\n' "${_path}" "${__fields}" >> "${_dst}"
        __matched=1
      fi
      __in_block=0
      __replacing=0
      if [[ "${__p}" == "${_path}" ]]; then
        __seen=$(( __seen + 1 ))
        __in_block=1
        printf '%s\n' "${__line}" >> "${_dst}"
        if (( __seen == _index )); then
          printf '%s\n' "${__fields}" >> "${_dst}"
          __replacing=1
          __matched=1
        fi
        continue
      fi
    elif [[ "${__line}" =~ ^[[:space:]]*\[(.+)\][[:space:]]*$ ]]; then
      if (( __in_block && !__matched && __seen == __total )); then
        printf '[[%s]]\n%s\n\n' "${_path}" "${__fields}" >> "${_dst}"
        __matched=1
      fi
      __in_block=0
      __replacing=0
    elif (( __replacing )) && _conf_is_kv_line "${__line}"; then
      continue
    fi
    printf '%s\n' "${__line}" >> "${_dst}"
  done < "${_src}"

  if (( !__matched )); then
    printf '\n[[%s]]\n%s\n' "${_path}" "${__fields}" >> "${_dst}"
  fi
}
