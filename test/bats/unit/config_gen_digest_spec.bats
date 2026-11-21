#!/usr/bin/env bats
#
# config_gen_digest_spec.bats -- script/ci/config_gen_digest.sh, the one place
# that prints the config-gen digest of a checkout (base#2042, part of
# base#2037 / base#1848).
#
# why: the shell shim compares ${tag#*:} of `tool_image_derive config_gen`
# against the digest stamped into the test-tools image. The three build paths
# of that image call this script instead of each deriving the digest, so the
# script must print exactly that value, move with the config-gen sources and
# stay put for everything else, and refuse (empty stdout, non-zero) when no
# digest can be derived.
#
# The subtree is a scratch copy so the script runs against a seeded tree.
# The expected digest is the literal observed from the shell library itself
# (`tool_image_derive config_gen` -> config-gen:b3b5e2b5cdca), not recomputed
# here. Unit level (ADR-00000018).

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=json
  load "${BATS_TEST_DIRNAME}/test_helper"
  ROOT=/source
  # Observed on the tree these sources are copied from.
  WANT_DIGEST="b3b5e2b5cdca"
}

teardown() {
  cleanup_mock_dir || true
}

# _seed_digest_tree [--no-dockerfile]
#   A scratch copy holding dist/, the config-gen build inputs, the
#   test-tools Dockerfile, the script under test and `.version`.
_seed_digest_tree() {
  SUB="${BATS_TEST_TMPDIR}/tree"
  mkdir -p "${SUB}/dist/script/docker" "${SUB}/dockerfile" "${SUB}/script/ci"
  cp -a "${ROOT}/dist/script/docker/lib" "${SUB}/dist/script/docker/lib"
  if [[ "${1:-}" != "--no-dockerfile" ]]; then
    cp -a "${ROOT}/dockerfile/Dockerfile.config-gen" "${SUB}/dockerfile/"
    cp -a "${ROOT}/dockerfile/config-gen" "${SUB}/dockerfile/config-gen"
  fi
  cp -a "${ROOT}/dockerfile/Dockerfile.test-tools" "${SUB}/dockerfile/"
  cp -a "${ROOT}/script/ci/config_gen_digest.sh" "${SUB}/script/ci/"
  printf 'v0.0.0-test\n' > "${SUB}/.version"
  DIGEST_SH="${SUB}/script/ci/config_gen_digest.sh"
}

# why: acceptance 1. One line, 12 lowercase hex, exit 0, equal to the part
#      after the colon of the shell library's own answer on this tree.
@test "config_gen_digest: prints the 12 hex of config-gen:<digest>, one line, exit 0" {
  _seed_digest_tree
  run --separate-stderr bash "${DIGEST_SH}"
  assert_success
  assert_output --regexp '^[0-9a-f]{12}$'
  assert_output "${WANT_DIGEST}"
}

# why: acceptance 2. The digest follows the config-gen sources and nothing else.
@test "config_gen_digest: a content edit under dockerfile/config-gen changes the value" {
  _seed_digest_tree
  printf '// edit\n' >> "${SUB}/dockerfile/config-gen/go.mod"
  run --separate-stderr bash "${DIGEST_SH}"
  assert_success
  assert_output --regexp '^[0-9a-f]{12}$'
  refute_output "${WANT_DIGEST}"
}

# why: acceptance 2. Dockerfile.config-gen itself is a digest input, so a
#      content edit of it must change the value.
@test "config_gen_digest: a content edit of Dockerfile.config-gen changes the value" {
  _seed_digest_tree
  printf '# edit\n' >> "${SUB}/dockerfile/Dockerfile.config-gen"
  run --separate-stderr bash "${DIGEST_SH}"
  assert_success
  refute_output "${WANT_DIGEST}"
}

# why: acceptance 2. Dockerfile.test-tools and script/ are not digest
#      inputs, so editing them must leave the value unchanged.
@test "config_gen_digest: editing Dockerfile.test-tools or a file under script/ leaves the value" {
  _seed_digest_tree
  printf '# edit\n' >> "${SUB}/dockerfile/Dockerfile.test-tools"
  printf '# edit\n' > "${SUB}/script/ci/unrelated.sh"
  run --separate-stderr bash "${DIGEST_SH}"
  assert_success
  assert_output "${WANT_DIGEST}"
}

# why: acceptance 3. No derivable digest: nothing on stdout, non-zero, and
#      the library's refusal reaches stderr unchanged.
@test "config_gen_digest: no Dockerfile.config-gen prints nothing, exits non-zero, forwards the refusal" {
  _seed_digest_tree --no-dockerfile
  run --separate-stderr bash "${DIGEST_SH}"
  assert_failure
  assert_output ""
  [[ "${stderr}" == *'"body":"config_gen_unprovisionable"'* ]]
  [[ "${stderr}" == *'cannot build the config generator image:'* ]]
  [[ "${stderr}" == *'Dockerfile.config-gen'* ]]
}
