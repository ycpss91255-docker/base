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

# _golang_tree <go.mod line>... -- the scanned tree for the go.mod cases:
# the golang pin marker and the line under it, copied from
# dockerfile/Dockerfile.config-gen, a Docker Hub fixture that answers that
# pin, and the module at dockerfile/config-gen/go.mod.
_golang_tree() {
  printf '%s\n' \
    '# tool-pin: golang dockerhub library/golang pattern=^1\.[0-9]+\.[0-9]+-trixie$' \
    'ARG GO_IMAGE=golang:1.27.2-trixie@sha256:47667934874913a449b96faa7ef4777fa285d9ec29126ee80ed61c45b7cccf0e' \
    > "${SCRATCH}/tree/dockerfile/Dockerfile.config-gen"
  mkdir -p "${SCRATCH}/hub/repositories/library/golang" "${SCRATCH}/tree/dockerfile/config-gen"
  printf '{"results": [{"name": "1.27.2-trixie"}]}\n' \
    > "${SCRATCH}/hub/repositories/library/golang/tags?page_size=100"
  printf '%s\n' "$@" > "${SCRATCH}/tree/dockerfile/config-gen/go.mod"
}

# _check_json <arg>... -- check.sh over the staged tree with JSON logs, its
# stdout and stderr judged apart (assert_refusal), the Docker Hub resolver
# pointed at the _golang_tree fixture.
_check_json() {
  _stage
  PATH="${SCRATCH}/bin:${PATH}" PIN_REPO_ROOT="${SCRATCH}/tree" LOG_FORMAT=json \
    WATCH_GITHUB_API="${API}" WATCH_DOCKERHUB_API="file://${SCRATCH}/hub" \
    run --separate-stderr "${CHECK}" "$@"
}

# why: The refusal cases below prove that a go.mod the reader cannot read
# stops the watch; without a go.mod the watch DOES read, a check that
# refused every go.mod would pass all of them. A marked BurntSushi/toml
# require at v1.5.0, line form, under a stubbed upstream v1.6.0, is drift:
# exit 10 and the one machine row naming both versions and the require's
# file and line (base#1440).
@test "watch: a go.mod require behind its upstream is drift, line form (base#1440)" {
  _release BurntSushi/toml v1.6.0
  _golang_tree 'module example.com/m' '' 'go 1.27' '' \
    '// tool-pin: toml github-release BurntSushi/toml' \
    'require github.com/BurntSushi/toml v1.5.0 // keep me'
  _check_json --drift-tsv
  assert_equal "${status}" 10
  assert_output $'toml\tv1.5.0\tv1.6.0\tdockerfile/config-gen/go.mod\t6'
  [[ "${stderr}" == *'DRIFTED (1)'* ]] || fail "no DRIFTED (1): ${stderr}"
}

# why: The block form is what `go get` writes; its entry has no `require`
# on its line, so a watch that read only the line form would miss it.
# Same drift, block form: the row names the entry's own line (base#1440).
@test "watch: a go.mod require behind its upstream is drift, block form (base#1440)" {
  _release BurntSushi/toml v1.6.0
  _golang_tree 'module example.com/m' '' 'go 1.27' '' 'require (' \
    '	// tool-pin: toml github-release BurntSushi/toml' \
    '	github.com/BurntSushi/toml v1.5.0 // keep me' ')'
  _check_json --drift-tsv
  assert_equal "${status}" 10
  assert_output $'toml\tv1.5.0\tv1.6.0\tdockerfile/config-gen/go.mod\t7'
  [[ "${stderr}" == *'DRIFTED (1)'* ]] || fail "no DRIFTED (1): ${stderr}"
}

# _curl_logged -- the fixture curl, with every call logged to curl.log.
_curl_logged() {
  : > "${SCRATCH}/curl.log"
  mv "${SCRATCH}/bin/curl" "${SCRATCH}/bin/curl.real"
  printf '#!/bin/sh\necho "curl $*" >> %s\nexec %s "$@"\n' \
    "${SCRATCH}/curl.log" "${SCRATCH}/bin/curl.real" > "${SCRATCH}/bin/curl"
  chmod +x "${SCRATCH}/bin/curl"
}

# _assert_watch_refused <event> <line> <reason> -- after _curl_logged and
# _check_json --report on a _golang_tree whose go.mod the reader refuses:
# exit 1, the event by name with the go.mod and the line, NOTHING was
# compared, no report row on stdout, and no upstream asked.
_assert_watch_refused() {
  assert_refusal 1 "${1}" \
    "file=${SCRATCH}/tree/dockerfile/config-gen/go.mod" "line=${2}" "reason=${3}"
  [[ "${stderr}" == *'NOTHING was compared'* ]] || fail "no NOTHING was compared: ${stderr}"
  assert_equal "$(cat "${SCRATCH}/curl.log")" ''
}

# why: An indirect requirement in a go.mod is refused by the reader
# (base#1463); the watch must not read past it into a clean week. The
# refusal is the indirect one by name, with its line, not any exit 1: the
# same tree with the comment changed is the drift case above (base#1440).
@test "watch: a go.mod with an indirect requirement is go_mod_indirect_requirement (base#1463)" {
  _curl_logged
  _release BurntSushi/toml v1.6.0
  _golang_tree 'module example.com/m' '' 'go 1.27' '' \
    '// tool-pin: toml github-release BurntSushi/toml' \
    'require github.com/BurntSushi/toml v1.5.0 // indirect'
  _check_json --report
  _assert_watch_refused go_mod_indirect_requirement 6 indirect
}

