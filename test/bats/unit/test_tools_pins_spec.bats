#!/usr/bin/env bats
#
# test_tools_pins_spec.bats -- the ROSTER of version pins the tooling
# image is built from, derived from the Dockerfile that declares them.
#
# ── What went unasserted, and for how long ──────────────────────────────
#
# release-test-tools.yaml's smoke step ran fifteen probes against the
# image it had just published. Fourteen of them asserted an exit status
# and nothing else, which catches a tool's REMOVAL and never its
# staleness -- the comment the `just` repair left in that step says so in
# as many words, having been written after the image sat 37 minors behind
# the runner every other path installed, green throughout.
#
# Three tools besides `just` are pinned by an ARG in
# dockerfile/Dockerfile.test-tools -- BATS_VERSION, KCOV_VERSION,
# ALPINE_VERSION -- and none of the three was compared to anything. The
# last was not probed at all. A silently downlevel `bats` is the worst of
# them: bats is the harness the whole repo is tested with, so a stale one
# quietly changes what every other spec means.
#
# ── Why a roster and not four more probes ───────────────────────────────
#
# Adding three comparisons would have left the same defect one ARG away:
# the next pinned tool arrives with no probe and nothing notices, exactly
# as these three did. So the POPULATION is computed from the Dockerfile --
# every `ARG <NAME>_VERSION=<value>` it declares -- and the accessor
# REFUSES to answer at all when a declared pin has no probe. A tool
# cannot be pinned in that file and go unasserted, because the roster its
# consumers iterate cannot be produced while one is missing.
#
# What stays a fixed table is the vocabulary: HOW to ask a given tool its
# version. That is the detector, not the population -- the same split
# script/test/drivers/just_provenance.sh draws between its marker table
# and the tree it scans.
#
# The behavioural half (the image really ships those versions) is
# test/bats/integration/test_tools_pins_spec.bats; the published-image
# half is the smoke step of release-test-tools.yaml, which iterates this
# same roster.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  ACCESSOR=/source/script/ci/test-tools-pins.sh
  DOCKERFILE=/source/dockerfile/Dockerfile.test-tools
  assert_spec_subject "${ACCESSOR}" "the tooling-image pin roster accessor"
  assert_spec_subject "${DOCKERFILE}" "the declaration the roster is read from"
  SCRATCH="$(mktemp -d)"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _declared_args -- every `ARG <NAME>_VERSION=` name in the Dockerfile,
# read with an expression that is NOT the accessor's, so "the roster
# covers the declarations" is a real comparison rather than the accessor
# agreeing with itself.
#
# Independent in MECHANISM, not merely in spelling: a second regex with the
# accessor's anchor agrees with it by construction, and a shape neither can
# see is invisible to the differential rather than reported by it -- which
# is how an indented or lower-case declaration stayed unnoticed while both
# sides were green. This one tokenises the line instead: strip the
# indentation, accept the keyword case-insensitively as the Dockerfile
# format defines it, and split the operand at its first `=`.
_declared_args() {
  awk '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (tolower(line) !~ /^arg[[:space:]]/) { next }
      rest = substr(line, 4)
      sub(/^[[:space:]]+/, "", rest)
      eq = index(rest, "=")
      if (eq < 2) { next }
      name = substr(rest, 1, eq - 1)
      if (name !~ /^[A-Za-z0-9_]+$/) { next }
      if (tolower(name) !~ /_version$/) { next }
      print name
    }
  ' "${DOCKERFILE}" | sort
}

# _roster_args -- the ARG column of the roster, sorted.
_roster_args() {
  bash "${ACCESSOR}" roster | cut -f1 | sort
}

