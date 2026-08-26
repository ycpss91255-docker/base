#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/catalog_description.sh -- the "a
# doc/test catalog row carries a description" lint.
#
# The column is required. It is not redundant with the test name: this
# repo's @test names are long and already say WHAT is asserted, so a
# description that restates them adds nothing, while the descriptions that
# exist say why the case matters -- which one is load-bearing, what it is
# defending. A `-` loses that half. Two specs landing the same week, same
# generator and same review bar, came out opposite ways because nothing
# said which was correct, and that divergence is what this lint stops.
#
# Three design decisions this spec pins:
#
#   - The guard is RATCHETED, not a wall. 747 rows carried the placeholder
#     on the day the rule landed; failing all of them would hold everyone
#     hostage to a backfill nobody asked for, and a rushed backfill
#     produces filler that passes the lint and is worse than `-`. So a
#     baseline file records those rows and the lint fails only on a
#     placeholder that is NOT on it.
#
#   - The baseline is keyed by SPEC PATH plus TEST NAME, so renaming or
#     moving a test drops it out of the baseline and forces a description.
#     Touch it, describe it; leave it alone, leave it alone. That property
#     is the whole reason the baseline is a name list rather than a count,
#     so it gets its own case.
#
#   - The baseline may only SHRINK. Nothing in a checkout can tell whether
#     a line was there yesterday, so the lint does not pretend to: it
#     instead makes every change to the file impossible to make silently.
#     The file declares its own entry count, the count must match, and a
#     baselined row that is no longer a placeholder is refused as stale --
#     so describing a row forces the list and the count DOWN in the same
#     commit, and growing either one is a deliberate, reviewable edit of a
#     number that states how much debt is left.
#
# Detection runs against a controlled temp REPO_ROOT so the spec is
# independent of the live tree's contents; the final cases drive the REAL
# tree. Shape mirrors changelog_entry_lint_spec.bats /
# home_literal_lint_spec.bats.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the function runs against a controlled scratch tree.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/catalog_description.sh

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/${_CATALOG_DESC_DOC_DIR}"
  mkdir -p "${SCRATCH}/$(dirname "${_CATALOG_DESC_BASELINE_FILE}")"
  REPO_ROOT="${SCRATCH}"
  CATALOG="${SCRATCH}/${_CATALOG_DESC_DOC_DIR}/unit.md"
  BASELINE="${SCRATCH}/${_CATALOG_DESC_BASELINE_FILE}"
  # Most cases are about the rows, not the baseline, so start from an
  # empty-but-well-formed baseline and let the cases that care rewrite it.
  _write_baseline
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _write_catalog <spec-path> <row>... -- a scratch catalog with one
# generated section for <spec-path> and the given `| name | desc |` rows.
_write_catalog() {
  local _spec="${1}"
  shift
  {
    printf '# Unit Tests\n\n'
    printf '## Test Files\n\n'
    printf '### %s (%d)\n\n' "${_spec}" "$#"
    printf '| Test | Description |\n|------|-------------|\n'
    [[ $# -gt 0 ]] && printf '%s\n' "$@"
  } > "${CATALOG}"
}

# _row <name> <desc> -- one rendered catalog row, the way
# sync-doc-counts.sh renders it.
_row() {
  printf '| `%s` | %s |' "${1}" "${2}"
}

# _write_baseline <entry>... -- a scratch baseline whose declared count
# matches the entries given. Entries are passed as `<spec>|<name>` and
# joined with the TAB the file actually uses, so the fixtures stay
# readable.
_write_baseline() {
  {
    printf '# scratch baseline\n'
    printf '# entries: %d\n' "$#"
    local _e
    for _e in "$@"; do
      printf '%s\t%s\n' "${_e%%|*}" "${_e#*|}"
    done
  } > "${BASELINE}"
}

# ════════════════════════════════════════════════════════════════════
# The rule: a placeholder row fails
# ════════════════════════════════════════════════════════════════════

@test "_run_catalog_description: FAILS on a placeholder row that is not on the baseline (#922)" {
  _write_catalog 'test/bats/unit/alpha_spec.bats' "$(_row 'alpha does a thing' '-')"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'alpha does a thing'
}

@test "_run_catalog_description: names the catalog file, the line, the spec and the test (#922)" {
  # A finding nobody can act on is a finding that gets muted. The line
  # number comes from the fixture via grep, not from arithmetic over the
  # driver's own scan, so the assertion cannot agree with a miscount.
  _write_catalog 'test/bats/unit/alpha_spec.bats' "$(_row 'alpha does a thing' '-')"
  local _line
  _line="$(grep -n 'alpha does a thing' "${CATALOG}" | cut -d: -f1)"
  run _run_catalog_description
  assert_failure
  assert_output --partial "${_CATALOG_DESC_DOC_DIR}/unit.md:${_line}:"
  assert_output --partial 'test/bats/unit/alpha_spec.bats'
}

@test "_run_catalog_description: reports EVERY undescribed row, not just the first (#922)" {
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' '-')" \
    "$(_row 'beta does another thing' '-')"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'alpha does a thing'
  assert_output --partial 'beta does another thing'
}

@test "_run_catalog_description: an EMPTY description cell counts as a placeholder (#922)" {
  # `-` is what the generator writes; a hand-edited row can be blank, and
  # a blank cell is the same missing sentence wearing less ink.
  _write_catalog 'test/bats/unit/alpha_spec.bats' "$(_row 'alpha does a thing' '')"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'alpha does a thing'
}

@test "_run_catalog_description: PASSES a described row (#922)" {
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'The load-bearing case: nothing else holds without it')"
  run _run_catalog_description
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# The ratchet: today's placeholders are excused, and only those
# ════════════════════════════════════════════════════════════════════

@test "_run_catalog_description: PASSES a placeholder row that IS on the baseline (#922)" {
  _write_catalog 'test/bats/unit/alpha_spec.bats' "$(_row 'alpha does a thing' '-')"
  _write_baseline 'test/bats/unit/alpha_spec.bats|alpha does a thing'
  run _run_catalog_description
  assert_success
}

@test "_run_catalog_description: renaming a baselined test forces a description (#922)" {
  # The property the whole design turns on, and the reason the baseline is
  # a name list rather than a count: touch a test and you own its
  # description; leave it alone and the debt stays parked.
  _write_catalog 'test/bats/unit/alpha_spec.bats' "$(_row 'alpha does a thing, renamed' '-')"
  _write_baseline 'test/bats/unit/alpha_spec.bats|alpha does a thing'
  run _run_catalog_description
  assert_failure
  assert_output --partial 'alpha does a thing, renamed'
}

@test "_run_catalog_description: MOVING a baselined test to another spec forces a description (#922)" {
  # The baseline is scoped by spec path as well as name -- three test
  # names in this tree already live in two specs at once, so a name-only
  # key would excuse a row nobody ever looked at.
  _write_catalog 'test/bats/unit/beta_spec.bats' "$(_row 'alpha does a thing' '-')"
  _write_baseline 'test/bats/unit/alpha_spec.bats|alpha does a thing'
  run _run_catalog_description
  assert_failure
  assert_output --partial 'beta_spec.bats'
}

# ════════════════════════════════════════════════════════════════════
# The baseline may only shrink
# ════════════════════════════════════════════════════════════════════

@test "_run_catalog_description: FAILS on a baseline entry whose row is now DESCRIBED (#922)" {
  # This is what drives the ratchet down. Without it a described row keeps
  # its excuse forever, the file never shrinks, and the count stops
  # meaning anything.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'The load-bearing case')"
  _write_baseline 'test/bats/unit/alpha_spec.bats|alpha does a thing'
  run _run_catalog_description
  assert_failure
  assert_output --partial 'stale'
}

@test "_run_catalog_description: FAILS on a baseline entry whose row is GONE (#922)" {
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'beta does another thing' 'Why beta matters')"
  _write_baseline 'test/bats/unit/alpha_spec.bats|alpha does a thing'
  run _run_catalog_description
  assert_failure
  assert_output --partial 'stale'
}

@test "_run_catalog_description: FAILS when the declared entry count is too LOW (#922)" {
  # Growing the list is the move the ratchet exists to stop, and the
  # declared count is what makes it impossible to make quietly: an added
  # line is a failing lint until someone also raises a number that states
  # how much debt is left.
  _write_catalog 'test/bats/unit/alpha_spec.bats' "$(_row 'alpha does a thing' '-')"
  {
    printf '# entries: 0\n'
    printf 'test/bats/unit/alpha_spec.bats\talpha does a thing\n'
  } > "${BASELINE}"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'entries'
}

@test "_run_catalog_description: FAILS when the declared entry count is too HIGH (#922)" {
  # The other direction: a count left behind by a deletion is a count
  # nobody is reading, and it silently buys room to grow later.
  _write_catalog 'test/bats/unit/alpha_spec.bats' "$(_row 'alpha does a thing' '-')"
  {
    printf '# entries: 9\n'
    printf 'test/bats/unit/alpha_spec.bats\talpha does a thing\n'
  } > "${BASELINE}"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'entries'
}

@test "_run_catalog_description: DIES when the baseline declares no count at all (#922)" {
  # Dropping the directive would turn the shrink-only lock off silently,
  # which is exactly the edit it exists to make loud.
  _write_catalog 'test/bats/unit/alpha_spec.bats' "$(_row 'alpha does a thing' '-')"
  printf 'test/bats/unit/alpha_spec.bats\talpha does a thing\n' > "${BASELINE}"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'entries:'
}

@test "_run_catalog_description: FAILS on an unsorted baseline (#922)" {
  # A 700-line file is only reviewable while its diff is one line per
  # change; unsorted, an insertion can hide anywhere.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'zulu' '-')" "$(_row 'alpha' '-')"
  {
    printf '# entries: 2\n'
    printf 'test/bats/unit/alpha_spec.bats\tzulu\n'
    printf 'test/bats/unit/alpha_spec.bats\talpha\n'
  } > "${BASELINE}"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'sorted'
}

@test "_run_catalog_description: FAILS on a duplicated baseline entry (#922)" {
  # Two lines, one excused row: the count then overstates the debt and a
  # later deletion of one copy looks like progress.
  _write_catalog 'test/bats/unit/alpha_spec.bats' "$(_row 'alpha' '-')"
  {
    printf '# entries: 2\n'
    printf 'test/bats/unit/alpha_spec.bats\talpha\n'
    printf 'test/bats/unit/alpha_spec.bats\talpha\n'
  } > "${BASELINE}"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'duplicate'
}

@test "_run_catalog_description: FAILS on a baseline line with no TAB separator (#922)" {
  _write_catalog 'test/bats/unit/alpha_spec.bats' "$(_row 'alpha' '-')"
  {
    printf '# entries: 1\n'
    printf 'test/bats/unit/alpha_spec.bats alpha\n'
  } > "${BASELINE}"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'malformed'
}

# ════════════════════════════════════════════════════════════════════
# What is and is not a catalog row
# ════════════════════════════════════════════════════════════════════

@test "_run_catalog_description: a summary table is not a per-test catalog (#922)" {
  # A section may summarise with a `| Category | Tests |` table instead of
  # a row each. Reading those cells as test names would invent findings
  # for rows that were never claimed to be tests.
  {
    printf '# Unit Tests\n\n'
    printf '### test/bats/unit/alpha_spec.bats (40)\n\n'
    printf '| Category | Tests |\n|------|-------------|\n'
    printf '| parsing | 20 |\n'
    printf '| rendering | 20 |\n'
  } > "${CATALOG}"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'no catalog rows'
}

@test "_run_catalog_description: a table under no spec section is not scanned (#922)" {
  # TEST.md's own index tables are `| Lint | ... |` shaped and belong to
  # no spec; only a table under a generated `### <path> (N)` heading is a
  # catalog.
  {
    printf '# Test index\n\n'
    printf '| Test | Description |\n|------|-------------|\n'
    printf '| `not a catalog row` | - |\n'
  } > "${CATALOG}"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'no catalog rows'
}

@test "_run_catalog_description: scans EVERY catalog in the directory, not just one (#922)" {
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  {
    printf '# Integration Tests\n\n'
    printf '### test/bats/integration/gamma_spec.bats (1)\n\n'
    printf '| Test | Description |\n|------|-------------|\n'
    printf '| `gamma does a thing` | - |\n'
  } > "${SCRATCH}/${_CATALOG_DESC_DOC_DIR}/integration.md"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'gamma does a thing'
}

# ════════════════════════════════════════════════════════════════════
# Non-vacuity
# ════════════════════════════════════════════════════════════════════

@test "_run_catalog_description: DIES when the catalog directory is missing (#922)" {
  rm -rf "${SCRATCH:?}/${_CATALOG_DESC_DOC_DIR}"
  run _run_catalog_description
  assert_failure
  assert_output --partial "${_CATALOG_DESC_DOC_DIR}"
}

@test "_run_catalog_description: DIES when the baseline file is missing (#922)" {
  # A missing baseline would fail 747 rows at once rather than pass
  # vacuously, but it is still the file's shape changing under the lint,
  # and it should say so instead of burying it in 747 findings.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')"
  rm -f "${BASELINE}"
  run _run_catalog_description
  assert_failure
  assert_output --partial "${_CATALOG_DESC_BASELINE_FILE}"
}

@test "_run_catalog_description: the clean line says how many rows it checked and excused (#922)" {
  # A green line standing for zero inspected rows is the vacuous pass this
  # repo keeps having to fix, so the count that was actually measured is
  # printed next to the count the baseline took off the table.
  _write_catalog 'test/bats/unit/alpha_spec.bats' \
    "$(_row 'alpha does a thing' 'Why alpha matters')" \
    "$(_row 'beta does another thing' '-')"
  _write_baseline 'test/bats/unit/alpha_spec.bats|beta does another thing'
  run _run_catalog_description
  assert_success
  assert_output --partial '2 rows checked'
  assert_output --partial '1 still on the baseline'
}

# ════════════════════════════════════════════════════════════════════
# The real tree
# ════════════════════════════════════════════════════════════════════

@test "_run_catalog_description: the real doc/test catalogs are clean (#922)" {
  REPO_ROOT=/source
  run _run_catalog_description
  assert_success
}

@test "_run_catalog_description: the rows the changelog-entry lint added are described, not baselined (#922)" {
  # The rows that prompted the rule. They landed the same week, so the
  # author's intent was still recoverable, which is why they were written
  # rather than parked -- and pinning that here stops a later sweep from
  # quietly moving them onto the baseline.
  run grep -c '(#917)' "/source/${_CATALOG_DESC_BASELINE_FILE}"
  assert_output '0'
}
