#!/usr/bin/env bats
#
# mutation_probe_spec.bats -- script/test/mutation-probe.sh, the loop that
# breaks a behaviour once to find out whether anything was pinning it.
#
# why: A green suite says every assertion ran. It does not say any of them
# would have noticed a wrong answer, and the v0.43 retrospective measured
# how far apart those two statements are: a guard that only greps for a
# string turns red when the file carrying that string is deleted, so under a
# revert it scores identically to a behavioural guard. The probe asks the
# question a revert cannot -- put the production code back, break its
# BEHAVIOUR in place, and see what fails.
#
# The subject under test here is the LOOP, not any one mutation: record the
# original, apply the mutation, run, restore, prove the restoration, and
# report a verdict that cannot be read off an empty measurement. Every
# vacuous answer the retrospective hit is refused by name below.
#
# The narrow-scope refusal is base#1108's measured correction and the reason
# this file exists rather than a paragraph of prose. That audit asked "is
# this change covered in the spec the PR edited", and on six changes five of
# the greens it produced had a failing witness in a SIBLING spec from the
# same PR. A spec that stays green under a mutation has answered about
# itself; it has not answered about the suite. So the probe reports
# INCONCLUSIVE for a narrow green instead of NOT PINNED, and only a
# tier-wide run can say a behaviour is unpinned.
#
# Measured on this tree before the loop was built, which is this repo's bar
# for a new rule. Deleting dist/script/docker/wrapper/build.sh -- the
# subject of reclaim_wiring_spec.bats's "the verbs that BEGIN a flow do not
# reclaim" -- leaves that spec at 32 ok / 0 not ok, because a refutation
# over a file that is not there is satisfied by its absence. The same
# mutation at tier scope is 4667 ok / 109 not ok, and the witnesses name
# build_sh_spec.bats. Narrow scope answered "not pinned"; the tier answered
# "pinned, by build_sh_spec".
#
# The fixtures are real git work trees, not scratch directories, because the
# probe's leak check IS git: it compares the tree before and after the
# mutation to catch a mutation command that touched a file it did not
# declare. Faking that comparison would test a control this repo does not
# ship.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  PROBE="/source/script/test/mutation-probe.sh"
}

# ── fixtures ────────────────────────────────────────────────────────────────

# _probe_fixture -- a committed git work tree with one subject file and one
# bystander, and print its path. The bystander is what the leak check has to
# notice a mutation touching.
_probe_fixture() {
  local _root="${BATS_TEST_TMPDIR}/tree"
  mkdir -p "${_root}"
  printf '%s\n' '#!/usr/bin/env bash' 'the_behaviour() { printf "right\n"; }' \
    > "${_root}/subject.sh"
  chmod +x "${_root}/subject.sh"
  printf '%s\n' 'untouched' > "${_root}/bystander.txt"
  git -C "${_root}" init -q
  git -C "${_root}" -c user.email=probe@example.invalid -c user.name=probe \
    add -A
  git -C "${_root}" -c user.email=probe@example.invalid -c user.name=probe \
    commit -qm fixture
  printf '%s\n' "${_root}"
}

# _probe_runner <name> <body> -- an executable stub standing in for the suite
# runner, and print its path. The probe takes the runner from the
# MUTATION_PROBE_RUNNER override precisely so the loop can be tested without
# a docker build in it.
_probe_runner() {
  local _p="${BATS_TEST_TMPDIR}/runner-${1}"
  printf '%s\n%s\n' '#!/usr/bin/env bash' "${2}" > "${_p}"
  chmod +x "${_p}"
  printf '%s\n' "${_p}"
}

# ── what the loop refuses before it touches anything ────────────────────────

# why: the probe's first act is to record the originals, and a root it cannot
# resolve means it recorded nothing -- so every later step would be
# operating on a tree it never read. Refusing here is what keeps a typo in
# a path from being reported as a test-suite verdict.
@test "_mutation_probe: refuses a root that does not exist" {
  run bash -c "source '${PROBE}'; _mutation_probe '${BATS_TEST_TMPDIR}/nope' --subject a.sh --mutate true"
  assert_failure
  assert_output --partial "does not exist or is not a directory"
  assert_output --partial "nope"
}

