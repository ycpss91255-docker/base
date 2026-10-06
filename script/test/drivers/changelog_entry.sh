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
# The same rule applied line by line: EVERY non-blank line of the section
# must end up inside some entry, or be a heading, or sit in an allow
# region. A line that is none of those is text the parser did not
# recognise -- '* ' / '+ ' bullets, an indented '- ', a stray paragraph --
# and it fails the lint by name. Without that, an entry written with a '*'
# is not an entry, so the section measures nothing and reports either
# "holds no entries" or, with one honest entry above it, an affirmative
# "clean (1 entries)". Both are the vacuous pass wearing a green line. The
# clean line therefore states what was actually measured: entries checked
# AND entries an allow region suppressed, so zero checked is never printed
# as zero present.
#
# Fenced code blocks are structurally INERT. Inside ``` / ~~~ a '## [' is
# an example of a heading and a '- ' is an example of a bullet, so neither
# may move the section boundary or open an entry; the text still counts
# toward the entry it sits under, because fencing prose must not buy any
# budget either. This file documents its own format in fenced examples, so
# the case is not hypothetical: the convention note's ```markdown block is
# one edit away from showing the surrounding heading.
#
# A second defect the same walk can see for free: an ORPHANED WRAP LINE.
# An entry re-wrapped by hand (a phrase edited, the paragraph not re-flowed)
# leaves a single word alone on its own line above the rest of the same
# paragraph. Markdown collapses it, so nothing renders wrong and the length
# measure -- which collapses whitespace on purpose -- cannot see it either;
# it is visible only in the source, which is where the file is read while it
# is being written. The rule is deliberately narrow: the line must hold
# exactly one word, the SOURCE line immediately below it must be more prose
# of the same paragraph, and the two must FIT on one line -- an orphan is a
# word that could have been joined downward and was not. That last clause
# is what keeps an unbreakable token (a long URL, a 60-character code span)
# off the report: it is alone on its line because nothing else fits there,
# which is wrapping working, not wrapping skipped. A one-word final line, a
# table row, an HTML comment and anything a fence made inert are left alone
# too, because none of them is a paragraph that failed to re-flow. Scope is
# [Unreleased] with everything else here: a shipped entry is history.
#
# Allowlist: an explicit, region-delimited opt-out, the same shape
# home_literal.sh uses. Bracket the entry with
#   <!-- changelog-entry-lint: allow-begin -- <why> -->
#   ...
#   <!-- changelog-entry-lint: allow-end -->
# HTML comments so the markers do not render. This does not re-open the
# rewrapping hole: a marker is a visible line in the diff carrying a stated
# reason, which a reviewer sees, whereas rewrapping is invisible.
# Unbalanced markers (an unterminated begin, an unmatched end, both on one
# line) fail the lint -- a silently swallowed region would re-open exactly
# the hole this guard closes.
#
# A marker is recognised only where the line IS a lone HTML comment, never
# where it merely CONTAINS the string. The entry that documents this
# escape hatch has to quote it, and the convention note above [Unreleased]
# hands contributors the exact text to paste; a substring match turns that
# entry into an unterminated region -- a false failure on a clean file
# that also stops the scan dead. And an unterminated begin, when it is
# real, is reported WITHOUT suppressing what follows: one run should name
# the dangling marker and the entries it was hiding, not trade one for the
# other.

# Two more shapes this lint refuses, neither of them about length. Both
# come out of one mechanism. Landing branches serially against `strict`
# protection means every branch merges origin/main into itself, and when
# two branches each APPEND to the [Unreleased] section git resolves the
# append by keeping BOTH sides. That is not a conflict, so nothing prompts
# a human: the section quietly grows a second verbatim copy of an entry,
# or a second '### <category>' heading. Both had shipped on main by the
# time this was written, and the same shape had produced a duplicated
# entry four times in one cycle, caught by eye every time.
#
#   - A DUPLICATE ENTRY: a lead bullet whose whitespace-collapsed text is
#     byte-identical to a lead bullet already opened in the same release
#     block. The unit is the LEAD bullet, not the whole entry: a copy that
#     one side later edits -- a typo fixed in the body, a sentence added
#     -- still opens with the same sentence, so a rule demanding the whole
#     entry match is a rule the first edit mutes. The whole collapsed
#     entry is compared too, as a fallback: that is what still catches a
#     copy someone re-wrapped at a different column, where the lead LINE
#     is no longer the same string. Comparing collapsed text rather than
#     raw lines is what makes indentation and a stripped trailing space
#     irrelevant to both.
#   - A REPEATED CATEGORY HEADING: '### <category>' opening twice inside
#     one '## [...]' block. The block stops reading as one grouped list --
#     a reader scanning '### Added' finds half the additions and no sign
#     the other half exists.
#
# Both report BOTH line numbers, the offending line and the line it
# duplicates. The fix is a comparison of two places, and a message naming
# one of them leaves the reader to find the other by eye, which is the
# manual step this check exists to remove.
#
# Both are scoped to [Unreleased] for the reason the cap is: a released
# section is a historical record, and a duplicate that shipped is a fact
# about what shipped. Rewriting it falsifies the record, so a duplicate
# planted in a released section is deliberately NOT a finding.

# ── Changelog entry length lint ──────────────────────────────────────────────

# The scanned tree and the section, repo-root-relative. The FILE is
# resolved, not fixed: the changelog is one file per 0.Y series
# (drivers/changelog_layout.sh owns that layout), so `[Unreleased]` lives in
# whichever series is currently being written, and doc/changelog/CHANGELOG.md
# is now the generated index -- a file that carries no entries at all, so a
# lint still pinned to it would report clean over a file that can never hold
# an entry. The heading is the address; the filename is not.
readonly _CHANGELOG_ENTRY_DIR='doc/changelog'
readonly _CHANGELOG_ENTRY_HEADING='## [Unreleased]'

# The locked category roster and the two places it has to agree with.
#
# The roster itself lives in ONE file, script/release/changelog_categories.sh,
# because a list written in each consumer drifts one consumer at a time. Its
# three readers are this lint, script/release/release_notes.sh (which orders
# a release page's merged sections by it) and doc/changelog/CONVENTIONS.md
# (which prints it for contributors). The first two SOURCE it, so they cannot
# disagree; the third is prose and can, which is why this lint also compares
# the printed roster against the sourced one. A roster nothing checks is the
# defect the twenty headings came from.
readonly _CHANGELOG_ENTRY_ROSTER='script/release/changelog_categories.sh'
readonly _CHANGELOG_ENTRY_CONVENTIONS='doc/changelog/CONVENTIONS.md'
readonly _CHANGELOG_ENTRY_ROSTER_BEGIN='changelog-categories: begin'
readonly _CHANGELOG_ENTRY_ROSTER_END='changelog-categories: end'

# Resolved by _changelog_entry_locate at the top of every run, so every
# message below can still name a real file and line.
_CHANGELOG_ENTRY_FILE=''

# Resolved by _changelog_entry_bounds: the first line INSIDE the section and
# one past its last line. Globals rather than return values because both the
# lint and the folder below read them, and a second copy of the boundary rule
# is a second answer to "where does [Unreleased] end".
_CHANGELOG_ENTRY_START=-1
_CHANGELOG_ENTRY_END=0

# Recorded by _changelog_entry_allow_map: the 1-based line of every malformed
# allow marker it met, and of an unterminated allow-begin (0 for none). The
# lint prints them as findings; the folder refuses on them.
declare -ga _CHANGELOG_ENTRY_MARKER_BOTH=()
declare -ga _CHANGELOG_ENTRY_MARKER_STRAY_END=()
_CHANGELOG_ENTRY_MARKER_UNTERMINATED=0

