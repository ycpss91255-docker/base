#!/usr/bin/env bash
#
# setup_conf.sh - setup.toml accessors over the effective configuration.
#
# ONE effective configuration, two shapes. Tables merge key by key at
# every depth and arrays are replaced atomically (ADR-00000037); every
# reader here resolves through the same merge, so no two of them can
# disagree about what is configured.
#
# The readers setup.sh and the other libs use to query the effective
# setup.toml: the per-section projection (_load_setup_conf), the parse-once
# handle model (_setup_conf_handle / _setup_effective_full) feeding the
# _conf_get / _conf_list_sorted accessors in lib/conf.sh, the convenience
# scalar/list getters (_get_conf_value / _get_conf_list_sorted), and the
# [image]-rule applicators (_rule_prefix / _rule_suffix / _rule_basename) used
# by detect_image_name.
#
# Extracted from setup.sh (ADR-00000014, epic decompose-setup-sh). The low-level
# _parse_ini_section + the handle accessors live in lib/conf.sh; this file is the
# setup.toml-path-resolving layer above them. Calls into _SETUP_SCRIPT_DIR +
# _parse_ini_section + the conf.sh accessors, all resolved at call-time via the
# _lib.sh load order.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_SETUP_CONF_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_SETUP_CONF_SOURCED=1

# The layer resolvers below are thin wrappers over conf.sh's INI
# primitives (_parse_ini_section / _ini_tokenize / _conf_load_layers), so
# pull conf.sh in directly (idempotent via its own double-source guard)
# rather than depending on _lib.sh's load order -- same shape as schema.sh
# pulling in _tui_conf.sh. Keeps this file sourceable on its own by the
# lighter callers (init.sh / upgrade.sh reach it through conf_logging.sh).
_setup_conf_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=dist/script/docker/lib/conf.sh
source "${_setup_conf_lib_dir}/conf.sh"
unset _setup_conf_lib_dir

# ════════════════════════════════════════════════════════════════════
# INI parser for setup.toml
#
# _parse_ini_section moved to lib/conf.sh in (PR-B) so init.sh
# can reach it via _lib.sh without sourcing setup.sh. The function
# stays callable from this file via the same name (_lib.sh sources
# conf.sh in the umbrella loader near setup.sh's top).
# ════════════════════════════════════════════════════════════════════

# ════════════════════════════════════════════════════════════════════
# The conf layer chain
#
# Three files, lowest precedence first:
#
#   <template>/setup.toml         the shipped default (inside .base)
#   <repo>/setup.toml             the repo's committed override -- ours,
#                                 shared, what CI and every other checkout
#                                 of this repo uses
#   <repo>/setup.local.toml       the operator's per-worktree override --
#                                 gitignored, never touched by tooling,
#                                 visible only on this machine
#
# The `local` infix means exactly what the repo's file-naming convention
# says it means: the standard name is ours, the `.local.` infix marks the
# operator's local variant. `setup.local.toml` is the local variant OF
# `setup.toml` and therefore shares its grammar -- same tables, same keys,
# same section-replace rule -- rather than being a second schema.
#
# It acts BEFORE compose.yaml is generated (one compose.yaml per worktree),
# which is what distinguishes it from the ADR-00000022 runtime `.env`
# overlay that isolates multi_run's Nth instance on ONE already-generated
# compose.yaml. Neither substitutes for the other.
# ════════════════════════════════════════════════════════════════════

