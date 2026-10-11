#!/usr/bin/env bats
#
# version_migrate_spec.bats - the version interval an upgrade crosses, and
# the migrations selected from it.
#
# The integration arm in test/bats/integration/prev_release_upgrade_spec.bats
# drives the real thing: a real released upgrade.sh, a real subtree pull, a
# migration declared in the release being installed. What it cannot produce
# is the set of histories that are NOT a clean upgrade -- a bootstrap, a
# standalone resync, a shallow clone, a vendored tree with no version in it.
# Those all end with no migration running, and the whole point is that they
# are not the same silence: one of them means work was skipped and nobody
# else will ever say so.
#
# So this spec crafts each history with plain git and reads the runner's own
# log body back. The merge shape is built by hand rather than by
# `git subtree pull`: what the runner reads is "HEAD has two parents and the
# first one carried a version", and building that directly is what lets the
# cases where it is ALMOST true exist at all.
#
# why: The version interval an upgrade crossed is what selects a
# version-bound migration, and every way of failing to read that interval
# ends in the same observable place -- no migration ran. The integration arm
# can only produce the clean upgrade; these craft the histories that are not
# one (bootstrap, standalone resync, shallow clone, a vendored tree carrying
# no version) and pin that each reports itself differently, because only some
# of them mean a consumer was silently owed work. Selection order,
# boundaries, an unusable declaration and a failing migration are here for
# the same reason: a real upgrade shows one interval, not the arithmetic.

bats_require_minimum_version 1.5.0

LIB="/source/dist/script/docker/lib"

