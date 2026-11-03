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
# The registry state is files: every raw index lives in STUB_FX as
# `<hex>.json`, stored under `sha256:<hex>`, and `${STUB_FX}/tags` maps each
# tag name to the hex it resolves to (`<tag> <hex>` per line). Every answer is
# read from those files, so the `Platform:` listing and the raw JSON cannot
# disagree. Three switches vary that state: STUB_TAG_MOVED (every read of a
# tag BY NAME after its first answers that hex instead), STUB_RAW_FAIL (the
# raw read of that hex exits non-zero after writing its body) and
# STUB_TAG_UNRESOLVED (resolving a tag by name exits 0 and prints
# STUB_TAG_ANSWER, which is not a digest).
#
# The LOCAL image store is the containerd one (ubuntu-26.04 runners, Docker
# 29), where `docker image inspect --format {{.Id}}` is the digest of the
# INDEX that was pulled, not the config digest the classic overlay2 store
# reports (base#1510, base#1514). The shard index and the published index
# carry the same linux/amd64 child, yet their `.Id`s differ.
_docker_stub() {
  mkdir -p "${SCRATCH}/bin"
  cat > "${SCRATCH}/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# _hex <ref>: the stored digest a reference names, refusing any reference
# the registry state does not hold.
_hex() {
  local _ref="${1}" _h _mark
  if [[ "${_ref}" == *@sha256:* ]]; then
    _h="${_ref##*@sha256:}"
  else
    _h="$(awk -v t="${_ref}" '$1 == t { print $2 }' "${STUB_FX}/tags")"
    if [[ -z "${_h}" ]]; then
      printf 'stub: unknown reference: %s\n' "${_ref}" >&2
      exit 91
    fi
    # A tag is mutable: when STUB_TAG_MOVED is set, the first read of a tag
    # by name answers its mapped hex and every later read by name answers
    # the moved index, the way a concurrent publish would.
    _mark="${STUB_FX}/.read-$(printf '%s' "${_ref}" | tr -c 'A-Za-z0-9' '_')"
    if [[ -n "${STUB_TAG_MOVED:-}" && -f "${_mark}" ]]; then
      _h="${STUB_TAG_MOVED}"
    fi
    : > "${_mark}"
  fi
  if [[ ! -f "${STUB_FX}/${_h}.json" ]]; then
    printf 'stub: no manifest stored under sha256:%s\n' "${_h}" >&2
    exit 92
  fi
  printf '%s\n' "${_h}"
}
case "${1:-}" in
  buildx)
    [[ "${2:-}" == 'imagetools' && "${3:-}" == 'inspect' ]] || {
      printf 'stub: unexpected docker invocation: %s\n' "${*}" >&2
      exit 90
    }
    shift 3
    _raw=0 _fmt='' _ref=''
    while [[ $# -gt 0 ]]; do
      case "${1}" in
        --raw) _raw=1 ;;
        --format) _fmt="${2}"; shift ;;
        --format=*) _fmt="${1#--format=}" ;;
        -*) printf 'stub: unexpected flag: %s\n' "${1}" >&2; exit 90 ;;
        *) _ref="${1}" ;;
      esac
      shift
    done
    _h="$(_hex "${_ref}")"
    if [[ -n "${_fmt}" ]]; then
      [[ "${_fmt}" == '{{.Manifest.Digest}}' ]] || {
        printf 'stub: unexpected format: %s\n' "${_fmt}" >&2
        exit 90
      }
      if [[ -n "${STUB_TAG_UNRESOLVED:-}" && "${_ref}" != *@sha256:* ]]; then
        printf '%s\n' "${STUB_TAG_ANSWER:-}"
      else
        printf 'sha256:%s\n' "${_h}"
      fi
    elif [[ "${_raw}" -eq 1 ]]; then
      cat "${STUB_FX}/${_h}.json"
      # A read that fails AFTER writing a usable body: the exit status is
      # the only sign anything went wrong.
      if [[ "${_h}" == "${STUB_RAW_FAIL:-}" ]]; then
        printf 'stub: registry read of sha256:%s failed\n' "${_h}" >&2
        exit 93
      fi
    else
      # buildx's human listing, derived from the same raw index.
      printf 'Name:      %s\n' "${_ref}"
      printf 'MediaType: application/vnd.oci.image.index.v1+json\n'
      printf 'Digest:    sha256:%s\n\n' "${_h}"
      printf 'Manifests: \n'
      _base="${_ref%@*}"
      jq -r --arg base "${_base%:*}" '.manifests[] |
          "  Name:        \($base)@\(.digest)\n  Platform:    \(.platform.os)/\(.platform.architecture)\(if .platform.variant then "/" + .platform.variant else "" end)\n"' \
          "${STUB_FX}/${_h}.json"
    fi
    ;;
  pull)
    # The step itself reads no local image store. This arm and the next are
    # kept so a step that pulls and reads `.Id` again gets the containerd
    # store's answer rather than a stub error.
    ;;
  image)
    # `docker image inspect --format {{.Id}} <ref>` on the containerd store:
    # the digest of the pulled index.
    printf 'sha256:%s\n' "$(_hex "${*: -1}")"
    ;;
  *)
    printf 'stub: unexpected docker invocation: %s\n' "${*}" >&2
    exit 90
    ;;
