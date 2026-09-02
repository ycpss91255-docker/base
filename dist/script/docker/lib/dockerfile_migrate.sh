#!/usr/bin/env bash
#
# dockerfile_migrate.sh - declarative Dockerfile-migration list.
#
# A deep module behind a small interface: `apply_migrations <dockerfile>`
# iterates an ordered, data-driven list of {detect, transform} migrations
# and applies each migration whose `detect` matches. It replaces the
# accreting pile of one-off seds that upgrade.sh Step 5 used to carry to
# heal downstream Dockerfiles after a base contract change.
#
# Each migration `X` is two functions:
#   _migrate_X_detect <file>   exit 0 -> migration applies to this file
#   _migrate_X_apply  <file>   perform the (idempotent) rewrite
# and one entry in the ordered `_MIGRATIONS` array. apply_migrations runs
# them in array order; this lets later migrations build on the shape an
# earlier one normalised (e.g. the lib-COPY split before the wrapper-COPY
# rename).
#
# Apply policy (inherited from upgrade.sh's Step-5 convention):
#   - `detect` matches a known shape -> `apply` runs and is IDEMPOTENT
#     (a second run is a no-op).
#   - structure does not match / anchor missing / ambiguous -> `detect`
#     returns non-zero so the migration is SKIPPED; where a partial /
#     custom shape is recognised the `apply` _log_warn's and leaves the
#     file untouched rather than force-rewriting.
#
# Compatible with ADR-00000006: the `.base` path contract is frozen; this
# restructures the heal MECHANISM, not the frozen paths.
#
# Style: Google Shell Style Guide.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_DOCKERFILE_MIGRATE_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_DOCKERFILE_MIGRATE_SOURCED=1

# Self-source the conf-chain resolver. The pip-helper migration has to
# know whether anything redirects the CONFIG_SRC build arg, and the set of
# files that can say so is lib/setup_conf.sh's _setup_conf_layers -- the
# one place the chain's membership and precedence are defined. Pulled in
# directly (idempotent via its own double-source guard) so the load order
# of _lib.sh is not load-bearing: init.sh and upgrade.sh source this file
# on its own, without setup.sh.
#
# _DFM_TEMPLATE_DIST_DIR is the other half of that. _setup_conf_layers
# places the template layer from _SETUP_SCRIPT_DIR, which ONLY setup.sh
# sets; init.sh / upgrade.sh have no such global, and a chain that
# silently loses its lowest layer would let a template-level redirect go
# unseen. This file ships at <template>/dist/script/docker/lib/, so its
# own directory locates dist/ in both callers -- the subtree root
# upgrade.sh sources from and the template dir init.sh sources from --
# without either having to pass anything.
_dfm_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=dist/script/docker/lib/setup_conf.sh
source "${_dfm_lib_dir}/setup_conf.sh"
readonly _DFM_TEMPLATE_DIST_DIR="${_dfm_lib_dir}/../../.."
unset _dfm_lib_dir

# ── Internal helpers ────────────────────────────────────────────────────────

# _dfm_entrypoint_path <dockerfile>
#   Resolve the conventional sibling entrypoint (script/entrypoint.sh) next
#   to a repo-root Dockerfile. Echoes the path (whether or not it exists).
_dfm_entrypoint_path() {
  local _file="$1"
  printf '%s/script/entrypoint.sh' "$(dirname -- "${_file}")"
}

# _dfm_join_copy_statements <file>
#   Emit the file with backslash-continued lines folded into single logical
#   lines, so a detect grep can reason about a whole COPY statement (multi-
#   distro repos hand-list moved files across continuation lines).
_dfm_join_copy_statements() {
  local _file="$1"
  awk '
    { line = line $0 }
    /\\[[:space:]]*$/ { sub(/\\[[:space:]]*$/, " ", line); next }
    { print line; line = "" }
    END { if (line != "") print line }
  ' "${_file}"
}

# ── Dispatcher ──────────────────────────────────────────────────────────────

# apply_migrations <dockerfile_path>
#   Iterate _MIGRATIONS in order; for each whose _migrate_<name>_detect
#   matches the file, run _migrate_<name>_apply. Migrations that do not
#   detect are silently skipped (not applicable to this repo's shape).
#   Returns 0 unless the path is unusable.
apply_migrations() {
  local _file="${1:?apply_migrations requires a Dockerfile path}"

  if [[ ! -f "${_file}" ]]; then
    _log_info upgrade upgrade_started "display=  no Dockerfile at ${_file} — skip migrations"
    return 0
  fi

  local _name
  for _name in "${_MIGRATIONS[@]}"; do
    if "_migrate_${_name}_detect" "${_file}"; then
      "_migrate_${_name}_apply" "${_file}"
    fi
  done
}

# ── Migration 0: shipped-tree dir rename .base/downstream/ -> .base/dist/ ────
#
# base's shipped tree was renamed downstream/ -> dist/ (terminology
# de-overload: "downstream" now means only the repo). A consumer Dockerfile
# that hand-references the subtree interior -- the lint-stage
#   COPY .base/downstream/script/docker/lib    /lint/lib
#   COPY .base/downstream/script/docker/wrapper /lint/wrapper
# (the Region C path the earlier base/downstream split wrote in) -- breaks
# with "COPY source not found" once the directory is gone. Rewrite every
# .base/downstream/ COPY source to .base/dist/. Runs first so any later
# migration sees the canonical dist/ path. Idempotent: once rewritten no
# .base/downstream/ remains, so detect returns non-zero on a second run.
_migrate_downstream_to_dist_detect() {
  local _file="$1"
  grep -q '\.base/downstream/' "${_file}"
}

_migrate_downstream_to_dist_apply() {
  local _file="$1"
  sed -i 's#\.base/downstream/#.base/dist/#g' "${_file}"
  _log_info upgrade upgrade_started "display=  Dockerfile patched: .base/downstream/ -> .base/dist/ (#714)"
}

# ── Migration 1: wrapper COPY shape A/B -> wrapper/*.sh ─────────────────────
#
# v0.41.0 moved the user-facing wrappers (build/run/exec/stop/prune.sh) out
# of the flat .base/script/docker/ root into .base/script/docker/wrapper/.
# Two pre-v0.41.0 lint-stage COPY shapes then resolve to zero files:
#   A  COPY *.sh /lint/                       (root-anchored, the shape)
#   B  COPY .base/script/docker/*.sh /lint/   (flat top-level glob)
# Both heal to the current wrapper-glob shape:
#   COPY .base/script/docker/wrapper/*.sh /lint/
# Idempotent: a Dockerfile already on the wrapper/ shape is not detected.
_migrate_wrapper_copy_detect() {
  local _file="$1"
  grep -qE '^[[:space:]]*COPY[[:space:]]+\*\.sh[[:space:]]+/lint/' "${_file}" \
    || grep -qE '^[[:space:]]*COPY[[:space:]]+\.base/script/docker/\*\.sh[[:space:]]+/lint/' "${_file}"
}

