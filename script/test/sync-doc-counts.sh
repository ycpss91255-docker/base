#!/usr/bin/env bash
#
# sync-doc-counts.sh - regenerate doc/test/*.md from the specs themselves,
# so no part of the catalogue is hand-kept in agreement with the tree.
#
# ONE-DIRECTIONAL, and that is the whole design. Everything derived flows
# spec -> document:
#
#   1. The count figures -- per-spec `### <path> (N)` headings, the
#      per-type `**N tests**` totals, and TEST.md's index table +
#      blockquote prose. Source: `grep -c '^@test'` per spec file.
#   2. The catalogue SECTIONS -- one per spec file, each with its blurb
#      and one row per `@test`. Source: the `# why:` markers the spec
#      files carry (script/test/spec-markers.sh).
#   3. The description lint's UNDESCRIBED CEILING, the one figure written
#      outside doc/test (into the lint's own driver). Source: the same
#      markers, over the lint's own population. It is a bound rather than
#      a statistic, so the write is down-only -- see "The undescribed
#      ceiling" below, and base#1024 for why a number every branch edits
#      by hand is a merge conflict whose right answer is neither side's.
#      `_sync_doc_counts_outputs` is the machine-readable answer to which
#      files those are.
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

# The description lint's population, for the one figure this generator
# writes ABOUT that lint rather than about the catalogues. The scan is
# still the lint's (spec-scan.sh's header argues the direction); reading
# it from there is what keeps the ceiling measured over the same set it
# is enforced over.
# shellcheck source=script/test/spec-scan.sh
source "${_SYNC_DOC_COUNTS_DIR}/spec-scan.sh"

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
# header to <count>.
_sync_type_total() {
  local _doc="$1" _count="$2"
  [[ -f "${_doc}" ]] || return 0
  sed -i -E "s/(: )\*\*[0-9]+ tests\*\*/\1**${_count} tests**/" "${_doc}"
}

# _sync_test_md_index <root> -- rewrite TEST.md's derived figures (grand total,
# per-type table, "not in the N figure", and the blockquote prose "System (N)
# and smoke (N)" pair) from the per-type totals. The prose pair is regenerated
# too: hand-maintaining it let it drift out of step with the table it sits
# next to.
_sync_test_md_index() {
  local _root="$1"
  local _t="${_root}/doc/test/TEST.md"
  [[ -f "${_t}" ]] || return 0
  # ISTQB taxonomy (ADR-00000018): levels unit / integration / system /
  # acceptance, plus the shipped build-time smoke type. system replaces the
  # retired behavioural category. Empty level dirs (e.g. acceptance before
  # S5 content lands) resolve to 0 via _dir_test_count's no-match path.
  local _u _i _sy _a _sm _tot
  _u="$(_dir_test_count "${_root}" 'test/bats/unit/**/*_spec.bats')"
  _i="$(_dir_test_count "${_root}" 'test/bats/integration/**/*_spec.bats')"
  _sy="$(_dir_test_count "${_root}" 'test/bats/system/**/*_spec.bats')"
  _a="$(_dir_test_count "${_root}" 'test/bats/acceptance/**/*_spec.bats')"
  _sm="$(_dir_test_count "${_root}" 'dist/test/bats/smoke/**/*.bats')"
  _tot=$(( _u + _i ))
  sed -i -E \
    "s/\*\*[0-9]+ tests\*\* total \([0-9]+ unit \+ [0-9]+ integration\)/**${_tot} tests** total (${_u} unit + ${_i} integration)/" \
    "${_t}"
  sed -i -E "s/not\*\* in the [0-9]+ figure/not** in the ${_tot} figure/" "${_t}"
  sed -i -E \
    "s/System \([0-9]+\) and smoke \([0-9]+\)/System (${_sy}) and smoke (${_sm})/" \
    "${_t}"
  sed -i -E "s#(\[unit\.md\]\(unit\.md\).*\| )[0-9]+ #\1${_u} #" "${_t}"
  sed -i -E "s#(\[integration\.md\]\(integration\.md\).*\| )[0-9]+ #\1${_i} #" "${_t}"
  sed -i -E "s#(\[system\.md\]\(system\.md\).*\| )[0-9]+ #\1${_sy} #" "${_t}"
  sed -i -E "s#(\[acceptance\.md\]\(acceptance\.md\).*\| )[0-9]+ #\1${_a} #" "${_t}"
  sed -i -E "s#(\[smoke\.md\]\(smoke\.md\).*\| )[0-9]+ #\1${_sm} #" "${_t}"
  sed -i -E "s/(grand total \(unit \+ integration\): )\*\*[0-9]+\*\*/\1**${_tot}**/" "${_t}"
}


# ── The undescribed ceiling ──────────────────────────────────────────────────
#
# The third derived figure, and the one that is not a statistic. It is a
# BOUND: the description lint fails when the tree carries more undescribed
# tests than the number records, so the number has to be stored somewhere
# or it bounds nothing (base#999 chose one number over a roster of per-test
# exemptions, and that choice stands).
#
# It was stored as a hand-kept `readonly` in the lint's own driver, which
# made it the shape ADR-00000028 removed for the test-count totals: every
# branch that describes a test has a correct reason to lower it, so every
# branch edited the same line, every merge conflicted on it, and the
# merged tree's right value was NEITHER side's -- descriptions compose, so
# two branches lowering to 2617 and 2614 merge into a tree that measures
# 2609. The resolution was never "take the lower"; it was "recompute from
# the merged tree", which is exactly what this generator does for the
# catalogues.
#
# So the generator writes it, in the run that writes the catalogue, from
# the same spec tree.
#
# WHAT MAKES THIS DIFFERENT FROM A MIRROR, and it is the whole reason the
# ceiling exists: the write is DOWN-ONLY. A measurement lower than the
# record replaces it; a measurement higher leaves the record alone and the
# breach reaches the lint, which fails. A generator that wrote whatever it
# measured would turn the ratchet into a mirror and the lint would stop
# bounding anything. Raising the number is still a person editing that
# line -- a merge cannot raise it as a side effect, because regeneration
# only ever lowers.
_CATALOG_CEILING_REL='script/test/drivers/catalog_description.sh'
_CATALOG_CEILING_VAR='_CATALOG_DESC_UNDESCRIBED_CEILING'
_CATALOG_CEILING_ASSIGN_RE="^readonly ${_CATALOG_CEILING_VAR}=[0-9]+\$"

