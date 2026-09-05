#!/usr/bin/env bash
# test.sh - Run CI pipeline (ShellCheck + Bats [+ Kcov])
#
# Usage:
#   ./test.sh                   # Run ShellCheck + Hadolint + Bats (fast dev loop)
#   ./test.sh --ci              # Run inside CI container (called by compose)
#   ./test.sh --lint            # Run all linters (ShellCheck + Hadolint) via
#                             # docker compose (the ci/test-tools image bakes in
#                             # hadolint). Narrow with --shellcheck / --hadolint
#                             # (ADR-00000011 #3 min->max)
#   ./test.sh --lint --shellcheck  # Only ShellCheck, via compose
#   ./test.sh --lint --hadolint    # Only Hadolint, via compose
#   ./test.sh --shellcheck-only # Run ShellCheck only, no compose, no bats deps
#                             # (used by self-test.yaml's dedicated shellcheck
#                             # job,; plain ubuntu-latest runner with
#                             # pre-installed shellcheck)
#   ./test.sh --<tool>-only     # Run ONE lint of the phase on the host, no
#                             # compose: --shellcheck-only / --issueref-only
#                             # / --adr-numbering-only /
#                             # --adr-structure-only /
#                             # --stale-setup-conf-only / --readme-sync-only
#                             # / --doc-counts-only / --home-literal-only /
#                             # --arch-literal-only /
#                             # --bash-source-guard-only /
#                             # --derived-figures-only / --i18n-orphan-only /
#                             # --early-close-reader-only /
#                             # --errexit-bang-only /
#                             # --self-hosted-guard-only /
#                             # --changelog-entry-only /
#                             # --pin-coverage-only /
#                             # --action-ref-agreement-only /
#                             # --generated-workflow-actions-only.
#                             # These are what the self-test.yaml lint jobs
#                             # call -- no CI job runs the lint phase itself
#   ./test.sh --hadolint-only   # Run Hadolint only inside the ci container
#                             # (single source of truth for the self-test.yaml
#                             # hadolint job;  ADR-00000011)
#   ./test.sh --bats-only       # Run Bats only inside compose (skip ShellCheck)
#                             # (used by self-test.yaml's bats jobs,)
#   ./test.sh --bats-unit-shard N/T  # Run unit shard N of T (skip ShellCheck +
#                                  # integration). Coverage-matrix slice
#                                  # primitive (greedy weight-balanced)
#   ./test.sh --bats-fragile         # Run ONLY the kcov-fragile unit specs in
#                                  # plain mode (the tests the coverage matrix
#                                  # skips). Used by the bats-fragile job in
#                                  # self-test.yaml
#   ./test.sh --bats-integration     # Run integration tests only (skip
#                                  # ShellCheck + unit). Used by the
#                                  # bats-integration job in self-test.yaml
#                                  #
#   ./test.sh --coverage        # Run ShellCheck + Bats + Kcov coverage
#                             # (full suite; local `just test coverage`)
#   ./test.sh --coverage-shard N/T  # Run kcov over coverage shard N of T
#                                  # (skip ShellCheck). Used by the coverage
#                                  # matrix in self-test.yaml. Codecov
#                                  # merges the per-shard uploads.
#   ./test.sh --coverage-path PATH  # Run ONE spec under kcov (instrumented
#                                  # inner loop). Reports no coverage
#                                  # figure and writes nothing to
#                                  # coverage/
#   ./test.sh -h, --help        # Show this help
#
# Kcov instrumentation wraps every bats command and slows the suite
# 2-5x, so the default no longer runs it. Run `--coverage` (or
# `just test coverage`) when you need the HTML report before
# releasing.

# Only set strict mode when running directly; when sourced, respect caller's settings
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
readonly REPO_ROOT

# Disable the wrapper transcript for the whole self-test: specs that
# run a wrapper main would otherwise tee a log/ tree into the mounted
# checkout (FILE_PATH/REPO_ROOT resolve to /source). The env override wins
# over setup.conf; transcript_spec clears it to exercise the conf logic.
export WRAPPER_TRANSCRIPT=false

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../dist/script/docker/lib/_lib.sh"

# Per-tool drivers. test.sh is the dispatcher (arg parsing, mode dispatch,
# CI-container setup); the per-tool execution lives in sourced driver
# libraries under drivers/. Each driver uses _log_* / _die from _lib.sh
# (sourced above) and references the ${REPO_ROOT} global defined here, so
# source order is: _lib.sh -> drivers. Adding a tool = a driver + a
# test/<tool>/ folder; the dispatcher is untouched (ADR-00000011).
# shellcheck source=script/test/drivers/shellcheck.sh
source "${SCRIPT_DIR}/drivers/shellcheck.sh"
# shellcheck source=script/test/drivers/hadolint.sh
source "${SCRIPT_DIR}/drivers/hadolint.sh"
# shellcheck source=script/test/drivers/bats.sh
source "${SCRIPT_DIR}/drivers/bats.sh"
# shellcheck source=script/test/drivers/issueref.sh
source "${SCRIPT_DIR}/drivers/issueref.sh"
# shellcheck source=script/test/drivers/adr_numbering.sh
source "${SCRIPT_DIR}/drivers/adr_numbering.sh"
# shellcheck source=script/test/drivers/adr_structure.sh
source "${SCRIPT_DIR}/drivers/adr_structure.sh"
# shellcheck source=script/test/drivers/stale_setup_conf.sh
source "${SCRIPT_DIR}/drivers/stale_setup_conf.sh"
# shellcheck source=script/test/drivers/readme_sync.sh
source "${SCRIPT_DIR}/drivers/readme_sync.sh"
# shellcheck source=script/test/drivers/doc_counts.sh
source "${SCRIPT_DIR}/drivers/doc_counts.sh"
# shellcheck source=script/test/drivers/home_literal.sh
source "${SCRIPT_DIR}/drivers/home_literal.sh"
# shellcheck source=script/test/drivers/arch_literal.sh
source "${SCRIPT_DIR}/drivers/arch_literal.sh"
# shellcheck source=script/test/drivers/bash_source_guard.sh
source "${SCRIPT_DIR}/drivers/bash_source_guard.sh"
# shellcheck source=script/test/drivers/early_close_reader.sh
source "${SCRIPT_DIR}/drivers/early_close_reader.sh"
# shellcheck source=script/test/drivers/errexit_bang.sh
source "${SCRIPT_DIR}/drivers/errexit_bang.sh"
# shellcheck source=script/test/drivers/derived_figures.sh
source "${SCRIPT_DIR}/drivers/derived_figures.sh"
# shellcheck source=script/test/drivers/i18n_orphan.sh
source "${SCRIPT_DIR}/drivers/i18n_orphan.sh"
# shellcheck source=script/test/drivers/self_hosted_guard.sh
source "${SCRIPT_DIR}/drivers/self_hosted_guard.sh"
# shellcheck source=script/test/drivers/changelog_entry.sh
source "${SCRIPT_DIR}/drivers/changelog_entry.sh"
# shellcheck source=script/test/drivers/changelog_layout.sh
source "${SCRIPT_DIR}/drivers/changelog_layout.sh"
# shellcheck source=script/test/drivers/pin_coverage.sh
source "${SCRIPT_DIR}/drivers/pin_coverage.sh"
# shellcheck source=script/test/drivers/action_ref_agreement.sh
source "${SCRIPT_DIR}/drivers/action_ref_agreement.sh"
# shellcheck source=script/test/drivers/generated_workflow_actions.sh
source "${SCRIPT_DIR}/drivers/generated_workflow_actions.sh"
# shellcheck source=script/test/drivers/just_provenance.sh
source "${SCRIPT_DIR}/drivers/just_provenance.sh"
# shellcheck source=script/test/drivers/catalog_description.sh
source "${SCRIPT_DIR}/drivers/catalog_description.sh"
# shellcheck source=script/test/drivers/shell_metrics.sh
source "${SCRIPT_DIR}/drivers/shell_metrics.sh"

# ── The lint phase's tool table ──────────────────────────────────────────────

# Every tool the lint phase runs, in phase order. THE list: three callers
# used to repeat it -- the full phase, the in-container LINT_TOOL
# narrowing, and the host-direct primitives -- so a newly added lint could
# be wired into one and silently missed by the others. They all dispatch
# through _run_lint_tool / _run_all_lint_tools below now.
#
# It is also the CI-coverage manifest: self_test_yaml_spec asserts that
# every entry here is RUN by a job in .github/workflows/self-test.yaml --
# a dedicated one (a host-direct `--<tool>-only` primitive, or the
# in-container hadolint job), or else exactly one group of the lint-static
# partition, which is computed from this very table. Add a lint here
# without giving it a CI job and that guard fails -- which is what stops
# the next lint from landing local-only, the way these four did.
readonly _LINT_TOOLS=(
  shellcheck
  hadolint
  issueref
  adr-numbering
  adr-structure
  stale-setup-conf
  readme-sync
  doc-counts
  home-literal
  arch-literal
  bash-source-guard
  early-close-reader
  errexit-bang
  derived-figures
  i18n-orphan
  self-hosted-guard
  changelog-entry
  changelog-layout
  pin-coverage
  action-ref-agreement
  generated-workflow-actions
  just-provenance
  catalog-description
)

# ORDER IS NOT A FAIL-FAST LEVER. It reads like one -- put the cheap
# drivers first and a broken tree is refused sooner -- and it stopped
# being one when the phase started running every driver (base#1059).
# Whatever the order, a run that enumerates ends when its LAST driver
# ends, so reordering moves only WHEN each finding appears on screen, not
# when the operator has the whole list -- and the whole list is what a
# cycle is spent on.
#
# The order therefore stays as it is: phase order, which is also the
# order the reports come out in and the order the failure summary names
# them in. The wall-clock lever that does exist is elsewhere: running the
# independent drivers concurrently, bounded by the slowest driver rather
# than by their sum, since a handful of them are most of the phase. That
# is a separate change with its own interleaving question and is
# deliberately not made here.
#
# What this comment does NOT carry is a measurement: how long a driver
# takes, or how far repeat timings of the table spread. Nothing re-derives
# such a figure -- no lint, no test, no generator -- the host and the tree
# both move it, and repeat runs of the same table on one machine do not
# agree either, so a number written here would be stale without saying so
# (ADR-00000028; `metrics` in justfile.test refuses the same thing for the
# same reason). Measure when the question is asked: `./script/test/test.sh
# --<tool>-only` times exactly one driver, host-direct. ci_spec pins this
# block to the argument and against the figures.
#
# END OF THE ORDER RATIONALE. ci_spec reads the block bounded by this
# sentence and the one that opens it, so neither a blank line inside the
# argument nor the paragraph below it can move what the two guards lint.
#
# Every tool but hadolint is runnable host-direct (`--<tool>-only`): the
# drivers are pure bash over the checkout, and shellcheck's binary ships
# on ubuntu-latest. hadolint's binary exists only in the alpine
# test-tools image, so its CI job runs the driver inside that image
# (`--lint --hadolint`) instead of host-direct.

# ── The lint-static CI partition ─────────────────────────────────────────────

# The lints of the table that carry a CI job of their OWN, and so are not
# part of the grouped lint-static jobs. Not a schedule and not a
# preference: each is here because something about it needs a job to
# itself -- shellcheck is the phase's own longest driver and ci-rollup
# reads its result by name, hadolint's binary exists only inside the
# test-tools image, and doc-counts is likewise read by name.
#
# THE OMISSION IS THE SAFE DIRECTION, which is why the roster this file no
# longer keeps is not simply moved here. A lint added to _LINT_TOOLS and
# not added here lands in a group and runs -- the default is covered. A
# lint given its own job and not added here runs TWICE, which wastes a
# runner and is visible. Neither direction can make a lint stop running,
# and self_test_yaml_spec refuses a name here that no dedicated job runs.
readonly _LINT_TOOLS_OWN_CI_JOB=(
  shellcheck
  hadolint
  doc-counts
)

# _lint_group_members <index>/<total> -- print the lints of one group.
#
# WHY A COMPUTED PARTITION AND NOT A GROUP LIST. The alternative is a
# table saying which driver belongs to which group. That table is a
# roster: it is correct on the day it is written and wrong on the day the
# next driver is added, and nothing notices, because a driver named in no
# group simply stops running in CI while every check stays green. This
# repo has decayed that way three times already (the _LINT_TOOLS
# completeness gap, the downstream roster, the release archive's path
# list). So the grouping falls out of _LINT_TOOLS, and adding a driver to
# that table is the whole of adding it to CI -- no workflow edit, no
# second list to keep true.
#
# THE PARTITION IS ROUND-ROBIN OVER TABLE POSITION, and deliberately
# blind to what a driver costs. A cost-weighted assignment would need
# per-driver durations written down, and a duration is exactly the
# hand-maintained figure ADR-00000028 refuses: the tree moves it, the host
# moves it, repeat runs on one machine move it, and nothing re-derives it.
# Round-robin needs no such input and cannot go stale. What it gives up is
# balance BETWEEN groups: the slowest group is the longest single driver
# -- which no assignment can beat -- plus whatever else the deal put
# beside it, so the phase runs somewhat above that floor rather than at
# it. The group count's rationale in .github/workflows/self-test.yaml says
# what that costs and why it is still the trade being made.
#
# The spec is validated rather than trusted. Every rejection here is a way
# a CI job could run zero drivers and exit 0 -- a check that goes green
# having gated nothing, which is the failure the grouping exists to avoid,
# arriving by another door.

# The group a validated spec names. Set by _refuse_bad_lint_group below,
# read by its callers; meaningless before it has run.
_LINT_GROUP_INDEX=0
_LINT_GROUP_TOTAL=0

