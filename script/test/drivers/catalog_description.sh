#!/usr/bin/env bash
# drivers/catalog_description.sh - "a doc/test catalog row carries a
# description" per-tool driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_catalog_description.
#
# Contract: runs INSIDE the ci (test-tools) container where test.sh
# invokes it. References ${REPO_ROOT} (a global exported by test.sh).
# Follows drivers/home_literal.sh / drivers/changelog_entry.sh conventions
# (sourced lib, uses ${REPO_ROOT}, _log_* / _die, no main).
#
# Why the column is required. The catalogs under doc/test/ carry a
# Description column that 40% of rows filled with the `-` placeholder
# sync-doc-counts.sh writes when it has nothing. That was not a decision
# anybody made -- two specs landing the same week, same generator and same
# review bar, came out opposite ways because nothing said which was
# correct. The column is worth keeping because it does not duplicate the
# test name: this repo's @test names are long and already say WHAT is
# asserted, while a description says why the case matters. Compare
#
#   name: build.sh test: a fully CACHED verification stage is not reported
#         as a pass
#   desc: The load-bearing case: every check CACHED reports that nothing ran
#
# A `-` loses the second half, which is the half a reader cannot
# reconstruct later.
#
# THE CONVENTION, which matters more than this lint. The description
# answers WHY THIS CASE MATTERS -- what it defends, whether it is the
# load-bearing one, what breaks if it goes. It does NOT restate what the
# test does; the name already does that, at length. A required field
# people do not know how to fill produces filler:
#
#   | `_run_changelog_entry: FAILS on an unterminated allow-begin` |
#     Fails on an unterminated allow-begin |
#
# which is WORSE than `-`, because it looks like information and passes
# this lint. The convention is the primary defence and this lint is only
# the floor; it is stated for spec authors in doc/test/TEST.md and in the
# "How this catalogue is maintained" section of doc/test/unit.md, and
# repeated in the failure message below, because the moment somebody meets
# the rule is the moment they need to know how to satisfy it.
#
# Mechanically detecting restatement -- high token overlap between name and
# description -- was considered and NOT built. The two rows above differ by
# a rewording, not by a measurable distance, so the rule would fire on
# honest short descriptions and miss reworded filler; a guard whose false
# positives are the good rows teaches people to write around it. That is a
# judgement a reviewer makes.
#
# ── The ratchet ─────────────────────────────────────────────────────────
#
# 747 of 1711 rows carried the placeholder on the day the rule landed.
# Failing all of them turns CI red until 747 sentences exist, which blocks
# everyone on a backfill nobody asked for -- and a rushed backfill produces
# exactly the filler above. So the rows that were already there are
# recorded in a baseline file and the lint fails only on a placeholder that
# is NOT on it. Forward-only: write the description while you still have
# the context, and inherit no debt.
#
# The baseline is keyed by SPEC PATH plus TEST NAME. That is deliberate and
# it is the property the whole design turns on: renaming or moving a test
# drops it out of the baseline and forces a description. Touch it, describe
# it; leave it alone, leave it alone. Keying by name alone was rejected --
# three test names in this tree already live in two specs at once, so one
# baseline line would excuse a row nobody ever looked at.
#
# ── What keeps the baseline shrink-only ─────────────────────────────────
#
# Nothing in a checkout can answer "was this line here yesterday?" -- only
# history can, and this driver deliberately does not shell out to git (the
# lint-static runner checks out at depth 1, and a lint whose verdict
# depends on how much history was fetched is worse than no lint). So the
# guard does not claim to detect growth. It makes growth impossible to
# commit SILENTLY, from three directions at once:
#
#   1. A baselined row that is no longer a placeholder -- described,
#      renamed, moved or deleted -- is refused as STALE. So describing a
#      row forces its line out of the file in the same commit. This is what
#      drives the count down, and it is why the file cannot quietly
#      accumulate excuses for rows that no longer need them.
#   2. The file DECLARES its own entry count, in a `# entries: N`
#      directive, and the count must match exactly. Adding a line is a
#      failing lint until somebody also edits a number whose only meaning
#      is "this much description debt is left". Raising that number is one
#      reviewable line in the diff, and it is the entire ask: the number
#      may only ever go DOWN.
#   3. The entries must be sorted (LC_ALL=C) and unique. A 700-line file is
#      only reviewable while its diff is one line per change; unsorted, an
#      insertion hides anywhere, and a duplicate overstates the debt so
#      that deleting one copy looks like progress.
#
# That is the honest boundary: (1) is mechanical and does the work, (2) and
# (3) make the remaining move visible rather than impossible.
#
# Scope: doc/test/*.md, and within them only the tables that a generated
# `### <path> (N)` section opens with a `| Test | Description |` header.
# TEST.md's own index tables belong to no spec, and reading those as test
# rows would invent findings for rows nobody claimed were tests.
#
# The row SPLITTER is SHARED with the generator, not copied:
# sync-doc-counts.sh's _catalog_cell_split_into is sourced and called
# directly, the way drivers/doc_counts.sh sources check_test_md_drift.sh.
# One `| `name` | desc |` line has exactly one correct reading -- the first
# UNESCAPED `|` ends the name cell, a `\|` inside a name does not, and a
# bare `|` inside a description belongs to the description -- and a second
# copy of that loop would agree with the generator on the day it was
# pasted and drift afterwards, which is the defect class this repo keeps
# paying for. It also has to be the same reading: the baseline records a
# name as bats reports it, so the lint only ever meets a row's name if it
# undoes the table escaping exactly as the generator applied it.
#
# What is deliberately NOT shared is the SCAN -- which sections and which
# tables are in scope. That is where leaning on the generator goes vacuous:
# a lint that inherits the generator's idea of a catalogue agrees, by
# construction, that a table the generator has stopped recognising has no
# rows to check. So the scan is this driver's own.
#
# Non-vacuity: a missing catalog directory, a missing baseline file, or a
# scan that finds no catalog rows at all DIES rather than reporting clean.
# The clean line states how many rows were checked and how many the
# baseline still excuses, so a green line is never read as a verdict over
# rows that were never there.

