#!/usr/bin/env bash
# drivers/stale_setup_conf.sh - "no stale config/docker/setup.conf path in
# runtime shell code" per-tool driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_stale_setup_conf, the guard against the pre-relocation setup.conf
# path creeping back into shipped runtime code.
#
# Contract: runs INSIDE the ci (test-tools) container where test.sh
# invokes it. References ${REPO_ROOT} (a global exported by test.sh).
# Follows drivers/issueref.sh / drivers/adr_numbering.sh conventions
# (sourced lib, uses ${REPO_ROOT}, _log_* / _die, no main).
#
# Why: setup.conf is `just setup`-managed, not hand-edited, so it left the
# hand-editable config/ surface for the repo-root setup.toml file, and
# the path constants in lib/setup_conf.sh, lib/resolve.sh and the wrapper /
# init / upgrade paths moved in lockstep (ADR-00000006 requires that
# lockstep). A newly added lib that hardcodes the legacy path reads a
# location that no longer exists: the repo's config knobs are then silently
# ignored, with no error and no test to catch it. This lint is the
# recurrence guard.
#
# THE STALE SET IS DERIVED, NOT DECLARED (base#1251). There is more than
# one retired spelling: the config/ relocation retired one and the
# INI-to-TOML move (ADR-00000037) retired two more, each with its own
# replacement. A guard naming today's three agrees with the tree the day
# it is written and stops agreeing the day a fourth is retired -- which is
# precisely what base#1167 is held back to do. So everything the TOML era
# retired is READ from `_ini_to_toml_conversions` in the shipped
# ini_to_toml_migrate.sh, which IS that rename table; a row added there is
# guarded by the edit that adds it. Only the pre-relocation path is
# hand-written, because it predates the table and there is nowhere to
# derive it from -- and it is ONE ENTRY in the set rather than the whole
# definition of "stale". The declared-population family this closes:
# base#1089, base#1090, base#1113, base#1112, base#1109, base#1214.
#
# A table that yields no rows is a FATAL error, not a narrower lint. It
# would silently take the subject back to the single spelling base#1251 is
# about, which is the vacuous pass the scan-root guard below already
# refuses one level up.
#
# What this missed while it tested one substring: base#1249 removed 19
# lines naming the repo-root INI dotfile from dist/script/docker/wrapper/
# setup_tui.sh, a shipped wrapper, and this lint was green before that PR
# and green after it. Those 19 were found and removed by hand.
#
# Scope: dist/**/*.sh -- the shipped runtime tree, the only place where a
# stale read is a live defect. Docs and CHANGELOG legitimately discuss the
# old path and are deliberately NOT scanned.
#
# Allowlist: an explicit, region-delimited opt-out rather than a per-file
# exclusion, so a NEW stale reference elsewhere in an allowlisted file is
# still caught. Bracket the legitimate lines with
#   # stale-path-lint: allow-begin -- <why>
#   ...
#   # stale-path-lint: allow-end
# The one live region is in dist/script/docker/lib/setup_conf_migrate.sh,
# around the single accessor that spells the old path, because relocating
# a downstream still carrying it is what that file is for. Unbalanced
# markers (an unterminated begin, an unmatched end) fail the lint -- a
# silently swallowed region would re-open exactly the hole this guard
# closes.

# ── Stale setup.conf path lint ───────────────────────────────────────────────

# The relocated file's basename, kept separate from the legacy directory
# so the driver's own source never carries the stale path as one token
# (it lives under script/, outside the scanned tree, but keeping it split
# means a grep for the stale literal reports only genuine call sites).
readonly _STALE_SETUP_CONF_BASENAME='setup.conf'

# The ONE stale spelling that is hand-written, with its replacement: the
# pre-relocation path from ADR-00000006. It predates the rename table, so
# there is nowhere to read it from -- and it is one entry in the set, not
# the definition of the set.
readonly _STALE_SETUP_CONF_LEGACY="config/docker/${_STALE_SETUP_CONF_BASENAME}"
readonly _STALE_SETUP_CONF_REPLACEMENT="setup.toml"

# Where the authoritative retired-to-current table lives, and the function
# that prints it. See _stale_setup_conf_pairs.
readonly _STALE_SETUP_CONF_TABLE_REL='dist/script/docker/lib/ini_to_toml_migrate.sh'
readonly _STALE_SETUP_CONF_TABLE_FN='_ini_to_toml_conversions'

# The scanned tree, repo-root-relative. Must exist: a missing root would
# make the scan pass vacuously.
readonly _STALE_SETUP_CONF_SCAN_ROOT='dist'

# Region markers for the explicit opt-out (see the header note).
readonly _STALE_SETUP_CONF_ALLOW_BEGIN='stale-path-lint: allow-begin'
readonly _STALE_SETUP_CONF_ALLOW_END='stale-path-lint: allow-end'

# _stale_setup_conf_table_rows -- the rename table's rows, as
# `source<TAB>target`, read from the SHIPPED table under ${REPO_ROOT}.
#
# Sourced in a SUBSHELL, and only its source redirected, so that neither
# the shipped lib's own definitions nor the `conf.sh` it pulls in can
# replace the dispatcher's `_die` / `_log_*` out from under it, and so a
# lib that writes to stdout while loading cannot be mistaken for a row.
# Blank and malformed rows are dropped here rather than defended against
# at every reader.
_stale_setup_conf_table_rows() {
  (
    set +u
    # shellcheck disable=SC1090
    source "${REPO_ROOT}/${_STALE_SETUP_CONF_TABLE_REL}" > /dev/null 2>&1 \
      || exit 0
    declare -F "${_STALE_SETUP_CONF_TABLE_FN}" > /dev/null 2>&1 || exit 0
    "${_STALE_SETUP_CONF_TABLE_FN}" 2>/dev/null
  ) | awk -F'\t' 'NF == 2 && $1 != "" && $2 != ""'
}

