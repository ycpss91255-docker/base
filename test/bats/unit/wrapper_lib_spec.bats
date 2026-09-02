#!/usr/bin/env bats
#
# wrapper_lib_spec.bats - unit tests for the wrapper-runtime module
# dist/script/docker/lib/wrapper.sh.
#
# The runtime hoists the cross-cutting surfaces the 5 docker wrappers
# (build / run / exec / stop / prune) used to duplicate: the _msg
# dispatcher, the --lang pre-pass, and the build/run setup/drift
# orchestration. These tests exercise each helper in isolation -- sourced
# directly (not through a wrapper) so the bash branches run and kcov can
# attribute coverage -- AND assert the "called from each of the 5
# wrappers" parameterisation (verb-derived log tags, per-verb message
# tables).

bats_require_minimum_version 1.5.0

LIB="/source/dist/script/docker/lib"

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC2154
  TEMP_DIR="$(mktemp -d)"
  export TEMP_DIR
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# ── _msg dispatcher ─────────────────────────────────────────────────────────

@test "_msg dispatches <category> <key> to _msg_<category> (#565)" {
  run bash -c "
    source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh
    _LANG=en
    _msg_errors() { case \"\${_LANG}:\$1\" in *:no_env) echo 'no env here';; esac; }
    _msg errors no_env
  "
  assert_success
  assert_output "no env here"
}

@test "_msg reads the global _LANG for locale selection (#565)" {
  run bash -c "
    source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh
    _LANG=ja
    _msg_errors() { case \"\${_LANG}:\$1\" in ja:no_env) echo 'JP';; *:no_env) echo 'EN';; esac; }
    _msg errors no_env
  "
  assert_success
  assert_output "JP"
}

@test "_msg errors when category is missing (#565)" {
  run bash -c "source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh; _msg"
  assert_failure
  assert_output --partial "requires category"
}

@test "_msg errors when key is missing (#565)" {
  run bash -c "source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh; _msg errors"
  assert_failure
  assert_output --partial "requires key"
}

# ── _wrapper_lang_prepass ───────────────────────────────────────────────────

@test "_wrapper_lang_prepass sets _LANG from --lang (#565, #222)" {
  run bash -c "
    source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh
    _LANG=en
    _wrapper_lang_prepass build --help --lang zh-TW
    echo \"\${_LANG}\"
  "
  assert_success
  assert_output "zh-TW"
}

@test "_wrapper_lang_prepass finds --lang even when it is not first (#565, #222)" {
  run bash -c "
    source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh
    _LANG=en
    _wrapper_lang_prepass run -d --lang ja -- somecmd
    echo \"\${_LANG}\"
  "
  assert_success
  assert_output "ja"
}

@test "_wrapper_lang_prepass leaves _LANG untouched when no --lang given (#565)" {
  run bash -c "
    source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh
    _LANG=en
    _wrapper_lang_prepass stop --prune --dry-run
    echo \"\${_LANG}\"
  "
  assert_success
  assert_output "en"
}

@test "_wrapper_lang_prepass falls back to 'en' on an unsupported --lang value (#565)" {
  # _sanitize_lang warns + rewrites to en; the verb appears in the warning.
  run bash -c "
    source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh
    LANG=en_US.UTF-8 _LANG=en
    _wrapper_lang_prepass prune --lang klingon
    echo \"LANG=\${_LANG}\"
  "
  assert_success
  assert_output --partial "LANG=en"
  assert_output --partial "[prune]"
}

@test "_wrapper_lang_prepass requires a verb argument (#565)" {
  run bash -c "source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh; _wrapper_lang_prepass"
  assert_failure
  assert_output --partial "requires verb"
}

# Parameterisation: each of the 5 wrappers passes its own verb through to
# _sanitize_lang, so the unsupported-value warning is tagged per wrapper.
@test "_wrapper_lang_prepass threads each wrapper's verb into the warning (#565)" {
  local _v
  for _v in build run exec stop prune; do
    run bash -c "
      source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh
      LANG=en_US.UTF-8 _LANG=en
      _wrapper_lang_prepass ${_v} --lang nope
    "
    assert_success
    assert_output --partial "[${_v}]"
  done
}

# ── _wrapper_setup_sync ─────────────────────────────────────────────────────
#
# Build a minimal sandbox with a mock setup.sh so the orchestration runs
# end-to-end without docker. The mock records its invocation and writes
# .env.generated + compose.yaml on `apply`.

_make_setup_sandbox() {
  local _root="$1"
  mkdir -p "${_root}/.base/dist/script/docker/wrapper" \
           "${_root}/config/docker"
  export SETUP_LOG="${TEMP_DIR}/setup.log"
  : > "${SETUP_LOG}"
  cat > "${_root}/.base/dist/script/docker/wrapper/setup.sh" <<EOS
#!/usr/bin/env bash
set -euo pipefail
_subcmd="apply"
case "\${1:-}" in
  check-drift) _subcmd="check-drift"; shift ;;
  apply)       shift ;;
esac
_base=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --base-path) _base="\$2"; shift 2 ;;
    --lang)      shift 2 ;;
    *)           shift ;;
  esac
