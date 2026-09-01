#!/usr/bin/env bats
#
# The `just` runner inside the test-tools image IS the pinned version --
# the behavioural half of test/bats/unit/just_version_spec.bats.
#
# The suite runs inside the test-tools image, so `just` on this PATH is
# the image's own copy. Integration tests exercise `just base update` /
# `just docker ...` through that binary while a developer host and the CI
# e2e job run their own; when those disagree, a recipe that works on one
# path and fails on another is indistinguishable from a broken recipe.
# Measured 2026-08-28 the spread was 37 minors (alpine 1.37.0 vs
# setup-just's floating latest 1.58.0).
#
# DELIBERATELY FAIL-CLOSED. Its siblings (justfile_user_spec,
# upgrade_spec) skip when the image has no `just` at all, because that is
# a capability of a pinned older TEST_TOOLS_IMAGE rather than a defect in
# this repo. Staleness is the opposite: an image whose `just` disagrees
# with the declaration is exactly the drift this spec exists to report,
# and a skip here would restore the silence.
#
# What it cannot see: the CI e2e job's own `just`. That one is installed
# by `extractions/setup-just` from the same declaration (asserted
# statically in just_version_spec), and no test inside this container can
# observe a GitHub runner.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
}

@test "test-tools image: just --version equals the declared pin (#948)" {
  local _pin _actual
  run /source/dist/script/base/just-version.sh
  assert_success
  _pin="${output}"

  run command -v just
  assert_success

  run just --version
  assert_success
  _actual="${output}"
  [ "${_actual}" = "just ${_pin}" ] || fail \
    "the test-tools image ships '${_actual}' but dockerfile/Dockerfile.test-tools declares ARG JUST_VERSION=${_pin}. Either the image predates the pin (rebuild it -- the local tag is a content hash of that Dockerfile) or the pinned fetch is not what lands on PATH."
}