# The cap, in characters of the whitespace-collapsed entry. See the header
# for how this number was arrived at; it is a constant, not an env
# override, so local and CI cannot disagree and nobody can raise it without
# the change showing up in a diff.
readonly _CHANGELOG_ENTRY_MAX=700

# The column the file wraps at, used ONLY to decide whether an orphaned
# word could have been joined to the line below it. It is not a line-length
# cap -- a per-line cap was rejected outright (see the header) -- and no
# line is ever failed for being long.
readonly _CHANGELOG_ENTRY_WRAP=79

# Region markers for the explicit opt-out (see the header note).
readonly _CHANGELOG_ENTRY_ALLOW_BEGIN='changelog-entry-lint: allow-begin'
readonly _CHANGELOG_ENTRY_ALLOW_END='changelog-entry-lint: allow-end'

# _changelog_entry_measure <line>... -- the entry's length in CHARACTERS:
# every line stripped, joined with single spaces, internal whitespace runs
# collapsed. This is the wrap-invariant half of the rule and the only place
# the count is defined.
#
# Characters, and the same number in every environment. bash's
# parameter-length expansion counts characters where the locale is UTF-8
# and BYTES where it is C/POSIX, and the two ways this lint runs do not
# share a locale: the lint-static CI job runs on a bare runner with LANG
# unset (glibc, so POSIX, so bytes) while the local gate runs inside the
# musl test-tools image (which falls back to UTF-8, so characters). Same
# file, opposite verdicts, and nothing in the diff to point at. Counting
# characters rather than bytes is also the fairer of the two: an entry that
# legitimately quotes a path or a heading from the ja / zh-TW / zh-CN
# guides would otherwise be charged three times over for it.
#
# So the count is derived from the bytes, with no locale involved at all:
# in UTF-8 every byte except a continuation byte (0x80-0xBF) starts exactly
# one character, so dropping those and counting what is left IS the
# character count -- and `wc -c` counts bytes by definition, where the
# shell's own expansion would not. Pinning LC_ALL for the two filters keeps
# them byte-oriented too, which is what makes dropping the range safe.
_changelog_entry_measure() {
  local _chars
  _chars="$(_changelog_entry_collapse "$@" | LC_ALL=C tr -d '\200-\277' | wc -c)"
  printf '%s' "$(( _chars ))"
}

# _changelog_entry_collapse <line>... -- the lines stripped, joined with
# single spaces and with internal whitespace runs collapsed. The one
# definition of "the same text" in this driver: the length cap counts what
# this returns, and the duplicate checks compare what it returns. They have
# to agree, because an author who re-wraps a line must neither buy budget
# nor turn a duplicate into two distinct entries.
_changelog_entry_collapse() {
  local _joined
  _joined="$(printf '%s\n' "$@" | LC_ALL=C tr -s '[:space:]' ' ')"
  # tr leaves one leading / trailing space where the input had any.
  _joined="${_joined# }"
  _joined="${_joined% }"
  printf '%s' "${_joined}"
}

