#!/usr/bin/env bash
# measure.sh -- base#1395 slice 1 measurement harness. SPIKE ONLY.
#
# Times the same `setup apply` on the shipped template configuration
# (dist/setup.toml copied into a fresh repo dir beside a two-stage
# Dockerfile) under several engines, and prints one TSV row per run.
#
# usage: measure.sh setup                 build the native Go binary, the
#                                         native-Python wrapper, the replay
#                                         recording and the cold builder
#        measure.sh count <mode>          one untimed run through a logging
#                                         docker shim; prints the call mix
#        measure.sh run <mode> <warm|cold> <n>
#                                         n timed runs, one TSV row each:
#                                         mode temp run ms rc load1 load5
#        measure.sh rr <n> <mode>...      warm, interleaved: n rounds, each
#                                         round runs every mode once, so
#                                         background load lands on all modes
#                                         alike; same TSV rows
#        measure.sh coldbuild <bridge|go> <n>
#                                         n cold image builds alone, as the
#                                         shim would run them: one TSV row
#                                         each (engine cold i ms rc load1 load5)
#        measure.sh outputs <mode>        one run; prints sha256 of the
#                                         files apply wrote
#        measure.sh rrcold <n> <mode>...  cold, interleaved and rotated
#        measure.sh gate <mode>...        frozen clock, every file apply
#                                         leaves, unfiltered: one manifest
#                                         digest per mode
#
# Modes:
#   current-docker   today: no batching, bridge forced through docker run
#   current-docker-fixed
#                    current-docker with the first-build log record on
#                    stderr (TOML_BRIDGE_SPIKE_LOG_STDERR=1), so a cold
#                    run completes; identical to current-docker warm
#   batch-docker     Python bridge --batch, one docker run
#   go-docker        Go prototype in a container (one docker run), views
#                    served from the recorded Python --batch output
#   go-native        Go prototype binary run natively, same replay
#   floor            replay only: the zero-cost-engine floor
#   current-native   today, bridge on PATH (host Python + tomli): CI shape
#   batch-native     --batch, bridge on PATH: CI shape, batched
#
# Cold = the engine image is absent AND the dedicated buildx builder
# (`spike1395`, docker-container driver, default-load) has had its whole
# cache pruned, so base layers are fetched again. Cold applies only to the
# docker modes. Runs are sequential; nothing else is started meanwhile.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BASE="$(cd -- "${HERE}/../../.." && pwd -P)"
WORK="${SPIKE_WORK:?set SPIKE_WORK to a scratch directory}"
GO_PROTO="${HERE}/go-proto"
GO_IMAGE_BUILDER="golang:1.27.2-alpine3.24"
BUILDER="spike1395"
REPO="${WORK}/repo"

die() { printf 'measure.sh: %s\n' "$*" >&2; exit 2; }

fresh_repo() {
  rm -rf -- "${REPO}"
  mkdir -p -- "${REPO}"
  cp -- "${BASE}/dist/setup.toml" "${REPO}/setup.toml"
  printf 'FROM alpine:3.22 AS devel\nRUN true\nFROM devel AS runtime\nCMD ["sleep","infinity"]\n' \
    > "${REPO}/Dockerfile"
}

bridge_tag() {
  bash -c 'source "$1/dist/script/docker/lib/toml_bridge.sh"; _toml_bridge_derive_image' _ "${BASE}"
}

go_tag() {
  # The same derivation as _tb_batch_go_image, without its build.
  local _h
  _h="$(cat "${GO_PROTO}/Dockerfile" "${GO_PROTO}"/go.mod "${GO_PROTO}"/go.sum "${GO_PROTO}"/*.go | sha256sum)"
  echo "spike-setupgen:${_h:0:12}"
}

