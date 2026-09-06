#!/usr/bin/env bash
#
# setup_conf_migrate.sh - the pre-relocation per-repo setup.conf, and the
# migration off it.
#
# `setup.conf` is `just setup`-managed rather than hand-edited, so the
# per-repo override left the hand-editable `config/` surface for the
# repo-root `.setup.conf` dotfile (ADR-00000006, amended 2026-07-15). A
# downstream still carrying the old path has a file nothing reads: the
# repo's image name, its GPU and GUI modes and its whole `[environment]`
# block silently revert to the shipped defaults, and the image renames
# itself after whatever directory the repo was cloned into.
#
# ── Why the migration lives here and not in upgrade.sh ──────────────────
#
# It shipped in `upgrade.sh`, where the population it exists for can never
# run it. An upgrade is driven by the CONSUMER'S OWN vendored copy of that
# script -- a copy that shipped in an older release and cannot be changed
# retroactively -- and no release before v0.42.0 has heard of the
# relocation. A repo sitting on v0.41.0, which is exactly a repo whose
# override is still at the old path, runs the v0.41.0 driver and the
# migration never fires. Worse, it disarms itself: the upgrade seeds a
# default `.setup.conf` on its way past, so the NEXT upgrade -- which does
# carry the migration -- finds BOTH files, and the old code declined to
# act on that. The one window the migration could help in is the one it
# cannot run in (base#1086).
#
# `init.sh` is the one piece of CURRENT code such an upgrade executes:
# every released `upgrade.sh` re-runs the freshly pulled `init.sh` as its
# Step 3 resync. So the migration runs from the existing-repo resync,
# before anything can regenerate over the result -- the same reasoning
# `_migrate_env_to_local` (lib/env_emit.sh) and `_migrate_smoke_tree`
# (lib/smoke_migrate.sh) spell out, and the third instance of the
# asymmetry ADR-00000006 records: work a released caller cannot do belongs
# on the new tree's side of the boundary. It also covers the path an
# upgrade never takes at all -- a repo that RE-ESTABLISHES its subtree
# (drop `.base/`, `git subtree add` at the new tag, run `init.sh`) loses
# its config the same way, and never runs `upgrade.sh` to be helped by it.
#
# ── Why BOTH-exist merges rather than refuses ───────────────────────────
#
# A wrong image name and an empty `[environment]` are not a warning-grade
# outcome, so the old "warn and proceed with the root file" is gone. The
# alternative to merging is refusing -- exit non-zero and let the caller
# put the repo back -- and at THIS point in the flow there is no caller
# that can. Read against the released sources: neither v0.41.0's nor
# v0.42.0's `upgrade.sh` installs an EXIT trap, and the one rollback they
# have (`_rollback_subtree_pull`) is reachable only from the Step 2
# integrity check, which has already passed by the time Step 3 runs. A
# non-zero exit here therefore aborts the driver under `set -e` with the
# subtree pull ALREADY COMMITTED, while init.sh's own rollback restores
# the consumer's wrappers to the layout the pull just deleted -- a repo
# whose `.version` claims the new release with every wrapper dangling,
# which is base#1077's shape. Refusing does not leave the repo as it was;
# it breaks it and keeps the config file company.
#
# So: merge, and never overwrite anything the user chose.
#
# ── What "the user chose" means, per SECTION ────────────────────────────
#
# The decision unit is the section, because section-replace is the conf
# chain's one rule (lib/conf.sh `_conf_load_layers`): a layer that defines
# a section supplies it WHOLESALE, and eight sections are `<prefix>_N`
# ordered lists that a per-key merge could neither assemble nor let anyone
# remove an item from. So for every section either file defines:
#
#   - only the legacy file defines it  -> the root file asserts nothing
#     there; the legacy file's is all there is.
#   - both spell it identically        -> nothing to decide. This is the
#     case that matters in practice: `setup.sh` writes `[volumes] mount_1`
#     into every freshly seeded root file, so a file-level "is this byte
#     for byte the template" test would find a difference in every repo
#     and the merge would never fire.
#   - the root's is byte-identical to the SHIPPED TEMPLATE's -> under
#     section-replace that says exactly what leaving it out says, so it is
#     not a choice anyone made; the legacy file's wins.
#   - anything else                    -> the user's. Nothing is
#     overwritten, BOTH files are kept, and the message names the sections
#     that need a human.
#
# A section the template does not carry at all can never match it, so an
# absent or unreadable template baseline blocks every section and the
# migration keeps both files -- the fail-safe direction, and the same
# discipline `_migrate_lifecycle_restart_default` uses when it cannot see
# the vendored baseline it discriminates on.
#
# Nothing here deletes user content on any branch. The only file removed
# is one the check above has established is a copy of the shipped default.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_SETUP_CONF_MIGRATE_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_SETUP_CONF_MIGRATE_SOURCED=1

