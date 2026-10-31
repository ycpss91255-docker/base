#!/usr/bin/env bats
#
# tool_image_spec.bats -- lib/tool_image.sh, the shared resolve/ensure/build
# path for a tool image built from the vendored subtree (base#1466).
#
# why: the TOML bridge provisions its image from the shipped Dockerfile
# under a content-digest tag; the config generator needs the same, with a
# build context that is NOT the Dockerfile's directory and a build target.
# tool_image.sh holds that logic once, parameterised by a profile:
#
#   tool_image_define <ns> <repo> <lib_dir> <dockerfile_rel> <context_rel>
#                     <override_var> <memo_var> [build_arg...]
#
# These cases drive a fake ns `demo` whose context is a sibling directory of
# its Dockerfile, so a helper that used the Dockerfile's own directory, or
# hard-coded a tool's override or memo name, goes red here. The bridge's own
# behaviour stays pinned, unchanged, by toml_bridge_spec.bats.
#
# docker is a mock that records its argv. Unit level (ADR-00000018).

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  ROOT=/source
  unset DEMO_IMAGE TOML_BRIDGE_IMAGE
  export TOML_BRIDGE_FORCE_DOCKER=1
}

teardown() {
  cleanup_mock_dir || true
}

# _seed_demo_subtree
#   A vendored subtree with its own lib copy (whose event registry also
#   carries the demo ns's ids), the bridge's inputs, and a demo tool:
#   dockerfile/Dockerfile.demo whose context is dockerfile/demo-ctx.
#   DEMO_PRELUDE sources the helper and defines the demo profile and its
#   display callback, for a `bash -c` to start from.
_seed_demo_subtree() {
  SUB="${BATS_TEST_TMPDIR}/consumer/vendored"
  mkdir -p "${SUB}/dist/script/docker" "${SUB}/dockerfile/demo-ctx"
  cp -a "${ROOT}/dist/script/docker/lib" "${SUB}/dist/script/docker/lib"
  cp -a "${ROOT}/dockerfile/Dockerfile.toml-bridge" "${SUB}/dockerfile/"
  cp -a "${ROOT}/dockerfile/toml_bridge.py" "${SUB}/dockerfile/"
  printf 'FROM scratch\nCOPY . .\n' > "${SUB}/dockerfile/Dockerfile.demo"
  printf 'payload v1\n' > "${SUB}/dockerfile/demo-ctx/payload.txt"
  printf 'v0.0.0-test\n' > "${SUB}/.version"
  LIB="${SUB}/dist/script/docker/lib"
  printf '\ndemo_building\ndemo_build_failed\ndemo_unprovisionable\n' \
    >> "${LIB}/log-events.txt"
  DEMO_DF="${SUB}/dockerfile/Dockerfile.demo"
  DEMO_CTX="${SUB}/dockerfile/demo-ctx"
  DEMO_PRELUDE="source '${LIB}/tool_image.sh'
_demo_tool_image_display() { printf 'DEMO-DISPLAY kind=%s image=%s' \"\$1\" \"\$2\"; }
tool_image_define demo demo-img '${LIB}' dockerfile/Dockerfile.demo dockerfile/demo-ctx DEMO_IMAGE _DEMO_RESOLVED --build-arg X=1
"
  export DOCKER_LOG="${BATS_TEST_TMPDIR}/docker.log"
  : > "${DOCKER_LOG}"
}

# _mock_docker [present|absent|fail]
_mock_docker() {
  local _mode="${1:-absent}"
  create_mock_dir
  mock_cmd "docker" \
    'printf "%s\n" "$*" >> "${DOCKER_LOG}"
     case "$1" in
       image) [[ "'"${_mode}"'" == present ]] && exit 0; exit 1 ;;
       build) [[ "'"${_mode}"'" == fail ]] && { echo "boom" >&2; exit 3; }; exit 0 ;;
       *) exit 1 ;;
     esac'
}

_demo_expected_tag() {
  local _h
  _h="$(bash -c "source '${LIB}/log.sh' && source '${LIB}/project_reclaim.sh' \
    && _reclaim_tool_dockerfile_hash '${DEMO_DF}' '${DEMO_CTX}'")"
  printf 'demo-img:%s\n' "${_h:0:12}"
}

_demo_derive() {
  bash -c "${DEMO_PRELUDE}
tool_image_derive demo"
}

# why: the context is a profile field used by the digest: the tag is
#      `<repo>:` + 12 hex over the Dockerfile and <context_rel>, it follows
#      an edit inside the context, and ignores one beside it.
@test "tool-image: the derived tag is keyed on the profile's context, not the Dockerfile's directory" {
  _seed_demo_subtree
  run _demo_derive
  assert_success
  assert_output --regexp '^demo-img:[0-9a-f]{12}$'
  assert_output "$(_demo_expected_tag)"
  local _t0="${output}"

  printf 'unrelated\n' > "${SUB}/dockerfile/sibling.txt"
  run _demo_derive
  assert_success
  assert_output "${_t0}"

  printf 'payload v2\n' > "${DEMO_CTX}/payload.txt"
  run _demo_derive
  assert_success
  refute_output "${_t0}"
}