# why: the probe compares the tree before and after the mutation to catch a
# mutation that touched an undeclared file, and git is what answers that
# comparison. A root that is not a work tree would silently lose the leak
# check, which is the one control standing between this tool and a
# half-mutated checkout.
@test "_mutation_probe: refuses a root that is not a git work tree" {
  local _root="${BATS_TEST_TMPDIR}/bare"
  mkdir -p "${_root}"
  printf 'x\n' > "${_root}/subject.sh"
  run bash -c "source '${PROBE}'; _mutation_probe '${_root}' --subject subject.sh --mutate true"
  assert_failure
  assert_output --partial "is not a git work tree"
}

# why: with no subject declared there is nothing to record and nothing to
# restore, so the loop could not put the tree back even if it wanted to.
# The declaration is also what the leak check measures against.
@test "_mutation_probe: refuses a run with no subject declared" {
  local _root
  _root="$(_probe_fixture)"
  run bash -c "source '${PROBE}'; _mutation_probe '${_root}' --mutate true"
  assert_failure
  assert_output --partial "no --subject declared"
}

# why: a probe of a file that is not there measures nothing, and this is the
# exact shape the retrospective kept hitting -- a guard whose subject had
# moved stayed green because the absence satisfied it. Naming the path in
# the refusal is what tells the author the path moved rather than the test
# being weak.
@test "_mutation_probe: refuses a subject that does not exist under the root" {
  local _root
  _root="$(_probe_fixture)"
  run bash -c "source '${PROBE}'; _mutation_probe '${_root}' --subject gone.sh --mutate true"
  assert_failure
  assert_output --partial "subject 'gone.sh' is not a regular file"
}

# why: without a mutation the run is just the suite, and the suite was already
# green -- reporting that as a probe result would certify every test in the
# tree as behavioural on no evidence at all.
@test "_mutation_probe: refuses a run with no mutation declared" {
  local _root
  _root="$(_probe_fixture)"
  run bash -c "source '${PROBE}'; _mutation_probe '${_root}' --subject subject.sh"
  assert_failure
  assert_output --partial "no --mutate command"
}

# ── the non-vacuity refusals: a green that means nothing ─────────────────────

# why: THE load-bearing refusal. A mutation command that matched nothing
# leaves the tree exactly as the suite already passed over, so the green
# that follows is the baseline and not a measurement -- and read as a
# verdict it certifies the test as behavioural on the strength of a typo in
# a sed expression.
@test "_mutation_probe: refuses a mutation that left every subject byte-identical" {
  local _root _runner
  _root="$(_probe_fixture)"
  _runner="$(_probe_runner green 'printf "ok 1 one\nok 2 two\n"')"
  run env MUTATION_PROBE_RUNNER="${_runner}" bash -c "source '${PROBE}'; _mutation_probe '${_root}' --subject subject.sh --mutate 'sed -i s/nothingmatches/x/ subject.sh'"
  assert_failure
  assert_output --partial "byte-identical"
  run cmp -s "${_root}/subject.sh" <(printf '%s\n' '#!/usr/bin/env bash' 'the_behaviour() { printf "right\n"; }')
  assert_success
}

# why: the leak check compares the tree before and after, and comparing only
# git's status CODES misses the commonest real case: a file that was already
# dirty stays ` M` through a second edit, so the probe would run the suite and
# leave the undeclared mutation behind with nothing said. An author running
# this mid-change always has dirty files.
@test "_mutation_probe: refuses a mutation that edited a file that was ALREADY dirty" {
  local _root _runner
  _root="$(_probe_fixture)"
  printf '%s\n' 'an edit the author had already made' > "${_root}/bystander.txt"
  _runner="$(_probe_runner green 'printf "ok 1 one\n"')"
  run env MUTATION_PROBE_RUNNER="${_runner}" bash -c "source '${PROBE}'; _mutation_probe '${_root}' --subject subject.sh --mutate 'sed -i s/right/wrong/ subject.sh; printf leaked > bystander.txt'"
  assert_failure
  assert_output --partial "touched bystander.txt, which it did not declare"
}