# _seed_tree <dockerfile-body> -- a minimal base tree at ${SCRATCH}/tree
# holding the accessor at its shipped path plus a declaration to read.
# The accessor derives its root from its OWN location, so a copy in a
# fabricated tree reads that tree's Dockerfile.
_seed_tree() {
  local _root="${SCRATCH}/tree"
  rm -rf "${_root}"
  mkdir -p "${_root}/script/ci" "${_root}/dockerfile"
  cp "${ACCESSOR}" "${_root}/script/ci/test-tools-pins.sh"
  printf '%s\n' "${1}" > "${_root}/dockerfile/Dockerfile.test-tools"
  printf '%s\n' "${_root}"
}

# ── The roster covers the declarations, exactly ──────────────────────

@test "test-tools pins: the roster names every ARG *_VERSION the Dockerfile declares (#1012)" {
  local _declared _roster
  _declared="$(_declared_args)"
  [[ -n "${_declared}" ]] || fail \
    "the Dockerfile declares no ARG *_VERSION at all -- the pins were renamed and every assertion here is vacuous."
  _roster="$(_roster_args)"
  [[ "${_roster}" == "${_declared}" ]] || fail \
    "the roster is
${_roster}
but the Dockerfile declares
${_declared}"
}

@test "test-tools pins: every roster row carries a pin and a probe (#1012)" {
  local _rows=0 _arg _pin _probe
  while IFS=$'\t' read -r _arg _pin _probe; do
    _rows=$(( _rows + 1 ))
    [[ -n "${_pin}" ]] || fail "${_arg}: the roster row carries no pinned version"
    [[ -n "${_probe}" ]] || fail "${_arg}: the roster row carries no probe command"
  done < <(bash "${ACCESSOR}" roster)
  [[ "${_rows}" -ge 4 ]] || fail \
    "the roster has ${_rows} row(s); the tooling image pins bats, alpine, kcov and just, so a shorter roster means the reader stopped matching."
}

@test "test-tools pins: a declared pin with no probe is refused, naming it (#1012)" {
  # The whole point: a tool cannot be pinned in that Dockerfile and go
  # unasserted, because the roster its consumers iterate cannot be
  # produced while one of them has no way to be asked.
  local _root
  _root="$(_seed_tree 'ARG BATS_VERSION=1.13.0
ARG ALPINE_VERSION=3.21
ARG KCOV_VERSION=v43
ARG JUST_VERSION=1.58.0
ARG CURL_VERSION=8.9.0')"
  run bash "${_root}/script/ci/test-tools-pins.sh" roster
  assert_failure
  assert_output --partial 'CURL_VERSION'
}

@test "test-tools pins: a pin the Dockerfile spells differently is on the roster, not dropped (#1012)" {
  # The refusal above is the whole claim -- "a tool cannot be pinned in
  # that Dockerfile and go unasserted" -- and it is only as wide as the
  # reader that finds the pins. A Dockerfile instruction may be indented
  # and its keyword is case-insensitive, and an ARG name is an ordinary
  # identifier, so all three lines below are legal declarations of a pin
  # with no probe. A reader anchored on `^ARG` and `[A-Z0-9_]` matches
  # none of them, and the roster then answers SUCCESSFULLY with the four
  # pins it did match: the guard does not refuse, it just gets shorter,
  # which is the fail-open direction for a guard whose whole assertion is
  # that something was checked.
  local _spelling _root
  for _spelling in '  ARG CURL_VERSION=8.9.0' \
      'arg CURL_VERSION=8.9.0' \
      'ARG curl_VERSION=8.9.0'; do
    _root="$(_seed_tree "ARG BATS_VERSION=1.13.0
ARG ALPINE_VERSION=3.21
ARG KCOV_VERSION=v43
ARG JUST_VERSION=1.58.0
${_spelling}")"
    run bash "${_root}/script/ci/test-tools-pins.sh" roster
    [[ "${status}" -ne 0 ]] || fail \
      "'${_spelling}' declares a pin with no probe, but the roster answered instead of refusing:
${output}"
  done
}

