#!/usr/bin/env bash
#
# config_gen_redpath.sh -- prove every config-gen gate can go red
# (base#1462).
#
# Usage:
#   ./script/test/config_gen_redpath.sh
#
# A gate that never fails is indistinguishable from a working one on a
# clean tree. So for each case below this copies dockerfile/, the steps
# directory and what the steps read (script/watch, the log library, the
# go.mod fixtures) into a fresh scratch root, plants one defect there, and
# runs ./config_gen_gates.sh --root <copy>. Each case must exit non-zero, name
# its own gate's id first, and show every earlier gate ok -- the last is
# what tells "this gate caught it" from "the build broke first". An
# unmodified copy, the control, runs last and must pass all five gates, so
# the reds are the defects' and not the copy's.
#
#   case       defect                                         gate
#   fmt        a misformatted .go file                        fmt
#   vet        fmt.Printf("%d", "x")                          vet
#   lint       an unchecked os.Remove error                   lint
#   race       two goroutines incrementing one int, joined    race
#   race-fuzz  a Fuzz seed that fails                         race
#   coverage   a package whose test covers 2 of 3 statements  coverage
#   fmt-parse  a _test.go file gofmt cannot parse             fmt
#
# fmt-parse plants in a _test.go file because go build skips those, so the
# build stage passes and the syntax error reaches the fmt gate, where
# gofmt exits non-zero instead of listing a file.
#
# Every case is reported before the run ends; any failed case or a red
# control exits 1. This never calls `just test go` -- that recipe runs this
# script -- and a nested entry is refused with config_gen_redpath_reentered
# before anything runs.
#
# Style: Google Shell Style Guide.

set -euo pipefail

_RP_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
readonly _RP_SCRIPT_DIR
readonly _RP_ROOT="${_RP_SCRIPT_DIR}/../.."
# shellcheck source=dist/script/docker/lib/log.sh
source "${_RP_ROOT}/dist/script/docker/lib/log.sh"

readonly _RP_SERVICE='config-gen'
readonly -a _RP_GATES=(fmt vet lint race coverage)
# <case>:<the gate whose id it must produce>, in the order they run.
readonly -a _RP_CASES=(fmt:fmt vet:vet lint:lint race:race race-fuzz:race coverage:coverage fmt-parse:fmt)

# _rp_plant <case> <module dir> -- write the case's defect into the copy.
_rp_plant() {
  local mod="${2}" cmd="${2}/cmd/config-gen"
  case "${1}" in
    fmt)
      printf 'package main\n\nfunc  zzFmt( ) {}\n' >"${cmd}/zz_fmt.go" ;;
    vet)
      printf 'package main\n\nimport "fmt"\n\nfunc zzVet() { fmt.Printf("%%d", "x") }\n' >"${cmd}/zz_vet.go" ;;
    lint)
      printf 'package main\n\nimport "os"\n\nfunc zzLint() { os.Remove("zz") }\n' >"${cmd}/zz_lint.go" ;;
    race)
      cat >"${cmd}/zz_race_test.go" <<'EOF'
package main

import (
	"sync"
	"testing"
)

func TestZzRace(t *testing.T) {
	var wg sync.WaitGroup
	start := make(chan struct{})
	shared := 0
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			for j := 0; j < 1000; j++ {
				shared++
			}
		}()
	}
	close(start)
	wg.Wait()
	_ = shared
}
EOF
      ;;
    race-fuzz)
      cat >"${cmd}/zz_fuzz_test.go" <<'EOF'
package main

import "testing"

func FuzzZz(f *testing.F) {
	f.Add("boom")
	f.Fuzz(func(t *testing.T, s string) {
		if s == "boom" {
			t.Fatal("the seed boom fails")
		}
	})
}
EOF
      ;;
    fmt-parse)
      printf 'package main\n\nfunc zzParse() {\n' >"${cmd}/zz_parse_test.go" ;;
    coverage)
      mkdir -p "${mod}/internal/zzcov"
      cat >"${mod}/internal/zzcov/zzcov.go" <<'EOF'
// Package zzcov is a planted coverage defect.
package zzcov

// Sign reports the sign of n.
func Sign(n int) int {
	if n < 0 {
		return -1
	}
	return 1
}
EOF
      cat >"${mod}/internal/zzcov/zzcov_test.go" <<'EOF'
package zzcov

import "testing"

func TestSign(t *testing.T) {
	if Sign(1) != 1 {
		t.Fatal("Sign(1) != 1")
	}
}
EOF
      ;;
  esac
}

