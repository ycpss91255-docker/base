#!/usr/bin/env bats
#
# release_test_tools_yaml_spec.bats — structural assertions for the
# `.github/workflows/release-test-tools.yaml` workflow.
#
# Locks the publish surface for the test-tools image consumed by every
# downstream Dockerfile.example (`FROM ${TEST_TOOLS_IMAGE} AS
# test-tools-stage`). The workflow has three triggers and two tag sets:
# the first two triggers each resolve one, and both ship behaviour that
# downstream CI depends on:
#
# 1. **Tag push (`v*`)** — multi-arch `:<version>`, plus `:latest` only
#    when the tag is NOT a prerelease. Cuts the release downstream
#    consumers pin via `inputs.test_tools_version` on build-worker /
#    publish-worker — whose default IS `latest`, which is why an RC tag
#    must leave it alone. `v0.42.0-rc1` through `-rc4` each matched the
#    `v*` trigger and each moved it.
#
# 2. **Main push** (P2) — multi-arch `:main` rolling tag. The
#    template's own self-test.yaml pulls this in its Obtain step to
#    skip a from-source rebuild on every PR. The paths filter
#    restricts the trigger to commits that actually touched
#    Dockerfile.test-tools or this workflow, so most main-branch
#    merges don't churn GHCR.
#
# 3. **workflow_dispatch** — no tag set of its own: it resolves by the
#    ref it was dispatched FROM (main takes the `:main` arm, a `v*` tag
#    takes the tag rules above). Unrestricted by ref, so any other ref is
#    REFUSED rather than resolved to the tag every downstream consumes.
#
# Smoke test step uses `steps.tags.outputs.smoke` so it always pulls
# the tag the current trigger produced (rather than statically
# pulling :latest, which would leave a freshly-pushed :main
# unverified).
#
# why: Structural assertions for
# `.github/workflows/release-test-tools.yaml`. Locks the publish surface
# that downstream Dockerfile.example's `FROM ${TEST_TOOLS_IMAGE} AS
# test-tools-stage` depends on. The workflow has three triggers and two tag
# sets -- the first two triggers each resolve one:
#
# 1. **Tag push (`v*`)** -- multi-arch `:<version>`, and `:latest` only when
# the tag is not a prerelease. Cuts the release downstream consumers pin via
# `inputs.test_tools_version`, whose default IS `latest`, which is why a
# prerelease tag must leave it alone.
#
# 2. **Main push** (P2) -- multi-arch `:main` rolling tag, pulled by
# self-test.yaml's Obtain step to skip from-source rebuilds. The paths
# filter (gotcha 3) restricts it to commits that touched
# `dockerfile/Dockerfile.test-tools` or this workflow.
#
# 3. **workflow_dispatch** -- no tag set of its own: it resolves by the ref
# it was dispatched from (main takes the `:main` arm, a `v*` tag takes the
# tag rules). Any other ref is refused, so an unrecognised input publishes
# nothing rather than overwriting `:latest`.
#
# The smoke step uses `steps.tags.outputs.smoke`, so it always pulls the tag
# the current trigger produced rather than statically pulling `:latest` and
# leaving a freshly-pushed `:main` unverified. Four of the cases below RUN
# the resolver rather than reading it: the step's own `run:` body is
# extracted with yq and executed against each ref shape. The text-reading
# cases above them stayed green through four RC tags that each moved
# `:latest`.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WF="/source/.github/workflows/release-test-tools.yaml"
  assert_spec_subject "${WF}" \
      "the test-tools release workflow this spec pins"
}

# _resolve_tags_step -- the code lines of the "Resolve tags" step, up to the
# next step. Comment-stripped: the step's prose explains the three publish
# modes by NAME, so an unstripped block lets the explanation stand in for the
# branch that implements it.
_resolve_tags_step() {
  awk '/Resolve tags/{flag=1} /^      - name:/{ if (flag && !first) {first=1; next} else if (flag) {flag=0}} flag' "${WF}" \
    | strip_comments
}

# _smoke_step -- the code lines from the "Smoke test pushed image" step on.
_smoke_step() {
  awk '/Smoke test pushed image/{flag=1} flag' "${WF}" | strip_comments
}

