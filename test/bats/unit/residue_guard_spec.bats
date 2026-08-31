#!/usr/bin/env bats
#
# The live-tree residue guard in script/test/test.sh: the EXECUTED answer to
# "did a spec write into the checkout it does not own".
#
# Why an executed check and not a scan. The static scan this file replaces
# enumerated the commands a spec might write with -- rm, mv, cp, tee, a
# redirection -- and every review of it found another spelling it claimed
# and could not see (a third operand of `mv`, `dd`'s `of=`, `rsync` named
# nowhere, `install` reading OUT of the tree flagged as a write), plus a
# trailing comment that defeated its end anchor. That is a roster: it is
# never finished, each round widens it, and the rounds in between are spent
# believing it.
#
# The property has an executed form with no roster at all. Snapshot the
# checkout, run the suite, snapshot again: anything that differs is a write,
# whatever command made it, through an alias, a subshell, a driver or a
# tool this repo has never heard of. It also cannot false-positive on the
# suite's own SETUP, which is what made the scan's cp / ln rule delicate --
# reading the live tree leaves nothing behind.
#
# The cost, which is the whole design of the two-snapshot form. A single
# "is the tree clean" check would need a clean tree to start from and would
# red every developer with work in flight. Comparing two snapshots taken
# either side of the run makes an in-flight edit appear in BOTH and cancel,
# so the guard speaks only about what changed DURING the run. The record is
# status code + content hash + path, not the status line alone, so a spec
# writing a file the developer had already modified still moves the record.
#
# What the executed check still does not cover, said out loud: a spec that
# writes into the checkout and then removes its own traces before the run
# ends. The race window it opens is real and invisible here. The scan could
# not see that reliably either (it missed six spellings), so nothing was
# traded away -- but it is the residual gap, and the runtime shape that
# would close it is a per-spec snapshot, which costs a `git status` per spec
# rather than per run.
#
# The other residual: this names PATHS, not the spec that wrote them. With
# 32 jobs in flight there is no attribution to be had at the phase
# boundary; the path is what a `grep -rn` over test/bats/ turns into a spec
# in one step.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  SCRATCH="$(mktemp -d)"
  REPO="${SCRATCH}/repo"
  BEFORE="${SCRATCH}/before"
  AFTER="${SCRATCH}/after"
  # The guard lives in the dispatcher, next to the compose call it wraps.
  # Sourced, not executed: test.sh only runs main when it is $0.
  # shellcheck disable=SC1091
  source /source/script/test/test.sh
  _make_repo
}

teardown() {
  rm -rf "${SCRATCH}"
}

# _make_repo -- a committed checkout with one tracked file, one tracked file
# whose name contains a space, and a .gitignore, so every case starts from a
# tree git calls clean.
_make_repo() {
  mkdir -p "${REPO}"
  git -C "${REPO}" -c init.defaultBranch=main init -q
  git -C "${REPO}" config user.email tester@example.invalid
  git -C "${REPO}" config user.name tester
  printf 'coverage/\n' > "${REPO}/.gitignore"
  printf 'one\n' > "${REPO}/tracked.txt"
  printf 'two\n' > "${REPO}/a file with spaces.txt"
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -qm init
}

# _snapshot_before / _snapshot_after -- the two ends of a run.
_snapshot_before() { _residue_snapshot "${REPO}" > "${BEFORE}"; }
_snapshot_after()  { _residue_snapshot "${REPO}" > "${AFTER}"; }

@test "_residue_paths: a file the run CREATED is named (#965)" {
  _snapshot_before
  printf 'planted\n' > "${REPO}/planted.md"
  _snapshot_after
  run _residue_paths "${BEFORE}" "${AFTER}"
  assert_success
  assert_output "planted.md"
}

@test "_residue_paths: an edit already in flight before the run is NOT named (#965)" {
  # The cry-wolf case, and the reason the guard compares two snapshots
  # instead of asking for a clean tree. A developer mid-change must be able
  # to run the gate.
  printf 'edited by the developer\n' > "${REPO}/tracked.txt"
  _snapshot_before
  _snapshot_after
  run _residue_paths "${BEFORE}" "${AFTER}"
  assert_success
  assert_output ""
}

@test "_residue_paths: a SECOND edit to an already-dirty file IS named (#965)" {
  # Why the record carries a content hash and not just git's status code:
  # both snapshots report ` M tracked.txt`, so a status-only record would
  # cancel and let a spec write over a file the developer was editing.
  printf 'edited by the developer\n' > "${REPO}/tracked.txt"
  _snapshot_before
  printf 'and then by a spec\n' > "${REPO}/tracked.txt"
  _snapshot_after
  run _residue_paths "${BEFORE}" "${AFTER}"
  assert_success
  assert_output "tracked.txt"
}