# _rp_copy <scratch> -- a fresh copy of what the runner reads; prints it.
# The copy is a one-commit Git checkout whose origin/main is that commit,
# so the 00-manifest step (base#1464) finds a base and lists the planted
# defect as the change; the target script and the logger it sources come
# along.
_rp_copy() {
  local dst
  dst="$(mktemp -d "${1}/root.XXXXXX")"
  cp -a "${_RP_ROOT}/dockerfile" "${dst}/"
  mkdir -p "${dst}/script/test" "${dst}/dist/script/docker/lib"
  if [[ -d "${_RP_ROOT}/script/test/config_gen_steps" ]]; then
    cp -a "${_RP_ROOT}/script/test/config_gen_steps" "${dst}/script/test/"
  fi
  # The go.mod oracle step (base#1463) runs the pin registry's scanner,
  # with its logger, over the go.mod fixtures -- each read relative to the
  # step's own root, so the copy carries all three. The logger and its
  # event registry are the log.sh copy below.
  mkdir -p "${dst}/test/fixtures"
  cp -a "${_RP_ROOT}/script/watch" "${dst}/script/"
  cp -a "${_RP_ROOT}/test/fixtures/gomod" "${dst}/test/fixtures/"
  cp -a "${_RP_ROOT}/script/test/config_gen_mutation_targets.sh" "${dst}/script/test/"
  cp -a "${_RP_ROOT}/dist/script/docker/lib/log.sh" "${_RP_ROOT}/dist/script/docker/lib/log-events.txt" \
    "${dst}/dist/script/docker/lib/"
  git -C "${dst}" init -q
  git -C "${dst}" add -A
  git -C "${dst}" -c user.name=config-gen-redpath -c user.email=config-gen-redpath@localhost \
    commit -q --no-verify --no-gpg-sign -m "config-gen redpath copy"
  git -C "${dst}" update-ref refs/remotes/origin/main HEAD
  printf '%s\n' "${dst}"
}

# _rp_gates <root> -- run the runner on <root>, its stdout to <root>.out
# and its stderr to <root>.err; returns the runner's status. Its log is
# JSON whatever the caller set, because _rp_verdict reads its records.
# The mutation context is pr with no base override whatever the caller
# inherited (base#1464): a CI main push exports main-push, and a
# one-commit copy has no HEAD^1.
_rp_gates() {
  env -u CONFIG_GEN_MUTATION_BASE CONFIG_GEN_MUTATION_CONTEXT=pr LOG_FORMAT=json \
    bash "${_RP_SCRIPT_DIR}/config_gen_gates.sh" --root "${1}" >"${1}.out" 2>"${1}.err"
}

# The runner's own record of the gate that went red: a whole JSON log line
# from service config-gen whose body is exactly a gate id. The build log
# streamed ahead of it, an id quoted inside other text and a longer id that
# starts with one are none of them that record (base#1462).
readonly _RP_GATE_RECORD_RE='^\{"timestamp":"[^"]*","severity_text":"ERROR","severity_number":[0-9]+,"body":"(config_gen_gate_[a-z]+_failed)",("trace_id":"[^"]*","span_id":"[^"]*",)?"attributes":\{"service\.name":"config-gen",.*\}\}$'

# _rp_verdict <rc> <out> <err> <gate> -- empty when the case went red as
# planted, else the reason it did not.
_rp_verdict() {
  local rc="${1}" out="${2}" err="${3}" gate="${4}" first g
  (( rc != 0 )) || { echo rc_zero; return 0; }
  # No record at all is a wrong id: first stays empty.
  first="$(sed -nE "s/${_RP_GATE_RECORD_RE}/\\1/p" "${err}")"
  first="${first%%$'\n'*}"
  [[ "${first}" == "config_gen_gate_${gate}_failed" ]] || { echo wrong_id; return 0; }
  for g in "${_RP_GATES[@]}"; do
    [[ "${g}" == "${gate}" ]] && break
    grep -qx "gate=${g} ok" "${out}" || { echo earlier_gate_missing; return 0; }
  done
}

# _rp_case <scratch> <case> <gate> -- run one planted case; non-zero when
# it did not go red as planted.
_rp_case() {
  local scratch="${1}" name="${2}" gate="${3}" root rc=0 reason
  root="$(_rp_copy "${scratch}")"
  _rp_plant "${name}" "${root}/dockerfile/config-gen"
  _rp_gates "${root}" || rc=$?
  reason="$(_rp_verdict "${rc}" "${root}.out" "${root}.err" "${gate}")"
  [[ -z "${reason}" ]] && return 0
  cat "${root}.err" >&2
  _log_err "${_RP_SERVICE}" config_gen_redpath_case_failed "case=${name}" "reason=${reason}" "gate=${gate}" \
    "display=config-gen redpath case ${name} did not go red on gate ${gate}: ${reason}"
  return 1
}

# _rp_control <scratch> -- the unmodified copy must pass every gate.
_rp_control() {
  local root rc=0 g
  root="$(_rp_copy "${1}")"
  _rp_gates "${root}" || rc=$?
  if (( rc == 0 )); then
    for g in "${_RP_GATES[@]}"; do
      grep -qx "gate=${g} ok" "${root}.out" || rc=1
    done
    (( rc == 0 )) && return 0
  fi
  cat "${root}.err" >&2
  _log_err "${_RP_SERVICE}" config_gen_redpath_control_failed "status=${rc}" \
    "display=config-gen redpath control (no defect) did not pass every gate: status ${rc}"
  return 1
}

main() {
  if [[ -n "${CONFIG_GEN_REDPATH_ACTIVE:-}" ]]; then
    _log_err "${_RP_SERVICE}" config_gen_redpath_reentered \
      "display=config_gen_redpath.sh entered from inside a redpath run; refusing to recurse"
    exit 1
  fi
  export CONFIG_GEN_REDPATH_ACTIVE=1
  local scratch entry failed=0
  scratch="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand ${scratch} now; it is local to main
  trap "rm -rf '${scratch}'" EXIT
  for entry in "${_RP_CASES[@]}"; do
    _rp_case "${scratch}" "${entry%%:*}" "${entry#*:}" || failed=1
  done
  _rp_control "${scratch}" || failed=1
  (( failed == 0 )) || exit 1
  echo "config-gen redpath: ${#_RP_CASES[@]} planted defects went red on their gates; the control passed"
}

main "$@"
