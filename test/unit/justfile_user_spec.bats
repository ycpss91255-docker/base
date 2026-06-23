#!/usr/bin/env bats
#
# Executable tests for the user-facing justfile at
# downstream/script/justfile (entry) + downstream/script/docker/justfile.docker (symlinked from downstream repo root as
# `justfile`). ADR-00000005 / #546: `just` replaces the GNU make wrapper.
# Each recipe is a 1:1 forward to ./script/<name>.sh with `{{args}}`
# passthrough -- no MAKEOVERRIDES guard / `--` separator / EXEC_ARGS shim.
#
# These RUN `just` for real (parity with the retired makefile_user_spec).
# They skip when `just` is not in the test-tools image yet (pre-release
# GHCR pull); see template_spec for the static `apk add ... just` guard
# and the release-test-tools smoke check. Static content lives in
# justfile_spec.bats.
#
# Strategy mirrors the old makefile_user_spec: sandbox a repo with the
# justfile symlinked at root and the wrapper scripts stubbed under
# script/, each recording `<name> <args...>` to ${TMP_REPO}/.invocation_log.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  command -v just >/dev/null 2>&1 || skip "just not installed in this test-tools image"

  # shellcheck disable=SC2154
  TMP_REPO="$(mktemp -d)"
  export TMP_REPO
  mkdir -p "${TMP_REPO}/.base/downstream/script/docker" "${TMP_REPO}/script/docker"

  # Layered entry chain (ADR-00000010): <repo>/justfile -> script/justfile
  # -> .base/downstream/script/justfile (entry), which imports
  # script/docker/justfile.docker (the top-level docker recipes).
  cp /source/downstream/script/justfile "${TMP_REPO}/.base/downstream/script/justfile"
  cp /source/downstream/script/docker/justfile.docker "${TMP_REPO}/.base/downstream/script/docker/justfile.docker"
  ln -s "script/justfile" "${TMP_REPO}/justfile"
  ln -s "../.base/downstream/script/justfile" "${TMP_REPO}/script/justfile"
  ln -s "../../.base/downstream/script/docker/justfile.docker" "${TMP_REPO}/script/docker/justfile.docker"

  local _name
  for _name in build run exec stop prune setup setup_tui; do
    cat > "${TMP_REPO}/script/${_name}.sh" <<EOS
#!/usr/bin/env bash
printf '${_name}'
for _arg in "\$@"; do printf ' %s' "\${_arg}"; done
printf '\n'
EOS
    chmod +x "${TMP_REPO}/script/${_name}.sh"
  done
  # upgrade wrapper lives under .base/
  mkdir -p "${TMP_REPO}/.base"
  cat > "${TMP_REPO}/.base/upgrade.sh" <<'EOS'
#!/usr/bin/env bash
printf 'upgrade'
for _arg in "$@"; do printf ' %s' "${_arg}"; done
printf '\n'
EOS
  chmod +x "${TMP_REPO}/.base/upgrade.sh"
}

teardown() {
  # Guard with an if-block (not `[ ] && rm`): when setup() skips before
  # TMP_REPO is set (e.g. `just` absent in the kcov runner image), the
  # `&&` chain exits non-zero and bats turns the clean skip into a
  # teardown failure (#613).
  if [ -n "${TMP_REPO:-}" ]; then
    rm -rf "${TMP_REPO}"
  fi
}

@test "just build forwards positional args to ./script/build.sh" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" build test
  assert_success
  assert_output --partial "build test"
}

@test "just build passes flags through verbatim (no -- separator needed)" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" build --no-cache test
  assert_success
  assert_output --partial "build --no-cache test"
}

@test "just exec passes = -bearing Kit-style args through (no EXEC_ARGS shim, #469)" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" exec -t cli --/app/k=v
  assert_success
  assert_output --partial "exec -t cli --/app/k=v"
}

@test "just run / stop / prune / setup forward to their wrappers" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" run -d
  assert_success
  assert_output --partial "run -d"
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" stop
  assert_success
  assert_output --partial "stop"
}

@test "just setup-tui forwards to ./script/setup_tui.sh" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" setup-tui
  assert_success
  assert_output --partial "setup_tui"
}

@test "just upgrade forwards to ./.base/upgrade.sh" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" upgrade v0.30.0
  assert_success
  assert_output --partial "upgrade v0.30.0"
}

@test "bare just lists recipes (replaces make help)" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}"
  assert_success
  assert_output --partial "build"
  assert_output --partial "run"
}

@test "repo-local group via script/local/justfile.local resolves as a top-level namespace (#632)" {
  # The entry imports script/local/justfile.local (`import?`); a group
  # registered there with a `mod?` line (path relative to script/local/)
  # becomes a top-level sub-command `just <group> <recipe>`.
  mkdir -p "${TMP_REPO}/script/local/greet"
  printf "mod? greet 'greet/justfile.greet'\n" > "${TMP_REPO}/script/local/justfile.local"
  printf 'hi:\n    @echo "greet-hi"\n' > "${TMP_REPO}/script/local/greet/justfile.greet"
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" greet hi
  assert_success
  assert_output --partial "greet-hi"
}
