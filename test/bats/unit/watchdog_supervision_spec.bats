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

# How long `timeout` waits after its own SIGTERM before sending SIGKILL.
# Without it a ceiling is a REQUEST: the product installs its own TERM
# handler and then blocks in an unbounded `wait` on a service that ignores
# signals, so `timeout` sends TERM at the ceiling and then waits for a child
# that will not die -- 300s measured against a stated 45. The 5s is the
# grace for a harness that IS going to unwind and wants to say why.
readonly _CASE_KILL_AFTER=5

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
  _kill_case_groups
  rm -rf "${TMP_DIR}"
  _within_case_bound "${_elapsed}" "${_CASE_CEILING}" "${_CASE_BOUND_MARGIN}" || fail \
    "this case returned after ${_elapsed}s, past the ${_CASE_CEILING}s ceiling its own harness declared (+${_CASE_BOUND_MARGIN}s margin): either something it started outlived it holding the descriptor bats reads its output from, or the harness itself took the ceiling's signal and kept running"
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

# _reap_child <pid> -- the outcome of a child THIS case started, into
# _CHILD_STATUS: 0 when it ran to completion, 128+N when a signal ended it.
#
# It is a rendezvous, not a glance, and that is the point. `kill -0` was
# here and it is not an oracle: it answers "alive" for a process that has
# been sent SIGKILL and has not yet been scheduled to die, and again for one
# that has died and has not yet been reaped. Either way a case asking it
# immediately after the signal reads ALIVE and passes while the property it
# names is broken -- measured at three greens in eight runs. `wait` returns
# the status ONCE, whenever the child gets there, so a loaded machine costs
# latency and never a verdict.
#
# The status goes into a global rather than onto stdout because `wait` only
# works on children of the CALLING shell: a command substitution or bats'
# own `run` would ask a subshell about a child it does not have.
_reap_child() {
  local _pid="${1:?BUG: _reap_child expects a pid}"
  _CHILD_STATUS=0
  wait "${_pid}" || _CHILD_STATUS=$?
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
_proc_gone() {
  local _pid="${1}" _stat _rest
  kill -0 "${_pid}" 2>/dev/null || return 0
  # An exited process nobody has reaped still answers the glance above. It
  # is not running: it holds a pid and nothing else, and whether its parent
  # ever calls wait is a scheduling accident. The product says the same
  # thing in _watchdog_child_alive for the same reason.
  #
  # The state is the field after the command name, which is parenthesised
  # and may itself contain spaces, so the parse strips through the closing
  # bracket rather than counting fields. Double quotes throughout: this
  # whole helper is injected as a single-quoted string.
  _stat="$(cat "/proc/${_pid}/stat" 2>/dev/null)" || return 0
  _rest="${_stat##*") "}"
  [ "${_rest%% *}" = "Z" ]
}
_await_gone() {
  local _pid="${1}" _n="${2:-100}" _i=0
  while [ "${_i}" -lt "${_n}" ]; do
    _proc_gone "${_pid}" && return 0
    sleep 0.1
    _i=$(( _i + 1 ))
  done
  return 1
}
'

