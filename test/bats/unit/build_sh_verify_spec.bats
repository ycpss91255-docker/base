#!/usr/bin/env bats
#
# Unit tests for build.sh's verification-run report: the answer to "did
# this build EXECUTE the stage's shellcheck / hadolint / bats steps, or
# re-use CACHED layers?".
#
# The failure this pins is asymmetric -- a fully-cached `-test` build always
# looked like a passing one, because the wrapper printed the same thing
# either way. So the interesting spec is not "a passing run says pass", it
# is "a CACHED run cannot be read as a passing one", plus the two ways the
# report itself can go wrong (nothing recognisable in the output, or a step
# whose state never arrived). Both of those are FAILURES here: an
# unreadable build output is not evidence, and silence must never be
# reported as a pass.
#
# The build output is SYNTHESISED, never a real cache hit: arranging a real
# one needs a daemon, a warm buildx cache and a stage that happens not to
# have changed, none of which is deterministic. The stub emits the exact
# BuildKit `--progress=plain` shapes (`#12 [stage 8/16] RUN ...`,
# `#12 CACHED`, `#12 DONE 0.4s`), which is the format build.sh pins.
#
# Stub control env vars (read per-invocation by the docker stub):
#   DOCKER_BUILD_OUTPUT   text the stub prints for a `compose ... build`
#                         invocation -- the synthesised progress log.
#   DOCKER_PROGRESS_LOG   file the stub records $BUILDKIT_PROGRESS into,
#                         so the pinned progress mode is assertable.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC2154
  TEMP_DIR="$(mktemp -d)"
  export TEMP_DIR

  SANDBOX="${TEMP_DIR}/repo"
  mkdir -p "${SANDBOX}/.base/dist/script/docker/lib" \
           "${SANDBOX}/.base/dist/script/docker/wrapper" \
           "${SANDBOX}/config/docker"

  cp /source/dist/script/docker/lib/* "${SANDBOX}/.base/dist/script/docker/lib/"
  # Symlink (not copy) so kcov attributes coverage to the real wrapper.
  ln -s /source/dist/script/docker/wrapper/build.sh "${SANDBOX}/build.sh"

  # A resolved .env.generated + compose.yaml + .setup.conf keep the run on
  # the drift-check path, so setup.sh is never invoked and the build is the
  # only thing under test.
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env.generated"
  : > "${SANDBOX}/.setup.conf"
  echo "# mock compose" > "${SANDBOX}/compose.yaml"

  cat > "${SANDBOX}/.base/dist/script/docker/wrapper/setup.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOS
  chmod +x "${SANDBOX}/.base/dist/script/docker/wrapper/setup.sh"

  BIN_DIR="${TEMP_DIR}/bin"
  mkdir -p "${BIN_DIR}"
  DOCKER_PROGRESS_LOG="${TEMP_DIR}/progress.log"
  export DOCKER_PROGRESS_LOG
  : > "${DOCKER_PROGRESS_LOG}"

  # docker stub. `compose ... build` replays the synthesised progress log
  # and records the progress mode it was handed; `image inspect` fails so
  # the prune path stays out of the way; everything else no-ops.
  cat > "${BIN_DIR}/docker" <<'EOS'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
  exit 1
fi
for _a in "$@"; do
  if [[ "${_a}" == "build" ]]; then
    printf '%s\n' "${BUILDKIT_PROGRESS:-<unset>}" >> "${DOCKER_PROGRESS_LOG}"
    [[ -n "${DOCKER_BUILD_OUTPUT:-}" ]] && printf '%s\n' "${DOCKER_BUILD_OUTPUT}"
    exit 0
  fi
done
exit 0
EOS
  chmod +x "${BIN_DIR}/docker"
  export PATH="${BIN_DIR}:${PATH}"

  # A fully CACHED devel-test stage: the exact output the issue reported,
  # where every check was a cache hit and the wrapper said nothing.
  ALL_CACHED="$(cat <<'EOF'
#30 [devel-test  8/16] RUN shellcheck -S warning /lint/wrapper/*.sh /lint/lib/*.sh
#30 CACHED
#33 [devel-test 10/16] RUN hadolint Dockerfile
#33 CACHED
#42 [devel-test 16/16] RUN bats /smoke_test/
#42 CACHED
EOF
)"
  export ALL_CACHED

  # The same stage with every check step re-executed.
  ALL_RAN="$(cat <<'EOF'
#30 [devel-test  8/16] RUN shellcheck -S warning /lint/wrapper/*.sh /lint/lib/*.sh
#30 DONE 1.2s
#33 [devel-test 10/16] RUN hadolint Dockerfile
#33 DONE 0.4s
#42 [devel-test 16/16] RUN bats /smoke_test/
#42 0.512 ok 1 entrypoint is executable
#42 DONE 3.1s
EOF
)"
  export ALL_RAN
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# ── the load-bearing spec: CACHED must not read as a pass ────────────

@test "build.sh test: a fully CACHED verification stage is not reported as a pass" {
  export DOCKER_BUILD_OUTPUT="${ALL_CACHED}"
  run bash "${SANDBOX}/build.sh" test
  assert_success
  # Names the state, names every check that did not run, and says in
  # words that this run verified nothing.
  assert_output --partial "CACHED"
  assert_output --partial "bats"
  assert_output --partial "hadolint"
  assert_output --partial "shellcheck"
  assert_output --partial "nothing ran in this invocation"
  # And it is a WARNing, not an informational aside.
  assert_output --partial "WARN"
}

@test "build.sh test: an executed verification stage reports every check as executed" {
  export DOCKER_BUILD_OUTPUT="${ALL_RAN}"
  run bash "${SANDBOX}/build.sh" test
  assert_success
  assert_output --partial "executed all 3 check step"
  refute_output --partial "nothing ran in this invocation"
}

@test "build.sh test: a partially cached stage names which checks were CACHED" {
  # bats re-ran (a smoke spec changed) while the two linters ahead of it
  # stayed cached -- the case a whole-image comparison cannot see.
  export DOCKER_BUILD_OUTPUT="$(cat <<'EOF'
#30 [devel-test  8/16] RUN shellcheck -S warning /lint/wrapper/*.sh /lint/lib/*.sh
#30 CACHED
#33 [devel-test 10/16] RUN hadolint Dockerfile
#33 CACHED
#42 [devel-test 16/16] RUN bats /smoke_test/
#42 DONE 3.1s
EOF
)"
  run bash "${SANDBOX}/build.sh" test
  assert_success
  assert_output --partial "executed 1 of 3 check step"
  assert_output --partial "cached: hadolint, shellcheck"
}

# ── the report can fail, and failing is never a pass ─────────────────

@test "build.sh test: build output with no recognisable steps fails the build" {
  # The parse found nothing. Under this repo's rules that is an error, not
  # a pass: reporting success here is exactly the bug being fixed.
  export DOCKER_BUILD_OUTPUT="Successfully built abc123"
  run bash "${SANDBOX}/build.sh" test
  assert_failure
  assert_output --partial "no verification step"
  assert_output --partial "ERROR"
}

@test "build.sh test: a check step with no CACHED/DONE state fails the build" {
  # The step was announced and then never resolved (truncated output, a
  # progress printer that changed shape). Neither branch is provable, so
  # neither is claimed.
  export DOCKER_BUILD_OUTPUT="$(cat <<'EOF'
#30 [devel-test  8/16] RUN shellcheck -S warning /lint/wrapper/*.sh /lint/lib/*.sh
#30 CACHED
#42 [devel-test 16/16] RUN bats /smoke_test/
EOF
)"
  run bash "${SANDBOX}/build.sh" test
  assert_failure
  assert_output --partial "neither CACHED nor DONE"
  assert_output --partial "bats"
}

# ── the progress mode the parse depends on is pinned, not inherited ──

@test "build.sh test: pins BUILDKIT_PROGRESS=plain for a verification target" {
  # The parse reads one documented output shape. Leaving the mode to the
  # caller's environment is what would make it fragile, so the wrapper
  # sets it -- overriding a tty/auto value already in the environment.
  export DOCKER_BUILD_OUTPUT="${ALL_CACHED}"
  export BUILDKIT_PROGRESS=tty
  run bash "${SANDBOX}/build.sh" test
  assert_success
  run cat "${DOCKER_PROGRESS_LOG}"
  assert_output "plain"
}

# ── scope: only verification targets are reported on ─────────────────

@test "build.sh devel: a non-verification target gets no verification report" {
  export DOCKER_BUILD_OUTPUT="${ALL_CACHED}"
  run bash "${SANDBOX}/build.sh" devel
  assert_success
  refute_output --partial "verification:"
}

@test "build.sh --target test-tools: the tooling image build is not a verification target" {
  # `just test` and `just test smoke` both build this target first. It
  # runs no checks, so classifying it as a verification target would fail
  # every one of those runs on "no verification step".
  export DOCKER_BUILD_OUTPUT="#12 [test-tools 2/4] RUN apk add --no-cache bats
#12 CACHED"
  run bash "${SANDBOX}/build.sh" --target test-tools
  assert_success
  refute_output --partial "verification:"
}

@test "build.sh smoke: base's own smoke harness IS a verification target" {
  # base has no consumer Dockerfile; dockerfile/Dockerfile.smoke is the
  # stage stand-in `just test smoke` builds, and its `RUN bats` is the
  # whole test. A cached one had the identical hole.
  export DOCKER_BUILD_OUTPUT="#42 [smoke 9/9] RUN bats /smoke_test/
#42 CACHED"
  run bash "${SANDBOX}/build.sh" --target smoke
  assert_success
  assert_output --partial "nothing ran in this invocation"
}

@test "build.sh --dry-run test: no build ran, so nothing is reported about one" {
  run bash "${SANDBOX}/build.sh" --dry-run test
  assert_success
  refute_output --partial "verification:"
}
