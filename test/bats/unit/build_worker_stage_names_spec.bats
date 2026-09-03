#!/usr/bin/env bats
#
# build_worker_stage_names_spec.bats -- unit tests for
# script/ci/build_worker/stage_names.sh, the reusable build worker's ONE
# reader of "which build stages does this Dockerfile declare".
#
# Two worker steps need that answer: the extra_stages loop (is there a
# <stage>-test companion to build?) and runtime_stages.sh (are runtime and
# runtime-test declared?). Each used to carry a regex of its own, and each
# carried a comment claiming it was the same regex the compose emitter's
# stage parser uses. Neither was. The loop matched ONE token between FROM
# and AS, so the cross-build `FROM --platform=... AS x-test` form declared
# nothing to it and a stage's smoke test was silently not built; the
# resolver's was looser than the emitter's in the other direction.
#
# This script ends that by CALLING the shared matcher
# (dist/script/docker/lib/stage.sh's _dockerfile_stage_from_line) rather
# than restating it, so there is one grammar with one owner. The agreement
# is asserted where it belongs -- stage_spec.bats runs every call site,
# this one included, over one corpus of FROM lines and demands a single
# verdict. What is left here is this script's OWN contract: which stages it
# emits, in what order, and what it does when it cannot read the file.
#
# The roster is deliberately UNFILTERED, unlike _parse_dockerfile_stages'
# projection: the worker asks about runtime / runtime-test / devel-test by
# name, which is exactly the set the compose emitter drops.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  SCRIPT="/source/script/ci/build_worker/stage_names.sh"
  assert_spec_subject "${SCRIPT}" \
      "the build worker's Dockerfile stage-roster reader"
  TMP="$(mktemp -d)"
}

teardown() {
  [[ -n "${TMP:-}" ]] && rm -rf "${TMP}"
}

# Writes a Dockerfile from stdin into the per-test tmpdir; path in ${TMP}.
_fixture() {
  cat > "${TMP}/Dockerfile"
}

# ── The roster ─────────────────────────────────────────────────

@test "stage_names: lists every declared stage in file order" {
  _fixture <<'EOF'
FROM alpine:3 AS sys
RUN echo not-a-stage
FROM sys AS devel-base
FROM devel-base AS devel
EOF
  DOCKERFILE="${TMP}/Dockerfile" run --separate-stderr bash "${SCRIPT}"
  assert_success
  assert_output "sys
devel-base
devel"
}

@test "stage_names: keeps the stages the compose parser filters out" {
  # _parse_dockerfile_stages drops the baseline set on its way to compose
  # services. The worker asks about those very names, so this reader must
  # not inherit that projection -- a filtered roster would answer "no
  # runtime-test stage" about a Dockerfile that declares one.
  _fixture <<'EOF'
FROM alpine:3 AS sys
FROM sys AS devel-base
FROM devel-base AS devel
FROM devel AS devel-test
FROM sys AS runtime
FROM runtime AS runtime-test
EOF
  DOCKERFILE="${TMP}/Dockerfile" run --separate-stderr bash "${SCRIPT}"
  assert_success
  assert_output --partial "runtime-test"
  assert_output --partial "devel-test"
  assert_output --partial "sys"
}

@test "stage_names: a Dockerfile declaring no stages is an empty roster, not an error" {
  # "No extra stages" is a legitimate answer and the caller decides what it
  # means; only an unreadable file is a failure.
  _fixture <<'EOF'
FROM alpine:3
RUN echo hi
EOF
  DOCKERFILE="${TMP}/Dockerfile" run --separate-stderr bash "${SCRIPT}"
  assert_success
  assert_output ""
}

# ── What it refuses to guess ───────────────────────────────────

@test "stage_names: a missing Dockerfile fails naming the path it looked for" {
  # An unreadable Dockerfile is not "no stages", it is "we do not know",
  # and answering an empty roster there is how a worker skips a build and
  # calls it a pass.
  DOCKERFILE="${TMP}/absent/Dockerfile" run --separate-stderr bash "${SCRIPT}"
  assert_failure
  [[ "${stderr}" == *"${TMP}/absent/Dockerfile"* ]] || {
    echo "stderr did not name the path: ${stderr}"
    return 1
  }
}

@test "stage_names: an empty DOCKERFILE path fails loudly" {
  DOCKERFILE= run --separate-stderr bash "${SCRIPT}"
  assert_failure
  [[ "${stderr}" == *"DOCKERFILE"* ]] || {
    echo "stderr did not name the variable: ${stderr}"
    return 1
  }
}