# _refuse_bad_lint_group <index>/<total> -- parse and range-check a group
# spec, or die naming which of those it failed.
#
# SEPARATE FROM THE LISTER, and called by both, because of WHERE each of
# them runs. `_run_lint_group` reads the lister through a process
# substitution, so a `_die` in the lister kills that subshell alone: the
# runner sees an empty list and reports the empty group, which is not why
# the spec was refused. That wrong reason is the visible half. The
# invisible half is that the runner would be reading the lister's OUTPUT
# as its verdict -- a lister that printed one member before dying hands
# back a truncated group, and a truncated group runs to a green exit
# having gated only part of the phase. So the runner validates in its own
# shell, where a refusal is a refusal, and the lister's copy is a backstop
# rather than the mechanism.
#
# `10#` because the regex above accepts digits and `(( ))` reads them as a
# NUMBER: a zero-padded `1/08` is a well-formed spec by every rule stated
# here and an invalid octal constant to bash arithmetic, which answers
# with its own "value too great for base" and a status this function would
# then blame on the range.
_refuse_bad_lint_group() {
  local _spec="${1:-}"
  [[ "${_spec}" =~ ^([0-9]+)/([0-9]+)$ ]] || _die ci_bad_lint_group \
    "lint group '${_spec}' is not <index>/<total> (e.g. 1/4)."
  _LINT_GROUP_INDEX=$(( 10#${BASH_REMATCH[1]} ))
  _LINT_GROUP_TOTAL=$(( 10#${BASH_REMATCH[2]} ))
  (( _LINT_GROUP_TOTAL >= 1 )) || _die ci_bad_lint_group \
    "lint group '${_spec}' asks for ${_LINT_GROUP_TOTAL} groups; a partition has at least one."
  (( _LINT_GROUP_INDEX >= 1 && _LINT_GROUP_INDEX <= _LINT_GROUP_TOTAL )) \
    || _die ci_bad_lint_group \
    "lint group '${_spec}' is outside its own total; expected 1..${_LINT_GROUP_TOTAL}."
}

_lint_group_members() {
  _refuse_bad_lint_group "${1:-}"
  local _index="${_LINT_GROUP_INDEX}" _total="${_LINT_GROUP_TOTAL}"

  local _tool _own _skip _position=0
  for _tool in "${_LINT_TOOLS[@]}"; do
    _skip=0
    for _own in "${_LINT_TOOLS_OWN_CI_JOB[@]}"; do
      [[ "${_tool}" != "${_own}" ]] || _skip=1
    done
    (( _skip == 0 )) || continue
    if (( _position % _total == _index - 1 )); then
      printf '%s\n' "${_tool}"
    fi
    _position=$(( _position + 1 ))
  done
}

# The lint tool currently on the stack, for _lint_driver_failed below.
# Empty whenever no driver is running.
_LINT_ACTIVE_TOOL=""

# _lint_driver_failed <status> <command>
#
# ERR-trap body for the lint phase. A driver stops at its first failing
# command under `set -e`, and some of those commands say nothing at all on
# the way out -- a signal above all, and SIGPIPE (141) most of all, from a
# pipeline whose reader closed before the writer wrote. `just` then prints
# only `recipe 'lint' failed ... exit code 141`, which reads like a lint
# finding rather than a broken driver, and the local-CI stamp is withheld
# with no explanation of what to fix.
#
# So name the tool, the status and the command that stopped it, and
# translate an above-128 status into the signal it encodes. `_die` (not a
# bare `_log_err`) because the event id has to be registered in
# log-events.txt, which is what keeps this reportable rather than another
# anonymous exit.
_lint_driver_failed() {
  local _status="${1}" _command="${2}"
  local _detail=""
  if (( _status > 128 )); then
    local _signal=$(( _status - 128 ))
    local _name
    _name="$(kill -l "${_signal}" 2>/dev/null)" || _name="?"
    _detail=" (killed by signal ${_signal}/SIG${_name#SIG})"
  fi
  _die ci_lint_driver_failed \
    "lint tool '${_LINT_ACTIVE_TOOL}' stopped at \`${_command}\`, status ${_status}${_detail}."
}

# _refuse_suppressed_errexit <what> -- die if a COMMAND SUBSTITUTION of
# this call sees errexit suppressed.
#
# bash suppresses errexit for every command of an `if` condition, an
# `&&` / `||` list or a `!`, and the suppression follows the call into the
# functions and subshells below it -- an ERR trap is suppressed with it,
# and a `set -e` inside does not give it back. Everything the lint phase
# leans on to stop a driver at its first failing command is therefore a
# property of how the phase was CALLED, and an unenforced precondition
# defaults to pass: the driver sails, the dispatch returns zero, and the
# tree is reported clean.
#
# So the precondition is measured. The probe is a subshell that arms
# errexit and then fails. With errexit reaching it, it dies at the `false`
# and prints nothing; inside a suppression context it sails and prints.
# The wrapping `( ... ); true` keeps the substitution's own status zero, so
# the probe is safe to run under the caller's errexit; `|| true` around it
# would instead create the very context it asks about and always answer
# "suppressed".
#
# WHAT IT MEASURES IS NARROWER THAN WHAT IT GUARDS, and the header says
# "command substitution" because of it. The probe runs inside `$( ... )`;
# the drivers run inside a plain `( ... )`. Those two answer the same for a
# direct `if` / `&&` / `||` / `!` caller, and differently through `eval`:
# on bash 5.1, `if eval f` leaves the substitution reporting errexit ARMED
# while a plain `( set -e; false )` subshell of that same call still sails.
# An eval'd suppressing caller is therefore NOT refused here.
#
# It is still not a way to make a driver sail, because this is not the only
# mechanism: `_run_lint_tool` arms `set -E` and an ERR trap around the
# dispatch, `eval` does not disarm either, and the driver dies at its first
# failing command with `ci_lint_driver_failed` naming it. ci_spec pins that
# ("an eval'd caller escapes the probe, the driver still cannot sail"), so
# the narrower claim above rests on a measured mechanism rather than on the
# absence of a report. What this refusal buys over the trap alone is the
# earlier and better-named stop: one refusal, before any driver runs.
#
# CALL THIS AS A PLAIN STATEMENT. Called from a condition of its own it
# measures that condition and refuses every time -- which is the honest
# answer to the question it is asked, and useless as a guard.
_refuse_suppressed_errexit() {
  local _what="${1:?BUG: _refuse_suppressed_errexit expects <what>}"
  local _probe
  _probe="$( ( set -e; false; printf suppressed ); true )"
  [[ -z "${_probe}" ]] || _die ci_lint_errexit_suppressed \
    "${_what} was called from a context that suppresses errexit (an 'if' condition, an '&&' / '||' list, or '!'). bash propagates that suppression into the driver, which would then run past its own first failing command and be reported as clean. Call it as a plain statement and let its failure end the run."
}

# Run one lint tool by name. The single dispatch point; unknown names die
# loudly rather than no-op'ing, so a typo in a CI job or a stale
# LINT_TOOL export cannot silently skip a gate.
#
# The ERR trap is armed only around the dispatch, and errexit is left
# ALONE: a driver must still stop at its first failing command (running it
# under `|| _rc=$?` would disable errexit inside the whole driver and let
# a failure sail past). `-E` is required because an ERR trap is not
# inherited by shell functions, and every driver is one.
_run_lint_tool() {
  _refuse_suppressed_errexit "the lint dispatch for '${1:-}'"
  _LINT_ACTIVE_TOOL="${1:-}"
  set -E
  trap '_lint_driver_failed "$?" "${BASH_COMMAND}"' ERR
  case "${1:-}" in
    shellcheck)       _run_shellcheck ;;
    hadolint)         _run_hadolint ;;
    issueref)         _run_issueref ;;
    adr-numbering)    _run_adr_numbering ;;
    adr-structure)    _run_adr_structure ;;
    stale-setup-conf) _run_stale_setup_conf ;;
    readme-sync)      _run_readme_sync ;;
    doc-counts)       _run_doc_counts ;;
    home-literal)     _run_home_literal ;;
    arch-literal)     _run_arch_literal ;;
    bash-source-guard) _run_bash_source_guard ;;
    early-close-reader) _run_early_close_reader ;;
    errexit-bang)     _run_errexit_bang ;;
    derived-figures)  _run_derived_figures ;;
    i18n-orphan)      _run_i18n_orphan ;;
    self-hosted-guard) _run_self_hosted_guard ;;
    changelog-entry)  _run_changelog_entry ;;
    changelog-layout) _run_changelog_layout ;;
    pin-coverage)     _run_pin_coverage ;;
    action-ref-agreement) _run_action_ref_agreement ;;
    generated-workflow-actions) _run_generated_workflow_actions ;;
    just-provenance)  _run_just_provenance ;;
    catalog-description) _run_catalog_description ;;
    # The three implementation-standard metric lints and their combined
    # report (base#994 phase 2). Dispatchable here -- this is the one
    # place a lint driver is run, and the ERR trap above is what names
    # the tool when one dies on a signal -- but deliberately ABSENT from
    # _LINT_TOOLS. Each judges by an adoption ceiling (base#994 phase 3), so
    # what keeps them out of the table is no longer an unflattened tree:
    # it is that _LINT_TOOLS runs INSIDE the ci container while their
    # population comes from the git index, and a `git worktree`
    # checkout's `.git` is a file pointing outside the bind mount. Giving
    # the lint phase a host-direct leg is phase 4's, along with the CI
    # jobs the table's completeness guard then demands.
    nesting-depth)    _run_nesting_depth ;;
    function-length)  _run_function_length ;;
    positional-params) _run_positional_params ;;
    shell-metrics)    _run_shell_metrics ;;
    *) _die ci_unknown_lint_tool \
         "Unknown LINT_TOOL '${1:-}' (expected $(printf '%s | ' "${_LINT_TOOLS[@]}")empty)." ;;
  esac
  trap - ERR
  set +E
  _LINT_ACTIVE_TOOL=""
}