# _repo_root -- the checkout this spec reads, derived from the spec's own
# location rather than restated, so the helpers below and ${WF} above cannot
# disagree about which tree is under test.
_repo_root() {
  (cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)
}

# _resolve_tags_for <ref> -- RUN the workflow's own "Resolve tags" step
# against <ref>, and print the `key=value` lines it wrote to GITHUB_OUTPUT.
#
# The body is read OUT OF THE WORKFLOW (yq over that step's `run:`) instead
# of being restated here: a spec that carried its own copy of the resolver
# would keep agreeing with itself while the workflow drifted, which is how
# a tag arm came to move `:latest` on four consecutive RC tags with the
# structural assertions above all green.
#
# The status is the step's OWN. A ref the resolver refuses must be
# observable as a FAILURE and not merely as an absence of output -- the
# defect being pinned here is precisely a branch that resolved silently
# and successfully to the most-consumed tag in the registry.
_resolve_tags_for() {
  local _ref="${1}" _dir _body _status=0
  _body="$(RTT_STEP='Resolve tags' yq -r \
      '.jobs.merge.steps[] | select(.name == strenv(RTT_STEP)) | .run' \
      "${WF}" 2>&1)" || {
    printf 'BUG: yq could not read the Resolve tags step of %s: %s\n' \
        "${WF}" "$(printf '%s' "${_body}" | tr '\n' ' ')"
    return 2
  }
  if [[ -z "${_body}" || "${_body}" == 'null' ]]; then
    printf 'BUG: %s declares no "Resolve tags" step in its merge job\n' "${WF}"
    return 2
  fi
  _dir="$(mktemp -d)"
  printf '%s\n' "${_body}" > "${_dir}/step.sh"
  (
    cd -- "$(_repo_root)" || exit 2
    GITHUB_REF="${_ref}" \
    IMAGE='ghcr.io/ycpss91255-docker/test-tools' \
    GITHUB_OUTPUT="${_dir}/out" \
      bash "${_dir}/step.sh" > /dev/null
  ) || _status=$?
  if [[ -f "${_dir}/out" ]]; then
    cat "${_dir}/out"
  fi
  rm -rf "${_dir}"
  return "${_status}"
}

# _header_comments -- the file's header prose: every line above the `on:`
# key, comments only. What the header CLAIMS is checked against what the
# resolver above actually DOES; a header describing a branch the code
# cannot reach is a defect with the same shape as the code one.
_header_comments() {
  awk '/^on:/{exit} {print}' "${WF}" | only_comments
}

# _merge_checkout_rationale -- the merge job's prose above its Checkout step.
# That job needs the tree for one reason (the smoke step compares the
# published image against the declaration it was built from), and the
# sentence naming that reason is the thing a reader follows to the file
# doing the comparison.
_merge_checkout_rationale() {
  yaml_job_text "${WF}" merge | awk '/- name: Checkout/{exit} {print}' \
    | only_comments
}

# _resolve_tags_prose -- the "Resolve tags" step's OWN comment block, from
# the step's name down to its `run:` body.
#
# Every other reader of that step in this file strips its comments on
# purpose, so that the explanation cannot stand in for the branch that
# implements it -- which leaves the block itself read by nothing. It is the
# longest description of the tag rules anywhere in the tree, so a sentence
# in it that survived the rules changing is the description a reader is
# most likely to believe.
_resolve_tags_prose() {
  awk '/- name: Resolve tags/{flag=1} flag && /^ *run: \|/{exit} flag' \
    "${WF}" | only_comments
}

# _spec_prose -- THIS file's own prose about the surface it pins: the header
# above, the section dividers, and every `@test` NAME.
#
# A spec's header is read far more often than its cases, so a header still
# describing the behaviour the cases refute misinforms every later reader
# -- the same defect as a workflow header describing an unreachable branch,
# one file over. A case NAME is read more often still: it is what the TAP
# output prints, so a name promising the old surface reports the new one
# under the old description on every green run. They are one reader
# because they are one property; splitting them is how half of it came to
# be corrected and the other half left standing.
_spec_prose() {
  local _self="${BATS_TEST_DIRNAME}/release_test_tools_yaml_spec.bats"
  awk '/^bats_require_minimum_version/{exit} {print}' "${_self}" \
    | only_comments
  grep -E '^(@test|# .*──)' "${_self}"
}

