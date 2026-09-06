#!/usr/bin/env bash
# drivers/spec_repo_root.sh - "a spec's REPO_ROOT is a fixture, never the
# live checkout" per-tool driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh and drivers/bats.sh, so the _log_* / _die helpers and the
# coverage suite's pool list are available. Provides _run_spec_repo_root.
#
# Contract: runs INSIDE the ci (test-tools) container where test.sh
# invokes it. References ${REPO_ROOT} (a global exported by test.sh).
# Follows drivers/i18n_orphan.sh conventions (sourced lib, uses
# ${REPO_ROOT}, _log_* / _die, no main).
#
# ── What it refuses, and why the cost is the point ──────────────────────────
#
# Every lint driver in this tree takes ONE input that decides how much work
# it does: ${REPO_ROOT}, the tree it walks. A spec that sets that to the
# live checkout does not test the driver -- it runs the LINT, inside the
# coverage suite, under kcov.
#
# base#1075 measured what that costs. In CI run 33977704286 one such case,
# `_run_errexit_bang: the real bats tree is clean`, took 330783 ms of a
# 501s coverage shard against a 211s median: 66% of the critical path of
# the whole coverage matrix, in one test. A test is the atom the partition
# cannot split, so no shard count helps -- 8 to 12 shards moved the run's
# wall clock 594s to 529s and the slowest shard 513s to 501s. The same
# assertion also ran in its own `lint-static` job at 77s, where kcov is not
# in the loop and nothing else waits on it.
#
# So the rule is a placement rule, not a coverage one: the coverage suite
# tests a driver against FIXTURES, and the lint jobs test the tree. The
# driver's own behaviour -- what it flags, what it ignores, how it reports
# -- is asserted by the cheap fixture cases beside the one this refuses,
# and base#1075 measured that removing the real-tree cases from all
# twenty-one of them changed the covered-line set of the suite by nothing
# at all.
#
# ── Why this is derived and not a list ─────────────────────────────────────
#
# The obvious spelling is a roster of the known offenders. That roster is
# correct the day it is written and wrong the day the next expensive driver
# is added, and nothing notices -- this repo has decayed that way three
# times (the _LINT_TOOLS completeness gap, the downstream roster, the
# release archive's path list). Nothing here is enumerated:
#
#   - the FILES come from _COVERAGE_FULL_SUITE_POOLS (drivers/bats.sh),
#     the one definition of what the coverage suite runs. A pool added
#     there is scanned here the same day.
#   - the REFUSED ROOTS come from compose.yaml's bind target for the
#     checkout plus the live ${REPO_ROOT} this run is reading -- so the
#     path is never written down here, and a compose file that stops
#     mounting the checkout fails the lint instead of emptying it.
#   - the ASSIGNMENTS come from the shape `<name>REPO_ROOT=<value>`, which
#     is what a spec has to write to point a driver anywhere. PIN_REPO_ROOT
#     (script/watch/pins.sh) matches the same shape for the same reason.
#
# ── Non-vacuity ────────────────────────────────────────────────────────────
#
# Three ways this could go green having checked nothing, each a _die: a
# pool that resolves to no directory, a scan that finds no spec file, and a
# scan that finds no `*REPO_ROOT=` assignment ANYWHERE. The third is the
# one that matters: ~40 fixture-rooted assignments exist today, so zero
# means the detector has gone blind (a renamed variable, a changed quoting
# convention), and a blind detector reports a clean tree.
#
# ── What it does NOT see ───────────────────────────────────────────────────
#
# A spec that reaches the live tree by some other spelling: reading a file
# under the mount directly (`grep ... /source/justfile` -- cheap, common,
# and deliberately allowed), or invoking a tool whose root DEFAULTS to the
# checkout when the variable is unset (script/watch/pins.sh resolves its
# own location's grandparent). The rule is about the one input that makes a
# driver walk a tree, not about every path to the mount; a rule wide enough
# to cover the second would flag the hundreds of cheap single-file reads
# this suite is built out of, which is the noise that gets a lint muted.

# ── The spec REPO_ROOT lint ────────────────────────────────────────────────