esac
SH
  chmod +x "${SCRATCH}/bin/docker"
}

# Digests of a real publish, run 41451556967 (base#1510): the two shard
# indexes the build jobs pushed, and the flattened index the tag resolved to
# after the create. Their raw JSON below is `docker buildx imagetools inspect
# --raw` of each, read back from ghcr.io. That run published test-tools, not
# a publish-worker image; the index shapes are the same ones this worker's
# shards and `imagetools create` produce, and only the repository name the
# spec serves them under differs.
_FX_SHARD_AMD64='a56897231c4de305d13a4239d383b86eb6db31e23dbc580b5c533bcfbef275e2'
_FX_SHARD_ARM64='b20adb715e65977b069de2ad2dbdb3e80cc702aaf39f361f865eca1581f240d1'
_FX_MAIN='e1486c027549f20207f134ad554e6da5b2c3fa4f77953dcd281a67a75231cafd'

# _fx <hex> -- store stdin as the raw index under sha256:<hex>.
_fx() {
  mkdir -p "${SCRATCH}/fx"
  cat > "${SCRATCH}/fx/${1}.json"
}

# _fx_real -- the raw indexes of run 41451556967, verbatim.
_fx_real() {
  _fx "${_FX_SHARD_AMD64}" <<'JSON'
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:ce29e05dca4c43414a0a607c3cc714d8b249386e9af33c576bad38a17f967d98",
      "size": 2769,
      "platform": {
        "architecture": "amd64",
        "os": "linux"
      }
    },
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:9ab55cf32b5cde968311d1467b911ebe76da4e44240934ed53c268b2b985bdec",
      "size": 838,
      "annotations": {
        "vnd.docker.reference.digest": "sha256:ce29e05dca4c43414a0a607c3cc714d8b249386e9af33c576bad38a17f967d98",
        "vnd.docker.reference.type": "attestation-manifest"
      },
      "platform": {
        "architecture": "unknown",
        "os": "unknown"
      }
    }
  ]
}
JSON
  _fx "${_FX_MAIN}" <<'JSON'
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:ce29e05dca4c43414a0a607c3cc714d8b249386e9af33c576bad38a17f967d98",
      "size": 2769,
      "platform": {
        "architecture": "amd64",
        "os": "linux"
      }
    },
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:9ab55cf32b5cde968311d1467b911ebe76da4e44240934ed53c268b2b985bdec",
      "size": 838,
      "annotations": {
        "vnd.docker.reference.digest": "sha256:ce29e05dca4c43414a0a607c3cc714d8b249386e9af33c576bad38a17f967d98",
        "vnd.docker.reference.type": "attestation-manifest"
      },
      "platform": {
        "architecture": "unknown",
        "os": "unknown"
      }
    },
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:7209dde70dcb2b29c3c146af1dc0a2f4e21a72a990b9498c9e67e48e478a8c89",
      "size": 2770,
      "platform": {
        "architecture": "arm64",
        "os": "linux"
      }
    },
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:7b848e2be96d5e6b1a76f89d0d651053a342899d9c58289f6a11a08edfe1f304",
      "size": 838,
      "annotations": {
        "vnd.docker.reference.digest": "sha256:7209dde70dcb2b29c3c146af1dc0a2f4e21a72a990b9498c9e67e48e478a8c89",
        "vnd.docker.reference.type": "attestation-manifest"
      },
      "platform": {
        "architecture": "unknown",
        "os": "unknown"
      }
    }
  ]
}
JSON
}

