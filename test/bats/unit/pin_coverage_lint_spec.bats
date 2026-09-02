#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/pin_coverage.sh -- the "every
# third-party version this repo names is declared to the watch" lint.
#
# This lint is the load-bearing half of the upstream-release watch. The
# watch's table is DERIVED from `tool-pin:` markers rather than kept in a
# roster, which removes the "the roster forgot a tool" failure and opens
# its mirror image: a pin added with no marker is simply not in the table,
# and an unwatched dependency is exactly the state the watch exists to
# end. Nothing about a derivation makes it complete. This lint is what
# makes it complete.
#
# So what is under test is the DETECTOR -- which line shapes are a version
# declaration -- rather than "does today's tree carry markers". The cases
# are mostly "a NEW pin spelled this way, with no marker, fails", because
# that is the regression a reviewer cannot be relied on to catch.
#
# The scope boundary matters and is tested both ways: a third-party
# version this repo names THAT DEPENDABOT CANNOT BUMP. A `uses:` version
# ref is dependabot's job and needs no marker; a `uses:` BRANCH ref, which
# dependabot has no way to advance, does.
#
# Shape mirrors self_hosted_guard_lint_spec.bats.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). It references SCRIPT_DIR (to reach the pin registry),
  # REPO_ROOT and _die; provide all three so the function runs against a
  # controlled scratch tree.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  SCRIPT_DIR=/source/script/test
  # shellcheck disable=SC1091
  source /source/script/test/drivers/pin_coverage.sh

  # The scratch tree carries none of the pruned basenames, so `-` (clean)
  # is the honest verdict for it. It is set explicitly rather than left to
  # the ambient container environment so each case starts from a known
  # state -- the cases about the verdict itself override or unset it.
  export PIN_PRUNE_TRACKED='-'

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/dockerfile" "${SCRATCH}/dist/dockerfile" \
           "${SCRATCH}/.github/workflows"
  printf 'FROM scratch\n' > "${SCRATCH}/dist/dockerfile/Dockerfile"
  printf 'name: x\non:\n  push:\n' > "${SCRATCH}/.github/workflows/x.yaml"
  REPO_ROOT="${SCRATCH}"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

_dockerfile() {
  printf '%s\n' "$@" > "${SCRATCH}/dockerfile/Dockerfile.test-tools"
}

_workflow() {
  printf '%s\n' "$@" > "${SCRATCH}/.github/workflows/x.yaml"
}

# A shell script anywhere in the tree. The walk is whole-repo, so where
# this lands decides nothing -- which is the property being relied on.
_script() {
  local _name="${1}"; shift
  printf '%s\n' "$@" > "${SCRATCH}/${_name}"
}

# Something for the non-vacuity check to find, in the cases that are not
# about vacuity.
_one_good_pin() {
  printf '%s\n' \
    '# tool-pin: seed github-release owner/seed' \
    'ARG SEED_VERSION=1.0.0' \
    >> "${SCRATCH}/dist/dockerfile/Dockerfile"
}

# ════════════════════════════════════════════════════════════════════
# The detector: a version declared with no marker FAILS
# ════════════════════════════════════════════════════════════════════

@test "_run_pin_coverage: FAILS on an ARG version with no marker" {
  _one_good_pin
  _dockerfile 'ARG HADOLINT_VERSION=v2.12.0'
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'declared with no tool-pin marker'
  assert_output --partial 'dockerfile/Dockerfile.test-tools:1'
}

@test "_run_pin_coverage: FAILS on an ARG naming an image with an explicit tag" {
  _one_good_pin
  _dockerfile 'ARG BASE_IMAGE="ubuntu:24.04"'
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'ARG BASE_IMAGE="ubuntu:24.04"'
}

@test "_run_pin_coverage: FAILS on a FROM with a literal tag" {
  _one_good_pin
  _dockerfile 'FROM alpine:3.21 AS builder'
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'FROM alpine:3.21'
}

