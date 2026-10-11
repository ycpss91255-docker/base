#!/usr/bin/env bats
#
# upgrade_migration_reachability_spec.bats - no migration may live in
# `dist/script/base/upgrade.sh`, because a migration placed there can only
# reach repos that already have it.
#
# ── The rule, and why it is a rule and not an incident ──────────────────────
#
# An upgrade is driven by the CONSUMER'S OWN vendored `upgrade.sh`, which
# shipped in an older release and can never be changed retroactively. So a
# migration added to that file today runs only on repos ALREADY at today's
# release -- which is, by construction, the population that does not need it.
# Worse, it does not fail: it reads a precondition that is false, returns 0,
# and nothing anywhere says the work was skipped.
#
# base#1110 is the instance that produced this file. `[lifecycle] restart`
# was rescoped, and the migration that retired the stale `restart = no`
# gated on the VENDORED template under `${TEMPLATE_REL}/` -- the tree the
# pull is about to replace -- still carrying the old value. The function and
# the new template default landed in the same commit, so the two conditions
# were mutually exclusive: every published tag carrying the function also
# carried a template saying `unless-stopped`. It could not fire once, ever,
# and the spec that covered it was green against a hand-built
# driver/template pair no release could produce.
#
# It is the third member of the family ADR-00000006 records, and the only one
# that fails silently: base#1086 (`_migrate_legacy_setup_conf`, same place,
# same reason) and the `.env` -> `.env.local` rename, which was never put
# there because the asymmetry was understood for that one first.
#
# ── Where a migration goes instead ──────────────────────────────────────────
#
# `init.sh`, which every released `upgrade.sh` re-executes from the FRESHLY
# PULLED subtree as its Step 3 resync -- the one point in an already-shipped
# upgrade flow that runs current code. Either as a heal that infers its own
# applicability from the shape of the tree (`lib/*_migrate.sh`), or, when the
# question is "did this repo arrive from before release X", as an entry in
# `lib/version_migrate.sh`'s declared set.
#
# ── Why this is a spec and not a grep ───────────────────────────────────────
#
# base#1115 / base#1117 / base#1175: three greps claiming to pin `xhost`
# behaviour passed against a `run.sh` that had no `xhost` in it at all. A
# rule that cannot be shown to go red is not a rule. So:
#
#   - the POPULATION is derived. Every top-level function definition in the
#     file is walked; not one name is written down here, so a migration
#     spelled some way nobody predicted is still a function definition.
#   - NON-VACUITY is asserted, not hoped for: the scan must find the file,
#     and must find a believable number of functions in it. A moved or
#     renamed `upgrade.sh` fails this file rather than emptying it.
#   - the rule is PROVED to fire. One arm injects a migration into a scratch
#     copy of the real file and requires the same scanner to report it, so a
#     scanner that has gone blind cannot pass the arms above by finding
#     nothing anywhere.

bats_require_minimum_version 1.5.0

UPGRADE="/source/dist/script/base/upgrade.sh"

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  TEMP_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# _defined_functions <file>
#   Every top-level function definition in <file>, one bare name per line.
#
#   Top-level means column zero: a nested definition is part of its
#   enclosing function and is reached only through it, and `upgrade.sh`
#   defines none. Both spellings bash accepts are read -- `name() {` and
#   `function name {` -- so declaring a migration the other way is not an
#   escape.
_defined_functions() {
  sed -n \
    -e 's/^\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*()[[:space:]]*{.*$/\1/p' \
    -e 's/^function[[:space:]]\+\([A-Za-z_][A-Za-z0-9_]*\).*$/\1/p' \
    "${1:?}"
}

# _migration_shaped <file>
#   The subset of <file>'s top-level functions whose name says migration.
#   `_migrate_*` is the convention every one in this tree has used; `migrate`
#   anywhere in the name is matched so a `_vmigrate_` or `_do_migrate_foo`
#   is not a loophole.
_migration_shaped() {
  _defined_functions "${1:?}" | grep -i 'migrat' || true
}

# why: The rule itself, read off the shipped file. A migration here cannot
# reach the population it exists for, and returns 0 while not reaching it --
# so the file has to carry none at all, and the check has to be against the
# real file rather than a fixture standing in for it
@test "dist/script/base/upgrade.sh defines no migration (base#1110)" {
  assert [ -f "${UPGRADE}" ]
  run _migration_shaped "${UPGRADE}"
  assert_success
  assert_output ""
}

# why: The call side is the other half. A migration defined in a lib and
# merely CALLED from upgrade.sh is just as unreachable, because what makes it
# unreachable is where the call runs and not where the body is written
@test "dist/script/base/upgrade.sh calls no migration (base#1110)" {
  run grep -nE '^[[:space:]]+_[A-Za-z0-9_]*migrat[A-Za-z0-9_]*[[:space:]]' \
    "${UPGRADE}"
  assert_failure
  assert_output ""
}

# why: Both arms above pass by finding nothing, which is exactly how a
# scanner that has gone blind reports a clean tree. This pins that the
# scanner can see the file at all, and sees a believable amount of it, so a
# renamed or relocated upgrade.sh fails rather than emptying the rule
@test "the migration scan is not vacuous: upgrade.sh is found and parsed (base#1110)" {
  assert [ -f "${UPGRADE}" ]
  local _count
  _count="$(_defined_functions "${UPGRADE}" | wc -l)"
  # The file defined 24 top-level functions when this landed. The floor is
  # deliberately far below that: it is here to catch a scanner reading
  # nothing, not to pin a count that a refactor would have to come and edit.
  assert [ "${_count}" -gt 10 ]
  run _defined_functions "${UPGRADE}"
  assert_success
  assert_output --partial "_upgrade"
}

# why: Driving the rule red by hand, as a test, so it can never pass by never
# firing. The injected function is added to a copy of the REAL file through
# the REAL scanner, so this arm fails the moment the detector stops detecting
# -- which is the failure the two arms above cannot tell from success
@test "the migration scan reports a migration injected into upgrade.sh (base#1110)" {
  local _scratch="${TEMP_DIR}/upgrade.sh"
  cp "${UPGRADE}" "${_scratch}"
  cat >> "${_scratch}" <<'EOS'

_migrate_something_from_the_vendored_tree() {
  local _tpl="${1}/${TEMPLATE_REL}/dist/setup.toml"
  [[ -f "${_tpl}" ]] || return 0
}
EOS
  run _migration_shaped "${_scratch}"
  assert_success
  assert_output "_migrate_something_from_the_vendored_tree"
}

# why: The `function name {` spelling is the one an author reaching for a way
# around a name rule would find first, and a scanner that only read
# `name() {` would report the file clean with a migration sitting in it
@test "the migration scan reads the 'function name' spelling too (base#1110)" {
  local _scratch="${TEMP_DIR}/upgrade.sh"
  cp "${UPGRADE}" "${_scratch}"
  printf '\nfunction _migrate_declared_the_other_way {\n  :\n}\n' \
    >> "${_scratch}"
  run _migration_shaped "${_scratch}"
  assert_success
  assert_output "_migrate_declared_the_other_way"
}