# _fx_content -- a tag index that lists both platforms under their correct
# labels, but whose linux/amd64 child is an image nothing verified.
_FX_CONTENT='deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
_fx_content() {
  _fx "${_FX_CONTENT}" <<'JSON'
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:ba5eba11ba5eba11ba5eba11ba5eba11ba5eba11ba5eba11ba5eba11ba5eba11",
      "size": 2769,
      "platform": {
        "architecture": "amd64",
        "os": "linux"
      }
    },
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:7209dde70dcb2b29c3c146af1dc0a2f4e21a72a990b9498c9e67e48e478a8c89",
      "size": 2770,
      "platform": {
        "architecture": "arm64",
        "os": "linux"
      }
    }
  ]
}
JSON
}

# _fx_index <hex> <entry>... -- store a hand-written raw index under
# sha256:<hex>. Each <entry> is `<child hex> <os>/<arch>[/<variant>]`, or
# `<child hex> attest <os>/<arch>` for a descriptor annotated as an
# attestation-manifest that still carries a real platform label.
_fx_index() {
  local _h="${1}" _e _d _kind _p _os _arch _var _sep='' _ann _vj
  shift
  {
    printf '{\n  "schemaVersion": 2,\n'
    printf '  "mediaType": "application/vnd.oci.image.index.v1+json",\n'
    printf '  "manifests": ['
    for _e in "$@"; do
      read -r _d _kind _p <<< "${_e}"
      _ann=''
      if [[ "${_kind}" == 'attest' ]]; then
        _ann='"annotations": {"vnd.docker.reference.type": "attestation-manifest"}, '
      else
        _p="${_kind}"
      fi
      IFS='/' read -r _os _arch _var <<< "${_p}"
      _vj=''
      [[ -n "${_var}" ]] && _vj=", \"variant\": \"${_var}\""
      printf '%s\n    {"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": "sha256:%s", "size": 1, %s"platform": {"architecture": "%s", "os": "%s"%s}}' \
          "${_sep}" "${_d}" "${_ann}" "${_arch}" "${_os}" "${_vj}"
      _sep=','
    done
    printf '\n  ]\n}\n'
  } | _fx "${_h}"
}

# Hand-written child digests: the real linux/amd64 and linux/arm64 children of
# run 41451556967, a second linux/amd64 image nothing verified, and two
# linux/arm children that differ only in variant.
_CH_AMD64='ce29e05dca4c43414a0a607c3cc714d8b249386e9af33c576bad38a17f967d98'
_CH_ARM64='7209dde70dcb2b29c3c146af1dc0a2f4e21a72a990b9498c9e67e48e478a8c89'
_CH_OTHER='ba5eba11ba5eba11ba5eba11ba5eba11ba5eba11ba5eba11ba5eba11ba5eba11'
_CH_ARMV6='6666666666666666666666666666666666666666666666666666666666666666'
_CH_ARMV7='7777777777777777777777777777777777777777777777777777777777777777'
_FX_CASE='c0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ff'
_FX_SHARD_ARMV6='a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6'
_FX_SHARD_ARMV7='a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7'

