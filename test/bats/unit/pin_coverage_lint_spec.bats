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

  # The suite container's host-computed handoff is left in place on
  # purpose. It is keyed to the root it describes (/source), so it cannot
  # reach the fixture -- which is the property "a carried list for another
  # root is not consulted" below asserts, and the reason no case here has
  # to remember to clear it.
  SCRATCH="$(mktemp -d)"
  # The scan population is what the tree TRACKS, so the fixture is a real
  # repository rather than a bare directory. `_lint` commits the fixture
  # to the index before each run; a case that wants an UNTRACKED file
  # writes it after calling nothing, or uses `_untracked`.
  git -C "${SCRATCH}" init -q
  mkdir -p "${SCRATCH}/dockerfile" "${SCRATCH}/dist/dockerfile" \
           "${SCRATCH}/.github/workflows"
  printf 'FROM scratch\n' > "${SCRATCH}/dist/dockerfile/Dockerfile"
  printf 'name: x\non:\n  push:\n' > "${SCRATCH}/.github/workflows/x.yaml"
  REPO_ROOT="${SCRATCH}"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# Run the lint over the fixture as the repo would see it: everything
# written so far is tracked. Staging here rather than in each writer
# keeps "what this case put in the tree" and "what the lint reads" the
# same thing by construction -- a case that means to leave a file
# untracked has to say so.
_lint() {
  git -C "${SCRATCH}" add -A
  run _run_pin_coverage
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

# why: The base case: an ARG is where most of this repo's versions live, and an
# unmarked one is a pin nothing watches
@test "_run_pin_coverage: FAILS on an ARG version with no marker" {
  _one_good_pin
  _dockerfile 'ARG HADOLINT_VERSION=v2.12.0'
  _lint
  assert_failure
  assert_output --partial 'declared with no tool-pin marker'
  assert_output --partial 'dockerfile/Dockerfile.test-tools:1'
}

# why: An image named through an ARG is still a third-party version, and the tag is
# the half that goes stale
@test "_run_pin_coverage: FAILS on an ARG naming an image with an explicit tag" {
  _one_good_pin
  _dockerfile 'ARG BASE_IMAGE="ubuntu:24.04"'
  _lint
  assert_failure
  assert_output --partial 'ARG BASE_IMAGE="ubuntu:24.04"'
}

# why: A literal FROM tag is the shape a helper stage takes, and it moves without
# any ARG changing
@test "_run_pin_coverage: FAILS on a FROM with a literal tag" {
  _one_good_pin
  _dockerfile 'FROM alpine:3.21 AS builder'
  _lint
  assert_failure
  assert_output --partial 'FROM alpine:3.21'
}

# why: dependabot parses uses: and nothing else, so an image run inside a run: step
# is invisible to it -- how a 14-month-old actionlint kept passing
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
  _lint
  assert_failure
  assert_output --partial 'rhysd/actionlint:1.7.7'
}

# why: The form hadolint and shellcheck were actually pinned in for three years, so
# a guard blind to it is blind to the defect it exists to prevent
@test "_run_pin_coverage: FAILS on a release-download URL naming the version" {
  # Not a shape at the margin. This is the form hadolint v2.12.0 and
  # shellcheck v0.10.0 were ACTUALLY pinned in for three years, and the
  # guard meant to stop them coming back could not see it -- so the guard
  # was blind to the shape of the defect it exists to prevent.
  _one_good_pin
  _dockerfile \
    'RUN curl -fsSL -o /usr/local/bin/hadolint \\' \
    '  "https://github.com/hadolint/hadolint/releases/download/v2.12.0/hadolint-Linux-x86_64"'
  _lint
  assert_failure
  assert_output --partial 'releases/download/v2.12.0'
}

# why: The form the three bats helper libraries were pinned in -- the same story,
# a different verb
@test "_run_pin_coverage: FAILS on a git clone pinned to a literal tag" {
  # The form the three bats helper libraries were pinned in. Same story.
  _one_good_pin
  _dockerfile \
    'RUN git clone --depth 1 -b v2.1.0 \\' \
    '      https://github.com/bats-core/bats-assert.git /x'
  _lint
  assert_failure
  assert_output --partial '-b v2.1.0'
}

# why: An official image carries no slash, so the registry-reference shape cannot
# anchor on it and it would pass unseen
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
  _lint
  assert_failure
  assert_output --partial 'alpine:3.21'
}

