#!/usr/bin/env bats
#
# config_gen_spec.bats -- config_gen_resolve, the host-side provisioning of
# the config generator image (base#1466, ADR-00000039).
#
# why: the config generator ships as a Go module under dockerfile/config-gen
# with dockerfile/Dockerfile.config-gen, and nothing on a consumer host
# builds it. config_gen_resolve names the image by a content digest of the
# Dockerfile and the module (the build context is dockerfile/config-gen, not
# the Dockerfile's own directory), provisions it once per shell, and refuses
# by name when it cannot. It shares the resolve/ensure/build path with the
# TOML bridge through lib/tool_image.sh (tool_image_spec.bats).
#
# docker is a mock that records its argv; the subtree is a scratch copy so
# the whole derivation runs inside the fixture. Unit level (ADR-00000018).

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  ROOT=/source
  unset CONFIG_GEN_IMAGE TOML_BRIDGE_IMAGE
  export TOML_BRIDGE_FORCE_DOCKER=1
}

teardown() {
  cleanup_mock_dir || true
}

# _seed_cg_subtree
#   A vendored subtree (prefix `vendored`, not `.base`: the prefix is the
#   consumer's to name) with its own lib copy, the config generator's build
#   inputs and the bridge's, and the `.version` + `dist/` markers.
_seed_cg_subtree() {
  SUB="${BATS_TEST_TMPDIR}/consumer/vendored"
  mkdir -p "${SUB}/dist/script/docker" "${SUB}/dockerfile"
  cp -a "${ROOT}/dist/script/docker/lib" "${SUB}/dist/script/docker/lib"
  cp -a "${ROOT}/dockerfile/Dockerfile.config-gen" "${SUB}/dockerfile/"
  cp -a "${ROOT}/dockerfile/config-gen" "${SUB}/dockerfile/config-gen"
  cp -a "${ROOT}/dockerfile/Dockerfile.toml-bridge" "${SUB}/dockerfile/"
  cp -a "${ROOT}/dockerfile/toml_bridge.py" "${SUB}/dockerfile/"
  printf 'v0.0.0-test\n' > "${SUB}/.version"
  LIB="${SUB}/dist/script/docker/lib"
  CG="${LIB}/config_gen.sh"
  TB="${LIB}/toml_bridge.sh"
  CG_DF="${SUB}/dockerfile/Dockerfile.config-gen"
  CG_CTX="${SUB}/dockerfile/config-gen"
  export DOCKER_LOG="${BATS_TEST_TMPDIR}/docker.log"
  : > "${DOCKER_LOG}"
}

# _mock_docker [present|absent|fail]
#   docker records its argv. `image inspect` answers present (0) or absent
#   (1); `build` succeeds, or with `fail` prints two lines and exits 125.
_mock_docker() {
  local _mode="${1:-absent}"
  create_mock_dir
  mock_cmd "docker" \
    'printf "%s\n" "$*" >> "${DOCKER_LOG}"
     case "$1" in
       image) [[ "'"${_mode}"'" == present ]] && exit 0; exit 1 ;;
       build)
         if [[ "'"${_mode}"'" == fail ]]; then
           echo "first-line of builder" >&2
           echo "second-line of builder" >&2
           exit 125
         fi
         exit 0 ;;
       *) exit 1 ;;
     esac'
}

# _derive -- the tag config_gen derives, printed. Runs in its own shell.
_derive() {
  bash -c "source '${CG}' && tool_image_derive config_gen"
}

# _expected_tag -- `config-gen:` + the first 12 hex of the digest over the
#   Dockerfile and the context dir, computed here from project_reclaim.sh.
_expected_tag() {
  local _h
  _h="$(bash -c "source '${LIB}/log.sh' && source '${LIB}/project_reclaim.sh' \
    && _reclaim_tool_dockerfile_hash '${CG_DF}' '${CG_CTX}'")"
  printf 'config-gen:%s\n' "${_h:0:12}"
}