# ── Trigger surface ──────────────────────────────────────────────────

@test "release-test-tools.yaml: triggers on tag push v* (existing)" {
  run yaml_top_lines "${WF}" on
  assert_success
  assert_output --partial 'tags:'
  assert_output --partial "'v*'"
}

@test "release-test-tools.yaml: triggers on main push (#317 P2)" {
  run yaml_top_lines "${WF}" on
  assert_success
  assert_output --partial 'branches: [main]'
}

@test "release-test-tools.yaml: main push trigger has paths filter limiting to Dockerfile.test-tools + workflow self (#317 P2 gotcha-3)" {
  run yaml_top_lines "${WF}" on
  assert_success
  assert_output --partial 'paths:'
  assert_output --partial "'dockerfile/Dockerfile.test-tools'"
  assert_output --partial "'.github/workflows/release-test-tools.yaml'"
}

@test "release-test-tools.yaml: triggers on workflow_dispatch (existing)" {
  run yaml_top_lines "${WF}" on
  assert_success
  assert_output --partial 'workflow_dispatch:'
}

# ── Resolve tags step: the two tag sets, read ────────────────────────

@test "release-test-tools.yaml: Resolve tags step handles v* tag push -> :<ver>, and :latest for a finished release" {
  run _resolve_tags_step
  assert_success
  assert_output --partial 'refs/tags/v*'
  assert_output --partial ':${ver}'
  assert_output --partial ':latest'
}

@test "release-test-tools.yaml: Resolve tags step handles main push -> :main rolling tag (#317 P2)" {
  run _resolve_tags_step
  assert_success
  assert_output --partial 'refs/heads/main'
  assert_output --partial ':main'
}

@test "release-test-tools.yaml: Resolve tags step emits a smoke output tracking the current trigger's tag (#317 P2)" {
  run _resolve_tags_step
  assert_success
  assert_output --partial 'smoke='
}

# ── Resolve tags: the decision, exercised ────────────────────────────
#
# The four assertions above read the step's TEXT. These four RUN it, over
# the four ref shapes that reach this workflow.

# why: The arm the four text-reading cases above only READ. It is the one
# ref shape allowed to move the tag every unpinned downstream builds its
# lint stage from.
@test "release-test-tools.yaml: a release tag publishes :<ver> and moves :latest" {
  run _resolve_tags_for refs/tags/v0.42.0
  assert_success
  assert_output --partial 'tags=ghcr.io/ycpss91255-docker/test-tools:v0.42.0,ghcr.io/ycpss91255-docker/test-tools:latest'
  assert_output --partial 'smoke=ghcr.io/ycpss91255-docker/test-tools:v0.42.0'
}

# why: The load-bearing case: `v0.42.0-rc1` through `-rc4` each matched the
# `v*` trigger and each moved the tag whose default every unpinned
# downstream inherits, for the length of an RC window.
@test "release-test-tools.yaml: an RC tag publishes :<ver> and leaves :latest where it was (#1012)" {
  # v0.42.0-rc1..rc4 each matched the `v*` trigger and each moved
  # `:latest`, so every downstream repo that does not pin
  # `test_tools_version` (its default IS "latest") built its lint stage
  # from an RC image for the whole RC window.
  run _resolve_tags_for refs/tags/v0.42.0-rc4
  assert_success
  assert_output --partial 'tags=ghcr.io/ycpss91255-docker/test-tools:v0.42.0-rc4'
  assert_output --partial 'smoke=ghcr.io/ycpss91255-docker/test-tools:v0.42.0-rc4'
  refute_output --partial ':latest'
}