_migrate_wrapper_copy_apply() {
  local _file="$1"
  # Shape A: root-anchored glob.
  sed -i -E 's|^([[:space:]]*)COPY[[:space:]]+\*\.sh[[:space:]]+/lint/|\1COPY .base/script/docker/wrapper/*.sh /lint/|' "${_file}"
  # Shape B: flat top-level .base glob.
  sed -i -E 's|^([[:space:]]*)COPY[[:space:]]+\.base/script/docker/\*\.sh[[:space:]]+/lint/|\1COPY .base/script/docker/wrapper/*.sh /lint/|' "${_file}"
  _log_info upgrade upgrade_started "display=  Dockerfile patched: wrapper COPY -> .base/script/docker/wrapper/*.sh (#567 m1)"
}

# ── Migration 2: retired .base/dockerfile/setup pip helper ──────────────────
#
# v0.41.0 retired the .base/dockerfile/setup pip flow. The downstream RUN
#   RUN PIP_BREAK_SYSTEM_PACKAGES=1 pip install --no-cache-dir \
#       -r "${CONFIG_DIR}"/pip/requirements.txt
# (optionally preceded by a "# Setup pip packages" comment) installs base's
# empty placeholder in most repos, so it is a no-op once the helper is gone
# — and a hard failure if CONFIG_DIR/pip/requirements.txt is absent, since
# the shipped dist/config/ no longer carries one. Drop both lines.
#
# WHAT THE LINE ALONE CANNOT SAY, and why this migration reads more than
# the Dockerfile. dist/dockerfile/Dockerfile layers the config directory
# twice: `.base/dist/config` (base's own, no pip/ any more) and then the
# repo's `${CONFIG_SRC}` -- ARG CONFIG_SRC="config", i.e. <repo>/config --
# onto the same ${CONFIG_DIR}. So the in-image
# ${CONFIG_DIR}/pip/requirements.txt IS the repo's own file, and the RUN
# line is byte-identical whether that file is the placeholder or a real
# dependency list. Deleting it in the second case removes a WORKING install:
# the build still succeeds and the packages are silently gone. This
# migration reaches every consumer repo mechanically through
# `just upgrade`, so a delete it cannot justify is a delete it must not do.
#
# The precondition is checkable, so it is checked: the requirements file
# sits next to the Dockerfile the migration was handed. The line is dropped
# only where the install is PROVABLY inert -- the file is absent (the
# build-breaking case the migration exists for) or carries nothing but
# blanks and comments. Anything with a real requirement in it is kept and
# reported, per the apply policy at the top of this file: a shape the
# migration does not recognise is warned about, never force-rewritten.
#
# WHICH directory that file sits in is itself a question, and answering it
# "config/, always" would narrow the silent package loss rather than close
# it. CONFIG_SRC is a build ARG: a repo can redeclare it in its own
# Dockerfile, or set it as a compose build arg via a
# `[build] arg_N = CONFIG_SRC=...` entry in .setup.conf. Either way
# ${CONFIG_DIR} is overlaid from <repo>/<something-else>, config/ holds
# nothing the RUN line reads, and reading it anyway would report "not
# populated" over a real dependency list. So the source directory has to
# RESOLVE to the default before its contents count as proof; where the
# migration cannot locate it -- redirected, or simply not there -- the
# install is unprovable and the line is kept, same as any other shape this
# migration does not recognise.
#
# The delete is also line-based, so it is only safe on a pip line that is a
# complete physical instruction. Inside a backslash-continued RUN, removing
# one physical line either dangles the previous line's continuation (which
# swallows the next instruction) or orphans the tail as a bare
# non-instruction line (a Dockerfile parse error). Those shapes are kept and
# reported too; restructuring someone's compound RUN is not a mechanical
# edit.

# The one spelling of the retired helper line, shared by the detector, the
# continuation check and the delete. `\%...%` addresses the sed so the
# pattern's own slashes need no escaping.
readonly _DFM_PIP_HELPER_RE='pip install .*-r[[:space:]]+.*\$\{?CONFIG_DIR\}?.*/pip/requirements\.txt'

# A physical line that continues onto the next one. Held in a variable
# because an inline `=~` right-hand side loses one level of backslash to
# quote removal, which would silently turn this into "a literal [".
readonly _DFM_LINE_CONTINUES_RE='\\[[:space:]]*$'

# The default of the Dockerfile's `ARG CONFIG_SRC` -- the repo directory the
# layer-2 `COPY "${CONFIG_SRC}" "${CONFIG_DIR}"` overlays onto ${CONFIG_DIR}.
readonly _DFM_CONFIG_SRC_DEFAULT='config'

# The conf keys that redirect the overlay, as one pattern. A build arg is
# `arg_N = CONFIG_SRC=<dir>` under [build]; the section is not matched
# because a key of this shape means nothing outside it.
readonly _DFM_CONF_REDIRECT_RE='^[[:space:]]*arg_[0-9]+[[:space:]]*=[[:space:]]*CONFIG_SRC='
readonly _DFM_ARG_REDIRECT_RE='^[[:space:]]*ARG[[:space:]]+CONFIG_SRC='

# The floor the conf chain must clear. _setup_conf_layers documents three
# layers -- template, per-repo, per-worktree -- and this guard authorises a
# DELETE, so a chain that came back shorter means a layer dropped out of
# the resolution and the scan did not see the population it is answering
# for. That is a refusal, not a pass.
readonly _DFM_CONF_LAYER_FLOOR=3

# READING A STATUS IN THIS FILE. Every decision below comes from some
# command's exit status, and each one of them has THREE answers, not two:
#
#   YES              the thing is there / the property holds
#   NO               it is provably not there -- the check OBSERVED its
#                    absence, having read everything it had to read
#   I-COULD-NOT-TELL the check returned "not found" without observing
#                    anything: grep exited 2, a directory could not be
#                    traversed, a path did not resolve
#
# The third answer must never authorise an action. Migration 2 is the only
# one here that DELETES a line on the strength of what it read outside the
# Dockerfile, so it is the one where the distinction is load-bearing: its
# guards return 0/1/2 and only 1 -- the observed NO -- reaches the delete.
# Every other migration decides only whether to ADD or rewrite a known
# shape, so an unanswered question in its DETECT means "detect did not
# fire" and the file is left alone, which is already the safe direction:
# _dfm_needs_dl4006 / _dfm_needs_dl3006 and every `_detect` fold 2 into
# "no", and _dfm_pip_line_is_standalone returns non-zero (= keep the line)
# when it cannot read the file at all.
#
# ONE migration asks an unanswered question in its APPLY instead, where
# that argument does not reach it, and it is NOT fixed: _migrate_smoke_copy
# globs <repo>/.base/dist/test/bats/smoke/*/ to decide which per-stage
# folders the freshly pulled subtree ships, and its `[[ -d ]] || continue`
# reads a path it could not traverse as "this stage ships no folder". The
# Dockerfile is then rewritten with the shared baseline COPY alone and the
# `-test` stage silently loses the smoke specs it used to run -- the same
# "a path nobody read is not an empty one" this block is about, one
# migration further down. Stated rather than implied, and pinned by
# dockerfile_migrate_spec ("an unresolvable per-stage path costs the stage
# its own COPY") so the deviation is a measured fact; a follow-up issue
# carries the fix, which is why this block does not claim it is closed.

