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
# unmodified copy, the control, runs last and must pass all six gates, so
# the reds are the defects' and not the copy's.
#
#   case           defect                                          gate
#   fmt            a misformatted .go file                         fmt
#   vet            fmt.Printf("%d", "x")                           vet
#   lint           an unchecked os.Remove error                    lint
#   race           two goroutines incrementing one int, joined     race
#   race-fuzz      a Fuzz seed that fails                          race
#   coverage       a package whose test covers 2 of 3 statements   coverage
#   fmt-parse      a _test.go file gofmt cannot parse              fmt
#   corpus-join    a test reading ../../testdata, not testcorpus   race
#   corpus-helper  a non-test helper a test calls reads testdata   race
#   corpus-var     a test spelling the path as "test"+"data"       race
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
# A stale case (base#1465, _RP_STALE) changes the module, or the mutation
# context, after the 00-manifest and 01-admit steps wrote it: the admit
# stage must refuse it before any gate, so the run exits exactly 1 with
# nothing on stdout, stderr carries the runner's JSON
# config_gen_gate_admission_failed record and a JSON
# config_gen_manifest_stale record whose attributes file and reason are
# the case's, and no "unregistered log body". The stale-* rows edit, add,
# delete or link a module file (stale-checker plants a syntax error in
# internal/buildgate, the ratchet's own package, so nothing built from the
# snapshot can be what refuses it); no-checker and no-lib take the checker
# or its library out of the context; each tamper-* row rewrites the
# baseline into bytes the producer cannot write for the module on disk,
# one admission rule each.
#
# In any stale case, go's "go: errors parsing go.mod" (stale-gomod's
# go.mod makes every go command print it) or a BuildKit step header for a
# RUN that calls go (BuildKit prints the header when the step starts, even
# one it then cancels) means some go ran on the snapshot before admission
# refused it, and fails the case (reason go_ran_before_admission).
#
# A green case (_RP_GREENS) brings the copy to a git state a real producer
# run was observed to write (base#1465 redesign r2 §1) -- a rename with the
# old path recreated, a tracked file untracked, a rename onto a moved file,
# a removed path left ignored, two copies under diff.renames=copies, a
# typechange to a symlink -- or to a baseline holding café.txt, `a b.txt`
# and one name per byte 0x01-0x7f but /. Each must exit 0 and print exactly
# the six ok lines below: admission accepts every baseline the producer
# writes, and every gate still runs after it.
#
# A coverage case (_RP_COVERAGE) changes a package or a floor so the
# coverage ratchet (cmd/cg-gates ratchet, base#1465) refuses it: the run
# must exit exactly 1 with exactly the five pre-coverage ok lines on
# stdout, the runner's JSON config_gen_gate_coverage_failed record, and its
# JSON record of the case's config_gen_coverage_* event naming the row's
# package (pkg) and fragment (file, empty when the event names none).
# cov-lowered lowers a floor below the copy's own commit, its merge base:
# only a coverage RUN that read floors.base through the mutation context
# can see that.
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
# Each runner call is told its case in CONFIG_GEN_REDPATH_CASE (control for
# the control), which the runner itself ignores.
#
# CONFIG_GEN_REDPATH_ONLY, when set, is a space-separated list of case
# names: only those cases run, then the control.
#
# fmt-parse plants in a _test.go file because go build skips those, so the
# build stage passes and the syntax error reaches the fmt gate, where
# gofmt exits non-zero instead of listing a file.
#
# corpus-join reads the shared corpus by a joined relative path instead of
# through internal/testcorpus. The race gate moves testdata out of the
# module before the tests run, so that read finds nothing and the gate goes
# red (base#1468). corpus-helper does the same read from a non-test helper
# package that a test in another package calls, so the gate cannot key on
# the test file's own source. corpus-var spells the directory name as the
# constant expression "test" + "data", which the compiler folds; the
# string testdata never appears in the planted source, so a scan of the
# source text for it cannot be what turns the gate red.
#
# Every case is reported before the run ends; any failed case or a red
# control exits 1. This never calls `just test go` -- that recipe runs this
# script -- and a nested entry is refused with config_gen_redpath_reentered
# before anything runs. Sourced, it defines its tables and functions and
# runs nothing.
#
# Style: Google Shell Style Guide.

# Strict mode only when run; sourced, the caller's settings stand (#869).
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  set -euo pipefail
fi

