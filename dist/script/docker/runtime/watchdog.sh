#!/usr/bin/env bash
# watchdog.sh -- generic single-service watchdog (supervised restart).
#
# Sourced from a repo's `script/entrypoint.sh` (a sibling of logging.sh),
# this helper adds a health-check-driven supervision loop for the one
# service the container runs. It is the third [lifecycle] capability base
# owns -- sibling to restart policy (#478) and init / PID1 (#792) -- and,
# like both of them, EVERY knob defaults OFF: with `WATCHDOG_CHECK` unset
# the source line is a no-op, so it is safe to drop into every entrypoint
# unconditionally (no behavior change for repos that do not opt in).
#
# What it is:
#   The app supplies a health-check COMMAND (`WATCHDOG_CHECK`) whose exit
#   status is the health signal (0 = healthy). This is what makes the
#   watchdog GENERIC -- base ships the supervision loop, the app defines
#   "healthy" (e.g. a rosnode-registration probe). After a startup grace
#   window (`WATCHDOG_START_PERIOD`) the loop runs the check every
#   `WATCHDOG_INTERVAL`s (each check bounded by `WATCHDOG_TIMEOUT`); after
#   `WATCHDOG_FAILURES` consecutive failures it takes the configured
#   failure action.
#
# Failure action (`WATCHDOG_ON_FAIL`):
#   - restart-container (DEFAULT): let the container EXIT so Docker's
#     restart policy (#478) restarts the whole container. Simplest,
#     Docker-native; Docker's own backoff absorbs restart storms (no
#     watchdog-side backoff). In this mode the entrypoint still `exec`s
#     the service as PID 2 and the watchdog runs as a background monitor
#     that, on give-up, signals PID 1 so the container tears down.
#   - restart-service: restart only the in-container service in place
#     (container stays up) -- for heavy-init containers where a full
#     container restart is expensive. The watchdog supervises the service
#     as a child, restarting it on failure and COUNTING restarts; on
#     reaching `WATCHDOG_MAX_RESTARTS` it GIVES UP with a LOUD log (never
#     silently churns), runs `WATCHDOG_NOTIFY` (if set), then falls back
#     to exiting the container (the Docker-native end state). This mode
#     relies on init / PID1 (#792) as the surviving supervisor.
#
# Logging:
#   Watchdog events (restart, give-up) are ALWAYS logged loudly to stderr
#   so `docker logs` captures them -- never silent. When a log dir is
#   configured (the [logging] local_path feature, i.e. `LOG_FILE_PATH`
#   is set), the events are ALSO written to a dedicated `watchdog.log`
#   following the #805 per-start-file + stable-symlink + retention
#   convention, reusing the shared runtime/logrotate.sh primitives. The
#   watchdog logs live in a `watchdog/` subdir of the log dir so their
#   retention never prunes the service's own per-start logs.
#
# Notification (`WATCHDOG_NOTIFY`):
#   An OPTIONAL, off-by-default pluggable command run on give-up. base
#   ships the hook point, not the destination; the operator fills in
#   delivery (a webhook, or simply appending to a log). Regardless of
#   NOTIFY, the give-up is loudly logged to stderr.
#
# Usage (downstream `script/entrypoint.sh`, after the logging helper):
#   #!/usr/bin/env bash
#   set -euo pipefail
#   # shellcheck source=/dev/null
#   . /usr/local/lib/base/logging.sh
#   # shellcheck source=/dev/null
#   . /usr/local/lib/base/watchdog.sh
#   exec "$@"
#
# The helper is COPY'd into the image at /usr/local/lib/base/watchdog.sh
# (with its siblings logging.sh / logrotate.sh) by the Dockerfile's devel
# stage, so the source line works the same at build-time and runtime.
#
# Refs: ADR-00000020 (base owns the single-service lifecycle).

# Shared glog-style rotate/symlink/prune primitives for watchdog.log.
# Sourced defensively from the sibling in-image path; a missing helper
# (partially-upgraded image) must not abort a caller under `set -e` -- the
# watchdog then logs to stderr only, without the rotated file.
_watchdog_helper_dir="${BASH_SOURCE[0]%/*}"
if [[ -r "${_watchdog_helper_dir}/logrotate.sh" ]]; then
  # shellcheck source=dist/script/docker/runtime/logrotate.sh
  . "${_watchdog_helper_dir}/logrotate.sh"
fi
unset _watchdog_helper_dir

# Defaults for every numeric knob (used when the env is unset or a
# hand-edited compose feeds a non-conforming value -- the read side
# re-validates and clamps back, so a bad value can never wedge the loop).
_WATCHDOG_DEFAULT_INTERVAL=30
_WATCHDOG_DEFAULT_TIMEOUT=10
_WATCHDOG_DEFAULT_START_PERIOD=0
_WATCHDOG_DEFAULT_FAILURES=3
_WATCHDOG_DEFAULT_MAX_RESTARTS=5