# Run a set of lint tools and report EVERY one that failed.
#
# The phase used to be a bare loop over the table under this file's
# `set -e`, so the first failing driver ended the run and every driver
# behind it was never reached -- measured on a branch mid-merge, 17
# drivers ran, `changelog-entry` died, and every entry behind it in the
# table, `changelog-layout` through `catalog-description`, was not
# attempted. A tree with three violations therefore cost three full gate
# cycles, and after each one nothing said how many remained (base#1059).
#
# Running them all is sound because the drivers are INDEPENDENT: the
# dispatch above is a `case`, each driver reads its own file set off the
# checkout, and none consumes another's output or writes anything a later
# one reads.
#
# THE SUBSHELL SHAPE IS LOAD-BEARING. The obvious spelling --
#
#   ( _run_lint_tool "${_tool}" ) || _failed+=( "${_tool}" )
#
# -- is wrong, and wrong in exactly the way _run_lint_tool's header
# refuses. bash suppresses `errexit` for the whole of a command that is
# part of a `||` list, and the suppression reaches INSIDE the subshell;
# a `set -e` in the subshell body does not bring it back (verified on
# bash 5.1 and 5.2). The driver would then sail past its own first
# failing command, which is the one thing this change must not buy.
#
# So the parent clears errexit for the loop and reads `$?` from a
# STANDALONE subshell -- no `||`, no `if`, nothing that creates the
# suppression context -- which re-arms `set -e` for itself. Each driver
# keeps its own errexit and its own ERR trap, and the trap still names
# the driver that died because `_LINT_ACTIVE_TOOL` is set inside that
# same subshell. stdout and stderr are inherited, not piped, so the
# drivers that stream progress interleave exactly as they did before.
#
# THAT SHAPE IS ONLY HALF THE INVARIANT. The suppression a `||` creates
# is a property of the CALL, not of this function: a caller who writes
# `if _run_lint_tools ...`, `_run_lint_tools ... || x` or `! _run_lint_tools
# ...` hands the same suppression through this function into the
# standalone subshell, and the driver sails past its first failing
# command exactly as it would in the spelling above -- only now the
# subshell exits 0, `_failed` stays empty, and the PHASE REPORTS CLEAN.
# Nothing inside the subshell repairs it (`( set +e; set -e; ... )` and an
# `ERR` trap were both tried); only a separate process escapes it. So the
# precondition is enforced instead of assumed, by the shared refusal above
# -- every caller shape its probe can read defaults to a refusal, not to a
# pass. A shape the probe cannot read is a different case and is handled
# by a different mechanism, not by this one: an `eval`'d suppressing caller
# is measured as armed and passes here, and is stopped one level down by
# `_run_lint_tool`'s ERR trap. Both are pinned in ci_spec, and the refusal's
# header carries the boundary between them.
#
# `_run_lint_tool` guards itself the same way, because `main --ci` also
# calls it on its own -- which is why an assertion about THIS refusal has
# to name the phase: the driver's copy emits the same event, and a spec
# that only reads the event name cannot tell the two apart.
#
# The caller's errexit is restored before returning: a phase that
# silently left `set +e` behind would disarm every check after it.
_run_lint_tools() {
  _refuse_suppressed_errexit "the lint phase"
  local _tool _rc
  local _caller_opts="$-"
  local -a _failed=()
  set +e
  for _tool in "$@"; do
    ( set -e; _run_lint_tool "${_tool}" )
    _rc=$?
    (( _rc == 0 )) || _failed+=( "${_tool}" )
  done
  [[ "${_caller_opts}" != *e* ]] || set -e
  (( ${#_failed[@]} == 0 )) || _die ci_lint_phase_failed \
    "${#_failed[@]} of $# lint tools failed: ${_failed[*]}. Each report is above, in phase order; this run enumerated all of them."
}

# Run the whole lint phase, in table order.
_run_all_lint_tools() {
  _run_lint_tools "${_LINT_TOOLS[@]}"
}

# Run one group of the partition, host-direct. The CI join for the
# grouped lint-static jobs.
#
# `_run_lint_tools`, not a loop: the group has to report EVERY driver in
# it that failed, in phase order, because the checks list no longer names
# the failing lint -- the job's name is a group, and its output is where
# the answer now is (base#1059 is what made that output complete; before
# it the phase stopped at the first failure, and a grouped job would have
# hidden the rest).
#
# An EMPTY group is refused rather than run. `_run_lint_tools` over
# nothing succeeds, so a total larger than the number of grouped lints
# would leave the tail jobs green having run no lint at all. That refusal
# is about a VALID spec whose group happens to be empty, which is why the
# spec itself is checked first and separately: read off the member list
# alone, "no members" is also what a spec that never parsed looks like,
# and the run would name the wrong reason.
_run_lint_group() {
  local _spec="${1:-}"
  # In THIS shell, before the process substitution below swallows it.
  _refuse_bad_lint_group "${_spec}"
  local -a _members=()
  mapfile -t _members < <(_lint_group_members "${_spec}")
  (( ${#_members[@]} > 0 )) || _die ci_bad_lint_group \
    "lint group '${_spec}' contains no lint; a job that runs nothing must not report success."
  _run_lint_tools "${_members[@]}"
}

# ── Help ─────────────────────────────────────────────────────────────────────

usage() {
  cat >&2 <<'EOF'
Usage: ./test.sh [OPTIONS]

Run CI pipeline: ShellCheck + Bats [+ Kcov coverage].

Options:
  --ci                    Run directly inside CI container (called by
                          compose); honors $COVERAGE=1 to include kcov,
                          $COVERAGE_SHARD to kcov one shard of the matrix,
                          $COVERAGE_PATH to kcov ONE named spec and report
                          no figure,
                          $BATS_ONLY=1 to skip the ShellCheck phase,
                          $BATS_UNIT_SHARD to run only one matrix shard,
                          $BATS_FRAGILE=1 to run only the kcov-fragile specs,
                          $BATS_INTEGRATION=1 to run integration only
  --lint                  All linters (ShellCheck + Hadolint) via docker
                          compose; the ci/test-tools image bakes in hadolint.
                          Narrow with --shellcheck / --hadolint (#650)
  --shellcheck            With --lint: run only ShellCheck (still via compose)
  --hadolint              With --lint: run only Hadolint (still via compose)
  --issueref              With --lint: run only the issue-ref comment lint
                          (no transient #NNN in code comments; ADR-00000013)
  --shell-metrics-only    Report the three implementation-standard shell
                          metrics -- nesting depth <= 3, function length
                          <= 50 body code lines, positional parameters
                          <= 5 -- over every tracked shell file, and fail
                          only ABOVE each metric's adoption ceiling: the
                          number of functions base#994 phase 3 has not
                          flattened yet, one readonly integer in
                          script/test/drivers/shell_metrics.sh that may
                          only ever go down. Every run prints count /
                          limit / ceiling / slack, clean or not. Also
                          --nesting-depth-only / --function-length-only /
                          --positional-params-only for one metric at a
                          time. NOT part of the default gate or of --lint
                          -- no longer because the tree is unflattened,
                          which the ceiling settled, but because the lint
                          phase runs INSIDE the ci container while this
                          population is derived from the git index, which
                          a container bind-mounting a `git worktree`
                          checkout cannot read. Giving the phase a
                          host-direct leg is base#994 phase 4's, and it
                          is why this entry is host-direct only.
                          `just test metrics` is the wrapper.
  --adr-numbering         With --lint: run only the ADR-numbering lint
                          (doc/adr/ duplicate-free + well-formed; gaps
                          warned, not failed)
  --adr-structure         With --lint: run only the ADR-structure lint
                          (every ADR carries a '> Serves:' back-pointer,
                          ## Context / ## Decision / ## Consequences /
                          ## Alternatives, and a Status of exactly
                          Accepted | Rejected | Superseded by
                          ADR-NNNNNNNN; zero ADRs examined is a refusal,
                          not a pass)
  --stale-setup-conf      With --lint: run only the stale setup.conf path
                          lint (no legacy config/docker/setup.conf in
                          dist/**/*.sh; the override lives at the repo-root
                          .setup.conf dotfile)
  --readme-sync           With --lint: run only the localized README sync
                          lint (each doc/readme/README.*.md section records
                          the hash of the README.md section it was
                          translated against AND of the translated section
                          itself; re-stamp with 'just test sync-readme',
                          which refuses to move an English hash while the
                          translation stands still)
  --doc-counts            With --lint: run only the doc/test count drift
                          gate (doc/test/*.md figures are generated from
                          the specs; regenerate with 'just test sync-docs').
                          Same gate as 'just test sync-docs-check' and as
                          the advisory harness PostToolUse hook -- one rule,
                          three entry points, this one being the blocking
                          one
  --home-literal          With --lint: run only the hardcoded home path
                          lint (no concrete username in a home path under
                          dist/ or dockerfile/ -- the container user is a
                          BUILD arg, so a literal breaks under a different
                          USER_NAME; bake artifacts at /opt, ADR-00000024)
  --arch-literal          With --lint: run only the bare architecture literal
                          lint (a shipped Dockerfile under dist/ or
                          dockerfile/ may not write an architecture into a
                          string -- buildx builds one file per --platform, so
                          the literal ships the wrong artifact inside every
                          other platform's image. Express it via
                          ARG TARGETARCH; a mapping onto an upstream asset
                          spelling opts out with a reason)
  --bash-source-guard     With --lint: run only the unguarded BASH_SOURCE
                          read lint (a self-locating read under dist/ or
                          script/ must default to $0; undefaulted it aborts
                          under the script's own nounset wherever bash does
                          not populate the array, e.g. the kcov shard)
  --early-close-reader    With --lint: run only the early-closing-reader
                          pipeline lint (nothing under dist/ or script/ may
                          pipe into `head` or into a quiet `grep`: the
                          reader leaves on its first match, the writer
                          still writing takes SIGPIPE, and pipefail turns a
                          SUCCESSFUL match into the pipeline's failure --
                          an inverted answer the caller acts on in silence)
  --errexit-bang          With --lint: run only the non-final bang-statement
                          lint (inside a bats test body, a `! <cmd>` line is
                          an assertion ONLY as the body's last statement --
                          bash exempts a `!` pipeline from errexit, so
                          anywhere else the command runs, the negation is
                          computed and the answer discarded, and the case
                          name claims a property the body never checked)
  --derived-figures       With --lint: run only the derived-figure lint (a
                          figure a document repeats must match the code
                          that defines it -- the baseline stage blocklist
                          comes from _validate_stage_name's own case arms,
                          the setup.conf section list and count from
                          SCHEMA_SECTIONS)
  --i18n-orphan           With --lint: run only the translation-only
                          identifier lint (an identifier-shaped token in a
                          doc/readme/README.*.md code span that README.md
                          never names -- either a mechanism removed from the
                          code while the translation kept documenting it, or
                          a translation running ahead of the English)
  --self-hosted-guard     With --lint: run only the self-hosted runner
                          guard lint (every workflow job that can land on
                          a self-hosted runner -- anything whose runs-on
                          does not statically resolve to reserved
                          ubuntu-* / windows-* / macos-* labels -- must
                          carry the same-repository condition, so fork-PR
                          code can never execute on the org's self-hosted
                          machine)
  --changelog-entry       With --lint: run only the changelog entry lint
                          ([Unreleased] entries only: a category heading
                          drawn from the locked roster in
                          script/release/changelog_categories.sh, which
                          doc/changelog/CONVENTIONS.md must print
                          unchanged; a length cap measured
                          over the whole entry with whitespace collapsed,
                          so rewrapping the same prose or splitting it into
                          sub-bullets buys no budget; plus an entry that
                          repeats another's lead bullet and a category
                          heading that opens twice in one release block,
                          both reported with BOTH line numbers. Released
                          sections are never checked -- rewriting a shipped
                          entry falsifies it)
  --changelog-layout      With --lint: run only the changelog layout lint
                          (the changelog is one file per 0.Y series behind
                          a generated index: a vX.Y.Z section lives in
                          vX.Y.md, its compare-link definition lives in the
                          SAME file because markdown link definitions are
                          file-scoped, exactly one series file carries
                          '## [Unreleased]', and the index block is
                          re-derived by script/release/changelog_index.sh
                          and must match what is committed)
  --pin-coverage          With --lint: run only the pin-coverage lint
                          (every third-party version this repo names in a
                          Dockerfile or a workflow -- the versions
                          dependabot cannot see -- carries a `tool-pin:`
                          marker saying where its upstream lives, so the
                          release watch's table is derived from the
                          declaration sites instead of a roster that falls
                          behind them)
  --action-ref-agreement  With --lint: run only the action ref agreement
                          lint (every call site of one action's REPOSITORY
                          across .github/workflows/ must name the same ref;
                          a partial bump is invisible to actionlint, which
                          reads each `uses:` in isolation, and dependabot
                          never re-raises a version pair whose PR was
                          closed. One call site may hold back behind an
                          `action-ref-agreement: allow -- <why>` comment)
  --generated-workflow-actions
                          With --lint: run only the generated-workflow
                          action ref lockstep lint (a `uses:` ref a shell
                          script writes into a generated workflow must
                          name the ref .github/workflows/ uses, since
                          dependabot reads workflow files and cannot see
                          a ref inside a heredoc)
  --catalog-description   With --lint: run only the test description
                          marker lint (every `@test` in the spec trees
                          carries a `# why:` block above it, and every
                          block is attached to one; the undescribed count
                          stays under the driver's transition ceiling)
  --just-provenance       With --lint: run only the just provenance pin
                          lint (every site under dockerfile/,
                          .github/workflows/, dist/ or script/ that
                          OBTAINS the `just` runner names the one pinned
                          version -- ARG JUST_VERSION in
                          dockerfile/Dockerfile.test-tools, read through
                          dist/script/base/just-version.sh -- or carries a
                          justified advisory region saying why it cannot
                          be pinned; the marker grammar is documented in
                          script/test/drivers/just_provenance.sh)
  --<tool>-only           Run ONE lint from the phase directly on this
                          host: no compose, no test-tools image. These are
                          the CI join for the lint phase -- no CI job runs
                          the phase itself (the lint jobs narrow to one
                          tool, and every bats / coverage job sets
                          BATS_ONLY=1 / COVERAGE=1, which skip it), so
                          self-test.yaml runs the same drivers -- a
                          dedicated job calls one of these, and a
                          lint-static group calls --lint-group, which runs
                          several. Available:
                            --shellcheck-only        (needs shellcheck in
                                                     PATH; ubuntu-latest
                                                     ships it)
                            --issueref-only          pure bash
                            --adr-numbering-only     pure bash
                            --adr-structure-only     pure bash
                            --stale-setup-conf-only  pure bash
                            --readme-sync-only       pure bash
                            --doc-counts-only        pure bash + diff
                            --home-literal-only      pure bash
                            --arch-literal-only      pure bash
                            --bash-source-guard-only pure bash
                            --early-close-reader-only pure bash
                            --errexit-bang-only      pure bash
                            --derived-figures-only   pure bash
                            --i18n-orphan-only       pure bash
                            --self-hosted-guard-only pure bash
                            --changelog-entry-only   pure bash
                            --changelog-layout-only  pure bash
                            --pin-coverage-only      pure bash
                            --action-ref-agreement-only pure bash
                            --generated-workflow-actions-only pure bash
                          (no --hadolint-only equivalent: hadolint exists
                          only in the test-tools image; see below)
  --lint-group N/T        Run lint group N of T directly on this host, no
                          compose. The grouped CI join: the drivers are
                          split round-robin over the _LINT_TOOLS table
                          (minus the lints that carry their own job), so
                          adding a lint to the table puts it in a group
                          with nothing else edited. Every failing driver
                          in the group is reported, not just the first.
  --lint-group-members N/T
                          Print the lints of group N of T, one per line,
                          and run none of them.
  --hadolint-only         Hadolint only, directly inside the ci container
                          (hadolint baked into the test-tools image). Single
                          source of truth for self-test.yaml's hadolint job
                          (#650)
  --bats-only             Bats only inside compose (skip ShellCheck) (#376)
  --bats-unit-shard N/T   Run unit shard N of T (skip ShellCheck +
                          integration). Greedy weight-balanced partition;
                          the coverage matrix slice primitive (#377, #677)
  --bats-fragile          Run ONLY the kcov-fragile unit specs in plain mode
                          (skip ShellCheck + integration). These are the
                          tests the coverage matrix skips; the bats-fragile
                          job in self-test.yaml runs them so no unit test
                          goes unrun (#677)
  --bats-integration      Run integration tests only (skip ShellCheck +
                          unit). Used by the bats-integration job in
                          self-test.yaml (#377)
  --bats-path PATH        Run a single spec FILE or DIRECTORY (repo-root-
                          relative, e.g. test/bats/unit/ci_spec.bats) via the ci
                          container. Skips ShellCheck + kcov for a fast TDD
                          inner loop. test/bats/system/ is rejected (needs
                          the ci-system service); cannot combine with
                          --coverage -- that combination is --coverage-path
                          (#523)
  --filter REGEX          Pass a bats -f name filter (within-file single-test
                          selection); usable with or without --bats-path.
                          Without a path it filters unit + integration (#523)
  --coverage              Run tests with Kcov coverage (slow; CI / release
                          check). Full suite (unit + integration). Local
                          `just test coverage`.
  --coverage-shard N/T    Run kcov over coverage shard N of T (skip
                          ShellCheck). Mirrors --bats-unit-shard's
                          round-robin slice; integration runs on the last
                          shard. Used by the coverage matrix in
                          self-test.yaml (#615). Codecov merges the
                          per-shard uploads into one project figure.
  --coverage-path PATH    Run ONE spec FILE or DIRECTORY (repo-root-
                          relative) under kcov via the coverage container:
                          the inner loop for a spec that is red under kcov
                          and green without it. Combines with --filter to
                          instrument a single test. It reports NO coverage
                          figure and writes nothing into coverage/ -- one
                          spec's lines over the whole tree's denominator is
                          not a project rate, and the gate must never be
                          handed one. The target is the path you name, so
                          the shard partition (which differs between a
                          local run and CI) cannot change what runs.
                          Rejected with --coverage / --coverage-shard /
                          --bats-path (#887)
  --test-tools-image      Print the local test-tools tag this checkout
                          resolves (a content hash of
                          dockerfile/Dockerfile.test-tools) and exit.
                          TEST_TOOLS_IMAGE, when set, is echoed verbatim.
  --await-project         Wait for the previous run's container to let go
                          of this checkout's compose project network, then
                          exit 0; exit non-zero -- naming the container and
                          the verb that clears it -- when it is still held
                          after the window (BASE_PROJECT_WAIT, default 2m).
                          A query that mints nothing, for the flows that
                          drive compose themselves (`just test system` /
                          `just test smoke`); the ordinary dispatch asks on
                          its own
  --compose-project-name  Print the compose project name this checkout
                          resolves (a hash of its absolute path, so two
                          checkouts sharing a directory basename do not
                          share a project) and exit. COMPOSE_PROJECT_NAME,
                          when set, is echoed verbatim.
  -h, --help              Show this help

Default (no flag): ShellCheck + Hadolint + bats via docker compose, no
kcov. Kcov wraps every bats command and slows the suite 2-5x, so the
dev-loop default skips it.

Every compose dispatch snapshots the checkout either side of the run and
fails naming any path the suite changed: a spec may READ the live tree,
but a write there makes every other spec's read racy under the 32-way
parallel suite. An edit you already had in flight appears in both
snapshots and cancels, so a dirty working tree is fine; an edit made
WHILE the suite runs cannot be told apart from a spec's write, and
TEST_RESIDUE_GUARD=0 switches the guard off for that one invocation. It
is inert outside a git checkout (a released tarball).

Examples:
  ./test.sh                       # Fast: ShellCheck + Hadolint + Bats (no kcov)
  just test      # Same as above
  ./test.sh --coverage            # Full: ShellCheck + Hadolint + Bats + Kcov
  just test coverage  # Same as above
  just test lint      # All linters (ShellCheck + Hadolint)
  just test lint --shellcheck     # ShellCheck only
  just test lint --hadolint       # Hadolint only
  just test lint --readme-sync    # Localized README sync lint only
  just test lint --doc-counts     # doc/test count drift gate only
  just test lint --home-literal   # hardcoded home path lint only
  just test lint --arch-literal   # bare architecture literal lint only
  just test lint --bash-source-guard  # unguarded BASH_SOURCE read lint only
  just test lint --early-close-reader # early-closing-reader pipeline lint only
  just test lint --errexit-bang   # non-final bang-statement lint only
  just test lint --just-provenance # just provenance pin lint only
  just test lint --catalog-description # test description marker lint only
  ./test.sh --shellcheck-only     # Direct shellcheck, no compose
  ./test.sh --doc-counts-only     # Direct doc/test count drift gate, no compose
  ./test.sh --readme-sync-only    # Direct localized README sync lint, no compose
  ./test.sh --home-literal-only   # Direct hardcoded home path lint, no compose
  ./test.sh --arch-literal-only   # Direct bare architecture literal lint, no compose
  ./test.sh --bash-source-guard-only  # Direct unguarded BASH_SOURCE lint, no compose
  ./test.sh --early-close-reader-only # Direct early-closing-reader lint, no compose
  ./test.sh --errexit-bang-only   # Direct non-final bang-statement lint, no compose
  ./test.sh --derived-figures-only # Direct derived-figure lint, no compose
  ./test.sh --i18n-orphan-only    # Direct translation-only identifier lint, no compose
  ./test.sh --self-hosted-guard-only # Direct self-hosted runner guard lint, no compose
  ./test.sh --changelog-entry-only # Direct changelog entry lint, no compose
  ./test.sh --pin-coverage-only   # Direct tool-pin coverage lint, no compose
  ./test.sh --action-ref-agreement-only # Direct action ref agreement lint, no compose
  ./test.sh --generated-workflow-actions-only # Direct generated-workflow action ref lint, no compose
  ./test.sh --just-provenance-only # Direct just provenance pin lint, no compose
  ./test.sh --catalog-description-only # Direct test description marker lint, no compose
  ./test.sh --hadolint-only       # Hadolint only (inside ci container)
  ./test.sh --bats-only           # Compose-bats only, skip ShellCheck
  ./test.sh --bats-unit-shard 1/2 # Compose-bats unit shard 1 of 2
  ./test.sh --bats-fragile        # Compose-bats kcov-fragile specs (plain)
  ./test.sh --bats-integration    # Compose-bats integration only
  ./test.sh --bats-path test/bats/unit/ci_spec.bats          # one spec, fast
  ./test.sh --bats-path test/bats/unit/                       # one directory
  ./test.sh --bats-path test/bats/unit/ci_spec.bats --filter 'shard'  # + name filter
  ./test.sh --filter 'cap_add'    # filter across unit + integration
  ./test.sh --coverage-path test/bats/unit/ci_spec.bats  # one spec, under kcov
  just test coverage-path test/bats/unit/ci_spec.bats    # same, via just
  ./test.sh --coverage-path test/bats/unit/ci_spec.bats --filter 'shard'  # one test, under kcov
EOF
  exit 0
}

# ── CI container setup ───────────────────────────────────────────────────────

_die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; exit 1; }

# _validate_spec_target <path>
#
# Shared host-side validation for the two flags that name a spec target,
# `--bats-path` (plain) and `--coverage-path` (kcov). Both resolve the
# path INSIDE the container as ${REPO_ROOT}/<path>, so both reject the
# same two cases, and checking here means a typo costs an error message
# rather than a container start.
#
# test/bats/system/ is refused because those specs need the ci-system
# service (host docker.sock + MOUNT_DOCKER_SOCK), which neither flag's
# service provides -- running them anywhere else fails on a missing
# socket, well after the point where the cause is obvious.
_validate_spec_target() {
  local _path="${1:?BUG: _validate_spec_target expects <path>}"
  if [[ "${_path}" == test/bats/system || "${_path}" == test/bats/system/* ]]; then
    _die ci_bats_path_system \
      "test/bats/system/ needs the ci-system service + docker.sock; run 'just test system' (host test.sh cannot launch it)."
  fi
  [[ -e "${REPO_ROOT}/${_path}" ]] \
    || _die ci_bats_path_not_found \
      "No such spec file or directory: ${_path} (path is repo-root-relative, resolved as \${REPO_ROOT}/${_path})."
}

# ── Released-tree fixture ────────────────────────────────────────────────────

# The ONE spec that reads .prev-release/. Repo-root-relative, because that
# is how the dispatch flags and the shard partition both name a spec.
readonly _PREV_RELEASE_SPEC="test/bats/integration/prev_release_upgrade_spec.bats"

# _prev_release_spec_under <path>
#   True when <path> -- a repo-root-relative file or directory, as
#   `--bats-path` / `--coverage-path` name one -- selects that spec.
_prev_release_spec_under() {
  local _path="${1%/}"
  # A target naming the root selects everything under it.
  if [[ -z "${_path}" || "${_path}" == "." ]]; then
    return 0
  fi
  [[ "${_PREV_RELEASE_SPEC}" == "${_path}" \
     || "${_PREV_RELEASE_SPEC}" == "${_path}/"* ]]
}

# _prev_release_spec_in_selection
#   True when the newline-separated list of absolute spec paths on stdin
#   contains that spec.
_prev_release_spec_in_selection() {
  grep -qxF "${REPO_ROOT}/${_PREV_RELEASE_SPEC}"
}

# _prev_release_spec_in_shard <n>/<total>
#   True when the partition assigns that spec to shard <n>. Asked of
#   _shard_unit_files -- the very function the in-container run partitions
#   with -- rather than assumed, because its pool is
#   test/bats/{unit,integration}/**: a "unit" shard genuinely carries
#   integration specs, so a blanket "shards never need the fixture" would
#   make the compatibility spec vacuous on whichever shard owns it.
_prev_release_spec_in_shard() {
  local _spec="${1:?BUG: _prev_release_spec_in_shard expects <n>/<total>}"
  local _files _rc=0
  _files="$(_shard_unit_files "${_spec}")" || _rc=$?
  # A partition we could not compute (a malformed spec -- the in-container
  # run rejects it by the same rule, a few seconds later) is answered YES:
  # of the two guesses, only "not needed" can end in a vacuous spec.
  if (( _rc != 0 )); then
    return 0
  fi
  _prev_release_spec_in_selection <<< "${_files}"
}

# _dispatch_needs_prev_release <coverage>
#   Whether the compose dispatch about to run will execute that spec.
#   <coverage> is _run_via_compose's own COVERAGE flag (0 / 1).
#
#   Resolving the fixture costs release tags, and on a shallow or tagless
#   checkout a network fetch of them. That cost used to be paid by EVERY
#   compose dispatch, so an offline or tagless clone could not run
#   `--bats-unit-shard`, `--bats-fragile` or a coverage shard at all, and a
#   transient tag fetch in CI could turn e.g. `coverage (5/8)` red with a
#   message naming nothing the job runs. It belongs to the runs that read
#   the fixture.
#
#   Narrowing WHO pays, never how loudly it fails: wherever the answer here
#   is yes, an unresolvable fixture still aborts the run before a container
#   starts. A compatibility spec that silently shrinks to zero cases is the
#   failure mode the fixture exists to prevent.
#
#   It answers by REPLAYING the in-container dispatch below (main's `ci`
#   case) over the same variables _run_via_compose is about to forward, and
#   the branch ORDER is part of that: COVERAGE_SHARD out-ranks a stale
#   BATS_FILE under kcov exactly as the container's does, so an ambient
#   variable cannot make this predict a different run from the one that
#   happens. Membership questions go to the very selectors the container
#   runs (_shard_unit_files / _fragile_unit_files), so nothing here drifts
#   the day the partition pool or the fragile set changes -- which a
#   hand-maintained list of modes would.
_dispatch_needs_prev_release() {
  local _coverage="${1:-0}"
  # The lint dispatches run no bats at all.
  if [[ "${LINT_ONLY:-0}" == "1" ]]; then
    return 1
  fi
  if [[ "${_coverage}" == "1" ]]; then
    # kcov: ONE named spec, else a shard slice, else the whole suite.
    if [[ -n "${COVERAGE_PATH:-}" ]]; then
      _prev_release_spec_under "${COVERAGE_PATH}"
      return
    fi
    if [[ -n "${COVERAGE_SHARD:-}" ]]; then
      _prev_release_spec_in_shard "${COVERAGE_SHARD}"
      return
    fi
    return 0
  fi
  # Plain: a named path, else a filter over unit + integration, else a
  # shard slice, else the fragile set, else unit + integration.
  if [[ -n "${BATS_FILE:-}" ]]; then
    _prev_release_spec_under "${BATS_FILE}"
    return
  fi
  if [[ -n "${BATS_FILTER:-}" ]]; then
    # A bare filter runs bats over both directories. Its regex could still
    # select none of that spec's tests, but the regex is bats' to evaluate
    # and the conservative answer is the one that cannot hide a missing
    # fixture.
    return 0
  fi
  if [[ -n "${BATS_UNIT_SHARD:-}" ]]; then
    _prev_release_spec_in_shard "${BATS_UNIT_SHARD}"
    return
  fi
  # The kcov-fragile set is grepped out of the spec tree at runtime, so ask
  # for it too rather than assuming it stays unit-only. Captured, not piped
  # into the matcher: `grep -q` leaves as soon as it matches, which would
  # strand the writer with SIGPIPE.
  if [[ "${BATS_FRAGILE:-0}" == "1" ]]; then
    local _fragile _frc=0
    _fragile="$(_fragile_unit_files)" || _frc=$?
    if (( _frc != 0 )); then
      return 0
    fi
    _prev_release_spec_in_selection <<< "${_fragile}"
    return
  fi
  # --bats-integration, --bats-only and bare `just test` all run the whole
  # integration directory.
  return 0
}

# _prepare_prev_release <coverage>
#   Materialise the last few RELEASED trees into .prev-release/ so
#   test/bats/integration/prev_release_upgrade_spec.bats can run their
#   upgrade.sh against this tree.
#
#   Host-side, and it has to be: the suite runs in a container that
#   bind-mounts the checkout, and a worktree checkout's `.git` is a file
#   pointing at a path outside that mount, so no in-container git command
#   can read the tags. The host can, always.
#
#   Runs only for the dispatches that execute that spec (see
#   _dispatch_needs_prev_release), and is fatal for all of them.
_prepare_prev_release() {
  if ! _dispatch_needs_prev_release "${1:-0}"; then
    return 0
  fi
  "${REPO_ROOT}/script/test/prepare-prev-release.sh"
}

# ── Coverage provenance ──────────────────────────────────────────────────────

# Where the coverage provenance stamp lives, relative to the repo root.
# One name for the writer, the eraser and script/release/coverage_badge.sh's
# reader: three places that have to agree on a path is two too many.
readonly _COVERAGE_HEAD_STAMP_REL="coverage/.head-sha"

# The run manifest kcov's bats leaves next to the reports: `<seconds>
# <basename>`, one line per spec FILE that actually ran (_junit_to_timings
# in drivers/bats.sh, from bats' junit report). It exists to weigh the next
# partition; it is reused here because it is the only local record of WHAT
# was measured, written by the run rather than by its caller.
readonly _COVERAGE_RUN_MANIFEST_REL="coverage/timings.tsv"

# _coverage_spec_inventory [root] -- print, one per line, the sorted unique
# BASENAMES of every spec a full coverage run covers.
#
# The pools and the file shape are NOT a second roster: both come from
# _COVERAGE_FULL_SUITE_POOLS / _COVERAGE_SPEC_GLOB in drivers/bats.sh, the
# same values _run_coverage builds its full-suite targets from and
# _shard_unit_files partitions. The recursion is `bats --recursive`'s, so
# the per-lib subfolders of ADR-00000015 count. Basenames, not paths, because
# that is the key space the manifest is written in -- _junit_to_timings
# reduces bats' junit `name=` to a basename so _spec_weight can read the
# merged weights back.
#
# Two specs in different pools may share a basename (there are such pairs
# here), so the inventory is smaller than the file count. That makes the
# comparison below very slightly lenient: a measurement missing ONLY the
# twin of a name it already carries would still compare equal. No
# partition produces that set -- a shard is a fraction of the tree, not
# the tree minus one file -- and the alternative, keying on paths, would
# mean a second manifest format nothing else reads.
#
# Empty is a FAILURE (return 1), not an empty set: an inventory that
# enumerated nothing would make every manifest look complete.
_coverage_spec_inventory() {
  local _root="${1:-${REPO_ROOT}}"
  local _pool _f
  local -a _names=() _dirs=()
  for _pool in "${_COVERAGE_FULL_SUITE_POOLS[@]}"; do
    [[ -d "${_root}/${_pool}" ]] && _dirs+=("${_root}/${_pool}")
  done
  (( ${#_dirs[@]} > 0 )) || return 1
  while IFS= read -r _f; do
    _names+=("${_f##*/}")
  done < <(find "${_dirs[@]}" -type f -name "${_COVERAGE_SPEC_GLOB}")
  (( ${#_names[@]} > 0 )) || return 1
  printf '%s\n' "${_names[@]}" | LC_ALL=C sort -u
}

# _measured_coverage_scope [root] -- print the scope the reports EARNED:
# `full` when the run manifest names every spec in the inventory,
# `partial <measured>/<total> specs` otherwise. Returns 1, printing
# nothing, when there is no evidence to read.
#
# This is the answer to a defect that kept coming back through a different
# door. The scope used to be read off the invocation -- the shard flag the
# caller passed -- and every input that narrows the RUN without passing
# through that flag therefore certified a partial measurement as `full`:
# an inherited COVERAGE_SHARD, an inherited COVERAGE_PATH (which the
# in-container dispatch reads FIRST), and whichever selector is added
# next. That set is not enumerable, so a certificate derived from it
# cannot be made trustworthy by closing one more door.
#
# What was MEASURED is enumerable, and the run writes it down. Comparing
# the manifest against the inventory cannot be fooled by an input nobody
# thought of: a run narrowed by anything at all leaves fewer specs in the
# manifest, and fewer specs is not `full`.
_measured_coverage_scope() {
  local _root="${1:-${REPO_ROOT}}"
  local _manifest="${_root}/${_COVERAGE_RUN_MANIFEST_REL}"
  [[ -s "${_manifest}" ]] || return 1
  local _inventory
  _inventory="$(_coverage_spec_inventory "${_root}")" || return 1
  [[ -n "${_inventory}" ]] || return 1
  local _measured
  _measured="$(awk '($2 != "") { print $2 }' "${_manifest}" \
    | LC_ALL=C sort -u)"
  [[ -n "${_measured}" ]] || return 1
  if [[ "${_measured}" == "${_inventory}" ]]; then
    printf 'full\n'
    return 0
  fi
  local _total _matched
  _total="$(printf '%s\n' "${_inventory}" | grep -c .)"
  _matched="$(LC_ALL=C comm -12 \
    <(printf '%s\n' "${_inventory}") <(printf '%s\n' "${_measured}") \
    | grep -c . || true)"
  printf 'partial %s/%s specs\n' "${_matched}" "${_total}"
}

# _stamp_coverage_head [root] -- record, next to the reports, the sha they
# were produced from AND how much of the suite produced them.
#
# The cobertura reports carry no identity: nothing in coverage/ says which
# tree kcov walked. The release badge generator
# (script/release/coverage_badge.sh) has to know, because publishing one
# tree's rate under another tree's version is exactly the invented figure
# its refusal exists to prevent -- and comparing the report's mtime against
# HEAD's commit time cannot tell, since that only catches reports that are
# too OLD, never a checkout that moved elsewhere after the run.
#
# The sha alone is not enough, and that gap was a real one. A sha answers
# WHICH tree; it says nothing about WHETHER the whole suite ran.
# `just test coverage <n>/<total>` writes its slice into the SAME
# ${REPO_ROOT}/coverage tree the full run uses, so a stamp that recorded
# only the sha certified a partition as HEAD's measurement: every check the
# generator makes passed, and the badge published a figure off by a factor
# of N. So the scope is stamped alongside the sha --
#   <sha>
#   scope=full                  (the manifest names every spec)
#   scope=partial <m>/<n> specs (it names fewer)
# -- and the generator publishes only `full`. The write is a truncating
# one, so a later partial run at the same commit REPLACES an earlier
# full-suite stamp rather than leaving its certificate standing.
#
# THE SCOPE IS DERIVED, NOT PASSED IN, and that is the whole of why this
# function takes no second argument. A shard argument would make the
# certificate a statement about the INVOCATION, and the invocation is not
# what decides which specs kcov walks: _run_via_compose forwards
# COVERAGE_SHARD and COVERAGE_PATH from the AMBIENT environment, the
# in-container dispatch reads COVERAGE_PATH first, and the next selector
# added to that list would be read before anybody remembered to clear it.
# Four review rounds each closed one of those doors. _measured_coverage_scope
# asks the reports instead: a run narrowed by ANY input leaves fewer specs
# in coverage/timings.tsv, and fewer specs is not `full`.
#
# Written on the HOST, after the container run returns and after
# _fix_permissions has handed coverage/ back: the coverage services run as
# root over the mounted checkout, where git refuses the tree as dubiously
# owned.
#
# Best-effort by design. A repo with no git (an unpacked tarball) still
# gets its reports; it just cannot publish a release badge from them, which
# is the safe direction -- the generator refuses on a missing stamp. A run
# that left NO manifest is the same case: no evidence of what was measured
# means no certificate, announced on stderr so the operator is not left
# wondering why the badge refuses.
_stamp_coverage_head() {
  local _root="${1:-${REPO_ROOT}}" _sha _scope
  _sha="$(git -C "${_root}" rev-parse HEAD 2>/dev/null)" || return 0
  [[ -n "${_sha}" ]] || return 0
  if ! _scope="$(_measured_coverage_scope "${_root}")" || [[ -z "${_scope}" ]]; then
    printf '%s\n' \
      "[test.sh] no coverage run manifest under ${_root}/${_COVERAGE_RUN_MANIFEST_REL}; writing no provenance stamp (a release badge will refuse rather than publish an unmeasured figure)." >&2
    return 0
  fi
  mkdir -p "${_root}/coverage" 2>/dev/null || return 0
  printf '%s\nscope=%s\n' "${_sha}" "${_scope}" \
    > "${_root}/${_COVERAGE_HEAD_STAMP_REL}" 2>/dev/null || return 0
}

# _invalidate_coverage_head [root] -- drop the provenance stamp AND the run
# manifest it is derived from, BEFORE a coverage run starts.
#
# The certificate must never outlive the reports it certifies, and
# rewriting it after the run is not enough to guarantee that. The stamp is
# written only when the run SUCCEEDS, while the reports are written as the
# run goes: kcov has its cobertura.xml on disk before the driver returns
# the failing spec's exit code (_run_coverage preserves it on purpose), and
# Ctrl-C lands in the same place. A run that dies there overwrites the
# reports and never reaches the writer, so an earlier `scope=full` stamp at
# the same commit goes on certifying numbers it never measured -- matching
# sha, clean worktree, whole-suite scope -- and `just release
# coverage-badge` publishes a partition's rate as the release figure.
#
# Erasing up front makes the failure mode NO evidence instead of STALE
# evidence. The generator refuses on a missing stamp, which is the safe
# direction; it trusts a present one, which is why a present one may only
# ever describe the run that just finished.
#
# NOT best-effort, unlike the writer it pairs with, and the asymmetry is
# the point. A stamp the writer fails to write is a MISSING one, and the
# generator refuses on a missing stamp; a stamp the eraser fails to remove
# is a SURVIVING one, and the generator trusts a present one. So the
# writer may shrug and this may not: swallowing the removal's status keeps
# the run going in exactly the state the erasure exists to prevent.
#
# A missing stamp is still not a failure -- `rm -f` succeeds on a path
# that is not there, which is the whole of what best-effort was buying
# here. What is left to fail on is the stamp that is still present
# afterwards: coverage/ owned by another uid (CI shard artifacts unpacked
# as root, the workflow script/release/coverage_badge.sh's header
# describes), a read-only checkout, an I/O error. The run stops before it
# writes a single report under a certificate it could not invalidate.
#
# The RUN MANIFEST goes with it, and inherits the same rule, because the
# scope on the certificate is now derived from the manifest: it is half
# the certificate, so leaving it behind leaves half a certificate
# standing. That matters for exactly the runs that write no manifest of
# their own -- a run that dies before bats' junit report is converted, or
# one narrowed to a single spec by an inherited COVERAGE_PATH, which
# writes nothing into coverage/ at all. Erased, those runs end with no
# evidence and get no stamp; left in place, the PREVIOUS run's record of
# what was measured would certify them.
_invalidate_coverage_head() {
  local _root="${1:-${REPO_ROOT}}"
  local _path
  for _path in "${_root}/${_COVERAGE_HEAD_STAMP_REL}" \
               "${_root}/${_COVERAGE_RUN_MANIFEST_REL}"; do
    rm -f "${_path}" 2>/dev/null || true
    # The status of `rm` is not the question; the file's presence is. They
    # differ on the case that matters (a partial removal, a racing
    # writer), and presence is what the next stamp will be derived from.
    if [[ -e "${_path}" ]]; then
      _die ci_coverage_evidence_not_erased \
        "cannot remove the stale coverage evidence ${_path}; a run that starts with it standing would write fresh partial reports under an earlier whole-suite certificate. Remove it (or fix the ownership of ${_root}/coverage) and re-run."
    fi
  done
  return 0
}

# ── Fix coverage permissions ─────────────────────────────────────────────────

_fix_permissions() {
  local uid="${HOST_UID:-}"
  local gid="${HOST_GID:-}"
  # The ids are numeric wherever they come from a caller of ours (`id -u`),
  # so anything else arrived from the environment. chown would read it as a
  # NAME and either fail with a message that names nothing useful or, worse,
  # find a real account of that name and hand the report to it. Name the
  # variable that is wrong instead.
  local _var _val
  for _var in HOST_UID HOST_GID; do
    _val="${!_var:-}"
    [[ -z "${_val}" || "${_val}" =~ ^[0-9]+$ ]] && continue
    _die ci_host_id_not_numeric \
      "${_var}='${_val}' is not a numeric id; it decides the ownership of everything the suite writes into the checkout"
  done
  if [[ -n "${uid}" && -n "${gid}" && -d "${REPO_ROOT}/coverage" ]]; then
    chown -R "${uid}:${gid}" "${REPO_ROOT}/coverage"
  fi
}

# ── Local test-tools tag ─────────────────────────────────────────────────────
#
# The local tooling tag used to be the fixed literal `test-tools:local`,
# written identically by every checkout on the host. Nothing errors when a
# sibling run rebuilds it: it silently displaces the image a live run is
# already using, and a coverage pass whose image lost kcov mid-run still
# reports green. The tag is now keyed to the build inputs, so identical
# inputs resolve to ONE tag (a build-cache hit, not a rebuild) and any
# difference resolves to a tag that cannot clobber the other.

# The tooling Dockerfile is the only build input of the test-tools image.
# The compose service passes `context: .`, but the Dockerfile never reads
# it: every COPY in it is `COPY --from=<stage>` (bats-src /
# bats-extensions / lint-tools / kcov-builder) and it has no ADD, so no
# file of the checkout can reach a layer. Hashing the context would make
# the tag churn on every unrelated source edit -- defeating the build
# cache -- while changing nothing about the image. The tool versions
# (BATS_VERSION / ALPINE_VERSION / KCOV_VERSION, the pinned shellcheck and
# hadolint release URLs) all live INSIDE this file, so an upgrade does move
# the tag. What the digest cannot see is upstream drift behind a floating
# reference (`apk add` package versions, the alpine tag) -- unchanged from
# the old literal, and not the thing that collides between two concurrent
# checkouts.
readonly _TEST_TOOLS_DOCKERFILE_REL="dockerfile/Dockerfile.test-tools"

# _compute_test_tools_hash <dockerfile> <outvar>
#
# sha256 of the WHOLE tooling Dockerfile. Deliberately not the stage-list
# projection dist/script/docker/lib/stage.sh's _compute_dockerfile_hash
# takes: that hash answers "did the set of compose services change?" and so
# must ignore RUN lines, while this one answers "is this the same image?"
# -- and a RUN line is exactly what dropped kcov out of the image.
#
# Empty output if the Dockerfile is missing (caller decides what to do).
_compute_test_tools_hash() {
  local _dockerfile="${1:?_compute_test_tools_hash requires <dockerfile>}"
  local -n _ctth_out="${2:?_compute_test_tools_hash requires <outvar>}"
  # Delegated to lib/project_reclaim.sh, which owns the derivation for the
  # same reason it owns the compose project name: the retention policy that
  # decides which of these tags to retire has to compute exactly what this
  # computes, and two implementations of one rule is how they come to
  # disagree. Absent Dockerfile still yields the empty string here (the
  # caller decides what to do about it).
  _ctth_out="$(_reclaim_tool_dockerfile_hash "${_dockerfile}")"
  return 0
}

# _resolve_test_tools_image [dockerfile]
#
# Prints the tag the local test-tools build writes and its consumers read.
# TEST_TOOLS_IMAGE wins verbatim: CI pins published, version-scoped GHCR
# tags through it (build-worker / publish-worker / release-test-tools) and
# self-test.yaml pins `test-tools:local`; the derivation is a LOCAL default
# only and must never rewrite a caller-pinned value.
#
# Fails loud when the Dockerfile is missing rather than falling back to a
# bare literal that would resolve to whatever another checkout last built
# -- the same no-silent-fallback rule the shipped wrapper
# (dist/script/docker/wrapper/build.sh) applies to its version-scoped local
# tag.
# shellcheck disable=SC2120  # production callers pass no args; tests pass a dockerfile
_resolve_test_tools_image() {
  if [[ -n "${TEST_TOOLS_IMAGE:-}" ]]; then
    printf '%s\n' "${TEST_TOOLS_IMAGE}"
    return 0
  fi
  local _dockerfile="${1:-${REPO_ROOT}/${_TEST_TOOLS_DOCKERFILE_REL}}"
  local _hash=""
  _compute_test_tools_hash "${_dockerfile}" _hash
  if [[ -z "${_hash}" ]]; then
    _die ci_test_tools_dockerfile_missing \
      "cannot derive the local test-tools tag: '${_dockerfile}' is missing (no bare test-tools:local fallback)."
  fi
  # 12 hex digits: the tag has to stay readable in `docker images`, and the
  # collision surface is the handful of checkouts on one host.
  printf 'test-tools:%s\n' "${_hash:0:12}"
  return 0
}

# _ensure_test_tools_image <image> <project>
#
# Makes the DERIVED tooling tag exist before a compose run reads it.
#
# The derived tag is local-only -- no registry can serve `test-tools:<hash
# of this checkout's tooling Dockerfile>` -- so an absent one means "not
# built yet", never "pull it". Building it here through the SAME compose
# service `just docker build --target test-tools` builds is what keeps the
# image this run consumes to one that was produced from this checkout's
# Dockerfile, instead of a published tag that may lag it (a stale rolling
# tag missing kcov is how a coverage pass once reported green having never
# run kcov).
#
# A caller-pinned TEST_TOOLS_IMAGE is left alone: CI pins a published GHCR
# tag or an in-run tag it built itself, and provisioning it is the
# caller's job (building over it here would replace what it asked for).
_ensure_test_tools_image() {
  local _image="${1:?_ensure_test_tools_image requires <image>}"
  local _project="${2:?_ensure_test_tools_image requires <project>}"
  if [[ -n "${TEST_TOOLS_IMAGE:-}" ]]; then
    return 0
  fi
  if docker image inspect "${_image}" >/dev/null 2>&1; then
    return 0
  fi
  echo "--- Building the tooling image ${_image} (content hash of ${_TEST_TOOLS_DOCKERFILE_REL}) ---"
  TEST_TOOLS_IMAGE="${_image}" docker compose -p "${_project}" \
    -f "${REPO_ROOT}/compose.yaml" build test-tools
}

# ── Compose project name ─────────────────────────────────────────────────────

# _compute_compose_project_name <repo_root> <outvar>
#
# Compose accepts only `[a-z0-9][a-z0-9_-]*` as a project name, and a
# checkout path may hold anything -- spaces, uppercase, punctuation,
# non-ASCII, a leading dot. Sanitising the path TEXT would have to
# enumerate every such case and would still have to answer what a path that
# sanitises to nothing becomes; hashing it cannot fail to: the name is the
# constant prefix plus 12 hex digits, which satisfies the grammar by
# construction for ANY input path.
#
# Keyed to the PATH, not the commit: two worktrees are routinely branched
# from the same commit, so a commit-keyed name would collide in exactly the
# concurrent case this exists to separate. The path is also stable across
# commits, so a checkout keeps one project (and one network) instead of
# churning a fresh one per commit.
#
# Delegated to lib/project_reclaim.sh's _reclaim_project_for_path, which is
# THE producer, so the rule has one implementation and cannot drift into
# two. Note what the name is NOT used for: the scoped reclaim in that same
# file decides whether an artifact belongs to a checkout that still exists
# by reading the checkout's PATH off the artifact's `base.checkout.path`
# label, never by recomputing this hash for anything. It used to recompute
# it for every worktree `git worktree list` reported, which made its answer
# depend on which repository the sweep was standing in -- and from a
# downstream consumer's checkout that answer was "every live base project
# is an orphan".
_compute_compose_project_name() {
  local _root="${1:?_compute_compose_project_name requires <repo_root>}"
  local -n _ccpn_out="${2:?_compute_compose_project_name requires <outvar>}"
  # `_ccpn_name`, not `_name`: the caller passes a variable of its own to be
  # filled, and a local here that happens to share that variable's NAME
  # captures the nameref -- the assignment below then lands on the local and
  # the caller sees an empty project name. The prefix is what keeps the
  # collision out of reach of any caller's choice of variable.
  local _ccpn_name
  # A short/empty digest (sha256sum or cut missing) would degrade to the
  # bare prefix -- a name EVERY checkout resolves, i.e. the collision this
  # exists to prevent, reintroduced silently. The producer refuses it; this
  # turns the refusal into a loud death.
  if ! _ccpn_name="$(_reclaim_project_for_path "${_root}")"; then
    _die ci_project_name_digest_failed \
      "cannot derive a compose project name for '${_root}': sha256sum produced no usable digest."
  fi
  _ccpn_out="${_ccpn_name}"
  return 0
}

# _resolve_compose_project_name
#
# Prints the project name `_run_via_compose` passes to `docker compose -p`.
# COMPOSE_PROJECT_NAME wins verbatim so CI can key the project to its run
# id; the derivation is a local default only.
_resolve_compose_project_name() {
  if [[ -n "${COMPOSE_PROJECT_NAME:-}" ]]; then
    printf '%s\n' "${COMPOSE_PROJECT_NAME}"
    return 0
  fi
  local _name=""
  _compute_compose_project_name "${REPO_ROOT}" _name
  printf '%s\n' "${_name}"
  return 0
}

# ── Live-tree residue guard ──────────────────────────────────────────────────
#
# The authoritative answer to "did the suite write into the checkout it does
# not own". A spec that writes there makes every OTHER spec's read of the
# live tree racy: the suite runs 32-way parallel, often beside a sibling
# checkout's gate, so a write in the window flips a verdict on correct code.
# Two specs lost that race and cost two or three full gate runs per landed
# branch.
#
# Why this shape and not a scan of the specs. The scan that came first
# enumerated the commands a write could be spelled with, and every review of
# it found another spelling it claimed and could not see -- a third operand
# of `mv`, `dd`'s `of=`, `rsync` named in no pattern at all -- plus
# `install` flagged for READING the tree. A roster of spellings is never
# finished. This asks the filesystem instead: whatever wrote, however it was
# spelled, through an alias or a subshell or a tool this repo has never
# heard of, the bytes moved and the snapshot moved with them. It also cannot
# fire on the suite's own setup, which is what made the scan's cp / ln rule
# delicate -- reading the live tree leaves nothing behind.
#
# THE COST, and the reason for two snapshots rather than one. A bare "is the
# tree clean afterwards" check needs a clean tree to start from and would
# red every developer with work in flight -- and a gate that cries wolf on a
# dirty working tree is switched off within the week. Comparing the
# snapshots taken either side of the run makes an in-flight edit appear in
# BOTH and cancel, so the guard speaks only about what changed DURING the
# run. What it cannot cancel is an edit made WHILE the suite runs; that one
# has the TEST_RESIDUE_GUARD=0 escape hatch, and the failure message names
# it at the moment a developer needs it.
#
# WHAT IT DOES NOT COVER, listed because a guard whose limits are implied
# gets believed past them. Every one of these is measured by a case in
# test/bats/unit/residue_guard_spec.bats rather than assumed:
#
#   - a spec that writes into the checkout and removes its own traces
#     before the phase ends. The race window is real and invisible here.
#     Closing it means snapshotting per SPEC rather than per run, which
#     costs a `git status` per spec instead of one per phase, and it is a
#     change to the in-container bats driver rather than to this host-side
#     wrapper.
#   - anything git ignores, through any of the files git reads to decide
#     that -- see `_residue_snapshot`.
#   - anything under `.git/`, which `git status` never reports: a planted
#     hook, config key or alternates entry is the most damaging write there
#     is and this cannot see it. Excluded rather than closed, because
#     snapshotting that directory is noise by construction (git rewrites it
#     on almost any command, this guard's own `git status` included) and
#     narrowing it to "the parts that matter" is an open-set roster.
#   - a permission change git does not track. Git records one bit of a
#     file's mode, the exec bit, so 644 -> 755 IS named and 644 -> 600 is
#     invisible: the status line stays clean and the content hash does not
#     move.
#
# And one thing it does not attempt: this names PATHS, not the spec that
# wrote them -- with 32 jobs in flight there is no attribution to be had at
# the phase boundary, and a `grep -rn` over test/bats/ turns a path into a
# spec in one step.

# _residue_guard_available <repo>
#   Whether the guard can speak about <repo> at all. A released tarball is
#   not a checkout, and a suite that refuses to run where git is not is a
#   worse outcome than an unguarded run, so absence costs nothing.
_residue_guard_available() {
  local _repo="${1:?BUG: _residue_guard_available expects <repo>}"
  [[ "${TEST_RESIDUE_GUARD:-1}" != "0" ]] || return 1
  command -v git >/dev/null 2>&1 || return 1
  git -C "${_repo}" rev-parse --git-dir >/dev/null 2>&1
}

# _residue_snapshot <repo>
#   One sorted TAB-separated record per path git reports as changed:
#   `<xy>\t<hash>\t<path>`. Ignored paths are absent, which is how the
#   trees the suite legitimately writes -- coverage/, log/, .prev-release/
#   -- stay out of it: the list is git's, not a second allowlist here that
#   would have to be remembered separately. Git's, and not just
#   `.gitignore`'s: `git status` also obeys `.git/info/exclude` and
#   `core.excludesFile`, so a path ignored by either of those is equally
#   invisible here. That is the cost of inheriting the list rather than
#   keeping one -- an ignore rule this repo never wrote, in a file it does
#   not ship, silences the guard for the paths it covers -- and it is
#   still the better trade than an allowlist that has to be remembered
#   every time the suite grows a generated tree.
#
#   The CONTENT HASH is what makes a record more than git's status code. A
#   spec overwriting a file the developer had already modified leaves the
#   status line ` M <path>` identical in both snapshots; only the hash
#   moves. The path is the LAST field and is read NUL-separated, so a name
#   containing a space -- which porcelain output would otherwise quote --
#   survives whole.
#
#   Failing to read the tree is a FAILURE, never an empty snapshot: two
#   empty snapshots agree, and agreeing is exactly what this guard reports
#   as "nothing happened".
_residue_snapshot() {
  local _repo="${1:?BUG: _residue_snapshot expects <repo>}"
  local _raw _rc=0
  _raw="$(mktemp)"
  if ! git -C "${_repo}" status --porcelain --untracked-files=all -z > "${_raw}"; then
    rm -f "${_raw}"
    return 1
  fi
  local _entry _code _path _hash
  while IFS= read -r -d '' _entry; do
    _code="${_entry:0:2}"
    _path="${_entry:3}"
    # A rename / copy record is followed by its ORIGIN path in a field of
    # its own. Consume it here, or every later record reads one field out
    # of step -- and a scan that silently loses its place names the wrong
    # paths, which is worse than naming none.
    case "${_code}" in
      R?|C?|?R|?C) IFS= read -r -d '' _ || true ;;
    esac
    # Directories, symlinks and deleted paths have no blob to hash; their
    # status code already carries the whole change.
    if [[ -f "${_repo}/${_path}" && ! -L "${_repo}/${_path}" ]]; then
      _hash="$(git -C "${_repo}" hash-object -- "${_path}" 2>/dev/null)" \
        || _hash="unreadable"
    else
      _hash="-"
    fi
    printf '%s\t%s\t%s\n' "${_code}" "${_hash}" "${_path}"
  done < "${_raw}" | LC_ALL=C sort || _rc=$?
  rm -f "${_raw}"
  return "${_rc}"
}

# _residue_paths <before> <after>
#   The paths whose record differs between the two snapshots, one per line.
#   Both directions: a record that APPEARED is a write, and one that
#   DISAPPEARED is the suite putting back something the developer had
#   changed. `comm -3` prefixes its second column with a tab, so that is
#   stripped before the path (field 3 to end of line, tabs and all) is cut.
_residue_paths() {
  local _before="${1:?BUG: _residue_paths expects <before>}"
  local _after="${2:?BUG: _residue_paths expects <after>}"
  LC_ALL=C comm -3 "${_before}" "${_after}" \
    | sed 's/^\t//' \
    | cut -f3- \
    | LC_ALL=C sort -u
}

# ── the guard's memory ───────────────────────────────────────────────────────
#
# Why there is one at all. The two-snapshot form is what makes the guard
# usable -- an edit already in flight appears in both snapshots and cancels,
# so a developer mid-change can run the gate -- and it is exactly that which
# made the alarm ONE-SHOT: residue left by run N is on disk before run N+1
# starts, so run N+1 reads it as "in flight" and goes green with the defect
# unchanged. Measured: run 1 named the path and exited 1, run 2 with nothing
# fixed exited 0.
#
# Three shapes were weighed. Taking the baseline from the INDEX instead of
# the working tree removes the laundering, and with it the whole reason the
# guard is usable: every in-flight edit becomes residue and the guard is
# switched off within the week. Narrowing what BEFORE may cancel -- say, only
# tracked modifications, never a new untracked file -- is a guess about which
# changes are developer-shaped, and it is wrong for anyone adding a file.
# What is left is to REMEMBER, which is precise: the un-cancellable set is
# exactly the paths this guard has already named out loud.
#
# What it costs the dirty working tree, stated. An edit made BEFORE a run
# cancels, is never named, and is therefore never remembered -- unchanged.
# The one edit that becomes sticky is one made WHILE the suite ran, which is
# the single false positive this guard already documents; it now costs one
# acknowledged invocation instead of evaporating on the next run. That is
# the trade: an alarm that persists until somebody answers it, against a
# second knob nobody would remember. There is no second knob --
# TEST_RESIDUE_GUARD=0, which the failure message already names, drops the
# record on its way past.
#
# WHAT THE ACKNOWLEDGEMENT COSTS, and why it is permanent. Dropping the
# record ends the alarm for good for a spec that writes the SAME BYTES on
# every run: the path is then identical in both snapshots for ever, so
# nothing at the phase boundary ever mentions it again. One flag, once, and
# a genuine defect is silent -- the "one more run and it goes green" habit
# with an extra keystroke.
#
# It is permanent anyway, because the two candidate fixes both fail on the
# same fact. EXPIRING the acknowledgement re-raises whatever it silenced on
# a timer, and what it silenced is by construction the developer's own edit
# -- an alarm that returns on a schedule teaches re-running exactly as well
# as one that never fires. SCOPING it to the paths it acknowledged changes
# nothing: those are the same paths, and the signal is missing rather than
# misrouted. An acknowledged path rewritten with identical bytes is, at the
# phase boundary, indistinguishable from an unfinished edit sitting in the
# tree -- same status line, same hash, and no snapshot of the tree either
# side of the run can tell them apart.
#
# Nor does the residual gap above close it. A per-SPEC snapshot catches a
# write-then-restore, but an identical rewrite moves no bytes at any
# granularity; separating those two would mean watching the WRITES (mtime
# across the whole tree, or an audit of the phase), which reports every file
# git itself touched and is noise by construction. So the cost is stated
# here, the failure message says what the flag gives up at the moment it
# offers it, and a case pins both the silence and its limit: bytes that
# CHANGE after an acknowledgement are named again.

# _residue_state_file <repo>
#   Where the pending record lives: inside the GIT DIR, never in the working
#   tree. `git status` does not report it, nothing ships it, and
#   `--absolute-git-dir` resolves a worktree to its own gitdir, so two
#   worktrees of one repo do not inherit each other's residue. A record kept
#   in the tree would be residue on the next run and the guard would report
#   itself for ever.
_residue_state_file() {
  local _repo="${1:?BUG: _residue_state_file expects <repo>}"
  local _gitdir
  _gitdir="$(git -C "${_repo}" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  printf '%s\n' "${_gitdir}/test-residue-pending"
}

# _residue_forget <repo>
#   Drop the record. Called when the run is clean and the remembered paths
#   are gone, and on any invocation that switched the guard off -- which is
#   how a developer says "that one was mine".
_residue_forget() {
  local _repo="${1:?BUG: _residue_forget expects <repo>}"
  local _record
  _record="$(_residue_state_file "${_repo}")" || return 0
  rm -f "${_record}"
}

# _residue_remember <repo> <paths>
#   Persist the paths just named, one per line, replacing whatever was
#   there: the report is always the whole pending set, so the record is too.
_residue_remember() {
  local _repo="${1:?BUG: _residue_remember expects <repo>}"
  local _paths="${2-}"
  local _record
  _record="$(_residue_state_file "${_repo}")" || return 0
  printf '%s\n' "${_paths}" > "${_record}"
}

# _residue_carried <repo> <after-snapshot>
#   The remembered paths that are STILL changed in the checkout. A path the
#   developer removed, reverted or committed has left the AFTER snapshot and
#   is dropped here -- cleaning up is the acknowledgement, and nothing has to
#   be typed for it.
_residue_carried() {
  local _repo="${1:?BUG: _residue_carried expects <repo>}"
  local _after="${2:?BUG: _residue_carried expects <after-snapshot>}"
  local _record
  _record="$(_residue_state_file "${_repo}")" || return 0
  [[ -s "${_record}" ]] || return 0
  local _still
  _still="$(cut -f3- < "${_after}" | LC_ALL=C sort -u)"
  LC_ALL=C comm -12 \
    <(LC_ALL=C sort -u "${_record}") \
    <(printf '%s\n' "${_still}")
}

# _residue_before_snapshot <repo> <out>
#   The BEFORE half, with the same treatment the AFTER half already had: a
#   snapshot that could not be taken is a FAILURE, never an empty baseline.
#   Left unchecked it aborts the whole dispatch under errexit with no event
#   line to read, and without errexit it hands the comparison an empty
#   baseline -- which names every edit in the developer's tree as residue,
#   the exact cry-wolf outcome the two-snapshot design exists to avoid.
_residue_before_snapshot() {
  local _repo="${1:?BUG: _residue_before_snapshot expects <repo>}"
  local _out="${2:?BUG: _residue_before_snapshot expects <out>}"
  _residue_snapshot "${_repo}" > "${_out}" && return 0
  _log_err ci ci_live_tree_residue \
    "display=Could not read the checkout BEFORE the test run, so there is no baseline to say what it looked like going in. Running unguarded would report every edit already in flight as residue, so this is reported as a failure instead."
  return 1
}

# _residue_check <before-snapshot> <repo>
#   Take the AFTER snapshot and report. Returns 1 and names every path when
#   the run changed the checkout -- and every path an earlier run named that
#   is still there, because residue nobody has answered for is still
#   residue however many runs ago it appeared.
_residue_check() {
  local _before="${1:?BUG: _residue_check expects <before-snapshot>}"
  local _repo="${2:?BUG: _residue_check expects <repo>}"
  local _after _new _carried _paths
  _after="$(mktemp)"
  if ! _residue_snapshot "${_repo}" > "${_after}"; then
    rm -f "${_after}"
    _log_err ci ci_live_tree_residue \
      "display=Could not read the checkout after the test run, so whether it was left unchanged is unknown; treating that as a failure rather than as a clean tree."
    return 1
  fi
  _new="$(_residue_paths "${_before}" "${_after}")"
  _carried="$(_residue_carried "${_repo}" "${_after}")"
  rm -f "${_after}"
  # `sed`, not `grep -v`: this file runs under pipefail, and grep answers 1
  # when it filters everything away -- which is exactly the clean run -- so a
  # grep here would abort the whole dispatch on the path that has nothing to
  # report.
  _paths="$(printf '%s\n%s\n' "${_new}" "${_carried}" \
    | sed '/^$/d' | LC_ALL=C sort -u)"
  if [[ -z "${_paths}" ]]; then
    _residue_forget "${_repo}"
    return 0
  fi
  _residue_remember "${_repo}" "${_paths}"
  # Two different facts, reported as two: what THIS run wrote, and what an
  # earlier run left that nobody has answered for. Leading with the union
  # asserted a write on every re-run of an unfixed residue, and a reader who
  # believes that sentence goes looking through a run that touched nothing.
  local _new_note="" _carried_note=""
  [[ -z "${_new}" ]] || _new_note="The test run changed the checkout it does not own: $(printf '%s' "${_new}" | tr '\n' ' '). "
  # printf with a trailing newline, so `tr` leaves a trailing SPACE whether
  # the set has one path or ten.
  if [[ -n "${_carried}" ]] && [[ -n "${_new}" ]]; then
    _carried_note="Already reported by an earlier run and still there: $(printf '%s\n' "${_carried}" | tr '\n' ' ')-- a re-run does not clear this, which is the point. "
  elif [[ -n "${_carried}" ]]; then
    _carried_note="This run changed nothing. What is named here was reported by an EARLIER run and is still in the checkout: $(printf '%s\n' "${_carried}" | tr '\n' ' ')-- a re-run does not clear this, which is the point. "
  fi
  _log_err ci ci_live_tree_residue \
    "display=${_new_note}${_carried_note}A spec may READ the live tree -- that is where its subject is -- but a write there makes every other spec's read racy under the 32-way parallel suite. Inspect with 'git diff -- <path>' (or 'git status' for an untracked one) and move the write into the spec's own scratch dir; 'grep -rn <path> test/bats/' finds the spec. This is remembered until the path is gone from the checkout, so the next run reports it again rather than mistaking it for an edit you had in flight. If the change was YOURS -- made while the suite was running, which is the one thing two snapshots cannot cancel -- re-run once with TEST_RESIDUE_GUARD=0, which drops the record -- and with it the guard's memory of that path, so a spec rewriting exactly the same bytes there stays unreported until they change."
  return 1
}

# ── The previous run's residue ───────────────────────────────────────────
#
# A compose network that cannot be recreated because a container is still
# attached to it is a WAIT, not a failure. Left to compose, that condition
# reaches the operator as the daemon's raw text plus `recipe failed`, with
# `not_ok=0` the only hint that no test was involved -- so the first thing
# they do is go looking for a code defect. It cleared on its own about a
# minute after it was first seen, which is what makes it worth handling:
# the run knows how to wait, and the operator cannot tell that waiting is
# all that was needed.
#
# So the dispatch asks first. It is one `network ls` and one `inspect` on
# the happy path, and it turns the whole class into either a wait that
# says what it waits for or a refusal that names the container and the
# verb that clears it.
#
# OWNERSHIP IS EXACT AND CARRIED BY THE ARTIFACT. The listing filters on
# BOTH labels: `com.docker.compose.project` must equal the name this run
# is about to hand compose, and `base.checkout.path` must equal this
# checkout. Neither is a prefix and neither is an enumeration of what else
# is on the host -- a network that does not carry both is somebody else's
# and is never inspected, let alone waited for. A network created before
# the path label existed carries no proof and is skipped, which costs this
# run the nicer message and nothing else.
#
# A RUNNING CONTAINER IS NOT A WEDGE. Two runs sharing a project's network
# is the ordinary concurrent case and compose reuses the network happily.
# Waiting there would be waiting for something that is not leaving, so a
# running endpoint is reported and stepped over.
#
# NOTHING HERE REMOVES ANYTHING. The wait's whole job is to make the
# condition legible; deleting a container to get past it would be acting
# on an artifact whose run may still be finishing with it. Removal is the
# operator's `just test stop`, which is what the refusal names.

# How long to wait for the previous run's container to let go. Not a tuned
# number: the one observation available says a minute, and the cost of
# waiting too long is a slow start while the cost of waiting too little is
# the confusing red this exists to remove. BASE_PROJECT_WAIT overrides it.
readonly _PROJECT_WAIT_DEFAULT='2m'
readonly _PROJECT_WAIT_POLL_SECONDS=2

# _await_docker_project_networks <project> <checkout>
#
# The ids of the networks that carry BOTH proofs. Ids only: they are hex,
# so this listing cannot be corrupted by the content of a label.
_await_docker_project_networks() {
  local _project="${1:?_await_docker_project_networks requires <project>}"
  local _checkout="${2:?_await_docker_project_networks requires <checkout>}"
  docker network ls \
    --filter "label=${_RECLAIM_PROJECT_LABEL}=${_project}" \
    --filter "label=${_RECLAIM_CHECKOUT_LABEL}=${_checkout}" \
    --format '{{.ID}}' 2>/dev/null
}

# _await_docker_network_endpoints <id>
#
# The name of every container attached to that network -- the daemon's own
# answer to the question that blocks the removal, rather than a model of
# which container states hold an endpoint. Compose's grammar for a
# container name excludes a newline, so one name per line is unambiguous.
_await_docker_network_endpoints() {
  local _id="${1:?_await_docker_network_endpoints requires <id>}"
  docker network inspect \
    --format '{{range $id, $c := .Containers}}{{$c.Name}}{{"\n"}}{{end}}' \
    "${_id}" 2>/dev/null
}

# _await_docker_container_state <name> -- `running` / `exited` /
# `removing` / ..., empty when the container has already gone.
_await_docker_container_state() {
  local _name="${1:?_await_docker_container_state requires <name>}"
  docker inspect --format '{{.State.Status}}' "${_name}" 2>/dev/null
}

# _await_project_blockers <project> <checkout> <outvar-array>
#
# Fills the outvar with `<name> (<state>)` for every attached container
# that is NOT running -- the previous run's residue, the thing that is on
# its way out. Returns non-zero when the networks could not be listed at
# all, which the caller reports and steps over: a failed listing is not
# evidence that something is attached.
_await_project_blockers() {
  local _project="${1:?_await_project_blockers requires <project>}"
  local _checkout="${2:?_await_project_blockers requires <checkout>}"
  local -n _apb_out="${3:?_await_project_blockers requires <outvar>}"
  _apb_out=()
  local _ids
  _ids="$(_await_docker_project_networks "${_project}" "${_checkout}")" || return 1
  local _id _name _state
  while IFS= read -r _id; do
    [[ -n "${_id}" ]] || continue
    while IFS= read -r _name; do
      [[ -n "${_name}" ]] || continue
      _state="$(_await_docker_container_state "${_name}")"
      # An empty state is a container that vanished between the two reads:
      # gone is exactly what we were waiting for.
      [[ -n "${_state}" ]] || continue
      [[ "${_state}" == running ]] && continue
      _apb_out+=("${_name} (${_state})")
    done < <(_await_docker_network_endpoints "${_id}")
  done <<< "${_ids}"
  return 0
}

# _await_project_quiescent <project> <checkout> [window]
#
# 0 when nothing of this checkout's project is holding its network, or
# when what was holding it let go inside the window. Non-zero -- naming
# every container still attached, its state, and `just test stop` -- when
# it did not.
_await_project_quiescent() {
  local _project="${1:?_await_project_quiescent requires <project>}"
  local _checkout="${2:?_await_project_quiescent requires <checkout>}"
  local _window="${3:-${BASE_PROJECT_WAIT:-${_PROJECT_WAIT_DEFAULT}}}"

  # A malformed window is named and replaced by the default rather than
  # refused. This function exists to turn one confusing red into a legible
  # one; declining to start the suite over a typo in a duration string
  # would just be a different confusing red.
  local _window_s
  if ! _window_s="$(_reclaim_duration_seconds "${_window}")"; then
    _log_warn ci ci_project_bad_wait \
      "display=not a duration: ${_window} (expected <N>s / <N>m / <N>h / <N>d); waiting the default ${_PROJECT_WAIT_DEFAULT} instead." \
      "window=${_window}"
    _window_s="$(_reclaim_duration_seconds "${_PROJECT_WAIT_DEFAULT}")"
  fi

  local -a _blockers=()
  if ! _await_project_blockers "${_project}" "${_checkout}" _blockers; then
    _log_warn ci ci_project_wait_unreadable \
      "display=could not list the networks of project ${_project}; starting anyway (a failed listing is not evidence that a container is still attached)." \
      "project=${_project}"
    return 0
  fi
  if (( ${#_blockers[@]} == 0 )); then
    return 0
  fi

  local _deadline=$(( $(date +%s) + _window_s ))
  _log_info ci ci_project_wait \
    "display=waiting up to ${_window} for the previous run to let go of project ${_project}: ${_blockers[*]}. Nothing is being removed -- these are containers on their way out, and the network cannot be recreated until they are." \
    "project=${_project}" "window=${_window}" "blocked_by=${_blockers[*]}"

  while (( $(date +%s) < _deadline )); do
    sleep "${_PROJECT_WAIT_POLL_SECONDS}"
    _blockers=()
    _await_project_blockers "${_project}" "${_checkout}" _blockers || return 0
    if (( ${#_blockers[@]} == 0 )); then
      _log_info ci ci_project_ready \
        "display=project ${_project} is clear; starting the suite." \
        "project=${_project}"
      return 0
    fi
  done

  _log_err ci ci_project_wedged \
    "display=project ${_project} is still held after ${_window} by: ${_blockers[*]}. The suite never started, so no test ran and none failed: this is the previous run's container, not a defect in this one. Clear it with 'just test stop', then run again." \
    "project=${_project}" "window=${_window}" "blocked_by=${_blockers[*]}"
  return 1
}

# ── Docker compose wrapper ───────────────────────────────────────────────────

# _pin_tracked_handoff
#
# The files this checkout TRACKS, computed HERE because this side can
# compute it, for the pin registry to read on the side that cannot. One
# repo-root-relative path per line; EMPTY when this side cannot answer
# either.
#
# The registry's scan population is the tracked set (script/watch/lib.sh
# says why it is derived rather than rostered), and answering that needs
# git. The container has the git BINARY but not this repository: a
# worktree's `.git` is a FILE naming a path outside the bind mount, so
# `git -C /source rev-parse --git-dir` fails there. So the answer
# travels, the way the prune-list verdict it replaces did.
#
# Empty is not "nothing is tracked": _pin_tracked treats an absent list as
# no answer and refuses, which is the correct outcome for a run that could
# not establish which files it is supposed to read. git still WINS on the
# far side wherever it is readable -- a normal clone's `.git` IS in the
# mount -- so this value can never silence a file git can see there.
_pin_tracked_handoff() {
  _pin_tracked "${REPO_ROOT}" 2>/dev/null || return 0
}

_run_via_compose() {
  # Service is the first arg so the caller picks the runner image:
  #   `ci`       — alpine test-tools (bats/shellcheck/hadolint baked in,
  #                no apt-install on each run; fast dev loop)
  #   `coverage` — the SAME alpine test-tools image as `ci`, with kcov
  #                source-built in. No apt-install, no APT_MIRROR_DEBIAN;
  #                the only difference is COVERAGE=1.
  #
  # BATS_ONLY is forwarded so the inner `--ci` dispatch can skip
  # _run_shellcheck when the dedicated GHA shellcheck job is
  # covering it in parallel. Default 0 keeps the local `just test`
  # path unchanged (full shellcheck + bats).
  #
  # BATS_UNIT_SHARD / BATS_FRAGILE / BATS_INTEGRATION route the
  # coverage-slice / bats-fragile / bats-integration GHA jobs to the right
  # subset inside the container; empty / 0 keep the local `just test` path
  # unchanged (full unit + integration).
  #
  # LINT_ONLY / LINT_TOOL route `just test lint [--shellcheck |
  # --hadolint]` to the lint phase only (skip bats) inside the container:
  # LINT_ONLY=1 runs the linters and returns; LINT_TOOL narrows to one
  # ('shellcheck' | 'hadolint'), empty = all. hadolint has no host binary,
  # so even shellcheck-via-lint runs in-container for behaviour parity.
  #
  # `-p` is explicit. Without it compose falls back to the project
  # directory's BASENAME, so two checkouts whose directories happen to share
  # a name silently share one project -- one set of containers, one network.
  # Worktrees stayed isolated only by the accident of being named apart.
  local _service="${1:-ci}"
  local _coverage="${2:-0}"
  # Fixture the released-caller spec reads. Prepared here because this is
  # the last point that still runs on the host, where git works -- and only
  # for the dispatches that reach that spec, which is why the COVERAGE flag
  # is handed over: it is what decides which in-container branch runs.
  _prepare_prev_release "${_coverage}"
  # Resolved into a local first, not inline in the argument list: a failing
  # command substitution inside an argument does not abort the command, so
  # an inline form would hand compose an empty -p and let the run continue.
  local _project
  _project="$(_resolve_compose_project_name)"
  # HOST_UID / HOST_GID go in the ENVIRONMENT of `docker compose`, not in a
  # `-e` flag: `-e` sets the variable inside the container, while the
  # service definition's `${HOST_UID:?}` is compose's own interpolation and
  # reads this process's environment. The compose file forwards them into
  # the container from there, so one assignment serves both. They exist so
  # the suite writes the bind-mounted checkout as the real user; compose
  # carries no default for them, so an entry point that forgets them is
  # refused rather than writing files owned by uid 1000.
  #
  # Set BEFORE the tooling-image resolution below, not after: compose
  # interpolates the WHOLE file for any command, so the `docker compose
  # build` inside _ensure_test_tools_image is refused just as the `run` is.
  export HOST_UID HOST_GID
  HOST_UID="$(id -u)"
  HOST_GID="$(id -g)"
  # The provenance compose.yaml stamps onto the network it is about to
  # create (`base.checkout.path`). The scoped reclaim reads that path back
  # off the artifact to decide whether the checkout that made it still
  # exists, so an artifact created without it can never be attributed;
  # compose.yaml therefore takes it with `:?` and no default, and this is
  # the assignment that satisfies it on every path that does not come
  # through `just` (each CI shard, the fragile set, a single --bats-path
  # run). Set beside the ids and for the same reason they are: compose
  # interpolates the WHOLE file whatever service a command names, so the
  # `docker compose build` inside _ensure_test_tools_image needs it too.
  export BASE_CHECKOUT_PATH="${REPO_ROOT}"
  # compose.yaml names every service's image `${TEST_TOOLS_IMAGE}` with NO
  # default, so resolving it is this runner's job -- it is the script `just
  # test` puts behind that entry point. Exported rather than passed with
  # `-e`: compose reads it while INTERPOLATING the file on this host, not
  # as an environment variable inside the container. Resolved into a local
  # first for the same reason the project name is (a failing command
  # substitution inline in an argument would not abort the command).
  local _image
  _image="$(_resolve_test_tools_image)"
  # Ask whether the previous run has let go of this project's network
  # before asking compose to use it. ABOVE the arm, because a refusal here
  # mints nothing: the project it names already exists, and a sweep for
  # dead checkouts has nothing to say about a checkout that is right here.
  _await_project_quiescent "${_project}" "${REPO_ROOT}" || return 1
  # Arm the end-of-run reclaim. BELOW everything that can still refuse the
  # dispatch and ABOVE the first compose call, because those are the two
  # things arming has to separate. A run that dies mid-compose is exactly
  # the run whose litter nobody comes back for, so it must be armed before
  # the build; a dispatch that refuses to start -- `_prepare_prev_release`
  # with no resolvable release tags, a missing tooling Dockerfile -- has
  # minted no project, so sweeping for its litter is a daemon round trip
  # spent on nothing. Arming is also what separates a run that minted a
  # project from `test.sh --test-tools-image`, a pure query the system /
  # smoke recipes make before they build: that one must not open a daemon
  # connection at all.
  _RECLAIM_ARMED=1
  _ensure_test_tools_image "${_image}" "${_project}"
  export TEST_TOOLS_IMAGE="${_image}"
  # The BEFORE half of the residue guard, taken here and not in main: this
  # is the ONE host-side point every bats dispatch passes through -- the
  # local gate, each CI shard, the fragile set, a single --bats-path run --
  # and it is host-side, which the guard needs. A worktree checkout's `.git`
  # is a FILE naming a gitdir outside the bind mount, so no in-container git
  # command can read this tree at all.
  #
  # It goes AFTER the image build and the fixture preparation on purpose:
  # `.prev-release/` is ignored, but the snapshot should describe the tree
  # the CONTAINER is handed, not the one this function was entered with.
  local _residue_before="" _residue_blind=0
  if _residue_guard_available "${REPO_ROOT}"; then
    _residue_before="$(mktemp)"
    if ! _residue_before_snapshot "${REPO_ROOT}" "${_residue_before}"; then
      rm -f "${_residue_before}"
      _residue_before=""
      _residue_blind=1
    fi
  else
    # An invocation that switched the guard off is the acknowledgement: it
    # is how a developer says the path it keeps naming is their own edit,
    # so the pending record goes with it. Outside a checkout there is no
    # record and this is a no-op.
    _residue_forget "${REPO_ROOT}" || true
  fi
  # The compose status is captured rather than left to errexit so the
  # residue check still runs after a FAILING suite -- a run that both failed
  # and wrote into the checkout has two things to say, and the second one
  # explains re-runs that disagree with each other.
  local _rc=0
  docker compose -p "${_project}" \
    -f "${REPO_ROOT}/compose.yaml" run --rm \
    -e COVERAGE="${_coverage}" \
    -e COVERAGE_SHARD="${COVERAGE_SHARD:-}" \
    -e COVERAGE_PATH="${COVERAGE_PATH:-}" \
    -e BATS_ONLY="${BATS_ONLY:-0}" \
    -e BATS_UNIT_SHARD="${BATS_UNIT_SHARD:-}" \
    -e BATS_FRAGILE="${BATS_FRAGILE:-0}" \
    -e BATS_INTEGRATION="${BATS_INTEGRATION:-0}" \
    -e BATS_FILE="${BATS_FILE:-}" \
    -e BATS_FILTER="${BATS_FILTER:-}" \
    -e LINT_ONLY="${LINT_ONLY:-0}" \
    -e LINT_TOOL="${LINT_TOOL:-}" \
    -e PIN_TRACKED_ROOT=/source \
    -e PIN_TRACKED_FILES="$(_pin_tracked_handoff)" \
    "${_service}" || _rc=$?
  if [[ -n "${_residue_before}" ]]; then
    _residue_check "${_residue_before}" "${REPO_ROOT}" || _rc=1
    rm -f "${_residue_before}"
  fi
  # A baseline that could not be taken fails the dispatch AFTER the suite has
  # run and said its own piece: the run is still worth having, but a gate
  # that could not answer "was the checkout left as it was found" must not
  # answer it with silence.
  [[ "${_residue_blind}" -eq 0 ]] || _rc=1
  return "${_rc}"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  local mode="compose"
  local system=0
  local bats_only=0
  local hadolint_only=0
  local lint=0
  local lint_tool=""
  # The `--<tool>-only` host-direct primitives all set this one variable:
  # they are the same operation (run ONE lint driver on this host, no
  # compose) parameterised by tool, so they share one short-circuit rather
  # than one boolean each.
  local host_lint=""
  local host_lint_group=""
  local bats_unit_shard=""
  local bats_fragile=0
  local bats_integration=0
  local bats_path=""
  local coverage_path=""
  local bats_filter=""
  local coverage_shard=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage ;;
      --ci) mode="ci"; shift ;;
      --lint) lint=1; shift ;;
      --await-project)
        # A query, like --compose-project-name / --test-tools-image: it
        # answers about this checkout and exits, minting nothing. The
        # project it asks about comes from the same resolver the dispatch
        # uses, so a caller that has already exported COMPOSE_PROJECT_NAME
        # is asking about the project it is actually going to drive.
        _await_project_quiescent "$(_resolve_compose_project_name)" "${REPO_ROOT}"
        exit $?
        ;;
      --shellcheck) lint_tool="shellcheck"; shift ;;
      --hadolint) lint_tool="hadolint"; shift ;;
      --issueref) lint_tool="issueref"; shift ;;
      --adr-numbering) lint_tool="adr-numbering"; shift ;;
      --adr-structure) lint_tool="adr-structure"; shift ;;
      --stale-setup-conf) lint_tool="stale-setup-conf"; shift ;;
      --readme-sync) lint_tool="readme-sync"; shift ;;
      --doc-counts) lint_tool="doc-counts"; shift ;;
      --home-literal) lint_tool="home-literal"; shift ;;
      --arch-literal) lint_tool="arch-literal"; shift ;;
      --bash-source-guard) lint_tool="bash-source-guard"; shift ;;
      --early-close-reader) lint_tool="early-close-reader"; shift ;;
      --errexit-bang) lint_tool="errexit-bang"; shift ;;
      --derived-figures) lint_tool="derived-figures"; shift ;;
      --i18n-orphan) lint_tool="i18n-orphan"; shift ;;
      --self-hosted-guard) lint_tool="self-hosted-guard"; shift ;;
      --changelog-entry) lint_tool="changelog-entry"; shift ;;
      --changelog-layout) lint_tool="changelog-layout"; shift ;;
      --pin-coverage) lint_tool="pin-coverage"; shift ;;
      --action-ref-agreement) lint_tool="action-ref-agreement"; shift ;;
      --generated-workflow-actions) lint_tool="generated-workflow-actions"; shift ;;
      --just-provenance) lint_tool="just-provenance"; shift ;;
      --catalog-description) lint_tool="catalog-description"; shift ;;
      --shellcheck-only) host_lint="shellcheck"; shift ;;
      --issueref-only) host_lint="issueref"; shift ;;
      --adr-numbering-only) host_lint="adr-numbering"; shift ;;
      --adr-structure-only) host_lint="adr-structure"; shift ;;
      --stale-setup-conf-only) host_lint="stale-setup-conf"; shift ;;
      --readme-sync-only) host_lint="readme-sync"; shift ;;
      --doc-counts-only) host_lint="doc-counts"; shift ;;
      --home-literal-only) host_lint="home-literal"; shift ;;
      --arch-literal-only) host_lint="arch-literal"; shift ;;
      --bash-source-guard-only) host_lint="bash-source-guard"; shift ;;
      --early-close-reader-only) host_lint="early-close-reader"; shift ;;
      --errexit-bang-only) host_lint="errexit-bang"; shift ;;
      --derived-figures-only) host_lint="derived-figures"; shift ;;
      --i18n-orphan-only) host_lint="i18n-orphan"; shift ;;
      --self-hosted-guard-only) host_lint="self-hosted-guard"; shift ;;
      --changelog-entry-only) host_lint="changelog-entry"; shift ;;
      --changelog-layout-only) host_lint="changelog-layout"; shift ;;
      --pin-coverage-only) host_lint="pin-coverage"; shift ;;
      --action-ref-agreement-only) host_lint="action-ref-agreement"; shift ;;
      --generated-workflow-actions-only) host_lint="generated-workflow-actions"; shift ;;
      --just-provenance-only) host_lint="just-provenance"; shift ;;
      --catalog-description-only) host_lint="catalog-description"; shift ;;
      --nesting-depth-only) host_lint="nesting-depth"; shift ;;
      --function-length-only) host_lint="function-length"; shift ;;
      --positional-params-only) host_lint="positional-params"; shift ;;
      --shell-metrics-only) host_lint="shell-metrics"; shift ;;
      --lint-group) host_lint_group="${2:?--lint-group expects <n>/<total>}"; shift 2 ;;
      --lint-group-members) _lint_group_members "${2:?--lint-group-members expects <n>/<total>}"; return 0 ;;
      --hadolint-only) hadolint_only=1; shift ;;
      --bats-only) bats_only=1; shift ;;
      --bats-unit-shard) bats_unit_shard="${2:?--bats-unit-shard expects <n>/<total>}"; shift 2 ;;
      --bats-fragile) bats_fragile=1; shift ;;
      --bats-integration) bats_integration=1; shift ;;
      --bats-path) bats_path="${2:?--bats-path expects <path>}"; shift 2 ;;
      --coverage-path) coverage_path="${2:?--coverage-path expects <path>}"; shift 2 ;;
      --filter) bats_filter="${2:?--filter expects <regex>}"; shift 2 ;;
      --coverage) mode="coverage"; shift ;;
      --coverage-shard) mode="coverage"; coverage_shard="${2:?--coverage-shard expects <n>/<total>}"; shift 2 ;;
      --system) system=1; shift ;;
      # Name-resolution primitives. They print one line and stop -- the
      # `just test system` recipe reads them so that the build-only
      # test-tools service and the ci-system consumer resolve the SAME tag
      # (a mismatch there is silent: the consumer would quietly pull the
      # published image while the local build sat unused).
      --test-tools-image) _resolve_test_tools_image; return 0 ;;
      --compose-project-name) _resolve_compose_project_name; return 0 ;;
      *) _die ci_unknown_option "Unknown option: $1" ;;
    esac
  done

  # --shellcheck / --hadolint are narrowing flags for --lint; reject them
  # standalone so a typo (`./test.sh --hadolint`, meaning --hadolint-only)
  # fails loudly instead of silently no-op'ing.
  if [[ -n "${lint_tool}" && "${lint}" != "1" ]]; then
    _die ci_lint_tool_without_lint \
      "--${lint_tool} narrows --lint; use './test.sh --lint --${lint_tool}' or '--${lint_tool}-only'."
  fi

  # The host-direct lint primitives (`--shellcheck-only`,
  # `--issueref-only`, `--adr-numbering-only`, `--adr-structure-only`,
  # `--stale-setup-conf-only`, `--readme-sync-only`,
  # `--doc-counts-only`, `--home-literal-only`, `--arch-literal-only`,
  # `--bash-source-guard-only`, `--derived-figures-only`,
  # `--i18n-orphan-only`, `--early-close-reader-only`,
  # `--errexit-bang-only`,
  # `--self-hosted-guard-only`, `--changelog-entry-only`,
  # `--pin-coverage-only`, `--action-ref-agreement-only`) short-circuit
  # before any mode dispatch and run
  # ONE driver right here: no compose, no test-tools image, no
  # apt-install. It is how a DEDICATED CI job runs its one lint (and how
  # a person times one driver); the grouped lint-static jobs reach the
  # same drivers through `--lint-group` below. Either way a plain
  # ubuntu-latest runner runs the SAME driver the local phase runs, so the
  # local gate and the CI gate cannot drift apart. Every tool but shellcheck is pure
  # bash over the checkout; shellcheck relies on the binary ubuntu-latest
  # ships pre-installed. hadolint is deliberately absent: its binary
  # exists only in the test-tools image, so its CI job uses
  # `--lint --hadolint` inside that image instead.
  if [[ -n "${host_lint}" ]]; then
    _run_lint_tool "${host_lint}"
    return 0
  fi

  # The grouped form of the same join (base#1071). One lint-static job per
  # GROUP of the partition rather than per driver: 20 one-driver jobs spent
  # more runner startup than they did work, and took 20 of the free plan's
  # ~20 org-wide concurrent slots away from the coverage shards, which are
  # the run's critical path. Which lint failed is still answerable -- the
  # group enumerates every failing driver in its output (base#1059) instead
  # of the checks list naming it.
  if [[ -n "${host_lint_group}" ]]; then
    _run_lint_group "${host_lint_group}"
    return 0
  fi

  # --hadolint-only short-circuits and runs the linter directly here (no
  # compose), so hadolint must already be in PATH. It is the in-container
  # primitive: callers run it from INSIDE the ci/test-tools image (which
  # bakes hadolint in) -- the self-test.yaml hadolint job invokes it via
  # `_run_via_compose ci`. _run_hadolint _die's with a clear message if the
  # binary is missing (e.g. invoked on a bare host).
  if [[ "${hadolint_only}" == "1" ]]; then
    _run_hadolint
    return 0
  fi

  # `--lint` runs the linters through the ci/test-tools container (it bakes
  # in hadolint, absent on the host). LINT_ONLY=1 tells the in-container
  # `--ci` path to run only the lint phase; LINT_TOOL narrows to one linter
  # (empty = all). Even `--lint --shellcheck` runs in-container so its
  # behaviour matches bare `just test lint`; the dedicated GHA shellcheck
  # job uses the host-only `--shellcheck-only` path instead.
  if [[ "${lint}" == "1" ]]; then
    LINT_ONLY=1 LINT_TOOL="${lint_tool}" _run_via_compose ci 0
    return 0
  fi

  # Instrumented single-spec inner loop. `--coverage-path <file|dir>` runs
  # ONE named spec under kcov via the `coverage` container -- the loop for
  # the failure class whose whole evidence is "red under kcov, green
  # without it", which until now cost a full suite or a full shard (8-12
  # minutes) per iteration.
  #
  # It goes through the SAME `coverage` service a shard does, so COVERAGE=1
  # is set inside the container and the kcov-fragile `[ "${COVERAGE:-0}" = 1
  # ] && skip` guards behave exactly as they do on a shard -- a
  # reproduction that differed there would reproduce the wrong thing.
  # COVERAGE_PATH is what the in-container dispatch branches on, ahead of
  # _run_coverage.
  #
  # It reports NO coverage figure and writes nothing into coverage/; see
  # _run_coverage_path in drivers/bats.sh for why that is the design rather
  # than a gap. The conflict guard is what keeps that true: `--coverage` /
  # `--coverage-shard` produce a figure over a partition and `--bats-path`
  # is the deliberately kcov-free loop, so silently letting one of them win
  # is how a one-spec run would end up reported as a shard.
  if [[ -n "${coverage_path}" ]]; then
    if [[ "${mode}" == "coverage" || -n "${bats_path}" ]]; then
      _die ci_coverage_path_conflict \
        "--coverage-path runs ONE named spec under kcov and reports no coverage figure; it cannot combine with --coverage / --coverage-shard (a figure over a partition) or --bats-path (the no-kcov loop). Pick one."
    fi
    _validate_spec_target "${coverage_path}"
    # COVERAGE_SHARD is cleared, not merely left unset: _run_via_compose
    # forwards it from the AMBIENT environment, so a caller that already has
    # one -- most obviously this suite's own specs when they run inside a
    # coverage shard -- would hand this mode a partition value it does not
    # use. Carrying an ignored value is how it later becomes a read one.
    BATS_ONLY=1 COVERAGE_PATH="${coverage_path}" BATS_FILTER="${bats_filter}" \
      COVERAGE_SHARD="" _run_via_compose coverage 1
    return 0
  fi

  # Single-path / filtered inner loop. `--bats-path <file|dir>` and / or
  # `--filter <regex>` run a named subset via the `ci` container, skipping
  # ShellCheck (BATS_ONLY=1) and kcov so the TDD inner loop stays fast.
  # Validation runs on the host before dispatch; the in-container `--ci`
  # branch (BATS_FILE / BATS_FILTER) actually invokes bats.
  if [[ -n "${bats_path}" || -n "${bats_filter}" ]]; then
    if [[ "${mode}" == "coverage" ]]; then
      _die ci_bats_path_coverage \
        "--bats-path / --filter cannot combine with --coverage (single-path is the fast no-kcov loop). One spec WITH kcov is --coverage-path <spec>; a coverage figure is --coverage / --coverage-shard alone."
    fi
    if [[ -n "${bats_path}" ]]; then
      _validate_spec_target "${bats_path}"
    fi
    BATS_ONLY=1 BATS_FILE="${bats_path}" BATS_FILTER="${bats_filter}" \
      _run_via_compose ci 0
    return 0
  fi

  case "${mode}" in
    ci)
      # Running inside container. Default path skips kcov for speed
      # (the dev loop is far more frequent than the coverage check).
      # Pass COVERAGE=1 via the outer `--coverage` flag to include it.
      # `--system` swaps the bats invocation to drive
      # `docker buildx build` against runtime-test fixtures.
      # BATS_ONLY=1 (set by `--bats-only` outer flag, plumbed via
      # `_run_via_compose`) skips the ShellCheck phase — the dedicated
      # self-test.yaml shellcheck job covers it in parallel.
      # BATS_UNIT_SHARD / BATS_INTEGRATION route this dispatch
      # to a matrix-shard / integration-only subset; the dedicated GHA
      # bats-unit / bats-integration jobs set these via the outer
      # `--bats-unit-shard` / `--bats-integration` flags so the
      # in-container path matches the local dev path.
      if [[ "${system}" == "1" ]]; then
        _run_system
        _fix_permissions
        return 0
      fi
      # LINT_ONLY: `just test lint [--shellcheck | --hadolint]`
      # routes here with LINT_ONLY=1; run the requested linter(s) and skip
      # bats entirely. LINT_TOOL empty = all linters (shellcheck +
      # hadolint), matching bare `just test lint`. The test-tools image
      # already ships every tool (bats / shellcheck / hadolint / kcov), so
      # nothing is installed at runtime on any path.
      if [[ "${LINT_ONLY:-0}" == "1" ]]; then
        if [[ -z "${LINT_TOOL:-}" ]]; then
          _run_all_lint_tools
        else
          _run_lint_tool "${LINT_TOOL}"
        fi
        return 0
      fi
      # Full `just test` lint phase: shellcheck THEN hadolint, so a
      # Dockerfile regression fails `just test` locally the same way it
      # fails the CI hadolint job (local==CI). BATS_ONLY=1 (dedicated
      # GHA shellcheck/hadolint jobs cover lint in parallel) skips both.
      # COVERAGE=1 also skips lint: lint is a separate concern measured by
      # the dedicated lint jobs, not the coverage matrix — running it once
      # per coverage shard would be wasted work (the coverage shards now
      # share the test-tools image, which DOES ship both linters, so this
      # is a deliberate skip, not a missing-binary workaround).
      if [[ "${BATS_ONLY:-0}" != "1" && "${COVERAGE:-0}" != "1" ]]; then
        # Every tool in _LINT_TOOLS, in table order. Membership of that
        # table is what puts a lint in the local gate; it does NOT put it
        # in CI, because no CI job runs this phase (the lint jobs narrow
        # to one tool, and every bats / coverage job sets BATS_ONLY=1 /
        # COVERAGE=1, which land in the branch this guard excludes). The
        # CI join is a job in self-test.yaml calling the tool's
        # host-direct primitive; the completeness guard in
        # self_test_yaml_spec is what makes that mandatory rather than
        # remembered.
        _run_all_lint_tools
      fi
      if [[ "${COVERAGE:-0}" == "1" ]]; then
        # COVERAGE_PATH names ONE spec to instrument, and is checked
        # FIRST: it is the only kcov mode that reports no figure, so it
        # must not fall through to _run_coverage, which writes
        # coverage/cobertura.xml + coverage/timings.tsv into the mounted
        # checkout -- the exact artifacts the coverage-gate merges and the
        # next partition weighs itself by. Nothing to chown and no report
        # to announce either, hence no _fix_permissions and no report line.
        if [[ -n "${COVERAGE_PATH:-}" ]]; then
          _run_coverage_path "${COVERAGE_PATH}"
          return 0
        fi
        # COVERAGE_SHARD narrows kcov to one matrix slice; empty =
        # full suite (local `just test coverage` / release path).
        _run_coverage "${COVERAGE_SHARD:-}"
        _fix_permissions
        echo "Coverage report: ${REPO_ROOT}/coverage/index.html"
      elif [[ -n "${BATS_FILE:-}" || -n "${BATS_FILTER:-}" ]]; then
        _run_bats_path
      elif [[ -n "${BATS_UNIT_SHARD:-}" ]]; then
        _run_unit_shard "${BATS_UNIT_SHARD}"
      elif [[ "${BATS_FRAGILE:-0}" == "1" ]]; then
        _run_bats_fragile
      elif [[ "${BATS_INTEGRATION:-0}" == "1" ]]; then
        _run_integration_tests
      else
        _run_tests
      fi
      ;;
    coverage)
      # Kcov via the kcov/kcov-based `coverage` service. Bare --coverage
      # runs the full suite; --coverage-shard N/T (coverage_shard set)
      # plumbs COVERAGE_SHARD into the container so _run_coverage kcov's
      # only this matrix slice. The self-test.yaml coverage matrix sets
      # the latter; local `just test coverage` uses the former.
      # The reports are only usable for a release badge if something
      # records WHICH commit they measured and HOW MUCH of the suite
      # measured it; see _stamp_coverage_head. The writer is handed the
      # ROOT ONLY: it derives the scope from the manifest the run left in
      # coverage/, so no input to this dispatch can make a partial
      # measurement wear a whole-suite certificate.
      #
      # The selectors are still passed to the CONTAINER on both branches,
      # and the full run says the empty values OUT LOUD, because
      # _run_via_compose forwards them from the AMBIENT environment: a
      # bare `--coverage` under an inherited COVERAGE_SHARD would kcov a
      # quarter of the specs, and under an inherited COVERAGE_PATH -- read
      # FIRST by the in-container dispatch, so it out-ranks the partition
      # -- would kcov ONE spec and write no report at all. The caller that
      # carries either is this suite itself, run under `just test
      # coverage` / `just test coverage-path`. Neither can lie about
      # itself now, but both are still the WRONG RUN, so both are cleared.
      #
      # The certificate is erased BEFORE the run and written only after it
      # succeeds, so the three states are the three truths: no stamp (no
      # run, or a run that died), or a stamp describing the run that just
      # finished. Leaving the old one in place through a failed run is the
      # one state that lies -- fresh partial reports under an earlier
      # `scope=full` certificate (see _invalidate_coverage_head).
      #
      # The eraser's status is read the same way the run's is below, and
      # for the same reason: a sourced main (this suite) has errexit off,
      # so an eraser that reported failure without exiting would be
      # ignored here and the run would go on under the certificate it
      # could not remove. Neither reading goes on the left of `||`.
      local _invalidate_rc _coverage_rc
      _invalidate_coverage_head "${REPO_ROOT}"
      _invalidate_rc=$?
      (( _invalidate_rc == 0 )) || return "${_invalidate_rc}"
      # One call for both branches: the shard spec is empty on the full
      # run, which is the value that has to be said out loud.
      #
      # The roster is not a memory exercise. coverage_badge_spec's "the
      # coverage dispatch pins every selector the container reads"
      # intersects the `-e NAME="${NAME:-}"` lines of _run_via_compose
      # with the names the in-container COVERAGE branch reads, and fails
      # until each member is assigned here -- so a third selector added to
      # that forwarder arrives with its clearing already demanded.
      COVERAGE_SHARD="${coverage_shard}" COVERAGE_PATH="" \
        _run_via_compose coverage 1
      # The status is read AFTER the branch, never as `|| rc=$?`: a
      # command on the left of `||` runs with errexit suspended, and the
      # suspension reaches inside the function -- a fatal step within
      # _run_via_compose (an unresolvable prev-release fixture, say) would
      # stop aborting the run and start being swallowed here.
      #
      # So under the real entry (strict mode) a failed run has already
      # exited by this line, and the writer below is unreachable; this
      # reading is what gives the SOURCED main -- the specs call it -- the
      # same guarantee without errexit.
      _coverage_rc=$?
      (( _coverage_rc == 0 )) || return "${_coverage_rc}"
      # The root, and nothing else. The writer derives the scope from the
      # reports this run just left behind; handing it the FLAG is what let
      # a run narrowed by something else wear a whole-suite certificate.
      _stamp_coverage_head "${REPO_ROOT}"
      ;;
    compose)
      # Default: fast CI (shellcheck + bats, no kcov) via the alpine
      # test-tools-based `ci` service. Flag-driven plumbing of the
      # relevant env vars selects the inner branch:
      #   --bats-only          -> BATS_ONLY=1 (skip _run_shellcheck)
      #   --bats-unit-shard X  -> BATS_ONLY=1 + BATS_UNIT_SHARD=X
      #   --bats-integration   -> BATS_ONLY=1 + BATS_INTEGRATION=1
      # Local `just test` (no flags) keeps the full pipeline.
      if [[ -n "${bats_unit_shard}" ]]; then
        BATS_ONLY=1 BATS_UNIT_SHARD="${bats_unit_shard}" _run_via_compose ci 0
      elif [[ "${bats_fragile}" == "1" ]]; then
        BATS_ONLY=1 BATS_FRAGILE=1 _run_via_compose ci 0
      elif [[ "${bats_integration}" == "1" ]]; then
        BATS_ONLY=1 BATS_INTEGRATION=1 _run_via_compose ci 0
      elif [[ "${bats_only}" == "1" ]]; then
        BATS_ONLY=1 _run_via_compose ci 0
      else
        _run_via_compose ci 0
      fi
      ;;
  esac
}

