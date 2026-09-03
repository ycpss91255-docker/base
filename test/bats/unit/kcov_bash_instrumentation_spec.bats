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
# run -- 572 of them across sixteen untouched files, moving the project
# line rate 84.97% -> 77.60% with no source change. A coverage floor cannot
# tell that from a real regression, which is the whole reason it is worth a
# spec: the failure mode of a broken instrument is a plausible number.
#
# dockerfile/Dockerfile.test-tools patches kcov's parity counter to
# understand `$'...'`. These two tests are that patch's acceptance, and
# they are deliberately BEHAVIOURAL: they run the real kcov over a fixture
# and read the report it writes, so they answer "does the image measure
# correctly", not "does the Dockerfile contain the sed I wrote". An image
# built from an unpatched kcov fails them whatever the Dockerfile says.
#
# The two cases are the two directions the patch can be wrong in. The first
# is the bug: ANSI-C `\'` must NOT flip the parity. The second is the
# over-correction: inside a plain `'...'` a backslash is literal to the
# shell, so a value ENDING in one closes its quote, and a patch that
# treated it as an escape would swallow the next line instead.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  DOCKERFILE=/source/dockerfile/Dockerfile.test-tools
  assert_spec_subject "${DOCKERFILE}" \
    "the test-tools Dockerfile whose kcov patch these tests are the acceptance for"
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

@test "kcov: lines after an ANSI-C \$'...' value are recorded as run (bash 5.3 xtrace quoting)" {
  # Lines 5-7 all execute unconditionally. Under an unpatched kcov every
  # one of them reports 0: line 4's trace carries two `\'` sequences, which
  # leave the parity counter inside a quote it never left.
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
      "line ${_l} ran but kcov recorded $(_hits "${_l}") hits. The bash-engine quote-parity patch in ${DOCKERFILE} is missing from this image (rebuild it) or no longer applies to this KCOV_VERSION. Until it does, every coverage figure this image produces under-reports by a silent, data-dependent margin."
  done
}

@test "kcov: a backslash inside a plain '...' value stays literal, so the next line is recorded" {
  # The over-correction guard. `_v` ends in a backslash, which the shell
  # keeps literal inside single quotes, so xtrace emits `_v='...\'` and the
  # quote genuinely closes there. A patch that read that backslash as an
  # escape would consume the closing quote and swallow lines 3-4.
  _measure "#!/usr/bin/env bash
_v='ends with a literal backslash \\'
_w=\"after\"
printf '%s\\n' \"\${_v}\${_w}\" >/dev/null"

  local _l
  for _l in 3 4; do
    [[ "$(_hits "${_l}")" -ge 1 ]] || fail \
      "line ${_l} ran but kcov recorded $(_hits "${_l}") hits. The quote-parity patch over-corrected: a backslash inside a plain single-quoted word is literal to the shell, so treating it as an escape eats the closing quote and discards everything after it."
  done
}
