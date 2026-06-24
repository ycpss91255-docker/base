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
  source /source/downstream/script/docker/wrapper/setup.sh

  create_mock_dir
  TEMP_DIR="$(mktemp -d)"
  # Ensure the per-repo config/docker/ path exists; setup.conf relocated
  # under #262 lives at ${BASE_PATH}/config/docker/config/docker/setup.conf, so fixtures
  # that write a sandbox setup.conf rely on the parent dir already being
  # there.
  mkdir -p "${TEMP_DIR}/config/docker"
}

teardown() {
  cleanup_mock_dir
  rm -rf "${TEMP_DIR}"
}
