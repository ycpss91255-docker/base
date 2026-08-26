#!/usr/bin/env bash
# drivers/self_hosted_guard.sh - "a job that can land on a self-hosted
# runner must be guarded to same-repository events" per-tool driver for
# the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_self_hosted_guard. Follows drivers/home_literal.sh /
# drivers/i18n_orphan.sh conventions (sourced lib, uses ${REPO_ROOT},
# _log_* / _die, no main).
#
# ── The hazard ──────────────────────────────────────────────────────────────
#
# This is a PUBLIC repo and the org has a self-hosted runner registered at
# org level, in the Default runner group, with visibility `all` and
# `allows_public_repositories: true`. That runner is a developer
# workstation shared with unrelated tenants. A fork PR's workflow is
# attacker-authored code; if it ever lands on that machine it runs as the
# runner user, with the machine's docker socket and the machine's other
# work alongside it. Secrets are a separate (already-closed) question --
# this is arbitrary code execution on hardware, which no secret policy
# addresses.
#
# Nothing runs there today. The point of authoring the guard BEFORE the
# migration is that the migration cannot forget it.
#
# ── Why a lint and not N hand-applied `if:` lines ───────────────────────────
#
# A hand-applied condition on today's jobs decays at job N+1: whoever adds
# the next job has no reason to know the rule exists. That is precisely
# how the _LINT_TOOLS completeness gap, the downstream roster and the
# release archive's path list each decayed in this repo. So the rule is
# expressed once, here, over the SHAPE of the workflow tree rather than
# over a remembered list of job names, and it runs in the lint phase with
# its own lint-static CI job.
#
# ── The eligibility rule ────────────────────────────────────────────────────
#
# A job is SELF-HOSTED-ELIGIBLE unless this lint can PROVE, statically,
# that every label its `runs-on` can resolve to is a reserved
# GitHub-hosted label. Proof, not assumption: anything unproven defaults
# to eligible, so a spelling the resolver does not understand fails
# closed.
#
# Resolution sources, in order:
#
#   1. A literal scalar (`runs-on: ubuntu-latest`), a literal flow
#      sequence (`runs-on: [self-hosted, gpu]`) or the block `- ` form.
#   2. `runs-on: ${{ matrix.<key> }}` resolved against the job's OWN
#      literal `strategy.matrix` -- both the `include:` entry form and the
#      bare `<key>:` list form.
#
# Everything else is eligible:
#
#   - `runs-on:` with a `group:` child -- a runner GROUP is a self-hosted
#     / larger-runner concept by construction; there is no hosted reading
#     of it.
#   - `matrix: ${{ fromJSON(...) }}` -- the label set is computed at
#     runtime by a script this lint does not execute. Today all three such
#     jobs (build-worker `build`, publish-worker `publish`,
#     release-test-tools `build`) take their labels from a
#     platform->runner map that emits only hosted labels, but that map is
#     ONE edit away from emitting a self-hosted label and no static check
#     would see it. Those are also the likeliest first stop of a
#     self-hosted migration -- they are already the "pick a machine per
#     shard" jobs -- so they are exactly where the insurance belongs.
#   - `runs-on: ${{ inputs.runner }}` or any other expression --
#     caller-supplied, unknowable here.
#   - A job with no `runs-on` that calls a REMOTE reusable workflow
#     (`uses: owner/repo/...@ref`): the callee picks the machine and the
#     callee is not in this tree. A LOCAL call (`uses: ./...`) is exempt,
#     because the callee's own jobs are checked where they are defined.
#
# Why the hosted allow-list is a label FAMILY pattern rather than a job
# roster: `ubuntu-*`, `windows-*` and `macos-*` are reserved by GitHub and
# cannot be assigned to a self-hosted runner, so membership is a property
# of the label, decided by GitHub, not a list this repo maintains. It
# therefore survives a migration untouched -- the day a `runs-on` stops
# naming one of those families, that job needs the guard, whether it was
# written today or years from now. The org's actual runner carries
# `self-hosted,Linux,X64,gpu`; note that `Linux` and `X64` fall outside
# the allow-list too, which is the intended reading.
#
# ── The guard itself ────────────────────────────────────────────────────────
#
# `github.event_name != 'pull_request' || <head repo is this repo>`. It is
# a FORK test, not a PR test: a same-repo PR passes it, and every non-PR
# event -- a tag push, a branch push, `schedule`, `workflow_dispatch`, a
# `workflow_call` from a same-repo caller -- passes on the first disjunct
# without ever reading the pull_request payload (which is null for those
# events, so the second disjunct alone would be wrong).
#
# Under `workflow_call` the `github` context is the CALLER's, so inside a
# reusable worker the condition reads "the event that started the calling
# repo's run was not a fork PR against that repo" -- which is the correct
# question, since it is the caller's fork PR whose code the worker builds.
#
# The residual cost is that a fork PR SKIPS a guarded job, and a skip is
# pass-equivalent in ci-rollup's conditionally-gated bucket. A guard that
# turned a required check vacuously green for exactly the untrusted PR
# would be worse than the hazard it closes, so ci-rollup carries an
# explicit fork-PR branch that fails loudly instead; the assertion for it
# lives in self_test_yaml_spec.bats.

