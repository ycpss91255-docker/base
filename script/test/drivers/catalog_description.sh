#!/usr/bin/env bash
# drivers/catalog_description.sh - "a test says why its case matters"
# per-tool driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_catalog_description.
#
# Contract: runs INSIDE the ci (test-tools) container where test.sh
# invokes it. References ${REPO_ROOT} (a global exported by test.sh).
# Follows drivers/home_literal.sh / drivers/changelog_entry.sh conventions
# (sourced lib, uses ${REPO_ROOT}, _log_* / _die, no main).
#
# The RULE, and the worked contrast, are base#922's and are ported here
# rather than re-derived; base#976 was the first implementation of them,
# against the catalogue rather than against the specs, and is superseded.
#
# ── Why a description is worth requiring ────────────────────────────────
#
# A description does not duplicate the test name. This tree's `@test`
# names are long and already say WHAT is asserted; a description says why
# the case matters. Compare:
#
#   name: build.sh test: a fully CACHED verification stage is not reported
#         as a pass
#   desc: The load-bearing case: every check CACHED reports that nothing ran
#
# A `-` loses the second half, which is the half a reader cannot
# reconstruct later.
#
# THE CONVENTION, which matters more than this lint. The description
# answers WHY THIS CASE MATTERS -- what it defends, whether it is the
# load-bearing one, what breaks if it goes. It does NOT restate what the
# test does; the name already does that, at length. A required field
# people do not know how to fill produces filler:
#
#   # why: fails on an unterminated allow-begin
#   @test "_run_changelog_entry: FAILS on an unterminated allow-begin" {
#
# which is WORSE than nothing, because it looks like information and
# passes this lint. The convention is the primary defence and this lint is
# only the floor; it is stated for spec authors in doc/test/unit.md's "How
# this catalogue is maintained" section, and repeated in the failure
# message below, because the moment somebody meets the rule is the moment
# they need to know how to satisfy it.
#
# Mechanically detecting restatement -- high token overlap between name
# and description -- was considered and NOT built. The two above differ by
# a rewording, not by a measurable distance, so the rule would fire on
# honest short descriptions and miss reworded filler; a guard whose false
# positives are the good rows teaches people to write around it. That is a
# judgement a reviewer makes.
#
# ── What this lint reads, and why it is the SPEC and not the catalogue ──
#
# The population is `^@test` over the spec trees. That is the whole
# suite, derived from a checkout, and it cannot be opted out of: base#976
# scanned doc/test/*.md instead, where a section that answered with a
# `| Category | Tests |` summary or with prose took its tests out of a
# REQUIRED field with both gates green -- 606 tests on the tree this
# replaced it on (measured 2026-09-03), plus 893 more in sections with no
# table at all. With the description at the test there is no shape to hide
# behind.
#
# The MARKER READER is shared with the generator (../spec-markers.sh), not
# copied: one `# why:` block has exactly one correct reading, and a second
# copy of that loop would agree on the day it was pasted and drift after.
# What is deliberately NOT shared is the SCAN -- which files are in scope.
# That is where leaning on the generator goes vacuous: a lint that
# inherits the generator's idea of the population agrees, by construction,
# that a spec the generator has stopped seeing has nothing to check. So
# the scan is this driver's own, and it is the whole spec tree rather than
# the five globs the catalogues happen to cover.
#
# ── The transition ceiling ──────────────────────────────────────────────
#
# Moving the rule from the row to the `@test` ENLARGES the debt by
# definition. Measured 2026-09-03: the catalogue held 1209 filled
# descriptions against 3700 tests, so the migration commit left 2491
# undescribed. This branch's own specs then described 18 more tests and
# added 26 already-described ones, and the ceiling below was that final
# figure -- so the slack started at exactly 0 rather than at the larger
# number the migration alone would have justified.
#
# It was recomputed ONCE more, at the origin/main merge, 2473 -> 2641. A
# merge is the one event that can raise it: it imports tests written
# before this rule existed (168 of them here -- 133 in four spec files
# added on main, 35 appended to existing ones), which is transition debt
# arriving late rather than debt this branch chose. The alternative is
# either failing the merge until somebody backfills 168 descriptions in a
# hurry, which produces exactly the filler the header argues against, or
# exempting the imported tests by name, which is the roster. The number is
# recomputed from the merged tree, so it is still a figure the tree
# computed and a person ratified.
#
# 19 of those 168 were then NOT debt and the reset had to give them back:
# main had written their descriptions in the catalogue table -- the one
# place this branch stops reading -- so a wholesale regeneration would
# have deleted authored prose while the gate stayed green. They were
# migrated into markers, the same direction the migration ran, and the
# ceiling went down with them: 2641 -> 2622, slack back to 0. A merge is
# the event that can raise the ceiling; it is not licence to drop what the
# other side wrote.
#
# Failing all of them at once blocks this change on a backfill nobody
# asked for -- and a rushed backfill produces exactly the filler above,
# which looks like information and passes.
#
# So there is ONE NUMBER, a CEILING, below. The lint fails when
# `undescribed > ceiling`. It is a `readonly` here and not a sidecar file,
# which is what "no roster" has to mean.
#
# Why that is not a roster, argued rather than asserted. The forbidden
# thing is a PERSON being the mechanism that keeps two things in
# agreement. A per-row baseline is exactly that: one judgement per row,
# each able to rot individually, each able to excuse one specific test
# forever, and nothing in a checkout able to say whether a given line is
# still true. A single number names no test. It cannot excuse a
# particular test, so it cannot be individually stale; it cannot be wrong
# about which tests exist, because the count is recomputed from the tree
# on every run; and it cannot decay, because it has no entries to decay.
# The person ratifies a number the tree computed.
#
# Why a CEILING and not exact equality. Exact equality is the stronger
# ratchet and it was rejected on this repo's own evidence: five
# self-declared grand-total lines that every branch edits caused 61
# conflicts in 65 merges (ADR-00000028, measured 2026-09-02). An
# exact-equality counter is that shape again -- every backfill PR and
# every new-test PR would edit the same line. A ceiling is edited only by
# a branch that ADDS an undescribed test, which is precisely the branch a
# reviewer should be looking at, and never by a branch that writes a
# description.
#
# THE COST, stated rather than papered over. Slack = ceiling - actual. It
# starts at 0 and grows by one each time somebody backfills a description
# without lowering the ceiling, and within that slack a new undescribed
# test can land green. That is a real weakening compared to a per-row
# baseline. What bounds it: the run PRINTS `tests=.. described=..
# undescribed=.. ceiling=.. slack=..` on every invocation, clean or not,
# so the slack is a visible number on every CI log rather than an
# invisible category. Closing it is a one-line PR anybody can open.
# Raising the ceiling is one reviewable line, and the policy is that it
# may only go down; that is NOT mechanically enforceable in the
# lint-static runner's shallow checkout with no history, and this driver
# does not pretend otherwise -- a lint whose verdict depends on how much
# was fetched is worse than no lint.
#
# Considered and rejected:
#   - per-file or per-directory ceilings: five to fifteen numbers instead
#     of one, no decision carried by the split, each acquiring its own
#     slack.
#   - "fail only on tests the change-set touched": needs git history,
#     unavailable in the shallow lint checkout -- and a lint that goes
#     quiet when the fetch is shallow is a fail-open default.
#   - "a file with any described test must have all of them described":
#     punishes the first person to write a description in a 135-test
#     spec, which trains people not to write the first one.
#   - writing all 2473 now: filler, and it is not this change.
#
# What actually makes the transition work is not the ceiling. It is that
# the marker sits on the lines above the `@test` the author is already
# writing, so a description is typed in the same keystroke run as the
# test -- unlike a row in a 4000-line document the author had to go and
# find after running the generator.
#
# ── What is NOT under the ceiling ───────────────────────────────────────
#
# Everything spec-markers.sh reports -- an orphaned block, a detached
# one, a second marker, a `@test` line the canonical form cannot read --
# fails outright, at any count. So does a marker whose prose is a
# non-answer. None of those is transition debt: each is an edit somebody
# made, and the ceiling exists for tests nobody has reached yet.
#
# Non-vacuity: an unusable scan root, or a scan that finds no spec files
# at all, DIES rather than reporting clean.

