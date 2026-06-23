#!/usr/bin/env bats
#
# Unit tests for the repo-local command-group scaffolder
# downstream/script/template/new.sh (#633, ADR-00000010). Runs new.sh
# directly (no `just` needed): it creates script/local/<name>/justfile.<name>
# + <name>.sh from skel/ and registers the group in
# script/local/justfile.local. Closes #594.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  SANDBOX="$(mktemp -d)"
  export SANDBOX
  # Mirror the shipped template tree so new.sh resolves skel/ relative to
  # itself, then run it with the sandbox as cwd (the [no-cd] recipe's cwd
  # is the repo root in production).
  mkdir -p "${SANDBOX}/script/template/skel" "${SANDBOX}/script/local"
  cp /source/downstream/script/template/new.sh "${SANDBOX}/script/template/new.sh"
  cp /source/downstream/script/template/skel/justfile.skel "${SANDBOX}/script/template/skel/justfile.skel"
  cp /source/downstream/script/template/skel/skel.sh "${SANDBOX}/script/template/skel/skel.sh"
  chmod +x "${SANDBOX}/script/template/new.sh"
}

teardown() {
  if [[ -n "${SANDBOX:-}" ]]; then
    rm -rf "${SANDBOX}"
  fi
}

@test "new.sh scaffolds script/local/<name>/{justfile.<name>,<name>.sh} from skel" {
  run bash -c "cd '${SANDBOX}' && ./script/template/new.sh deploy"
  assert_success
  assert [ -f "${SANDBOX}/script/local/deploy/justfile.deploy" ]
  assert [ -f "${SANDBOX}/script/local/deploy/deploy.sh" ]
  assert [ -x "${SANDBOX}/script/local/deploy/deploy.sh" ]
}

@test "new.sh substitutes __NAME__ in the scaffolded files" {
  run bash -c "cd '${SANDBOX}' && ./script/template/new.sh deploy"
  assert_success
  run grep -F '__NAME__' "${SANDBOX}/script/local/deploy/justfile.deploy" "${SANDBOX}/script/local/deploy/deploy.sh"
  assert_failure
  run grep -F 'deploy' "${SANDBOX}/script/local/deploy/deploy.sh"
  assert_success
}

@test "new.sh registers the group in script/local/justfile.local (mod? line)" {
  run bash -c "cd '${SANDBOX}' && ./script/template/new.sh deploy"
  assert_success
  run grep -F "mod? deploy 'deploy/justfile.deploy'" "${SANDBOX}/script/local/justfile.local"
  assert_success
}

@test "new.sh refuses to clobber an existing group" {
  bash -c "cd '${SANDBOX}' && ./script/template/new.sh deploy"
  run bash -c "cd '${SANDBOX}' && ./script/template/new.sh deploy"
  assert_failure
  assert_output --partial "already exists"
}

@test "new.sh does not duplicate the registry line on a second distinct group" {
  bash -c "cd '${SANDBOX}' && ./script/template/new.sh deploy"
  run bash -c "cd '${SANDBOX}' && ./script/template/new.sh backup"
  assert_success
  run grep -c '^mod? ' "${SANDBOX}/script/local/justfile.local"
  assert_output "2"
}

@test "new.sh rejects an invalid group name" {
  run bash -c "cd '${SANDBOX}' && ./script/template/new.sh 'Bad Name'"
  assert_failure
  assert_output --partial "invalid group name"
}

@test "new.sh errors with usage when no name given" {
  run bash -c "cd '${SANDBOX}' && ./script/template/new.sh"
  assert_failure
  assert_output --partial "usage"
}
