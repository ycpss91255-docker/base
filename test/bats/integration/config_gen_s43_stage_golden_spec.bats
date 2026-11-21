#!/usr/bin/env bats
#
# config_gen_s43_stage_golden_spec.bats -- the s43 stage-list corpus against
# the `.stages` goldens (base#2093, S43a-1 of base#2054).
#
# why: Before any Go parser exists, the shell `_parse_dockerfile_stages`
# (dist/script/docker/lib/stage.sh) is the oracle for the stage list. Every
# dockerfile/config-gen/testdata/corpus/s43/s43_stage_<case>.Dockerfile has
# one golden testdata/golden/s43/s43_stage_<case>.stages holding that
# function's stdout (one stage per line, trailing newline; empty output is a
# 0-byte file). The Go side must later match these byte for byte. The spec
# regenerates the list from the shell and compares it with the golden, and a
# partition check keeps fixtures and goldens one-to-one.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  # shellcheck disable=SC1091
  source /source/dist/script/docker/wrapper/setup.sh
  TESTDATA="/source/dockerfile/config-gen/testdata"
  CORPUS="${TESTDATA}/corpus/s43"
  GOLDEN="${TESTDATA}/golden/s43"
}

# _check_case <case> -- regenerate the stage list of s43_stage_<case>.Dockerfile
# from the shell and compare it byte for byte with the .stages golden.
_check_case() {
  local _name="s43_stage_${1}"
  [[ -f "${CORPUS}/${_name}.Dockerfile" ]] || {
    echo "fixture missing: ${_name}.Dockerfile" >&2
    return 1
  }
  [[ -f "${GOLDEN}/${_name}.stages" ]] || {
    echo "golden missing: ${_name}.stages" >&2
    return 1
  }
  _parse_dockerfile_stages "${CORPUS}/${_name}.Dockerfile" > "${BATS_TEST_TMPDIR}/${_name}.out"
  cmp -- "${BATS_TEST_TMPDIR}/${_name}.out" "${GOLDEN}/${_name}.stages"
}

# ── one test per case ───────────────────────────────────────────────────────

@test "s43 stage golden: legacy_baseline lists no stage" {
  run _check_case legacy_baseline
  assert_success
}

@test "s43 stage golden: new_baseline lists no stage" {
  run _check_case new_baseline
  assert_success
}

@test "s43 stage golden: devel_test lists devel-test" {
  run _check_case devel_test
  assert_success
}

@test "s43 stage golden: extract lists headless then gui" {
  run _check_case extract
  assert_success
}

@test "s43 stage golden: order keeps file order" {
  run _check_case order
  assert_success
}

@test "s43 stage golden: dedup lists a repeated stage once" {
  run _check_case dedup
  assert_success
}

@test "s43 stage golden: lower_comment skips a commented FROM" {
  run _check_case lower_comment
  assert_success
}

# ── literal expectations, independent of the goldens ────────────────────────

# why: the issue's table gives the expected stage lists; pin two of them as
# literals so a wrong golden cannot pass by being regenerated the same way.
@test "s43 stage golden: order golden is gamma, alpha, beta" {
  run cat "${GOLDEN}/s43_stage_order.stages"
  assert_success
  assert_output $'gamma\nalpha\nbeta'
}

@test "s43 stage golden: baseline goldens are 0-byte files" {
  [[ -f "${GOLDEN}/s43_stage_legacy_baseline.stages" ]]
  [[ ! -s "${GOLDEN}/s43_stage_legacy_baseline.stages" ]]
  [[ -f "${GOLDEN}/s43_stage_new_baseline.stages" ]]
  [[ ! -s "${GOLDEN}/s43_stage_new_baseline.stages" ]]
}

# why: a missing Dockerfile is not an error, so the Go side needs the same
# empty output and rc 0.
@test "s43 stage golden: a missing Dockerfile gives empty output and rc 0" {
  run _parse_dockerfile_stages "${BATS_TEST_TMPDIR}/no_such.Dockerfile"
  assert_success
  assert_output ""
}

# ── the partition check ─────────────────────────────────────────────────────

# why: a fixture with no golden, or a golden with no fixture, must fail the
# spec so the corpus cannot drift from its goldens.
@test "s43 stage golden: every fixture has exactly one golden and no extra" {
  local _f _stem _bad=0
  for _f in "${CORPUS}"/s43_stage_*.Dockerfile; do
    [[ -e "${_f}" ]] || continue
    _stem="$(basename -- "${_f}" .Dockerfile)"
    if [[ ! -f "${GOLDEN}/${_stem}.stages" ]]; then
      echo "fixture with no golden: ${_stem}" >&2
      _bad=1
    fi
  done
  for _f in "${GOLDEN}"/s43_stage_*.stages; do
    [[ -e "${_f}" ]] || continue
    _stem="$(basename -- "${_f}" .stages)"
    if [[ ! -f "${CORPUS}/${_stem}.Dockerfile" ]]; then
      echo "golden with no fixture: ${_stem}" >&2
      _bad=1
    fi
  done
  [[ -d "${CORPUS}" ]] || _bad=1
  (( _bad == 0 ))
}