# ── Guard vocabulary ────────────────────────────────────────────────────────

# The canonical condition, whitespace-normalised. A job may AND it with
# its own gate; what is required is that this exact expression appear in
# the job's `if:` after newline / indent collapsing, so the parenthesised
# `<existing> && (<guard>)` form satisfies it while a hand-reworded
# near-miss does not.
readonly _SHG_GUARD_CANON="github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository"

# The block form to paste, for the failure message.
readonly _SHG_GUARD_SNIPPET="    if: >-
      github.event_name != 'pull_request' ||
      github.event.pull_request.head.repo.full_name == github.repository"

# Reserved GitHub-hosted label families. A self-hosted runner cannot
# register under these, which is what makes the pattern a proof rather
# than a convention.
readonly _SHG_HOSTED_RE='^(ubuntu|windows|macos)-[A-Za-z0-9._-]+$'

# Where workflows live. A directory, not a file list, so a workflow added
# tomorrow is scanned without touching this driver.
readonly _SHG_WORKFLOW_DIR_REL='.github/workflows'

# The opener of a GitHub expression, as a literal. Named rather than
# inlined because the SC2016 suppression it needs cannot sit in front of
# an `elif` branch, and the comparison that uses it is one.
# shellcheck disable=SC2016 # the literal expression opener, not an expansion.
readonly _SHG_EXPR_OPEN='${{'

# ── The workflow reader ─────────────────────────────────────────────────────

