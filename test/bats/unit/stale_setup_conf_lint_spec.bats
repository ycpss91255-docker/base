#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/stale_setup_conf.sh -- the
# "no stale config/docker/setup.conf path in runtime shell code" lint.
# The per-repo override and the template default now live at the repo-root
# setup.toml file, so a hardcoded config/docker/setup.conf in dist/
# runtime code reads a path that no longer exists and silently ignores the
# repo's knobs. The legacy-migration lib, dist/script/docker/lib/
# setup_conf_migrate.sh, is the one legitimate consumer and opts out via
# explicit allow-begin / allow-end markers. Detection runs against a controlled temp REPO_ROOT so
# the spec is independent of the live tree's contents; a final case drives
# the REAL dist/ to prove it passes today.
#
# why: Unit tests for `script/test/drivers/stale_setup_conf.sh`
# (`_run_stale_setup_conf`, refs #845), the "no stale
# `config/docker/setup.conf` path in runtime shell code" lint. The per-repo
# override and the template default now live at the repo-root `setup.toml`
# file, so a hardcoded legacy path in `dist/**/*.sh` reads a location
# that no longer exists and silently ignores the repo's knobs. The
# legacy-migration lib `dist/script/docker/lib/setup_conf_migrate.sh` is
# the one legitimate consumer and opts out via explicit `allow-begin` /
# `allow-end` markers. Driven over throwaway fixture `dist/` trees, plus a real-tree
# guard that the live `dist/` passes today.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the function runs against a controlled scratch tree. Mirrors
  # issueref_lint_spec.bats.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/stale_setup_conf.sh

  # The table's delimiter, named rather than typed. A literal 0x09 in a
  # spec line is invisible, and losing one is not a loud failure: the row
  # it delimited stops parsing, the derived population silently SHRINKS by
  # one, and most of this file stays green over a fixture that no longer
  # says what it says. That is the declared-population failure this issue
  # is about, reached through the test rather than the driver, so the
  # fixture refuses a row it cannot deliver (see _write_table).
  _TAB=$'\t'

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/dist/script/docker/lib" "${SCRATCH}/dist/script/base"
  REPO_ROOT="${SCRATCH}"

  # The literal the lint hunts for, assembled at runtime so this spec file
  # never carries the stale path as a plain token of its own.
  STALE="config/docker/${_STALE_SETUP_CONF_BASENAME}"

  # The fixture tree carries a rename table, because the lint DERIVES the
  # TOML-era half of its stale set from one rather than declaring it. A
  # tree without a table is its own case below, not the default.
  _write_table ".${_STALE_SETUP_CONF_BASENAME}${_TAB}setup.toml" \
    ".${_STALE_SETUP_CONF_BASENAME}.local${_TAB}setup.local.toml"
}

# _assert_tab_delimited <row>... -- fail the test, loudly, on any row that
# is not exactly `source<TAB>target`.
#
# The driver drops a malformed row, by design: it is reading a shipped lib
# and must not break on one. That is the right behaviour there and the
# wrong silence here, because a fixture row that quietly stops counting
# leaves a test asserting over a population it did not set up -- and
# several of the cases below would still pass, on the refusal the shrunken
# table triggers rather than on the rule they name.
_assert_tab_delimited() {
  local _row
  for _row in "$@"; do
    [[ "${_row}" == *"${_TAB}"* ]] \
      || fail "fixture row is not tab-delimited: ${_row}"
    [[ "${_row}" != *"${_TAB}"*"${_TAB}"* ]] \
      || fail "fixture row has more than one tab: ${_row}"
    [[ "${_row%"${_TAB}"*}" != "" && "${_row#*"${_TAB}"}" != "" ]] \
      || fail "fixture row has an empty half: ${_row}"
  done
}

# _write_table <row>... -- plant a rename table in the fixture tree at the
# path the driver reads, each row a literal `source<TAB>target`.
#
# BRACKETED by allow markers, the way the real table is. The table sits
# inside the scanned tree and its rows name the retired spellings, so it
# is itself a hit; the lint does not exempt its own source, and
# `_write_table_unbracketed` below is the case that pins that. The markers
# go outside the heredoc so they never become table rows.
_write_table() {
  local _f="${SCRATCH}/${_STALE_SETUP_CONF_TABLE_REL}"
  _assert_tab_delimited "$@"
  mkdir -p "$(dirname "${_f}")"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '# %s -- the table is the retired-to-current map\n' \
      "${_STALE_SETUP_CONF_ALLOW_BEGIN}"
    printf '%s() {\n' "${_STALE_SETUP_CONF_TABLE_FN}"
    printf "  cat <<'TABLE_EOF'\n"
    printf '%s\n' "$@"
    printf 'TABLE_EOF\n}\n'
    printf '# %s\n' "${_STALE_SETUP_CONF_ALLOW_END}"
  } > "${_f}"
}

