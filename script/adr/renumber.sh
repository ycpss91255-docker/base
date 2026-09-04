#!/usr/bin/env bash
#
# renumber.sh - move one ADR record to another number and rewrite every
# reference to it, in one step, with the reference set DERIVED from the
# tree rather than kept in a list here.
#
# Usage:
#   ./script/adr/renumber.sh <record> <to> [root]
#
#   <record>  the record to move: its number (`30`, `00000030`) when
#             exactly one record claims that number, or its filename when
#             the tree is in a state where more than one does.
#   <to>      the number to move it to; must be claimed by nothing.
#   [root]    repo root. Defaults to the enclosing checkout.
#
# Exit status: 0 = renumbered; 1 = refused. Every precondition is checked
# BEFORE the first write, and the RENAME is that first write, so a refusal
# leaves nothing half-renumbered -- including the refusals no precondition
# can predict, because the rename is the step that fails for reasons the
# tree cannot be asked about in advance.
#
# ── Why this exists ─────────────────────────────────────────────────────
#
# Nothing allocates an ADR number. Every branch reads doc/adr/, sees the
# highest, and takes the next one -- and every branch is right, by the only
# rule there is, so parallel work collides by construction rather than by
# mistake. Three branches took 00000030 on one day (base#1021).
#
# The collision itself reaches a red check: drivers/adr_numbering.sh fails
# on a duplicate number. What was expensive was the REPAIR. Renumbering one
# of them touched 14 files -- CONTEXT.md, the index row, the audit
# keep-list and two of its "postdates the audit" notes, the changelog, an
# amended ADR's forward pointer, six spec files, three catalogue documents,
# a lib and a workflow -- and every one of those is a place the repair can
# be done incompletely and stay green. It was done by hand, and it WAS left
# incomplete: the index row for the moved record still carried the old
# number when this tool was written.
#
# ── The classes of reference, and why a blind sed is wrong ──────────────
#
#   record    doc/adr/<from>-<slug>.md itself. Renamed with `git mv` where
#             git TRACKS it, so the move is a move; with a plain `mv`
#             otherwise, which covers the root that is no checkout and the
#             ADR authored this morning and not yet `git add`ed.
#   token     `ADR-<from>` in prose, comments and code. The common one.
#   path      `doc/adr/<from>-<slug>.md` written out as a path. Carries the
#             slug, so it stays unambiguous where the number does not.
#   index     a BARE <from> -- doc/adr/README.md ONLY. That document's
#             8-digit runs are all ADR numbers (its rows open with one and
#             its audit conclusions enumerate them). Everywhere else an
#             8-digit run standing on its own is not a reference to
#             anything: it is a version, a count, an argument.
#   derived   the generated regions of the doc/test catalogues. Rewritten
#             LIKE ANY OTHER FILE and then REBUILT, in that order, and
#             neither step subsumes the other. One of the 14 sites was a
#             `@test` NAME carrying the number, and a test name is a ROW in
#             a catalogue: a substitution on the row appears to work and
#             the next regeneration reverts it, so the rebuild is what
#             actually carries a renamed test into its document. But a
#             catalogue is only PARTLY generated -- its preamble is
#             hand-written prose the generator does not own -- so skipping
#             the file, which this tool did first, leaves a reference
#             standing there under a green run. Both, in order.
#
# A file that builds its own throwaway registry DECLARES the numbers that
# registry uses (script/adr/references.sh), and a reference carrying one
# of them is dropped in every class. Per-class was tried and is how this
# tool corrupted the spec that guards it: the `ADR-<n>` and `adr/<n>-`
# forms in adr_renumber_spec.bats were rewritten and the numbers it passes
# to this tool as ARGUMENTS were not, so its setup and its command named
# different records. Per-FILE was tried next and is how this tool aborted
# half-way: adr_numbering_spec.bats's `# why:` marker cites a live record
# and the generator publishes that marker as a doc/test row, so the sweep
# fixed the row, the regeneration put the old number back, and the run
# ended on a survivor with the record already moved.
#
# The population is references.sh's, which is also the ADR-numbering
# lint's -- see that file for why one definition and not two. Not a list:
# a list of the 14 places is the same defect one level up, and it would
# have been written on the day the fifteenth site was added.
#
# ── What it refuses, and why that is not a gap ──────────────────────────
#
# A number claimed by TWO records is refused before anything is written.
# That is the state a collision merge lands in, and in it the `token` class
# is genuinely unattributable: `ADR-00000030` in a sentence names whichever
# of the two the author had in mind, and nothing in the merged tree records
# which. Rewriting all of them corrupts every reference to the record that
# keeps the number; rewriting none leaves the repair half-done under a
# green gate, which is the defect this tool is for.
#
# So the refusal names both records and points at the resolution that IS
# derivable: renumber ON THE BRANCH, where the record is the only claimant
# of its number, and merge afterwards. The reference set is unambiguous
# there, and the merge then carries a record nobody else has claimed.
#
# (The attribution a later version could derive: during a merge, or while
# the merge commit is still the tip, `MERGE_HEAD` / the second parent names
# the side each reference came from. Not built, because it holds only for
# as long as that is true, and a repair tool whose correctness depends on
# how soon it is run is worse than one that says what it cannot do.)
#
# Style: Google Shell Style Guide.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

