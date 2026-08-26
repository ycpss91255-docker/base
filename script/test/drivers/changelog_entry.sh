#!/usr/bin/env bash
# drivers/changelog_entry.sh - "an [Unreleased] changelog entry is not a PR
# body" per-tool driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_changelog_entry.
#
# Contract: runs INSIDE the ci (test-tools) container where test.sh
# invokes it. References ${REPO_ROOT} (a global exported by test.sh).
# Follows drivers/home_literal.sh conventions (sourced lib, uses
# ${REPO_ROOT}, _log_* / _die, no main).
#
# Why: this repo already decided that the PR body is the canonical decision
# record, enforced by a hook on `gh pr create`. The reasoning, the
# alternatives considered and the measurements belong there, and a
# changelog entry already links to it by number. What drifted is that the
# same prose got pasted into the changelog too -- so the argument lives
# twice, and the changelog copy is the one nobody can read. Measured over
# all 641 bullets in this file's history: median 448 characters, p90 2073,
# and a single unbroken bullet of 6342. A changelog entry answers two
# questions -- what changed, and does it affect me. Not why, and not what
# was rejected.
#
# What is measured, and why it is the whole ENTRY. A per-LINE cap is
# satisfiable by rewrapping: the same 6000 characters folded at 79 columns
# passes it and nothing has improved. So the unit is the entry -- a
# top-level '- ' bullet plus every continuation line and sub-bullet up to
# the next top-level bullet or the next heading -- and whitespace is
# COLLAPSED before counting. Collapsing is what makes the count invariant
# under re-wrapping and re-indentation in BOTH directions: an author is
# never charged for wrapping at 79 columns or for indenting a sub-list, and
# an author never buys budget by doing either. Sub-bullets counting toward
# their parent closes the second escape hatch, chopping one paragraph into
# twenty short nested bullets.
#
# Rejected alternatives:
#   - a per-line cap: gameable by rewrapping, as above.
#   - counting raw bytes including indentation and newlines: it charges for
#     correct wrapping and rewards the single unwrapped line that made the
#     file unreadable to begin with.
#   - excluding sub-bullets from the parent's measure: reopens the
#     re-shaping hatch.
#   - a per-SECTION budget: punishes a release that genuinely carried many
#     small changes, and cannot name the entry at fault.
#   - counting words: the same anti-gaming property, but characters are
#     what make a rendered bullet unscannable, code spans and backticks are
#     real visual weight, and a character count is easier to state and
#     reproduce by hand.
#
# The cap, and the evidence for it. 500 was the opening proposal, defended
# as roughly the median of history. It was tested by writing ten entries in
# the intended style for this cycle's real changes, including the hardest
# ones (a nine-site behavioural fix, a three-layer config chain with a
# deploy refusal, two BREAKING migrations) and including this change's own
# entry. Those ten measured 210-543, mean 406 -- and three of them landed
# just OVER 500. A cap a good entry routinely brushes against is a cap that
# gets muted, so 500 is the wrong number: it fires on the honest version of
# exactly the entries that most need to say something. 700 clears the
# observed honest maximum by 29% while still cutting the offending sections
# (rc4's median entry is 2437) by more than three times. A legitimately
# structured entry -- a short lead plus a four-item migration sub-list,
# which is the shape a whole-entry measure was said to endanger -- measures
# 449, so it fits with room to spare; that case is pinned in the spec.
#
# Scope: the [Unreleased] section ALONE, ending at the next '## [' heading.
# A released section is a historical record and rewriting a shipped entry
# falsifies it. That scoping is also what keeps this lint honest -- it
# governs only the section still being written, so it can never fail on
# something nobody is allowed to fix.
#
# Non-vacuity: a missing file or a missing [Unreleased] heading DIES rather
# than reporting clean. An [Unreleased] section that is present but empty
# is a different thing -- the legitimate state right after a release -- so
# it passes, but it says out loud that it checked nothing, because a green
# line that silently stands for zero inspected entries is the vacuous pass
# this repo keeps having to fix.
#
# Allowlist: an explicit, region-delimited opt-out, the same shape
# home_literal.sh uses. Bracket the entry with
#   <!-- changelog-entry-lint: allow-begin -- <why> -->
#   ...
#   <!-- changelog-entry-lint: allow-end -->
# HTML comments so the markers do not render. This does not re-open the
# rewrapping hole: a marker is a visible line in the diff carrying a stated
# reason, which a reviewer sees, whereas rewrapping is invisible.
# Unbalanced markers (an unterminated begin, an unmatched end) fail the
# lint -- a silently swallowed region would re-open exactly the hole this
# guard closes.

