#!/usr/bin/env bats
#
# build_worker_runtime_stages_spec.bats -- unit tests for
# script/ci/build_worker/runtime_stages.sh, the runtime-stage resolver
# behind build-worker.yaml's runtime / runtime-test build steps.
#
# The worker used to be TOLD whether a runtime stage exists (the
# `build_runtime` workflow input, default true) while the shipped
# dist/dockerfile/Dockerfile ships its builder / runtime / runtime-test
# blocks commented out. Two statements of one fact with nothing checking
# they agree, so the default shape asked buildx for a `runtime-test` target
# the default Dockerfile does not declare -- "target stage could not be
# found", on the first push of every repo created from the template.
#
# The resolver makes the Dockerfile the single source of truth: it reads
# the stages the Dockerfile actually declares and answers whether the
# runtime pair should be built. The surviving flag is an opt-OUT only, and
# a Dockerfile that declares one half of the pair fails loudly here instead
# of deep inside buildx.
#
# The two shapes that matter both have a test below: the shipped Dockerfile
# with its runtime blocks commented out (the default new-repo shape, which
# nothing covered), and the same file with them uncommented.
#
# stdout carries the answer and stderr carries the diagnostics, so every
# case runs with `--separate-stderr` and asserts against the right stream --
# build-worker.yaml reads stdout through a command substitution.
#
# why: `script/ci/build_worker/runtime_stages.sh`, the resolver that decides
# whether build-worker.yaml runs its `runtime-test` / `runtime` targets
# (#925). Whether those stages exist is a fact only the Dockerfile holds; it
# used to be stated a second time as the caller's `build_runtime` input,
# with nothing checking the two agreed -- the shipped Dockerfile ships its
# runtime blocks commented out while the input defaulted to true, so every
# repo created from the template asked buildx for a target that did not
# exist. Both shapes of the shipped file are covered here: runtime blocks
# commented out (the default new-repo shape, previously untested) and
# uncommented.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  SCRIPT="/source/script/ci/build_worker/runtime_stages.sh"
  DIST_DOCKERFILE="/source/dist/dockerfile/Dockerfile"
  TMP="$(mktemp -d)"
  [[ -f "${SCRIPT}" ]] || {
    echo "missing resolver: ${SCRIPT}"
    return 1
  }
}

teardown() {
  [[ -n "${TMP:-}" ]] && rm -rf "${TMP}"
}

# Writes a Dockerfile from stdin into the per-test tmpdir; path in ${TMP}.
_fixture() {
  cat > "${TMP}/Dockerfile"
}

# Asserts a substring appears on stderr, printing the whole stream when not.
_assert_stderr_has() {
  [[ "${stderr}" == *"${1}"* ]] || {
    echo "stderr did not contain '${1}':"
    echo "${stderr}"
    return 1
  }
}

# ── Detection ──────────────────────────────────────────────────

# why: The four-stage default shape skips the runtime build steps
@test "runtime_stages: a Dockerfile with no runtime stages resolves to false" {
  _fixture <<'EOF'
FROM alpine:3 AS sys
FROM sys AS devel-base
FROM devel-base AS devel
FROM devel AS devel-test
EOF
  DOCKERFILE="${TMP}/Dockerfile" run --separate-stderr bash "${SCRIPT}"
  assert_success
  assert_output "false"
}

# why: A declared pair enables the runtime build with no second edit
@test "runtime_stages: a Dockerfile declaring runtime + runtime-test resolves to true" {
  _fixture <<'EOF'
FROM alpine:3 AS sys
FROM sys AS devel
FROM devel AS devel-test
FROM sys AS runtime
FROM runtime AS runtime-test
EOF
  DOCKERFILE="${TMP}/Dockerfile" run --separate-stderr bash "${SCRIPT}"
  assert_success
  assert_output "true"
}

# why: A `#`-prefixed `FROM ... AS runtime` is documentation, not a stage
@test "runtime_stages: commented-out runtime stages do not count as declared" {
  _fixture <<'EOF'
FROM alpine:3 AS sys
FROM sys AS devel
FROM devel AS devel-test
# FROM sys AS runtime
#   FROM runtime AS runtime-test
EOF
  DOCKERFILE="${TMP}/Dockerfile" run --separate-stderr bash "${SCRIPT}"
  assert_success
  assert_output "false"
}

# why: `from ... as runtime-test` is the same declaration to buildx
@test "runtime_stages: stage detection is case-insensitive (Dockerfile keywords are)" {
  _fixture <<'EOF'
from alpine:3 as sys
from sys as devel
from devel as devel-test
from sys as runtime
from runtime as runtime-test
EOF
  DOCKERFILE="${TMP}/Dockerfile" run --separate-stderr bash "${SCRIPT}"
  assert_success
  assert_output "true"
}