# why: the same hole with the other status code. An untracked file is `??`
# before and after, so a mutation that rewrites one is invisible to a
# code-only comparison -- and an untracked file is exactly what a half-built
# fixture or a scratch script is.
@test "_mutation_probe: refuses a mutation that edited a file that was ALREADY untracked" {
  local _root _runner
  _root="$(_probe_fixture)"
  printf '%s\n' 'scratch' > "${_root}/scratch.txt"
  _runner="$(_probe_runner green 'printf "ok 1 one\n"')"
  run env MUTATION_PROBE_RUNNER="${_runner}" bash -c "source '${PROBE}'; _mutation_probe '${_root}' --subject subject.sh --mutate 'sed -i s/right/wrong/ subject.sh; printf leaked > scratch.txt'"
  assert_failure
  assert_output --partial "touched scratch.txt, which it did not declare"
}

# why: a mutation that edits a file it did not declare is a mutation the loop
# cannot undo, because only the declared subjects were recorded. Catching it
# between the mutation and the run is what keeps the undeclared edit from
# being carried through a multi-minute suite and then left behind.
@test "_mutation_probe: refuses a mutation that touched a file it did not declare" {
  local _root _runner
  _root="$(_probe_fixture)"
  _runner="$(_probe_runner green 'printf "ok 1 one\n"')"
  run env MUTATION_PROBE_RUNNER="${_runner}" bash -c "source '${PROBE}'; _mutation_probe '${_root}' --subject subject.sh --mutate 'sed -i s/right/wrong/ subject.sh; printf leaked > bystander.txt'"
  assert_failure
  assert_output --partial "touched bystander.txt, which it did not declare"
}

# why: the subject it DID declare still has to come back. A leak refusal that
# left the declared mutation in place would turn the safest control in the
# loop into the thing that strands the tree. The marker is the positive the
# refutation needs: without it this case passes on a probe that never ran at
# all, which is the defect the whole change is about.
@test "_mutation_probe: restores the declared subject even when it refuses for a leak" {
  local _root _runner _ran="${BATS_TEST_TMPDIR}/mutation-ran"
  _root="$(_probe_fixture)"
  _runner="$(_probe_runner green 'printf "ok 1 one\n"')"
  run env MUTATION_PROBE_RUNNER="${_runner}" bash -c "source '${PROBE}'; _mutation_probe '${_root}' --subject subject.sh --mutate 'sed -i s/right/wrong/ subject.sh; printf leaked > bystander.txt; : > ${_ran}'"
  assert_failure
  assert_output --partial "touched bystander.txt, which it did not declare"
  run test -f "${_ran}"
  assert_success
  run grep -cF 'right' "${_root}/subject.sh"
  assert_output "1"
}

# why: base#1089's rule, applied to a probe instead of a gate: both no-evidence
# states are refused by name. A run that reported no test results at all has
# zero reds, and zero reds is the same number a fully behavioural suite
# would print -- so reading it as NOT PINNED turns a broken runner into a
# finding about the tests.
@test "_mutation_probe: refuses a run that reported no test results at all" {
  local _root _runner
  _root="$(_probe_fixture)"
  _runner="$(_probe_runner silent 'printf "the runner died before collection\n"; exit 1')"
  run env MUTATION_PROBE_RUNNER="${_runner}" bash -c "source '${PROBE}'; _mutation_probe '${_root}' --subject subject.sh --mutate 'sed -i s/right/wrong/ subject.sh'"
  assert_failure
  assert_output --partial "no test results"
}

