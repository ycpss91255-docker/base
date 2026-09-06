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
# -- is asserted by the cheap fixture cases beside the one this refuses.
# base#1075 measured the coverage cost of removing all twenty-three of
# them before removing any: two full runs of the unchanged tree recorded
# the same 8591 covered lines of 10195, and the tree with all twenty-three
# gone -- plus the four fixtures that replace the one contribution they
# had -- records the same 8591, with the symmetric difference empty in
# both directions.
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
#   - the VALUE is resolved one hop, inside the file being read: a name the
#     same spec assigns a refused root to counts as that root. All
#     twenty-three cases base#1075 removed wrote the literal, so a literal
#     reader was right about the tree it was written against -- but this
#     driver's own spec CANNOT write the literal (it is one of the files
#     scanned), so the indirect form is the idiom the next author finds
#     when they look for one. Resolution stays inside one file: a name
#     means the mount in one spec and a scratch directory in the next.
#
# ── Non-vacuity ────────────────────────────────────────────────────────────
#
# SIX ways this could go green having checked nothing, each a _die: no pool
# table at all, a pool that resolves to no directory, a scan that finds no
# spec file, a compose.yaml that is missing, one that binds no checkout,
# and a scan that finds no `*REPO_ROOT=` assignment ANYWHERE. The last is
# the one that matters: 63 fixture-rooted assignments exist today, so zero
# means the detector has gone blind (a renamed variable, a changed quoting
# convention), and a blind detector reports a clean tree.
#
# Each has a case in the spec, and each case asserts the sentence only ITS
# die prints. That is not pedantry: every message here ends in "vacuously"
# and two of them name compose.yaml, so a case that asserted the shared
# word passed with the guard it named deleted -- a different die fired and
# the assertion could not tell.
#
# ── What it does NOT see ───────────────────────────────────────────────────
#
# A spec that reaches the live tree by some other spelling. Three of them,
# named rather than implied, because a blind spot with a shape is one the
# next reader can decide about:
#
#   1. Reading a file under the mount directly (`grep ... /source/justfile`)
#      -- cheap, common, and deliberately allowed. A rule wide enough to
#      cover it would flag the hundreds of single-file reads this suite is
#      built out of, which is the noise that gets a lint muted.
#   2. Invoking a tool whose root DEFAULTS to the checkout when the
#      variable is unset (costed below).
#   3. A root the file does not resolve: a command substitution, a relative
#      path, `${PWD}`, or a name assigned in ANOTHER file. One hop of
#      in-file indirection is resolved (above); a value this driver would
#      have to run a shell to know is not. test/bats/unit/upgrade_spec.bats
#      is the live example -- `$(pwd -P)` after the caller has cd-ed into a
#      fixture repo, which is correct there and invisible here either way.
#      Reading it would mean modelling shell in awk, and the cases that
#      matter reach the tree far more cheaply than that.
#
# THAT REMAINDER IS MEASURED, not assumed, so the next reader does not have
# to rediscover its size. Read the SHARES and the identities below, not the
# absolute seconds: two warm 32-way `just test coverage-local` runs of the
# same tree on this machine put the same test 40% apart, so a second here
# is a machine-load reading and a share is a property of the suite.
#
# One family is the host-direct lint entry, reaching THIS SAME SHAPE
# through `--<tool>-only` rather than through an assignment:
# `--pin-coverage-only`, `--ci LINT_TOOL=doc-counts`, `--doc-counts-only`,
# `--readme-sync-only`. Measured at 174 tests and 6.8% of instrumented
# time on the run that landed this lint.
#
# It is NOT the largest survivor, and the two that are carry no assignment
# either: `_sync_readme_hashes: is a no-op on the REAL tree` in
# readme_sync_spec.bats at 116.0s, and `doc/adr: every record's workflow
# and quotation claims hold against the tree` in adr_doc_claims_spec.bats
# at 115.3s. The first copies the live doc/readme/ tree and runs the
# generator over the COPY -- a fixture root by the letter of this rule and
# a whole-tree run by its purpose -- and the second reads doc/adr/
# directly. Those two, not the entry-point family, are what now bounds the
# partition: 116.0s against a 266.7s twelve-shard ideal, which is the
# margin that makes the shard count a lever again.
#
# THE ENTRY-POINT CASES are not refused here, and the reason is a real
# obstacle rather than a judgement call: they assert the ENTRY POINT --
# that `--<tool>-only` runs on the host with no compose -- and test.sh
# derives REPO_ROOT from its OWN location, so there is no fixture root to
# point them at. Making that derivation overridable is the change to make
# before widening this rule, not after. Until then the cost is above, not
# implied.

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

