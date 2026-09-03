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

# ════════════════════════════════════════════════════════════════════
# Scan roots
# ════════════════════════════════════════════════════════════════════

@test "pins: a tree yielding no scannable file at all FAILS" {
  # An empty table read as "this repo declares no pins" is the one answer
  # the watch must never give by accident: it is indistinguishable from a
  # clean week.
  rm -rf "${SCRATCH:?}"
  mkdir -p "${SCRATCH}/doc"
  printf 'hello\n' > "${SCRATCH}/doc/a.md"
  _pins --list
  assert_failure
  assert_output --partial 'no scannable file'
}

@test "pins: --files lists every file it walks, prose and specs aside" {
  _dockerfile 'FROM scratch'
  _pins --files
  assert_success
  assert_output --partial 'dockerfile/Dockerfile.test-tools'
  assert_output --partial 'dist/dockerfile/Dockerfile'
  assert_output --partial '.github/workflows/x.yaml'
}

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

@test "pins: a pruned tree contributes nothing" {
  # `.prev-release/` is `git archive` of PAST releases, materialised for a
  # spec. Every version in it is supposed to be stale, and a bump inside
  # it would be meaningless.
  mkdir -p "${SCRATCH}/.prev-release/v0.1.0/dockerfile"
  printf '%s\n' \
    '# tool-pin: ancient github-release owner/ancient' \
    'ARG ANCIENT_VERSION=0.0.1' \
    > "${SCRATCH}/.prev-release/v0.1.0/dockerfile/Dockerfile"
  _pins --files
  assert_success
  refute_output --partial '.prev-release'
  _pins --value ancient
  assert_failure
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