# The INI primitives (`_conf_load` and the handle arrays behind it) are
# pulled in directly rather than via _lib.sh's load order, so this file
# stays sourceable on its own by the light callers -- the same shape
# lib/setup_conf.sh uses. conf.sh has its own double-source guard.
_setup_conf_migrate_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=dist/script/docker/lib/conf.sh
source "${_setup_conf_migrate_lib_dir}/conf.sh"
unset _setup_conf_migrate_lib_dir

# stale-path-lint: allow-begin -- the one function allowed to name the
# pre-relocation override path, because relocating a downstream still
# carrying it is what this file is for. Every other mention of that path
# in shipped runtime code is a defect (the override lives at the repo-root
# .setup.conf dotfile), so the opt-out ends at the matching allow-end.
#
# _setup_conf_legacy_rel
#   The legacy override's repo-relative path. One spelling, so the callers
#   below -- which hand it to git as a pathspec and to the filesystem as a
#   path -- cannot come apart from each other.
_setup_conf_legacy_rel() {
  printf '%s' "config/docker/setup.conf"
}
# stale-path-lint: allow-end

# _setup_conf_git_can_stage <repo_root>
#
# Whether `git add` run against <repo_root> lands in THAT repo's index.
#
# `rev-parse --is-inside-work-tree` answers "is this inside ANY work
# tree", which on a hand-bootstrapped repo sitting inside somebody else's
# checkout resolves to yes and writes the whole resync into a third
# party's index (ADR-00000006, amended a fourth time). Comparing
# `--show-toplevel` against the root is the fence that keeps a staging
# call inside the repo it is about. Physical paths on both sides so a
# symlinked checkout compares equal.
_setup_conf_git_can_stage() {
  local _root="${1:?"${FUNCNAME[0]}: missing repo_root"}"
  local _top _abs
  _top="$(git -C "${_root}" rev-parse --show-toplevel 2> /dev/null)" || return 1
  [[ -n "${_top}" ]] || return 1
  _top="$(cd -P -- "${_top}" 2> /dev/null && pwd -P)" || return 1
  _abs="$(cd -P -- "${_root}" 2> /dev/null && pwd -P)" || return 1
  [[ -n "${_abs}" && "${_top}" == "${_abs}" ]]
}