# _confirm_step_for <mode> -- RUN the merge job's tag-confirmation step
# against one registry state and return the step's OWN exit status, printing
# whatever it printed.
#
# The body is read OUT OF THE WORKFLOW with yq instead of restated here: a
# spec carrying its own copy of a check agrees with itself while the workflow
# drifts. TAGS carries BOTH tags a caller with `is_latest: true` gets, so the
# loop over them is exercised rather than assumed. The job verified the amd64
# shard index; the artifact files are named by the real shard digests.
#
# <mode>:
#   agree     an ordinary two-platform publish, run 41451556967's indexes
#             verbatim -- both tags resolve to the flattened index, a
#             DIFFERENT index from the verified shard one, and both carry the
#             same linux/amd64 child.
#   content   the version tag is the ordinary flattened index, but
#             `:latest` lists both platforms and its linux/amd64 child is
#             different content than was verified.
#   platform  both tags resolve to the amd64 shard index alone, so the
#             published manifest is missing an arch the matrix built.
#   moved     an ordinary publish whose tags move under the step: the first
#             read of each tag BY NAME answers the flattened index, every
#             later read by name answers an index whose linux/amd64 child is
#             content nothing verified, the way a concurrent publish would.
#   rawfail-tag / rawfail-verified
#             an ordinary publish, but the raw read of the flattened index
#             (the tags' side) or of the verified shard index exits non-zero
#             after printing its full, valid body.
#   attest-only
#             both tags resolve to an index whose only linux/amd64 entry is
#             annotated as an attestation-manifest.
#   ambiguous-tag
#             both tags resolve to an index with two linux/amd64 images, the
#             verified one listed first.
#   missing-verified / ambiguous-verified
#             the tags are the ordinary flattened index, but the verified
#             shard index has no linux/amd64 image, or has two.
#   variant   the verified shard is linux/arm/v7; it and the tags' index
#             both carry linux/arm/v6 and linux/arm/v7 images.
#   unresolved
#             resolving a tag by name to a digest exits 0 and prints nothing.
_confirm_step_for() {
  local _mode="${1}" _body _dir _base _ver _latest _moved='' _rawfail=''
  local _status=0 _unresolved='' _verified="${_FX_SHARD_AMD64}"
  local -a _arts=("${_FX_SHARD_AMD64}" 'linux/amd64'
    "${_FX_SHARD_ARM64}" 'linux/arm64')
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
  _fx_real
  case "${_mode}" in
    agree) _ver="${_FX_MAIN}" _latest="${_FX_MAIN}" ;;
    content) _fx_content; _ver="${_FX_MAIN}" _latest="${_FX_CONTENT}" ;;
    platform) _ver="${_FX_SHARD_AMD64}" _latest="${_FX_SHARD_AMD64}" ;;
    moved) _fx_content; _ver="${_FX_MAIN}" _latest="${_FX_MAIN}"
      _moved="${_FX_CONTENT}" ;;
    rawfail-tag) _ver="${_FX_MAIN}" _latest="${_FX_MAIN}"
      _rawfail="${_FX_MAIN}" ;;
    rawfail-verified) _ver="${_FX_MAIN}" _latest="${_FX_MAIN}"
      _rawfail="${_FX_SHARD_AMD64}" ;;
    attest-only)
      _fx_index "${_FX_CASE}" "${_CH_AMD64} attest linux/amd64" \
          "${_CH_ARM64} linux/arm64"
      _ver="${_FX_CASE}" _latest="${_FX_CASE}" ;;
    ambiguous-tag)
      _fx_index "${_FX_CASE}" "${_CH_AMD64} linux/amd64" \
          "${_CH_OTHER} linux/amd64" "${_CH_ARM64} linux/arm64"
      _ver="${_FX_CASE}" _latest="${_FX_CASE}" ;;
    missing-verified)
      _fx_index "${_FX_SHARD_AMD64}" "${_CH_ARM64} linux/arm64" \
          "${_CH_AMD64} attest linux/amd64"
      _ver="${_FX_MAIN}" _latest="${_FX_MAIN}" ;;
    ambiguous-verified)
      _fx_index "${_FX_SHARD_AMD64}" "${_CH_AMD64} linux/amd64" \
          "${_CH_OTHER} linux/amd64"
      _ver="${_FX_MAIN}" _latest="${_FX_MAIN}" ;;
    variant)
      _fx_index "${_FX_SHARD_ARMV7}" "${_CH_ARMV6} linux/arm/v6" \
          "${_CH_ARMV7} linux/arm/v7"
      _fx_index "${_FX_SHARD_ARMV6}" "${_CH_ARMV6} linux/arm/v6"
      _fx_index "${_FX_CASE}" "${_CH_ARMV6} linux/arm/v6" \
          "${_CH_ARMV7} linux/arm/v7"
      _ver="${_FX_CASE}" _latest="${_FX_CASE}"
      _verified="${_FX_SHARD_ARMV7}"
      _arts=("${_FX_SHARD_ARMV7}" 'linux/arm/v7'
        "${_FX_SHARD_ARMV6}" 'linux/arm/v6') ;;
    unresolved) _ver="${_FX_MAIN}" _latest="${_FX_MAIN}" _unresolved=1 ;;
    *) printf 'BUG: unknown registry state %s\n' "${_mode}"; return 2 ;;
  esac
  # The artifact directory the step reads: one file per arch the matrix
  # built, named by that shard's digest and carrying the platform it built.
  local _i
  for (( _i = 0; _i < ${#_arts[@]}; _i += 2 )); do
    printf '%s\n' "${_arts[_i+1]}" > "${_dir}/digests/${_arts[_i]}"
  done
  _base='ghcr.io/ycpss91255-docker/ros_distro'
  printf '%s %s\n%s %s\n' \
      "${_base}:v1.2.3-standard" "${_ver}" \
      "${_base}:latest-standard" "${_latest}" > "${SCRATCH}/fx/tags"
  _docker_stub
  (
    cd -- "${_dir}/digests" || exit 2
    PATH="${SCRATCH}/bin:${PATH}" \
    STUB_FX="${SCRATCH}/fx" \
    STUB_TAG_MOVED="${_moved:-}" \
    STUB_RAW_FAIL="${_rawfail:-}" \
    STUB_TAG_UNRESOLVED="${_unresolved:-}" \
    STUB_TAG_ANSWER='' \
    TAGS="${_base}:v1.2.3-standard,${_base}:latest-standard" \
    VERIFIED_REF="${_base}@sha256:${_verified}" \
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

# why: On the containerd image store (Docker 29 on ubuntu-26.04, which is
# `ubuntu-latest` today) `docker image inspect --format {{.Id}}` answers the
# digest of the pulled INDEX, not the config digest. In a multi-platform
# publish the verified ref names a shard index and every tag names the
# flattened published index -- two different indexes -- so an `.Id`
# comparison refuses every multi-platform publish after its tags have moved.
# (A single-platform call is the exception: `imagetools create` copies its one
# shard index unchanged, so the two digests match there.) What both indexes
# share in either configuration is the runner-platform child, and that is the
# content the comparison has to be about. The child
# digest asserted below is read from run 41451556967's raw indexes, not
# computed by the step (base#1514, base#1510).
@test "publish-worker.yaml: the tag confirmation passes when the verified shard index and the tag's index differ but share the runner-platform child (base#1514)" {
  run _confirm_step_for agree
  assert_success
  assert_output --partial 'ros_distro:v1.2.3-standard resolves to the verified image for linux/amd64 (sha256:ce29e05dca4c43414a0a607c3cc714d8b249386e9af33c576bad38a17f967d98)'
  assert_output --partial 'ros_distro:latest-standard resolves to the verified image for linux/amd64 (sha256:ce29e05dca4c43414a0a607c3cc714d8b249386e9af33c576bad38a17f967d98)'
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

# why: A tag is mutable, so every read of it BY NAME may answer a different
# index: a concurrent publish can move it between the platform listing and
# the content comparison. A step that reads the tag by name more than once
# checks two different indexes and reports on neither -- here it would refuse
# content the run never published. Each tag has to be resolved ONCE to a
# digest and every later read made through that digest. The child asserted is
# the linux/amd64 descriptor of run 41451556967's flattened index, the one the
# tag answered first (base#1514, base#1510).
@test "publish-worker.yaml: the tag confirmation reads each tag by name once, so a tag that moves mid-step is judged on the index it first named (base#1514)" {
  run _confirm_step_for moved
  assert_success
  assert_output --partial 'ros_distro:v1.2.3-standard resolves to the verified image for linux/amd64 (sha256:ce29e05dca4c43414a0a607c3cc714d8b249386e9af33c576bad38a17f967d98)'
  assert_output --partial 'ros_distro:latest-standard resolves to the verified image for linux/amd64 (sha256:ce29e05dca4c43414a0a607c3cc714d8b249386e9af33c576bad38a17f967d98)'
}

# why: A registry read can write a complete, valid index body and still exit
# non-zero. A step that trusts the stdout of a failed read compares content
# the registry never confirmed, so a failed raw read of the TAG's index has
# to refuse even though the body it printed carries the verified child
# (base#1514, base#1510).
@test "publish-worker.yaml: the tag confirmation refuses when the raw read of a tag's index fails after printing a body (base#1514)" {
  run _confirm_step_for rawfail-tag
  assert_failure
  refute_output --partial 'resolves to the verified image'
}

# why: The same refusal on the other side: a failed raw read of the VERIFIED
# shard index leaves nothing confirmed to compare a tag with, whatever body
# it printed (base#1514, base#1510).
@test "publish-worker.yaml: the tag confirmation refuses when the raw read of the verified index fails after printing a body (base#1514)" {
  run _confirm_step_for rawfail-verified
  assert_failure
  refute_output --partial 'resolves to the verified image'
}

# why: With provenance on, every index carries attestation descriptors next
# to the images. One annotated as an attestation-manifest is not an image the
# smoke step could have run, even when it carries the runner's platform label
# -- and the tag listing still shows that platform, so only the content
# comparison can catch it (base#1514, base#1510).
@test "publish-worker.yaml: the tag confirmation refuses a tag whose only linux/amd64 entry is an attestation (base#1514)" {
  run _confirm_step_for attest-only
  assert_failure
  assert_output --partial 'carries 0 image manifests for linux/amd64'
}

# why: A tag index with two image manifests for the runner's platform names
# no single image, so it cannot be said to resolve to the verified one -- even
# when the verified child is listed first, which a first-match pick would
# accept (base#1514, base#1510).
@test "publish-worker.yaml: the tag confirmation refuses a tag index with two image manifests for the runner platform (base#1514)" {
  run _confirm_step_for ambiguous-tag
  assert_failure
  assert_output --partial "ros_distro@sha256:${_FX_CASE} carries 2 image manifests for linux/amd64"
  refute_output --partial 'resolves to the verified image'
}

# why: The verified side is held to the same rule. A verified index without
# an image for the runner's platform leaves nothing to compare a tag with; a
# step that let it through would compare an empty answer with an empty one
# (base#1514, base#1510).
@test "publish-worker.yaml: the tag confirmation refuses when the verified index has no image for the runner platform (base#1514)" {
  run _confirm_step_for missing-verified
  assert_failure
  assert_output --partial "ros_distro@sha256:${_FX_SHARD_AMD64} carries 0 image manifests for linux/amd64"
  refute_output --partial 'resolves to the verified image'
}

# why: A verified index with two images for the runner's platform does not
# say which one the smoke step ran (base#1514, base#1510).
@test "publish-worker.yaml: the tag confirmation refuses when the verified index has two images for the runner platform (base#1514)" {
  run _confirm_step_for ambiguous-verified
  assert_failure
  assert_output --partial "ros_distro@sha256:${_FX_SHARD_AMD64} carries 2 image manifests for linux/amd64"
}

# why: A platform with a variant (linux/arm/v7) shares os and architecture
# with its siblings. Matching on os/arch alone finds two images and refuses
# an ordinary publish; the variant the shard recorded is what picks the one
# that was verified. The child asserted is the hand-written v7 descriptor
# (base#1514, base#1510).
@test "publish-worker.yaml: the tag confirmation matches the platform variant the verified shard recorded (base#1514)" {
  run _confirm_step_for variant
  assert_success
  assert_output --partial "ros_distro:v1.2.3-standard resolves to the verified image for linux/arm/v7 (sha256:${_CH_ARMV7})"
  assert_output --partial "ros_distro:latest-standard resolves to the verified image for linux/arm/v7 (sha256:${_CH_ARMV7})"
}

# why: A tag that does not resolve to a digest cannot be pinned, and every
# read after it would name nothing (base#1514, base#1510).
@test "publish-worker.yaml: the tag confirmation refuses a tag that resolves to no digest (base#1514)" {
  run _confirm_step_for unresolved
  assert_failure
  refute_output --partial 'resolves to the verified image'
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
