#!/usr/bin/env bash
#
# config_gen_gates.sh -- run the config generator's Go gates (base#1462).
#
# Usage:
#   ./script/test/config_gen_gates.sh [--root <dir>]
#
# The one command every environment reaches through `just test go`: the
# hosted self-test job, the self-hosted coverage-local job, the pre-PR
# mirror and a developer's shell. <dir> (default: this checkout) must hold
# dockerfile/Dockerfile.config-gen; script/test/config_gen_redpath.sh
# points it at scratch copies carrying a planted defect.
#
# In order:
#   1. steps     every <dir>/script/test/config_gen_steps/*.sh, in C-locale
#                glob order, run with CONFIG_GEN_CTX set to a fresh
#                directory, its stdout sent to stderr (stdout carries only
#                the ok lines below; base#1465). The first step that fails
#                stops the run with its status. Each directory a step leaves under CONFIG_GEN_CTX
#                becomes a named build context, `--build-context
#                <name>=<path>`, so a later slice's inputs reach the build
#                without an edit here. A name outside [a-z0-9-] is refused:
#                it is spliced into that argument.
#   2. gates     the Dockerfile's `test` stage, with --no-cache-filter
#                admit,test so the admission RUN and every gate RUN execute
#                on every call, an unchanged rerun included (base#1465).
#                The build log streams to stderr; each `gate=<g> ok` it
#                printed is re-printed on stdout, and on a red build the first
#                `config_gen_gate_<g>_failed` is re-emitted as an event with
#                gate=<g> and the run exits with docker's status. A red
#                build that printed an allowlisted `cg_event <id>`
#                (config_gen_manifest_missing: no mutation context;
#                config_gen_manifest_stale: a module file changed after the
#                baseline, with its file= and reason=; base#1465) re-emits
#                <id> first, and the gate id after it when there is one.
#   3. contract  the `final` stage is built and its binary run with no
#                arguments: it must exit 2 with nothing on stdout.
#
# Exit: 0 green; docker's or the step's status on a red gate or step; 1 on
# a broken binary contract or an invalid context name; 2 on usage or an
# invalid --root.
#
# Style: Google Shell Style Guide.

set -euo pipefail

_CG_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
readonly _CG_SCRIPT_DIR
# shellcheck source=dist/script/docker/lib/log.sh
source "${_CG_SCRIPT_DIR}/../../dist/script/docker/lib/log.sh"

readonly _CG_SERVICE='config-gen'

# A BuildKit plain-progress output line: `#<step> <seconds> <text>`. The
# RUN line BuildKit echoes (`#<step> [test 2/6] RUN ...`) has no seconds
# field, so it never matches. Both match the WHOLE line, because sed's s///
# keeps whatever the pattern leaves unmatched: the coverage gate's id is
# followed by `reason=... pkg=...`.
readonly _CG_OK_RE='^#[0-9]+ [0-9]+\.[0-9]+ gate=([a-z]+) ok$'
readonly _CG_FAIL_RE='^#[0-9]+ [0-9]+\.[0-9]+ config_gen_gate_([a-z]+)_failed( .*)?$'
# A refusal the build prints as `cg_event <id>` before any gate runs
# (base#1465). Only an id named here is re-emitted, so the build log can
# never put an arbitrary body into the runner's own records.
readonly _CG_EVENT_RE='^#[0-9]+ [0-9]+\.[0-9]+ cg_event (config_gen_manifest_missing|config_gen_manifest_stale)( .*)?$'
# The attributes a re-emitted event may carry, each `<key>=<value>` whose
# value is bytes 0x21-0x7e only: config_gen_admit.sh writes every other
# byte, and the % itself, as %XX, so a value is one word and is kept here
# verbatim, still encoded. Any other word on the line is dropped.
readonly _CG_EVENT_ATTR_RE='^(file|reason)=[!-~]+$'

# _cg_run_steps <root> <ctx> -- run each step; the first red one ends the
# run with its status.
_cg_run_steps() {
  local root="${1}" ctx="${2}" step name rc
  local -a steps=()
  [[ -d "${root}/script/test/config_gen_steps" ]] || return 0
  mapfile -t steps < <(LC_ALL=C compgen -G "${root}/script/test/config_gen_steps/*.sh" | LC_ALL=C sort)
  for step in "${steps[@]}"; do
    [[ -n "${step}" ]] || continue
    name="$(basename -- "${step}" .sh)"
    rc=0
    CONFIG_GEN_CTX="${ctx}" bash "${step}" </dev/null >&2 || rc=$?
    if (( rc != 0 )); then
      _log_err "${_CG_SERVICE}" config_gen_step_failed "step=${name}" "status=${rc}" \
        "display=config-gen step ${name} exited ${rc}"
      exit "${rc}"
    fi
  done
}