# _setup_conf_layers <base_path> <outarray> [template_dist_dir]
#
# Fill <outarray> with the chain's paths in INCREASING precedence. Paths
# are returned whether or not they exist -- an absent layer contributes
# nothing, and every reader passes the whole chain unconditionally so the
# precedence lives in exactly one place.
#
# The template layer sits at <template_dist>/setup.toml. Its directory is
# taken from the optional third argument, else from _SETUP_SCRIPT_DIR (the
# shipped wrapper dir, three levels below dist/), and the layer is OMITTED
# when neither is available. Omitted rather than left to resolve: an empty
# prefix would leave nothing to drop three levels from, and the path would
# come out as a bare `setup.toml` relative to whatever the caller's cwd
# happens to be.
#
# The third argument exists for the callers that reach the readers WITHOUT
# setup.sh and therefore without _SETUP_SCRIPT_DIR (init.sh / upgrade.sh,
# and lib/dockerfile_migrate.sh which they source). For them the omission
# is not free: a guard that decides whether a build reads <repo>/config/
# would scan two of the three layers and answer for a chain it never saw.
# Such a caller passes the dist/ dir it already knows and gets the full
# chain; what the chain CONTAINS and in which ORDER stays here either way,
# which is the property that keeps a second, drifting copy from appearing
# at each call site.
_setup_conf_layers() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local -n _scl_out="${2:?"${FUNCNAME[0]}: missing outvar"}"
  local _scl_dist="${3:-}"
  _scl_out=()
  if [[ -z "${_scl_dist}" && -n "${_SETUP_SCRIPT_DIR:-}" ]]; then
    # Three levels up, taken by dropping the three trailing components
    # rather than appending `/../../..`. The same directory, spelled once:
    # these paths are what every "a local layer is in effect" message names
    # and what the bridge is handed as its mount sources, and a caller
    # comparing one layer path against another is comparing strings.
    # Resolving through the filesystem instead would follow base's own
    # origin symlinks and name dist/ a second time.
    _scl_dist="${_SETUP_SCRIPT_DIR%/*/*/*}"
  fi
  # The TOP layer is asked for rather than spelled: it is the one layer a
  # CALLER can address (see _setup_conf_local_path), and a second spelling
  # of that path here is how an override would reach the merge but not the
  # drift hash, or the hash but not the refusal deploy is built on.
  local _scl_local
  _scl_local="$(_setup_conf_local_path "${_base}")"
  # An addressed layer that cannot be read is REFUSED here, before the
  # chain exists, rather than resolved past. An absent layer contributes
  # nothing by design -- that is what makes the per-worktree default
  # optional -- so an override naming nothing would quietly produce the
  # template defaults and the call would report success. That is exactly
  # the "second, unchecked resolution path that silently wins over the
  # real one" this header used to rule out by having no address at all.
  if [[ -n "${_SETUP_CONF_LOCAL:-}" ]]; then
    _setup_conf_local_check "${_scl_local}" || return 1
  fi
  [[ -n "${_scl_dist}" ]] && _scl_out+=("${_scl_dist}/setup.toml")
  _scl_out+=(
    "${_base}/setup.toml"
    "${_scl_local}"
  )
}

# _setup_conf_local_path <base_path>
#
# Echo the chain's TOP layer: the per-worktree override at
# <base>/setup.local.toml, or the file a CALLER named for this invocation.
# One spelling of that path for every reader, every writer and every
# caller that has to name it in a message.
#
# The address is ADR-00000036's: base's two generate stages are APIs an
# orchestrator calls N times against ONE repo, and this layer is already
# the one that overrides ANY section rather than a whitelist
# (ADR-00000025 sec.1). What it lacked was somewhere to put the Nth call's
# parameters, so two parameter sets meant two checkouts racing one file.
#
# `_SETUP_CONF_LOCAL` carries it. It is an internal, process-scoped
# variable in the same class as `_SETUP_SCRIPT_DIR` -- set by an entry
# point that PARSED `--local-conf`, not a user-facing environment knob --
# and it is not the unchecked lever the chain header above rules out:
# `_setup_conf_layers` refuses an address it cannot honour, so no value of
# this variable can resolve to "no layer at all" and hand back the
# template defaults while reporting success.
_setup_conf_local_path() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  if [[ -n "${_SETUP_CONF_LOCAL:-}" ]]; then
    printf '%s' "${_SETUP_CONF_LOCAL}"
    return 0
  fi
  printf '%s/setup.local.toml' "${_base}"
}

# _setup_conf_local_check <path>
#
# Refuse a caller-supplied local layer the call cannot honour. Zero when
# <path> is a readable regular file.
#
# Three ways it cannot be honoured, and none of them is loud on its own:
# an empty address resolves to the repo's own file, a path that is not
# there resolves to an absent layer (which the chain treats as
# contributing nothing), and a directory or an unreadable file resolves to
# a parse of nothing. All three end in a generated set built from the
# template defaults while the caller is told its parameters were applied.
# A parameterised API handed something it cannot honour refuses.
_setup_conf_local_check() {
  local _p="${1-}"
  if [[ -z "${_p}" ]]; then
    _log_err conf conf_local_override_unusable \
      "display=the local conf layer was addressed with an empty path; refusing to resolve the chain without the layer the caller named" \
      "path="
    return 1
  fi
  if [[ ! -e "${_p}" ]]; then
    _log_err conf conf_local_override_unusable \
      "display=the local conf layer was addressed as ${_p}, which does not exist; refusing to resolve the chain without it rather than emitting the template defaults as if the parameters had been applied" \
      "path=${_p}"
    return 1
  fi
  if [[ ! -f "${_p}" ]]; then
    _log_err conf conf_local_override_unusable \
      "display=the local conf layer was addressed as ${_p}, which is not a regular file; refusing to resolve the chain without it" \
      "path=${_p}"
    return 1
  fi
  if [[ ! -r "${_p}" ]]; then
    _log_err conf conf_local_override_unusable \
      "display=the local conf layer was addressed as ${_p}, which is not readable; refusing to resolve the chain without it" \
      "path=${_p}"
    return 1
  fi
  return 0
}