# _sync_err <message> -- diagnostic to stderr. Block-redirected rather than
# a bare `printf ... >&2`: this is a standalone, log.sh-free CI tool (the
# same rationale class as check_test_md_drift.sh) and the bare-stderr lint
# scans script/test/.
_sync_err() {
  {
    printf 'sync-doc-counts: %s\n' "$1"
  } >&2
}

# _undescribed_count <root> -- how many `@test`s in the lint's population
# carry no `# why:` marker at all.
#
# The lint's own arithmetic, deliberately: a marker that is PRESENT and
# says nothing is a hard finding there and is NOT under the ceiling, so it
# must not be counted here either. `<line> TAB <marked> TAB ...` -- only
# the second field is read.
_undescribed_count() {
  local _root="$1" _rel _rec _rest _n=0
  local -a _files=() _tests=() _findings=()
  local _blurb=''
  mapfile -t _files < <(_spec_scan_files "${_root}")
  for _rel in "${_files[@]+"${_files[@]}"}"; do
    _spec_markers_scan "${_root}/${_rel}" _tests _findings _blurb
    for _rec in "${_tests[@]+"${_tests[@]}"}"; do
      _rest="${_rec#*$'\t'}"
      (( "${_rest%%$'\t'*}" )) || _n=$(( _n + 1 ))
    done
  done
  printf '%s\n' "${_n}"
}

# _recorded_ceiling <file> -- the number the driver currently records.
#
# Fails, rather than defaulting, when the assignment is not there exactly
# once. Guessing is the fail-open direction for a BOUND: a missing value
# read as "no limit" unbounds the lint silently, and a conflicted file
# (two assignments between merge markers) would otherwise be resolved by
# whichever `grep` hit first.
_recorded_ceiling() {
  local _file="$1"
  local -a _hits=()
  mapfile -t _hits < <(grep -E -- "${_CATALOG_CEILING_ASSIGN_RE}" "${_file}")
  if (( ${#_hits[@]} != 1 )); then
    _sync_err "${_file} carries ${#_hits[@]} '${_CATALOG_CEILING_VAR}=<n>' assignment(s), expected exactly 1 -- the undescribed ceiling is a bound this generator maintains, and a value it cannot read is not one to guess at (a guess high unbounds the lint). Resolve the file (conflict markers?), then re-run."
    return 1
  fi
  printf '%s\n' "${_hits[0]##*=}"
}

# _sync_undescribed_ceiling <root> -- lower the recorded ceiling to what
# <root> measures; never raise it.
#
# A root with no driver in it is a SKIP and not a failure: the drift gate
# and the merge resolver both run this generator against scratch trees
# that hold doc/test plus symlinked spec trees and nothing else, and those
# callers are the normal case, not a broken checkout.
_sync_undescribed_ceiling() {
  local _root="$1"
  local _file="${_root}/${_CATALOG_CEILING_REL}"
  [[ -f "${_file}" ]] || return 0
  local _recorded _measured
  _recorded="$(_recorded_ceiling "${_file}")" || return 1
  _measured="$(_undescribed_count "${_root}")"
  (( _measured < _recorded )) || return 0
  sed -i -E "s/${_CATALOG_CEILING_ASSIGN_RE}/readonly ${_CATALOG_CEILING_VAR}=${_measured}/" \
    "${_file}"
}

# _sync_doc_counts_outputs <root> -- every file _sync_doc_counts writes,
# one absolute path per line.
#
# The answer to "which files in this tree are generated", asked by the
# drift gate (what to compare) and by the merge resolver (what a
# regeneration is entitled to overwrite). It is computed here, next to the
# writes, because a second copy of the list kept anywhere else is the
# defect this whole file exists to remove -- and because the set grew: the
# ceiling is an output now and a resolver carrying "doc/test/*.md" would
# have gone on refusing it.
_sync_doc_counts_outputs() {
  local _root="$1" _doc
  for _doc in "${_root}"/doc/test/*.md; do
    [[ -f "${_doc}" ]] || continue
    printf '%s\n' "${_doc}"
  done
  [[ -f "${_root}/${_CATALOG_CEILING_REL}" ]] \
    && printf '%s\n' "${_root}/${_CATALOG_CEILING_REL}"
  return 0
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
    # and no fenced region, and its figures are written by
    # _sync_test_md_index below.
    [[ -n "${_glob}" ]] || continue
    _sync_catalog_region "${_root}" "${_doc}" "${_glob}" || return 1
    _sync_type_total "${_doc}" "$(_dir_test_count "${_root}" "${_glob}")"
  done
  _sync_test_md_index "${_root}"
  _sync_undescribed_ceiling "${_root}" || return 1
}

main() {
  local _root="${1:-${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
  _sync_doc_counts "${_root}" || return 1
  printf 'synced doc/test catalogues under %s\n' "${_root}/doc/test"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
