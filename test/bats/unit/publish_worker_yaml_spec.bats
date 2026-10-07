#!/usr/bin/env bats
#
# publish_worker_yaml_spec.bats — structural assertions for the
# `.github/workflows/publish-worker.yaml` reusable workflow.
#
# publish-worker is the opt-in `call-publish` reusable workflow that
# foundational image repos (ros_distro / ros2_distro) reference to push
# their Dockerfile target stage to a registry on tag push. Downstream
# app repos consume the result via `FROM ${registry}/${owner}/<image>`.
#
# the original `publish` job was a per-platform matrix where every
# shard pushed the SAME computed tag(s) via `push: true` + `tags:`. With
# a 2-platform matrix the second shard's single-arch manifest overwrites
# the first at the tag — a last-shard-wins single-arch image, not a
# multi-arch manifest list (despite the docstring claiming otherwise).
# The fix mirrors the release-test-tools pattern: each shard pushes
# BY DIGEST (no tag), uploads its digest as an artifact, and a `merge`
# job assembles the tagged manifest list via
# `docker buildx imagetools create`. These guards lock that contract.
#
# why: Structural assertions for the `.github/workflows/publish-worker.yaml`
# reusable `call-publish` workflow (foundational image repos push their
# Dockerfile target stage to a registry on tag push; downstream app repos
# consume via `FROM ${registry}/${owner}/<image>`). #602: the original
# `publish` job had every matrix shard push the SAME computed tag(s) via
# `push: true` + `tags:`, leaving a last-shard-wins single-arch tag on a
# multi-platform call (no manifest merge). The fix mirrors the #587
# release-test-tools pattern — each shard pushes by digest, uploads its
# digest, and a `merge` job assembles the tagged manifest list via `docker
# buildx imagetools create`. These guards lock that contract.
#
# Grouped by concern:
#
# - Stays a reusable `workflow_call` workflow; preserves the
# registry-parameterised inputs
#
# - Native-runner matrix: `compute-matrix` maps platforms to native runners;
# build shards run on `matrix.runner`
#
# - Push-by-digest per shard (#602): build pushes by digest; no shared
# same-tag-per-shard push (regression guard); digest exported + uploaded as
# artifact
#
# - Merge job (#602): downloads digests + creates the manifest via
# `imagetools`; resolves tags from inputs once; login uses the parameterised
# registry
#
# - Every job's grant pinned as an exact per-job entry set, over the job
# list derived from the file -- `packages: write` on `publish` + `merge`
# only, `compute-matrix` read-only. Replaces a `grep -c
# '^\s+packages:\s+write' >= 2` count, which was blind to WHICH job held the
# scope, to a third job acquiring it, and to any other scope beside it
#
# - Same-repo guard on the self-hosted-eligible `publish` job (#766)

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WF="/source/.github/workflows/publish-worker.yaml"
  assert_spec_subject "${WF}" \
      "the reusable publish worker this spec pins"
  # Scratch for the tag-confirmation cases, which RUN that step's own body
  # against a stubbed registry rather than reading it.
  SCRATCH="$(mktemp -d)"
}

teardown() {
  if [[ -n "${SCRATCH:-}" ]]; then
    rm -rf "${SCRATCH}"
  fi
}

# _resolve_tags_onward / _merge_onward -- the code lines from a named point
# to the end of the workflow. Open-ended on purpose (the tag resolution and
# the merge job are both the last of their kind), comment-stripped so the
# prose that explains the tag scheme cannot stand in for the code that
# builds it.
_resolve_tags_onward() {
  awk '/Resolve tags/{flag=1} flag' "${WF}" | strip_comments
}

_merge_onward() {
  awk '/^  merge:/{flag=1} flag' "${WF}" | strip_comments
}

# _smoke_step -- the code lines of the merge job's smoke step, and of that
# step only. Bounded by the parser rather than by "from this name onward",
# because the manifest create now sits BELOW it: an open-ended read would let
# a string the create step carries satisfy an assertion made about the smoke
# step, including the one about which reference it verifies.
_smoke_step() {
  yaml_step_run "${WF}" merge 'Smoke test the pushed image' | strip_comments
}

# _confirm_step_name -- the one place the confirmation step's name is written,
# so the helpers below and the assertions cannot drift apart over a rename.
readonly _CONFIRM_STEP='Confirm the published tags name the verified content'