_count_inspects() {
  grep -c '^image inspect' "${DOCKER_LOG}" || true
}

# why: the identity rule shared with the bridge and the tooling tag
#      (base#1169): one digest function, twelve hex, over the Dockerfile
#      AND its build context dockerfile/config-gen.
@test "config-gen: the tag is config-gen:<12 hex> of the Dockerfile and its context" {
  _seed_cg_subtree
  run _derive
  assert_success
  assert_output --regexp '^config-gen:[0-9a-f]{12}$'
  assert_output "$(_expected_tag)"
}

# why: a tag keyed only on the Dockerfile, or only on the module's top
#      level, would keep the old name after a Go edit: the build is skipped
#      as already present and the run uses a stale generator. Both files
#      exist before the baseline and only their BYTES change, so a tag keyed
#      on file names alone keeps its old value and fails here.
@test "config-gen: the tag follows a content edit of a nested internal/**.go and of go.sum" {
  _seed_cg_subtree
  mkdir -p "${CG_CTX}/internal/a/b"
  printf 'package b\n' > "${CG_CTX}/internal/a/b/x.go"
  printf 'example.com/m v1.0.0 h1:abc=\n' > "${CG_CTX}/go.sum"
  run _derive
  assert_success
  assert_output "$(_expected_tag)"
  local _t0="${output}"

  printf 'package b\n\nconst X = 1\n' > "${CG_CTX}/internal/a/b/x.go"
  run _derive
  assert_success
  assert_output --regexp '^config-gen:[0-9a-f]{12}$'
  assert_output "$(_expected_tag)"
  refute_output "${_t0}"
  local _t1="${output}"

  printf 'example.com/m v1.0.0 h1:xyz=\n' > "${CG_CTX}/go.sum"
  run _derive
  assert_success
  assert_output --regexp '^config-gen:[0-9a-f]{12}$'
  assert_output "$(_expected_tag)"
  refute_output "${_t0}"
  refute_output "${_t1}"
}

# why: the default context of _reclaim_tool_dockerfile_hash is the
#      Dockerfile's directory, dockerfile/, which would key the tag on every
#      sibling tool's inputs (measured: an edit of Dockerfile.toml-bridge
#      moved it). The context is dockerfile/config-gen only.
@test "config-gen: the tag does not follow an edit outside dockerfile/config-gen" {
  _seed_cg_subtree
  run _derive
  assert_success
  local _t0="${output}"

  printf '\n# unrelated revision\n' >> "${SUB}/dockerfile/Dockerfile.toml-bridge"
  run _derive
  assert_success
  assert_output "${_t0}"
}

# why: the memo has to live in the caller's shell. A resolve that prints
#      its answer is read through $(...), where no memo survives and each
#      read inspects (and maybe builds) again.
@test "config-gen: resolve memoises in the caller's shell: one inspect for three resolves" {
  _seed_cg_subtree
  _mock_docker absent

  run --separate-stderr bash -c "source '${CG}'
config_gen_resolve || exit 7
p=\"\${_CONFIG_GEN_RESOLVED}\"
config_gen_resolve || exit 8
s=\"\$(config_gen_resolve; echo \"\${_CONFIG_GEN_RESOLVED}\")\"
printf 'parent=%s\n' \"\${p}\"
printf 'sub=%s\n' \"\${s}\""
  assert_success
  local _tag
  _tag="$(_expected_tag)"
  assert_line "parent=${_tag}"
  assert_line "sub=${_tag}"
  assert_equal "$(_count_inspects)" 1
}

# why: config_gen_resolve answers through the global, never on stdout, and
#      sourcing the file again keeps the memo.
@test "config-gen: resolve publishes _CONFIG_GEN_RESOLVED, prints nothing, survives a re-source" {
  _seed_cg_subtree
  _mock_docker present

  run --separate-stderr bash -c "source '${CG}'
out=\"\$(config_gen_resolve)\"
printf 'printed=[%s]\n' \"\${out}\"
config_gen_resolve
source '${CG}'
printf 'memo=%s\n' \"\${_CONFIG_GEN_RESOLVED}\""
  assert_success
  assert_line "printed=[]"
  assert_line "memo=$(_expected_tag)"
}

