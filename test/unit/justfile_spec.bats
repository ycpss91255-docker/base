#!/usr/bin/env bats
#
# Static checks for the layered user-facing just entry (ADR-00000010):
# the entry at downstream/script/justfile (symlinked into the consumer as
# script/justfile, with <repo>/justfile -> script/justfile) imports the
# docker recipes at downstream/script/docker/justfile.docker as top-level
# verbs. ADR-00000005: `just` replaces the GNU make wrapper -- recipes
# forward 1:1 to ./script/<name>.sh with full `{{args}}` passthrough (no
# MAKEOVERRIDES guard / `--` separator / EXEC_ARGS shim).
#
# These are content assertions (grep), not execution: `just` is not
# installed in the test-tools image, so the files are verified statically
# here; downstream installs `just` to run them. Execution parity lives in
# justfile_user_spec.bats.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  # Verb recipes live in the docker module; the `default` recipe + the
  # import live in the entry.
  DOCKER_JUSTFILE=/source/downstream/script/docker/justfile.docker
  ENTRY=/source/downstream/script/justfile
}

@test "layered entry + docker module exist" {
  [ -f "${ENTRY}" ]
  [ -f "${DOCKER_JUSTFILE}" ]
}

@test "docker module declares args-passthrough recipes for every wrapper verb (#545)" {
  local _v
  for _v in build run exec stop prune setup; do
    run grep -E "^${_v} \*args:" "${DOCKER_JUSTFILE}"
    assert_success
  done
  run grep -E '^setup-tui \*args:' "${DOCKER_JUSTFILE}"
  assert_success
}

@test "docker module no longer carries upgrade/upgrade-check (moved to base ns, #652)" {
  # upgrade is a .base-management op, not a docker op -- it lives in the
  # `base` namespace (just base upgrade / just base update), ADR-00000011.
  run grep -E '^upgrade |^upgrade-check:' "${DOCKER_JUSTFILE}"
  assert_failure
}

@test "docker module recipes forward to ./script/<wrapper>.sh with {{args}} (#545)" {
  run grep -F './script/build.sh {{args}}' "${DOCKER_JUSTFILE}"
  assert_success
  run grep -F './script/run.sh {{args}}' "${DOCKER_JUSTFILE}"
  assert_success
  run grep -F './script/exec.sh {{args}}' "${DOCKER_JUSTFILE}"
  assert_success
  run grep -F './script/setup_tui.sh {{args}}' "${DOCKER_JUSTFILE}"
  assert_success
}

@test "base module declares upgrade + update (apt-aligned) forwarding to .base/upgrade.sh (#652, ADR-00000011)" {
  local _base=/source/downstream/script/base/justfile.base
  [ -f "${_base}" ]
  run grep -E '^upgrade \*args:' "${_base}"
  assert_success
  run grep -E '^update:' "${_base}"
  assert_success
  run grep -F './.base/upgrade.sh {{args}}' "${_base}"
  assert_success
  run grep -F './.base/upgrade.sh --check' "${_base}"
  assert_success
}

@test "entry mods the base namespace (#652, ADR-00000011)" {
  run grep -F "mod? base 'script/base/justfile.base'" "${ENTRY}"
  assert_success
}

@test "docker module owns a default recipe + pins cwd to repo root (#652, ADR-00000011)" {
  # As a mod? module (not a top-level import) it owns its own default
  # (`just docker` lists the verbs); module recipes default cwd to the
  # module dir, so `set working-directory := '../..'` pins them to the
  # repo root for the ./script/<wrapper>.sh calls.
  run grep -E '^default:' "${DOCKER_JUSTFILE}"
  assert_success
  run grep -F "set working-directory := '../..'" "${DOCKER_JUSTFILE}"
  assert_success
}

@test "entry mods the docker namespace + default recipe lists recipes (#652, ADR-00000011)" {
  # docker is a namespace (zero special case): `just docker build`, not a
  # top-level `just build`. bare `just` still lists via the entry default.
  run grep -F "mod? docker 'script/docker/justfile.docker'" "${ENTRY}"
  assert_success
  run grep -E '^default:' "${ENTRY}"
  assert_success
  run grep -F 'just --list' "${ENTRY}"
  assert_success
}
