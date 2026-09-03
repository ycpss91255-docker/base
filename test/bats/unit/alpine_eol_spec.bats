#!/usr/bin/env bats
#
# alpine_eol_spec.bats -- the alpine series this image is built on carries
# its own expiry date, and that date is a gate rather than a note.
#
# The defect this closes is not "the pin was old". It is that the pin
# CANNOT be old in any way a build can see. `ARG ALPINE_VERSION=3.21` is a
# series tag: it keeps resolving after 2026-11-01, the image keeps building,
# and the ~20 unpinned apk packages the final stage installs simply stop
# receiving security updates. Nothing turns red. The content-hash tag
# test.sh derives from the Dockerfile's BYTES completes the silence --
# unchanged bytes produce the same tag whatever upstream resolves to, so not
# even the tag churns. The 3.21 expiry was found by a hand audit, nine weeks
# before the date, and a hand audit is not a schedule.
#
# So the date is written next to the pin as a machine-readable marker
#
#     # alpine-eol: <series> <YYYY-MM-DD>
#     ARG ALPINE_VERSION=<series>
#
# and this spec is what makes writing it worth anything. It fails the build
# LEAD_DAYS before the recorded date, which converts the next expiry from an
# audit finding into a red suite with two quarters of head-room -- long
# enough that the bump is scheduled work rather than an incident.
#
# On the deliberate time dependence: yes, this spec goes red on a calendar
# date with no commit behind it. That IS the feature -- an alarm that only
# rings when someone re-reads it is the same defect one level up -- a thing
# that names a version while nobody re-reads it. The alarm is
# silenced by doing the work: bump the series, bump the date, and the marker
# and the pin must move together or the agreement test below fails.
#
# LEAD_DAYS is 180. Alpine cuts a series roughly every six months and
# supports each for two years, so the NEWEST supported series clears 180
# days by a wide margin and the alarm lands about two releases before the
# series it names actually dies -- early enough to choose a successor, late
# enough not to be noise.
#
# The pin does not have to be the newest supported series, though, and
# right now it is not: 3.22 was chosen for the bash it ships, because every
# newer series ships a bash whose xtrace this repo's coverage instrument
# misreads, and it clears the window by weeks rather than by a year. So
# this alarm is not measuring slack here -- it is dating the work that lets
# the pin move at all. Read the comment beside the pin before treating a
# red from this file as a routine bump.
#
# Every rule is DERIVED from the file rather than restated from it: no test
# below names 3.22 or 2027-05-01, so a future bump changes the Dockerfile
# and nothing here.
#
# The four tests over the real Dockerfile assert the invariant. The five
# over synthetic fixtures assert the READER -- that a missing marker, a
# marker that disagrees with the pin, an expired date and a malformed date
# are each caught rather than waved through. A guard whose failure path has
# never executed is a guard nobody has tested.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  DOCKERFILE=/source/dockerfile/Dockerfile.test-tools
  assert_spec_subject "${DOCKERFILE}" \
    "the test-tools Dockerfile whose alpine series pin this spec dates"

  # How long before the recorded end-of-life the suite starts failing.
  LEAD_DAYS=180
}

# _pinned_series <file>
#   The value of `ARG ALPINE_VERSION=`. Prints nothing and fails when the
#   ARG is absent or declared more than once -- either state means the
#   marker below has no single pin to agree with, which is a defect, not a
#   reason to pass.
_pinned_series() {
  local _file="${1:?BUG: _pinned_series expects a file}"
  local -a _hits=()
  local _line
  while IFS= read -r _line; do
    _hits+=("${_line#ARG ALPINE_VERSION=}")
  done < <(grep -E '^ARG ALPINE_VERSION=' "${_file}")
  [[ "${#_hits[@]}" -eq 1 ]] || return 1
  printf '%s\n' "${_hits[0]}"
}

# _marker_field <file> <n>
#   Field <n> (1 = series, 2 = date) of the single `# alpine-eol:` marker.
#   Fails when the marker is missing or duplicated: two markers disagreeing
#   with each other is exactly the state a reader must not silently pick a
#   side in.
_marker_field() {
  local _file="${1:?BUG: _marker_field expects a file}"
  local _n="${2:?BUG: _marker_field expects a field number}"
  local -a _hits=()
  local _line
  while IFS= read -r _line; do
    _hits+=("${_line}")
  done < <(grep -E '^#[[:space:]]*alpine-eol:' "${_file}")
  [[ "${#_hits[@]}" -eq 1 ]] || return 1
  local _rest="${_hits[0]#*alpine-eol:}"
  # shellcheck disable=SC2086 # deliberate word-split of the marker payload
  set -- ${_rest}
  [[ "$#" -eq 2 ]] || return 1
  printf '%s\n' "${!_n}"
}