_RP_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
readonly _RP_SCRIPT_DIR
readonly _RP_ROOT="${_RP_SCRIPT_DIR}/../.."
# shellcheck source=dist/script/docker/lib/log.sh
source "${_RP_ROOT}/dist/script/docker/lib/log.sh"

readonly _RP_SERVICE='config-gen'
readonly -a _RP_GATES=(admission fmt vet lint race coverage)
# <case>:<the gate whose id it must produce>, in the order they run.
readonly -a _RP_CASES=(fmt:fmt vet:vet lint:lint race:race race-fuzz:race coverage:coverage fmt-parse:fmt corpus-join:race corpus-helper:race corpus-var:race)
# <case>:<the event id the build must refuse it with> (base#1465).
readonly -a _RP_REFUSALS=(no-context:config_gen_manifest_missing)
# <case>|<file>|<reason> the admission stale record must carry (base#1465).
readonly -a _RP_STALE=(
  'stale-edit|dockerfile/config-gen/cmd/config-gen/main.go|sha_mismatch'
  'stale-new-pkg|dockerfile/config-gen/internal/zznew/zznew.go|unlisted'
  'stale-delete|dockerfile/config-gen/cmd/config-gen/main_test.go|missing'
  'stale-symlink|dockerfile/config-gen/cmd/config-gen/zz.go|unlisted'
  'stale-dangling|dockerfile/config-gen/zz-dangling|not_regular'
  'stale-gomod|dockerfile/config-gen/go.mod|sha_mismatch'
  'stale-checker|dockerfile/config-gen/internal/buildgate/zz.go|unlisted'
  'stale-names|dockerfile/config-gen/zznames/a%20b.txt|sha_mismatch'
  'stale-header|manifest|header'
  'no-checker|admit.sh|absent'
  'no-lib|config_gen_mutation_lang.sh|absent'
  'tamper-r-garbage|manifest|record'
  'tamper-r999|manifest|record'
  'tamper-r101|manifest|record'
  'tamper-copy|manifest|record'
  'tamper-arity|manifest|record'
  'tamper-rename-self|manifest|presence'
  'tamper-ghost|manifest|presence'
  'tamper-delete-listed|manifest|presence'
  'tamper-add-twice|manifest|duplicate'
  'tamper-src-twice|manifest|presence'
  'tamper-modify-over-src|manifest|presence'
  'tamper-header-mixed|manifest|header'
  'tamper-header-dirty|manifest|header'
  'tamper-header-context|manifest|header'
  'tamper-marker-twice|manifest|none_marker'
  'tamper-header-only|manifest|body_empty'
  'tamper-manifest-unterminated|manifest|malformed'
  'tamper-visible-unterminated|visible.sha256|malformed'
  'tamper-ignored-unterminated|ignored.sha256|malformed'
  'tamper-crlf|manifest|header'
  'tamper-dotdot|manifest|path'
  'tamper-outside|manifest|path'
  'tamper-visible-dup|visible.sha256|duplicate'
  'tamper-dual|ignored.sha256|dual'
)
# The green cases: each a git state whose baseline must be admitted
# (base#1465).
readonly -a _RP_GREENS=(names rename-recreate untrack rename-move untrack-ignored copies typechange)
# <case>|<the coverage ratchet event the build must refuse it with>|<its
# pkg>|<its file, empty when the event names none> (base#1465).
readonly -a _RP_COVERAGE=(
  'cov-drop|config_gen_coverage_floor_below|cmd/config-gen|'
  'cov-lowered|config_gen_coverage_floor_lowered|internal/buildgate|'
  'cov-stale|config_gen_coverage_floor_stale|internal/buildgate|'
  'cov-missing|config_gen_coverage_floor_missing|internal/zzmiss|'
  'cov-duplicate|config_gen_coverage_floor_duplicate|internal/testcorpus|s1g.txt'
  'cov-dropped|config_gen_coverage_floor_dropped|internal/testcorpus|'
)

