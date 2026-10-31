#!/usr/bin/env bats
#
# Unit tests for script/watch/lib.sh + script/watch/pins.sh -- the pin
# registry the upstream-release watch reads.
#
# What is under test is the DERIVATION, not a roster. There is no list of
# watched tools anywhere in this repo: every watched version carries a
# `tool-pin:` marker on the line that declares it, and the table is
# whatever those markers say today. So the cases below are about the
# reader's contract -- what is a marker, what is its target, what version
# does that target carry -- plus the one edit a bump consists of
# (`--set`), because the scheduled workflow performs it unattended and a
# rewrite that silently does not take would produce a green proposal that
# changed nothing.
#
# Shape mirrors self_hosted_guard_lint_spec.bats: a controlled scratch
# tree for the rules, and a final section that drives the REAL tree.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # The suite container's host-computed handoff is left in place on
  # purpose. It is keyed to the root it describes (/source), so it cannot
  # reach a scratch tree -- and the real-tree cases at the bottom of this
  # file are the ones that read it, which is the only in-container
  # exercise the handoff gets.
  PINS="/source/script/watch/pins.sh"
  SCRATCH="$(mktemp -d)"
  # The reader's population is what the tree TRACKS, so the fixture is a
  # real repository. `_pins` stages it before every invocation.
  git -C "${SCRATCH}" init -q
  mkdir -p "${SCRATCH}/dockerfile" "${SCRATCH}/dist/dockerfile" \
           "${SCRATCH}/.github/workflows"
  # The reader walks the whole tree by shape, so these paths are a
  # convenience that mirrors the real repo rather than a requirement. The
  # one thing that IS required is that the tree yield at least one file of
  # a scanned shape; a tree that yields none is the vacuity case below.
  printf 'FROM scratch\n' > "${SCRATCH}/dist/dockerfile/Dockerfile"
  printf 'name: x\non:\n  push:\n' > "${SCRATCH}/.github/workflows/x.yaml"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _dockerfile <line>... -- write the scratch test-tools Dockerfile.
_dockerfile() {
  printf '%s\n' "$@" > "${SCRATCH}/dockerfile/Dockerfile.test-tools"
}

# _workflow <line>... -- write the scratch workflow.
_workflow() {
  printf '%s\n' "$@" > "${SCRATCH}/.github/workflows/x.yaml"
}

_pins() {
  git -C "${SCRATCH}" add -A
  PIN_REPO_ROOT="${SCRATCH}" run "${PINS}" "$@"
}

# ════════════════════════════════════════════════════════════════════
# What is a marker
# ════════════════════════════════════════════════════════════════════

# why: The grammar's one structural rule -- comments and blanks are skipped, so a
# marker can be documented above the line it claims
@test "pins: a marker's target is the next non-comment, non-blank line" {
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    '# an intervening comment' \
    '' \
    'ARG FOO_VERSION=1.2.3'
  _pins --list
  assert_success
  assert_output --partial $'pinned\tfoo\tgithub-release\towner/foo'
  assert_output --partial $'1.2.3\tdockerfile/Dockerfile.test-tools\t4'
}

# why: The convention must be documentable inside the trees it scans, and a
# substring match would make every mention a marker with the wrong target
@test "pins: PROSE that merely mentions the marker token is not a marker" {
  # The convention has to be documentable inside the very trees it scans:
  # the Dockerfile header explains it, this file quotes it, and the lint's
  # failure message prints it. A substring match would turn every one of
  # those into a marker with the wrong target.
  _dockerfile \
    '# Every version below carries a `tool-pin:` marker naming its upstream.' \
    'ARG FOO_VERSION=1.2.3' \
    '# tool-pin: foo github-release owner/foo' \
    'ARG BAR_VERSION=4.5.6'
  _pins --list
  assert_success
  assert_output --partial $'pinned\tfoo\tgithub-release\towner/foo'
  refute_output --partial 'Every version below'
  # Exactly one record: the prose line produced none.
  [[ "$(printf '%s\n' "${output}" | grep -c 'pinned') " == "1 " ]]
}

# why: A marker claiming nothing is a pin its author believes is watched; that
# belief is the state the whole mechanism exists to remove
@test "pins: a marker with no target line after it FAILS" {
  _dockerfile \
    'ARG FOO_VERSION=1.2.3' \
    '# tool-pin: foo github-release owner/foo'
  _pins --list
  assert_failure
  assert_output --partial 'has no target line after it'
}

