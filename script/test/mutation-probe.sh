#!/usr/bin/env bash
#
# mutation-probe.sh - break the behaviour once, to prove the test was
# pinning it.
#
# Usage:
#   ./script/test/mutation-probe.sh --subject <path> --mutate '<command>'
#   ./script/test/mutation-probe.sh --subject <path> --mutate '<command>' \
#       --spec test/bats/unit/<name>_spec.bats
#   ./script/test/mutation-probe.sh --root <dir> ...        # default: this checkout
#
# Exit status: 0 = PINNED (something went red), 1 = NOT PINNED (the tier
# stayed green under a real mutation), 2 = INCONCLUSIVE (a narrow run stayed
# green, which answers about that spec and not about the suite), 3 = refused
# (an unusable input, or a measurement that could only be read vacuously).
#
# Style: Google Shell Style Guide.
#
# ── What this answers that a revert does not ────────────────────────────────
#
# The v0.43 retrospective audited every PR of the cycle by REMOVING the
# production change and re-running its tests. That move finds a test that
# does not notice absence. It cannot find a test that notices absence and
# would miss a WRONG ANSWER: a guard that only greps for a string still turns
# red when the file carrying that string is deleted, so under a revert it
# scores identically to a behavioural guard. Four assertion groups shipped in
# that blind spot, and ten more PRs' tests failed on revert only with
# `command not found` or `No such file` -- one refactor away from fail-open.
#
# So the probe puts the production code BACK and breaks its behaviour in
# place. A test that survives that was never pinning the behaviour; a test
# that fails names itself as the one that was.
#
# Measured on this tree before this file existed. Deleting
# dist/script/docker/wrapper/build.sh -- the subject of
# reclaim_wiring_spec.bats's "the verbs that BEGIN a flow do not reclaim" --
# leaves that spec at 32 ok / 0 not ok, because the assertion is a refutation
# and a refutation over a file that is not there is satisfied by its absence.
# The same mutation at tier scope is 4667 ok / 109 not ok, with the witnesses
# in build_sh_spec.bats.
#
# ── Why the SCOPE decides what a green may be called ───────────────────────
#
# That pair of numbers is the whole reason this is a script and not a
# paragraph. base#1108 ran the audit per-file -- revert the production
# change, re-run THE ONE SPEC THAT PR EDITED, call the change untested if
# that spec is green -- and named six changes on that basis. Measured
# afterwards, five of the six had a failing witness in a SIBLING spec from
# the same PR, one was a genuine gap, and one did not reproduce at all. The
# defect in the five was the coverage ACCOUNTING, not the coverage.
#
# A spec that stays green under a mutation has answered about ITSELF. Only a
# tier-wide run can say the suite does not pin a behaviour. So a narrow green
# is reported as INCONCLUSIVE and never as NOT PINNED, and the verdict always
# states the scope it was measured at -- the figure nobody recorded the first
# time. A RED needs no such qualification: something observed the wrong
# answer, which is sound at any scope.
#
# ── Why the restoration is proven rather than assumed ──────────────────────
#
# A harness that leaves a half-mutated tree is worse than no harness: the
# next run measures a tree nobody described, and the author's next commit
# ships the mutation. Three controls, in this order:
#
#   1. Every declared subject is RECORDED (bytes and mode) before anything is
#      touched, and restored from that record -- not from git, which cannot
#      see an uncommitted edit the author is in the middle of.
#   2. The tree is compared BEFORE and AFTER the mutation, by git -- status
#      code AND content hash for every path in the dirty set, because a file
#      that was already dirty stays ` M` through a second edit and a
#      code-only comparison misses exactly the case an author working
#      mid-change is always in. A mutation command that edited a file it did
#      not declare is refused there, before a multi-minute suite carries the
#      undeclared edit past the point anyone is still watching. Only the
#      declared subjects were recorded, so an undeclared edit is one this
#      script could not undo.
#   3. The restoration is VERIFIED -- bytes and mode, against the record --
#      and a failure is loud, names the file, keeps the record directory, and
#      exits refused. An EXIT trap runs the same restore for the paths the
#      explicit one cannot reach (a dead daemon), and a separate INT / TERM
#      handler stops the runner first and then exits reporting nothing.
#
# ── Four measurements that must not be read as verdicts ────────────────────
#
# base#1089's rule, applied to a probe instead of a gate: every no-evidence
# state is refused by name.
#
#   - A mutation that left every declared subject byte-identical. The tree the
#     suite then passes over is the tree it already passed over, so the green
#     is the baseline. Read as a verdict it certifies a test as behavioural on
#     the strength of a sed expression that matched nothing.
#   - A run that reported no test results at all. Zero reds is the number a
#     fully behavioural suite prints too, so reading it as NOT PINNED turns a
#     broken runner into a finding about the tests.
#   - A run that reported SOME passes and then died. Same hole, arriving with a
#     plausible number attached: zero reds over a population that never ran.
#     The runner's exit status is what tells the two apart, so it is kept.
#   - A narrow green, per the scope section above.
#
# An interrupt is the same question asked by a signal, and it is answered the
# same way: INT / TERM stops the runner, restores, and exits without reporting
# anything, because a measurement over a suite that was killed partway cannot
# be told apart from a finished one's.
#
# ── What it does NOT decide ────────────────────────────────────────────────
#
# Whether running the probe is required before a change lands is a policy
# question and is not answered here: this file is the loop, available on
# demand, like `just test coverage-path`. It is wired into no gate and no CI
# job, and it fails nothing that does not ask for it.
#
# ── The mutations worth reaching for ───────────────────────────────────────
#
# The mutation is the caller's, because only the caller knows what the
# behaviour IS. Five shapes earned their place during the v0.43 audit, and
# the last one catches what the others miss:
#
#   --mutate 'sed -i "/^_run_thing()/a return 0" script/test/drivers/thing.sh'
#       The cheapest: the driver reports clean without looking. Validated
#       twice during the audit; on one driver it turned 11 of 20 cases red and
#       left four "ignores X" cases green, because a lint that compares
#       nothing also exits 0.
#   --mutate 'sed -i "/- name: the step/,+3d" .github/workflows/w.yaml'
#       Delete a step from a workflow.
#   --mutate 'sed -i "s/_the_function/_the_functionX/g" path/to/lib.sh'
#       Rename a function away from its callers.
#   --mutate 'sed -i "s/-eq 0/-ne 0/" path/to/file.sh'
#       Invert a branch.
#   --mutate '<a behaviour-PRESERVING refactor>'
#       Rename a local, reorder two independent lines, change a quoting
#       style. Everything above is destructive, so a test that merely greps
#       for text goes red on all of them and looks behavioural. A refactor
#       that preserves behaviour must leave the suite GREEN -- a red here
#       means the test is pinned to the text and not to the behaviour. Three
#       greps audited on base#1117 were anti-correlated exactly this way:
#       green through a total inversion of the branch, green with the subject
#       removed entirely, and red on a behaviour-preserving refactor.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