_CATALOG_DESC_DRIVER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" \
  && pwd -P)"
readonly _CATALOG_DESC_DRIVER_DIR

# The marker reader, shared rather than copied. Sourcing is side-effect
# free: spec-markers.sh guards its `set -euo pipefail` on being run
# directly and defines no readonly globals, so a second source (the
# generator reaches it too) is a no-op.
# shellcheck source=script/test/spec-markers.sh
source "${_CATALOG_DESC_DRIVER_DIR}/../spec-markers.sh"

# ── Catalog description lint ─────────────────────────────────────────────────

# The spec trees, repo-root-relative. This driver's OWN scan: see the
# header on why it is not the generator's doc-to-glob map.
readonly _CATALOG_DESC_SCAN_GLOBS=(
  'test/bats/**/*_spec.bats'
  'dist/test/bats/smoke/**/*.bats'
)

# The transition ceiling. Set to the exact count the migration left, then
# recomputed once when origin/main was merged in: 2473 -> 2641 -> 2622. It
# may only ever go DOWN by an ordinary change; the one thing that raises it
# is a merge that IMPORTS tests written before this rule existed, which is a
# ratchet reset and not a licence, and it is recomputed from the merged
# tree rather than guessed. The second step is the ordinary direction and
# not part of that reset: 19 of the imported tests arrived carrying a
# description main had written in the catalogue table, so those 19 were
# migrated into markers here rather than counted as debt somebody else
# would have to re-derive. See the header for why this is one number and
# not a file of them.
#
# 2622 -> 2620 at the changelog-split merge, and that is the ordinary
# direction again, not a second reset. That branch added 42 tests and
# renamed 2, and all 44 were described here rather than imported as debt --
# the 42 are this branch's own, and the 2 renames were already inside the
# ceiling, so describing them is what takes the number down by 2.
#
# 2605 at the second merge with origin/main. This is the case the number's
# storage makes awkward and it is worth writing down: BOTH sides had
# lowered it independently -- 2612 here, 2607 on main -- and NEITHER was
# right afterwards, because the descriptions compose. The merged tree
# measures 2605. Taking a side would have handed this branch slack it did
# not earn (2612) or claimed a floor the tree does not reach (2607); the
# rule is to recompute from the merged tree, which is what the catalogue
# itself does. See base#1024 for why a single stored number conflicts on
# every merge by construction.
readonly _CATALOG_DESC_UNDESCRIBED_CEILING=2605

