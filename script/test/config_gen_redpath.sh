#!/usr/bin/env bash
#
# config_gen_redpath.sh -- prove every config-gen gate can go red
# (base#1462).
#
# Usage:
#   ./script/test/config_gen_redpath.sh
#
# A gate that never fails is indistinguishable from a working one on a
# clean tree. So for each case below this copies dockerfile/ and the steps
# directory into a fresh scratch root, plants one defect there, and runs
# ./config_gen_gates.sh --root <copy>. Each case must exit non-zero, name
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
# A refusal case plants a defect the build must refuse before any gate
# runs: the run must exit exactly 1 with nothing on stdout, and stderr
# must carry the runner's JSON record of the case's event id and no
# "unregistered log body" (base#1465).
#
#   case        defect                                         event
#   no-context  a last step removes $CONFIG_GEN_CTX/mutation,  config_gen_manifest_missing
#               so the build gets no mutation context
#
# A stale case (base#1465) changes the module after the 00-manifest step
# wrote the host mutation baseline: admission must refuse it before any
# gate, so the run exits exactly 1 with nothing on stdout, stderr carries
# the runner's JSON config_gen_gate_admission_failed record and a JSON
# config_gen_manifest_stale record whose attributes file and reason are
# the case's, and no "unregistered log body".
#
#   case        change after 00                 file                                      reason
#   stale-edit     a line appended to main.go   dockerfile/config-gen/cmd/config-gen/main.go     sha_mismatch
#   stale-new-pkg  a new package internal/zznew  dockerfile/config-gen/internal/zznew/zznew.go   unlisted
#   stale-gomod    a line go cannot parse        dockerfile/config-gen/go.mod                     sha_mismatch
#                  appended to go.mod
#
# stale-gomod's go.mod makes every go command fail with go's own
# "go: errors parsing go.mod". In any stale case, that line or a BuildKit
# step header for a RUN that calls go (BuildKit prints the header when the
# step starts, even one it then cancels) means some go ran on the snapshot
# before admission refused it, and fails the case (reason
# go_ran_before_admission).
#
# The rerun case (base#1465) plants nothing: it calls the runner twice in
# a row on one unchanged copy. Each call must exit 0 and print exactly
#
#   gate=admission ok
#   gate=fmt ok
#   gate=vet ok
#   gate=lint ok
#   gate=race ok
#   gate=coverage ok
#
# on stdout, so a verdict RUN the second call took from the build cache
# (it prints no line) fails the case instead of passing on cache state.
#
# CONFIG_GEN_REDPATH_ONLY, when set, is a space-separated list of case
# names: only those cases run, then the control.
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
readonly -a _RP_GATES=(admission fmt vet lint race coverage)
# <case>:<the gate whose id it must produce>, in the order they run.
readonly -a _RP_CASES=(fmt:fmt vet:vet lint:lint race:race race-fuzz:race coverage:coverage fmt-parse:fmt)
# <case>:<the event id the build must refuse it with> (base#1465).
readonly -a _RP_REFUSALS=(no-context:config_gen_manifest_missing)
# <case>|<file>|<reason> the admission stale record must carry (base#1465).
readonly -a _RP_STALE=(
  'stale-edit|dockerfile/config-gen/cmd/config-gen/main.go|sha_mismatch'
  'stale-new-pkg|dockerfile/config-gen/internal/zznew/zznew.go|unlisted'
  'stale-gomod|dockerfile/config-gen/go.mod|sha_mismatch'
)

# _rp_plant <case> <root> -- write the case's defect into the copy.
_rp_plant() {
  local root="${2}" mod="${2}/dockerfile/config-gen" cmd="${2}/dockerfile/config-gen/cmd/config-gen"
  case "${1}" in
    no-context)
      # Runs after every real step (C-locale glob order) and takes away the
      # mutation context they wrote.
      cat >"${root}/script/test/config_gen_steps/99-zz-no-context.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
rm -rf -- "${CONFIG_GEN_CTX:?}/mutation"
EOF
      ;;
    stale-edit)
      # Runs after 00-manifest (C-locale glob order), so the baseline holds
      # main.go's sha256 from before this edit. The appended line is a
      # comment: every gate would still pass on the edited file.
      cat >"${root}/script/test/config_gen_steps/99-zz-stale-edit.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/../../.." && pwd -P)"
printf '\n// zz stale edit after the manifest\n' >>"${_root}/dockerfile/config-gen/cmd/config-gen/main.go"
EOF
      ;;
    stale-new-pkg)
      # Runs after 00-manifest, so the baseline lists neither file. The
      # package is fully covered by its own test: every gate would pass.
      cat >"${root}/script/test/config_gen_steps/99-zz-stale-new-pkg.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
_pkg="${_root}/dockerfile/config-gen/internal/zznew"
mkdir -p "${_pkg}"
cat >"${_pkg}/zznew.go" <<'GO'
// Package zznew is planted after the manifest.
package zznew

