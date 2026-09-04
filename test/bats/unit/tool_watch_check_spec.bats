#!/usr/bin/env bats
#
# Unit tests for script/watch/check.sh -- the network half of the
# upstream-release watch, driven entirely offline.
#
# What is under test is the EXIT CODE, because that is the whole
# interface: the scheduled workflow reads it and nothing else decides
# whether a bump is proposed, whether the job goes red, or whether the
# week is declared clean. The three answers have to stay
# distinguishable -- 0 "every pin is current", 10 "there is work", 1
# "this run proves nothing" -- and the failure that matters is not a
# crash. It is 1 collapsing into 0, because the watch is a job nobody
# reads precisely because it normally does nothing, so a silent green is
# indistinguishable from a real one.
#
# The resolvers are pointed at a `file://` tree instead of the real APIs,
# so every case here is deterministic and runs with no network.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  CHECK="/source/script/watch/check.sh"
  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/tree/dockerfile" "${SCRATCH}/api" "${SCRATCH}/bin"
  # The registry's population is what the scanned tree TRACKS, so the
  # tree is a real repository. `_check` stages it before each run; the
  # fixture API and the curl stub sit OUTSIDE it on purpose, so nothing
  # the harness needs can be mistaken for repo content.
  git -C "${SCRATCH}/tree" init -q
  API="file://${SCRATCH}/api"

  # The one external call check.sh makes, served from a fixture tree. A
  # stub SCRIPT rather than a shell function because check.sh runs as a
  # subprocess, and the test-tools image carries no curl at all -- which
  # is itself the reason these cases must not reach a real API: a unit
  # spec that needed the network would be skipped in exactly the
  # environment it is meant to guard.
  cat > "${SCRATCH}/bin/curl" <<'STUB'
#!/usr/bin/env bash
_url="${!#}"
_path="${_url#file://}"
[[ -f "${_path}" ]] || exit 22
cat -- "${_path}"
STUB
  chmod +x "${SCRATCH}/bin/curl"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _release <owner/repo> <tag> -- what the github-release resolver reads.
_release() {
  mkdir -p "${SCRATCH}/api/repos/${1}/releases"
  printf '{"tag_name": "%s"}\n' "${2}" \
    > "${SCRATCH}/api/repos/${1}/releases/latest"
}

# _dockerfile <line>... -- the scanned tree.
_dockerfile() {
  printf '%s\n' "$@" > "${SCRATCH}/tree/dockerfile/Dockerfile"
}

_check() {
  _stage
  PATH="${SCRATCH}/bin:${PATH}" PIN_REPO_ROOT="${SCRATCH}/tree" \
    WATCH_GITHUB_API="${API}" run "${CHECK}" "$@"
}

# _stage -- everything written into the tree so far is what it tracks.
# Called by _check, and by hand in the cases that invoke check.sh
# directly to separate its two streams.
_stage() {
  git -C "${SCRATCH}/tree" add -A
}

# _reset_tree <subdir>... -- start the scanned tree over. It is a git
# repository again afterwards, because that is what makes it a tree the
# reader has a population for at all.
_reset_tree() {
  rm -rf "${SCRATCH:?}/tree"
  mkdir -p "${SCRATCH}/tree" "${@/#/${SCRATCH}/tree/}"
  git -C "${SCRATCH}/tree" init -q
}

# ════════════════════════════════════════════════════════════════════
# The three answers stay apart
# ════════════════════════════════════════════════════════════════════

# why: The load-bearing case: exit 10 is what the workflow reads as "open a
# proposal", and it has to carry both versions to write one
@test "watch: a pin behind its upstream exits 10 and names both versions" {
  _release owner/foo v2.0.0
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=1.0.0'
  _check --report
  assert_equal "${status}" 10
  assert_output --partial 'DRIFTED (1)'
  assert_output --partial '1.0.0'
  assert_output --partial 'v2.0.0'
}

# why: The other side of that switch -- a clean week must stay distinguishable
# from a run that compared nothing
@test "watch: a pin level with its upstream exits 0" {
  _release owner/foo v1.0.0
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=v1.0.0'
  _check --report
  assert_success
  assert_output --partial 'CURRENT (1)'
}

# why: An unreachable upstream yielding an empty matrix would look exactly like
# a clean week
@test "watch: an upstream that does not answer FAILS the run" {
  # Never reported as up to date and never skipped quietly: an
  # unreachable upstream that yielded an empty matrix would look exactly
  # like a clean week.
  _dockerfile \
    '# tool-pin: ghost github-release owner/ghost' \
    'ARG GHOST_VERSION=1.0.0'
  _check --report
  assert_equal "${status}" 1
  assert_output --partial 'UNRESOLVED (1)'
}

# why: A refusal this repo already recorded must not be re-proposed every week;
# closing a PR is how the old mechanism forgot one silently
@test "watch: a version on the pin's skip list is refused, not proposed" {
  _release owner/foo v2.0.0
  _dockerfile \
    '# tool-pin: foo github-release owner/foo skip=v2.0.0' \
    'ARG FOO_VERSION=1.0.0'
  _check --report
  assert_success
  assert_output --partial 'REFUSED (1)'
  assert_output --partial 'DRIFTED (0)'
}