# ── End-of-run reclaim ───────────────────────────────────────────────────────
#
# `just test` is where the litter is made. Every throwaway copy of this tree
# an agent takes to mutation-test a guard is a fresh absolute path, and a
# fresh path is a fresh compose project with a network of its own; the copy
# is then deleted and the network is not. Nobody runs `just docker prune` in
# a directory they are about to remove, and the measurement that opened this
# was 468 such networks, 417 of them belonging to paths that no longer
# existed. A chore that requires a human to remember it is not a handled
# chore, so the suite collects after itself.
#
# It runs on the FAILING path too: litter from a red run is still litter,
# and a red run is the one a developer walks away from.
#
# _test_exit_reclaim
#   Captures the status the shell was about to exit with, reclaims, and
#   exits with that same status. THE STATUS IS NEVER THE RECLAIM'S. A
#   collector that could turn a green suite red would be switched off within
#   the week, and it would deserve to be: nothing about the verdict on the
#   code under test depends on whether a network could be removed. A failure
#   is reported and the sweep is left to the next run.
#
#   The PROJECT sweep only. Tooling-tag retention is deliberately not here:
#   it is the half of `just docker prune --reclaim` that has no proof to
#   act on -- the tooling tag is content-hash shared on purpose, so no
#   artifact names all of a tag's users and "nothing I can see resolves it"
#   is a measurement rather than evidence. Measured on the shared host: the
#   first automatic run retired one tooling image nobody asked it to, and
#   with the recency window out of the way the same rule names the tag a
#   live sibling worktree still resolves. That costs a rebuild rather than
#   data, which is exactly why it stays an explicit
#   `just docker prune --tool-tags` alongside --volumes and
#   --worktree-orphans instead of something the suite does to the machine on
#   its way out.
_test_exit_reclaim() {
  local _rc=$?
  if [[ "${_RECLAIM_ARMED:-0}" == "1" ]]; then
    _reclaim_orphan_projects \
      || _log_warn ci ci_reclaim_failed \
        "display=scoped reclaim of orphaned compose projects failed; litter left for the next run (the suite's verdict is unchanged)."
  fi
  exit "${_rc}"
}

# Guard: only run main when executed directly, not when sourced (for testing)
#
# The trap is installed INSIDE this guard, not at file scope: the specs
# source this file, and a file-scope EXIT trap would fire when the spec's
# own shell exits -- reclaiming from a bats worker, in the middle of the
# 32-way parallel run, against the daemon the suite itself is using.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  trap _test_exit_reclaim EXIT
  main "$@"
fi