# _rp_stale_body <case> -- the shell a stale case's step runs, with _mod
# (the module), _m (the mutation context), P (the module prefix), h (the
# manifest's header line) and vis (visible.sha256's first line) set.
# Each body is shell text the step runs, printed verbatim: nothing in it
# expands here.
# shellcheck disable=SC2016,SC2028
_rp_stale_body() {
  case "${1}" in
    stale-edit)
      # The appended line is a comment: every gate would pass on it.
      echo 'printf "\n// zz stale edit after the manifest\n" >>"${_mod}/cmd/config-gen/main.go"' ;;
    stale-new-pkg)
      # The package is fully covered by its own test, but no coverage
      # floor names it: the coverage ratchet refuses it as
      # config_gen_coverage_floor_missing when it is planted before the
      # manifest (cov-missing, the same source as internal/zzmiss).
      # Admission must refuse it here first. No floor is planted with it:
      # a floor appended to coverage-floors.d/s1e.txt after the manifest
      # is refused first, as that file's sha_mismatch, so the case would
      # no longer be about zznew.go. (base#1465)
      cat <<'STEP'
mkdir -p "${_mod}/internal/zznew"
printf '// Package zznew is planted after the manifest.\npackage zznew\n\n// One returns 1.\nfunc One() int { return 1 }\n' >"${_mod}/internal/zznew/zznew.go"
printf 'package zznew\n\nimport "testing"\n\nfunc TestOne(t *testing.T) {\n\tif One() != 1 {\n\t\tt.Fatal("One")\n\t}\n}\n' >"${_mod}/internal/zznew/zznew_test.go"
STEP
      ;;
    stale-delete) echo 'rm "${_mod}/cmd/config-gen/main_test.go"' ;;
    stale-symlink) echo 'ln -s main.go "${_mod}/cmd/config-gen/zz.go"' ;;
    stale-dangling) echo 'ln -s /nonexistent/zz "${_mod}/zz-dangling"' ;;
    # go refuses to parse the appended directive.
    stale-gomod) echo 'printf "\nzzstale after the manifest\n" >>"${_mod}/go.mod"' ;;
    stale-checker) echo 'printf "package buildgate\n\nfunc zz( {\n" >"${_mod}/internal/buildgate/zz.go"' ;;
    stale-names) echo 'printf "edit\n" >>"${_mod}/zznames/a b.txt"' ;;
    # The header without its context= field, which S1d's header never is.
    stale-header) echo 'sed -i "1s/ context=[^ ]*\$//" "${_m}/manifest"' ;;
    no-checker) echo 'rm "${_m}/admit.sh"' ;;
    no-lib) echo 'rm "${_m}/config_gen_mutation_lang.sh"' ;;
    tamper-r-garbage) echo 'printf "%s\nRgarbage\t%s/go.mod\t%s/zz.go\n" "${h}" "${P}" "${P}" >"${_m}/manifest"' ;;
    tamper-r999) echo 'printf "%s\nR999\t%s/zz.go\t%s/go.mod\n" "${h}" "${P}" "${P}" >"${_m}/manifest"' ;;
    tamper-r101) echo 'printf "%s\nR101\t%s/zz.go\t%s/go.mod\n" "${h}" "${P}" "${P}" >"${_m}/manifest"' ;;
    tamper-copy) echo 'printf "%s\nC100\t%s/zz.go\t%s/go.mod\n" "${h}" "${P}" "${P}" >"${_m}/manifest"' ;;
    tamper-arity) echo 'printf "%s\nM\t%s/go.mod\t%s/zz.go\n" "${h}" "${P}" "${P}" >"${_m}/manifest"' ;;
    tamper-rename-self) echo 'printf "%s\nR100\t%s/go.mod\t%s/go.mod\n" "${h}" "${P}" "${P}" >"${_m}/manifest"' ;;
    tamper-ghost) echo 'printf "%s\nM\t%s/ghost.go\n" "${h}" "${P}" >"${_m}/manifest"' ;;
    tamper-delete-listed) echo 'printf "%s\nD\t%s/go.mod\n" "${h}" "${P}" >"${_m}/manifest"' ;;
    tamper-add-twice) echo 'printf "%s\nA\t%s/go.mod\nA\t%s/go.mod\n" "${h}" "${P}" "${P}" >"${_m}/manifest"' ;;
    tamper-src-twice) echo 'printf "%s\nD\t%s/zz.go\nR100\t%s/zz.go\t%s/go.mod\n" "${h}" "${P}" "${P}" "${P}" >"${_m}/manifest"' ;;
    tamper-modify-over-src) echo 'printf "%s\nD\t%s/go.mod\nM\t%s/go.mod\n" "${h}" "${P}" "${P}" >"${_m}/manifest"' ;;
    tamper-header-mixed)
      echo 'printf "base=%s head=%s dirty=no context=pr\nnone: no-go-change\n" "$(printf "a%.0s" {1..40})" "$(printf "b%.0s" {1..64})" >"${_m}/manifest"' ;;
    tamper-header-dirty) echo 'sed -i "1s/ dirty=[a-z]* / dirty=maybe /" "${_m}/manifest"' ;;
    tamper-header-context) echo 'sed -i "1s/ context=[a-z-]*\$/ context=x/" "${_m}/manifest"' ;;
    tamper-marker-twice) echo 'printf "%s\nnone: no-go-change\nnone: no-go-change\n" "${h}" >"${_m}/manifest"' ;;
    tamper-header-only) echo 'printf "%s\n" "${h}" >"${_m}/manifest"' ;;
    tamper-manifest-unterminated) echo 'printf "%s\nnone: no-go-change" "${h}" >"${_m}/manifest"' ;;
    tamper-visible-unterminated) echo 'v="$(cat "${_m}/visible.sha256")"; printf "%s" "${v}" >"${_m}/visible.sha256"' ;;
    tamper-ignored-unterminated) echo 'printf "%s/zz\t%s" "${P}" "$(printf "b%.0s" {1..64})" >"${_m}/ignored.sha256"' ;;
    tamper-crlf) echo 'printf "%s\r\nnone: no-go-change\r\n" "${h}" >"${_m}/manifest"' ;;
    tamper-dotdot) echo 'printf "%s\nM\t%s/../go.mod\n" "${h}" "${P}" >"${_m}/manifest"' ;;
    tamper-outside) echo 'printf "%s\nM\t%sx/go.mod\n" "${h}" "${P}" >"${_m}/manifest"' ;;
    tamper-visible-dup) echo 'printf "%s\n" "${vis}" >>"${_m}/visible.sha256"' ;;
    tamper-dual) echo 'printf "%s\n" "${vis}" >"${_m}/ignored.sha256"' ;;
    *) return 1 ;;
  esac
}

