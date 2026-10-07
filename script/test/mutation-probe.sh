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
# ── Five measurements that must not be read as verdicts ────────────────────
#
# base#1089's rule, applied to a probe instead of a gate: every no-evidence
# state is refused by name.
#
#   - A mutation that left every declared subject byte-identical. The tree the
#     suite then passes over is the tree it already passed over, so the green
#     is the baseline. Read as a verdict it certifies a test as behavioural on
#     the strength of a sed expression that matched nothing.
#   - A run that EXECUTED no tests at all. Zero reds is the number a fully
#     behavioural suite prints too, so reading it as NOT PINNED turns a broken
#     runner into a finding about the tests. A skip is not an execution: bats
#     reports one as `ok N name # skip ...`, and counting it lets a mutation
#     erase the evidence against itself and still look measured.
#   - A run that reported SOME passes and then died. Same hole, arriving with a
#     plausible number attached: zero reds over a population that never ran.
#     The runner's exit status is what tells the two apart, so it is kept.
#   - A green that executed FEWER assertions than the baseline. A mutation can
#     remove the assertions that would have observed it -- deleting a dispatch
#     from a driver is the obvious case -- and the run then exits 0 with fewer
#     tests and nothing red.
#   - A narrow green, per the scope section above.
#
# A RED is held to none of them: something observed the wrong answer, which
# stands however much else ran.
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

# The pid of whichever child is running right now -- the mutation command or
# the suite -- and the status the last run exited with. The pid is what a
# signal handler needs in order to STOP that child rather than leave it
# working against a tree that is about to be restored under it, and BOTH
# children go through it because both can hang: a mutation that sleeps blocks
# the handler just as a suite that sleeps does.
_MUTATION_PROBE_CHILD_PID=''
_MUTATION_PROBE_RUN_STATUS=0

# The checkout root's identity, recorded before anything is touched: the
# originals belong to THAT directory, and a restore into a different one is
# not a restore.
_MUTATION_PROBE_ROOT_ID=''

# Whether the run went through the BUILT-IN runner. Only then is there a
# compose project for the daemon question below to be about.
_MUTATION_PROBE_DEFAULT_RUNNER=0

# Seconds a runner is given to come down after a TERM before the group is
# KILLed. Overridable so the case that pins the bound does not spend the
# default on every run.
: "${_MUTATION_PROBE_SHUTDOWN_GRACE:=5}"

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
# _mutation_probe_root_id <root> -- the root's device and inode, or empty.
_mutation_probe_root_id() {
  stat -c '%d:%i' -- "${1}" 2>/dev/null || printf ''
}

# _mutation_probe_root_ok <root> -- 0 when <root> is still the very directory
# the originals were recorded from.
#
# The ancestor walk starts BELOW the root, so it cannot see the root itself
# being swapped: `mv tree tree-saved; ln -s outside tree` left every later
# check passing while every write landed in `outside`. Identity, not the path
# string, because the path is exactly what such a swap keeps.
_mutation_probe_root_ok() {
  local _root="${1}"
  [[ -n "${_MUTATION_PROBE_ROOT_ID}" ]] || return 0
  [[ -L "${_root}" ]] && return 1
  [[ -d "${_root}" ]] || return 1
  [[ "$(_mutation_probe_root_id "${_root}")" == "${_MUTATION_PROBE_ROOT_ID}" ]]
}

