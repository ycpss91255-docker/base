#!/usr/bin/env bats
#
# test_tools_config_gen_digest_spec.bats -- the local base build of the
# test-tools service forwards CONFIG_GEN_DIGEST to the image build
# (base#2044, part of base#2037 / base#1848 / base#1395).
#
# why: Dockerfile.test-tools stamps `-X main.contentDigest=${CONFIG_GEN_DIGEST}`
# and the shell shim compares that stamp with `tool_image_derive config_gen`.
# A local build that forwards nothing stamps an empty digest. So
# _ensure_test_tools_image must run script/ci/config_gen_digest.sh and hand
# its output to `docker compose build test-tools` as CONFIG_GEN_DIGEST, and
# compose.yaml must list the arg in the bare form so compose passes it on.
#
# The tree is a scratch copy so a config-gen source can be edited. The
# expected digest is the literal observed from the shell library itself
# (`tool_image_derive config_gen` -> config-gen:b3b5e2b5cdca on the seeded
# tree, the same literal config_gen_digest_spec.bats holds), not recomputed
# here. Unit level (ADR-00000018).

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=json
  load "${BATS_TEST_DIRNAME}/test_helper"
  create_mock_dir
  ROOT=/source
  # Observed on the tree these sources are copied from.
  WANT_DIGEST="b3b5e2b5cdca"
}

teardown() {
  cleanup_mock_dir || true
}

# _seed_tree
#   A scratch copy of the pieces test.sh and config_gen_digest.sh read.
_seed_tree() {
  SUB="${BATS_TEST_TMPDIR}/tree"
  mkdir -p "${SUB}"
  cp -a "${ROOT}/script" "${SUB}/script"
  cp -a "${ROOT}/dist" "${SUB}/dist"
  cp -a "${ROOT}/dockerfile" "${SUB}/dockerfile"
  cp -a "${ROOT}/compose.yaml" "${SUB}/compose.yaml"
  printf 'v0.0.0-test\n' > "${SUB}/.version"
}

# _mock_docker <log>
#   `image inspect` fails (image absent); `compose ... build test-tools`
#   records the CONFIG_GEN_DIGEST of its environment, `<unset>` when absent.
_mock_docker() {
  local _log="${1}"
  mock_cmd "docker" '
    [[ "${1}" == "image" ]] && exit 1
    if [[ "${1}" == "compose" ]]; then
      printf "%s\n" "${CONFIG_GEN_DIGEST-<unset>}" >> "'"${_log}"'"
    fi
    exit 0'
}

# _ensure_recorded <log>
#   Runs _ensure_test_tools_image from the scratch tree's test.sh.
_ensure_recorded() {
  local _log="${1}"
  : > "${_log}"
  run --separate-stderr bash -c '
    source "'"${SUB}"'/script/test/test.sh"
    export PATH="'"${MOCK_DIR}"':${PATH}"
    unset TEST_TOOLS_IMAGE CONFIG_GEN_DIGEST
    _ensure_test_tools_image test-tools:abc123abc123 base-000000000000
  '
}

# why: acceptance 1. The bare form, so compose omits the arg when unset.
@test "compose.yaml: test-tools build.args lists CONFIG_GEN_DIGEST in the bare form" {
  run grep -E '^[[:space:]]+- CONFIG_GEN_DIGEST$' "${ROOT}/compose.yaml"
  assert_success
}

# why: acceptance 2 and 4. The build sees the digest the script prints on the
#      same checkout, 12 hex.
@test "_ensure_test_tools_image: the compose build receives CONFIG_GEN_DIGEST" {
  _seed_tree
  local _log="${BATS_TEST_TMPDIR}/digest.log"
  _mock_docker "${_log}"
  _ensure_recorded "${_log}"
  assert_success
  run cat "${_log}"
  assert_output --regexp '^[0-9a-f]{12}$'
  assert_output "${WANT_DIGEST}"
  run bash "${SUB}/script/ci/config_gen_digest.sh"
  assert_output "${WANT_DIGEST}"
}

# why: acceptance 4. The value follows the config-gen sources.
@test "_ensure_test_tools_image: a content edit under dockerfile/config-gen changes the recorded digest" {
  _seed_tree
  printf '// edit\n' >> "${SUB}/dockerfile/config-gen/go.mod"
  local _log="${BATS_TEST_TMPDIR}/digest.log"
  _mock_docker "${_log}"
  _ensure_recorded "${_log}"
  assert_success
  run cat "${_log}"
  assert_output --regexp '^[0-9a-f]{12}$'
  refute_output "${WANT_DIGEST}"
}

# why: acceptance 4. An edit outside dockerfile/config-gen leaves it alone.
@test "_ensure_test_tools_image: an edit outside dockerfile/config-gen keeps the recorded digest" {
  _seed_tree
  printf '# edit\n' >> "${SUB}/dockerfile/Dockerfile.test-tools"
  local _log="${BATS_TEST_TMPDIR}/digest.log"
  _mock_docker "${_log}"
  _ensure_recorded "${_log}"
  assert_success
  run cat "${_log}"
  assert_output "${WANT_DIGEST}"
}

# why: acceptance 3. A script failure refuses through ci_tooling_build_failed
#      and never reaches `docker compose build`.
@test "_ensure_test_tools_image: a failing config_gen_digest.sh refuses and does not build" {
  _seed_tree
  printf '#!/usr/bin/env bash\nexit 1\n' > "${SUB}/script/ci/config_gen_digest.sh"
  local _log="${BATS_TEST_TMPDIR}/digest.log"
  _mock_docker "${_log}"
  local _sentinel="${BATS_TEST_TMPDIR}/continued-past-the-failed-digest"
  : > "${_log}"
  run bash -c '
    source "'"${SUB}"'/script/test/test.sh"
    export PATH="'"${MOCK_DIR}"':${PATH}"
    unset TEST_TOOLS_IMAGE CONFIG_GEN_DIGEST
    if _ensure_test_tools_image test-tools:abc123abc123 base-000000000000; then :; fi
    : > "'"${_sentinel}"'"
  '
  assert_failure
  refute [ -e "${_sentinel}" ]
  assert_output --partial "ci_tooling_build_failed"
  run cat "${_log}"
  assert_output ""
}

# why: acceptance 2. A caller-pinned image returns early and never runs the
#      script, so no build happens.
@test "_ensure_test_tools_image: a caller-pinned TEST_TOOLS_IMAGE builds nothing" {
  _seed_tree
  local _log="${BATS_TEST_TMPDIR}/digest.log"
  _mock_docker "${_log}"
  : > "${_log}"
  run bash -c '
    source "'"${SUB}"'/script/test/test.sh"
    export PATH="'"${MOCK_DIR}"':${PATH}"
    export TEST_TOOLS_IMAGE=ghcr.io/example/test-tools:pinned
    _ensure_test_tools_image test-tools:abc123abc123 base-000000000000
  '
  assert_success
  run cat "${_log}"
  assert_output ""
}