@test "_residue_paths: a tracked file the run DELETED is named (#965)" {
  _snapshot_before
  rm -f "${REPO}/tracked.txt"
  _snapshot_after
  run _residue_paths "${BEFORE}" "${AFTER}"
  assert_success
  assert_output "tracked.txt"
}

@test "_residue_paths: a gitignored path the run wrote is NOT named (#965)" {
  # The suite legitimately writes coverage/, log/ and .prev-release/, all
  # of them ignored. The guard inherits that list from .gitignore rather
  # than carrying an allowlist of its own -- one place to add a generated
  # tree, and it is the place that already had to know.
  _snapshot_before
  mkdir -p "${REPO}/coverage"
  printf 'report\n' > "${REPO}/coverage/index.html"
  _snapshot_after
  run _residue_paths "${BEFORE}" "${AFTER}"
  assert_success
  assert_output ""
}

@test "_residue_paths: a path containing a space is named whole (#965)" {
  # git's porcelain output QUOTES such a path unless it is read NUL-
  # separated, and a record split on whitespace truncates it. Either way
  # the guard would name a path that does not exist and the reader would
  # conclude the guard is broken -- which, for that report, it would be.
  _snapshot_before
  printf 'written by a spec\n' > "${REPO}/a file with spaces.txt"
  _snapshot_after
  run _residue_paths "${BEFORE}" "${AFTER}"
  assert_success
  assert_output "a file with spaces.txt"
}

@test "_residue_paths: a write under .git/ is EXCLUDED, and the exclusion is narrow (#965)" {
  # The blind spot, measured rather than assumed. `git status` never reports
  # a path under .git/, so a spec planting a hook, a config or an
  # alternates entry in the live checkout is invisible here -- and that is
  # the most damaging write there is, because git then executes or obeys it
  # in every later job.
  #
  # It is EXCLUDED, with a reason, rather than closed. Snapshotting .git/
  # wholesale reports noise on every run: git rewrites its own dir on
  # essentially any command, and the guard's own `git status` refreshes the
  # index. Narrowing that to "the parts that matter" means enumerating what
  # git reads to change its behaviour -- hooks, config keys, alternates,
  # modules, filters -- which is an OPEN set that grows with git, and an
  # open-set roster is exactly what this round deleted from the spec side
  # for being wrong in every review.
  #
  # So the check is: the exclusion is real, and it is NARROW -- one
  # directory up, the same write is named. A case that only asserted the
  # silence would also pass against a guard that had gone blind entirely.
  _snapshot_before
  printf 'a hook, as far as the guard can tell\n' > "${REPO}/.git/planted-under-git-dir"
  _snapshot_after
  run _residue_paths "${BEFORE}" "${AFTER}"
  assert_success
  assert_output ""
  printf 'planted\n' > "${REPO}/planted.md"
  _snapshot_after
  run _residue_paths "${BEFORE}" "${AFTER}"
  assert_success
  assert_output "planted.md"
}

@test "_residue_check: fails naming the path, and says what to do about it (#965)" {
  _snapshot_before
  printf 'planted\n' > "${REPO}/planted.md"
  run _residue_check "${BEFORE}" "${REPO}"
  assert_failure
  assert_output --partial "planted.md"
}

@test "_residue_check: passes on a run that changed nothing (#965)" {
  _snapshot_before
  run _residue_check "${BEFORE}" "${REPO}"
  assert_success
}

@test "_residue_check: a residue it already named is named AGAIN on the next run (#965)" {
  # The alarm was ONE-SHOT, and that is a hole in the SHAPE, not a slip.
  # The BEFORE snapshot exists so a developer's in-flight edit cancels --
  # and it therefore launders LAST RUN'S RESIDUE into this run's "in
  # flight". Measured before this case existed: run 1 failed naming the
  # path, run 2 with nothing fixed and nothing cleaned was green. The
  # second run is the one people believe, and re-running until green is the
  # habit this whole issue exists to break.
  #
  # "The suite left something behind" is not a statement about one run. It
  # is a statement about a path that appeared and nobody claimed, so the
  # guard has to REMEMBER what it named until the path is gone or somebody
  # says it is theirs.
  _snapshot_before
  printf 'planted\n' > "${REPO}/planted.md"
  run _residue_check "${BEFORE}" "${REPO}"
  assert_failure
  # The second run: the residue is on disk before it starts, so it appears
  # in BOTH snapshots and the comparison cancels it exactly as it cancels a
  # developer's edit. Only the memory can tell those two apart.
  _snapshot_before
  run _residue_check "${BEFORE}" "${REPO}"
  assert_failure
  assert_output --partial "planted.md"
}