# The scan program. A FILE-SCOPE constant and not a heredoc inside the
# function, the shape drivers/self_hosted_guard.sh already uses for
# _SHG_AWK: the reader is one program either way, and a function carrying
# it is one function over the implementation-standard length (base#994).
#
# The file is read TWICE. Pass one records every name the file assigns a
# refused root to; pass two resolves `${NAME}` / `$NAME` (with an optional
# path suffix) through that table before deciding. Both passes skip
# whole-line comments -- this driver's own header, and the prose in half
# the specs, spells the refused form out.
#
# Written for POSIX awk: the ci image carries busybox awk, mawk and gawk,
# and the issueref lint (base#872) is the standing reminder that a program
# here runs under more than one of them.
# shellcheck disable=SC2016 # awk program; $-vars are awk's, not the shell's.
readonly _SPEC_REPO_ROOT_AWK='
function _val(rest,   q, v, i) {
  q = substr(rest, 1, 1)
  if (q == "\"" || q == "\047") {
    v = substr(rest, 2)
    i = index(v, q)
    if (i > 0) v = substr(v, 1, i - 1)
  } else {
    v = rest
    sub(/[[:space:];)].*$/, "", v)
  }
  return v
}
function _refused(v,   r) {
  for (r = 1; r <= n_roots; r++) {
    if (roots[r] == "") continue
    if (v == roots[r] || index(v, roots[r] "/") == 1) return 1
  }
  return 0
}
function _deref(v,   nm) {
  if (substr(v, 1, 1) != "$") return v
  if (match(v, /^[$][{][A-Za-z_][A-Za-z0-9_]*[}]/))
    nm = substr(v, 3, RLENGTH - 3)
  else if (match(v, /^[$][A-Za-z_][A-Za-z0-9_]*/))
    nm = substr(v, 2, RLENGTH - 1)
  else
    return v
  if (!(nm in lit)) return v
  return lit[nm] substr(v, RLENGTH + 1)
}
BEGIN { n_roots = split(ROOTS, roots, "\n") }
/^[[:space:]]*#/ { next }
NR == FNR {
  line = $0
  while (match(line, /(^|[^A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*=/)) {
    tok = substr(line, RSTART, RLENGTH)
    sub(/^[^A-Za-z0-9_]/, "", tok)
    name = tok; sub(/=$/, "", name)
    line = substr(line, RSTART + RLENGTH)
    v = _val(line)
    if (_refused(v)) lit[name] = v
  }
  next
}
{
  line = $0
  while (match(line, /(^|[^A-Za-z0-9_])[A-Za-z0-9_]*REPO_ROOT=/)) {
    tok = substr(line, RSTART, RLENGTH)
    sub(/^[^A-Za-z0-9_]/, "", tok)
    name = tok; sub(/=$/, "", name)
    rest = substr(line, RSTART + RLENGTH)
    line = rest
    seen++
    raw = _val(rest)
    v = _deref(raw)
    if (_refused(v))
      printf "%s:%d: %s=%s%s\n", REL, FNR, name, raw, \
             (v == raw ? "" : " -> " v)
  }
}
END { printf "SEEN=%d\n", seen }
'

# _spec_repo_root_scan <file> <root>...
#
# Print one `<file>:<line>: <name>=<value>` record per assignment of a
# `*REPO_ROOT` variable to one of <root>... (or to a path under it), and a
# final `SEEN=<n>` line counting EVERY `*REPO_ROOT=` assignment the file
# carries, violation or not. The count is what the non-vacuity check reads.
# A record whose value took a hop through a name carries the resolution,
# so the report says why a line naming no path is on the list.
_spec_repo_root_scan() {
  local _file="${1}"; shift
  local _roots
  _roots="$(printf '%s\n' "$@")"
  awk -v ROOTS="${_roots}" -v REL="${_file}" "${_SPEC_REPO_ROOT_AWK}" \
    "${REPO_ROOT}/${_file}" "${REPO_ROOT}/${_file}"
}

# The scanned files, filled by _spec_repo_root_files and read by its
# caller. Meaningless before it has run.
_SPEC_REPO_ROOT_FILES=()

# _spec_repo_root_files
#
# Fill _SPEC_REPO_ROOT_FILES with every *.bats under the coverage pools,
# repo-relative and sorted. Dies when a pool resolves to no directory (the
# lint would scan less than the suite runs) and when the walk finds no spec
# at all. A GLOBAL rather than stdout, for the reason
# _spec_repo_root_live_roots states at length: a _die inside a process
# substitution refuses a subshell nobody is listening to.
_spec_repo_root_files() {
  _SPEC_REPO_ROOT_FILES=()
  local _pool _file
  for _pool in "${_COVERAGE_FULL_SUITE_POOLS[@]}"; do
    if [[ ! -d "${REPO_ROOT}/${_pool}" ]]; then
      _die ci_spec_repo_root \
        "coverage pool '${_pool}/' not found under ${REPO_ROOT} -- the lint would scan less than the suite runs."
      return 1
    fi
    while IFS= read -r -d '' _file; do
      _SPEC_REPO_ROOT_FILES+=("${_file#"${REPO_ROOT}"/}")
    done < <(find "${REPO_ROOT}/${_pool}" -type f -name '*.bats' -print0 \
               2>/dev/null | sort -z)
  done
  if [[ "${#_SPEC_REPO_ROOT_FILES[@]}" -eq 0 ]]; then
    _die ci_spec_repo_root \
      "no *.bats under ${_COVERAGE_FULL_SUITE_POOLS[*]} -- nothing was scanned, so the lint would pass vacuously."
    return 1
  fi
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

  _spec_repo_root_files || return 1
  local -a _files=("${_SPEC_REPO_ROOT_FILES[@]}")

  local _violations=0 _seen=0 _line _file
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
