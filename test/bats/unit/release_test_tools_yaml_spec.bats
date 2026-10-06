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
#    when the tag is NOT a prerelease. `:<version>` is what build-worker
#    and publish-worker build FROM, derived from the `.version` of the
#    base checkout they take at their own ref (base#1122); `:latest` is
#    the rolling tag a human pulls, which is why an RC tag must leave it
#    alone. `v0.42.0-rc1` through `-rc4` each matched the `v*` trigger and
#    each moved it.
#
# 2. **Main push** (P2) — multi-arch `:main` rolling tag. The
#    template's own self-test.yaml pulls this in its Obtain step to
#    skip a from-source rebuild on every PR. The paths filter holds back
#    the merges that change nothing the image is built from, and the last
#    section of this file holds the filter to the set
#    `script/ci/testtools_paths.sh` derives from the Dockerfile's COPY
#    lines -- a filter naming only the Dockerfile is why a merge touching
#    only a COPYed file never reached GHCR at all.
#
# 3. **workflow_dispatch** — no tag set of its own: it resolves by the
#    ref it was dispatched FROM (main takes the `:main` arm, a `v*` tag
#    takes the tag rules above). Unrestricted by ref, so any other ref is
#    REFUSED rather than resolved to the tag every downstream consumes.
#
# The smoke step verifies a DIGEST, and runs before the manifest create
# attaches any tag to it. It used to verify `steps.tags.outputs.smoke`, a
# tag -- which cannot exist until the create has run, so the only check
# this image has ran after the publish it was supposed to authorise, with
# no rollback anywhere in the file. That output now belongs to the step
# after the create, the one assertion that needs the tag to exist: that it
# resolves, and resolves to the digests this run verified.
#
# why: Structural assertions for
# `.github/workflows/release-test-tools.yaml`. Locks the publish surface
# that downstream Dockerfile.example's `FROM ${TEST_TOOLS_IMAGE} AS
# test-tools-stage` depends on. The workflow has three triggers and two tag
# sets -- the first two triggers each resolve one:
#
# 1. **Tag push (`v*`)** -- multi-arch `:<version>`, and `:latest` only when
# the tag is not a prerelease. `:<version>` is the one the workers build
# FROM, derived from the base checkout's own `.version` (base#1122);
# `:latest` is the rolling tag a human pulls, which is why a prerelease tag
# must leave it alone.
#
# 2. **Main push** (P2) -- multi-arch `:main` rolling tag, pulled by
# self-test.yaml's Obtain step to skip from-source rebuilds. Its paths filter
# holds back the merges that change nothing the image is built from, and is
# itself held to the set derived from the Dockerfile's own COPY lines.
#
# 3. **workflow_dispatch** -- no tag set of its own: it resolves by the ref
# it was dispatched from (main takes the `:main` arm, a `v*` tag takes the
# tag rules). Any other ref is refused, so an unrecognised input publishes
# nothing rather than overwriting `:latest`.
#
# The merge job's ORDER is pinned here too, over a population read off the
# workflow's own jobs and steps: no step may let a registry tag name content
# that no step of that job has run yet. The smoke step -- the only check this
# image has, since no job of this workflow needs self-test.yaml -- used to
# verify a tag, which cannot exist before the manifest create, so it ran
# after the publish it was supposed to authorise and a red verdict left the
# moved tag standing. It verifies a digest now; the tag's own resolution is
# checked by the step after the create, which is the only assertion that
# needs the tag to exist.
#
# Four of the cases below RUN the resolver rather than reading it: the step's
# own `run:` body is extracted with yq and executed against each ref shape.
# The text-reading cases above them stayed green through four RC tags that
# each moved `:latest`.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WF="/source/.github/workflows/release-test-tools.yaml"
  assert_spec_subject "${WF}" \
      "the test-tools release workflow this spec pins"
  # Scratch for the workflow FIXTURES the publish-ordering cases need. Three
  # of the shapes that scan has to classify are ones the real workflow must
  # never contain, so they can only be exercised over a file written here --
  # and a classifier asserted solely against the live tree can stop
  # recognising them without anything going red.
  SCRATCH="$(mktemp -d)"
}

teardown() {
  if [[ -n "${SCRATCH:-}" ]]; then
    rm -rf "${SCRATCH}"
  fi
}