# ── The two shapes the shipped Dockerfile can be in ────────────

# why: The real default artifact, the shape that shipped red
@test "runtime_stages: the shipped dist Dockerfile (runtime blocks commented out) resolves to false" {
  # The default new-repo shape. Before the resolver, this shape still asked
  # buildx for `target: runtime-test`, so a repo created from the template
  # was born with a permanently red build job.
  [[ -f "${DIST_DOCKERFILE}" ]] || {
    echo "missing ${DIST_DOCKERFILE}"
    return 1
  }
  DOCKERFILE="${DIST_DOCKERFILE}" run --separate-stderr bash "${SCRIPT}"
  assert_success
  assert_output "false"
}

# why: Uncommenting is sufficient to get a runtime build
@test "runtime_stages: the shipped dist Dockerfile with its runtime blocks uncommented resolves to true" {
  # Enabling the runtime split is exactly "uncomment the blocks", and the
  # resolver reads only the `FROM ... AS <stage>` headers, so uncommenting
  # those headers is the property under test: no second edit anywhere else.
  [[ -f "${DIST_DOCKERFILE}" ]] || {
    echo "missing ${DIST_DOCKERFILE}"
    return 1
  }
  sed -E 's/^#[[:space:]]?(FROM[[:space:]])/\1/' \
    "${DIST_DOCKERFILE}" > "${TMP}/Dockerfile"
  DOCKERFILE="${TMP}/Dockerfile" run --separate-stderr bash "${SCRIPT}"
  assert_success
  assert_output "true"
}

# ── The flag is an opt-out, never a claim about existence ──────

# why: The surviving flag is an opt-out and is honoured
@test "runtime_stages: build_runtime=false opts out even when both stages exist" {
  _fixture <<'EOF'
FROM alpine:3 AS sys
FROM sys AS runtime
FROM runtime AS runtime-test
EOF
  DOCKERFILE="${TMP}/Dockerfile" BUILD_RUNTIME=false \
    run --separate-stderr bash "${SCRIPT}"
  assert_success
  assert_output "false"
}

# why: The Dockerfile wins the disagreement that used to fail the build
@test "runtime_stages: build_runtime=true with no runtime stage resolves to false, not a buildx failure" {
  # The disagreement that shipped: the caller says true, the Dockerfile
  # says nothing. The Dockerfile wins and the runtime build steps skip.
  _fixture <<'EOF'
FROM alpine:3 AS sys
FROM sys AS devel
EOF
  DOCKERFILE="${TMP}/Dockerfile" BUILD_RUNTIME=true \
    run --separate-stderr bash "${SCRIPT}"
  assert_success
  assert_output "false"
  _assert_stderr_has "runtime-test"
}

# why: Anything other than true / false is a config error, not a default
@test "runtime_stages: an unparseable build_runtime value fails loudly" {
  _fixture <<'EOF'
FROM alpine:3 AS sys
EOF
  DOCKERFILE="${TMP}/Dockerfile" BUILD_RUNTIME=yes \
    run --separate-stderr bash "${SCRIPT}"
  assert_failure
  _assert_stderr_has "yes"
}

# ── Half a pair is drift, and says so ──────────────────────────

# why: Half a pair silently loses the install-check, so it fails here
@test "runtime_stages: runtime without runtime-test fails naming both stages and the Dockerfile" {
  _fixture <<'EOF'
FROM alpine:3 AS sys
FROM sys AS runtime
EOF
  DOCKERFILE="${TMP}/Dockerfile" run --separate-stderr bash "${SCRIPT}"
  assert_failure
  _assert_stderr_has "runtime-test"
  _assert_stderr_has "${TMP}/Dockerfile"
}

# why: The mirror case, which cannot build at all
@test "runtime_stages: runtime-test without runtime fails naming both stages and the Dockerfile" {
  _fixture <<'EOF'
FROM alpine:3 AS sys
FROM sys AS runtime-test
EOF
  DOCKERFILE="${TMP}/Dockerfile" run --separate-stderr bash "${SCRIPT}"
  assert_failure
  _assert_stderr_has "runtime"
  _assert_stderr_has "${TMP}/Dockerfile"
}

# why: A wrong `context_path` / `dockerfile_path` is reported by path
@test "runtime_stages: a missing Dockerfile fails naming the path it looked for" {
  DOCKERFILE="${TMP}/nope/Dockerfile" run --separate-stderr bash "${SCRIPT}"
  assert_failure
  _assert_stderr_has "${TMP}/nope/Dockerfile"
}

# why: No path means no source of truth to read
@test "runtime_stages: an empty DOCKERFILE path fails loudly" {
  DOCKERFILE="" run --separate-stderr bash "${SCRIPT}"
  assert_failure
  _assert_stderr_has "DOCKERFILE"
}