@test "_run_pin_coverage: FAILS on an image named inside a workflow run: step" {
  # dependabot parses `uses:` refs and nothing else, so an image invoked
  # by `docker run` inside a `run:` step is invisible to it. That is how a
  # 14-month-old actionlint kept passing.
  _one_good_pin
  _workflow \
    'jobs:' \
    '  a:' \
    '    steps:' \
    '      - run: docker run --rm rhysd/actionlint:1.7.7 -color'
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'rhysd/actionlint:1.7.7'
}

@test "_run_pin_coverage: FAILS on a release-download URL naming the version" {
  # Not a shape at the margin. This is the form hadolint v2.12.0 and
  # shellcheck v0.10.0 were ACTUALLY pinned in for three years, and the
  # guard meant to stop them coming back could not see it -- so the guard
  # was blind to the shape of the defect it exists to prevent.
  _one_good_pin
  _dockerfile \
    'RUN curl -fsSL -o /usr/local/bin/hadolint \\' \
    '  "https://github.com/hadolint/hadolint/releases/download/v2.12.0/hadolint-Linux-x86_64"'
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'releases/download/v2.12.0'
}

@test "_run_pin_coverage: FAILS on a git clone pinned to a literal tag" {
  # The form the three bats helper libraries were pinned in. Same story.
  _one_good_pin
  _dockerfile \
    'RUN git clone --depth 1 -b v2.1.0 \\' \
    '      https://github.com/bats-core/bats-assert.git /x'
  run _run_pin_coverage
  assert_failure
  assert_output --partial '-b v2.1.0'
}

@test "_run_pin_coverage: FAILS on an OFFICIAL image, which has no namespace" {
  # `alpine:3.21` carries no slash, so the registry-reference shape cannot
  # anchor on it. The `docker run` context is what keeps a `<host>:<port>`
  # example and a `sha256:` digest out.
  _one_good_pin
  _workflow \
    'jobs:' \
    '  a:' \
    '    steps:' \
    '      - run: docker run --rm alpine:3.21 true'
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'alpine:3.21'
}

@test "_run_pin_coverage: FAILS on a uses: ref written inside a SHELL SCRIPT" {
  # The `uses:` exemption is dependabot's job, and dependabot reads
  # WORKFLOW FILES. A ref inside a heredoc a generator writes is not one,
  # and the repos it is written into have no updater at all -- so here
  # even a version-shaped ref is nobody's job but the watch's.
  _one_good_pin
  mkdir -p "${SCRATCH}/dist/script"
  printf '%s\n' \
    'cat > "${_wf}" <<YAML' \
    '      - uses: actions/checkout@v7' \
    'YAML' \
    > "${SCRATCH}/dist/script/gen.sh"
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'actions/checkout@v7'
}

@test "_run_pin_coverage: FAILS on an image tag sed into a generated Dockerfile" {
  # The live instance: dockerfile_migrate.sh wrote `bats/bats:1.11.0` into
  # every downstream Dockerfile it migrated, two minors behind this repo's
  # own bats pin, with nothing reporting it.
  _one_good_pin
  mkdir -p "${SCRATCH}/dist/script"
  printf '%s\n' \
    "sed -i -E 's|^FROM bats/bats:latest|FROM bats/bats:1.11.0|' \"\${_f}\"" \
    > "${SCRATCH}/dist/script/gen.sh"
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'bats/bats:1.11.0'
}

@test "_run_pin_coverage: FAILS on a uses: ref pinned to a BRANCH" {
  # dependabot bumps a version ref to the next version. `main` is not one,
  # so it can never advance it and never says so.
  _one_good_pin
  _workflow \
    'jobs:' \
    '  a:' \
    '    steps:' \
    '      - uses: jlumbroso/free-disk-space@main'
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'free-disk-space@main'
}

# ════════════════════════════════════════════════════════════════════
# The scope boundary: what deliberately needs NO marker
# ════════════════════════════════════════════════════════════════════

@test "_run_pin_coverage: a uses: VERSION ref needs no marker (dependabot's job)" {
  # Covering it here would give one dependency two mechanisms with
  # opinions, which is worse than one that works.
  _one_good_pin
  _workflow \
    'jobs:' \
    '  a:' \
    '    steps:' \
    '      - uses: actions/checkout@v7' \
    '      - uses: docker/login-action@v4.5.2'
  run _run_pin_coverage
  assert_success
}

