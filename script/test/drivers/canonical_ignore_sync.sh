#!/usr/bin/env bash
# drivers/canonical_ignore_sync.sh - "base's own .dockerignore covers every
# entry the shipped canonical set emits" per-tool driver for the self-test
# dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_canonical_ignore_sync. Follows drivers/stale_setup_conf.sh /
# drivers/derived_figures.sh conventions (sourced lib, uses ${REPO_ROOT},
# _log_* / _die, no main).
#
# Contract: runs INSIDE the ci (test-tools) container where test.sh
# invokes it. References ${REPO_ROOT} (a global exported by test.sh).
#
# ── What it refuses, and why ────────────────────────────────────────────────
#
# base#1275. base's own root .dockerignore carries a block headed
# "Derived / generated artifacts (see script/docker/lib/gitignore.sh
# _canonical_gitignore_entries)" -- a hand-written copy of a set a shipped
# function computes. Two sources of truth for one set, which is the family
# this repo keeps repairing: base#1122, base#1114, base#1169, base#1171,
# each closed by making one side DERIVE from the other rather than by
# re-synchronising the copy.
#
# The copy had drifted by eight entries. Measured on a111c004, with
# _canonical_gitignore_entries at eighteen: .env.local.toml,
# .env.generated, .env.local.bak, env.local.toml, setup.toml.bak,
# .setup.conf.local.bak, setup.local.toml and /deploy/ were all absent
# from the block. base self-uses the docker namespace it ships (its root
# .gitignore says so for the per-worktree override layer), so a base
# checkout can hold a hand-authored setup.local.toml / env.local.toml, and
# those names went to the daemon as build context under a header asserting
# they were handled.
#
# WHAT GOES WRONG TODAY IS NOT A BREACH, and saying so plainly is part of
# the record. .dockerignore's own header states that the only root-context
# build is dockerfile/Dockerfile.test-tools and that it copies NOTHING
# from the context (every COPY is `COPY --from=<stage>`), so no unexcluded
# file reaches an image layer. The live cost is machine-local names
# uploaded to the daemon, and a block that the next person to add an entry
# to the function will read as authoritative. The value here is the gate,
# not a present breach.
#
# ── THE SET IS DERIVED, NOT DECLARED (base#1275) ───────────────────────────
#
# A lint naming today's eighteen entries agrees with the tree the day it
# is written and stops agreeing the day the function grows a row -- which
# is exactly how the block being repaired got wrong in the first place
# (it was CORRECT when written; base#1273 added env.local.toml and nothing
# noticed). So both sides are read: the canonical side from
# _canonical_dockerignore_entries in the SHIPPED lib under ${REPO_ROOT},
# the file side from ${REPO_ROOT}/.dockerignore. The declared-population
# family this follows: base#1089, base#1090, base#1113, base#1112,
# base#1109, base#1214.
#
# ── ONE-DIRECTIONAL, NOT EQUALITY ──────────────────────────────────────────
#
# The rule is "every canonical entry is present", with EXTRAS ALLOWED. Not
# a judgement call and not a softening: `.prev-release/` is genuine
# base-local content (nothing in dist/ names it; it is the released-tree
# scratch script/test/prepare-prev-release.sh materialises) and the
# `*.bak` / `*.swp` / editor globs are a genuine hand-maintained section.
# Equality would refuse all of them. It is also exactly what
# _sync_dockerignore does for a consumer -- append what is missing, leave
# the hand-maintained half alone -- so the gate agrees with the shipped
# mechanism instead of inventing a stricter one.
#
# ── PRESENCE IS A WHOLE LINE, NOT A GLOB THAT WOULD COVER IT ───────────────
#
# Three of the eight absent entries -- .env.local.bak, setup.toml.bak,
# .setup.conf.local.bak -- were excluded IN EFFECT by the `*.bak` glob in
# the hand-maintained cruft section below the block. This driver counts
# them as ABSENT anyway, and the reason is not strictness for its own
# sake: `grep -qxF` is the test _sync_managed_entries itself applies
# (dist/script/docker/lib/gitignore.sh), so a canonical entry a glob
# happens to cover is one the shipped sync would still append verbatim.
# A gate that accepted the glob would disagree with the mechanism it
# exists to mirror, and would rest the coverage of three machine-local
# names carrying credentials on a line in a DIFFERENT, hand-maintained
# section that nothing stops the next editor from narrowing. The report
# says which rule it applied, so a reader of a failure does not have to
# infer it.
#
# Substring matching is the specific wrong answer here and the report
# would hide it: `.env` is canonical and a prefix of five other canonical
# entries, so a substring reader finds `.env.local.bak` "present" in the
# `.env` line and reports three absences where there are eight.
#
# ── Non-vacuity ────────────────────────────────────────────────────────────
#
# THREE ways this could go green having checked nothing, each a _die: the
# target file missing, the shipped lib unreadable or its emitter gone, and
# an emitter that yields no entries. The last is the one the rule
# stale_setup_conf.sh states for its own derived population: a table that
# yields no rows is fatal, not a narrower lint, because an empty canonical
# set makes "every canonical entry is present" true of every file.
#
# ── Scope: base's OWN root .dockerignore, and NOT its root .gitignore ──────
#
# base#1275's Out of scope, and the asymmetry is the point. base's root
# .gitignore carries no header citing the function and no
# `# managed by template` marker, so it has never claimed to be a copy --
# it is a larger divergence (twelve of the eighteen canonical entries are
# not effectively ignored there) but not a two-sources-of-truth bug. It
# also differs DELIBERATELY: compose.yaml is canonical and must never be
# committed in a consumer, while base's own root compose.yaml is tracked
# on purpose -- hand-written, carrying base's test-tools / ci tooling
# services (ADR-00000011 sec.2/4), and not `setup.sh apply` output.
# Gating it needs its own judgement about which entries base opts out of,
# which is its own issue. Neither root file is ever written by the sync:
# _sync_gitignore / _sync_dockerignore have callers only in
# dist/script/base/init.sh, against a consumer's ${REPO_ROOT}.
#
# Every existing case on this subject (gitignore_spec.bats,
# dockerignore_spec.bats, integration/gitignore_sync_spec.bats) works on a
# SYNTHESIZED consumer repo. That absence -- nothing asserting base's own
# file against the canonical set -- is the gap base#1275 names, and it is
# why this gate reaches base's own file rather than a fixture.