# _mutation_probe_bad_ancestor <root> <subject> -- print the first ancestor of
# <subject> that is not a plain directory under <root>, and return 0; return 1
# when every ancestor is one. The CALLERS phrase the message, because the same
# fact means two different things at the two places it is asked.
#
# Removing the final component before a copy is one directory short. If a parent
# is a symlink -- `rm -rf dir; ln -s ../outside dir` -- both the `rm` and the
# `cp` resolve THROUGH it and act on a file outside the tree, so the restore
# destroys an unrelated file and then reports success.
#
# The same question has to be asked when the subject is DECLARED, and for the
# mirror-image reason: a subject reached through a link can be recorded and
# mutated, and then the restore correctly refuses to traverse that ancestor --
# leaving the subject mutated, which is the one outcome this tool must not have.
# Refusing it up front is what keeps the two answers consistent.
_mutation_probe_bad_ancestor() {
  local _root="${1}" _prefix='' _seg
  local _rest="${2}"
  while [[ "${_rest}" == */* ]]; do
    _seg="${_rest%%/*}"
    _rest="${_rest#*/}"
    _prefix="${_prefix:+${_prefix}/}${_seg}"
    if [[ -L "${_root}/${_prefix}" ]] \
      || { [[ -e "${_root}/${_prefix}" ]] && [[ ! -d "${_root}/${_prefix}" ]]; }
    then
      printf '%s\n' "${_prefix}"
      return 0
    fi
  done
  return 1
}

_mutation_probe_restore() {
  local _rec="${1}" _root="${2}"
  shift 2
  if ! _mutation_probe_root_ok "${_root}"; then
    _mutation_probe_err "will not restore anything: ${_root} is no longer the directory the originals were recorded from. Every write would land somewhere else under the same path."
    return 1
  fi
  local _s _rc=0
  for _s in "$@"; do
    local _bad
    if _bad="$(_mutation_probe_bad_ancestor "${_root}" "${_s}")"; then
      _mutation_probe_err "will not restore ${_s}: its ancestor '${_bad}' is no longer a plain directory, so a write there would land outside the path the original was recorded from."
      _rc=1
      continue
    fi
    # The destination is REMOVED first, and that is not tidiness. `cp` follows
    # a destination symlink and writes through it, so a mutation that replaced
    # the subject with a link -- `unlink x; ln -s bystander x` -- would have
    # the restore overwrite the LINK'S TARGET with the recorded bytes: an
    # undeclared file destroyed by the step whose whole job is to put things
    # back. Removing first also covers a subject replaced by a directory.
    # `:?` on both halves, not a style note: an empty root or an empty subject
    # would make this `rm -rf -- /`, and a tool whose contract is that it cannot
    # damage the tree does not get to rely on its callers for that.
    if [[ -e "${_root}/${_s}" || -L "${_root}/${_s}" ]]; then
      rm -rf -- "${_root:?}/${_s:?}" || _rc=1
    fi
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
  _mutation_probe_stop_child
  _mutation_probe_await_daemon "${_MUTATION_PROBE_ROOT}" || true
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
# The FINGERPRINT is what makes the comparison a comparison, and the POPULATION
# is what makes it complete. Both took three attempts, so both are argued here.
#
# A status code alone answers only whether a file is dirty, and a file that was
# ALREADY dirty stays ` M` through a second edit -- so a code-only snapshot
# reported no change, the suite ran, and the undeclared edit was left behind
# with nothing said. Type, MODE and link target are in the fingerprint as well
# as the bytes, because git's status does not move for every change that
# matters either: a `chmod +x` on an already-dirty file leaves both the code and
# the hash where they were.
#
# And the dirty set is not the population. `chmod 600` on a CLEAN tracked file
# is invisible to `git status` -- git records only the executable bit -- and an
# IGNORED file is invisible to it by definition, which matters here because the
# files this repo ignores include the generated config (`.env`,
# `.setup.conf.local`) that the suite being measured reads. So the population is
# every tracked path plus everything git reports as untracked or ignored, and
# each one is fingerprinted.
#
# That is 480-odd paths on this tree, twice, and it is measured in seconds
# against a probe that runs the suite twice. Nothing outside the checkout is
# covered, and no snapshot of a checkout could be: a mutation command is
# arbitrary shell.
_mutation_probe_fingerprint() {
  local _p="${1}" _hash
  if [[ -L "${_p}" ]]; then
    printf 'L:%s' "$(readlink -- "${_p}" 2>/dev/null || printf '?')"
  elif [[ -d "${_p}" ]]; then
    printf 'D:%s' "$(stat -c '%a' -- "${_p}" 2>/dev/null || printf '?')"
  elif [[ -f "${_p}" ]]; then
    _hash="$(sha256sum -- "${_p}" 2>/dev/null || printf '? ')"
    printf 'F:%s:%s' "$(stat -c '%a' -- "${_p}" 2>/dev/null || printf '?')" \
      "${_hash%% *}"
  else
    printf 'X:absent'
  fi
}

_mutation_probe_tree_state() {
  local _root="${1}" _out="${2}"
  local -A _paths=()
  local -a _records=()
  local _rec _path
  : > "${_out}"
  mapfile -d '' -t _records < <(git -C "${_root}" ls-files -z 2>/dev/null)
  for _rec in "${_records[@]}"; do
    [[ -n "${_rec}" ]] && _paths["${_rec}"]=1
  done
  _records=()
  mapfile -d '' -t _records < <(git -C "${_root}" status --porcelain -z \
    --untracked-files=all --ignored=matching --no-renames 2>/dev/null)
  for _rec in "${_records[@]}"; do
    [[ ${#_rec} -gt 3 ]] || continue
    _paths["${_rec:3}"]=1
  done
  # An ignore pattern that names a DIRECTORY (`coverage/`, `log/`) is reported
  # by git as that directory, not as its contents, and a directory's
  # fingerprint is only its mode -- so editing a file inside one was invisible.
  # Expanded here rather than asked of git, which has no mode that lists them.
  local -a _dirs=()
  for _path in "${!_paths[@]}"; do
    if [[ -d "${_root}/${_path}" ]] && [[ ! -L "${_root}/${_path}" ]]; then
      _dirs+=( "${_path}" )
    fi
  done
  for _path in "${_dirs[@]+"${_dirs[@]}"}"; do
    _records=()
    mapfile -d '' -t _records \
      < <(find "${_root}/${_path%/}" -mindepth 1 -print0 2>/dev/null)
    for _rec in "${_records[@]}"; do
      [[ -n "${_rec}" ]] && _paths["${_rec#"${_root}/"}"]=1
    done
  done
  for _path in "${!_paths[@]}"; do
    printf '%s\t%s\0' \
      "$(_mutation_probe_fingerprint "${_root}/${_path}")" "${_path}" \
      >> "${_out}"
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
  local _rec _path
  # The fingerprint is taken off the FRONT and the path is whatever is left, so
  # a path carrying a tab stays whole: a fingerprint cannot contain one.
  mapfile -d '' -t _records < "${1}"
  for _rec in "${_records[@]}"; do
    [[ -n "${_rec}" ]] || continue
    _before["${_rec#*$'\t'}"]="${_rec%%$'\t'*}"
  done
  _records=()
  mapfile -d '' -t _records < "${2}"
  for _rec in "${_records[@]}"; do
    [[ -n "${_rec}" ]] || continue
    _after["${_rec#*$'\t'}"]="${_rec%%$'\t'*}"
  done
  # NUL-terminated, like the snapshots it reads. A newline-delimited list is
  # read back by `mapfile` as several paths, and the pieces of a file named
  # `a.sh<newline>b.sh` are two paths that may BOTH be declared subjects -- so
  # the undeclared edit reads as two declared ones and the leak check waves it
  # through.
  for _path in "${!_after[@]}"; do
    [[ "${_before["${_path}"]:-}" == "${_after["${_path}"]}" ]] && continue
    printf '%s\0' "${_path}"
  done
  for _path in "${!_before[@]}"; do
    [[ -n "${_after["${_path}"]:-}" ]] && continue
    printf '%s\0' "${_path}"
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
  else
    _MUTATION_PROBE_DEFAULT_RUNNER=1
    if [[ -n "${_spec}" ]]; then
      _cmd=( "${_root}/script/test/test.sh" --bats-path "${_spec}" )
    else
      _cmd=( "${_root}/script/test/test.sh" --bats-only )
    fi
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
  _MUTATION_PROBE_CHILD_PID="$!"
  (( _jobctl )) || set +m
  local _st=0
  wait "${_MUTATION_PROBE_CHILD_PID}" || _st=$?
  _MUTATION_PROBE_CHILD_PID=''
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

# _mutation_probe_await_daemon <root> -- wait until the daemon has let go of
# this checkout's compose project, so nothing is writing into the tree the
# restore is about to rewrite.
#
# Killing the child's process group is not enough when the suite runs in a
# container: `docker compose run` starts a container that belongs to the
# DAEMON, not to any process group this script can signal, and it keeps the
# checkout bind-mounted. So a probe that restored right after the kill could
# have its restored files overwritten by a container nobody was waiting on.
#
# The question is asked with the runner's own primitive rather than with
# compose knowledge copied in here: `test.sh --await-project` waits for the
# project network to be released and, when it is not, refuses by naming the
# container and the verb that clears it. Only asked when the BUILT-IN runner
# ran, because a caller-supplied runner has no project this could be about.
_mutation_probe_await_daemon() {
  (( _MUTATION_PROBE_DEFAULT_RUNNER )) || return 0
  "${1}/script/test/test.sh" --await-project
}

# _mutation_probe_stop_child -- stop the suite and WAIT for it, before any
# restore touches the tree it is reading.
_mutation_probe_stop_child() {
  local _pid="${_MUTATION_PROBE_CHILD_PID}"
  [[ -n "${_pid}" ]] || return 0
  _MUTATION_PROBE_CHILD_PID=''
  # The wait is BOUNDED by a watchdog, because a plain `wait` after a TERM
  # never returns for a runner that ignores the signal or hangs in its own
  # shutdown handler -- and the probe would then sit there with the tree still
  # mutated, which is the worst of both outcomes. A `kill -0` poll cannot
  # substitute: an exited child this shell has not reaped is a zombie and still
  # answers to it.
  local _group=0
  _mutation_probe_own_group "${_pid}" && _group=1
  if (( _group )); then
    kill -TERM -- "-${_pid}" 2>/dev/null || true
  else
    kill -TERM "${_pid}" 2>/dev/null || true
  fi
  local _watchdog
  if (( _group )); then
    ( sleep "${_MUTATION_PROBE_SHUTDOWN_GRACE}"
      kill -KILL -- "-${_pid}" 2>/dev/null || true ) &
  else
    ( sleep "${_MUTATION_PROBE_SHUTDOWN_GRACE}"
      kill -KILL "${_pid}" 2>/dev/null || true ) &
  fi
  _watchdog="$!"
  wait "${_pid}" 2>/dev/null || true
  kill -TERM "${_watchdog}" 2>/dev/null || true
  wait "${_watchdog}" 2>/dev/null || true
  # Anything still in the group outlived the leader. A group KILL is bounded
  # and reaches it; on an empty group it fails harmlessly.
  (( _group )) && { kill -KILL -- "-${_pid}" 2>/dev/null || true; }
  return 0
}

# _mutation_probe_apply <root> <mutate> -- run the mutation command as a
# tracked child in its own process group.
#
# Not a foreground subshell. Bash defers a trap until the foreground command
# finishes, so a mutation that hangs -- `printf wrong > subject.sh; sleep 60`
# -- held the handler off while the subject sat mutated, and its pid was
# recorded nowhere so nothing could stop it. It goes through the same global
# and the same bounded stop as the suite, because both children can hang for
# the same reasons.
_mutation_probe_apply() {
  local _root="${1}" _mutate="${2}"
  local _jobctl=0
  case "$-" in *m*) _jobctl=1 ;; esac
  set -m
  ( cd -- "${_root}" || exit 127
    eval "${_mutate}" ) &
  _MUTATION_PROBE_CHILD_PID="$!"
  (( _jobctl )) || set +m
  wait "${_MUTATION_PROBE_CHILD_PID}" 2>/dev/null || true
  _MUTATION_PROBE_CHILD_PID=''
  return 0
}

# _mutation_probe_tap_counts <out-file> -- "<executed-ok> <not-ok> <skipped>"
# off the TAP stream. Read from the FILE rather than through a pipe: an
# early-closing reader strands its writer, which the tree lints against.
#
# A SKIP is reported by bats as `ok N name # skip <reason>`, and counting it as
# a pass is how a mutation can erase the evidence against it and still look
# measured: a subject the spec can no longer find turns its cases into skips,
# and a run of nothing-but-skips read as 1 ok / 0 not ok slipped past both the
# no-evidence refusal and the population comparison. Executed means ran.
_mutation_probe_tap_counts() {
  local _ok _not _skip
  _ok="$(grep -cE '^ok ' -- "${1}" || true)"
  _not="$(grep -cE '^not ok ' -- "${1}" || true)"
  _skip="$(grep -ciE '^ok .*#[[:space:]]*skip' -- "${1}" || true)"
  printf '%s %s %s\n' "$(( _ok - _skip ))" "${_not}" "${_skip}"
}

# _mutation_probe_witnesses <out-file> -- the `not ok` lines, which are the
# assertions that were pinning the behaviour. The issue asks for these in the
# PR body, so they are printed in full rather than counted.
_mutation_probe_witnesses() {
  grep -E '^not ok ' -- "${1}" || true
}

# _mutation_probe_normalise <path> -- print <path> as git would spell it,
# relative to the root; fail when it is not a path inside the root.
#
# `--subject ./subject.sh` is a valid thing to type and was accepted, recorded
# and then refused as an UNDECLARED edit, because git reports the changed path
# as `subject.sh` and the comparison is string equality. The declaration and
# git's answer have to be spelled the same way, so the declaration is
# normalised rather than the comparison loosened -- a looser comparison would
# also start matching paths that merely look alike.
_mutation_probe_normalise() {
  local _p="${1}"
  if [[ "${_p}" == /* ]]; then
    _mutation_probe_err "subject '${_p}' is absolute. Subjects are root-relative, so that the path recorded is the path git reports."
    return 1
  fi
  while [[ "${_p}" == *//* ]]; do _p="${_p//\/\//\/}"; done
  while [[ "${_p}" == ./* ]]; do _p="${_p#./}"; done
  while [[ "${_p}" == */./* ]]; do _p="${_p//\/.\//\/}"; done
  _p="${_p%/}"
  _p="${_p%/.}"
  case "${_p}" in
    ..|../*|*/../*|*/..)
      _mutation_probe_err "subject '${1}' walks out of the root with '..'. A subject outside the tree is one the leak check cannot see and the restore has no business writing to."
      return 1
      ;;
  esac
  if [[ -z "${_p}" ]]; then
    _mutation_probe_err "subject '${1}' names no path."
    return 1
  fi
  printf '%s\n' "${_p}"
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

  _MUTATION_PROBE_ROOT_ID="$(_mutation_probe_root_id "${_root}")"

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

  # Normalised BEFORE anything else reads them, so the path recorded, the path
  # restored and the path git reports are one spelling.
  local -a _normalised=()
  local _n
  for _n in "${_subjects[@]+"${_subjects[@]}"}"; do
    _n="$(_mutation_probe_normalise "${_n}")" || return 3
    _normalised+=( "${_n}" )
  done
  _subjects=( "${_normalised[@]+"${_normalised[@]}"}" )

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
    local _bad_ancestor
    if _bad_ancestor="$(_mutation_probe_bad_ancestor "${_root}" "${_s}")"; then
      _mutation_probe_err "subject '${_s}' is reached through '${_bad_ancestor}', which is not a plain directory. Such a subject can be recorded and mutated and then NOT restored, because the restore refuses to write through a changed ancestor -- so it is refused here instead, where nothing has been touched yet."
      return 3
    fi
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

  # ── the BASELINE, which is what makes a red attributable ────────────────
  #
  # Running only the mutated tree cannot establish that anything TURNED red. On
  # a checkout that already has a failing test, every mutation reports PINNED
  # and names that pre-existing failure as its witness -- a confident answer
  # about an assertion that never looked at the subject. And a dirty checkout
  # is the normal case for this tool, because it is reached mid-change.
  #
  # So the scope is run first, unmutated, and a baseline that is not clean is
  # REFUSED rather than subtracted. Subtracting would let the probe report on a
  # suite whose failures nobody has explained, and the whole method presumes
  # the suite was green before the behaviour was broken. The cost is two runs
  # per probe rather than one, and that is stated rather than rounded down.
  # Armed BEFORE the baseline, not after it. The runner is forked into its own
  # process group, so an interrupt that arrives while the BASELINE is running
  # would kill the probe and leave that group -- a docker compose run, in the
  # real case -- alive with nobody waiting on it. There is nothing to restore
  # yet, and the handler knows that: with no record taken it stops the runner
  # and exits.
  _MUTATION_PROBE_ROOT="${_root}"
  trap _mutation_probe_emergency_restore EXIT
  trap _mutation_probe_signal_restore INT TERM

  _mutation_probe_say "baseline: running scope=${_scope} unmutated"
  _mutation_probe_run "${_root}" "${_spec}" "${_work}/baseline"
  local _base_ok _base_not _base_skip
  read -r _base_ok _base_not _base_skip \
    < <(_mutation_probe_tap_counts "${_work}/baseline")
  if (( _base_ok + _base_not == 0 )); then
    _mutation_probe_err "the baseline run reported no test results at all, so there is nothing to compare a mutated run against. Its output: $(cat "${_work}/baseline")"
    trap - EXIT INT TERM
    rm -rf "${_work}"
    return 3
  fi
  if (( _base_not > 0 )); then
    _mutation_probe_err "the baseline is already red: ${_base_ok} ok / ${_base_not} not ok at scope=${_scope}, before any mutation. A red under the mutation could not be attributed to it, so there is no verdict to give. Get the scope green first, or narrow it with --spec. The reds: $(_mutation_probe_witnesses "${_work}/baseline")"
    trap - EXIT INT TERM
    rm -rf "${_work}"
    return 3
  fi
  if (( _MUTATION_PROBE_RUN_STATUS != 0 )); then
    _mutation_probe_err "the baseline runner did not finish: ${_base_ok} ok / 0 not ok and then exit ${_MUTATION_PROBE_RUN_STATUS}. A baseline over a population that never ran is not a baseline."
    trap - EXIT INT TERM
    rm -rf "${_work}"
    return 3
  fi
  _mutation_probe_say "baseline: ${_base_ok} executed / 0 not ok / ${_base_skip} skipped -- clean, so a red below is the mutation's"

  if ! _mutation_probe_record "${_rec}" "${_root}" "${_subjects[@]}"; then
    _mutation_probe_err "could not record the originals of ${_subjects[*]} -- refusing to mutate a tree it cannot put back."
    trap - EXIT INT TERM
    rm -rf "${_work}"
    return 3
  fi

  _MUTATION_PROBE_RECORD_DIR="${_rec}"
  _MUTATION_PROBE_SUBJECTS=( "${_subjects[@]}" )

  _mutation_probe_say "subjects=${_subjects[*]} scope=${_scope}"
  _mutation_probe_say "mutation=${_mutate}"

  _mutation_probe_tree_state "${_root}" "${_work}/before"
  _mutation_probe_apply "${_root}" "${_mutate}"
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
    _mutation_probe_stop_child
    local _held=0
    _mutation_probe_await_daemon "${_root}" || _held=1
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
    if (( _held )); then
      _mutation_probe_err "a container was still holding this checkout when the subjects were restored -- the refusal above names it and the verb that clears it. The tree HAS been restored and verified, but a container with the checkout bind-mounted can write to it afterwards: clear it, then check git status."
      return 3
    fi
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
  mapfile -d '' -t _changed < <(_mutation_probe_changed_paths \
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

  local _ok _not _skip
  read -r _ok _not _skip < <(_mutation_probe_tap_counts "${_work}/run")

  if (( _ok + _not == 0 )); then
    _probe_refuse "the run executed no tests at all (${_skip} skipped). Zero reds is the number a fully behavioural suite prints too, so this cannot be read as a verdict about the tests -- it is a broken runner. Its output: $(cat "${_work}/run")"
    return 3
  fi

  # A green over a SMALLER population is not the same measurement. A mutation
  # can remove the assertions that would have observed it -- deleting a
  # dispatch from a driver is the obvious case, and probing the test tooling is
  # one of the things this is for -- and the run then exits 0 with fewer tests
  # and nothing red. Compared against the baseline's count rather than against
  # a number kept here. A RED is not held to this: something observed the wrong
  # answer, which stands however much else ran.
  if (( _not == 0 && _ok < _base_ok )); then
    _probe_refuse "the mutated run executed ${_ok} assertions where the baseline ran ${_base_ok}. A green over a smaller population is not the same measurement -- the mutation removed assertions rather than being observed by them. Check what the mutation did to the test dispatch."
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

  _mutation_probe_say "${_ok} executed / ${_not} not ok / ${_skip} skipped at scope=${_scope}"
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