# _setup_conf_sections_of <handle> <outarray>
#
# The sections <handle> DEFINES, first-appearance order. "Defines" is
# ">= 1 entry", which is what section-replace means by it: a bare header
# with no keys contributes nothing and does not displace a lower layer.
_setup_conf_sections_of() {
  local _h="${1:?"${FUNCNAME[0]}: missing handle"}"
  local -n _sso_out="${2:?"${FUNCNAME[0]}: missing outvar"}"
  local -n _sso_es="${_h}__es"
  local -A _sso_seen=()
  local _sso_i _sso_s
  _sso_out=()
  for (( _sso_i = 0; _sso_i < ${#_sso_es[@]}; _sso_i++ )); do
    _sso_s="${_sso_es[_sso_i]}"
    [[ -n "${_sso_seen[${_sso_s}]:-}" ]] && continue
    _sso_seen["${_sso_s}"]=1
    _sso_out+=("${_sso_s}")
  done
}

# _setup_conf_union_sections <outarray> <handle>...
#
# Every section any of the handles defines, deduped, in the order the
# handles introduce them.
_setup_conf_union_sections() {
  local -n _scus_out="${1:?"${FUNCNAME[0]}: missing outvar"}"
  shift
  local -A _scus_seen=()
  local -a _scus_one=()
  local _scus_h _scus_s
  _scus_out=()
  for _scus_h in "$@"; do
    _setup_conf_sections_of "${_scus_h}" _scus_one
    for _scus_s in ${_scus_one[@]+"${_scus_one[@]}"}; do
      [[ -n "${_scus_seen[${_scus_s}]:-}" ]] && continue
      _scus_seen["${_scus_s}"]=1
      _scus_out+=("${_scus_s}")
    done
  done
}

# _setup_conf_section_repr <handle> <section> <outvar>
#
# One section's entries as a single comparable string: key, US, value, RS,
# in file order. Duplicate keys and reopened sections are preserved, so
# two sections compare equal only when they say the same thing in the same
# order -- comments and blank lines, which the tokenizer drops, are the
# only difference this deliberately cannot see.
_setup_conf_section_repr() {
  local _h="${1:?"${FUNCNAME[0]}: missing handle"}"
  local _sec="${2:?"${FUNCNAME[0]}: missing section"}"
  local -n _scr_out="${3:?"${FUNCNAME[0]}: missing outvar"}"
  local -n _scr_es="${_h}__es" _scr_k="${_h}__keys" _scr_v="${_h}__vals"
  local _scr_i
  _scr_out=""
  for (( _scr_i = 0; _scr_i < ${#_scr_k[@]}; _scr_i++ )); do
    [[ "${_scr_es[_scr_i]}" == "${_sec}" ]] || continue
    _scr_out+="${_scr_k[_scr_i]}"$'\x1f'"${_scr_v[_scr_i]}"$'\x1e'
  done
}

# _setup_conf_merge_blockers <legacy_handle> <root_handle> <template_handle> <outarray>
#
# The sections the legacy file cannot take over, i.e. the ones where the
# root file says something the shipped template does not. Empty means the
# whole relocation is safe; anything in it means keep both files and hand
# the decision to a person. The rules, and why the unit is the section at
# all, are in this file's header.
_setup_conf_merge_blockers() {
  local _legacy_h="${1:?"${FUNCNAME[0]}: missing legacy handle"}"
  local _root_h="${2:?"${FUNCNAME[0]}: missing root handle"}"
  local _tmpl_h="${3:?"${FUNCNAME[0]}: missing template handle"}"
  local -n _scmb_out="${4:?"${FUNCNAME[0]}: missing outvar"}"
  _scmb_out=()

  local -a _scmb_secs=()
  _setup_conf_union_sections _scmb_secs "${_legacy_h}" "${_root_h}"

  local _scmb_s _scmb_l _scmb_r _scmb_t
  for _scmb_s in ${_scmb_secs[@]+"${_scmb_secs[@]}"}; do
    _setup_conf_section_repr "${_legacy_h}" "${_scmb_s}" _scmb_l
    _setup_conf_section_repr "${_root_h}" "${_scmb_s}" _scmb_r
    _setup_conf_section_repr "${_tmpl_h}" "${_scmb_s}" _scmb_t
    # The root file does not define it: replacing the file cannot lose
    # anything it never said.
    [[ -z "${_scmb_r}" ]] && continue
    # Both spell it the same way, so there is nothing to decide.
    [[ "${_scmb_l}" == "${_scmb_r}" ]] && continue
    # The root's is the shipped default: under section-replace that is
    # what saying nothing says. A section the template does not carry
    # never matches here, which is the fail-safe direction.
    [[ "${_scmb_r}" == "${_scmb_t}" ]] && continue
    _scmb_out+=("${_scmb_s}")
  done
}

# _relocate_legacy_setup_conf <repo_root> <legacy_path> <new_path>
#
# Move the override to the root dotfile and stage the move.
#
# STAGED, never committed. The script that commits is the consumer's own
# released `upgrade.sh`, whose closing commit takes whatever is in the
# index, and init.sh is also a repair command a user may run by hand --
# where a commit it never asked for would be the surprise. Same contract
# as `_stage_resync_output` (ADR-00000006, amended 2026-09-04).
#
# EVERY git call here is behind the same fence, not just the staging pair
# at the end. `git -C <root>` answers for the nearest ENCLOSING work tree,
# so on a hand-bootstrapped repo living inside somebody else's checkout an
# unfenced `git mv` or `git rm` writes this relocation into a third
# party's index -- which is the failure _setup_conf_git_can_stage was
# written for, and it does not stop being that failure because the call
# spelling it is `mv` rather than `add`.
_relocate_legacy_setup_conf() {
  local _root="${1:?"${FUNCNAME[0]}: missing repo_root"}"
  local _legacy="${2:?"${FUNCNAME[0]}: missing legacy path"}"
  local _new="${3:?"${FUNCNAME[0]}: missing new path"}"
  local _rel
  _rel="$(_setup_conf_legacy_rel)"

  local _can_stage=0
  _setup_conf_git_can_stage "${_root}" && _can_stage=1

  # Any root file still here is one the blocker check has established is
  # a copy of the shipped default. Dropping it first makes the move a
  # plain rename in every git state, rather than depending on how `git mv`
  # treats a destination that exists but is not tracked.
  if [[ -e "${_new}" || -L "${_new}" ]]; then
    if (( _can_stage )); then
      git -C "${_root}" rm -f --quiet -- ".setup.conf" > /dev/null 2>&1 \
        || rm -f -- "${_new}"
    else
      rm -f -- "${_new}"
    fi
  fi

  local _moved=0
  if [[ -L "${_legacy}" ]]; then
    # A symlink is a POINTER, and a relative one is spelled against the
    # directory it sits in. Moving the pointer from `config/docker/` to
    # the repo root re-aims it two levels up, so `.setup.conf` arrives
    # DANGLING: the repo reads no override at all and runs on the
    # template defaults, under a log line saying its configuration was
    # relocated. So the CONTENT moves. The file the link named is its
    # owner's and is left exactly where they put it -- which is also why
    # this cannot be a `git mv`: the pointer is what git tracks.
    #
    # Written via a temporary so a read that fails partway cannot leave a
    # truncated `.setup.conf` standing in for the repo's configuration.
    local _tmp="${_new}.migrating.$$"
    if cp -L -- "${_legacy}" "${_tmp}" > /dev/null 2>&1; then
      mv -f -- "${_tmp}" "${_new}"
      if (( _can_stage )) \
        && git -C "${_root}" ls-files --error-unmatch -- "${_rel}" > /dev/null 2>&1; then
        git -C "${_root}" rm -f --quiet -- "${_rel}" > /dev/null 2>&1 \
          || rm -f -- "${_legacy}"
      else
        rm -f -- "${_legacy}"
      fi
      _moved=1
    else
      rm -f -- "${_tmp}"
      _log_warn init setup_conf_migration_conflict \
        "display=The per-repo setup.conf override under config/ is a symlink whose target could not be read, so nothing was moved and BOTH paths were left exactly as they are. Copy the configuration to the repo-root .setup.conf by hand -- only that path is read." \
        "path=${_legacy}"
      return 0
    fi
  elif (( _can_stage )) \
    && git -C "${_root}" ls-files --error-unmatch -- "${_rel}" > /dev/null 2>&1; then
    git -C "${_root}" mv -- "${_rel}" ".setup.conf" > /dev/null 2>&1 && _moved=1
  fi
  if (( _moved == 0 )); then
    mv -f -- "${_legacy}" "${_new}"
  fi
  if (( _can_stage )); then
    git -C "${_root}" add -- ".setup.conf" > /dev/null 2>&1 || true
    git -C "${_root}" rm --cached --quiet -- "${_rel}" > /dev/null 2>&1 || true
  fi

  # Working-tree tidy: git tracks no empty directories, and a leftover
  # `config/docker/` reads to the next person as "the old path is still
  # there". Both rmdirs refuse a non-empty directory, so a config/ holding
  # anything else is untouched.
  rmdir -- "${_root%/}/config/docker" 2> /dev/null || true
  rmdir -- "${_root%/}/config" 2> /dev/null || true
  return 0
}

# _migrate_legacy_setup_conf <repo_root> [template_dist_dir]
#
# Relocate a legacy per-repo `setup.conf` override -- the one under
# `config/`, spelled by _setup_conf_legacy_rel above -- to the repo-root
# `.setup.conf`, merging over a root file that is only the shipped
# default. <template_dist_dir> is the freshly pulled subtree's `dist/`
# directory, the one place the shipped baseline can be read from; without
# it nothing can tell a default from a choice, so every contested section
# blocks and both files are kept.
#
# Idempotent, and inert on every repo that has no legacy file -- which is
# every repo bootstrapped since the relocation.
_migrate_legacy_setup_conf() {
  local _root="${1:?"${FUNCNAME[0]}: missing repo_root"}"
  local _tmpl_dist="${2-}"
  local _legacy _rel
  _rel="$(_setup_conf_legacy_rel)"
  _legacy="${_root%/}/${_rel}"
  local _new="${_root%/}/.setup.conf"

  [[ -f "${_legacy}" ]] || return 0

  if [[ ! -f "${_new}" ]]; then
    _log_warn init setup_conf_migrated_to_root \
      "display=MIGRATION: relocating per-repo setup.conf override to the repo root. setup.conf is tool-managed, so it left the hand-editable config/ surface and is read at the repo-root .setup.conf dotfile; the file at the old path was the repo's own configuration and nothing reads it there any more." \
      "path=${_new}"
    _relocate_legacy_setup_conf "${_root}" "${_legacy}" "${_new}"
    return 0
  fi

  # Without the shipped baseline nothing can tell a default from a choice,
  # so decide nothing. The path is built only from a non-empty prefix: an
  # empty one resolves to `/.setup.conf`, a real readable path with
  # nothing to do with this repo, which lib/setup_conf.sh rejects for the
  # same reason in the layer chain.
  local _tmpl_conf=""
  [[ -n "${_tmpl_dist}" ]] && _tmpl_conf="${_tmpl_dist%/}/.setup.conf"
  if [[ -z "${_tmpl_conf}" || ! -f "${_tmpl_conf}" ]]; then
    _log_warn init setup_conf_migration_conflict \
      "display=Found BOTH a legacy per-repo setup.conf under config/ and a repo-root .setup.conf, and no shipped template baseline to tell a default apart from a setting somebody chose. Nothing was overwritten and BOTH files were kept -- reconcile them by hand, then delete the one under config/. Only the root file is read." \
      "path=${_new}"
    return 0
  fi

  _conf_load "${_legacy}" _SCM_LEGACY
  _conf_load "${_new}" _SCM_ROOT
  _conf_load "${_tmpl_conf}" _SCM_TMPL

  local -a _blockers=()
  _setup_conf_merge_blockers _SCM_LEGACY _SCM_ROOT _SCM_TMPL _blockers

  if (( ${#_blockers[@]} > 0 )); then
    _log_warn init setup_conf_migration_conflict \
      "display=Found BOTH a legacy per-repo setup.conf under config/ and a repo-root .setup.conf, and the root file carries settings the shipped template does not: [${_blockers[*]}]. Nothing was overwritten and BOTH files were kept -- reconcile them by hand, then delete the one under config/. Only the root file is read." \
      "sections=${_blockers[*]}" \
      "path=${_new}"
    return 0
  fi

  _log_warn init setup_conf_migrated_to_root \
    "display=MIGRATION: relocating per-repo setup.conf override to the repo root. A .setup.conf was already here, but every section of it was the shipped template's, which under section-replace says exactly what leaving it out says -- so it was never a choice anyone made and the repo's own file at the old path takes over." \
    "path=${_new}"
  _relocate_legacy_setup_conf "${_root}" "${_legacy}" "${_new}"
  return 0
}