# why: the same context field drives the build, and the build args sit
#      between the -f and the context; the build record goes to stderr.
@test "tool-image: an absent image is built from the profile's context with its build args" {
  _seed_demo_subtree
  _mock_docker absent

  LOG_FORMAT=json run --separate-stderr bash -c "${DEMO_PRELUDE}
tool_image_resolve demo || exit 7
printf '%s\n' \"\${_DEMO_RESOLVED}\" >&2"
  assert_success
  assert_output ""
  local _tag
  _tag="$(_demo_expected_tag)"
  assert_stderr_contains "${_tag}"
  assert_logged_event demo_building "image=${_tag}" "path=${DEMO_DF}" \
    "DEMO-DISPLAY kind=building"
  run cat "${DOCKER_LOG}"
  assert_line "image inspect ${_tag}"
  assert_line "build -t ${_tag} -f ${DEMO_DF} --build-arg X=1 ${DEMO_CTX}"
}

# why: the override and memo are the profile's variables, not a tool's
#      literal names: a non-empty override wins verbatim with no docker
#      call, and the memo is the named global.
@test "tool-image: the profile's override variable is used verbatim, with no docker call" {
  _seed_demo_subtree
  _mock_docker absent

  run --separate-stderr bash -c "export DEMO_IMAGE=pinned/demo:1
${DEMO_PRELUDE}
tool_image_resolve demo || exit 7
printf '%s\n' \"\${_DEMO_RESOLVED}\""
  assert_success
  assert_output "pinned/demo:1"
  run cat "${DOCKER_LOG}"
  assert_output ""
}

@test "tool-image: the profile's memo variable holds the resolution for the shell" {
  _seed_demo_subtree
  _mock_docker present

  run --separate-stderr bash -c "${DEMO_PRELUDE}
tool_image_resolve demo || exit 7
tool_image_resolve demo || exit 8
printf '%s\n' \"\${_DEMO_RESOLVED}\""
  assert_success
  assert_output "$(_demo_expected_tag)"
  assert_equal "$(grep -c '^image inspect' "${DOCKER_LOG}")" 1
}

# why: the shim's display callback writes the text; the helper owns the
#      event id, attributes and the folded builder output, and returns 1.
@test "tool-image: a failed build carries the display callback text and returns 1" {
  _seed_demo_subtree
  _mock_docker fail

  LOG_FORMAT=json run --separate-stderr bash -c "${DEMO_PRELUDE}
tool_image_resolve demo"
  assert_refusal 1 demo_build_failed "path=${DEMO_DF}" "status=3" \
    "DEMO-DISPLAY kind=build_failed"
}

@test "tool-image: a missing Dockerfile refuses as <ns>_unprovisionable" {
  _seed_demo_subtree
  _mock_docker present
  rm -f "${DEMO_DF}"

  LOG_FORMAT=json run --separate-stderr bash -c "${DEMO_PRELUDE}
tool_image_resolve demo"
  assert_refusal 1 demo_unprovisionable "path=${DEMO_DF}" \
    "DEMO-DISPLAY kind=no_dockerfile"
}

# why: TOML_BRIDGE_IMAGE set but empty counts as unset, as it does today:
#      the bridge derives and inspects. Pinned here because the bridge now
#      reaches the override through the helper.
@test "tool-image: the bridge with TOML_BRIDGE_IMAGE= derives and inspects" {
  _seed_demo_subtree
  _mock_docker present

  run --separate-stderr bash -c "export TOML_BRIDGE_IMAGE=
source '${LIB}/toml_bridge.sh'
_toml_bridge_resolve_image || exit 7
printf '%s\n' \"\${_TOML_BRIDGE_RESOLVED}\""
  assert_success
  assert_output --regexp '^toml-bridge:[0-9a-f]{12}$'
  local _tag="${output}"
  run cat "${DOCKER_LOG}"
  assert_line "image inspect ${_tag}"
}

# why: the bridge's functions are wrappers over the helper, so the bridge
#      and the helper name the same tag.
@test "tool-image: the toml_bridge wrapper and tool_image_derive toml_bridge agree" {
  _seed_demo_subtree
  run bash -c "source '${LIB}/toml_bridge.sh'
a=\"\$(_toml_bridge_derive_image)\" || exit 7
b=\"\$(tool_image_derive toml_bridge)\" || exit 8
[[ \"\${a}\" == \"\${b}\" ]] || { echo \"differ: \${a} \${b}\"; exit 9; }
printf '%s\n' \"\${a}\""
  assert_success
  assert_output --regexp '^toml-bridge:[0-9a-f]{12}$'
}
