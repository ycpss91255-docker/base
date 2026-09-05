#!/usr/bin/env bash
# drivers/adr_numbering.sh - ADR-numbering per-tool driver for the
# self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_adr_numbering, the enforcer that keeps the ADR registry (the
# filesystem, doc/adr/NNNNNNNN-<slug>.md) duplicate-free and well-formed.
#
# Contract: runs INSIDE the ci (test-tools) container where test.sh
# invokes it. References ${REPO_ROOT} (a global exported by test.sh).
# Follows drivers/issueref.sh conventions (sourced lib, uses ${REPO_ROOT},
# _log_* / _die, no main).
#
# The registry is the filesystem. ADR files live at
# doc/adr/NNNNNNNN-<slug>.md (8-digit zero-padded number + kebab slug).
# doc/adr/README.md (the ADR index / PRD audit) is the one conventional
# non-ADR file in the registry dir and is exempt from the naming contract.
# The lint reads doc/adr/*.md and:
#   - FAILS (non-zero) on a DUPLICATE ADR number (two files sharing
#     NNNNNNNN). This is the primary defect -- two PRs once authored the
#     same ADR number in parallel, caught only by manual inspection.
#   - FAILS (non-zero) on a MALFORMED ADR filename (not matching
#     ^[0-9]{8}-.+\.md$).
#   - WARNS (still exit 0) on a numbering GAP (a missing number in the
#     min..max run). A gap must NOT block CI -- an intentional gap exists
#     in the live tree. The gap is printed as an advisory line only.
#   - Exits 0 clean on a well-formed, duplicate-free set (gaps allowed).
# Fail-loud messages name exactly which file(s)/number(s) are wrong.

# ── The pointers into the registry (base#1021) ──────────────────────────
#
# A registry nothing points at is half a registry, and the half this lint
# used to read was the filesystem alone. What that missed: nothing
# allocates an ADR number, so three branches took 00000030 on one day,
# each of them right by the only rule there is. The duplicate reached this
# lint. The REPAIR did not: renumbering one of them touched 14 files, and
# three of the sites were left naming the old number -- the index row, and
# two of the audit conclusions -- with every gate green, because a stale
# number in prose is read by nothing.
#
# Four checks, and what each catches:
#
#   dangling    `ADR-NNNNNNNN` naming a number no record claims. What a
#               renumber leaves behind once the old number is free.
#   mispaired   a `doc/adr/NNNNNNNN-<slug>.md` path that names no file.
#               The number may still resolve -- another record took it --
#               and the slug beside it is what says the pointer no longer
#               names what its author meant.
#   index       doc/adr/README.md: exactly one row per record, no row
#               without a record, and no bare number that no record claims
#               anywhere the document ENUMERATES -- which is every line
#               except the prose sections named in _ADR_INDEX_PROSE_RE.
#               The site the hand renumber actually missed, twice, and
#               both times it was a conclusion bullet rather than a row,
#               which is why the row's opening number is not the whole
#               check. The prose exception is where the document
#               deliberately names a number no record claims (the
#               intentional 00000009 gap), and the verb can rewrite it
#               safely only because the number IT moves has a record by
#               construction.
#   declaration a fixture declaration this reader cannot parse. It exempts
#               nothing, which is the safe direction to fail in and
#               exactly why it is worth saying out loud: the alternative
#               is a marker that has silently stopped protecting the
#               fixtures it was written for.
#   captive     a declared number the declaring file PUBLISHES. The
#               declaration is per file, and the doc/test generator copies
#               a spec's blurb, its test descriptions and its test NAMES
#               verbatim into a catalogue that declares nothing -- so the
#               number arrives there as a reference to this tree, the verb
#               rewrites the row, the regeneration puts it straight back
#               from the marker the verb may not touch, and the run aborts
#               half-way. The finding names the marker, because the row is
#               generated and a hand edit to it is undone by the next
#               `just test sync-docs`.
#
# WHAT IS NOT CHECKED, said out loud because the gap is the interesting
# part. A prose `ADR-NNNNNNNN` whose number EXISTS but names a different
# record than its author meant is indistinguishable, in a checkout, from a
# correct one: the number resolves, and only the author knew which record
# they had in mind. That is precisely what a missed reference looks like
# after a collision is repaired by renumbering one of two claimants -- and
# it is an argument for renumbering ON THE BRANCH, where the number has
# one claimant and the rewrite is mechanical (script/adr/renumber.sh), not
# for a lint that guesses.
#
# Non-canonical spellings (`ADR-3`, `ADR-0011`, both live in this tree)
# are not references for this purpose. Eight digits is the filename
# contract; widening the pattern to shapes the registry never uses would
# trade precision for guesswork.
#
# WHICH FILES are read is script/adr/references.sh's answer, shared with
# the verb that repairs these findings, and it is also where a file that
# builds its own throwaway registry declares the NUMBERS that registry
# uses. Both halves were once decided here and decided differently: this
# lint read the whole filesystem while the verb swept the tracked files,
# and it guessed at a fixture from a brace two characters back. See that
# file -- including why the declaration is about numbers and not about
# the file, which a spec that builds fixtures AND cites a live record
# settles.
#
# The index checks run where doc/adr/README.md enumerates records at all:
# a row, or the audit table's header. A README with neither is not an
# index, which is the fixture case and also the honest reading. Either
# signal, and not the header alone, because the header is a LITERAL and
# renaming one column heading turned all four checks off in silence -- an
# input the guard was not written for, in an edit that reads as a
# typographical tidy-up.
#
# The residue is stated rather than hidden: deleting the table -- every row
# AND the header -- disables the checks. That is a whole document's spine
# going missing in a diff, where a single missed row is invisible, and the
# invisible one is what this is for.

