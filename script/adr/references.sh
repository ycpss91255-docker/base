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
# Style: Google Shell Style Guide.

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
_adr_ref_files() {
  local _root="$1" _rel
  while IFS= read -r _rel; do
    [[ -f "${_root}/${_rel}" ]] || continue
    printf '%s\n' "${_rel}"
  done < <(_adr_ref_candidates "${_root}")
}