# _cg_context_args <ctx> -- one `--build-context <name>=<path>` pair per
# directory under <ctx>, one argument per line; refuses an unsafe name.
_cg_context_args() {
  local ctx="${1}" dir name
  for dir in "${ctx}"/*/; do
    [[ -d "${dir}" ]] || continue
    dir="${dir%/}"
    name="$(basename -- "${dir}")"
    if [[ ! "${name}" =~ ^[a-z0-9-]+$ ]]; then
      _log_err "${_CG_SERVICE}" config_gen_context_invalid "context=${name}" \
        "display=config-gen build context name '${name}' is outside [a-z0-9-]"
      return 1
    fi
    printf '%s\n' --build-context "${name}=${dir}"
  done
}

# _cg_attr_ok <word> -- true when <word> is an allowed attribute. The
# range in _CG_EVENT_ATTR_RE is a byte range only in the C locale: under
# en_US.UTF-8 on the host, bash's [!-~] matched no
# file=dockerfile/config-gen/... word at all, while the C-locale test-tools
# container matched every one. The local LC_ALL ends with the function.
_cg_attr_ok() {
  local LC_ALL=C
  [[ "${1}" =~ ${_CG_EVENT_ATTR_RE} ]]
}

# _cg_event <id and words> <rc> -- re-emit an allowlisted `cg_event` line
# as the event <id>, keeping only the words _cg_attr_ok allows.
_cg_event() {
  local id word
  local -a words=() keep=()
  read -r -a words <<<"${1}"
  id="${words[0]}"
  for word in "${words[@]:1}"; do
    _cg_attr_ok "${word}" && keep+=("${word}")
  done
  _log_err "${_CG_SERVICE}" "${id}" "${keep[@]}" "status=${2}" \
    "display=config-gen build refused with ${id}${keep[*]:+ (${keep[*]})} (docker exited ${2})"
}

# _cg_gates <root> <log> <context args...> -- build the test stage, stream
# its log to stderr, re-print the ok lines; on red re-emit the first gate
# id and exit with docker's status.
_cg_gates() {
  local root="${1}" log="${2}" rc=0 gate event
  shift 2
  docker build --progress=plain --no-cache-filter admit,test --target test "$@" \
    -f "${root}/dockerfile/Dockerfile.config-gen" "${root}/dockerfile/config-gen" \
    >"${log}" 2>&1 || rc=$?
  cat "${log}" >&2
  sed -nE "s/${_CG_OK_RE}/gate=\\1 ok/p" "${log}"
  (( rc == 0 )) && return 0
  gate="$(sed -nE "s/${_CG_FAIL_RE}/\\1/p" "${log}")"
  gate="${gate%%$'\n'*}"
  event="$(sed -nE "s/${_CG_EVENT_RE}/\\1\\2/p" "${log}")"
  event="${event%%$'\n'*}"
  [[ -z "${event}" ]] || _cg_event "${event}" "${rc}"
  if [[ -n "${gate}" ]]; then
    _log_err "${_CG_SERVICE}" "config_gen_gate_${gate}_failed" "gate=${gate}" "status=${rc}" \
      "display=config-gen gate ${gate} failed (docker exited ${rc})"
  elif [[ -z "${event}" ]]; then
    _log_err "${_CG_SERVICE}" config_gen_build_failed "status=${rc}" \
      "display=config-gen test stage failed before any gate (docker exited ${rc})"
  fi
  exit "${rc}"
}

# _cg_contract <root> <tmp> <context args...> -- build `final` and run it
# with no arguments: rc 2 and an empty stdout, or the run fails.
_cg_contract() {
  local root="${1}" tmp="${2}" rc=0 iid bytes
  shift 2
  docker build --progress=plain --target final --iidfile "${tmp}/iid" "$@" \
    -f "${root}/dockerfile/Dockerfile.config-gen" "${root}/dockerfile/config-gen" \
    >"${tmp}/final.log" 2>&1 || rc=$?
  if (( rc != 0 )); then
    cat "${tmp}/final.log" >&2
    _log_err "${_CG_SERVICE}" config_gen_build_failed "status=${rc}" \
      "display=config-gen final stage failed to build (docker exited ${rc})"
    exit "${rc}"
  fi
  iid="$(cat "${tmp}/iid")"
  rc=0
  docker run --rm --network none "${iid}" >"${tmp}/run.out" || rc=$?
  bytes="$(wc -c <"${tmp}/run.out")"
  bytes="${bytes//[[:space:]]/}"
  if (( rc != 2 || bytes != 0 )); then
    _log_err "${_CG_SERVICE}" config_gen_binary_contract_failed "status=${rc}" "stdout_bytes=${bytes}" \
      "display=config-gen with no arguments exited ${rc} with ${bytes} stdout byte(s); the contract is 2 and 0"
    exit 1
  fi
}

main() {
  local root="${_CG_SCRIPT_DIR}/../.." tmp
  while (( $# > 0 )); do
    case "${1}" in
      --root)
        if (( $# < 2 )); then
          _log_err "${_CG_SERVICE}" config_gen_usage_invalid "arg=${1}" \
            "display=config_gen_gates.sh: --root expects a directory"
          exit 2
        fi
        root="${2}"
        shift 2
        ;;
      *)
        _log_err "${_CG_SERVICE}" config_gen_usage_invalid "arg=${1}" \
          "display=config_gen_gates.sh: unknown argument ${1}; usage: config_gen_gates.sh [--root <dir>]"
        exit 2
        ;;
    esac
  done
  if [[ ! -f "${root}/dockerfile/Dockerfile.config-gen" ]]; then
    _log_err "${_CG_SERVICE}" config_gen_root_invalid "root=${root}" \
      "display=config-gen root ${root} holds no dockerfile/Dockerfile.config-gen"
    exit 2
  fi
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand ${tmp} now; it is local to main
  trap "rm -rf '${tmp}'" EXIT
  mkdir "${tmp}/ctx"
  _cg_run_steps "${root}" "${tmp}/ctx"
  local -a ctx_args=()
  local ctx_list
  ctx_list="$(_cg_context_args "${tmp}/ctx")" || exit 1
  [[ -z "${ctx_list}" ]] || mapfile -t ctx_args <<<"${ctx_list}"
  _cg_gates "${root}" "${tmp}/test.log" "${ctx_args[@]}"
  _cg_contract "${root}" "${tmp}" "${ctx_args[@]}"
}

main "$@"