# _rp_step <root> <case> -- write the stale case's step: it runs after
# every real step (C-locale glob order), so after 00-manifest wrote the
# baseline and 01-admit installed the checker.
_rp_step() {
  local body
  body="$(_rp_stale_body "${2}")"
  cat >"${1}/script/test/config_gen_steps/99-zz-${2}.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
_root="\$(cd -- "\$(dirname -- "\${BASH_SOURCE[0]:-\$0}")/../../.." && pwd -P)"
_mod="\${_root}/dockerfile/config-gen"
_m="\${CONFIG_GEN_CTX:?}/mutation"
P=dockerfile/config-gen
h="\$(head -n 1 "\${_m}/manifest")"
vis="\$(head -n 1 "\${_m}/visible.sha256")"
: "\${_mod}" "\${P}" "\${h}" "\${vis}"
${body}
EOF
}

# _rp_git <root> <args...> -- git in the copy, as the copy's committer.
_rp_git() {
  local root="${1}"
  shift
  git -C "${root}" -c user.name=config-gen-redpath -c user.email=config-gen-redpath@localhost \
    -c commit.gpgsign=false "$@"
}

# _rp_rebase <root> -- commit the copy's work tree and make that commit its
# origin/main, so only a later change is one 00-manifest lists.
_rp_rebase() {
  _rp_git "${1}" add -A
  _rp_git "${1}" commit -q --no-verify -m "config-gen redpath base"
  _rp_git "${1}" update-ref refs/remotes/origin/main HEAD
}

