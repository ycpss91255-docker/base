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
# BuildKit `--progress=plain` shapes -- a `#<id> [stage 8/16] RUN ...`
# step line followed by `#<id> CACHED` or `#<id> DONE 0.4s` -- which is
# the format build.sh pins.
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

# Narrows ${output} to build.sh's OWN log lines, discarding the BuildKit
# progress log the stub replays and build.sh tees straight to stdout.
#
# Without this, an assertion over the captured stream is satisfied by the
# FIXTURE rather than by the reporter: the words CACHED, bats, hadolint
# and shellcheck are all literally present in the replayed log whatever
# _report_verification_run does with them. Measured: gutting the report so
# it named one cached tool instead of three, and then so it named none and
# dropped the word CACHED from its own text, left every assertion in the
# headline spec below passing. A report assertion has to read the report.
narrow_to_report() {
  output="$(printf '%s\n' "${output}" \
    | grep -E '\[build\] (INFO|WARN|ERROR|DEBUG)' || true)"
  # bats-assert's assert_line / refute_line read ${lines}; keep the two
  # halves of bats' result contract consistent with each other.
  # shellcheck disable=SC2034  # consumed by bats-assert, not by this file
  mapfile -t lines <<< "${output}"
}

# ── the load-bearing spec: CACHED must not read as a pass ────────────

@test "build.sh test: a fully CACHED verification stage is not reported as a pass" {
  export DOCKER_BUILD_OUTPUT="${ALL_CACHED}"
  run bash "${SANDBOX}/build.sh" test
  assert_success
  # Asserted against build.sh's own output alone (see narrow_to_report):
  # every literal below also appears in the replayed progress log, so
  # over the whole stream none of them would be evidence about the report.
  narrow_to_report
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
  # Listed in Dockerfile order (by step id), not hash order: two runs of
  # the same build have to produce the same line.
  assert_output --partial "cached: shellcheck, hadolint"
}

# ── a consumer's own verification stage is verification ──────────────
#
# base emits every non-blocklisted `<stage>-test` in a consumer Dockerfile
# as a compose service, so `just docker build <stage>-test` is a supported
# call on a stage base has never seen. What that stage RUNs is the
# consumer's business -- a Playwright gate, pytest, colcon test, the
# template's own `RUN bash -c "${RUNTIME_SMOKE_CMD}"` install-check, a
# heredoc script. The report may not require it to be one of three
# binaries base happens to know.

@test "build.sh field-test: the template's own RUNTIME_SMOKE_CMD style is a check" {
  # dist/dockerfile/Dockerfile documents this as style (a), "the bare,
  # dependency-free default" for a `-test` stage: an ldd-based
  # install-check run through a bash -c wrapper. It names none of
  # bats / hadolint / shellcheck.
  export DOCKER_BUILD_OUTPUT="$(cat <<'EOF'
#9 [field-test 3/3] RUN bash -c "whoami && bash --version && bash /usr/local/lib/base/smoke.sh"
#9 0.312 tester
#9 DONE 1.7s
EOF
)"
  run bash "${SANDBOX}/build.sh" field-test
  assert_success
  narrow_to_report
  assert_output --partial "executed all 1 check step"
  refute_output --partial "ERROR"
}

@test "build.sh e2e-test: a Playwright gate's own steps are the check steps" {
  # omniverse_web_viewer's shipped stage, verbatim. Its first step was
  # cached and its second ran, which is the report that has to come out.
  export DOCKER_BUILD_OUTPUT="$(cat <<'EOF'
#14 [e2e-test 4/5] RUN npm install && npx playwright install --with-deps chromium
#14 CACHED
#17 [e2e-test 5/5] RUN bash /e2e/run-in-image.sh
#17 12.4 Running 24 tests using 4 workers
#17 DONE 12.4s
EOF
)"
  run bash "${SANDBOX}/build.sh" e2e-test
  assert_success
  narrow_to_report
  assert_output --partial "executed 1 of 2 check step"
  # Named by what the step actually invokes, so the line can be checked
  # against the Dockerfile.
  assert_output --partial "cached: npm"
}

