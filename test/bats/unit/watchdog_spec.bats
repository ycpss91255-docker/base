#!/usr/bin/env bats
#
# Unit tests for dist/script/docker/runtime/watchdog.sh -- the generic
# single-service watchdog sourced from a repo entrypoint (sibling of
# logging.sh). Health-check-driven supervision with two failure actions
# (restart-container default / restart-service), all knobs default OFF.
# See ADR-00000020 (base owns the single-service lifecycle).

bats_require_minimum_version 1.5.0

WD="/source/dist/script/docker/runtime/watchdog.sh"

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  TMP_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP_DIR}"
}

# ── master off switch ────────────────────────────────────────────────

@test "watchdog is a no-op when WATCHDOG_CHECK is unset (default off) (#797)" {
  run bash -c "
    unset WATCHDOG_CHECK
    . '${WD}'
    echo ready
  "
  assert_success
  assert_output "ready"
}

@test "_watchdog_enabled is false when check empty, true when set (#797)" {
  run bash -c ". '${WD}'; WATCHDOG_CHECK=''  _watchdog_enabled"
  assert_failure
  run bash -c ". '${WD}'; WATCHDOG_CHECK='true' _watchdog_enabled"
  assert_success
}

# ── config load: defaults + clamping ─────────────────────────────────

@test "_watchdog_load_config applies defaults when knobs unset (#797)" {
  run bash -c "
    . '${WD}'
    _watchdog_load_config
    echo \"\${_WATCHDOG_INTERVAL} \${_WATCHDOG_TIMEOUT} \${_WATCHDOG_START_PERIOD} \${_WATCHDOG_FAILURES} \${_WATCHDOG_MAX_RESTARTS} \${_WATCHDOG_ON_FAIL}\"
  "
  assert_success
  assert_output "30 10 0 3 5 restart-container"
}

@test "_watchdog_load_config clamps a non-positive interval back to default (#797)" {
  run bash -c "
    . '${WD}'
    WATCHDOG_INTERVAL=0 WATCHDOG_FAILURES=-2 _watchdog_load_config
    echo \"\${_WATCHDOG_INTERVAL} \${_WATCHDOG_FAILURES}\"
  "
  assert_success
  assert_output "30 3"
}

@test "_watchdog_load_config accepts start_period 0 but clamps non-numeric (#797)" {
  run bash -c ". '${WD}'; WATCHDOG_START_PERIOD=0 _watchdog_load_config; echo \"\${_WATCHDOG_START_PERIOD}\""
  assert_output "0"
  run bash -c ". '${WD}'; WATCHDOG_START_PERIOD=abc _watchdog_load_config; echo \"\${_WATCHDOG_START_PERIOD}\""
  assert_output "0"
}

@test "_watchdog_load_config honors restart-service, defaults bogus ON_FAIL to restart-container (#797)" {
  run bash -c ". '${WD}'; WATCHDOG_ON_FAIL=restart-service _watchdog_load_config; echo \"\${_WATCHDOG_ON_FAIL}\""
  assert_output "restart-service"
  run bash -c ". '${WD}'; WATCHDOG_ON_FAIL=bogus _watchdog_load_config; echo \"\${_WATCHDOG_ON_FAIL}\""
  assert_output "restart-container"
}

# ── health check runner ──────────────────────────────────────────────

@test "_watchdog_run_check returns the check command's status (#797)" {
  run bash -c ". '${WD}'; WATCHDOG_CHECK='true'  _WATCHDOG_TIMEOUT=2 _watchdog_run_check"
  assert_success
  run bash -c ". '${WD}'; WATCHDOG_CHECK='false' _WATCHDOG_TIMEOUT=2 _watchdog_run_check"
  assert_failure
}

@test "_watchdog_run_check times out a hung check as unhealthy (#797)" {
  run bash -c ". '${WD}'; WATCHDOG_CHECK='sleep 10' _WATCHDOG_TIMEOUT=1 _watchdog_run_check"
  assert_failure
}

# ── evaluate: the shared decision seam ───────────────────────────────

@test "_watchdog_evaluate resets the counter on a healthy check (#797)" {
  run bash -c "
    . '${WD}'
    WATCHDOG_CHECK='true' _WATCHDOG_FAILURES=3
    _ctr=2
    _watchdog_evaluate _ctr
    echo \"rc=\$? ctr=\${_ctr}\"
  "
  assert_output "rc=0 ctr=0"
}

@test "_watchdog_evaluate returns 1 (under threshold) then 2 (threshold reached) (#797)" {
  run bash -c "
    . '${WD}'
    export WATCHDOG_CHECK='false' _WATCHDOG_FAILURES=2 _WATCHDOG_TIMEOUT=2
    _ctr=0
    _watchdog_evaluate _ctr; r1=\$?
    _watchdog_evaluate _ctr; r2=\$?
    echo \"r1=\${r1} r2=\${r2} ctr=\${_ctr}\"
  "
  assert_output "r1=1 r2=2 ctr=2"
}

# ── give-up boundary ─────────────────────────────────────────────────