# why: Both would claim one line and only the first would ever be read -- a pin
# that looks declared and is not watched
@test "pins: two markers with no target between them FAIL" {
  # Both would otherwise claim one line and only the first would ever be
  # read -- a pin that looks declared and is not watched.
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    '# tool-pin: bar github-release owner/bar' \
    'ARG FOO_VERSION=1.2.3'
  _pins --list
  assert_failure
  assert_output --partial 'marker follows another with no target between them'
}

# why: A pinned marker with no coordinate can never be compared, so accepting it
# would put an uncheckable row in the table
@test "pins: a pinned marker naming no coordinate FAILS" {
  _dockerfile \
    '# tool-pin: foo github-release' \
    'ARG FOO_VERSION=1.2.3'
  _pins --list
  assert_failure
  assert_output --partial 'names no resolver and coordinate'
}

# why: An unknown option is a typo in the one line that says how to watch a pin,
# and a typo caught weeks later is weeks of not watching
@test "pins: a marker carrying an unknown option FAILS" {
  _dockerfile \
    '# tool-pin: foo github-release owner/foo latest=9' \
    'ARG FOO_VERSION=1.2.3'
  _pins --list
  assert_failure
  assert_output --partial 'unknown option latest=9'
}

# why: A marker whose target holds no version is a declaration with nothing to
# compare, which reads as watched and is not
@test "pins: a pinned marker whose target carries no version FAILS" {
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'RUN echo hello'
  _pins --list
  assert_failure
  assert_output --partial 'no version for owner/foo on its target line'
}

# why: unpinned is a declaration that the dependency floats, not an off switch, so
# it must produce a record rather than nothing
@test "pins: an unpinned marker records the dependency and no version" {
  _dockerfile \
    '# tool-pin: unpinned apk-packages -- bounded by the alpine pin' \
    'RUN apk add --no-cache bash git'
  _pins --list
  assert_success
  assert_output --partial $'unpinned\tapk-packages'
}

# why: Where the target IS an assignment, an empty value column throws away the one
# fact the record could carry -- the generated-workflow lint needs it
@test "pins: an unpinned marker on an assignment records the value it declares" {
  # An `unpinned` marker says "this dependency floats", not "this line
  # holds nothing". Where the target IS an assignment the reader can
  # already extract the right-hand side from, leaving the value column
  # empty throws away the one fact the record could carry -- and the
  # generated-workflow lint needs exactly that fact to answer "what does
  # this variable hold" without re-deriving it from the file.
  _dockerfile \
    '# tool-pin: unpinned downstream-checkout -- a major ref on purpose' \
    "readonly _MONITOR_REF='actions/checkout@v7'"
  _pins --list
  assert_success
  assert_output --partial $'unpinned\tdownstream-checkout'
  assert_output --partial $'actions/checkout@v7\tdockerfile/Dockerfile.test-tools\t2'
}

# why: The other side of that rule: an unpinned marker carries no coordinate to
# anchor on, so guessing a token would put a fabricated version in the table
@test "pins: an unpinned marker on a NON-assignment still records no value" {
  # The other side of that rule. `RUN apk add ...` names no single value,
  # and an unpinned marker carries no coordinate to anchor an extraction
  # on, so guessing a token off the line would put a fabricated version in
  # the table. `-` is the honest column.
  _dockerfile \
    '# tool-pin: unpinned apk-packages -- bounded by the alpine pin' \
    'RUN apk add --no-cache bash git'
  _pins --list
  assert_success
  assert_output --partial $'unpinned\tapk-packages\t-\t-\t-\t-\t-\t'
}

# why: An unnamed floating dependency cannot be reported on, which is the whole
# point of recording it
@test "pins: an unpinned marker that names no dependency FAILS" {
  _dockerfile \
    '# tool-pin: unpinned -- no name at all' \
    'RUN apk add --no-cache bash'
  _pins --list
  assert_failure
  assert_output --partial 'names no dependency'
}

# why: These are per-pin properties of the upstream; dropped from the table they
# silently become "compare every tag, refuse nothing"
@test "pins: pattern= and skip= are carried through to the table" {
  _dockerfile \
    '# tool-pin: alp dockerhub library/alpine pattern=^[0-9]+\.[0-9]+$ skip=3.24' \
    'ARG ALPINE_VERSION=3.21'
  _pins --list
  assert_success
  assert_output --partial '^[0-9]+\.[0-9]+$'
  assert_output --partial $'\t3.24\t3.21\t'
}

# ════════════════════════════════════════════════════════════════════
# Version extraction: the two target shapes
# ════════════════════════════════════════════════════════════════════

