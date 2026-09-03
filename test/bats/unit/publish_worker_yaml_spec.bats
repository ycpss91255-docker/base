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

# ── Reusable-workflow surface preserved ──────────────────────────────

@test "publish-worker.yaml: stays a reusable workflow_call workflow" {
  run code_grep -E '^\s+workflow_call:' "${WF}"
  assert_success
}

@test "publish-worker.yaml: preserves the registry-parameterised inputs" {
  for _in in image_name tag_suffix is_latest registry target build_args platforms context_path dockerfile_path build_contexts test_tools_version; do
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
