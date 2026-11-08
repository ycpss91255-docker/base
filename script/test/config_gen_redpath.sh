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
#   mut-unstaged   a committed package's test loses its assertion  mutation
#                  as an unstaged edit, so every mutant survives
#   mut-staged     the same edit, staged                           mutation
#   mut-timeout    an untracked package whose loop mutant hangs:   mutation
#                  3 mutants killed and 1 timed out is 75.0
#   mut-untracked-lived  an untracked package whose test asserts   mutation
#                  nothing: both mutants end and survive, 0.0
#   corpus        a committed importer of internal/testcorpus     mutation
#                  whose result goes unasserted; the change is
#                  only an untracked file under the module's
#                  root testdata/
#   notes          an untracked notes.txt at the module root, a    mutation
#                  file no mapping rule covers
#   sens-per-golden  an untracked golden whose one consumer reached  corpus_sensitivity
#                  through a helper asserts only that it exists,
#                  beside a strong reader of another golden
#
# A sensitivity case listed in _RP_WEAK (gate corpus_sensitivity,
# base#1467) must also carry, as the runner's JSON
# config_gen_corpus_sensitivity_weak records, exactly the `<pkg>|<file>`
# pairs its row names, in that order (reason weak_records_mismatch): the
# golden whose byte flip left that package's tests passing, and no record
# for a package that reads another golden.
#
# A mutation case (gate mutation, base#1467) must also show the manifest
# the 00-manifest step wrote with dirty=yes: a step planted after every
# real one prints its header line, prefixed with
# "config-gen redpath manifest: ", and the runner streams a step's stdout
# to stderr. A mutation case listed in _RP_MUTATION_FAILED must also carry
# exactly one runner JSON config_gen_mutation_package_failed record, and
# it must name the row's package by pkg= with the row's reason and
# measured efficacy (reason mutation_record_mismatch): the gate's verdict
# on the planted package, attributed to it. A mutation case
# listed in _RP_MUTATION_EVENTS must carry exactly one runner JSON record
# of its event, naming its file (reason mutation_event_mismatch): the
# mapping's refusal of what the case planted, re-emitted with its file=.
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
# stale-edit-locale is stale-edit with the runner run under
# LC_ALL=en_US.UTF-8, a locale in which bash's [!-~] does not match the
# word file=dockerfile/config-gen/cmd/config-gen/main.go: on glibc 2.35
# (Ubuntu 22.04) the runner's attribute filter dropped every file and
# reason word under it, and kept them only once _cg_attr_ok pinned LC_ALL=C
# (base#1465). Where en_US.UTF-8 does not drop that word, the redpath makes
# it with localedef into a LOCPATH of its own; where neither yields such a
# locale -- no localedef, a localedef that writes none, or a libc that is
# neither glibc nor musl -- the case fails (reason locale_not_affected)
# rather than pass on a locale that proves nothing. Musl alone runs the
# case under the name as it is, and is told by its loader, not by a
# missing localedef: in the musl test-tools image bash matched the word
# under C, C.UTF-8 and en_US.UTF-8 alike.
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
# two copies under diff.renames=copies, a
# typechange to a symlink -- or to a baseline holding café.txt, `a b.txt`
# and one name per byte 0x01-0x7f but /. Each must exit 0 and print exactly
# the six ok lines below: admission accepts every baseline the producer
# writes, and every gate still runs after it.
#
# docs-only (a green case, base#1467) changes only a file outside the
# module: the producer writes the no-change marker, and the run must also
# stream the mutation gate's `mutation targets none` (_RP_GREEN_LINES; a
# green case listed there whose build log ends no line with " <its
# line>" fails, reason green_line_missing).
#
# ign-excluded (a green case, base#1467) leaves cmd/config-gen/.main.go.swp,
# an editor swap file, in the module, Git-ignored by the `*.swp` line the
# repository's own .gitignore holds. The producer
# lists it in ignored.sha256; Dockerfile.config-gen.dockerignore must keep
# it out of the build context, admission must accept a listed ignored file
# the context does not hold, and so the ignored-input gate has nothing to
# refuse: the run passes with the six ok lines. ign-excluded-go is the ign
# case below, the same Git-ignored cmd/config-gen/zz_ign.go planted the
# same way, with one more line in the copy's
# Dockerfile.config-gen.dockerignore that drops it from the build context:
# that line alone turns ign's refusal into a green run, so the gate judges
# what the context holds, never the file's name or kind.
#
# An after-admit case (_RP_AFTER_ADMIT, base#1467) leaves a Git-ignored
# module file in the build context, so the producer lists it in
# ignored.sha256 and admission accepts the context: the ignored-input gate
# must refuse it after every S1b gate. The run must exit exactly 1 with
# exactly the rerun case's six ok lines on stdout, no "unregistered log body",
# the runner's JSON config_gen_gate_<gate>_failed as its first gate record,
# and exactly one runner JSON record of the row's event, naming the
# row's file (reason after_admit_detail_mismatch).
#
#   case             ignored file left in the context               gate
#   ign              cmd/config-gen/zz_ign.go, a Go file ignored     ignored
#                    by .git/info/exclude
#   untrack-ignored  testdata/zzg/a.txt, untracked and then         ignored
#                    ignored (once a green case)
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
# The retro case (base#1467) plants nothing either: it puts an empty root
# commit under the copy's one commit and runs the runner with
# CONFIG_GEN_MUTATION_BASE set to it, so every tracked module file is an
# `A` line of the manifest. It must exit 0 with exactly the six ok lines,
# a manifest header with that base and dirty=no, no
# config_gen_mutation_unmapped anywhere, and one mutation line, `<pkg> ok
# efficacy=<e>` or `<pkg> no-mutants`, for exactly each package of the
# copy: each directory holding a tracked .go file outside testdata/
# (reason package_set_mismatch). A tracked module file no mapping rule
# covers, or a real package below the mutation floor, turns it red.
#
# Each runner call is told its case in CONFIG_GEN_REDPATH_CASE (control for
# the control), which the runner itself ignores.
#
# CONFIG_GEN_REDPATH_ONLY, when set, is a space-separated list of case
# names: only those cases run, then the control. config_gen_gates_spec
# scopes each test this way; `just test go` unsets it, so the recipe
# always runs every case (base#1465).
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

