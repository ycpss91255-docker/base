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
# The subtree is a scratch tree so the script runs against a seeded one. The
# config-gen inputs in it are a small FIXED synthetic set, not a copy of the
# live dockerfile/config-gen, so adding a file there (a corpus testdata file,
# say) cannot move the expected digest (base#2104). The expected digest is the
# literal the real script printed for that fixed tree, not recomputed here.
# Unit level (ADR-00000018).

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=json
  load "${BATS_TEST_DIRNAME}/test_helper"
  ROOT=/source
  # Observed from the script on the fixed synthetic tree of _seed_digest_tree.
  WANT_DIGEST="c86a33f64423"
}

teardown() {
  cleanup_mock_dir || true
}

# _seed_digest_tree [--no-dockerfile]
#   A scratch tree holding the live dist/ library and script under test, a
#   fixed synthetic Dockerfile.config-gen + config-gen/ context, a fixed
#   Dockerfile.test-tools and `.version`. Only dist/ and the script come
#   from ${ROOT}; nothing under ${ROOT}/dockerfile is read.
_seed_digest_tree() {
  SUB="${BATS_TEST_TMPDIR}/tree"
  mkdir -p "${SUB}/dist/script/docker" "${SUB}/dockerfile" "${SUB}/script/ci"
  cp -a "${ROOT}/dist/script/docker/lib" "${SUB}/dist/script/docker/lib"
  if [[ "${1:-}" != "--no-dockerfile" ]]; then
    mkdir -p "${SUB}/dockerfile/config-gen/internal"
    printf 'FROM scratch\nCOPY . /src\n' > "${SUB}/dockerfile/Dockerfile.config-gen"
    printf 'module example.test/config-gen\n\ngo 1.22\n' \
      > "${SUB}/dockerfile/config-gen/go.mod"
    printf 'package main\n\nfunc main() {}\n' \
      > "${SUB}/dockerfile/config-gen/main.go"
    printf 'package internal\n' > "${SUB}/dockerfile/config-gen/internal/a.go"
  fi
  printf 'FROM scratch\n' > "${SUB}/dockerfile/Dockerfile.test-tools"
  cp -a "${ROOT}/script/ci/config_gen_digest.sh" "${SUB}/script/ci/"
  printf 'v0.0.0-test\n' > "${SUB}/.version"
  DIGEST_SH="${SUB}/script/ci/config_gen_digest.sh"
}

# why: acceptance 1. One line, 12 lowercase hex, exit 0, equal to the digest
#      pinned in WANT_DIGEST for the fixed synthetic tree.
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

# why: base#2104. The spec must not read the live
#      dockerfile/config-gen: a checkout whose dockerfile/ holds an extra
#      testdata file gives the same pinned digest.
@test "config_gen_digest: an extra testdata file in the live checkout does not move the digest" {
  LIVE="${BATS_TEST_TMPDIR}/live"
  mkdir -p "${LIVE}/dockerfile/config-gen/testdata" "${LIVE}/script"
  cp -a "${ROOT}/dist" "${LIVE}/dist"
  cp -a "${ROOT}/script/ci" "${LIVE}/script/ci"
  cp -a "${ROOT}/dockerfile/Dockerfile.config-gen" "${LIVE}/dockerfile/"
  printf '{}\n' > "${LIVE}/dockerfile/config-gen/testdata/new_corpus.json"
  ROOT="${LIVE}"
  _seed_digest_tree
  run --separate-stderr bash "${DIGEST_SH}"
  assert_success
  assert_output "${WANT_DIGEST}"
}
