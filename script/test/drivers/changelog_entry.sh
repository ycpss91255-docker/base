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
# exactly one word, and the SOURCE line immediately below it must be more
# prose of the same paragraph. A one-word final line, a table row, an HTML
# comment and anything a fence made inert are all left alone, because none
# of them is a paragraph that failed to re-flow. Scope is [Unreleased] with
# everything else here, for the same reason: a shipped entry is history.
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
  local _joined _chars
  _joined="$(printf '%s\n' "$@" | LC_ALL=C tr -s '[:space:]' ' ')"
  # tr leaves one leading / trailing space where the input had any.
  _joined="${_joined# }"
  _joined="${_joined% }"
  _chars="$(printf '%s' "${_joined}" | LC_ALL=C tr -d '\200-\277' | wc -c)"
  printf '%s' "$(( _chars ))"
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

  # Which lines a fenced code block makes inert. Resolved once, up front,
  # because every scan below has to agree about it -- a boundary that
  # counts a fenced heading and an entry walker that does not would
  # disagree about what the section even is.
  local -A _fenced=()
  _changelog_entry_fences _fenced "${_lines[@]}"

  # Locate the section: from the heading to the next '## [' heading (or
  # EOF). Walking past that boundary into a released section is THE failure
  # mode this lint has to avoid, so the end is found explicitly rather than
  # by falling off the end of the file.
  local _i _start=-1 _end="${#_lines[@]}"
  for (( _i = 0; _i < ${#_lines[@]}; _i++ )); do
    if [[ -n "${_fenced[${_i}]:-}" ]]; then
      continue
    fi
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
    if [[ -n "${_fenced[${_i}]:-}" ]]; then
      continue
    fi
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
  local _in_allow=0 _begin_line=0 _begin_idx=-1 _marker
  for (( _i = _start; _i < _end; _i++ )); do
    if [[ -n "${_fenced[${_i}]:-}" ]]; then
      continue
    fi
    _marker="$(_changelog_entry_marker "${_lines[_i]}")"
    case "${_marker}" in
      both)
        printf '%s:%d: malformed allow marker (allow-begin and allow-end in one comment)\n' \
          "${_CHANGELOG_ENTRY_FILE}" "$(( _i + 1 ))"
        _violations=$(( _violations + 1 ))
        _skip["${_i}"]=1
        continue
        ;;
      begin)
        _in_allow=1
        _begin_line=$(( _i + 1 ))
        _begin_idx="${_i}"
        _skip["${_i}"]=1
        continue
        ;;
      end)
        if [[ "${_in_allow}" -eq 0 ]]; then
          printf '%s:%d: unmatched allow-end (no open allow-begin)\n' \
            "${_CHANGELOG_ENTRY_FILE}" "$(( _i + 1 ))"
          _violations=$(( _violations + 1 ))
        fi
        _in_allow=0
        _skip["${_i}"]=1
        continue
        ;;
    esac
    if [[ "${_in_allow}" -eq 1 ]]; then
      _skip["${_i}"]=1
    fi
  done
  if [[ "${_in_allow}" -eq 1 ]]; then
    printf '%s:%d: unterminated allow-begin (no closing allow-end)\n' \
      "${_CHANGELOG_ENTRY_FILE}" "${_begin_line}"
    _violations=$(( _violations + 1 ))
    # The region never closed, so it swallowed the whole rest of the
    # section. Hand those lines back: a dangling marker is one violation to
    # report, not a licence to stop measuring, and an author who has to fix
    # the marker before the entries even become visible pays for the same
    # mistake twice.
    for (( _i = _begin_idx + 1; _i < _end; _i++ )); do
      unset "_skip[${_i}]"
    done
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
  local _entries=0 _j _k _len _label
  local -A _seen=()
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

    # Orphaned wrap lines within this entry. A word is orphaned when it is
    # alone on its line AND the very next SOURCE line carries more of the
    # same paragraph -- contiguity is what separates "the paragraph was not
    # re-flowed" from "the paragraph ended on a short line", which is not a
    # defect. See the header note.
    local _b _next _orphan
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

  if [[ "${_violations}" -gt 0 ]]; then
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_changelog_entry \
      "${_violations} over-long entry / orphaned wrap line / unbalanced allow marker / unrecognised line in '${_CHANGELOG_ENTRY_HEADING}'. An entry is a top-level '- ' bullet at column 0 plus everything under it -- a '*' or '+' bullet, or an indented one, is content no entry measures and is refused rather than skipped. An entry answers what changed and whether it affects the reader, in at most ${_CHANGELOG_ENTRY_MAX} characters measured over the whole entry with whitespace collapsed -- so rewrapping it or splitting it into sub-bullets does not help. The reasoning, the alternatives and the measurements belong in the PR the entry already links to. A single word left alone on a continuation line above the rest of its paragraph is an entry that was edited and not re-wrapped -- re-flow it. A genuinely exceptional entry opts out by bracketing it with '<!-- ${_CHANGELOG_ENTRY_ALLOW_BEGIN} -- <why> -->' / '<!-- ${_CHANGELOG_ENTRY_ALLOW_END} -->'."
    return 1
  fi

  if [[ "${_entries}" -eq 0 ]]; then
    # Legitimate right after a release. Said out loud so a green line is
    # never read as a green verdict over entries that were never there --
    # and an empty section and a fully suppressed one are different facts,
    # so they get different sentences.
    if [[ "${_suppressed}" -gt 0 ]]; then
      echo "changelog entry lint: no entries checked -- all ${_suppressed} in '${_CHANGELOG_ENTRY_HEADING}' sit inside an allow region"
    else
      echo "changelog entry lint: '${_CHANGELOG_ENTRY_HEADING}' holds no entries -- nothing to check"
    fi
    return 0
  fi
  echo "changelog entry lint: clean (${_entries} entries checked, ${_suppressed} suppressed by an allow region, max ${_CHANGELOG_ENTRY_MAX} chars)"
}