# Strict mode only when run; sourced, the caller's settings stand.
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
readonly -a _RP_CASES=(fmt:fmt vet:vet lint:lint race:race race-fuzz:race coverage:coverage fmt-parse:fmt corpus-join:race corpus-helper:race corpus-var:race mut-unstaged:mutation mut-staged:mutation mut-timeout:mutation mut-untracked-lived:mutation corpus:mutation notes:mutation sens-per-golden:corpus_sensitivity)
# <case>|<pkg>|<reason>|<measured>: the one package failure record the
# runner must log for <case>, re-emitted from the mutation gate's
# config_gen_mutation_package_failed line (base#1467). The mut-timeout
# figure is 3 killed over 4 judged: gremlins reported its loop
# fixture as KILLED x3 and TIMED OUT x1 (design r1r2, gremlins v0.6.0).
# The corpus figure is 0 killed over 2 judged: Pos's boundary and negation
# mutants of n > 0 both live, since no test asserts Pos's result; so are
# mut-unstaged's and mut-staged's, whose edited test asserts nothing, and
# mut-untracked-lived's, an added package whose test asserts nothing: no
# mutant there times out, so its 0.0 holds only if a LIVED mutant is
# judged not killed.
readonly -a _RP_MUTATION_FAILED=(
  'mut-unstaged|github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/zzmut|below|0.0'
  'mut-staged|github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/zzmut|below|0.0'
  'mut-timeout|github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/zzloop|below|75.0'
  'mut-untracked-lived|github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/zzlive|below|0.0'
  'corpus|github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/zzweak|below|0.0'
)
# <case>|<event>|<file>: the one record of <event>, naming <file>, the
# mutation gate's mapping must refuse <case> with (base#1467).
readonly -a _RP_MUTATION_EVENTS=(
  'notes|config_gen_mutation_unmapped|dockerfile/config-gen/notes.txt'
)
# <case>|<pkg>|<file>: each weak record the sensitivity gate must log for
# <case>, in order (base#1467). sens-per-golden's one pair is its planted
# tests' own contract: zzglob reaches zz.golden only through zzhelp and
# asserts only that Glob returned it, so no byte of it can fail zzglob;
# zzhelp compares zz.golden's bytes and zzseed seed.golden's, so neither
# is weak.
readonly -a _RP_WEAK=(
  'sens-per-golden|github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/zzglob|golden/s1/zz.golden'
)
# <case>:<the event id the build must refuse it with> (base#1465).
readonly -a _RP_REFUSALS=(no-context:config_gen_manifest_missing)
# <case>|<file>|<reason> the admission stale record must carry (base#1465).
readonly -a _RP_STALE=(
  'stale-edit|dockerfile/config-gen/cmd/config-gen/main.go|sha_mismatch'
  'stale-edit-locale|dockerfile/config-gen/cmd/config-gen/main.go|sha_mismatch'
  'stale-new-pkg|dockerfile/config-gen/internal/zznew/zznew.go|unlisted'
  'stale-delete|dockerfile/config-gen/cmd/config-gen/main_test.go|missing'
  'stale-symlink|dockerfile/config-gen/cmd/config-gen/zz.go|unlisted'
  'stale-dangling|dockerfile/config-gen/zz-dangling|not_regular'
  'stale-gomod|dockerfile/config-gen/go.mod|sha_mismatch'
  'stale-checker|dockerfile/config-gen/internal/buildgate/zz.go|unlisted'
  'stale-names|dockerfile/config-gen/testdata/zznames/a%20b.txt|sha_mismatch'
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
readonly -a _RP_GREENS=(names rename-recreate untrack rename-move copies typechange ign-excluded ign-excluded-go docs-only)
# <case>|<a line its build log must end a line with> (base#1467).
readonly -a _RP_GREEN_LINES=('docs-only|mutation targets none')
# <case>|<gate>|<event>|<file>: a context the producer and admission both
# accept, holding a Git-ignored module file the gate must refuse, naming
# that file in each <event> record (base#1467).
readonly -a _RP_AFTER_ADMIT=(
  'ign|ignored|config_gen_mutation_ignored_input|dockerfile/config-gen/cmd/config-gen/zz_ign.go'
  'untrack-ignored|ignored|config_gen_mutation_ignored_input|dockerfile/config-gen/testdata/zzg/a.txt'
)
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
    stale-edit | stale-edit-locale)
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
    stale-names) echo 'printf "edit\n" >>"${_mod}/testdata/zznames/a b.txt"' ;;
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
# testdata/zzg/a.txt and testdata/zzg/c.txt committed as the base, then
# the case's change. names commits testdata/zznames/ (café.txt, `a b.txt`,
# one name holding every byte 0x01-0x7f but /) and leaves an untracked name
# the producer C-quotes. Both sit under the module-root testdata/, which the
# mutation gate maps to the test importers of internal/testcorpus, so the
# case stays green there (base#1467).
_rp_green() {
  local root="${2}" mod="${2}/dockerfile/config-gen"
  local g="${mod}/testdata/zzg" n="${mod}/testdata/zznames"
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
      printf 'dockerfile/config-gen/testdata/zzg/a.txt\n' >"${root}/.git/info/exclude"
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

# The prefix the manifest step puts before the manifest's header line.
readonly _RP_MANIFEST_TAG='config-gen redpath manifest: '

# _rp_manifest_step <root> -- write a step that runs after every real one
# (C-locale glob order) and prints the header line of the manifest
# 00-manifest wrote, prefixed with _RP_MANIFEST_TAG (base#1467).
_rp_manifest_step() {
  cat >"${1}/script/test/config_gen_steps/99-zz-manifest.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s%s\n' '${_RP_MANIFEST_TAG}' "\$(head -n 1 "\${CONFIG_GEN_CTX:?}/mutation/manifest")"
EOF
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
    ign | ign-excluded-go)
      # Every gate before the ignored one passes on it: a package clause
      # and no statement. Ignored only by the copy's own .git/info/exclude,
      # so nothing in the context names it. ign-excluded-go also has the
      # copy's dockerignore drop it from the build context.
      printf 'zz_ign.go\n' >"${root}/.git/info/exclude"
      printf '// zz_ign.go is a Git-ignored file left in the build context.\npackage main\n' \
        >"${cmd}/zz_ign.go"
      if [[ "${1}" == ign-excluded-go ]]; then
        printf '**/zz_ign.go\n' >>"${root}/dockerfile/Dockerfile.config-gen.dockerignore"
      fi
      ;;
    ign-excluded)
      # The swap file vim leaves beside main.go while it is open, ignored
      # by the copy's .git/info/exclude through the `*.swp` line the
      # repository's own .gitignore holds.
      printf '*.swp\n' >"${root}/.git/info/exclude"
      printf 'zz editor swap file\n' >"${cmd}/.main.go.swp"
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
    mut-unstaged | mut-staged)
      # zzmut and its floor are committed with a test that kills both of
      # Pos's mutants (n >= 0 fails Pos(0), n <= 0 fails all three rows).
      # The edit, left unstaged (mut-unstaged) or staged (mut-staged),
      # keeps every call (coverage stays 100.0) and drops the comparison,
      # so both mutants survive (base#1467).
      mkdir -p "${mod}/internal/zzmut"
      cat >"${mod}/internal/zzmut/zzmut.go" <<'EOF'