_ADR_RENUMBER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"

# The doc/test generator, for exactly one question this tool must not
# answer for itself: WHICH FILES ARE GENERATED. Sourced, not run, for
# `_sync_doc_counts_outputs` and `_sync_doc_counts`; it guards its own
# `main` on being executed directly, and this file's `main` is defined
# after the source, so the entry point below is the one that runs.
# shellcheck source=script/test/sync-doc-counts.sh
source "${_ADR_RENUMBER_DIR}/../test/sync-doc-counts.sh"

# Which files can carry a reference at all. Shared with the ADR-numbering
# lint so the verb and the gate cannot disagree about what it swept.
# shellcheck source=script/adr/references.sh
source "${_ADR_RENUMBER_DIR}/references.sh"

# An ADR record's basename: the contract drivers/adr_numbering.sh enforces.
_ADR_RECORD_RE='^[0-9]{8}-.+\.md$'

_renumber_err() {
  {
    printf 'adr renumber: %s\n' "$1"
  } >&2
}

_renumber_usage() {
  {
    printf 'Usage: renumber.sh <record> <to> [root]\n'
    printf '  <record>  the record to move: its number, or its filename\n'
    printf '            when more than one record claims that number.\n'
    printf '  <to>      the number to move it to; must be free.\n'
    printf '  [root]    repo root (default: the enclosing checkout).\n'
  } >&2
}

# _renumber_pad <n> -- <n> as the canonical 8 digits.
_renumber_pad() {
  local _n="$1"
  if [[ ! "${_n}" =~ ^[0-9]{1,8}$ ]]; then
    _renumber_err "'${_n}' is not an ADR number (one to eight digits)."
    return 1
  fi
  # `10#` so a leading zero is decimal and not octal; the arithmetic
  # happens in the expansion because printf's %d does not evaluate one.
  printf '%08d\n' "$(( 10#${_n} ))"
}

# _renumber_claimants <root> <num> -- basenames of the records claiming
# <num>, one per line. The glob runs in a subshell so `nullglob` cannot
# leak into a caller that is not expecting it.
_renumber_claimants() {
  local _root="$1" _num="$2"
  (
    shopt -s nullglob
    local _f
    for _f in "${_root}"/doc/adr/"${_num}"-*.md; do
      printf '%s\n' "${_f##*/}"
    done
  )
}