# _rp_green <case> <root> -- bring the copy to a green case's git state:
# zzg/a.txt and zzg/c.txt committed as the base, then the case's change.
# names commits zznames/ (café.txt, `a b.txt`, one name holding every byte
# 0x01-0x7f but /) and leaves an untracked name the producer C-quotes.
_rp_green() {
  local root="${2}" g="${2}/dockerfile/config-gen/zzg" n="${2}/dockerfile/config-gen/zznames"
  local name='' i
  if [[ "${1}" == names ]]; then
    mkdir -p "${n}"
    for (( i = 1; i < 128; i++ )); do
      (( i == 0x2f )) && continue
      # shellcheck disable=SC2059 # the byte is the format's \xHH escape
      name+="$(printf "\\x$(printf '%02x' "${i}")")"
    done
    printf 'x\n' >"${n}/café.txt"
    printf 'x\n' >"${n}/a b.txt"
    printf 'x\n' >"${n}/${name}"$'\n'
    _rp_rebase "${root}"
    printf 'y\n' >"${n}/zz\"q.txt"
    return 0
  fi
  mkdir -p "${g}"
  printf 'a\n' >"${g}/a.txt"
  printf 'c\n' >"${g}/c.txt"
  _rp_rebase "${root}"
  case "${1}" in
    rename-recreate) _rp_git "${root}" mv "${g}/a.txt" "${g}/d.txt"; printf 'new\n' >"${g}/a.txt" ;;
    untrack) _rp_git "${root}" rm -q --cached "${g}/a.txt" ;;
    rename-move) _rp_git "${root}" mv "${g}/a.txt" "${g}/d.txt"; mv "${g}/c.txt" "${g}/a.txt" ;;
    untrack-ignored)
      printf 'dockerfile/config-gen/zzg/a.txt\n' >"${root}/.git/info/exclude"
      _rp_git "${root}" rm -q --cached "${g}/a.txt"
      ;;
    copies)
      _rp_git "${root}" config diff.renames copies
      cp "${g}/a.txt" "${g}/e.txt"
      cp "${g}/a.txt" "${g}/f.txt"
      _rp_git "${root}" add -A
      ;;
    typechange) rm "${g}/a.txt"; ln -s c.txt "${g}/a.txt" ;;
  esac
}

# _rp_floor <root> <pkg> <floor> -- set <pkg>'s floor in the copy's
# coverage-floors.d/s1e.txt.
_rp_floor() {
  sed -i "s#^${2} .*#${2} ${3}#" "${1}/dockerfile/config-gen/coverage-floors.d/s1e.txt"
}

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
    stale-names)
      # The names baseline, then the edit after 00.
      _rp_green names "${root}"
      _rp_step "${root}" "${1}"
      ;;
    stale-* | no-checker | no-lib | tamper-*)
      _rp_step "${root}" "${1}"
      ;;
    names | rename-recreate | untrack | rename-move | untrack-ignored | copies | typechange)
      _rp_green "${1}" "${root}"
      ;;
    cov-drop)
      # Two statements no test reaches: cmd/config-gen falls below 100.0.
      printf 'package main\n\nfunc zzDrop(n int) int {\n\tif n > 0 {\n\t\treturn n\n\t}\n\treturn -n\n}\n' \
        >"${cmd}/zz_drop.go"
      ;;
    cov-lowered)
      # The copy's own commit is its merge base, so floors.base holds 97.9.
      _rp_floor "${root}" internal/buildgate 97.8
      ;;
    cov-stale)
      # 96.0 in the base and in the head, with 97.9 measured.
      _rp_floor "${root}" internal/buildgate 96.0
      _rp_rebase "${root}"
      ;;
    cov-missing)
      # A fully covered package with no floor.
      mkdir -p "${mod}/internal/zzmiss"
      printf '// Package zzmiss has no floor.\npackage zzmiss\n\n// One returns 1.\nfunc One() int { return 1 }\n' \
        >"${mod}/internal/zzmiss/zzmiss.go"
      printf 'package zzmiss\n\nimport "testing"\n\nfunc TestOne(t *testing.T) {\n\tif One() != 1 {\n\t\tt.Fatal("One")\n\t}\n}\n' \
        >"${mod}/internal/zzmiss/zzmiss_test.go"
      ;;
    cov-duplicate)
      printf 'internal/testcorpus 96.0\n' >"${mod}/coverage-floors.d/s1z.txt"
      ;;
    cov-dropped)
      # The fragment goes while its package stays.
      rm "${mod}/coverage-floors.d/s1g.txt"
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
    corpus-join)
      mkdir -p "${mod}/internal/zzjoin"
      cat >"${mod}/internal/zzjoin/zzjoin_test.go" <<'EOF'
package zzjoin

import (
	"os"
	"path/filepath"
	"testing"
)

func TestZzJoin(t *testing.T) {
	if _, err := os.ReadFile(filepath.Join("..", "..", "testdata", "golden", "s1", "seed.golden")); err != nil {
		t.Fatal(err)
	}
}
EOF
      ;;
    corpus-helper)
      mkdir -p "${mod}/internal/zzhelp" "${mod}/internal/zzhelpuser"
      cat >"${mod}/internal/zzhelp/zzhelp.go" <<'EOF'