@test "_watchdog_should_give_up fires only at the MAX_RESTARTS ceiling (#797)" {
  run bash -c "
    . '${WD}'
    _WATCHDOG_MAX_RESTARTS=2
    _watchdog_should_give_up 0 && echo a || echo -a
    _watchdog_should_give_up 1 && echo b || echo -b
    _watchdog_should_give_up 2 && echo c || echo -c
  "
  assert_output $'-a\n-b\nc'
}

# ── start period defers checks (real monitor loop, bounded) ──────────

@test "restart-container monitor DEFERS checks during the start period (#797)" {
  # A failing check + a start period longer than the observation window
  # must NOT trigger a container exit yet (still initializing).
  run timeout 6 bash -c "
    . '${WD}'
    export WATCHDOG_CHECK='false'
    _WATCHDOG_START_PERIOD=30 _WATCHDOG_INTERVAL=1 _WATCHDOG_TIMEOUT=1 _WATCHDOG_FAILURES=1
    _watchdog_exit_container() { echo ACTED; exit 0; }
    ( _watchdog_monitor ) &
    _pid=\$!
    sleep 2
    kill \${_pid} 2>/dev/null || true
    echo DONE
  "
  refute_output --partial "ACTED"
  assert_output --partial "DONE"
}

# ── restart-container acts after the failure threshold ───────────────

@test "restart-container monitor EXITS the container after consecutive failures (#797)" {
  run timeout 8 bash -c "
    . '${WD}'
    export WATCHDOG_CHECK='false'
    _WATCHDOG_START_PERIOD=0 _WATCHDOG_INTERVAL=1 _WATCHDOG_TIMEOUT=1 _WATCHDOG_FAILURES=2
    _watchdog_exit_container() { echo ACTED-\$1; exit 0; }
    _watchdog_monitor
  " 2>&1
  assert_success
  assert_output --partial "restart-container"
  assert_output --partial "ACTED-1"
}

# ── restart-service: restarts in place, gives up loudly at MAX ───────

@test "restart-service supervisor restarts in place then GIVES UP loudly at MAX_RESTARTS (#797)" {
  run timeout 10 bash -c "
    . '${WD}'
    export WATCHDOG_CHECK='false'
    _WATCHDOG_START_PERIOD=0 _WATCHDOG_INTERVAL=1 _WATCHDOG_TIMEOUT=1 _WATCHDOG_FAILURES=1 _WATCHDOG_MAX_RESTARTS=2
    # Stub the child-management seams so no real processes are spawned.
    _watchdog_start_service()   { :; }
    _watchdog_child_alive()     { return 0; }
    _watchdog_restart_service() { echo RESTARTED; }
    _watchdog_stop_service()    { :; }
    _watchdog_exit_container()  { echo EXITED; exit 0; }
    _watchdog_supervise sleep 100
  " 2>&1
  assert_success
  # Two in-place restarts (MAX_RESTARTS=2), then a loud give-up + container exit.
  assert_output --partial "restart 1/2"
  assert_output --partial "restart 2/2"
  assert_output --partial "GIVING UP"
  assert_output --partial "EXITED"
}

# ── NOTIFY runs on give-up when set ──────────────────────────────────

@test "_watchdog_give_up runs WATCHDOG_NOTIFY when set + logs loudly (#797)" {
  local _marker="${TMP_DIR}/notified"
  run bash -c "
    . '${WD}'
    export WATCHDOG_CHECK='false' WATCHDOG_NOTIFY='touch ${_marker}'
    _WATCHDOG_MAX_RESTARTS=1
    _watchdog_stop_service()   { :; }
    _watchdog_exit_container() { echo EXITED; }
    _watchdog_give_up
  " 2>&1
  assert_output --partial "GIVING UP"
  assert [ -f "${_marker}" ]
}

@test "_watchdog_notify is a no-op when WATCHDOG_NOTIFY is unset (#797)" {
  run bash -c ". '${WD}'; unset WATCHDOG_NOTIFY; _watchdog_notify; echo ok"
  assert_success
  assert_output "ok"
}

# ── watchdog.log persistence (reuses logrotate.sh) ───────────────────

@test "watchdog log setup writes a per-start file + stable symlink under watchdog/ (#797, #805)" {
  run bash -c "
    . '${WD}'
    export LOG_FILE_PATH='${TMP_DIR}/devel.log'
    _watchdog_log_setup
    _watchdog_log WARN 'restart event'
  " 2>&1
  assert_success
  # A per-start real file exists in the watchdog/ subdir, holding the event.
  run bash -c "grep -rF 'restart event' '${TMP_DIR}/watchdog/'"
  assert_success
  # The stable watchdog.log symlink points at the current run.
  assert [ -L "${TMP_DIR}/watchdog/watchdog.log" ]
}

@test "watchdog log is stderr-only (no file) when no log dir is configured (#797)" {
  run bash -c "
    . '${WD}'
    unset LOG_FILE_PATH
    _watchdog_log_setup
    _watchdog_log WARN 'to stderr only'
    echo \"file='\${_WATCHDOG_LOG_FILE}'\"
  " 2>&1
  assert_success
  assert_output --partial "to stderr only"
  assert_output --partial "file=''"
}