# _dfm_dir_is_readable <path>
#   Exit 0 when <path> is a directory this process can stat AND list, 1
#   otherwise -- it is not a directory, the path did not resolve (a
#   dangling or looping symlink, a non-directory component), or its mode
#   forbids reading or searching it.
#
#   This is the question the word "absent" depends on. `[[ -f <dir>/x ]]`
#   is false both when x is not in <dir> and when <dir> was never read,
#   and only the first is proof; a caller that folds the second into it
#   turns an unreadable directory into permission to delete. Callers ask
#   this BEFORE they are allowed to call a missing file absent.
_dfm_dir_is_readable() {
  local _dir="$1"
  [[ -d "${_dir}" && -r "${_dir}" && -x "${_dir}" ]]
}

# _dfm_conf_declares_redirect <conf_file>
#   Exit 0 when this layer redirects CONFIG_SRC, 1 when it provably does
#   not, 2 when the question could not be answered (grep could not read
#   what it was pointed at). The third status is the point: `grep -q`
#   exits 2 when it scanned nothing, and a caller that folds 2 into "no
#   match" turns an unreadable layer into permission to delete.
_dfm_conf_declares_redirect() {
  local _conf="$1" _st=0
  grep -qE "${_DFM_CONF_REDIRECT_RE}" "${_conf}" || _st=$?
  case "${_st}" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# _dfm_pip_config_dir <dockerfile>
#   Print the repo directory ${CONFIG_DIR} is overlaid from, or exit
#   non-zero when this migration cannot know it. Non-zero on each of the
#   three ways the answer stops being a provable <repo>/config: something
#   redirects CONFIG_SRC (an `ARG CONFIG_SRC=<non-default>` in the
#   Dockerfile itself, or a `[build] arg_N = CONFIG_SRC=...` in ANY layer
#   of the setup.conf chain, which reaches the build as a compose build
#   arg); the default directory is not next to the Dockerfile at all; or
#   some layer of the chain could not be READ, which is not the same as a
#   layer that says nothing. A bare `ARG CONFIG_SRC` with no `=` is a
#   per-stage re-scope, not a redirect, and is ignored.
#
#   The conf layers are DERIVED from _setup_conf_layers rather than listed
#   here. The chain is three files, not the two per-repo ones: the lowest
#   is the template's own .setup.conf inside .base/dist, and the build
#   reads all three (setup_cmd.sh -> _setup_conf_handle ->
#   _setup_conf_layers). A repo that never ran `init.sh --gen-conf` has no
#   per-repo conf at all and runs on template defaults, so a hand-listed
#   roster would answer "no redirect" for exactly the repos whose answer
#   comes from the layer it omitted -- and delete their pip install.
_dfm_pip_config_dir() {
  local _file="$1"
  local _dir
  _dir="$(dirname -- "${_file}")"

  # The Dockerfile's own ARG. Read through a variable rather than a
  # process substitution so grep's status is not thrown away: exit 2 here
  # would present an unscanned file as "no ARG CONFIG_SRC", i.e. as the
  # default.
  local _args _st=0
  _args="$(grep -E "${_DFM_ARG_REDIRECT_RE}" "${_file}")" || _st=$?
  case "${_st}" in
    0|1) ;;
    *) return 1 ;;
  esac

  local _line _val
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    [[ -n "${_line}" ]] || continue
    _val="${_line#*=}"
    _val="${_val%\"}"; _val="${_val#\"}"
    _val="${_val%\'}"; _val="${_val#\'}"
    [[ "${_val}" == "${_DFM_CONFIG_SRC_DEFAULT}" ]] || return 1
  done <<< "${_args}"

  local -a _layers=()
  _setup_conf_layers "${_dir}" _layers "${_DFM_TEMPLATE_DIST_DIR}"
  (( ${#_layers[@]} >= _DFM_CONF_LAYER_FLOOR )) || return 1

  local _conf _cst
  for _conf in "${_layers[@]}"; do
    if [[ ! -f "${_conf}" ]]; then
      # An absent layer declares nothing, which is a legitimate NO -- but
      # only once this has OBSERVED the absence. `[[ -f ]]` also answers
      # false for a layer that exists and is not a readable regular file,
      # and for one whose directory could not be traversed; both are
      # I-COULD-NOT-TELL, and a chain with an unread layer in it cannot
      # say the build reads <repo>/config.
      _dfm_dir_is_readable "$(dirname -- "${_conf}")" || return 1
      [[ -e "${_conf}" || -L "${_conf}" ]] && return 1
      continue
    fi
    _cst=0
    _dfm_conf_declares_redirect "${_conf}" || _cst=$?
    # 1 -- and only 1 -- is "this layer provably declares no redirect".
    # 0 is a redirect and 2 is an unanswered question; both mean the
    # overlay source is not <repo>/config as far as this guard can prove.
    (( _cst == 1 )) || return 1
  done

  [[ -d "${_dir}/${_DFM_CONFIG_SRC_DEFAULT}" ]] || return 1
  printf '%s' "${_dir}/${_DFM_CONFIG_SRC_DEFAULT}"
}

# _dfm_pip_requirements_populated <config_dir>
#   Exit 0 when the repo ships a requirements file with at least one real
#   requirement (any line that is neither blank nor a `#` comment), 1 when
#   it PROVABLY ships none -- the file is absent, which is the case whose
#   build the migration is repairing, or it was read end to end and holds
#   nothing but blanks and comments -- and 2 when the question could not
#   be answered because something on the way to the file, or the file
#   itself, could not be read.
#
#   The third status is the point, and it is the same one
#   _dfm_conf_declares_redirect carries. It has TWO sources here, not one.
#   `grep -q` exits 2 when it scanned nothing -- and, before grep is ever
#   reached, `[[ -f ]]` answers false both for a file that is not there
#   and for a path that could not be traversed at all (a mode that
#   forbids searching config/ or config/pip/, a symlink that does not
#   resolve). Only the first is the absence this migration repairs; the
#   second is a file nobody read, and a file nobody read is not a file
#   with nothing in it. Takes the RESOLVED config source dir, so it is
#   never the one that decides where to look.
_dfm_pip_requirements_populated() {
  local _config_dir="$1"
  local _pip_dir="${_config_dir}/pip"
  local _req="${_pip_dir}/requirements.txt"

  if [[ ! -f "${_req}" ]]; then
    # Walk down to the file, refusing at the first level this process
    # could not read. Absence counts as proof only below a directory that
    # was actually listed.
    _dfm_dir_is_readable "${_config_dir}" || return 2
    if [[ -e "${_pip_dir}" || -L "${_pip_dir}" ]]; then
      _dfm_dir_is_readable "${_pip_dir}" || return 2
      # pip/ was read; something sits at requirements.txt that is not a
      # regular file this process can open.
      [[ -e "${_req}" || -L "${_req}" ]] && return 2
    fi
    # config/ was read and holds no pip/requirements.txt: the observed
    # absence, and the v0.41.0 build breakage this migration exists for.
    return 1
  fi

  local _st=0
  grep -qE '^[[:space:]]*[^#[:space:]]' "${_req}" || _st=$?
  case "${_st}" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# _dfm_pip_line_is_standalone <dockerfile>
#   Exit 0 when every matched helper line is a complete physical
#   instruction -- it neither continues the previous line nor continues
#   onto the next. Only that shape survives a line-based delete intact.
#
#   Exit 1 both when one of them does not AND when the file could not be
#   READ at all. The loop below reads through a redirect, and a redirect
#   that fails leaves the loop unrun: without the status check the
#   unconditional `return 0` at the end would answer "standalone, safe to
#   delete" for a file nothing opened. This is the leg of the status block
#   at the top of the file that names this function, so it has to hold --
#   I-COULD-NOT-TELL never authorises the delete.
#
#   Two probes, because one does not cover it. `[[ -f ]]` answers for
#   every path that is not a regular file to begin with: a missing one,
#   an unresolvable symlink, and a DIRECTORY -- which the redirect alone
#   reads as clean, since on Linux open(2) on a directory succeeds, the
#   first `read` fails with EISDIR, and the loop then exits with the
#   status of its last assignment, 0. The redirect's own status answers
#   for the rest: a path that IS a regular file and still could not be
#   opened (its mode, a mount that went away between the test and the
#   open). Neither is redundant and neither is the whole probe.
_dfm_pip_line_is_standalone() {
  local _file="$1"
  [[ -f "${_file}" ]] || return 1
  local _line _prev_cont=false _cont _read_st=0
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    if [[ "${_line}" =~ ${_DFM_LINE_CONTINUES_RE} ]]; then
      _cont=true
    else
      _cont=false
    fi
    if [[ "${_line}" =~ ${_DFM_PIP_HELPER_RE} ]] \
        && { [[ "${_prev_cont}" == true ]] || [[ "${_cont}" == true ]]; }; then
      return 1
    fi
    _prev_cont="${_cont}"
  done < "${_file}" || _read_st=$?
  [[ "${_read_st}" -eq 0 ]] || return 1
  return 0
}

_migrate_pip_helper_detect() {
  local _file="$1"
  grep -qE "${_DFM_PIP_HELPER_RE}" "${_file}"
}

_migrate_pip_helper_apply() {
  local _file="$1"

  local _config_dir
  if ! _config_dir="$(_dfm_pip_config_dir "${_file}")"; then
    _log_warn upgrade upgrade_started "display=  Dockerfile unchanged: retired CONFIG_DIR pip helper line kept — CONFIG_DIR is not provably overlaid from <repo>/config here (CONFIG_SRC is redirected, a conf layer could not be read, or that directory is absent), so what the line installs cannot be read from here; drop it by hand if it installs nothing (#567 m2)"
    return 0
  fi

  # 1 -- and only 1 -- is "this repo provably installs nothing here", the
  # single status that may reach the delete below. 0 is a real requirement
  # list and 2 is an unanswered question; both keep the line.
  local _rst=0
  _dfm_pip_requirements_populated "${_config_dir}" || _rst=$?
  case "${_rst}" in
    0)
      _log_warn upgrade upgrade_started "display=  Dockerfile unchanged: retired CONFIG_DIR pip helper line kept — config/pip/requirements.txt carries real requirements, so the line still installs them (#567 m2)"
      return 0
      ;;
    1) ;;
    *)
      _log_warn upgrade upgrade_started "display=  Dockerfile unchanged: retired CONFIG_DIR pip helper line kept — config/pip/requirements.txt could not be read, so what the line installs is unknown; a file this migration never read is not a file with nothing in it (#567 m2)"
      return 0
      ;;
  esac

  if ! _dfm_pip_line_is_standalone "${_file}"; then
    _log_warn upgrade upgrade_started "display=  Dockerfile unchanged: retired CONFIG_DIR pip helper line kept — it is part of a backslash-continued RUN a line delete would break; drop it by hand (#567 m2)"
    return 0
  fi

  sed -i -E "\\%${_DFM_PIP_HELPER_RE}%d" "${_file}"
  sed -i '/^# Setup pip packages$/d' "${_file}"
  _log_warn upgrade upgrade_started "display=  Dockerfile patched: dropped retired CONFIG_DIR pip helper line (#567 m2) — re-add an explicit pip step if you ship a real requirements file"
}