# The bind mount declared in compose.yaml. Read, not written down: `/source`
# is compose's target for `.`, and a lint that spelled it here would keep
# agreeing with itself after compose stopped agreeing.
readonly _SPEC_REPO_ROOT_COMPOSE_REL='compose.yaml'

# The live roots, set by _spec_repo_root_live_roots below and read by its
# caller. Meaningless before it has run.
_SPEC_REPO_ROOT_LIVE_ROOTS=()

# _spec_repo_root_live_roots
#
# Fill _SPEC_REPO_ROOT_LIVE_ROOTS with every path that IS the live checkout:
# compose.yaml's bind target(s) for `.`, plus ${REPO_ROOT} itself (which is
# the mount in-container and the worktree path under a host-direct
# `--spec-repo-root-only` run). Dies when compose.yaml declares no such
# mount -- an empty refused set is a lint that passes on everything.
#
# IT WRITES A GLOBAL RATHER THAN PRINTING, and the reason is where a _die
# would land. Read through a process substitution, this function runs in a
# subshell: a _die there kills that subshell alone, the caller sees an
# empty list, and -- if the message went to stdout -- reads the refusal
# ITSELF as a root. test.sh's _refuse_bad_lint_group splits the same way,
# for the same reason. Here the refusal happens in the caller's shell,
# where a refusal is a refusal.
_spec_repo_root_live_roots() {
  _SPEC_REPO_ROOT_LIVE_ROOTS=()
  local _compose="${REPO_ROOT}/${_SPEC_REPO_ROOT_COMPOSE_REL}"
  if [[ ! -f "${_compose}" ]]; then
    _die ci_spec_repo_root \
      "'${_SPEC_REPO_ROOT_COMPOSE_REL}' not found under ${REPO_ROOT} -- the checkout's mount point is unknown, so every root would be accepted."
    return 1
  fi
  local -a _roots=()
  local _target
  while IFS= read -r _target; do
    [[ -n "${_target}" ]] && _roots+=("${_target%/}")
  done < <(awk '
    match($0, /^[[:space:]]*-[[:space:]]*\.:\/[^[:space:]:]+/) {
      s = substr($0, RSTART, RLENGTH)
      sub(/^[[:space:]]*-[[:space:]]*\.:/, "", s)
      print s
    }
  ' "${_compose}" | sort -u)
  if [[ "${#_roots[@]}" -eq 0 ]]; then
    _die ci_spec_repo_root \
      "no '- .:<path>' bind for the checkout in '${_SPEC_REPO_ROOT_COMPOSE_REL}' -- the mount point this lint refuses is unknown, so it would refuse nothing."
    return 1
  fi
  _roots+=("${REPO_ROOT%/}")
  mapfile -t _SPEC_REPO_ROOT_LIVE_ROOTS < <(printf '%s\n' "${_roots[@]}" | sort -u)
}

# _spec_repo_root_scan <file> <root>...
#
# Print one `<file>:<line>: <name>=<value>` record per assignment of a
# `*REPO_ROOT` variable to one of <root>... (or to a path under it), and a
# final `SEEN=<n>` line counting EVERY `*REPO_ROOT=` assignment the file
# carries, violation or not. The count is what the non-vacuity check reads.
#
# Whole-line comments are skipped: this driver's own header, and the prose
# in half the specs, spells the refused form out.
_spec_repo_root_scan() {
  local _file="${1}"; shift
  local _roots
  _roots="$(printf '%s\n' "$@")"
  awk -v ROOTS="${_roots}" -v REL="${_file}" '
    BEGIN { n_roots = split(ROOTS, roots, "\n") }
    /^[[:space:]]*#/ { next }
    {
      line = $0
      while (match(line, /(^|[^A-Za-z0-9_])[A-Za-z0-9_]*REPO_ROOT=/)) {
        tok = substr(line, RSTART, RLENGTH)
        sub(/^[^A-Za-z0-9_]/, "", tok)
        name = tok; sub(/=$/, "", name)
        rest = substr(line, RSTART + RLENGTH)
        line = rest
        seen++
        q = substr(rest, 1, 1)
        if (q == "\"" || q == "\047") {
          v = substr(rest, 2)
          i = index(v, q)
          if (i > 0) v = substr(v, 1, i - 1)
        } else {
          v = rest
          sub(/[[:space:];)].*$/, "", v)
        }
        for (r = 1; r <= n_roots; r++) {
          if (roots[r] == "") continue
          if (v == roots[r] || index(v, roots[r] "/") == 1) {
            printf "%s:%d: %s=%s\n", REL, FNR, name, v
            break
          }
        }
      }
    }
    END { printf "SEEN=%d\n", seen }
  ' "${REPO_ROOT}/${_file}"
}

