#!/usr/bin/env bats
#
# The tooling image really ships the versions its Dockerfile pins -- the
# behavioural half of test/bats/unit/test_tools_pins_spec.bats.
#
# The suite runs INSIDE the test-tools image, so every tool on this PATH
# is the image's own copy: the probe the roster names can simply be run.
# That is the same trick test/bats/integration/just_runner_version_spec
# plays for `just` alone; this spec asks the question for the whole
# roster, and gains each new pin the day it is declared rather than the
# day somebody remembers to add a case.
#
# DELIBERATELY FAIL-CLOSED, for the reason its `just` sibling states: an
# image whose tool disagrees with the declaration is exactly the drift
# this exists to report, and a skip would restore the silence. The one
# thing it cannot see is a tool the image does not carry at all under a
# pinned older TEST_TOOLS_IMAGE -- and that is reported too, because a
# probe that cannot run is not evidence that the version is right.
#
# why: The image really ships the versions its Dockerfile pins -- the
# behavioural half of `test/bats/unit/test_tools_pins_spec.bats`. The suite
# runs INSIDE the test-tools image, so every tool on `PATH` is the image's
# own copy and the probe the roster names can simply be run. Fail-closed,
# for the reason its `just` sibling states: an image whose tool disagrees
# with the declaration is exactly the drift this exists to report, and a
# skip would restore the silence. A probe that cannot run at all is reported
# too -- it is not evidence that the version is right.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  ACCESSOR=/source/script/ci/test-tools-pins.sh
  assert_spec_subject "${ACCESSOR}" "the tooling-image pin roster accessor"
}

# why: It iterates the roster rather than a list of tools, so a pin declared
# tomorrow is asserted tomorrow -- and a probe that cannot run at all is
# reported rather than read as agreement.
@test "test-tools image: every pinned tool answers with the declared version (#1012)" {
  local _roster _arg _pin _probe _observed _checked=0
  _roster="$(bash "${ACCESSOR}" roster)"
  [[ -n "${_roster}" ]] || fail \
    "the roster came back empty -- nothing was checked, which is the direction this spec exists to refuse."
  while IFS=$'\t' read -r _arg _pin _probe; do
    _checked=$(( _checked + 1 ))
    _observed="$(sh -c "${_probe}" 2>&1)" || fail \
      "${_arg}: the probe '${_probe}' did not run in this image (output: ${_observed}). A probe that cannot run is not evidence that the version is right."
    bash "${ACCESSOR}" check "${_arg}" "${_observed}" || fail \
      "${_arg}: this image answers '${_observed}', but dockerfile/Dockerfile.test-tools declares ARG ${_arg}=${_pin}. Either the image predates the pin (rebuild it -- the local tag is a content hash of that Dockerfile) or what lands on PATH is not what the pinned build produced."
  done <<< "${_roster}"
  [[ "${_checked}" -ge 4 ]] || fail \
    "only ${_checked} pin(s) were checked; the tooling image pins bats, alpine, kcov and just."
}