_MUTATION_PROBE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"

# Trap state. Globals, because an EXIT / INT / TERM handler takes no
# arguments and the handler is the half that has to work when nothing else
# did.
_MUTATION_PROBE_RECORD_DIR=''
_MUTATION_PROBE_ROOT=''
_MUTATION_PROBE_SUBJECTS=()

# The runner's pid while it is running, and the status it exited with. The pid
# is what a signal handler needs in order to STOP the suite rather than leave
# it running against a tree that is about to be restored under it.
_MUTATION_PROBE_RUNNER_PID=''
_MUTATION_PROBE_RUN_STATUS=0

# _mutation_probe_err <message> -- diagnostic to stderr. Block-redirected
# rather than a bare `printf ... >&2` because this is a standalone,
# log.sh-free host-side tool (the same rationale class as
# drivers/coverage_gate.sh) and the bare-stderr lint scans script/test/.
_mutation_probe_err() {
  {
    printf 'mutation probe: %s\n' "${1}"
  } >&2
}

# _mutation_probe_say <message> -- the report, on stdout. The caller pastes
# these lines into a PR body, so they are the product and not a log.
_mutation_probe_say() {
  printf 'mutation probe: %s\n' "${1}"
}

# ── the record / restore / verify spine ─────────────────────────────────────