// Package zzhelp is a planted helper that reads the shared corpus past
// internal/testcorpus.
package zzhelp

import "os"

// Seed returns the golden seed, read relative to the caller's package.
func Seed() ([]byte, error) {
	return os.ReadFile("../../testdata/golden/s1/seed.golden")
}
EOF
      cat >"${mod}/internal/zzhelpuser/zzhelpuser_test.go" <<'EOF'
package zzhelpuser

import (
	"testing"

	"MODPATH/internal/zzhelp"
)

func TestZzHelpUser(t *testing.T) {
	if _, err := zzhelp.Seed(); err != nil {
		t.Fatal(err)
	}
}
EOF
      sed -i "s%MODPATH%$(awk '$1 == "module" {print $2; exit}' "${mod}/go.mod")%" \
        "${mod}/internal/zzhelpuser/zzhelpuser_test.go"
      ;;
    corpus-var)
      mkdir -p "${mod}/internal/zzvar"
      cat >"${mod}/internal/zzvar/zzvar_test.go" <<'EOF'
package zzvar

import (
	"os"
	"path/filepath"
	"testing"
)

func TestZzVar(t *testing.T) {
	dir := "test" + "data"
	if _, err := os.ReadFile(filepath.Join("..", "..", dir, "golden", "s1", "seed.golden")); err != nil {
		t.Fatal(err)
	}
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
# defect as the change; the target script, the constructor library it
# sources, the admission checker the 01-admit step installs (base#1465)
# and the logger they source come along.
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
  cp -a "${_RP_ROOT}/script/test/config_gen_mutation_targets.sh" \
    "${_RP_ROOT}/script/test/config_gen_mutation_lang.sh" \
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

# _rp_gates <root> <case> -- run the runner on <root>, its stdout to
# <root>.out and its stderr to <root>.err; returns the runner's status. Its
# log is JSON whatever the caller set, because the verdicts read its
# records. The mutation context is pr with no base override whatever the
# caller inherited (base#1464): a CI main push exports main-push, and a
# one-commit copy has no HEAD^1.
_rp_gates() {
  env -u CONFIG_GEN_MUTATION_BASE CONFIG_GEN_MUTATION_CONTEXT=pr LOG_FORMAT=json \
    CONFIG_GEN_REDPATH_CASE="${2}" \
    bash "${_RP_SCRIPT_DIR}/config_gen_gates.sh" --root "${1}" >"${1}.out" 2>"${1}.err"
}

# The runner's own record of the gate that went red: a whole JSON log line
# from service config-gen whose body is exactly a gate id. The build log
# streamed ahead of it, an id quoted inside other text and a longer id that
# starts with one are none of them that record (base#1462).
readonly _RP_GATE_RECORD_RE='^\{"timestamp":"[^"]*","severity_text":"ERROR","severity_number":[0-9]+,"body":"(config_gen_gate_[a-z]+_failed)",("trace_id":"[^"]*","span_id":"[^"]*",)?"attributes":\{"service\.name":"config-gen",.*\}\}$'

# _rp_exit_one <rc> -- empty when a refused run exited exactly 1, the
# status every refusal ends with; else rc_zero or rc_not_one. A runner that
# crashed with another status is not a refusal, whatever it logged.
_rp_exit_one() {
  local rc="${1}"
  (( rc != 0 )) || { echo rc_zero; return 0; }
  (( rc == 1 )) || { echo rc_not_one; return 0; }
}

# _rp_verdict <rc> <out> <err> <gate> -- empty when the case went red as
# planted (exit exactly 1), else the reason it did not.
_rp_verdict() {
  local rc="${1}" out="${2}" err="${3}" gate="${4}" first g gate_exit
  gate_exit="$(_rp_exit_one "${rc}")"
  [[ -z "${gate_exit}" ]] || { echo "${gate_exit}"; return 0; }
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
  _rp_gates "${root}" "${name}" || rc=$?
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

# _rp_event_detail <err> <id> <key> <key2> -- `<value>|<value2>` of each
# runner record of <id> in <err>, one line per record, a missing attribute
# empty.
_rp_event_detail() {
  jq -Rr --arg id "${2}" --arg a "${3}" --arg b "${4}" 'fromjson? | select(type == "object" and .body == $id
    and .attributes."service.name" == "config-gen") | "\(.attributes[$a] // "")|\(.attributes[$b] // "")"' "${1}"
}

# _rp_refused_shape <rc> <out> <err> -- empty when the run ended the way
# every refusal must (exit exactly 1, nothing on stdout, no "unregistered
# log body" on stderr), else the reason it did not.
_rp_refused_shape() {
  local rc="${1}" out="${2}" err="${3}" refused_exit
  refused_exit="$(_rp_exit_one "${rc}")"
  [[ -z "${refused_exit}" ]] || { echo "${refused_exit}"; return 0; }
  [[ ! -s "${out}" ]] || { echo stdout_not_empty; return 0; }
  ! grep -qF 'unregistered log body' "${err}" || { echo unregistered_body; return 0; }
}

# _rp_refusal_verdict <rc> <out> <err> <id> -- empty when the build refused
# the case as planted, else the reason it did not.
_rp_refusal_verdict() {
  local err="${3}" id="${4}" shape
  shape="$(_rp_refused_shape "${1}" "${2}" "${err}")"
  [[ -z "${shape}" ]] || { echo "${shape}"; return 0; }
  grep -qE "$(_rp_event_record_re "${id}")" "${err}" || { echo wrong_id; return 0; }
}

# _rp_refusal <scratch> <case> <id> -- run one refusal case; non-zero when
# the build did not refuse it with <id>.
_rp_refusal() {
  local scratch="${1}" name="${2}" id="${3}" root rc=0 reason
  root="$(_rp_copy "${scratch}")"
  _rp_plant "${name}" "${root}"
  _rp_gates "${root}" "${name}" || rc=$?
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
  local err="${3}" file="${4}" reason="${5}" shape got
  shape="$(_rp_refused_shape "${1}" "${2}" "${err}")"
  [[ -z "${shape}" ]] || { echo "${shape}"; return 0; }
  ! grep -qF 'go: errors parsing go.mod' "${err}" || { echo go_ran_before_admission; return 0; }
  ! grep -qE "${_RP_GO_STEP_RE}" "${err}" || { echo go_ran_before_admission; return 0; }
  grep -qE "$(_rp_event_record_re config_gen_gate_admission_failed)" "${err}" || { echo gate_record_missing; return 0; }
  got="$(_rp_event_detail "${err}" config_gen_manifest_stale file reason)"
  [[ -n "${got}" ]] || { echo stale_record_missing; return 0; }
  [[ "${got}" == "${file}|${reason}" ]] || { echo stale_detail_mismatch; return 0; }
}

# _rp_stale <scratch> <case> <file> <reason> -- run one stale case;
# non-zero when admission did not refuse it with <file> and <reason>.
_rp_stale() {
  local scratch="${1}" name="${2}" file="${3}" want="${4}" root rc=0 reason
  root="$(_rp_copy "${scratch}")"
  _rp_plant "${name}" "${root}"
  _rp_gates "${root}" "${name}" || rc=$?
  reason="$(_rp_stale_verdict "${rc}" "${root}.out" "${root}.err" "${file}" "${want}")"
  [[ -z "${reason}" ]] && return 0
  cat "${root}.err" >&2
  _log_err "${_RP_SERVICE}" config_gen_redpath_case_failed "case=${name}" "reason=${reason}" \
    "event=config_gen_manifest_stale" \
    "display=config-gen redpath case ${name} was not refused as stale (file=${file} reason=${want}): ${reason}"
  return 1
}

# The six lines each green, rerun and control call must print, typed from
# the issue's gate list (base#1465), not derived from _RP_GATES.
readonly _RP_RERUN_OUT='gate=admission ok
gate=fmt ok
gate=vet ok
gate=lint ok
gate=race ok
gate=coverage ok'

# The five lines a coverage case must print: every gate before coverage.
readonly _RP_PRE_COVERAGE_OUT='gate=admission ok
gate=fmt ok
gate=vet ok
gate=lint ok
gate=race ok'

# _rp_rerun_verdict <rc> <out> -- empty when one call passed with exactly
# the six ok lines, else the reason it did not.
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
    _rp_gates "${root}" rerun || rc=$?
    reason="$(_rp_rerun_verdict "${rc}" "${root}.out")"
    [[ -z "${reason}" ]] && continue
    cat "${root}.err" >&2
    _log_err "${_RP_SERVICE}" config_gen_redpath_case_failed "case=rerun" "call=${call}" "reason=${reason}" \
      "display=config-gen redpath case rerun: call ${call} of 2 did not print exactly the six ok lines: ${reason}"
    return 1
  done
}

