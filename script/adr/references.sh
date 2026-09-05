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
# One rule, in two tiers that have to answer the same: every file under the
# root that the tree does not DECLARE derived. Not "every file git tracks".
#
# The difference is untracked files, and it matters because only one of the
# two tiers can ask git. `git ls-files` alone drops a file that is in the
# working tree and not yet in the index; the walk has no way to tell one
# from a tracked one and keeps it. And the WALK is the tier the local gate
# takes -- `just test` reads this checkout from inside the container, where
# a worktree's `.git` is a file naming a gitdir that was never mounted, so
# `git rev-parse` fails there by construction. Tracked-only therefore
# reproduced the very split this file exists to close, one tier over: a
# scratch note carrying a dangling `ADR-NNNNNNNN` reddened `just test lint
# --adr-numbering` and `just adr renumber`, which runs on the host where
# git DOES answer, never swept it. A red gate with no repair path through
# the verb, again. Not yet tracked is not derived -- and it is the state a
# freshly authored ADR and every reference to it are in.
#
# So git is asked for the tracked files AND the untracked ones it does not
# exclude (`--others --exclude-standard`), which is git's own reading of
# the tree's declaration and strictly better than this file's. Where git
# cannot answer at all -- a fixture tree that is no checkout, or the
# container case above -- the walk prunes what the root `.gitignore`
# declares derived. That is a reader of the repo's own declaration, not a
# second opinion about what is derived.
#
# Only the ROOT .gitignore is read, and the effect of a pattern it fails
# to apply is a file scanned that git would have skipped -- which is not
# harmless, and was not: requiring a trailing slash left `.claude` and
# `CLAUDE.md`, the two this repo's own root .gitignore writes without one,
# in this lint's population and out of the verb's, which is a finding no
# documented command can clear.
#
# So the reader applies every form it can apply EXACTLY, and REPORTS the
# rest rather than skipping them. The line between the two is not a
# judgement about how likely a form is; it is whether `find`'s matcher and
# git's agree on it:
#
#   applied     a plain path (`name`, `name/`, `/name`, `dir/name`), and a
#               wildcard with no separator (`*.swp`). git matches a
#               separator-less pattern against the basename at any depth
#               with fnmatch, which is `find -name`, character for
#               character.
#   reported    a negation, a wildcard beside a separator, and a nested
#               .gitignore. git's `*` stops at a `/` and find's `-path`
#               does not, no prune expression re-includes what an earlier
#               one excluded, and a per-directory file is a rule this
#               reader never opens. Each would silently widen the walk's
#               population past the verb's.
#
# And the root .gitignore is not the whole declaration either.
# `--exclude-standard` is THREE files: that one, `<gitdir>/info/exclude`,
# and whatever `core.excludesFile` names. The other two are reported by
# the same rule and for the same reason (_adr_ref_other_excludes), with
# one addition -- `core.excludesFile` is per USER, so applying it would
# make this lint answer differently in the container and on the host from
# a file that is not in the tree and that no diff can show.
#
# Reported and not modelled, deliberately. A shell reimplementation of
# gitignore would be right about the forms someone thought of and wrong
# in silence about the rest, which is the failure mode this file exists
# to remove -- whereas a tree told which line to spell differently has a
# repair it can make. The report fires only in the WALK tier: where git
# answers, git applies all of it, and a finding there would name a
# declaration nothing gets wrong. base's own root .gitignore is inside the
# applied set today, `*.swp` and `*.swo` included.
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

