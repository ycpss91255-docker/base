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

# How far past its own declared ceiling a case may run before the bound
# guard in teardown calls it a hang rather than a slow machine. Generous on
# purpose: the thing it separates is a case legitimately running to its own
# timeout on a 32-way parallel machine from one held open by a survivor for
# the whole lifetime of its fixture -- 45s against 301s, measured. A tight
# margin here would buy nothing and would make this guard the next flake.
readonly _CASE_BOUND_MARGIN=30

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  TMP_DIR="$(mktemp -d)"
  # The two halves of the bound guard in teardown: when this case started,
  # and the ceiling its own harness declared (0 until it declares one).
  _CASE_T0="${SECONDS}"
  _CASE_CEILING=0
}

# teardown -- the file-wide bound. Every case here starts real processes,
# and the way that goes wrong is not a wrong answer but NO answer: bats
# reads a case's output from one descriptor, so anything the case started
# that outlives it and inherited that descriptor keeps `run` waiting for
# EOF long after the verdict was printed. The case then costs its FIXTURE's
# lifetime rather than its own timeout -- 301s against a stated 45 -- and a
# reader takes that for a hung suite rather than for a failed test.
#
# Asserting it here rather than case by case is the point: it holds for the
# fourth sibling written next year without that sibling having to remember,
# and it is a measurement rather than a rule about how a case is spelled.
teardown() {
  local _elapsed=$(( SECONDS - _CASE_T0 ))
  rm -rf "${TMP_DIR}"
  _within_case_bound "${_elapsed}" "${_CASE_CEILING}" "${_CASE_BOUND_MARGIN}" || fail \
    "this case returned after ${_elapsed}s, past the ${_CASE_CEILING}s ceiling its own harness declared (+${_CASE_BOUND_MARGIN}s margin): something it started outlived it and is still holding the descriptor bats reads its output from"
}