# ── Changelog entry length lint ──────────────────────────────────────────────

# The scanned file and the section, repo-root-relative. Both must exist: a
# missing file or heading would make the scan pass vacuously.
readonly _CHANGELOG_ENTRY_FILE='doc/changelog/CHANGELOG.md'
readonly _CHANGELOG_ENTRY_HEADING='## [Unreleased]'

# The cap, in characters of the whitespace-collapsed entry. See the header
# for how this number was arrived at; it is a constant, not an env
# override, so local and CI cannot disagree and nobody can raise it without
# the change showing up in a diff.
readonly _CHANGELOG_ENTRY_MAX=700

# Region markers for the explicit opt-out (see the header note).
readonly _CHANGELOG_ENTRY_ALLOW_BEGIN='changelog-entry-lint: allow-begin'
readonly _CHANGELOG_ENTRY_ALLOW_END='changelog-entry-lint: allow-end'

# _changelog_entry_measure <line>... -- the entry's length: every line
# stripped, joined with single spaces, internal whitespace runs collapsed.
# This is the wrap-invariant half of the rule and the only place the count
# is defined.
_changelog_entry_measure() {
  local _joined
  _joined="$(printf '%s\n' "$@" | tr -s '[:space:]' ' ')"
  # tr leaves one leading / trailing space where the input had any.
  _joined="${_joined# }"
  _joined="${_joined% }"
  printf '%s' "${#_joined}"
}