# why: the halfway version of the same hole, and the dangerous one, because it
# arrives with a plausible number. A runner that prints some passes and then
# dies has zero reds over a population that never finished, so counting
# results alone reports NOT PINNED about assertions that did not run.
@test "_mutation_probe: refuses a green whose runner did not finish" {
  local _root _runner
  _root="$(_probe_fixture)"
  _runner="$(_probe_runner partial 'printf "ok 1 one\nok 2 two\n"; exit 143')"
  run env MUTATION_PROBE_RUNNER="${_runner}" bash -c "source '${PROBE}'; _mutation_probe '${_root}' --subject subject.sh --mutate 'sed -i s/right/wrong/ subject.sh'"
  assert_failure
  refute_output --partial "PINNED"
  assert_output --partial "did not finish"
}

# why: a red is still a red when the runner exits non-zero, because that is how
# every failing suite exits. A completion check written without this case
# would refuse the probe's entire reason for existing.
@test "_mutation_probe: a red runner exit is PINNED, not an unfinished run" {
  local _root _runner
  _root="$(_probe_fixture)"
  _runner="$(_probe_runner redexit 'printf "ok 1 one\nnot ok 2 the witness\n"; exit 1')"
  run env MUTATION_PROBE_RUNNER="${_runner}" bash -c "source '${PROBE}'; _mutation_probe '${_root}' --subject subject.sh --mutate 'sed -i s/right/wrong/ subject.sh'"
  assert_success
  assert_output --partial "PINNED"
}

# ── the verdicts ────────────────────────────────────────────────────────────

# why: the answer the probe exists to produce, and the reason the issue asks
# for the witness in the PR body: a red names WHICH assertion was pinning
# the behaviour, which is the half a pass/fail verdict throws away.
@test "_mutation_probe: reports PINNED and names the witness when the mutation turns something red" {
  local _root _runner
  _root="$(_probe_fixture)"
  _runner="$(_probe_runner red 'printf "ok 1 one\nnot ok 2 the_behaviour returns the right answer\nok 3 three\n"')"
  run env MUTATION_PROBE_RUNNER="${_runner}" bash -c "source '${PROBE}'; _mutation_probe '${_root}' --subject subject.sh --mutate 'sed -i s/right/wrong/ subject.sh'"
  assert_success
  assert_output --partial "PINNED"
  assert_output --partial "the_behaviour returns the right answer"
}

# why: a tier-wide green under a real mutation is the finding -- the behaviour
# can be wrong and the whole suite still passes. It exits non-zero so the
# probe can sit in a loop that stops on it.
@test "_mutation_probe: reports NOT PINNED on a tier-wide run that stays green" {
  local _root _runner
  _root="$(_probe_fixture)"
  _runner="$(_probe_runner green 'printf "ok 1 one\nok 2 two\n"')"
  run env MUTATION_PROBE_RUNNER="${_runner}" bash -c "source '${PROBE}'; _mutation_probe '${_root}' --subject subject.sh --mutate 'sed -i s/right/wrong/ subject.sh'"
  assert_failure
  assert_output --partial "NOT PINNED"
}

# why: base#1108's correction, which is the whole reason this file is a
# mechanism and not a paragraph. Asked per-file, that audit called six
# changes untested; five of the six had their failing witness in a sibling
# spec from the same PR. A narrow green is a statement about one spec, so
# the probe refuses to spell it NOT PINNED.
@test "_mutation_probe: a narrow green is INCONCLUSIVE, never NOT PINNED" {
  local _root _runner
  _root="$(_probe_fixture)"
  _runner="$(_probe_runner green 'printf "ok 1 one\nok 2 two\n"')"
  run env MUTATION_PROBE_RUNNER="${_runner}" bash -c "source '${PROBE}'; _mutation_probe '${_root}' --subject subject.sh --spec test/bats/unit/x_spec.bats --mutate 'sed -i s/right/wrong/ subject.sh'"
  assert_failure
  assert_output --partial "INCONCLUSIVE"
  refute_output --partial "NOT PINNED"
}