# why: CONFIG_GEN_IMAGE pins an image (CI, a published tag). Building or
#      even inspecting over what the caller asked for is the mistake
#      _ensure_test_tools_image declines to make.
@test "config-gen: CONFIG_GEN_IMAGE is used verbatim with no inspect and no build" {
  _seed_cg_subtree
  _mock_docker absent

  run --separate-stderr bash -c "export CONFIG_GEN_IMAGE=pinned/cg:v1
source '${CG}'
config_gen_resolve || exit 7
printf '%s\n' \"\${_CONFIG_GEN_RESOLVED}\""
  assert_success
  assert_output "pinned/cg:v1"
  run cat "${DOCKER_LOG}"
  assert_output ""
}

# why: set-but-empty follows TOML_BRIDGE_IMAGE: it counts as unset, so the
#      tag is derived and inspected.
@test "config-gen: CONFIG_GEN_IMAGE set but empty derives and inspects" {
  _seed_cg_subtree
  _mock_docker present

  run --separate-stderr bash -c "export CONFIG_GEN_IMAGE=
source '${CG}'
config_gen_resolve || exit 7
printf '%s\n' \"\${_CONFIG_GEN_RESOLVED}\""
  assert_success
  assert_output "$(_expected_tag)"
  run cat "${DOCKER_LOG}"
  assert_line "image inspect $(_expected_tag)"
}

# why: the build context is dockerfile/config-gen (the Dockerfile's
#      `COPY . .`), the shipped stage is `final`, and the build record goes
#      to stderr: stdout is a caller's to read.
@test "config-gen: an absent image is built from dockerfile/config-gen at --target final" {
  _seed_cg_subtree
  _mock_docker absent

  LOG_FORMAT=json run --separate-stderr bash -c "source '${CG}'; config_gen_resolve"
  assert_success
  assert_output ""
  assert_log_event config_gen_building "${stderr}"
  local _tag
  _tag="$(_expected_tag)"
  run cat "${DOCKER_LOG}"
  assert_line "image inspect ${_tag}"
  assert_line "build -t ${_tag} -f ${CG_DF} --target final ${CG_CTX}"
}

# why: a failed build is a named refusal carrying the builder's output on
#      one line, rc 1 -- and a return, not an exit, so the caller decides.
@test "config-gen: a failed build refuses with config_gen_build_failed" {
  _seed_cg_subtree
  _mock_docker fail

  LOG_FORMAT=json run --separate-stderr bash -c "source '${CG}'; config_gen_resolve"
  assert_refusal 1 config_gen_build_failed "path=${CG_DF}" "status=125" \
    "first-line of builder second-line of builder"
}

@test "config-gen: a failed build does not exit the caller" {
  _seed_cg_subtree
  _mock_docker fail

  LOG_FORMAT=json run --separate-stderr bash -c "source '${CG}'
config_gen_resolve
echo alive"
  assert_success
  assert_output "alive"
  assert_log_event config_gen_build_failed "${stderr}"
}

# why: with no subtree root above the lib there is nothing to build from;
#      that is a refusal, never a fallback to a literal tag.
@test "config-gen: no subtree root refuses with config_gen_unprovisionable" {
  local _loose="${BATS_TEST_TMPDIR}/loose"
  mkdir -p "${_loose}"
  cp -a "${ROOT}/dist/script/docker/lib" "${_loose}/lib"
  local _lib
  _lib="$(cd "${_loose}/lib" && pwd -P)"
  export DOCKER_LOG="${BATS_TEST_TMPDIR}/docker.log"
  : > "${DOCKER_LOG}"
  _mock_docker present

  LOG_FORMAT=json run --separate-stderr bash -c "source '${_lib}/config_gen.sh'; config_gen_resolve"
  assert_refusal 1 config_gen_unprovisionable "lib=${_lib}"
}

