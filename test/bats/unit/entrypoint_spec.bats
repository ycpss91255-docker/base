#!/usr/bin/env bats
#
# Unit tests for dist/script/docker/runtime/entrypoint.sh -- base's
# container ENTRYPOINT orchestrator.
#
# The orchestrator is the base-owned half of the two-file entrypoint model:
# it ships from .base/dist/, lands in the image at
# /usr/local/lib/base/entrypoint.sh next to the helpers it sources, and is
# the container ENTRYPOINT. The repo-owned half is the bringup at
# /entrypoint.sh, which the orchestrator SOURCES -- it is not the entry
# point and does not exec.
#
# What is under test here is the ORDER, because every one of the four steps
# depends on the one before it: logging rebinds stdout/stderr and so has to
# be first; the bringup sets the env the workload needs and so has to
# precede it; the watchdog may take over the process on
# ON_FAIL=restart-service and so has to arm last, around the real exec.
#
# The three absolute paths are frozen into the file's bottom guard, which
# is where the Dockerfile contract lives. The dispatcher above it takes
# them as arguments so this spec can drive the REAL function against a
# scratch tree rather than assert on the text of a copy -- the same
# sourced-vs-executed seam every other shipped script carries.
#
# (Sibling naming: runtime/logging.sh's spec is entrypoint_logging_spec.bats,
# named after the helper's former _entrypoint_logging.sh spelling.)

bats_require_minimum_version 1.5.0

ORCH="/source/dist/script/docker/runtime/entrypoint.sh"

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  assert_spec_subject "${ORCH}" "the ENTRYPOINT orchestrator this spec drives"
  TMP_DIR="$(mktemp -d)"
  LIB_DIR="${TMP_DIR}/lib"
  mkdir -p "${LIB_DIR}"
  BRINGUP="${TMP_DIR}/entrypoint.sh"
}

teardown() {
  rm -rf "${TMP_DIR}"
}

# _orchestrate <cmd...> -- drive the real dispatcher against the scratch
# lib dir and bringup path this spec built, with <cmd...> as the workload.
_orchestrate() {
  bash -c ". '${ORCH}'; _base_entrypoint_main '${LIB_DIR}' '${BRINGUP}' \"\$@\"" \
    _orchestrate "$@"
}

# ── the ordering ─────────────────────────────────────────────────────

@test "orchestrator runs logging, then the bringup, then the watchdog, then the workload (#945)" {
  printf 'printf "LOGGING\\n"\n'  > "${LIB_DIR}/logging.sh"
  printf 'printf "WATCHDOG\\n"\n' > "${LIB_DIR}/watchdog.sh"
  printf 'printf "BRINGUP\\n"\n'  > "${BRINGUP}"

  run _orchestrate bash -c 'printf "WORKLOAD\n"'
  assert_success
  assert_line --index 0 "LOGGING"
  assert_line --index 1 "BRINGUP"
  assert_line --index 2 "WATCHDOG"
  assert_line --index 3 "WORKLOAD"
}

@test "the watchdog sees a knob the bringup set, because bringup is sourced first (#945)" {
  # The behavioural statement of the order: a repo whose bringup decides
  # WATCHDOG_CHECK (from its own config, its ROS overlay, ...) is armed
  # with that value. Ordering the watchdog first would silently disarm it.
  printf 'export WATCHDOG_CHECK=true\n' > "${BRINGUP}"
  printf 'printf "check=%%s\\n" "${WATCHDOG_CHECK:-unset}"\n' \
    > "${LIB_DIR}/watchdog.sh"

  run _orchestrate true
  assert_success
  assert_output "check=true"
}

# ── the bringup is sourced, not executed ─────────────────────────────

@test "environment the bringup exports reaches the workload (#945)" {
  printf 'export BRINGUP_VAR=set-by-bringup\n' > "${BRINGUP}"

  run _orchestrate bash -c 'printf "%s\n" "${BRINGUP_VAR:-unset}"'
  assert_success
  assert_output "set-by-bringup"
}

@test "a non-executable bringup still runs, because it is sourced (#945)" {
  # The repo-owned file is COPY'd --chmod=0755 today, but nothing about
  # the contract depends on that: `.` reads it. Pinning this is what keeps
  # a later "just exec it" simplification from passing its own tests.
  printf 'export BRINGUP_VAR=sourced-anyway\n' > "${BRINGUP}"
  chmod 0644 "${BRINGUP}"

  run _orchestrate bash -c 'printf "%s\n" "${BRINGUP_VAR:-unset}"'
  assert_success
  assert_output "sourced-anyway"
}

# ── every source is optional ─────────────────────────────────────────

@test "a missing bringup and missing helpers still start the workload cleanly (#945)" {
  # The runtime stage's helper COPY is opt-in and a repo need not have a
  # bringup at all, so an image carrying none of the three must still come
  # up -- with nothing on stderr, and without aborting under the strict
  # mode the orchestrator runs with.
  rm -f "${BRINGUP}"

  run --separate-stderr _orchestrate bash -c 'printf "WORKLOAD\n"'
  assert_success
  assert_output "WORKLOAD"
  [ -z "${stderr}" ] || fail "orchestrator wrote to stderr: ${stderr}"
}

@test "the workload's argv survives verbatim, spaces included (#945)" {
  run _orchestrate printf '[%s]' a 'b c'
  assert_success
  assert_output "[a][b c]"
}

# ── the frozen paths ─────────────────────────────────────────────────

@test "executed directly with nothing installed, it still execs the workload (#945)" {
  # The frozen literals, driven for real rather than grepped: run the
  # shipped file as the container would, in an image that has neither
  # /usr/local/lib/base/ nor /entrypoint.sh. It must reach the exec with
  # nothing on stderr and without aborting under its own strict mode --
  # the runtime stage's helper COPY is opt-in and a repo need not have a
  # bringup, so this is a real image shape, not a hypothetical one.
  if [[ -e /usr/local/lib/base/logging.sh || -e /usr/local/lib/base/watchdog.sh \
     || -e /entrypoint.sh ]]; then
    skip "this image installs part of the model -- the absent path is not observable here"
  fi
  local _err="${BATS_TEST_TMPDIR}/orchestrator.err"
  run bash -c 'bash "$1" printf ok 2>"$2"' _ "${ORCH}" "${_err}"
  assert_success
  assert_output "ok"
  assert_equal "$(cat "${_err}")" ""
}

@test "executed directly, the orchestrator drives the in-image paths (#945)" {
  # The Dockerfile contract, in the one place it is spelled: the helpers
  # come from /usr/local/lib/base/ (the directory COPY'd from
  # .base/dist/script/docker/runtime/) and the bringup is /entrypoint.sh
  # (the repo file COPY'd from ${ENTRYPOINT_FILE}). Both are frozen paths;
  # a rewrite that changes one has to change the Dockerfile with it.
  run grep -Fq '_base_entrypoint_main /usr/local/lib/base /entrypoint.sh "$@"' \
    "${ORCH}"
  assert_success
}