# _adr_ref_ignored_paths <root> -- every line of <root>/.gitignore this
# reader has an opinion about, as `<kind><TAB><lineno><TAB><text>`:
#
#   anchored   a root-relative path, matched there only.
#   anywhere   a name (or a separator-less wildcard), matched at any depth.
#   negation   a `!` line. NOT applied -- reported.
#   deep-glob  a wildcard beside a separator. NOT applied -- reported.
#
# The two reported kinds are here rather than dropped so that ONE pass
# over the file decides both what the walk prunes and what it cannot
# promise, and neither list can go stale against the other. See the
# header for why they are reported instead of modelled.
#
# A trailing slash means "a directory and not a file", which is a
# distinction this reader does not need to make: pruning the name reaches
# whichever of the two is there. It is therefore STRIPPED rather than
# required -- git needs none, and this repo's own root .gitignore writes
# `.claude` and `CLAUDE.md` without one, so requiring it left two paths
# the tree declares derived in the lint's population and out of the
# verb's.
_adr_ref_ignored_paths() {
  local _root="$1" _line _text _n=0
  [[ -f "${_root}/.gitignore" ]] || return 0
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    _n=$(( _n + 1 ))
    _line="${_line%$'\r'}"
    _line="${_line%"${_line##*[![:space:]]}"}"
    [[ "${_line}" != '#'* ]] || continue
    [[ -n "${_line}" ]] || continue
    _text="${_line}"
    if [[ "${_line}" == '!'* ]]; then
      printf 'negation\t%s\t%s\n' "${_n}" "${_text}"
      continue
    fi
    _line="${_line%/}"
    [[ -n "${_line}" ]] || continue
    # A wildcard is applied only where git's matcher and find's are the
    # same one: with no separator, both fnmatch the basename. With a
    # separator git's `*` stops at the next `/` and find's `-path` does
    # not, so that form is reported instead of approximated.
    if [[ "${_line}" == *[*?\[]* && "${_line}" == */* ]]; then
      printf 'deep-glob\t%s\t%s\n' "${_n}" "${_text}"
      continue
    fi
    if [[ "${_line}" == /* ]]; then
      printf 'anchored\t%s\t%s\n' "${_n}" "${_line#/}"
    elif [[ "${_line}" == */* ]]; then
      printf 'anchored\t%s\t%s\n' "${_n}" "${_line}"
    else
      printf 'anywhere\t%s\t%s\n' "${_n}" "${_line}"
    fi
  done < "${_root}/.gitignore"
}

# _adr_ref_has_rules <file> -- whether <file> carries at least one line
# that is a rule rather than a blank or a comment.
#
# The boundary that keeps the report below from being noise: git seeds
# every checkout's `.git/info/exclude` with comments and nothing else, and
# a declaration that declares nothing is a finding with no repair to make.
_adr_ref_has_rules() {
  local _file="$1" _line
  [[ -f "${_file}" ]] || return 1
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    _line="${_line%$'\r'}"
    _line="${_line#"${_line%%[![:space:]]*}"}"
    _line="${_line%"${_line##*[![:space:]]}"}"
    [[ -n "${_line}" ]] || continue
    [[ "${_line}" == '#'* ]] || return 0
  done < "${_file}"
  return 1
}

# _adr_ref_other_excludes <root> -- the exclude declarations git applies to
# <root> that are NOT the root .gitignore and that this reader can SEE, one
# absolute path per line.
#
# `--exclude-standard` is THREE files, not one: the root `.gitignore`,
# `<gitdir>/info/exclude`, and whatever `core.excludesFile` names. The git
# tier applies all three. This reader opens only the first, so a path
# excluded by either of the others is read by the walk and never swept by
# `just adr renumber` -- the nested-`.gitignore` split again, by the same
# mechanism, and the reason the two are reported here.
#
# REPORTED and not applied, and the two have different reasons.
# `core.excludesFile` is per USER: applying it would make this lint answer
# differently in the container and on the host, from a file that is not in
# the tree at all and that no diff can show. `info/exclude` is per
# CHECKOUT and equally invisible in a diff, so the repair for both is the
# same one every other finding here asks for -- spell the rule in the root
# `.gitignore`, where both tiers read it and a reviewer can see it.
#
# The residue, stated rather than papered over: this reports what it can
# SEE. Where `.git` is a file naming a gitdir that was never mounted --
# a worktree read from inside the test container, which is the tier this
# whole fallback exists for -- there is no exclude file to open and none
# is reported. Nothing can be said about a declaration that is not there
# to read, and saying it anyway would be a permanent finding with no
# repair.
_adr_ref_other_excludes() {
  local _root="$1" _gitdir='' _line _global
  if [[ -d "${_root}/.git" ]]; then
    _gitdir="${_root}/.git"
  elif [[ -f "${_root}/.git" ]]; then
    # `gitdir: <path>`, absolute in every worktree git writes, but the
    # format permits a relative one and it is resolved against the root.
    _line="$(sed -n 's/^gitdir: //p' "${_root}/.git" 2>/dev/null | head -n 1)"
    if [[ -n "${_line}" ]]; then
      _gitdir="${_line}"
      [[ "${_gitdir}" == /* ]] || _gitdir="${_root}/${_gitdir}"
    fi
  fi
  if [[ -n "${_gitdir}" ]] \
    && _adr_ref_has_rules "${_gitdir}/info/exclude"; then
    printf '%s\n' "${_gitdir}/info/exclude"
  fi
  # `-C <root>`, and not a bare `git config`: the question is which global
  # file applies to THIS root, and a bare call discovers the repository
  # from the CALLER's directory. That is fatal where the caller stands in
  # a worktree whose gitdir was never mounted -- which is the tier this
  # whole function reports about -- so the answer would depend on where
  # the lint was invoked from. Scoped to the root, a failure means only
  # that git cannot be asked here, and nothing is reported.
  _global="$(git -C "${_root}" config --get core.excludesFile 2>/dev/null \
    || true)"
  [[ -n "${_global}" ]] || return 0
  [[ "${_global}" != '~/'* ]] || _global="${HOME:-}/${_global#\~/}"
  ! _adr_ref_has_rules "${_global}" || printf '%s\n' "${_global}"
}

# _adr_ref_walk <root> -- every file under <root> that the tree does not
# declare derived, one root-relative path per line. The fallback for a
# root git cannot answer for.
#
# Symlinks are printed as well as regular files, because `git ls-files`
# reports them and the two tiers have to name one population -- this
# tree's eight wrapper links carry ADR tokens between them. `_adr_ref_files`
# then drops the ones that do not resolve to a file, which is what keeps a
# broken link and a link to a directory out.
_adr_ref_walk() {
  local _root="$1" _kind _lineno _name
  local -a _expr=( '(' -name '.git' )
  while IFS=$'\t' read -r _kind _lineno _name; do
    case "${_kind}" in
      # `-path` and `-name` are find's own fnmatch, which is git's for
      # these two kinds. The kinds this reader cannot apply are not
      # approximated here; they are reported (_adr_ref_unreadable_ignores).
      anchored) _expr+=( -o -path "./${_name}" ) ;;
      anywhere) _expr+=( -o -name "${_name}" ) ;;
    esac
  done < <(_adr_ref_ignored_paths "${_root}")
  _expr+=( ')' -prune -o '(' -type f -o -type l ')' -print )
  ( cd -- "${_root}" && find . "${_expr[@]}" ) | sed 's|^\./||'
}

# _adr_ref_candidates <root> -- the population before the fixture
# declarations are read. git where git can answer, the walk otherwise; an
# empty answer from git is treated as no answer, because a root that is
# inside a checkout without being one of its tracked directories would
# otherwise come back as a tree with nothing in it.
#
# That is the same rule project_reclaim.sh states for the same shape ("a
# failed listing is not evidence that nothing is labelled"), and it fails
# the same way if it goes: the probe succeeds anywhere inside a checkout,
# so a scan root the checkout declares derived -- a materialised release
# under .prev-release/, a vendored tree -- answers it and lists nothing,
# and a lint handed no files is clean over anything. Removing the guard
# left the whole suite green until adr_numbering_spec's "a root git
# answers for but lists nothing is not an empty tree" was written, which
# is the case that now refuses it.
#
# `--others --exclude-standard` alongside the tracked files, and not
# `ls-files` bare: the question is which files the tree does not declare
# derived, and an untracked one answers it the same way a tracked one does.
# See the header for the split the bare form produced between this tier and
# the walk -- and note that the exclusion here is git's own, which reads
# nested .gitignore files, negations and `info/exclude` that the walk's
# reader deliberately does not.
_adr_ref_git_files() {
  local _root="$1"
  git -C "${_root}" rev-parse --git-dir >/dev/null 2>&1 || return 0
  git -C "${_root}" ls-files --cached --others --exclude-standard 2>/dev/null
}

_adr_ref_candidates() {
  local _root="$1"
  local -a _tracked=()
  mapfile -t _tracked < <(_adr_ref_git_files "${_root}")
  if (( ${#_tracked[@]} > 0 )); then
    printf '%s\n' "${_tracked[@]}"
    return 0
  fi
  _adr_ref_walk "${_root}"
}

# _adr_ref_unreadable_ignores <root> -- `<location><TAB><text>` for every
# declaration the walk cannot apply, one per line, and NOTHING where git
# answers for <root>.
#
# The tier test is `_adr_ref_git_files`, the same call `_adr_ref_candidates`
# decides the population with, so this cannot report about a tier the
# population was not taken from. Where git answers it applies negations,
# deep globs and nested files itself, and a finding there would name a
# declaration nothing gets wrong.
#
# What it reports is not a defect in the tree: it is this reader saying
# its population is WIDER than the verb's, so a reference finding may name
# a file `just adr renumber` never sweeps. That is the whole failure the
# shared reader exists to prevent, and the only honest alternatives were
# to model gitignore in shell (wrong in silence about the forms nobody
# thought of) or to go on skipping the line (wrong in silence about all
# of them).
_adr_ref_unreadable_ignores() {
  local _root="$1" _kind _lineno _text _rel _path
  local -a _git=()
  mapfile -t _git < <(_adr_ref_git_files "${_root}")
  (( ${#_git[@]} == 0 )) || return 0
  # The two declarations that are not a `.gitignore` at all. See
  # _adr_ref_other_excludes.
  while IFS= read -r _path; do
    printf '%s\ta declaration git applies and this reader does not open\n' \
      "${_path}"
  done < <(_adr_ref_other_excludes "${_root}")
  while IFS=$'\t' read -r _kind _lineno _text; do
    case "${_kind}" in
      negation|deep-glob)
        printf '.gitignore:%s\t%s\n' "${_lineno}" "${_text}"
        ;;
    esac
  done < <(_adr_ref_ignored_paths "${_root}")
  # A nested file, found through the walk itself so that one inside a
  # pruned directory -- a materialised release under .prev-release/ --
  # is not reported: the walk does not read that tree either.
  while IFS= read -r _rel; do
    [[ "${_rel}" == */.gitignore ]] || continue
    printf '%s\ta per-directory declaration; only the root one is read\n' \
      "${_rel}"
  done < <(_adr_ref_walk "${_root}")
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