# _within_case_bound <elapsed> <ceiling> <margin> -- the arithmetic above,
# split out so it can be exercised. A bound guard that is never asked a
# question it should answer NO to is a net with the bottom out.
_within_case_bound() {
  local _elapsed="${1:?BUG: _within_case_bound expects <elapsed>}"
  local _ceiling="${2:?BUG: _within_case_bound expects <ceiling>}"
  local _margin="${3:?BUG: _within_case_bound expects <margin>}"
  (( _elapsed <= _ceiling + _margin ))
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
# The helper text is injected into each harness body because those run in
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
# occupying a slot for the rest of its fixture's lifetime.
#
# A group id comes from the FIXTURE itself: each one records `$$` into
# ${_PGID_DIR}/<name>.pgid, and setsid made it the group leader, so its pid
# IS the group. Reading them from the directory rather than being handed one
# is what lets the single harness door below tear down whatever a case
# happened to start, without the case restating it. The single-pid fallback
# covers a userland with no setsid, where there is no group to signal.
# Signalling a pid the supervisor already reaped is a no-op here: pids are
# handed out in increasing order and a container would have to fork through
# the whole pid space between the reap and this line to hand it to a
# stranger.
_CLEANUP_FN='
_kill_group() {
  local _f="${1}" _p=""
  [ -s "${_f}" ] || return 0
  _p="$(cat "${_f}")"
  [ -n "${_p}" ] || return 0
  kill -KILL "-${_p}" 2>/dev/null || kill -KILL "${_p}" 2>/dev/null || true
}
_kill_all_groups() {
  local _f
  for _f in "${_PGID_DIR}"/*.pgid; do
    [ -e "${_f}" ] || continue
    _kill_group "${_f}"
  done
}
'

# ── the one door every case starts a process through ─────────────────
#
# _run_bounded <ceiling-seconds> <body> -- run <body> as a shell of its own
# under `timeout <ceiling>`, and make that ceiling mean what it says.
#
# TWO mechanisms, because the earlier fix used one of them and three cases
# in this file went on costing their fixtures' lifetimes anyway.
#
#   1. The body's output goes to a LOG FILE, not to the descriptor bats
#      reads this case's output from. Everything the body spawns inherits
#      that file, so no survivor -- the setsid'd service, the product's own
#      interruptible-sleep child, a grandchild the case never knew about --
#      can hold the case open after the verdict is printed. The log is
#      replayed into `${output}` afterwards, so the supervisor's own lines
#      stay in the failure report, where they are the diagnosis.
#
#   2. Whatever the body started is KILLED BY GROUP on the way out, on the
#      normal path and on the timeout path alike. This does not bound the
#      case (1 does); it bounds the LEAK, a given-up-on service occupying a
#      slot in a 32-way parallel suite for the rest of its fixture's life.
#
# Making it the ONE spelling, rather than a pattern each case repeats, is
# what a structural case at the bottom of this file enforces -- the three
# siblings that drifted away from the fixed harness drifted because there
# was nothing to drift from.
#
# It also records the ceiling for the bound guard in teardown, so a case
# cannot declare a bound and then be measured against a different one.
_run_bounded() {
  local _ceiling="${1:?BUG: _run_bounded expects a ceiling in seconds}"
  local _body="${2:?BUG: _run_bounded expects a body}"
  local _log="${TMP_DIR}/harness.log"
  : > "${_log}"
  _CASE_CEILING="${_ceiling}"
  run timeout "${_ceiling}" bash -c "{
    _PGID_DIR='${TMP_DIR}'
    ${_SYNC_FN}
    ${_CLEANUP_FN}
    trap '_kill_all_groups' EXIT
    trap '_kill_all_groups; exit 143' TERM INT
    ${_body}
  } > '${_log}' 2>&1"
  _replay_harness_log "${_log}"
}

# _replay_harness_log <log> -- put the harness's own words back into the
# bats globals the assertions read. `run` captured an empty stream (that is
# the point: nothing wrote to it), so ${output} / ${lines} come from the
# file instead -- including on the timeout path, where the body never got
# to replay them itself and the log IS the diagnosis.
_replay_harness_log() {
  local _log="${1:?BUG: _replay_harness_log expects a log path}"
  output="$(cat "${_log}" 2>/dev/null || true)"
  lines=()
  if [[ -n "${output}" ]]; then
    mapfile -t lines <<< "${output}"
  fi
}

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
  _run_bounded 30 "
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
  # Ceiling 30, not 8: the loop needs two 1s intervals plus two bounded
  # checks, so a value sized to the EXPECTED wall clock turns a loaded
  # machine into a red gate. The ceiling is here to catch a loop that never
  # terminates, and 30s catches that just as well.
  _run_bounded 30 "
    . '${WD}'
    export WATCHDOG_CHECK='false'
    _WATCHDOG_START_PERIOD=0 _WATCHDOG_INTERVAL=1 _WATCHDOG_TIMEOUT=1 _WATCHDOG_FAILURES=2
    _watchdog_exit_container() { echo ACTED-\$1; exit 0; }
    _watchdog_monitor
  "
  assert_success
  assert_output --partial "restart-container"
  assert_output --partial "ACTED-1"
}

# ── restart-service supervisor: restart-in-place + give-up (stubbed
#    child seams so the loop logic is exercised without real processes) ─

@test "restart-service supervisor restarts in place then GIVES UP loudly at MAX_RESTARTS (#797)" {
  [ "${COVERAGE:-0}" = 1 ] && skip "signal/process-timing spec runs plain under bats-fragile (#613)"
  # Ceiling 30 for the reason given on the monitor case above: it bounds a
  # non-terminating loop, it does not schedule a correct one.
  _run_bounded 30 "
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
  "
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
# setsid made this process its own group leader, so `$$` is both the pid the
# case awaits and the group the harness tears down.
echo $$ > "$1"
sleep 60
EOF
  # Ceiling 30: an unbounded wait (the pre-fix bug) hangs here. The two
  # waits inside are event-driven: a `sleep 0.5` before reading the pid
  # file is a guess, and when the guess lost the read produced an EMPTY
  # pid, `kill -0 ""` failed, and the case reported KILLED -- a green run
  # that had killed nothing. NO_PID is now its own outcome, and it is a
  # give-up path, so it goes out through the same door as the rest.
  _run_bounded 30 "
    . '${WD}'
    export _WATCHDOG_TIMEOUT=1
    _watchdog_start_service bash '${TMP_DIR}/ignore_term.sh' '${TMP_DIR}/service.pgid'
    if ! _await_file '${TMP_DIR}/service.pgid' 150; then echo NO_PID; exit 0; fi
    _pid=\"\$(cat '${TMP_DIR}/service.pgid')\"
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
# $1 -- the GRANDCHILD's pid, what this case observes.
# $2 -- this process's group id, so the harness can tear the whole subtree
#       down on a path where the product never got to.
#
# A grandchild that ignores SIGTERM and records its own pid, then the
# service itself sleeps. Both share the setsid process group.
#
# BASHPID, not $$: `$$` keeps the INVOKING shell's pid inside a
# subshell, so this line used to record the SERVICE's pid and the case
# below re-checked the process it had already stopped -- it never observed
# a grandchild at all, and stayed green with the process-group kill
# disabled. BASHPID is the subshell's own pid.
echo "$$" > "$2"
( trap '' TERM; echo "${BASHPID}" > "$1"; sleep 60 ) &
sleep 60
EOF
  # Event-driven for the same reason as the case above: losing the
  # `sleep 0.7` race read an empty grandchild pid and reported SUBTREE_DEAD
  # without having observed any subtree.
  _run_bounded 30 "
    . '${WD}'
    export _WATCHDOG_TIMEOUT=1
    _watchdog_start_service bash '${TMP_DIR}/spawner.sh' '${TMP_DIR}/grand.pid' '${TMP_DIR}/service.pgid'
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
# $1 -- this process's group id. Recorded FIRST and unconditionally: this
# fixture outlives its own case by five minutes if nothing tears it down,
# and this case's whole subject is a path where the product might not.
echo "$$" > "$1"
sleep 300
EOF
  # Real (bounded) stop_service against a wedged child; only exit_container
  # is overridden to observe that give-up REACHES it (the pre-fix unbounded
  # wait would hang stop_service so give-up never exits -> the ceiling
  # fires). 45, not 15: the ceiling bounds that hang, it does not schedule
  # the several bounded stop cycles a correct run performs.
  #
  # This is the case that measured 301s against that stated 45 with the
  # product's SIGKILL escalation disabled: `timeout` cut the harness at 45,
  # and the wedged fixture -- setsid into its own group, holding the
  # descriptor bats reads this case from -- kept it open until its own
  # `sleep 300` ended. Both halves of the door answer that: the fixture
  # never had the case's descriptor, and it is killed by group on the
  # timeout path too.
  _run_bounded 45 "
    . '${WD}'
    export WATCHDOG_CHECK='false'
    _WATCHDOG_START_PERIOD=0 _WATCHDOG_INTERVAL=1 _WATCHDOG_TIMEOUT=1 _WATCHDOG_FAILURES=1 _WATCHDOG_MAX_RESTARTS=1
    _watchdog_exit_container() { echo EXITED; exit 0; }
    _watchdog_supervise bash '${TMP_DIR}/wedged.sh' '${TMP_DIR}/service.pgid'
  "
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
_run_forward_harness() {
  local _svc="${1:?BUG: _run_forward_harness expects a service script}"
  local _ready_tenths="${2:?BUG: _run_forward_harness expects a ceiling}"
  _run_bounded 60 "
    . '${WD}'
    export WATCHDOG_CHECK='true'
    _WATCHDOG_START_PERIOD=0 _WATCHDOG_INTERVAL=30 _WATCHDOG_TIMEOUT=2 _WATCHDOG_FAILURES=3 _WATCHDOG_MAX_RESTARTS=5
    _watchdog_supervise bash '${_svc}' \
      '${TMP_DIR}/graceful.marker' '${TMP_DIR}/graceful.ready' \
      '${TMP_DIR}/service.pgid' &
    _sup=\$!
    if ! _await_file '${TMP_DIR}/graceful.ready' ${_ready_tenths}; then
      kill -KILL \${_sup} 2>/dev/null || true
      echo NOT_READY
      exit 0
    fi
    _t0=\$(date +%s)
    kill -TERM \${_sup}
    wait \${_sup} 2>/dev/null || true
    _elapsed=\$(( \$(date +%s) - _t0 ))
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
  # at once. This used to be measured by the harness's own ceiling cutting a
  # deferred run short -- i.e. by wall clock.
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
  # own 60s ceiling, which a reader takes for a hung suite rather than a
  # failed test.
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

# ── the file's own bound: nothing a case starts may outlive it ───────────

@test "a service the case gives up on cannot hold the case open past its bound (#965)" {
  [ "${COVERAGE:-0}" = 1 ] && skip "signal/process-timing spec runs plain under bats-fragile (#613)"
  # Optional on purpose, for the same reason as every other case here:
  # without setsid the service is not in its own process group, which is
  # the whole mechanism under test.
  command -v setsid >/dev/null 2>&1 \
    || skip "no setsid in this userland; the process-group teardown under test cannot be set up without it"
  # The shape every give-up path in this file has, reduced to its bones: a
  # service is started, something goes wrong, the harness prints its
  # verdict and leaves. _watchdog_start_service setsids the service into
  # its own process group, so it survives the harness -- and before the
  # door it also inherited the descriptor bats reads this case's output
  # from, so `run` sat there waiting for EOF long after the verdict was
  # printed. The case was then bounded by the FIXTURE's lifetime rather
  # than by its own ceiling: 45s measured here, and 301s on the wedged
  # give-up case against a stated bound of 45.
  cat > "${TMP_DIR}/lingering.sh" <<'EOF'
#!/usr/bin/env bash
# Records its process group and then outlives anything that waits for it.
echo "$$" > "$1"
sleep 45
EOF
  local _t0 _elapsed
  _t0="$(date +%s)"
  _run_bounded 30 "
    . '${WD}'
    export _WATCHDOG_TIMEOUT=1
    _watchdog_start_service bash '${TMP_DIR}/lingering.sh' '${TMP_DIR}/service.pgid'
    if ! _await_file '${TMP_DIR}/service.pgid' 150; then echo NO_PID; exit 0; fi
    echo GAVE_UP
  "
  _elapsed=$(( $(date +%s) - _t0 ))
  assert_success
  assert_output --partial "GAVE_UP"
  refute_output --partial "NO_PID"
  [[ "${_elapsed}" -lt 20 ]] || fail \
    "the case returned after ${_elapsed}s though it printed its verdict in about one: the service it started outlived it and is still holding the descriptor bats reads this case's output from"
}

@test "a harness that swallows its own ceiling's signal is still bounded (#965)" {
  [ "${COVERAGE:-0}" = 1 ] && skip "signal/process-timing spec runs plain under bats-fragile (#613)"
  # The other half of "the ceiling means what it says", and the half a log
  # file cannot supply. A ceiling enforced with SIGTERM alone is a REQUEST:
  # `timeout` signals and then waits for the child, so a harness that takes
  # the signal and keeps going runs for as long as it likes. Every case
  # driving _watchdog_supervise is such a harness -- the product installs
  # its own TERM handler the moment supervision starts -- and against a
  # service that ignores signals that handler unwinds into an unbounded
  # `wait`. The case that stated `timeout 45` was measured at 300s.
  #
  # Modelled here without breaking the product, in its exact shape: a child
  # that ignores the signal, and a handler that waits for it. Nothing the
  # body starts can hold the case open (the log file settles that), so what
  # this measures is the ceiling alone.
  local _t0 _elapsed
  _t0="$(date +%s)"
  _run_bounded 5 "
    ( trap '' TERM; sleep 120 ) &
    _child=\$!
    trap 'echo SWALLOWED; wait \${_child}' TERM
    wait \${_child}
  "
  _elapsed=$(( $(date +%s) - _t0 ))
  assert_failure
  [[ "${_elapsed}" -lt 30 ]] || fail \
    "the harness ran ${_elapsed}s past a 5s ceiling: it took the ceiling's SIGTERM and nothing followed it, so the number in the harness call is a suggestion"
}

@test "_within_case_bound: answers no exactly when a case outran its own ceiling (#965)" {
  # The teardown bound guard applies this to EVERY case in the file, which
  # is what makes the property survive the fourth sibling written next
  # year. A guard nothing ever exercises is a net with the bottom out, so
  # its arithmetic is pinned here rather than trusted.
  run _within_case_bound 3 30 30
  assert_success
  # The margin is inclusive: a case that legitimately runs to its own
  # ceiling on a loaded machine is not a hang.
  run _within_case_bound 60 30 30
  assert_success
  run _within_case_bound 61 30 30
  assert_failure
  # The measurement that opened this: a stated bound of 45s, 301s observed.
  run _within_case_bound 301 45 30
  assert_failure
  # A case that declared no ceiling still may not run away.
  run _within_case_bound 29 0 30
  assert_success
  run _within_case_bound 31 0 30
  assert_failure
}

@test "every process this file starts goes through the one bounded harness (#965)" {
  # Why a structural check here after deleting one from
  # spec_source_isolation_spec: that one enumerated the spellings a WRITE
  # could take, which is an open set and was wrong every round. This is the
  # closed complement -- ONE permitted spelling, in one named place -- so a
  # sibling written next year cannot start a process outside the harness
  # that bounds it, which is exactly how three siblings drifted away from
  # the harness the previous round fixed.
  local _spec="${BATS_TEST_FILENAME}"
  # Assembled from pieces so that this line cannot match the scan it runs.
  local _pat="bash[[:space:]]+-c"
  local _door _door_end _hits _hit_line
  _door="$(grep -n '^_run_bounded() {$' "${_spec}" | cut -d: -f1)"
  [[ -n "${_door}" ]] || fail \
    "this file defines no _run_bounded, so there is no single door for a case to start a process through"
  _door_end="$(awk -v s="${_door}" 'NR>=s && /^}$/ {print NR; exit}' "${_spec}")"
  _hits="$(grep -cE "${_pat}" "${_spec}" || true)"
  [[ "${_hits}" -eq 1 ]] || fail \
    "${_hits} places in this file start a shell, not 1: every case must go through _run_bounded, which is what hands the process a log file instead of the descriptor bats reads the case's output from, and what kills its process group afterwards"
  _hit_line="$(grep -nE "${_pat}" "${_spec}" | cut -d: -f1)"
  [[ "${_hit_line}" -gt "${_door}" && "${_hit_line}" -lt "${_door_end}" ]] || fail \
    "the one place that starts a shell is at line ${_hit_line}, outside _run_bounded (lines ${_door}-${_door_end})"
}