// Package zzmut is a redpath fixture whose test kills every mutant.
package zzmut

// Pos reports whether n is positive.
func Pos(n int) bool {
	return n > 0
}
EOF
      cat >"${mod}/internal/zzmut/zzmut_test.go" <<'EOF'
package zzmut

import "testing"

func TestPos(t *testing.T) {
	for n, want := range map[int]bool{-1: false, 0: false, 1: true} {
		if got := Pos(n); got != want {
			t.Fatalf("Pos(%d) = %v, want %v", n, got, want)
		}
	}
}
EOF
      printf 'internal/zzmut 100.0\n' >"${mod}/coverage-floors.d/zz.txt"
      _rp_rebase "${root}"
      cat >"${mod}/internal/zzmut/zzmut_test.go" <<'EOF'
package zzmut

import "testing"

func TestPos(t *testing.T) {
	for n := range map[int]bool{-1: false, 0: false, 1: true} {
		_ = Pos(n)
	}
}
EOF
      if [[ "${1}" == mut-staged ]]; then
        _rp_git "${root}" add -- "${mod}/internal/zzmut/zzmut_test.go"
      fi
      _rp_manifest_step "${root}"
      ;;
    notes)
      # Untracked, so 00-manifest lists it as the one change; no mapping
      # rule covers a text file at the module root (base#1467).
      printf 'notes\n' >"${mod}/notes.txt"
      _rp_manifest_step "${root}"
      ;;
    docs-only)
      # A change outside dockerfile/config-gen/, so 00-manifest writes the
      # no-change marker (base#1467).
      mkdir -p "${root}/doc"
      printf 'docs only\n' >"${root}/doc/zz-docs-only.md"
      ;;
    mut-timeout)
      # Never committed. The test kills the boundary and negation mutants
      # of i > 0 (Count(3) gives 4 and 0) and c-- (Count(3) gives -3); i++
      # never ends for n = 3, so gremlins times that mutant out. No row
      # has n = 0: under the negation i <= 0 that loop never ends either,
      # which a run with a 0 row showed as a second TIMED OUT (base#1467).
      mkdir -p "${mod}/internal/zzloop"
      cat >"${mod}/internal/zzloop/zzloop.go" <<'EOF'