_run_changelog_entry() {
  echo "--- Running changelog entry length lint ---"
  local _abs="${REPO_ROOT}/${_CHANGELOG_ENTRY_FILE}"

  if [[ ! -f "${_abs}" ]]; then
    _die ci_changelog_entry \
      "'${_CHANGELOG_ENTRY_FILE}' not found under ${REPO_ROOT} -- the lint would pass vacuously. Point it at the changelog."
    return 1
  fi

  # Read the whole file so an entry can be reported by its real line
  # number, not its offset within the section.
  local -a _lines=()
  mapfile -t _lines < "${_abs}"

  # Locate the section: from the heading to the next '## [' heading (or
  # EOF). Walking past that boundary into a released section is THE failure
  # mode this lint has to avoid, so the end is found explicitly rather than
  # by falling off the end of the file.
  local _i _start=-1 _end="${#_lines[@]}"
  for (( _i = 0; _i < ${#_lines[@]}; _i++ )); do
    if [[ "${_lines[_i]}" == "${_CHANGELOG_ENTRY_HEADING}"* ]]; then
      _start=$(( _i + 1 ))
      break
    fi
  done
  if [[ "${_start}" -lt 0 ]]; then
    _die ci_changelog_entry \
      "'${_CHANGELOG_ENTRY_FILE}' has no '${_CHANGELOG_ENTRY_HEADING}' heading -- the lint would pass vacuously. The file's shape changed; fix the heading or the lint."
    return 1
  fi
  for (( _i = _start; _i < ${#_lines[@]}; _i++ )); do
    if [[ "${_lines[_i]}" == '## ['* ]]; then
      _end="${_i}"
      break
    fi
  done

  local _violations=0

  # Pass 1: the allow regions. Collect the in-region line indices and
  # validate the markers' balance. Marker lines are themselves excluded, so
  # a region never becomes part of an entry.
  local -A _skip=()
  local _in_allow=0 _begin_line=0
  for (( _i = _start; _i < _end; _i++ )); do
    if [[ "${_lines[_i]}" == *"${_CHANGELOG_ENTRY_ALLOW_BEGIN}"* ]]; then
      _in_allow=1
      _begin_line=$(( _i + 1 ))
      _skip["${_i}"]=1
      continue
    fi
    if [[ "${_lines[_i]}" == *"${_CHANGELOG_ENTRY_ALLOW_END}"* ]]; then
      if [[ "${_in_allow}" -eq 0 ]]; then
        printf '%s:%d: unmatched allow-end (no open allow-begin)\n' \
          "${_CHANGELOG_ENTRY_FILE}" "$(( _i + 1 ))"
        _violations=$(( _violations + 1 ))
      fi
      _in_allow=0
      _skip["${_i}"]=1
      continue
    fi
    [[ "${_in_allow}" -eq 1 ]] && _skip["${_i}"]=1
  done
  if [[ "${_in_allow}" -eq 1 ]]; then
    printf '%s:%d: unterminated allow-begin (no closing allow-end)\n' \
      "${_CHANGELOG_ENTRY_FILE}" "${_begin_line}"
    _violations=$(( _violations + 1 ))
  fi

  # Pass 2: split the section into entries and measure each. An entry runs
  # from its top-level bullet to the next top-level bullet, the next
  # heading, or the end of the list -- a blank line followed by a line that
  # is neither indented nor a bullet. Indented lines and nested bullets
  # belong to the entry above them, which is what makes re-shaping prose
  # into a sub-list cost the same as leaving it in the paragraph.
  local _entries=0 _j _k _len _label
  local -a _body=()
  for (( _i = _start; _i < _end; _i++ )); do
    [[ -n "${_skip[${_i}]:-}" ]] && continue
    [[ "${_lines[_i]}" =~ ^-\  ]] || continue

    _body=("${_lines[_i]}")
    for (( _j = _i + 1; _j < _end; _j++ )); do
      [[ -n "${_skip[${_j}]:-}" ]] && continue
      [[ "${_lines[_j]}" == '#'* ]] && break
      [[ "${_lines[_j]}" =~ ^-\  ]] && break
      if [[ -z "${_lines[_j]// }" ]]; then
        # A blank line continues the entry only if the next non-blank line
        # is indented: that is a loose list item, not a new paragraph.
        for (( _k = _j + 1; _k < _end; _k++ )); do
          [[ -n "${_skip[${_k}]:-}" ]] && continue
          [[ -n "${_lines[_k]// }" ]] && break
        done
        [[ "${_k}" -ge "${_end}" ]] && break
        [[ "${_lines[_k]}" == '#'* ]] && break
        [[ "${_lines[_k]}" =~ ^-\  ]] && break
        [[ "${_lines[_k]}" =~ ^[[:space:]] ]] || break
        continue
      fi
      _body+=("${_lines[_j]}")
    done

    _entries=$(( _entries + 1 ))
    _len="$(_changelog_entry_measure "${_body[@]}")"
    if [[ "${_len}" -gt "${_CHANGELOG_ENTRY_MAX}" ]]; then
      _label="${_body[0]:0:72}"
      printf '%s:%d: %d chars (max %d) -- %s\n' \
        "${_CHANGELOG_ENTRY_FILE}" "$(( _i + 1 ))" \
        "${_len}" "${_CHANGELOG_ENTRY_MAX}" "${_label}"
      _violations=$(( _violations + 1 ))
    fi
    _i=$(( _j - 1 ))
  done

  if [[ "${_violations}" -gt 0 ]]; then
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_changelog_entry \
      "${_violations} over-long entry / unbalanced allow marker in '${_CHANGELOG_ENTRY_HEADING}'. An entry answers what changed and whether it affects the reader, in at most ${_CHANGELOG_ENTRY_MAX} characters measured over the whole entry with whitespace collapsed -- so rewrapping it or splitting it into sub-bullets does not help. The reasoning, the alternatives and the measurements belong in the PR the entry already links to. A genuinely exceptional entry opts out by bracketing it with '<!-- ${_CHANGELOG_ENTRY_ALLOW_BEGIN} -- <why> -->' / '<!-- ${_CHANGELOG_ENTRY_ALLOW_END} -->'."
    return 1
  fi

  if [[ "${_entries}" -eq 0 ]]; then
    # Legitimate right after a release. Said out loud so a green line is
    # never read as a green verdict over entries that were never there.
    echo "changelog entry lint: '${_CHANGELOG_ENTRY_HEADING}' holds no entries -- nothing to check"
    return 0
  fi
  echo "changelog entry lint: clean (${_entries} entries, max ${_CHANGELOG_ENTRY_MAX} chars)"
}
