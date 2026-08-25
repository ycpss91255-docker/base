#!/usr/bin/env bats
#
# System-level: the LOCAL smoke harness behind `just test smoke` really runs
# the shipped smoke specs, really runs them as a non-root user, and really
# fails when one of them fails (ISTQB taxonomy, ADR-00000018 -- System
# level). Sister of test/bats/unit/smoke_harness_spec.bats, which pins the
# harness's COPY set against the shipped devel-test stage statically; this
# file is what proves the harness is a GATE and not a report.
#
# Every case builds the REAL dockerfile/Dockerfile.smoke. Only the build
# CONTEXT is synthesized -- a minimal copy of the paths the harness COPYs,
# so a spec can be added to it without touching the checkout. Building a
# fixture Dockerfile instead would assert against the fixture and leave the
# real one unproven, which is the shape the harness exists to replace.
#
# Requires the ci-system compose service (mounts host /var/run/docker.sock).
# Auto-skips when the socket is absent so accidental invocation via the
# default `ci` service is harmless.
#
# Each @test invokes one `docker build` over an alpine-based image with no
# package installs -- a few seconds once the tooling image is warm.

bats_require_minimum_version 1.5.0

setup_file() {
  if [[ ! -S "${SYSTEM_DOCKER_SOCK:-/var/run/docker.sock}" ]]; then
    skip "system test: docker socket not mounted (run via 'just test system')"
  fi
  if ! command -v docker >/dev/null 2>&1; then
    skip "system test: docker CLI not present"
  fi

  # The harness's `FROM ${TEST_TOOLS_IMAGE}` needs a real image. The tag is
  # a content hash of the tooling Dockerfile (test.sh --test-tools-image),
  # so the value resolved in here is the value the outer run resolved --
  # unless the caller pinned one that this container cannot see, which is a
  # missing prerequisite, not a failure.
  TEST_TOOLS_IMAGE="$(/source/script/test/test.sh --test-tools-image)"
  export TEST_TOOLS_IMAGE
  if ! docker image inspect "${TEST_TOOLS_IMAGE}" >/dev/null 2>&1; then
    skip "system test: tooling image ${TEST_TOOLS_IMAGE} not in the daemon (run via 'just test system')"
  fi
}

# No test_helper: this level's specs assert with plain `[ ]` on docker's
# status and output, exactly like its siblings here, and load nothing.

# _make_context <out_var>
#
# A build context carrying exactly the paths dockerfile/Dockerfile.smoke
# COPYs, copied out of the checkout. Deliberately narrow: the whole checkout
# would ship dist/config and the doc tree into every build for nothing.
#
# `cp -L` on the wrapper scripts because <repo>/script/*.sh are symlinks
# into dist/ in base's own tree, and this copy has no dist/ sibling at that
# relative depth to resolve them against.
_make_context() {
  local -n _mc_out="${1}"
  _mc_out="$(mktemp -d -t smoke-harness-XXXXXX)"
  mkdir -p "${_mc_out}/script" \
    "${_mc_out}/dist/script/docker" \
    "${_mc_out}/dist/test/bats"
  cp -L /source/script/*.sh "${_mc_out}/script/"
  cp -a /source/dist/script/docker/lib "${_mc_out}/dist/script/docker/"
  cp -a /source/dist/script/docker/wrapper "${_mc_out}/dist/script/docker/"
  cp -a /source/dist/script/docker/runtime "${_mc_out}/dist/script/docker/"
  cp -a /source/dist/test/bats/smoke "${_mc_out}/dist/test/bats/"
}

# _build_harness <context> -- build the real harness Dockerfile against
# <context>. Merges stderr into stdout and forces plain progress so a failing
# spec's bats output lands in the bats failure report instead of a collapsed
# progress line. Exits with docker's status.
_build_harness() {
  local _ctx="${1}"
  docker build \
    --progress=plain \
    --build-arg "TEST_TOOLS_IMAGE=${TEST_TOOLS_IMAGE}" \
    -f /source/dockerfile/Dockerfile.smoke \
    "${_ctx}" 2>&1
}

teardown() {
  [[ -n "${CONTEXT_DIR:-}" && -d "${CONTEXT_DIR}" ]] && rm -rf "${CONTEXT_DIR}"
}

# ────────────────────────────────────────────────────────────────────
# Positive case: the shipped specs, unmodified, pass in the harness.
# ────────────────────────────────────────────────────────────────────

@test "the smoke harness runs the shipped specs and they pass" {
  _make_context CONTEXT_DIR
  run _build_harness "${CONTEXT_DIR}"
  [ "${status}" -eq 0 ]
  # Not just "the build succeeded": bats has to have reported a plan, so a
  # harness that copied an empty /smoke_test and short-circuited cannot pass
  # this by doing nothing.
  echo "${output}" | grep -qE '1\.\.[0-9]+'
}

# ────────────────────────────────────────────────────────────────────
# Fidelity case: the specs run as a NON-ROOT user. Asserted by running
# a spec that says so, rather than by reading the Dockerfile -- the
# static half already reads the Dockerfile, and it is the runtime
# identity that decides whether a permission-sensitive spec is
# meaningful.
# ────────────────────────────────────────────────────────────────────

@test "the smoke harness runs the specs as a non-root user" {
  _make_context CONTEXT_DIR
  cat > "${CONTEXT_DIR}/dist/test/bats/smoke/devel-test/zz_identity.bats" <<'EOF'
#!/usr/bin/env bats

@test "the smoke run is not root" {
  [ "$(id -u)" -ne 0 ]
}

@test "the smoke run cannot write into /lint" {
  ! touch /lint/zz_probe
}
EOF
  run _build_harness "${CONTEXT_DIR}"
  [ "${status}" -eq 0 ]
}

# ────────────────────────────────────────────────────────────────────
# Negative case: the harness MUST fail when a spec fails. Without
# this, a future edit that swallows the bats exit status (a `|| true`,
# a CMD the build never reaches) would turn `just test smoke` into a
# report that always says green, which is strictly worse than having
# no entry point at all.
# ────────────────────────────────────────────────────────────────────

@test "the smoke harness build FAILS when a shipped spec fails (gate-fires assertion)" {
  _make_context CONTEXT_DIR
  cat > "${CONTEXT_DIR}/dist/test/bats/smoke/devel-test/zz_failing.bats" <<'EOF'
#!/usr/bin/env bats

@test "failing on purpose" {
  false
}
EOF
  run _build_harness "${CONTEXT_DIR}"
  [ "${status}" -ne 0 ]
  echo "${output}" | grep -q 'failing on purpose'
}
