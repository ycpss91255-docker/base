#!/usr/bin/env bash
#
# references.sh - which files in a tree can carry a reference to the ADR
# registry. Sourced by both tools that ask, and that is the point:
#
#   script/adr/renumber.sh          rewrites the references
#   script/test/drivers/adr_numbering.sh   fails on the stale ones
#
# ── Why one definition and not two ──────────────────────────────────────
#
# They had two, and they disagreed. The verb swept `git ls-files`; the
# lint grepped the whole filesystem under the scan root with only `.git`
# excluded. So `just adr renumber` could report a complete sweep, with its
# own survivor self-check green, and the lint would then fail on files the
# verb deliberately never reaches -- `.prev-release/`, the materialised
# old releases this repo's own .gitignore parks at the root so that "an
# old release inside one of those roots would be linted as if it were
# current source" cannot happen, and `log/`, the wrapper transcripts the
# test suite itself writes. A red gate with no repair path through the
# documented verb, on a repair that was actually complete.
#
# A derived tree is not a reference this repo keeps true, and rewriting
# one would be worse than skipping it: an old release and a transcript are
# records of what WAS said, and editing them falsifies the record.
#
# ── How the population is decided ───────────────────────────────────────
#
# Ask git where git can answer: the tracked files are exactly "what this
# repo keeps true", and no rule here can be more accurate than that.
#
# Where it cannot -- a fixture tree that is no checkout, or the real
# checkout seen from inside the test container, where a worktree's `.git`
# is a file naming a gitdir that was never mounted -- walk the filesystem
# and prune what the tree DECLARES derived: the plain directory patterns
# in the root `.gitignore`. That is a reader of the repo's own
# declaration, not a second opinion about what is derived.
#
# The residue, stated rather than papered over: only the ROOT .gitignore
# is read, and only its unambiguous directory patterns (`name/`,
# `/name/`) -- no wildcards, no negations, no nested .gitignore files.
# Anything more expressive is git's business, and where git is available
# it is git that answers. The effect of missing one is a file scanned that
# git would have skipped, which is the behaviour this fallback replaces
# rather than a new failure.
#
# ── A file that builds its own registry ─────────────────────────────────
#
# A lint spec constructs a throwaway `doc/adr/` under a temp root. Its
# `ADR-NNNNNNNN` tokens and `doc/adr/NNNNNNNN-<slug>.md` paths name THAT
# registry, never this one, and both tools have to know it: the lint would
# report every fixture as a dangling reference, and the verb would rewrite
# the fixtures out from under the assertions that guard it.
#
# It is DECLARED, not guessed. The guess was a two-character lookback in
# the lint -- a path preceded by `}` was taken for a shell expansion and
# therefore a fixture -- and it was wrong in both directions at once: it
# read `"${REPO}/doc/adr/00000008-coverage-sharded-pr-gate.md"`, a live
# pointer into this tree's own registry, as somebody's fixture, and it
# would have read an unbraced `"$SCRATCH/doc/adr/..."` as a reference. A
# rule whose default on the shape it does not recognise is "pass" is not a
# check.
#
# The verb made the same distinction a THIRD way, per class: it rewrote
# the `ADR-<n>` and `adr/<n>-` forms inside a lint spec while leaving the
# bare numbers that spec passes to it as ARGUMENTS alone. Renumbering
# 00000030 therefore rewrote adr_renumber_spec.bats's fixture record and
# its assertions but not its `renumber.sh 00000030 00000032` lines, so the
# setup and the command named different records -- with the tool's own
# survivor check and the lint both reporting clean.
#
# ── What the declaration is ABOUT: numbers, not the file ────────────────
#
# The declaration first dropped the whole FILE, on the reading that a file
# is either this tree's or its own. That reading is false, and both of
# this tree's declaring specs falsify it. adr_structure_spec.bats builds
# fixture records AND names, in a comment, the real record whose three
# column-0 Status lines the check was written for. adr_numbering_spec.bats
# builds fixture registries AND carries a `# why:` block citing
# `doc/adr/00000008-coverage-sharded-pr-gate.md` -- a marker the generator
# publishes VERBATIM as a doc/test catalogue row, which is a file in this
# population.
#
# Whole-file, that second one has no consistent state at all: the sweep
# rewrites the generated row, `_sync_doc_counts` regenerates it from the
# marker the sweep may not touch, the old number comes straight back, and
# the verb aborts on a survivor -- with the record already moved, 25 files
# rewritten, and no message naming the marker that produced the row. The
# first one is quieter and worse: neither tool sees the pointer, so it
# goes stale under a green gate.
#
# So the declaration names the NUMBERS whose references in this file are
# the file's own. A reference carrying one of them is dropped in every
# class -- token, path, and the bare arguments a spec passes to the verb --
# which is what the per-class guess got wrong. A reference carrying any
# other number is this tree's, and is swept and checked like any other.
#
# The default is now the SAFE direction. Whole-file, an unlisted live
# pointer was silently exempt; per-number, an undeclared fixture number is
# rewritten and, where it names no record, reported -- loudly, by the lint
# that reads the same declaration.
#
# The marker is a comment line whose whole content is `adr-refs:`, the
# word `fixture`, and one or more 8-digit numbers (see
# _ADR_REF_FIXTURE_RE). Whole-line, so that a sentence about the marker --
# this one -- is not one. A file may carry several; their numbers add up.
#
# The residue, stated rather than papered over. A declaration this reader
# cannot parse exempts NOTHING, which is why the lint reports one
# (_adr_ref_bad_markers): a marker that has quietly stopped protecting the
# fixtures it was written for is the failure the declaration exists to
# remove. A fixture number that IS a real record's number and is left
# undeclared is rewritten in the token and path classes and not in the
# bare-argument one -- the pre-existing failure, reached only by omitting
# the one line that prevents it, and visible as a spec whose setup and
# command name different records. And a file in a language with no `#`
# comment cannot declare itself; none of this tree's registry-building
# fixtures is in one.
#
# Style: Google Shell Style Guide.

