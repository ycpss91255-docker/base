#!/usr/bin/env bash
# drivers/adr_structure.sh - ADR-structure per-tool driver for the
# self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_adr_structure, the enforcer that keeps every ADR under doc/adr/
# carrying the parts an ADR is read for.
#
# Contract: runs INSIDE the ci (test-tools) container where test.sh
# invokes it. References ${REPO_ROOT} (a global exported by test.sh).
# Follows drivers/adr_numbering.sh conventions (sourced lib, uses
# ${REPO_ROOT}, _log_* / _die, no main).
#
# Division of labour with its sibling: adr_numbering.sh guards what an ADR
# file is CALLED (the number and the filename). This guards what it
# CONTAINS. doc/adr/README.md (the ADR index / PRD audit) is the one
# conventional non-ADR file in the registry dir and is exempt from both,
# exactly as it is there.
#
# What every ADR must carry, and why each one is a failure rather than a
# warning:
#
#   - A `> Serves:` back-pointer at line start. It is what connects a
#     decision to the PRD invariant or design principle it upholds; an ADR
#     without one is a decision nobody can check against the north star.
#     Must open the line: a `> Serves:` in the middle of a sentence is
#     prose about back-pointers, not a back-pointer.
#
#   - `## Context`, `## Decision`, `## Consequences`. The three that make
#     the file an ADR rather than an announcement -- what the situation
#     was, what was chosen, and what it costs.
#
#   - `## Alternatives`. REQUIRED, not advisory, and this is the one
#     judgement call in the driver, so it is argued here rather than left
#     to the reader. An ADR's value to a future reader is not the decision
#     -- that is visible in the code -- it is the option space, and an ADR
#     with no alternatives cannot answer the only question anybody brings
#     to it: "why not the obvious other thing?" Without that section the
#     reader cannot tell a decision that beat a real contender from one
#     nobody examined, and re-litigating it is cheaper than trusting it.
#     Advisory was rejected on top of that: a warning nobody must act on
#     is a warning, and the measurement that prompted this lint (25 of 27
#     carried the section by convention alone) is exactly the shape that
#     decays -- the 26th is written by whoever is in a hurry. The two
#     files that were missing it were written, not waived.
#     A heading may carry trailing text -- `## Alternatives considered`,
#     `## Consequences / trade-offs`, `## Decision (pending ...)` are all
#     in the live tree -- so the match is the heading plus an optional
#     space-separated tail, never a substring.
#
#   - A Status that is EXACTLY one of three values: `Accepted`,
#     `Rejected`, `Superseded by ADR-NNNNNNNN`. Free text in Status is why
#     this check exists: four ADRs carried things like
#     `Accepted (amended 2026-06-12)`, which reads as a fourth state and
#     puts a revision where no reader looks for one. A revision belongs in
#     the body as `**Amendment (#issue, YYYY-MM-DD):**`, where the prose
#     it qualifies is.
#
# ── The contract: each part occurs EXACTLY ONCE, at column 0 ────────────
#
# Every part above is found by COUNTING the lines that match it at column
# 0, and the only passing count is one. That count replaces the question
# this driver used to ask -- "is this heading inside a fenced code block?"
# -- and it is the only thing that decides a part is present. The Status
# VALUE check is a second contract layered on top of the count, not a
# by-product of it: it runs only where the count came back one, and it
# re-reads the file with the same pattern to fetch the value, because a
# count returns a number and not a line.
#
# WHY COUNTING RATHER THAN PARSING. "Inside a fence" is a question only a
# CommonMark parser can answer, and this driver carried a hand-written one.
# It was narrowed twice and a hole survived both rounds, each hole passing
# an ADR whose only Decision heading was an illustration: the first ignored
# the fence marker's run LENGTH, so a SHORTER inner ``` ended a longer outer
# block; the second bounded the closing marker's INDENT against the
# OPENER instead of against column 0, so an opener indented one column
# still accepted a closer at four, which CommonMark keeps as block content.
# Both were reproduced against the shipped drivers before this rewrite. A
# count has no comparable surface: one counting grep per part, one number,
# arrived at the same way for every file. (Status runs a second grep, the
# same pattern again, to read the value back off the line the count has
# already proved unique. It cannot disagree with the count -- same pattern,
# same file, count of one -- but it is a second read and not the first
# one's return value.) Three properties follow, and they are the reason to
# prefer it:
#
#   - It needs no notion of "inside", so no markdown construct changes what
#     it does. An illustrated heading is counted like any other line.
#   - It is TOTAL. Every file yields a number for every part; there is no
#     input shape for which the check has no answer.
#   - It refuses in BOTH directions. Zero is a missing part. Two or more is
#     a file that does not say which occurrence is the record, and that is
#     reported rather than resolved by picking one. Picking one is what
#     `grep -m1` did for Status, and it is how the two free-text Status
#     lines in ADR-00000008's amendment sections stayed invisible to a
#     check written to reject exactly that shape.
#
# THE AUTHORING RULE, in full: an ADR that illustrates one of these lines
# indents the illustration so it is not at column 0 -- inside a fenced block
# the leading space is part of the sample text and costs nothing -- and an
# amendment that restates a section or a status uses a `###` heading or a
# different key. Half of the amendment rule codifies what the tree already
# did and half of it does not, and the difference is worth stating exactly:
# ADR-00000008's amendment sections ALREADY carried `### Context` /
# `### Decision`, so the heading half writes down existing practice, but
# `- **Amendment status:**` is a key this change INVENTED. It appeared
# nowhere under doc/ beforehand; it was created here to give that file's two
# free-text amendment Status lines a home that is not a second Status. What
# the rule cost the tree when it landed, measured: no ADR illustrates one of
# these lines at column 0 -- in a fence, in a comment or anywhere else; every
# one of the 28 counts exactly one of every part -- so none needed the
# indent. ADR-00000008 needed the amendment half, and two of its lines
# changed key.
#
# WHAT THIS DOES NOT HANDLE. One fail-open, and two limits that were never
# in scope:
#
#   - THE FAIL-OPEN. An ADR reads as compliant when it BOTH omits a required
#     part AND carries that same line at column 0 somewhere that is not the
#     record: a fenced illustration, a commented-out draft, any context at
#     all, since the count does not look at context. DIRECTION: it PASSES a
#     file that should FAIL. So a clean result from this lint is not a proof
#     that every ADR examined carries its parts.
#     The conjunction is the whole of the shape, and neither half leaks on
#     its own: omit the part and show it nowhere, and the count is zero, a
#     refusal; carry the part AND show it, and the count is two, also a
#     refusal. Only the two together produce a count of one.
#     It is WIDER than what it replaces, and saying so is the point of
#     naming it. Three shapes in this class were run against both the
#     shipped fence parser and this count. The parser REFUSED two of them --
#     a `## Decision` illustrated in a plain ``` fence, and the same heading
#     inside an outer ```` fence between two inner ``` markers (the round-one
#     run-length hole) -- and both now PASS. The third
#     (opener at indent 1, inner marker at indent 4) passed the parser too,
#     so for that one shape this is a reclassification and not a regression:
#     an unnamed parser bug becomes a named, spec-pinned one. For the other
#     two it is a real loss of detection, accepted deliberately.
#     Why accepted: closing it means deciding which lines are code again,
#     which is the parser this rewrite exists to delete; that parser bought
#     nothing on real input (no ADR in the tree carries any of the six
#     markers at column 0 inside a fence at all); and it was hiding a REAL
#     defect the count found -- ADR-00000008's three column-0 Status lines,
#     two of them the free-text shape the three-value contract exists to
#     reject, invisible only because `grep -m1` stopped at the first.
#     What bounds it: the author has to have dropped the part already, and
#     an illustration showing more of the template than the dropped part
#     makes every other line it shows a second occurrence, on which the file
#     IS refused.
#   - ORDER, NESTING and BODY are not checked: a `## Decision` sitting under
#     `## Alternatives`, or with nothing beneath it, passes. A scope limit,
#     not a consequence of counting -- the fence rule did not check them
#     either. This lint is about presence.
#   - A file that legitimately wants a part twice is REFUSED. That is the
#     refusing direction, and the fix is one edit: demote the second
#     occurrence to `###`, or give it a different key.
#
# The sibling `changelog_entry.sh` does carry a fence parser, and that is
# not an inconsistency left standing. Its subject is a repeated structure --
# every changelog entry is one of many -- so no occurrence count says
# anything there, and it has to know what a fence is. An ADR carries exactly
# one of each part, which is what makes counting a contract here rather than
# a heuristic.
#
# An empty population is a REFUSAL. A lint that examined zero ADRs and
# printed "clean" cannot distinguish a tree with no ADRs from a scan whose
# glob, path or exemption has stopped matching, and the second reports
# exactly what success reports. So the count of files examined is part of
# the result, and a zero is fatal (PRD design principle P3).