# ════════════════════════════════════════════════════════════════════
# Config
# ════════════════════════════════════════════════════════════════════

# _watchdog_enabled -- 0 iff WATCHDOG_CHECK is non-empty. The master off
# switch: an empty (or unset) check means the watchdog does nothing, so
# the source line is a safe no-op on repos that have not opted in.
_watchdog_enabled() {
  [[ -n "${WATCHDOG_CHECK:-}" ]]
}

# _watchdog_posint <value> <default> -- echo <value> when it is a positive
# integer, else <default>. Clamps a non-positive / non-numeric hand-edit.
_watchdog_posint() {
  local _v="${1-}" _d="${2:?}"
  [[ "${_v}" =~ ^[1-9][0-9]*$ ]] && { printf '%s' "${_v}"; return 0; }
  printf '%s' "${_d}"
}

# _watchdog_nonneg <value> <default> -- echo <value> when it is a
# non-negative integer (0 allowed, for the start period), else <default>.
_watchdog_nonneg() {
  local _v="${1-}" _d="${2:?}"
  [[ "${_v}" =~ ^[0-9]+$ ]] && { printf '%s' "${_v}"; return 0; }
  printf '%s' "${_d}"
}

# _watchdog_load_config -- resolve every WATCHDOG_* env into the internal
# `_WATCHDOG_*` locals with validation / clamping. ON_FAIL falls back to
# the Docker-native default (restart-container) on any unrecognised value.
_watchdog_load_config() {
  _WATCHDOG_INTERVAL="$(_watchdog_posint "${WATCHDOG_INTERVAL:-}" "${_WATCHDOG_DEFAULT_INTERVAL}")"
  _WATCHDOG_TIMEOUT="$(_watchdog_posint "${WATCHDOG_TIMEOUT:-}" "${_WATCHDOG_DEFAULT_TIMEOUT}")"
  _WATCHDOG_START_PERIOD="$(_watchdog_nonneg "${WATCHDOG_START_PERIOD:-}" "${_WATCHDOG_DEFAULT_START_PERIOD}")"
  _WATCHDOG_FAILURES="$(_watchdog_posint "${WATCHDOG_FAILURES:-}" "${_WATCHDOG_DEFAULT_FAILURES}")"
  _WATCHDOG_MAX_RESTARTS="$(_watchdog_posint "${WATCHDOG_MAX_RESTARTS:-}" "${_WATCHDOG_DEFAULT_MAX_RESTARTS}")"
  case "${WATCHDOG_ON_FAIL:-}" in
    restart-service) _WATCHDOG_ON_FAIL="restart-service" ;;
    *)               _WATCHDOG_ON_FAIL="restart-container" ;;
  esac
}

# ════════════════════════════════════════════════════════════════════
# Logging
# ════════════════════════════════════════════════════════════════════

# _watchdog_log_setup -- when a log dir is configured (LOG_FILE_PATH set),
# create a per-start watchdog file `<logdir>/watchdog/watchdog_<ts>.log`,
# repoint the stable `watchdog.log` symlink at it, and prune old per-start
# files by keep-count AND age (the #805 convention). The watchdog logs
# live in their own `watchdog/` subdir so pruning them never touches the
# service's per-start logs (the shared-dir pooled-keep limitation of
# logrotate.sh). Best-effort: any failure degrades to stderr-only logging.
_watchdog_log_setup() {
  _WATCHDOG_LOG_FILE=""
  local _link="${LOG_FILE_PATH:-}"
  [[ -z "${_link}" ]] && return 0
  local _dir
  _dir="$(dirname -- "${_link}")/watchdog"
  mkdir -p -- "${_dir}" 2>/dev/null || return 0
  local _ts
  _ts="$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || printf 'unknown')"
  local _real="${_dir}/watchdog_${_ts}.log"
  local _seq=1
  while [[ -e "${_real}" ]]; do
    _real="${_dir}/watchdog_${_ts}-${_seq}.log"
    _seq=$(( _seq + 1 ))
  done
  : > "${_real}" 2>/dev/null || return 0
  _WATCHDOG_LOG_FILE="${_real}"
  if declare -F _logrotate_repoint >/dev/null 2>&1; then
    _logrotate_repoint "${_real}" "watchdog.log"
  fi
  if declare -F _logrotate_prune >/dev/null 2>&1; then
    local _keep="${CONTAINER_LOG_KEEP:-20}" _days="${CONTAINER_LOG_DAYS:-14}"
    [[ "${_keep}" =~ ^[1-9][0-9]*$ ]] || _keep=20
    [[ "${_days}" =~ ^[1-9][0-9]*$ ]] || _days=14
    _logrotate_prune "${_dir}" "watchdog.log" "${_keep}" "${_days}"
  fi
}

