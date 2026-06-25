#!/usr/bin/env bats
#
# Unit tests for script/test/lint_bare_stderr.sh -- the "all stderr goes
# through lib/log.sh helpers" lint. It scans the docker wrapper/lib tree
# and the test tree for bare `printf/echo ... >&2` lines that bypass the
# _log_* / _die helpers.
#
# The lint takes the repo root as $1 (defaulting to two levels up from the
# script), so the spec drives it against synthesized fixture trees laid out
# exactly like the real repo: sources live under downstream/script/docker/**
# and script/test/**. Exit contract: 0 = clean, 1 = violations found.

bats_require_minimum_version 1.5.0

LINT="/source/script/test/lint_bare_stderr.sh"

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  FIXTURE="$(mktemp -d)"
  mkdir -p "${FIXTURE}/downstream/script/docker/lib" \
           "${FIXTURE}/script/test"
}

teardown() {
  rm -rf "${FIXTURE}"
}

@test "flags a bare 'printf ... >&2' under downstream/script/docker (#692)" {
  cat > "${FIXTURE}/downstream/script/docker/lib/foo.sh" <<'EOF'
#!/usr/bin/env bash
_thing() {
  printf 'boom: %s\n' "${1}" >&2
}
EOF
  run bash "${LINT}" "${FIXTURE}"
  assert_failure
  assert_equal "${status}" 1
  assert_output --partial "downstream/script/docker/lib/foo.sh"
  assert_output --partial "bare stderr output"
}

@test "exits 0 on a clean tree (no bare stderr) (#692)" {
  cat > "${FIXTURE}/downstream/script/docker/lib/foo.sh" <<'EOF'
#!/usr/bin/env bash
_thing() {
  _log_err thing thing_failed "display=boom"
}
EOF
  run bash "${LINT}" "${FIXTURE}"
  assert_success
  assert_output ""
}

@test "does NOT flag an allowlisted _log_* line (#692)" {
  cat > "${FIXTURE}/downstream/script/docker/lib/foo.sh" <<'EOF'
#!/usr/bin/env bash
_thing() {
  _log_warn thing thing_warn "display=heads up" >&2
}
EOF
  run bash "${LINT}" "${FIXTURE}"
  assert_success
}

@test "does NOT flag an allowlisted getopts / [y/N] prompt line (#692)" {
  cat > "${FIXTURE}/downstream/script/docker/lib/foo.sh" <<'EOF'
#!/usr/bin/env bash
_thing() {
  printf 'Overwrite? [y/N] ' >&2
  while getopts ":h" opt; do printf 'bad: %s\n' "${OPTARG}" >&2; done
}
EOF
  run bash "${LINT}" "${FIXTURE}"
  assert_success
}

@test "the real repo tree (default root) is clean (#692)" {
  # No $1: the lint defaults its root to two levels up from the script,
  # i.e. the real /source tree. This guards the live wrapper/lib + test
  # tree against an un-allowlisted bare stderr AND the path-drift bug --
  # an empty find root would pass vacuously, but a populated correct root
  # proves the scan actually walks downstream/script/docker.
  run bash "${LINT}"
  assert_success
}