# why: The ARG shape is the majority of this repo's pins, and quoting must not
# become part of the version a branch name and CI are built from
@test "pins: an ARG target yields its right-hand side, unquoted" {
  _dockerfile \
    '# tool-pin: base dockerhub library/ubuntu pattern=.' \
    'ARG BASE_IMAGE="ubuntu:24.04"'
  _pins --value base
  assert_success
  assert_output 'ubuntu:24.04'
}

# why: Anchoring on the coordinate is what keeps extraction precise on a line
# carrying flags, paths and other colons
@test "pins: a non-ARG target yields the token after the coordinate" {
  # Anchoring on the coordinate is what keeps extraction precise on a line
  # that also carries flags, paths and other colons.
  _workflow \
    'jobs:' \
    '  a:' \
    '    steps:' \
    '      - env:' \
    '          # tool-pin: actionlint dockerhub rhysd/actionlint pattern=.' \
    '          IMAGE: rhysd/actionlint:1.7.7'
  _pins --value actionlint
  assert_success
  assert_output '1.7.7'
}

# why: A name that declares no version has no answer to give, and an empty answer
# would be read by a caller as a version
@test "pins: --value refuses a name declared unpinned" {
  _dockerfile \
    '# tool-pin: unpinned apk-packages -- no version to name' \
    'RUN apk add --no-cache bash'
  _pins --value apk-packages
  assert_failure
  assert_output --partial 'names no version'
}

# why: A typo in a pin name must fail rather than resolve to nothing, which a
# caller would substitute into a URL or a branch name
@test "pins: --value refuses a name nothing declares" {
  _dockerfile '# nothing here'
  _pins --value ghost
  assert_failure
  assert_output --partial 'no pin named ghost'
}

# ════════════════════════════════════════════════════════════════════
# --set: the one edit a bump consists of
# ════════════════════════════════════════════════════════════════════

# why: --set is the whole of a bump, and rebuilding the line would drop the quoting
# the Dockerfile relies on
@test "pins: --set rewrites an ARG and preserves its quoting" {
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION="v1.2.3"' \
    'RUN echo "${FOO_VERSION}"'
  _pins --set foo v2.0.0
  assert_success
  run grep -F 'ARG FOO_VERSION="v2.0.0"' \
    "${SCRATCH}/dockerfile/Dockerfile.test-tools"
  assert_success
}

# why: A blind file-wide substitution rewrites a URL that happens to carry the old
# version; the pin is a line, not a string
@test "pins: --set leaves every other line of the file alone" {
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=1.2.3' \
    'RUN curl -o /x "https://example.invalid/1.2.3/x"'
  _pins --set foo 2.0.0
  assert_success
  # The URL happens to contain the old version. A blind file-wide
  # substitution would have rewritten it too.
  run grep -F 'https://example.invalid/1.2.3/x' \
    "${SCRATCH}/dockerfile/Dockerfile.test-tools"
  assert_success
}

# why: An image tag is the other target shape a bump must rewrite, and it lives on
# its own line inside a nested YAML block
@test "pins: --set rewrites an image tag in place, on its own line" {
  _workflow \
    'jobs:' \
    '  a:' \
    '    steps:' \
    '      - env:' \
    '          # tool-pin: actionlint dockerhub rhysd/actionlint pattern=.' \
    '          IMAGE: rhysd/actionlint:1.7.7' \
    '        run: docker run --rm "${IMAGE}" -color'
  _pins --set actionlint 1.7.12
  assert_success
  run grep -F 'IMAGE: rhysd/actionlint:1.7.12' \
    "${SCRATCH}/.github/workflows/x.yaml"
  assert_success
}

# why: A bump run twice must not report a change it did not make, or the workflow
# opens a proposal with an empty diff
@test "pins: --set is a no-op when the pin already names that version" {
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=1.2.3'
  _pins --set foo 1.2.3
  assert_success
  assert_output --partial 'already 1.2.3'
}

# why: The from/to and the site are what a reviewer of a proposal reads first, and
# they are the only record of what the bump touched
@test "pins: --set reports the from/to and where it wrote" {
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=1.2.3'
  _pins --set foo 1.3.0
  assert_success
  assert_output --partial 'foo 1.2.3 -> 1.3.0'
  assert_output --partial 'dockerfile/Dockerfile.test-tools:2'
}