_CATALOG_DESC_DRIVER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" \
  && pwd -P)"
readonly _CATALOG_DESC_DRIVER_DIR

# The row splitter, shared rather than copied. Sourcing is side-effect free:
# sync-doc-counts.sh guards its `set -euo pipefail` and its main() on being
# run directly, and defines no readonly globals, so a second source (the
# doc-counts driver reaches it through check_test_md_drift.sh) is a no-op.
# shellcheck source=script/test/sync-doc-counts.sh
source "${_CATALOG_DESC_DRIVER_DIR}/../sync-doc-counts.sh"

# ── Catalog description lint ─────────────────────────────────────────────────

# The scanned directory and the baseline, repo-root-relative. Both must
# exist: either one missing would change what the lint means without
# changing the lint.
readonly _CATALOG_DESC_DOC_DIR='doc/test'
readonly _CATALOG_DESC_BASELINE_FILE='script/test/catalog-description-baseline.txt'

# The placeholder sync-doc-counts.sh writes for a row it has no description
# for (`_catalog_flush_desc[${_name}]:--`). An empty cell counts as one
# too: a hand-edited blank is the same missing sentence wearing less ink.
readonly _CATALOG_DESC_PLACEHOLDER='-'

# The directive the baseline declares its own size with. See the header:
# this is the number that may only ever go down.
readonly _CATALOG_DESC_COUNT_RE='^#[[:space:]]*entries:[[:space:]]*([0-9]+)[[:space:]]*$'

