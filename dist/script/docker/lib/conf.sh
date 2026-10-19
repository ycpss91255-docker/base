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

# _conf_kv_split <row> <section_outvar> <key_outvar> <value_outvar>
#
# One row of the bridge's tab-separated KV stream, split at its FIRST TWO
# tabs. Everything after the second tab is the value, byte for byte.
#
# NOT `IFS=$'\t' read -r a b c`, and that is the whole point of this
# function existing. A tab is IFS WHITESPACE, so `read` strips it from
# the ends of a field and collapses runs of it -- which silently rewrote
# values the writer had preserved: `[environment] env_1 = "TOKEN=abc<TAB>"`
# loaded as `TOKEN=abc`, and a leading one went the same way. The value
# is the LAST field precisely so a tab inside it survives the transport
# (toml_bridge.py's `_check_transportable` draws the line there and
# refuses one in a section or key NAME), and then the reader undid it.
_conf_kv_split() {
  local _row="${1-}"
  local -n _cks_s="${2:?"${FUNCNAME[0]}: missing section outvar"}"
  local -n _cks_k="${3:?"${FUNCNAME[0]}: missing key outvar"}"
  local -n _cks_v="${4:?"${FUNCNAME[0]}: missing value outvar"}"
  local _rest
  _cks_s="${_row%%$'\t'*}"
  _cks_k=""
  _cks_v=""
  [[ "${_row}" == *$'\t'* ]] || return 0
  _rest="${_row#*$'\t'}"
  _cks_k="${_rest%%$'\t'*}"
  [[ "${_rest}" == *$'\t'* ]] || return 0
  _cks_v="${_rest#*$'\t'}"
}