# ════════════════════════════════════════════════════════════════════
# A table it could not read must never read as a clean week
# ════════════════════════════════════════════════════════════════════

# why: The regression: a process substitution discarded the reader's status, so
# an unreadable tree printed all-zero counts and exited green
@test "watch: a pin table that does not parse exits 1, not 0" {
  # The regression this pins down: the scan loop used to consume the
  # reader through a process substitution, which discards the producer's
  # status. A tree the reader could not read printed DRIFTED (0) /
  # UNRESOLVED (0) / CURRENT (0) and exited 0 -- `count=0` in the
  # workflow, the bump skipped, the job green, indistinguishable from a
  # week with nothing to do.
  _dockerfile \
    '# tool-pin: broken github-release owner/broken latest=9' \
    'ARG BROKEN_VERSION=1.0.0'
  _check --report
  assert_equal "${status}" 1
  assert_output --partial 'NOTHING was compared'
  refute_output --partial 'CURRENT (0)'
}

# why: The partial form of that defect -- pins after the bad marker vanish while
# the exit code reflects only the ones before it
@test "watch: a marker that stops the reader mid-file does not shrink the table silently" {
  # The partial form of the same defect: the reader stops at the bad
  # marker, and every pin after it vanishes from the report while the
  # exit code reflects only the pins before it.
  _release owner/foo v1.0.0
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=v1.0.0' \
    '# tool-pin: bar github-release owner/bar latest=9' \
    'ARG BAR_VERSION=1.0.0'
  _check --report
  assert_equal "${status}" 1
  refute_output --partial 'CURRENT (1)'
}

# why: The floor the lint already had and this did not: a walk that found nothing
# is the case that actually comes back looking clean
@test "watch: a tree that yields files but no pin exits 1" {
  # The floor the lint already has and this did not. `pin_coverage.sh`
  # dies when the table yields no PINNED entry, with the rationale that a
  # table with no pins makes every watch run come back clean -- but this
  # is the thing that actually comes back clean. A tree the reader walked
  # and found nothing in printed DRIFTED (0) / UNRESOLVED (0) /
  # FLOATING (0) / CURRENT (0) and exited 0: `count=0` in the workflow,
  # the bump skipped, the job green.
  _reset_tree
  printf 'echo hi\n' > "${SCRATCH}/tree/a.sh"
  _check --report
  assert_equal "${status}" 1
  assert_output --partial 'NOTHING was compared'
}

# why: The floor has to hold on the machine path too -- an empty TSV with status 0
# is the same silent clean week the report path refuses
@test "watch: the no-pin floor also refuses to emit a machine answer" {
  _reset_tree
  printf 'echo hi\n' > "${SCRATCH}/tree/a.sh"
  _stage
  PATH="${SCRATCH}/bin:${PATH}" PIN_REPO_ROOT="${SCRATCH}/tree" \
    WATCH_GITHUB_API="${API}" run --separate-stderr "${CHECK}" --drift-tsv
  assert_equal "${status}" 1
  assert_output ''
}

# why: A scan root of pure prose is the other way to reach an empty table, and it
# must not read as up to date either
@test "watch: a tree with nothing scannable in it exits 1" {
  _reset_tree doc
  printf 'hello\n' > "${SCRATCH}/tree/doc/a.md"
  _check --report
  assert_equal "${status}" 1
  assert_output --partial 'NOTHING was compared'
}

# why: The workflow builds its matrix from this stdout, so an empty list with a
# zero status is precisely the silent clean week
@test "watch: --drift-tsv emits no machine answer when the table is unreadable" {
  # The workflow builds its matrix from this stdout. Emitting an empty
  # list with a zero status is precisely the silent-clean-week outcome.
  _dockerfile \
    '# tool-pin: broken github-release owner/broken latest=9' \
    'ARG BROKEN_VERSION=1.0.0'
  _stage
  PATH="${SCRATCH}/bin:${PATH}" PIN_REPO_ROOT="${SCRATCH}/tree" \
    WATCH_GITHUB_API="${API}" run --separate-stderr "${CHECK}" --drift-tsv
  assert_equal "${status}" 1
  assert_output ''
}

# why: The machine answer and the human report share one run, so a report line
# landing on stdout would corrupt the matrix
@test "watch: --drift-tsv puts the drifted pins on stdout, the report on stderr" {
  _release owner/foo v2.0.0
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=1.0.0'
  _stage
  PATH="${SCRATCH}/bin:${PATH}" PIN_REPO_ROOT="${SCRATCH}/tree" \
    WATCH_GITHUB_API="${API}" run --separate-stderr "${CHECK}" --drift-tsv
  assert_equal "${status}" 10
  assert_output --partial $'foo\t1.0.0\tv2.0.0\t'
  [[ "${stderr}" == *'upstream-release watch'* ]]
}

# ════════════════════════════════════════════════════════════════════
# Usage
# ════════════════════════════════════════════════════════════════════

# why: Exit 2 keeps a typo apart from 1 (nothing compared) and 10 (drift), which
# is what the workflow branches on
@test "watch: an unknown option is a usage error, distinct from both" {
  _dockerfile 'FROM scratch'
  _check --nonsense
  assert_equal "${status}" 2
  assert_output --partial 'unknown option'
}