# why: A ref in a generator's heredoc is not a workflow file, so dependabot cannot
# see it, and the downstream repos it lands in have no updater at all
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
  _lint
  assert_failure
  assert_output --partial 'actions/checkout@v7'
}

# why: The hole under this repo's own advice: hoisting a ref makes the marker on it
# voluntary, so deleting the marker leaves the lint green
@test "_run_pin_coverage: FAILS on an assignment whose value is an action ref" {
  # The shape this repo's own advice produces, and the hole under it. When
  # a `uses:` ref inside a heredoc has no line a marker can address, the
  # documented fix is to HOIST it: `readonly REF='actions/checkout@v7'`
  # above the heredoc, marker on the assignment. But an action ref is not
  # a version by the version rule and names no image, so the detector saw
  # nothing there -- which made the marker on the hoisted line VOLUNTARY.
  # Delete it and this lint stays green over a generated ref nothing
  # watches, which is the exact state the hoist was performed to leave.
  _one_good_pin
  _script 'gen.sh' \
    '#!/usr/bin/env bash' \
    "readonly _MONITOR_REF='actions/checkout@v7'"
  _lint
  assert_failure
  assert_output --partial '_MONITOR_REF'
}

# why: The other half -- the hoist is the documented fix, so declaring it has to be
# enough, and unpinned keeps the ref on the floating list every run
@test "_run_pin_coverage: a marked assignment of an action ref satisfies it" {
  # The other half: the hoist is the fix, so declaring it has to be
  # enough. `unpinned` is the honest state for a MAJOR ref -- there is no
  # comparable version -- and it keeps the ref on the floating list every
  # run instead of pretending it is checked.
  _one_good_pin
  _script 'gen.sh' \
    '#!/usr/bin/env bash' \
    '# tool-pin: unpinned downstream-checkout -- a major ref on purpose' \
    "readonly _MONITOR_REF='actions/checkout@v7'"
  _lint
  assert_success
}

# why: The rule is owner/repo@ref, not "has a slash in it"; a detector that flagged
# paths and globs would be muted within a week
@test "_run_pin_coverage: an assignment of a plain path is not an action ref" {
  # The rule is `<owner>/<repo>@<ref>`, not "has a slash in it". A path, a
  # glob or a URL fragment assigned to a name is not a third-party pin,
  # and a detector that said otherwise would be muted within a week.
  _one_good_pin
  _script 'gen.sh' \
    '#!/usr/bin/env bash' \
    "readonly _DIR='dist/script/base'" \
    "readonly _GLOB='dist/script/*.sh'"
  _lint
  assert_success
}

# why: The live instance: the migration wrote bats/bats:1.11.0 into every
# downstream Dockerfile it healed, two minors behind this repo's own pin
@test "_run_pin_coverage: FAILS on an image tag sed into a generated Dockerfile" {
  # The live instance: dockerfile_migrate.sh wrote `bats/bats:1.11.0` into
  # every downstream Dockerfile it migrated, two minors behind this repo's
  # own bats pin, with nothing reporting it.
  _one_good_pin
  mkdir -p "${SCRATCH}/dist/script"
  printf '%s\n' \
    "sed -i -E 's|^FROM bats/bats:latest|FROM bats/bats:1.11.0|' \"\${_f}\"" \
    > "${SCRATCH}/dist/script/gen.sh"
  _lint
  assert_failure
  assert_output --partial 'bats/bats:1.11.0'
}

# why: dependabot bumps a version ref to the next version, and a branch is not one,
# so it can never advance the ref and never says so
@test "_run_pin_coverage: FAILS on a uses: ref pinned to a BRANCH" {
  # dependabot bumps a version ref to the next version. `main` is not one,
  # so it can never advance it and never says so.
  _one_good_pin
  _workflow \
    'jobs:' \
    '  a:' \
    '    steps:' \
    '      - uses: jlumbroso/free-disk-space@main'
  _lint
  assert_failure
  assert_output --partial 'free-disk-space@main'
}

# ════════════════════════════════════════════════════════════════════
# The scope boundary: what deliberately needs NO marker
# ════════════════════════════════════════════════════════════════════

# why: Covering it here would give one dependency two mechanisms with opinions,
# which is worse than one that works
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
  _lint
  assert_success
}