// One returns 1.
func One() int { return 1 }
GO
cat >"${_pkg}/zznew_test.go" <<'GO'
package zznew

import "testing"

func TestOne(t *testing.T) {
	if One() != 1 {
		t.Fatal("One() != 1")
	}
}
GO
EOF
      ;;
    stale-gomod)
      # Runs after 00-manifest, so the baseline holds go.mod's sha256 from
      # before this edit. go refuses to parse the appended directive.
      cat >"${root}/script/test/config_gen_steps/99-zz-stale-gomod.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
printf '\nzzstale after the manifest\n' >>"${_root}/dockerfile/config-gen/go.mod"
EOF
      ;;
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
# defect as the change; the target script, the admission checker the
# 01-admit step installs (base#1465) and the logger they source come
# along.
_rp_copy() {
  local dst
  dst="$(mktemp -d "${1}/root.XXXXXX")"
  cp -a "${_RP_ROOT}/dockerfile" "${dst}/"
  mkdir -p "${dst}/script/test" "${dst}/dist/script/docker/lib"
  if [[ -d "${_RP_ROOT}/script/test/config_gen_steps" ]]; then
    cp -a "${_RP_ROOT}/script/test/config_gen_steps" "${dst}/script/test/"
  fi
  cp -a "${_RP_ROOT}/script/test/config_gen_mutation_targets.sh" \
    "${_RP_ROOT}/script/test/config_gen_admit.sh" "${dst}/script/test/"
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
  _rp_plant "${name}" "${root}"
  _rp_gates "${root}" || rc=$?
  reason="$(_rp_verdict "${rc}" "${root}.out" "${root}.err" "${gate}")"
  [[ -z "${reason}" ]] && return 0
  cat "${root}.err" >&2
  _log_err "${_RP_SERVICE}" config_gen_redpath_case_failed "case=${name}" "reason=${reason}" "gate=${gate}" \
    "display=config-gen redpath case ${name} did not go red on gate ${gate}: ${reason}"
  return 1
}

# _rp_event_record_re <id> -- the runner's JSON record of <id>: a whole
# log line from service config-gen whose body is exactly <id>.
_rp_event_record_re() {
  printf '^\\{"timestamp":"[^"]*","severity_text":"ERROR","severity_number":[0-9]+,"body":"%s",("trace_id":"[^"]*","span_id":"[^"]*",)?"attributes":\\{"service\\.name":"config-gen",.*\\}\\}$' "${1}"
}

# _rp_refusal_verdict <rc> <out> <err> <id> -- empty when the build refused
# the case as planted, else the reason it did not.
_rp_refusal_verdict() {
  local rc="${1}" out="${2}" err="${3}" id="${4}"
  (( rc != 0 )) || { echo rc_zero; return 0; }
  (( rc == 1 )) || { echo rc_not_one; return 0; }
  [[ ! -s "${out}" ]] || { echo stdout_not_empty; return 0; }
  ! grep -qF 'unregistered log body' "${err}" || { echo unregistered_body; return 0; }
  grep -qE "$(_rp_event_record_re "${id}")" "${err}" || { echo wrong_id; return 0; }
}

# _rp_refusal <scratch> <case> <id> -- run one refusal case; non-zero when
# the build did not refuse it with <id>.
_rp_refusal() {
  local scratch="${1}" name="${2}" id="${3}" root rc=0 reason
  root="$(_rp_copy "${scratch}")"
  _rp_plant "${name}" "${root}"
  _rp_gates "${root}" || rc=$?
  reason="$(_rp_refusal_verdict "${rc}" "${root}.out" "${root}.err" "${id}")"
  [[ -z "${reason}" ]] && return 0
  cat "${root}.err" >&2
  _log_err "${_RP_SERVICE}" config_gen_redpath_case_failed "case=${name}" "reason=${reason}" "event=${id}" \
    "display=config-gen redpath case ${name} was not refused with ${id}: ${reason}"
  return 1
}

# A BuildKit step header for a RUN that calls a go subcommand.
readonly _RP_GO_STEP_RE='^#[0-9]+ \[[^]]+\] RUN .*(^|[ ;])go (build|vet|test|mod|list|run|generate|install) '