# _mutation_probe_record <record-dir> <root> <subject>... -- copy each
# subject's bytes and mode aside. `cp -p` rather than a git object read: the
# subject may carry an uncommitted edit, and a probe that silently measured
# the committed version instead would report on a tree the author does not
# have.
_mutation_probe_record() {
  local _rec="${1}" _root="${2}"
  shift 2
  local _s
  for _s in "$@"; do
    mkdir -p -- "${_rec}/$(dirname -- "${_s}")" || return 1
    cp -p -- "${_root}/${_s}" "${_rec}/${_s}" || return 1
  done
  return 0
}

# _mutation_probe_restore <record-dir> <root> <subject>... -- copy each
# recorded original back. Recreates a subject the mutation deleted, and
# carries the mode with it.
_mutation_probe_restore() {
  local _rec="${1}" _root="${2}"
  shift 2
  local _s _rc=0
  for _s in "$@"; do
    mkdir -p -- "$(dirname -- "${_root}/${_s}")" || _rc=1
    cp -p -- "${_rec}/${_s}" "${_root}/${_s}" || _rc=1
  done
  return "${_rc}"
}

# _mutation_probe_verify_restored <record-dir> <root> <subject>... -- 0 when
# every subject is byte-identical AND mode-identical to its record, non-zero
# naming each that is not.
#
# The mode is checked as well as the bytes because restoring an executable
# without its bit leaves a tree that reads clean to a diff and is broken to
# everything that runs it.
_mutation_probe_verify_restored() {
  local _rec="${1}" _root="${2}"
  shift 2
  local _s _rc=0 _want _got
  for _s in "$@"; do
    if ! cmp -s -- "${_rec}/${_s}" "${_root}/${_s}"; then
      _mutation_probe_err "RESTORATION FAILED: ${_s} is not byte-identical to the recorded original."
      _rc=1
      continue
    fi
    _want="$(stat -c '%a' -- "${_rec}/${_s}" 2>/dev/null || printf 'unknown')"
    _got="$(stat -c '%a' -- "${_root}/${_s}" 2>/dev/null || printf 'unknown')"
    if [[ "${_want}" != "${_got}" ]]; then
      _mutation_probe_err "RESTORATION FAILED: ${_s} came back with mode ${_got}, recorded as ${_want}."
      _rc=1
    fi
  done
  return "${_rc}"
}