# why: A SHA is already immutable, so there is nothing for a marker to name and
# demanding one would teach people to reach for ignore
@test "_run_pin_coverage: a SHA-pinned uses: ref needs no marker" {
  _one_good_pin
  _workflow \
    'jobs:' \
    '  a:' \
    '    steps:' \
    '      - uses: dataaxiom/ghcr-cleanup-action@d52806a0dc70b430571a37da1fde39733ffd640f'
  _lint
  assert_success
}

# why: A local call is this tree at this commit; it names no third party to watch
@test "_run_pin_coverage: a local reusable-workflow call needs no marker" {
  _one_good_pin
  _workflow \
    'jobs:' \
    '  a:' \
    '    uses: ./.github/workflows/build-worker.yaml'
  _lint
  assert_success
}

# why: ARG USER_UID=1000 is ours, not a third-party version, and a detector that
# flagged it would be muted
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
  _lint
  assert_success
}

# why: The ARG carries the pin and the FROM references it; demanding a second
# marker for one pin is how a lint gets muted
@test "_run_pin_coverage: a FROM whose tag is an ARG needs no marker" {
  # The ARG carries the pin; the FROM is a reference to it.
  _one_good_pin
  _dockerfile \
    '# tool-pin: alp dockerhub library/alpine pattern=.' \
    'ARG ALPINE_VERSION=3.21' \
    'FROM alpine:${ALPINE_VERSION} AS builder' \
    'FROM builder AS final'
  _lint
  assert_success
}

# why: An interpolated URL names no version -- it references the ARG that carries
# the marker, and redundant markers are what people mute
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
  _lint
  assert_success
}

# why: The clone half of the same rule, so the fix documented for a clone ref does
# not itself become a finding
@test "_run_pin_coverage: an INTERPOLATED clone ref needs no marker" {
  _one_good_pin
  _dockerfile \
    '# tool-pin: ba github-release bats-core/bats-assert' \
    'ARG BATS_ASSERT_VERSION=v2.1.0' \
    'RUN git clone --depth 1 -b "${BATS_ASSERT_VERSION}" https://x/y /z'
  _lint
  assert_success
}

# why: The fix for the live instance: the ref is hoisted to a line a marker can
# address, so the accepted shape has to actually be accepted
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
  _lint
  assert_success
}