# _rp_stale_verdict <rc> <out> <err> <file> <reason> -- empty when
# admission refused the case with a stale record naming <file> and
# <reason>, else the reason it did not.
_rp_stale_verdict() {
  local rc="${1}" out="${2}" err="${3}" file="${4}" reason="${5}" got
  (( rc != 0 )) || { echo rc_zero; return 0; }
  (( rc == 1 )) || { echo rc_not_one; return 0; }
  [[ ! -s "${out}" ]] || { echo stdout_not_empty; return 0; }
  ! grep -qF 'unregistered log body' "${err}" || { echo unregistered_body; return 0; }
  ! grep -qF 'go: errors parsing go.mod' "${err}" || { echo go_ran_before_admission; return 0; }
  ! grep -qE "${_RP_GO_STEP_RE}" "${err}" || { echo go_ran_before_admission; return 0; }
  grep -qE "$(_rp_event_record_re config_gen_gate_admission_failed)" "${err}" || { echo gate_record_missing; return 0; }
  got="$(jq -Rr 'fromjson? | select(type == "object" and .body == "config_gen_manifest_stale"
    and .attributes."service.name" == "config-gen") | "\(.attributes.file)|\(.attributes.reason)"' "${err}")"
  [[ -n "${got}" ]] || { echo stale_record_missing; return 0; }
  [[ "${got}" == "${file}|${reason}" ]] || { echo stale_detail_mismatch; return 0; }
}

# _rp_stale <scratch> <case> <file> <reason> -- run one stale case;
# non-zero when admission did not refuse it with <file> and <reason>.
_rp_stale() {
  local scratch="${1}" name="${2}" file="${3}" want="${4}" root rc=0 reason
  root="$(_rp_copy "${scratch}")"
  _rp_plant "${name}" "${root}"
  _rp_gates "${root}" || rc=$?
  reason="$(_rp_stale_verdict "${rc}" "${root}.out" "${root}.err" "${file}" "${want}")"
  [[ -z "${reason}" ]] && return 0
  cat "${root}.err" >&2
  _log_err "${_RP_SERVICE}" config_gen_redpath_case_failed "case=${name}" "reason=${reason}" \
    "event=config_gen_manifest_stale" \
    "display=config-gen redpath case ${name} was not refused as stale (file=${file} reason=${want}): ${reason}"
  return 1
}

# The six lines each rerun call must print, typed from the issue's gate
# list (base#1465), not derived from _RP_GATES.
readonly _RP_RERUN_OUT='gate=admission ok
gate=fmt ok
gate=vet ok
gate=lint ok
gate=race ok
gate=coverage ok'

# _rp_rerun_verdict <rc> <out> -- empty when one rerun call passed with
# exactly the six ok lines, else the reason it did not.
_rp_rerun_verdict() {
  local rc="${1}" out="${2}"
  (( rc == 0 )) || { echo rc_not_zero; return 0; }
  printf '%s\n' "${_RP_RERUN_OUT}" | cmp -s - "${out}" || { echo stdout_mismatch; return 0; }
}

# _rp_rerun <scratch> -- run the runner twice on one unchanged copy;
# non-zero when either call did not pass with exactly the six ok lines.
_rp_rerun() {
  local root rc call reason
  root="$(_rp_copy "${1}")"
  for call in 1 2; do
    rc=0
    _rp_gates "${root}" || rc=$?
    reason="$(_rp_rerun_verdict "${rc}" "${root}.out")"
    [[ -z "${reason}" ]] && continue
    cat "${root}.err" >&2
    _log_err "${_RP_SERVICE}" config_gen_redpath_case_failed "case=rerun" "call=${call}" "reason=${reason}" \
      "display=config-gen redpath case rerun: call ${call} of 2 did not print exactly the six ok lines: ${reason}"
    return 1
  done
}

# _rp_selected <case> -- true unless CONFIG_GEN_REDPATH_ONLY is set and
# does not name <case>.
_rp_selected() {
  [[ -z "${CONFIG_GEN_REDPATH_ONLY:-}" ]] && return 0
  [[ " ${CONFIG_GEN_REDPATH_ONLY} " == *" ${1} "* ]]
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
  local scratch entry failed=0 ran=0
  scratch="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand ${scratch} now; it is local to main
  trap "rm -rf '${scratch}'" EXIT
  for entry in "${_RP_CASES[@]}"; do
    _rp_selected "${entry%%:*}" || continue
    ran=$(( ran + 1 ))
    _rp_case "${scratch}" "${entry%%:*}" "${entry#*:}" || failed=1
  done
  for entry in "${_RP_REFUSALS[@]}"; do
    _rp_selected "${entry%%:*}" || continue
    ran=$(( ran + 1 ))
    _rp_refusal "${scratch}" "${entry%%:*}" "${entry#*:}" || failed=1
  done
  local name file want
  for entry in "${_RP_STALE[@]}"; do
    IFS='|' read -r name file want <<<"${entry}"
    _rp_selected "${name}" || continue
    ran=$(( ran + 1 ))
    _rp_stale "${scratch}" "${name}" "${file}" "${want}" || failed=1
  done
  if _rp_selected rerun; then
    ran=$(( ran + 1 ))
    _rp_rerun "${scratch}" || failed=1
  fi
  _rp_control "${scratch}" || failed=1
  (( failed == 0 )) || exit 1
  echo "config-gen redpath: ${ran} planted defects went red or were refused; the control passed"
}

main "$@"