# _write_table_unbracketed <row>... -- the same table with NO allow
# markers, for the case that asserts the lint has no implicit exemption
# for the file it derives its population from.
_write_table_unbracketed() {
  local _f="${SCRATCH}/${_STALE_SETUP_CONF_TABLE_REL}"
  _assert_tab_delimited "$@"
  mkdir -p "$(dirname "${_f}")"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s() {\n' "${_STALE_SETUP_CONF_TABLE_FN}"
    printf "  cat <<'TABLE_EOF'\n"
    printf '%s\n' "$@"
    printf 'TABLE_EOF\n}\n'
  } > "${_f}"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _write <relative-path> <line>... -- create a dist/ fixture script.
_write() {
  local _rel="${1}"; shift
  mkdir -p "$(dirname "${SCRATCH}/${_rel}")"
  printf '%s\n' "$@" > "${SCRATCH}/${_rel}"
}

# ════════════════════════════════════════════════════════════════════
# _run_stale_setup_conf: violations
# ════════════════════════════════════════════════════════════════════

# why: Stale path fails, file:line named
@test "_run_stale_setup_conf: FAILS on a stale path in a dist/ script, naming file and line (#845)" {
  _write "dist/script/docker/lib/sample.sh" \
    '#!/usr/bin/env bash' \
    "_conf=\"\${_root}/${STALE}\""
  run _run_stale_setup_conf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/sample.sh:2"* ]]
}

# why: Message points at `setup.toml`
@test "_run_stale_setup_conf: names the replacement path in the failure message (#845)" {
  _write "dist/script/docker/lib/sample.sh" \
    "_conf=\"\${_root}/${STALE}\""
  run _run_stale_setup_conf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"setup.toml"* ]]
}

# why: Comments are in scope, not exempt
@test "_run_stale_setup_conf: FAILS on a stale path inside a comment too (#845)" {
  _write "dist/script/docker/lib/sample.sh" \
    "# read the override from ${STALE}"
  run _run_stale_setup_conf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"sample.sh:1"* ]]
}

# why: Allow region ends at the end marker
@test "_run_stale_setup_conf: FAILS on a stale path AFTER an allow-end (region does not leak) (#845)" {
  _write "dist/script/base/sample.sh" \
    "# ${_STALE_SETUP_CONF_ALLOW_BEGIN} legacy migration" \
    "_legacy=\"\${_root}/${STALE}\"" \
    "# ${_STALE_SETUP_CONF_ALLOW_END}" \
    "_other=\"\${_root}/${STALE}\""
  run _run_stale_setup_conf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"sample.sh:4"* ]]
  [[ "${output}" != *"sample.sh:2"* ]]
}

# why: Unbalanced begin marker fails loudly
@test "_run_stale_setup_conf: FAILS on an unterminated allow-begin region (#845)" {
  _write "dist/script/base/sample.sh" \
    "# ${_STALE_SETUP_CONF_ALLOW_BEGIN} legacy migration" \
    "_legacy=\"\${_root}/${STALE}\""
  run _run_stale_setup_conf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unterminated"* ]]
}