@test "test-tools pins: a Dockerfile declaring no pin at all is refused, not answered empty (#1012)" {
  # An empty roster satisfies every "iterate the roster" consumer in
  # silence, which is the fail-open direction for a guard whose whole
  # assertion is that something was checked.
  local _root
  _root="$(_seed_tree 'FROM alpine:3.21')"
  run bash "${_root}/script/ci/test-tools-pins.sh" roster
  assert_failure
}

# ── check: does an observed version carry the pin ────────────────────

@test "test-tools pins: check accepts the exact declared version (#1012)" {
  run bash "${ACCESSOR}" check BATS_VERSION 'Bats 1.13.0'
  assert_success
  run bash "${ACCESSOR}" check JUST_VERSION 'just 1.58.0'
  assert_success
  run bash "${ACCESSOR}" check KCOV_VERSION 'kcov v43'
  assert_success
}

@test "test-tools pins: check accepts a longer version under a series pin (#1012)" {
  # ALPINE_VERSION pins a SERIES (3.21); /etc/alpine-release answers
  # 3.21.7. A rule that demanded equality would fail every alpine image
  # this Dockerfile can produce.
  run bash "${ACCESSOR}" check ALPINE_VERSION '3.21.7'
  assert_success
}

@test "test-tools pins: check refuses a downlevel version (#1012)" {
  run bash "${ACCESSOR}" check BATS_VERSION 'Bats 1.12.0'
  assert_failure
  run bash "${ACCESSOR}" check ALPINE_VERSION '3.20.6'
  assert_failure
}

@test "test-tools pins: check refuses a version the pin is merely a digit prefix of (#1012)" {
  # `v43` must not be satisfied by `v431`, and `1.13.0` must not be
  # satisfied by `1.13.01`. Both are the failure a substring test makes.
  run bash "${ACCESSOR}" check KCOV_VERSION 'kcov v431'
  assert_failure
  run bash "${ACCESSOR}" check BATS_VERSION 'Bats 1.13.01'
  assert_failure
}

@test "test-tools pins: check refuses empty observed output (#1012)" {
  # A probe whose command was not found prints nothing and the caller
  # must not read that as agreement.
  run bash "${ACCESSOR}" check BATS_VERSION ''
  assert_failure
}

@test "test-tools pins: check refuses an ARG that is not on the roster (#1012)" {
  run bash "${ACCESSOR}" check CURL_VERSION 'curl 8.9.0'
  assert_failure
  assert_output --partial 'CURL_VERSION'
}

@test "test-tools pins: an unrecognised subcommand is refused and names what it does answer (#1012)" {
  run bash "${ACCESSOR}" versions
  assert_failure
  assert_output --partial 'roster'
}

@test "test-tools pins: roster and check read a quoted declaration the same way (#1012)" {
  # `ARG BATS_VERSION="1.13.0"` is a legal declaration, and the two halves
  # of one accessor have to agree about what it says. `roster` strips the
  # surrounding quotes and `check` did not, so the release smoke step --
  # which asks `roster` what is pinned and then asks `check` whether the
  # image carries it -- would refuse a CORRECT image, naming a pin nobody
  # could satisfy. Both quote spellings, because both are stripped on the
  # roster side.
  local _root _acc _pin
  _root="$(_seed_tree 'ARG BATS_VERSION="1.13.0"
ARG ALPINE_VERSION='"'"'3.21'"'"'
ARG KCOV_VERSION=v43
ARG JUST_VERSION=1.58.0')"
  _acc="${_root}/script/ci/test-tools-pins.sh"

  _pin="$(bash "${_acc}" roster | awk -F'\t' '$1 == "BATS_VERSION" { print $2 }')"
  [[ "${_pin}" == '1.13.0' ]] || fail \
    "the roster reports BATS_VERSION as '${_pin}', so the quoted declaration is not being read at all."

  run bash "${_acc}" check BATS_VERSION 'Bats 1.13.0'
  assert_success
  run bash "${_acc}" check ALPINE_VERSION '3.21.7'
  assert_success
}