# _watchdog_log <level> <message> -- loud stderr line (captured by
# `docker logs`) plus, when configured, an append to the per-start
# watchdog.log. Never silent.
_watchdog_log() {
  local _level="${1:-INFO}" _msg="${2-}"
  local _ts
  _ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf 'unknown')"
  local _line="[watchdog] ${_ts} ${_level}: ${_msg}"
  printf '%s\n' "${_line}" >&2
  [[ -n "${_WATCHDOG_LOG_FILE:-}" ]] || return 0
  printf '%s\n' "${_line}" >> "${_WATCHDOG_LOG_FILE}" 2>/dev/null || true
}

# ════════════════════════════════════════════════════════════════════
# Health check + notify (both pluggable)
# ════════════════════════════════════════════════════════════════════

# _watchdog_run_check -- run WATCHDOG_CHECK bounded by WATCHDOG_TIMEOUT;
# its exit status IS the health signal (0 = healthy). A timeout resolves
# to non-zero (unhealthy), as does any missing-command / crash.
_watchdog_run_check() {
  local _t="${_WATCHDOG_TIMEOUT:-${_WATCHDOG_DEFAULT_TIMEOUT}}"
  if command -v timeout >/dev/null 2>&1; then
    timeout "${_t}" bash -c "${WATCHDOG_CHECK}"
  else
    bash -c "${WATCHDOG_CHECK}"
  fi
}

# _watchdog_notify -- run the optional WATCHDOG_NOTIFY command on give-up.
# No-op (and never fatal) when unset; failures are swallowed so a broken
# notifier can't block the container's Docker-native teardown.
_watchdog_notify() {
  [[ -n "${WATCHDOG_NOTIFY:-}" ]] || return 0
  bash -c "${WATCHDOG_NOTIFY}" || true
}

# _watchdog_evaluate <counter_nameref> -- run one health check, update the
# consecutive-failure <counter>, and classify the result:
#   0 = healthy           (counter reset to 0)
#   1 = unhealthy, under the WATCHDOG_FAILURES threshold (counter++)
#   2 = unhealthy AND the threshold reached (caller should act)
# The single decision seam both failure-action loops share.
_watchdog_evaluate() {
  local -n _wd_ctr="$1"
  if _watchdog_run_check; then
    _wd_ctr=0
    return 0
  fi
  _wd_ctr=$(( _wd_ctr + 1 ))
  (( _wd_ctr >= ${_WATCHDOG_FAILURES:-${_WATCHDOG_DEFAULT_FAILURES}} )) && return 2
  return 1
}

# _watchdog_should_give_up <restarts_so_far> -- 0 when the restart-service
# ceiling (WATCHDOG_MAX_RESTARTS) has been reached. The give-up boundary.
_watchdog_should_give_up() {
  local _r="${1:-0}"
  (( _r >= ${_WATCHDOG_MAX_RESTARTS:-${_WATCHDOG_DEFAULT_MAX_RESTARTS}} ))
}

# ════════════════════════════════════════════════════════════════════
# Terminal actions (overridable seams -- unit tests replace them)
# ════════════════════════════════════════════════════════════════════

# _watchdog_exit_container <code> -- end the container so Docker's restart
# policy takes over. Signals PID 1 (the init) so tini tears the whole
# container down cleanly, then exits this process. Best-effort on the
# signal so a restricted environment still exits.
_watchdog_exit_container() {
  local _code="${1:-1}"
  kill -TERM 1 2>/dev/null || true
  exit "${_code}"
}

# ── restart-service child management ─────────────────────────────────

# _watchdog_start_service <cmd...> -- launch the supervised service as a
# background child and record its PID in _WATCHDOG_CHILD_PID.
_watchdog_start_service() {
  "$@" &
  _WATCHDOG_CHILD_PID=$!
}

# _watchdog_child_alive -- 0 while the supervised child is still running.
_watchdog_child_alive() {
  [[ -n "${_WATCHDOG_CHILD_PID:-}" ]] || return 1
  kill -0 "${_WATCHDOG_CHILD_PID}" 2>/dev/null
}

# _watchdog_stop_service -- terminate the current supervised child (if any).
_watchdog_stop_service() {
  [[ -n "${_WATCHDOG_CHILD_PID:-}" ]] || return 0
  kill -TERM "${_WATCHDOG_CHILD_PID}" 2>/dev/null || true
  wait "${_WATCHDOG_CHILD_PID}" 2>/dev/null || true
  _WATCHDOG_CHILD_PID=""
}