# _setup_conf_chain_snapshot <layers_array> <assoc_outvar>
# _setup_conf_chain_changed  <layers_array> <assoc_snapshot>
#
# Photograph a conf chain and ask whether it moved.
#
# Taken over the WHOLE chain rather than over one file because the
# property watched here -- "this call did not change the repo's
# configuration" -- is a property of the chain, and the chain is where new
# layers appear. The alternative is to enumerate the places an apply can
# write to the conf, which passes forever the day a third one is added.
#
# ABSENCE IS RECORDED, NOT SKIPPED. A file the call CREATES is a change,
# and skipping the absent entries would read it as no change at all.
#
# There is deliberately no `restore`. A rollback attributes every write in
# the window to the call that took the photograph, and the window contains
# other processes -- a concurrent `setup set`, a plain apply, an operator's
# edit -- whose work it would silently discard. The caller's answer to a
# changed chain is to refuse, not to revert.
#
# Content is held in memory, not in a scratch copy: these files are small,
# and a temp directory would have to be cleaned up on every one of the
# intermediate return paths between the two photographs. The `X` sentinel
# survives the trailing newline that command substitution strips, so two
# photographs of one byte-identical file compare equal.
_setup_conf_chain_snapshot() {
  local _sccs_name="${1:?"${FUNCNAME[0]}: missing layers array"}"
  local -n _sccs_layers="${_sccs_name}"
  local -n _sccs_out="${2:?"${FUNCNAME[0]}: missing outvar"}"
  _sccs_out=()
  local _sccs_f
  for _sccs_f in "${_sccs_layers[@]+"${_sccs_layers[@]}"}"; do
    if [[ -f "${_sccs_f}" ]]; then
      _sccs_out["${_sccs_f}"]="present:$(cat -- "${_sccs_f}"; printf 'X')"
    else
      _sccs_out["${_sccs_f}"]="absent:"
    fi
  done
}

_setup_conf_chain_changed() {
  local _sccc_name="${1:?"${FUNCNAME[0]}: missing layers array"}"
  local -n _sccc_layers="${_sccc_name}"
  local -n _sccc_pre="${2:?"${FUNCNAME[0]}: missing snapshot"}"
  local -A _sccc_now=()
  _setup_conf_chain_snapshot "${_sccc_name}" _sccc_now
  local _sccc_f
  for _sccc_f in "${_sccc_layers[@]+"${_sccc_layers[@]}"}"; do
    [[ "${_sccc_now[${_sccc_f}]-}" == "${_sccc_pre[${_sccc_f}]-}" ]] || return 0
  done
  return 1
}