# why: the asymmetry is the point and it is easy to get backwards. A red
# answers soundly at any scope -- something observed the wrong answer --
# while only a green has to be qualified by how much ran.
@test "_mutation_probe: a narrow RED is still PINNED, because a red needs no scope" {
  local _root _runner
  _root="$(_probe_fixture)"
  _runner="$(_probe_runner red 'printf "not ok 1 the narrow spec noticed\n"')"
  run env MUTATION_PROBE_RUNNER="${_runner}" bash -c "source '${PROBE}'; _mutation_probe '${_root}' --subject subject.sh --spec test/bats/unit/x_spec.bats --mutate 'sed -i s/right/wrong/ subject.sh'"
  assert_success
  assert_output --partial "PINNED"
}

# why: the scope is what makes a verdict readable a week later, and the
# retrospective's false positives are exactly the case where nobody
# recorded how much had run. Printing it on every verdict is what stops the
# next reader from having to assume.
@test "_mutation_probe: every verdict states the scope it was measured at" {
  local _root _runner
  _root="$(_probe_fixture)"
  _runner="$(_probe_runner red 'printf "not ok 1 witness\n"')"
  run env MUTATION_PROBE_RUNNER="${_runner}" bash -c "source '${PROBE}'; _mutation_probe '${_root}' --subject subject.sh --mutate 'sed -i s/right/wrong/ subject.sh'"
  assert_success
  assert_output --partial "scope=tier"
}

# ── the tree cannot be left mutated ─────────────────────────────────────────

# why: the whole reason a probe is safe to recommend. A harness that leaves a
# half-mutated tree is worse than no harness, so the restoration is proven
# on the happy path rather than assumed from the absence of a complaint.
@test "_mutation_probe: restores the subject byte-for-byte after a completed run" {
  local _root _runner
  _root="$(_probe_fixture)"
  _runner="$(_probe_runner red 'printf "not ok 1 witness\n"')"
  run env MUTATION_PROBE_RUNNER="${_runner}" bash -c "source '${PROBE}'; _mutation_probe '${_root}' --subject subject.sh --mutate 'sed -i s/right/wrong/ subject.sh'"
  assert_success
  run git -C "${_root}" status --porcelain
  assert_output ""
}

# why: the mode is part of the file. Restoring the bytes of an executable as a
# non-executable leaves a tree that reads clean to a diff and is broken to
# everything that runs it.
@test "_mutation_probe: restores the subject's mode, not only its bytes" {
  local _root _runner
  _root="$(_probe_fixture)"
  _runner="$(_probe_runner red 'printf "not ok 1 witness\n"')"
  run env MUTATION_PROBE_RUNNER="${_runner}" bash -c "source '${PROBE}'; _mutation_probe '${_root}' --subject subject.sh --mutate 'chmod -x subject.sh; sed -i s/right/wrong/ subject.sh'"
  assert_success
  run test -x "${_root}/subject.sh"
  assert_success
}

# why: the failure mode that matters most -- a runner that dies mid-suite is
# the ordinary case (a ctrl-c, a docker daemon hiccup), and that is exactly
# when a tree gets stranded. The marker is the positive: a clean tree proves
# nothing unless the mutation reached it and the runner started, so without
# it this case passes on a probe that never ran.
@test "_mutation_probe: restores the subject when the runner dies without finishing" {
  local _root _runner _ran="${BATS_TEST_TMPDIR}/runner-started"
  _root="$(_probe_fixture)"
  _runner="$(_probe_runner crash "printf 'ok 1 one\n'; : > ${_ran}; kill -TERM \$\$")"
  run env MUTATION_PROBE_RUNNER="${_runner}" bash -c "source '${PROBE}'; _mutation_probe '${_root}' --subject subject.sh --mutate 'sed -i s/right/wrong/ subject.sh'"
  assert_failure
  run test -f "${_ran}"
  assert_success
  run git -C "${_root}" status --porcelain
  assert_output ""
}