# _renumber_resolve <root> <arg> -- the basename of the record <arg> names.
# A bare number is accepted only where it is unambiguous; a filename is
# accepted always, which is how an operator names one of two claimants.
_renumber_resolve() {
  local _root="$1" _arg="$2" _num _base
  local -a _claimants=()
  if [[ "${_arg}" =~ ^[0-9]{1,8}$ ]]; then
    _num="$(_renumber_pad "${_arg}")" || return 1
    mapfile -t _claimants < <(_renumber_claimants "${_root}" "${_num}")
    if (( ${#_claimants[@]} == 0 )); then
      _renumber_err "no record claims ${_num}: there is no doc/adr/${_num}-*.md."
      return 1
    fi
    if (( ${#_claimants[@]} > 1 )); then
      _renumber_err "${_num} is claimed by ${#_claimants[@]} records (${_claimants[*]}); name the one to move by filename."
      return 1
    fi
    printf '%s\n' "${_claimants[0]}"
    return 0
  fi
  _base="${_arg##*/}"
  if [[ ! -f "${_root}/doc/adr/${_base}" ]]; then
    _renumber_err "no such record: doc/adr/${_base}"
    return 1
  fi
  if [[ ! "${_base}" =~ ${_ADR_RECORD_RE} ]]; then
    _renumber_err "doc/adr/${_base} is not a record filename (NNNNNNNN-<slug>.md)."
    return 1
  fi
  printf '%s\n' "${_base}"
}

# The population is `_adr_ref_files` (script/adr/references.sh), and the
# whole of it. It is shared with the ADR-numbering lint, so a sweep this
# tool reports complete cannot be one the gate then fails on.
#
# A GENERATED file is not excluded, and the first version of this tool
# excluded it. Running the verb over a copy of the real tree is what
# corrected that: a doc/test catalogue is only PARTLY generated -- the
# paragraph above the fence explaining the level is hand-written, and the
# generator does not own a word of it -- so skipping the file left
# `ADR-00000032` standing in doc/test/acceptance.md's preamble with the
# run reporting success.
#
# So both halves are covered, in this order: every file is rewritten, and
# the generated regions are then REBUILT from the specs. Neither step
# subsumes the other. The rewrite is the only thing that reaches
# hand-written prose inside a generated file; the rebuild is the only
# thing that carries a renamed `@test` into its catalogue row, which a
# substitution on the row would appear to do and the next regeneration
# would revert.

# _renumber_targets <root> <from> -- the files whose references to <from>
# are THIS tree's: the population minus the files that declare <from> one
# of their own fixture numbers.
#
# One definition for the sweep and for the survivor check below, so the
# tool cannot rewrite a file it will then read back with a different idea
# of what counts.
_renumber_targets() {
  local _root="$1" _from="$2" _rel _nums
  local -A _fixture=()
  while IFS=$'\t' read -r _rel _nums; do
    _fixture["${_rel}"]="${_nums}"
  done < <(_adr_ref_fixture_map "${_root}")
  while IFS= read -r _rel; do
    ! _adr_ref_declares "${_fixture[${_rel}]:-}" "${_from}" || continue
    printf '%s\n' "${_rel}"
  done < <(_adr_ref_files "${_root}")
}

# _renumber_patterns <from> <rel> -- the grep -E alternation that finds a
# reference to <from> in <rel>. The bare-number class is only ever offered
# for the index.
_renumber_patterns() {
  local _from="$1" _rel="$2"
  printf 'ADR-%s|adr/%s-' "${_from}" "${_from}"
  if [[ "${_rel}" == 'doc/adr/README.md' ]]; then
    printf '|(^|[^0-9])%s([^0-9]|$)' "${_from}"
  fi
}

# _renumber_rewrite_file <root> <from> <to> <rel> -- rewrite one file,
# printing its path when it changed.
_renumber_rewrite_file() {
  local _root="$1" _from="$2" _to="$3" _rel="$4"
  local _re
  # A symlink has no content of its own: the bytes are the target's, and
  # the target is swept like any other file. Writing through it is not
  # merely redundant, it is destructive -- `sed -i` replaces the link with
  # a regular copy of the target, silently, and reports success. This tool
  # survived that only because base's eight wrapper links sort after their
  # `dist/` targets, so the pattern no longer matched by the time a link
  # was reached. Where the target is NOT in the population, the survivor
  # check below reports the link, which is the honest answer: that
  # reference is not one this verb can repair.
  [[ ! -L "${_root}/${_rel}" ]] || return 0
  _re="$(_renumber_patterns "${_from}" "${_rel}")"
  grep -qIE -e "${_re}" "${_root}/${_rel}" || return 0
  local -a _args=(
    -E -i
    -e "s|ADR-${_from}|ADR-${_to}|g"
    -e "s|adr/${_from}-|adr/${_to}-|g"
  )
  if [[ "${_rel}" == 'doc/adr/README.md' ]]; then
    # The bare-number class, index only. Applied TWICE because the
    # expression consumes the character on each side of the number, so two
    # numbers with a single character between them would leave the second
    # unmatched on the first pass.
    # `/` and not `|` as the delimiter: the expression's own alternation
    # is spelled with pipes, and sed reads the first one as the end of the
    # pattern.
    local _bare="s/(^|[^0-9])${_from}([^0-9]|$)/\\1${_to}\\2/g"
    _args+=( -e "${_bare}" -e "${_bare}" )
  fi
  sed "${_args[@]}" -- "${_root}/${_rel}"
  printf '%s\n' "${_rel}"
}

# _renumber_survivors <root> <from> -- any reference to <from> still in the
# population, as `<file>: <match>` lines.
#
# The self-check, and the reason a 14-file sweep can be trusted to a tool:
# a class nobody thought of shows up here as a failure rather than as a
# green run with a stale pointer.
_renumber_survivors() {
  local _root="$1" _from="$2" _rel _re
  while IFS= read -r _rel; do
    _re="$(_renumber_patterns "${_from}" "${_rel}")"
    grep -qIE -e "${_re}" "${_root}/${_rel}" || continue
    printf '%s\n' "${_rel}"
  done < <(_renumber_targets "${_root}" "${_from}")
}

# _renumber_move <root> <old-base> <new-base> -- rename the record, and
# say so truthfully. Every path here returns the mover's own status: this
# is the one destructive step, and it ran `git mv` followed by an
# unconditional `return 0`, which made it the one step whose failure the
# tool could not see. The survivor check cannot cover for it -- that greps
# for the OLD number, which the sweep has just removed everywhere.
#
# WHICH mover is a question about the record, not about the root. `git mv`
# refuses a path git does not track, and an ADR authored on this branch and
# not yet `git add`ed is exactly the record this verb exists to renumber.
# There, and wherever the root is no checkout at all, a plain `mv` IS the
# move: git has nothing to be told, because it was never told about the
# file.
_renumber_move() {
  local _root="$1" _old="$2" _new="$3"
  if git -C "${_root}" ls-files --error-unmatch -- "doc/adr/${_old}" \
    >/dev/null 2>&1; then
    git -C "${_root}" mv -- "doc/adr/${_old}" "doc/adr/${_new}" || return 1
    return 0
  fi
  mv -- "${_root}/doc/adr/${_old}" "${_root}/doc/adr/${_new}"
}

# _adr_renumber <record> <to> <root> -- the whole flow.
_adr_renumber() {
  local _record="$1" _to_arg="$2" _root="$3"
  local _base _from _to
  if [[ ! -d "${_root}/doc/adr" ]]; then
    _renumber_err "no doc/adr/ under ${_root} -- there is no registry here to renumber."
    return 1
  fi
  _base="$(_renumber_resolve "${_root}" "${_record}")" || return 1
  _to="$(_renumber_pad "${_to_arg}")" || return 1
  _from="${_base:0:8}"

  if [[ "${_from}" == "${_to}" ]]; then
    _renumber_err "doc/adr/${_base} already carries ${_to}."
    return 1
  fi

  # Ambiguity is refused whichever way the record was named: with two
  # records on one number the `ADR-<from>` class cannot be attributed by
  # any rule. See the header.
  local -a _claimants=() _taken=()
  mapfile -t _claimants < <(_renumber_claimants "${_root}" "${_from}")
  if (( ${#_claimants[@]} > 1 )); then
    _renumber_err "${_from} is claimed by ${#_claimants[@]} records (${_claimants[*]}) -- a bare 'ADR-${_from}' in prose names whichever of them its author meant, and nothing here records which. Renumber on the branch instead, where the record is the only claimant of its number, and merge afterwards. Nothing was changed."
    return 1
  fi
  mapfile -t _taken < <(_renumber_claimants "${_root}" "${_to}")
  if (( ${#_taken[@]} > 0 )); then
    _renumber_err "${_to} is already claimed by ${_taken[*]}. Nothing was changed."
    return 1
  fi

  # The rename goes FIRST, and that ordering is the whole of the header's
  # "a refusal leaves nothing half-renumbered". It is the one step that can
  # fail for a reason no precondition can check -- a concurrent
  # `index.lock`, a permission, a repository state -- and a failure after
  # the sweep would leave a tree whose every pointer names a record that is
  # still at its old number. Before it, the same failure leaves the tree
  # exactly as it was found. Nothing depends on the order: the sweep
  # enumerates the population fresh, and the record's own path is the only
  # thing the move changes.
  local _new="${_to}-${_base#*-}"
  if ! _renumber_move "${_root}" "${_base}" "${_new}"; then
    _renumber_err "could not rename doc/adr/${_base} to doc/adr/${_new} (the mover's own message is above). Nothing was changed."
    return 1
  fi

  local -a _changed=()
  local _rel
  while IFS= read -r _rel; do
    _changed+=( "${_rel}" )
  done < <(
    while IFS= read -r _rel; do
      _renumber_rewrite_file "${_root}" "${_from}" "${_to}" "${_rel}"
    done < <(_renumber_targets "${_root}" "${_from}")
  )

  # The generated documents are rebuilt, never rewritten. This is also
  # what carries a renamed `@test` into its catalogue row.
  _sync_doc_counts "${_root}" >/dev/null || return 1

  local -a _left=()
  mapfile -t _left < <(_renumber_survivors "${_root}" "${_from}")
  if (( ${#_left[@]} > 0 )); then
    _renumber_err "the record and ${#_changed[@]} file(s) were rewritten, but a reference to ${_from} survives in: ${_left[*]}. That is a class of reference this tool does not know about -- fix those by hand and report it."
    return 1
  fi

  printf 'adr renumber: doc/adr/%s -> doc/adr/%s\n' "${_base}" "${_new}"
  local _c
  for _c in "${_changed[@]+"${_changed[@]}"}"; do
    printf 'adr renumber: rewrote %s\n' "${_c}"
  done
  printf 'adr renumber: %s reference file(s) rewritten; generated documents regenerated.\n' \
    "${#_changed[@]}"
}

main() {
  local _record="${1:-}" _to="${2:-}" _root="${3:-}"
  if [[ "${_record}" == '-h' || "${_record}" == '--help' ]]; then
    _renumber_usage
    return 0
  fi
  if [[ -z "${_record}" || -z "${_to}" ]]; then
    _renumber_usage
    return 1
  fi
  if [[ -z "${_root}" ]]; then
    _root="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
  fi
  _adr_renumber "${_record}" "${_to}" "${_root}"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
