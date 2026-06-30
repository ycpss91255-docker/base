#!/usr/bin/env bats
#
# Static checks for base's self-use of the `docker` namespace
# (ADR-00000011 sec.2/4): base is the template SOURCE, so it has no `.base/`
# subtree -- it wires the docker namespace into its own root justfile and
# ships the wrapper symlinks pointing directly at dist/ (no `.base/`
# prefix), mirroring what init.sh produces for a consumer. `just` is not
# installed in the test-tools image, so these are content / symlink
# assertions, not execution (execution parity is a consumer/local concern).

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  ROOT=/source
}

@test "base root justfile mods the docker namespace (#713)" {
  run grep -E "^mod\?? docker 'script/docker/justfile.docker'" "${ROOT}/justfile"
  assert_success
}

@test "base ships script/docker/justfile.docker as a symlink into dist/ (no .base/)" {
  assert [ -L "${ROOT}/script/docker/justfile.docker" ]
  # Resolves to a real file under dist/script/docker (not via a .base/ hop).
  local _t
  _t="$(readlink -- "${ROOT}/script/docker/justfile.docker")"
  assert [ -f "${ROOT}/script/docker/justfile.docker" ]
  [[ "${_t}" != *".base/"* ]]
  [[ "${_t}" == *"dist/script/docker/justfile.docker" ]]
}

@test "base ships flat wrapper symlinks resolving into dist/script/docker/wrapper" {
  local _w
  for _w in build run exec stop prune setup setup_tui; do
    assert [ -L "${ROOT}/script/${_w}.sh" ]
    assert [ -f "${ROOT}/script/${_w}.sh" ]
    local _t
    _t="$(readlink -- "${ROOT}/script/${_w}.sh")"
    [[ "${_t}" != *".base/"* ]]
    [[ "${_t}" == *"dist/script/docker/wrapper/${_w}.sh" ]]
  done
}

@test "base compose.yaml declares a test-tools service building Dockerfile.test-tools" {
  run grep -nE '^\s{2}test-tools:' "${ROOT}/compose.yaml"
  assert_success
  # The service builds from the standalone tooling Dockerfile.
  run grep -nE 'dockerfile:\s*dockerfile/Dockerfile.test-tools' "${ROOT}/compose.yaml"
  assert_success
}

@test "just test system builds test-tools via the docker namespace, not a raw docker build (#713, ADR-00000011 sec.5)" {
  run grep -nE 'just docker build --target test-tools' "${ROOT}/script/test/justfile.test"
  assert_success
  # The raw `docker build -t test-tools:local -f dockerfile/Dockerfile.test-tools`
  # one-liner is gone -- the test runner invokes the docker namespace instead.
  run grep -nE 'docker build -t test-tools:local -f' "${ROOT}/script/test/justfile.test"
  assert_failure
}