# ── ADR-numbering lint ───────────────────────────────────────────────────────

# Which files can carry a reference. Shared with script/adr/renumber.sh,
# the verb that rewrites them, because a lint whose population is wider
# than the verb's fails on files no documented command can repair -- see
# that file's header for the two the disagreement actually produced.
_ADR_NUMBERING_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=script/adr/references.sh
source "${_ADR_NUMBERING_DIR}/../../adr/references.sh"
# The two readers the `captive` check below needs, sourced rather than
# re-implemented: which files the catalogue generator reads, and what it
# publishes out of each one. A second copy of either would agree on the
# day it was pasted and drift after -- and this check is precisely about
# text that travels from a spec into a generated document, so it has to
# ask the reader that moves it.
# shellcheck source=script/test/spec-scan.sh
source "${_ADR_NUMBERING_DIR}/../spec-scan.sh"
# shellcheck source=script/test/spec-markers.sh
source "${_ADR_NUMBERING_DIR}/../spec-markers.sh"

# Well-formed ADR basename: 8-digit zero-padded number, a dash, a non-empty
# slug, and the .md extension. Anything else is a malformed filename.
readonly _ADR_NAME_RE='^[0-9]{8}-.+\.md$'

# The reference vocabulary. The token form is the common one; the path
# form is the one that carries a slug.
readonly _ADR_TOKEN_SCAN_RE='ADR-[0-9]{8}'
# No lookback, and no attempt to tell a fixture path from a real one by
# how it is spelled. That was tried: a path preceded by `}` was read as a
# shell expansion and therefore as somebody's throwaway registry, which
# dropped `"${REPO}/doc/adr/00000008-coverage-sharded-pr-gate.md"` -- a
# live pointer into this tree's own registry -- unchecked. A file that
# builds a registry declares the NUMBERS it uses instead
# (script/adr/references.sh); a reference carrying one of them is skipped
# and every other reference in that file is read like any other.
readonly _ADR_PATH_SCAN_RE='doc/adr/[0-9]{8}-[A-Za-z0-9._-]+\.md'
# The audit table: a row opens with the number of the record it is about,
# and its header is the document's own label for the table.
#
# EITHER of them marks the document as the index, and that is the whole
# reason both are here. The header alone was the gate, and it is a
# literal: renaming one column heading turned all four index checks off
# with "proceed" as the default, in an edit that reads as a typographical
# tidy-up. What makes a README the index is that it ENUMERATES records, so
# a row is the honest signal; the header stays beside it because deleting
# every row would otherwise disable the missing-row check, which is the
# one that reports a table emptied by accident.
readonly _ADR_INDEX_HEADER_RE='^\| ADR \| Verdict \|'
readonly _ADR_INDEX_ROW_RE='^\| ([0-9]{8}) '
# The index's OTHER numbers: the ones a row or a conclusion carries
# without an `ADR-` in front. Digit RUNS, so a longer number is not read as
# eight digits with something after it.
readonly _ADR_INDEX_RUN_RE='[0-9]+'
# WHERE those are read: every row, and every line outside the sections
# this document reserves for PROSE. A table row is about a record from its
# first cell to its last, so a `keep (amended by 00000023)` three columns
# along is a pointer like any other; the audit conclusion is a second
# listing of the same records, and it is where the 00000030 hand repair
# was actually left incomplete -- twice, in bullets no row check reads.
#
# The exception, and the one place the verb's rule and this lint's part
# company. The verb rewrites a bare number anywhere here, and that is safe
# for it by construction: the number it rewrites has exactly one record (it
# refuses otherwise), so every occurrence names that record. This lint asks
# the opposite question -- which numbers name NO record -- and the document
# answers it deliberately in prose: "`00000009` is an intentional gap ...
# do not invent a `00000009`", under Anomalies, twice.
#
# So Anomalies is named and everything else is read, rather than the
# conclusion being named and everything else skipped. Both spellings pass
# today; they differ in which way a rename fails. Gated on
# `## Audit conclusion`, renaming that heading turned the scan off in
# silence -- and it guards exactly the two sites the hand repair missed.
# Excepting `## Anomalies` instead, renaming THAT heading makes the
# deliberate gap a finding: loud, immediately, on the line that moved.
# The residue is unchanged in kind and smaller: a stale number in a prose
# section this list names is not caught.
readonly _ADR_INDEX_PROSE_RE='^## Anomalies'
readonly _ADR_INDEX_SECTION_RE='^## '
# The two classes _adr_ref_findings already reports, removed before the
# bare scan so one site produces one finding rather than two.
readonly _ADR_INDEX_CLASSED_RE='ADR-[0-9]{8}|doc/adr/[0-9]{8}-'