@test "config-gen: a missing Dockerfile refuses with config_gen_unprovisionable" {
  _seed_cg_subtree
  _mock_docker present
  rm -f "${CG_DF}"

  LOG_FORMAT=json run --separate-stderr bash -c "source '${CG}'; config_gen_resolve"
  assert_refusal 1 config_gen_unprovisionable "path=${CG_DF}"
}

@test "config-gen: a missing build context refuses with config_gen_unprovisionable" {
  _seed_cg_subtree
  _mock_docker present
  rm -rf "${CG_CTX}"

  LOG_FORMAT=json run --separate-stderr bash -c "source '${CG}'; config_gen_resolve"
  assert_refusal 1 config_gen_unprovisionable "${CG_CTX}"
}

# why: a digest that fails, or that answers nothing, names no image; a
#      tag built from it would be `config-gen:` with no identity. Both are
#      refusals, never a literal or empty tag. The digest function is
#      replaced in the resolving shell, so the guard is judged alone.
@test "config-gen: a failed digest refuses with config_gen_unprovisionable" {
  _seed_cg_subtree
  _mock_docker present

  LOG_FORMAT=json run --separate-stderr bash -c "source '${CG}'
_reclaim_tool_dockerfile_hash() { return 1; }
config_gen_resolve"
  assert_refusal 1 config_gen_unprovisionable "path=${CG_DF}"
  assert_equal "$(_count_inspects)" "0"
}

@test "config-gen: an empty digest refuses with config_gen_unprovisionable" {
  _seed_cg_subtree
  _mock_docker present

  LOG_FORMAT=json run --separate-stderr bash -c "source '${CG}'
_reclaim_tool_dockerfile_hash() { return 0; }
config_gen_resolve"
  assert_refusal 1 config_gen_unprovisionable "path=${CG_DF}"
  assert_equal "$(_count_inspects)" "0"
}

# why: without docker the bridge path logs a build and then a build failure
#      whose output is "command not found" -- nothing names the cause.
#      config_gen_resolve names it.
@test "config-gen: docker missing from PATH refuses with config_gen_docker_missing" {
  _seed_cg_subtree
  local _bin="${BATS_TEST_TMPDIR}/nodocker" _d _f
  mkdir -p "${_bin}"
  local -a _dirs
  IFS=: read -r -a _dirs <<< "${PATH}"
  for _d in "${_dirs[@]}"; do
    [[ -d "${_d}" ]] || continue
    for _f in "${_d}"/*; do
      [[ -x "${_f}" && ! -d "${_f}" ]] || continue
      [[ "${_f##*/}" == docker ]] && continue
      [[ -e "${_bin}/${_f##*/}" ]] || ln -s "${_f}" "${_bin}/${_f##*/}"
    done
  done

  run --separate-stderr env LOG_FORMAT=json PATH="${_bin}" \
    "${_bin}/bash" -c "source '${CG}'; config_gen_resolve"
  assert_refusal 1 config_gen_docker_missing
  refute_stderr_contains config_gen_build_failed config_gen_building
}

# why: the two shims share one helper; their profiles and memos must not.
@test "config-gen: toml_bridge.sh and config_gen.sh in one shell keep separate tags and memos" {
  _seed_cg_subtree
  _mock_docker present

  run --separate-stderr bash -c "source '${TB}'; source '${CG}'"
  assert_success
  assert_equal "${stderr}" ""

  run --separate-stderr bash -c "source '${TB}'; source '${CG}'
_toml_bridge_resolve_image || exit 7
config_gen_resolve || exit 8
printf 'tb=%s\n' \"\${_TOML_BRIDGE_RESOLVED}\"
printf 'cg=%s\n' \"\${_CONFIG_GEN_RESOLVED}\""
  assert_success
  assert_line --regexp '^tb=toml-bridge:[0-9a-f]{12}$'
  assert_line "cg=$(_expected_tag)"
  assert_equal "$(_count_inspects)" 2
}