# ── The canonical ignore-sync lint ─────────────────────────────────────────

# The shipped lib that defines the canonical set, and the emitter to call.
# Read from under ${REPO_ROOT} rather than sourced by path from here: the
# shipped tree is the source of truth, and a lib that moves fails the lint
# loudly instead of silently emptying it.
readonly _CANONICAL_IGNORE_SYNC_LIB_REL='dist/script/docker/lib/gitignore.sh'
readonly _CANONICAL_IGNORE_SYNC_FN='_canonical_dockerignore_entries'

# The file the set must cover: base's own root .dockerignore. Must exist --
# a missing target would make "every canonical entry is present" a
# question asked of nothing.
readonly _CANONICAL_IGNORE_SYNC_TARGET_REL='.dockerignore'

# _canonical_ignore_sync_entries -- the canonical set, one entry per line,
# read from the SHIPPED emitter under ${REPO_ROOT}.
#
# Sourced in a SUBSHELL, and only its source redirected, so that neither
# the shipped lib's own definitions nor the log.sh it pulls in can replace
# the dispatcher's _die / _log_* out from under it, and so a lib that
# writes to stdout while loading cannot be mistaken for an entry. The
# pattern _stale_setup_conf_table_rows uses, for the same reasons. Blank
# lines are dropped here rather than defended against at the reader.
_canonical_ignore_sync_entries() {
  (
    set +u
    # shellcheck disable=SC1090
    source "${REPO_ROOT}/${_CANONICAL_IGNORE_SYNC_LIB_REL}" > /dev/null 2>&1 \
      || exit 0
    declare -F "${_CANONICAL_IGNORE_SYNC_FN}" > /dev/null 2>&1 || exit 0
    "${_CANONICAL_IGNORE_SYNC_FN}" 2>/dev/null
  ) | awk 'NF > 0'
}