// Package zzloop is a redpath fixture whose loop mutant never ends.
package zzloop

// Count returns how many times a loop from n down to 1 runs.
func Count(n int) int {
	c := 0
	for i := n; i > 0; i-- {
		c++
	}
	return c
}
EOF
      cat >"${mod}/internal/zzloop/zzloop_test.go" <<'EOF'
package zzloop

import "testing"

func TestCount(t *testing.T) {
	for n, want := range map[int]int{1: 1, 3: 3} {
		if got := Count(n); got != want {
			t.Fatalf("Count(%d) = %d, want %d", n, got, want)
		}
	}
}
EOF
      printf 'internal/zzloop 100.0\n' >"${mod}/coverage-floors.d/zz.txt"
      _rp_manifest_step "${root}"
      ;;
    mut-untracked-lived)
      # Never committed. The test calls Pos on every row, so coverage is
      # 100.0, and asserts nothing: the boundary and negation mutants of
      # n > 0 both run to an end and survive. No loop, so no mutant can
      # time out (base#1467).
      mkdir -p "${mod}/internal/zzlive"
      cat >"${mod}/internal/zzlive/zzlive.go" <<'EOF'
// Package zzlive is a redpath fixture whose test asserts nothing.
package zzlive

// Pos reports whether n is positive.
func Pos(n int) bool {
	return n > 0
}
EOF
      cat >"${mod}/internal/zzlive/zzlive_test.go" <<'EOF'
package zzlive

import "testing"

func TestPos(t *testing.T) {
	for _, n := range []int{-1, 0, 1} {
		_ = Pos(n)
	}
}
EOF
      printf 'internal/zzlive 100.0\n' >"${mod}/coverage-floors.d/zz.txt"
      _rp_manifest_step "${root}"
      ;;
    corpus)
      # zzweak is committed with its floor, so the change 00-manifest lists
      # is only the untracked testdata/c.txt. Its test reads the golden
      # through internal/testcorpus and compares its bytes, but leaves
      # Pos(5) unasserted: every Pos mutant survives, and only a root
      # testdata change that reaches the test importers of testcorpus can
      # make zzweak a target (base#1467).
      mkdir -p "${mod}/internal/zzweak"
      cat >"${mod}/internal/zzweak/zzweak.go" <<'EOF'
// Package zzweak is a redpath fixture whose test asserts nothing of Pos.
package zzweak

// Pos reports whether n is positive.
func Pos(n int) bool {
	return n > 0
}
EOF
      cat >"${mod}/internal/zzweak/zzweak_test.go" <<'EOF'
package zzweak

import (
	"os"
	"testing"

	"MODPATH/internal/testcorpus"
)

func TestPos(t *testing.T) {
	_ = Pos(5)
	for _, p := range testcorpus.Glob(t, "golden/s1/seed.golden") {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		if string(b) != "seed golden for internal/testcorpus (base#1468)\n" {
			t.Fatalf("%s = %q", p, b)
		}
	}
}
EOF
      sed -i "s%MODPATH%$(awk '$1 == "module" {print $2; exit}' "${mod}/go.mod")%" \
        "${mod}/internal/zzweak/zzweak_test.go"
      printf 'internal/zzweak 100.0\n' >"${mod}/coverage-floors.d/zz.txt"
      _rp_rebase "${root}"
      printf 'c\n' >"${mod}/testdata/c.txt"
      _rp_manifest_step "${root}"
      ;;
    sens-per-golden)
      # zzseed, zzhelp and zzglob are committed with their floors (the two
      # test-only packages have no statements, so none); the change is
      # only the untracked golden/s1/zz.golden. zzseed compares
      # seed.golden's bytes and never reads zz.golden. zzhelp's Golden
      # returns zz.golden through internal/testcorpus, and zzhelp's own
      # test compares its bytes. zzglob calls zzhelp.Golden and asserts
      # only that one path came back, so a flipped byte of zz.golden
      # leaves it passing: the one weak pair (base#1467).
      mkdir -p "${mod}/internal/zzseed" "${mod}/internal/zzhelp" "${mod}/internal/zzglob"
      cat >"${mod}/internal/zzseed/zzseed_test.go" <<'EOF'