# The fixture declaration: a comment line naming the numbers this file's
# references are its own, and nothing else on it.
_ADR_REF_FIXTURE_RE='^[[:space:]]*#[[:space:]]*adr-refs:[[:space:]]*fixture([[:space:]]+[0-9]{8})+[[:space:]]*$'

# Any line that OPENS a declaration, well-formed or not. A line that
# matches this and not the above is a declaration this reader cannot
# read, and the lint says so rather than treating it as an exemption.
_ADR_REF_MARKER_RE='^[[:space:]]*#[[:space:]]*adr-refs:'

# _adr_ref_ignored_dirs <root> -- the directories <root>/.gitignore
# declares derived, as `anchored<TAB><path>` (root-relative, matched
# there only) or `anywhere<TAB><name>` (matched at any depth), one per
# line. Only unambiguous directory patterns are read; see the header.
_adr_ref_ignored_dirs() {
  local _root="$1" _line
  [[ -f "${_root}/.gitignore" ]] || return 0
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    _line="${_line%$'\r'}"
    _line="${_line%"${_line##*[![:space:]]}"}"
    [[ "${_line}" == */ ]] || continue
    [[ "${_line}" != '#'* && "${_line}" != '!'* ]] || continue
    [[ "${_line}" != *[*?\[]* ]] || continue
    _line="${_line%/}"
    if [[ "${_line}" == */* ]]; then
      printf 'anchored\t%s\n' "${_line#/}"
    else
      printf 'anywhere\t%s\n' "${_line}"
    fi
  done < "${_root}/.gitignore"
}

# _adr_ref_walk <root> -- every regular file under <root> that the tree
# does not declare derived, one root-relative path per line. The fallback
# for a root git cannot answer for.
_adr_ref_walk() {
  local _root="$1" _kind _name
  local -a _expr=( '(' -name '.git' )
  while IFS=$'\t' read -r _kind _name; do
    case "${_kind}" in
      anchored) _expr+=( -o -path "./${_name}" ) ;;
      anywhere) _expr+=( -o -name "${_name}" ) ;;
    esac
  done < <(_adr_ref_ignored_dirs "${_root}")
  _expr+=( ')' -prune -o -type f -print )
  ( cd -- "${_root}" && find . "${_expr[@]}" ) | sed 's|^\./||'
}

# _adr_ref_candidates <root> -- the population before the fixture
# declarations are read. git where git can answer, the walk otherwise; an
# empty answer from git is treated as no answer, because a root that is
# inside a checkout without being one of its tracked directories would
# otherwise come back as a tree with nothing in it.
_adr_ref_candidates() {
  local _root="$1"
  local -a _tracked=()
  if git -C "${_root}" rev-parse --git-dir >/dev/null 2>&1; then
    mapfile -t _tracked < <(git -C "${_root}" ls-files 2>/dev/null)
  fi
  if (( ${#_tracked[@]} > 0 )); then
    printf '%s\n' "${_tracked[@]}"
    return 0
  fi
  _adr_ref_walk "${_root}"
}

# _adr_ref_files <root> -- every file under <root> that can carry a
# reference to THIS tree's ADR registry, one root-relative path per line.
# The answer both tools use, so that neither can be right about a file the
# other is wrong about.
#
# A file that declares fixture numbers is in this population like any
# other; what its declaration exempts is looked up per reference, against
# _adr_ref_fixture_map.
_adr_ref_files() {
  local _root="$1" _rel
  while IFS= read -r _rel; do
    [[ -f "${_root}/${_rel}" ]] || continue
    printf '%s\n' "${_rel}"
  done < <(_adr_ref_candidates "${_root}")
}

# _adr_ref_fixture_map <root> -- `<rel><TAB><num> <num>...` for every file
# in the population that carries a declaration, one per line. A file whose
# declarations name no number appears with an empty list, because a
# declaration that names nothing exempts nothing.
#
# Two passes rather than one grep per file: the marker is rare and the
# population is the tree, so the first pass finds the handful of files
# that carry one and the second reads only those.
_adr_ref_fixture_map() {
  local _root="$1" _rel _nums
  local -a _all=() _marked=()
  while IFS= read -r _rel; do
    _all+=( "${_rel}" )
  done < <(_adr_ref_files "${_root}")
  (( ${#_all[@]} > 0 )) || return 0
  mapfile -t _marked < <(
    cd -- "${_root}" || exit 0
    grep -lIE -e "${_ADR_REF_MARKER_RE}" -- "${_all[@]}" 2>/dev/null || true
  )
  for _rel in "${_marked[@]+"${_marked[@]}"}"; do
    [[ -n "${_rel}" ]] || continue
    _nums="$(
      grep -hIE -e "${_ADR_REF_FIXTURE_RE}" -- "${_root}/${_rel}" 2>/dev/null \
        | grep -oE '[0-9]{8}' | LC_ALL=C sort -u | tr '\n' ' '
    )"
    printf '%s\t%s\n' "${_rel}" "${_nums% }"
  done
}

# _adr_ref_declares <fixture-list> <num> -- whether a file whose declared
# numbers are <fixture-list> (a space-separated list, possibly empty)
# claims <num> as its own. The one reading of the list, so the verb and
# the lint cannot spell the membership test differently.
_adr_ref_declares() {
  local _list="$1" _num="$2"
  [[ " ${_list} " == *" ${_num} "* ]]
}

# _adr_ref_bad_markers <root> -- `<rel>:<line>:<text>` for every line that
# opens a declaration this reader cannot parse, one per line.
#
# Reported rather than tolerated: an unreadable declaration exempts
# nothing, so the fixtures it was written for are being swept and checked
# as if they were this tree's. That is the safe direction to fail in, and
# saying so is what keeps it from being discovered by a rewritten fixture.
_adr_ref_bad_markers() {
  local _root="$1" _rel _hit _text
  local -a _all=()
  while IFS= read -r _rel; do
    _all+=( "${_rel}" )
  done < <(_adr_ref_files "${_root}")
  (( ${#_all[@]} > 0 )) || return 0
  while IFS= read -r _hit; do
    # `<rel>:<line>:<text>`; the text is what follows the second colon.
    _text="${_hit#*:}"
    _text="${_text#*:}"
    [[ ! "${_text}" =~ ${_ADR_REF_FIXTURE_RE} ]] || continue
    printf '%s\n' "${_hit}"
  done < <(
    cd -- "${_root}" || exit 0
    grep -HnIE -e "${_ADR_REF_MARKER_RE}" -- "${_all[@]}" 2>/dev/null || true
  )
}