# why: The rolling tag self-test.yaml pulls to skip a from-source rebuild;
# it must not reach `:latest` either.
@test "release-test-tools.yaml: a main push publishes the :main rolling tag only" {
  run _resolve_tags_for refs/heads/main
  assert_success
  assert_output --partial 'tags=ghcr.io/ycpss91255-docker/test-tools:main'
  assert_output --partial 'smoke=ghcr.io/ycpss91255-docker/test-tools:main'
  refute_output --partial ':latest'
}

# why: `workflow_dispatch` is unrestricted by ref, so this arm is reachable
# from any feature branch: resolving it to the production tag made the
# unrecognised input the most destructive one.
@test "release-test-tools.yaml: a ref the resolver does not recognise is refused, never resolved to :latest (#1012)" {
  # `workflow_dispatch` is unrestricted by ref, so this arm is reachable
  # from any feature branch. Resolving it to the production tag makes an
  # unrecognised input the most destructive one.
  run _resolve_tags_for refs/heads/feature/whatever
  assert_failure
  refute_output --partial ':latest'
}

# why: A header describing a branch the code cannot reach is a defect with
# the same shape as the code one, and it is what a later reader believes
# over the code.
@test "release-test-tools.yaml: the header and the resolver step's own prose describe the tag rules it applies (#1012)" {
  # The header promised `workflow_dispatch -> pushes only :latest`. A
  # dispatch from main carries GITHUB_REF=refs/heads/main and so takes the
  # main arm; the sentence described a branch the code cannot reach.
  run _header_comments
  assert_success
  refute_output --partial 'pushes only :latest'
  assert_output --partial 'prerelease'

  # The step's own block is the second half of the same property. It
  # opened on "Three publish modes, three tag sets" -- written when the
  # third arm published `:latest` -- and the paragraphs beneath it were
  # rewritten to say that arm now publishes nothing, which left the
  # summary sentence contradicting the four paragraphs under it.
  run _resolve_tags_prose
  assert_success
  refute_output --partial 'three tag sets'
  assert_output --partial 'prerelease'
  assert_output --partial 'publishes NOTHING'
}

# why: What keeps the correction from being half made: a case NAME is what
# the TAP line prints, so a stale one reports the new behaviour under the
# old description on every green run.
@test "release-test-tools.yaml: this spec's own prose -- header, dividers and case names -- describes the surface it pins (#1012)" {
  # The header above is the first thing a reader of this file meets, and it
  # documented the surface these cases now refute: `:<version>` + `:latest`
  # on every `v*` tag, and a `workflow_dispatch` that republishes
  # `:latest`. Both are what four RC tags did to `:latest` and what an
  # unrecognised dispatch ref could still do. The workflow's header was
  # corrected and this one was not, which leaves the correction half made
  # -- and a reader who trusts the header reads the cases as the anomaly.
  #
  # The case NAMES and the section dividers are the same prose at a site
  # that is read more often, not less: a name is what the TAP line prints.
  # `-> :<ver> + :latest` stayed on the case that reads the step's text
  # while the case three lines below it proves an RC tag leaves `:latest`
  # alone, so a green run printed both.
  run _spec_prose
  assert_success
  refute_output --partial 'republish'
  refute_output --partial '+ `:latest`'
  refute_output --partial '+ :latest'
  refute_output --partial '3 publish modes'
  assert_output --partial 'prerelease'
}

# ── Smoke test step ──────────────────────────────────────────────────

@test "release-test-tools.yaml: smoke step pulls the trigger's tag (not statically :latest) (#317 P2)" {
  # Avoids the regression where main push publishes :main but the
  # smoke step still pulls (and verifies) the stale :latest from the
  # previous tag.
  run _smoke_step
  assert_success
  assert_output --partial 'steps.tags.outputs.smoke'
}

# why: One loop over the pins the Dockerfile declares, rather than fourteen
# hand-written comparisons that leave the next tool unasserted the day it is
# pinned.
@test "release-test-tools.yaml: the smoke step derives its version assertions from the pin roster (#1012)" {
  # Fourteen of the fifteen probes asserted exit 0 and nothing else,
  # which catches a tool's removal and never its staleness. The repair is
  # not fourteen hand-written comparisons: it is one loop over the pins
  # the Dockerfile declares, so a tool pinned tomorrow is asserted
  # tomorrow. script/ci/test-tools-pins.sh refuses to produce a roster
  # while any declared pin lacks a probe.
  run _smoke_step
  assert_success
  assert_output --partial 'script/ci/test-tools-pins.sh roster'
  assert_output --partial 'script/ci/test-tools-pins.sh check'
  refute_output --partial 'just_pin='
}