# why: The reader scans every tracked go.mod, not only one a marker points
# into, and its scanner's refusal ends the run. Here no marker names a
# require, so only that status stops the reader: one that dropped it would
# read on, and the go directive check would scan the go.mod again and
# repeat the refusal. The refusal is logged once (base#1440).
@test "watch: an unmarked go.mod with an indirect requirement is refused once, by the reader (base#1440)" {
  _curl_logged
  _release BurntSushi/toml v1.6.0
  _golang_tree 'module example.com/m' '' 'go 1.27' '' \
    'require github.com/BurntSushi/toml v1.5.0 // indirect'
  _check_json --report
  _assert_watch_refused go_mod_indirect_requirement 5 indirect
  assert_equal "$(grep -c '"body":"go_mod_indirect_requirement"' <<< "${stderr}")" 1
}

# why: A replace directive changes which version builds, so the require
# the marker names is not the one Go uses; the reader refuses it, and the
# watch with it, by name and line (base#1440).
@test "watch: a go.mod with a replace directive is go_mod_unsupported_syntax (base#1440)" {
  _curl_logged
  _release BurntSushi/toml v1.6.0
  _golang_tree 'module example.com/m' '' 'go 1.27' '' \
    '// tool-pin: toml github-release BurntSushi/toml' \
    'require github.com/BurntSushi/toml v1.5.0' '' \
    'replace github.com/BurntSushi/toml => github.com/BurntSushi/toml v1.4.0'
  _check_json --report
  _assert_watch_refused go_mod_unsupported_syntax 8 replace
}

# why: A require block with no closing paren is a go.mod Go rejects; the
# reader refuses it at the line that opens the block, and the watch with
# it (base#1440).
@test "watch: a go.mod with an unterminated require block is go_mod_unsupported_syntax (base#1440)" {
  _curl_logged
  _release BurntSushi/toml v1.6.0
  _golang_tree 'module example.com/m' '' 'go 1.27' '' 'require (' \
    '	// tool-pin: toml github-release BurntSushi/toml' \
    '	github.com/BurntSushi/toml v1.5.0'
  _check_json --report
  _assert_watch_refused go_mod_unsupported_syntax 5 unterminated_block
}

# why: A go.mod `go` directive names the Go a module needs and the golang
# pin the Go that builds it; the watch compared neither, so `go 1.26` under
# golang:1.27.2 read as a clean week. The directive is checked against the
# pin before any upstream is asked: the run is refused by name with both
# sides and the directive's line, and no resolver is called (base#1440).
@test "watch: a go 1.26 go.mod under golang:1.27.2 exits 1 before any resolver runs (base#1440)" {
  local _log="${SCRATCH}/curl.log"
  : > "${_log}"
  printf '#!/bin/sh\necho "curl $*" >> %s\nexit 22\n' "${_log}" > "${SCRATCH}/bin/curl"
  _release owner/foo v1.0.0
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=v1.0.0'
  printf '%s\n' \
    '# tool-pin: golang dockerhub library/golang pattern=^1\.[0-9]+\.[0-9]+-trixie$' \
    'ARG GO_IMAGE=golang:1.27.2-trixie@sha256:47667934874913a449b96faa7ef4777fa285d9ec29126ee80ed61c45b7cccf0e' \
    > "${SCRATCH}/tree/dockerfile/Dockerfile.config-gen"
  mkdir -p "${SCRATCH}/tree/dockerfile/config-gen"
  printf '%s\n' 'module example.com/m' '' 'go 1.26' \
    > "${SCRATCH}/tree/dockerfile/config-gen/go.mod"
  _stage
  PATH="${SCRATCH}/bin:${PATH}" PIN_REPO_ROOT="${SCRATCH}/tree" LOG_FORMAT=json \
    WATCH_GITHUB_API="${API}" run --separate-stderr "${CHECK}" --report
  assert_refusal 1 go_mod_go_directive_mismatch \
    file=dockerfile/config-gen/go.mod line=3 go=1.26 golang=1.27
  [[ "${stderr}" == *'NOTHING was compared'* ]] || fail "no NOTHING was compared: ${stderr}"
  assert_equal "$(cat "${_log}")" ''
}

# why: An unreadable tracked file used to print `Permission denied` and leave
# the reader's status 0, so the watch reported the rest as a clean week
# (base#1463). As root the run drops to nobody, the only user a mode-000
# file applies to.
@test "watch: an unreadable tracked file exits 1, not 0 (base#1463)" {
  _release owner/foo v1.0.0
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=v1.0.0'
  printf 'x\n' > "${SCRATCH}/tree/.a.txt"
  _stage
  chmod 000 "${SCRATCH}/tree/.a.txt"
  local _cmd="export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*' PATH='${SCRATCH}/bin:${PATH}' PIN_REPO_ROOT='${SCRATCH}/tree' WATCH_GITHUB_API='${API}'; '${CHECK}' --report"
  if (( EUID == 0 )); then
    su -s /bin/bash nobody -c true 2>/dev/null \
      || skip "running as root and cannot drop to nobody, so no unreadable file can be staged"
    chmod -R a+rX "${SCRATCH}"
    chmod 000 "${SCRATCH}/tree/.a.txt"
    run su -s /bin/bash nobody -c "${_cmd}"
  else
    run bash -c "${_cmd}"
  fi
  assert_equal "${status}" 1
  refute_output --partial 'CURRENT (1)'
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