package zzseed

import (
	"os"
	"testing"

	"MODPATH/internal/testcorpus"
)

func TestSeed(t *testing.T) {
	for _, p := range testcorpus.Glob(t, "golden/s1/seed.golden") {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		if string(b) != "seed golden for internal/testcorpus (base#1468)\n" {
			t.Fatalf("%s = %q", p, b)
		}
	}
}
EOF
      cat >"${mod}/internal/zzhelp/zzhelp.go" <<'EOF'
// Package zzhelp is a redpath fixture that hands its callers zz.golden.
package zzhelp

import (
	"testing"

	"MODPATH/internal/testcorpus"
)

// Golden returns zz.golden's path, read through internal/testcorpus.
func Golden(t testing.TB) []string {
	t.Helper()
	return testcorpus.Glob(t, "golden/s1/zz.golden")
}
EOF
      cat >"${mod}/internal/zzhelp/zzhelp_test.go" <<'EOF'
package zzhelp

import (
	"os"
	"testing"
)

func TestGolden(t *testing.T) {
	for _, p := range Golden(t) {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		if string(b) != "zz golden for redpath sens-per-golden (base#1467)\n" {
			t.Fatalf("%s = %q", p, b)
		}
	}
}
EOF
      cat >"${mod}/internal/zzglob/zzglob_test.go" <<'EOF'
package zzglob

import (
	"testing"

	"MODPATH/internal/zzhelp"
)

func TestGlob(t *testing.T) {
	if got := zzhelp.Golden(t); len(got) != 1 {
		t.Fatalf("zzhelp.Golden = %q, want one path", got)
	}
}
EOF
      sed -i "s%MODPATH%$(awk '$1 == "module" {print $2; exit}' "${mod}/go.mod")%" \
        "${mod}/internal/zzseed/zzseed_test.go" "${mod}/internal/zzhelp/zzhelp.go" \
        "${mod}/internal/zzglob/zzglob_test.go"
      printf 'internal/zzseed none\ninternal/zzhelp 100.0\ninternal/zzglob none\n' \
        >"${mod}/coverage-floors.d/zz.txt"
      _rp_rebase "${root}"
      printf 'zz golden for redpath sens-per-golden (base#1467)\n' >"${mod}/testdata/golden/s1/zz.golden"
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
    "${_RP_ROOT}/script/test/config_gen_admit.sh" \
    "${_RP_ROOT}/script/test/config_gen_coverage.sh" "${dst}/script/test/"
  cp -a "${_RP_ROOT}/dist/script/docker/lib/log.sh" "${_RP_ROOT}/dist/script/docker/lib/log-events.txt" \
    "${dst}/dist/script/docker/lib/"
  git -C "${dst}" init -q
  git -C "${dst}" add -A
  git -C "${dst}" -c user.name=config-gen-redpath -c user.email=config-gen-redpath@localhost \
    commit -q --no-verify --no-gpg-sign -m "config-gen redpath copy"
  git -C "${dst}" update-ref refs/remotes/origin/main HEAD
  printf '%s\n' "${dst}"
}

# _rp_gates <root> <case> [VAR=value...] -- run the runner on <root>, its
# stdout to <root>.out and its stderr to <root>.err, with any VAR=value
# words added to its environment; returns the runner's status. Its
# log is JSON whatever the caller set, because the verdicts read its
# records. The mutation context is pr with no base override whatever the
# caller inherited (base#1464): a CI main push exports main-push, and a
# one-commit copy has no HEAD^1.
_rp_gates() {
  env -u CONFIG_GEN_MUTATION_BASE CONFIG_GEN_MUTATION_CONTEXT=pr LOG_FORMAT=json \
    CONFIG_GEN_REDPATH_CASE="${2}" "${@:3}" \
    bash "${_RP_SCRIPT_DIR}/config_gen_gates.sh" --root "${1}" >"${1}.out" 2>"${1}.err"
}

# The runner's own record of the gate that went red: a whole JSON log line
# from service config-gen whose body is exactly a gate id. The build log
# streamed ahead of it, an id quoted inside other text and a longer id that
# starts with one are none of them that record (base#1462).
readonly _RP_GATE_RECORD_RE='^\{"timestamp":"[^"]*","severity_text":"ERROR","severity_number":[0-9]+,"body":"(config_gen_gate_[a-z_]+_failed)",("trace_id":"[^"]*","span_id":"[^"]*",)?"attributes":\{"service\.name":"config-gen",.*\}\}$'

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
  # A mutation case is an uncommitted change: its manifest says so.
  [[ "${gate}" != mutation ]] \
    || grep -qxE "${_RP_MANIFEST_TAG}base=[0-9a-f]{40} head=[0-9a-f]{40} dirty=yes context=pr" "${err}" \
    || { echo not_dirty; return 0; }
}