# why: the restoration is only a guarantee if something checks it, and the
# check has to be able to say no. Asserted directly rather than through the
# loop, because the loop is built so this never fires -- a control nothing
# exercises is a control nobody knows works.
@test "_mutation_probe_verify_restored: fails and names the file when a subject did not come back" {
  local _root="${BATS_TEST_TMPDIR}/vr" _rec="${BATS_TEST_TMPDIR}/rec"
  mkdir -p "${_root}" "${_rec}"
  printf 'original\n' > "${_rec}/subject.sh"
  printf 'still mutated\n' > "${_root}/subject.sh"
  run bash -c "source '${PROBE}'; _mutation_probe_verify_restored '${_rec}' '${_root}' subject.sh"
  assert_failure
  assert_output --partial "subject.sh"
}

# why: the other direction of the same control. A verifier that always failed
# would make the loop refuse every clean run, and a verifier that always
# passed is the one that strands a tree -- so both answers are pinned.
@test "_mutation_probe_verify_restored: passes when the subject is byte-identical to the record" {
  local _root="${BATS_TEST_TMPDIR}/vr2" _rec="${BATS_TEST_TMPDIR}/rec2"
  mkdir -p "${_root}" "${_rec}"
  printf 'original\n' > "${_rec}/subject.sh"
  printf 'original\n' > "${_root}/subject.sh"
  run bash -c "source '${PROBE}'; _mutation_probe_verify_restored '${_rec}' '${_root}' subject.sh"
  assert_success
}

# why: a ctrl-c has to STOP the probe, not just tidy up behind it. A handler
# that restores and then returns lets the loop fall through to its verdict
# and report a measurement taken over a suite that was killed partway --
# which is a number nobody can tell apart from a finished run's.
@test "_mutation_probe: a signal stops the run instead of reporting a verdict" {
  local _root _runner _marker="${BATS_TEST_TMPDIR}/runner-entered"
  local _out="${BATS_TEST_TMPDIR}/signal-out"
  local _runner_pid="${BATS_TEST_TMPDIR}/runner-pid"
  _root="$(_probe_fixture)"
  _runner="$(_probe_runner slow "printf 'ok 1 one\n'; printf '%s\n' \"\$\$\" > ${_runner_pid}; : > ${_marker}; sleep 30")"
  env MUTATION_PROBE_RUNNER="${_runner}" bash -c "source '${PROBE}'; _mutation_probe '${_root}' --subject subject.sh --mutate 'sed -i s/right/wrong/ subject.sh'" > "${_out}" 2>&1 &
  local _pid=$! _i=0
  while (( _i < 500 )); do
    [[ -f "${_marker}" ]] && break
    sleep 0.02
    _i=$(( _i + 1 ))
  done
  run test -f "${_marker}"
  assert_success
  kill -TERM "${_pid}" 2>/dev/null || true
  wait "${_pid}" 2>/dev/null || true
  run cat "${_out}"
  # The discriminating line. A handler that merely restored and returned would
  # fall through to the completion refusal instead, which also says
  # "interrupted" and also withholds a verdict -- so refuting PINNED alone
  # cannot tell the two apart, and did not.
  assert_output --partial "so there is NO verdict"
  refute_output --partial "PINNED"
  # The suite must be STOPPED, not left running against a tree that is being
  # restored under it. The runner sleeps 30s, so a live pid here is a kill
  # that did not happen.
  run bash -c "kill -0 \"$(cat "${_runner_pid}")\" 2>/dev/null"
  assert_failure
  run git -C "${_root}" status --porcelain
  assert_output ""
}

# why: the trap is what covers the paths the explicit restore cannot reach, and
# a trap handler nothing ever calls is the classic dead control. Driving the
# payload directly is the only way to see it put a file back.
@test "_mutation_probe_emergency_restore: puts the recorded subject back from the trap path" {
  local _root="${BATS_TEST_TMPDIR}/er" _rec="${BATS_TEST_TMPDIR}/erec"
  mkdir -p "${_root}" "${_rec}"
  printf 'original\n' > "${_rec}/subject.sh"
  printf 'mutated\n' > "${_root}/subject.sh"
  run bash -c "
    source '${PROBE}'
    _MUTATION_PROBE_RECORD_DIR='${_rec}'
    _MUTATION_PROBE_ROOT='${_root}'
    _MUTATION_PROBE_SUBJECTS=( subject.sh )
    _mutation_probe_emergency_restore
  "
  run cat "${_root}/subject.sh"
  assert_output "original"
}