# ── Migration 3: explicit hand-listed lib/wrapper COPYs ─────────────────────
#
# Multi-distro repos hand-listed the moved top-level files in their lint
# stage, e.g. `COPY .base/script/docker/_lib.sh .base/script/docker/i18n.sh
# /lint/` or a backslash-continued block of build/run/exec/stop.sh. All
# moved under lib/ and wrapper/ in v0.41.0, so these resolve to zero files.
# The stage already pulls them via the `lib` dir COPY + the wrapper glob, so
# the explicit COPYs are redundant and broken — delete the whole COPY
# statement (handling backslash continuation).
#
# The match anchors on a top-level `.base/script/docker/<name>.sh` reference
# (a bare file directly under docker) whose COPY destination is the lint
# sandbox `/lint/`. The `/lint/` constraint scopes this to the lint-stage
# redundant COPYs and deliberately spares unrelated runtime helper COPYs
# (e.g. `_entrypoint_logging.sh` -> /usr/local/lib/base/, healed by
# migration 4). It also does NOT match migration-1's output
# `.base/script/docker/wrapper/*.sh` (path segment + glob) nor the
# `.base/script/docker/lib` dir COPY (no `.sh`).
_migrate_explicit_copy_detect() {
  local _file="$1"
  local _stmt
  _stmt="$(_dfm_join_copy_statements "${_file}")"
  grep -qE 'COPY[[:space:]]+.*\.base/script/docker/[A-Za-z_]+\.sh.*[[:space:]]/lint/' <<<"${_stmt}"
}

