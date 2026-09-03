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
# Headings inside a fenced code block do NOT count. An ADR that shows a
# markdown example -- and several do -- would otherwise satisfy the
# section check with an illustration, which is a fail-open: the check
# would pass a file that has no Decision section at all.
#
# An empty population is a REFUSAL. A lint that examined zero ADRs and
# printed "clean" cannot distinguish a tree with no ADRs from a scan whose
# glob, path or exemption has stopped matching, and the second reports
# exactly what success reports. So the count of files examined is part of
# the result, and a zero is fatal (PRD design principle P3).

# ── ADR-structure lint ───────────────────────────────────────────────────────

# The three Status values that are the whole contract. Anchored at both
# ends: a trailing parenthetical is precisely what this rejects.
readonly _ADR_STATUS_RE='^(Accepted|Rejected|Superseded by ADR-[0-9]{8})$'

# Well-formed ADR basename (mirrors adr_numbering.sh). A file that is not
# an ADR by name is not this lint's subject -- adr_numbering.sh is what
# fails it -- so it is skipped here rather than double-reported.
readonly _ADR_STRUCT_NAME_RE='^[0-9]{8}-.+\.md$'

# The section headings every ADR must carry.
readonly _ADR_REQUIRED_SECTIONS=(Context Decision Consequences Alternatives)

# _adr_outline <file>
#
# Print the file's structural lines -- the ones a check may read -- with
# every line inside a fenced code block dropped. Fences are ``` or ~~~ at
# any indent, and the run LENGTH is part of the fence, per CommonMark: a
# block closes only on a marker of the same character at least as long as
# the one that opened it, followed by nothing but whitespace.
#
# Length is what makes nesting parse. A fenced block shown inside a fenced
# block is legal only with a longer outer fence, so closing on any ``` at
# all would let the inner ``` end the outer block and emit the example
# heading as real content -- the fail-open this stripping exists to
# prevent. Requiring the same character keeps the sibling case honest: a
# ``` example nested in a ~~~ block does not end the outer block either.
_adr_outline() {
  local _file="${1}"
  awk '
    # Length of the leading run of <ch> in <s>.
    function _run(s, ch,   n) {
      n = 0
      while (substr(s, n + 1, 1) == ch) { n++ }
      return n
    }
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      if (fence == "") {
        n = _run(line, "`")
        if (n >= 3) { fence = "`"; flen = n; next }
        n = _run(line, "~")
        if (n >= 3) { fence = "~"; flen = n; next }
        print $0
        next
      }
      # Inside a block: same marker, at least as long, nothing trailing.
      n = _run(line, fence)
      if (n >= flen) {
        rest = substr(line, n + 1)
        sub(/[ \t]+$/, "", rest)
        if (rest == "") { fence = ""; flen = 0 }
      }
      next
    }
  ' "${_file}"
}

_run_adr_structure() {
  echo "--- Running ADR-structure lint ---"
  local _adr_dir="${REPO_ROOT}/doc/adr"
  local _file _base _outline _status_line _status _section _examined=0
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

    _outline="$(_adr_outline "${_file}")"

    # The back-pointer, at line start.
    if ! grep -qE '^> Serves:' <<< "${_outline}"; then
      _violations+=("${_base}: no '> Serves:' back-pointer (which PRD invariant or design principle does this decision uphold?)")
    fi

    # The required sections. A trailing tail is allowed; a substring is not.
    for _section in "${_ADR_REQUIRED_SECTIONS[@]}"; do
      if ! grep -qE "^## ${_section}([[:space:]].*)?$" <<< "${_outline}"; then
        _violations+=("${_base}: no '## ${_section}' section (a heading inside a fenced code block does not count)")
      fi
    done

    # The Status line, and the three-value contract.
    _status_line="$(grep -m1 -E '^- \*\*Status:\*\*' <<< "${_outline}" || true)"
    if [[ -z "${_status_line}" ]]; then
      _violations+=("${_base}: no '- **Status:**' line (expected one of: Accepted | Rejected | Superseded by ADR-NNNNNNNN)")
    else
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
      "${#_violations[@]} ADR-structure defect(s) across ${_examined} ADR(s) under doc/adr/. Fix the named file(s): every ADR carries a '> Serves:' back-pointer, ## Context / ## Decision / ## Consequences / ## Alternatives, and a Status of exactly Accepted | Rejected | Superseded by ADR-NNNNNNNN."
    return 1
  fi
  printf 'ADR-structure lint: %d ADR(s) examined, clean\n' "${_examined}"
}