# why: There is no version to set on a floating dependency, so a silent success
# would report a bump nobody performed
@test "pins: --set refuses a name declared unpinned" {
  _dockerfile \
    '# tool-pin: unpinned apk-packages -- no version to set' \
    'RUN apk add --no-cache bash'
  _pins --set apk-packages 1.0
  assert_failure
  assert_output --partial 'there is no version to set'
}

# why: That trailing comment is where a "held at this version because" rationale
# lives -- the one sentence a reviewer of a bump most needs
@test "pins: --set keeps the trailing comment on the line it rewrites" {
  # That comment is where a "held at this version because ..." rationale
  # lives, and it is the one sentence a reviewer of a bump proposal most
  # needs to still be able to read. Rebuilding the line from the `NAME=`
  # prefix alone deletes it silently.
  _dockerfile \
    '# tool-pin: hadolint github-release hadolint/hadolint' \
    'ARG HADOLINT_VERSION=v2.12.0  # held: 2.13 rejects our DL3059 usage'
  _pins --set hadolint v2.15.1
  assert_success
  run grep -F \
    'ARG HADOLINT_VERSION=v2.15.1  # held: 2.13 rejects our DL3059 usage' \
    "${SCRATCH}/dockerfile/Dockerfile.test-tools"
  assert_success
}

# why: A stray space does not stay local: it flows into the reported from, into the
# branch name a bump builds, and into whatever CI feeds from --value
@test "pins: a trailing comment does not leak whitespace into the version" {
  # The stray space does not stay local: it flows into the reported
  # `from`, into the branch name a bump builds, and into whatever CI feeds
  # from `--value`.
  _dockerfile \
    '# tool-pin: hadolint github-release hadolint/hadolint' \
    'ARG HADOLINT_VERSION=v2.12.0  # held for now'
  _pins --value hadolint
  assert_success
  assert_output 'v2.12.0'
}

# why: mktemp creates 0600 and mv carries that mode onto the file -- invisible in
# CI and a permission denied on the next local just test
@test "pins: --set leaves the file's mode alone" {
  # `mktemp` creates 0600 and `mv` carries that mode onto whatever it
  # lands on. Invisible in the bump job (fresh checkout, git records
  # 100644) and a "permission denied" on the next `just test` for anyone
  # who runs the bump on their own machine.
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=1.2.3'
  chmod 664 "${SCRATCH}/dockerfile/Dockerfile.test-tools"
  _pins --set foo 1.3.0
  assert_success
  run stat -c '%a' "${SCRATCH}/dockerfile/Dockerfile.test-tools"
  assert_output '664'
}

# _gomod <line>... -- write the scratch config-gen go.mod.
_gomod() {
  mkdir -p "${SCRATCH}/dockerfile/config-gen"
  printf '%s\n' "$@" > "${SCRATCH}/dockerfile/config-gen/go.mod"
}

# why: The reader registers a go.mod require as a pin (base#1463), so a bump
# must be able to rewrite it; the assignment and coordinate:version rewrites
# never match `require <path> <version>` (review round 2). The version token
# the scanner read is replaced in place: spacing and comment kept.
@test "pins: --set rewrites a go.mod require, line form, keeping its comment (base#1463)" {
  _gomod 'module example.com/m' '' 'go 1.27' '' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.21.0 // held: v0.21.0 is the last for go 1.22'
  _pins --set xmod v0.22.0
  assert_success
  run sed -n 6p "${SCRATCH}/dockerfile/config-gen/go.mod"
  assert_output 'require golang.org/x/mod v0.22.0 // held: v0.21.0 is the last for go 1.22'
  _pins --value xmod
  assert_output v0.22.0
}

# why: The block form is what `go get` writes; the entry has no verb on its
# line, so a rewrite keyed on `require` would miss it.
@test "pins: --set rewrites a go.mod require, block form (base#1463)" {
  _gomod 'module example.com/m' '' 'require (' \
    '	// tool-pin: xmod github-release golang/mod' \
    '	golang.org/x/mod v0.21.0' ')'
  _pins --set xmod v0.22.0
  assert_success
  run sed -n 5p "${SCRATCH}/dockerfile/config-gen/go.mod"
  assert_output $'\tgolang.org/x/mod v0.22.0'
}

# why: A quoted version is read without its quotes; the rewrite keeps them.
@test "pins: --set rewrites a quoted go.mod version and keeps the quotes (base#1463)" {
  _gomod 'module example.com/m' \
    '// tool-pin: xmod github-release golang/mod' \
    'require "golang.org/x/mod" "v0.21.0"'
  _pins --set xmod v0.22.0
  assert_success
  run sed -n 3p "${SCRATCH}/dockerfile/config-gen/go.mod"
  assert_output 'require "golang.org/x/mod" "v0.22.0"'
}