# Environment for one mode, as `env` arguments.
mode_env() {
  local _m="$1"
  local _np="${WORK}/native-bin:${PATH}"
  case "${_m}" in
    current-docker) echo "TOML_BRIDGE_FORCE_DOCKER=1" ;;
    current-docker-fixed)
                    echo "TOML_BRIDGE_FORCE_DOCKER=1 TOML_BRIDGE_SPIKE_LOG_STDERR=1" ;;
    batch-docker)   echo "TOML_BRIDGE_FORCE_DOCKER=1 TOML_BRIDGE_BATCH=1" ;;
    go-docker)      echo "TOML_BRIDGE_FORCE_DOCKER=1 TOML_BRIDGE_BATCH=1 TOML_BRIDGE_BATCH_GO=docker:${GO_PROTO} TOML_BRIDGE_BATCH_REPLAY=${WORK}/replay.batch" ;;
    go-native)      echo "TOML_BRIDGE_FORCE_DOCKER=1 TOML_BRIDGE_BATCH=1 TOML_BRIDGE_BATCH_GO=native:${WORK}/setupgen TOML_BRIDGE_BATCH_REPLAY=${WORK}/replay.batch" ;;
    floor)          echo "TOML_BRIDGE_FORCE_DOCKER=1 TOML_BRIDGE_BATCH=1 TOML_BRIDGE_BATCH_REPLAY=${WORK}/replay.batch" ;;
    current-native) echo "PATH=${_np}" ;;
    batch-native)   echo "PATH=${_np} TOML_BRIDGE_BATCH=1" ;;
    *) die "unknown mode ${_m}" ;;
  esac
}

apply_once() {
  local _m="$1"; shift
  # shellcheck disable=SC2046  # mode_env is a word list on purpose
  env $(mode_env "${_m}") "$@" \
    bash "${BASE}/dist/script/docker/wrapper/setup.sh" apply --base-path "${REPO}" \
    > "${WORK}/last-${_m}.out" 2>&1
}

make_cold() {
  local _m="$1" _tag
  case "${_m}" in
    current-docker|current-docker-fixed|batch-docker) _tag="$(bridge_tag)" ;;
    go-docker) _tag="$(go_tag)" ;;
    *) die "cold does not apply to ${_m}" ;;
  esac
  docker rmi -f "${_tag}" > /dev/null 2>&1 || true
  docker buildx prune --builder "${BUILDER}" -af > /dev/null 2>&1 || die "prune failed"
  docker image inspect "${_tag}" > /dev/null 2>&1 && die "${_tag} still present"
  return 0
}

cmd_setup() {
  mkdir -p -- "${WORK}/native-bin"
  docker buildx inspect "${BUILDER}" > /dev/null 2>&1 \
    || docker buildx create --name "${BUILDER}" --driver docker-container \
         --driver-opt default-load=true > /dev/null || die "builder"
  # Native Python: a venv with the bridge's own tomli pin.
  if [[ ! -x "${WORK}/venv/bin/python" ]]; then
    python3 -m venv "${WORK}/venv" && "${WORK}/venv/bin/pip" install -q tomli==2.4.1 || die "venv"
  fi
  printf '#!/bin/sh\nexec %q %q "$@"\n' "${WORK}/venv/bin/python" "${BASE}/dockerfile/toml_bridge.py" \
    > "${WORK}/native-bin/toml-bridge"
  chmod +x "${WORK}/native-bin/toml-bridge"
  # Native Go: a static binary from the same sources the image builds.
  docker run --rm -u "$(id -u):$(id -g)" -e GOCACHE=/tmp/gocache -e GOPATH=/tmp/gopath \
    -e CGO_ENABLED=0 -v "${GO_PROTO}:/src:ro" -v "${WORK}:/out" -w /src "${GO_IMAGE_BUILDER}" \
    go build -trimpath -ldflags "-s -w" -o /out/setupgen . || die "go build"
  # Replay: the Python --batch answer for this exact chain and these paths.
  fresh_repo
  "${WORK}/native-bin/toml-bridge" --batch "${BASE}/dist/setup.toml" "${REPO}/setup.toml" \
    > "${WORK}/replay.batch" || die "replay"
  printf 'setup ok: %s\n' "${WORK}"
}