# _days_until <YYYY-MM-DD>
#   Whole days from today (UTC) to the given date; negative once it is past.
#   A date `date` cannot parse is a FAILURE, never a large number: an
#   unparseable expiry that read as "far away" would disarm the alarm by
#   typo. The strict shape check comes first because GNU date happily reads
#   "2028-6" as a date.
_days_until() {
  local _date="${1:?BUG: _days_until expects a date}"
  [[ "${_date}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  local _then _now
  _then="$(date -u -d "${_date}" +%s 2>/dev/null)" || return 1
  _now="$(date -u +%s)"
  printf '%s\n' "$(( ( _then - _now ) / 86400 ))"
}

# _fixture <marker-line> <arg-line>
#   A two-line stand-in for the Dockerfile, for the reader tests.
_fixture() {
  local _path="${BATS_TEST_TMPDIR}/Dockerfile.fixture"
  printf '%s\n%s\n' "${1}" "${2}" > "${_path}"
  printf '%s\n' "${_path}"
}

# ── The invariant, over the real Dockerfile ─────────────────────────────────

@test "alpine eol: the test-tools Dockerfile records its series' end-of-life (#946)" {
  run _marker_field "${DOCKERFILE}" 2
  assert_success
  assert_output --regexp '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
}

@test "alpine eol: the recorded series is the series actually pinned (#946)" {
  local _pinned _recorded
  _pinned="$(_pinned_series "${DOCKERFILE}")"
  _recorded="$(_marker_field "${DOCKERFILE}" 1)"
  [[ "${_recorded}" == "${_pinned}" ]] || fail \
    "the alpine-eol marker names ${_recorded} but ARG ALPINE_VERSION pins ${_pinned}. A date attached to the wrong series is worse than no date: the alarm would ring for a series this image is not built on. Bump the marker and the pin together."
}

@test "alpine eol: the recorded date is parseable, not merely present (#946)" {
  local _recorded
  _recorded="$(_marker_field "${DOCKERFILE}" 2)"
  run _days_until "${_recorded}"
  assert_success
}

@test "alpine eol: the pinned series is more than the lead time from expiry (#946)" {
  local _series _recorded _left
  _series="$(_marker_field "${DOCKERFILE}" 1)"
  _recorded="$(_marker_field "${DOCKERFILE}" 2)"
  _left="$(_days_until "${_recorded}")"
  [[ "${_left}" -gt "${LEAD_DAYS}" ]] || fail \
    "alpine ${_series} reaches end-of-life on ${_recorded}, ${_left} days away, inside the ${LEAD_DAYS}-day lead window. This is the scheduled alarm, not a broken test: pick the current supported series, bump ARG ALPINE_VERSION and the alpine-eol marker together, rebuild the test-tools image and re-run the suite. Series and dates: https://endoflife.date/alpine"
}

# ── The reader, over synthetic fixtures ─────────────────────────────────────

@test "alpine eol reader: a Dockerfile with NO marker fails, it does not pass (#946)" {
  local _f
  _f="$(_fixture '# nothing to see here' 'ARG ALPINE_VERSION=3.24')"
  run _marker_field "${_f}" 2
  assert_failure
}

@test "alpine eol reader: TWO disagreeing markers fail rather than a side being picked (#946)" {
  local _f="${BATS_TEST_TMPDIR}/two.fixture"
  printf '# alpine-eol: 3.24 2028-06-01\n# alpine-eol: 3.24 2099-01-01\nARG ALPINE_VERSION=3.24\n' \
    > "${_f}"
  run _marker_field "${_f}" 2
  assert_failure
}

@test "alpine eol reader: a marker naming a series the ARG does not pin is visible (#946)" {
  local _f
  _f="$(_fixture '# alpine-eol: 3.21 2026-11-01' 'ARG ALPINE_VERSION=3.24')"
  [[ "$(_marker_field "${_f}" 1)" != "$(_pinned_series "${_f}")" ]]
}

@test "alpine eol reader: an already-expired date reads as negative days (#946)" {
  run _days_until 2000-01-01
  assert_success
  [[ "${output}" -lt 0 ]]
}

@test "alpine eol reader: a malformed date FAILS, it does not read as far away (#946)" {
  run _days_until 'someday'
  assert_failure
  run _days_until '2028-6-1'
  assert_failure
}
