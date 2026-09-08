#!/usr/bin/env bats
#
# ghcr_publish_surface_spec.bats -- "this repo publishes only its own GHCR
# packages".
#
# ── What counts as a publish target, and why it is drawn this narrowly ──
#
# A PUBLISH TARGET is a bare `<key>: ghcr.io/<org>/<package>` YAML scalar
# on a code line -- no tag, no quotes, nothing after the package name.
# That is this repo's publisher idiom, and both publishers written to date
# use it: `release-test-tools.yaml:77` and, until base#1180, the retired
# `release-toml-bridge.yaml:49`, each declaring one workflow-level
# `env: IMAGE:` and pushing `${IMAGE}` everywhere below.
#
# A CONSUMER reference is deliberately NOT a publish target. Consumers
# carry a tag and usually quotes -- `TEST_TOOLS_IMAGE:
# "ghcr.io/ycpss91255-docker/test-tools:${{ inputs.test_tools_version }}"`
# in `build-worker.yaml`, the same as a build arg in a `run:` block. base
# is expected to grow more of these: base#1176 items 1 and 2 repoint this
# repo AT the published toml-bridge image. A rule that could not tell
# pushing from pulling would fail on that work, which is the opposite of
# what this guard is for.
#
# The cost of drawing it there is stated rather than hidden: a publisher
# that inlined its image instead of declaring `IMAGE:` would not be seen.
# The last case below pins the idiom against the live tree, so the day
# `release-test-tools.yaml` stops declaring its target this way, this
# spec fails and says so instead of quietly seeing nothing.
#
# The OWNED set is written here, once, with its reason -- and the check is
# set EQUALITY, not containment, so it fails in both directions: a
# publisher for a package not on the list, and the disappearance of the
# publisher for one that is.
#
# why: the set of GHCR packages this repo's workflows PUBLISH to, derived
# from `.github/workflows/` rather than listed anywhere, held equal to the
# packages this repo owns. A publisher for somebody else's package is not
# a broken build here -- it is green, and it moves a floating tag on a
# package another repo ships. `release-toml-bridge.yaml` was exactly that
# (base#1180): an unfiltered `tags: ['v*']` arm plus an
# `else tags="${tags},${IMAGE}:latest"` branch, on a package
# `ycpss91255-docker/toml-bridge` now owns and has published `v0.1.0` of,
# so the next non-RC tag cut here would have republished the name and
# moved `:latest` off the image that repo shipped. Nothing in the tree
# could have said so: that workflow carried no spec at all.

bats_require_minimum_version 1.5.0

# The org whose packages this repo may publish. A different org's package
# is somebody else's by construction.
readonly _ORG='ycpss91255-docker'

# The GHCR packages this repo owns and publishes, one per line. base
# publishes `test-tools` (`release-test-tools.yaml`) and, since base#1180,
# nothing else: `toml-bridge` moved to `ycpss91255-docker/toml-bridge`,
# which owns the package and publishes it from there.
readonly _OWNED_PACKAGES='test-tools'

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WF_DIR=/source/.github/workflows
  assert_spec_subject_dir "${WF_DIR}" \
      "the workflow directory whose publish targets this spec scans"
  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/wf"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _publish_targets <dir>
#   Every GHCR package under ${_ORG} that a workflow in <dir> declares as
#   a publish target, one per line, deduplicated and sorted.
#
#   Comment lines are dropped before the match: this header, and the
#   changelog-style prose a workflow carries about what it pushes, must
#   not be violations of the rule they describe, or the explanation
#   becomes unwritable.
_publish_targets() {
  local _dir="${1}" _f _code
  {
    while IFS= read -r _f; do
      [[ -n "${_f}" ]] || continue
      _code="$(grep -v '^[[:space:]]*#' -- "${_f}")" || :
      printf '%s\n' "${_code}" \
        | grep -oE "^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*:[[:space:]]+ghcr\.io/${_ORG}/[A-Za-z0-9._-]+[[:space:]]*$" \
        || :
    done <<< "$(workflow_files "${_dir}")"
  } | sed -E "s@^.*ghcr\.io/${_ORG}/@@; s@[[:space:]]*\$@@" | sort -u
}

# _wf <name> <line>... -- a workflow fixture, written verbatim.
_wf() {
  local _name="${1}"; shift
  printf '%s\n' "$@" > "${SCRATCH}/wf/${_name}.yaml"
}

# ── The scan detects the shape ──────────────────────────────────────────