cmd_count() {
  local _m="$1"
  mkdir -p -- "${WORK}/shim"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "${DOCKER_LOG:?}"\nexec /usr/bin/docker "$@"\n' \
    > "${WORK}/shim/docker"
  chmod +x "${WORK}/shim/docker"
  fresh_repo
  : > "${WORK}/docker-${_m}.log"
  local _rc=0
  # shellcheck disable=SC2046
  env $(mode_env "${_m}") DOCKER_LOG="${WORK}/docker-${_m}.log" \
    PATH="${WORK}/shim:$(env $(mode_env "${_m}") bash -c 'echo "$PATH"')" \
    bash "${BASE}/dist/script/docker/wrapper/setup.sh" apply --base-path "${REPO}" \
    > "${WORK}/last-${_m}.out" 2>&1 || _rc=$?
  printf '%s rc=%s run=%s inspect=%s build=%s other=%s\n' "${_m}" "${_rc}" \
    "$(grep -c '^run ' "${WORK}/docker-${_m}.log")" \
    "$(grep -c '^image inspect' "${WORK}/docker-${_m}.log")" \
    "$(grep -c '^build ' "${WORK}/docker-${_m}.log")" \
    "$(grep -vc '^run \|^image inspect\|^build ' "${WORK}/docker-${_m}.log")"
}

cmd_run() {
  local _m="$1" _temp="$2" _n="$3" _i _s _e _rc _la
  for (( _i = 1; _i <= _n; _i++ )); do
    fresh_repo
    local -a _extra=()
    if [[ "${_temp}" == cold ]]; then
      make_cold "${_m}"
      _extra=("BUILDX_BUILDER=${BUILDER}")
    else
      # Warm: make sure the engine exists before the clock starts.
      [[ "${_i}" == 1 ]] && { apply_once "${_m}" "BUILDX_BUILDER=${BUILDER}"; fresh_repo; }
    fi
    read -r _la _ < /proc/loadavg
    local _la5; _la5="$(cut -d' ' -f2 /proc/loadavg)"
    _rc=0
    _s="$(date +%s%N)"
    apply_once "${_m}" "${_extra[@]}" || _rc=$?
    _e="$(date +%s%N)"
    printf '%s\t%s\t%d\t%d\t%d\t%s\t%s\n' "${_m}" "${_temp}" "${_i}" \
      $(( (_e - _s) / 1000000 )) "${_rc}" "${_la}" "${_la5}"
  done
}

cmd_rr() {
  local _n="$1"; shift
  local _m _r _k=$# _j _off
  local -a _all=("$@") _order=()
  for _m in "$@"; do fresh_repo; apply_once "${_m}" "BUILDX_BUILDER=${BUILDER}"; done
  for (( _r = 1; _r <= _n; _r++ )); do
    # Balanced order: round r starts at mode (r-1) mod k, and every
    # second round runs backwards, so no mode always follows the same one
    # or always sits in the same position.
    _order=()
    _off=$(( (_r - 1) % _k ))
    for (( _j = 0; _j < _k; _j++ )); do _order+=("${_all[(_off + _j) % _k]}"); done
    if (( _r % 2 == 0 )); then
      local -a _rev=()
      for (( _j = _k - 1; _j >= 0; _j-- )); do _rev+=("${_order[_j]}"); done
      _order=("${_rev[@]}")
    fi
    for _m in "${_order[@]}"; do
      cmd_run_one "${_m}" warm "${_r}"
    done
  done
}

# rrcold <n> <mode>... -- cold, interleaved and rotated like rr: before
# every timed run the engine image and the builder cache are removed.
cmd_rrcold() {
  local _n="$1"; shift
  local _r _j _k=$# _off _m
  local -a _all=("$@")
  for (( _r = 1; _r <= _n; _r++ )); do
    _off=$(( (_r - 1) % _k ))
    for (( _j = 0; _j < _k; _j++ )); do
      _m="${_all[(_off + _j) % _k]}"
      make_cold "${_m}"
      cmd_run_one "${_m}" cold "${_r}" "BUILDX_BUILDER=${BUILDER}"
    done
  done
}

cmd_run_one() {
  local _m="$1" _temp="$2" _i="$3" _s _e _rc=0 _la _la5
  shift 3
  fresh_repo
  read -r _la _la5 _ < /proc/loadavg
  _s="$(date +%s%N)"
  apply_once "${_m}" "$@" || _rc=$?
  _e="$(date +%s%N)"
  printf '%s\t%s\t%d\t%d\t%d\t%s\t%s\n' "${_m}" "${_temp}" "${_i}" \
    $(( (_e - _s) / 1000000 )) "${_rc}" "${_la}" "${_la5}"
}