@test "_residue_check: the memory clears when the residue is GONE (#965)" {
  # The other direction, and the one that keeps the memory from being a
  # permanent red. Nothing has to be acknowledged for a path that is no
  # longer there: cleaning up IS the acknowledgement.
  _snapshot_before
  printf 'planted\n' > "${REPO}/planted.md"
  run _residue_check "${BEFORE}" "${REPO}"
  assert_failure
  rm -f "${REPO}/planted.md"
  _snapshot_before
  run _residue_check "${BEFORE}" "${REPO}"
  assert_success
}

@test "_residue_forget: an acknowledged path goes quiet with the file still there (#965)" {
  # The escape hatch's second job. `TEST_RESIDUE_GUARD=0` already switched
  # the guard off for one invocation, for the one false positive the two
  # snapshots cannot cancel -- an edit made WHILE the suite ran. With a
  # memory in place that edit would otherwise be named on every run
  # afterwards, so the same switch drops the record: one knob, and it is
  # the one the failure message already names.
  _snapshot_before
  printf 'planted\n' > "${REPO}/planted.md"
  run _residue_check "${BEFORE}" "${REPO}"
  assert_failure
  _residue_forget "${REPO}"
  # The path is still there and still uncommitted. What changed is that
  # somebody claimed it, so it is an edit in flight like any other.
  _snapshot_before
  run _residue_check "${BEFORE}" "${REPO}"
  assert_success
}

@test "the pending record is kept OUTSIDE the working tree, so it is not residue itself (#965)" {
  # A guard whose own state file shows up in the next snapshot reports
  # itself for ever. The git dir is where this belongs: `git status` never
  # reports it, nothing ships it, and `--absolute-git-dir` resolves a
  # worktree to its OWN gitdir, so two worktrees of one repo do not share a
  # memory of each other's residue.
  local _record _gitdir
  _record="$(_residue_state_file "${REPO}")"
  _gitdir="$(git -C "${REPO}" rev-parse --absolute-git-dir)"
  [[ "${_record}" == "${_gitdir}/"* ]] || fail \
    "the pending record is at ${_record}, outside the git dir ${_gitdir}: anywhere in the working tree it becomes residue on the next run and the guard reports itself for ever"
  _snapshot_before
  printf 'planted\n' > "${REPO}/planted.md"
  run _residue_check "${BEFORE}" "${REPO}"
  assert_failure
  [[ -s "${_record}" ]] || fail \
    "the guard named a path and remembered nothing, so the next run inherits it as an edit in flight and goes green"
  _snapshot_after
  run _residue_paths "${BEFORE}" "${AFTER}"
  assert_output "planted.md"
}

@test "_residue_guard_available: answers no outside a git checkout (#965)" {
  # A released tarball is not a checkout. The guard is a developer-tree
  # invariant, so its absence must cost nothing -- a suite that refuses to
  # run where git is not is a worse outcome than an unguarded run.
  mkdir -p "${SCRATCH}/tarball"
  run _residue_guard_available "${SCRATCH}/tarball"
  assert_failure
  run _residue_guard_available "${REPO}"
  assert_success
}

@test "_residue_guard_available: is switched off by TEST_RESIDUE_GUARD=0 (#965)" {
  # The escape hatch for the one false positive the two-snapshot form
  # cannot cancel: an edit made WHILE the suite runs. It is per-invocation
  # and it is named in the failure message, so the developer who needs it
  # is told about it at the moment they need it.
  #
  # Both directions, because only one of them can go wrong quietly: a guard
  # that is unavailable for some OTHER reason answers "off" here too, and
  # the case would pass while proving nothing about the switch.
  run _residue_guard_available "${REPO}"
  assert_success
  TEST_RESIDUE_GUARD=0 run _residue_guard_available "${REPO}"
  assert_failure
}

@test "the compose dispatch is what runs the guard, not a caller that could forget (#965)" {
  # Both halves live inside _run_via_compose, which is the ONE host-side
  # point every bats dispatch passes through -- the local gate, each CI
  # shard, the fragile set, a single --bats-path run. A guard wired into
  # main's branches instead would be wired into some of them.
  local _body
  _body="$(awk '/^_run_via_compose\(\) \{/{f=1} f{print} f && /^\}$/{exit}' \
    /source/script/test/test.sh | strip_comments)"
  [[ -n "${_body}" ]] || fail "could not extract _run_via_compose from script/test/test.sh"
  grep -q '_residue_before_snapshot' <<< "${_body}" || fail \
    "_run_via_compose does not take a BEFORE snapshot, so nothing establishes what the run inherited"
  grep -q '_residue_check' <<< "${_body}" || fail \
    "_run_via_compose does not check for residue, so the snapshot is taken and thrown away"
  grep -q '_residue_forget' <<< "${_body}" || fail \
    "_run_via_compose never drops the pending record, so an invocation with TEST_RESIDUE_GUARD=0 -- the acknowledgement the failure message points at -- leaves the path named on every run afterwards"
}