_run_spec_repo_root() {
  echo "--- Running spec repo-root lint ---"

  # The scan roots ARE the coverage suite. Taking them from the array
  # drivers/bats.sh runs is what keeps the guard's scope equal to the
  # thing it protects; a pool added there needs no edit here.
  if [[ -z "${_COVERAGE_FULL_SUITE_POOLS[*]:-}" ]]; then
    _die ci_spec_repo_root \
      "_COVERAGE_FULL_SUITE_POOLS is unset -- drivers/bats.sh defines the pools the coverage suite runs, and without it this lint does not know what to scan."
    return 1
  fi

  _spec_repo_root_live_roots || return 1
  local -a _roots=("${_SPEC_REPO_ROOT_LIVE_ROOTS[@]}")

  local -a _files=()
  local _pool _file
  for _pool in "${_COVERAGE_FULL_SUITE_POOLS[@]}"; do
    if [[ ! -d "${REPO_ROOT}/${_pool}" ]]; then
      _die ci_spec_repo_root \
        "coverage pool '${_pool}/' not found under ${REPO_ROOT} -- the lint would scan less than the suite runs."
      return 1
    fi
    while IFS= read -r -d '' _file; do
      _files+=("${_file#"${REPO_ROOT}"/}")
    done < <(find "${REPO_ROOT}/${_pool}" -type f -name '*.bats' -print0 \
               2>/dev/null | sort -z)
  done
  if [[ "${#_files[@]}" -eq 0 ]]; then
    _die ci_spec_repo_root \
      "no *.bats under ${_COVERAGE_FULL_SUITE_POOLS[*]} -- nothing was scanned, so the lint would pass vacuously."
    return 1
  fi

  local _violations=0 _seen=0 _line
  local -a _reports=()
  for _file in "${_files[@]}"; do
    while IFS= read -r _line; do
      if [[ "${_line}" == SEEN=* ]]; then
        _seen=$(( _seen + ${_line#SEEN=} ))
        continue
      fi
      _reports+=("${_line}")
      _violations=$(( _violations + 1 ))
    done < <(_spec_repo_root_scan "${_file}" "${_roots[@]}")
  done

  # The blind-detector case: the shape this lint reads has to still exist
  # in the tree, or a clean report means only that nothing matched.
  if [[ "${_seen}" -eq 0 ]]; then
    _die ci_spec_repo_root \
      "the ${#_files[@]} spec file(s) scanned carry no '*REPO_ROOT=' assignment at all -- nothing was checked, so the lint would pass vacuously. The detector, not the specs, is what to look at."
    return 1
  fi

  if [[ "${_violations}" -gt 0 ]]; then
    printf '%s\n' "${_reports[@]}"
    _die ci_spec_repo_root \
      "${_violations} spec(s) point a tree-walking tool at the LIVE checkout (${_roots[*]}). That runs the lint inside the coverage suite, under kcov, where it is 4x its own cost and on the critical path: base#1075 measured one such case at 331s of a 501s coverage shard, duplicating a lint-static job that made the same assertion in 77s. Assert the DRIVER against a fixture tree (a mktemp REPO_ROOT, as every other case in these files does); the live tree is the lint job's assertion to make."
    return 1
  fi
  echo "spec repo-root lint: clean (${_seen} REPO_ROOT assignment(s) across" \
       "${#_files[@]} spec file(s) in ${#_COVERAGE_FULL_SUITE_POOLS[@]} pool(s);" \
       "all fixture-rooted)"
}
