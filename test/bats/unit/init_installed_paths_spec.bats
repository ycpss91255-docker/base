#!/usr/bin/env bats
#
# Unit tests: init.sh must be able to SAY what it installs into a consumer,
# without installing anything.
#
# Why this exists. Every file init.sh writes into a consumer arrives only on
# an upgrade, so "which release is this repo on" and "did that release's
# files actually land" are different questions -- and only the first one was
# answerable. Anything auditing the second had to carry its own copy of the
# list, which decays the moment init.sh learns to install one more file.
#
# `--list-installed-paths` is the answer to the second question, read from
# the installer itself. It is a query, not a run: it must print the manifest
# and exit BEFORE the template-source guard and before `cd "${REPO_ROOT}"`,
# so an auditor can ask the base checkout what a consumer should contain
# without base's own tree being touched.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  INIT="/source/dist/script/base/init.sh"
}

@test "init.sh --list-installed-paths prints a non-empty manifest and exits 0" {
  run bash "${INIT}" --list-installed-paths
  assert_success
  assert [ "${#lines[@]}" -gt 0 ]
}

@test "init.sh --list-installed-paths lists the base version monitor workflow" {
  run bash "${INIT}" --list-installed-paths
  assert_success
  assert_line ".github/workflows/base-version-monitor.yaml"
}

@test "init.sh --list-installed-paths lists the wrapper symlinks and hook stubs" {
  run bash "${INIT}" --list-installed-paths
  assert_success
  assert_line "justfile"
  assert_line "script/build.sh"
  assert_line "script/hooks/pre/build.sh"
  assert_line "script/hooks/post/setup_tui.sh"
}

@test "init.sh --list-installed-paths emits repo-relative paths only" {
  run bash "${INIT}" --list-installed-paths
  assert_success
  local _p
  for _p in "${lines[@]}"; do
    [[ "${_p}" != /* ]] || fail "absolute path in manifest: ${_p}"
    [[ "${_p}" != */ ]] || fail "trailing slash in manifest: ${_p}"
    [[ "${_p}" != .base/* ]] \
      || fail "subtree-internal path in manifest: ${_p}"
  done
}

@test "init.sh --list-installed-paths output is sorted and free of duplicates" {
  run bash "${INIT}" --list-installed-paths
  assert_success

  local _got="${BATS_TEST_TMPDIR}/got"
  printf '%s\n' "${lines[@]}" > "${_got}"

  run diff -u "${_got}" <(LC_ALL=C sort -u "${_got}")
  assert_success
}

@test "init.sh --list-installed-paths mutates nothing and never leaves its cwd" {
  local _cwd="${BATS_TEST_TMPDIR}/cwd"
  mkdir -p "${_cwd}"
  cd "${_cwd}"

  run bash "${INIT}" --list-installed-paths
  assert_success

  run find "${_cwd}" -mindepth 1
  assert_success
  assert_output ""
}