# _catalog_desc_load_baseline <abs-path> <set-outvar> -- read the baseline
# into an associative array keyed `<spec>\t<name>`, validating the file's
# own shape on the way through: the declared count, sortedness, uniqueness
# and the TAB separator. Prints one line per finding and returns the number
# of findings.
_catalog_desc_load_baseline() {
  local _abs="${1}"
  local -n _cd_set="${2}"
  local _rel="${_CATALOG_DESC_BASELINE_FILE}"
  local _line _lineno=0 _declared='' _count=0 _prev='' _findings=0
  # The file's order is defined as LC_ALL=C, and `[[ < ]]` compares by the
  # CURRENT locale's collation -- which differs between the musl test-tools
  # image and the glibc lint-static runner, so the same file would sort two
  # ways. A local assignment to LC_ALL is scoped to this function and
  # restored on return, which makes the comparison byte-wise without
  # spawning a `sort`.
  local LC_ALL=C
  _cd_set=()

  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    _lineno=$(( _lineno + 1 ))
    if [[ "${_line}" =~ ${_CATALOG_DESC_COUNT_RE} ]]; then
      _declared="${BASH_REMATCH[1]}"
      continue
    fi
    [[ "${_line}" == '#'* ]] && continue
    [[ -z "${_line}" ]] && continue

    if [[ "${_line}" != *$'\t'* ]]; then
      printf '%s:%d: malformed entry (expected <spec path> TAB <test name>) -- %s\n' \
        "${_rel}" "${_lineno}" "${_line}"
      _findings=$(( _findings + 1 ))
      continue
    fi
    if [[ -n "${_cd_set[${_line}]:-}" ]]; then
      printf '%s:%d: duplicate entry -- %s\n' "${_rel}" "${_lineno}" "${_line}"
      _findings=$(( _findings + 1 ))
      continue
    fi
    # Sortedness is checked pairwise against the previous entry rather than
    # by re-sorting the whole file, so the report names the line that broke
    # the order instead of handing back a diff.
    if [[ -n "${_prev}" ]] && [[ "${_prev}" > "${_line}" ]]; then
      printf '%s:%d: not sorted (LC_ALL=C) -- %s\n' "${_rel}" "${_lineno}" "${_line}"
      _findings=$(( _findings + 1 ))
    fi
    _prev="${_line}"
    _cd_set["${_line}"]=1
    _count=$(( _count + 1 ))
  done < "${_abs}"

  if [[ -z "${_declared}" ]]; then
    printf '%s: no "# entries: <n>" directive -- the shrink-only lock is that number, and dropping it is the one edit it exists to make loud\n' \
      "${_rel}"
    _findings=$(( _findings + 1 ))
  elif [[ "${_declared}" -ne "${_count}" ]]; then
    printf '%s: declares "# entries: %s" but holds %d -- the baseline may only SHRINK, so if this is a removal lower the number, and if it is an addition it needs saying out loud\n' \
      "${_rel}" "${_declared}" "${_count}"
    _findings=$(( _findings + 1 ))
  fi

  return "${_findings}"
}

