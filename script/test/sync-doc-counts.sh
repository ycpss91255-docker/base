#!/usr/bin/env bash
#
# sync-doc-counts.sh - regenerate doc/test/*.md from the specs themselves,
# so no part of the catalogue is hand-kept in agreement with the tree.
#
# ONE-DIRECTIONAL, and that is the whole design. Everything derived flows
# spec -> document:
#
#   1. The count figures -- per-spec `### <path> (N)` headings and the
#      per-type `**N tests**` total at a catalogue's head. Source:
#      `grep -c '^@test'` per spec file.
#   2. The catalogue SECTIONS -- one per spec file, each with its blurb
#      and one row per `@test`. Source: the `# why:` markers the spec
#      files carry (script/test/spec-markers.sh).
#
# What is deliberately NOT here: any AGGREGATE over the suite.
# ADR-00000028 sec. 1 removed the grand total, TEST.md's index-table
# Count column and its blockquote figures, and unit.md's per-type header,
# and this generator's TEST.md pass went with them -- so TEST.md is now a
# document this script does not write to at all. A figure above is about
# ONE spec file or ONE level and is regenerated where it is read; an
# aggregate named nothing it measured, so it was wrong between every
# commit and its resync and every branch had to edit it. The count for
# the working tree comes from the run (`just test`), and a released
# version's from its release. `doc_counts_spec.bats` fails if one is
# typed back into TEST.md or unit.md.
#
# Nothing flows the other way. A description used to be hand-written in
# the document and PRESERVED here across regeneration, which made a person
# the mechanism keeping two files in agreement: a rename lost the prose
# (the catalogue documented that loss as a rule), a merge could drop a
# section body while keeping its heading, and a section could leave the
# per-test rule by changing its table's shape. With the description
# authored beside the test, a rename carries it, a merge cannot lose it,
# and a deleted row is restored byte-for-byte by the next run.
#
# The check_test_md_drift.sh hook stays the validating safety net: it runs
# THIS generator against a throwaway copy and diffs, so the validator
# cannot drift from the generator. Idempotent.
#
# Usage:
#   ./script/test/sync-doc-counts.sh            # sync REPO_ROOT/doc/test/*.md
#   ./script/test/sync-doc-counts.sh <root>     # sync <root>/doc/test/*.md
#
# Style: Google Shell Style Guide.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

_SYNC_DOC_COUNTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"

# The marker reader, shared rather than copied. One `# why:` block has
# exactly one correct reading, and a second copy of that loop would agree
# with this one on the day it was pasted and drift afterwards -- the defect
# class this whole change removes. The lint sources the same file; what it
# does NOT share is the SCAN (which specs are in scope), because a lint
# that inherits the generator's idea of the population agrees by
# construction that a spec the generator stopped seeing has nothing to
# check.
# shellcheck source=script/test/spec-markers.sh
source "${_SYNC_DOC_COUNTS_DIR}/spec-markers.sh"

# _dir_test_count <root> <relglob> -- total `^@test` count across the spec
# files matching <root>/<relglob>. This is the authoritative per-type total
# (what `just test` actually runs), independent of how many specs happen to
# have an individual `### <path> (N)` doc heading.
_dir_test_count() {
  local _root="$1" _glob="$2" _f _sum=0 _c
  # globstar so a caller can pass `<dir>/**/*_spec.bats` to recurse into
  # per-lib sub-folders (test/bats/unit/<lib>/<subunit>_spec.bats,
  # ADR-00000015). Saved/restored so sourcing this lib does not leak the
  # option to the caller.
  local _globstar_was_set=0
  shopt -q globstar && _globstar_was_set=1
  shopt -s globstar
  for _f in "${_root}"/${_glob}; do
    [[ -f "${_f}" ]] || continue
    _c="$(grep -cE '^@test' "${_f}" 2>/dev/null || true)"
    _sum=$(( _sum + ${_c:-0} ))
  done
  (( _globstar_was_set )) || shopt -u globstar
  printf '%s\n' "${_sum}"
}