done
case "\${_subcmd}" in
  check-drift) exit "\${MOCK_DRIFT_RC:-0}" ;;
  apply)
    printf 'apply base=%s\n' "\${_base}" >> "${SETUP_LOG}"
    {
      echo "USER_NAME=tester"
      echo "IMAGE_NAME=mockimg"
      echo "DOCKER_HUB_USER=mockuser"
    } > "\${_base}/.env.generated"
    echo "# mock compose" > "\${_base}/compose.yaml"
    ;;
esac
EOS
  chmod +x "${_root}/.base/dist/script/docker/wrapper/setup.sh"
}

# Run _wrapper_setup_sync for a given verb in a fresh subshell against a
# sandbox at $1. Extra env (RUN_SETUP, MOCK_DRIFT_RC, ...) is inherited.
_run_setup_sync() {
  local _root="$1" _verb="$2"
  run bash -c "
    source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh
    _LANG=en
    FILE_PATH='${_root}'
    RUN_SETUP=\${RUN_SETUP:-false}
    declare -a SETUP_FORWARD_ARGS=()
    # Per-verb message tables the orchestration calls.
    _msg_bootstrap() { echo 'First run'; }
    _msg_drift()     { echo 'regen drift'; }
    _msg_errors()    { case \"\$1\" in no_env) echo 'no env';; rerun_setup) echo 'rerun';; esac; }
    _wrapper_setup_sync ${_verb}
    echo 'SYNC_OK'
  "
}

@test "_wrapper_setup_sync bootstraps via setup.sh when .env is missing (#565)" {
  local R="${TEMP_DIR}/repo"
  _make_setup_sandbox "${R}"
  _run_setup_sync "${R}" build
  assert_success
  assert_output --partial "First run"
  assert_output --partial "SYNC_OK"
  assert [ -f "${R}/.env.generated" ]
  run cat "${SETUP_LOG}"
  assert_output --partial "apply base=${R}"
}

@test "_wrapper_setup_sync RUN_SETUP=true forces an interactive setup run (#565)" {
  local R="${TEMP_DIR}/repo2"
  _make_setup_sandbox "${R}"
  # Pre-seed all three artifacts so the only reason setup runs is RUN_SETUP.
  echo "x" > "${R}/.setup.conf"
  echo "USER_NAME=a" > "${R}/.env.generated"
  echo "# c" > "${R}/compose.yaml"
  RUN_SETUP=true _run_setup_sync "${R}" run
  assert_success
  run cat "${SETUP_LOG}"
  assert_output --partial "apply base=${R}"
}

@test "_wrapper_setup_sync drift-check clean path does NOT re-apply (#565)" {
  local R="${TEMP_DIR}/repo3"
  _make_setup_sandbox "${R}"
  echo "x" > "${R}/.setup.conf"
  echo "USER_NAME=a" > "${R}/.env.generated"
  echo "# c" > "${R}/compose.yaml"
  MOCK_DRIFT_RC=0 _run_setup_sync "${R}" build
  assert_success
  # check-drift returned 0 → no apply recorded.
  run cat "${SETUP_LOG}"
  refute_output --partial "apply base="
}

@test "_wrapper_setup_sync regenerates on drift (check-drift non-zero) (#565)" {
  local R="${TEMP_DIR}/repo4"
  _make_setup_sandbox "${R}"
  echo "x" > "${R}/.setup.conf"
  echo "USER_NAME=a" > "${R}/.env.generated"
  echo "# c" > "${R}/compose.yaml"
  MOCK_DRIFT_RC=1 _run_setup_sync "${R}" run
  assert_success
  assert_output --partial "regen drift"
  run cat "${SETUP_LOG}"
  assert_output --partial "apply base=${R}"
}

@test "_wrapper_setup_sync exits 1 with no_env error when setup leaves no .env (#565)" {
  local R="${TEMP_DIR}/repo5"
  mkdir -p "${R}/.base/dist/script/docker/wrapper" "${R}"
  # setup.sh that does nothing (writes neither .env nor compose).
  cat > "${R}/.base/dist/script/docker/wrapper/setup.sh" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
  chmod +x "${R}/.base/dist/script/docker/wrapper/setup.sh"
  run bash -c "
    source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh
    _LANG=en
    FILE_PATH='${R}'
    RUN_SETUP=false
    declare -a SETUP_FORWARD_ARGS=()
    _msg_bootstrap() { echo 'First run'; }
    _msg_drift()     { echo 'regen'; }
    _msg_errors()    { case \"\$1\" in no_env) echo 'no env produced';; rerun_setup) echo 'rerun me';; esac; }
    _wrapper_setup_sync build
    echo 'SHOULD_NOT_REACH'
  "
  assert_failure 1
  assert_output --partial "no env produced"
  assert_output --partial "rerun me"
  refute_output --partial "SHOULD_NOT_REACH"
}

# Parameterisation: build + run share the orchestration; the verb is
# threaded into _log_* as the service name (`[<verb>]` tag) and the event
# name (`<verb>_bootstrap`). The text log format surfaces the `[<verb>]`
# tag; assert both verbs emit their own tagged bootstrap line.
@test "_wrapper_setup_sync tags log events with the caller's verb (#565)" {
  local _v
  for _v in build run; do
    local R="${TEMP_DIR}/repo_${_v}"
    _make_setup_sandbox "${R}"
    run bash -c "
      source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh
      _LANG=en
      FILE_PATH='${R}'
      RUN_SETUP=false
      declare -a SETUP_FORWARD_ARGS=()
      _msg_bootstrap() { echo 'First run'; }
      _msg_drift()     { echo 'regen'; }
      _msg_errors()    { case \"\$1\" in no_env) echo 'no env';; rerun_setup) echo 'rerun';; esac; }
      _wrapper_setup_sync ${_v}
    "
    assert_success
    # text log line carries the per-verb service tag "[<verb>]".
    assert_output --partial "[${_v}]"
  done
}

@test "_wrapper_setup_sync requires a verb argument (#565)" {
  run bash -c "
    source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh
    FILE_PATH='${TEMP_DIR}'
    _wrapper_setup_sync
  "
  assert_failure
  assert_output --partial "requires verb"
}

@test "_wrapper_setup_sync degrades to empty forward-args when SETUP_FORWARD_ARGS is unset (#565)" {
  # lib defensive-unset convention: a caller that never declared the
  # override array must not trip set -u. RUN_SETUP=true reaches the
  # _run_interactive branch that reads the array.
  local R="${TEMP_DIR}/repo_noargs"
  _make_setup_sandbox "${R}"
  echo "x" > "${R}/.setup.conf"
  echo "USER_NAME=a" > "${R}/.env.generated"
  echo "# c" > "${R}/compose.yaml"
  run bash -c "
    set -u
    source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh
    _LANG=en
    FILE_PATH='${R}'
    RUN_SETUP=true
    # NOTE: SETUP_FORWARD_ARGS intentionally NOT declared.
    _msg_bootstrap() { echo 'First run'; }
    _msg_drift()     { echo 'regen'; }
    _msg_errors()    { case \"\$1\" in no_env) echo 'no env';; rerun_setup) echo 'rerun';; esac; }
    _wrapper_setup_sync build
    echo 'NOARGS_OK'
  "
  assert_success
  assert_output --partial "NOARGS_OK"
}

# ── project-name settle (adopt a deferred rename) ───────────────────────────
#
# `setup apply` never renames a checkout out from under its own
# containers: it records the name the checkout already had and carries the
# newly resolved one beside it as PROJECT_NAME_PENDING (see
# `_carry_project_name`, lib/compose.sh, and setup_cmd_spec). Adopting it
# needs an answer setup cannot get -- is the old project empty? -- so the
# wrapper asks the daemon and settles it here.
#
# The stub answers `docker ps --all --quiet --filter label=...`: the
# projects named in ${DOCKER_OCCUPIED} own one container each, every other
# project owns none, and DOCKER_PS_RC makes the daemon unreachable
# instead. `docker volume ls --quiet --filter label=...` is the second
# half of the same question -- the projects in ${DOCKER_VOLUMED} own one
# named volume each, DOCKER_VOLUME_RC makes that query fail -- and the two
# are separate knobs because the case that matters is a project with a
# volume and NO container. `docker compose ... ps` answers the service
# probe from ${COMPOSE_PS_SERVICES} for the project passed in `-p`.

_make_docker_stub() {
  local _bin="${TEMP_DIR}/bin"
  mkdir -p "${_bin}"
  cat > "${_bin}/docker" <<'EOS'
#!/usr/bin/env bash
_project=""
_prev=""
for _a in "$@"; do
  case "${_prev}" in
    -p) _project="${_a}" ;;
  esac
  case "${_a}" in
    label=com.docker.compose.project=*) _project="${_a##*=}" ;;
  esac
  _prev="${_a}"
done

if [[ "$1" == "ps" ]]; then
  if [[ -n "${DOCKER_PS_RC:-}" ]] && (( DOCKER_PS_RC != 0 )); then
    printf 'Cannot connect to the Docker daemon\n' >&2
    exit "${DOCKER_PS_RC}"
  fi
  for _p in ${DOCKER_OCCUPIED:-}; do
    [[ "${_p}" == "${_project}" ]] && printf 'cid-%s\n' "${_p}"
  done
  exit 0
fi

if [[ "$1" == "volume" ]]; then
  if [[ -n "${DOCKER_VOLUME_RC:-}" ]] && (( DOCKER_VOLUME_RC != 0 )); then
    printf 'Cannot connect to the Docker daemon\n' >&2
    exit "${DOCKER_VOLUME_RC}"
  fi
  for _p in ${DOCKER_VOLUMED:-}; do
    [[ "${_p}" == "${_project}" ]] && printf '%s_mydata\n' "${_p}"
  done
  exit 0
fi

if [[ "$1" == "compose" ]]; then
  for _a in "$@"; do
    if [[ "${_a}" == "ps" ]]; then
      if [[ -n "${COMPOSE_PS_RC:-}" ]] && (( COMPOSE_PS_RC != 0 )); then
        printf 'unknown flag: --status\n' >&2
        exit "${COMPOSE_PS_RC}"
      fi
      # Last argv element is the service; answer only for the -p asked.
      for _s in ${COMPOSE_PS_SERVICES:-}; do
        [[ "${_s}" == "${_project}/${!#}" ]] && printf 'cid-%s\n' "${_s}"
      done
      exit 0
    fi
  done
fi
exit 0
EOS
  chmod +x "${_bin}/docker"
  PATH="${_bin}:${PATH}"
  export PATH
}

# A repo that already ran: all three artifacts present, .env.generated
# carrying the project name $2 and, when given, the pending name $3.
#
# The pending name is written as the whole BLOCK `write_env` emits -- a
# blank separator, the banner comment, then the key -- and not as a bare
# key. A fixture that writes only the key cannot see a remover that takes
# only the key, which is exactly how an adopted rename came to leave its
# banner standing over nothing. The banner is spelled out here rather than
# read from `_PROJECT_PENDING_BANNER` so the constant and its consumers
# are pinned by an independent copy of the text.
_seed_recorded_repo() {
  local _root="$1" _project="$2" _pending="${3-}"
  _make_setup_sandbox "${_root}"
  echo "x" > "${_root}/.setup.conf"
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "PROJECT_NAME=${_project}"
    if [[ -n "${_pending}" ]]; then
      echo ""
      echo "# -- Deferred project rename (adopted once the old project is empty) --"
      echo "PROJECT_NAME_PENDING=${_pending}"
    fi
  } > "${_root}/.env.generated"
  echo "# c" > "${_root}/compose.yaml"
}

@test "a deferred rename is adopted by the first run that finds the project empty (#920)" {
  # No drift, so setup does not run at all: the pending name alone drives
  # the adoption. This is the step that makes `stop` the whole migration.
  local R="${TEMP_DIR}/pending_empty"
  _seed_recorded_repo "${R}" "local-mockimg" "tester-mockimg"
  _make_docker_stub
  export DOCKER_OCCUPIED=""
  MOCK_DRIFT_RC=0 _run_setup_sync "${R}" build
  assert_success
  assert_output --partial "local-mockimg"
  assert_output --partial "tester-mockimg"
  run cat "${SETUP_LOG}"
  refute_output --partial "apply base="
  run cat "${R}/.env.generated"
  assert_output --partial "PROJECT_NAME=tester-mockimg"
  refute_output --partial "PROJECT_NAME_PENDING"
  # The banner goes with the key. A generated file the user is told not to
  # edit must not be left announcing a deferral that is over.
  refute_output --partial "Deferred project rename"
  # An edit, not a regeneration: every other line survives.
  assert_output --partial "USER_NAME=tester"
}

@test "adopting a rename takes the deferral block out whole and nothing else (#920)" {
  # Asserted byte for byte, because "every other line is copied through" is
  # this function's contract and a blank line is a line. The bug it pins:
  # dropping only the key left the banner standing over nothing, in a file
  # whose own header tells the user not to edit it.
  local F="${TEMP_DIR}/env.generated"
  cat > "${F}" <<'ENVEOF'
USER_NAME=tester
PROJECT_NAME=local-mockimg

# -- Deferred project rename (adopted once the old project is empty) --
PROJECT_NAME_PENDING=tester-mockimg

# -- SSH X11 forwarding cookie override --
XAUTHORITY=/tmp/.docker.xauth
ENVEOF
  run bash -c "
    source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh
    _wrapper_record_project_name '${F}' tester-mockimg
    cat '${F}'
  "
  assert_success
  assert_output "USER_NAME=tester
PROJECT_NAME=tester-mockimg

# -- SSH X11 forwarding cookie override --
XAUTHORITY=/tmp/.docker.xauth"
}

@test "a deferred rename stays deferred while the old project is still up (#920)" {
  local R="${TEMP_DIR}/pending_occupied"
  _seed_recorded_repo "${R}" "local-mockimg" "tester-mockimg"
  _make_docker_stub
  export DOCKER_OCCUPIED="local-mockimg"
  MOCK_DRIFT_RC=0 _run_setup_sync "${R}" run
  assert_success
  assert_output --partial "still has containers"
  run cat "${R}/.env.generated"
  assert_output --partial "PROJECT_NAME=local-mockimg"
  assert_output --partial "PROJECT_NAME_PENDING=tester-mockimg"
}

@test "a rename is NOT adopted while the old project still holds named volumes (#920)" {
  # `stop` runs `compose down` WITHOUT -v, so a torn-down stack routinely
  # leaves its named volumes behind. Counting containers alone would read
  # that project as empty, adopt the rename, and let compose create a
  # fresh EMPTY volume under the new name -- the user's data left in an
  # orphan no wrapper addresses and `prune --volumes` later deletes.
  local R="${TEMP_DIR}/pending_volumes"
  _seed_recorded_repo "${R}" "local-mockimg" "tester-mockimg"
  _make_docker_stub
  export DOCKER_OCCUPIED=""
  export DOCKER_VOLUMED="local-mockimg"
  MOCK_DRIFT_RC=0 _run_setup_sync "${R}" run
  assert_success
  assert_output --partial "still holds named volumes"
  # And NOT the containers wording: './stop.sh' does not clear a volume,
  # so sending the user there would be sending them nowhere.
  refute_output --partial "still has containers"
  run cat "${R}/.env.generated"
  assert_output --partial "PROJECT_NAME=local-mockimg"
  assert_output --partial "PROJECT_NAME_PENDING=tester-mockimg"
}

@test "a project holding BOTH containers and volumes is reported as containers (#920)" {
  # The pair for the case above: with containers present, `stop` IS the
  # next step, and it is what the user is told. Without this half the
  # volume case passes on a stub that always says volumes.
  local R="${TEMP_DIR}/pending_both"
  _seed_recorded_repo "${R}" "local-mockimg" "tester-mockimg"
  _make_docker_stub
  export DOCKER_OCCUPIED="local-mockimg"
  export DOCKER_VOLUMED="local-mockimg"
  MOCK_DRIFT_RC=0 _run_setup_sync "${R}" run
  assert_success
  assert_output --partial "still has containers"
  run cat "${R}/.env.generated"
  assert_output --partial "PROJECT_NAME_PENDING=tester-mockimg"
}

@test "a volume query the daemon cannot answer leaves the rename deferred (#920)" {
  # The volume half is load-bearing, so failing it must be fail-safe in
  # the same way the container half is: an unanswerable probe defers.
  local R="${TEMP_DIR}/volume_probe_fail"
  _seed_recorded_repo "${R}" "local-mockimg" "tester-mockimg"
  _make_docker_stub
  export DOCKER_OCCUPIED=""
  export DOCKER_VOLUME_RC=1
  MOCK_DRIFT_RC=0 _run_setup_sync "${R}" run
  assert_success
  assert_output --partial "Could not ask the daemon"
  assert_output --partial "Cannot connect to the Docker daemon"
  run cat "${R}/.env.generated"
  assert_output --partial "PROJECT_NAME=local-mockimg"
  assert_output --partial "PROJECT_NAME_PENDING=tester-mockimg"
}

@test "an unanswerable daemon leaves the rename deferred and says why (#920)" {
  # Fail-safe: deferring costs one more cycle under the old name, while
  # adopting on a guess costs the running stack.
  local R="${TEMP_DIR}/probe_fail"
  _seed_recorded_repo "${R}" "local-mockimg" "tester-mockimg"
  _make_docker_stub
  export DOCKER_PS_RC=1
  MOCK_DRIFT_RC=0 _run_setup_sync "${R}" run
  assert_success
  assert_output --partial "Could not ask the daemon"
  assert_output --partial "Cannot connect to the Docker daemon"
  run cat "${R}/.env.generated"
  assert_output --partial "PROJECT_NAME=local-mockimg"
  assert_output --partial "PROJECT_NAME_PENDING=tester-mockimg"
}

@test "no pending rename touches nothing and asks the daemon nothing (#920)" {
  # The ordinary run: two greps of .env.generated, no docker call. Any
  # call at all would answer this project as occupied, so a line about it
  # would be the tell.
  local R="${TEMP_DIR}/unchanged"
  _seed_recorded_repo "${R}" "local-mockimg"
  _make_docker_stub
  export DOCKER_OCCUPIED="local-mockimg"
  MOCK_DRIFT_RC=0 _run_setup_sync "${R}" run
  assert_success
  refute_output --partial "still has containers"
  refute_output --partial "project name updated"
  run cat "${R}/.env.generated"
  assert_output --partial "PROJECT_NAME=local-mockimg"
  refute_output --partial "PROJECT_NAME_PENDING"
}

# ── _wrapper_service_running (the probe both run and exec ask) ──────────────

# The two answers are spelled as DISJOINT tokens, and every assertion on
# them is a whole-line match (`assert_line`, never `--partial`). The pair
# `RUNNING` / `NOT_RUNNING` read with `--partial` is what let a probe that
# can never find anything pass the positive half too -- "NOT_RUNNING"
# contains "RUNNING" -- so the discrimination the cases below claim to make
# was made by nothing. `assert_line` also survives the warning line the
# failing-probe case prints alongside the verdict.
_run_service_probe() {
  local _root="$1" _service="$2"
  run bash -c "
    source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh
    _LANG=en
    FILE_PATH='${_root}'
    PROJECT_NAME='proj'
    DRY_RUN=true
    if _wrapper_service_running '${_service}'; then
      echo 'PROBE_UP'
    else
      echo 'PROBE_DOWN'
    fi
  "
}

@test "_wrapper_service_running answers per project, not per host (#920)" {
  local R="${TEMP_DIR}/probe"
  mkdir -p "${R}"
  echo "# c" > "${R}/compose.yaml"
  _make_docker_stub
  # devel is up, but in a DIFFERENT project. The probe carries -p, so the
  # neighbour is invisible to it -- which is what lets two stacks of one
  # repo coexist at all.
  export COMPOSE_PS_SERVICES="neighbour/devel"
  _run_service_probe "${R}" devel
  assert_success
  assert_line "PROBE_DOWN"
  # Same stub, same seed: asked about the project that DOES have it, the
  # answer flips. Without that pair the case above passes on a stub that
  # never answers anything.
  export COMPOSE_PS_SERVICES="proj/devel"
  _run_service_probe "${R}" devel
  assert_success
  assert_line "PROBE_UP"
}

@test "a FAILING service probe is reported, not silently read as not-running (#920)" {
  # `ps --status` is newer than the Compose v2 the README promises. A
  # compose that rejects it used to report every service as stopped with
  # the parse error dropped on the floor: exec refuses a container that is
  # up, and run's guard fails open onto a live stack.
  local R="${TEMP_DIR}/probe_err"
  mkdir -p "${R}"
  echo "# c" > "${R}/compose.yaml"
  _make_docker_stub
  export COMPOSE_PS_RC=125
  _run_service_probe "${R}" devel
  assert_success
  assert_line "PROBE_DOWN"
  assert_output --partial "unknown flag: --status"
  assert_output --partial "devel"
  assert_output --partial "proj"
}

@test "a service probe that answers cleanly stays quiet (#920)" {
  local R="${TEMP_DIR}/probe_quiet"
  mkdir -p "${R}"
  echo "# c" > "${R}/compose.yaml"
  _make_docker_stub
  export COMPOSE_PS_SERVICES="proj/devel"
  _run_service_probe "${R}" devel
  assert_success
  assert_line "PROBE_UP"
  refute_output --partial "Could not ask compose"
}
