#!/usr/bin/env bash
#
# 30-watch-gosum.sh -- a go.mod pin bump carries its go.sum, proven in the
# pinned golang image (base#1440).
#
# A config-gen step: script/test/config_gen_gates.sh runs it before the
# gates, in every environment `just test go` reaches, and the redpath runs
# it again on each scratch copy. It reads everything relative to its own
# root (three directories up), never the caller's checkout.
#
# The unit specs stub docker, so they never run the container script that
# regenerates go.sum; only a real image can show that the go.sum a bump
# commits is the one Go wants, with nothing else on it. So, per require
# form, this builds a git-initialised scratch tree:
#
#   dockerfile/Dockerfile.config-gen  the `# tool-pin: golang` marker and
#                                     the line under it, copied from this
#                                     checkout's file (never retyped);
#   dockerfile/config-gen/go.mod      `go <major.minor of that pin>` and a
#                                     marked BurntSushi/toml v1.5.0 require
#                                     with odd spacing and a comment;
#   dockerfile/config-gen/main.go     importing toml, so tidy keeps it;
#   dockerfile/config-gen/go.sum      the two v1.5.0 sum.golang.org lines;
#
# runs this checkout's `pins.sh --set toml v1.6.0` against it, and holds
# the result to literals:
#
#   - pins.sh exits 0;
#   - go.sum is byte for byte the two v1.6.0 lines sum.golang.org serves
#     (lookup/github.com/!burnt!sushi/toml@v1.6.0), so a stale go.sum and
#     a stray `all modules verified` on it both fail;
#   - go.mod is its old bytes with v1.5.0 -> v1.6.0 and nothing else;
#   - `go build -mod=readonly ./...` passes in the pinned image.
#
# Refusals: a Dockerfile with no golang pin is watch_gosum_pin_missing,
# with no docker call; each point that does not hold is one
# watch_gosum_mismatch (form= reason=), every point reported before the
# step fails.
#
# Exit: 0 every point holds; 1 otherwise.
#
# Style: Google Shell Style Guide.

set -euo pipefail

_WG_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
readonly _WG_DIR
_WG_ROOT="$(cd -- "${_WG_DIR}/../../.." && pwd -P)"
readonly _WG_ROOT
# shellcheck source=dist/script/docker/lib/log.sh
source "${_WG_ROOT}/dist/script/docker/lib/log.sh"

readonly _WG_SERVICE='config-gen'
readonly _WG_DOCKERFILE_REL='dockerfile/Dockerfile.config-gen'
readonly _WG_MODULE_REL='dockerfile/config-gen'

# sum.golang.org, lookup/github.com/!burnt!sushi/toml@v1.5.0 and @v1.6.0.
readonly _WG_SUM_OLD='github.com/BurntSushi/toml v1.5.0 h1:W5quZX/G/csjUnuI8SUYlsHs9M38FC7znL0lIO+DvMg=
github.com/BurntSushi/toml v1.5.0/go.mod h1:ukJfTF/6rtPPRCnwkur4qwRxa8vTRFBF0uk2lLoLwho=
'
readonly _WG_SUM_NEW='github.com/BurntSushi/toml v1.6.0 h1:dRaEfpa2VI55EwlIW72hMRHdWouJeRF7TPYhI+AUQjk=
github.com/BurntSushi/toml v1.6.0/go.mod h1:ukJfTF/6rtPPRCnwkur4qwRxa8vTRFBF0uk2lLoLwho=
'

# Build the module in the pinned image, from a tar on stdin.
# shellcheck disable=SC2016 # expanded by the container's shell, not here.
readonly _WG_BUILD_SCRIPT='set -eu
mkdir -p /tmp/w
cd /tmp/w
tar -xf -
go build -mod=readonly -o /tmp/out/ ./...'

# _wg_pin_lines -- the `# tool-pin: golang` marker line and the line under
# it, from this checkout's Dockerfile.config-gen; empty when there is none.
_wg_pin_lines() {
  sed -n '/^#[[:space:]]*tool-pin:[[:space:]]\{1,\}golang[[:space:]]/{N;p;q}' \
    "${_WG_ROOT}/${_WG_DOCKERFILE_REL}"
}

# _wg_mismatch <form> <reason> <text> -- one point that does not hold.
_wg_mismatch() {
  _log_err "${_WG_SERVICE}" watch_gosum_mismatch "form=${1}" "reason=${2}" \
    "display=watch_gosum_mismatch: ${1} form: ${3}"
}