# _doc_spec_glob <doc-basename> -- the root-relative spec glob the named
# doc/test catalogue covers, or nothing for a doc that is not a per-level
# catalogue (TEST.md is the index). Single source for "which specs belong in
# which doc", used by the per-type totals and by the missing-section sweep.
_doc_spec_glob() {
  case "$1" in
    unit.md) printf '%s\n' 'test/bats/unit/**/*_spec.bats' ;;
    integration.md) printf '%s\n' 'test/bats/integration/**/*_spec.bats' ;;
    system.md) printf '%s\n' 'test/bats/system/**/*_spec.bats' ;;
    acceptance.md) printf '%s\n' 'test/bats/acceptance/**/*_spec.bats' ;;
    smoke.md) printf '%s\n' 'dist/test/bats/smoke/**/*.bats' ;;
    *) return 0 ;;
  esac
}

# ── Catalogue sections ───────────────────────────────────────────────────────
#
# The generation is ONE-DIRECTIONAL. Descriptions and section blurbs are
# read out of the SPEC FILES (script/test/spec-markers.sh, `# why:`) and
# written into doc/test/*.md. Nothing reads a description back out of the
# catalogue: the round trip is what made a person the mechanism keeping
# two files in agreement, and it is what a rename used to break.
#
# The generated region is delimited and replaced WHOLESALE:
#
#   <!-- generated: catalogue sections -->
#   ... every section, regenerated from the spec tree ...
#   <!-- /generated -->
#
# Wholesale, never merged, because merging is the behaviour that let a
# section survive its spec and a table survive its rows. Outside the
# fence the document is hand-written and this generator does not touch
# it: the title, the "how this catalogue is maintained" prose, and the
# per-level narrative sections enumerate nothing -- no spec, no test, no
# count -- so nothing out there can fall behind the tree.
#
# The contract, in full (doc/test/unit.md states it for readers too):
#
#   Row identity   The test name, exactly as bats reports it, so a row can
#                  be pasted straight into `--filter`. A `|` in the name is
#                  escaped `\|` on the way into the table.
#   Description    Whatever the test's `# why:` block says, joined to one
#                  line. A `|` in it is escaped by the RENDERER: the marker
#                  holds prose and markdown is the renderer's problem.
#                  A test with no marker renders `-`.
#   Blurb          The spec file's own file-level `# why:` block, wrapped.
#   Ordering       Spec-file order within a section; the level's glob order
#                  between sections. Both are derivable from a checkout,
#                  which hand-placed sections were not.
#   Rename         Carries the description with it, because the description
#                  is on the lines above the test that moved.

# The fence. A catalogue that has lost it is an ERROR, not a document with
# nothing to generate: silently writing no sections is how a generator
# stops covering a level while its gate stays green.
_CATALOG_FENCE_OPEN='<!-- generated: catalogue sections -->'
_CATALOG_FENCE_CLOSE='<!-- /generated -->'

# Prose is wrapped at this tree's own norm rather than emitted as one long
# line, so the committed catalogue stays readable and a blurb edit shows up
# as a local diff instead of one rewritten paragraph-line.
_CATALOG_WRAP_WIDTH=76

# The two line-openers that would turn wrapped prose into markdown
# STRUCTURE: an ATX heading and a table row. Wrapping decides where a line
# starts, so without this a blurb could grow a heading at a line break that
# has nothing to do with the prose.
#
# The heading pattern requires the space CommonMark requires, which is not
# pedantry: a bare issue reference (a hash followed straight by digits)
# opens no heading, and escaping one would rewrite prose a blurb is
# entitled to contain -- it happens in this tree. List markers are
# deliberately NOT escaped: a blurb that argues in bullets should render
# as bullets.
_CATALOG_PROSE_ESCAPE_RE='^(#{1,6}([[:space:]]|$)|\|)'

# _catalog_prose_line <line> -- one wrapped prose line, escaped if it would
# otherwise open a block.
_catalog_prose_line() {
  if [[ "$1" =~ ${_CATALOG_PROSE_ESCAPE_RE} ]]; then
    printf '\\%s\n' "$1"
    return 0
  fi
  printf '%s\n' "$1"
}