# why: A loop fed by a command that failed simply gets no input and passes,
# which is fail-open for a step whose whole assertion is that the versions
# were checked.
@test "release-test-tools.yaml: the smoke step refuses an empty pin roster (#1012)" {
  # A loop fed by a command that failed simply gets no input and passes.
  # For a step whose whole assertion is "the versions were checked", that
  # is the fail-open direction, so emptiness is refused by name.
  run _smoke_step
  assert_success
  assert_output --partial 'the pin roster came back empty'
}

# why: That sentence is what a reader follows to the file doing the
# comparison, and it still named the accessor the step had stopped opening.
@test "release-test-tools.yaml: the merge job's checkout rationale names what the smoke step reads (#1012)" {
  # That job checks the tree out for exactly one reason, and the sentence
  # saying so still sent a reader to dist/script/base/just-version.sh --
  # the file the smoke step compared `just` against BEFORE this workflow
  # started iterating the pin roster instead. The step no longer opens it,
  # so the rationale named a dependency the job does not have and hid the
  # one it does.
  run grep -n 'just-version\.sh' "${WF}"
  assert_failure
  run _merge_checkout_rationale
  assert_success
  assert_output --partial 'test-tools-pins.sh'
}

# ── Native-runner matrix + push-by-digest + manifest merge ─────

@test "release-test-tools.yaml: drops docker/setup-qemu-action (native arm64 runner, #587)" {
  # Each arch builds on its native runner, so the QEMU emulation layer
  # is gone.
  run code_grep -F 'docker/setup-qemu-action' "${WF}"
  assert_failure
}

@test "release-test-tools.yaml: compute-matrix job maps platforms to native runners (#587)" {
  run code_grep -E '^  compute-matrix:' "${WF}"
  assert_success
  run code_grep -F 'ubuntu-24.04-arm' "${WF}"
  assert_success
  run code_grep -F 'ubuntu-latest' "${WF}"
  assert_success
}

@test "release-test-tools.yaml: build shards run on the matrix runner (#587)" {
  run code_grep -F 'runs-on: ${{ matrix.runner }}' "${WF}"
  assert_success
}

@test "release-test-tools.yaml: build shards build per-platform and push by digest (#587)" {
  # A single-arch build per shard pushed BY DIGEST (no tag); the tags
  # are applied by the merge job's manifest-list create. This is what
  # keeps the published tag a true multi-arch manifest instead of a
  # last-shard-wins single-arch overwrite.
  run code_grep -F 'platforms: ${{ matrix.platform }}' "${WF}"
  assert_success
  run code_grep -F 'push-by-digest=true' "${WF}"
  assert_success
}

@test "release-test-tools.yaml: merge job creates the multi-arch manifest via imagetools (#587)" {
  run code_grep -F 'docker buildx imagetools create' "${WF}"
  assert_success
}

@test "release-test-tools.yaml: declares packages: write permission for GHCR push" {
  run code_grep -E '^\s+packages:\s+write' "${WF}"
  assert_success
}

# ── Same-repository guard on the self-hosted-eligible build job ────────

# why: Inert today -- this workflow has no `pull_request` trigger at all --
# so that adding one later cannot open the hole silently.
@test "release-test-tools.yaml: the build job carries the same-repo guard (#766)" {
  # Self-hosted-eligible by the static rule: `runs-on: ${{ matrix.runner }}`
  # over a runtime-computed matrix. This workflow has no `pull_request`
  # trigger at all today, so the condition is inert -- it is here so that
  # adding one later cannot open the hole silently.
  run yaml_job_lines "${WF}" build
  assert_success
  assert_output --partial "github.event_name != 'pull_request' ||"
  assert_output --partial 'github.event.pull_request.head.repo.full_name == github.repository'
}