# _wg_case <form> <pin-lines> <go-version> <tmp> -- one require form, end to
# end; 0 when every point holds.
_wg_case() {
  local form="${1}" pin_lines="${2}" gover="${3}" tmp="${4}"
  local tree="${tmp}/${form}" mod gomod_old gomod_new rc=0 failed=0 image
  local mod_rel="${_WG_MODULE_REL}"
  image="${pin_lines#*$'\n'}"
  image="${image#*=}"

  case "${form}" in
    line)
      gomod_old="module example.com/m

go ${gover}

// tool-pin: toml github-release BurntSushi/toml
require github.com/BurntSushi/toml   v1.5.0 // keep me
"
      gomod_new="module example.com/m

go ${gover}

// tool-pin: toml github-release BurntSushi/toml
require github.com/BurntSushi/toml   v1.6.0 // keep me
"
      ;;
  esac

  mod="${tree}/${mod_rel}"
  mkdir -p "${mod}"
  printf '%s\n' "${pin_lines}" > "${tree}/${_WG_DOCKERFILE_REL}"
  printf '%s' "${gomod_old}" > "${mod}/go.mod"
  printf '%s' "${_WG_SUM_OLD}" > "${mod}/go.sum"
  printf 'package main\n\nimport _ "github.com/BurntSushi/toml"\n\nfunc main() {}\n' > "${mod}/main.go"
  git -C "${tree}" init -q
  git -C "${tree}" add -A

  PIN_REPO_ROOT="${tree}" bash "${_WG_ROOT}/script/watch/pins.sh" --set toml v1.6.0 \
    > "${tmp}/${form}.pins.out" 2> "${tmp}/${form}.pins.err" || rc=$?
  if (( rc != 0 )); then
    cat "${tmp}/${form}.pins.err" >&2
    _wg_mismatch "${form}" pins_status "pins.sh --set toml v1.6.0 exited ${rc}"
    failed=1
  fi
  if ! cmp -s <(printf '%s' "${_WG_SUM_NEW}") "${mod}/go.sum"; then
    _wg_mismatch "${form}" go_sum \
      "go.sum is not the two v1.6.0 sum.golang.org lines; it holds [$(tr '\n' ';' < "${mod}/go.sum")]"
    failed=1
  fi
  if ! cmp -s <(printf '%s' "${gomod_new}") "${mod}/go.mod"; then
    _wg_mismatch "${form}" go_mod \
      "go.mod is not its old bytes with v1.5.0 -> v1.6.0; it holds [$(tr '\n' ';' < "${mod}/go.mod")]"
    failed=1
  fi

  rc=0
  tar -C "${mod}" -cf - . | docker run --rm -i --user "$(id -u):$(id -g)" \
    -e GOTOOLCHAIN=local -e HOME=/tmp -e GOCACHE=/tmp/gocache \
    -e GOMODCACHE=/tmp/gomodcache -e GOFLAGS= \
    --entrypoint /bin/sh "${image}" -c "${_WG_BUILD_SCRIPT}" \
    > "${tmp}/${form}.build.out" 2> "${tmp}/${form}.build.err" || rc=$?
  if (( rc != 0 )); then
    cat "${tmp}/${form}.build.err" >&2
    _wg_mismatch "${form}" go_build "go build -mod=readonly ./... exited ${rc} in ${image%%@*}"
    failed=1
  fi
  (( failed == 0 ))
}

main() {
  local pin_lines tag gover tmp form failed=0
  local -a forms=(line)

  pin_lines="$(_wg_pin_lines)"
  if [[ "${pin_lines}" != *$'\n'*=golang:* ]]; then
    _log_err "${_WG_SERVICE}" watch_gosum_pin_missing "file=${_WG_DOCKERFILE_REL}" \
      "display=watch_gosum_pin_missing: ${_WG_DOCKERFILE_REL} has no golang image under '# tool-pin: golang'"
    return 1
  fi
  # golang:<major>.<minor>.<patch>-<variant>[@digest] -> <major>.<minor>
  tag="${pin_lines#*=golang:}"
  tag="${tag%%[-@]*}"
  gover="${tag%.*}"

  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand ${tmp} now; it is local to main
  trap "rm -rf '${tmp}'" EXIT
  for form in "${forms[@]}"; do
    _wg_case "${form}" "${pin_lines}" "${gover}" "${tmp}" || failed=1
  done
  (( failed == 0 )) || return 1
  printf 'watch-gosum: a toml bump carries its go.sum in every require form\n'
}

main "$@"