# _adr_scan <root> <regexp> -- `<relpath>:<line>:<match>` for every match
# under <root>, one per line.
#
# The population is `_adr_ref_files` and not a recursive grep: the verb
# that repairs these findings sweeps exactly that set, and a lint that
# read more would fail on files the verb cannot reach.
_adr_scan() {
  local _root="$1" _re="$2" _rel
  local -a _files=()
  while IFS= read -r _rel; do
    _files+=( "${_rel}" )
  done < <(_adr_ref_files "${_root}")
  (( ${#_files[@]} > 0 )) || return 0
  (
    cd -- "${_root}" || exit 0
    grep -HnIo -E -e "${_re}" -- "${_files[@]}" 2>/dev/null || true
  )
}

# _adr_ref_findings <root> <claimed-number>... -- one line per reference
# that names no record: a dangling `ADR-NNNNNNNN`, or a `doc/adr/` path
# whose number and slug are not a file.
#
# `<relpath>:<line>:<match>` is split on the LAST colon, which is exact
# rather than approximate: neither reference form can contain one.
_adr_ref_findings() {
  local _root="$1"
  shift
  # The population's own precondition, and it is checked BEFORE anything is
  # read from it: every check below reports by finding a match, so over no
  # files at all every one of them is silent and this lint prints "clean"
  # after examining nothing. That is the one output a check may never
  # produce, because it is identical to the output of a tree with nothing
  # wrong in it. Reported and returned, rather than reported and continued:
  # the checks that follow have no files to say anything about.
  local -a _population=()
  mapfile -t _population < <(_adr_ref_files "${_root}")
  if (( ${#_population[@]} == 0 )); then
    printf 'ADR numbering: %s' "$(_adr_ref_population_refusal "${_root}")"
    return 0
  fi
  local -A _known=()
  local _n
  for _n in "$@"; do
    _known["${_n}"]=1
  done
  # Which numbers each file claims as its OWN fixture registry's. Read
  # once here rather than per hit, and read from the same file the verb
  # reads it from, so a number the verb refuses to rewrite is a number
  # this lint refuses to judge.
  local -A _fixture=()
  local _rel _nums
  while IFS=$'\t' read -r _rel _nums; do
    _fixture["${_rel}"]="${_nums}"
  done < <(_adr_ref_fixture_map "${_root}")

  local _hit _loc _match _num _path
  while IFS= read -r _hit; do
    _match="${_hit##*:}"
    _loc="${_hit%:*}"
    _num="${_match#ADR-}"
    [[ -z "${_known[${_num}]:-}" ]] || continue
    ! _adr_ref_declares "${_fixture[${_loc%:*}]:-}" "${_num}" || continue
    printf 'ADR numbering: %s: reference to ADR-%s, which no record claims (there is no doc/adr/%s-*.md).\n' \
      "${_loc}" "${_num}" "${_num}"
  done < <(_adr_scan "${_root}" "${_ADR_TOKEN_SCAN_RE}")
  while IFS= read -r _hit; do
    _match="${_hit##*:}"
    _loc="${_hit%:*}"
    _path="${_match}"
    [[ ! -f "${_root}/${_path}" ]] || continue
    # `doc/adr/` is 8 characters, and the number is the 8 that follow it.
    ! _adr_ref_declares "${_fixture[${_loc%:*}]:-}" "${_path:8:8}" || continue
    printf 'ADR numbering: %s: reference to %s, which is not a record in this tree (renumbered, renamed, or a typo).\n' \
      "${_loc}" "${_path}"
  done < <(_adr_scan "${_root}" "${_ADR_PATH_SCAN_RE}")
  # `<rel>:<line>:<text>`, and the TEXT of a declaration carries a colon
  # of its own, so the location is taken from the front rather than by
  # trimming from the back the way the two reference forms are.
  local _rest
  while IFS= read -r _hit; do
    _rest="${_hit#*:}"
    printf 'ADR numbering: %s:%s: a fixture declaration this reader cannot parse, so it exempts nothing. The form is the word fixture followed by the 8-digit numbers the file uses.\n' \
      "${_hit%%:*}" "${_rest%%:*}"
  done < <(_adr_ref_bad_markers "${_root}")
  # A declaration that IS readable and still fails to protect what it
  # names, because the text carrying the number leaves the file.
  _adr_marker_captive_findings "${_root}"
  # The population's own honesty check, and it is about THIS RUN rather
  # than about the tree: git could not be asked here, so the walk read the
  # declaration, and these are the lines it cannot apply. Every one of them
  # leaves a file in this lint's population that `just adr renumber` (which
  # runs where git DOES answer) never sweeps -- the red gate with no repair
  # path the shared reader exists to close, which is why this is a finding
  # and not a warning. The repair is to spell the rule in a form both tiers
  # read: a separator-less pattern, an explicit path, and no per-directory
  # file.
  local _loc _text
  while IFS=$'\t' read -r _loc _text; do
    printf 'ADR numbering: %s: %s -- an ignore rule this scan cannot apply, so the files it covers are read here and never swept by "just adr renumber". Spell it as a separator-less pattern or an explicit path in the root .gitignore.\n' \
      "${_loc}" "${_text}"
  done < <(_adr_ref_unreadable_ignores "${_root}")
  # The same honesty check for the split no ignore RULE can explain, and
  # the one this run CAN see: git answered here, and it lists a file the
  # walk prunes. The walk is the tier the in-container gate takes, so that
  # file is one `just adr renumber` rewrites and `just test` never reads --
  # a stale reference in it goes green locally and the two tiers name two
  # populations, which is the state the shared reader exists to prevent.
  while IFS=$'\t' read -r _loc _text; do
    printf 'ADR numbering: %s: %s, so the walk that decides the population where git cannot be asked -- the in-container run of this lint -- never reads it while "just adr renumber" sweeps it. Untrack the file, or narrow the root .gitignore rule that covers it.\n' \
      "${_loc}" "${_text}"
  done < <(_adr_ref_tier_split "${_root}")
}

# _adr_marker_captive_findings <root> -- one line per DECLARED fixture
# number that the file declaring it also publishes into a generated
# catalogue.
#
# The residue the per-number rule keeps, and the one site at which it
# bites. A declaration is per FILE, and a `# why:` marker is the one thing
# in a spec that LEAVES the file: script/test/sync-doc-counts.sh publishes
# the file blurb, every test description and every test NAME verbatim into
# doc/test/*.md, which declares nothing. So a declared number written at
# one of those three sites arrives in the catalogue as THIS tree's
# reference, and `just adr renumber` has no state it can reach -- it
# rewrites the published row, the regeneration puts the number straight
# back from the marker it may not touch, and the run aborts on a survivor
# with the record already moved and the rest of the tree swept.
#
# The finding names the MARKER, not the row, because the row is generated:
# a hand edit there is undone by the next `just test sync-docs`, and
# rewording the marker is the only repair. It is a finding rather than a
# tolerated residue for the reason every other declaration finding is one:
# it is the safe direction to fail in, and the alternative is discovering
# it from a half-renumbered tree.
#
# Three sites and not "the marker", because the generator publishes three
# things: a check that read only the prose would pass a spec whose `@test`
# names carry the number -- which is the site ADR-00000034 records as
# having actually cost.
_adr_marker_captive_findings() {
  local _root="$1" _rel _nums _num _re _site _line _marked _name _desc
  local -A _fixture=()
  while IFS=$'\t' read -r _rel _nums; do
    [[ -n "${_nums}" ]] || continue
    _fixture["${_rel}"]="${_nums}"
  done < <(_adr_ref_fixture_map "${_root}")
  (( ${#_fixture[@]} > 0 )) || return 0

  local -a _specs=() _tests=() _marker_findings=()
  local _blurb=''
  mapfile -t _specs < <(_spec_scan_files "${_root}")
  for _rel in "${_specs[@]+"${_specs[@]}"}"; do
    _nums="${_fixture[${_rel}]:-}"
    [[ -n "${_nums}" ]] || continue
    _spec_markers_scan "${_root}/${_rel}" _tests _marker_findings _blurb
    # Unquoted on purpose: the declared numbers are a space-separated list
    # and every element is eight digits, so there is nothing to split
    # wrongly.
    # shellcheck disable=SC2086
    for _num in ${_nums}; do
      # Matched in-shell rather than piped into `grep -q`: a reader that
      # leaves on its first match strands the writer with SIGPIPE, and
      # pipefail then reports a SUCCESSFUL match as the pipeline failing.
      _re="ADR-${_num}|doc/adr/${_num}-"
      if [[ -n "${_blurb}" && "${_blurb}" =~ ${_re} ]]; then
        _adr_marker_captive_report "${_rel}" '' "${_num}"
      fi
      for _site in "${_tests[@]+"${_tests[@]}"}"; do
        IFS=$'\t' read -r _line _marked _name _desc <<< "${_site}"
        [[ "${_name} ${_desc}" =~ ${_re} ]] || continue
        _adr_marker_captive_report "${_rel}" "${_line}" "${_num}"
      done
    done
  done
}

# _adr_marker_captive_report <rel> <line> <num> -- one captive-number
# finding. Split out so the three publication sites cannot word the same
# fact differently; <line> is empty for the file blurb, which is the one
# site whose text is the whole opening block rather than one place in it.
_adr_marker_captive_report() {
  local _rel="$1" _line="$2" _num="$3" _loc="$1"
  [[ -z "${_line}" ]] || _loc="${_rel}:${_line}"
  printf 'ADR numbering: %s: %s is one of this file'"'"'s own declared fixture numbers, and this file publishes it into a generated doc/test catalogue -- where it reads as a reference to this tree, and where the regeneration puts it straight back after "just adr renumber" rewrites the row. Reword the marker or the test name; editing the generated document is undone by the next "just test sync-docs".\n' \
    "${_loc}" "${_num}"
}

# _adr_index_line_bare <line> -- the bare ADR numbers in one index line:
# every digit run of exactly eight, once the token and path classes have
# been removed. Runs and not a bounded pattern, so a 9-digit number is not
# read as an 8-digit one with a digit after it.
#
# `#` as the sed delimiter: the expression's own alternation is spelled
# with pipes and its paths carry slashes, so both of the obvious choices
# would end the pattern early.
_adr_index_line_bare() {
  local _line="$1" _run
  _line="$(printf '%s\n' "${_line}" | sed -E "s#${_ADR_INDEX_CLASSED_RE}##g")"
  while IFS= read -r _run; do
    [[ "${#_run}" -eq 8 ]] || continue
    printf '%s\n' "${_run}"
  done < <(printf '%s\n' "${_line}" | grep -oE -e "${_ADR_INDEX_RUN_RE}" || true)
}

# _adr_index_bare_findings <readme> <claimed-number>... -- one line per
# bare number in the index's enumerations that no record claims.
#
# The row check below reads the number a row OPENS with, and nothing else.
# That is where the verb and this lint parted: `just adr renumber` rewrites
# a bare number anywhere in this document, and two of the three sites the
# 00000030 hand repair left stale were audit-conclusion bullets rather than
# rows. Same document, same failure, and only half of it guarded.
#
# A row's own opening number is taken out of the line first: it is the row
# check's finding, and reporting it twice would make one stale row read as
# two defects.
_adr_index_bare_findings() {
  local _readme="$1"
  shift
  local -A _known=()
  local _n
  for _n in "$@"; do
    _known["${_n}"]=1
  done
  local _line _rest _rownum _num _lineno=0 _in_prose=0
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    _lineno=$(( _lineno + 1 ))
    if [[ "${_line}" =~ ${_ADR_INDEX_SECTION_RE} ]]; then
      _in_prose=0
      [[ ! "${_line}" =~ ${_ADR_INDEX_PROSE_RE} ]] || _in_prose=1
      continue
    fi
    _rest="${_line}"
    if [[ "${_rest}" =~ ${_ADR_INDEX_ROW_RE} ]]; then
      _rownum="${BASH_REMATCH[1]}"
      _rest="${_rest/${_rownum}/}"
    elif (( _in_prose )); then
      continue
    fi
    while IFS= read -r _num; do
      [[ -z "${_known[${_num}]:-}" ]] || continue
      printf 'ADR numbering: doc/adr/README.md:%s: %s names no record; every number the index enumerates is a record.\n' \
        "${_lineno}" "${_num}"
    done < <(_adr_index_line_bare "${_rest}")
  done < "${_readme}"
}

# _adr_index_findings <root> <claimed-number>... -- one line per
# disagreement between doc/adr/README.md's audit table and the records.
#
# Runs where the document enumerates records at all: a row, or the table
# header. A README with neither is not an index, which is the fixture case
# and also the honest reading. Row order is not checked -- the table is
# sorted by hand and a renumber does not make it wrong, only unsorted.
_adr_index_findings() {
  local _root="$1"
  shift
  local _readme="${_root}/doc/adr/README.md"
  [[ -f "${_readme}" ]] || return 0
  grep -qE -e "${_ADR_INDEX_HEADER_RE}" "${_readme}" \
    || grep -qE -e "${_ADR_INDEX_ROW_RE}" "${_readme}" \
    || return 0

  _adr_index_bare_findings "${_readme}" "$@"

  local -A _rows=()
  local _line _num
  while IFS= read -r _line; do
    [[ "${_line}" =~ ${_ADR_INDEX_ROW_RE} ]] || continue
    _num="${BASH_REMATCH[1]}"
    if [[ -n "${_rows[${_num}]:-}" ]]; then
      printf 'ADR numbering: doc/adr/README.md: %s opens more than one index row; a record has exactly one.\n' \
        "${_num}"
      continue
    fi
    _rows["${_num}"]=1
  done < "${_readme}"

  local -A _known=()
  for _num in "$@"; do
    _known["${_num}"]=1
    [[ -z "${_rows[${_num}]:-}" ]] || continue
    printf 'ADR numbering: doc/adr/README.md carries no index row for %s; every record is named there exactly once.\n' \
      "${_num}"
  done
  # Sorted: an associative array's key order is a hash order, and a
  # findings list that reorders between runs is a diff nobody can read.
  local -a _row_nums=()
  mapfile -t _row_nums < <(printf '%s\n' "${!_rows[@]}" | LC_ALL=C sort)
  for _num in "${_row_nums[@]+"${_row_nums[@]}"}"; do
    [[ -z "${_known[${_num}]:-}" ]] || continue
    printf 'ADR numbering: doc/adr/README.md: index row for %s, which no record claims.\n' \
      "${_num}"
  done
}

_run_adr_numbering() {
  echo "--- Running ADR-numbering lint ---"
  local _adr_dir="${REPO_ROOT}/doc/adr"
  local _file _base _num
  local -a _malformed=()
  local -a _dups=()
  local -a _nums=()
  # number -> first basename that claimed it; a second claimant is a dup.
  local -A _seen=()

  local -a _files=()
  local _f
  shopt -s nullglob
  for _f in "${_adr_dir}"/*.md; do
    _files+=("${_f}")
  done
  shopt -u nullglob

  for _file in "${_files[@]}"; do
    _base="$(basename "${_file}")"
    # README.md is the ADR index / PRD audit (doc/adr/README.md), not an
    # ADR record. It is the conventional non-ADR file in the registry dir,
    # so it is deliberately exempt from the NNNNNNNN-<slug>.md contract.
    if [[ "${_base}" == "README.md" ]]; then
      continue
    fi
    if [[ ! "${_base}" =~ ${_ADR_NAME_RE} ]]; then
      _malformed+=("${_base}")
      continue
    fi
    _num="${_base:0:8}"
    if [[ -n "${_seen[${_num}]:-}" ]]; then
      _dups+=("${_num}: ${_seen[${_num}]} + ${_base}")
    else
      _seen["${_num}"]="${_base}"
      _nums+=("${_num}")
    fi
  done

  # Advisory: warn every missing number in the min..max run. A gap is
  # informational only -- it never contributes to the violation count.
  # Numbers are 8-digit zero-padded; 10#-prefix the arithmetic so a leading
  # zero is decimal, not octal.
  #
  # The min/max scan is in-shell on purpose. It used to be
  # `printf '%s\n' "${_nums[@]}" | sort | head -n1`: `head` closes the
  # pipe the moment it has its line, so a `sort` that has not written yet
  # takes SIGPIPE and dies 141, `pipefail` promotes that to the pipeline's
  # status, and the bare assignment under `set -e` killed the entire lint
  # phase with no message -- failing the local-CI stamp rather than any
  # test. Nothing below can be killed by a reader that stopped reading,
  # because there is no reader: no pipe, no subprocess, no exit status
  # that depends on how two processes were scheduled.
  if [[ "${#_nums[@]}" -gt 0 ]]; then
    local _min _max _i _padded _n
    _min="${_nums[0]}"
    _max="${_nums[0]}"
    for _n in "${_nums[@]}"; do
      if (( 10#${_n} < 10#${_min} )); then _min="${_n}"; fi
      if (( 10#${_n} > 10#${_max} )); then _max="${_n}"; fi
    done
    for (( _i = 10#${_min}; _i <= 10#${_max}; _i++ )); do
      _padded="$(printf '%08d' "${_i}")"
      if [[ -z "${_seen[${_padded}]:-}" ]]; then
        printf 'ADR numbering: advisory: gap at %s (no doc/adr/%s-*.md)\n' \
          "${_padded}" "${_padded}"
      fi
    done
  fi

  # Failures: malformed filenames and duplicate numbers, each named.
  local _violations=0 _m _d
  for _m in "${_malformed[@]}"; do
    printf 'ADR numbering: malformed filename: doc/adr/%s (expected NNNNNNNN-<slug>.md)\n' \
      "${_m}"
    _violations=$(( _violations + 1 ))
  done
  for _d in "${_dups[@]}"; do
    printf 'ADR numbering: duplicate number %s\n' "${_d}"
    _violations=$(( _violations + 1 ))
  done

  # The pointers. Run after the registry itself has been read, because
  # every one of these questions is asked against the set of numbers the
  # filesystem actually claims.
  local -a _ref_findings=()
  local _finding
  mapfile -t _ref_findings < <(
    _adr_ref_findings "${REPO_ROOT}" "${_nums[@]+"${_nums[@]}"}"
    _adr_index_findings "${REPO_ROOT}" "${_nums[@]+"${_nums[@]}"}"
  )
  for _finding in "${_ref_findings[@]+"${_ref_findings[@]}"}"; do
    printf '%s\n' "${_finding}"
    _violations=$(( _violations + 1 ))
  done

  if [[ "${_violations}" -gt 0 ]]; then
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_adr_numbering \
      "${_violations} ADR-numbering defect(s): duplicate number(s), malformed filename(s), and/or references that name no record. Fix the named file(s)/number(s) (a numbering gap is advisory, not a failure). To move a record and every reference to it in one step, use 'just adr renumber <record> <number>' rather than a hand sweep -- a reference missed by hand is a reference no gate reads."
    return 1
  fi
  echo "ADR-numbering lint: clean"
}