# _catalog_wrap <text> -- <text> greedily wrapped to _CATALOG_WRAP_WIDTH.
# `read -r -a` rather than an unquoted expansion: word splitting is wanted
# here, filename globbing is not, and a blurb that mentions `*.sh` would
# otherwise be replaced by whatever the working directory holds.
_catalog_wrap() {
  local _text="$1" _line='' _word
  local -a _words=()
  read -r -a _words <<< "${_text}"
  for _word in "${_words[@]}"; do
    if [[ -z "${_line}" ]]; then
      _line="${_word}"
    elif (( ${#_line} + 1 + ${#_word} <= _CATALOG_WRAP_WIDTH )); then
      _line+=" ${_word}"
    else
      _catalog_prose_line "${_line}"
      _line="${_word}"
    fi
  done
  [[ -n "${_line}" ]] && _catalog_prose_line "${_line}"
  return 0
}

# _catalog_wrap_paragraphs <text> -- <text> as wrapped markdown paragraphs,
# one blank line between them. A file-level `# why:` block keeps its
# paragraph breaks (spec-markers.sh returns them as newlines), so a blurb
# that argues in three paragraphs renders as three, not as one wall.
_catalog_wrap_paragraphs() {
  local _text="$1" _para _first=1
  while IFS= read -r _para; do
    [[ -n "${_para}" ]] || continue
    (( _first )) || printf '\n'
    _first=0
    _catalog_wrap "${_para}"
  done <<< "${_text}"
  return 0
}

# _catalog_render_row <name> <desc> -- one markdown catalog row. A `|` is
# escaped in BOTH cells: the name has always been escaped here, and the
# description now is too, because the author types prose into a `# why:`
# block and must not be asked to know it will end up between pipes. A name
# containing a backtick gets a double-backtick code span so the span still
# closes where it should.
_catalog_render_row() {
  local _name="$1" _desc="$2" _fence='`'
  [[ "${_name}" == *'`'* ]] && _fence='``'
  printf '| %s%s%s | %s |\n' \
    "${_fence}" "${_name//|/\\|}" "${_fence}" "${_desc//|/\\|}"
}

# _catalog_render_sections <root> <glob> -- the whole generated region for
# one level, on stdout: one section per spec file the glob matches, in glob
# order, each with its heading + count, its blurb, and one row per `@test`.
_catalog_render_sections() {
  local _root="$1" _glob="$2" _f _rel _n _rec _name _desc
  local -a _cat_tests=() _cat_findings=()
  local _cat_blurb=''

  # Section order is the glob's, sorted EXPLICITLY under LC_ALL=C rather
  # than left to pathname expansion. Bash sorts a glob by the current
  # locale's collation, and this generator runs in two of them: the musl
  # alpine test-tools container and a glibc host. Under en_US
  # `log_spec.bats` and `logrotate_spec.bats` come out in the opposite
  # order to C, because the underscore is ignored at the primary level --
  # so the same tree regenerated in the two places produced two byte
  # sequences and the drift gate fired on a checkout nobody had touched.
  # The globstar dance happens in the subshell, which is also why nothing
  # has to be saved and restored here.
  local -a _cat_files=()
  mapfile -t _cat_files < <(
    shopt -s globstar
    for _f in "${_root}"/${_glob}; do
      # `|| continue` and not `&& printf`: under pipefail the loop's status
      # is the last iteration's, so a final non-file match would fail the
      # pipeline and take the whole generator with it.
      [[ -f "${_f}" ]] || continue
      printf '%s\n' "${_f}"
    done | LC_ALL=C sort
  )

  for _f in "${_cat_files[@]+"${_cat_files[@]}"}"; do
    _rel="${_f#"${_root}"/}"
    # The SAME `grep -cE '^@test'` the per-type totals use, so a heading
    # count and its row count cannot disagree -- a line this counts and
    # the reader refuses is a finding there, not a silent gap here.
    _n="$(grep -cE '^@test' "${_f}" 2>/dev/null || true)"
    _spec_markers_scan "${_f}" _cat_tests _cat_findings _cat_blurb
    printf '\n### %s (%s)\n' "${_rel}" "${_n:-0}"
    if [[ -n "${_cat_blurb}" ]]; then
      printf '\n'
      _catalog_wrap_paragraphs "${_cat_blurb}"
    fi
    printf '\n| Test | Description |\n|------|-------------|\n'
    if (( ${#_cat_tests[@]} > 0 )); then
      for _rec in "${_cat_tests[@]}"; do
        # `<line> TAB <marked> TAB <name> TAB <desc>`; the description is
        # the remainder, so a TAB in it would be kept, not split on.
        _name="${_rec#*$'\t'}"
        _name="${_name#*$'\t'}"
        _desc="${_name#*$'\t'}"
        _name="${_name%%$'\t'*}"
        _catalog_render_row "${_name}" "${_desc:--}"
      done
    fi
  done
  printf '\n'
}

# _sync_catalog_region <root> <doc> <glob> -- replace <doc>'s fenced region
# with a freshly rendered one. Fails, naming the document, when either
# fence is missing.
_sync_catalog_region() {
  local _root="$1" _doc="$2" _glob="$3"
  [[ -f "${_doc}" ]] || return 0
  local _tmp
  _tmp="$(mktemp "${_doc}.XXXXXX")" || return 1
  local _line _inside=0 _open=0 _close=0
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    if [[ "${_line}" == "${_CATALOG_FENCE_OPEN}" ]]; then
      _open=1
      _inside=1
      printf '%s\n' "${_line}"
      _catalog_render_sections "${_root}" "${_glob}"
      continue
    fi
    if [[ "${_line}" == "${_CATALOG_FENCE_CLOSE}" ]]; then
      _close=1
      _inside=0
      printf '%s\n' "${_line}"
      continue
    fi
    (( _inside )) && continue
    printf '%s\n' "${_line}"
  done < "${_doc}" > "${_tmp}"
  if (( ! _open || ! _close )); then
    rm -f "${_tmp}"
    {
      printf "sync-doc-counts: %s carries no '%s' ... '%s' region -- the catalogue sections are generated into it, so a document without one would silently stop covering its level.\n" \
        "${_doc}" "${_CATALOG_FENCE_OPEN}" "${_CATALOG_FENCE_CLOSE}"
    } >&2
    return 1
  fi
  mv "${_tmp}" "${_doc}"
}

# _sync_type_total <doc> <count> -- rewrite the per-type `...: **N tests**.`
# header to <count>, in the catalogues that have one.
#
# unit.md deliberately does NOT: it is the file every branch that adds a
# unit test rewrites, and its header was one of the five aggregate lines
# ADR-00000028 sec. 1 removed. The `sed` below simply finds no pattern
# there. That is a silent no-op, which is exactly why it is not the only
# thing keeping the line out: `doc_counts_spec.bats` fails if one is typed
# back into unit.md or TEST.md.
_sync_type_total() {
  local _doc="$1" _count="$2"
  [[ -f "${_doc}" ]] || return 0
  sed -i -E "s/(: )\*\*[0-9]+ tests\*\*/\1**${_count} tests**/" "${_doc}"
}

# _sync_doc_counts [root] -- regenerate every derived figure and every
# catalogue section under <root>/doc/test.
_sync_doc_counts() {
  local _root="${1:-${REPO_ROOT:-.}}"
  local _doc _glob
  for _doc in "${_root}"/doc/test/*.md; do
    [[ -f "${_doc}" ]] || continue
    _glob="$(_doc_spec_glob "$(basename -- "${_doc}")")"
    # TEST.md is the index, not a per-level catalogue: it has no spec glob
    # and no fenced region. It also carries no figure any more, so this
    # generator writes nothing to it at all (ADR-00000028 sec. 1).
    [[ -n "${_glob}" ]] || continue
    _sync_catalog_region "${_root}" "${_doc}" "${_glob}" || return 1
    _sync_type_total "${_doc}" "$(_dir_test_count "${_root}" "${_glob}")"
  done
}

main() {
  local _root="${1:-${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
  _sync_doc_counts "${_root}" || return 1
  printf 'synced doc/test catalogues under %s\n' "${_root}/doc/test"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