# _setup_conf_local_sections <base_path> <outarray>
#
# Fill <outarray> with the sections <base>/setup.local.toml actually
# DEFINES (>=1 entry), in file order; empty when the file is absent or
# defines nothing. These are the sections in which the local layer has a
# say -- on the keys it names, and on any array it declares, whole -- so
# this is the list every "your write is shadowed" / "a local layer is in
# effect" message names. A section is never silently shadowed: the section
# list, not a boolean, is what makes the message actionable. It is a
# section list rather than a key list because the array case is not
# key-level: a local `[[volumes]]` replaces the whole list, so naming the
# section is the honest granularity for both kinds of entry.
#
# AN ARRAY DECLARED WITH NO ENTRIES IS ONE OF THOSE DECLARATIONS, and the
# ENTRIES alone cannot see it. `args = []` replaces the lower layer's list
# with nothing (ADR-00000037's zero-entry amendment), so a
# `setup.local.toml` carrying only that changes the effective
# configuration -- measured through the real merge: the template's three
# build args become zero -- while the bridge emits no `--kv` row for it,
# because there is no entry to emit. Read off the entries alone this
# function answered "no local sections" for exactly that file, and the one
# caller whose answer is a REFUSAL let it through: `_setup_deploy` bars a
# field bundle from depending on the gitignored local layer, and a bundle
# built from that clear came from untracked configuration with nothing in
# its README recording which section. `_setup_warn_shadowed_write` and the
# config summary read the same answer and had the same blind spot.
#
# So the declarations are read off the FILE, beside the entries. The
# section of an array path is its FIRST component -- `build.args` is
# `[build]`'s, `devices.cgroup_rules` is `[devices]`'s, and a root-level
# `volumes` is its own -- which holds for every family
# `_conf_toml_aot_section` maps, none of them deeper than two.
_setup_conf_local_sections() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local -n _scls_out="${2:?"${FUNCNAME[0]}: missing outvar"}"
  _scls_out=()

  local _local
  _local="$(_setup_conf_local_path "${_base}")"
  [[ -f "${_local}" ]] || return 0

  # _conf_load auto-dispatches: .toml -> _toml_tokenize, INI -> _ini_tokenize.
  _conf_load "${_local}" _SCLS_LOCAL
  local -n _scls_s=_SCLS_LOCAL__sects
  local -n _scls_es=_SCLS_LOCAL__es

  # The sections an empty-array declaration defines, gathered first so the
  # loop below can answer for a section that has nothing else.
  #
  # ASKED OF THE PARSE, not of the file's lines. The first spelling of
  # this read the lines through `_conf_toml_empty_array_decl`, which is
  # the WRITERS' matcher and correct there because they rewrite lines.
  # For a reader it is one spelling of several: TOML takes `args = []`,
  # `args = [` with the `]` on the next line, and the inline
  # `build = { args = [] }`, and a line matcher saw only the first. A
  # local layer whose only content was one of the others reported NO
  # sections, so `_setup_deploy` -- whose answer is a refusal -- let a
  # field bundle be built from gitignored configuration again, which is
  # the defect this whole block exists to close.
  local -A _scls_decl=()
  if [[ "${_local}" == *.toml ]]; then
    local _scls_row _scls_sect
    while IFS=$'\t' read -r _scls_sect _ ; do
      [[ -n "${_scls_sect}" ]] || continue
      _scls_decl["${_scls_sect}"]=1
    done < <(toml_bridge_parse "${_local}" --empty-arrays || true)
  fi

  local _sec _i _has
  for _sec in "${_scls_s[@]+"${_scls_s[@]}"}"; do
    _has=0
    for (( _i = 0; _i < ${#_scls_es[@]}; _i++ )); do
      [[ "${_scls_es[_i]}" == "${_sec}" ]] && { _has=1; break; }
    done
    (( _has == 0 )) && [[ -n "${_scls_decl[${_sec}]+x}" ]] && _has=1
    (( _has )) && _scls_out+=("${_sec}")
    unset "_scls_decl[${_sec}]"
  done

  # A declaration whose section the tokenizer listed nowhere still names a
  # section the local layer defines: a root-level `volumes = []` has no
  # `[volumes]` header to be listed under.
  for _sec in "${!_scls_decl[@]}"; do
    _scls_out+=("${_sec}")
  done
  return 0
}

# _load_setup_conf <base_path> <section> <keys_outvar> <values_outvar>
#
# One section of THE effective configuration, in the flat key/value array
# shape its callers read. A projection of _setup_conf_handle, not a second
# resolver: the merge, the precedence and the per-layer rules live in the
# handle, and this function only selects a section out of the result.
#
# It used to do its own walk -- highest layer that defines the section
# supplies ALL of it, the layers below contributing nothing. That was the
# blanket section-replace ADR-00000037 amended, and keeping it here meant
# the tree had two answers for "what is configured": `show` reported the
# handle's key-level merge while `_collect_logging` and the per-stage
# resolver read the section-replace one, so a repo could be told one
# configuration and built with another. ONE effective configuration,
# queried two ways, is what makes the two agree by construction rather
# than by a convention nothing checks.
#
# The chain's surface is the set of paths _setup_conf_layers names, and
# its TOP layer is addressable (ADR-00000036): a call may name the file it
# wants read there, which is what lets an orchestrator drive one repo N
# times. That is not the relocation lever this header used to rule out --
# the objection to one was that it is a second, UNCHECKED resolution path
# that silently wins over the real one, and the address is checked: an
# override that cannot be read refuses the whole resolution rather than
# leaving the layer out. The lower two layers are not addressable.
#
# Non-zero when the merge itself failed, which the handle reports rather
# than returning an empty configuration as a loaded one.
_load_setup_conf() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local _section="${2:?"${FUNCNAME[0]}: missing section"}"
  local -n _lsc_keys="${3:?"${FUNCNAME[0]}: missing keys outvar"}"
  local -n _lsc_values="${4:?"${FUNCNAME[0]}: missing values outvar"}"

  _lsc_keys=()
  _lsc_values=()

  _setup_conf_handle "${_base}" _LSC_CONF || return 1

  local -n _lsc_es=_LSC_CONF__es
  local -n _lsc_k=_LSC_CONF__keys
  local -n _lsc_v=_LSC_CONF__vals

  # Exact section match, duplicates and order preserved -- the same
  # projection _parse_conf_section performs on one file.
  local _i
  for (( _i = 0; _i < ${#_lsc_k[@]}; _i++ )); do
    [[ "${_lsc_es[_i]}" == "${_section}" ]] || continue
    _lsc_keys+=("${_lsc_k[_i]}")
    _lsc_values+=("${_lsc_v[_i]}")
  done
  return 0
}

# _setup_conf_handle <base> <handle>
#
# Load the effective setup.toml into an opaque conf.sh <handle>: the whole
# layer chain merged (tables key-level and recursive, arrays atomic), as
# one queryable handle for the _conf_get / _conf_list_sorted accessors.
# This is where the chain's precedence lives; _load_setup_conf is a
# projection of it and _setup_effective_full is a reshaping of it.
#
# The optional third argument is _setup_conf_layers' own: the dist/ dir
# that holds the template layer, for a caller that reaches the readers
# without _SETUP_SCRIPT_DIR. setup_tui.sh is one -- it is a sibling of
# setup.sh in the same wrapper dir and resolves that directory itself --
# and threading the argument here rather than letting the editor assemble
# a layer list of its own is what keeps ONE builder of this handle: the
# chain, its order and the merge answer for every caller from here.
_setup_conf_handle() {
  local _base="${1:?"${FUNCNAME[0]}: missing base"}"
  local _h="${2:?"${FUNCNAME[0]}: missing handle"}"
  local _sch_dist="${3:-}"
  local -a _sch_layers=()
  # Propagated: a chain that refused to resolve must not be reported as a
  # loaded configuration, which is the same reason the bridge's parse
  # failure is propagated rather than read as an empty conf.
  _setup_conf_layers "${_base}" _sch_layers "${_sch_dist}" || return 1
  _conf_load_layers "${_h}" "${_sch_layers[@]}"
}

# _setup_effective_full <base_path> <sections_outvar> <keys_outvar> <values_outvar>
#                       [template_dist_dir]
#
# The merge-resolved view of the whole chain in the `*_full`
# array shape (sections list + parallel `<section>.<key>` / value arrays).
# What `show` / `list` and the store-time diagnostics read, so they report
# the values the emitters will actually use -- including the ones the local
# layer supplies.
#
# <template_dist_dir> is passed straight to _setup_conf_handle; see its
# header for the caller that needs it.
_setup_effective_full() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local -n _sef_sections="${2:?"${FUNCNAME[0]}: missing sections outvar"}"
  local -n _sef_keys="${3:?"${FUNCNAME[0]}: missing keys outvar"}"
  local -n _sef_values="${4:?"${FUNCNAME[0]}: missing values outvar"}"
  local _sef_dist="${5:-}"

  _setup_conf_handle "${_base}" _SEF_CONF "${_sef_dist}" || return 1

  _sef_sections=()
  _sef_keys=()
  _sef_values=()

  local -n _sef_s=_SEF_CONF__sects
  local -n _sef_es=_SEF_CONF__es
  local -n _sef_k=_SEF_CONF__keys
  local -n _sef_v=_SEF_CONF__vals

  local _i
  for (( _i = 0; _i < ${#_sef_s[@]}; _i++ )); do
    _sef_sections+=("${_sef_s[_i]}")
  done
  for (( _i = 0; _i < ${#_sef_k[@]}; _i++ )); do
    _sef_keys+=("${_sef_es[_i]}.${_sef_k[_i]}")
    _sef_values+=("${_sef_v[_i]}")
  done
  return 0
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
