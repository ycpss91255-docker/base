#!/usr/bin/env bash
#
# Shared setup()/teardown() for the setup.sh unit specs.
#
# setup_spec.bats was split by concern (refs #377, #677) to let the CI
# bats-unit + coverage round-robin (which shards BY FILE) balance the
# per-shard floor. Every split file loads this helper so the common
# preamble stays single-sourced and cannot drift between files.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source setup.sh functions only (main is guarded)
  # shellcheck disable=SC1091
  source /source/dist/script/docker/wrapper/setup.sh

  create_mock_dir
  TEMP_DIR="$(mktemp -d)"
  # The per-repo config is setup.toml (ADR-37), so sandbox fixtures
  # write straight to ${TEMP_DIR}/setup.toml with no nested parent dir
  # to pre-create.

  # Override toml_bridge_parse to use the in-container bridge directly
  # instead of docker run (the test container has the bridge installed
  # at /usr/local/bin/toml-bridge via Dockerfile.test-tools).
  toml_bridge_parse() {
    local _file="${1:?missing file}"
    shift
    [[ -f "${_file}" ]] || { echo "toml_bridge_parse: file not found: ${_file}" >&2; return 1; }
    /usr/local/bin/toml-bridge "$@" < "${_file}"
  }
}

teardown() {
  cleanup_mock_dir
  rm -rf "${TEMP_DIR}"
}