# ── the documented entry point hands the mutation over intact ───────────────
#
# The recipe is a seam, and a seam is what a grep cannot check. `just test
# mutation-probe --mutate 'printf x > y'` interpolated unquoted is split by
# the recipe's own shell: the probe sees `printf`, and the `>` redirection
# runs OUTSIDE the record-and-restore loop, writing a file nothing will put
# back. So the forwarding is driven for real, over a sandbox that copies the
# justfiles and stubs the script.

# _probe_just_sandbox <dir> -- the two justfiles plus a mutation-probe stub
# that prints its argv one element per line.
_probe_just_sandbox() {
  local _dir="${1:?_probe_just_sandbox requires a dir}"
  mkdir -p "${_dir}/script/test"
  cp /source/justfile "${_dir}/justfile"
  cp /source/script/test/justfile.test "${_dir}/script/test/justfile.test"
  cat > "${_dir}/script/test/mutation-probe.sh" <<'STUB'
#!/usr/bin/env bash
for _a in "$@"; do printf 'ARG[%s]\n' "${_a}"; done
STUB
  chmod +x "${_dir}/script/test/mutation-probe.sh"
}

# why: the defect the review reproduced. A mutation is one argument containing
# spaces, quotes, a redirection and a semicolon; split by the recipe shell it
# becomes an unknown-argument refusal at best and an edit made outside the
# restore loop at worst.
@test "just test mutation-probe hands the mutation over as ONE argument" {
  command -v just >/dev/null 2>&1 \
    || skip "this test-tools image has no just (older pinned TEST_TOOLS_IMAGE)"
  local _tmp
  _tmp="$(mktemp -d)"
  _probe_just_sandbox "${_tmp}"
  run just --justfile "${_tmp}/justfile" --working-directory "${_tmp}" \
    test mutation-probe --subject s.sh --mutate 'printf wrong > s.sh; true'
  local _s="${status}" _o="${output}"
  rm -rf "${_tmp}"
  status="${_s}"; output="${_o}"
  assert_success
  assert_output --partial 'ARG[--mutate]'
  assert_output --partial 'ARG[printf wrong > s.sh; true]'
}

# why: the other half of the same seam. The redirection inside the mutation
# must not be performed by the recipe's shell, because a file it wrote is a
# file the probe never recorded and so can never restore.
@test "just test mutation-probe does not execute the mutation's redirection itself" {
  command -v just >/dev/null 2>&1 \
    || skip "this test-tools image has no just (older pinned TEST_TOOLS_IMAGE)"
  local _tmp
  _tmp="$(mktemp -d)"
  _probe_just_sandbox "${_tmp}"
  run just --justfile "${_tmp}/justfile" --working-directory "${_tmp}" \
    test mutation-probe --subject s.sh --mutate 'printf wrong > leaked.txt'
  local _s="${status}" _leaked=0
  [[ -f "${_tmp}/leaked.txt" ]] && _leaked=1
  rm -rf "${_tmp}"
  status="${_s}"
  assert_success
  [[ "${_leaked}" -eq 0 ]] \
    || fail "the recipe shell performed the mutation's redirection itself"
}

# ── round-two review findings, each reproduced before it was fixed ───────────

# why: a symlink passes the regular-file test, and `cp -p` then records the
# TARGET's bytes. An in-place editor replaces the link with a regular file,
# the restore writes the bytes back, verification reports success, and git
# calls the result `T`. This repo ships such links.
@test "_mutation_probe: refuses a symlink subject and names its target" {
  local _root
  _root="$(_probe_fixture)"
  ln -s subject.sh "${_root}/link.sh"
  run bash -c "source '${PROBE}'; _mutation_probe '${_root}' --subject link.sh --mutate true"
  assert_failure
  assert_output --partial "is a symlink to 'subject.sh'"
}