# The written-out non-answers, matched case-insensitively on the whole
# trimmed marker. `nil`, `none`, `tbd`, `todo` and `unknown` carry a
# three-character run, so the "has a word in it" test below lets them
# through and this list is the only thing that refuses them. `n/a` and
# `na` do NOT -- the word rule catches them first and their entries here
# are spare. They are listed anyway, because this is the vocabulary a
# reader audits and a half-list reads as a decision that `n/a` is
# acceptable.
readonly _CATALOG_DESC_NON_ANSWERS_RE='^(n/a|na|nil|none|tbd|todo|unknown)$'

# _catalog_desc_is_placeholder <text> -- true when the marker says nothing.
#
# Empty is the first spelling. The rest is one rule: text with no
# alphanumeric run three characters long has no WORD in it, which makes
# `.`, `-`, `--`, `...` and `?` the placeholder wearing a different hat --
# and a rule people must satisfy gives them a reason to reach for one.
#
# The line is drawn at "has a word in it" rather than at a length on
# purpose. The catalogues carry honest six-character descriptions ("GPU
# on", "vi mode", "--dry-run") that say something the test name does not,
# and this driver's header already argues why a guard whose false
# positives are the good rows is worse than no guard. Whether a sentence
# merely RESTATES the name stays a judgement a reviewer makes; this only
# refuses text that makes no claim at all.
_catalog_desc_is_placeholder() {
  local _text="${1}"
  _text="${_text#"${_text%%[![:space:]]*}"}"
  _text="${_text%"${_text##*[![:space:]]}"}"
  [[ -z "${_text}" ]] && return 0
  [[ "${_text}" =~ [[:alnum:]]{3,} ]] || return 0
  local _lower="${_text,,}"
  [[ "${_lower}" =~ ${_CATALOG_DESC_NON_ANSWERS_RE} ]] && return 0
  return 1
}

# _catalog_desc_spec_files <root> -- every spec file in scope, one per
# line, repo-root-relative.
# Sorted explicitly under LC_ALL=C: this lint runs both in the musl
# test-tools container and on a glibc host, whose collations order
# `log_spec.bats` and `logrotate_spec.bats` oppositely, and a findings list
# that reorders between the two is a diff nobody can read. The globstar
# dance happens in the subshell, so nothing leaks to the caller.
_catalog_desc_spec_files() {
  local _root="$1"
  (
    shopt -s globstar
    local _glob _f
    for _glob in "${_CATALOG_DESC_SCAN_GLOBS[@]}"; do
      for _f in "${_root}"/${_glob}; do
        # `|| continue` and not `&& printf`: under pipefail the loop's
        # status is the last iteration's, so a final non-file match would
        # fail the pipeline and be reported as a broken driver.
        [[ -f "${_f}" ]] || continue
        printf '%s\n' "${_f#"${_root}"/}"
      done
    done
  ) | LC_ALL=C sort
}

# _run_catalog_description -- the dispatcher entry point.
_run_catalog_description() {
  echo "--- Running catalog description lint ---"

  local _root="${REPO_ROOT}"
  if [[ ! -d "${_root}" ]]; then
    _die ci_catalog_description \
      "scan root '${_root}' does not exist or is not a directory -- nothing would be read, so the lint would pass over the whole suite."
    return 1
  fi

  local -a _files=()
  mapfile -t _files < <(_catalog_desc_spec_files "${_root}")
  if (( ${#_files[@]} == 0 )); then
    _die ci_catalog_description \
      "no spec files under '${_root}' (looked for ${_CATALOG_DESC_SCAN_GLOBS[*]}) -- every test would be described vacuously. Point the lint at the repo root, or update the scan globs if the spec tree moved."
    return 1
  fi

  local -a _tests=() _findings=()
  local _blurb='' _rel _rec _line _marked _name _desc _code _detail
  local _total=0 _described=0 _undescribed=0 _hard=0
  local -a _undescribed_lines=() _hard_lines=()

  for _rel in "${_files[@]}"; do
    _spec_markers_scan "${_root}/${_rel}" _tests _findings _blurb
    if (( ${#_findings[@]} > 0 )); then
      for _rec in "${_findings[@]}"; do
        _line="${_rec%%$'\t'*}"
        _detail="${_rec#*$'\t'}"
        _code="${_detail%%$'\t'*}"
        _detail="${_detail#*$'\t'}"
        _hard_lines+=( "${_rel}:${_line}: ${_code} -- ${_detail}" )
        _hard=$(( _hard + 1 ))
      done
    fi
    (( ${#_tests[@]} > 0 )) || continue
    for _rec in "${_tests[@]}"; do
      _total=$(( _total + 1 ))
      _line="${_rec%%$'\t'*}"
      _name="${_rec#*$'\t'}"
      _marked="${_name%%$'\t'*}"
      _name="${_name#*$'\t'}"
      _desc="${_name#*$'\t'}"
      _name="${_name%%$'\t'*}"
      if (( ! _marked )); then
        _undescribed=$(( _undescribed + 1 ))
        _undescribed_lines+=( "${_rel}:${_line}: ${_name}" )
        continue
      fi
      # A marker that is PRESENT and says nothing is not transition debt:
      # somebody wrote it. It fails at any count.
      if _catalog_desc_is_placeholder "${_desc}"; then
        _hard_lines+=( "${_rel}:${_line}: empty-marker -- the '# why:' block above '${_name}' says nothing. A cell with no word in it ('.', '--', '...') and the written-out non-answers ('n/a', 'TBD', 'TODO') are the missing sentence wearing less ink." )
        _hard=$(( _hard + 1 ))
        continue
      fi
      _described=$(( _described + 1 ))
    done
  done

  # Printed on EVERY run, clean or not. The slack is the cost this design
  # accepts (see the header), and a cost nobody can see is one nobody
  # closes.
  printf 'catalog description lint: tests=%d described=%d undescribed=%d ceiling=%d slack=%d (%d spec file(s))\n' \
    "${_total}" "${_described}" "${_undescribed}" \
    "${_CATALOG_DESC_UNDESCRIBED_CEILING}" \
    "$(( _CATALOG_DESC_UNDESCRIBED_CEILING - _undescribed ))" \
    "${#_files[@]}"

  local _over=0
  (( _undescribed > _CATALOG_DESC_UNDESCRIBED_CEILING )) && _over=1

  if (( _hard > 0 )); then
    printf '%s\n' "${_hard_lines[@]}" | LC_ALL=C sort
  fi
  # Listed only when the ceiling is breached: on a clean run this is 2491
  # lines of noise, and when it is breached the author needs to find
  # theirs. No truncation -- a capped list is one somebody's test can fall
  # off the end of.
  if (( _over )); then
    printf '%s\n' "${_undescribed_lines[@]}" | LC_ALL=C sort
  fi

  if (( _hard > 0 || _over )); then
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_catalog_description \
      "${_hard} marker finding(s); ${_undescribed} undescribed test(s) against a ceiling of ${_CATALOG_DESC_UNDESCRIBED_CEILING}. A description is a '# why:' comment block on the lines immediately above the '@test' -- see doc/test/unit.md, 'How this catalogue is maintained'. It answers WHY THIS CASE MATTERS: what it defends, whether it is the load-bearing one, what breaks without it. It does NOT restate what the test does, which the name already says at length. Continuation lines are joined with a single space; a bare '#' line inside the block detaches it, and a block with no '@test' beneath it describes nothing. The ceiling is one number in this driver and it may only ever go DOWN: if this branch added a test, describe it rather than raising the number."
    return 1
  fi

  echo "catalog description lint: clean"
}