# why: Unmatched end marker fails loudly
@test "_run_stale_setup_conf: FAILS on an allow-end with no matching allow-begin (#845)" {
  _write "dist/script/base/sample.sh" \
    '#!/usr/bin/env bash' \
    "# ${_STALE_SETUP_CONF_ALLOW_END}"
  run _run_stale_setup_conf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unmatched"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_stale_setup_conf: exemptions and clean trees
# ════════════════════════════════════════════════════════════════════

# why: Marked migration block exempt
@test "_run_stale_setup_conf: EXEMPTS a stale path inside an allow-begin/allow-end region (#845)" {
  _write "dist/script/base/sample.sh" \
    "# ${_STALE_SETUP_CONF_ALLOW_BEGIN} legacy migration" \
    "_legacy=\"\${_root}/${STALE}\"" \
    "# ${_STALE_SETUP_CONF_ALLOW_END}"
  run _run_stale_setup_conf
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# why: `setup.toml` tree clean
@test "_run_stale_setup_conf: PASSES a dist/ tree that uses the repo-root config (#845)" {
  _write "dist/script/docker/lib/sample.sh" \
    '#!/usr/bin/env bash' \
    '_conf="${_root}/setup.toml"'
  run _run_stale_setup_conf
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# why: Docs out of the lint's scope
@test "_run_stale_setup_conf: ignores non-.sh files under dist/ (#845)" {
  mkdir -p "${SCRATCH}/dist/doc"
  printf '%s\n' "the override used to live at ${STALE}" \
    > "${SCRATCH}/dist/doc/notes.md"
  run _run_stale_setup_conf
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_stale_setup_conf: scan-root guard
# ════════════════════════════════════════════════════════════════════

# why: Missing scan root fails, no vacuous pass
@test "_run_stale_setup_conf: FAILS when the dist/ scan root is missing (no vacuous pass) (#845)" {
  # An empty find root passes vacuously, silently disabling the lint if
  # dist/ is ever relocated. Fail loudly on a missing scan root instead.
  rm -rf "${SCRATCH}/dist"
  run _run_stale_setup_conf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_stale_setup_conf: the retired spellings the table declares
# (base#1251)
# ════════════════════════════════════════════════════════════════════

# why: the guard tested ONE substring while the tree's own rename table
# listed three retired spellings. base#1249 deleted 19 lines naming the
# repo-root INI dotfile from a shipped wrapper -- exactly the shape this
# driver's header calls a live defect -- and the lint was green before the
# PR and green after it. A new lib hardcoding that spelling reads a file
# nothing writes any more, with no error and, until now, no test.
@test "_run_stale_setup_conf: FAILS on the repo-root INI dotfile spelling the table retired (base#1251)" {
  _write "dist/script/docker/lib/sample.sh" \
    '#!/usr/bin/env bash' \
    "_conf=\"\${_root}/.${_STALE_SETUP_CONF_BASENAME}\""
  run _run_stale_setup_conf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/sample.sh:2"* ]]
  [[ "${output}" == *"setup.toml"* ]]
}

# why: the per-worktree override layer was retired by the same rename and
# is a separate spelling with a DIFFERENT replacement. Reported as a hit
# on the shorter spelling it contains, it would have been sent to
# `setup.toml` -- the wrong file, and the one whose values every worktree
# shares. Longest source first is what keeps the advice right.
@test "_run_stale_setup_conf: names setup.local.toml for the local-override spelling, not setup.toml (base#1251)" {
  _write "dist/script/docker/lib/sample.sh" \
    "_local=\"\${_root}/.${_STALE_SETUP_CONF_BASENAME}.local\""
  run _run_stale_setup_conf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"setup.local.toml"* ]]
  [[ "${output}" != *"use setup.toml"* ]]
}

# why: THE declared-population test (base#1089, base#1090, base#1113,
# base#1112, base#1109, base#1214). A guard naming today's three spellings
# would agree with the tree the day it was written and stop agreeing the
# day a fourth is retired -- which base#1167 is held back to do. So the
# population is read from `_ini_to_toml_conversions`, and this proves it:
# a row this spec invents is guarded, with ITS replacement, by a driver
# that has never heard of it.
@test "_run_stale_setup_conf: guards a spelling retired by a row the driver never named (base#1251)" {
  _write_table ".oldthing.conf${_TAB}newthing.toml"
  _write "dist/script/docker/lib/sample.sh" \
    '_c="${_root}/.oldthing.conf"'
  run _run_stale_setup_conf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"sample.sh:1"* ]]
  [[ "${output}" == *"newthing.toml"* ]]
}

# why: the derivation is the guard's subject, so losing it has to be
# loud. A table that cannot be read would narrow the stale set back to the
# one hand-written pre-relocation spelling and the lint would go green
# over the very spellings base#1251 is about -- the vacuous pass the scan
# root guard already refuses, one level up.
@test "_run_stale_setup_conf: FAILS when the rename table yields no rows (no vacuous pass) (base#1251)" {
  rm -f "${SCRATCH}/${_STALE_SETUP_CONF_TABLE_REL}"
  _write "dist/script/docker/lib/sample.sh" \
    '_c="${_root}/setup.toml"'
  run _run_stale_setup_conf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"${_STALE_SETUP_CONF_TABLE_FN}"* ]]
}

# why: the widened spellings take the SAME region-delimited opt-out, not a
# per-file exclusion -- which is what lets the three migration libs name
# the old paths (that is their job) while a NEW stale reference elsewhere
# in those same files is still caught.
@test "_run_stale_setup_conf: EXEMPTS the INI dotfile spelling inside an allow region (base#1251)" {
  _write "dist/script/base/sample.sh" \
    "# ${_STALE_SETUP_CONF_ALLOW_BEGIN} legacy migration" \
    "_legacy=\"\${_root}/.${_STALE_SETUP_CONF_BASENAME}\"" \
    "# ${_STALE_SETUP_CONF_ALLOW_END}" \
    "_other=\"\${_root}/.${_STALE_SETUP_CONF_BASENAME}.local\""
  run _run_stale_setup_conf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"sample.sh:4"* ]]
  [[ "${output}" != *"sample.sh:2"* ]]
}

# why: the lint reads its population from a file inside the tree it scans,
# whose rows spell out the retired paths -- so that file is a hit like any
# other, and it opts out by the same bracketed region rather than by the
# driver special-casing it. An implicit self-exemption would be a
# file-level exclusion by another name, and it would hide a NEW stale read
# added to the migration lib that owns the table.
@test "_run_stale_setup_conf: does NOT exempt the rename table's own file implicitly (base#1251)" {
  _write_table_unbracketed ".${_STALE_SETUP_CONF_BASENAME}${_TAB}setup.toml"
  run _run_stale_setup_conf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"${_STALE_SETUP_CONF_TABLE_REL}"* ]]
}
