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
# 1517 of 2556 rows carry the placeholder (747 of 1711 when the rule was
# first written, before the 25 sections that had no per-test table at all
# were given one -- 820 rows the catalogue had never listed and the rule
# had therefore never reached).
# Failing all of them turns CI red until 1517 sentences exist, which blocks
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
#   3. The entries must be sorted (LC_ALL=C) and unique. A 1500-line file is
#      only reviewable while its diff is one line per change; unsorted, an
#      insertion hides anywhere, and a duplicate overstates the debt so
#      that deleting one copy looks like progress.
#
#   4. An entry over a row that is already DESCRIBED is refused. The file
#      records what was ALREADY missing; the moment it also holds a row
#      that was fine, that row's description is unenforced -- it can go
#      back to `-` with the lint green. The way a described row acquires a
#      placeholder twin is a spec answering TWICE, so a duplicated
#      `### <path> (N)` section is refused as well: it is a document
#      contradicting itself, and the generator fills both copies.
#
# That is the honest boundary: (1) and (4) are mechanical and do the work,
# (2) and (3) make the remaining move visible rather than impossible.
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
# ── Reach ─────────────────────────────────────────────────────────────
#
# A rule that does not apply to half of what it governs is close to no rule
# at all, and the worse half is the silence. Scanning only the sections it
# recognised, this lint reached 1736 of 3162 tests; the other 1426 sat
# outside a REQUIRED field because their section answered with a
# `| Category | Tests |` summary or with prose and no table, which nothing
# recorded, nothing reported and nothing bounded. It was also an opt-out:
# replacing a covered section's rows with a three-line summary took them
# out of scope with both gates green and nothing in the diff saying why.
#
# So the unit of the rule is the generated SECTION, not the table the
# section happens to carry. Every `### <path> (N)` heading in a scanned
# document is either
#
#   1. a per-test catalogue (`| Test | Description |`), every row of which
#      needs a description; or
#   2. DECLARED, with a reason, in the exemptions file -- which the lint
#      reads, holds to a declared count, refuses without a reason, and
#      refuses to keep once the section has real rows again.
#
# There is no third answer, so a section cannot leave the rule by accident
# and the clean line can state the reach it actually has: rows checked,
# rows the baseline still excuses, sections declared out, and the tests
# those sections account for.
#
# Summarising is a legitimate answer -- 13 sections here group 606 tests by
# concern rather than list 606 near-identical assertion names -- and the
# exemptions file is not shrink-only for that reason: unlike the baseline
# it holds decisions, not debt. What it costs is a line, a sentence and a
# bumped number, in front of a reviewer.
#
# Non-vacuity: a missing catalog directory, a missing baseline file, a
# missing exemptions file, or a scan that finds no catalog rows at all DIES
# rather than reporting clean. The clean line states how many rows were
# checked, how many the baseline still excuses and how much of the suite is
# declared out, so a green line is never read as a verdict over rows that
# were never there.

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

# The scanned directory and the two sidecar files, repo-root-relative. All
# three must exist: any one missing would change what the lint means
# without changing the lint.
readonly _CATALOG_DESC_DOC_DIR='doc/test'
readonly _CATALOG_DESC_BASELINE_FILE='script/test/catalog-description-baseline.txt'
readonly _CATALOG_DESC_EXEMPT_FILE='script/test/catalog-description-exemptions.txt'

# The placeholder sync-doc-counts.sh writes for a row it has no description
# for (`_catalog_flush_desc[${_name}]:--`). An empty cell counts as one
# too: a hand-edited blank is the same missing sentence wearing less ink.
readonly _CATALOG_DESC_PLACEHOLDER='-'

# The directive the baseline declares its own size with. See the header:
# this is the number that may only ever go down.
readonly _CATALOG_DESC_COUNT_RE='^#[[:space:]]*entries:[[:space:]]*([0-9]+)[[:space:]]*$'