# _toml_tokenize <file> <sections_out> <entry_sections_out> <keys_out> <values_out>
#
# TOML counterpart of _ini_tokenize. Calls the containerised bridge
# (toml_bridge_parse --kv) and populates the same four parallel arrays.
# Drop-in replacement for _ini_tokenize when the source is TOML.
#
# A file that is NOT there leaves the arrays empty and answers 0, which is
# _ini_tokenize's contract too: an absent layer contributes nothing.
#
# A file that IS there and could not be parsed answers NON-ZERO with the
# arrays empty, and the two outcomes must not be read as one. The bridge
# reports a failure with its exit status and an empty stdout, and the
# process substitution this used to read through put that status out of
# reach: the loop read nothing, the handle came back empty, and every
# value fell back to its default with nothing said -- a total parser
# failure wearing the shape of a file that says nothing. That is the same
# trap _conf_load_layers names on its own merge call, and it is why an
# unprovisionable parser has to be able to stop a run rather than quietly
# produce the template defaults.
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

  # Collected first, so the bridge's status is somewhere it can be acted
  # on. An empty stdout from a SUCCESSFUL parse is still a success: the
  # herestring's single blank line is dropped by the guard in the loop.
  local _tt_kv
  if ! _tt_kv="$(toml_bridge_parse "${_file}" --kv)"; then
    _log_err conf conf_toml_parse_failed \
      "display=_toml_tokenize: the TOML parse of ${_file} failed; refusing to report an empty configuration as a loaded one" \
      "path=${_file}"
    return 1
  fi

  local _tt_sect _tt_key _tt_val
  local -A _tt_seen=()
  local _tt_row
  while IFS= read -r _tt_row; do
    _conf_kv_split "${_tt_row}" _tt_sect _tt_key _tt_val
    [[ -z "${_tt_sect}" ]] && continue
    if [[ -z "${_tt_seen[${_tt_sect}]:-}" ]]; then
      _tt_sections+=("${_tt_sect}")
      _tt_seen[${_tt_sect}]=1
    fi
    _tt_entry_sects+=("${_tt_sect}")
    _tt_keys+=("${_tt_key}")
    _tt_values+=("${_tt_val}")
  done <<< "${_tt_kv}"
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
# The join is lossy -- either half may contain a dot -- so no rule over
# the STRING can recover which dot was the join's: `logging.max_size`
# and `logging.web.driver` share a prefix and split at different dots.
# The split therefore asks something outside the string. A name whose
# HEAD is registered in SCHEMA_SUBSECTIONED and that carries at least
# two dots splits at the RIGHTMOST dot; everything else splits at the
# first (`stage:headless.gui.mode` -> section `stage:headless`, key
# `gui.mode`, because `stage:headless`'s dot is in the KEY).
#
# This used to be a literal `logging.*.*` match, which made the set of
# sub-sectioned names one long by construction and was the reason
# base#1152's `base.*` namespace and base#1184's `[base.watchdog]`
# could not land: registering a section was not enough, because the
# name was already destroyed by the time anything checked membership.
# Adding a name to SCHEMA_SUBSECTIONED is now the whole of it.
#
# A dot-split PREFIX is still not a substitute, for the reason above.
# Anything deciding which section an override key belongs to must ask
# here rather than re-derive it.
#
# Returns non-zero with both outvars empty in two cases, and callers
# that can act on only one of them must tell them apart by the shape of
# the input rather than by the status:
#   - <nskey> carries no dot, i.e. it names a section and no key;
#   - the registry is not loaded, because "no answer" must not read as
#     "nothing is sub-sectioned" -- that reading is WORSE than the
#     literal this replaced, which at least got `logging` right.
_conf_split_nskey() {
  local _nskey="${1-}"
  local -n _csn_section="${2:?"${FUNCNAME[0]}: missing section outvar"}"
  local -n _csn_key="${3:?"${FUNCNAME[0]}: missing key outvar"}"

  _csn_section=""
  _csn_key=""
  [[ "${_nskey}" == *.* ]] || return 1

  # conf.sh's first dependency on schema.sh, which conf.sh declares for
  # itself at the foot of this file -- so in a loaded tree this branch
  # is unreachable. It exists for a tree where the registry has been
  # removed or shadowed, because the cheap reading of "no answer" is
  # "nothing is sub-sectioned", and that answer is WORSE than the
  # literal `logging.*.*` it replaced: the literal at least got
  # `logging.<svc>.<key>` right. Refusing is the only safe answer.
  #
  # BOTH halves are checked. The predicate without the array is not a
  # registry: `_schema_is_subsectioned` would iterate an unset array,
  # answer "no" for everything, and leave no trace. A DECLARED but empty
  # array is a different thing and is allowed -- it is a registry that
  # happens to name nothing, and every key then splits at the first dot,
  # which is a true answer to the question asked.
  if ! declare -F _schema_is_subsectioned > /dev/null 2>&1 \
    || ! declare -p SCHEMA_SUBSECTIONED > /dev/null 2>&1; then
    _log_err conf conf_subsection_registry_missing \
      "display=cannot split the namespace key ${_nskey}: SCHEMA_SUBSECTIONED and its predicate are not both loaded, so whether its first component has sub-sections has no answer. conf.sh sources schema.sh itself, so reaching this means the registry was removed or shadowed rather than merely not sourced. Guessing here would file every sub-sectioned key under its parent section without saying so, including the per-service [logging.<svc>] blocks that worked before this registry existed." \
      "nskey=${_nskey}"
    return 1
  fi

  if [[ "${_nskey}" == *.*.* ]] \
    && _schema_is_subsectioned "${_nskey%%.*}"; then
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
# Load the merge of an arbitrary-length layer chain into <handle>. Files
# are given in INCREASING precedence (baseline first, the most local
# override last). Section order is the order the layers introduced them,
# lowest layer first.
#
# TOML chain (every existing layer is `.toml`, which is every chain the
# shipped readers build): the rule is ADR-00000037's, and the merge runs
# in the bridge where the types are native.
#
#   - A TABLE merges key by key, at every depth: the upper layer overrides
#     only the keys it names, the rest inherit, and a nested table
#     (`[logging.web]`) merges the same way rather than being replaced.
#   - An ARRAY is replaced ATOMICALLY: the list from the highest layer
#     that defines it wins whole. That is what the ordered lists need --
#     a per-element merge would assemble one list out of several layers,
#     would offer no way to REMOVE an item, and would require the author
#     of an upper layer to know the highest index used by a layer they
#     cannot see. The numbered `<prefix>_N` keys the shell view speaks are
#     a rendering of those arrays, so they inherit the atomicity.
#
# INI chain (the legacy file the frozen TUI writes, and any mixed chain):
# section-replace, which is what that format's readers have always done --
# the entries come wholesale from the highest layer that defines the
# section. ADR-00000037's rule is a rule about TOML tables and arrays, and
# an INI section is neither; the two formats are never mixed in one
# shipped chain, so this is a legacy path, not a second answer about
# setup.toml.
#
# Missing files are skipped (an absent layer contributes nothing), so callers
# pass the whole chain unconditionally.
_conf_load_layers() {
  local _h="${1:?"${FUNCNAME[0]}: missing handle"}"
  shift
  (( $# > 0 )) || { declare -g -a "${_h}__sects=()" "${_h}__es=()" "${_h}__keys=()" "${_h}__vals=()"; return 0; }

  # ── TOML path: type-aware merge via containerised bridge ──────────
  #
  # When every existing layer file is TOML, the merge (tables key-level
  # and recursive, arrays replaced atomically) runs in Python where the
  # type information is native (dict vs list).  ADR-37 sec. Merge
  # semantics.
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
    local _cll_row
    while IFS= read -r _cll_row; do
      _conf_kv_split "${_cll_row}" _cll_sect _cll_key _cll_val
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
# template/repo call sites read by. Same merge semantics.
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
#
# THE TIE IS NOT FILE ORDER, and that is a parked question, not a settled
# one. `sort -t: -k1,1n` is not stable, so two entries at the SAME index
# fall through to the whole-line comparison and resolve in alphabetical
# order of their VALUES. The TOML side can no longer produce such a pair
# -- a duplicate key is refused by TOML itself, and a family carried both
# as a table scalar and as an array block is declined by the shell view
# -- but `_ini_tokenize` preserves duplicate keys by design and this
# reader is shared, so a hand-edited INI layer still reaches it.
# base#1247 carries the decision between stabilising the order, refusing
# the tie, and leaving it; nothing here may be read as having made it.
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
#      `device_N`, `cgroup_rule_N`, `tmpfs_N`, `context_N`, `cap_add_N`,
#      `cap_drop_N`, `security_opt_N`)
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
# table (`[environment] env_N`): the bridge reads a table scalar back
# under its own name, so those keys round-trip as they are, and moving
# them is a reader-side change. `[environment]` is the last of these --
# ADR-00000037 splits it along the service boundary and the direct-key
# readers have not landed, so where its entries go is still open.
#
# `[devices]` hosts TWO numbered families, so each gets its own nested
# array path -- `device_N` -> `[[devices.bindings]]`, `cgroup_rule_N` ->
# `[[devices.cgroup_rules]]` -- the same shape `[security]` uses for
# `cap_add_N`, `cap_drop_N` and `security_opt_N`. One array at the
# section could not hold both: `[[devices]]` makes the name an array,
# and a rule left as a table scalar needed `[devices]`, which TOML
# refuses in the same document. A conf that binds a device AND allows a
# major number is ordinary, and `setup.sh set` wrote exactly that
# unparseable pair.

# _conf_toml_str <value> <outvar>
#
# Render a bash string as a TOML basic string, ALWAYS -- no type is
# inferred from the text. Backslash, double quote and tab are escaped;
# TOML has no other escape a config value can trip over.
#
# This is the renderer for a field whose TYPE is fixed by the bridge's
# array spec rather than by what the operator typed. Every field of an
# array-of-tables entry is one of those: the spec joins a volume's
# source / target / mode with `:` and formats a build arg into
# `key=value`, so the field is a string even when its text spells
# something else. Inferring a type there is not a cosmetic slip -- a
# numeric named volume (`123:/data`) rendered a bare `source = 123`,
# `":".join` was handed an int, and the TypeError stopped `--kv`
# mid-stream, so the WHOLE configuration failed to load over one mount.
# A build arg spelled `FEATURE=true` rendered a bare `value = true`, a
# TOML boolean the Dockerfile never asked for.
_conf_toml_str() {
  local _v="${1-}"
  local -n _ctstr_out="${2:?"${FUNCNAME[0]}: missing outvar"}"
  _v="${_v//\\/\\\\}"
  _v="${_v//\"/\\\"}"
  _v="${_v//$'\t'/\\t}"
  _ctstr_out="\"${_v}\""
}

# _conf_toml_scalar <value> <outvar>
#
# Render a bash string as the TOML scalar the bridge reads back to the
# same string. `true` / `false` and a CANONICAL TOML integer are bare;
# everything else goes through _conf_toml_str.
#
# For a TABLE key only: the table's keys are free-typed, and `init = true`
# / `max_file = 3` are how the shipped template spells them. An array
# field is NOT free-typed -- it takes _conf_toml_str directly.
#
# CANONICAL is the test, not VALID, and the two differ. The question this
# renderer answers is which text the bridge reads back as the SAME text --
# not which text TOML accepts. TOML accepts `-0`, `+1`, `0x10` and
# `1_000` as integers and reads them as 0, 1, 16 and 1000, so rendering
# any of them bare loses the operator's spelling: `[environment] env_1 =
# -0` came back `0`, the sign gone from a value someone typed
# (base#1234). Only `0` and a signed or unsigned run of digits with no
# leading zero spell themselves back, so only those stay bare and the
# other four forms are quoted -- the same rule the _conf_toml_str header
# applies to array fields, one level further in, and for the same reason:
# what a value LOOKS like is not its type.
#
# The shipped template spells none of those four bare. Measured against
# dist/setup.toml: its only bare scalars are the booleans `init`,
# `privileged`, `compress` and `wrapper_transcript` and the plain
# integers `max_file`, `container_log_keep`, `container_log_days`,
# `wrapper_transcript_keep` and `wrapper_transcript_days`. Quoting the
# four therefore changes no template value's type.
_conf_toml_scalar() {
  local _v="${1-}"
  local -n _cts_out="${2:?"${FUNCNAME[0]}: missing outvar"}"
  case "${_v}" in
    true|false) _cts_out="${_v}"; return 0 ;;
  esac
  if [[ "${_v}" =~ ^(0|-?[1-9][0-9]*)$ ]]; then
    _cts_out="${_v}"
    return 0
  fi
  _conf_toml_str "${_v}" _cts_out
}

# _conf_toml_header_uncomment <line> <outvar>
#
# <line> with a trailing header comment removed when it has one:
# `[network] # chosen mode` -> `[network] `. Every other line is copied
# through unchanged, so the bracket matchers that read the result keep
# their existing rule for everything that is not a header.
#
# A comment after the closing bracket is part of a VALID table header --
# TOML reads `[network] # chosen mode` as the `[network]` table, and so
# does the bridge. The writers required the `]` to be the last non-blank
# character of the line, so none of them saw a header there at all:
# `setup.sh set network.mode bridge` never entered the table, appended a
# SECOND `[network]` at the end of the file, and left the original value
# standing. TOML rejects a table declared twice, so a user who had
# commented their own config got a file nothing could read -- after a
# write that reported success.
#
# The cut is made at the first `#` AFTER the LAST `]`, which is where a
# comment can start. Inside the brackets a `#` belongs to a quoted key
# (`["stage:a#b"]` is legal TOML), and cutting at the first `#` in the
# line would truncate the header itself.
_conf_toml_header_uncomment() {
  local _line="${1-}" _after _before
  local -n _cthu_out="${2:?"${FUNCNAME[0]}: missing outvar"}"
  _cthu_out="${_line}"
  [[ "${_line}" == *\]* ]] || return 0
  _after="${_line##*\]}"
  [[ "${_after}" == *\#* ]] || return 0
  _before="${_line%"${_after}"}"
  _cthu_out="${_before}${_after%%\#*}"
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
#
# BOTH quote characters, because TOML has two quoted-key spellings and a
# hand-authored file may use either. Basic quotes are what
# _conf_toml_header writes, so stripping only those read `['network']`
# back as the name `'network'`: no writer recognised the section, and
# setting `network.mode` appended a SECOND `[network]` -- the duplicate
# table TOML refuses, from the same class of half-recognised header as a
# trailing comment.
_conf_header_name() {
  local _raw="${1-}"
  local -n _chn_out="${2:?"${FUNCNAME[0]}: missing outvar"}"
  _raw="${_raw//\"/}"
  _raw="${_raw//\'/}"
  _raw="${_raw#"${_raw%%[![:space:]]*}"}"
  _raw="${_raw%"${_raw##*[![:space:]]}"}"
  _chn_out="${_raw}"
}

# _conf_toml_index_rejected <file> <section> <key>
#
# Zero -- having said so -- when `<section>.<key>` names a numbered
# family of a TOML <file> with an index that has NO 1-based slot, so the
# write must not be routed to an array block at all.
#
# Index N of the array IS the key `<prefix>_N`, and the writer addresses
# a block by its POSITION, so a suffix that is not the plain decimal
# spelling of a position lands somewhere else under a different name.
# Measured on the shipped template, whose `[volumes]` holds no block:
# `set volumes.mount_0` and `set volumes.mount_01` each wrote one block
# that read back as `mount_1` -- the workspace bind -- so a key the
# operator typed became the one slot that redirects WS_PATH.
#
# The converter already DECLINES exactly these two shapes, by name, for
# exactly this reason (ini_to_toml_migrate.sh: "a populated `_0` has no
# 1-based slot", `mount_01`). The writer was missing the same check, and
# `_conf_toml_aot_slot` is deliberately NOT tightened to supply it: the
# converter's decline depends on that matcher still RECOGNISING a
# non-canonical suffix, so narrowing it there would turn a named refusal
# into a key silently carried over as a table scalar.
_conf_toml_index_rejected() {
  local _f="${1-}" _s="${2-}" _k="${3-}"
  [[ "${_f}" == *.toml ]] || return 1
  local _cti_p="" _cti_n=""
  _conf_toml_aot_slot "${_s}" "${_k}" _cti_p _cti_n || return 1
  [[ "${_cti_n}" =~ ^[1-9][0-9]*$ ]] && return 1
  _log_err conf conf_write_index_rejected \
    "display=[conf] refusing to write ${_s}.${_k} into ${_f}: an entry of a numbered family is the ${_cti_p} array's N-th block, and '${_cti_n}' is not the plain decimal spelling of a position -- there is no slot of that name, so the value would land in another one. Use the index you mean, counting from 1." \
    "file=${_f}" "section=${_s}" "key=${_k}" "index=${_cti_n}"
  return 0
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
  local -a _cas_fams=()
  _conf_toml_aot_section "${_s}" _cas_fams || return 1
  local _cas_f
  for _cas_f in ${_cas_fams[@]+"${_cas_fams[@]}"}; do
    [[ "${_k}" =~ ^${_cas_f%%=*}_([0-9]+)$ ]] || continue
    _cas_path="${_cas_f#*=}"
    _cas_idx="${BASH_REMATCH[1]}"
    return 0
  done
  return 1
}

# _conf_toml_aot_section <section> <outvar_array>
#
# Every numbered family a section HOSTS, as `<prefix>=<path>` pairs:
# `[security]` answers `cap_add=security.cap_add`,
# `cap_drop=security.cap_drop` and
# `security_opt=security.security_opt`. Returns 1 for a section with no
# family at all (`[gui]`, `[logging]`).
#
# `cap_drop` is here because its two siblings are. All three are read by
# the same `_conf_list_sorted _RDC_CONF security "<prefix>_"` call in
# _resolve_docker_conf, so a family of the three with only two homes was
# an omission rather than a distinction. Without a home it was carried as
# a scalar and merged KEY BY KEY, so an upper layer replacing the list
# no longer replaced it and the lower layer's drops survived -- the
# effective drop list stopped being the one the layering says. Note the
# direction: a drop that survives REMOVES a capability, so this one
# over-restricts rather than exposing, which is why it breaks a workload
# instead of opening one up. cap_add's version of the same defect runs
# the other way.
#
# THE table. _conf_toml_aot_slot is a lookup over it, so the question
# "which array does this key belong to" and the question "which arrays
# does this section have" cannot drift apart -- and the second one has a
# caller: the INI-to-TOML converter asks it to decide which arrays a
# converted section has EMPTIED. Under the pre-ADR-37 chain a section was
# replaced whole, so an INI override layer naming `[security]` at all
# left the layer below with no cap_add entries; the TOML merge is
# key-level, so that is a `cap_add = []` the converted file has to carry
# or the list comes back.
_conf_toml_aot_section() {
  local _s="${1-}"
  local -n _ctas_out="${2:?"${FUNCNAME[0]}: missing outvar"}"
  _ctas_out=()
  case "${_s}" in
    image)               _ctas_out=("rule=image.rules") ;;
    build)               _ctas_out=("arg=build.args") ;;
    network)             _ctas_out=("port=network.ports") ;;
    volumes)             _ctas_out=("mount=volumes") ;;
    tmpfs)               _ctas_out=("tmpfs=tmpfs") ;;
    devices)             _ctas_out=("device=devices.bindings"
                                    "cgroup_rule=devices.cgroup_rules") ;;
    additional_contexts) _ctas_out=("context=additional_contexts") ;;
    security)            _ctas_out=("cap_add=security.cap_add"
                                    "cap_drop=security.cap_drop"
                                    "security_opt=security.security_opt") ;;
    *) return 1 ;;
  esac
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
    security.cap_drop)     _can_out="security.cap_drop_${_n}" ;;
    security.security_opt) _can_out="security.security_opt_${_n}" ;;
    volumes)               _can_out="volumes.mount_${_n}" ;;
    tmpfs)                 _can_out="tmpfs.tmpfs_${_n}" ;;
    devices.bindings)      _can_out="devices.device_${_n}" ;;
    devices.cgroup_rules)  _can_out="devices.cgroup_rule_${_n}" ;;
    devices)               _can_out="devices.device_${_n}" ;;
    additional_contexts)   _can_out="additional_contexts.context_${_n}" ;;
    *) return 1 ;;
  esac
  return 0
}