# _mutation_probe_emergency_restore -- the trap payload. Restores from the
# globals and says so loudly if it could not, because the one thing worse
# than a mutated tree is a mutated tree nobody was told about.
_mutation_probe_emergency_restore() {
  [[ -n "${_MUTATION_PROBE_RECORD_DIR}" ]] || return 0
  (( ${#_MUTATION_PROBE_SUBJECTS[@]} > 0 )) || return 0
  _mutation_probe_restore "${_MUTATION_PROBE_RECORD_DIR}" "${_MUTATION_PROBE_ROOT}" \
    "${_MUTATION_PROBE_SUBJECTS[@]}" || true
  if ! _mutation_probe_verify_restored "${_MUTATION_PROBE_RECORD_DIR}" \
      "${_MUTATION_PROBE_ROOT}" "${_MUTATION_PROBE_SUBJECTS[@]}"; then
    _mutation_probe_err "the tree may still be mutated. The recorded originals are kept in ${_MUTATION_PROBE_RECORD_DIR} -- copy them back before anything else reads this checkout."
    return 1
  fi
  _mutation_probe_err "the run was interrupted; the subjects were restored from the record."
  return 0
}

# _mutation_probe_signal_restore -- the INT / TERM handler, which is a separate
# function from the EXIT one because it has to STOP.
#
# A handler that restored and returned would let the loop fall through into its
# verdict and report a measurement taken over a suite that was killed partway
# -- a number nobody can tell apart from a finished run's, which is exactly the
# kind of unsupported figure this tool exists to stop producing. It also kills
# the runner first: a suite left running against a tree that is about to be
# restored under it is worse than either outcome alone.
_mutation_probe_signal_restore() {
  trap - EXIT INT TERM
  _mutation_probe_stop_runner
  _mutation_probe_emergency_restore || true
  _mutation_probe_err "interrupted, so there is NO verdict: a measurement over a suite that was stopped partway cannot be told apart from a finished one."
  exit 3
}

# ── the leak check: git answers what the mutation touched ───────────────────

# _mutation_probe_tree_state <root> <out-file> -- the tree's dirty set as NUL
# separated `<status><TAB><content-hash><TAB><path>` records.
#
# `-z` rather than the line form because git quotes a path with a space or a
# newline in it, and a quoted path is not the path the record was keyed on.
#
# The HASH is what makes the comparison a comparison. A status code alone
# answers only whether a file is dirty, and the commonest real case is a file
# that was ALREADY dirty: editing it again leaves it ` M` before and after, so
# a code-only snapshot reports no change, the suite runs, and the undeclared
# edit is left behind with nothing said. An already-untracked file is `??`
# either way and has the same hole. Hashing is cheap here because the set is
# the DIRTY set, not the tree.
_mutation_probe_tree_state() {
  local _root="${1}" _out="${2}"
  local -a _records=()
  local _rec _path _hash
  : > "${_out}"
  mapfile -d '' -t _records < <(git -C "${_root}" status --porcelain -z \
    --untracked-files=all --no-renames 2>/dev/null)
  for _rec in "${_records[@]}"; do
    [[ ${#_rec} -gt 3 ]] || continue
    _path="${_rec:3}"
    _hash='-'
    if [[ -f "${_root}/${_path}" ]]; then
      _hash="$(sha256sum -- "${_root}/${_path}")"
      _hash="${_hash%% *}"
    fi
    printf '%s\t%s\t%s\0' "${_rec:0:2}" "${_hash}" "${_path}" >> "${_out}"
  done
}

# _mutation_probe_changed_paths <before-file> <after-file> -- every path whose
# status or content differs between the two snapshots, one per line. A path
# that gained, lost or changed a record all count: a mutation that deletes a
# file, one that edits it, and one that edits a file already dirty are all the
# mutation's work.
_mutation_probe_changed_paths() {
  local -A _before=() _after=()
  local -a _records=()
  local _rec _rest _path
  # Fields are taken off the FRONT, so a path carrying a tab stays whole: the
  # status and the hash cannot contain one, the path is whatever is left.
  mapfile -d '' -t _records < "${1}"
  for _rec in "${_records[@]}"; do
    [[ -n "${_rec}" ]] || continue
    _rest="${_rec#*$'\t'}"
    _path="${_rest#*$'\t'}"
    _before["${_path}"]="${_rec%%$'\t'*}${_rest%%$'\t'*}"
  done
  _records=()
  mapfile -d '' -t _records < "${2}"
  for _rec in "${_records[@]}"; do
    [[ -n "${_rec}" ]] || continue
    _rest="${_rec#*$'\t'}"
    _path="${_rest#*$'\t'}"
    _after["${_path}"]="${_rec%%$'\t'*}${_rest%%$'\t'*}"
  done
  for _path in "${!_after[@]}"; do
    [[ "${_before["${_path}"]:-}" == "${_after["${_path}"]}" ]] && continue
    printf '%s\n' "${_path}"
  done
  for _path in "${!_before[@]}"; do
    [[ -n "${_after["${_path}"]:-}" ]] && continue
    printf '%s\n' "${_path}"
  done
}

# ── reading the run ────────────────────────────────────────────────────────

# _mutation_probe_run <root> <spec-or-empty> <out-file> -- run the suite and
# capture everything it said.
#
# MUTATION_PROBE_RUNNER overrides the command, which is what lets this loop be
# tested without a docker build inside every case. It receives the root and
# the spec (empty for a tier run) as its last two arguments.
#
# The status is KEPT, in _MUTATION_PROBE_RUN_STATUS, and it is not the verdict:
# a red suite exits non-zero and a red suite is the answer this tool is looking
# for. What it answers is whether the run FINISHED. A runner that prints some
# passes and then dies has zero reds over a population that never ran, so
# counting results alone would report a tier-wide green about assertions nobody
# executed -- which is the same unsupported figure as a green over an empty
# population, arriving with a plausible number attached.
#
# The runner goes in the BACKGROUND and is waited on, so its pid is known: a
# signal handler can then stop the suite instead of leaving it running against
# a tree that is about to be restored under it. `exec` in the subshell makes
# that pid the runner's own rather than a shell that would outlive the kill.
_mutation_probe_run() {
  local _root="${1}" _spec="${2}" _out="${3}"
  local -a _cmd=()
  if [[ -n "${MUTATION_PROBE_RUNNER:-}" ]]; then
    read -r -a _cmd <<< "${MUTATION_PROBE_RUNNER}"
    _cmd+=( "${_root}" "${_spec}" )
  elif [[ -n "${_spec}" ]]; then
    _cmd=( "${_root}/script/test/test.sh" --bats-path "${_spec}" )
  else
    _cmd=( "${_root}/script/test/test.sh" --bats-only )
  fi
  # Job control on for the fork, so the child is its own process-group leader
  # and a signal handler can reach the WHOLE suite -- test.sh waits on
  # `docker compose run`, so signalling the shell alone leaves a container
  # running against a tree that is about to be restored under it.
  local _jobctl=0
  case "$-" in *m*) _jobctl=1 ;; esac
  set -m
  (
    cd -- "${_root}" || exit 127
    _mutation_probe_clear_selectors
    exec "${_cmd[@]}"
  ) > "${_out}" 2>&1 &
  _MUTATION_PROBE_RUNNER_PID="$!"
  (( _jobctl )) || set +m
  local _st=0
  wait "${_MUTATION_PROBE_RUNNER_PID}" || _st=$?
  _MUTATION_PROBE_RUNNER_PID=''
  _MUTATION_PROBE_RUN_STATUS="${_st}"
  return 0
}

# _mutation_probe_clear_selectors -- drop every inherited BATS_* variable from
# the runner's environment. Called INSIDE the runner subshell, so the probe's
# own shell keeps whatever it had.
#
# `test.sh --bats-only` is not by itself a whole-tier run: an exported
# BATS_FILE, BATS_FILTER, BATS_UNIT_SHARD, BATS_FRAGILE or BATS_INTEGRATION is
# forwarded into the container and narrows the dispatch, so a green subset
# would be published as `NOT PINNED at scope=tier` -- a claim about sibling
# tests that never ran, which is the one thing this tool exists to stop. The
# PREFIX is the rule rather than that list of five: a sixth selector added to
# the dispatch is cleared here the day it is added.
_mutation_probe_clear_selectors() {
  local -a _vars=()
  local _v
  mapfile -t _vars < <(compgen -v)
  for _v in "${_vars[@]}"; do
    case "${_v}" in
      BATS_*) unset -v "${_v}" 2>/dev/null || true ;;
    esac
  done
}

# _mutation_probe_own_group <pid> -- 0 when <pid> leads its own process group.
#
# Asked before any group signal, because `kill -- -<pid>` against a pid that is
# NOT a group leader addresses whatever group that number names -- which can be
# the probe's own. Read from /proc rather than ps: the comm field can contain
# spaces and parentheses, so the fields are taken after the last `) `, where
# they are state, ppid, pgrp.
_mutation_probe_own_group() {
  local _pid="${1}" _raw _rest _pgrp _ignored
  _raw="$(cat "/proc/${_pid}/stat" 2>/dev/null || printf '')"
  [[ -n "${_raw}" ]] || return 1
  _rest="${_raw##*') '}"
  read -r _ignored _ignored _pgrp _ignored <<< "${_rest}"
  [[ "${_pgrp}" == "${_pid}" ]]
}

# _mutation_probe_stop_runner -- stop the suite and WAIT for it, before any
# restore touches the tree it is reading.
_mutation_probe_stop_runner() {
  local _pid="${_MUTATION_PROBE_RUNNER_PID}"
  [[ -n "${_pid}" ]] || return 0
  _MUTATION_PROBE_RUNNER_PID=''
  if _mutation_probe_own_group "${_pid}"; then
    kill -TERM -- "-${_pid}" 2>/dev/null || true
    wait "${_pid}" 2>/dev/null || true
    # Anything still in the group outlived the leader. A group KILL is bounded
    # and reaches it; on an empty group it fails harmlessly.
    kill -KILL -- "-${_pid}" 2>/dev/null || true
  else
    kill -TERM "${_pid}" 2>/dev/null || true
    wait "${_pid}" 2>/dev/null || true
  fi
  return 0
}

# _mutation_probe_tap_counts <out-file> -- "<ok> <not-ok>" off the TAP stream.
# Read from the FILE rather than through a pipe: an early-closing reader
# strands its writer, which the tree lints against.
_mutation_probe_tap_counts() {
  local _ok _not
  _ok="$(grep -cE '^ok ' -- "${1}" || true)"
  _not="$(grep -cE '^not ok ' -- "${1}" || true)"
  printf '%s %s\n' "${_ok}" "${_not}"
}

# _mutation_probe_witnesses <out-file> -- the `not ok` lines, which are the
# assertions that were pinning the behaviour. The issue asks for these in the
# PR body, so they are printed in full rather than counted.
_mutation_probe_witnesses() {
  grep -E '^not ok ' -- "${1}" || true
}

# ── the loop ───────────────────────────────────────────────────────────────

_mutation_probe_usage() {
  {
    printf 'Usage: mutation-probe.sh [--root <dir>] --subject <path> [--subject <path>]... \\\n'
    printf '                         --mutate <command> [--spec <path>]\n'
    printf '\n'
    printf '  --root     repo root to probe (default: this checkout)\n'
    printf '  --subject  a production file the mutation may touch, root-relative;\n'
    printf '             repeatable, at least one required\n'
    printf '  --mutate   shell command that breaks the behaviour, run with the\n'
    printf '             root as its working directory\n'
    printf '  --spec     narrow the run to one spec. A green then reports\n'
    printf '             INCONCLUSIVE, not NOT PINNED\n'
  } >&2
}

# _mutation_probe <root> [--subject <path>]... --mutate <command> [--spec <path>]
#
# The whole loop. See the file header for why each refusal is a refusal.
_mutation_probe() {
  local _root_arg="${1:-}"
  [[ $# -gt 0 ]] && shift

  local _root
  if ! _root="$(cd -- "${_root_arg}" 2>/dev/null && pwd -P)"; then
    _mutation_probe_err "root '${_root_arg}' does not exist or is not a directory -- nothing would be recorded, so nothing could be restored."
    return 3
  fi

  local -a _subjects=()
  local _mutate='' _spec=''
  while (( $# > 0 )); do
    case "${1}" in
      --subject|--mutate|--spec)
        if (( $# < 2 )); then
          _mutation_probe_err "${1} needs a value."
          return 3
        fi
        case "${1}" in
          --subject) _subjects+=( "${2}" ) ;;
          --mutate) _mutate="${2}" ;;
          --spec) _spec="${2}" ;;
        esac
        shift 2
        ;;
      *)
        _mutation_probe_err "unknown argument '${1}'."
        return 3
        ;;
    esac
  done

  # git is the leak check. Without a work tree there is no before/after
  # comparison, and the one control standing between this tool and a
  # half-mutated checkout would be silently absent.
  if ! git -C "${_root}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    _mutation_probe_err "root '${_root}' is not a git work tree. The probe compares the tree before and after the mutation to catch a mutation that touched a file it did not declare, and git is what answers that."
    return 3
  fi

  if (( ${#_subjects[@]} == 0 )); then
    _mutation_probe_err "no --subject declared. A subject is what gets recorded and restored, and what the leak check is measured against."
    return 3
  fi

  local _s
  for _s in "${_subjects[@]}"; do
    if [[ ! -f "${_root}/${_s}" ]]; then
      _mutation_probe_err "subject '${_s}' is not a regular file under ${_root} -- a probe of a file that is not there measures nothing. Check whether the path moved."
      return 3
    fi
    # A SYMLINK passes the -f test above, and that is the trap. `cp -p` would
    # record the TARGET's bytes, an in-place editor replaces the link with a
    # regular file, and the restore then writes a regular file whose bytes
    # match -- so verification reports success over a tree git calls `T`. This
    # repo ships such links (script/build.sh among them). Refusing and naming
    # the target is also the better interface: the behaviour lives in the
    # target, which is what the caller meant.
    if [[ -L "${_root}/${_s}" ]]; then
      _mutation_probe_err "subject '${_s}' is a symlink to '$(readlink -- "${_root}/${_s}")'. Probe the target instead: an in-place editor replaces a link with a regular file, and a restore that puts the bytes back would leave a file where a link was, which this script would report as restored. The behaviour you mean to break lives in the target."
      return 3
    fi
  done

  if [[ -z "${_mutate}" ]]; then
    _mutation_probe_err "no --mutate command. Without one this is just the suite, which was already green, and reporting that as a probe result certifies every test on no evidence."
    return 3
  fi

  local _scope='tier'
  [[ -n "${_spec}" ]] && _scope="spec:${_spec}"

  local _work
  _work="$(mktemp -d)" || return 3
  local _rec="${_work}/record"
  mkdir -p "${_rec}"

  if ! _mutation_probe_record "${_rec}" "${_root}" "${_subjects[@]}"; then
    _mutation_probe_err "could not record the originals of ${_subjects[*]} -- refusing to mutate a tree it cannot put back."
    rm -rf "${_work}"
    return 3
  fi

  _MUTATION_PROBE_RECORD_DIR="${_rec}"
  _MUTATION_PROBE_ROOT="${_root}"
  _MUTATION_PROBE_SUBJECTS=( "${_subjects[@]}" )
  trap _mutation_probe_emergency_restore EXIT
  trap _mutation_probe_signal_restore INT TERM

  _mutation_probe_say "subjects=${_subjects[*]} scope=${_scope}"
  _mutation_probe_say "mutation=${_mutate}"

  _mutation_probe_tree_state "${_root}" "${_work}/before"
  ( cd -- "${_root}" && eval "${_mutate}" ) || true
  _mutation_probe_tree_state "${_root}" "${_work}/after"

  # _probe_put_back -- stop the runner if it is still up, restore, and PROVE
  # the restoration. 0 when the tree is back, 3 when it is not.
  #
  # It returns only those two, and never a verdict code, because the caller has
  # to be able to tell "the tree is back" from "the measurement says 1". The
  # earlier shape folded the two together and then discarded the result with an
  # unconditional `return`, so a red run whose restore had failed reported
  # PINNED and exit 0 with the mutation still in the tree.
  _probe_put_back() {
    trap - EXIT INT TERM
    _mutation_probe_stop_runner
    if ! _mutation_probe_restore "${_rec}" "${_root}" "${_subjects[@]}"; then
      _mutation_probe_err "the restore itself failed. The recorded originals are kept in ${_rec} -- copy them back before anything else reads this checkout."
      return 3
    fi
    if ! _mutation_probe_verify_restored "${_rec}" "${_root}" "${_subjects[@]}"; then
      _mutation_probe_err "the recorded originals are kept in ${_rec} -- copy them back before anything else reads this checkout."
      return 3
    fi
    _MUTATION_PROBE_RECORD_DIR=''
    _MUTATION_PROBE_SUBJECTS=()
    rm -rf "${_work}"
    return 0
  }

  # _probe_refuse <message> -- put the tree back, then say why there is no
  # verdict. Always 3: a refusal whose restore also failed is still a refusal,
  # and both diagnostics are printed.
  _probe_refuse() {
    _probe_put_back || true
    _mutation_probe_err "${1}"
    return 3
  }

  local -a _changed=()
  mapfile -t _changed < <(_mutation_probe_changed_paths \
    "${_work}/before" "${_work}/after")

  local -a _undeclared=()
  local _path _declared
  for _path in "${_changed[@]}"; do
    _declared=0
    for _s in "${_subjects[@]}"; do
      [[ "${_path}" == "${_s}" ]] && _declared=1
    done
    (( _declared )) || _undeclared+=( "${_path}" )
  done
  if (( ${#_undeclared[@]} > 0 )); then
    _probe_refuse "the mutation touched ${_undeclared[*]}, which it did not declare as a subject. Only declared subjects were recorded, so that edit is one this script cannot undo -- declare it with --subject, or narrow the mutation. The declared subjects have been restored."
    return 3
  fi

  local _moved=0
  for _s in "${_subjects[@]}"; do
    cmp -s -- "${_rec}/${_s}" "${_root}/${_s}" || _moved=1
  done
  if (( _moved == 0 )); then
    _probe_refuse "the mutation left every subject byte-identical. The tree the suite would pass over is the tree it already passed over, so the green would be the baseline and not a measurement. Check the mutation command."
    return 3
  fi

  _mutation_probe_run "${_root}" "${_spec}" "${_work}/run"

  local _counts _ok _not
  _counts="$(_mutation_probe_tap_counts "${_work}/run")"
  _ok="${_counts%% *}"
  _not="${_counts##* }"

  if (( _ok + _not == 0 )); then
    _probe_refuse "the run reported no test results at all. Zero reds is the number a fully behavioural suite prints too, so this cannot be read as a verdict about the tests -- it is a broken runner. Its output: $(cat "${_work}/run")"
    return 3
  fi

  # A non-zero runner status with no reds means the run DID NOT FINISH. With
  # reds it means exactly what it should: a failing suite exits non-zero, and
  # that is the answer this tool wants.
  if (( _not == 0 && _MUTATION_PROBE_RUN_STATUS != 0 )); then
    _probe_refuse "the runner did not finish: ${_ok} ok / 0 not ok and then exit ${_MUTATION_PROBE_RUN_STATUS}. Zero reds over a population that never ran is not a green -- it is the same unsupported figure as a run with no results, wearing a plausible number. Fix the runner and probe again."
    return 3
  fi

  # The verdict is COMPOSED here and published after the tree is proven back.
  # Printing it first would hand the reader a verdict that a restoration
  # failure then contradicts, and the failure is the more important news.
  local _code=0
  local -a _verdict=()
  if (( _not > 0 )); then
    _code=0
    _verdict=( "PINNED. The assertions that noticed, at scope=${_scope}:" )
    local -a _witnesses=()
    mapfile -t _witnesses < <(_mutation_probe_witnesses "${_work}/run")
    _verdict+=( "${_witnesses[@]+"${_witnesses[@]}"}" )
  elif [[ -n "${_spec}" ]]; then
    _code=2
    _verdict=( "INCONCLUSIVE at scope=${_scope}. That spec does not pin the behaviour; the suite may still. Measured on base#1108, five of six per-file greens had their failing witness in a sibling spec from the same PR -- re-run without --spec and then ask which spec should have been the one to notice." )
  else
    _code=1
    _verdict=( "NOT PINNED at scope=${_scope}. The behaviour can be wrong and ${_ok} assertions still pass. Nothing in the tier observed it." )
  fi

  _probe_put_back || return 3

  _mutation_probe_say "${_ok} ok / ${_not} not ok at scope=${_scope}"
  # The verdict carries the report prefix; the witness lines below it stay raw
  # TAP, so `grep "^not ok "` over this output still finds them.
  _mutation_probe_say "${_verdict[0]}"
  local _i
  for (( _i = 1; _i < ${#_verdict[@]}; _i++ )); do
    printf '%s\n' "${_verdict[_i]}"
  done
  return "${_code}"
}

main() {
  local _root=''
  local -a _rest=()
  while (( $# > 0 )); do
    case "${1}" in
      -h|--help)
        _mutation_probe_usage
        return 0
        ;;
      --root)
        if (( $# < 2 )); then
          _mutation_probe_err "--root needs a value."
          return 3
        fi
        _root="${2}"
        shift 2
        ;;
      *)
        _rest+=( "${1}" )
        shift
        ;;
    esac
  done
  if [[ -z "${_root}" ]]; then
    _root="$(cd -- "${_MUTATION_PROBE_DIR}/../.." && pwd -P)"
  fi
  _mutation_probe "${_root}" "${_rest[@]+"${_rest[@]}"}"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