# _catalog_desc_load_list <abs-path> <rel-path> <mode> <map-outvar>
# <count-outvar> -- read one of the two sidecar lists into an associative
# array, validating the file's own shape on the way through: the declared
# count, sortedness, uniqueness and the TAB separator. Prints one line per
# finding and stores the number of findings in <count-outvar>.
#
# The count comes back through a nameref and NOT through the exit status,
# which is why the caller does not read `$?`. An exit status is 8 bits: a
# 256-finding file returned 0, the caller's `||` never fired, and the lint
# printed 256 findings and then declared itself clean -- a guard whose own
# report contradicted its verdict, which is the defect class this driver
# exists to refuse. This file holds four figures of entries, so 256 is one
# re-sort under another locale or one bulk regeneration away.
#
# <mode> is 'rows' for the baseline, whose whole `<spec> TAB <name>` line is
# the key and which carries no value, or 'reasons' for the exemptions, whose
# key is the spec path and whose value -- the reason the section is outside
# the rule -- must actually say something. One loader rather than two: the
# two files answer different questions but they are the same artifact, a
# sorted list that declares its own size so a change to it cannot be made
# quietly, and a second copy of that reader would drift from this one.
_catalog_desc_load_list() {
  local _abs="${1}" _rel="${2}" _mode="${3}"
  local -n _cd_map="${4}"
  local -n _cd_findings_out="${5}"
  local _shape='<spec path> TAB <test name>'
  [[ "${_mode}" == 'reasons' ]] && _shape='<spec path> TAB <reason>'
  local _line _lineno=0 _declared='' _count=0 _prev='' _findings=0
  local _key _value _keep
  # The file's order is defined as LC_ALL=C, and `[[ < ]]` compares by the
  # CURRENT locale's collation -- which differs between the musl test-tools
  # image and the glibc lint-static runner, so the same file would sort two
  # ways. A local assignment to LC_ALL is scoped to this function and
  # restored on return, which makes the comparison byte-wise without
  # spawning a `sort`.
  local LC_ALL=C
  _cd_map=()
  _cd_findings_out=0

  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    _lineno=$(( _lineno + 1 ))
    if [[ "${_line}" =~ ${_CATALOG_DESC_COUNT_RE} ]]; then
      _declared="${BASH_REMATCH[1]}"
      continue
    fi
    [[ "${_line}" == '#'* ]] && continue
    [[ -z "${_line}" ]] && continue

    if [[ "${_line}" != *$'\t'* ]]; then
      printf '%s:%d: malformed entry (expected %s) -- %s\n' \
        "${_rel}" "${_lineno}" "${_shape}" "${_line}"
      _findings=$(( _findings + 1 ))
      continue
    fi
    _key="${_line}"
    _value=1
    # A rejected entry still COUNTS: the file holds the line, so dropping it
    # from the tally would report the reason and the size as two separate
    # findings for one edit.
    _keep=1
    if [[ "${_mode}" == 'reasons' ]]; then
      _key="${_line%%$'\t'*}"
      _value="${_line#*$'\t'}"
      # A blank or placeholder reason is the silence this file exists to
      # break, one indirection further away, so it is refused exactly as a
      # row's own placeholder is.
      if [[ ! "${_value}" =~ [^[:space:]] ]] \
        || [[ "${_value}" == "${_CATALOG_DESC_PLACEHOLDER}" ]]; then
        printf '%s:%d: no reason given for the exemption -- say what makes a row each the wrong shape for this section: %s\n' \
          "${_rel}" "${_lineno}" "${_key}"
        _findings=$(( _findings + 1 ))
        _keep=0
      fi
    fi
    if [[ -n "${_cd_map[${_key}]:-}" ]]; then
      printf '%s:%d: duplicate entry -- %s\n' "${_rel}" "${_lineno}" "${_key}"
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
    (( _keep )) && _cd_map["${_key}"]="${_value}"
    _count=$(( _count + 1 ))
  done < "${_abs}"

  if [[ -z "${_declared}" ]]; then
    printf '%s: no "# entries: <n>" directive -- that number is what makes a change to this file impossible to commit silently, and dropping it is the one edit it exists to make loud\n' \
      "${_rel}"
    _findings=$(( _findings + 1 ))
  elif [[ "${_declared}" -ne "${_count}" ]]; then
    printf '%s: declares "# entries: %s" but holds %d -- if this is a removal lower the number, and if it is an addition it needs saying out loud\n' \
      "${_rel}" "${_declared}" "${_count}"
    _findings=$(( _findings + 1 ))
  fi

  _cd_findings_out="${_findings}"
}