# _stale_setup_conf_pairs -- the whole stale set, `source<TAB>replacement`,
# LONGEST SOURCE FIRST.
#
# The hand-written pre-relocation entry plus every row of the table. The
# ordering is the rule that keeps the advice right: `.setup.conf.local`
# CONTAINS `.setup.conf`, so matched the other way round it would be
# reported as a hit on the shorter spelling and sent to `setup.toml` --
# the wrong file, and the one whose values every worktree shares.
_stale_setup_conf_pairs() {
  {
    printf '%s\t%s\n' "${_STALE_SETUP_CONF_LEGACY}" \
      "${_STALE_SETUP_CONF_REPLACEMENT}"
    _stale_setup_conf_table_rows
  } | awk -F'\t' '{ print length($1) "\t" $0 }' \
    | sort -k1,1nr -k2,2 \
    | cut -f2-
}

_run_stale_setup_conf() {
  echo "--- Running stale setup.conf path lint ---"
  local _violations=0
  local _file _rel _line _lineno _in_allow _begin_line
  local _pair _stale _repl _hit

  # Fail loudly on a missing scan root: an empty find root would pass
  # vacuously and silently disable the lint if the shipped tree ever moves.
  local _scan_root="${REPO_ROOT}/${_STALE_SETUP_CONF_SCAN_ROOT}"
  if [[ ! -d "${_scan_root}" ]]; then
    _die ci_stale_setup_conf_path \
      "scan root '${_STALE_SETUP_CONF_SCAN_ROOT}/' not found under ${REPO_ROOT} -- the lint would pass vacuously. Point it at the shipped runtime tree."
    return 1
  fi

  # The derived half of the set, refused when it is empty. A table that
  # cannot be read would narrow the subject back to the single spelling
  # this issue is about and the lint would go green over the other two.
  local -a _table_rows=()
  while IFS= read -r _pair; do
    _table_rows+=("${_pair}")
  done < <(_stale_setup_conf_table_rows)
  if (( ${#_table_rows[@]} == 0 )); then
    _die ci_stale_setup_conf_path \
      "the rename table '${_STALE_SETUP_CONF_TABLE_REL}' yielded no rows, so '${_STALE_SETUP_CONF_TABLE_FN}' could not be read -- the lint would scan for the pre-relocation path only and pass over every spelling the TOML move retired. Point it at the shipped table, or add the conversion rows back to it."
    return 1
  fi

  # `source<TAB>replacement`, longest source first (see the function).
  local -a _pairs=()
  while IFS= read -r _pair; do
    _pairs+=("${_pair}")
  done < <(_stale_setup_conf_pairs)

  local -a _files=()
  while IFS= read -r -d '' _file; do
    _files+=("${_file}")
  done < <(find "${_scan_root}" -name '*.sh' -type f -print0 2>/dev/null \
    | sort -z)

  for _file in "${_files[@]}"; do
    _rel="${_file#"${REPO_ROOT}"/}"
    _in_allow=0
    _begin_line=0
    _lineno=0
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
      _lineno=$(( _lineno + 1 ))

      if [[ "${_line}" == *"${_STALE_SETUP_CONF_ALLOW_BEGIN}"* ]]; then
        _in_allow=1
        _begin_line="${_lineno}"
        continue
      fi
      if [[ "${_line}" == *"${_STALE_SETUP_CONF_ALLOW_END}"* ]]; then
        if [[ "${_in_allow}" -eq 0 ]]; then
          printf '%s:%d: unmatched allow-end (no open allow-begin)\n' \
            "${_rel}" "${_lineno}"
          _violations=$(( _violations + 1 ))
        fi
        _in_allow=0
        continue
      fi

      [[ "${_in_allow}" -eq 1 ]] && continue

      # First match wins, and the set is ordered longest source first, so
      # a `.setup.conf.local` line is reported against that spelling and
      # not against the shorter one it contains.
      _hit=0
      for _pair in "${_pairs[@]}"; do
        _stale="${_pair%%$'\t'*}"
        _repl="${_pair#*$'\t'}"
        if [[ "${_line}" == *"${_stale}"* ]]; then
          printf '%s:%d: %s -> use %s: %s\n' \
            "${_rel}" "${_lineno}" "${_stale}" "${_repl}" "${_line}"
          _violations=$(( _violations + 1 ))
          _hit=1
          break
        fi
      done
      (( _hit )) && continue
    done < "${_file}"

    if [[ "${_in_allow}" -eq 1 ]]; then
      printf '%s:%d: unterminated allow-begin (no closing allow-end)\n' \
        "${_rel}" "${_begin_line}"
      _violations=$(( _violations + 1 ))
    fi
  done

  if [[ "${_violations}" -gt 0 ]]; then
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_stale_setup_conf_path \
      "${_violations} stale config-path reference(s) / unbalanced allow marker(s) under dist/, over ${#_pairs[@]} retired spelling(s). Each line above names the spelling it used and the path that replaced it; use that path. A legitimate legacy-migration line opts out by bracketing it with '# ${_STALE_SETUP_CONF_ALLOW_BEGIN} -- <why>' / '# ${_STALE_SETUP_CONF_ALLOW_END}'."
    return 1
  fi
  echo "stale setup.conf path lint: clean (${#_pairs[@]} retired spelling(s): ${#_table_rows[@]} from ${_STALE_SETUP_CONF_TABLE_FN}, 1 pre-relocation)"
}