# why: A version Go would rewrite (`v0.22` -> `v0.22.0`) is refused before
# the file is touched, so a bump cannot write a pin the reader then refuses.
@test "pins: --set refuses a go.mod version Go would rewrite and leaves the file alone (base#1463)" {
  _gomod 'module example.com/m' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.21.0'
  local _f="${SCRATCH}/dockerfile/config-gen/go.mod"
  chmod 664 "${_f}"
  _snapshot "${_f}"
  _pins_json --set xmod v0.22
  assert_refusal 1 pin_set_refused "file=${_f}" line=3 reason=version_noncanonical
  _assert_unchanged "${_f}"
}

# why: An empty quoted path once shifted the comment into the version column,
# so --list printed current=`// note` with rc 0 (review round 2, base#1463).
@test "pins: --list refuses a go.mod require with an empty path (base#1463)" {
  _gomod 'module example.com/m' \
    '// tool-pin: x github-release golang/mod' \
    'require "" v1.0.0 // note'
  _pins_json --list
  assert_refusal 1 go_mod_unsupported_syntax \
    "file=${SCRATCH}/dockerfile/config-gen/go.mod" line=3 reason=path_empty
}

# _pins_json <arg>... -- _pins with JSON logs and stdout and stderr judged
# apart, for the refusal cases (assert_refusal). A command _stub put on
# ${STUB_BIN} is first on pins.sh's PATH, and on nothing else's: bats'
# own `run` needs a working mktemp.
_pins_json() {
  git -C "${SCRATCH}" add -A
  _pins_json_unstaged "$@"
}

# _pins_json_unstaged <arg>... -- _pins_json without staging the tree.
_pins_json_unstaged() {
  run --separate-stderr env PATH="${STUB_BIN:+${STUB_BIN}:}${PATH}" \
    PIN_REPO_ROOT="${SCRATCH}" LOG_FORMAT=json "${PINS}" "$@"
}

# _snapshot <file> -- record the file's bytes, its mode and its directory's
# listing; _assert_unchanged <file> holds the file to that record.
_snapshot() {
  mkdir -p "${BATS_TEST_TMPDIR}/snap"
  cp -- "${1}" "${BATS_TEST_TMPDIR}/snap/bytes"
  stat -c '%a' -- "${1}" > "${BATS_TEST_TMPDIR}/snap/mode"
  ls -A -- "$(dirname -- "${1}")" > "${BATS_TEST_TMPDIR}/snap/dir"
}

# _assert_unchanged <file> -- the bytes and the mode _snapshot recorded, and
# no file left beside it (a refused bump leaves no temp copy behind).
_assert_unchanged() {
  cmp -s -- "${BATS_TEST_TMPDIR}/snap/bytes" "${1}" \
    || fail "the bytes of ${1} changed: $(od -c -- "${1}" | head -n 20)"
  assert_equal "$(stat -c '%a' -- "${1}")" "$(cat "${BATS_TEST_TMPDIR}/snap/mode")"
  assert_equal "$(ls -A -- "$(dirname -- "${1}")")" "$(cat "${BATS_TEST_TMPDIR}/snap/dir")"
}

# _stub <command> <exit> -- a <command> on ${STUB_BIN} that prints nothing
# and exits <exit>, standing in for a step of the commit that fails.
_stub() {
  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${STUB_BIN}"
  printf '#!/bin/sh\nexit %s\n' "${2}" > "${STUB_BIN}/${1}"
  chmod +x "${STUB_BIN}/${1}"
}

# _foo_pin -- a Dockerfile pin with a line after it, mode 664, snapshotted.
_foo_pin() {
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=1.2.3' \
    'RUN true'
  chmod 664 "${SCRATCH}/dockerfile/Dockerfile.test-tools"
  _snapshot "${SCRATCH}/dockerfile/Dockerfile.test-tools"
}

# why: The rewritten line once went through `awk -v repl=...`, which
# expands backslash escapes, so a preserved comment holding `\n` was split
# into two lines and the go.mod corrupted before the read-back ran (review
# round 3, base#1463). The line is written byte for byte.
@test "pins: --set keeps a literal backslash in a go.mod comment byte for byte (base#1463)" {
  _gomod 'module example.com/m' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.21.0 // literal \n text \\ end' \
    'require golang.org/x/net v0.30.0'
  _pins --set xmod v0.22.0
  assert_success
  run cat "${SCRATCH}/dockerfile/config-gen/go.mod"
  assert_output "$(printf '%s\n' 'module example.com/m' \
    '// tool-pin: xmod github-release golang/mod' \
    'require golang.org/x/mod v0.22.0 // literal \n text \\ end' \
    'require golang.org/x/net v0.30.0')"
  assert_equal "$(wc -l < "${SCRATCH}/dockerfile/config-gen/go.mod")" 4
}

