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

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  PINS="/source/script/watch/pins.sh"
  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/dockerfile" "${SCRATCH}/dist/dockerfile" \
           "${SCRATCH}/.github/workflows"
  # A scan root that holds no file at all is a separate (vacuity) case;
  # every other case needs all three roots populated, because the reader
  # refuses a missing root by design.
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
  PIN_REPO_ROOT="${SCRATCH}" run "${PINS}" "$@"
}

# ════════════════════════════════════════════════════════════════════
# What is a marker
# ════════════════════════════════════════════════════════════════════

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

@test "pins: a marker with no target line after it FAILS" {
  _dockerfile \
    'ARG FOO_VERSION=1.2.3' \
    '# tool-pin: foo github-release owner/foo'
  _pins --list
  assert_failure
  assert_output --partial 'has no target line after it'
}

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

@test "pins: a pinned marker naming no coordinate FAILS" {
  _dockerfile \
    '# tool-pin: foo github-release' \
    'ARG FOO_VERSION=1.2.3'
  _pins --list
  assert_failure
  assert_output --partial 'names no resolver and coordinate'
}

@test "pins: a marker carrying an unknown option FAILS" {
  _dockerfile \
    '# tool-pin: foo github-release owner/foo latest=9' \
    'ARG FOO_VERSION=1.2.3'
  _pins --list
  assert_failure
  assert_output --partial 'unknown option latest=9'
}

@test "pins: a pinned marker whose target carries no version FAILS" {
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'RUN echo hello'
  _pins --list
  assert_failure
  assert_output --partial 'no version for owner/foo on its target line'
}

@test "pins: an unpinned marker records the dependency and no version" {
  _dockerfile \
    '# tool-pin: unpinned apk-packages -- bounded by the alpine pin' \
    'RUN apk add --no-cache bash git'
  _pins --list
  assert_success
  assert_output --partial $'unpinned\tapk-packages'
}

@test "pins: an unpinned marker that names no dependency FAILS" {
  _dockerfile \
    '# tool-pin: unpinned -- no name at all' \
    'RUN apk add --no-cache bash'
  _pins --list
  assert_failure
  assert_output --partial 'names no dependency'
}

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

@test "pins: an ARG target yields its right-hand side, unquoted" {
  _dockerfile \
    '# tool-pin: base dockerhub library/ubuntu pattern=.' \
    'ARG BASE_IMAGE="ubuntu:24.04"'
  _pins --value base
  assert_success
  assert_output 'ubuntu:24.04'
}

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

@test "pins: --value refuses a name declared unpinned" {
  _dockerfile \
    '# tool-pin: unpinned apk-packages -- no version to name' \
    'RUN apk add --no-cache bash'
  _pins --value apk-packages
  assert_failure
  assert_output --partial 'names no version'
}

@test "pins: --value refuses a name nothing declares" {
  _dockerfile '# nothing here'
  _pins --value ghost
  assert_failure
  assert_output --partial 'no pin named ghost'
}

# ════════════════════════════════════════════════════════════════════
# --set: the one edit a bump consists of
# ════════════════════════════════════════════════════════════════════

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

@test "pins: --set is a no-op when the pin already names that version" {
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=1.2.3'
  _pins --set foo 1.2.3
  assert_success
  assert_output --partial 'already 1.2.3'
}

@test "pins: --set reports the from/to and where it wrote" {
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=1.2.3'
  _pins --set foo 1.3.0
  assert_success
  assert_output --partial 'foo 1.2.3 -> 1.3.0'
  assert_output --partial 'dockerfile/Dockerfile.test-tools:2'
}

@test "pins: --set refuses a name declared unpinned" {
  _dockerfile \
    '# tool-pin: unpinned apk-packages -- no version to set' \
    'RUN apk add --no-cache bash'
  _pins --set apk-packages 1.0
  assert_failure
  assert_output --partial 'there is no version to set'
}

# ════════════════════════════════════════════════════════════════════
# Scan roots
# ════════════════════════════════════════════════════════════════════

@test "pins: a missing scan root FAILS rather than contributing nothing" {
  # A renamed tree would otherwise shrink the table in silence and every
  # watch run would come back clean.
  rm -rf "${SCRATCH}/dist/dockerfile"
  _pins --list
  assert_failure
  assert_output --partial 'scan root dist/dockerfile/ does not exist'
}

@test "pins: --files lists every Dockerfile and workflow under the roots" {
  _dockerfile 'FROM scratch'
  _pins --files
  assert_success
  assert_output --partial 'dockerfile/Dockerfile.test-tools'
  assert_output --partial 'dist/dockerfile/Dockerfile'
  assert_output --partial '.github/workflows/x.yaml'
}

# ════════════════════════════════════════════════════════════════════
# The resolvers the lint accepts are the resolvers check.sh implements
# ════════════════════════════════════════════════════════════════════

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

@test "pins: the real tree's markers all parse" {
  PIN_REPO_ROOT=/source run "${PINS}" --list
  assert_success
}

@test "pins: just is PINNED in the real tree, not left to a package manager" {
  # The defect this closes: four provenance paths for one tool, 37 minors
  # apart, none of them naming a version in the image.
  PIN_REPO_ROOT=/source run "${PINS}" --value just
  assert_success
  assert_output --regexp '^[0-9]+\.[0-9]+\.[0-9]+$'
}

@test "pins: the just pin is the number the test-tools image installs" {
  PIN_REPO_ROOT=/source run "${PINS}" --value just
  assert_success
  local _version="${output}"
  run grep -F "ARG JUST_VERSION=${_version}" \
    /source/dockerfile/Dockerfile.test-tools
  assert_success
}

@test "pins: the CI just install reads the pin instead of repeating it" {
  # Without this the workflow would carry a fourth copy of the number, and
  # a bump PR that moved the Dockerfile alone would leave CI testing a
  # different just than the image ships.
  run grep -F 'pins.sh --value just' /source/.github/workflows/self-test.yaml
  assert_success
  run grep -F 'just-version: ${{ steps.just-pin.outputs.version }}' \
    /source/.github/workflows/self-test.yaml
  assert_success
}

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
