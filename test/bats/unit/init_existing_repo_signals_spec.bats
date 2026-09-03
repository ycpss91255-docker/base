#!/usr/bin/env bats
#
# Unit tests: init.sh must be able to SAY which files it reads to decide
# "new repo" from "already set up", without running either path.
#
# Why this exists. The decision is a PROXY -- the presence of a file that
# only an already-initialized repo was supposed to carry -- and a proxy is
# valid only while nothing else ships that file. It inverted once already:
# the template began shipping a `Dockerfile`, every repo bootstrapped from
# it took the existing-repo branch, and the new-repo scaffold (the CI
# workflow, the changelog, the smoke tree) was never installed
# (ycpss91255-docker/base#928). Nothing failed, because nothing could name
# the proxy: the only statement of it was a bash condition in the middle of
# `main`.
#
# `--list-existing-repo-signals` is that statement, read out of the
# installer itself, so a checker (the template's shipped-file guard,
# ycpss91255-docker/template#18) derives the discriminator instead of
# restating it. Like `--list-installed-paths`, it is a query and not a run:
# it prints and exits BEFORE the template-source guard and before
# `cd "${REPO_ROOT}"`, so it can be asked of the base checkout itself
# without base's own tree being touched.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  INIT="/source/dist/script/base/init.sh"
}

@test "init.sh --list-existing-repo-signals prints a non-empty list and exits 0" {
  run bash "${INIT}" --list-existing-repo-signals
  assert_success
  assert [ "${#lines[@]}" -gt 0 ]
}

@test "init.sh --list-existing-repo-signals names the Dockerfile proxy (#928)" {
  run bash "${INIT}" --list-existing-repo-signals
  assert_success
  assert_line "Dockerfile"
}

@test "init.sh --list-existing-repo-signals emits repo-relative paths only" {
  run bash "${INIT}" --list-existing-repo-signals
  assert_success
  local _p
  for _p in "${lines[@]}"; do
    [[ "${_p}" != /* ]] || fail "absolute path in signal list: ${_p}"
    [[ "${_p}" != */ ]] || fail "trailing slash in signal list: ${_p}"
    [[ "${_p}" != .base/* ]] \
      || fail "subtree-internal path in signal list: ${_p}"
  done
}

@test "init.sh --list-existing-repo-signals output is sorted and free of duplicates" {
  run bash "${INIT}" --list-existing-repo-signals
  assert_success

  local _got="${BATS_TEST_TMPDIR}/got"
  printf '%s\n' "${lines[@]}" > "${_got}"

  run diff -u "${_got}" <(LC_ALL=C sort -u "${_got}")
  assert_success
}

@test "init.sh --list-existing-repo-signals mutates nothing and never leaves its cwd" {
  local _cwd="${BATS_TEST_TMPDIR}/cwd"
  mkdir -p "${_cwd}"
  cd "${_cwd}"

  run bash "${INIT}" --list-existing-repo-signals
  assert_success

  run find "${_cwd}" -mindepth 1
  assert_success
  assert_output ""
}

@test "init.sh --help names --list-existing-repo-signals" {
  run bash "${INIT}" --help
  assert_success
  assert_output --partial "--list-existing-repo-signals"
}