# _compute_matrix_for <platforms> -- RUN the compute-matrix job's own step
# against one `platforms` input and print the matrix JSON it wrote to
# GITHUB_OUTPUT.
#
# The body is read out of the workflow rather than restated, so the pairing a
# caller actually gets is what is asserted: the merge job's runner is the first
# entry's, and whether that runner can execute that entry's platform is the
# whole question an arm64-only call asks.
_compute_matrix_for() {
  local _platforms="${1}" _body _dir _status=0
  _body="$(yaml_step_run "${WF}" compute-matrix set)" || _status=$?
  if [[ "${_status}" -ne 0 || -z "${_body}" || "${_body}" == 'null' ]]; then
    printf 'BUG: could not read the compute-matrix step of %s\n' "${WF}"
    return 2
  fi
  _dir="${SCRATCH}/matrix"
  mkdir -p "${_dir}"
  printf '%s\n' "${_body}" > "${_dir}/step.sh"
  : > "${_dir}/output"
  (
    PLATFORMS="${_platforms}" GITHUB_OUTPUT="${_dir}/output" \
      bash "${_dir}/step.sh" >/dev/null
  ) || return 1
  sed -n 's/^matrix=//p' "${_dir}/output"
}

# _docker_stub -- put a `docker` on PATH that answers for ONE registry state,
# so the tag-confirmation step can be RUN rather than read.
#
# It models the shape a real publish leaves behind, which is the shape that
# check is easy to get wrong. Each publish shard pushes an INDEX, not a bare
# image manifest: provenance is on by default in docker/build-push-action, so
# a shard's `outputs.digest` names an index carrying the platform image and
# its attestation. `imagetools create` FLATTENS those indexes into the
# published one, so what the tag resolves to lists their CHILDREN and none of
# the shard digests themselves. A check that looked for the shard digests in
# the published manifest would therefore fail every ordinary publish -- after
# the tags had already moved.
#
# STUB_MODE picks which state is answered; see _confirm_step_for.
_docker_stub() {
  mkdir -p "${SCRATCH}/bin"
  cat > "${SCRATCH}/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
_last="${*: -1}"
case "${1:-}" in
  buildx)
    # `docker buildx imagetools inspect <tag>`: the published index, whose
    # descriptors are the CHILDREN of each shard's index. The shard digests
    # the artifact directory is named by appear nowhere in it.
    printf 'Name:      %s\n' "${_last}"
    printf 'MediaType: application/vnd.oci.image.index.v1+json\n'
    printf 'Digest:    sha256:9999\n\n'
    printf 'Manifests: \n'
    printf '  Name:        %s@sha256:c0de01\n' "${_last}"
    printf '  Platform:    linux/amd64\n\n'
    if [[ "${STUB_MODE}" != 'platform' ]]; then
      printf '  Name:        %s@sha256:c0de02\n' "${_last}"
      printf '  Platform:    linux/arm64\n\n'
    fi
    printf '  Name:        %s@sha256:c0de03\n' "${_last}"
    printf '  Platform:    unknown/unknown\n'
    ;;
  pull)
    ;;
  image)
    # `docker image inspect --format {{.Id}} <ref>`: the config digest, which
    # is what survives both the index flattening and the tag resolution.
    if [[ "${_last}" == "${VERIFIED_REF}" ]]; then
      printf 'sha256:aaaa\n'
    elif [[ "${STUB_MODE}" == 'content' ]]; then
      printf 'sha256:bbbb\n'
    else
      printf 'sha256:aaaa\n'
    fi
    ;;
  *)
    printf 'stub: unexpected docker invocation: %s\n' "${*}" >&2
    exit 90
    ;;
esac
SH
  chmod +x "${SCRATCH}/bin/docker"
}