# ── ADR-structure lint ───────────────────────────────────────────────────────

# The three values that are the whole of the Status-VALUE contract (the
# exactly-once count above is the other half of what an ADR must satisfy).
# Anchored at both ends: a trailing parenthetical is precisely what this
# rejects.
readonly _ADR_STATUS_RE='^(Accepted|Rejected|Superseded by ADR-[0-9]{8})$'

# Well-formed ADR basename (mirrors adr_numbering.sh). A file that is not
# an ADR by name is not this lint's subject -- adr_numbering.sh is what
# fails it -- so it is skipped here rather than double-reported.
readonly _ADR_STRUCT_NAME_RE='^[0-9]{8}-.+\.md$'

# The section headings every ADR must carry.
readonly _ADR_REQUIRED_SECTIONS=(Context Decision Consequences Alternatives)

# _adr_count <extended-regex> <file>
#
# How many lines of <file> match <regex>. grep exits 1 when the count is
# zero, which is an answer here and not an error, so the status is
# discarded and the number is what is read. A grep that fails outright --
# an unreadable file -- prints no number, which reads as zero and reports
# every part of that file missing: the wrong defect named, and a refusal.
_adr_count() {
  local _n
  _n="$(grep -cE -- "${1}" "${2}")" || true
  printf '%s\n' "${_n:-0}"
}