# _rp_green_case <scratch> <case> -- run one green case; non-zero when the
# runner did not pass with exactly the six ok lines.
_rp_green_case() {
  local root rc=0 reason
  root="$(_rp_copy "${1}")"
  _rp_plant "${2}" "${root}"
  _rp_gates "${root}" "${2}" || rc=$?
  reason="$(_rp_rerun_verdict "${rc}" "${root}.out")"
  [[ -z "${reason}" ]] && return 0
  cat "${root}.err" >&2
  _log_err "${_RP_SERVICE}" config_gen_redpath_case_failed "case=${2}" "reason=${reason}" \
    "display=config-gen redpath green case ${2} did not pass with exactly the six ok lines: ${reason}"
  return 1
}

# _rp_coverage_verdict <rc> <out> <err> <event> <pkg> <file> -- empty when
# the coverage ratchet refused the case (exit exactly 1) with <event> naming
# <pkg> and <file> after exactly the five earlier ok lines, else the reason
# it did not.
_rp_coverage_verdict() {
  local rc="${1}" out="${2}" err="${3}" event="${4}" pkg="${5}" file="${6}" first coverage_exit
  coverage_exit="$(_rp_exit_one "${rc}")"
  [[ -z "${coverage_exit}" ]] || { echo "${coverage_exit}"; return 0; }
  printf '%s\n' "${_RP_PRE_COVERAGE_OUT}" | cmp -s - "${out}" || { echo stdout_mismatch; return 0; }
  ! grep -qF -- 'unregistered log body' "${err}" || { echo unregistered_body; return 0; }
  first="$(sed -nE "s/${_RP_GATE_RECORD_RE}/\\1/p" "${err}")"
  first="${first%%$'\n'*}"
  [[ "${first}" == config_gen_gate_coverage_failed ]] || { echo wrong_id; return 0; }
  grep -qE "$(_rp_event_record_re "${event}")" "${err}" || { echo event_record_missing; return 0; }
  [[ "$(_rp_event_detail "${err}" "${event}" pkg file)" == "${pkg}|${file}" ]] || { echo event_detail_mismatch; return 0; }
}