# why: The same awk carried every rewrite, so a Dockerfile comment with a
# backslash was mangled the same way (base#1463).
@test "pins: --set keeps a literal backslash in a Dockerfile comment byte for byte (base#1463)" {
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=1.2.3  # held: C:\temp \t x' \
    'RUN true'
  _pins --set foo 1.3.0
  assert_success
  run cat "${SCRATCH}/dockerfile/Dockerfile.test-tools"
  assert_output "$(printf '%s\n' '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=1.3.0  # held: C:\temp \t x' 'RUN true')"
}

# why: The last line of a file with no final newline stays without one: the
# splice changes the version and nothing else (base#1463).
@test "pins: --set on a last line with no final newline adds none (base#1463)" {
  printf '# tool-pin: foo github-release owner/foo\nARG FOO_VERSION=1.2.3' \
    > "${SCRATCH}/dockerfile/Dockerfile.test-tools"
  _pins --set foo 1.3.0
  assert_success
  printf '# tool-pin: foo github-release owner/foo\nARG FOO_VERSION=1.3.0' \
    > "${BATS_TEST_TMPDIR}/want"
  cmp -- "${BATS_TEST_TMPDIR}/want" "${SCRATCH}/dockerfile/Dockerfile.test-tools" \
    || fail "the rewrite did not keep the missing final newline: $(od -c -- "${SCRATCH}/dockerfile/Dockerfile.test-tools")"
}

# why: A write through a symlink edits a file outside the tree the reader
# named; the bump refuses it by name and touches neither the link nor its
# target (base#1463). The reader takes only blobs from the index, so the
# link is the working-tree file under a path the index still records as
# a regular file -- staged first, then swapped for the link.
@test "pins: --set refuses a symlinked destination and leaves its target alone (base#1463)" {
  local _t="${BATS_TEST_TMPDIR}/ext/target"
  mkdir -p "${BATS_TEST_TMPDIR}/ext"
  _dockerfile '# tool-pin: foo github-release owner/foo' 'ARG FOO_VERSION=1.2.3'
  git -C "${SCRATCH}" add -A
  mv "${SCRATCH}/dockerfile/Dockerfile.test-tools" "${_t}"
  chmod 664 "${_t}"
  ln -s "${_t}" "${SCRATCH}/dockerfile/Dockerfile.test-tools"
  _snapshot "${_t}"
  _pins_json_unstaged --set foo 1.3.0
  assert_refusal 1 pin_set_refused \
    "file=${SCRATCH}/dockerfile/Dockerfile.test-tools" reason=symlink
  [[ -L "${SCRATCH}/dockerfile/Dockerfile.test-tools" ]] || fail "the symlink was replaced"
  _assert_unchanged "${_t}"
}

# why: Replacing one name of a hard-linked file splits the link and leaves
# the other name on the old version; refused by name (base#1463).
@test "pins: --set refuses a hard-linked destination and leaves it alone (base#1463)" {
  _foo_pin
  ln "${SCRATCH}/dockerfile/Dockerfile.test-tools" "${BATS_TEST_TMPDIR}/hardlink"
  _pins_json --set foo 1.3.0
  assert_refusal 1 pin_set_refused \
    "file=${SCRATCH}/dockerfile/Dockerfile.test-tools" reason=hard_link
  _assert_unchanged "${SCRATCH}/dockerfile/Dockerfile.test-tools"
}

# why: The temp copy lives beside the destination so the final mv is one
# rename; a directory that cannot hold it refuses before anything is
# written (base#1463).
@test "pins: --set that cannot create its temp copy leaves the file alone (base#1463)" {
  _foo_pin
  _stub mktemp 1
  _pins_json --set foo 1.3.0
  assert_refusal 1 pin_set_refused \
    "file=${SCRATCH}/dockerfile/Dockerfile.test-tools" reason=temp_create
  _assert_unchanged "${SCRATCH}/dockerfile/Dockerfile.test-tools"
}