# _kill_case_groups -- take down whatever this case STARTED. Killing the
# harness shell does not: _watchdog_start_service setsids the service into
# its own process group, so it outlives its parent and, in a 32-way parallel
# suite, goes on occupying a slot for the rest of its fixture's lifetime.
#
# It runs HERE, in the bats shell, rather than from a trap inside the
# harness -- which is where it was first put, and why that did not work.
# Two independent reasons, both measured: the product installs its OWN TERM
# handler the moment `_watchdog_supervise` starts, overwriting any trap the
# harness set; and a harness that has to be SIGKILLed to honour its ceiling
# never runs a trap at all. Teardown runs whatever happened.
#
# A group id comes from the FIXTURE itself: each one records `$$` into
# ${TMP_DIR}/<name>.pgid, and setsid made it the group leader, so its pid IS
# the group. Reading them from the directory rather than being handed one is
# what lets this cover whatever a case happened to start, without the case
# restating it.
#
# ONLY ever a group, never a bare pid. By the time this runs the product has
# usually already reaped the service, so "the id names nothing" is the
# common path -- and a container running 32 jobs forks hard enough that the
# id can by then belong to a stranger in another job. Requiring the target
# to be a GROUP is what makes that safe: only a process that called setsid
# leads one, and every case that records an id skips where there is no
# setsid, so a single-pid fallback would have covered nothing and could have
# hit anything. The `kill -0` first narrows it further, from "the id was
# recorded at some point during this case" to the instant of the signal.
_kill_case_groups() {
  local _f _p
  for _f in "${TMP_DIR}"/*.pgid; do
    [[ -e "${_f}" ]] || continue
    _p="$(cat "${_f}" 2>/dev/null || true)"
    [[ -n "${_p}" ]] || continue
    kill -0 "-${_p}" 2>/dev/null || continue
    kill -KILL "-${_p}" 2>/dev/null || true
  done
}

# ── the one door every case starts a process through ─────────────────
#
# _run_bounded <ceiling-seconds> <body> -- run <body> as a shell of its own
# under `timeout <ceiling>`, and make that ceiling mean what it says.
#
# TWO mechanisms, and a case in this file needed BOTH -- which is why the
# earlier round, which shipped one of them in one place, left three siblings
# still costing their fixtures' lifetimes.
#
#   1. The body's output goes to a LOG FILE, not to the descriptor bats
#      reads this case's output from. Everything the body spawns inherits
#      that file, so no survivor -- the setsid'd service, the product's own
#      interruptible-sleep child, a grandchild the case never knew about --
#      can hold the case open after the verdict is printed. Measured on its
#      own: without this a case that printed its verdict in about a second
#      returned after 45, its fixture's whole lifetime.
#
#   2. `--kill-after`, because a bare ceiling is a REQUEST, not a bound.
#      `timeout` sends SIGTERM and then waits for the child; the product
#      installs its own SIGTERM handler as soon as `_watchdog_supervise`
#      starts and, against a service that ignores signals, unwinds into an
#      unbounded `wait`. Measured on its own: 300s against a stated 45, with
#      1 already in place. SIGKILL after a 5s grace ends it.
#
# The log is replayed into `${output}` afterwards -- including on the
# timeout path, where the body never got to say anything itself and the
# supervisor's own lines ARE the diagnosis.
#
# What is NOT here: the process-group teardown. It was, and it did not run
# -- the product's TERM trap displaces the harness's, and a SIGKILLed shell
# runs no trap at all. It lives in `teardown` now, which runs whatever
# happened to the harness.
#
# Making this the ONE spelling, rather than a pattern each case repeats, is
# what a structural case at the bottom of this file enforces -- the three
# siblings that drifted away from the previous round's harness drifted
# because there was nothing to drift from.
#
# It also records the ceiling for the bound guard in teardown, so a case
# cannot declare a bound and then be measured against a different one.
_run_bounded() {
  local _ceiling="${1:?BUG: _run_bounded expects a ceiling in seconds}"
  local _body="${2:?BUG: _run_bounded expects a body}"
  local _log="${TMP_DIR}/harness.log"
  : > "${_log}"
  _CASE_CEILING="${_ceiling}"
  run timeout --kill-after="${_CASE_KILL_AFTER}" "${_ceiling}" bash -c "{
    ${_SYNC_FN}
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
  #
  # That question goes through _proc_gone, not through a bare `kill -0`.
  # This is the direction where the unsound glance costs a FALSE GREEN: a
  # monitor that crashed and has not been reaped still answers the glance,
  # so the vacuity check the window ends with would report the crash as
  # "still deferring" and the case would pass having observed nothing.
  _run_bounded 30 "
    . '${WD}'
    export WATCHDOG_CHECK='false'
    _WATCHDOG_START_PERIOD=30 _WATCHDOG_INTERVAL=1 _WATCHDOG_TIMEOUT=1 _WATCHDOG_FAILURES=1
    _watchdog_exit_container() { echo ACTED; exit 0; }
    ( _watchdog_monitor ) &
    _pid=\$!
    sleep 2
    if _proc_gone \${_pid}; then echo MONITOR_GONE; else echo STILL_DEFERRING; fi
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

# ── the group-signalling invariant the graceful stop depends on ──────

@test "_watchdog_start_service group-signals even when the pgid is read before setsid takes (#797)" {
  [ "${COVERAGE:-0}" = 1 ] && skip "signal/process-timing spec runs plain under bats-fragile (#613)"
  command -v setsid >/dev/null 2>&1 \
    || skip "no setsid in this userland; there is no separate process group to detect"
  # A load-sensitive PRODUCT race, and the mechanism behind the NO_SIGNAL
  # sighting this issue was opened for. `setsid cmd &` returns as soon as
  # the fork happens; the child has not necessarily called setsid() yet, so
  # its process group is still the SUPERVISOR's at that instant. The pgid
  # was sampled once, right there, and when the sample lost the race the
  # supervisor silently fell back to signalling the bare child pid for the
  # rest of that service's life.
  #
  # That fallback is not a small degradation. A service whose shell is
  # sitting in a foreground command does not run its SIGTERM trap until
  # that command returns, and the command only returns because the GROUP
  # signal reached it too. Signal the pid alone and the trap is deferred,
  # the stop grace expires, and a service that handles SIGTERM correctly is
  # SIGKILLed instead -- reported by the case below as NO_SIGNAL, i.e. as a
  # supervisor that did not forward the signal.
  #
  # Measured on a deliberately loaded machine before the fix: 3 of 40
  # starts fell back, and the forward case failed 3 runs in 8.
  #
  # The race is modelled deterministically instead of being waited for: the
  # first pgid read answers with the SUPERVISOR's group, exactly as it does
  # when the child has not called setsid() yet, and every read after it
  # tells the truth. The "first" is marked with a FILE rather than a
  # counter: each read happens inside a command substitution, so a variable
  # would be incremented in a subshell and every read would be the first.
  _run_bounded 30 "
    . '${WD}'
    eval \"_watchdog_pgid_of_real() \$(declare -f _watchdog_pgid_of | tail -n +2)\"
    _watchdog_pgid_of() {
      if [ -e '${TMP_DIR}/pgid_read_once' ]; then
        _watchdog_pgid_of_real \"\$1\"
      else
        : > '${TMP_DIR}/pgid_read_once'
        _watchdog_pgid_of_real \$\$
      fi
    }
    _watchdog_start_service sleep 5
    echo PGKILL=\${_WATCHDOG_USE_PGKILL}
    kill -KILL \${_WATCHDOG_CHILD_PID} 2>/dev/null || true
  "
  assert_success
  assert_output --partial "PGKILL=1"
  refute_output --partial "PGKILL=0"
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
  # product's SIGKILL escalation disabled, and the one that showed a
  # ceiling alone is not a bound: `timeout` sent its SIGTERM at 45s, the
  # supervisor's own handler took it, and stop_service unwound into an
  # unbounded `wait` on a service that ignores signals -- so `timeout` sat
  # waiting for a child that would not die until `sleep 300` ended. It now
  # returns at the ceiling plus the kill grace, and the group the fixture
  # left behind is torn down in teardown.
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
  # than by its own ceiling: 45s measured here against a 30s ceiling, with
  # the harness shell long gone. This case isolates that half; the wedged
  # give-up case above isolates the other.
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

@test "_kill_case_groups: never signals a bare pid, only a process GROUP (#965)" {
  # The hazard in a teardown that runs for every case. By the time it runs,
  # the product has usually already reaped the service, so the recorded id
  # names nothing -- and a container running 32 jobs forks hard enough that
  # the id can by then belong to a stranger in another job. A group id can
  # only be reused by a process that called setsid, and every case that
  # records one skips without setsid, so the bare-pid fallback covered
  # nothing and could hit anything.
  #
  # The fixture is a plain background child: alive, in THIS shell's process
  # group, not a group leader. Nothing may happen to it.
  #
  # The oracle is the child's EXIT STATUS, not `kill -0`, and that is the
  # whole soundness of this case. `kill -0` answers a question about an
  # INSTANT, and both ways this fixture can be dead answer "alive" for a
  # while: a process that has been sent SIGKILL but not yet scheduled to
  # die, and one that has died and not yet been reaped. Against a harness
  # that DID signal the bare pid, that spelling was green three runs in
  # eight -- a coin, not a witness. `wait` is a rendezvous: it returns the
  # status once, whenever the child gets there, so the verdict does not
  # depend on how loaded the machine is.
  sleep 2 &
  local _victim=$!
  printf '%s\n' "${_victim}" > "${TMP_DIR}/stale.pgid"
  _kill_case_groups
  _reap_child "${_victim}"
  [[ "${_CHILD_STATUS}" -eq 0 ]] || fail \
    "_kill_case_groups signalled a pid that leads no process group: the child reported ${_CHILD_STATUS} (137 = SIGKILL, 143 = SIGTERM) instead of running to completion. After a case whose service the product already reaped, that id can belong to another job in the same container"
}

@test "_await_gone: a killed process nobody has reaped is GONE, not still alive (#965)" {
  [ "${COVERAGE:-0}" = 1 ] && skip "signal/process-timing spec runs plain under bats-fragile (#613)"
  # The same unsound oracle as the bare-pid case, in the helper every
  # subtree case settles its verdict with. `kill -0` answers ALIVE for a
  # process that has exited and not been reaped, and that is not a corner:
  # it is precisely what the subtree case produces. The whole group is
  # SIGKILLed, so the grandchild's parent dies too and nobody is left to
  # wait for it -- the grandchild holds a pid and nothing else. Whether
  # anything gets round to reaping it inside ten seconds is a scheduling
  # accident, which is why that case reported ORPHAN_ALIVE on a full gate
  # run with a correct product underneath it.
  #
  # The fixture makes the state deterministic instead of waiting for it:
  # `exec` replaces the shell with a `sleep`, so the child it started a
  # moment earlier stays in state Z for as long as that sleep lives,
  # because its parent can never call wait.
  cat > "${TMP_DIR}/zombie_maker.sh" <<'EOF'
#!/usr/bin/env bash
# $1 -- where to record the pid that is about to become a zombie.
sleep 0.1 &
echo $! > "$1"
exec sleep 10
EOF
  _run_bounded 30 "
    bash '${TMP_DIR}/zombie_maker.sh' '${TMP_DIR}/zombie.pid' &
    if ! _await_file '${TMP_DIR}/zombie.pid' 100; then echo NO_PID; exit 0; fi
    sleep 1
    echo RECORDED
  "
  assert_success
  assert_output --partial "RECORDED"
  local _zombie
  _zombie="$(cat "${TMP_DIR}/zombie.pid")"
  # The premise, asserted rather than assumed: this pid still answers the
  # glance. Without that, the case below would pass against a helper that
  # is right for the wrong reason.
  kill -0 "${_zombie}" 2>/dev/null || fail \
    "the fixture pid ${_zombie} was reaped before the case could ask about it, so there is no unreaped process here to test the helper against"
  # The helpers are defined inside the harness text because that is where
  # they run; evaluated here so the case can ask one directly.
  eval "${_SYNC_FN}"
  # The predicate first, in both directions: an unreaped pid is gone, and a
  # process that is genuinely running is not. Without the second half this
  # would pass against a predicate that calls everything gone -- which in
  # the deferral case above, where the question is asked the other way
  # round, is a FALSE GREEN rather than a false red.
  _proc_gone "${_zombie}" || fail \
    "_proc_gone calls an exited, unreaped process alive"
  sleep 30 &
  local _live=$!
  ! _proc_gone "${_live}" || fail \
    "_proc_gone calls a running process gone, which turns the vacuity check in the deferral case into a green that observed nothing"
  kill "${_live}" 2>/dev/null || true
  _reap_child "${_live}"
  _await_gone "${_zombie}" 1 || fail \
    "_await_gone calls an exited, unreaped process alive: every subtree case in this file then reports ORPHAN_ALIVE whenever the reap happens to be late, which is a verdict about the machine's load and not about the product"
}

@test "_reap_child: a killed child and a completed one report DIFFERENT statuses (#965)" {
  # The oracle the case above settles its verdict with, exercised in both
  # directions. An oracle that answers the same thing either way witnesses
  # nothing, which is exactly what `kill -0` did here: it said ALIVE for a
  # child that had just been SIGKILLed, so the case passed while the
  # property it names was broken.
  sleep 30 &
  local _doomed=$!
  kill -KILL "${_doomed}" 2>/dev/null || true
  _reap_child "${_doomed}"
  [[ "${_CHILD_STATUS}" -eq 137 ]] || fail \
    "a SIGKILLed child reported ${_CHILD_STATUS}, not 137: this oracle cannot see the outcome the case above exists to rule out"
  sleep 0.2 &
  local _fine=$!
  _reap_child "${_fine}"
  [[ "${_CHILD_STATUS}" -eq 0 ]] || fail \
    "a child that ran to completion reported ${_CHILD_STATUS}, not 0: this oracle would call every untouched fixture killed"
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

@test "every SHELL this file starts is started inside the one bounded harness (#965)" {
  # Narrowed on purpose, and the narrowing is the point. This does NOT say
  # "every process this file starts": two cases above start a plain
  # background `sleep` deliberately, and a line-wise scan cannot see a
  # `bash` split across a continuation line, a command name held in a
  # variable, or an alias -- the same three holes the comparison scan next
  # door discloses. Measured: a sibling spelled `bash \` + newline + `-c`
  # walks straight past this case.
  #
  # THE REAL NET IS NOT THIS CASE. It is the bound guard in teardown, which
  # measures every case against the ceiling its own harness declared and so
  # holds for a sibling written in a spelling nothing here anticipated --
  # the same continuation-line sibling that evades the scan is caught there,
  # at 45s against a declared 0.
  #
  # What this case adds on top of that net is WHERE: the bound guard says a
  # case ran too long, this says which line drifted, at the moment it is
  # written rather than the first time it hangs. It is a closed claim about
  # ONE spelling in ONE named place, not an open claim about processes.
  local _spec="${BATS_TEST_FILENAME}"
  # Assembled from pieces, and every fixture below builds its shell name
  # from a printf ARGUMENT, so that no line of this file can match the scan
  # it runs and fail the invariant on its own source.
  # `\b(ba)?sh`: the word boundary is what keeps this off `dash` and off
  # any other name ending in sh, while covering the two spellings that
  # actually start a shell here.
  local _pat="\\b(ba)?sh[[:space:]]+-c"
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

  # The scan has to see both spellings of "start a shell" it claims to
  # cover: plain `sh` with the same flag starts one just as well, and
  # against the busybox userland this suite runs on it is the shorter thing
  # to type. Spelled around the pattern here, like the pattern itself, so
  # this comment is not a second hit.
  local _shell _fixture
  for _shell in bash sh; do
    _fixture="${BATS_TEST_TMPDIR}/starts_a_${_shell}"
    printf '  run timeout 5 %s -c "true"\n' "${_shell}" > "${_fixture}"
    grep -qE "${_pat}" "${_fixture}" || fail \
      "the scan does not see \`${_shell} -c\`, so a case starting one outside _run_bounded would leave this invariant green while its process holds the case open for its fixture's lifetime"
  done
}