# _rp_row <case> <entry>... -- the rest of the first `<case>|<rest>` entry,
# empty when no entry is <case>'s.
_rp_row() {
  local name="${1}" entry
  shift
  for entry in "$@"; do
    [[ "${entry%%|*}" == "${name}" ]] && { printf '%s\n' "${entry#*|}"; return 0; }
  done
  return 0
}

# _rp_weak_pairs <case> -- the `<pkg>|<file>` pairs _RP_WEAK holds for
# <case>, one per line in table order; empty when it holds none.
_rp_weak_pairs() {
  local entry
  for entry in "${_RP_WEAK[@]}"; do
    [[ "${entry%%|*}" == "${1}" ]] && printf '%s\n' "${entry#*|}"
  done
  return 0
}

# _rp_line_ends <err> <line> -- true when a line of <err> ends with
# " <line>" (the build log puts its step and time first).
_rp_line_ends() {
  awk -v w=" ${2}" 'length($0) >= length(w) && substr($0, length($0) - length(w) + 1) == w { f = 1 }
    END { exit !f }' "${1}"
}

# _rp_case <scratch> <case> <gate> -- run one planted case; non-zero when
# it did not go red as planted.
_rp_case() {
  local scratch="${1}" name="${2}" gate="${3}" root rc=0 reason failed pkg want weak event
  root="$(_rp_copy "${scratch}")"
  _rp_plant "${name}" "${root}"
  _rp_gates "${root}" "${name}" || rc=$?
  reason="$(_rp_verdict "${rc}" "${root}.out" "${root}.err" "${gate}")"
  failed="$(_rp_row "${name}" "${_RP_MUTATION_FAILED[@]}")"
  if [[ -z "${reason}" && -n "${failed}" ]]; then
    pkg="${failed%%|*}" want="${failed#*|}"
    [[ "$(_rp_event_detail "${root}.err" config_gen_mutation_package_failed pkg reason)" == "${pkg}|${want%%|*}" \
      && "$(_rp_event_detail "${root}.err" config_gen_mutation_package_failed pkg measured)" == "${pkg}|${want#*|}" ]] \
      || reason=mutation_record_mismatch
  fi
  weak="$(_rp_weak_pairs "${name}")"
  if [[ -z "${reason}" && -n "${weak}" ]] \
    && [[ "$(_rp_event_detail "${root}.err" config_gen_corpus_sensitivity_weak pkg file)" != "${weak}" ]]; then
    reason=weak_records_mismatch
  fi
  event="$(_rp_row "${name}" "${_RP_MUTATION_EVENTS[@]}")"
  if [[ -z "${reason}" && -n "${event}" ]] \
    && [[ "$(_rp_event_detail "${root}.err" "${event%%|*}" file file)" != "${event#*|}|${event#*|}" ]]; then
    reason=mutation_event_mismatch
  fi
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

# The locale stale-edit-locale runs the runner under, and the word whose
# match under it decides whether that locale proves anything (base#1465).
readonly _RP_LOCALE='en_US.UTF-8'
readonly _RP_LOCALE_WORD='file=dockerfile/config-gen/cmd/config-gen/main.go'

# _rp_locale_drops [VAR=value...] -- true when bash, with those variables
# and LC_ALL=_RP_LOCALE, does not match _RP_LOCALE_WORD against the
# runner's attribute range [!-~] with no LC_ALL=C of its own.
_rp_locale_drops() {
  # shellcheck disable=SC2016 # the script is bash -c's, its $1 is the word
  ! env "$@" LC_ALL="${_RP_LOCALE}" bash -c '[[ "${1}" =~ ^file=[!-~]+$ ]]' _ "${_RP_LOCALE_WORD}" 2>/dev/null
}

# _rp_libc -- glibc when getconf answers GNU_LIBC_VERSION, musl when the
# musl dynamic loader is on disk, unknown otherwise (base#1465).
_rp_libc() {
  if getconf GNU_LIBC_VERSION >/dev/null 2>&1; then
    echo glibc
  elif compgen -G '/lib/ld-musl-*.so.1' >/dev/null; then
    echo musl
  else
    echo unknown
  fi
}

# _rp_locale_env <scratch> -- the VAR=value words, one per line, that put
# stale-edit-locale's runner call under _RP_LOCALE; non-zero when no
# _RP_LOCALE that drops _RP_LOCALE_WORD can be had. Musl is the one libc
# let through on a locale that does not drop the word, and only by name
# (base#1465).
_rp_locale_env() {
  local dir="${1}/locale" libc
  libc="$(_rp_libc)"
  if _rp_locale_drops || [[ "${libc}" == musl ]]; then
    printf 'LC_ALL=%s\n' "${_RP_LOCALE}"
    return 0
  fi
  [[ "${libc}" == glibc ]] || return 1
  command -v localedef >/dev/null 2>&1 || return 1
  mkdir -p "${dir}"
  # localedef exits 1 on warnings it still writes the locale through.
  localedef -i en_US -f UTF-8 "${dir}/${_RP_LOCALE}" >/dev/null 2>&1 || true
  _rp_locale_drops LOCPATH="${dir}" || return 1
  printf 'LC_ALL=%s\nLOCPATH=%s\n' "${_RP_LOCALE}" "${dir}"
}

# _rp_stale <scratch> <case> <file> <reason> -- run one stale case;
# non-zero when admission did not refuse it with <file> and <reason>.
_rp_stale() {
  local scratch="${1}" name="${2}" file="${3}" want="${4}" root rc=0 reason words=''
  local -a env_words=()
  if [[ "${name}" == stale-edit-locale ]]; then
    if ! words="$(_rp_locale_env "${scratch}")"; then
      _log_err "${_RP_SERVICE}" config_gen_redpath_case_failed "case=${name}" "reason=locale_not_affected" \
        "event=config_gen_manifest_stale" \
        "display=config-gen redpath case ${name}: no ${_RP_LOCALE} in which [!-~] drops ${_RP_LOCALE_WORD} could be had, from the installed locales or localedef"
      return 1
    fi
    mapfile -t env_words <<<"${words}"
  fi
  root="$(_rp_copy "${scratch}")"
  _rp_plant "${name}" "${root}"
  _rp_gates "${root}" "${name}" "${env_words[@]}" || rc=$?
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
# runner did not pass with exactly the six ok lines, or its build log lacks
# the line _RP_GREEN_LINES holds for <case>.
_rp_green_case() {
  local root rc=0 reason line
  root="$(_rp_copy "${1}")"
  _rp_plant "${2}" "${root}"
  _rp_gates "${root}" "${2}" || rc=$?
  reason="$(_rp_rerun_verdict "${rc}" "${root}.out")"
  line="$(_rp_row "${2}" "${_RP_GREEN_LINES[@]}")"
  if [[ -z "${reason}" && -n "${line}" ]] && ! _rp_line_ends "${root}.err" "${line}"; then
    reason=green_line_missing
  fi
  [[ -z "${reason}" ]] && return 0
  cat "${root}.err" >&2
  _log_err "${_RP_SERVICE}" config_gen_redpath_case_failed "case=${2}" "reason=${reason}" \
    "display=config-gen redpath green case ${2} did not pass with exactly the six ok lines: ${reason}"
  return 1
}

# _rp_after_admit_verdict <rc> <out> <err> <gate> <event> <file> -- empty
# when <gate> refused the case (exit exactly 1) after exactly the six ok
# lines, with exactly one <event> record, naming <file>, else the reason
# it did not.
_rp_after_admit_verdict() {
  local rc="${1}" out="${2}" err="${3}" gate="${4}" event="${5}" file="${6}" first after_exit
  after_exit="$(_rp_exit_one "${rc}")"
  [[ -z "${after_exit}" ]] || { echo "${after_exit}"; return 0; }
  printf '%s\n' "${_RP_RERUN_OUT}" | cmp -s - "${out}" || { echo stdout_mismatch; return 0; }
  ! grep -qF -- 'unregistered log body' "${err}" || { echo unregistered_body; return 0; }
  first="$(sed -nE "s/${_RP_GATE_RECORD_RE}/\\1/p" "${err}")"
  first="${first%%$'\n'*}"
  [[ "${first}" == "config_gen_gate_${gate}_failed" ]] || { echo wrong_id; return 0; }
  grep -qE "$(_rp_event_record_re "${event}")" "${err}" || { echo event_record_missing; return 0; }
  [[ "$(_rp_event_detail "${err}" "${event}" file file)" == "${file}|${file}" ]] \
    || { echo after_admit_detail_mismatch; return 0; }
}

# _rp_after_admit <scratch> <case> <gate> <event> <file> -- run one
# after-admit case; non-zero when <gate> did not refuse it with <event>
# naming <file>.
_rp_after_admit() {
  local root rc=0 reason
  root="$(_rp_copy "${1}")"
  _rp_plant "${2}" "${root}"
  _rp_gates "${root}" "${2}" || rc=$?
  reason="$(_rp_after_admit_verdict "${rc}" "${root}.out" "${root}.err" "${3}" "${4}" "${5}")"
  [[ -z "${reason}" ]] && return 0
  cat "${root}.err" >&2
  _log_err "${_RP_SERVICE}" config_gen_redpath_case_failed "case=${2}" "reason=${reason}" "gate=${3}" \
    "event=${4}" "display=config-gen redpath case ${2} was not refused by gate ${3} with ${4} file=${5}: ${reason}"
  return 1
}

# _rp_retro_want <root> -- the packages of the copy's module, one import
# path per line, sorted: each directory holding a tracked .go file, with
# no testdata, `.` or `_` path component under the module (the rule
# `go list ./...` documents), named under the module path go.mod declares.
_rp_retro_want() {
  local mod="${1}/dockerfile/config-gen" path
  path="$(awk '$1 == "module" {print $2; exit}' "${mod}/go.mod")"
  git -C "${mod}" ls-files -- '*.go' \
    | awk -v m="${path}" '{
        n = split($0, c, "/"); d = ""
        for (i = 1; i < n; i++) {
          if (c[i] == "testdata" || c[i] ~ /^[._]/) next
          d = d "/" c[i]
        }
        print m d
      }' \
    | LC_ALL=C sort -u
}

# _rp_retro_got <err> -- the packages the mutation gate passed, one per
# line, sorted: the build log lines ending `<pkg> ok efficacy=<e>` or
# `<pkg> no-mutants`. BuildKit merges the gate's streams into one step log,
# so a verdict can land after other text on the same line (base#1546).
_rp_retro_got() {
  sed -nE 's/^#[0-9]+ [0-9]+\.[0-9]+ (.* )?([^ ]+) (ok efficacy=[0-9]+\.[0-9]|no-mutants)$/\2/p' "${1}" \
    | LC_ALL=C sort -u
}

# _rp_retro_verdict <rc> <root> <base> -- empty when the retro call passed
# with the six ok lines, a clean manifest from <base>, nothing unmapped
# and a passing mutation line for exactly each package, else the reason
# it did not.
_rp_retro_verdict() {
  local rc="${1}" root="${2}" base="${3}"
  (( rc == 0 )) || { echo rc_not_zero; return 0; }
  printf '%s\n' "${_RP_RERUN_OUT}" | cmp -s - "${root}.out" || { echo stdout_mismatch; return 0; }
  grep -qxE "${_RP_MANIFEST_TAG}base=${base} head=[0-9a-f]{40} dirty=no context=pr" "${root}.err" \
    || { echo not_clean; return 0; }
  ! grep -qF -- config_gen_mutation_unmapped "${root}.err" || { echo unmapped; return 0; }
  [[ "$(_rp_retro_got "${root}.err")" == "$(_rp_retro_want "${root}")" ]] \
    || { echo package_set_mismatch; return 0; }
}

# _rp_retro <scratch> -- the retro case: the copy's commit re-parented on
# an empty root commit, the runner called with that root as
# CONFIG_GEN_MUTATION_BASE; non-zero when it did not pass as planted.
_rp_retro() {
  local root rc=0 reason empty head
  local -a id=(-c user.name=config-gen-redpath -c user.email=config-gen-redpath@localhost)
  root="$(_rp_copy "${1}")"
  empty="$(git -C "${root}" "${id[@]}" commit-tree --no-gpg-sign -m 'config-gen redpath empty root' \
    "$(git -C "${root}" mktree </dev/null)")"
  head="$(git -C "${root}" "${id[@]}" commit-tree --no-gpg-sign -p "${empty}" -m 'config-gen redpath copy' 'HEAD^{tree}')"
  git -C "${root}" update-ref HEAD "${head}"
  git -C "${root}" update-ref refs/remotes/origin/main "${head}"
  _rp_manifest_step "${root}"
  _rp_gates "${root}" retro "CONFIG_GEN_MUTATION_BASE=${empty}" || rc=$?
  reason="$(_rp_retro_verdict "${rc}" "${root}" "${empty}")"
  [[ -z "${reason}" ]] && return 0
  cat "${root}.err" >&2
  printf 'config-gen redpath retro: want packages:\n%s\ngot:\n%s\n' \
    "$(_rp_retro_want "${root}")" "$(_rp_retro_got "${root}.err")" >&2
  _log_err "${_RP_SERVICE}" config_gen_redpath_case_failed "case=retro" "reason=${reason}" "gate=mutation" \
    "display=config-gen redpath case retro (every module file added since an empty base) did not pass: ${reason}"
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
  local gate
  for entry in "${_RP_AFTER_ADMIT[@]}"; do
    IFS='|' read -r name gate want file <<<"${entry}"
    _rp_selected "${name}" || continue
    ran=$(( ran + 1 ))
    _rp_after_admit "${scratch}" "${name}" "${gate}" "${want}" "${file}" || failed=1
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
  if _rp_selected retro; then
    ran=$(( ran + 1 ))
    _rp_retro "${scratch}" || failed=1
  fi
  _rp_control "${scratch}" || failed=1
  (( failed == 0 )) || exit 1
  echo "config-gen redpath: ${ran} planted cases went red, were refused or passed as planted; the control passed"
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  main "$@"
fi