setup() {
  # JSON, not text: what separates "there was no interval" from "there was
  # one and it could not be read" is the log BODY, and the text sink prints
  # only the display string.
  export LOG_FORMAT=json
  load "${BATS_TEST_DIRNAME}/test_helper"
  TEMP_DIR="$(mktemp -d)"
  REPO="${TEMP_DIR}/consumer"
  PREFIX=".base"
  PROBE="migration-probe"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# ── Driving the lib ─────────────────────────────────────────────────────────

# _src
#   Source text that brings the lib up in a fresh shell, so every case
#   exercises the real function bodies. _lib.sh supplies _log_*.
_src() {
  printf 'source %s/_lib.sh; source %s/version_migrate.sh' "${LIB}" "${LIB}"
}

# _declarations <version> <name> [<version> <name>...]
#   Write a file declaring one probe migration per pair and echo its path.
#   Each apply APPENDS its own name to the probe, so order, count and
#   identity are all readable off one artifact.
#
#   The set is CLEARED first, and so is _declare_raw's. The shipped set is no
#   longer empty and the intervals these arms use are ones a real entry sits
#   in, so an exact `assert_output` here would be asserting against base's
#   own release history and would have to be rewritten every time a migration
#   is declared. The real set has its own arms at the end of this file --
#   those are the ones that must break when it changes.
_declarations() {
  local _file="${TEMP_DIR}/declarations.sh"
  printf '_VERSION_MIGRATIONS=()\n' > "${_file}"
  while (( $# > 0 )); do
    cat >> "${_file}" <<EOF
_VERSION_MIGRATIONS+=("${1} ${2}")
_vmigrate_${2}_apply() {
  printf '%s\n' "${2}" >> "\${1}/${PROBE}"
}
EOF
    shift 2
  done
  printf '%s' "${_file}"
}

# _declare_raw <line>...
#   As _declarations, for entries that are deliberately malformed: the line
#   is appended to _VERSION_MIGRATIONS verbatim and no apply is written.
_declare_raw() {
  local _file="${TEMP_DIR}/declarations.sh"
  printf '_VERSION_MIGRATIONS=()\n' > "${_file}"
  local _entry
  for _entry in "$@"; do
    printf '_VERSION_MIGRATIONS+=("%s")\n' "${_entry}" >> "${_file}"
  done
  printf '%s' "${_file}"
}

# _probe
#   What the probe recorded, one applied migration per line.
_probe() {
  [[ -f "${REPO}/${PROBE}" ]] || return 0
  cat "${REPO}/${PROBE}"
}

# ── Crafting a consumer's history ───────────────────────────────────────────

_git_repo() {
  git init -q -b main "${1}"
  git -C "${1}" config user.email t@t
  git -C "${1}" config user.name t
}

# _side_branch
#   A second parent for the merge below. Its content is irrelevant -- the
#   runner reads the FIRST parent -- it only has to exist.
_side_branch() {
  git -C "${REPO}" checkout -q -b incoming
  printf 'incoming\n' > "${REPO}/incoming-marker"
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -q -m "incoming"
  git -C "${REPO}" checkout -q main
}

# _merge_landing <to>
#   Close the fixture with the two-parent merge a subtree pull lands: the
#   first parent is main's tip (whatever the caller gave it), and the merge's
#   own tree carries <to> as the installed version.
_merge_landing() {
  local _to="${1}"
  _side_branch
  git -C "${REPO}" merge -q --no-ff --no-commit -s ours incoming
  mkdir -p "${REPO}/${PREFIX}"
  printf '%s\n' "${_to}" > "${REPO}/${PREFIX}/.version"
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -q -m "chore: upgrade ${PREFIX} subtree to ${_to}"
}

# _crossing <from> <to>
#   The clean upgrade: a repo sitting on <from> that has just pulled <to>.
_crossing() {
  _git_repo "${REPO}"
  mkdir -p "${REPO}/${PREFIX}"
  printf '%s\n' "${1}" > "${REPO}/${PREFIX}/.version"
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -q -m "bootstrap at ${1}"
  _merge_landing "${2}"
}

# _bootstrapping <to>
#   A first subtree add: the merge's first parent predates the subtree, so
#   there is no earlier version and nothing was crossed.
_bootstrapping() {
  _git_repo "${REPO}"
  printf 'repo\n' > "${REPO}/README"
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -q -m "chore: initial commit"
  _merge_landing "${1}"
}

# _crossing_without_version <to>
#   The near miss: the first parent DOES carry the subtree, and there is no
#   version inside it to read. Not a bootstrap -- an unidentifiable tree.
_crossing_without_version() {
  _git_repo "${REPO}"
  mkdir -p "${REPO}/${PREFIX}"
  printf 'vendored\n' > "${REPO}/${PREFIX}/marker"
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -q -m "vendored without a version"
  _merge_landing "${1}"
}

# ── Selection ───────────────────────────────────────────────────────────────

# why: The interval is half-open and both ends are a decision. The
# from-version's migrations ran when the consumer arrived there, so
# re-running them is the double-apply this shape exists to prevent; the
# to-version's are the release being installed right now, so dropping them
# is the whole job not done. A closed or open-at-the-wrong-end interval
# passes any arm that only checks the middle
@test "interval_migrations excludes the version arrived from and includes the version arrived at (base#1097)" {
  local _decl
  _decl="$(_declarations v0.41.0 at_from v0.42.0 inside v0.43.0 at_to v0.44.0 beyond)"
  run bash -c "$(_src); source '${_decl}'; interval_migrations v0.41.0 v0.43.0"
  assert_success
  assert_output "v0.42.0 inside
v0.43.0 at_to"
}

# why: Declaration order is where an author appends, and version order is
# what a migration set means -- an entry for an older release must run
# before one for a newer release even when it was written later. Those agree
# until the first out-of-order append, which is exactly when nobody is
# looking
@test "interval_migrations orders by version ascending, not by declaration order (base#1097)" {
  local _decl
  _decl="$(_declarations v0.43.0 third v0.41.5 first v0.42.0 second)"
  run bash -c "$(_src); source '${_decl}'; interval_migrations v0.41.0 v0.43.0"
  assert_success
  assert_output "v0.41.5 first
v0.42.0 second
v0.43.0 third"
}

# why: Two migrations landing in one release have no version to order them
# by, so something else has to be the answer and it has to be stable.
# Declaration order is the only thing an author controls
@test "interval_migrations breaks a same-version tie by declaration order (base#1097)" {
  local _decl
  _decl="$(_declarations v0.42.0 written_first v0.42.0 written_second)"
  run bash -c "$(_src); source '${_decl}'; interval_migrations v0.41.0 v0.43.0"
  assert_success
  assert_output "v0.42.0 written_first
v0.42.0 written_second"
}

# why: A release candidate of a release carries that release's migrations.
# Ordering the rc below the release it belongs to would run them on the rc
# and then again on the release -- harmless only because they are idempotent,
# and wrong in the log both times
@test "interval_migrations treats a release candidate as the release it is a candidate for (base#1097)" {
  local _decl
  _decl="$(_declarations v0.43.0 landed_in_043)"
  run bash -c "$(_src); source '${_decl}'; interval_migrations v0.42.0 v0.43.0-rc1"
  assert_success
  assert_output "v0.43.0 landed_in_043"

  run bash -c "$(_src); source '${_decl}'; interval_migrations v0.43.0-rc1 v0.43.0"
  assert_success
  assert_output ""
}

# why: An entry that can never be selected is base's own bug, and the only
# symptom is a migration that silently never runs. Reporting it on every
# upgrade rather than on the ones that would have selected it is the
# difference between finding it here and finding it at a consumer
@test "interval_migrations reports a declaration it cannot select and keeps the rest (base#1097)" {
  local _decl
  _decl="$(_declarations v0.42.0 usable)"
  printf '_VERSION_MIGRATIONS+=("not-a-version broken")\n' >> "${_decl}"
  printf '_VERSION_MIGRATIONS+=("v0.42.0")\n' >> "${_decl}"
  run bash -c "$(_src); source '${_decl}'; interval_migrations v0.41.0 v0.43.0"
  assert_success
  assert_output --partial '"body":"interval_migration_declined"'
  assert_output --partial 'not-a-version broken'
  assert_output --partial '"entry":"v0.42.0"'
  assert_output --partial "v0.42.0 usable"
}

# why: A declared name with no apply behind it is the same silence by a
# different route -- the selection is correct and nothing happens. It is the
# shape a rename inside the lib produces
@test "interval_migrations reports a declaration whose apply function is missing (base#1097)" {
  local _decl
  _decl="$(_declare_raw "v0.42.0 vanished")"
  run bash -c "$(_src); source '${_decl}'; interval_migrations v0.41.0 v0.43.0"
  assert_success
  assert_output --partial '"body":"interval_migration_declined"'
  assert_output --partial '_vmigrate_vanished_apply'
  refute_output --partial 'v0.42.0 vanished
'
}

# ── The interval, read off a real history ───────────────────────────────────

# why: The clean upgrade through the resolver rather than through a released
# driver. It is what makes every negative arm below mean something: without
# it they are all satisfied by a runner that never runs anything
@test "run_interval_migrations applies what the crossed interval covers and reports the interval (base#1097)" {
  _crossing v0.41.0 v0.43.0
  local _decl
  _decl="$(_declarations v0.40.0 before v0.42.0 inside v0.44.0 after)"
  run bash -c "$(_src); source '${_decl}'; run_interval_migrations '${REPO}' '${PREFIX}' v0.43.0"
  assert_success
  assert_output --partial '"body":"interval_migration_window"'
  assert_output --partial '"from":"v0.41.0"'
  assert_output --partial '"to":"v0.43.0"'
  assert_output --partial '"body":"interval_migration_applied"'
  run _probe
  assert_output "inside"
}

# why: There is no ledger of what has run, deliberately, so the second entry
# into the same interval applies the same migrations again. That IS the
# contract -- idempotence is the migration's job -- and a reader who assumes
# otherwise writes a migration that doubles. The arm exists to make the
# absence of the ledger a stated property rather than an oversight
@test "run_interval_migrations keeps no record, so a second run over the same interval applies again (base#1097)" {
  _crossing v0.41.0 v0.43.0
  local _decl
  _decl="$(_declarations v0.42.0 inside)"
  run bash -c "$(_src); source '${_decl}'; run_interval_migrations '${REPO}' '${PREFIX}' v0.43.0; run_interval_migrations '${REPO}' '${PREFIX}' v0.43.0"
  assert_success
  run _probe
  assert_output "inside
inside"
}

# why: A failing migration inside an ordered set has two wrong answers. Let
# it abort and the resync dies at upgrade Step 3, where no released driver up
# to v0.42.0 arms a rollback -- the pull stays committed and the repo is left
# half-upgraded. Carry on and the next migration runs over a tree the failed
# one left half-written
@test "run_interval_migrations reports a failing migration, skips the rest, and does not fail the resync (base#1097)" {
  _crossing v0.41.0 v0.43.0
  local _decl
  _decl="$(_declarations v0.41.5 good v0.43.0 later)"
  cat >> "${_decl}" <<EOF
_VERSION_MIGRATIONS+=("v0.42.0 doomed")
_vmigrate_doomed_apply() {
  return 3
}
EOF
  run bash -c "$(_src); source '${_decl}'; run_interval_migrations '${REPO}' '${PREFIX}' v0.43.0"
  assert_success
  assert_output --partial '"reason":"apply-failed"'
  assert_output --partial '"migration":"doomed"'
  assert_output --partial '"code":"3"'
  run _probe
  assert_output "good"
}

# ── Naming the interval when the history no longer can ──────────────────────
#
# Every one of the warnings above leaves a consumer owed work, and until the
# override below existed none of them could be acted on. The reason is Step 4:
# every released upgrade.sh COMMITS after the resync, so by the time the user
# reads a Step-3 warning HEAD is no longer the subtree-pull merge and the
# interval it was derived from is gone. "Fix it and re-run the resync" was
# therefore advice that could not be followed on any release.

# why: The retry path, and it is the one codex reproduced as missing. A
# migration that fails, or an interval that could not be read, leaves work
# owed -- and the upgrade's own Step 4 commit destroys the merge the interval
# came from before the user has read the warning. Without a way to name the
# pair by hand there is no second chance on any release, and the warning is
# telling them to do something impossible
@test "run_interval_migrations takes the from-version from BASE_MIGRATION_FROM when the history no longer has it (base#1097)" {
  _git_repo "${REPO}"
  mkdir -p "${REPO}/${PREFIX}"
  printf 'v0.43.0\n' > "${REPO}/${PREFIX}/.version"
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -q -m "a plain commit, the interval long gone"
  local _decl
  _decl="$(_declarations v0.42.0 inside v0.44.0 outside)"
  run bash -c "$(_src); source '${_decl}'; BASE_MIGRATION_FROM=v0.41.0 run_interval_migrations '${REPO}' '${PREFIX}' v0.43.0"
  assert_success
  assert_output --partial '"from":"v0.41.0"'
  assert_output --partial '"from_source":"override"'
  run _probe
  assert_output "inside"
}

# why: An override that is wrong must not quietly become something else. A
# silent fall back to the history would hand the operator a different
# interval from the one they named, which is worse than refusing: they would
# believe the owed migrations had run
@test "run_interval_migrations refuses an unorderable BASE_MIGRATION_FROM rather than deriving one instead (base#1097)" {
  _crossing v0.41.0 v0.43.0
  local _decl
  _decl="$(_declarations v0.42.0 inside)"
  run bash -c "$(_src); source '${_decl}'; BASE_MIGRATION_FROM=main run_interval_migrations '${REPO}' '${PREFIX}' v0.43.0"
  assert_success
  assert_output --partial '"body":"interval_migration_unreadable"'
  assert_output --partial '"reason":"from-override-not-semver"'
  refute_output --partial '"from":"v0.41.0"'
  run _probe
  assert_output ""
}

# why: codex's reproduction, end to end: a migration fails, the upgrade
# commits anyway, the cause is fixed, and the entries the failure skipped are
# still owed. This is the sequence the failure warning has to be able to
# promise a way out of
@test "run_interval_migrations recovers the entries a failed migration skipped after the upgrade has committed (base#1097)" {
  _crossing v0.41.0 v0.43.0
  local _decl
  _decl="$(_declarations v0.43.0 later)"
  cat >> "${_decl}" <<EOF
_VERSION_MIGRATIONS+=("v0.42.0 doomed")
_vmigrate_doomed_apply() {
  [[ -f "\${1}/cause-fixed" ]] || return 3
  printf '%s\n' doomed >> "\${1}/${PROBE}"
}
EOF
  run bash -c "$(_src); source '${_decl}'; run_interval_migrations '${REPO}' '${PREFIX}' v0.43.0"
  assert_success
  assert_output --partial '"reason":"apply-failed"'
  # The warning has to name the way out, or it is the advice codex found
  # could not be followed.
  assert_output --partial 'BASE_MIGRATION_FROM'
  run _probe
  assert_output ""

  # What the released driver does next, in every release: Step 4 commits.
  printf 'resync\n' > "${REPO}/resync"
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -q -m "chore: upgrade to v0.43.0"

  printf 'fixed\n' > "${REPO}/cause-fixed"
  run bash -c "$(_src); source '${_decl}'; BASE_MIGRATION_FROM=v0.41.0 run_interval_migrations '${REPO}' '${PREFIX}' v0.43.0"
  assert_success
  run _probe
  assert_output "doomed
later"
}

# ── Where there is no interval, and where there is one nobody can read ──────

# why: The standalone resync. `just base init` is a repair command a user
# runs whenever they like, and on a committed tree HEAD is no merge at all --
# so there is no pair to select on and nothing is owed. A runner that read
# the installed version alone would re-apply every migration ever declared
# on every invocation
@test "run_interval_migrations runs nothing when HEAD is not a merge (base#1097)" {
  _git_repo "${REPO}"
  mkdir -p "${REPO}/${PREFIX}"
  printf 'v0.43.0\n' > "${REPO}/${PREFIX}/.version"
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -q -m "a plain commit"
  local _decl
  _decl="$(_declarations v0.42.0 inside)"
  run bash -c "$(_src); source '${_decl}'; run_interval_migrations '${REPO}' '${PREFIX}' v0.43.0"
  assert_success
  assert_output --partial '"body":"interval_migration_window"'
  assert_output --partial '"reason":"not-a-merge"'
  refute_output --partial '"body":"interval_migration_unreadable"'
  run _probe
  assert_output ""
}

# why: The documented bootstrap. A repo is set up by hand before `git` is
# even in the picture, and init.sh is the first thing to run in it -- the
# path that must not be a warning, because nothing is wrong
@test "run_interval_migrations runs nothing outside a git repo (base#1097)" {
  mkdir -p "${REPO}/${PREFIX}"
  printf 'v0.43.0\n' > "${REPO}/${PREFIX}/.version"
  local _decl
  _decl="$(_declarations v0.42.0 inside)"
  run bash -c "$(_src); source '${_decl}'; run_interval_migrations '${REPO}' '${PREFIX}' v0.43.0"
  assert_success
  assert_output --partial '"reason":"not-a-git-repo"'
  refute_output --partial '"body":"interval_migration_unreadable"'
  run _probe
  assert_output ""
}

# why: `git subtree add --squash` also lands a two-parent merge, so "HEAD is
# a merge" is not the question -- whether the first parent had the subtree
# is. A first bootstrap has crossed nothing, and the arm below is the same
# git shape with the opposite answer
@test "run_interval_migrations runs nothing when the first parent predates the subtree (base#1097)" {
  _bootstrapping v0.43.0
  local _decl
  _decl="$(_declarations v0.42.0 inside)"
  run bash -c "$(_src); source '${_decl}'; run_interval_migrations '${REPO}' '${PREFIX}' v0.43.0"
  assert_success
  assert_output --partial '"body":"interval_migration_window"'
  assert_output --partial '"reason":"no-prior-subtree"'
  refute_output --partial '"body":"interval_migration_unreadable"'
  run _probe
  assert_output ""
}

# why: The pair this mechanism's worst failure is made of. A vendored subtree
# with no version in it is NOT a bootstrap: a version interval was crossed,
# its migrations were skipped, and the repo looks exactly like the arm above
# unless the two report differently. Guessing is not available either --
# there is no floor version to run everything from without knowing what the
# repo is
@test "run_interval_migrations warns, rather than reporting no interval, when the version it came from is missing (base#1097)" {
  _crossing_without_version v0.43.0
  local _decl
  _decl="$(_declarations v0.42.0 inside)"
  run bash -c "$(_src); source '${_decl}'; run_interval_migrations '${REPO}' '${PREFIX}' v0.43.0"
  assert_success
  assert_output --partial '"body":"interval_migration_unreadable"'
  assert_output --partial '"reason":"version-missing"'
  refute_output --partial '"body":"interval_migration_window"'
  run _probe
  assert_output ""
}

# why: The same class through the other door -- a version file that is
# present and says something nothing can order. A hand-edited `.version`, a
# merge conflict left in it, a branch name
@test "run_interval_migrations warns when the version it came from cannot be ordered (base#1097)" {
  _crossing 'not-a-version' v0.43.0
  local _decl
  _decl="$(_declarations v0.42.0 inside)"
  run bash -c "$(_src); source '${_decl}'; run_interval_migrations '${REPO}' '${PREFIX}' v0.43.0"
  assert_success
  assert_output --partial '"reason":"version-not-semver"'
  run _probe
  assert_output ""
}

# why: A shallow clone is the one case git itself erases: it GRAFTS the
# parents away, so a subtree-pull merge on the shallow boundary reads back as
# a root commit and is byte-identical to the standalone-resync arm above.
# Reading the parent count alone therefore reports "nothing was crossed"
# about a repo that crossed a release -- the one answer that looks healthy
# and is wrong. It is also CI's default checkout
@test "run_interval_migrations warns when a shallow history has grafted the first parent away (base#1097)" {
  _crossing v0.41.0 v0.43.0
  local _shallow="${TEMP_DIR}/shallow"
  git clone -q --depth 1 "file://${REPO}" "${_shallow}"
  # The premise: git reports no parents at all, so nothing downstream of the
  # parent count can tell this from a plain commit.
  run git -C "${_shallow}" rev-list --parents -n 1 HEAD
  assert_success
  [ "$(printf '%s' "${output}" | wc -w)" -eq 1 ]

  local _decl
  _decl="$(_declarations v0.42.0 inside)"
  run bash -c "$(_src); source '${_decl}'; run_interval_migrations '${_shallow}' '${PREFIX}' v0.43.0"
  assert_success
  assert_output --partial '"body":"interval_migration_unreadable"'
  assert_output --partial '"reason":"shallow-history"'
  refute_output --partial '"reason":"not-a-merge"'
  assert [ ! -f "${_shallow}/${PROBE}" ]
}

# why: The other half of the pair can be unreadable too, and it is the half
# the caller supplies. An empty or junk installed version would otherwise
# compare as 0.0.0 and select nothing at all -- silently, which is the shape
# every arm here exists to refuse
@test "run_interval_migrations warns when the installed version cannot be ordered (base#1097)" {
  _crossing v0.41.0 v0.43.0
  local _decl
  _decl="$(_declarations v0.42.0 inside)"
  run bash -c "$(_src); source '${_decl}'; run_interval_migrations '${REPO}' '${PREFIX}' ''"
  assert_success
  assert_output --partial '"body":"interval_migration_unreadable"'
  assert_output --partial '"reason":"to-not-semver"'
  run _probe
  assert_output ""
}

# why: A re-established subtree or a hand-pinned downgrade moves the version
# backwards, which makes the interval empty rather than wrong -- but silence
# there would mean the one case where a migration genuinely cannot help is
# indistinguishable from a bug in the selection
@test "run_interval_migrations warns when the version moved backwards (base#1097)" {
  _crossing v0.43.0 v0.41.0
  local _decl
  _decl="$(_declarations v0.42.0 inside)"
  run bash -c "$(_src); source '${_decl}'; run_interval_migrations '${REPO}' '${PREFIX}' v0.41.0"
  assert_success
  assert_output --partial '"body":"interval_migration_unreadable"'
  assert_output --partial '"reason":"backwards"'
  run _probe
  assert_output ""
}

# ── The SHIPPED declared set ────────────────────────────────────────────────
#
# Everything above clears `_VERSION_MIGRATIONS` and declares probes, because
# it is about the arithmetic. These arms are about the set this release
# actually ships: they read it as it stands and must break when it changes,
# which is the half a probe can never cover.
#
# The population is DERIVED -- every entry of the shipped array is walked, no
# entry is named -- so a migration added without an apply function, or with
# an unorderable version, is caught by the fact of being declared rather than
# by anyone remembering to extend a list.

# why: Every shipped entry must be selectable at all. The runner reports an
# unusable declaration only on the upgrades that would have selected it,
# which is how one stays unreported -- so the whole set is validated here,
# walked rather than listed, and a new entry is covered the moment it exists
@test "every shipped _VERSION_MIGRATIONS entry is well formed and has its apply function" {
  run bash -c "$(_src)
    (( \${#_VERSION_MIGRATIONS[@]} > 0 )) \
      || { echo 'VACUOUS: the shipped set is empty, so this arm checked nothing'; exit 1; }
    _rc=0
    for _e in \"\${_VERSION_MIGRATIONS[@]}\"; do
      _v=\"\${_e%% *}\"; _n=\"\${_e#* }\"
      [[ -n \"\${_n}\" && \"\${_n}\" != \"\${_e}\" ]] \
        || { echo \"BAD ENTRY (not '<version> <name>'): \${_e}\"; _rc=1; continue; }
      _vm_is_semver \"\${_v}\" \
        || { echo \"BAD VERSION (not orderable): \${_e}\"; _rc=1; }
      declare -F \"_vmigrate_\${_n}_apply\" >/dev/null 2>&1 \
        || { echo \"NO APPLY: _vmigrate_\${_n}_apply is not defined for \${_e}\"; _rc=1; }
    done
    exit \"\${_rc}\""
  assert_success
  refute_output --partial "VACUOUS"
}

# why: base#1110's whole defect was a migration no consumer could reach, so
# the one thing its new home has to prove is that a repo arriving from before
# v0.42.0 selects it -- read off the real shipped set, through the real
# interval resolver, not a probe standing in for it
@test "the shipped set selects lifecycle_restart_default for a repo arriving from before v0.42.0 (base#1110)" {
  run bash -c "$(_src); interval_migrations v0.41.0 v0.43.0"
  assert_success
  assert_output --partial "v0.42.0 lifecycle_restart_default"
}

# why: The fail-safe is the other half of the predicate and is as easy to
# lose as the firing half. Past the rescope a `no` cannot be told from a
# choice, so a repo whose interval STARTS at v0.42.0 must select nothing --
# the arm that would go quiet if the version were ever re-pointed
@test "the shipped set does NOT select lifecycle_restart_default for a repo already past v0.42.0 (base#1110)" {
  run bash -c "$(_src); interval_migrations v0.42.0 v0.43.0"
  assert_success
  refute_output --partial "lifecycle_restart_default"
}

# ── _vmigrate_lifecycle_restart_default_apply ───────────────────────────────
#
# The rewrite itself. `restart = no` was the pre-v0.42.0 template's literal
# and `init.sh --gen-conf` copies the whole template, so a repo bootstrapped
# before the rescope carries it whether or not anyone chose it; left alone it
# denies a field service its auto-start after a host reboot.

# _restart_repo <dir> <restart_value_line>...
#   A consumer repo carrying its own setup.toml at the path the resync has
#   already put it at by the time the interval runner runs. No vendored
#   template is seeded, deliberately: reading one is what base#1110 was.
_restart_repo() {
  local _dir="$1"; shift
  mkdir -p "${_dir}"
  printf '%s\n' "$@" > "${_dir}/setup.toml"
}

# why: The firing case, and the one no spec could reach before: the repo's
# own stale value is rewritten with no vendored template read at all
@test "_vmigrate_lifecycle_restart_default_apply rewrites the stale copied default (base#1110)" {
  _restart_repo "${TEMP_DIR}/stale" '[lifecycle]' 'restart = "no"' 'init = true'
  run bash -c "$(_src); _vmigrate_lifecycle_restart_default_apply '${TEMP_DIR}/stale'"
  assert_success
  assert_output --partial '"body":"lifecycle_restart_default_migrated"'
  run cat "${TEMP_DIR}/stale/setup.toml"
  assert_output --partial 'restart = "unless-stopped"'
  # Every other line of the file survives the single-key edit.
  assert_output --partial 'init = true'
}

# why: The runner keeps no ledger and re-selects the same interval on a
# resync re-entered before the pull commits, so a second run that wrote again
# would be a second log line over an unchanged value -- idempotence is the
# migration's own job
@test "_vmigrate_lifecycle_restart_default_apply is silent and inert on a second run (base#1110)" {
  _restart_repo "${TEMP_DIR}/twice" '[lifecycle]' 'restart = "no"'
  run bash -c "$(_src)
    _vmigrate_lifecycle_restart_default_apply '${TEMP_DIR}/twice' >/dev/null 2>&1
    _vmigrate_lifecycle_restart_default_apply '${TEMP_DIR}/twice'"
  assert_success
  refute_output --partial "lifecycle_restart_default_migrated"
  run grep -c 'restart' "${TEMP_DIR}/twice/setup.toml"
  assert_output "1"
}

# why: A repo that chose something else never had the stale default, and the
# migration touching it would be rewriting a policy somebody picked
@test "_vmigrate_lifecycle_restart_default_apply leaves a chosen policy alone (base#1110)" {
  _restart_repo "${TEMP_DIR}/chosen" '[lifecycle]' 'restart = "on-failure:5"'
  run bash -c "$(_src); _vmigrate_lifecycle_restart_default_apply '${TEMP_DIR}/chosen'"
  assert_success
  refute_output --partial "lifecycle_restart_default_migrated"
  run cat "${TEMP_DIR}/chosen/setup.toml"
  assert_output --partial 'restart = "on-failure:5"'
}

# why: `restart` is a legal key of a `[stage:*]` section too, and a reader
# that matched the key without its section would rewrite a per-stage value
# the migration has nothing to say about
@test "_vmigrate_lifecycle_restart_default_apply ignores a restart key outside [lifecycle] (base#1110)" {
  _restart_repo "${TEMP_DIR}/othersection" '["stage:runtime"]' 'restart = "no"'
  run bash -c "$(_src); _vmigrate_lifecycle_restart_default_apply '${TEMP_DIR}/othersection'"
  assert_success
  refute_output --partial "lifecycle_restart_default_migrated"
  run cat "${TEMP_DIR}/othersection/setup.toml"
  assert_output --partial 'restart = "no"'
}

# why: TOML quotes a string value, so a reader comparing the raw text after
# the `=` compares the SPELLING and not the value -- `"no"` never equals `no`,
# which is a mistake the function this replaced had to carry its own unquoter
# to avoid. The read goes through conf.sh's tokenizer instead, so a basic
# string and a literal string are one value. The bare INI spelling is
# deliberately NOT in this list: it is not a TOML value, and by the time the
# interval runner runs, the resync's INI-to-TOML conversion has already
# quoted the file
#   Written out one spelling per call rather than looped over a variable: the
#   TOML fixture body gate reads these bodies out of this file's own text, so
#   a body assembled from `${_s}` is one it cannot parse and has to be
#   excused from -- and the point of the gate is that a fixture the bridge
#   refuses leaves an EMPTY handle, which is exactly how an arm like this
#   would pass without its fixture ever being read.
@test "_vmigrate_lifecycle_restart_default_apply reads both string spellings of the same value (base#1110)" {
  _restart_repo "${TEMP_DIR}/basic" '[lifecycle]' 'restart = "no"'
  run bash -c "$(_src); _vmigrate_lifecycle_restart_default_apply '${TEMP_DIR}/basic'"
  assert_success
  assert_output --partial '"body":"lifecycle_restart_default_migrated"'
  run cat "${TEMP_DIR}/basic/setup.toml"
  assert_output --partial 'restart = "unless-stopped"'

  _restart_repo "${TEMP_DIR}/literal" '[lifecycle]' "restart = 'no'"
  run bash -c "$(_src); _vmigrate_lifecycle_restart_default_apply '${TEMP_DIR}/literal'"
  assert_success
  assert_output --partial '"body":"lifecycle_restart_default_migrated"'
  run cat "${TEMP_DIR}/literal/setup.toml"
  assert_output --partial 'restart = "unless-stopped"'
}

# why: The resync runs on repos that are not upgrades at all, and a migration
# that assumed its file existed would abort the resync of a repo that simply
# has no configuration yet
@test "_vmigrate_lifecycle_restart_default_apply is a no-op with no setup.toml (base#1110)" {
  mkdir -p "${TEMP_DIR}/noconf"
  run bash -c "$(_src); _vmigrate_lifecycle_restart_default_apply '${TEMP_DIR}/noconf'"
  assert_success
  assert_output ""
  refute [ -e "${TEMP_DIR}/noconf/setup.toml" ]
}