# _conf_toml_empty_array_decl <line> <table> <path_outvar>
#
# True when <line> declares, as `[]`, an array the bridge's spec knows:
# `args = []` seen inside `[build]` is the path `build.args`, and
# `volumes = []` seen at the document root is `volumes`. <path_outvar>
# comes back with that path.
#
# Why the writers read these lines instead of copying them. `args = []`
# is an ordinary key, and TOML will not let a key already bound to an
# array be extended by `[[build.args]]` blocks -- the bridge answers
# `Cannot mutate immutable namespace ('build', 'args')` and the whole
# file stops parsing. So a declaration left behind by a removal has to go
# when an entry is added back, or remove-then-add is not a round trip:
# the add reports success and every read after it fails. Each writer
# therefore DROPS the declaration on the way through and writes one back
# only while the list is still empty -- which also keeps an operator's
# deliberate clear, since a save that does not refill the list re-decides
# it the same way.
# Every local here is `_ctea_`-prefixed, the outvars this function hands
# to other helpers included: _conf_line_key declares a local `_k` of its
# own, so a nameref pointing at the bare name `_k` resolves to the
# CALLEE's variable and the key comes back empty -- which read every
# declaration as the path `build.` and matched nothing.
_conf_toml_empty_array_decl() {
  local _line="${1-}" _table="${2-}"
  local _ctea_k="" _ctea_v="" _ctea_cand="" _ctea_probe=""
  local -n _ctea_out="${3:?"${FUNCNAME[0]}: missing path outvar"}"
  _ctea_out=""
  _conf_is_kv_line "${_line}" || return 1
  _ctea_v="${_line#*=}"
  _ctea_v="${_ctea_v#"${_ctea_v%%[![:space:]]*}"}"
  _ctea_v="${_ctea_v%"${_ctea_v##*[![:space:]]}"}"
  # Whitespace inside the brackets, and a trailing comment, are both part
  # of a valid declaration -- `args = [ ]  # intentionally cleared` is
  # still an empty array, and an operator who clears a list is exactly
  # the one who writes down why. Matched as the bare two characters, the
  # annotated spelling was copied through and the next added entry landed
  # beside a key already bound to an array: the unreadable file again,
  # reached by annotating the decision the declaration records. (A
  # declaration the writers re-create carries no annotation; only one
  # `setup add` retired behind _CONF_ADD_DECL_NOTE comes back as it was
  # spelled.)
  [[ "${_ctea_v}" =~ ^\[[[:space:]]*\][[:space:]]*(#.*)?$ ]] || return 1
  _conf_line_key "${_line}" _ctea_k
  _ctea_cand="${_table:+${_table}.}${_ctea_k}"
  # Only a path the array spec names is one of ours. Anything else is an
  # ordinary key whose value happens to be an empty array.
  _conf_toml_aot_nskey "${_ctea_cand}" 1 _ctea_probe || return 1
  _ctea_out="${_ctea_cand}"
}

# _conf_toml_array_decl <path> <table_out> <key_out>
#
# Where an EXPLICIT declaration of the array at <path> belongs, and under
# what key: `build.args` is the key `args` of the table `build`,
# `volumes` is the key `volumes` of the document root (<table_out> empty).
#
# `[[build.args]]` is sugar -- the array is still an ordinary key of an
# ordinary table -- so `args = []` is how the same array is declared with
# nothing in it, and it has to sit inside `[build]` like any other key of
# it. TOML gives a root-level key exactly one home, the region before the
# first table header, which is why the root case is answered separately
# rather than being written wherever the blocks used to be.
_conf_toml_array_decl() {
  local _p="${1-}"
  local -n _ctad_table="${2:?"${FUNCNAME[0]}: missing table outvar"}"
  local -n _ctad_key="${3:?"${FUNCNAME[0]}: missing key outvar"}"
  if [[ "${_p}" == *.* ]]; then
    _ctad_table="${_p%.*}"
    _ctad_key="${_p##*.}"
  else
    _ctad_table=""
    _ctad_key="${_p}"
  fi
}

# _conf_toml_aot_fields <path> <value> <outvar>
#
# The body of one `[[<path>]]` block for a numbered-key value, as the
# bridge's array spec serialises it back: `KEY=VALUE` splits into
# key / value, `host:container` into host / container, a mount into
# source / target / mode, and a bare entry is its one field. Lines are
# newline-joined, no trailing newline.
#
# Every one of those fields is STRING-typed, so every one of them is
# rendered by _conf_toml_str and not by _conf_toml_scalar. The split that
# produced it is textual -- the array spec joins the halves back with `:`
# or `=` -- so what the half happens to look like is not a type. See the
# _conf_toml_str header for what inferring one cost.
#
# A half the value does not HAVE is a field this writes no line for, and
# that absence is the whole record of it: the array spec joins the fields
# a block has, so an absent `value` reads back as `HTTP_PROXY` while a
# `value = ""` reads back as `HTTP_PROXY=`. Rendering the missing half as
# `""` instead made the two the same string, and they are two different
# build arguments -- one inherits from the build environment, the other
# sets it empty. `80` came back `80:`, which is not a port mapping
# compose accepts at all. The empty half still gets its line when the
# separator WAS there, which is what keeps a three-field mount's
# positions: `/srv/data::ro` writes an empty `target` so `mode` cannot
# slide into it.
_conf_toml_aot_fields() {
  local _p="${1-}" _v="${2-}"
  local -n _caf_out="${3:?"${FUNCNAME[0]}: missing outvar"}"
  local _a _b _c
  _caf_out=""
  case "${_p}" in
    image.rules)
      _conf_toml_str "${_v}" _a
      _caf_out="rule = ${_a}"
      ;;
    build.args|additional_contexts)
      local _caf_f1="key" _caf_f2="value"
      if [[ "${_p}" == additional_contexts ]]; then
        _caf_f1="name"
        _caf_f2="source"
      fi
      _conf_toml_str "${_v%%=*}" _a
      _caf_out="${_caf_f1} = ${_a}"
      if [[ "${_v}" == *=* ]]; then
        _conf_toml_str "${_v#*=}" _b
        _caf_out+=$'\n'"${_caf_f2} = ${_b}"
      fi
      ;;
    network.ports)
      _conf_toml_str "${_v%%:*}" _a
      _caf_out="host = ${_a}"
      if [[ "${_v}" == *:* ]]; then
        _conf_toml_str "${_v#*:}" _b
        _caf_out+=$'\n'"container = ${_b}"
      fi
      ;;
    security.cap_add|security.cap_drop)
      _conf_toml_str "${_v}" _a
      _caf_out="cap = ${_a}"
      ;;
    security.security_opt)
      _conf_toml_str "${_v}" _a
      _caf_out="opt = ${_a}"
      ;;
    volumes)
      # `_caf_`-prefixed like the function's other locals, and not the bare
      # `_rest` it was: this file is read by ShellCheck with -x, so a name
      # a SOURCED library declares as an array is one every scalar use of
      # that name here is reported for. toml_bridge.sh now pulls in
      # project_reclaim.sh for the bridge tag's content digest, and that
      # library has a `local -a _rest`.
      local _caf_rest=""
      _conf_toml_str "${_v%%:*}" _a
      _caf_out="source = ${_a}"
      if [[ "${_v}" == *:* ]]; then
        _caf_rest="${_v#*:}"
        _conf_toml_str "${_caf_rest%%:*}" _b
        _caf_out+=$'\n'"target = ${_b}"
        if [[ "${_caf_rest}" == *:* ]]; then
          _conf_toml_str "${_caf_rest#*:}" _c
          _caf_out+=$'\n'"mode = ${_c}"
        fi
      fi
      ;;
    tmpfs|devices|devices.bindings)
      _conf_toml_str "${_v}" _a
      _caf_out="path = ${_a}"
      ;;
    devices.cgroup_rules)
      _conf_toml_str "${_v}" _a
      _caf_out="rule = ${_a}"
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
#
# BOTH quote forms, because TOML has two and a hand-edited file uses
# either: `'mode' = 'host'` is a literal-quoted key and exactly as valid
# as `"mode"`. Stripping only the double quotes left the key as
# `'mode'`, so `setup.sh set network.mode bridge` did not recognise the
# line it was there to replace and appended a SECOND `mode` to the table
# -- which TOML refuses (`Cannot overwrite a value`), so a file that
# parsed before the write stopped parsing after it, and the write
# reported success. The table HEADER matcher already took both forms
# (`_conf_header_name`, pinned by the literal-quoted-header test); this
# is that rule one level down, and `_setup_remove` reads keys through
# here too.
#
# A MATCHED pair only. Stripped independently, a key half that merely
# ENDS in a quote loses a character it owns.
_conf_line_key() {
  local _line="${1-}" _k
  local -n _clk_out="${2:?"${FUNCNAME[0]}: missing outvar"}"
  _k="${_line%%=*}"
  _k="${_k#"${_k%%[![:space:]]*}"}"
  _k="${_k%"${_k##*[![:space:]]}"}"
  if (( ${#_k} >= 2 )); then
    case "${_k}" in
      \"*\") _k="${_k#\"}"; _k="${_k%\"}" ;;
      \'*\') _k="${_k#\'}"; _k="${_k%\'}" ;;
    esac
  fi
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
    __wsc_nw=$(( __wsc_nw + 1 ))
  done
  # This is also where <section>'s key scope ends, so it is where an
  # emptied array belonging to <section> gets its explicit declaration.
  _wsc_flush_empty_arrays "${_sect}"
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

# _wsc_close_aot <path>
#
# Append <path>'s added blocks where the walk leaves its run of
# `[[<path>]]` blocks for a header. With blank lines held back (see
# _wsc_emit) the separator before the header is still to come, so the
# blocks go in `eof` shape (blank line first) and land ahead of it;
# with none held back they go in `boundary` shape (blank line after).
_wsc_close_aot() {
  if (( __wsc_blank > 0 )); then
    _wsc_flush_aot "${1}" eof
  else
    _wsc_flush_aot "${1}" boundary
  fi
}

# _wsc_flush_empty_arrays <table>
#
# Declare, as `<key> = []`, each array path this rewrite leaves with no
# blocks whose declaration belongs in <table> (the empty string for the
# document root). Called at the point <table>'s key scope ends, so the
# line lands inside the table it belongs to; each path is declared once.
_wsc_flush_empty_arrays() {
  local _table="${1-}"
  local __fea_p __fea_t __fea_k
  for __fea_p in "${!__aot_empty[@]}"; do
    [[ -z "${__aot_empty_done[${__fea_p}]:-}" ]] || continue
    _conf_toml_array_decl "${__fea_p}" __fea_t __fea_k
    [[ "${__fea_t}" == "${_table}" ]] || continue
    _conf_toml_key "${__fea_k}" __fea_k
    printf '%s = []\n' "${__fea_k}" >> "${_out}"
    __aot_empty_done["${__fea_p}"]=1
    __wsc_nw=$(( __wsc_nw + 1 ))
  done
}

# _wsc_emit <line>
#
# Write one non-blank line of the walk: the blank lines held back before
# it first, then the line. Blank lines are held back so that what a
# table's end appends (added keys, emptied-array declarations) lands
# after the table's last line and before the blank lines that separate
# it from the next header, not after them (base#1363).
_wsc_emit() {
  _wsc_emit_blanks
  printf '%s\n' "${1}" >> "${_out}"
  __wsc_nw=$(( __wsc_nw + 1 ))
  __wsc_tail_removed=0
}

# _wsc_emit_blanks
#
# Write the blank lines the walk is holding back.
_wsc_emit_blanks() {
  while (( __wsc_blank > 0 )); do
    printf '\n' >> "${_out}"
    __wsc_blank=$(( __wsc_blank - 1 ))
  done
}

# _wsc_end_table
#
# _wsc_end_table [eof]
#
# Close the `[table]` whose keys are in scope: append its added keys and
# emptied-array declarations, and -- unless the file ends here [eof] --
# put back the blank line that separates appended keys from the next
# header when the file had none.
#
# Then drop the table when this save removed a key from it, left nothing
# under the header, and the header carries _CONF_ADD_TABLE_NOTE, the
# comment `setup add` writes on a table it creates. Only the note tells
# such a table apart from an empty one the file already held: `add`
# gives back the same bytes for a file without `[environment]` and for
# one ending in an empty `[environment]` (base#1363). What goes is the
# header and ONE blank line, the one `add` put before it (or, with none
# before it, the one after it); every other blank line stays.
_wsc_end_table() {
  local _nw_before="${__wsc_nw}" _keep
  _wsc_flush_scalars "${__current}"
  if [[ "${1-}" != eof ]] && (( __wsc_nw > _nw_before && __wsc_blank == 0 )); then
    __wsc_blank=1
  fi
  if (( __wsc_tbl_removed && __wsc_tbl_noted && __wsc_nw == __wsc_tbl_nw )); then
    _keep="$(head -c "${__wsc_tbl_off}" "${_out}"; printf x)"
    printf '%s' "${_keep%x}" > "${_out}"
    if (( !__wsc_tbl_sep && __wsc_blank > 0 )); then
      __wsc_blank=$(( __wsc_blank - 1 ))
    fi
  fi
  __wsc_tbl_removed=0
}

# _wsc_begin_table <header-line>
#
# Note where the table about to be written starts: the size of the
# output before the last blank line held back ahead of its header (the
# others are written now, so dropping the table cannot take them), how
# many lines will have been written once the header is, whether one
# blank line separates it from what came before, and whether its header
# carries _CONF_ADD_TABLE_NOTE.
_wsc_begin_table() {
  __wsc_tbl_sep=0
  if (( __wsc_blank > 0 )); then
    __wsc_blank=$(( __wsc_blank - 1 ))
    _wsc_emit_blanks
    __wsc_blank=1
    __wsc_tbl_sep=1
  fi
  __wsc_tbl_off="$(wc -c < "${_out}")"
  __wsc_tbl_nw=$(( __wsc_nw + 1 ))
  __wsc_tbl_removed=0
  __wsc_tbl_noted=0
  if (( __toml )) && [[ "${1-}" == *"] ${_CONF_ADD_TABLE_NOTE}" ]]; then
    __wsc_tbl_noted=1
  fi
}

# _wsc_refuse_ws_slot_move <dst>
#
# Zero -- having said so -- when this save would hand slot 1 of
# `[volumes]` to something that is not the workspace bind. One for every
# other save.
#
# Removing an entry of an array of tables COMPACTS the ones after it, and
# for every family but one that is simply the list getting shorter. Slot
# 1 of `[volumes]` is the workspace bind, identified by POSITION and
# nothing else, so a removal there promotes the operator's next mount
# into the workspace position. Measured on a two-mount file, both ways:
#   - the promoted source EXISTS on this machine ->
#     `_reconcile_workspace_path` reads it as a deliberately pinned
#     workspace and warns about nothing, so WS_PATH resolves to the
#     operator's data directory and the container's workspace binds
#     there instead of the repo;
#   - the source is ABSENT -> the stale-path branch WARNs and overwrites
#     that bind with the portable workspace mount on the next apply, so
#     the operator's own mount is gone from the file.
# Neither outcome is a removal of `mount_1`, and both are silent at the
# moment the operator asks for one.
#
# So the save is REFUSED, before the rewrite is built and with <dst>
# untouched -- the answer the converter already gives for the six INI
# shapes it cannot represent faithfully, rather than guessing. The
# message names the CLEAR instead: an empty `mount_1` is the published
# opt-out, `setup.sh` does not re-populate it, and it moves no other
# slot. Clearing is not removing; only the removal is contained here.
#
# NARROW, or it would be a blanket ban on `remove` over `[volumes]`. The
# question asked is whether anything is LEFT to occupy slot 1, which is
# exactly `__aot_empty` not naming `volumes`: a removal that empties the
# array writes `volumes = []` and promotes nothing, and a removal above
# slot 1 leaves slot 1 where it is. Both still succeed. An INI
# destination is out of scope because it renumbers nothing -- the
# remaining keys keep their own suffixes and the gap is tolerated.
#
# base#1233 asks how the workspace bind SHOULD be identified -- a named
# key, or target matching -- and this function does not answer it. It
# writes nothing, so nothing on disk commits to an answer either.
#
# Called from _write_setup_conf only; reads its walk state through bash's
# dynamic scope, like the `_wsc_flush_*` helpers above.
_wsc_refuse_ws_slot_move() {
  local _dst="${1-}"
  local _slot="volumes.mount_1"
  [[ "${_dst}" == *.toml ]] || return 1
  [[ -n "${__removed[${_slot}]+x}" ]] || return 1
  (( ${__aot_total[volumes]:-0} >= 1 )) || return 1
  [[ -z "${__aot_empty[volumes]:-}" ]] || return 1
  _log_err conf conf_write_ws_slot_refused \
    "display=[conf] WRITE DECLINED for ${_dst}: ${_slot} was to be removed, and removing an entry of an array compacts the ones after it -- the next mount would take slot 1, which is the workspace bind by position and nothing else. That bind would become the container's workspace when its source exists on this machine, and would itself be overwritten by the portable workspace mount on the next apply when it does not. Nothing was written and ${_dst} is unchanged. To stop mounting a workspace, CLEAR the entry instead of removing it: 'setup.sh set volumes.mount_1 \"\"' leaves slot 1 in place and empty, setup.sh does not re-populate it, and no other mount moves. To drop the other mounts, remove them by their own index. base#1233 carries how the workspace bind should be identified." \
    "file=${_dst}" "key=${_slot}"
  return 0
}

# _conf_take_mode <dst> <tmp>
#   Give the rewrite in <tmp> the mode <dst> should end up with, before
#   the `mv` lands it. <tmp> comes from a bare mktemp (0600), so without
#   this every rewrite of a user-owned setup.toml left it at 0600
#   (base#1356). An existing <dst> keeps its own mode (the base#1323
#   precedent, chmod --reference); a <dst> the write is about to create
#   gets the mode any new file gets under the caller's umask.
#   Non-zero when the chmod fails: the caller must then not land <tmp>,
#   which would put the 0600 file this helper exists to prevent in place.
_conf_take_mode() {
  local _dst="${1:?BUG: _conf_take_mode expects a destination}"
  local _tmp="${2:?BUG: _conf_take_mode expects the rewritten file}"
  if [[ -e "${_dst}" ]]; then
    chmod --reference="${_dst}" -- "${_tmp}"
  else
    chmod "$(printf '%o' $(( 0666 & ~0$(umask) )))" -- "${_tmp}"
  fi
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

  # The same index refusal the per-key writer makes, over every key this
  # save carries, and BEFORE any of them is written: a save is one unit,
  # so a key with no slot to land in refuses the save rather than being
  # dropped out of it silently. The TUI composes these keys itself, and
  # the commit gate below cannot catch this one -- the file stays valid
  # TOML, with the value in the wrong block.
  local __wsc_s="" __wsc_k=""
  for i in "${_wsc_keys[@]+"${_wsc_keys[@]}"}" ${_removed_keys}; do
    _conf_split_nskey "${i}" __wsc_s __wsc_k || continue
    if _conf_toml_index_rejected "${_dst}" "${__wsc_s}" "${__wsc_k}"; then
      return 1
    fi
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
  local -A __aot_empty=() __aot_empty_done=() __aot_declared_empty=()
  local __root_decls_flushed=0 __eap="" __decl=""
  local __ovk __ovk_sect __ovk_key __p __n __hline
  if (( __toml )); then
    for __ovk in "${!__override[@]}"; do
      _conf_split_nskey "${__ovk}" __ovk_sect __ovk_key || continue
      if _conf_toml_aot_slot "${__ovk_sect}" "${__ovk_key}" __p __n; then
        __aot_of["${__ovk}"]="${__p}"
        __aot_idx_of["${__ovk}"]="${__n}"
      fi
    done
    local __pp_table="" __pp_in_aot=0
    for __line in "${__tpl_lines[@]}"; do
      _conf_toml_header_uncomment "${__line}" __hline
      if [[ "${__hline}" =~ ^[[:space:]]*\[\[(.+)\]\][[:space:]]*$ ]]; then
        _conf_header_name "${BASH_REMATCH[1]}" __p
        __aot_total["${__p}"]=$(( ${__aot_total["${__p}"]:-0} + 1 ))
        __pp_table=""
        __pp_in_aot=1
        continue
      fi
      if [[ "${__hline}" =~ ^[[:space:]]*\[(.+)\][[:space:]]*$ ]]; then
        _conf_header_name "${BASH_REMATCH[1]}" __pp_table
        __pp_in_aot=0
        continue
      fi
      # An array the file ALREADY declares empty: the clear is an
      # operator decision, so it has to survive a save that does not
      # refill the list. Without this the walk would drop the line (it
      # re-decides every such declaration) and nothing would write one
      # back, because the path has no blocks to count.
      if (( ! __pp_in_aot )) \
         && _conf_toml_empty_array_decl "${__line}" "${__pp_table}" __eap; then
        __aot_declared_empty["${__eap}"]=1
      fi
    done
    # Which arrays this rewrite leaves with NO blocks: every block of the
    # path is removed and no override puts one back.
    #
    # Such a path must keep an EXPLICIT declaration, `key = []`. Arrays
    # are replaced atomically at every depth, so an operator who removed
    # the last entry of a list has replaced that list with nothing --
    # which is what an empty array says. Dropping the declaration says
    # something else entirely: the key is ABSENT, the one state that is
    # not a replacement, and the merge then inherits the layer below. A
    # `setup remove build.arg_1` against a repo's single build argument
    # was handing back every build argument the template defines.
    # A FAMILY THIS LAYER HAS NO BLOCK OF IS ONE OF THOSE PATHS, and the
    # block count alone cannot see it. A removal names a slot of the
    # EFFECTIVE list, which may be inherited whole: an operator clearing
    # the template's only `[[build.args]]` entry from a repo whose own
    # file declares no args has decided this repo takes no build
    # arguments, and under atomic array replacement the only way to say
    # that is `args = []` in this layer. Counted off the blocks alone the
    # path was absent from this loop, nothing wrote a declaration, and
    # the removal had no way to take effect at all -- the save was
    # declined and the operator was told to edit the file by hand. So the
    # paths the save REMOVES FROM are seeded at zero beside the ones it
    # counted blocks for; zero reads the same as absent everywhere else
    # `__aot_total` is consulted, and the loop below then finds no live
    # slot and no override and declares the array empty, which is the
    # state ADR-00000037's zero-entry amendment says this is.
    local __sp_nskey __sp_s __sp_k __sp_p __sp_n
    for __sp_nskey in "${!__removed[@]}"; do
      _conf_split_nskey "${__sp_nskey}" __sp_s __sp_k || continue
      _conf_toml_aot_slot "${__sp_s}" "${__sp_k}" __sp_p __sp_n || continue
      [[ -n "${__aot_total[${__sp_p}]+x}" ]] && continue
      __aot_total["${__sp_p}"]=0
    done
    local __fe_n __fe_live __fe_nskey
    for __p in "${!__aot_total[@]}"; do
      __fe_live=0
      for (( __fe_n = 1; __fe_n <= ${__aot_total[${__p}]}; __fe_n++ )); do
        if ! _conf_toml_aot_nskey "${__p}" "${__fe_n}" __fe_nskey \
           || [[ -z "${__removed[${__fe_nskey}]+x}" ]]; then
          __fe_live=1
          break
        fi
      done
      (( __fe_live )) && continue
      for __ovk in "${!__aot_of[@]}"; do
        [[ "${__aot_of[${__ovk}]}" == "${__p}" ]] || continue
        [[ -n "${__removed[${__ovk}]+x}" ]] && continue
        __fe_live=1
        break
      done
      (( __fe_live )) || __aot_empty["${__p}"]=1
    done
    # Same question for a path the file declares empty and has no block
    # of: it stays empty unless an override refills it.
    for __p in "${!__aot_declared_empty[@]}"; do
      [[ -z "${__aot_total[${__p}]:-}" ]] || continue
      __fe_live=0
      for __ovk in "${!__aot_of[@]}"; do
        [[ "${__aot_of[${__ovk}]}" == "${__p}" ]] || continue
        [[ -n "${__removed[${__ovk}]+x}" ]] && continue
        __fe_live=1
        break
      done
      (( __fe_live )) || __aot_empty["${__p}"]=1
    done
  fi

  # The one array position that identifies something rather than just
  # ordering it. Asked here because the answer needs `__aot_empty` --
  # whether anything is left to be promoted into slot 1 -- and asked
  # before the walk writes a byte, so a refusal leaves _dst exactly as it
  # was.
  if _wsc_refuse_ws_slot_move "${_dst}"; then
    rm -f "${_out}"
    return 1
  fi

  # Walk state: __current is the table whose scalar keys are in scope;
  # __aot_cur the array-of-tables path whose block is in scope (one of
  # the two is always empty); __aot_skip says what to do with the body of
  # the current block: 0 copy, 1 drop (removed), 2 drop its key lines
  # (replaced, the new fields already written).
  local __current="" __aot_cur="" __aot_skip=0 __nskey __raw __rest __hdr __kv __fields
  # __wsc_blank: blank lines read and not yet written (see _wsc_emit);
  # __wsc_nw: non-blank lines written so far; __wsc_tbl_*: where the
  # current `[table]` started and whether this save removed a key of it
  # (see _wsc_end_table).
  local __wsc_blank=0 __wsc_nw=0 __wsc_tbl_off=0 __wsc_tbl_nw=0 __wsc_tbl_removed=0
  local __wsc_tbl_sep=0 __wsc_tbl_noted=0
  # __wsc_tail_removed: the last thing read was a removed `[[...]]` block;
  # __wsc_skip_blank: blank lines that ended it, read and not written.
  local __wsc_tail_removed=0 __wsc_skip_blank=0
  : > "${_out}"
  for __line in "${__tpl_lines[@]}"; do
    # The root-key region ends at the first table header, so that is the
    # last point a root-level array (`volumes`, `tmpfs`) can be declared
    # empty. Written where its blocks used to be, the key would land
    # inside whichever table precedes them.
    # A header's own trailing comment is read off before any bracket
    # matcher sees the line; the line itself is still written verbatim,
    # comment included.
    __hline="${__line}"
    (( __toml )) && _conf_toml_header_uncomment "${__line}" __hline
    if (( __toml && ! __root_decls_flushed )) \
       && [[ "${__hline}" =~ ^[[:space:]]*\[ ]]; then
      _wsc_flush_empty_arrays ""
      __root_decls_flushed=1
    fi
    if (( __toml )) && [[ "${__hline}" =~ ^[[:space:]]*\[\[(.+)\]\][[:space:]]*$ ]]; then
      _conf_header_name "${BASH_REMATCH[1]}" __p
      if [[ -n "${__current}" ]]; then
        _wsc_end_table
        __current=""
      fi
      if [[ -n "${__aot_cur}" && "${__aot_cur}" != "${__p}" ]] \
         && (( ${__aot_seen[${__aot_cur}]:-0} >= ${__aot_total[${__aot_cur}]:-0} )); then
        _wsc_close_aot "${__aot_cur}"
      fi
      __aot_cur="${__p}"
      __aot_seen["${__p}"]=$(( ${__aot_seen["${__p}"]:-0} + 1 ))
      __aot_skip=0
      if _conf_toml_aot_nskey "${__p}" "${__aot_seen["${__p}"]}" __nskey; then
        if [[ -n "${__removed[${__nskey}]+x}" ]]; then
          # REMOVAL COMPACTS: skipping this block renumbers every block
          # after it. That is correct for every family but one. Slot 1 of
          # `[volumes]` is the workspace bind, identified by POSITION and
          # nothing else, so `remove volumes.mount_1` would make what was
          # `mount_2` into the workspace -- and
          # `_reconcile_workspace_path` then either honours the promoted
          # source as a pinned workspace (silently, when it exists) or
          # overwrites the operator's own bind with the portable
          # workspace mount. Such a save never reaches this line:
          # `_wsc_refuse_ws_slot_move` declines it up front, with the
          # file untouched, whenever anything would be left to promote.
          # base#1233 still carries how the workspace bind SHOULD be
          # identified, and ADR-00000022 publishes the positional
          # convention any answer would depart from; the refusal contains
          # the edit without answering either, and writes nothing that
          # would commit to an answer -- the same note
          # `_setup_remove`'s header carries one level up.
          __emitted[${__nskey}]=1
          __aot_skip=1
          __wsc_tail_removed=1
          __wsc_skip_blank=0
          continue
        fi
        _wsc_emit "${__line}"
        if [[ -n "${__override[${__nskey}]+x}" ]]; then
          _conf_toml_aot_fields "${__p}" "${__override[${__nskey}]}" __fields
          _wsc_emit "${__fields}"
          __emitted[${__nskey}]=1
          __aot_skip=2
        fi
        continue
      fi
      _wsc_emit "${__line}"
      continue
    fi
    if [[ "${__hline}" =~ ^[[:space:]]*\[(.+)\][[:space:]]*$ ]]; then
      # Taken before the flushes below: the TOML renderers match
      # patterns of their own, and BASH_REMATCH is one global.
      __raw="${BASH_REMATCH[1]}"
      # Flush not-yet-emitted overrides belonging to the section we are
      # about to leave (those are "added" keys with no template line).
      if [[ -n "${__current}" ]]; then
        _wsc_end_table
      fi
      if [[ -n "${__aot_cur}" ]] \
         && (( ${__aot_seen[${__aot_cur}]:-0} >= ${__aot_total[${__aot_cur}]:-0} )); then
        _wsc_close_aot "${__aot_cur}"
      fi
      __aot_cur=""
      __aot_skip=0
      if (( __toml )); then
        _conf_header_name "${__raw}" __current
      else
        __current="${__raw}"
      fi
      _wsc_begin_table "${__line}"
      _wsc_emit "${__line}"
      continue
    fi
    if (( __aot_skip == 1 )); then
      if [[ -z "${__line}" ]]; then
        __wsc_skip_blank=$(( __wsc_skip_blank + 1 ))
      else
        __wsc_skip_blank=0
      fi
      continue
    fi
    if (( __aot_skip == 2 )) && _conf_is_kv_line "${__line}"; then
      continue
    fi
    if [[ -z "${__line}" ]]; then
      __wsc_blank=$(( __wsc_blank + 1 ))
      continue
    fi
    # A declaration `setup add` retired (see _CONF_ADD_DECL_NOTE) comes
    # back, as it was spelled and where it stood, once this rewrite
    # leaves its list empty; until then the comment is copied.
    if (( __toml )) && [[ -z "${__aot_cur}" \
          && "${__line}" == "${_CONF_ADD_DECL_NOTE}"* ]]; then
      __decl="${__line#"${_CONF_ADD_DECL_NOTE}"}"
      if _conf_toml_empty_array_decl "${__decl}" "${__current}" __eap \
         && [[ -n "${__aot_empty[${__eap}]:-}" \
               && -z "${__aot_empty_done[${__eap}]:-}" ]]; then
        _wsc_emit "${__decl}"
        __aot_empty_done["${__eap}"]=1
        continue
      fi
    fi
    if [[ "${__line}" =~ ^[[:space:]]*# ]]; then
      _wsc_emit "${__line}"
      continue
    fi
    # An explicit empty-array declaration is re-decided: it is kept, in
    # its place, while the path is still empty, and dropped when an
    # override refills it (TOML refuses to extend a key already bound to
    # an array). Kept where it stands, the file's own order of `x = []`
    # lines survives a rewrite that does not touch them (base#1363).
    if (( __toml )) && [[ -z "${__aot_cur}" ]] \
       && _conf_toml_empty_array_decl "${__line}" "${__current}" __eap; then
      if [[ -n "${__aot_empty[${__eap}]:-}" && -z "${__aot_empty_done[${__eap}]:-}" ]]; then
        _wsc_emit "${__line}"
        __aot_empty_done["${__eap}"]=1
      fi
      continue
    fi
    if [[ -n "${__current}" && "${__line}" == *=* ]]; then
      _conf_line_key "${__line}" __rest
      __nskey="${__current}.${__rest}"
      if [[ -n "${__removed[${__nskey}]+x}" ]]; then
        __emitted[${__nskey}]=1
        __wsc_tbl_removed=1
        continue
      fi
      if [[ -n "${__override[${__nskey}]+x}" ]]; then
        _conf_fmt_kv "${__toml}" "${__rest}" "${__override[${__nskey}]}" __kv
        _wsc_emit "${__kv}"
        __emitted[${__nskey}]=1
        continue
      fi
    fi
    _wsc_emit "${__line}"
  done

  # Flush leftovers belonging to the final section / final block kind
  if [[ -n "${__current}" ]]; then
    # No header follows, so no separator is owed to one: the file keeps
    # the trailing blank lines it had.
    _wsc_end_table eof
  fi
  # A removed `[[...]]` block that ended the file goes with ONE blank
  # line next to it -- the one before it when there is one -- and the
  # file keeps every other blank line it ended with (base#1363).
  if (( __wsc_tail_removed )); then
    __wsc_blank=$(( __wsc_blank + __wsc_skip_blank ))
    (( __wsc_blank > 0 )) && __wsc_blank=$(( __wsc_blank - 1 ))
  fi
  _wsc_emit_blanks
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

  # An emptied array whose declaration found no scope during the walk:
  # its table is not declared in the file at all (a repo carrying
  # `[[devices.bindings]]` and no `[devices]` header). TOML allows a
  # super-table after its sub-tables, so the declaration gets its own
  # header here. A root-level path only reaches this when the file has no
  # header line at all, which makes the end of the file root scope too.
  local __fe_p __fe_t __fe_k
  if (( __toml )); then
    for __fe_p in "${!__aot_empty[@]}"; do
      [[ -z "${__aot_empty_done[${__fe_p}]:-}" ]] || continue
      _conf_toml_array_decl "${__fe_p}" __fe_t __fe_k
      _conf_toml_key "${__fe_k}" __fe_k
      if [[ -n "${__fe_t}" ]]; then
        _conf_fmt_header "${__toml}" "${__fe_t}" __hdr
        printf '\n%s\n%s = []\n' "${__hdr}" "${__fe_k}" >> "${_out}"
      else
        printf '\n%s = []\n' "${__fe_k}" >> "${_out}"
      fi
      __aot_empty_done["${__fe_p}"]=1
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
  local __l __lh
  for __l in "${__tpl_lines[@]}"; do
    __lh="${__l}"
    (( __toml )) && _conf_toml_header_uncomment "${__l}" __lh
    if [[ "${__lh}" =~ ^[[:space:]]*\[(.+)\][[:space:]]*$ ]]; then
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

  # THE COMMIT GATE, for a TOML destination: the same one
  # _upsert_conf_value uses, for the same reason. This writer is the TUI's
  # save path and walks the whole file, so it meets every shape the
  # per-key writer does.
  if (( __toml )) && ! _conf_commit_toml "${_dst}" "${_out}"; then
    return 1
  fi

  # And that the removals this writer can be held to actually happened:
  # a removal that did nothing leaves a file the parse gate is happy
  # with. See _conf_toml_removal_applied.
  local __wsc_why=""
  if (( __toml )) \
     && ! _conf_toml_removal_applied "${_out}" "${_removed_keys}" "${_tpl}" \
          __wsc_why _wsc_keys; then
    rm -f "${_out}"
    _log_err conf conf_write_not_applied \
      "display=[conf] WRITE DECLINED for ${_dst}: ${__wsc_why} was to be removed and the rewrite still carries it, so nothing was written and ${_dst} is unchanged. The writers edit a key written on its own line; this one is spelled somewhere they cannot reach -- an inline table is the usual case. Edit ${_dst} by hand instead." \
      "file=${_dst}" "target=${__wsc_why}"
    return 1
  fi

  # Atomically replace _dst only after the full rewrite succeeded. A
  # failed mv (e.g. _dst on a read-only mount) is surfaced rather than
  # leaving a stray temp file silently behind: remove the orphan temp,
  # log an actionable error, and bail with the original _dst untouched.
  if ! _conf_take_mode "${_dst}" "${_out}"; then
    rm -f "${_out}"
    _log_err conf conf_write_mode_failed "display=_write_setup_conf: could not give the rewrite the mode of ${_dst}; destination left unchanged" "file=${_dst}"
    return 1
  fi
  mv "${_out}" "${_dst}" || {
    rm -f "${_out}"
    _log_err conf conf_write_mv_failed "display=_write_setup_conf: could not replace ${_dst}; destination left unchanged" "file=${_dst}"
    return 1
  }
}

# ════════════════════════════════════════════════════════════════════
# Single-key upsert (used by setup.sh for WS_PATH writeback)
# ════════════════════════════════════════════════════════════════════

# _upsert_conf_value <file> <section> <key> <value> [<note>]
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
#
# <note>: a comment for the header of a TOML table this creates
# (`setup add` passes _CONF_ADD_TABLE_NOTE).
_upsert_conf_value() {
  local _file="${1:?}"
  local _section="${2:?}"
  local _key="${3:?}"
  local _value="${4-}"
  local _note="${5-}"

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

  # An index with no 1-based slot is refused BEFORE the temp file exists,
  # so nothing is created and the original is never touched.
  if _conf_toml_index_rejected "${_file}" "${_section}" "${_key}"; then
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
    _conf_upsert_scalar "${_file}" "${_tmp}" "${__toml}" "${_section}" "${_key}" "${_value}" "${_note}"
  fi

  # THE COMMIT GATE, for a TOML destination: promote the rewrite only once
  # the SHIPPED bridge has parsed it. See _conf_commit_toml.
  if (( __toml )) && ! _conf_commit_toml "${_file}" "${_tmp}" "${_section}" "${_key}"; then
    return 1
  fi

  # Atomically replace _file only after the rewrite succeeded. A failed
  # mv (e.g. _file on a read-only mount) removes the orphan temp, logs an
  # actionable error, and bails with the original _file untouched.
  if ! _conf_take_mode "${_file}" "${_tmp}"; then
    rm -f "${_tmp}"
    _log_err conf conf_upsert_mode_failed "display=_upsert_conf_value: could not give the rewrite the mode of ${_file}; original left unchanged" "file=${_file}"
    return 1
  fi
  mv "${_tmp}" "${_file}" || {
    rm -f "${_tmp}"
    _log_err conf conf_upsert_mv_failed "display=_upsert_conf_value: could not replace ${_file}; original left unchanged" "file=${_file}"
    return 1
  }
}

# _conf_toml_removal_applied <tmp> <removed_keys> <why_outvar>
#
# Zero when every `<section>.<key>` in the space-separated <removed_keys>
# that this writer can be held to is actually GONE from the rewrite in
# <tmp>; non-zero with <why_outvar> naming the first one still there.
#
# WHY THE PARSE GATE IS NOT ENOUGH. `_conf_commit_toml` asks whether the
# rewrite is readable, and a removal that did nothing leaves a file that
# reads perfectly -- with the value still in it. The writers are
# line-oriented, so a key TOML spells somewhere other than on its own
# line is one they cannot reach: `resources = { shm_size = "64m" }` is a
# valid inline table, the bridge finds `resources.shm_size` in it, and
# `setup.sh remove resources.shm_size` copied the line through, parsed
# clean and reported success with the limit still configured. Asking the
# reader what the file now SAYS is the only check that covers a shape
# nobody has thought of yet.
#
# A NUMBERED-FAMILY KEY IS ASKED A DIFFERENT QUESTION, not excused.
# Removing an entry of an `[[array of tables]]` COMPACTS the ones after
# it, so `<prefix>_N` is EXPECTED to still exist, holding what used to be
# `<prefix>_N+1` -- an absence check would fail on a correct removal, and
# whether compaction is right for slot 1 of `[volumes]` is base#1233's
# open question, which this gate must not answer by refusing. (The one
# save where compaction would hand slot 1 of `[volumes]` to another mount
# is declined before the rewrite exists, so it never reaches this gate;
# see `_wsc_refuse_ws_slot_move`.) What is unambiguous either way is that
# the family got SHORTER. So for those
# keys the check is on the array's LENGTH, which says nothing about which
# value lands where.
#
# That matters because the first spelling of this excused them
# unconditionally, and an inline ARRAY is a spelling the line-oriented
# writer cannot reach any more than an inline table: `args = [{ key =
# "FOO", value = "bar" }]` exposes `build.arg_1` to the reader, the
# rewrite left it untouched, and the removal reported success with
# `FOO=bar` still active.
#
# BOUNDED to a family the save does not also WRITE to. With overrides in
# the same family the resulting length is a function of which indices
# were written and whether any sat past the end, and an arithmetic this
# function cannot verify is worse than no check: it would refuse correct
# TUI saves. `setup.sh remove` passes removals and no overrides, which is
# the whole of the path this covers; a mixed save still has the parse
# gate and the scalar absence check.
_conf_toml_removal_applied() {
  local _tmp="${1:?}" _removed="${2-}" _src="${3-}"
  local -n _ctra_why="${4:?"${FUNCNAME[0]}: missing why outvar"}"
  local -n _ctra_ov="${5:?"${FUNCNAME[0]}: missing override-keys var"}"
  _ctra_why=""
  [[ -n "${_removed}" ]] || return 0

  local _kv="" _skv=""
  _kv="$(toml_bridge_parse "${_tmp}" --kv 2>/dev/null)" || return 0

  local _nskey _sect _key _p _n _ovk _ovs _ovk2 _touched
  for _nskey in ${_removed}; do
    _conf_split_nskey "${_nskey}" _sect _key || continue
    if _conf_toml_aot_slot "${_sect}" "${_key}" _p _n; then
      # Only when nothing else in this save writes the same family.
      _touched=0
      for _ovk in ${_ctra_ov[@]+"${_ctra_ov[@]}"}; do
        _conf_split_nskey "${_ovk}" _ovs _ovk2 || continue
        [[ "${_ovs}" == "${_sect}" ]] || continue
        _conf_toml_aot_slot "${_ovs}" "${_ovk2}" _p _n || continue
        _touched=1
        break
      done
      (( _touched )) && continue
      [[ -n "${_src}" && -f "${_src}" ]] || continue
      _skv="$(toml_bridge_parse "${_src}" --kv 2>/dev/null)" || continue
      local _before _after
      _before="$(_conf_kv_family_count "${_skv}" "${_sect}" "${_key%_*}_")"
      _after="$(_conf_kv_family_count "${_kv}" "${_sect}" "${_key%_*}_")"
      # NOTHING TO SHORTEN IS NOT A FAILURE TO SHORTEN. A removal names a
      # slot of the EFFECTIVE list, so the family may be inherited whole
      # and absent from THIS file in every spelling -- in which case the
      # rewrite's answer is the explicit `key = []` the writer emits, and
      # an empty array contributes no `--kv` row at all. The length check
      # would then read 0 against 0 and refuse a save that is exactly
      # right. It is also the one case where the check has nothing to
      # catch: the line-oriented writer can only have missed a spelling
      # the reader can see, and the reader sees no entry of this family
      # here.
      (( _before == 0 )) && continue
      if (( _after >= _before )); then
        _ctra_why="${_nskey}"
        return 1
      fi
      continue
    fi
    # In-shell, not `printf | grep -q`: a reader that stops reading
    # strands the writer with SIGPIPE and pipefail turns a SUCCESSFUL
    # match into the pipeline's 141, which an `if` reads as "not found"
    # -- the answer inverted rather than lost. The row is matched with
    # its delimiters either side so a key is never a prefix of another.
    if [[ $'\n'"${_kv}"$'\n' == *$'\n'"${_sect}"$'\t'"${_key}"$'\t'* ]]; then
      _ctra_why="${_nskey}"
      return 1
    fi
  done
  return 0
}

# _conf_kv_family_count <kv-text> <section> <prefix>
#
# How many `<section>\t<prefix><digits>\t...` rows <kv-text> holds. Read
# in-shell, one row at a time over a herestring, for the reason
# _conf_toml_removal_applied's comment gives: a pipeline into a reader
# that stops early reports the wrong answer rather than no answer.
_conf_kv_family_count() {
  local _kv="${1-}" _sect="${2-}" _prefix="${3-}"
  local _row _s _k _v _n=0
  while IFS= read -r _row; do
    [[ -n "${_row}" ]] || continue
    _conf_kv_split "${_row}" _s _k _v
    [[ "${_s}" == "${_sect}" ]] || continue
    [[ "${_k}" == "${_prefix}"* ]] || continue
    [[ "${_k#"${_prefix}"}" =~ ^[0-9]+$ ]] || continue
    _n=$(( _n + 1 ))
  done <<< "${_kv}"
  printf '%s' "${_n}"
}

# _conf_commit_toml <file> <tmp> [<section>] [<key>]
#
# Whether the just-written <tmp> may replace <file>: zero when the SHIPPED
# bridge parses it, non-zero -- having removed <tmp> and said what the
# parser objected to -- when it does not. <file> is never touched either
# way, so a refused write leaves the operator's configuration exactly as
# it was.
#
# WHY A PARSE AND NOT MORE PATTERNS. The writers are LINE-ORIENTED: they
# walk the file, match a header or a `key = value` line, and copy
# everything else through. Every shape TOML allows that does not fit that
# model is a way for a write to report success and leave a file nothing
# can read, and this branch has now fixed four of them one at a time -- a
# header with a trailing comment declared twice, an empty-array
# declaration beside new blocks, a literal-quoted key appended as a
# duplicate, and a value spanning physical lines whose first line alone
# was replaced:
#
#   watchdog_check = """        ->  watchdog_check = "pgrep -f other"
#   pgrep -f my_node                pgrep -f my_node
#   """                             """
#
# -- `Expected '=' after a key in a key/value pair`. Patching the fifth
# shape as it is reported leaves the sixth, and the writers cannot be
# made into a TOML parser in bash. So the question is asked of the reader
# that will have to read the file: the same gate, for the same reason,
# that `_ini_to_toml_commit` puts in front of the converter's output.
#
# AND IT IS ASKED IN `--kv`, the mode that reader actually reads in.
# `_toml_tokenize` loads every configuration through `toml_bridge_parse
# ... --kv`, and the shell view that mode produces refuses two shapes the
# plain parse accepts: a value the tab-separated transport cannot carry,
# and a numbered family carried BOTH as a table scalar and as an array
# block. Asking in the other mode let the second one through -- measured:
# `setup.sh set security.cap_drop_1 CHOWN` on a file spelling
# `cap_drop_1` both ways replaced the array block, left the scalar line,
# and reported SUCCESS, so the operator who set one capability to drop
# got two. The gate cannot be held to a file that was ALREADY unreadable
# before the write, and it is not: a refusal leaves the original exactly
# as it was and says what the reader objected to, which is the answer
# `remove`ing a value the rewrite did not remove already gives.
#
# An unavailable bridge reads as a REFUSAL, not as a pass. A write whose
# result nothing verified costs the operator a configuration they cannot
# load; a refusal costs them one re-run.
_conf_commit_toml() {
  local _file="${1:?"${FUNCNAME[0]}: missing file"}"
  local _tmp="${2:?"${FUNCNAME[0]}: missing tmp file"}"
  local _section="${3-}" _key="${4-}"

  local _why=""
  _why="$(toml_bridge_parse "${_tmp}" --kv 2>&1 >/dev/null)" && return 0

  rm -f -- "${_tmp}"
  _why="${_why//$'\n'/ }"
  local _what="${_section:+${_section}}"
  [[ -n "${_key}" ]] && _what="${_what:+${_what}.}${_key}"
  _log_err conf conf_write_declined \
    "display=[conf] WRITE DECLINED for ${_file}${_what:+ (${_what})}: the rewrite produced a file the configuration reader refuses, so nothing was written and ${_file} is unchanged. This happens when the file carries a shape the line-oriented writers cannot edit -- a value spanning several physical lines is the usual one -- or when the file already said one thing two ways, which no write can make it stop saying. Reader said: ${_why:-the TOML parser could not be run}. Edit ${_file} by hand instead." \
    "file=${_file}" \
    "target=${_what}" \
    "reason=${_why}"
  return 1
}

# _CONF_ADD_TABLE_NOTE
#
# The comment `setup add` writes on the header of a table it creates.
# `setup remove` drops a table again only when its header carries it, so
# an add/remove round trip gives back the file it started from without
# deleting an empty table the file already held (base#1363).
_CONF_ADD_TABLE_NOTE="# added by setup add; removed with its last entry"

# _CONF_ADD_DECL_NOTE
#
# The prefix `setup add` puts in front of an empty-array declaration
# (`ports = []`) it has to retire because it gives the list an entry.
# The declaration stays on its line as a comment, spelling and inline
# comment included, and the rewrite that leaves the list empty again
# writes it back from there, so an add/remove round trip gives back the
# file it started from (base#1363).
_CONF_ADD_DECL_NOTE="# setup remove restores this once the list is empty: "

# _conf_upsert_scalar <src> <dst> <toml> <section> <key> <value> [<note>]
#
# The scalar half of _upsert_conf_value: rewrite <src> into <dst> with
# `<section>.<key>` set. A `[[...]]` header ends the section's scope
# like a `[...]` one does, so an appended key lands inside its table.
# A TOML table this creates gets <note> as a comment on its header.
_conf_upsert_scalar() {
  local _src="${1:?}" _dst="${2:?}" _toml="${3:?}"
  local _section="${4:?}" _key="${5:?}" _value="${6-}" _note="${7-}"

  local __line __hline __current="" __raw __rest __kv __hdr
  local __matched=0 __in_sect=0 __sect_found=0
  _conf_fmt_kv "${_toml}" "${_key}" "${_value}" __kv
  while IFS= read -r __line || [[ -n "${__line}" ]]; do
    __hline="${__line}"
    (( _toml )) && _conf_toml_header_uncomment "${__line}" __hline
    if [[ "${__hline}" =~ ^[[:space:]]*\[(.+)\][[:space:]]*$ ]]; then
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
    (( _toml )) && [[ -n "${_note}" ]] && __hdr+=" ${_note}"
    printf '\n%s\n%s\n' "${__hdr}" "${__kv}" >> "${_dst}"
  fi
}

# _conf_toml_aot_pad <dst> <path> <total> <index>
#
# Append the FIELD-LESS `[[<path>]]` blocks that have to stand between
# the <total> blocks the file already holds and the <index>-th one about
# to be written: positions <total>+1 .. <index>-1, and nothing when
# <index> is the next position or below.
#
# Index N of the array IS the key `<prefix>_N`, so a write that names an
# index past the end has to LAND there. Appending one block instead gave
# it position <total>+1 under a different name: on the shipped template,
# whose `[volumes]` holds no block at all, `setup.sh set volumes.mount_2
# /data:/data` wrote one block that read back as `mount_1` -- the
# workspace bind -- and `_reconcile_workspace_path` honours an existing
# absolute source at `mount_1` as a deliberately pinned workspace, so
# WS_PATH silently became the operator's data directory. The INI writer
# had no such failure: it wrote the key `mount_2` and left `mount_1`
# absent.
#
# This is the rule the converter already states for the same reason (see
# ini_to_toml_migrate.sh's dense-emission header): a hole below the
# highest populated slot need not be a key at all, and a
# present-blocks-only rule hands the entry position 1. A field-less block
# -- a header with no body -- is the spelling for a slot that holds
# nothing, because every serialiser in the bridge's array spec answers ""
# for an absent field and the join is over the fields a block HAS.
# Rendering an empty VALUE instead produces the bogus `":"` / `"="` that
# `_conf_list_sorted` does not skip.
_conf_toml_aot_pad() {
  local _d="${1:?}" _p="${2:?}" _total="${3:?}" _idx="${4:?}"
  local _i
  for (( _i = _total + 1; _i < _idx; _i++ )); do
    printf '[[%s]]\n\n' "${_p}" >> "${_d}"
  done
}

# _conf_toml_upsert_aot <src> <dst> <path> <index> <value>
#
# The array-of-tables half of _upsert_conf_value: rewrite <src> into
# <dst> with the <index>-th `[[<path>]]` block carrying <value>. The
# block's key lines are replaced, its comments and blank lines kept.
# When the file has fewer blocks than <index>, the positions in between
# are padded field-less by `_conf_toml_aot_pad` so the value lands at the
# index named, and the new block goes after the last one of that kind --
# or at the end of the file when there is none.
_conf_toml_upsert_aot() {
  local _src="${1:?}" _dst="${2:?}" _path="${3:?}" _index="${4:?}" _value="${5-}"

  local __fields
  _conf_toml_aot_fields "${_path}" "${_value}" __fields

  local __line __hline __p __total=0 __seen=0 __in_block=0 __replacing=0 __matched=0
  local __cur_table="" __in_aot=0 __eap=""
  while IFS= read -r __line || [[ -n "${__line}" ]]; do
    _conf_toml_header_uncomment "${__line}" __hline
    if [[ "${__hline}" =~ ^[[:space:]]*\[\[(.+)\]\][[:space:]]*$ ]]; then
      _conf_header_name "${BASH_REMATCH[1]}" __p
      [[ "${__p}" == "${_path}" ]] && __total=$(( __total + 1 ))
    fi
  done < "${_src}"

  while IFS= read -r __line || [[ -n "${__line}" ]]; do
    _conf_toml_header_uncomment "${__line}" __hline
    if [[ "${__hline}" =~ ^[[:space:]]*\[\[(.+)\]\][[:space:]]*$ ]]; then
      _conf_header_name "${BASH_REMATCH[1]}" __p
      if (( __in_block && !__matched && __seen == __total )); then
        _conf_toml_aot_pad "${_dst}" "${_path}" "${__total}" "${_index}"
        printf '[[%s]]\n%s\n\n' "${_path}" "${__fields}" >> "${_dst}"
        __matched=1
      fi
      __in_block=0
      __replacing=0
      __in_aot=1
      __cur_table=""
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
    elif [[ "${__hline}" =~ ^[[:space:]]*\[(.+)\][[:space:]]*$ ]]; then
      if (( __in_block && !__matched && __seen == __total )); then
        _conf_toml_aot_pad "${_dst}" "${_path}" "${__total}" "${_index}"
        printf '[[%s]]\n%s\n\n' "${_path}" "${__fields}" >> "${_dst}"
        __matched=1
      fi
      __in_block=0
      __replacing=0
      __in_aot=0
      _conf_header_name "${BASH_REMATCH[1]}" __cur_table
    elif (( __replacing )) && _conf_is_kv_line "${__line}"; then
      continue
    elif (( ! __in_aot )) \
         && _conf_toml_empty_array_decl "${__line}" "${__cur_table}" __eap \
         && [[ "${__eap}" == "${_path}" ]]; then
      # This write gives the array an entry, so the declaration that said
      # it had none cannot stay: TOML refuses to extend a key already
      # bound to an array, and the whole file would stop parsing. It
      # stays, commented out behind _CONF_ADD_DECL_NOTE, where it stood,
      # so the remove that empties the list again puts back these exact
      # bytes in this place (base#1363).
      printf '%s%s\n' "${_CONF_ADD_DECL_NOTE}" "${__line}" >> "${_dst}"
      continue
    fi
    printf '%s\n' "${__line}" >> "${_dst}"
  done < "${_src}"

  if (( !__matched )); then
    printf '\n' >> "${_dst}"
    _conf_toml_aot_pad "${_dst}" "${_path}" "${__total}" "${_index}"
    printf '[[%s]]\n%s\n' "${_path}" "${__fields}" >> "${_dst}"
  fi
}

# ════════════════════════════════════════════════════════════════════
# conf.sh's one dependency on the schema registry, declared here rather
# than left to whoever sources this file.
#
# `_conf_split_nskey` asks SCHEMA_SUBSECTIONED which names have
# sub-sections (base#1185). Every production ENTRY POINT reaches both
# files through _lib.sh, but five libraries source conf.sh directly --
# setup_conf.sh, conf_logging.sh, config_summary.sh,
# setup_conf_migrate.sh and ini_to_toml_migrate.sh -- and
# config_summary.sh calls the splitter. Left implicit, a lone
# `source config_summary.sh` would refuse every split: correct, and
# useless.
#
# It sources at the END, after conf.sh's own functions exist. The chain
# schema.sh -> _tui_conf.sh -> conf.sh closes on the
# _DOCKER_LIB_CONF_SOURCED guard at the top of this file, and
# _tui_conf.sh does no source-time work beyond declarations, so the
# cycle resolves whichever file a caller names first.
# ════════════════════════════════════════════════════════════════════
# `disable=SC1091` rather than a `source=` directive, which is what
# _lib.sh and config_summary.sh use for every sibling they pull in this
# way. A resolving directive makes shellcheck analyse schema.sh as part
# of THIS file, and in the consumer's flat-layout pass (no -x, lib/*.sh
# copied side by side) that merged view reports SC2178 against
# `_schema_section_keys`'s nameref -- a finding about a function this
# change does not touch, raised only because of how it was reached.
# shellcheck disable=SC1091
source "${_conf_sh_dir}/schema.sh"