# Flattens one workflow file into a tagged record stream, one record per
# line, tab-separated:
#
#   JOB        <name>             a job block starts
#   RUNSON     <raw>              inline `runs-on:` value (may be an
#                                 expression or a `[a, b]` flow sequence)
#   RUNSONITEM <label>            one entry of a block-form `runs-on:`
#   RUNSONGROUP                   `runs-on:` names a runner group
#   MATRIXKV   <key> <value>      one candidate value of a literal matrix key
#   MATRIXDYN                     `matrix:` is an expression, not a literal
#   USES       <value>            the job calls a reusable workflow
#   IF         <normalised text>  the job's `if:`, whitespace-collapsed
#
# Written for busybox-awk / mawk / gawk alike (the three the test-tools
# image carries): no gensub, no three-argument match, no non-POSIX
# character classes.
#
# shellcheck disable=SC2016 # awk program; $-vars are awk's, not the shell's.
readonly _SHG_AWK='
function trim(s) {
  sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s
}
function unquote(s) {
  if (s ~ /^".*"$/ || s ~ /^'"'"'.*'"'"'$/) s = substr(s, 2, length(s) - 2)
  return s
}
function flush_if() {
  if (ifbuf != "") { print "IF\t" trim(ifbuf); ifbuf = "" }
}
BEGIN { injobs = 0; mode = ""; ifbuf = ""; mkey = "" }
# `jobs:` opens the only region read here; any other column-0 key closes it.
/^jobs:[ \t]*$/ { injobs = 1; next }
/^[^ \t#]/      { if (injobs == 1) { flush_if(); injobs = 0 } ; next }
injobs != 1     { next }
/^[ \t]*#/      { next }
/^[ \t]*$/      { next }
# A job name: exactly two spaces of indent, nothing after the colon.
/^  [A-Za-z0-9_.-]+:[ \t]*$/ {
  flush_if()
  name = $0; sub(/^  /, "", name); sub(/:[ \t]*$/, "", name)
  print "JOB\t" name
  mode = ""; mkey = ""
  next
}
# A job key: exactly four spaces of indent.
/^    [A-Za-z0-9_-]+:/ {
  flush_if()
  key = $0; sub(/^    /, "", key); sub(/:.*$/, "", key)
  val = $0; sub(/^    [A-Za-z0-9_-]+:/, "", val); val = trim(val)
  mode = ""; mkey = ""
  if (key == "runs-on") {
    if (val == "") { mode = "runson" } else { print "RUNSON\t" unquote(val) }
  } else if (key == "if") {
    # `>-` / `|` / empty all mean the text is on the following lines.
    if (val == "" || val == ">" || val == ">-" || val == "|" || val == "|-") {
      mode = "if"
    } else { ifbuf = val }
  } else if (key == "strategy") {
    mode = "strategy"
  } else if (key == "uses") {
    print "USES\t" unquote(val)
  }
  next
}
# Continuation lines (six or more spaces), dispatched by the open mode.
mode == "runson" {
  t = trim($0)
  if (t ~ /^group:/) { print "RUNSONGROUP" }
  else if (t ~ /^- /) { sub(/^- /, "", t); print "RUNSONITEM\t" unquote(trim(t)) }
  next
}
mode == "if" { ifbuf = ifbuf " " trim($0); next }
mode == "strategy" {
  if ($0 ~ /^      matrix:/) {
    val = $0; sub(/^      matrix:/, "", val); val = trim(val)
    if (val == "") { mode = "matrix"; mkey = "" }
    else { print "MATRIXDYN" }
  }
  next
}
mode == "matrix" {
  t = trim($0)
  sub(/^-[ \t]*/, "", t)
  if (t ~ /^[A-Za-z0-9_-]+:/) {
    k = t; sub(/:.*$/, "", k)
    v = t; sub(/^[A-Za-z0-9_-]+:/, "", v); v = trim(v)
    if (v == "") { mkey = k }
    else if (v ~ /^\[/) {
      mkey = k
      sub(/^\[/, "", v); sub(/\]$/, "", v)
      n = split(v, parts, ",")
      for (i = 1; i <= n; i++) print "MATRIXKV\t" k "\t" unquote(trim(parts[i]))
    }
    else { print "MATRIXKV\t" k "\t" unquote(v) }
  } else if (t != "" && mkey != "") {
    print "MATRIXKV\t" mkey "\t" unquote(t)
  }
  next
}
END { flush_if() }
'

# ── Per-job state ───────────────────────────────────────────────────────────
#
# The record reader is a stream, so the classifier needs the job it has
# just finished reading. These carry it. Declared at file scope rather
# than nested inside the loop so the classifier is an ordinary,
# separately testable function; _shg_reset_job is the one place that
# defines "a fresh job".
_SHG_JOB=""
_SHG_FILE=""
_SHG_RUNSON=""
_SHG_GROUP=0
_SHG_MATRIX_DYN=0
_SHG_USES=""
_SHG_IF=""
_SHG_RUNSON_ITEMS=()
# `-g` because this file is SOURCED, and a bare `declare -A` inside a
# function body (a bats `setup`, or any caller that sources drivers from a
# function) would make the map local to that call and leave the classifier
# reading an undefined name. The plain assignments above are global by
# default; an associative array has no such default.
declare -gA _SHG_MATRIX=()

# Counters, drained by _run_self_hosted_guard.
_SHG_JOBS_SEEN=0
_SHG_ELIGIBLE=0
_SHG_VIOLATIONS=0

# _shg_reset_job <name>
_shg_reset_job() {
  _SHG_JOB="${1}"
  _SHG_RUNSON=""
  _SHG_GROUP=0
  _SHG_MATRIX_DYN=0
  _SHG_USES=""
  _SHG_IF=""
  _SHG_RUNSON_ITEMS=()
  _SHG_MATRIX=()
}

# ── Classification ──────────────────────────────────────────────────────────

# _shg_is_hosted_label <label>
#
# True when <label> is a reserved GitHub-hosted label. Anything else --
# `self-hosted`, `gpu`, `Linux`, a bare hostname -- is not.
_shg_is_hosted_label() {
  [[ "${1}" =~ ${_SHG_HOSTED_RE} ]]
}

# _shg_has_guard <if-text>
#
# True when the job's whitespace-normalised `if:` contains the canonical
# condition verbatim.
_shg_has_guard() {
  local _if="${1}"
  # Collapse residual runs of whitespace so a block-scalar form and a
  # single-line form compare equal.
  _if="$(printf '%s' "${_if}" | tr '\t' ' ' | tr -s ' ')"
  [[ "${_if}" == *"${_SHG_GUARD_CANON}"* ]]
}

# _shg_split_flow <flow-sequence>
#
# Print one entry per line for a `[a, b]` flow sequence, unquoted and
# trimmed.
_shg_split_flow() {
  local _inner="${1#\[}"
  _inner="${_inner%\]}"
  local _item _old_ifs="${IFS}"
  IFS=','
  # shellcheck disable=SC2206 # deliberate word-split on the comma IFS.
  local _parts=(${_inner})
  IFS="${_old_ifs}"
  for _item in "${_parts[@]}"; do
    _item="${_item#"${_item%%[![:space:]]*}"}"
    _item="${_item%"${_item##*[![:space:]]}"}"
    _item="${_item#[\'\"]}"
    _item="${_item%[\'\"]}"
    [[ -n "${_item}" ]] && printf '%s\n' "${_item}"
  done
}

# _shg_eligibility_reason
#
# Print WHY the current job is self-hosted-eligible, or nothing at all
# when the lint can prove it is GitHub-hosted-only. Exits non-zero
# (printing nothing) for a job that is out of scope entirely -- today,
# only a local reusable-workflow call, whose own jobs are checked where
# they are defined.
_shg_eligibility_reason() {
  local -a _labels=()
  local _label _value _key

  if [[ "${_SHG_GROUP}" -eq 1 ]]; then
    printf 'runs-on names a runner group\n'
    return 0
  fi

  if [[ -n "${_SHG_RUNSON}" ]]; then
    if [[ "${_SHG_RUNSON}" == \[*\] ]]; then
      while IFS= read -r _label; do
        _labels+=("${_label}")
      done < <(_shg_split_flow "${_SHG_RUNSON}")
    elif [[ "${_SHG_RUNSON}" =~ ^\$\{\{[[:space:]]*matrix\.([A-Za-z0-9_]+)[[:space:]]*\}\}$ ]]; then
      _key="${BASH_REMATCH[1]}"
      if [[ "${_SHG_MATRIX_DYN}" -eq 1 ]]; then
        printf 'runs-on reads matrix.%s and the matrix is computed at runtime\n' "${_key}"
        return 0
      fi
      if [[ -z "${_SHG_MATRIX["${_key}"]:-}" ]]; then
        printf 'runs-on reads matrix.%s but the job declares no literal value for it\n' "${_key}"
        return 0
      fi
      for _value in ${_SHG_MATRIX["${_key}"]}; do
        _labels+=("${_value}")
      done
    elif [[ "${_SHG_RUNSON}" == *"${_SHG_EXPR_OPEN}"* ]]; then
      printf "runs-on is the expression '%s', whose value is not knowable here\n" \
        "${_SHG_RUNSON}"
      return 0
    else
      _labels+=("${_SHG_RUNSON}")
    fi
  elif [[ "${#_SHG_RUNSON_ITEMS[@]}" -gt 0 ]]; then
    _labels=("${_SHG_RUNSON_ITEMS[@]}")
  elif [[ -n "${_SHG_USES}" ]]; then
    if [[ "${_SHG_USES}" == ./* ]]; then
      return 1
    fi
    printf "calls the remote reusable workflow '%s', which picks its own runner\n" \
      "${_SHG_USES}"
    return 0
  else
    printf 'declares neither runs-on nor uses\n'
    return 0
  fi

  for _label in "${_labels[@]}"; do
    if ! _shg_is_hosted_label "${_label}"; then
      printf "runs-on can resolve to the label '%s', which is not a reserved GitHub-hosted label\n" \
        "${_label}"
      return 0
    fi
  done
  return 0
}

# _shg_classify_job
#
# Score the job the reader has just finished. Prints one violation line
# per unguarded eligible job and advances the counters. A no-op when no
# job is open (start of file).
_shg_classify_job() {
  [[ -z "${_SHG_JOB}" ]] && return 0
  # Counted before the out-of-scope branch below, so the non-vacuity check
  # measures "did the reader see jobs", not "did the reader see jobs this
  # lint has an opinion about". A workflow made entirely of local
  # reusable-workflow calls is a real, parseable workflow.
  _SHG_JOBS_SEEN=$(( _SHG_JOBS_SEEN + 1 ))
  local _why
  _why="$(_shg_eligibility_reason)" || { _SHG_JOB=""; return 0; }
  if [[ -n "${_why}" ]]; then
    _SHG_ELIGIBLE=$(( _SHG_ELIGIBLE + 1 ))
    if ! _shg_has_guard "${_SHG_IF}"; then
      printf '%s: job %s: %s -- but it carries no same-repo guard\n' \
        "${_SHG_FILE}" "${_SHG_JOB}" "${_why}"
      _SHG_VIOLATIONS=$(( _SHG_VIOLATIONS + 1 ))
    fi
  fi
  _SHG_JOB=""
}

# ── The lint ────────────────────────────────────────────────────────────────

_run_self_hosted_guard() {
  echo "--- Running self-hosted runner guard lint ---"

  local _dir="${REPO_ROOT}/${_SHG_WORKFLOW_DIR_REL}"
  if [[ ! -d "${_dir}" ]]; then
    _die ci_self_hosted_guard \
      "workflow directory '${_SHG_WORKFLOW_DIR_REL}/' not found under ${REPO_ROOT} -- there is nothing to scan, so the guard would pass vacuously."
    return 1
  fi

  local -a _files=()
  local _file
  while IFS= read -r -d '' _file; do
    _files+=("${_file}")
  done < <(find "${_dir}" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) \
             -print0 2>/dev/null | sort -z)
  if [[ "${#_files[@]}" -eq 0 ]]; then
    _die ci_self_hosted_guard \
      "no workflow under '${_SHG_WORKFLOW_DIR_REL}/' -- nothing was scanned, so the guard would pass vacuously."
    return 1
  fi

  _SHG_JOBS_SEEN=0
  _SHG_ELIGIBLE=0
  _SHG_VIOLATIONS=0

  local _tag _a _b
  for _file in "${_files[@]}"; do
    _SHG_FILE="${_file#"${REPO_ROOT}"/}"
    _shg_reset_job ""
    while IFS=$'\t' read -r _tag _a _b; do
      case "${_tag}" in
        JOB)
          _shg_classify_job
          _shg_reset_job "${_a}"
          ;;
        RUNSON)      _SHG_RUNSON="${_a}" ;;
        RUNSONITEM)  _SHG_RUNSON_ITEMS+=("${_a}") ;;
        RUNSONGROUP) _SHG_GROUP=1 ;;
        MATRIXDYN)   _SHG_MATRIX_DYN=1 ;;
        MATRIXKV)    _SHG_MATRIX["${_a}"]="${_SHG_MATRIX["${_a}"]:-} ${_b}" ;;
        USES)        _SHG_USES="${_a}" ;;
        IF)          _SHG_IF="${_a}" ;;
      esac
    done < <(awk "${_SHG_AWK}" "${_file}")
    _shg_classify_job
  done

  # Non-vacuity. A reader regression that stopped recognising job blocks
  # would report zero violations forever, in silence -- the same failure
  # mode this guard exists to prevent, one level up.
  if [[ "${_SHG_JOBS_SEEN}" -eq 0 ]]; then
    _die ci_self_hosted_guard \
      "the ${#_files[@]} workflow(s) under '${_SHG_WORKFLOW_DIR_REL}/' yielded no job at all -- nothing was classified, so the lint would pass vacuously. The record reader, not the workflows, is what to look at."
    return 1
  fi

  if [[ "${_SHG_VIOLATIONS}" -gt 0 ]]; then
    _die ci_self_hosted_guard \
      "${_SHG_VIOLATIONS} job(s) can land on a self-hosted runner without a same-repo guard. This org registers a self-hosted runner at org level with public-repo access, so an unguarded eligible job is arbitrary fork-PR code executing on that machine. Add to each job listed above:
${_SHG_GUARD_SNIPPET}
AND-ing it with any gate the job already has (\`<existing> && (<guard>)\`). If the job is genuinely GitHub-hosted-only, spell its runs-on as a literal reserved label (ubuntu-* / windows-* / macos-*) rather than an expression and the guard is not required."
    return 1
  fi

  echo "self-hosted runner guard lint: clean (${_SHG_JOBS_SEEN} job(s) across ${#_files[@]} workflow(s); ${_SHG_ELIGIBLE} self-hosted-eligible, all guarded)"
}
