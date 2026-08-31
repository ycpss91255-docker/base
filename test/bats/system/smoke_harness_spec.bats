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

# _add_fixture_spec <context> <name> <body-line>...
#
# Write a bats spec into <context>'s devel-test spec directory, so the
# harness picks it up through its normal COPY.
#
# Assembled line by line rather than from a heredoc on purpose: a heredoc
# would put `@test` at the start of a line in THIS file, and the doc/test
# count generator derives every catalogue figure from `grep -c '^@test'`.
# A fixture would then be counted as a test of this spec and appear in the
# catalogue under a name nothing here runs.
_add_fixture_spec() {
  local _ctx="${1}" _name="${2}"; shift 2
  local _dest="${_ctx}/dist/test/bats/smoke/devel-test/${_name}.bats"
  printf '%s\n' '#!/usr/bin/env bats' '' > "${_dest}"
  printf '%s\n' "$@" >> "${_dest}"
}

# _build_harness <context> -- build the real harness Dockerfile against
# <context>. Merges stderr into stdout and forces plain progress so a failing
# spec's bats output lands in the bats failure report instead of a collapsed
# progress line. Exits with docker's status.
#
# --no-cache because these cases assert on what the RUN produced, and a
# CACHED layer produces nothing: the positive case builds a context
# identical to the previous run's, so without it the second invocation
# reports success having executed no specs at all -- and the assertion that
# bats reported a plan is precisely what caught that.
# Extra arguments after the context are passed to `docker build` before the
# `-f`, so a case can tag the result or override a build arg.
_build_harness() {
  local _ctx="${1}"; shift
  docker build \
    --no-cache \
    --progress=plain \
    --build-arg "TEST_TOOLS_IMAGE=${TEST_TOOLS_IMAGE}" \
    "$@" \
    -f /source/dockerfile/Dockerfile.smoke \
    "${_ctx}" 2>&1
}

teardown() {
  [[ -n "${CONTEXT_DIR:-}" && -d "${CONTEXT_DIR}" ]] && rm -rf "${CONTEXT_DIR}"
  # A case that tagged its build sets IMAGE_TAG; the image is this file's
  # litter and nothing else reads it.
  if [[ -n "${IMAGE_TAG:-}" ]]; then
    docker rmi -f "${IMAGE_TAG}" >/dev/null 2>&1 || true
  fi
  return 0
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
  _add_fixture_spec "${CONTEXT_DIR}" zz_identity \
    '@test "the smoke run is not root" {' \
    '  [ "$(id -u)" -ne 0 ]' \
    '}' \
    '' \
    '@test "the smoke run cannot write into /lint" {' \
    '  ! touch /lint/zz_probe' \
    '}'
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
  _add_fixture_spec "${CONTEXT_DIR}" zz_failing \
    '@test "failing on purpose" {' \
    '  false' \
    '}'
  run _build_harness "${CONTEXT_DIR}"
  [ "${status}" -ne 0 ]
  echo "${output}" | grep -q 'failing on purpose'
}

# ────────────────────────────────────────────────────────────────────
# Reproducibility record: the sys stage writes the base digest into TWO
# sinks -- /usr/local/share/base/base-image.env and the OCI
# org.opencontainers.image.base.digest annotation -- and one image must
# not get two answers. base's unit spec compares the two EXPRESSIONS in
# the template text; only a build resolves them, and only from outside
# the image can the annotation be read at all. The harness mirrors the
# stage's record, so this is where that resolution happens.
# ────────────────────────────────────────────────────────────────────

# Not a real digest: nothing here pulls the reference (the harness is FROM
# the tooling image), and the shipped spec asserts the SHAPE
# `sha256:<64 hex>`, which is what a route that drops or reshapes the value
# stops producing.
PINNED_DIGEST="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

@test "a digest-pinned BASE_IMAGE lands in the manifest and the OCI annotation as one value (#951)" {
  _make_context CONTEXT_DIR
  # The file half is asserted from INSIDE the build, by a spec running in
  # the stage that wrote it -- the same place the shipped repro specs run.
  _add_fixture_spec "${CONTEXT_DIR}" zz_pinned_digest \
    '@test "the manifest records the pinned digest" {' \
    "  run grep -x 'base_image_digest=${PINNED_DIGEST}' /usr/local/share/base/base-image.env" \
    '  [ "${status}" -eq 0 ]' \
    '}'
  IMAGE_TAG="base-smoke-pinned-digest:test"
  run _build_harness "${CONTEXT_DIR}" \
    -t "${IMAGE_TAG}" \
    --build-arg "BASE_IMAGE=ubuntu@${PINNED_DIGEST}" \
    --build-arg "BASE_IMAGE_DIGEST=${PINNED_DIGEST}"
  [ "${status}" -eq 0 ]
  # The annotation half, read off the built image: no spec running inside
  # the image can see a label, which is why this sink went unchecked while
  # it disagreed with the file.
  run docker inspect \
    --format '{{index .Config.Labels "org.opencontainers.image.base.digest"}}' \
    "${IMAGE_TAG}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "${PINNED_DIGEST}" ]
}

@test "the build REFUSES a reference-carried digest the build arg does not repeat (#951)" {
  _make_context CONTEXT_DIR
  # The half-pinned call: the reference carries the digest, nothing carries
  # it into the annotation. Recording it in the file alone is what gave one
  # image two answers, so the build stops instead -- and says which arg
  # closes it.
  run _build_harness "${CONTEXT_DIR}" \
    --build-arg "BASE_IMAGE=ubuntu@${PINNED_DIGEST}"
  [ "${status}" -ne 0 ]
  echo "${output}" | grep -q 'BASE_IMAGE_DIGEST'
}
