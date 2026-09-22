#!/usr/bin/env bats
#
# ghcr_publish_surface_spec.bats -- "this repo publishes only its own GHCR
# packages".
#
# ── What counts as a publish target, and why the operation decides ─────
#
# A workflow file is a PUBLISHER if, on a code line, it performs a
# publishing operation: `docker push`, `docker buildx build` with
# `--push`, `docker buildx imagetools create`, `crane push`, `skopeo copy`,
# or docker/build-push-action's push input in either spelling it takes
# (`push: true` under `with:`, or `push=true` inside an `outputs:` string,
# which is how `release-test-tools.yaml` writes it). A file with none of
# these is a CONSUMER: whatever images it names, it only pulls them, and
# it contributes no targets.
#
# In a PUBLISHER, every literal `ghcr.io/<org>/<package>` reference on a
# code line is a PUBLISH TARGET, normalised to `<org>/<package>`: the tag
# (`:v1`, `:${{ github.ref_name }}`), a digest (`@sha256:...`) and any
# quotes are dropped. The operation decides, not the spelling. A tagged
# image is not a pull because it carries a tag -- fed to a push it is
# exactly the hazard this guard exists for -- and a consumer's tagged
# reference (`TEST_TOOLS_IMAGE: "ghcr.io/ycpss91255-docker/test-tools:${{
# inputs.test_tools_version }}"` in `build-worker.yaml`, which sets
# `push: false` throughout) is not a target because nothing in that file
# pushes. base is expected to grow more consumers: base#1176 items 1 and 2
# repoint this repo AT the published toml-bridge image, and this rule
# leaves that work alone.
#
# Both publishers written to date declare one workflow-level `env: IMAGE:`
# and push `${IMAGE}` below it: `release-test-tools.yaml:77` and, until
# base#1180, the retired `release-toml-bridge.yaml:49`. That idiom is no
# longer what the scan keys on, but the last case below still pins it
# against the live tree, so the day `release-test-tools.yaml` stops naming
# its target as a literal this spec fails and says so instead of quietly
# seeing nothing.
#
# The cost that remains is stated rather than hidden: a target assembled
# entirely from expressions (`${{ inputs.registry }}/${{
# github.repository_owner }}/...`, as `publish-worker.yaml` does for the
# downstream image it builds on behalf of a caller) is not a literal and
# is not seen. Comment lines are dropped before either match, so a
# workflow's own prose about what it pushes, and this header, are not
# violations of the rule they describe.
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

# The org this repo's packages live under. It names the fixtures and the
# owned set below; it does NOT narrow the scan, which reports a GHCR
# target under any org -- a different org's package is somebody else's by
# construction, and a scan that only looked here would look past it.
readonly _ORG='ycpss91255-docker'

# The GHCR packages this repo owns and publishes, fully qualified as
# `<org>/<package>`, one per line. base publishes `test-tools`
# (`release-test-tools.yaml`) and, since base#1180, nothing else:
# `toml-bridge` moved to `ycpss91255-docker/toml-bridge`, which owns the
# package and publishes it from there.
readonly _OWNED_PACKAGES="${_ORG}/test-tools"

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

# A publishing operation, on a code line. Any one of these makes the file
# a publisher. `push:[[:space:]]*true` is build-push-action's input under
# `with:`; `push=true` is the same input inside its `outputs:` string. The
# bare `push:` key that names a workflow trigger (`on: push:`) matches
# neither.
readonly _PUBLISH_OP='docker push|docker buildx build[^#]*--push|docker buildx imagetools create|crane push|skopeo copy|push:[[:space:]]*true([[:space:]]|$)|push=true'

# A literal GHCR reference: org and package, each starting alphanumeric so
# prose like `ghcr.io/.../name` is not an org. The match stops at a tag,
# a digest or a closing quote, which is what normalises the reference.
readonly _GHCR_REF='ghcr\.io/[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*'

# _publish_targets <dir>
#   Every GHCR package, under any org, that a PUBLISHER workflow in <dir>
#   references, as `<org>/<package>` one per line, deduplicated and
#   sorted. A file without a publishing operation contributes nothing.
#
#   Comment lines are dropped before either match: this header, and the
#   changelog-style prose a workflow carries about what it pushes, must
#   not be violations of the rule they describe, or the explanation
#   becomes unwritable.
_publish_targets() {
  local _dir="${1}" _f _code
  {
    while IFS= read -r _f; do
      [[ -n "${_f}" ]] || continue
      _code="$(grep -v '^[[:space:]]*#' -- "${_f}")" || :
      printf '%s\n' "${_code}" | grep -qE "${_PUBLISH_OP}" || continue
      printf '%s\n' "${_code}" | grep -oE "${_GHCR_REF}" || :
    done <<< "$(workflow_files "${_dir}")"
  } | sed -E 's@^ghcr\.io/@@' | sort -u
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
    "  IMAGE: ghcr.io/${_ORG}/toml-bridge" \
    'jobs:' \
    '  merge:' \
    '    steps:' \
    '      - run: docker buildx imagetools create -t "${IMAGE}:latest" "${src[@]}"'
  run _publish_targets "${SCRATCH}/wf"
  assert_success
  assert_output "${_ORG}/toml-bridge"
}