# why: The injected write failure: a temp copy that could not be written is
# never moved over the destination (base#1463).
@test "pins: --set whose temp write fails leaves the file's bytes and mode alone (base#1463)" {
  _foo_pin
  _stub head 1
  _pins_json --set foo 1.3.0
  assert_refusal 1 pin_set_refused \
    "file=${SCRATCH}/dockerfile/Dockerfile.test-tools" reason=write_failed
  _assert_unchanged "${SCRATCH}/dockerfile/Dockerfile.test-tools"
}

# why: The temp copy is held to the splice before it lands: everything but
# the target line byte-identical, the target line exactly the new one. A
# write that exited 0 but lost the lines after the target (a `tail` that
# printed nothing) is refused, not moved into place (base#1463).
@test "pins: --set whose temp copy is not the exact splice leaves the file alone (base#1463)" {
  _foo_pin
  _stub tail 0
  _pins_json --set foo 1.3.0
  assert_refusal 1 pin_set_refused \
    "file=${SCRATCH}/dockerfile/Dockerfile.test-tools" reason=check_failed
  _assert_unchanged "${SCRATCH}/dockerfile/Dockerfile.test-tools"
}

# why: mktemp creates 0600; a copy whose mode could not be set to the
# destination's is not moved over it (base#1463).
@test "pins: --set that cannot carry the mode onto its temp copy leaves the file alone (base#1463)" {
  _foo_pin
  _stub chmod 1
  _pins_json --set foo 1.3.0
  assert_refusal 1 pin_set_refused \
    "file=${SCRATCH}/dockerfile/Dockerfile.test-tools" reason=mode_failed
  _assert_unchanged "${SCRATCH}/dockerfile/Dockerfile.test-tools"
}

# why: The rename is the commit; one that fails leaves the old file and no
# temp copy behind (base#1463).
@test "pins: --set whose final rename fails leaves the file alone (base#1463)" {
  _foo_pin
  _stub mv 1
  _pins_json --set foo 1.3.0
  assert_refusal 1 pin_set_refused \
    "file=${SCRATCH}/dockerfile/Dockerfile.test-tools" reason=commit_failed
  _assert_unchanged "${SCRATCH}/dockerfile/Dockerfile.test-tools"
}

# ════════════════════════════════════════════════════════════════════
# Scan roots
# ════════════════════════════════════════════════════════════════════

# why: An empty table read as "this repo declares no pins" is indistinguishable
# from a clean week, which is the one answer the watch must never guess
@test "pins: a tree yielding no scannable file at all FAILS" {
  # An empty table read as "this repo declares no pins" is the one answer
  # the watch must never give by accident: it is indistinguishable from a
  # clean week.
  rm -rf "${SCRATCH:?}"
  mkdir -p "${SCRATCH}/doc"
  git -C "${SCRATCH}" init -q
  printf 'hello\n' > "${SCRATCH}/doc/a.md"
  _pins --list
  assert_failure
  assert_output --partial 'no scannable file'
}

# why: The walk is every tracked file minus the exempt shapes, so what it actually
# opens is the claim worth checking rather than trusting
@test "pins: --files lists every file it walks, prose and specs aside" {
  _dockerfile 'FROM scratch'
  _pins --files
  assert_success
  assert_output --partial 'dockerfile/Dockerfile.test-tools'
  assert_output --partial 'dist/dockerfile/Dockerfile'
  assert_output --partial '.github/workflows/x.yaml'
}

# why: The scan surface is not a roster of directories; it decayed once already,
# with two live pins sitting outside the three original roots
@test "pins: a Dockerfile at a path nothing anticipated is still scanned" {
  # The scan surface is NOT a roster of directories. A hand-kept list of
  # places to look decays exactly the way a hand-kept list of tools does,
  # and it decayed here: two live third-party versions sat outside the
  # original three roots, one of them two minors behind this repo's own
  # pin, written into every downstream repo, with nothing reporting it.
  mkdir -p "${SCRATCH}/somewhere/new/deep"
  printf '%s\n' \
    '# tool-pin: newthing github-release owner/newthing' \
    'ARG NEWTHING_VERSION=1.0.0' \
    > "${SCRATCH}/somewhere/new/deep/Dockerfile.other"
  _pins --value newthing
  assert_success
  assert_output '1.0.0'
}