_run_catalog_description() {
  echo "--- Running catalog description lint ---"
  local _doc_dir="${REPO_ROOT}/${_CATALOG_DESC_DOC_DIR}"
  local _baseline="${REPO_ROOT}/${_CATALOG_DESC_BASELINE_FILE}"
  local _exempt="${REPO_ROOT}/${_CATALOG_DESC_EXEMPT_FILE}"

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

  if [[ ! -f "${_exempt}" ]]; then
    _die ci_catalog_description \
      "exemptions file '${_CATALOG_DESC_EXEMPT_FILE}' not found under ${REPO_ROOT} -- without it every section that answers with a summary instead of a row each fails at once. Restore the file rather than regenerating it: it is a record of decisions somebody made, not a cache."
    return 1
  fi

  local _violations=0

  # The loaders report their finding count through a nameref: the count is
  # a tally, not a verdict, and an exit status cannot carry one (see
  # _catalog_desc_load_list).
  local _load_findings=0

  local -A _baselined=()
  _catalog_desc_load_list "${_baseline}" "${_CATALOG_DESC_BASELINE_FILE}" \
    rows _baselined _load_findings
  _violations=$(( _violations + _load_findings ))

  # The sections that answer with a summary instead of a row each, keyed by
  # spec path, valued by the reason. Read the same way and held to the same
  # shape as the baseline.
  local -A _exempted=()
  _catalog_desc_load_list "${_exempt}" "${_CATALOG_DESC_EXEMPT_FILE}" \
    reasons _exempted _load_findings
  _violations=$(( _violations + _load_findings ))

  # Which baseline entries a live placeholder row still needs. Anything
  # left over at the end is stale -- described, renamed, moved or deleted --
  # and is what drives the file down.
  local -A _used=()

  local _doc _rel _spec _line _lineno _in_table _rows=0 _catalogs=0 _excused=0
  local _name _desc _key
  # Where each described row was read, keyed the way the baseline is. A
  # baseline entry over one of these is refused below: the entry would
  # excuse a row that does not need excusing, and the description it sits
  # on stops being enforced.
  local -A _described=()
  # One section per spec, and where the first one was. A second copy is the
  # document contradicting itself: the generator fills both, so the copies
  # disagree the moment either is enriched.
  local -A _section_at=()
  # Every generated section, whether or not it turned out to be a
  # catalogue: `<doc> TAB <heading line> TAB <spec> TAB <declared tests>`,
  # with _governed marking the ones that opened a per-test table. Deciding
  # after the scan rather than at each closing heading keeps one copy of
  # the decision instead of one at every place a section can end.
  local -a _sections=()
  local -A _governed=()
  local _cur=-1
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
          _key="${_spec}"$'\t'"${_name}"
          if [[ -n "${_desc}" ]] \
            && [[ "${_desc}" != "${_CATALOG_DESC_PLACEHOLDER}" ]]; then
            _described["${_key}"]="${_rel}:${_lineno}"
            continue
          fi
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
        _cur=-1
        if [[ "${_line}" =~ ^#{3,6}[[:space:]]+(.+)[[:space:]]+\(([0-9]+)\)[[:space:]]*$ ]]; then
          _spec="${BASH_REMATCH[1]}"
          # A spec answers ONCE. The second copy is skipped rather than
          # scanned -- both copies carry the same names, so reading it
          # would report its rows a second time and count them a second
          # time on top of the one finding that says what is wrong.
          if [[ -n "${_section_at[${_spec}]:-}" ]]; then
            printf '%s:%d: %s: duplicate section -- already opened at %s. Two sections for one spec are two answers: "just test sync-docs" fills both, so a row described in one is a placeholder in the other, and a placeholder the baseline excuses unenforces the description in its twin. Delete the copy, heading and table together.\n' \
              "${_rel}" "${_lineno}" "${_spec}" "${_section_at[${_spec}]}"
            _violations=$(( _violations + 1 ))
            _spec=''
            continue
          fi
          _section_at["${_spec}"]="${_rel}:${_lineno}"
          _sections+=(
            "${_rel}"$'\t'"${_lineno}"$'\t'"${_spec}"$'\t'"${BASH_REMATCH[2]}"
          )
          _cur=$(( ${#_sections[@]} - 1 ))
        fi
        continue
      fi

      if [[ -n "${_spec}" ]] \
        && [[ "${_line}" =~ ^\|[[:space:]]*Test[[:space:]]*\|[[:space:]]*Description[[:space:]]*\|[[:space:]]*$ ]]; then
        _in_table=1
        (( _cur >= 0 )) && _governed["${_cur}"]=1
      fi
    done < "${_doc}"
  done < <(find "${_doc_dir}" -maxdepth 1 -type f -name '*.md' -print0 | LC_ALL=C sort -z)

  # Every section is a catalogue or a declared exemption. There is no
  # third answer: a section outside the rule by table shape alone is what
  # let 45% of the suite sit outside a required field with nothing saying
  # so.
  local -A _exempt_used=()
  local _sec_rel _sec_line _sec_spec _sec_tests _i
  local _exempt_sections=0 _exempt_tests=0
  for (( _i = 0; _i < ${#_sections[@]}; _i++ )); do
    [[ -n "${_governed[${_i}]:-}" ]] && continue
    IFS=$'\t' read -r _sec_rel _sec_line _sec_spec _sec_tests \
      <<< "${_sections[_i]}"
    if [[ -n "${_exempted[${_sec_spec}]:-}" ]]; then
      _exempt_used["${_sec_spec}"]=1
      _exempt_sections=$(( _exempt_sections + 1 ))
      _exempt_tests=$(( _exempt_tests + _sec_tests ))
      continue
    fi
    printf '%s:%d: %s: no per-test catalogue and no declared exemption -- the description rule does not reach these %s test(s). Give the section a "| Test | Description |" table ("just test sync-docs" fills the rows) or add it to %s with the reason a row each is the wrong shape here.\n' \
      "${_sec_rel}" "${_sec_line}" "${_sec_spec}" "${_sec_tests}" \
      "${_CATALOG_DESC_EXEMPT_FILE}"
    _violations=$(( _violations + 1 ))
  done

  local -a _stale_exempt=()
  for _key in "${!_exempted[@]}"; do
    [[ -n "${_exempt_used[${_key}]:-}" ]] && continue
    _stale_exempt+=("${_key}")
  done
  if [[ "${#_stale_exempt[@]}" -gt 0 ]]; then
    local _gone
    while IFS= read -r _gone; do
      printf '%s: stale entry, no longer a section outside the per-test rule -- %s\n' \
        "${_CATALOG_DESC_EXEMPT_FILE}" "${_gone}"
      _violations=$(( _violations + 1 ))
    done < <(printf '%s\n' "${_stale_exempt[@]}" | LC_ALL=C sort)
  fi

  # The other half of "the baseline records what was ALREADY missing": an
  # entry may only ever excuse an UNDESCRIBED row. A key that is also a
  # described row leaves that description unenforced -- it can go back to
  # the placeholder with the lint green -- which is the ratchet running
  # backwards. Only entries a live placeholder still uses are reported
  # here; one whose only match is the described row is already stale
  # below, and one edit deserves one finding.
  local -a _absorbed=()
  for _key in "${!_baselined[@]}"; do
    [[ -n "${_used[${_key}]:-}" ]] || continue
    [[ -n "${_described[${_key}]:-}" ]] || continue
    _absorbed+=("${_key}"$'\t'"${_described[${_key}]}")
  done
  if [[ "${#_absorbed[@]}" -gt 0 ]]; then
    local _entry _where
    while IFS= read -r _entry; do
      _where="${_entry##*$'\t'}"
      _entry="${_entry%$'\t'*}"
      printf '%s: entry excuses a row that is DESCRIBED at %s -- %s\n' \
        "${_CATALOG_DESC_BASELINE_FILE}" "${_where}" "${_entry//$'\t'/: }"
      _violations=$(( _violations + 1 ))
    done < <(printf '%s\n' "${_absorbed[@]}" | LC_ALL=C sort)
  fi

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
      "${_violations} undescribed catalogue row / ungoverned or duplicated section / stale, absorbing or malformed baseline or exemption entry. The Description column is REQUIRED: write it after 'just test sync-docs' fills the row with '${_CATALOG_DESC_PLACEHOLDER}'. It answers WHY THIS CASE MATTERS -- what it defends, whether it is the load-bearing one, what breaks without it -- and it does NOT restate what the test does, which the name already says at length. See doc/test/TEST.md. Rows that predate the rule are parked in '${_CATALOG_DESC_BASELINE_FILE}', which may only SHRINK: a stale entry there means its row was described, renamed, moved or deleted, so delete the line and lower the file's '# entries:' count to match. A section that answers with a summary rather than a row each is outside the rule only when '${_CATALOG_DESC_EXEMPT_FILE}' says so and says why. An entry that excuses a row somebody already described is refused too -- the baseline records what was missing, never a row that was fine -- and so is a spec carrying two sections, which is how a described row acquires a placeholder twin."
    return 1
  fi

  echo "catalog description lint: clean (${_rows} rows checked across ${_catalogs} catalogue(s), ${_excused} still on the baseline; ${_exempt_sections} section(s) declared outside the per-test rule, covering ${_exempt_tests} test(s))"
}