# _rp_coverage <scratch> <case> <event> <pkg> <file> -- run one coverage
# case; non-zero when the ratchet did not refuse it with <event> naming
# <pkg> and <file>.
_rp_coverage() {
  local root rc=0 reason
  root="$(_rp_copy "${1}")"
  _rp_plant "${2}" "${root}"
  _rp_gates "${root}" "${2}" || rc=$?
  reason="$(_rp_coverage_verdict "${rc}" "${root}.out" "${root}.err" "${3}" "${4}" "${5}")"
  [[ -z "${reason}" ]] && return 0
  cat "${root}.err" >&2
  _log_err "${_RP_SERVICE}" config_gen_redpath_case_failed "case=${2}" "reason=${reason}" "event=${3}" \
    "display=config-gen redpath coverage case ${2} was not refused with ${3}: ${reason}"
  return 1
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
  _rp_gates "${root}" control || rc=$?
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
  local name file want pkg
  for entry in "${_RP_STALE[@]}"; do
    IFS='|' read -r name file want <<<"${entry}"
    _rp_selected "${name}" || continue
    ran=$(( ran + 1 ))
    _rp_stale "${scratch}" "${name}" "${file}" "${want}" || failed=1
  done
  for name in "${_RP_GREENS[@]}"; do
    _rp_selected "${name}" || continue
    ran=$(( ran + 1 ))
    _rp_green_case "${scratch}" "${name}" || failed=1
  done
  for entry in "${_RP_COVERAGE[@]}"; do
    IFS='|' read -r name want pkg file <<<"${entry}"
    _rp_selected "${name}" || continue
    ran=$(( ran + 1 ))
    _rp_coverage "${scratch}" "${name}" "${want}" "${pkg}" "${file}" || failed=1
  done
  if _rp_selected rerun; then
    ran=$(( ran + 1 ))
    _rp_rerun "${scratch}" || failed=1
  fi
  _rp_control "${scratch}" || failed=1
  (( failed == 0 )) || exit 1
  echo "config-gen redpath: ${ran} planted cases went red, were refused or passed as planted; the control passed"
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  main "$@"
fi