@test "_run_pin_coverage: a SHA-pinned uses: ref needs no marker" {
  _one_good_pin
  _workflow \
    'jobs:' \
    '  a:' \
    '    steps:' \
    '      - uses: dataaxiom/ghcr-cleanup-action@d52806a0dc70b430571a37da1fde39733ffd640f'
  run _run_pin_coverage
  assert_success
}

@test "_run_pin_coverage: a local reusable-workflow call needs no marker" {
  _one_good_pin
  _workflow \
    'jobs:' \
    '  a:' \
    '    uses: ./.github/workflows/build-worker.yaml'
  run _run_pin_coverage
  assert_success
}

@test "_run_pin_coverage: an ARG that is not a version needs no marker" {
  # `ARG USER_UID=1000` and `ARG TZ="Asia/Taipei"` are ours, not a
  # third-party version. A detector that flagged them would be muted.
  _one_good_pin
  _dockerfile \
    'ARG USER_UID=1000' \
    'ARG TZ="Asia/Taipei"' \
    'ARG DEBIAN_FRONTEND=noninteractive' \
    'ARG ENTRYPOINT_FILE="script/entrypoint.sh"' \
    'ARG TARGETARCH'
  run _run_pin_coverage
  assert_success
}

@test "_run_pin_coverage: a FROM whose tag is an ARG needs no marker" {
  # The ARG carries the pin; the FROM is a reference to it.
  _one_good_pin
  _dockerfile \
    '# tool-pin: alp dockerhub library/alpine pattern=.' \
    'ARG ALPINE_VERSION=3.21' \
    'FROM alpine:${ALPINE_VERSION} AS builder' \
    'FROM builder AS final'
  run _run_pin_coverage
  assert_success
}

@test "_run_pin_coverage: an INTERPOLATED release URL needs no marker" {
  # `releases/download/${FOO_VERSION}/` names no version -- it references
  # the ARG, which carries the marker. Flagging it would demand a second
  # marker for one pin, and a detector that asks for redundant markers is
  # a detector people mute.
  _one_good_pin
  _dockerfile \
    '# tool-pin: sc github-release koalaman/shellcheck' \
    'ARG SHELLCHECK_VERSION=v0.10.0' \
    'RUN curl -fsSL \\' \
    '  "https://example.invalid/releases/download/${SHELLCHECK_VERSION}/sc.tar.xz"'
  run _run_pin_coverage
  assert_success
}

@test "_run_pin_coverage: an INTERPOLATED clone ref needs no marker" {
  _one_good_pin
  _dockerfile \
    '# tool-pin: ba github-release bats-core/bats-assert' \
    'ARG BATS_ASSERT_VERSION=v2.1.0' \
    'RUN git clone --depth 1 -b "${BATS_ASSERT_VERSION}" https://x/y /z'
  run _run_pin_coverage
  assert_success
}

@test "_run_pin_coverage: an INTERPOLATED uses: ref in a script needs no marker" {
  # The fix for the live instance: the ref is hoisted onto a line of its
  # own where a marker can address it, and the heredoc references that.
  _one_good_pin
  mkdir -p "${SCRATCH}/dist/script"
  printf '%s\n' \
    '# tool-pin: unpinned checkout-action -- a MAJOR ref on purpose' \
    "readonly _REF='actions/checkout@v7'" \
    'cat > "${_wf}" <<YAML' \
    '      - uses: ${_REF}' \
    'YAML' \
    > "${SCRATCH}/dist/script/gen.sh"
  run _run_pin_coverage
  assert_success
}

