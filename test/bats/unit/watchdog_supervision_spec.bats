#!/usr/bin/env bats
#
# Process-level supervision tests for dist/script/docker/runtime/watchdog.sh
# (issue 797): the restart-container monitor loop, the restart-service
# supervisor, and the real signal / process-group teardown paths (bounded
# SIGTERM -> grace -> SIGKILL, whole-subtree kill via setsid, and the
# docker-stop SIGTERM forward). These drive real background processes,
# sleeps, and signals, so they are KCOV-FRAGILE (the kcov wrapper perturbs
# child processes / signal timing, per ADR-00000008): every test below
# carries the line-anchored `[ "${COVERAGE:-0}" = 1 ] && skip` guard so
# the coverage matrix skips this file and it runs PLAIN under bats-fragile.
# The kcov-safe pure-logic units live in watchdog_spec.bats.

bats_require_minimum_version 1.5.0

WD="/source/dist/script/docker/runtime/watchdog.sh"

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  TMP_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP_DIR}"
}

# ── event-driven synchronisation, never a fixed sleep ───────────────
#
# Every case below drives REAL processes, so the harness has to wait for
# something a child does before it acts: the pid file is written, the TERM
# trap is installed. A fixed `sleep N` cannot express that wait -- N is a
# guess about the scheduler, and this suite runs 32-way parallel, often
# beside a sibling checkout's gate, so the guess is regularly wrong. When it
# was wrong here the signal landed BEFORE the service installed its trap and
# the assertion read NO_SIGNAL: a correct supervisor reported as a product
# defect, five gate runs across four unrelated branches.
#
# `_await_file` / `_await_gone` poll for the OBSERVABLE EVENT under a
# generous ceiling instead. A slow machine then costs latency, never a
# verdict. Just as important, a harness that never got going reports its OWN
# distinct outcome (NOT_READY / NO_PID) rather than borrowing the product's
# failure word, so "the test never set the experiment up" can never again be
# read as "the supervisor did not forward the signal".
#
# The helper text is injected into each `bash -c` body because those run in
# their own process, not in the bats shell. The ceilings are in units of
# 0.1s and are deliberately far larger than any plausible scheduling delay;
# they exist to bound a HANG, not to time a correct run.
_SYNC_FN='
_await_file() {
  local _p="${1}" _n="${2:-100}" _i=0
  while [ "${_i}" -lt "${_n}" ]; do
    [ -s "${_p}" ] && return 0
    sleep 0.1
    _i=$(( _i + 1 ))
  done
  return 1
}
_await_gone() {
  local _pid="${1}" _n="${2:-100}" _i=0
  while [ "${_i}" -lt "${_n}" ]; do
    kill -0 "${_pid}" 2>/dev/null || return 0
    sleep 0.1
    _i=$(( _i + 1 ))
  done
  return 1
}
'

# The teardown counterpart, injected the same way: a harness that gives up
# has to take down what it STARTED. Killing the supervisor does not --
# _watchdog_start_service setsids the service into its own process group,
# so it outlives the supervisor and, in a 32-way parallel suite, goes on
# occupying a slot for the rest of its fixture's lifetime. (What it can no
# longer do is hold the case itself open: the harness hands the supervisor
# a log file rather than the case's own descriptor. Both are wanted --
# one bounds the case, the other bounds the leak.)
#
# The group id comes from the fixture itself (it records `$$`, and setsid
# made it the group leader) rather than from the supervisor, which is dead
# by the time this runs. The single-pid fallback covers a userland with no
# setsid, where there is no group to signal. Signalling a pid the
# supervisor already reaped is a no-op here: pids are handed out in
# increasing order and a container would have to fork through the whole
# pid space between the reap and this line to hand it to a stranger.
_CLEANUP_FN='
_kill_group() {
  local _f="${1}" _p=""
  [ -s "${_f}" ] || return 0
  _p="$(cat "${_f}")"
  [ -n "${_p}" ] || return 0
  kill -KILL "-${_p}" 2>/dev/null || kill -KILL "${_p}" 2>/dev/null || true
}
'

# ── restart-container monitor loop ───────────────────────────────────