# why: the rule bites, demonstrated over a fixture rather than over the
# live tree -- the only occurrence in this repo is the workflow base#1180
# deletes, so without a fixture this spec would go green by having nothing
# left to look at and could never go red again if the match stopped
# working.
@test "publish surface: a workflow declaring somebody else's package is reported" {
  _wf offender \
    'name: Release toml-bridge image to GHCR' \
    'on:' \
    '  push:' \
    '    tags: ["v*"]' \
    'env:' \
    "  IMAGE: ghcr.io/${_ORG}/toml-bridge"
  run _publish_targets "${SCRATCH}/wf"
  assert_success
  assert_output 'toml-bridge'
}

# why: the other half of a usable rule -- what this repo is SUPPOSED to
# publish has to read as clean, or the guard says stop without saying what
# to write instead.
@test "publish surface: this repo's own package is a target and is allowed" {
  _wf ours \
    'name: Release test-tools image to GHCR' \
    'env:' \
    "  IMAGE: ghcr.io/${_ORG}/test-tools"
  run _publish_targets "${SCRATCH}/wf"
  assert_success
  assert_output 'test-tools'
}

# why: the deliberate narrowing, pinned as behaviour rather than left in
# prose. base#1176 items 1 and 2 repoint this repo at the PUBLISHED
# toml-bridge image; a rule that read a pull as a push would fail that
# work, and the guard meant to protect the migration would block it.
@test "publish surface: a tagged consumer reference is not a publish target" {
  _wf consumer \
    'jobs:' \
    '  build:' \
    '    env:' \
    "      TEST_TOOLS_IMAGE: \"ghcr.io/${_ORG}/test-tools:v0.42.0\"" \
    '    steps:' \
    '      - run: |' \
    "          docker build --build-arg IMG=ghcr.io/${_ORG}/toml-bridge:v0.1.0 ."
  run _publish_targets "${SCRATCH}/wf"
  assert_success
  assert_output ''
}

# why: a workflow's own prose explains what it pushes, and this spec's
# header quotes the retired declaration it exists because of. A scan that
# could not tell prose from code would make both unwritable and push
# authors to delete the reasoning to get the lint green.
@test "publish surface: a comment naming a package is not a declaration" {
  _wf prose \
    "# Publishes ghcr.io/${_ORG}/toml-bridge, or it used to." \
    "#   IMAGE: ghcr.io/${_ORG}/toml-bridge" \
    'name: Something else'
  run _publish_targets "${SCRATCH}/wf"
  assert_success
  assert_output ''
}

# ── The real tree ───────────────────────────────────────────────────────

# why: the rule applied to the live tree, over a population derived from
# the directory rather than listed here -- which is what makes a publisher
# added tomorrow scanned the day it lands instead of the day somebody
# remembers this file exists. Set EQUALITY, so a publisher for a package
# this repo does not own fails, and so does losing the publisher for one
# it does.
@test "every GHCR package this repo publishes is one this repo owns" {
  run _publish_targets "${WF_DIR}"
  assert_success
  assert_output "${_OWNED_PACKAGES}"
}

# why: the named hazard, kept as its own case so the failure says WHY and
# not merely that a set differs. `ycpss91255-docker/toml-bridge` owns this
# package and has shipped v0.1.0 of it; a publisher here with an
# unfiltered `v*` arm moves `:latest` off that image on the next non-RC
# tag cut from main, silently and green (base#1180).
@test "no workflow here publishes the toml-bridge package, which another repo owns" {
  run _publish_targets "${WF_DIR}"
  assert_success
  refute_output --partial 'toml-bridge'
}

# why: the non-vacuity case, and the one that keeps the two above honest.
# An expected set satisfies them whether the scan read every workflow or
# none of them, and the narrow match above is worth exactly as much as its
# ability to still see this repo's one real publisher: the day
# `release-test-tools.yaml` stops declaring its target as a bare `IMAGE:`
# scalar, this fails and says so rather than reporting a clean surface it
# no longer looks at.
@test "the scan really walked this repo's workflows and still sees the real publisher" {
  local _n=0 _f
  while IFS= read -r _f; do
    [[ -n "${_f}" ]] || continue
    _n=$(( _n + 1 ))
  done <<< "$(workflow_files "${WF_DIR}")"
  [ "${_n}" -ge 5 ] || {
    echo "only ${_n} workflow(s) walked"
    return 1
  }
  assert_spec_subject "${WF_DIR}/release-test-tools.yaml" \
      "this repo's one real GHCR publisher, whose idiom the scan matches"
  run _publish_targets "${WF_DIR}"
  assert_success
  assert_output --partial 'test-tools'
}