# _confirm_step_for <mode> -- RUN the merge job's tag-confirmation step
# against one registry state and return the step's OWN exit status, printing
# whatever it printed.
#
# The body is read OUT OF THE WORKFLOW with yq instead of restated here: a
# spec carrying its own copy of a check agrees with itself while the workflow
# drifts. TAGS carries BOTH tags a caller with `is_latest: true` gets, so the
# loop over them is exercised rather than assumed.
#
# <mode>:
#   agree     an ordinary publish -- every tag carries every platform the
#             matrix built and resolves, for this runner's arch, to the
#             config digest the smoke step ran.
#   content   a tag resolves to different content than was verified.
#   platform  the published manifest is missing an arch the matrix built.
_confirm_step_for() {
  local _mode="${1}" _body _dir _base _status=0
  _body="$(yaml_step_run "${WF}" merge "${_CONFIRM_STEP}")" || {
    printf 'BUG: yq could not read the confirmation step of %s\n' "${WF}"
    return 2
  }
  if [[ -z "${_body}" || "${_body}" == 'null' ]]; then
    printf 'BUG: %s declares no tag-confirmation step in its merge job\n' \
        "${WF}"
    return 2
  fi
  _dir="${SCRATCH}/confirm"
  mkdir -p "${_dir}/digests"
  printf '%s\n' "${_body}" > "${_dir}/step.sh"
  # The artifact directory the step reads: one file per arch the matrix
  # built, named by that shard's digest and carrying the platform it built.
  printf 'linux/amd64\n' > "${_dir}/digests/aa11"
  printf 'linux/arm64\n' > "${_dir}/digests/bb22"
  _docker_stub
  _base='ghcr.io/ycpss91255-docker/ros_distro'
  (
    cd -- "${_dir}/digests" || exit 2
    PATH="${SCRATCH}/bin:${PATH}" \
    STUB_MODE="${_mode}" \
    TAGS="${_base}:v1.2.3-standard,${_base}:latest-standard" \
    VERIFIED_REF="${_base}@sha256:aa11" \
      bash "${_dir}/step.sh" 2>&1
  ) || _status=$?
  return "${_status}"
}

# ── Reusable-workflow surface preserved ──────────────────────────────

@test "publish-worker.yaml: stays a reusable workflow_call workflow" {
  run code_grep -E '^\s+workflow_call:' "${WF}"
  assert_success
}

@test "publish-worker.yaml: preserves the registry-parameterised inputs" {
  for _in in image_name tag_suffix is_latest registry target build_args platforms context_path dockerfile_path build_contexts; do
    run code_grep -E "^      ${_in}:" "${WF}"
    assert_success
  done
}

# ── Native-runner matrix (shared with build/publishconvention) ─

@test "publish-worker.yaml: compute-matrix maps platforms to native runners" {
  run code_grep -E '^  compute-matrix:' "${WF}"
  assert_success
  run code_grep -F 'ubuntu-24.04-arm' "${WF}"
  assert_success
  run code_grep -F 'ubuntu-latest' "${WF}"
  assert_success
}

@test "publish-worker.yaml: build shards run on the matrix runner" {
  run code_grep -F 'runs-on: ${{ matrix.runner }}' "${WF}"
  assert_success
}

# ──push-by-digest per shard + manifest merge ──────────────────

@test "publish-worker.yaml: build shards push per-platform BY DIGEST (#602)" {
  run code_grep -F 'platforms: ${{ matrix.platform }}' "${WF}"
  assert_success
  run code_grep -F 'push-by-digest=true' "${WF}"
  assert_success
}

@test "publish-worker.yaml: shards do NOT push the same tag per shard (#602 regression guard)" {
  # The latent bug: every matrix shard ran `push: true` + a shared
  # `tags: ${{ steps.tags.outputs.tags }}`, overwriting the tag with a
  # single arch. After the fix tags are applied only by the merge job.
  run code_grep -F 'tags: ${{ steps.tags.outputs.tags }}' "${WF}"
  assert_failure
}

@test "publish-worker.yaml: each shard exports + uploads its digest as an artifact (#602)" {
  run code_grep -F 'actions/upload-artifact' "${WF}"
  assert_success
  run code_grep -F 'name: digests-${{ matrix.hardware }}' "${WF}"
  assert_success
}

@test "publish-worker.yaml: merge job assembles the multi-arch manifest via imagetools (#602)" {
  run code_grep -E '^  merge:' "${WF}"
  assert_success
  run code_grep -F 'actions/download-artifact' "${WF}"
  assert_success
  run code_grep -F 'docker buildx imagetools create' "${WF}"
  assert_success
}

@test "publish-worker.yaml: merge resolves tags from inputs (version + optional latest) once (#602)" {
  # The tag-resolution logic (github.ref_name + tag_suffix, plus
  # :latest${suffix} when is_latest) moved intact into the merge job so
  # tags are applied exactly once, at manifest-create time.
  run _resolve_tags_onward
  assert_success
  assert_output --partial 'latest'
  assert_output --partial 'SUFFIX'
}

@test "publish-worker.yaml: merge login uses the parameterised registry (not hardcoded ghcr.io)" {
  # publish-worker is registry-parameterised; the merge job must log in
  # to inputs.registry to push the manifest list.
  run _merge_onward
  assert_success
  assert_output --partial 'registry: ${{ inputs.registry }}'
}