@test "restart-container monitor DEFERS checks during the start period (#797)" {
  [ "${COVERAGE:-0}" = 1 ] && skip "signal/process-timing spec runs plain under bats-fragile (#613)"
  # A failing check + a start period longer than the observation window
  # must NOT trigger a container exit yet (still initializing).
  #
  # The 2s window is an OBSERVATION window, not a synchronisation point: the
  # property is the ABSENCE of an event, and load can only make that absence
  # more likely, never less. What load CAN do is make it vacuous -- a monitor
  # that crashed on its first line also never prints ACTED. So the window
  # ends by asking whether the monitor is still there, which separates "it
  # deferred" from "it was never running to defer".
  run timeout 30 bash -c "
    . '${WD}'
    export WATCHDOG_CHECK='false'
    _WATCHDOG_START_PERIOD=30 _WATCHDOG_INTERVAL=1 _WATCHDOG_TIMEOUT=1 _WATCHDOG_FAILURES=1
    _watchdog_exit_container() { echo ACTED; exit 0; }
    ( _watchdog_monitor ) &
    _pid=\$!
    sleep 2
    if kill -0 \${_pid} 2>/dev/null; then echo STILL_DEFERRING; else echo MONITOR_GONE; fi
    kill \${_pid} 2>/dev/null || true
    echo DONE
  "
  refute_output --partial "ACTED"
  assert_output --partial "STILL_DEFERRING"
  refute_output --partial "MONITOR_GONE"
  assert_output --partial "DONE"
}