# _canonical_ignore_sync_absent <target> <entry>...
#
# Print every <entry> that does not appear as a WHOLE LINE in <target>,
# in canonical order. `grep -qxF` is the comparison _sync_managed_entries
# applies; see the header on why a glob that would cover an entry does not
# count as that entry being present.
_canonical_ignore_sync_absent() {
  local _target="${1}"; shift
  local _entry
  for _entry in "$@"; do
    grep -qxF -- "${_entry}" "${_target}" || printf '%s\n' "${_entry}"
  done
}

_run_canonical_ignore_sync() {
  echo "--- Running canonical ignore-sync lint ---"

  local _target="${REPO_ROOT}/${_CANONICAL_IGNORE_SYNC_TARGET_REL}"
  if [[ ! -f "${_target}" ]]; then
    _die ci_canonical_ignore_sync \
      "'${_CANONICAL_IGNORE_SYNC_TARGET_REL}' not found under ${REPO_ROOT} -- there is no file to hold the canonical set to, so the lint would pass vacuously. Point it at base's own root .dockerignore."
    return 1
  fi

  # The derived side, refused when it is empty. An empty canonical set
  # makes "every canonical entry is present" true of every file, which is
  # the vacuous pass stale_setup_conf.sh refuses for its own table.
  local -a _entries=()
  local _entry
  while IFS= read -r _entry; do
    _entries+=("${_entry}")
  done < <(_canonical_ignore_sync_entries)
  if (( ${#_entries[@]} == 0 )); then
    _die ci_canonical_ignore_sync \
      "'${_CANONICAL_IGNORE_SYNC_FN}' in '${_CANONICAL_IGNORE_SYNC_LIB_REL}' yielded no entries, so the canonical set could not be read -- every file covers an empty set, and the lint would pass vacuously. Point it at the shipped lib, or restore the emitter."
    return 1
  fi

  local -a _absent=()
  while IFS= read -r _entry; do
    _absent+=("${_entry}")
  done < <(_canonical_ignore_sync_absent "${_target}" "${_entries[@]}")

  if (( ${#_absent[@]} > 0 )); then
    # One printf PER entry. A single format carrying two `%s` is reused
    # until its arguments run out, so one call over the array would pair
    # the target with every SECOND entry and print half as many lines,
    # each naming the wrong file -- measured on the first run of this
    # driver, which reported five lines for eight absences.
    for _entry in "${_absent[@]}"; do
      printf '%s: missing canonical entry: %s\n' \
        "${_CANONICAL_IGNORE_SYNC_TARGET_REL}" "${_entry}"
    done
    _die ci_canonical_ignore_sync \
      "${#_absent[@]} of ${#_entries[@]} canonical entries are absent from '${_CANONICAL_IGNORE_SYNC_TARGET_REL}', which heads a block citing '${_CANONICAL_IGNORE_SYNC_FN}' as their source. Each line above names one; add it to that block verbatim. THE RULE IS ONE-DIRECTIONAL: extras are allowed (base's own .prev-release/, the hand-maintained editor globs), so nothing here asks you to delete a line. PRESENCE IS A WHOLE LINE: a glob elsewhere in the file that would cover an entry does not count as that entry, because 'grep -qxF' is what _sync_managed_entries applies and it would append the entry verbatim anyway."
    return 1
  fi

  echo "canonical ignore-sync lint: clean" \
       "(${#_entries[@]} canonical entries from ${_CANONICAL_IGNORE_SYNC_FN}," \
       "all present as whole lines in ${_CANONICAL_IGNORE_SYNC_TARGET_REL};" \
       "extras allowed)"
}