# why: Commented-out text declares nothing, and demanding a marker on it teaches
# people to delete history to satisfy the lint
@test "_run_pin_coverage: a commented-out declaration needs no marker" {
  _one_good_pin
  _dockerfile \
    '# ARG HADOLINT_VERSION=v2.12.0  (was here before the rewrite)'
  _lint
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# The three ways to satisfy the detector
# ════════════════════════════════════════════════════════════════════

# why: The ordinary success path, and the only one of the three states that ends up
# compared against an upstream
@test "_run_pin_coverage: a pinned marker satisfies the detector" {
  _dockerfile \
    '# tool-pin: hadolint github-release hadolint/hadolint' \
    'ARG HADOLINT_VERSION=v2.12.0'
  _lint
  assert_success
  assert_output --partial 'pin-coverage lint: clean'
}

# why: unpinned is a declaration that the dependency floats, counted apart so the
# watch prints it on every run rather than hiding it
@test "_run_pin_coverage: an unpinned marker satisfies it and is counted apart" {
  # `unpinned` is a DECLARATION that the dependency floats, not an off
  # switch: the watch prints every one of them on every run.
  _dockerfile \
    '# tool-pin: seed github-release owner/seed' \
    'ARG SEED_VERSION=1.0.0' \
    '# tool-pin: unpinned base-image -- a moving tag, consumer-facing' \
    'FROM ubuntu:24.04 AS sys'
  _lint
  assert_success
  assert_output --partial '1 pinned, 1 declared unpinned'
}

# why: ignore is the escape for a false positive, and without one a detector this
# broad gets turned off wholesale
@test "_run_pin_coverage: an ignore marker satisfies it for a false positive" {
  _one_good_pin
  _dockerfile \
    '# tool-pin: ignore -- ours, not a third-party version' \
    'ARG SCHEMA_VERSION=2.1'
  _lint
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Marker hygiene the lint enforces
# ════════════════════════════════════════════════════════════════════

# why: A typo caught by a scheduled run weeks later is weeks of not watching, so
# the resolver is validated at the declaration site
@test "_run_pin_coverage: FAILS on a marker naming an unimplemented resolver" {
  # A typo caught by a scheduled run weeks later is weeks of not watching.
  _dockerfile \
    '# tool-pin: foo gitub-release owner/foo' \
    'ARG FOO_VERSION=1.0.0'
  _lint
  assert_failure
  assert_output --partial "names resolver 'gitub-release'"
  assert_output --partial 'Known resolvers:'
}

# why: --value and --set address a pin by name, so a shared name makes both read
# and rewrite whichever came first, silently
@test "_run_pin_coverage: FAILS when two markers share a name" {
  # `pins.sh --value` and `--set` address a pin BY NAME, so a shared name
  # makes both read and rewrite whichever came first, silently.
  _dockerfile \
    '# tool-pin: foo github-release owner/foo' \
    'ARG FOO_VERSION=1.0.0' \
    '# tool-pin: foo github-release owner/other' \
    'ARG OTHER_VERSION=2.0.0'
  _lint
  assert_failure
  assert_output --partial 'two tool-pin markers share a name'
}

# why: A marker that does not parse must fail at the site rather than be dropped,
# which would leave the pin uncovered and the lint green
@test "_run_pin_coverage: FAILS when a marker does not parse" {
  _dockerfile \
    '# tool-pin: foo github-release owner/foo bogus=1' \
    'ARG FOO_VERSION=1.0.0'
  _lint
  assert_failure
  assert_output --partial 'did not parse'
}

# why: Two of the three states exist for dependencies that cannot name a version,
# so a reader who only knows the pinned form has no correct move
@test "_run_pin_coverage: the failure names all three marker forms" {
  # The message has to be actionable: two of the three states exist for
  # dependencies that CANNOT name a version, and a reader who only knows
  # about the pinned form has no correct move.
  _one_good_pin
  _dockerfile 'ARG HADOLINT_VERSION=v2.12.0'
  _lint
  assert_failure
  assert_output --partial 'tool-pin: <name> github-release <owner>/<repo>'
  assert_output --partial 'tool-pin: unpinned <name>'
  assert_output --partial 'tool-pin: ignore'
}

# ════════════════════════════════════════════════════════════════════
# Non-vacuity: the lint must not pass because it read nothing
# ════════════════════════════════════════════════════════════════════

# why: A reader regression matching nothing would report a clean tree forever --
# the failure this guard exists to prevent one level up
@test "_run_pin_coverage: DIES when the scanned trees yield no pinned entry" {
  # A reader regression that matched nothing would otherwise report a
  # clean tree forever, which is the failure this guard exists to prevent
  # one level up.
  _dockerfile 'FROM scratch'
  _lint
  assert_failure
  assert_output --partial 'yielded no PINNED entry'
}

# why: A walk that opens no file is the same vacuous pass by the other road, and it
# must not be quieter than the first
@test "_run_pin_coverage: DIES when the walk yields no file at all" {
  rm -rf "${SCRATCH:?}"
  mkdir -p "${SCRATCH}/doc"
  git -C "${SCRATCH}" init -q
  printf 'hello\n' > "${SCRATCH}/doc/a.md"
  _lint
  assert_failure
  assert_output --partial 'no scannable file at all'
}

# ════════════════════════════════════════════════════════════════════
# The population: the files this repo TRACKS, and nothing else
# ════════════════════════════════════════════════════════════════════

# why: A generated directory inside the checkout made the verdict depend on whose
# machine ran the lint -- the one thing a gate must not do (base#987)
@test "_run_pin_coverage: an UNTRACKED file is not part of the population" {
  # The defect this replaced a prune roster to fix. `just test coverage`
  # writes kcov's HTML report into `coverage/` INSIDE the checkout, so the
  # CI coverage shard read kcov's bundled jQuery and reported its
  # `m="2.1.1"` as an undeclared third-party version, while the same
  # commit on a checkout that had never run coverage was clean. A roster
  # of trees not to read would have had to name `coverage/` in advance,
  # and the next generated directory reproduces it exactly.
  _one_good_pin
  _lint
  assert_success
  mkdir -p "${SCRATCH}/coverage/data/js"
  printf 'var m="2.1.1";\nFROM alpine:3.19\n' \
    > "${SCRATCH}/coverage/data/js/jquery.min.js"
  run _run_pin_coverage
  assert_success
}

# why: The other half of that rule: untracked-ness is the ONLY exemption, so a file
# the repo ships is read wherever it sits
@test "_run_pin_coverage: a TRACKED file anywhere is part of the population" {
  _one_good_pin
  mkdir -p "${SCRATCH}/some/deep/place"
  printf 'FROM alpine:3.19\n' > "${SCRATCH}/some/deep/place/Dockerfile"
  _lint
  assert_failure
  assert_output --partial 'some/deep/place/Dockerfile:1'
}

# why: The question the prune guard could not reach: check-ignore says yes for the
# whole tree while the file inside it is content this repo ships
@test "_run_pin_coverage: a force-added file inside an IGNORED tree is scanned" {
  # The old guard asked "is this tree ignored" and "is anything in it
  # tracked" as two separate questions about a roster entry, and a
  # force-added file could satisfy both at once -- ignored tree, tracked
  # content, out of the walk. Deriving the population from the index makes
  # the answer structural: the file is tracked, so it is read.
  _one_good_pin
  printf 'log/\n' > "${SCRATCH}/.gitignore"
  mkdir -p "${SCRATCH}/log"
  printf 'FROM alpine:3.19\n' > "${SCRATCH}/log/Dockerfile"
  git -C "${SCRATCH}" add -A
  git -C "${SCRATCH}" add -f log/Dockerfile
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'log/Dockerfile:1'
}

# why: An ignored tree nobody force-added is the ordinary case the old roster
# existed for, and it must stay quiet with no roster at all
@test "_run_pin_coverage: an ignored tree nobody tracked is simply absent" {
  _one_good_pin
  printf 'log/\n' > "${SCRATCH}/.gitignore"
  mkdir -p "${SCRATCH}/log" "${SCRATCH}/dist/log"
  printf 'FROM alpine:3.19\n' > "${SCRATCH}/log/Dockerfile"
  printf 'FROM alpine:3.19\n' > "${SCRATCH}/dist/log/Dockerfile"
  _lint
  assert_success
}

# why: This repo tracks eight symlinks into dist/, and reading through one yields a
# SECOND record for every marker in the target -- the duplicate-name check fires
@test "_run_pin_coverage: a tracked SYMLINK is a pointer, not content" {
  # `script/run.sh` and its siblings point into
  # `dist/script/docker/wrapper/`. Following one reads a file already in
  # the population under a second name, so every marker in it produces two
  # records with two `file` fields -- and the lint's own duplicate-NAME
  # check fails on the repo's real pins.
  _one_good_pin
  ln -s dist/dockerfile/Dockerfile "${SCRATCH}/Dockerfile.link"
  _lint
  assert_success
  assert_output --partial 'no undeclared version'
}

# why: The blobs-only rule was enforced on the git road only, so one checkout
# answered two ways depending on which road the environment took
@test "_run_pin_coverage: a carried list's symlink is a pointer too" {
  # The index modes are what tell a symlink from a blob, and a carried
  # list has none -- so this half of the population has to ask the tree.
  # Without that, `git ls-files` piped in by hand (which is what the
  # refusal message above asks a reader to supply) reads through the
  # repo's eight wrapper symlinks, and the duplicate-NAME check fails on
  # declarations that are fine.
  _one_good_pin
  ln -s dist/dockerfile/Dockerfile "${SCRATCH}/Dockerfile.link"
  git -C "${SCRATCH}" add -A
  local _files
  _files="$(git -C "${SCRATCH}" ls-files)"
  rm -rf "${SCRATCH:?}/.git"
  PIN_TRACKED_ROOT="${SCRATCH}" PIN_TRACKED_FILES="${_files}" \
    run _run_pin_coverage
  assert_success
  assert_output --partial 'no undeclared version'
}

# why: The registry used to be skipped where git was unreadable -- which is the
# container the local gate runs in, so fail-open was the default there
@test "_run_pin_coverage: DIES when the tracked set cannot be established" {
  # The guard this replaced was wrapped in `if git rev-parse --git-dir`,
  # so an environment it could not inspect got a PASS. The suite runs in a
  # container that bind-mounts the checkout without a resolvable .git,
  # which is the repo's own local gate -- so fail-open was the default in
  # the place the lint runs most. Reading a population nobody could
  # establish is the same fail-open one layer down.
  _one_good_pin
  git -C "${SCRATCH}" add -A
  rm -rf "${SCRATCH}/.git"
  run _run_pin_coverage
  assert_failure
  assert_output --partial 'could not establish which files'
}

# why: The container cannot answer and the host always can, so the population is
# computed where git works and carried in rather than skipped
@test "_run_pin_coverage: accepts a host-computed tracked list when git is gone" {
  _one_good_pin
  git -C "${SCRATCH}" add -A
  local _files
  _files="$(git -C "${SCRATCH}" ls-files)"
  rm -rf "${SCRATCH}/.git"
  PIN_TRACKED_ROOT="${SCRATCH}" PIN_TRACKED_FILES="${_files}" \
    run _run_pin_coverage
  assert_success
}

# why: The carried list has to be able to FAIL, or computing it on the host is just
# a longer way to pass
@test "_run_pin_coverage: FAILS on a carried list naming an undeclared version" {
  _one_good_pin
  _dockerfile 'ARG HADOLINT_VERSION=v2.12.0'
  git -C "${SCRATCH}" add -A
  local _files
  _files="$(git -C "${SCRATCH}" ls-files)"
  rm -rf "${SCRATCH}/.git"
  PIN_TRACKED_ROOT="${SCRATCH}" PIN_TRACKED_FILES="${_files}" \
    run _run_pin_coverage
  assert_failure
  assert_output --partial 'dockerfile/Dockerfile.test-tools:1'
}

# why: A list describing a DIFFERENT tree is not an answer about this one, and the
# suite container exports one describing /source into every case
@test "_run_pin_coverage: a carried list for another root is not consulted" {
  # PIN_TRACKED_FILES is keyed to the root it was computed for. Without
  # that key the container's list -- which describes /source -- would be
  # applied to any scratch tree a case builds, and the lint would report
  # on files that are not there.
  _one_good_pin
  git -C "${SCRATCH}" add -A
  rm -rf "${SCRATCH}/.git"
  PIN_TRACKED_ROOT=/source PIN_TRACKED_FILES='dockerfile/Dockerfile' \
    run _run_pin_coverage
  assert_failure
  assert_output --partial 'could not establish which files'
}

# why: A stale or hand-set list must not silence a file git can see; the handoff is
# for an environment with no git, never an override
@test "_run_pin_coverage: git OUTRANKS a carried tracked list" {
  _one_good_pin
  _dockerfile 'ARG HADOLINT_VERSION=v2.12.0'
  git -C "${SCRATCH}" add -A
  PIN_TRACKED_ROOT="${SCRATCH}" PIN_TRACKED_FILES='dist/dockerfile/Dockerfile' \
    run _run_pin_coverage
  assert_failure
  assert_output --partial 'dockerfile/Dockerfile.test-tools:1'
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

# why: This repo's own core artefact names its image with no docker verb anywhere
# on the line
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
  _lint
  assert_failure
  assert_output --partial 'alpine:3.21'
}

# why: The job runs inside this image, and dependabot can bump it no more than it
# can bump a run: one
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
  _lint
  assert_failure
  assert_output --partial 'alpine:3.21'
}

# why: The live shape: the migration's sed rewrote a FROM line, and only the
# namespaced half was caught -- the alpine half was invisible
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
  _lint
  assert_failure
  assert_output --partial 'alpine:3.21'
}