cmd_coldbuild() {
  local _e="$1" _n="$2" _i _tag _df _ctx _s _t _rc _la _la5
  for (( _i = 1; _i <= _n; _i++ )); do
    case "${_e}" in
      bridge) make_cold batch-docker; _tag="$(bridge_tag)"
              _df="${BASE}/dockerfile/Dockerfile.toml-bridge"; _ctx="${BASE}/dockerfile" ;;
      go)     make_cold go-docker; _tag="$(go_tag)"
              _df="${GO_PROTO}/Dockerfile"; _ctx="${GO_PROTO}" ;;
      *) die "engine is bridge or go" ;;
    esac
    read -r _la _la5 _ < /proc/loadavg
    _rc=0
    _s="$(date +%s%N)"
    BUILDX_BUILDER="${BUILDER}" docker build -q -t "${_tag}" -f "${_df}" "${_ctx}" \
      > /dev/null 2>&1 || _rc=$?
    _t="$(date +%s%N)"
    printf '%s\tcold\t%d\t%d\t%d\t%s\t%s\n' "build-${_e}" "${_i}" \
      $(( (_t - _s) / 1000000 )) "${_rc}" "${_la}" "${_la5}"
  done
}

cmd_outputs() {
  local _m="$1" _rc=0
  fresh_repo
  apply_once "${_m}" || _rc=$?
  printf '%s rc=%s\n' "${_m}" "${_rc}"
  ( cd -- "${REPO}" && for f in .env .env.generated compose.yaml; do
      # The generation timestamp is the only line that varies by run
      # (observed: diff of two runs); it is dropped before hashing.
      printf '  %s %s\n' "$(grep -v -e '^# Auto-generated by setup.sh on' \
        -e '^SETUP_TIMESTAMP=' "${f}" | sha256sum | cut -c1-16)" "${f}"
    done )
}


# gate <mode>... -- correctness lane, separate from timing. The clock is
# frozen (a `date` shim on PATH answers for one fixed instant unless the
# caller passes -d/-r), the fixture is fresh, and EVERY file apply leaves
# in the repo dir is hashed with its mode. Nothing is filtered. Prints one
# manifest digest per mode and the manifest of the first mode.
cmd_gate() {
  local _m _rc
  mkdir -p -- "${WORK}/frozen"
  printf '#!/bin/sh\nfor a in "$@"; do case "$a" in -d|-r|--date*|--reference*) exec /usr/bin/date "$@";; esac; done\nexec /usr/bin/date -d @1800000000 "$@"\n' \
    > "${WORK}/frozen/date"
  chmod +x "${WORK}/frozen/date"
  for _m in "$@"; do
    fresh_repo
    _rc=0
    # shellcheck disable=SC2046
    env $(mode_env "${_m}") \
      PATH="${WORK}/frozen:$(env $(mode_env "${_m}") bash -c 'echo "$PATH"')" \
      bash "${BASE}/dist/script/docker/wrapper/setup.sh" apply --base-path "${REPO}" \
      > "${WORK}/gate-${_m}.out" 2>&1 || _rc=$?
    ( cd -- "${REPO}" && find . -type f -printf '%m %p\n' | sort -k2 \
        | while read -r _mode _p; do printf '%s %s %s\n' "${_mode}" "$(sha256sum < "${_p}" | cut -c1-16)" "${_p}"; done ) \
      > "${WORK}/gate-${_m}.manifest"
    printf '%s rc=%s files=%s manifest=%s\n' "${_m}" "${_rc}" \
      "$(wc -l < "${WORK}/gate-${_m}.manifest")" \
      "$(sha256sum < "${WORK}/gate-${_m}.manifest" | cut -c1-16)"
  done
  sed 's/^/  /' "${WORK}/gate-${1}.manifest"
}

case "${1:-}" in
  setup) cmd_setup ;;
  count) cmd_count "${2:?mode}" ;;
  run) cmd_run "${2:?mode}" "${3:?warm|cold}" "${4:?n}" ;;
  rr) shift; cmd_rr "$@" ;;
  rrcold) shift; cmd_rrcold "$@" ;;
  gate) shift; cmd_gate "$@" ;;
  coldbuild) cmd_coldbuild "${2:?bridge|go}" "${3:?n}" ;;
  outputs) cmd_outputs "${2:?mode}" ;;
  *) sed -n '2,34p' "${BASH_SOURCE[0]}"; exit 2 ;;
esac