# _changelog_entry_trim <line> -- the line with leading and trailing
# whitespace removed.
_changelog_entry_trim() {
  local _line="${1}"
  _line="${_line#"${_line%%[![:space:]]*}"}"
  _line="${_line%"${_line##*[![:space:]]}"}"
  printf '%s' "${_line}"
}

# _changelog_entry_wrappable <line> -- is the line ordinary wrapped prose,
# i.e. the kind of line an orphaned word can be stranded on? A blank line
# is not; nor is a table row (`|---|---|` is one "word" and always will be)
# nor an HTML comment (the allow markers are single-purpose lines). Fenced
# lines are excluded by the caller, which is the only place that knows.
_changelog_entry_wrappable() {
  local _trimmed
  _trimmed="$(_changelog_entry_trim "${1}")"
  [[ -n "${_trimmed}" ]] || return 1
  [[ "${_trimmed}" == '|'* ]] && return 1
  [[ "${_trimmed}" == '<!--'* ]] && return 1
  return 0
}

# _changelog_entry_marker <line> -- 'begin', 'end', 'both' or nothing:
# which allow marker the line IS. Recognition is anchored on purpose. A
# line that merely MENTIONS a marker is prose -- and the entry announcing a
# change to this lint is the one entry guaranteed to mention both, because
# the convention note tells contributors to paste exactly that text. Under
# a substring match such an entry opens a region that never closes: the
# file fails for a marker nobody wrote, and every entry after it goes
# unmeasured. So a marker is a LONE HTML comment carrying exactly one of
# the two strings; a comment carrying both is refused rather than resolved
# in favour of either.
_changelog_entry_marker() {
  local _trimmed _begin=0 _end=0
  _trimmed="$(_changelog_entry_trim "${1}")"
  if [[ "${_trimmed}" != '<!--'*'-->' ]]; then
    return 0
  fi
  # Two comments on one line is not a marker line either: whatever else it
  # is, it is not the one-marker-per-line shape a region is built from.
  if [[ "${_trimmed}" == *'<!--'*'<!--'* ]]; then
    return 0
  fi
  if [[ "${_trimmed}" == *"${_CHANGELOG_ENTRY_ALLOW_BEGIN}"* ]]; then
    _begin=1
  fi
  if [[ "${_trimmed}" == *"${_CHANGELOG_ENTRY_ALLOW_END}"* ]]; then
    _end=1
  fi
  if [[ "${_begin}" -eq 1 && "${_end}" -eq 1 ]]; then
    printf 'both'
  elif [[ "${_begin}" -eq 1 ]]; then
    printf 'begin'
  elif [[ "${_end}" -eq 1 ]]; then
    printf 'end'
  fi
}

# _changelog_entry_fences <assoc-array-name> <line>... -- fill the named
# associative array with the index of every line a fenced code block makes
# structurally inert: the ``` / ~~~ delimiters and everything between them.
# An unterminated fence runs to the end of the file, as CommonMark says.
_changelog_entry_fences() {
  local -n _fm_out="${1}"
  shift
  local -a _fm_lines=("$@")
  local _fm_i _fm_trimmed _fm_open=''
  _fm_out=()
  for (( _fm_i = 0; _fm_i < ${#_fm_lines[@]}; _fm_i++ )); do
    _fm_trimmed="$(_changelog_entry_trim "${_fm_lines[_fm_i]}")"
    if [[ -z "${_fm_open}" ]]; then
      if [[ "${_fm_trimmed}" =~ ^(\`\`\`+|~~~+) ]]; then
        _fm_open="${BASH_REMATCH[1]}"
        _fm_out["${_fm_i}"]=1
      fi
      continue
    fi
    _fm_out["${_fm_i}"]=1
    # A closing fence is the same character, at least as long as the
    # opening one, and carries no info string.
    if [[ "${_fm_trimmed}" =~ ^(\`\`\`+|~~~+)$ ]] \
      && [[ "${BASH_REMATCH[1]:0:1}" == "${_fm_open:0:1}" ]] \
      && [[ "${#BASH_REMATCH[1]}" -ge "${#_fm_open}" ]]; then
      _fm_open=''
    fi
  done
}

# _changelog_entry_carries_heading <file> -- does the file carry the
# heading at column 0, OUTSIDE a fenced code block?
#
# The fence state is not decoration here. doc/changelog/CONVENTIONS.md is
# the document whose entire subject is how to write an entry, so it is the
# document that SHOWS the heading, in a ```markdown example. A plain text
# match reads that example as a second live series and dies saying there
# are two -- and the only way to clear it would be to delete the example
# from the document that exists to carry it. Every other markdown scan in
# this driver and its two siblings already treats a fence as inert.
_changelog_entry_carries_heading() {
  local -a _cl_lines=()
  local -A _cl_fenced=()
  local _cl_i
  mapfile -t _cl_lines < "${1}"
  _changelog_entry_fences _cl_fenced "${_cl_lines[@]}"
  for (( _cl_i = 0; _cl_i < ${#_cl_lines[@]}; _cl_i++ )); do
    if [[ -z "${_cl_fenced[${_cl_i}]:-}" ]] \
      && [[ "${_cl_lines[_cl_i]}" == "${_CHANGELOG_ENTRY_HEADING}" ]]; then
      return 0
    fi
  done
  return 1
}

# _changelog_entry_locate -- set _CHANGELOG_ENTRY_FILE to the repo-relative
# path of the ONE file under doc/changelog/ carrying the heading, or fail
# saying which way it went wrong.
#
# Zero and two are different defects and get different sentences. Zero means
# nothing is being written and every future entry goes unmeasured; two means
# there are two places to write the next entry and two places a serial merge
# can keep, and measuring whichever the glob reaches first would report
# clean over the other. Neither may be resolved by picking one.
_changelog_entry_locate() {
  local _dir="${REPO_ROOT}/${_CHANGELOG_ENTRY_DIR}" _file _found=''
  local _count=0
  if [[ ! -d "${_dir}" ]]; then
    _die ci_changelog_entry \
      "'${_CHANGELOG_ENTRY_DIR}' not found under ${REPO_ROOT} -- the lint would pass vacuously. Point it at the changelog tree."
    return 1
  fi
  for _file in "${_dir}"/*.md; do
    [[ -f "${_file}" ]] || continue
    _changelog_entry_carries_heading "${_file}" || continue
    _count=$(( _count + 1 ))
    _found+="${_CHANGELOG_ENTRY_DIR}/$(basename "${_file}") "
  done
  if [[ "${_count}" -eq 0 ]]; then
    _die ci_changelog_entry \
      "no file under '${_CHANGELOG_ENTRY_DIR}' carries a '${_CHANGELOG_ENTRY_HEADING}' heading -- the lint would pass vacuously. The changelog is one file per 0.Y series and the heading lives in the series being written; restore it or fix the lint."
    return 1
  fi
  if [[ "${_count}" -gt 1 ]]; then
    _die ci_changelog_entry \
      "'${_CHANGELOG_ENTRY_HEADING}' is carried by ${_count} files (${_found% }) -- there is one live series, so there is one place the next entry goes. Measuring whichever file the glob reaches first would report clean over the other."
    return 1
  fi
  _CHANGELOG_ENTRY_FILE="${_found% }"
}

# _changelog_entry_documented_roster -- the category names
# doc/changelog/CONVENTIONS.md prints between its roster markers, one per
# line. A name is a backticked item in a top-level list there; anything else
# between the markers is prose about the roster, not part of it.
_changelog_entry_documented_roster() {
  local _file="${1}" _line _in=0
  while IFS= read -r _line; do
    if [[ "${_line}" == *"${_CHANGELOG_ENTRY_ROSTER_BEGIN}"* ]]; then
      _in=1
      continue
    fi
    if [[ "${_line}" == *"${_CHANGELOG_ENTRY_ROSTER_END}"* ]]; then
      _in=0
      continue
    fi
    [[ "${_in}" -eq 1 ]] || continue
    [[ "${_line}" =~ ^-\ \`([A-Za-z]+)\` ]] || continue
    printf '%s\n' "${BASH_REMATCH[1]}"
  done < "${_file}"
}

# _changelog_entry_in_roster <category> -- is the heading one of the seven?
_changelog_entry_in_roster() {
  local _want="${1}" _cat
  for _cat in "${CHANGELOG_CATEGORIES[@]}"; do
    [[ "${_cat}" == "${_want}" ]] && return 0
  done
  return 1
}

# _changelog_entry_bounds <lines-array-name> <fenced-array-name> -- resolve
# the section into _CHANGELOG_ENTRY_START (the first line INSIDE it) and
# _CHANGELOG_ENTRY_END (one past its last line). Dies when the heading is
# gone, because a lint with no section passes vacuously.
#
# Shared with the folder below rather than copied into it. The folder
# REWRITES the range this lint measures, so a boundary the two disagreed
# about is either a folder that edits a released section or a lint that
# reports clean over lines the folder moved. One reader, one answer.
#
# Walking past the boundary into a released section is THE failure mode
# here, so the end is found explicitly rather than by falling off the end of
# the file.
_changelog_entry_bounds() {
  local -n _cb_lines="${1}"
  local -n _cb_fenced="${2}"
  local _cb_i
  _CHANGELOG_ENTRY_START=-1
  _CHANGELOG_ENTRY_END="${#_cb_lines[@]}"
  for (( _cb_i = 0; _cb_i < ${#_cb_lines[@]}; _cb_i++ )); do
    if [[ -n "${_cb_fenced[${_cb_i}]:-}" ]]; then
      continue
    fi
    if [[ "${_cb_lines[_cb_i]}" == "${_CHANGELOG_ENTRY_HEADING}"* ]]; then
      _CHANGELOG_ENTRY_START=$(( _cb_i + 1 ))
      break
    fi
  done
  if [[ "${_CHANGELOG_ENTRY_START}" -lt 0 ]]; then
    _die ci_changelog_entry \
      "'${_CHANGELOG_ENTRY_FILE}' has no '${_CHANGELOG_ENTRY_HEADING}' heading -- the lint would pass vacuously. The file's shape changed; fix the heading or the lint."
    return 1
  fi
  for (( _cb_i = _CHANGELOG_ENTRY_START; _cb_i < ${#_cb_lines[@]}; _cb_i++ )); do
    if [[ -n "${_cb_fenced[${_cb_i}]:-}" ]]; then
      continue
    fi
    if [[ "${_cb_lines[_cb_i]}" == '## ['* ]]; then
      _CHANGELOG_ENTRY_END="${_cb_i}"
      break
    fi
    # The compare-link block ends the section too. In a series file
    # [Unreleased] is the LAST section, so a boundary that only knows about
    # the next '## [' runs to end of file and swallows the link
    # definitions -- every one of which is then a line no entry measures,
    # reported as unrecognised content. A link definition is reference
    # data, not an entry.
    if [[ "${_cb_lines[_cb_i]}" =~ ^\[[^]]+\]:[[:space:]] ]]; then
      _CHANGELOG_ENTRY_END="${_cb_i}"
      break
    fi
  done
}

# _changelog_entry_allow_map <skip-array-name> <lines-array-name>
# <fenced-array-name> -- fill the named associative array with the index of
# every line an allow region makes invisible, over the range
# _changelog_entry_bounds resolved. Marker lines are themselves in the map,
# so a region never becomes part of an entry.
#
# It REPORTS nothing. The three ways the markers can be malformed are
# recorded in _CHANGELOG_ENTRY_MARKER_BOTH and
# _CHANGELOG_ENTRY_MARKER_STRAY_END (1-based line numbers) and
# _CHANGELOG_ENTRY_MARKER_UNTERMINATED (a 1-based line number, or 0), and
# the two callers do different things with them: the lint turns each into a
# finding, the folder refuses outright, because a region whose extent is
# ambiguous is a region a rewriter must not guess at.
_changelog_entry_allow_map() {
  local -n _am_skip="${1}"
  local -n _am_lines="${2}"
  local -n _am_fenced="${3}"
  local _am_i _am_in=0 _am_begin_line=0 _am_marker _am_idx
  local -a _am_open=() _am_hidden=()
  _am_skip=()
  _CHANGELOG_ENTRY_MARKER_BOTH=()
  _CHANGELOG_ENTRY_MARKER_STRAY_END=()
  _CHANGELOG_ENTRY_MARKER_UNTERMINATED=0
  for (( _am_i = _CHANGELOG_ENTRY_START; _am_i < _CHANGELOG_ENTRY_END; _am_i++ )); do
    if [[ -n "${_am_fenced[${_am_i}]:-}" ]]; then
      continue
    fi
    _am_marker="$(_changelog_entry_marker "${_am_lines[_am_i]}")"
    case "${_am_marker}" in
      both)
        _CHANGELOG_ENTRY_MARKER_BOTH+=( "$(( _am_i + 1 ))" )
        _am_hidden+=( "${_am_i}" )
        continue
        ;;
      begin)
        _am_in=1
        _am_begin_line=$(( _am_i + 1 ))
        _am_open=()
        _am_hidden+=( "${_am_i}" )
        continue
        ;;
      end)
        if [[ "${_am_in}" -eq 0 ]]; then
          _CHANGELOG_ENTRY_MARKER_STRAY_END+=( "$(( _am_i + 1 ))" )
        fi
        _am_in=0
        _am_hidden+=( "${_am_open[@]}" "${_am_i}" )
        _am_open=()
        continue
        ;;
    esac
    if [[ "${_am_in}" -eq 1 ]]; then
      _am_open+=( "${_am_i}" )
    fi
  done
  # An unterminated begin swallowed the whole rest of the section. Hand
  # those lines back -- _am_open is dropped rather than merged -- because a
  # dangling marker is one thing to report, not a licence to stop measuring,
  # and an author who has to fix the marker before the entries even become
  # visible pays for the same mistake twice. The marker line itself stays
  # hidden: whatever else it is, it is not an entry.
  if [[ "${_am_in}" -eq 1 ]]; then
    _CHANGELOG_ENTRY_MARKER_UNTERMINATED="${_am_begin_line}"
  fi
  for _am_idx in "${_am_hidden[@]}"; do
    _am_skip["${_am_idx}"]=1
  done
}

_run_changelog_entry() {
  echo "--- Running changelog entry lint (length / duplicates / categories) ---"

  # The roster, sourced rather than repeated. Missing is fatal: with no
  # roster every heading is off-roster or none is, and either way the
  # category rule below would be deciding on a list nobody wrote.
  local _roster_abs="${REPO_ROOT}/${_CHANGELOG_ENTRY_ROSTER}"
  if [[ ! -f "${_roster_abs}" ]]; then
    _die ci_changelog_entry \
      "'${_CHANGELOG_ENTRY_ROSTER}' not found under ${REPO_ROOT} -- the locked category set is defined there and this lint enforces it, so without it the category rule would pass over any heading at all."
    return 1
  fi
  # shellcheck source=script/release/changelog_categories.sh
  source "${_roster_abs}"

  _changelog_entry_locate || return 1
  local _abs="${REPO_ROOT}/${_CHANGELOG_ENTRY_FILE}"

  # Read the whole file so an entry can be reported by its real line
  # number, not its offset within the section.
  local -a _lines=()
  mapfile -t _lines < "${_abs}"

  # Which lines a fenced code block makes inert. Resolved once, up front,
  # because every scan below has to agree about it -- a boundary that
  # counts a fenced heading and an entry walker that does not would
  # disagree about what the section even is.
  local -A _fenced=()
  _changelog_entry_fences _fenced "${_lines[@]}"

  # Locate the section. The reader is shared with the folder below, which
  # rewrites exactly the range measured here.
  _changelog_entry_bounds _lines _fenced || return 1
  local _i _start="${_CHANGELOG_ENTRY_START}" _end="${_CHANGELOG_ENTRY_END}"

  local _violations=0

  # Pass 1: the allow regions. The map is built by the reader the folder
  # shares, so the two cannot disagree about which lines are exempt; what
  # differs is the verdict, and this is the half that reports.
  local -A _skip=()
  _changelog_entry_allow_map _skip _lines _fenced
  local _marker_line
  for _marker_line in "${_CHANGELOG_ENTRY_MARKER_BOTH[@]}"; do
    printf '%s:%d: malformed allow marker (allow-begin and allow-end in one comment)\n' \
      "${_CHANGELOG_ENTRY_FILE}" "${_marker_line}"
    _violations=$(( _violations + 1 ))
  done
  for _marker_line in "${_CHANGELOG_ENTRY_MARKER_STRAY_END[@]}"; do
    printf '%s:%d: unmatched allow-end (no open allow-begin)\n' \
      "${_CHANGELOG_ENTRY_FILE}" "${_marker_line}"
    _violations=$(( _violations + 1 ))
  done
  if [[ "${_CHANGELOG_ENTRY_MARKER_UNTERMINATED}" -gt 0 ]]; then
    printf '%s:%d: unterminated allow-begin (no closing allow-end)\n' \
      "${_CHANGELOG_ENTRY_FILE}" "${_CHANGELOG_ENTRY_MARKER_UNTERMINATED}"
    _violations=$(( _violations + 1 ))
  fi

  # How many entries the regions took off the table. Reported alongside the
  # count that WAS checked, so a suppressed section never reads as an empty
  # one.
  local _idx _suppressed=0
  for _idx in "${!_skip[@]}"; do
    if [[ "${_lines[_idx]}" =~ ^-\  ]]; then
      _suppressed=$(( _suppressed + 1 ))
    fi
  done

  # Pass 2: split the section into entries and measure each. An entry runs
  # from its top-level bullet to the next top-level bullet, the next
  # heading, or the end of the list -- a blank line followed by a line that
  # is neither indented nor a bullet. Indented lines and nested bullets
  # belong to the entry above them, which is what makes re-shaping prose
  # into a sub-list cost the same as leaving it in the paragraph.
  #
  # Structure -- what opens an entry, what ends one -- is read only OUTSIDE
  # a fenced block. Inside one the same characters are an example of
  # markdown, so they neither start nor stop anything, while the text still
  # joins the entry it sits under.
  local _entries=0 _j _k _len _label _lead _full
  local -A _seen=()
  # <collapsed text> -> the 1-based line the entry first opened on, so a
  # repeat can name the line it repeats rather than just itself. Keyed on
  # the lead bullet and, as a fallback, on the whole entry.
  local -A _lead_first=()
  local -A _full_first=()
  local -a _body=()
  local -a _body_idx=()
  for (( _i = _start; _i < _end; _i++ )); do
    [[ -n "${_skip[${_i}]:-}" ]] && continue
    [[ -n "${_fenced[${_i}]:-}" ]] && continue
    [[ "${_lines[_i]}" =~ ^-\  ]] || continue

    _body=("${_lines[_i]}")
    _body_idx=("${_i}")
    _seen["${_i}"]=1
    for (( _j = _i + 1; _j < _end; _j++ )); do
      [[ -n "${_skip[${_j}]:-}" ]] && continue
      if [[ -z "${_fenced[${_j}]:-}" ]]; then
        [[ "${_lines[_j]}" == '#'* ]] && break
        [[ "${_lines[_j]}" =~ ^-\  ]] && break
        if [[ -z "${_lines[_j]// }" ]]; then
          # A blank line continues the entry only if the next non-blank
          # line is indented -- that is a loose list item, not a new
          # paragraph -- or fenced, which is a code block belonging to the
          # entry that introduced it.
          for (( _k = _j + 1; _k < _end; _k++ )); do
            [[ -n "${_skip[${_k}]:-}" ]] && continue
            [[ -n "${_lines[_k]// }" ]] && break
          done
          [[ "${_k}" -ge "${_end}" ]] && break
          if [[ -z "${_fenced[${_k}]:-}" ]]; then
            [[ "${_lines[_k]}" == '#'* ]] && break
            [[ "${_lines[_k]}" =~ ^-\  ]] && break
            [[ "${_lines[_k]}" =~ ^[[:space:]] ]] || break
          fi
          continue
        fi
      fi
      _body+=("${_lines[_j]}")
      _body_idx+=("${_j}")
      _seen["${_j}"]=1
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

    # The same lead bullet twice in one release block is a duplicated
    # entry, not two entries: an append-vs-append merge keeps both sides
    # without conflicting, so this arrives with nothing for a reviewer to
    # resolve. The whole-entry key behind it catches the copy that was
    # re-wrapped, where the lead LINE stopped being the same string. Both
    # compare collapsed text, so indentation never decides the answer.
    _lead="$(_changelog_entry_collapse "${_lines[_i]}")"
    _full="$(_changelog_entry_collapse "${_body[@]}")"
    if [[ -n "${_lead_first["${_lead}"]:-}" ]]; then
      printf '%s:%d: duplicate entry -- this lead bullet already opened at %s:%s -- %s\n' \
        "${_CHANGELOG_ENTRY_FILE}" "$(( _i + 1 ))" \
        "${_CHANGELOG_ENTRY_FILE}" "${_lead_first["${_lead}"]}" \
        "${_body[0]:0:72}"
      _violations=$(( _violations + 1 ))
    elif [[ -n "${_full_first["${_full}"]:-}" ]]; then
      printf '%s:%d: duplicate entry -- the same text, re-wrapped, already opened at %s:%s -- %s\n' \
        "${_CHANGELOG_ENTRY_FILE}" "$(( _i + 1 ))" \
        "${_CHANGELOG_ENTRY_FILE}" "${_full_first["${_full}"]}" \
        "${_body[0]:0:72}"
      _violations=$(( _violations + 1 ))
    else
      _lead_first["${_lead}"]=$(( _i + 1 ))
      _full_first["${_full}"]=$(( _i + 1 ))
    fi
    # Orphaned wrap lines within this entry. A word is orphaned when it is
    # alone on its line, the very next SOURCE line carries more of the same
    # paragraph, and the two would fit on one line. Contiguity separates
    # "the paragraph was not re-flowed" from "the paragraph ended on a short
    # line"; the fit separates it from "nothing else fits on that line".
    # See the header note.
    local _b _next _orphan _joined
    local -a _words=()
    for (( _b = 1; _b < ${#_body[@]}; _b++ )); do
      [[ -n "${_fenced[${_body_idx[_b]}]:-}" ]] && continue
      _changelog_entry_wrappable "${_body[_b]}" || continue
      # read -r -a, not a pipeline: nothing here may own an exit status
      # that depends on how two processes were scheduled.
      read -r -a _words <<< "${_body[_b]}"
      [[ "${#_words[@]}" -eq 1 ]] || continue
      _next=$(( _b + 1 ))
      [[ "${_next}" -lt "${#_body[@]}" ]] || continue
      [[ "${_body_idx[_next]}" -eq $(( _body_idx[_b] + 1 )) ]] || continue
      [[ -n "${_fenced[${_body_idx[_next]}]:-}" ]] && continue
      _changelog_entry_wrappable "${_body[_next]}" || continue
      # Could the word have moved down onto the next line? Indentation is
      # counted (it is what the wrapped line really costs), the next line
      # is measured trimmed (its own indent does not double up).
      _joined="$(_changelog_entry_trim "${_body[_next]}")"
      (( ${#_body[_b]} + 1 + ${#_joined} <= _CHANGELOG_ENTRY_WRAP )) || continue
      _orphan="${_words[0]}"
      printf "%s:%d: orphaned wrap line -- '%s' sits alone above the rest of its paragraph; re-wrap the entry\n" \
        "${_CHANGELOG_ENTRY_FILE}" "$(( _body_idx[_b] + 1 ))" "${_orphan}"
      _violations=$(( _violations + 1 ))
    done
    _i=$(( _j - 1 ))
  done

  # Pass 3: every line has to be accounted for. Anything left -- a '* ' or
  # '+ ' bullet, an indented '- ', a stray paragraph, a code block under no
  # entry -- renders as content but opened no entry, so it was measured by
  # nothing. Reporting it is what stops "the section holds no entries" and
  # "clean (1 entries)" from being said over text nobody looked at.
  for (( _i = _start; _i < _end; _i++ )); do
    [[ -n "${_seen[${_i}]:-}" ]] && continue
    [[ -n "${_skip[${_i}]:-}" ]] && continue
    [[ -z "${_lines[_i]// }" ]] && continue
    [[ "${_lines[_i]}" == '#'* ]] && continue
    printf '%s:%d: unrecognised content, measured by no entry -- %s\n' \
      "${_CHANGELOG_ENTRY_FILE}" "$(( _i + 1 ))" "${_lines[_i]:0:72}"
    _violations=$(( _violations + 1 ))
  done

  # Pass 4: a category opens at most once per release block. The second
  # '### Added' splits one grouped list into two that read as unrelated,
  # and it arrives by the same silent append-vs-append merge. Headings
  # inside a fenced example are inert here as everywhere else, and a
  # heading inside an allow region is suppressed like the entries are.
  local -A _heading_first=()
  local _headings=0 _heading _category
  for (( _i = _start; _i < _end; _i++ )); do
    [[ -n "${_fenced[${_i}]:-}" ]] && continue
    [[ -n "${_skip[${_i}]:-}" ]] && continue
    [[ "${_lines[_i]}" == '### '* ]] || continue
    _heading="$(_changelog_entry_collapse "${_lines[_i]}")"
    _headings=$(( _headings + 1 ))
    # The locked roster. Twenty heading variants is what an unlocked axis
    # produced, and each of them was one person's reasonable local choice:
    # nothing was wrong at the point of writing, and the result is that a
    # reader scanning for what broke has no heading to scan for. Scoped to
    # [Unreleased] with everything else here -- a shipped `### Tests` is a
    # fact about what shipped.
    _category="${_heading#\#\#\# }"
    if ! _changelog_entry_in_roster "${_category}"; then
      printf '%s:%d: category heading outside the locked set -- %s (allowed: %s)\n' \
        "${_CHANGELOG_ENTRY_FILE}" "$(( _i + 1 ))" "${_category}" \
        "${CHANGELOG_CATEGORIES[*]}"
      _violations=$(( _violations + 1 ))
    fi
    if [[ -n "${_heading_first["${_heading}"]:-}" ]]; then
      printf '%s:%d: repeated category heading -- %s already opened at %s:%s\n' \
        "${_CHANGELOG_ENTRY_FILE}" "$(( _i + 1 ))" "${_heading}" \
        "${_CHANGELOG_ENTRY_FILE}" "${_heading_first["${_heading}"]}"
      _violations=$(( _violations + 1 ))
    else
      _heading_first["${_heading}"]=$(( _i + 1 ))
    fi
  done

  # Pass 5: the printed roster agrees with the enforced one. CONVENTIONS.md
  # is what a contributor reads before writing an entry, so a rendering that
  # has stopped agreeing with the code is not a stale doc -- it is a wrong
  # answer delivered confidently to the one person asking the question.
  local _conv_abs="${REPO_ROOT}/${_CHANGELOG_ENTRY_CONVENTIONS}"
  if [[ ! -f "${_conv_abs}" ]]; then
    printf '%s: missing -- the locked category set has to be written down where a contributor looks for it, or the roster exists only in the lint that refuses them\n' \
      "${_CHANGELOG_ENTRY_CONVENTIONS}"
    _violations=$(( _violations + 1 ))
  else
    local _documented _enforced
    _documented="$(_changelog_entry_documented_roster "${_conv_abs}")"
    _enforced="$(printf '%s\n' "${CHANGELOG_CATEGORIES[@]}")"
    if [[ "${_documented}" != "${_enforced}" ]]; then
      printf '%s: the roster it prints disagrees with %s. Documented: %s. Enforced: %s.\n' \
        "${_CHANGELOG_ENTRY_CONVENTIONS}" "${_CHANGELOG_ENTRY_ROSTER}" \
        "${_documented//$'\n'/ }" "${CHANGELOG_CATEGORIES[*]}"
      _violations=$(( _violations + 1 ))
    fi
  fi

  if [[ "${_violations}" -gt 0 ]]; then
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_changelog_entry \
      "${_violations} over-long entry / duplicate entry / repeated category heading / orphaned wrap line / unbalanced allow marker / unrecognised line in '${_CHANGELOG_ENTRY_HEADING}'. An entry is a top-level '- ' bullet at column 0 plus everything under it -- a '*' or '+' bullet, or an indented one, is content no entry measures and is refused rather than skipped. An entry answers what changed and whether it affects the reader, in at most ${_CHANGELOG_ENTRY_MAX} characters measured over the whole entry with whitespace collapsed -- so rewrapping it or splitting it into sub-bullets does not help. The reasoning, the alternatives and the measurements belong in the PR the entry already links to. A lead bullet repeating another word for word, and a '### <category>' heading opening twice in one release block, are refused naming BOTH lines: merging origin/main into a branch that appended to '${_CHANGELOG_ENTRY_HEADING}' keeps both sides without conflicting, so a duplicate lands with nothing to review. A repeated CATEGORY HEADING is mechanical to repair and 'just test changelog-fix' (./script/test/test.sh --changelog-entry-fix) does it: each category is emitted once in roster order with its entries byte-for-byte, and a section with nothing to fold is not rewritten. A duplicate ENTRY is not folded for you -- which of two near-identical entries survives is a judgement about text. A single word left alone on a continuation line above the rest of its paragraph is an entry that was edited and not re-wrapped -- re-flow it. A '### <category>' heading names one of ${CHANGELOG_CATEGORIES[*]} and nothing else -- twenty variants is what an unlocked axis produced, and migration instructions belong INSIDE the BREAKING entry they serve rather than in a parallel section a reader can miss; the roster is defined once in '${_CHANGELOG_ENTRY_ROSTER}' and printed for contributors in '${_CHANGELOG_ENTRY_CONVENTIONS}', and the two must agree. A genuinely exceptional entry opts out by bracketing it with '<!-- ${_CHANGELOG_ENTRY_ALLOW_BEGIN} -- <why> -->' / '<!-- ${_CHANGELOG_ENTRY_ALLOW_END} -->'."
    return 1
  fi

  if [[ "${_entries}" -eq 0 ]]; then
    # Legitimate right after a release. Said out loud so a green line is
    # never read as a green verdict over entries that were never there --
    # and an empty section and a fully suppressed one are different facts,
    # so they get different sentences.
    if [[ "${_suppressed}" -gt 0 ]]; then
      echo "changelog entry lint: no entries checked -- all ${_suppressed} in '${_CHANGELOG_ENTRY_HEADING}' sit inside an allow region (${_headings} category headings compared)"
    else
      echo "changelog entry lint: '${_CHANGELOG_ENTRY_HEADING}' holds no entries -- nothing to check (${_headings} category headings compared)"
    fi
    return 0
  fi
  echo "changelog entry lint: clean (${_entries} entries checked for length and for duplication, ${_headings} category headings checked against the ${#CHANGELOG_CATEGORIES[@]}-name roster, ${_suppressed} suppressed by an allow region, max ${_CHANGELOG_ENTRY_MAX} chars)"
}

# ── Folding a repeated category heading ──────────────────────────────────────
#
# The lint above refuses a '### <category>' heading that opens twice in
# [Unreleased], and it is right to: two '### Fixed' blocks in one release
# block mean a reader scanning for what was fixed finds half of it, and the
# release-notes assembler has no reason to prefer one over the other. What
# was missing is that the repair is deterministic and nobody did it
# automatically, so every branch in a serial queue paid a full gate cycle to
# be told something a script can fix.
#
# WHERE THE DUPLICATE COMES FROM, measured rather than assumed.
# doc/changelog/v[0-9]*.md carries `merge=union` (.gitattributes). Two
# branches each appending a '### Fixed' block at the SAME anchor do NOT
# produce a duplicate: git refines the conflict, the two identical heading
# lines line up, and only the entry bullets are concatenated. The duplicate
# arrives when the two blocks land at DIFFERENT anchors -- one branch forked
# before the category now above it existed, so its block sits higher in the
# section -- because then the two hunks do not overlap, both are applied
# verbatim, and the file ends with two headings separated by somebody else's
# category. Under the default three-way merge that same pair is a CONFLICT a
# human resolves; `merge=union` resolves it silently, which is what makes the
# duplicate arrive with nothing to review.
#
# THE RULE, in full:
#
#   - Scope is [Unreleased], read through the same bounds, the same fence map
#     and the same allow map the lint uses. A released section is a
#     historical record and a duplicate that shipped is a fact about what
#     shipped.
#   - Each category is emitted ONCE, in the order the roster declares
#     (script/release/changelog_categories.sh), with any heading the roster
#     does not name emitted after them in first-seen order. That is exactly
#     the order script/release/release_notes.sh already assembles a release
#     page in, so the file and the page it becomes stop differing by one.
#   - Entry text moves BYTE FOR BYTE. Nothing is reworded, re-wrapped,
#     re-indented, merged with a similar entry or dropped, and within a
#     category the entries keep their file order: the first occurrence's,
#     then the second's. Only the edge blank lines of a block are touched,
#     because they are what joins two blocks into one list; a blank line
#     INSIDE an entry is part of the entry.
#   - A section with no repeated heading is NOT REWRITTEN AT ALL. The file is
#     left byte-identical rather than re-emitted in canonical shape, which is
#     what makes this idempotent in the strong sense: folding twice changes
#     nothing, and a file nobody broke is never reformatted by a command
#     somebody ran for a different reason.
#   - A duplicate ENTRY -- the same lead bullet twice -- is NOT folded.
#     Which of two near-identical entries survives is a judgement about text,
#     and the lint goes on refusing it.
#   - An allow region whose markers do not balance makes the section's extent
#     ambiguous, so the fold REFUSES rather than guess which lines the author
#     meant to exempt.
#
# WHERE IT HANGS. On the gate that refuses, as `--changelog-entry-fix`
# (`just test changelog-fix`), named by the refusal itself. The alternative
# considered was `just test sync-docs`, which already regenerates derived doc
# content; it was rejected because that recipe's generator is scoped to
# doc/test/*.md and its drift validator runs that same generator against a
# throwaway copy, so a changelog rewrite hung there would be a tracked file
# edited by a verb whose checker cannot see it. CI keeps refusing exactly as
# it does now -- this writes, it never validates.

# Read once by the fold, which needs the whole file in memory to move a block
# and has to agree with the lint about every map in it.
#
# `-g` is load-bearing on every one of these, not decoration. This file is
# sourced at top level by script/test/test.sh but INSIDE a function by the
# unit spec's setup(), and a bare `declare -A` in a function declares a LOCAL:
# the declaration would vanish before the test body ran, the first `=()` would
# mint a plain INDEXED array instead, and every string key would then index
# element 0 -- so one category's entries were emitted under all seven roster
# headings. Measured, not hypothesised; the specs below caught it.
declare -ga _CHANGELOG_FOLD_LINES=()
declare -gA _CHANGELOG_FOLD_FENCED=()
declare -gA _CHANGELOG_FOLD_SKIP=()
# The index of every category heading the fold may move, in file order.
declare -ga _CHANGELOG_FOLD_HEADS=()
# The categories the section carries, in first-seen order, and each one's
# accumulated entry lines.
declare -ga _CHANGELOG_FOLD_ORDER=()
declare -gA _CHANGELOG_FOLD_BODY=()
# How many headings folded away -- zero means the file is not touched.
_CHANGELOG_FOLD_DUPS=0

# _changelog_entry_fold_load -- the resolved series file and every map the
# fold reads, or a refusal. Nothing is written here.
_changelog_entry_fold_load() {
  _changelog_entry_locate || return 1
  _CHANGELOG_FOLD_LINES=()
  mapfile -t _CHANGELOG_FOLD_LINES < "${REPO_ROOT}/${_CHANGELOG_ENTRY_FILE}"
  _CHANGELOG_FOLD_FENCED=()
  _changelog_entry_fences _CHANGELOG_FOLD_FENCED "${_CHANGELOG_FOLD_LINES[@]}"
  _changelog_entry_bounds _CHANGELOG_FOLD_LINES _CHANGELOG_FOLD_FENCED || return 1
  _CHANGELOG_FOLD_SKIP=()
  _changelog_entry_allow_map _CHANGELOG_FOLD_SKIP _CHANGELOG_FOLD_LINES \
    _CHANGELOG_FOLD_FENCED
  if [[ "${#_CHANGELOG_ENTRY_MARKER_BOTH[@]}" -gt 0 ]] \
    || [[ "${#_CHANGELOG_ENTRY_MARKER_STRAY_END[@]}" -gt 0 ]] \
    || [[ "${_CHANGELOG_ENTRY_MARKER_UNTERMINATED}" -gt 0 ]]; then
    _die ci_changelog_entry_fix \
      "'${_CHANGELOG_ENTRY_FILE}': the allow markers in '${_CHANGELOG_ENTRY_HEADING}' do not balance, so which lines are exempt is ambiguous and a rewriter must not guess at it. The entry lint names every offending line; fix the markers, then fold."
    return 1
  fi
}

# _changelog_entry_fold_body <head-index> <block-end> -- the block's lines
# with its leading and trailing blank lines removed, one per line.
#
# Only the EDGES. A blank line inside an entry is part of the entry -- a
# loose sub-list, a fenced example, a second paragraph -- and dropping it
# would be rewording. The edges are what two concatenated blocks would
# otherwise leave as a blank line in the middle of one bullet list.
_changelog_entry_fold_body() {
  local _fb_to="${2}" _fb_i _fb_first=-1 _fb_last=-1
  local _fb_from=$(( ${1} + 1 ))
  for (( _fb_i = _fb_from; _fb_i < _fb_to; _fb_i++ )); do
    if [[ -z "${_CHANGELOG_FOLD_LINES[_fb_i]// }" ]]; then
      continue
    fi
    if [[ "${_fb_first}" -lt 0 ]]; then
      _fb_first="${_fb_i}"
    fi
    _fb_last="${_fb_i}"
  done
  if [[ "${_fb_first}" -lt 0 ]]; then
    return 0
  fi
  for (( _fb_i = _fb_first; _fb_i <= _fb_last; _fb_i++ )); do
    printf '%s\n' "${_CHANGELOG_FOLD_LINES[_fb_i]}"
  done
}

# _changelog_entry_fold_group -- group every block in the section under its
# category and report each heading that folds away, naming BOTH lines for the
# same reason the lint's refusal does: the fix is a comparison of two places.
#
# The population is the heading set the lint's category pass compares --
# outside a fenced example, outside an allow region. A heading the set
# excludes does not split a block either, so it travels with the entries
# around it rather than becoming a block of its own.
_changelog_entry_fold_group() {
  local _fg_i _fg_h _fg_end _fg_key _fg_cat _fg_text
  local -A _fg_first=()
  _CHANGELOG_FOLD_HEADS=()
  _CHANGELOG_FOLD_ORDER=()
  _CHANGELOG_FOLD_BODY=()
  _CHANGELOG_FOLD_DUPS=0
  for (( _fg_i = _CHANGELOG_ENTRY_START; _fg_i < _CHANGELOG_ENTRY_END; _fg_i++ )); do
    [[ -n "${_CHANGELOG_FOLD_FENCED[${_fg_i}]:-}" ]] && continue
    [[ -n "${_CHANGELOG_FOLD_SKIP[${_fg_i}]:-}" ]] && continue
    [[ "${_CHANGELOG_FOLD_LINES[_fg_i]}" == '### '* ]] || continue
    _CHANGELOG_FOLD_HEADS+=( "${_fg_i}" )
  done
  for (( _fg_i = 0; _fg_i < ${#_CHANGELOG_FOLD_HEADS[@]}; _fg_i++ )); do
    _fg_h="${_CHANGELOG_FOLD_HEADS[_fg_i]}"
    _fg_end="${_CHANGELOG_ENTRY_END}"
    if [[ $(( _fg_i + 1 )) -lt "${#_CHANGELOG_FOLD_HEADS[@]}" ]]; then
      _fg_end="${_CHANGELOG_FOLD_HEADS[_fg_i + 1]}"
    fi
    # The same key the lint compares, so the two cannot disagree about which
    # headings are the same heading.
    _fg_key="$(_changelog_entry_collapse "${_CHANGELOG_FOLD_LINES[_fg_h]}")"
    _fg_cat="${_fg_key#\#\#\# }"
    if [[ -z "${_CHANGELOG_FOLD_BODY["${_fg_cat}"]+set}" ]]; then
      _CHANGELOG_FOLD_BODY["${_fg_cat}"]=''
      _CHANGELOG_FOLD_ORDER+=( "${_fg_cat}" )
      _fg_first["${_fg_cat}"]=$(( _fg_h + 1 ))
    else
      _CHANGELOG_FOLD_DUPS=$(( _CHANGELOG_FOLD_DUPS + 1 ))
      printf '%s:%d: folded -- %s into the block %s:%s opened\n' \
        "${_CHANGELOG_ENTRY_FILE}" "$(( _fg_h + 1 ))" "${_fg_key}" \
        "${_CHANGELOG_ENTRY_FILE}" "${_fg_first["${_fg_cat}"]}"
    fi
    # Joined with a single newline, never a blank line: two blocks of one
    # category are one bullet list, and a blank line between them is the
    # loose-list shape nobody wrote.
    _fg_text="$(_changelog_entry_fold_body "${_fg_h}" "${_fg_end}")"
    if [[ -n "${_fg_text}" ]]; then
      if [[ -n "${_CHANGELOG_FOLD_BODY["${_fg_cat}"]}" ]]; then
        _CHANGELOG_FOLD_BODY["${_fg_cat}"]+=$'\n'
      fi
      _CHANGELOG_FOLD_BODY["${_fg_cat}"]+="${_fg_text}"
    fi
  done
}

# _changelog_entry_fold_emit <out-array-name> <category> <body> -- append one
# heading, a blank line, the body and a blank line to the named array. The
# shape script/release/release_notes.sh emits a merged category in, which is
# the shape the file already has.
_changelog_entry_fold_emit() {
  local -n _fe_out="${1}"
  local _fe_cat="${2}" _fe_body="${3}" _fe_line
  _fe_out+=( "### ${_fe_cat}" '' )
  if [[ -z "${_fe_body}" ]]; then
    return 0
  fi
  while IFS= read -r _fe_line; do
    _fe_out+=( "${_fe_line}" )
  done <<< "${_fe_body}"
  _fe_out+=( '' )
}

# _changelog_entry_fold_section <out-array-name> -- the folded section into
# the named array. Returns 1 when there is nothing to fold, which is the
# signal to leave the file alone entirely.
_changelog_entry_fold_section() {
  local -n _fs_out="${1}"
  local _fs_i _fs_cat
  local -A _fs_done=()
  _changelog_entry_fold_group
  if [[ "${_CHANGELOG_FOLD_DUPS}" -eq 0 ]]; then
    return 1
  fi
  _fs_out=()
  # Everything above the first heading is the section's lead prose, and an
  # entry sitting under no heading at all is somebody's entry: both stay
  # exactly where they are.
  for (( _fs_i = _CHANGELOG_ENTRY_START; _fs_i < _CHANGELOG_FOLD_HEADS[0]; _fs_i++ )); do
    _fs_out+=( "${_CHANGELOG_FOLD_LINES[_fs_i]}" )
  done
  for _fs_cat in "${CHANGELOG_CATEGORIES[@]}"; do
    [[ -n "${_CHANGELOG_FOLD_BODY["${_fs_cat}"]+set}" ]] || continue
    _changelog_entry_fold_emit _fs_out "${_fs_cat}" \
      "${_CHANGELOG_FOLD_BODY["${_fs_cat}"]}"
    _fs_done["${_fs_cat}"]=1
  done
  # A heading the roster does not name is history, not a defect (the lint
  # refuses one in [Unreleased] on its own account). Emitted after the roster
  # ones, in first-seen order, exactly as the release assembler does.
  for _fs_cat in "${_CHANGELOG_FOLD_ORDER[@]}"; do
    [[ -n "${_fs_done["${_fs_cat}"]:-}" ]] && continue
    _changelog_entry_fold_emit _fs_out "${_fs_cat}" \
      "${_CHANGELOG_FOLD_BODY["${_fs_cat}"]}"
    _fs_done["${_fs_cat}"]=1
  done
  return 0
}

# _changelog_entry_fold_write <section-array-name> -- replace the section in
# the file on disk with the given lines.
#
# The section's trailing blank-line budget is PRESERVED rather than assumed:
# one blank line separates it from the released section below it, and no
# blank line follows it when [Unreleased] ends the file. A missing final
# newline is preserved for the same reason -- a rewriter that is about the
# heading level has no business adding a byte at end of file.
_changelog_entry_fold_write() {
  local -n _fw_section="${1}"
  local _fw_path="${REPO_ROOT}/${_CHANGELOG_ENTRY_FILE}"
  local _fw_i _fw_tail=0 _fw_keep="${#_fw_section[@]}" _fw_tmp _fw_nl=1
  local -a _fw_out=()
  for (( _fw_i = _CHANGELOG_ENTRY_END - 1; _fw_i >= _CHANGELOG_ENTRY_START; _fw_i-- )); do
    if [[ -n "${_CHANGELOG_FOLD_LINES[_fw_i]// }" ]]; then
      break
    fi
    _fw_tail=$(( _fw_tail + 1 ))
  done
  while [[ "${_fw_keep}" -gt 0 ]] && [[ -z "${_fw_section[_fw_keep - 1]// }" ]]; do
    _fw_keep=$(( _fw_keep - 1 ))
  done
  for (( _fw_i = 0; _fw_i < _CHANGELOG_ENTRY_START; _fw_i++ )); do
    _fw_out+=( "${_CHANGELOG_FOLD_LINES[_fw_i]}" )
  done
  for (( _fw_i = 0; _fw_i < _fw_keep; _fw_i++ )); do
    _fw_out+=( "${_fw_section[_fw_i]}" )
  done
  for (( _fw_i = 0; _fw_i < _fw_tail; _fw_i++ )); do
    _fw_out+=( '' )
  done
  for (( _fw_i = _CHANGELOG_ENTRY_END; _fw_i < ${#_CHANGELOG_FOLD_LINES[@]}; _fw_i++ )); do
    _fw_out+=( "${_CHANGELOG_FOLD_LINES[_fw_i]}" )
  done
  if [[ -s "${_fw_path}" ]] && [[ -n "$(tail -c 1 "${_fw_path}")" ]]; then
    _fw_nl=0
  fi
  _fw_tmp="$(mktemp "${_fw_path}.fold.XXXXXX")" || return 1
  _changelog_entry_fold_spill _fw_out "${_fw_nl}" > "${_fw_tmp}"
  # mktemp creates 0600. Without this the fold leaves the changelog
  # owner-only-readable in the working tree, on a bit git does not track --
  # so nothing downstream reports it and the next reader cannot tell what
  # changed the mode.
  chmod --reference="${_fw_path}" "${_fw_tmp}" 2> /dev/null || true
  mv -- "${_fw_tmp}" "${_fw_path}"
}

# _changelog_entry_fold_spill <lines-array-name> <final-newline> -- the lines
# on stdout, with a trailing newline on the last one only when the second
# argument is 1.
_changelog_entry_fold_spill() {
  local -n _sp_lines="${1}"
  local _sp_nl="${2}" _sp_n="${#_sp_lines[@]}"
  if [[ "${_sp_n}" -eq 0 ]]; then
    return 0
  fi
  if [[ "${_sp_n}" -gt 1 ]]; then
    printf '%s\n' "${_sp_lines[@]:0:_sp_n - 1}"
  fi
  if [[ "${_sp_nl}" -eq 1 ]]; then
    printf '%s\n' "${_sp_lines[_sp_n - 1]}"
  else
    printf '%s' "${_sp_lines[_sp_n - 1]}"
  fi
}

# _run_changelog_entry_fix -- the repair behind `--changelog-entry-fix`.
# Folds every repeated category heading in [Unreleased] into that category's
# first occurrence and rewrites the file, or says the section was already
# clean and writes nothing at all.
_run_changelog_entry_fix() {
  echo "--- Folding repeated [Unreleased] category headings ---"
  local _roster_abs="${REPO_ROOT}/${_CHANGELOG_ENTRY_ROSTER}"
  if [[ ! -f "${_roster_abs}" ]]; then
    _die ci_changelog_entry_fix \
      "'${_CHANGELOG_ENTRY_ROSTER}' not found under ${REPO_ROOT} -- the category order a folded section is emitted in is defined there, so without it the fold would be inventing one."
    return 1
  fi
  # shellcheck source=script/release/changelog_categories.sh
  source "${_roster_abs}"
  _changelog_entry_fold_load || return 1
  local -a _folded=()
  if ! _changelog_entry_fold_section _folded; then
    echo "changelog fold: no category heading opens twice in '${_CHANGELOG_ENTRY_HEADING}' (${#_CHANGELOG_FOLD_HEADS[@]} compared in '${_CHANGELOG_ENTRY_FILE}') -- nothing folded, nothing written"
    return 0
  fi
  _changelog_entry_fold_write _folded || return 1
  echo "changelog fold: folded ${_CHANGELOG_FOLD_DUPS} repeated category heading(s) into ${#_CHANGELOG_FOLD_ORDER[@]} section(s) of '${_CHANGELOG_ENTRY_HEADING}' in '${_CHANGELOG_ENTRY_FILE}'. Entry text is unchanged; review the diff and commit it."
}
