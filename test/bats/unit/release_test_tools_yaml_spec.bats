#!/usr/bin/env bats
#
# release_test_tools_yaml_spec.bats — structural assertions for the
# `.github/workflows/release-test-tools.yaml` workflow.
#
# Locks the publish surface for the test-tools image consumed by every
# downstream Dockerfile.example (`FROM ${TEST_TOOLS_IMAGE} AS
# test-tools-stage`). The workflow has three publish modes; the first
# two ship behaviour that downstream CI depends on:
#
# 1. **Tag push (`v*`)** — multi-arch `:<version>` + `:latest`. Cuts
#    the release that downstream consumers pin via
#    `inputs.test_tools_version` on build-worker / publish-worker.
#
# 2. **Main push** (P2) — multi-arch `:main` rolling tag. The
#    template's own self-test.yaml pulls this in its Obtain step to
#    skip a from-source rebuild on every PR. The paths filter
#    restricts the trigger to commits that actually touched
#    Dockerfile.test-tools or this workflow, so most main-branch
#    merges don't churn GHCR.
#
# 3. **workflow_dispatch** — manual `:latest` republish. Bootstrap
#    path; kept un-filtered.
#
# Smoke test step uses `steps.tags.outputs.smoke` so it always pulls
# the tag the current trigger produced (rather than statically
# pulling :latest, which would leave a freshly-pushed :main
# unverified).

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

# ── Resolve tags step: 3 publish modes ───────────────────────────────

@test "release-test-tools.yaml: Resolve tags step handles v* tag push -> :<ver> + :latest" {
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

@test "release-test-tools.yaml: a release tag publishes :<ver> and moves :latest" {
  run _resolve_tags_for refs/tags/v0.42.0
  assert_success
  assert_output --partial 'tags=ghcr.io/ycpss91255-docker/test-tools:v0.42.0,ghcr.io/ycpss91255-docker/test-tools:latest'
  assert_output --partial 'smoke=ghcr.io/ycpss91255-docker/test-tools:v0.42.0'
}

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

@test "release-test-tools.yaml: a main push publishes the :main rolling tag only" {
  run _resolve_tags_for refs/heads/main
  assert_success
  assert_output --partial 'tags=ghcr.io/ycpss91255-docker/test-tools:main'
  assert_output --partial 'smoke=ghcr.io/ycpss91255-docker/test-tools:main'
  refute_output --partial ':latest'
}

@test "release-test-tools.yaml: a ref the resolver does not recognise is refused, never resolved to :latest (#1012)" {
  # `workflow_dispatch` is unrestricted by ref, so this arm is reachable
  # from any feature branch. Resolving it to the production tag makes an
  # unrecognised input the most destructive one.
  run _resolve_tags_for refs/heads/feature/whatever
  assert_failure
  refute_output --partial ':latest'
}

@test "release-test-tools.yaml: the header describes the tag rules the resolver applies (#1012)" {
  # The header promised `workflow_dispatch -> pushes only :latest`. A
  # dispatch from main carries GITHUB_REF=refs/heads/main and so takes the
  # main arm; the sentence described a branch the code cannot reach.
  run _header_comments
  assert_success
  refute_output --partial 'pushes only :latest'
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
