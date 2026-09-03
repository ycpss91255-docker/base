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
#
# why: base's container ENTRYPOINT orchestrator, the base-owned half of the
# two-file entrypoint model (ADR-00000030). It ships from `.base/dist/`,
# lands at `/usr/local/lib/base/entrypoint.sh`, and SOURCES the repo-owned
# bringup at `/entrypoint.sh` rather than executing it.
#
# The subject is the ORDER, because each of the four steps depends on the
# one before it: logging rebinds stdout/stderr, the bringup sets the env
# the workload reads, the watchdog may take over the process, and the
# workload execs last. The dispatcher takes its three paths as arguments so
# the REAL function runs against a scratch tree; the frozen in-image
# literals live in the file's bottom guard and are pinned separately.

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

# why: The load-bearing one. Every other ordering assertion is a
# consequence of this sequence, and a reordering that broke it would leave
# each step still working in isolation -- logging after the bringup loses
# the bringup's output, the watchdog before the bringup arms on stale
# knobs, and both stay green under a per-step test
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

# why: The behavioural statement of the order rather than the positional
# one: a repo whose bringup decides WATCHDOG_CHECK is armed with that
# value. Arming the watchdog first disarms it silently, which no ordering
# assertion on printed lines would call wrong
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

# why: The whole point of sourcing rather than executing the bringup. Run
# as a child it would still print, still exit 0, and still lose every
# export -- the failure a repo only sees when its ROS overlay is missing
# from the running workload
@test "environment the bringup exports reaches the workload (#945)" {
  printf 'export BRINGUP_VAR=set-by-bringup\n' > "${BRINGUP}"

  run _orchestrate bash -c 'printf "%s\n" "${BRINGUP_VAR:-unset}"'
  assert_success
  assert_output "set-by-bringup"
}

# why: Nothing in the contract depends on the mode bit, and pinning that
# is what stops a later "just exec it" simplification from passing its own
# tests -- the shipped file happens to be COPY'd 0755, so the exec variant
# would look correct everywhere except a repo that ships its bringup 0644
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

# why: The shape most existing repos are actually in -- the runtime helper
# COPY is opt-in and a repo need not carry a bringup at all. Asserted with
# stderr separated and under the orchestrator's own strict mode, because
# the interesting failures here are a stray diagnostic and a nounset abort,
# neither of which changes the workload's exit status
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

# why: The orchestrator sits between docker and CMD, so an unquoted `$@`
# anywhere in it re-splits the command a user typed. The embedded space is
# the only argument shape that catches that; a single-word workload passes
# through every wrong spelling
@test "the workload's argv survives verbatim, spaces included (#945)" {
  run _orchestrate printf '[%s]' a 'b c'
  assert_success
  assert_output "[a][b c]"
}

# ── the frozen paths ─────────────────────────────────────────────────

# why: The bottom guard driven for real instead of grepped. Every other
# test here calls the dispatcher with scratch paths, so nothing else
# exercises the frozen literals or the strict mode the shipped file turns
# on for itself -- and an image with none of the three installed is the
# ordinary pre-adoption shape, not a hypothetical
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

# why: The Dockerfile contract in the one place it is spelled. The test
# above proves the guard RUNS but passes just as happily on a helper
# directory the Dockerfile never populates, so the two literals need
# pinning on their own: change one and the Dockerfile has to change with it
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

# ── what ships, and how ──────────────────────────────────────────────

# why: Its four runtime siblings are 644 because they are sourced; this
# one is executed. The Dockerfile's `COPY --chmod=0755` hides a committed
# 644, so nothing in a normal build goes red -- the file is simply not
# runnable from the subtree, and any consumer path that stops going through
# that COPY inherits an exit 126
@test "the orchestrator ships with the executable bit set (#945)" {
  # It is EXECUTED, not sourced: the Dockerfile names it as ENTRYPOINT and
  # this spec drives it with `bash <file>`. Its four runtime siblings are
  # 644 because they are sourced; every shipped script that is run rather
  # than sourced is 755, and only the Dockerfile's `COPY --chmod=0755`
  # hides a 644 here -- so the file as committed would not be runnable from
  # the subtree, and any consumer path that stops going through that COPY
  # inherits an exit 126.
  assert [ -x "${ORCH}" ]
}

# why: Joins the two files nothing else joins -- it reads the ENTRYPOINT
# out of the shipped Dockerfile and requires the shared build-time baseline
# to name that same path. Without it the half the container actually starts
# is asserted by nothing, and a dropped runtime-directory COPY stays
# invisible until a real container fails to come up
@test "the shared smoke baseline asserts the orchestrator's in-image path (#945)" {
  # The build-time baseline exists to prove the installed entry point is
  # there. Pinning only the repo-owned bringup at /entrypoint.sh leaves the
  # base-owned half -- the file the ENTRYPOINT actually names -- asserted by
  # nothing in the tree, so a dropped runtime-dir COPY is invisible until a
  # container fails to start.
  local _wired
  _wired="$(sed -nE 's/^ENTRYPOINT \["([^"]+)".*/\1/p' \
    /source/dist/dockerfile/Dockerfile | head -n1)"
  [[ -n "${_wired}" ]] || fail "no uncommented ENTRYPOINT in the shipped Dockerfile"
  run grep -F "${_wired}" /source/dist/test/bats/smoke/shared/entrypoint.bats
  assert_success
}