# why: a package under a different org is somebody else's by construction,
# and a guard anchored to this repo's org would look straight past it:
# `IMAGE: ghcr.io/another-org/toml-bridge` would produce nothing, and the
# live equality check would stay green. So the scan reports every GHCR
# target it sees, org included, and the owned set is spelled fully
# qualified to match.
@test "publish surface: a package in another org is reported, org included" {
  _wf elsewhere \
    'name: Release somebody else'"'"'s image to GHCR' \
    'env:' \
    '  IMAGE: ghcr.io/another-org/toml-bridge' \
    '      - run: docker push "${IMAGE}"'
  run _publish_targets "${SCRATCH}/wf"
  assert_success
  assert_output 'another-org/toml-bridge'
}

# why: a quoted scalar is an ordinary YAML spelling of the same value, and
# the guard exists to catch a publisher added by accident, not one written
# in the idiom the guard happened to expect. The operation decides; the
# spelling around the reference is dropped.
@test "publish surface: a double-quoted untagged image is a publish target" {
  _wf quoted \
    'env:' \
    '  IMAGE: "ghcr.io/another-org/package"' \
    '      - run: docker push "${IMAGE}"'
  run _publish_targets "${SCRATCH}/wf"
  assert_success
  assert_output 'another-org/package'
}

# why: the other quote style, pinned on its own so the match cannot
# quietly accept one and miss the other.
@test "publish surface: a single-quoted untagged image is a publish target" {
  _wf squoted \
    'env:' \
    "  IMAGE: 'ghcr.io/another-org/package'" \
    '      - run: docker push "${IMAGE}"'
  run _publish_targets "${SCRATCH}/wf"
  assert_success
  assert_output 'another-org/package'
}

# why: the other half of a usable rule -- what this repo is SUPPOSED to
# publish has to read as clean, or the guard says stop without saying what
# to write instead.
@test "publish surface: this repo's own package is a target and is allowed" {
  _wf ours \
    'name: Release test-tools image to GHCR' \
    'env:' \
    "  IMAGE: ghcr.io/${_ORG}/test-tools" \
    '      - run: docker buildx imagetools create -t "${IMAGE}:latest" "${src[@]}"'
  run _publish_targets "${SCRATCH}/wf"
  assert_success
  assert_output "${_ORG}/test-tools"
}

# why: the consumer shape this repo already has, pinned as behaviour
# rather than left in prose: tagged references in a file that never
# pushes. base#1176 items 1 and 2 repoint this repo at the PUBLISHED
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
# authors to delete the reasoning to get the lint green. The fixture is a
# real publisher, so this also shows a comment cannot name a target.
@test "publish surface: a comment naming a package is not a declaration" {
  _wf prose \
    "# Publishes ghcr.io/${_ORG}/toml-bridge, or it used to." \
    "#   IMAGE: ghcr.io/${_ORG}/toml-bridge" \
    '# and a comment that says docker push is not a push either' \
    'name: Something else' \
    '      - run: docker push "${SOMEWHERE_ELSE}"'
  run _publish_targets "${SCRATCH}/wf"
  assert_success
  assert_output ''
}

# ── The operation decides, not the spelling ─────────────────────────────

# why: a tagged image fed to a push is exactly the hazard this guard is
# for. A publisher that declared `IMAGE: ghcr.io/another-org/package:latest`
# and pushed it would move that repo's floating tag, and a scan that read
# the tag as "consumer" would wave it through.
@test "publish surface: a tagged image in a file that pushes is a publish target" {
  _wf tagged-push \
    'env:' \
    '  IMAGE: ghcr.io/another-org/package:latest' \
    'jobs:' \
    '  publish:' \
    '    steps:' \
    '      - run: docker push "${IMAGE}"'
  run _publish_targets "${SCRATCH}/wf"
  assert_success
  assert_output 'another-org/package'
}

# why: the same tagged reference in a file that never pushes anything is
# a pull, and contributes nothing. This is what keeps the base#1176
# repoint (this repo consuming the published toml-bridge image) clean.
@test "publish surface: a tagged image in a file that never pushes is not a target" {
  _wf tagged-pull \
    'jobs:' \
    '  build:' \
    '    env:' \
    '      TOML_BRIDGE_IMAGE: ghcr.io/another-org/toml-bridge:v0.1.0' \
    '    steps:' \
    '      - run: docker pull "${TOML_BRIDGE_IMAGE}"'
  run _publish_targets "${SCRATCH}/wf"
  assert_success
  assert_output ''
}

# why: build-push-action is the other way this repo pushes, and its
# `push: true` input is the operation. A tagged ref in that file is a
# target whatever the tag says.
@test "publish surface: build-push-action with push true makes its tagged ref a target" {
  _wf action-push \
    'jobs:' \
    '  publish:' \
    '    steps:' \
    '      - uses: docker/build-push-action@v7' \
    '        with:' \
    '          push: true' \
    '          tags: ghcr.io/another-org/package:${{ github.ref_name }}'
  run _publish_targets "${SCRATCH}/wf"
  assert_success
  assert_output 'another-org/package'
}

# why: the same action with `push: false` builds and keeps the result
# local; no package moves, so the file is a consumer and contributes
# nothing. build-worker.yaml is this shape.
@test "publish surface: build-push-action with push false contributes nothing" {
  _wf action-nopush \
    'jobs:' \
    '  build:' \
    '    steps:' \
    '      - uses: docker/build-push-action@v7' \
    '        with:' \
    '          push: false' \
    '          tags: ghcr.io/another-org/package:${{ github.ref_name }}'
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
# none of them, and the match above is worth exactly as much as its
# ability to still see this repo's real publisher: the day
# `release-test-tools.yaml` stops pushing through an operation the scan
# knows, or stops naming its target as a literal, this fails and says so
# rather than reporting a clean surface it no longer looks at.
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