# ── GHCR push permission ─────────────────────────────────────────────

@test "publish-worker.yaml: every job's grant is pinned as an exact set (#957)" {
  # This is a REUSABLE workflow: a job with no `permissions:` runs under
  # whatever the CALLING repo granted its calling job, and a job that
  # names a scope the caller did not grant fails the caller's whole run
  # before it starts. So the grant has to be pinned in BOTH directions,
  # which only an exact set does -- a `-c ... >= 2` count of
  # `packages: write` lines (what this assertion used to be) is blind to
  # which job holds it, to a third job acquiring it, and to any other
  # scope appearing next to it.
  #
  # `packages: write` on `publish` and `merge` is the legitimate case in
  # this repo: publish pushes the per-arch images by digest and merge
  # pushes the manifest list. compute-matrix only reads.
  #
  # The job list is DERIVED (yaml_permission_surface reads the file's own
  # `jobs:` keys), so a fourth job appears in this output on the day it
  # lands rather than being waved through -- and an unreadable file
  # arrives as a `BUG:` line, which fails this assertion instead of
  # passing it. The expected text is non-empty, so an empty surface
  # cannot satisfy it either.
  run yaml_permission_surface "${WF}"
  assert_success
  assert_output 'compute-matrix: contents: read
publish: contents: read
publish: packages: write
merge: contents: read
merge: packages: write'
}

# ── Same-repository guard on the self-hosted-eligible publish job ──────

@test "publish-worker.yaml: the publish job carries the same-repo guard (#766)" {
  # Self-hosted-eligible by the static rule: `runs-on: ${{ matrix.runner }}`
  # over a runtime-computed matrix. Inert today (the callers are tag-push
  # release flows, and every non-PR event passes the first disjunct), which
  # is exactly when insurance is cheap to install.
  run yaml_job_lines "${WF}" publish
  assert_success
  assert_output --partial "github.event_name != 'pull_request' ||"
  assert_output --partial 'github.event.pull_request.head.repo.full_name == github.repository'
}

# ── Content verified before a tag names it ───────────────────────────

# why: A step that verifies a TAG cannot run until the tag exists, so reading
# one is what kept the only check in this job running after the publish it was
# supposed to authorise -- and nothing in this file can detach a tag again.
# It reads the digest a publish shard pushed instead, which exists before any
# tag names it (#1214).
@test "publish-worker.yaml: the smoke step verifies the digest it is about to tag, not a tag name (#1214)" {
  run _smoke_step
  assert_success
  assert_output --partial 'steps.verify.outputs.ref'
  # And it RUNS the image. The step this replaced was a single `imagetools
  # inspect`, which asks the registry whether a manifest exists under a name
  # and never executes what the name points at.
  assert_output --partial 'docker run --rm'
  # `${REF}` / `${SUFFIX}` would be a tag read, which is the shape being
  # refused: a tag cannot exist before the manifest create below it.
  refute_output --partial '${REF}'
  refute_output --partial '${SUFFIX}'
}

# why: Verification has to RUN the image and a runner can only run its own
# architecture, so the merge job must tell which downloaded digest it can
# execute. `merge-multiple: true` flattens the per-arch artifact NAMES away
# before that job sees them, so the digest FILE is the only place the answer
# survives -- a `touch`ed empty file leaves the selection with nothing to read
# and the manifest create with nothing in front of it (#1214).
@test "publish-worker.yaml: each shard records the platform it built in its digest file (#1214)" {
  run yaml_step_run "${WF}" publish 'Export digest'
  assert_success
  assert_output --partial '${{ matrix.platform }}'
  refute_output --partial 'touch "/tmp/digests/'
  # And the merge job reads that platform rather than assuming the one
  # `runs-on:` happens to name.
  run yaml_step_run "${WF}" merge 'Select the digest to verify'
  assert_success
  assert_output --partial "docker version --format '{{.Server.Arch}}'"
  assert_output --partial 'refusing'
}