# _watchdog_restart_service <cmd...> -- stop the current child, start a
# fresh one. In-place service restart (the container stays up).
_watchdog_restart_service() {
  _watchdog_stop_service
  _watchdog_start_service "$@"
}

# _watchdog_give_up -- restart-service ceiling reached: log loudly, run
# the notify hook, stop the service, and fall back to exiting the
# container (Docker-native end state). Never silent.
_watchdog_give_up() {
  _watchdog_log ERROR "GIVING UP: reached WATCHDOG_MAX_RESTARTS=${_WATCHDOG_MAX_RESTARTS} in-place restart attempts; running notify (if set) then exiting the container so Docker's restart policy decides the end state (check: ${WATCHDOG_CHECK})"
  _watchdog_notify
  _watchdog_stop_service
  _watchdog_exit_container 1
}

# ════════════════════════════════════════════════════════════════════
# Supervision loops
# ════════════════════════════════════════════════════════════════════

# _watchdog_monitor -- restart-container loop. Runs as a background child
# while the entrypoint `exec`s the real service as PID 2. After the start
# period, checks health every interval; on reaching the failure threshold
# it logs loudly and exits the container so Docker restarts the whole
# container (no watchdog-side backoff -- Docker's restart policy owns it).
_watchdog_monitor() {
  local _ctr=0 _rc
  sleep "${_WATCHDOG_START_PERIOD}"
  while : ; do
    sleep "${_WATCHDOG_INTERVAL}"
    _rc=0
    _watchdog_evaluate _ctr || _rc=$?
    if (( _rc == 2 )); then
      _watchdog_log WARN "health check failed ${_ctr} consecutive time(s) (threshold ${_WATCHDOG_FAILURES}); action=restart-container -- exiting the container so Docker's restart policy restarts it (check: ${WATCHDOG_CHECK})"
      _watchdog_exit_container 1
    fi
  done
}

# _watchdog_supervise <cmd...> -- restart-service loop. The watchdog owns
# the service lifecycle: it launches the service as a child, checks health
# every interval after the start period, and on the failure threshold (or
# the child dying) restarts the service in place, counting restarts. On
# reaching WATCHDOG_MAX_RESTARTS it gives up (loud log + notify + container
# exit). Never returns -- the entrypoint's own `exec` is not reached.
_watchdog_supervise() {
  local _restarts=0 _ctr=0 _rc
  _watchdog_start_service "$@"
  sleep "${_WATCHDOG_START_PERIOD}"
  while : ; do
    sleep "${_WATCHDOG_INTERVAL}"
    if ! _watchdog_child_alive; then
      _rc=2
    else
      _rc=0
      _watchdog_evaluate _ctr || _rc=$?
    fi
    if (( _rc == 2 )); then
      _ctr=0
      if _watchdog_should_give_up "${_restarts}"; then
        _watchdog_give_up
      fi
      _restarts=$(( _restarts + 1 ))
      _watchdog_log WARN "health check failed (threshold ${_WATCHDOG_FAILURES}); action=restart-service -- restarting the in-container service in place (restart ${_restarts}/${_WATCHDOG_MAX_RESTARTS}) (check: ${WATCHDOG_CHECK})"
      _watchdog_restart_service "$@"
    fi
  done
}

# ════════════════════════════════════════════════════════════════════
# Entry
# ════════════════════════════════════════════════════════════════════

# _watchdog_main <cmd...> -- the source-time entry. No-op (returns 0) when
# disabled so the entrypoint proceeds to its own `exec "$@"`. For
# restart-container it forks the background monitor and returns (the
# entrypoint execs the service). For restart-service it takes over: it
# supervises the service itself and never returns.
_watchdog_main() {
  _watchdog_enabled || return 0
  _watchdog_load_config
  _watchdog_log_setup
  if [[ "${_WATCHDOG_ON_FAIL}" == "restart-service" ]]; then
    _watchdog_log INFO "enabled (restart-service): supervising the service in place; interval=${_WATCHDOG_INTERVAL}s timeout=${_WATCHDOG_TIMEOUT}s start_period=${_WATCHDOG_START_PERIOD}s failures=${_WATCHDOG_FAILURES} max_restarts=${_WATCHDOG_MAX_RESTARTS}"
    _watchdog_supervise "$@"
    # _watchdog_supervise never returns; the entrypoint's exec is bypassed.
  else
    _watchdog_log INFO "enabled (restart-container): monitoring health; interval=${_WATCHDOG_INTERVAL}s timeout=${_WATCHDOG_TIMEOUT}s start_period=${_WATCHDOG_START_PERIOD}s failures=${_WATCHDOG_FAILURES}"
    _watchdog_monitor &
    disown 2>/dev/null || true
  fi
  return 0
}

_watchdog_main "$@"