# why: A uses: ref inside a heredoc is not a workflow file, so nothing but this
# watch can ever see the versions a generator writes
@test "pins: a shell script that generates a file is a declaration site" {
  # dist/script/base/init.sh writes a workflow and dockerfile_migrate.sh
  # seds a downstream Dockerfile. dependabot reads workflow files, and a
  # `uses:` ref inside a heredoc is not one -- so nothing but this watch
  # can ever see those versions.
  mkdir -p "${SCRATCH}/dist/script"
  printf '%s\n' \
    '# tool-pin: gen-bats dockerhub bats/bats pattern=.' \
    "local _bats_tag='1.13.0'" \
    > "${SCRATCH}/dist/script/gen.sh"
  _pins --value gen-bats
  assert_success
  assert_output '1.13.0'
  _pins --set gen-bats 1.14.0
  assert_success
  run grep -F "local _bats_tag='1.14.0'" "${SCRATCH}/dist/script/gen.sh"
  assert_success
}

# why: Every version in a shipped release is supposed to be stale, so a bump inside
# .prev-release/ would be meaningless -- and nothing tracks it
@test "pins: an untracked tree contributes nothing" {
  # `.prev-release/` is `git archive` of PAST releases, materialised for a
  # spec. Every version in it is supposed to be stale, and a bump inside
  # it would be meaningless. It used to be named in a prune roster; it is
  # absent now because nothing tracks it, which is the same verdict with
  # nothing to keep up to date.
  _dockerfile 'FROM scratch'
  _pins --files
  assert_success
  mkdir -p "${SCRATCH}/.prev-release/v0.1.0/dockerfile"
  printf '%s\n' \
    '# tool-pin: ancient github-release owner/ancient' \
    'ARG ANCIENT_VERSION=0.0.1' \
    > "${SCRATCH}/.prev-release/v0.1.0/dockerfile/Dockerfile"
  PIN_REPO_ROOT="${SCRATCH}" run "${PINS}" --files
  assert_success
  refute_output --partial '.prev-release'
  PIN_REPO_ROOT="${SCRATCH}" run "${PINS}" --value ancient
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# The resolvers the lint accepts are the resolvers check.sh implements
# ════════════════════════════════════════════════════════════════════

# why: A resolver the lint accepts and check.sh does not implement blesses a pin
# that then fails weeks later, unattended
@test "pins: check.sh dispatches every resolver the registry declares" {
  # The lint rejects an unknown resolver at the declaration site, using
  # _PIN_RESOLVERS. If that table listed a resolver check.sh does not
  # implement, the lint would bless a pin the watch then fails on weeks
  # later, unattended.
  # shellcheck disable=SC1091
  source /source/script/watch/lib.sh
  local _r
  for _r in "${_PIN_RESOLVERS[@]}"; do
    run grep -F "    ${_r})" /source/script/watch/check.sh
    assert_success
  done
}

# ════════════════════════════════════════════════════════════════════
# The real tree
# ════════════════════════════════════════════════════════════════════

# why: Otherwise the workflow carries a fourth copy, and a bump moving only the
# Dockerfile leaves CI testing a different just than the image ships
@test "pins: the CI just install reads the pin instead of repeating it" {
  # Without this the workflow would carry a fourth copy of the number, and
  # a bump PR that moved the Dockerfile alone would leave CI testing a
  # different just than the image ships.
  #
  # The reader is the shipped accessor, not pins.sh: both read the
  # SAME line -- the `ARG JUST_VERSION` that the `tool-pin: just` marker
  # sits on is the marker's TARGET, so it is where the pin's value comes
  # from as well. CI resolving the number twice is therefore two chances
  # to disagree about one declaration, not two declarations. base#1075
  # removed the case this paragraph used to point at, which compared the
  # pin against that same ARG line and so asserted one line against
  # itself. What this test is about is that the workflow READS the number
  # rather than repeating it; which of the two readers it uses is not.
  run grep -F 'dist/script/base/just-version.sh' \
    /source/.github/workflows/self-test.yaml
  assert_success
  run grep -F 'just-version: ${{ steps.just-pin.outputs.version }}' \
    /source/.github/workflows/self-test.yaml
  assert_success
}

# why: An unversioned setup-just installs whatever released most recently, so the
# e2e job turns red on a day nobody touched the repo
@test "pins: setup-just is no longer invoked without a just-version" {
  # An unversioned setup-just installs whatever released most recently, so
  # the e2e job turns red on a day nobody touched the repo and the diff
  # that appears to have caused it is unrelated.
  run awk '/uses: extractions\/setup-just/{found=1; next}
           found && /just-version:/{print "pinned"; exit}
           found && /^ *- /{print "unpinned"; exit}' \
    /source/.github/workflows/self-test.yaml
  assert_success
  assert_output 'pinned'
}