# _resolve_tags_step -- the code lines of the "Resolve tags" step, up to the
# next step. Comment-stripped: the step's prose explains the three publish
# modes by NAME, so an unstripped block lets the explanation stand in for the
# branch that implements it.
_resolve_tags_step() {
  awk '/Resolve tags/{flag=1} /^      - name:/{ if (flag && !first) {first=1; next} else if (flag) {flag=0}} flag' "${WF}" \
    | strip_comments
}

# _smoke_step -- the code lines of the "Smoke test pushed image" step, and of
# that step only.
#
# Bounded by the parser rather than by "from this name to the end of the
# file", which is what it used to be. That read was harmless only while the
# smoke step was last: the moment the manifest create moved below it, a
# string the CREATE step carries satisfied every assertion made about the
# SMOKE step -- including the one about which reference it verifies, which is
# the property the reordering changed.
_smoke_step() {
  yaml_step_run "${WF}" merge 'Smoke test pushed image' | strip_comments
}

# _publish_order_census <file> -- one `<job> attach=<i> verify=<j>` line per
# job of <file>, where <i> is the 0-based index of the first step that makes a
# registry TAG name content and <j> the index of the first step that RUNS the
# image. `-1` means the job has no such step.
#
# Both populations are the workflow's OWN: the jobs come from its `jobs:`
# mapping and the indices from each job's `steps:` list, so a fourth job -- or
# a step inserted between two existing ones -- is read the day it lands. No
# job is named here, and that is the point: the defect this answers was a
# publish that sat one step ahead of its only check inside a job the spec
# would have had to remember.
#
# A step ATTACHES a tag when its shell runs `imagetools create` or `docker
# push`, or when it hands an action a non-empty `tags:` input -- the three
# ways a tag in this registry comes to name a digest. A step VERIFIES when it
# runs the image: `docker run` is the only thing in this workflow that
# executes what was built, so it is the only thing whose success says the
# content works. `docker pull` is not verification; it is a download.
#
# An unreadable job is a `BUG:` line and a non-zero status, never a job with
# no publish in it: a census that fails open reports perfect ordering for a
# workflow it could not parse.
_publish_order_census() {
  local _wf="${1}" _jobs _job _steps _status=0
  _jobs="$(yaml_job_names "${_wf}")" || {
    printf '%s\n' "${_jobs}"
    return 1
  }
  while IFS= read -r _job; do
    [[ -n "${_job}" ]] || continue
    _status=0
    _steps="$(RTT_JOB="${_job}" yq -r '
        (.jobs[strenv(RTT_JOB)].steps // []) | .[]
        | ("@@TAGS@@" + ((.with.tags // "") | tostring))
          + "\n" + ((.run // "") | tostring) + "\n@@STEP@@"' \
        "${_wf}" 2>&1)" || _status=$?
    if [[ "${_status}" -ne 0 ]]; then
      printf 'BUG: yq exited %s reading the steps of job %s in %s: %s\n' \
          "${_status}" "${_job}" "${_wf}" \
          "$(printf '%s' "${_steps}" | tr '\n' ' ')"
      return 1
    fi
    printf '%s\n' "${_steps}" | awk -v _job="${_job}" '
      BEGIN { idx = 0; attach = -1; verify = -1 }
      $0 == "@@STEP@@" { idx++; next }
      /^@@TAGS@@/ {
        _v = $0
        sub(/^@@TAGS@@/, "", _v)
        if (attach < 0 && _v ~ /[^[:space:]]/) { attach = idx }
        next
      }
      /^[[:space:]]*#/ { next }
      {
        if (attach < 0 && ($0 ~ /imagetools[[:space:]]+create/ \
            || $0 ~ /docker[[:space:]]+push/)) { attach = idx }
        if (verify < 0 && $0 ~ /docker[[:space:]]+run/) { verify = idx }
      }
      END { printf "%s attach=%d verify=%d\n", _job, attach, verify }
    '
  done <<< "${_jobs}"
}

# _publish_order_violations <file> -- one line per job of <file> that lets a
# registry tag name content no step of that job had run yet.
#
# Derived from the census above, so the classification lives in one place and
# the two readers cannot drift into two different questions.
_publish_order_violations() {
  local _wf="${1}" _census _job _attach _verify _status=0
  _census="$(_publish_order_census "${_wf}")" || _status=$?
  if [[ "${_status}" -ne 0 ]]; then
    printf '%s\n' "${_census}"
    return 1
  fi
  while read -r _job _attach _verify; do
    [[ -n "${_job}" ]] || continue
    _attach="${_attach#attach=}"
    _verify="${_verify#verify=}"
    [[ "${_attach}" -ge 0 ]] || continue
    if [[ "${_verify}" -lt 0 ]]; then
      printf '%s: job %s attaches a registry tag at step %s and no step of' \
          "${_wf}" "${_job}" "${_attach}"
      printf ' that job ever runs the image\n'
    elif [[ "${_verify}" -gt "${_attach}" ]]; then
      printf '%s: job %s attaches a registry tag at step %s, ahead of the' \
          "${_wf}" "${_job}" "${_attach}"
      printf ' step that runs the image at step %s\n' "${_verify}"
    fi
  done <<< "${_census}"
}

# _docker_stub -- put a `docker` on PATH that answers for ONE registry state,
# so the tag-confirmation step can be RUN rather than read.
#
# It models the shape a real publish of this image leaves behind, which is the
# shape the first version of that step got wrong. Each build shard pushes an
# INDEX, not a bare image manifest: provenance is on by default in
# docker/build-push-action, so a shard's `outputs.digest` names an index
# carrying the platform image and its attestation. `imagetools create`
# FLATTENS those indexes into the published one, so what the tag resolves to
# lists their CHILDREN and none of the shard digests themselves. A step that
# looked for the shard digests in the published manifest therefore failed
# every ordinary publish -- after the tags had already moved.
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
    # `docker buildx imagetools inspect [--raw] <tag>`: the published index,
    # whose descriptors are the CHILDREN of each shard's index. The shard
    # digests the artifact directory is named by appear nowhere in it.
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

# _confirm_step_node -- the WHOLE tag-confirmation step, its `env:` mapping
# included. The two references that step reads arrive through `env:` so the
# `run:` body is shell a spec can execute, which means the assertions about
# WHICH references it reads have to look at the step and not only at its body.
_confirm_step_node() {
  RTT_STEP='Confirm the published tag names the verified content' yq -r \
      '.jobs.merge.steps[] | select(.name == strenv(RTT_STEP))' "${WF}"
}

# _confirm_step_for <mode> -- RUN the merge job's tag-confirmation step
# against one registry state and return the step's OWN exit status, printing
# whatever it printed.
#
# The body is read OUT OF THE WORKFLOW with yq instead of restated here, for
# the reason the resolver cases below are: a spec carrying its own copy of a
# check agrees with itself while the workflow drifts.
#
# <mode>:
#   agree     an ordinary publish -- the tag carries every platform the
#             matrix built and resolves, for this runner's arch, to the
#             config digest the smoke step ran.
#   content   the tag resolves to different content than was verified.
#   platform  the published manifest is missing an arch the matrix built.
_confirm_step_for() {
  local _mode="${1}" _body _dir _status=0
  _body="$(yaml_step_run "${WF}" merge \
      'Confirm the published tag names the verified content')" || {
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
  (
    cd -- "${_dir}/digests" || exit 2
    PATH="${SCRATCH}/bin:${PATH}" \
    STUB_MODE="${_mode}" \
    IMAGE='ghcr.io/ycpss91255-docker/test-tools' \
    IMAGE_TAG='ghcr.io/ycpss91255-docker/test-tools:main' \
    VERIFIED_REF='ghcr.io/ycpss91255-docker/test-tools@sha256:aa11' \
      bash "${_dir}/step.sh" 2>&1
  ) || _status=$?
  return "${_status}"
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

# why: The main push trigger is filtered at all, which is what keeps every
# non-doc merge from republishing the same image content under a new manifest
# digest. WHAT the filter has to contain is asserted against the derivation,
# in both directions, in the last section of this file -- the two cases there
# are the ones that fail when a context COPY is added without extending it.
@test "release-test-tools.yaml: main push trigger carries a paths filter (#317 P2 gotcha-3)" {
  run yaml_top_lines "${WF}" on
  assert_success
  assert_output --partial 'paths:'
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
# `v*` trigger and each moved the rolling tag, for the length of an RC
# window, to a release candidate.
@test "release-test-tools.yaml: an RC tag publishes :<ver> and leaves :latest where it was (#1012)" {
  # v0.42.0-rc1..rc4 each matched the `v*` trigger and each moved
  # `:latest`, so for the whole RC window the rolling tag named a release
  # candidate -- and back then every downstream repo that had not pinned
  # built its lint stage from it.
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

# why: A step that verifies a TAG cannot run until the tag exists, so reading
# one here is what forced the only check on this image to run after the
# publish it was supposed to authorise (#1109). It verifies the digest a build
# shard pushed instead, which exists before any tag names it.
@test "release-test-tools.yaml: smoke step verifies the digest it is about to tag, not a tag name (#1109)" {
  # The digest reference is resolved by the step above this one, which picks
  # the arch this runner can execute. Reading `steps.tags.outputs.smoke` here
  # would mean the manifest create had already run -- and that is the
  # ordering being refused: the tag moved, then the check ran, and nothing in
  # the file could move it back.
  run _smoke_step
  assert_success
  assert_output --partial 'steps.verify.outputs.ref'
  refute_output --partial 'steps.tags.outputs.smoke'
}

# why: The trigger's own tag still has to be the one checked, which was the
# property the old smoke target carried: a main push publishes `:main` and
# must not report on the stale `:latest` from the previous release. It moved
# to the only step that can hold it, the one that runs after the tag exists.
@test "release-test-tools.yaml: the tag confirmation reads the trigger's own tag, never a stale one (#317 P2)" {
  # Avoids the regression where a main push publishes :main but the check
  # reports on the stale :latest left by the previous tag. This is also the
  # one assertion that cannot be made before the publish: that the tag
  # RESOLVES, and resolves to the digests this run verified.
  run _confirm_step_node
  assert_success
  assert_output --partial 'steps.tags.outputs.smoke'
  assert_output --partial 'imagetools inspect'
}

# why: An ordinary publish of this image must PASS the confirmation, and the
# first version of it could not: each shard pushes an index (provenance is on
# by default), imagetools create flattens those into the published index, so
# the shard digests the step compared against were never in it. Every
# successful release would have reported failure -- after the tags moved.
@test "release-test-tools.yaml: the tag confirmation passes an ordinary publish, whose shard digests are flattened away (#1109)" {
  # The published index lists the CHILDREN of each shard's index -- the
  # platform image and its provenance attestation -- and none of the shard
  # digests the digest artifacts are named by.
  run _confirm_step_for agree
  assert_success
}

# why: The property the step exists for: a tag that resolves to content other
# than what was verified is the one thing the reordering leaves checkable only
# after the publish, so a confirmation that cannot fail on it checks nothing.
@test "release-test-tools.yaml: the tag confirmation fails when the tag resolves to content nothing verified (#1109)" {
  run _confirm_step_for content
  assert_failure
  assert_output --partial '::error::'
}

# why: The other half of what the published tag has to be: a manifest list
# covering every arch the matrix built. A tag that lost an arch is the
# last-shard-wins failure the whole push-by-digest design exists to prevent,
# and the expected platform list is read from the artifacts, not written here.
@test "release-test-tools.yaml: the tag confirmation fails when the published manifest drops an arch the matrix built (#1109)" {
  run _confirm_step_for platform
  assert_failure
  assert_output --partial '::error::'
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

# ── Publish ordering: content verified before a tag names it ─────────

# why: The rolling tag moved first and the only check on the image ran after
# it, with nothing anywhere in the file that could put it back -- so a red
# smoke left the moved tag standing, and on the measured v0.42.0 tag the tag
# moved 5m58s before that commit's tests had any verdict at all (#1109). The
# ordering is read off the workflow's own jobs and steps, so the job that
# publishes does not have to be remembered here and a fourth one is in the
# population the day it lands.
@test "release-test-tools.yaml: no job attaches a registry tag ahead of the step that runs the image (#1109)" {
  # The step that attaches the tags ran BEFORE the only step that executes
  # the image, and `failure()` / rollback / `imagetools rm` appear nowhere in
  # the file -- so a failing smoke reported red with the tag already moved.
  run _publish_order_violations "${WF}"
  assert_success
  assert_output ""
}

# why: An empty violation list satisfies the case above whether the scan read
# every job and found the ordering right, or read nothing and classified
# nothing. So the population it walked and the pair it ordered are asserted,
# not assumed.
@test "release-test-tools.yaml: the ordering scan read every job and found the publish it ordered (#1109)" {
  local _census _jobs _job
  _census="$(_publish_order_census "${WF}")"
  _jobs="$(yaml_job_names "${WF}")"
  # One census line per job of the workflow, counted off the file's own jobs
  # mapping, so a job outside the scan's population is a failure here.
  assert_equal "$(printf '%s\n' "${_jobs}" | grep -c '')" \
      "$(printf '%s\n' "${_census}" | grep -c '')"
  while IFS= read -r _job; do
    [[ -n "${_job}" ]] || continue
    printf '%s\n' "${_census}" \
      | grep -qE "^${_job} attach=-?[0-9]+ verify=-?[0-9]+$"
  done <<< "${_jobs}"
  # And some job really does both, so the clean result above is an ordering
  # that was observed rather than a scan that recognised neither end of it.
  run grep -cE ' attach=[0-9]+ verify=[0-9]+$' <<< "${_census}"
  assert_success
  [ "${output}" -ge 1 ]
}

# why: The live tree cannot exercise this shape -- a publish with no check at
# all -- and must never be able to, so without a fixture the classifier could
# stop reporting it and nothing would notice.
@test "publish ordering: a job that attaches a tag with nothing running the image is reported (#1109)" {
  cat > "${SCRATCH}/no-check.yaml" <<'YAML'
name: fixture
on: [push]
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - name: Attach the tag
        run: docker buildx imagetools create -t img:latest img@sha256:aaa
YAML
  run _publish_order_violations "${SCRATCH}/no-check.yaml"
  assert_success
  assert_output --partial 'job publish attaches a registry tag at step 0'
  assert_output --partial 'no step of that job ever runs the image'
}

# why: The other half of a usable rule -- the prescribed order has to pass --
# plus the property that makes the population derived rather than remembered:
# the walk does not stop at the first job, so the job somebody adds tomorrow
# is scanned the day it lands.
@test "publish ordering: a verified publish is clean, and a job after it is still read (#1109)" {
  cat > "${SCRATCH}/two-jobs.yaml" <<'YAML'
name: fixture
on: [push]
jobs:
  verified:
    runs-on: ubuntu-latest
    steps:
      - name: Run the image
        run: docker run --rm img@sha256:aaa true
      - name: Attach the tag
        run: docker buildx imagetools create -t img:latest img@sha256:aaa
  added-later:
    runs-on: ubuntu-latest
    steps:
      - name: Attach the tag
        run: docker buildx imagetools create -t img:main img@sha256:bbb
      - name: Run the image
        run: docker run --rm img:main true
YAML
  run _publish_order_violations "${SCRATCH}/two-jobs.yaml"
  assert_success
  assert_output --partial 'job added-later attaches a registry tag at step 0,'
  assert_output --partial 'ahead of the step that runs the image at step 1'
  refute_output --partial 'job verified'
}

# why: A tag can also be attached by an action handed a tags input, which is
# the shape this very workflow would take if its build shards ever stopped
# pushing by digest -- and no run block would mention a tag at all. The
# digest-only push the shards do today is the negative half: it names nothing,
# so it is reachable by content alone and needs no check in front of it.
@test "publish ordering: an action handed a tags input attaches a tag, a digest-only push does not (#1109)" {
  cat > "${SCRATCH}/action-tags.yaml" <<'YAML'
name: fixture
on: [push]
jobs:
  tagging:
    runs-on: ubuntu-latest
    steps:
      - uses: docker/build-push-action@v7
        with:
          push: true
          tags: img:latest
  digest-only:
    runs-on: ubuntu-latest
    steps:
      - uses: docker/build-push-action@v7
        with:
          outputs: type=image,push-by-digest=true,name-canonical=true,push=true
YAML
  run _publish_order_violations "${SCRATCH}/action-tags.yaml"
  assert_success
  assert_output --partial 'job tagging attaches a registry tag at step 0'
  refute_output --partial 'job digest-only'
}

# why: A scan that cannot read a workflow must say so, not report it clean:
# the fail-open direction here is a workflow whose publish ordering nothing
# checked, passing the live-tree case for the wrong reason.
@test "publish ordering: a workflow the scan cannot read is a BUG, never a clean ordering (#1109)" {
  printf 'name: fixture\non: [push]\n' > "${SCRATCH}/no-jobs.yaml"
  run _publish_order_violations "${SCRATCH}/no-jobs.yaml"
  assert_failure
  assert_output --partial 'BUG:'
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

# ── Pin agreement: the smoke step compares versions, it does not print them ──
#
# The smoke step ran `shellcheck --version` and `hadolint --version` and
# asserted exit 0. That catches a tool that vanished; it cannot catch a tool
# that is the wrong version, which is the failure that actually happened --
# a hadolint pin sat 3.8 years stale behind a green gate, and the gate was
# reading "the binary starts" as "the binary is what the Dockerfile asked
# for". The two are only the same claim while nothing goes wrong.
#
# The comparison has to DERIVE the expected version from the pin rather than
# restate it in YAML: a hardcoded expectation in the workflow is a second
# place to forget, and a bump that updates the Dockerfile and not the
# workflow would fail for the wrong reason -- or, worse, a bump that updates
# both would prove only that two literals match each other.
#
# `hadolint --version` prints the version as a bare number ("Haskell
# Dockerfile Linter 2.15.1") while the pin is a tag ("v2.15.1"), so the
# comparison is on the number with the leading v stripped. Asserting the
# stripping happens is part of the rule: without it the check would compare
# "v2.15.1" against a line that never contains it and fail every run, which
# is the shape of a check that gets deleted rather than fixed.

# why: The precondition the other five rest on -- with no checkout in the
# merge job there is no Dockerfile to read the pins out of, and the whole
# comparison degrades to the exit-0 check it replaced
@test "release-test-tools.yaml: merge job checks out the repo so the smoke step can read the pins (#947)" {
  run grep -n 'actions/checkout' "${WF}"
  assert_success
  # Two call sites: the build shards, and the merge job the smoke step
  # lives in. One means the smoke step is comparing against nothing.
  [[ "$(grep -c 'actions/checkout' "${WF}")" -ge 2 ]]
}

# why: The expectation has to come from the pin: a version literal in the
# workflow would be a second place to bump, and two literals agreeing prove
# only that somebody edited both
@test "release-test-tools.yaml: smoke step reads the shellcheck pin from the Dockerfile (#947)" {
  run _smoke_step
  assert_success
  assert_output --partial 'dockerfile/Dockerfile.test-tools'
  # The ARG declaration, not the release URL it feeds: the URL interpolates
  # the ARG now, so there is no literal in it left to read.
  assert_output --regexp 'SHELLCHECK_VERSION='
}

# why: The pin that sat 3.8 years stale behind an exit-0 check -- the
# concrete drift this whole step was rewritten for, so its half of the
# comparison is asserted separately from shellcheck's
@test "release-test-tools.yaml: smoke step reads the hadolint pin from the Dockerfile (#947)" {
  run _smoke_step
  assert_success
  assert_output --regexp 'HADOLINT_VERSION='
}

# why: Reading two numbers is not comparing them: holding the pin and
# running `<tool> --version` still passes for an image whose linters are
# years old, which is exactly the state that shipped
@test "release-test-tools.yaml: smoke step COMPARES the reported versions, not just exit 0 (#947)" {
  run _smoke_step
  assert_success
  # The shipped binary's own report is captured and matched against the
  # pin. A step that only ran `<tool> --version` would have neither.
  assert_output --regexp 'shellcheck --version'
  assert_output --regexp 'hadolint --version'
  assert_output --partial 'expected_sc'
  assert_output --partial 'expected_hd'
}

# why: A comparison whose mismatch branch only warns is not a gate -- the
# publish would go out with the wrong linters and a green log
@test "release-test-tools.yaml: smoke step fails loudly when a pin and a binary disagree (#947)" {
  run _smoke_step
  assert_success
  # An exit non-zero on mismatch, with both values in the message -- a
  # comparison whose failure branch only warns is not a gate.
  assert_output --regexp 'exit 1'
}

# why: The failure mode a moved release URL produces: an empty expectation
# compared against an empty reading agrees with itself, which is the shape
# of pass the whole step exists to refuse
@test "release-test-tools.yaml: smoke step refuses an unreadable pin rather than passing (#947)" {
  run _smoke_step
  assert_success
  # A grep that matched nothing must not compare "" against "" and call it
  # agreement. The step names the empty case explicitly.
  assert_output --partial 'could not read'
}

# ── The trigger's path filter, read against the image it is about ─────

# _trigger_paths -- the `paths:` entries of the push trigger, one per line.
# Read out of the YAML so the two cases below cannot drift from the file.
_trigger_paths() {
  local _out _status=0
  _out="$(yq -r '.on.push.paths[]' "${WF}" 2>&1)" || _status=$?
  if [[ "${_status}" -ne 0 || -z "${_out}" || "${_out}" == 'null' ]]; then
    printf 'BUG: %s declares no push paths filter (yq said: %s)\n' \
        "${WF}" "$(printf '%s' "${_out}" | tr '\n' ' ')"
    return 2
  fi
  printf '%s\n' "${_out}"
}

# _filter_selects <path>
#   Does any `paths:` entry match <path>, by GitHub's filter-pattern rules?
#   `**` matches any characters including `/`; a plain entry has to name the
#   path outright. A pattern this does not model is reported as a BUG rather
#   than read as "no match": a filter form nobody here understands must not
#   be certified by a matcher that quietly answers for it.
_filter_selects() {
  local _path="${1:?BUG: _filter_selects expects a path}" _e
  while IFS= read -r _e; do
    [[ -n "${_e}" ]] || continue
    case "${_e}" in
      BUG:*) printf '%s\n' "${_e}"; return 2 ;;
      '**') return 0 ;;
      */\*\*) case "${_path}/" in "${_e%\*\*}"*) return 0 ;; esac ;;
      *[*?!+\[]*)
        printf 'BUG: %s uses a filter pattern this matcher does not model\n' \
            "${_e}"
        return 2 ;;
      *) [[ "${_path}" == "${_e}" ]] && return 0 ;;
    esac
  done < <(_trigger_paths)
  return 1
}

# why: The reported defect, on the half that compounds the other. The tag a
# pull request falls back to when the rebuild signal says "unchanged" is a tag
# nothing refreshed: this trigger named the Dockerfile and this workflow, and
# the image has more inputs than that, so a merge touching only a file the
# Dockerfile COPYs out of the build context never started the publisher at
# all. `paths:` is static YAML GitHub evaluates before any job runs, so it
# cannot derive the set -- but it can be HELD to it. The expected set is read
# from the derivation, so the next context COPY anyone adds fails here, on the
# pull request that adds it, naming the path the filter does not cover.
@test "release-test-tools.yaml: the push filter covers every input of the tooling image (#1171)" {
  local _p _missing="" _status
  while IFS= read -r _p; do
    [[ -n "${_p}" ]] || continue
    _status=0
    _filter_selects "${_p}" || _status=$?
    case "${_status}" in
      0) ;;
      1) _missing="${_missing}${_p}"$'\n' ;;
      *) fail "could not read the filter: $(_filter_selects "${_p}")" ;;
    esac
  done < <(bash /source/script/ci/testtools_paths.sh)
  [[ -z "${_missing}" ]] || fail \
      "these paths can change what the tooling image contains, and no entry of this workflow's push filter selects them, so a merge touching only one of them never republishes :main:"$'\n'"${_missing}"
  _filter_selects '.github/workflows/release-test-tools.yaml' || fail \
      "the filter no longer names this workflow, so a change to how the tag is resolved or smoke-tested never goes out"
}

# why: The direction the filter exists for, and the reason it is a filter at
# all rather than `'**'` plus a job that decides. Every non-doc merge pushes
# to main; a filter that matches all of them would burn a multi-arch build per
# merge -- and, worse, put a run that will NOT publish into the workflow's
# concurrency group, where GitHub keeps only ONE pending run: a doc-only merge
# could then evict a queued publish and decline to publish in its place,
# leaving `:main` without the change it was queued for. So every run this
# trigger starts has a reason to publish, and the publish is unconditional.
@test "release-test-tools.yaml: the push filter does not start on what the image never reads (#1171)" {
  local _p
  for _p in doc/guide.md README.md test/bats/unit/example_spec.bats \
            dist/script/docker/wrapper/build.sh; do
    ! _filter_selects "${_p}" || fail \
        "this workflow's push filter selects ${_p}, which cannot change what the tooling image contains: every merge would republish :main, and a run that publishes nothing can evict a queued one from the concurrency group"
  done
}