_migrate_explicit_copy_apply() {
  local _file="$1"
  local _tmp
  _tmp="$(mktemp)"
  # awk state machine: when a COPY statement (possibly spanning backslash
  # continuations) references a top-level .base/script/docker/<name>.sh AND
  # targets the /lint/ sandbox, drop every physical line of that statement;
  # otherwise pass through verbatim.
  awk '
    /^[[:space:]]*COPY[[:space:]]/ {
      stmt = $0; buf = $0 ORS; cont = ($0 ~ /\\[[:space:]]*$/)
      while (cont) {
        if ((getline nxt) <= 0) { break }
        stmt = stmt " " nxt; buf = buf nxt ORS
        cont = (nxt ~ /\\[[:space:]]*$/)
      }
      if (stmt ~ /\.base\/script\/docker\/[A-Za-z_]+\.sh/ && stmt ~ /[[:space:]]\/lint\//) { next }
      printf "%s", buf; next
    }
    { print }
  ' "${_file}" > "${_tmp}"
  mv "${_tmp}" "${_file}"
  _log_info upgrade upgrade_started "display=  Dockerfile patched: dropped redundant explicit lib/wrapper COPY(s) (#567 m3)"
}

# ── Migration 4: _entrypoint_logging.sh -> runtime/logging.sh rename ────────
#
# The host-log helper was renamed `_entrypoint_logging.sh` -> `logging.sh`
# and relocated under runtime/ (-> current). Two downstream references
# break: the Dockerfile COPY of the helper into /usr/local/lib/base/, and
# the entrypoint's `source /usr/local/lib/base/_entrypoint_logging.sh`. The
# Dockerfile COPY is healed in place; when a sibling script/entrypoint.sh
# exists next to the Dockerfile, its source line is healed too (the helper's
# baked path /usr/local/lib/base/_entrypoint_logging.sh -> .../logging.sh).
_migrate_logging_rename_detect() {
  local _file="$1"
  # Fire when EITHER the Dockerfile COPY or the sibling entrypoint still
  # references the retired helper name. A partial migration (Dockerfile
  # hand-fixed to runtime/logging.sh, entrypoint still sourcing the old
  # /usr/local/lib/base/_entrypoint_logging.sh) must still heal the
  # entrypoint, otherwise the container cannot source the renamed helper.
  grep -q '_entrypoint_logging\.sh' "${_file}" && return 0
  local _entry
  _entry="$(_dfm_entrypoint_path "${_file}")"
  [[ -f "${_entry}" ]] && grep -q '_entrypoint_logging\.sh' "${_entry}"
}

_migrate_logging_rename_apply() {
  local _file="$1"
  # Dockerfile COPY: old flat helper path -> new runtime/ path, both src and
  # the baked dest filename.
  sed -i -E \
    's#\.base/(downstream/|dist/)?script/docker/(runtime/)?_entrypoint_logging\.sh#.base/dist/script/docker/runtime/logging.sh#g' \
    "${_file}"
  sed -i 's|/usr/local/lib/base/_entrypoint_logging\.sh|/usr/local/lib/base/logging.sh|g' "${_file}"

  # Heal the sibling entrypoint's baked source path, if present. The
  # Dockerfile sits at the repo root; the entrypoint is the conventional
  # script/entrypoint.sh.
  local _entry
  _entry="$(_dfm_entrypoint_path "${_file}")"
  if [[ -f "${_entry}" ]] && grep -q '_entrypoint_logging\.sh' "${_entry}"; then
    sed -i 's|/usr/local/lib/base/_entrypoint_logging\.sh|/usr/local/lib/base/logging.sh|g' "${_entry}"
    _log_info upgrade upgrade_started "display=  entrypoint patched: _entrypoint_logging.sh -> logging.sh source (#567 m4)"
  fi
  _log_info upgrade upgrade_started "display=  Dockerfile patched: _entrypoint_logging.sh -> runtime/logging.sh (#567 m4)"
}

# ── Migration 5: hadolint rules surfaced by the slimmed .hadolint.yaml ──────
#
# v0.41.0 slimmed .hadolint.yaml so it no longer ignores a batch of
# rules the v0.41.0 template Dockerfile already satisfies but older
# downstream Dockerfiles do not. This migration mechanically heals the same
# violations the ad-hoc fanout fixed by hand (each sub-fix is idempotent):
#   DL3007  pin `FROM bats/bats:latest` / `FROM alpine:latest` helper stages
#   DL3046  `useradd -u`  -> `useradd -l -u`
#   DL3003  `RUN cd /lint && hadolint ...` -> `WORKDIR /lint` + `RUN hadolint`
#   DL3042  `pip install -r` -> `pip install --no-cache-dir -r`
#   DL4006  alpine lint-tools stage gains a `SHELL [ash -o pipefail]`
#   DL3006  parameterized `FROM ${BASE_IMAGE}` / `${TEST_TOOLS_IMAGE}` gains
#           an inline `# hadolint ignore=DL3006` (an ARG-driven base image
#           cannot be explicitly tagged)
_migrate_hadolint_detect() {
  local _file="$1"
  grep -Eq '^FROM (bats/bats|alpine):latest' "${_file}" && return 0
  grep -Eq 'useradd[[:space:]]+-u[[:space:]]' "${_file}" && return 0
  grep -Eq '^[[:space:]]*RUN[[:space:]]+cd[[:space:]]+/lint[[:space:]]+&&[[:space:]]+hadolint' "${_file}" && return 0
  grep -Eq 'pip install[[:space:]]+-r' "${_file}" && return 0
  _dfm_needs_dl4006 "${_file}" && return 0
  _dfm_needs_dl3006 "${_file}" && return 0
  return 1
}

# _dfm_needs_dl4006 <file>
#   True when an `alpine ... AS lint-tools` stage is present without a
#   following SHELL ash-pipefail directive.
_dfm_needs_dl4006() {
  local _file="$1"
  grep -Eq '^FROM alpine:[^[:space:]]+ AS lint-tools' "${_file}" \
    && ! grep -Fq 'SHELL ["/bin/ash", "-o", "pipefail", "-c"]' "${_file}"
}

# _dfm_needs_dl3006 <file>
#   True when a parameterized `FROM ${IMAGE}` lacks a preceding inline ignore.
_dfm_needs_dl3006() {
  local _file="$1"
  awk '
    /^FROM \$\{[A-Za-z_]+\}/ && prev !~ /hadolint ignore=DL3006/ { found=1 }
    { prev=$0 }
    END { exit (found ? 0 : 1) }
  ' "${_file}"
}

_migrate_hadolint_apply() {
  local _file="$1"
  # DL3007: pin the helper-stage :latest tags.
  sed -i -E 's|^FROM bats/bats:latest|FROM bats/bats:1.11.0|; s|^FROM alpine:latest|FROM alpine:3.21|' "${_file}"
  # DL3046: useradd -l (idempotent — only adds when not already present).
  sed -i -E 's|useradd[[:space:]]+-u[[:space:]]|useradd -l -u |' "${_file}"
  sed -i -E 's|useradd -l[[:space:]]+-l |useradd -l |' "${_file}"
  # DL3042: pip --no-cache-dir (idempotent).
  sed -i -E 's|pip install[[:space:]]+-r|pip install --no-cache-dir -r|' "${_file}"
  sed -i -E 's|pip install --no-cache-dir --no-cache-dir|pip install --no-cache-dir|' "${_file}"
  # DL3003: cd /lint -> WORKDIR /lint + RUN.
  sed -i -E 's|^([[:space:]]*)RUN[[:space:]]+cd[[:space:]]+/lint[[:space:]]+&&[[:space:]]+hadolint[[:space:]]+(.*)$|\1WORKDIR /lint\n\1RUN hadolint \2|' "${_file}"

  # DL4006: SHELL ash-pipefail right after the alpine lint-tools FROM.
  if _dfm_needs_dl4006 "${_file}"; then
    sed -i -E '/^FROM alpine:[^[:space:]]+ AS lint-tools/a SHELL ["/bin/ash", "-o", "pipefail", "-c"]' "${_file}"
  fi

  # DL3006: inline ignore before each unguarded parameterized FROM.
  if _dfm_needs_dl3006 "${_file}"; then
    local _tmp
    _tmp="$(mktemp)"
    awk '
      /^FROM \$\{[A-Za-z_]+\}/ && prev !~ /hadolint ignore=DL3006/ { print "# hadolint ignore=DL3006" }
      { print; prev=$0 }
    ' "${_file}" > "${_tmp}"
    mv "${_tmp}" "${_file}"
  fi
  _log_info upgrade upgrade_started "display=  Dockerfile patched: hadolint DL3007/DL3046/DL3003/DL3042/DL4006/DL3006 (#567 m5)"
}

# ── Migration 6: noetic entrypoint SC1090 directive ─────────────────────────
#
# The noetic sensor entrypoints `source "/opt/ros/${ROS_DISTRO}/setup.bash"`
# with a stale `# shellcheck disable=SC1091` directive. The non-constant
# path triggers SC1090 (not SC1091), so the slimmed v0.41.0 lint stage fails.
# Broaden the directive to `SC1090,SC1091` on the sibling entrypoint.
_migrate_sc1090_detect() {
  local _entry
  _entry="$(_dfm_entrypoint_path "$1")"
  [[ -f "${_entry}" ]] || return 1
  grep -Eq '^[[:space:]]*#[[:space:]]*shellcheck disable=SC1091[[:space:]]*$' "${_entry}"
}

_migrate_sc1090_apply() {
  local _entry
  _entry="$(_dfm_entrypoint_path "$1")"
  sed -i -E 's|^([[:space:]]*#[[:space:]]*shellcheck disable=)SC1091([[:space:]]*)$|\1SC1090,SC1091\2|' "${_entry}"
  _log_info upgrade upgrade_started "display=  entrypoint patched: shellcheck SC1091 -> SC1090,SC1091 (#567 m6)"
}

# ── Migration 7 (facet B): ARG USER -> ARG USER="${USER_NAME}" ─────────
#
# v0.41.0 compose/CI pass the build args USER_NAME / USER_GROUP / USER_UID /
# USER_GID. A downstream Dockerfile still declaring a bare `ARG USER`
# receives no value, so the image builds the default `initial` user, whose
# home directory mismatches the compose `/home/${USER_NAME}/work` bind
# mount. Re-declare the arg to default from USER_NAME so the existing
# user-creation block (which references ${USER}) keeps working unchanged.
#
# home-literal-lint: allow-begin -- naming the WRONG home directory is the
# whole point of the note below; it is prose about a defect, not a path any
# shipped code reads.
# The mismatching home directory is literally /home/initial.
# home-literal-lint: allow-end
_migrate_arg_user_detect() {
  local _file="$1"
  grep -Eq '^[[:space:]]*ARG[[:space:]]+USER[[:space:]]*$' "${_file}"
}

_migrate_arg_user_apply() {
  local _file="$1"
  # SC2016: the ${USER_NAME} must be written LITERALLY into the Dockerfile
  # (Docker, not this shell, resolves the build arg), so single quotes are
  # intentional.
  # shellcheck disable=SC2016
  sed -i -E 's|^([[:space:]]*)ARG[[:space:]]+USER[[:space:]]*$|\1ARG USER="${USER_NAME}"|' "${_file}"
  _log_info upgrade upgrade_started "display=  Dockerfile patched: ARG USER -> ARG USER=\${USER_NAME} (#567 m7 / #579)"
}

# ── Migration 8 (facet B): nounset-guard the entrypoint ROS source ─────
#
# Under `set -u`, sourcing /opt/ros/$ROS_DISTRO/setup.bash dies on the
# unbound AMENT_TRACE_SETUP_FILES the ament setup chain references, so the
# container exits the instant it starts and `just run` fails. CI never
# catches this — smoke runs at Dockerfile build time and never starts the
# container / runs the ENTRYPOINT. Bracket the source with `set +u` before
# and `set -u` after so unbound vars inside setup.bash do not abort PID 1.
#
# Only fires when the entrypoint actually runs under nounset (`set -u` /
# `set -eu` / `set -euo pipefail`) AND the source is not already guarded by
# an immediately-preceding `set +u`.
_migrate_nounset_source_detect() {
  local _entry
  _entry="$(_dfm_entrypoint_path "$1")"
  [[ -f "${_entry}" ]] || return 1
  grep -Eq '^[[:space:]]*set[[:space:]]+-[a-z]*u' "${_entry}" || return 1
  # An un-guarded source is one whose nearest preceding non-shellcheck-comment
  # line is NOT `set +u` (a shellcheck directive sits between guard and source
  # and must be treated as transparent so re-runs stay idempotent).
  awk '
    /\/opt\/ros\/.*setup\.bash/ {
      if (guard != "+u") { found=1 }
    }
    /^[[:space:]]*#[[:space:]]*shellcheck/ { next }   # transparent: keep guard
    /^[[:space:]]*set[[:space:]]+\+u[[:space:]]*$/ { guard="+u"; next }
    { guard="" }
    END { exit (found ? 0 : 1) }
  ' "${_entry}"
}

_migrate_nounset_source_apply() {
  local _entry
  _entry="$(_dfm_entrypoint_path "$1")"
  local _tmp
  _tmp="$(mktemp)"
  # Wrap each un-guarded setup.bash source with `set +u` / `set -u`,
  # preserving any preceding shellcheck-directive comment line directly above
  # the source (do not split the directive from its target).
  awk '
    /\/opt\/ros\/.*setup\.bash/ && prev !~ /^[[:space:]]*set[[:space:]]+\+u[[:space:]]*$/ {
      # If the previous emitted line was a shellcheck directive for this
      # source, the +u must go ABOVE the directive. Re-buffer it.
      if (held != "") { print "set +u"; print held; held = ""; print; print "set -u"; prev=$0; next }
      print "set +u"; print; print "set -u"; prev=$0; next
    }
    {
      if (held != "") { print held; held = "" }
      if ($0 ~ /^[[:space:]]*#[[:space:]]*shellcheck/) { held=$0; prev=$0; next }
      print; prev=$0
    }
    END { if (held != "") print held }
  ' "${_entry}" > "${_tmp}"
  mv "${_tmp}" "${_entry}"
  _log_info upgrade upgrade_started "display=  entrypoint patched: nounset-guard ROS setup.bash source (#567 m8 / #579)"
}

# ── Migration (smoke-copy): flat .base/test/smoke/ -> per-stage dist tree ────
#
# Up to v0.41.0 base shipped ONE flat smoke tree, and a consumer Dockerfile
# reached it in one of two spellings:
#   COPY .base/test/smoke/ /smoke_test/                       wholesale
#   COPY .base/test/smoke/test_helper.bash /smoke_test/       hand-listed
# Both are in the wild. The shipped specs now live under
# dist/test/bats/smoke/, split into a shared/ baseline plus one folder per
# Dockerfile stage, so every source in both spellings is gone.
#
# The wholesale spelling cannot be rewritten to the shared baseline alone:
# that would build, but would silently drop the specs the stage used to
# run. It is replaced by the shared baseline PLUS the enclosing stage's own
# folder, which is what the current template Dockerfile writes by hand. The
# stage folder is emitted only when the freshly pulled subtree actually
# ships one for that stage: a stage base has no specs for (or an unnamed
# final stage) gets the shared baseline and nothing else, rather than a COPY
# of a directory that does not exist.
#
# The hand-listed spelling names one spec, so it maps to one path -- the
# place that spec now lives. Where that is comes from the freshly pulled
# subtree, looked up by basename, never from a table here: the tree is what
# moved, so the tree is what knows. A basename the subtree ships at two
# paths, or no longer ships at all, is ambiguous or gone; the rewrite
# declines it and warns, leaving a reference a reader can act on rather
# than a guess that resolves somewhere wrong.
#
# Runs BEFORE flat_to_dist so the generic .base/script rewrite never sees
# these lines. Idempotent: once rewritten no flat .base/test/smoke
# reference remains, so detect is false on a second run.
#
# _dfm_smoke_copy_present <file>
#   True when a COPY statement in <file> names the retired flat
#   .base/test/smoke tree. The file is read FOLDED, so a source wrapped onto
#   a backslash continuation counts as part of the statement it belongs to
#   -- a ^COPY-anchored grep over raw lines cannot see one. Anchored at a
#   path boundary (`/`, whitespace, or end of statement) so a sibling tree
#   merely PREFIXED by the retired name -- .base/test/smoke_helpers -- is
#   not mistaken for it.
#
#   The fold is captured into a variable rather than piped into grep: `grep
#   -q` stops reading at the first match, which SIGPIPEs the writer, and
#   under pipefail the caller would read a SUCCESSFUL match as "not found".
_dfm_smoke_copy_present() {
  local _file="$1"
  local _joined
  _joined="$(_dfm_join_copy_statements "${_file}")"
  grep -qE '^[[:space:]]*COPY[[:space:]][^#]*\.base/test/smoke(/|[[:space:]]|$)' \
    <<< "${_joined}"
}

# A COPY is a STATEMENT, not a line: a consumer wraps a long hand-listed one
# across backslash continuations and Docker still reads it as one. Both the
# detect and the post-apply warning ask _dfm_smoke_copy_present, which folds
# first, so neither can miss a source on a continuation line or fire on a
# sibling path merely prefixed by the retired name.
_migrate_smoke_copy_detect() {
  local _file="$1"
  _dfm_smoke_copy_present "${_file}"
}

_migrate_smoke_copy_apply() {
  local _file="$1"

  # Both derivations read the tree NEXT TO the Dockerfile, i.e. the subtree
  # the upgrade just pulled.
  local _root
  _root="$(dirname -- "${_file}")"
  local _smoke_root="${_root}/.base/dist/test/bats/smoke"

  # Which stage folders the subtree ships, as a ":a:b:" membership string
  # awk can test with index().
  local _stages=":"
  local _dir
  for _dir in "${_smoke_root}"/*/; do
    [[ -d "${_dir}" ]] || continue
    _stages+="$(basename -- "${_dir}"):"
  done

  # Every spec the subtree ships, subtree-relative, newline-separated. awk
  # turns it into the basename -> path lookup the hand-listed spelling
  # needs. Passed as a VALUE rather than a second input file on purpose: a
  # subtree that ships no spec yet makes that file empty, and awk's
  # NR == FNR idiom then treats the Dockerfile itself as the list.
  local _specs=""
  if [[ -d "${_smoke_root}" ]]; then
    _specs="$( ( cd "${_smoke_root}" && find . -type f ) | sed 's#^\./##' )"
  fi

  local _tmp
  _tmp="$(mktemp)"
  # The awk below buffers each backslash-continued statement whole and
  # decides once, on the folded text, then rewrites the PHYSICAL lines it
  # buffered -- so a source on a continuation line is healed like any other
  # and the consumer's own wrapping, flags, destination and column
  # alignment survive. Track the enclosing build stage (`FROM ... AS
  # <name>`) so each rewritten wholesale COPY can name its own folder.
  awk -v stages="${_stages}" -v specs="${_specs}" '
    # Exact, whitespace-delimited literal substitution. A regex would let
    # the dots in a spec name match anything, and these are file names read
    # off disk, not patterns.
    function repl(s, from, to,   p, tail, pre, off) {
      off = 0
      while (1) {
        p = index(substr(s, off + 1), from)
        if (p == 0) { return s }
        p = p + off
        tail = substr(s, p + length(from), 1)
        pre = (p == 1) ? " " : substr(s, p - 1, 1)
        if ((tail == "" || tail == " " || tail == "\t") \
            && (pre == " " || pre == "\t")) {
          return substr(s, 1, p - 1) to substr(s, p + length(from))
        }
        off = p
      }
    }
    # Emit the buffered statement as it stands.
    function emit(   i) {
      for (i = 1; i <= nb; i++) { print buf[i] }
    }
    # Emit the buffered statement with the FIRST wholesale smoke source
    # re-rooted at prefix, wherever in the statement that source sits.
    function emit_rerooted(prefix,   i, done, line) {
      done = 0
      for (i = 1; i <= nb; i++) {
        line = buf[i]
        if (!done && line ~ /\.base\/test\/smoke\/?([ \t\\]|$)/) {
          sub(/\.base\/test\/smoke\/?/, prefix, line)
          done = 1
        }
        print line
      }
    }
    function reset() {
      nb = 0
      joined = ""
    }
    function flush(   s, m, f, i, j, k, t, b, line, tok) {
      if (nb == 0) { return }
      s = joined
      sub(/^[ \t]+/, "", s)
      m = split(s, f, /[ \t]+/)
      if (toupper(f[1]) == "FROM") {
        stage = ""
        for (i = 2; i < m; i++) {
          if (toupper(f[i]) == "AS") { stage = f[i + 1] }
        }
        emit(); reset(); return
      }
      if (toupper(f[1]) != "COPY" \
          || s !~ /^[^#]*\.base\/test\/smoke(\/|[ \t]|$)/) {
        emit(); reset(); return
      }
      # Wholesale: a source ENDS at the smoke directory. The whole
      # statement is reproduced twice -- once re-rooted at the shared
      # baseline, once at the enclosing stage folder when the pulled
      # subtree ships one.
      if (s ~ /\.base\/test\/smoke\/?([ \t]|$)/) {
        emit_rerooted(".base/dist/test/bats/smoke/shared/")
        if (stage != "" && index(stages, ":" stage ":") > 0) {
          emit_rerooted(".base/dist/test/bats/smoke/" stage "/")
        }
        reset(); return
      }
      # Hand-listed: rewrite each named spec to where it now lives. A
      # statement may name several (one COPY, many sources) across any
      # number of physical lines, so every token of every line is
      # considered, not only the ones on the line that opens it.
      for (i = 1; i <= nb; i++) {
        line = buf[i]
        k = split(line, tok, /[ \t]+/)
        for (j = 1; j <= k; j++) {
          t = tok[j]
          if (t !~ /^\.base\/test\/smoke\//) { continue }
          b = t
          sub(/.*\//, "", b)
          if (!(b in seen) || seen[b] == "?") { continue }
          line = repl(line, t, ".base/dist/test/bats/smoke/" seen[b])
        }
        buf[i] = line
      }
      emit(); reset()
    }
    BEGIN {
      nb = 0
      joined = ""
      n = split(specs, spec, "\n")
      for (j = 1; j <= n; j++) {
        if (spec[j] == "") { continue }
        b = spec[j]
        sub(/.*\//, "", b)
        # A basename at two paths cannot be resolved from the name alone.
        seen[b] = (b in seen) ? "?" : spec[j]
      }
    }
    {
      buf[++nb] = $0
      joined = joined $0
      if ($0 ~ /\\[ \t]*$/) {
        sub(/\\[ \t]*$/, " ", joined)
        next
      }
      flush()
    }
    END { flush() }
  ' "${_file}" > "${_tmp}"
  mv "${_tmp}" "${_file}"
  _log_info upgrade upgrade_started "display=  Dockerfile patched: .base/test/smoke/ -> per-stage dist smoke COPYs (#915)"

  # Anything still naming the retired tree is a spec the pulled subtree no
  # longer ships under that name, or ships twice. Say so: the build will
  # fail on it, and the message is the only chance to say why. Asked of the
  # same folded view the detect uses: a half-healed statement leaves its
  # unresolved sources on continuation lines, which is exactly where a
  # ^COPY-anchored grep over raw lines cannot see them.
  if _dfm_smoke_copy_present "${_file}"; then
    _log_warn upgrade upgrade_started "display=  Dockerfile still COPYs a retired .base/test/smoke/ spec the pulled subtree ships at no single path — resolve it by hand (#928)"
  fi
}

# ── Migration (flat-to-dist): pre-dist .base/ layout -> .base/dist/ ──────────
#
# base's shipped tree moved under dist/. downstream_to_dist above heals the
# `.base/downstream/` spelling, but that layout only ever shipped as a
# prerelease: the layout every stable consumer is actually sitting on is the
# FLAT one that v0.41.0 shipped --
#   COPY .base/script/docker/runtime/logging.sh ...
#   COPY .base/config "${CONFIG_DIR}"
#   COPY .base/script/docker/lib     /lint/lib
#   COPY .base/script/docker/wrapper /lint/wrapper
# -- and the relocation deleted every one of those paths. Nothing migrated
# it, so the upgrade completed cleanly onto a Dockerfile whose first COPY
# BuildKit resolves does not exist, and the repo could not be built.
#
# Rewrites both prefixes wherever they appear, comments included, so the
# commented-out runtime-stage hints a consumer later uncomments are correct
# too. `.base/test` is deliberately NOT in this table: the smoke tree did not
# just move, it was restructured, and smoke_copy above owns it.
#
# Order is load-bearing. It runs AFTER the migrations whose detect anchors on
# the flat spelling (wrapper_copy, explicit_copy) so those still recognise it,
# and BEFORE logrotate_copy / watchdog_copy, which clone the logging.sh COPY
# line -- from the flat path they would append two MORE COPYs of files that
# no longer exist. Idempotent: `.base/dist/...` does not match.
_migrate_flat_to_dist_detect() {
  local _file="$1"
  grep -qE '\.base/(config|script)' "${_file}"
}

_migrate_flat_to_dist_apply() {
  local _file="$1"
  sed -i -e 's#\.base/config#.base/dist/config#g' \
    -e 's#\.base/script#.base/dist/script#g' "${_file}"
  _log_info upgrade upgrade_started "display=  Dockerfile patched: flat .base/{config,script} -> .base/dist/ (#915)"
}

# ── Migration (logrotate-copy): logging.sh's logrotate.sh sibling ────────────
#
# runtime/logging.sh now sources a sibling logrotate.sh from the in-image
# helper dir (the shared per-start-file + symlink + retention primitives).
# A downstream Dockerfile that COPYs logging.sh into /usr/local/lib/base/
# but predates the split lacks the logrotate.sh COPY, so the container tee
# degrades to no rotation/prune. Insert the sibling COPY right after the
# logging.sh COPY, reusing that line's own flag/src shape. Runs after
# logging_rename so the logging COPY is already in its canonical
# runtime/logging.sh -> /usr/local/lib/base/logging.sh form.
_migrate_logrotate_copy_detect() {
  local _file="$1"
  # Fire only on an ACTIVE (non-commented) COPY of the logging helper into
  # its baked dest, with the logrotate sibling not yet COPY'd. Anchoring on
  # the stable dest path (not the src) heals a hand-relocated src too.
  grep -Eq '^[[:space:]]*COPY[^#]*/usr/local/lib/base/logging\.sh([[:space:]]|$)' "${_file}" || return 1
  grep -Eq '^[[:space:]]*COPY[^#]*/usr/local/lib/base/logrotate\.sh([[:space:]]|$)' "${_file}" && return 1
  return 0
}

_migrate_logrotate_copy_apply() {
  local _file="$1"
  # Emit each active logging.sh COPY line, then a logrotate.sh twin with
  # both the src basename and the baked dest rewritten logging -> logrotate.
  local _tmp
  _tmp="$(mktemp)"
  awk '
    { print }
    /^[[:space:]]*COPY[^#]*\/usr\/local\/lib\/base\/logging\.sh([[:space:]]|$)/ {
      twin=$0
      gsub(/logging\.sh/, "logrotate.sh", twin)
      print twin
    }
  ' "${_file}" > "${_tmp}"
  mv "${_tmp}" "${_file}"
  _log_info upgrade upgrade_started "display=  Dockerfile patched: added runtime/logrotate.sh COPY sibling (#805)"
}

# ── Migration (watchdog-copy): watchdog.sh runtime helper sibling ────────────
#
# The generic single-service watchdog ships a new runtime helper
# watchdog.sh, COPY'd next to logging.sh / logrotate.sh at
# /usr/local/lib/base/. A downstream Dockerfile that COPYs logging.sh but
# predates the watchdog lacks the watchdog.sh COPY, so a repo that adds
# `. /usr/local/lib/base/watchdog.sh` to its entrypoint would source a
# missing file. Insert the sibling COPY right after the logging.sh COPY,
# reusing that line's own flag/src shape. Mirrors the logrotate-copy
# migration; runs after logging_rename / logrotate_copy so the logging
# COPY is already canonical. Idempotent: skipped once watchdog.sh is COPY'd.
_migrate_watchdog_copy_detect() {
  local _file="$1"
  # Fire only on an ACTIVE (non-commented) COPY of the logging helper into
  # its baked dest, with the watchdog sibling not yet COPY'd. Anchoring on
  # the stable dest path heals a hand-relocated src too.
  grep -Eq '^[[:space:]]*COPY[^#]*/usr/local/lib/base/logging\.sh([[:space:]]|$)' "${_file}" || return 1
  grep -Eq '^[[:space:]]*COPY[^#]*/usr/local/lib/base/watchdog\.sh([[:space:]]|$)' "${_file}" && return 1
  return 0
}

_migrate_watchdog_copy_apply() {
  local _file="$1"
  # Emit each active logging.sh COPY line, then a watchdog.sh twin with both
  # the src basename and the baked dest rewritten logging -> watchdog.
  local _tmp
  _tmp="$(mktemp)"
  awk '
    { print }
    /^[[:space:]]*COPY[^#]*\/usr\/local\/lib\/base\/logging\.sh([[:space:]]|$)/ {
      twin=$0
      gsub(/logging\.sh/, "watchdog.sh", twin)
      print twin
    }
  ' "${_file}" > "${_tmp}"
  mv "${_tmp}" "${_file}"
  _log_info upgrade upgrade_started "display=  Dockerfile patched: added runtime/watchdog.sh COPY sibling (#797)"
}

# Ordered migration list. Append new {detect, transform} pairs here; the
# order is load-bearing (earlier normalisations feed later ones).
_MIGRATIONS=(
  downstream_to_dist
  wrapper_copy
  pip_helper
  explicit_copy
  logging_rename
  smoke_copy
  flat_to_dist
  logrotate_copy
  watchdog_copy
  hadolint
  sc1090
  arg_user
  nounset_source
)