# why: The whole point of dropping the context roster: an unrecognised context has
# to raise the question rather than answer it
@test "_run_pin_coverage: FAILS on an image named by a key nothing anticipated" {
  # The whole point of dropping the context roster. Neither `image:` nor
  # `container:` nor any `docker` verb appears here, and the file shape is
  # one no earlier version of this lint looked at. An unrecognised context
  # must raise the question rather than pass.
  _one_good_pin
  printf 'fallback_image=alpine:3.21\n' > "${SCRATCH}/dist.setup.conf"
  _lint
  assert_failure
  assert_output --partial 'alpine:3.21'
}

# why: justfiles are this repo's control surface, so a container it actually starts
# is likelier to be named in one than in a shell script
@test "_run_pin_coverage: FAILS on a bare image named in a justfile" {
  # justfiles are this repo's control surface -- ADR-00000005 makes `just`
  # the single runner, so a container this repo actually starts is far
  # more likely to be named in one than in a shell script.
  _one_good_pin
  printf '%s\n' \
    'lint:' \
    '    docker run --rm alpine:3.21 true' \
    > "${SCRATCH}/justfile"
  _lint
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

# why: A published port is core idiom here and would have fired even under the old
# rule, so this is the noise the token rules buy down
@test "_run_pin_coverage: a published port is not a version" {
  # `-p 8080:8080` is core idiom here and would have fired even under the
  # old rule, which required only a `docker run` somewhere on the line.
  _one_good_pin
  mkdir -p "${SCRATCH}/dist/script"
  printf '%s\n' \
    'docker run --rm -p 8080:8080 "${IMAGE}" true' \
    > "${SCRATCH}/dist/script/gen.sh"
  _lint
  assert_success
}

# why: A UID:GID pair wears the same shape as a tag, and flagging it would teach
# people to mute the lint
@test "_run_pin_coverage: a UID:GID pair is not a version" {
  _one_good_pin
  mkdir -p "${SCRATCH}/dist/script"
  printf '%s\n' \
    'docker run --rm --user 1000:1000 "${IMAGE}" bats' \
    > "${SCRATCH}/dist/script/gen.sh"
  _lint
  assert_success
}

# why: You cannot depend on a version you are creating; -t names an output, which is
# a shape rule rather than a list of our own image names
@test "_run_pin_coverage: the image this repo BUILDS is not one it depends on" {
  # You cannot depend on a version you are creating. `-t`/`--tag` names an
  # OUTPUT, so the token it introduces is ours by construction -- which is
  # a shape rule, not a list of our image names.
  _one_good_pin
  mkdir -p "${SCRATCH}/dist/script"
  printf '%s\n' \
    'docker build --build-arg USER_UID=1000 -t base:0.1 .' \
    > "${SCRATCH}/dist/script/gen.sh"
  _lint
  assert_success
}

# why: A digest is already immutable, so there is no newer one to propose
@test "_run_pin_coverage: a digest is not a version" {
  # A digest is already immutable; there is no newer one to propose.
  _one_good_pin
  _workflow \
    'jobs:' \
    '  a:' \
    '    steps:' \
    '      - run: echo sha256:0123456789abcdef0123456789abcdef01234567'
  _lint
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# The scan surface: an exemption list, and it is checked
# ════════════════════════════════════════════════════════════════════

# why: A spec's heredoc IS the fixture under test, and the marker grammar cannot
# reach inside one without changing what the test feeds its subject
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
  _lint
  assert_success
}

# why: A version in prose is stale the way a sentence is stale -- a doc-review
# problem rather than a supply-chain one
@test "_run_pin_coverage: prose needs no marker" {
  _one_good_pin
  mkdir -p "${SCRATCH}/doc"
  printf 'Run `docker run --rm alpine:3.21 true` to check.\n' \
    > "${SCRATCH}/doc/guide.md"
  _lint
  assert_success
}

# why: The exemption list is the last hand-kept thing in the scan surface, so a
# marker in an exempt file is a belief in watching that nothing reads
@test "_run_pin_coverage: FAILS when a tool-pin marker sits in an unscanned file" {
  # The exemption list is the one hand-kept thing left in the scan
  # surface -- the population itself is derived now -- so it is checked
  # rather than trusted. A marker written in an exempt file is a pin its
  # author believes is watched and which nothing reads, and that belief is
  # exactly what this whole mechanism exists to make impossible.
  _one_good_pin
  mkdir -p "${SCRATCH}/test/bats/unit"
  printf '%s\n' \
    '# tool-pin: ghost github-release owner/ghost' \
    'ARG GHOST_VERSION=1.0.0' \
    > "${SCRATCH}/test/bats/unit/x_spec.bats"
  _lint
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

# why: local sat outside the keyword roster while the extraction regex already named
# it, so the convention pushed authors into the one invisible shape
@test "_run_pin_coverage: FAILS on a local= version with no marker" {
  _one_good_pin
  _script 'x.sh' \
    '_f() {' \
    "  local _bats_tag='1.13.0'" \
    '}'
  _lint
  assert_failure
  assert_output --partial 'declared with no tool-pin marker'
  assert_output --partial 'x.sh:2'
}

# why: readonly is the spelling this repo's style guide asks for, which makes it the
# likeliest place for an unwatched pin to land
@test "_run_pin_coverage: FAILS on a readonly= version with no marker" {
  _one_good_pin
  _script 'x.sh' 'readonly HELM_VERSION=3.16.2'
  _lint
  assert_failure
  assert_output --partial 'x.sh:1'
}

# why: export crosses into the environment a build reads, so a version declared
# there reaches further than the file it sits in
@test "_run_pin_coverage: FAILS on an export= version with no marker" {
  _one_good_pin
  _script 'x.sh' 'export TERRAFORM_VERSION="1.9.5"'
  _lint
  assert_failure
  assert_output --partial 'x.sh:1'
}

# why: No keyword at all is still an assignment, and the hoisting convention
# produces this shape as readily as the other three
@test "_run_pin_coverage: FAILS on a bare NAME=version with no marker" {
  # No keyword at all is still an assignment, and the hoisting convention
  # produces this shape as readily as the other three.
  _one_good_pin
  _script 'x.sh' 'KUBECTL_VERSION=1.31.0'
  _lint
  assert_failure
  assert_output --partial 'x.sh:1'
}

# why: The success path for the four shapes above, so the fix for all of them is one
# marker rather than four different answers
@test "_run_pin_coverage: a marked shell assignment satisfies the detector" {
  _one_good_pin
  _script 'x.sh' \
    '# tool-pin: bats dockerhub bats/bats pattern=.' \
    "local _bats_tag='1.13.0'"
  _lint
  assert_success
}

# why: This repo's scripts are full of counts, ports and timeouts, and a detector
# that flagged them would be muted within a week
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
  _lint
  assert_success
}

# why: An interpolating value references a pin rather than declaring one, exactly as
# a FROM on an ARG tag does
@test "_run_pin_coverage: an assignment whose value INTERPOLATES needs no marker" {
  # `local _t="${BATS_VERSION}"` references the pin; it does not declare
  # one, exactly as a `FROM alpine:${ALPINE_VERSION}` does not.
  _one_good_pin
  _script 'x.sh' \
    '_f() {' \
    '  local _tag="${BATS_VERSION}"' \
    '  local _url="releases/download/${HADOLINT_VERSION}/hadolint"' \
    '}'
  _lint
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

# why: kcov's own pin is a single-component tag, so the dot rule made this repo's
# own pin invisible to the guard meant to prove it was watched
@test "_run_pin_coverage: FAILS on a v-prefixed version with no dot" {
  _one_good_pin
  _dockerfile 'ARG KCOV_VERSION=v43'
  _lint
  assert_failure
  assert_output --partial 'declared with no tool-pin marker'
  assert_output --partial 'dockerfile/Dockerfile.test-tools:1'
}

# why: The shell half of the same rule -- a major action ref hoisted for a marker is
# dotless by construction
@test "_run_pin_coverage: FAILS on a v-prefixed major-only ref in a shell assignment" {
  _one_good_pin
  _script 'x.sh' 'readonly ACTION_MAJOR=v7'
  _lint
  assert_failure
  assert_output --partial 'x.sh:1'
}

# why: The success path for the dotless rule, so the fix is a marker rather than an
# artificial dot
@test "_run_pin_coverage: a marked dotless version satisfies the detector" {
  _one_good_pin
  _dockerfile \
    '# tool-pin: kcov github-release SimonKagstrom/kcov' \
    'ARG KCOV_VERSION=v43'
  _lint
  assert_success
}

# why: The stated cost of the v-prefix rule: a bare integer carries nothing that
# separates a release from a UID or a year
@test "_run_pin_coverage: a bare integer is still not a version" {
  # The stated cost of the rule above. `1000` and `2024` carry nothing
  # that separates a release from a UID or a year.
  _one_good_pin
  _dockerfile \
    'ARG USER_UID=1000' \
    'ARG THIRD_VERSION=2024'
  _lint
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# The real tree
# ════════════════════════════════════════════════════════════════════

# why: Drives the live tree, so the fixtures cannot drift away from the pins that
# actually ship
@test "_run_pin_coverage: the real repo tree declares every version it names" {
  REPO_ROOT=/source run _run_pin_coverage
  assert_success
  assert_output --partial 'pin-coverage lint: clean'
}

# why: Membership in that table is what gives the lint a CI job; without it the lint
# would gate only a local run
@test "_run_pin_coverage: pin-coverage is in test.sh's _LINT_TOOLS table" {
  # Membership is what gives it a CI job: self_test_yaml_spec asserts
  # every entry of that table is named by a job in self-test.yaml.
  run grep -E '^  pin-coverage$' /source/script/test/test.sh
  assert_success
}

# why: The host-direct entry point is how a bump proposal's author checks coverage
# without building the image
@test "_run_pin_coverage: --pin-coverage-only runs it host-direct" {
  run /source/script/test/test.sh --pin-coverage-only
  assert_success
  assert_output --partial 'pin-coverage lint: clean'
}