@test "build.sh cli-test: a heredoc RUN step is a check step" {
  # BuildKit's vertex name for a heredoc RUN is the header line alone --
  # the body never appears as a step at all -- so any rule that reads the
  # COMMAND to decide what a check is cannot see this stage's checks.
  export DOCKER_BUILD_OUTPUT="$(cat <<'EOF'
#8 [cli-test 2/2] RUN <<EOF
#8 CACHED
EOF
)"
  run bash "${SANDBOX}/build.sh" cli-test
  assert_success
  narrow_to_report
  assert_output --partial "nothing ran in this invocation"
  assert_output --partial "cli-test"
}

@test "build.sh custom-test: a verification stage with no RUN step warns, it does not fail" {
  # The build was read fine; the stage simply has no RUN of its own. base
  # has no authority to call a consumer's stage meaningless, so this says
  # out loud that nothing was checked and leaves the exit status alone.
  export DOCKER_BUILD_OUTPUT="$(cat <<'EOF'
#5 [internal] load build definition from Dockerfile
#5 DONE 0.0s
#9 [custom-test 2/2] COPY --from=builder /out /out
#9 CACHED
EOF
)"
  run bash "${SANDBOX}/build.sh" custom-test
  assert_success
  narrow_to_report
  assert_output --partial "WARN"
  assert_output --partial "not evidence"
}

# ── installing a check binary is not running one ─────────────────────

@test "build.sh test: an install step in a side stage is not a check that ran" {
  # A `COPY --from` toolchain stage can re-run while the -test stage it
  # feeds stays fully cached, so this is the one shape that can produce
  # "something executed" over checks that all came from cache. Counting
  # the install as a check downgrades the load-bearing all-cached warning
  # and names a tool that did not run -- #882's own failure, re-sourced.
  export DOCKER_BUILD_OUTPUT="$(cat <<'EOF'
#4 [tools 2/2] RUN apk add --no-cache bats shellcheck
#4 DONE 6.1s
#30 [devel-test  8/16] RUN shellcheck -S warning /lint/wrapper/*.sh /lint/lib/*.sh
#30 CACHED
#33 [devel-test 10/16] RUN hadolint Dockerfile
#33 CACHED
#42 [devel-test 16/16] RUN bats /smoke_test/
#42 CACHED
EOF
)"
  run bash "${SANDBOX}/build.sh" test
  assert_success
  narrow_to_report
  assert_output --partial "all 3 check step"
  assert_output --partial "nothing ran in this invocation"
  refute_output --partial "executed 1 of"
}

@test "build.sh test: a -test stage that only INSTALLS a tool is not reported as running it" {
  # The step executed, so the build is not silent about it -- but the
  # report may not put shellcheck in the ran list, because shellcheck did
  # not run. Naming the command word is what keeps the line checkable.
  export DOCKER_BUILD_OUTPUT="$(cat <<'EOF'
#12 [devel-test 5/9] RUN apt-get install -y --no-install-recommends shellcheck
#12 DONE 4.2s
EOF
)"
  run bash "${SANDBOX}/build.sh" test
  assert_success
  narrow_to_report
  assert_output --partial "executed all 1 check step"
  assert_output --partial "apt-get"
  refute_output --partial "(shellcheck)"
}

@test "build.sh test: a tool named only as an argument is not a check step" {
  # `ln -sf /opt/bats/bin/bats /usr/local/bin/bats` is the example the
  # matcher's comment always cited; `pip install bats` is the one it never
  # survived. Neither is a stage this target's report may count, and
  # neither is in a verification stage here.
  export DOCKER_BUILD_OUTPUT="$(cat <<'EOF'
#6 [builder 3/7] RUN pip install bats
#6 DONE 2.0s
#7 [builder 4/7] RUN ln -sf /opt/bats/bin/bats /usr/local/bin/bats
#7 DONE 0.1s
#42 [devel-test 16/16] RUN bats /smoke_test/
#42 DONE 3.1s
EOF
)"
  run bash "${SANDBOX}/build.sh" test
  assert_success
  narrow_to_report
  assert_output --partial "executed all 1 check step"
  assert_output --partial "(bats)"
}

# ── the report can fail, and failing is never a pass ─────────────────

@test "build.sh test: build output with no BuildKit progress lines fails the build" {
  # Not "the stage ran no checks" -- the captured output carries no
  # progress steps AT ALL, which means the format the report is read from
  # moved or the output was lost. That is the mechanism itself failing,
  # and it is the one thing that still stops the build.
  export DOCKER_BUILD_OUTPUT="Successfully built abc123"
  run bash "${SANDBOX}/build.sh" test
  assert_failure
  assert_output --partial "no BuildKit progress"
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