_run_adr_structure() {
  echo "--- Running ADR-structure lint ---"
  local _adr_dir="${REPO_ROOT}/doc/adr"
  local _file _base _n _status_line _status _section _examined=0
  local -a _violations=()

  local -a _files=()
  local _f
  shopt -s nullglob
  for _f in "${_adr_dir}"/*.md; do
    _files+=("${_f}")
  done
  shopt -u nullglob

  for _file in "${_files[@]}"; do
    _base="$(basename "${_file}")"
    # The ADR index / PRD audit, deliberately not an ADR record -- the same
    # exemption adr_numbering.sh makes, for the same file.
    if [[ "${_base}" == "README.md" ]]; then
      continue
    fi
    # Not an ADR by name: adr_numbering.sh owns that failure. Reporting it
    # here too would name one defect twice under two lints.
    if [[ ! "${_base}" =~ ${_ADR_STRUCT_NAME_RE} ]]; then
      continue
    fi
    _examined=$(( _examined + 1 ))

    # The back-pointer, at line start, exactly once.
    _n="$(_adr_count '^> Serves:' "${_file}")"
    if [[ "${_n}" -eq 0 ]]; then
      _violations+=("${_base}: no '> Serves:' back-pointer at column 0 (which PRD invariant or design principle does this decision uphold?)")
    elif [[ "${_n}" -gt 1 ]]; then
      _violations+=("${_base}: '> Serves:' appears ${_n} times at column 0 -- an ADR carries exactly one back-pointer, so fold them into one line, or indent an illustrated one so it is not at column 0")
    fi

    # The required sections. A trailing tail is allowed; a substring is not.
    for _section in "${_ADR_REQUIRED_SECTIONS[@]}"; do
      _n="$(_adr_count "^## ${_section}([[:space:]].*)?\$" "${_file}")"
      if [[ "${_n}" -eq 0 ]]; then
        _violations+=("${_base}: no '## ${_section}' section at column 0")
      elif [[ "${_n}" -gt 1 ]]; then
        _violations+=("${_base}: '## ${_section}' appears ${_n} times at column 0 -- exactly one of them is the section and the file does not say which. Demote an amendment's copy to '### ${_section}', or indent an illustrated heading so it is not at column 0")
      fi
    done

    # The Status line, and the three-value contract.
    _n="$(_adr_count '^- \*\*Status:\*\*' "${_file}")"
    if [[ "${_n}" -eq 0 ]]; then
      _violations+=("${_base}: no '- **Status:**' line at column 0 (expected one of: Accepted | Rejected | Superseded by ADR-NNNNNNNN)")
    elif [[ "${_n}" -gt 1 ]]; then
      _violations+=("${_base}: '- **Status:**' appears ${_n} times at column 0 -- an ADR has one Status. An amendment records its own under a different key ('- **Amendment status:**'), never a second Status line")
    else
      _status_line="$(grep -E '^- \*\*Status:\*\*' "${_file}")"
      _status="${_status_line#- \*\*Status:\*\* }"
      if [[ ! "${_status}" =~ ${_ADR_STATUS_RE} ]]; then
        _violations+=("${_base}: Status '${_status}' is not one of the three contract values (Accepted | Rejected | Superseded by ADR-NNNNNNNN). Free text belongs in the body as '**Amendment (#issue, YYYY-MM-DD):**'.")
      fi
    fi
  done

  # An empty population is a refusal, never a pass. Checked BEFORE the
  # violation report, because zero examined makes an empty violation list
  # meaningless rather than clean.
  if [[ "${_examined}" -eq 0 ]]; then
    _die ci_adr_structure \
      "examined 0 ADR file(s) under doc/adr/ -- refusing to report a pass. Either the directory is empty or the scan stopped matching (glob, path, or the NNNNNNNN-<slug>.md name rule); both need a human, and neither is a pass."
    return 1
  fi

  local _v
  for _v in "${_violations[@]}"; do
    printf 'ADR structure: %s\n' "${_v}"
  done

  if [[ "${#_violations[@]}" -gt 0 ]]; then
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_adr_structure \
      "${#_violations[@]} ADR-structure defect(s) across ${_examined} ADR(s) under doc/adr/. Fix the named file(s): every ADR carries EXACTLY ONE of each part, at column 0 -- a '> Serves:' back-pointer, ## Context / ## Decision / ## Consequences / ## Alternatives, and a '- **Status:**' line whose value is exactly Accepted | Rejected | Superseded by ADR-NNNNNNNN."
    return 1
  fi
  printf 'ADR-structure lint: %d ADR(s) examined, clean\n' "${_examined}"
}