_run_catalog_description() {
  echo "--- Running catalog description lint ---"
  local _doc_dir="${REPO_ROOT}/${_CATALOG_DESC_DOC_DIR}"
  local _baseline="${REPO_ROOT}/${_CATALOG_DESC_BASELINE_FILE}"

  if [[ ! -d "${_doc_dir}" ]]; then
    _die ci_catalog_description \
      "catalog directory '${_CATALOG_DESC_DOC_DIR}/' not found under ${REPO_ROOT} -- the lint would pass vacuously. Point it at the generated test catalogues."
    return 1
  fi
  if [[ ! -f "${_baseline}" ]]; then
    _die ci_catalog_description \
      "baseline '${_CATALOG_DESC_BASELINE_FILE}' not found under ${REPO_ROOT} -- without it every row that predates the rule fails at once. Restore the file rather than regenerating it: it is a record of what was already there, not a cache."
    return 1
  fi

  local _violations=0

  local -A _baselined=()
  _catalog_desc_load_baseline "${_baseline}" _baselined \
    || _violations=$(( _violations + $? ))

  # Which baseline entries a live placeholder row still needs. Anything
  # left over at the end is stale -- described, renamed, moved or deleted --
  # and is what drives the file down.
  local -A _used=()

  local _doc _rel _spec _line _lineno _in_table _rows=0 _catalogs=0 _excused=0
  local _name _desc _key
  while IFS= read -r -d '' _doc; do
    _rel="${_doc#"${REPO_ROOT}"/}"
    _catalogs=$(( _catalogs + 1 ))
    _spec=''
    _in_table=0
    _lineno=0
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
      _lineno=$(( _lineno + 1 ))

      if (( _in_table )); then
        if [[ "${_line}" == '|'* ]]; then
          # The header's own separator rule is not a row.
          [[ "${_line}" =~ ^\|[-:[:space:]|]+\|[[:space:]]*$ ]] && continue
          _catalog_cell_split_into _name _desc "${_line}" || continue
          [[ -z "${_name}" ]] && continue
          _rows=$(( _rows + 1 ))
          if [[ -n "${_desc}" ]] \
            && [[ "${_desc}" != "${_CATALOG_DESC_PLACEHOLDER}" ]]; then
            continue
          fi
          _key="${_spec}"$'\t'"${_name}"
          if [[ -n "${_baselined[${_key}]:-}" ]]; then
            _used["${_key}"]=1
            _excused=$(( _excused + 1 ))
            continue
          fi
          printf '%s:%d: %s: no description -- %s\n' \
            "${_rel}" "${_lineno}" "${_spec}" "${_name}"
          _violations=$(( _violations + 1 ))
          continue
        fi
        _in_table=0
      fi

      # A heading closes the current section. Only a generated
      # `### <path> (N)` heading opens one, so a hand-written section and
      # TEST.md's index tables carry no spec and are never scanned.
      if [[ "${_line}" =~ ^#{1,6}[[:space:]] ]]; then
        _spec=''
        if [[ "${_line}" =~ ^#{3,6}[[:space:]]+(.+)[[:space:]]+\([0-9]+\)[[:space:]]*$ ]]; then
          _spec="${BASH_REMATCH[1]}"
        fi
        continue
      fi

      if [[ -n "${_spec}" ]] \
        && [[ "${_line}" =~ ^\|[[:space:]]*Test[[:space:]]*\|[[:space:]]*Description[[:space:]]*\|[[:space:]]*$ ]]; then
        _in_table=1
      fi
    done < "${_doc}"
  done < <(find "${_doc_dir}" -maxdepth 1 -type f -name '*.md' -print0 | LC_ALL=C sort -z)

  # The stale half of the ratchet.
  local -a _stale=()
  for _key in "${!_baselined[@]}"; do
    [[ -n "${_used[${_key}]:-}" ]] && continue
    _stale+=("${_key}")
  done
  if [[ "${#_stale[@]}" -gt 0 ]]; then
    local _entry
    while IFS= read -r _entry; do
      printf '%s: stale entry, no longer an undescribed row -- %s\n' \
        "${_CATALOG_DESC_BASELINE_FILE}" "${_entry//$'\t'/: }"
      _violations=$(( _violations + 1 ))
    done < <(printf '%s\n' "${_stale[@]}" | LC_ALL=C sort)
  fi

  if [[ "${_rows}" -eq 0 ]]; then
    _die ci_catalog_description \
      "no catalog rows found under '${_CATALOG_DESC_DOC_DIR}/' (${_catalogs} file(s) read) -- the lint would pass vacuously. A catalogue row is a '| \`name\` | description |' line inside a table a generated '### <path> (N)' section opened with a '| Test | Description |' header; if that shape changed, fix the lint with it."
    return 1
  fi

  if [[ "${_violations}" -gt 0 ]]; then
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_catalog_description \
      "${_violations} undescribed catalogue row / stale or malformed baseline entry. The Description column is REQUIRED: write it after 'just test sync-docs' fills the row with '${_CATALOG_DESC_PLACEHOLDER}'. It answers WHY THIS CASE MATTERS -- what it defends, whether it is the load-bearing one, what breaks without it -- and it does NOT restate what the test does, which the name already says at length. See doc/test/TEST.md. Rows that predate the rule are parked in '${_CATALOG_DESC_BASELINE_FILE}', which may only SHRINK: a stale entry there means its row was described, renamed, moved or deleted, so delete the line and lower the file's '# entries:' count to match."
    return 1
  fi

  echo "catalog description lint: clean (${_rows} rows checked across ${_catalogs} catalogue(s), ${_excused} still on the baseline)"
}