# why: the probe reads a BATS_* selector out of its own environment and hands it
# to the runner, so `--bats-only` can run one spec while the verdict says
# scope=tier -- a claim about sibling tests that never ran, which is the exact
# false positive the scope rule exists to prevent.
@test "_mutation_probe: no inherited BATS_ selector reaches the runner on a tier run" {
  local _root _runner
  _root="$(_probe_fixture)"
  _runner="$(_probe_runner selectors 'if [[ -n "${BATS_FILE:-}${BATS_FILTER:-}${BATS_UNIT_SHARD:-}" ]]; then printf "not ok 1 a narrowing selector reached the runner\n"; else printf "ok 1 the runner saw no selector\n"; fi')"
  run env BATS_FILE=test/bats/unit/x_spec.bats BATS_FILTER=nothing \
    MUTATION_PROBE_RUNNER="${_runner}" bash -c "source '${PROBE}'; _mutation_probe '${_root}' --subject subject.sh --mutate 'sed -i s/right/wrong/ subject.sh'"
  assert_failure
  refute_output --partial "a narrowing selector reached the runner"
  assert_output --partial "NOT PINNED at scope=tier"
}

# why: the verdict used to be printed first and the restore's status then
# discarded by an unconditional return, so a RED run whose restore had failed
# reported PINNED and exit 0 with the mutation still in the tree. The
# restoration failure is the more important news and has to be the only news.
# The mutation replaces the subject with a DIRECTORY, which no `cp` can
# overwrite; a permission-based failure was tried first and does not work,
# because `cp` onto an existing file needs write on the FILE, so chmod on the
# parent changes nothing and chmod on the file is a no-op under a root
# container. This one fails for every uid.
@test "_mutation_probe: publishes NO verdict when the restoration failed" {
  local _root _runner
  _root="$(_probe_fixture)"
  mkdir -p "${_root}/sub"
  printf '%s\n' 'right' > "${_root}/sub/held.sh"
  git -C "${_root}" -c user.email=probe@example.invalid -c user.name=probe add -A
  git -C "${_root}" -c user.email=probe@example.invalid -c user.name=probe \
    commit -qm held
  _runner="$(_probe_runner red 'printf "not ok 1 the witness\n"')"
  run env MUTATION_PROBE_RUNNER="${_runner}" bash -c "source '${PROBE}'; _mutation_probe '${_root}' --subject sub/held.sh --mutate 'sed -i s/right/wrong/ sub/held.sh; rm -f sub/held.sh; mkdir sub/held.sh'"
  assert_failure
  assert_output --partial "copy them back before anything else reads this checkout"
  refute_output --partial "PINNED"
}

# why: a TERM to the runner's pid alone leaves its children running -- and the
# real runner is test.sh waiting on `docker compose run`, so the container
# would keep reading a tree the probe is restoring under it.
@test "_mutation_probe: a signal stops the runner's children too, not just the runner" {
  local _root _runner _marker="${BATS_TEST_TMPDIR}/grp-entered"
  local _out="${BATS_TEST_TMPDIR}/grp-out"
  local _childpid="${BATS_TEST_TMPDIR}/grp-childpid"
  _root="$(_probe_fixture)"
  _runner="$(_probe_runner group "printf 'ok 1 one\n'; sleep 30 & printf '%s\n' \"\$!\" > ${_childpid}; : > ${_marker}; wait")"
  env MUTATION_PROBE_RUNNER="${_runner}" bash -c "source '${PROBE}'; _mutation_probe '${_root}' --subject subject.sh --mutate 'sed -i s/right/wrong/ subject.sh'" > "${_out}" 2>&1 &
  local _pid=$! _i=0
  while (( _i < 500 )); do
    [[ -s "${_childpid}" ]] && break
    sleep 0.02
    _i=$(( _i + 1 ))
  done
  run test -s "${_childpid}"
  assert_success
  kill -TERM "${_pid}" 2>/dev/null || true
  wait "${_pid}" 2>/dev/null || true
  run bash -c "kill -0 \"$(cat "${_childpid}")\" 2>/dev/null"
  assert_failure
}