# why: The load-bearing case, and the one a structural read cannot make. With
# provenance on by default each shard's exported digest names an INDEX, and
# `imagetools create` flattens those into the published one -- so the shard
# digests the artifact files are named by are absent from the published
# manifest and a digest-set comparison fails every SUCCESSFUL publish, after
# the tags have moved. Running the step over that state is what says it
# compares the constituent manifests instead (#1214).
@test "publish-worker.yaml: the tag confirmation passes an ordinary publish, whose shard digests are flattened away (#1214)" {
  run _confirm_step_for agree
  assert_success
  # Both tags a caller with `is_latest: true` gets are read, not just the
  # version one: `:latest-<variant>` is the tag the unpinned downstream
  # consumers follow.
  assert_output --partial 'ros_distro:v1.2.3-standard resolves to the verified image'
  assert_output --partial 'ros_distro:latest-standard resolves to the verified image'
  assert_output --partial 'carries a manifest for linux/amd64'
  assert_output --partial 'carries a manifest for linux/arm64'
}

# why: The failure this check exists for and the only one the reordering
# leaves on this side of the publish: the create attached a tag to content the
# smoke step never ran. A confirmation that cannot report it is a step that
# only ever agrees (#1214).
@test "publish-worker.yaml: the tag confirmation fails when a tag resolves to content nothing verified (#1214)" {
  run _confirm_step_for content
  assert_failure
  assert_output --partial 'The tags were attached to content'
}

# why: The other half: a published index that silently lost an arch the
# matrix built leaves the losing architecture's downstream consumers unable to
# pull the tag at all, which is the defect the per-shard digest push exists to
# prevent (#1214).
@test "publish-worker.yaml: the tag confirmation fails when the published manifest drops an arch the matrix built (#1214)" {
  run _confirm_step_for platform
  assert_failure
  assert_output --partial 'carries no manifest for linux/arm64'
}

# why: An arm64-only caller -- `platforms: linux/arm64`, which this worker
# supports and which a multi-arch base image repo uses -- builds and pushes on
# `ubuntu-24.04-arm`. A merge job pinned to `ubuntu-latest` can execute none of
# the digests that run produced, so the selection refuses, no tag is attached,
# and a supported configuration stops publishing altogether. The runner has to
# follow the matrix the caller asked for (#1214).
@test "publish-worker.yaml: the merge job's runner follows the publish matrix, not a fixed arch (#1214)" {
  run yq -r '.jobs.merge."runs-on"' "${WF}"
  assert_success
  refute_output 'ubuntu-latest'
  assert_output --partial 'needs.compute-matrix.outputs.matrix'
  # And the job declares the dependency that expression reads, so the runner
  # is resolved from the matrix rather than from an empty context.
  run yaml_job_needs "${WF}" merge
  assert_success
  assert_output --partial 'compute-matrix'
  assert_output --partial 'publish'
}

# why: The structural half above says the runner is derived; this says the
# derivation lands on a runner that can RUN what the caller asked for. An
# arm64-only call must put the merge job on the arm64 runner, or the smoke
# step has nothing it can execute and the publish fails for a configuration
# that worked before the gate existed (#1214).
@test "publish-worker.yaml: an arm64-only call verifies on an arm64 runner (#1214)" {
  local _matrix _entry
  _matrix="$(_compute_matrix_for 'linux/arm64')"
  # The first entry is what the merge job's runs-on expression selects.
  _entry="$(printf '%s' "${_matrix}" | yq -r -o=json '.include[0]')"
  run yq -r -o=json '.runner' <<< "${_entry}"
  assert_success
  assert_output 'ubuntu-24.04-arm'
  run yq -r -o=json '.platform' <<< "${_entry}"
  assert_success
  assert_output 'linux/arm64'
}

# why: base#1171's invariant, stated as behaviour rather than left in prose:
# every run the trigger starts has a reason to publish and the publish is
# unconditional. An `if:` on any merge step would let a run reach the end
# having published nothing while still holding its concurrency slot, which is
# the eviction that issue removed. The job's own `if:` is held to the
# same-repo guard the self-hosted rule requires of its derived runner and to
# nothing else, so a condition on WHETHER to publish cannot arrive there
# either.
@test "publish-worker.yaml: nothing in the merge job conditions whether it publishes (#1171)" {
  run yq -r '[.jobs.merge.steps[] | select(has("if"))] | length' "${WF}"
  assert_success
  assert_output '0'
  run yq -r '.jobs.merge."if"' "${WF}"
  assert_success
  assert_output --partial "github.event_name != 'pull_request' ||"
  assert_output --partial 'github.event.pull_request.head.repo.full_name == github.repository'
  # Nothing else: no second disjunct, no `inputs.*` or `steps.*` read that
  # could make a run decline to publish.
  refute_output --partial 'inputs.'
  refute_output --partial 'steps.'
  refute_output --partial '&&'
}
