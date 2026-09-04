#!/usr/bin/env bats
#
# kcov_bash_instrumentation_spec.bats -- the coverage instrument records
# the lines that ran.
#
# Every other spec in this tree asserts something about the code. This one
# asserts about the MEASURING INSTRUMENT, because the instrument is the one
# input to the coverage gate that no test was watching -- and it moved.
#
# kcov collects bash coverage by setting PS4 to
# `kcov@${BASH_SOURCE}@${LINENO}@` and reading the xtrace stream. The traced
# command's own text follows the marker on the same line, so a value that
# CONTAINS a newline used to arrive as several physical lines, and the
# continuation lines carry no marker. kcov therefore tracks single-quote
# parity across lines, and while it believes it is inside an unterminated
# quote it DISCARDS every line it reads -- markers included.
#
# Its parity counter honoured a backslash escape only outside a quote,
# which was right for bash <= 5.2. bash 5.3 changed xtrace to ANSI-C
# quoting: one line, `$'a\nb'`, with an embedded quote written `\'`. Each
# of those flipped the counter, so a value holding an ODD number of them
# left kcov convinced it was mid-quote, and it then threw away every
# following trace line until the parity happened to flip back.
#
# Nothing failed. The suite stayed green, the shards stayed green, and a
# contiguous BURST of lines that had just executed was reported as never
# run -- 598 of them, moving the project line rate 84.77% (7058/8326) ->
# 77.60% (6460/8325). Both figures are the same source on alpine 3.24;
# the only difference between the two images is whether kcov's parity
# counter had been patched. (The reading that first showed it up was
# 84.97%, main's, which is a different tree: its numerator falls by 520
# across sixteen files this branch never touched while its denominator
# moves by +110, so it is the alarm rather than the measurement.) A
# coverage floor cannot tell any of that from a real regression, which is
# the whole reason it is worth a spec: the failure mode of a broken
# instrument is a plausible number.
#
# What this repo does about it is choose the series: the ALPINE_VERSION
# pinned in dockerfile/Dockerfile.test-tools stays on the bash 5.2 side of
# the boundary, which is at alpine 3.23 (3.21 and 3.22 ship bash 5.2.37;
# 3.23 ships 5.3.3, 3.24 ships 5.3.9 -- all read out of the built images).
# These two tests are that choice's acceptance, and they are deliberately
# BEHAVIOURAL: they run the real kcov over a fixture and read the report it
# writes, so they answer "does this image measure correctly", not "does the
# Dockerfile pin the series I expect". A bump onto a bash whose xtrace kcov
# misreads fails them at the moment of the bump, loudly, instead of moving
# the coverage number by a plausible-looking margin.
#
# The two cases are the two directions the reading can be wrong in. The
# first is the bug: an ANSI-C `\'` must not flip the parity. The second is
# its mirror -- inside a plain `'...'` a backslash is literal to the shell,
# so a value ENDING in one really does close its quote, and an instrument
# that read it as an escape would swallow the next line instead.
#
# why: Asserts about the MEASURING INSTRUMENT rather than about the code,
# because the instrument is the one input to the coverage gate that nothing
# was watching. kcov reads bash coverage out of the xtrace stream and tracks
# single-quote parity across lines; while it believes it is inside an
# unterminated quote it discards every line it reads, markers included. bash
# 5.3 changed xtrace to ANSI-C quoting (`$'a\nb'`, embedded quotes written
# `\'`), each of which flipped that counter -- so a burst of lines that had
# just executed was reported as never run, silently, with the suite green.
# `dockerfile/Dockerfile.test-tools` answers that by pinning an alpine
# series on the bash 5.2 side of the boundary, which is at 3.23 (3.21 and
# 3.22 ship 5.2.37; 3.23 ships 5.3.3, 3.24 ships 5.3.9). These two tests are
# that choice's acceptance, and they are behavioural (run the real kcov over
# a fixture and read the report), so a bump onto a bash kcov misreads fails
# at the bump rather than moving the coverage number by a plausible margin.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  DOCKERFILE=/source/dockerfile/Dockerfile.test-tools
  assert_spec_subject "${DOCKERFILE}" \
    "the test-tools Dockerfile whose alpine series pin decides which bash kcov has to read"
  command -v kcov >/dev/null || \
    fail "no kcov in this image -- the coverage instrument these tests measure is the thing that is missing."

  SRC_DIR="${BATS_TEST_TMPDIR}/src"
  OUT_DIR="${BATS_TEST_TMPDIR}/out"
  mkdir -p "${SRC_DIR}"
}