@test "restart-container monitor EXITS the container after consecutive failures (#797)" {
  [ "${COVERAGE:-0}" = 1 ] && skip "signal/process-timing spec runs plain under bats-fragile (#613)"
  # timeout 30, not 8: the loop needs two 1s intervals plus two bounded
  # checks, so a value sized to the EXPECTED wall clock turns a loaded
  # machine into a red gate. The timeout is here to catch a loop that never
  # terminates, and 30s catches that just as well.
  run timeout 30 bash -c "
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

# ── restart-service supervisor: restart-in-place + give-up (stubbed
#    child seams so the loop logic is exercised without real processes) ─

@test "restart-service supervisor restarts in place then GIVES UP loudly at MAX_RESTARTS (#797)" {
  [ "${COVERAGE:-0}" = 1 ] && skip "signal/process-timing spec runs plain under bats-fragile (#613)"
  # timeout 30 for the reason given on the monitor case above: it bounds a
  # non-terminating loop, it does not schedule a correct one.
  run timeout 30 bash -c "
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
  assert_output --partial "restart 1/2"
  assert_output --partial "restart 2/2"
  assert_output --partial "GIVING UP"
  assert_output --partial "EXITED"
}

# ── bounded stop: a SIGTERM-ignoring service is SIGKILL'd, no hang ────

@test "_watchdog_stop_service SIGKILLs a SIGTERM-ignoring service within the bounded grace (no hang) (#797)" {
  [ "${COVERAGE:-0}" = 1 ] && skip "signal/process-timing spec runs plain under bats-fragile (#613)"
  # Optional on purpose: setsid comes from the base distro userland
  # (busybox on alpine), not from anything this repo installs or
  # tracks, so its absence is a property of where the suite is running
  # and there is no repo-side change that could cause it. Without a new
  # session the SIGKILL escalation cannot be observed at all.
  command -v setsid >/dev/null 2>&1 \
    || skip "no setsid in this userland; the process-group escalation under test cannot be set up without it"
  cat > "${TMP_DIR}/ignore_term.sh" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
echo $$ > "$1"
sleep 60
EOF
  # timeout 30: an unbounded wait (the pre-fix bug) hangs here -> status 124.
  # The two waits inside are event-driven: a `sleep 0.5` before
  # reading the pid file is a guess, and when the guess lost the read
  # produced an EMPTY pid, `kill -0 ""` failed, and the case reported KILLED
  # -- a green run that had killed nothing. NO_PID is now its own outcome.
  run timeout 30 bash -c "
    ${_SYNC_FN}
    . '${WD}'
    export _WATCHDOG_TIMEOUT=1
    _watchdog_start_service bash '${TMP_DIR}/ignore_term.sh' '${TMP_DIR}/svc.pid'
    if ! _await_file '${TMP_DIR}/svc.pid' 150; then echo NO_PID; exit 0; fi
    _pid=\"\$(cat '${TMP_DIR}/svc.pid')\"
    _watchdog_stop_service
    if _await_gone \"\${_pid}\" 100; then echo KILLED; else echo STILL_ALIVE; fi
  "
  assert_success
  assert_output --partial "KILLED"
  refute_output --partial "STILL_ALIVE"
  refute_output --partial "NO_PID"
}

# ── whole-subtree kill: no orphaned grandchild survives a stop ───────

@test "_watchdog_stop_service kills the whole service subtree (no orphaned grandchild) (#797)" {
  [ "${COVERAGE:-0}" = 1 ] && skip "signal/process-timing spec runs plain under bats-fragile (#613)"
  # Optional on purpose: setsid comes from the base distro userland
  # (busybox on alpine), not from anything this repo installs or
  # tracks, so its absence is a property of where the suite is running
  # and there is no repo-side change that could cause it. Without a new
  # session the SIGKILL escalation cannot be observed at all.
  command -v setsid >/dev/null 2>&1 \
    || skip "no setsid in this userland; the process-group escalation under test cannot be set up without it"
  cat > "${TMP_DIR}/spawner.sh" <<'EOF'
#!/usr/bin/env bash
# A grandchild that ignores SIGTERM and records its own pid, then the
# service itself sleeps. Both share the setsid process group.
#
# BASHPID, not $$: `$$` keeps the INVOKING shell's pid inside a
# subshell, so this line used to record the SERVICE's pid and the case
# below re-checked the process it had already stopped -- it never observed
# a grandchild at all, and stayed green with the process-group kill
# disabled. BASHPID is the subshell's own pid.
( trap '' TERM; echo "${BASHPID}" > "$1"; sleep 60 ) &
sleep 60
EOF
  # Event-driven for the same reason as the case above: losing the
  # `sleep 0.7` race read an empty grandchild pid and reported SUBTREE_DEAD
  # without having observed any subtree.
  run timeout 30 bash -c "
    ${_SYNC_FN}
    . '${WD}'
    export _WATCHDOG_TIMEOUT=1
    _watchdog_start_service bash '${TMP_DIR}/spawner.sh' '${TMP_DIR}/grand.pid'
    if ! _await_file '${TMP_DIR}/grand.pid' 150; then echo NO_PID; exit 0; fi
    _gpid=\"\$(cat '${TMP_DIR}/grand.pid')\"
    _watchdog_stop_service
    if _await_gone \"\${_gpid}\" 100; then echo SUBTREE_DEAD; else echo ORPHAN_ALIVE; fi
  "
  assert_success
  assert_output --partial "SUBTREE_DEAD"
  refute_output --partial "ORPHAN_ALIVE"
  refute_output --partial "NO_PID"
}

# ── give-up against a wedged service still reaches container exit ────

@test "restart-service give-up against a wedged (SIGTERM-ignoring) service still exits the container (#797)" {
  [ "${COVERAGE:-0}" = 1 ] && skip "signal/process-timing spec runs plain under bats-fragile (#613)"
  # Optional on purpose: setsid comes from the base distro userland
  # (busybox on alpine), not from anything this repo installs or
  # tracks, so its absence is a property of where the suite is running
  # and there is no repo-side change that could cause it. Without a new
  # session the SIGKILL escalation cannot be observed at all.
  command -v setsid >/dev/null 2>&1 \
    || skip "no setsid in this userland; the process-group escalation under test cannot be set up without it"
  cat > "${TMP_DIR}/wedged.sh" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
sleep 300
EOF
  # Real (bounded) stop_service against a wedged child; only exit_container
  # is overridden to observe that give-up REACHES it (the pre-fix unbounded
  # wait would hang stop_service so give-up never exits -> the timeout
  # fires). 45, not 15: the timeout bounds that hang, it does not schedule
  # the several bounded stop cycles a correct run performs.
  run timeout 45 bash -c "
    . '${WD}'
    export WATCHDOG_CHECK='false'
    _WATCHDOG_START_PERIOD=0 _WATCHDOG_INTERVAL=1 _WATCHDOG_TIMEOUT=1 _WATCHDOG_FAILURES=1 _WATCHDOG_MAX_RESTARTS=1
    _watchdog_exit_container() { echo EXITED; exit 0; }
    _watchdog_supervise bash '${TMP_DIR}/wedged.sh'
  " 2>&1
  assert_success
  assert_output --partial "GIVING UP"
  assert_output --partial "EXITED"
}

# ── docker stop: supervisor forwards SIGTERM PROMPTLY (not deferred until
#    the interval) to the service group ───────────────────────────────

# _run_forward_harness <service-script> <ready-ceiling-tenths> -- start the
# supervisor on <service-script>, wait for its READY marker, SIGTERM it, and
# report the verdict as words: GRACEFUL / NO_SIGNAL for the forward,
# PROMPT_<n>s / DEFERRED_<n>s for the promptness, NOT_READY when the service
# never got as far as installing its trap.
#
# One body, two cases: the case below drives it with a service that DOES
# become ready, and the case after that drives it with one that never does,
# so the harness's own failure path is exercised by the same code the
# passing path uses rather than by a copy that can drift away from it.
#
# The supervisor's own output goes to a FILE and is replayed at the end,
# which is what makes the failure paths cost what their ceilings say. bats
# reads a case's output from one descriptor; everything the supervisor
# spawns used to inherit it, so ANY survivor held the case open long after
# it had printed its verdict -- the service (setsid into its own group,
# 326s observed) and then, once that was being killed, the product's own
# interruptible-sleep child, for the full 30s interval. Handing the
# supervisor a file instead means no descendant can hold the case open,
# whichever one outlives it. Replaying the file keeps the supervisor's log
# lines in the failure report, where they are the diagnosis.
_run_forward_harness() {
  local _svc="${1:?BUG: _run_forward_harness expects a service script}"
  local _ready_tenths="${2:?BUG: _run_forward_harness expects a ceiling}"
  run timeout 60 bash -c "
    ${_SYNC_FN}
    ${_CLEANUP_FN}
    . '${WD}'
    export WATCHDOG_CHECK='true'
    _WATCHDOG_START_PERIOD=0 _WATCHDOG_INTERVAL=30 _WATCHDOG_TIMEOUT=2 _WATCHDOG_FAILURES=3 _WATCHDOG_MAX_RESTARTS=5
    _watchdog_supervise bash '${_svc}' \
      '${TMP_DIR}/graceful.marker' '${TMP_DIR}/graceful.ready' \
      '${TMP_DIR}/service.pgid' > '${TMP_DIR}/sup.log' 2>&1 &
    _sup=\$!
    if ! _await_file '${TMP_DIR}/graceful.ready' ${_ready_tenths}; then
      kill -KILL \${_sup} 2>/dev/null || true
      _kill_group '${TMP_DIR}/service.pgid'
      cat '${TMP_DIR}/sup.log' 2>/dev/null || true
      echo NOT_READY
      exit 0
    fi
    _t0=\$(date +%s)
    kill -TERM \${_sup}
    wait \${_sup} 2>/dev/null || true
    _elapsed=\$(( \$(date +%s) - _t0 ))
    _kill_group '${TMP_DIR}/service.pgid'
    cat '${TMP_DIR}/sup.log' 2>/dev/null || true
    if [ -s '${TMP_DIR}/graceful.marker' ]; then echo GRACEFUL; else echo NO_SIGNAL; fi
    if [ \${_elapsed} -lt 10 ]; then echo PROMPT_\${_elapsed}s; else echo DEFERRED_\${_elapsed}s; fi
  "
}

@test "restart-service supervisor forwards SIGTERM PROMPTLY on docker stop, not deferred until the interval (#797)" {
  [ "${COVERAGE:-0}" = 1 ] && skip "signal/process-timing spec runs plain under bats-fragile (#613)"
  # Optional on purpose: setsid comes from the base distro userland
  # (busybox on alpine), not from anything this repo installs or
  # tracks, so its absence is a property of where the suite is running
  # and there is no repo-side change that could cause it. Without a new
  # session the SIGKILL escalation cannot be observed at all.
  command -v setsid >/dev/null 2>&1 \
    || skip "no setsid in this userland; the process-group escalation under test cannot be set up without it"
  cat > "${TMP_DIR}/graceful.sh" <<'EOF'
#!/usr/bin/env bash
# $1 -- written IFF a trapped SIGTERM arrives (the graceful forward).
# $2 -- the READY marker, written only AFTER the trap is installed. It is
#       what makes the harness's wait an EVENT rather than a guess: until
#       this file exists a SIGTERM would be taken by the DEFAULT handler and
#       kill the service silently, which says nothing about forwarding.
# $3 -- this process's group id, written FIRST and unconditionally, so the
#       harness can tear the group down on a path where it never gets a
#       ready marker to wait for. setsid made this process its own group
#       leader, so its pid IS the group.
echo "$$" > "$3"
trap 'echo forwarded > "$1"; exit 0' TERM
echo ready > "$2"
sleep 300
EOF
  # Two separate properties, asserted separately.
  #
  # FORWARDING: with INTERVAL=30 a bare foreground `sleep 30` in the
  # supervisor would DEFER the trapped SIGTERM until the interval elapsed,
  # so the marker would never be written; the interruptible sleep handles it
  # at once. This used to be measured by the harness's own `timeout 12`
  # cutting a deferred run short -- i.e. by wall clock.
  #
  # PROMPTNESS: measured directly instead, as the seconds between the signal
  # and the supervisor's exit, and required to be well under the 30s
  # interval. A deferred forward reports DEFERRED_30s by name rather than
  # by being killed, and a merely SLOW machine no longer looks like one.
  #
  # The wait for readiness gets a 20s ceiling and its own NOT_READY
  # outcome: under 32-way parallel load one fixed second was not enough for
  # the supervisor to spawn the service and for the service to install its
  # trap, so the signal arrived first, no marker was written, and the case
  # reported NO_SIGNAL -- the harness's own failure wearing the product's
  # failure word, five times across four branches.
  _run_forward_harness "${TMP_DIR}/graceful.sh" 200
  assert_success
  assert_output --partial "GRACEFUL"
  assert_output --partial "PROMPT_"
  refute_output --partial "NO_SIGNAL"
  refute_output --partial "NOT_READY"
  refute_output --partial "DEFERRED_"
}

@test "the readiness wait's own failure path returns within its bound, it does not hang (#965)" {
  [ "${COVERAGE:-0}" = 1 ] && skip "signal/process-timing spec runs plain under bats-fragile (#613)"
  # Optional on purpose, for the same reason as the case above: without
  # setsid the service is not in its own process group, which is the whole
  # subject here.
  command -v setsid >/dev/null 2>&1 \
    || skip "no setsid in this userland; the process-group teardown under test cannot be set up without it"
  # A harness failure has to COST what its ceiling says it costs. NOT_READY
  # used to kill the supervisor only: the service, setsid into its own
  # process group, survived holding the descriptor bats reads this case's
  # output from, so the case printed NOT_READY in about two seconds and then
  # sat there until the service exited on its own -- 326s observed, past its
  # own `timeout 60`, which a reader takes for a hung suite rather than a
  # failed test. The ceilings elsewhere in this file are documented as
  # bounding a HANG; on this path they bounded nothing.
  cat > "${TMP_DIR}/never_ready.sh" <<'EOF'
#!/usr/bin/env bash
# Records its process group ($3) and then never writes the READY marker
# ($2): a service that dies or wedges before installing its trap.
echo "$$" > "$3"
sleep 60
EOF
  local _t0 _elapsed
  _t0="$(date +%s)"
  # 20 tenths = a 2s ceiling, deliberately far below the fixture's lifetime,
  # so the readiness wait is guaranteed to give up and this case is about
  # what happens next rather than about the wait itself.
  _run_forward_harness "${TMP_DIR}/never_ready.sh" 20
  _elapsed=$(( $(date +%s) - _t0 ))
  assert_success
  assert_output --partial "NOT_READY"
  refute_output --partial "GRACEFUL"
  [[ "${_elapsed}" -lt 30 ]] || fail \
    "the readiness failure path returned after ${_elapsed}s, long past its own 2s ceiling: something the harness started outlived it and is still holding the output open"
}