@test "_run_pin_coverage: a commented-out declaration needs no marker" {
  _one_good_pin
  _dockerfile \
    '# ARG HADOLINT_VERSION=v2.12.0  (was here before the rewrite)'
  run _run_pin_coverage
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# The three ways to satisfy the detector
# ════════════════════════════════════════════════════════════════════

@test "_run_pin_coverage: a pinned marker satisfies the detector" {
  _dockerfile \
    '# tool-pin: hadolint github-release hadolint/hadolint' \
    'ARG HADOLINT_VERSION=v2.12.0'
  run _run_pin_coverage
  assert_success
  assert_output --partial 'pin-coverage lint: clean'
}

@test "_run_pin_coverage: an unpinned marker satisfies it and is counted apart" {
  # `unpinned` is a DECLARATION that the dependency floats, not an off
  # switch: the watch prints every one of them on every run.
  _dockerfile \
    '# tool-pin: seed github-release owner/seed' \
    'ARG SEED_VERSION=1.0.0' \
    '# tool-pin: unpinned base-image -- a moving tag, consumer-facing' \
    'FROM ubuntu:24.04 AS sys'
  run _run_pin_coverage
  assert_success
  assert_output --partial '1 pinned, 1 declared unpinned'
}

@test "_run_pin_coverage: an ignore marker satisfies it for a false positive" {
  _one_good_pin
  _dockerfile \
    '# tool-pin: ignore -- ours, not a third-party version' \
    'ARG SCHEMA_VERSION=2.1'
  run _run_pin_coverage
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Marker hygiene the lint enforces
# ════════════════════════════════════════════════════════════════════

@test "_run_pin_coverage: FAILS on a marker naming an unimplemented resolver" {
  # A typo caught by a scheduled run weeks later is weeks of not watching.
  _dockerfile \
    '# tool-pin: foo gitub-release owner/foo' \
    'ARG FOO_VERSION=1.0.0'
  run _run_pin_coverage
  assert_failure
  assert_output --partial "names resolver 'gitub-release'"
  assert_output --partial 'Known resolvers:'
}

@test "_run_pin_coverage: FAILS when two markers share a name" {
  # `pins.sh --value` and `--set` address a pin BY NAME, so a shared name
  # makes both read and rewrite whichever came first, silently.
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=1.0.0' \
    '# tool-pin: foo github-release owner/other' \
    'ARG OTHER_VERSION=2.0.0'
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'two tool-pin markers share a name'
}

@test "_run_pin_coverage: FAILS when a marker does not parse" {
  _dockerfile \
    '# tool-pin: foo github-release owner/foo bogus=1' \
    'ARG FOO_VERSION=1.0.0'
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'did not parse'
}

@test "_run_pin_coverage: the failure names all three marker forms" {
  # The message has to be actionable: two of the three states exist for
  # dependencies that CANNOT name a version, and a reader who only knows
  # about the pinned form has no correct move.
  _one_good_pin
  _dockerfile 'ARG HADOLINT_VERSION=v2.12.0'
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'tool-pin: <name> github-release <owner>/<repo>'
  assert_output --partial 'tool-pin: unpinned <name>'
  assert_output --partial 'tool-pin: ignore'
}

# ════════════════════════════════════════════════════════════════════
# Non-vacuity: the lint must not pass because it read nothing
# ════════════════════════════════════════════════════════════════════

@test "_run_pin_coverage: DIES when the scanned trees yield no pinned entry" {
  # A reader regression that matched nothing would otherwise report a
  # clean tree forever, which is the failure this guard exists to prevent
  # one level up.
  _dockerfile 'FROM scratch'
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'yielded no PINNED entry'
}

@test "_run_pin_coverage: DIES when the walk yields no file at all" {
  rm -rf "${SCRATCH:?}"
  mkdir -p "${SCRATCH}/doc"
  printf 'hello\n' > "${SCRATCH}/doc/a.md"
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'did not parse'
}

@test "_run_pin_coverage: FAILS when a pruned BASENAME matches a tracked tree at depth" {
  # `find -name <entry> -prune` prunes a directory of that basename at ANY
  # depth. The guard only ever tested `<repo-root>/<entry>` and skipped
  # the entry when that path did not exist, so an entry that never appears
  # at the root was not checked at all -- while removing every nested tree
  # of that name from the walk, from this lint and from the watch.
  _one_good_pin
  git -C "${SCRATCH}" init -q
  mkdir -p "${SCRATCH}/dist/script/log"
  printf 'FROM alpine:3.19\n' > "${SCRATCH}/dist/script/log/Dockerfile"
  git -C "${SCRATCH}" add -A
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'prunes a tree the repo tracks'
  assert_output --partial 'dist/script/log'
}

@test "_run_pin_coverage: a pruned basename matching nothing tracked is fine" {
  # The whole point of the prune list. `log/` holds run transcripts and is
  # gitignored, so no tracked path lies under it and the entry is honest.
  _one_good_pin
  git -C "${SCRATCH}" init -q
  printf 'log/\n' > "${SCRATCH}/.gitignore"
  mkdir -p "${SCRATCH}/log" "${SCRATCH}/dist/log"
  printf 'x\n' > "${SCRATCH}/log/x.txt"
  printf 'x\n' > "${SCRATCH}/dist/log/x.txt"
  git -C "${SCRATCH}" add -A
  run _run_pin_coverage
  assert_success
}

@test "_run_pin_coverage: DIES when the prune list cannot be checked at all" {
  # The guard used to be wrapped in `if git rev-parse --git-dir`, so an
  # environment it could not inspect got a PASS. The suite runs in a
  # container that bind-mounts the checkout without a resolvable .git,
  # which is the repo's own local gate -- so the fail-open default was the
  # default in the place the guard is run most.
  _one_good_pin
  unset PIN_PRUNE_TRACKED
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'cannot check its prune list'
}

@test "_run_pin_coverage: accepts a host-computed verdict when git is unreadable" {
  # The container cannot answer the question; the host always can. So the
  # answer is COMPUTED where git works and carried in, and the guard runs
  # on it rather than being skipped. `-` is the clean verdict, spelled so
  # that "clean" and "never computed" are different values.
  _one_good_pin
  unset PIN_PRUNE_TRACKED
  PIN_PRUNE_TRACKED='-' run _run_pin_coverage
  assert_success
}

@test "_run_pin_coverage: FAILS on a host-computed verdict naming a tracked tree" {
  _one_good_pin
  unset PIN_PRUNE_TRACKED
  PIN_PRUNE_TRACKED='doc' run _run_pin_coverage
  assert_failure
  assert_output --partial 'prunes a tree the repo tracks'
  assert_output --partial 'doc'
}

@test "_run_pin_coverage: git OUTRANKS an inherited verdict" {
  # A stale or hand-set PIN_PRUNE_TRACKED must not be able to silence a
  # tree git can see is tracked. The carried answer is a fallback for the
  # environment that has no git, never an override for the one that does.
  _one_good_pin
  git -C "${SCRATCH}" init -q
  mkdir -p "${SCRATCH}/log"
  printf 'x\n' > "${SCRATCH}/log/x.txt"
  git -C "${SCRATCH}" add -A
  PIN_PRUNE_TRACKED='-' run _run_pin_coverage
  assert_failure
  assert_output --partial 'prunes a tree the repo tracks'
}

# ════════════════════════════════════════════════════════════════════
# An image reference is a declaration WHEREVER it is written
# ════════════════════════════════════════════════════════════════════
#
# The detector used to recognise a namespace-less image only when a
# `docker run|pull|create|build` sat on the SAME LINE. That is a roster
# of contexts wearing a regex's clothes, and it had the roster failure
# mode: a context nobody listed passes SILENTLY. These cases are the
# contexts that were missing, and the last one is the point -- an
# unrecognised context has to raise the question, not answer it.

@test "_run_pin_coverage: FAILS on an image: in compose.yaml" {
  # This repo's own core artefact. A compose service names its image the
  # way a Dockerfile names its base, and no `docker` verb appears on the
  # line at all.
  _one_good_pin
  printf '%s\n' \
    'services:' \
    '  devel:' \
    '    image: alpine:3.21' \
    > "${SCRATCH}/compose.yaml"
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'alpine:3.21'
}

@test "_run_pin_coverage: FAILS on a workflow container: image" {
  # A first-class GitHub Actions feature: the job runs INSIDE this image,
  # and dependabot cannot bump it any more than it can bump a `run:` one.
  _one_good_pin
  _workflow \
    'jobs:' \
    '  a:' \
    '    container: alpine:3.21' \
    '    steps:' \
    '      - run: true'
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'alpine:3.21'
}

@test "_run_pin_coverage: FAILS on a bare image tag sed into a generated file" {
  # The live shape. dockerfile_migrate.sh rewrote the FROM line of every
  # downstream Dockerfile it migrated, and the namespaced half of that one
  # sed (`bats/bats:1.11.0`) was caught only because it carries a slash --
  # the `alpine` half of the same line was invisible.
  _one_good_pin
  mkdir -p "${SCRATCH}/dist/script"
  printf '%s\n' \
    "sed -i -E 's|^FROM alpine:latest|FROM alpine:3.21|' \"\${_file}\"" \
    > "${SCRATCH}/dist/script/gen.sh"
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'alpine:3.21'
}

@test "_run_pin_coverage: FAILS on an image named by a key nothing anticipated" {
  # The whole point of dropping the context roster. Neither `image:` nor
  # `container:` nor any `docker` verb appears here, and the file shape is
  # one no earlier version of this lint looked at. An unrecognised context
  # must raise the question rather than pass.
  _one_good_pin
  printf 'fallback_image=alpine:3.21\n' > "${SCRATCH}/dist.setup.conf"
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'alpine:3.21'
}

@test "_run_pin_coverage: FAILS on a bare image named in a justfile" {
  # justfiles are this repo's control surface -- ADR-00000005 makes `just`
  # the single runner, so a container this repo actually starts is far
  # more likely to be named in one than in a shell script.
  _one_good_pin
  printf '%s\n' \
    'lint:' \
    '    docker run --rm alpine:3.21 true' \
    > "${SCRATCH}/justfile"
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'alpine:3.21'
}

# ════════════════════════════════════════════════════════════════════
# What a `<name>:<tag>` token is NOT
# ════════════════════════════════════════════════════════════════════
#
# Dropping the `docker <verb>` context cannot be paid for with noise. The
# exemptions are properties of the TOKEN (or of the flag that introduces
# it), never of the surrounding line, so they do not decay the way the
# context roster did.

@test "_run_pin_coverage: a published port is not a version" {
  # `-p 8080:8080` is core idiom here and would have fired even under the
  # old rule, which required only a `docker run` somewhere on the line.
  _one_good_pin
  mkdir -p "${SCRATCH}/dist/script"
  printf '%s\n' \
    'docker run --rm -p 8080:8080 "${IMAGE}" true' \
    > "${SCRATCH}/dist/script/gen.sh"
  run _run_pin_coverage
  assert_success
}

@test "_run_pin_coverage: a UID:GID pair is not a version" {
  _one_good_pin
  mkdir -p "${SCRATCH}/dist/script"
  printf '%s\n' \
    'docker run --rm --user 1000:1000 "${IMAGE}" bats' \
    > "${SCRATCH}/dist/script/gen.sh"
  run _run_pin_coverage
  assert_success
}

@test "_run_pin_coverage: the image this repo BUILDS is not one it depends on" {
  # You cannot depend on a version you are creating. `-t`/`--tag` names an
  # OUTPUT, so the token it introduces is ours by construction -- which is
  # a shape rule, not a list of our image names.
  _one_good_pin
  mkdir -p "${SCRATCH}/dist/script"
  printf '%s\n' \
    'docker build --build-arg USER_UID=1000 -t base:0.1 .' \
    > "${SCRATCH}/dist/script/gen.sh"
  run _run_pin_coverage
  assert_success
}

@test "_run_pin_coverage: a digest is not a version" {
  # A digest is already immutable; there is no newer one to propose.
  _one_good_pin
  _workflow \
    'jobs:' \
    '  a:' \
    '    steps:' \
    '      - run: echo sha256:0123456789abcdef0123456789abcdef01234567'
  run _run_pin_coverage
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# The scan surface: an exemption list, and it is checked
# ════════════════════════════════════════════════════════════════════

@test "_run_pin_coverage: a spec's fixture text needs no marker" {
  # A .bats spec's heredoc IS the fixture the code under test parses, so
  # the marker grammar cannot reach it: the marker's target is the next
  # non-comment line, and inserting that comment INTO the heredoc changes
  # the fixture. See script/watch/lib.sh.
  _one_good_pin
  mkdir -p "${SCRATCH}/test/bats/unit"
  printf '%s\n' \
    '@test "x" {' \
    '  cat > "${D}/Dockerfile" <<EOD' \
    'FROM alpine:3.20 AS sys' \
    'EOD' \
    '}' \
    > "${SCRATCH}/test/bats/unit/x_spec.bats"
  run _run_pin_coverage
  assert_success
}

@test "_run_pin_coverage: prose needs no marker" {
  _one_good_pin
  mkdir -p "${SCRATCH}/doc"
  printf 'Run `docker run --rm alpine:3.21 true` to check.\n' \
    > "${SCRATCH}/doc/guide.md"
  run _run_pin_coverage
  assert_success
}

@test "_run_pin_coverage: FAILS when a tool-pin marker sits in an unscanned file" {
  # The exemption list is the one hand-kept thing left in the scan
  # surface, so it is checked rather than trusted -- the same treatment
  # the prune list gets. A marker written in an exempt file is a pin its
  # author believes is watched and which nothing reads, and that belief is
  # exactly what this whole mechanism exists to make impossible.
  _one_good_pin
  mkdir -p "${SCRATCH}/test/bats/unit"
  printf '%s\n' \
    '# tool-pin: ghost github-release owner/ghost' \
    'ARG GHOST_VERSION=1.0.0' \
    > "${SCRATCH}/test/bats/unit/x_spec.bats"
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'is not scanned'
}

# ════════════════════════════════════════════════════════════════════
# A version is a version wherever the ASSIGNMENT is written
# ════════════════════════════════════════════════════════════════════
#
# The detector recognised an assignment only when its keyword was `ARG`.
# That is a roster of KEYWORDS, and it failed the way every roster in
# this mechanism has: `local`, `readonly`, `export` and a bare
# `NAME=<version>` were all outside it and all passed in silence -- while
# `_PIN_ASSIGN_RE` already named those four keywords for EXTRACTION, and
# while script/watch/lib.sh calls hoisting a literal onto a line of its
# own "the standard fix for a version the reader cannot address". The
# convention pushed authors into the one shape the guard could not see.
#
# The bill was not hypothetical: `local _bats_tag='1.13.0'` and
# `local _alpine_tag='3.21'` in dist/script/docker/lib/dockerfile_migrate.sh
# are written into every downstream Dockerfile that function migrates,
# and deleting both markers left the lint clean.
#
# The reader and the detector now ask the same question -- does this line
# assign a version -- of the same regex, so they cannot disagree about
# which shapes are pins.

@test "_run_pin_coverage: FAILS on a local= version with no marker" {
  _one_good_pin
  _script 'x.sh' \
    '_f() {' \
    "  local _bats_tag='1.13.0'" \
    '}'
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'declared with no tool-pin marker'
  assert_output --partial 'x.sh:2'
}

@test "_run_pin_coverage: FAILS on a readonly= version with no marker" {
  _one_good_pin
  _script 'x.sh' 'readonly HELM_VERSION=3.16.2'
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'x.sh:1'
}

@test "_run_pin_coverage: FAILS on an export= version with no marker" {
  _one_good_pin
  _script 'x.sh' 'export TERRAFORM_VERSION="1.9.5"'
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'x.sh:1'
}

@test "_run_pin_coverage: FAILS on a bare NAME=version with no marker" {
  # No keyword at all is still an assignment, and the hoisting convention
  # produces this shape as readily as the other three.
  _one_good_pin
  _script 'x.sh' 'KUBECTL_VERSION=1.31.0'
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'x.sh:1'
}

@test "_run_pin_coverage: a marked shell assignment satisfies the detector" {
  _one_good_pin
  _script 'x.sh' \
    '# tool-pin: bats dockerhub bats/bats pattern=.' \
    "local _bats_tag='1.13.0'"
  run _run_pin_coverage
  assert_success
}

@test "_run_pin_coverage: a shell assignment that is not a version is not one" {
  # The same boundary the ARG branch draws, for the same reason: this
  # repo's scripts are full of assignments, and a detector that flagged a
  # count, a port or a timeout would be muted within a week.
  _one_good_pin
  _script 'x.sh' \
    '_f() {' \
    '  local _count=0' \
    '  local _timeout=30' \
    '  readonly PORT=8080' \
    '  export DEBIAN_FRONTEND=noninteractive' \
    '  local _path="script/entrypoint.sh"' \
    '  local _msg="took 1.5s"' \
    '  local _n' \
    '}'
  run _run_pin_coverage
  assert_success
}

@test "_run_pin_coverage: an assignment whose value INTERPOLATES needs no marker" {
  # `local _t="${BATS_VERSION}"` references the pin; it does not declare
  # one, exactly as a `FROM alpine:${ALPINE_VERSION}` does not.
  _one_good_pin
  _script 'x.sh' \
    '_f() {' \
    '  local _tag="${BATS_VERSION}"' \
    '  local _url="releases/download/${HADOLINT_VERSION}/hadolint"' \
    '}'
  run _run_pin_coverage
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# A version with one component is still a version
# ════════════════════════════════════════════════════════════════════
#
# The version test required at least one dot, to keep `ARG USER_UID=1000`
# from being read as a release. That is a real distinction and the dot was
# the wrong way to draw it: kcov's own pin is `ARG KCOV_VERSION=v43`, a
# single-component upstream tag, so this repo's own pin was invisible to
# the guard meant to prove it was watched.
#
# The distinction that actually holds is the `v` PREFIX, which nobody
# writes on a UID, a port or a count. A bare `2024` stays not-a-version
# on purpose: nothing on the line distinguishes it from `ARG USER_UID=1000`,
# and a guard that cannot tell them apart has to choose the answer that
# keeps it usable. That boundary is stated, not silent -- it is the
# reason `ARG THIRD_VERSION=2024` is accepted below.

@test "_run_pin_coverage: FAILS on a v-prefixed version with no dot" {
  _one_good_pin
  _dockerfile 'ARG KCOV_VERSION=v43'
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'declared with no tool-pin marker'
  assert_output --partial 'dockerfile/Dockerfile.test-tools:1'
}

@test "_run_pin_coverage: FAILS on a v-prefixed major-only ref in a shell assignment" {
  _one_good_pin
  _script 'x.sh' 'readonly ACTION_MAJOR=v7'
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'x.sh:1'
}

@test "_run_pin_coverage: a marked dotless version satisfies the detector" {
  _one_good_pin
  _dockerfile \
    '# tool-pin: kcov github-release SimonKagstrom/kcov' \
    'ARG KCOV_VERSION=v43'
  run _run_pin_coverage
  assert_success
}

@test "_run_pin_coverage: a bare integer is still not a version" {
  # The stated cost of the rule above. `1000` and `2024` carry nothing
  # that separates a release from a UID or a year.
  _one_good_pin
  _dockerfile \
    'ARG USER_UID=1000' \
    'ARG THIRD_VERSION=2024'
  run _run_pin_coverage
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# The real tree
# ════════════════════════════════════════════════════════════════════

@test "_run_pin_coverage: the real repo tree declares every version it names" {
  REPO_ROOT=/source run _run_pin_coverage
  assert_success
  assert_output --partial 'pin-coverage lint: clean'
}

@test "_run_pin_coverage: pin-coverage is in test.sh's _LINT_TOOLS table" {
  # Membership is what gives it a CI job: self_test_yaml_spec asserts
  # every entry of that table is named by a job in self-test.yaml.
  run grep -E '^  pin-coverage$' /source/script/test/test.sh
  assert_success
}

@test "_run_pin_coverage: --pin-coverage-only runs it host-direct" {
  run /source/script/test/test.sh --pin-coverage-only
  assert_success
  assert_output --partial 'pin-coverage lint: clean'
}