# _measure <script-body>
#   Write <script-body> to a fixture, run it under a nested kcov, and leave
#   the report in ${OUT_DIR}. Fails loudly rather than returning an empty
#   report: a fixture that never ran would make every hit assertion below
#   vacuous in the passing direction.
#
#   OUT_DIR is outside SRC_DIR on purpose -- kcov writes its own helper
#   scripts into the report directory and would otherwise measure them too.
#
#   The `env -u` list is not decoration. Under `just test coverage` this
#   spec is itself running inside kcov, which exports its instrumentation
#   through the environment (BASH_ENV, BASH_XTRACEFD, LD_PRELOAD). Inherited,
#   the inner bash would write its trace into the OUTER kcov's pipe and this
#   fixture would measure nothing at all.
_measure() {
  local _body="${1:?BUG: _measure expects a script body}"
  printf '%s\n' "${_body}" > "${SRC_DIR}/fixture.sh"
  chmod +x "${SRC_DIR}/fixture.sh"
  rm -rf "${OUT_DIR}"
  env -u BASH_ENV -u BASH_XTRACEFD -u KCOV_BASH_XTRACEFD -u LD_PRELOAD \
    kcov --include-path="${SRC_DIR}" "${OUT_DIR}" "${SRC_DIR}/fixture.sh" \
    >/dev/null 2>&1 || fail "kcov refused to run the fixture at all"
  REPORT="$(find "${OUT_DIR}" -name codecov.json -print -quit)"
  [[ -n "${REPORT}" ]] || fail \
    "kcov wrote no codecov.json under ${OUT_DIR} -- the report format changed, so these assertions read nothing."
}

# _hits <line>
#   Hit count kcov recorded for <line> of the fixture. Absent (the line is
#   not executable code at all) prints `null`, which no assertion below
#   accepts as a pass.
_hits() {
  local _line="${1:?BUG: _hits expects a line number}"
  yq -p=json ".coverage[] | .[\"${_line}\"]" "${REPORT}"
}

# why: The bug: an embedded `\'` must not flip the quote-parity counter and
# swallow the following lines
@test "kcov: lines after an ANSI-C \$'...' value are recorded as run (bash 5.3 xtrace quoting)" {
  # Lines 5-7 all execute unconditionally. Under a bash whose xtrace uses
  # ANSI-C quoting every one of them reports 0: line 4's trace carries two
  # `\'` sequences, which leave kcov's parity counter inside a quote it
  # never left.
  _measure "#!/usr/bin/env bash
declare -A _msg
_msg[a]=\"plain\"
_msg[b]=\$'line one\\n  - \\'quoted\\' word\\n  - end'
_msg[c]=\"first line after\"
_msg[d]=\"second line after\"
printf '%s\\n' \"\${_msg[c]}\" >/dev/null"

  [[ "$(_hits 4)" != "null" ]] || fail \
    "line 4 is not in the report at all -- the fixture no longer says what this test is about."
  local _l
  for _l in 5 6 7; do
    [[ "$(_hits "${_l}")" -ge 1 ]] || fail \
      "line ${_l} ran but kcov recorded $(_hits "${_l}") hits. This image's bash emits xtrace in a form kcov's bash engine misreads -- the ANSI-C quoting bash 5.3 introduced, which alpine picks up at 3.23. Check ARG ALPINE_VERSION in ${DOCKERFILE} against \`bash --version\` inside the image. Until they agree, every coverage figure this image produces under-reports by a silent, data-dependent margin."
  done
}

# why: The mirror case: inside `'...'` a backslash is literal, so a value
# ending in one really does close its quote
@test "kcov: a backslash inside a plain '...' value stays literal, so the next line is recorded" {
  # The mirror-image guard. `_v` ends in a backslash, which the shell keeps
  # literal inside single quotes, so xtrace emits `_v='...\'` and the quote
  # genuinely closes there. An instrument that read that backslash as an
  # escape would consume the closing quote and swallow lines 3-4.
  _measure "#!/usr/bin/env bash
_v='ends with a literal backslash \\'
_w=\"after\"
printf '%s\\n' \"\${_v}\${_w}\" >/dev/null"

  local _l
  for _l in 3 4; do
    [[ "$(_hits "${_l}")" -ge 1 ]] || fail \
      "line ${_l} ran but kcov recorded $(_hits "${_l}") hits. kcov read a backslash inside a plain single-quoted word as an escape. It is literal to the shell, so reading it as an escape eats the closing quote and discards everything after it."
  done
}
