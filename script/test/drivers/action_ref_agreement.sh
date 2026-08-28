#!/usr/bin/env bash
# drivers/action_ref_agreement.sh - "every call site of the same GitHub
# Action agrees on one ref" per-tool driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_action_ref_agreement. Follows drivers/self_hosted_guard.sh /
# drivers/i18n_orphan.sh conventions (sourced lib, uses ${REPO_ROOT},
# _log_* / _die, no main).
#
# ── The hazard ──────────────────────────────────────────────────────────────
#
# `docker/build-push-action` sat at eleven call sites across
# .github/workflows/, five on `@v6` and six on `@v7`, for months. Which
# major version built an image depended on which workflow fired, and
# every gate was green throughout, because nothing in the tree compares
# one action's refs ACROSS files:
#
#   - actionlint validates each `uses:` in isolation. Two valid refs of
#     one action are two valid `uses:` lines; there is no cross-file
#     question for it to answer.
#   - dependabot HAD offered the bump, in a pull request that was CLOSED.
#     Dependabot never re-raises a version pair it has already proposed
#     and had closed, so closing it silenced the upgrade permanently, for
#     every call site the bump covered -- including call sites written
#     afterwards, which were never part of the decision.
#
# The second half is the general hazard, and the reason a lint is the
# only fix: closing a dependabot pull request is not "deferring" a bump,
# it is opting out of it for good, and the resulting blind spot is NOT
# discoverable from .github/dependabot.yml. That file stays correct and
# says nothing about which pairs have been dismissed. The only ways to
# see it are to diff the refs the workflows actually carry -- which is
# this lint -- or to go trawling dependabot's closed pull requests.
#
# So the rule is expressed once, over the SHAPE of the workflow tree
# rather than over a remembered list of actions, and it runs in the lint
# phase with its own lint-static CI job. The next partial bump fails
# here, whatever action it is and whoever leaves it half done.
#
# ── The identity: the action's REPOSITORY ───────────────────────────────────
#
# Refs are grouped by `<owner>/<repo>`, with any sub-path dropped, because
# a ref is a git tag on the ACTION'S REPOSITORY: `actions/cache/save@v6`
# and `actions/cache/restore@v6` are two entry points of one versioned
# thing and move together or not at all. Grouping by the full `uses:`
# string would call `save@v6` + `restore@v7` agreement, which is the same
# split one directory level down.
#
# ── What is not compared ────────────────────────────────────────────────────
#
#   - A local call (`uses: ./.github/workflows/x.yaml`) carries no ref:
#     the callee is this tree, at this commit.
#   - A container action (`uses: docker://image:tag`) is an image
#     reference, not a repository tag; it has no `<owner>/<repo>` reading.
#   - A commented-out `uses:` line is not a call site.
#   - A trailing `# comment` after the value is stripped before the ref is
#     read. The repo's one sha-pinned action annotates the pin with the
#     tag it corresponds to, and left unstripped that annotation would
#     become part of the ref, making every annotated pin its own version.
#
# A sha pin and a tag naming the same action DO disagree, and that is
# intended: they are two different ways of saying which code runs, and
# which one a given workflow gets is exactly the question this lint asks.
#
# ── The recorded exception ──────────────────────────────────────────────────
#
# One call site may hold back, if the reason is written where the
# divergence is:
#
#   # action-ref-agreement: allow -- <why this call site holds back>
#   uses: some/action@v6
#
# The marker sits in the contiguous comment block directly above the
# `uses:` line, and it must carry a reason after `--`; a bare marker is
# refused. That is not ceremony. A mute with no reason rebuilds the
# closed-pull-request hazard INSIDE the repo -- a divergence nobody
# decided, that no file explains -- and the whole point of the mechanism
# is that an exception is something you read while looking at the line
# that diverges. The exception scope ends with the comment block, so one
# recorded divergence cannot licence the next call site down.

# ── Vocabulary ──────────────────────────────────────────────────────────────

# Where workflows live. A directory, not a file list, so a workflow added
# tomorrow is scanned without touching this driver.
readonly _ARA_WORKFLOW_DIR_REL='.github/workflows'

# The marker that records a deliberate hold-back, and the separator its
# reason must follow.
readonly _ARA_ALLOW_MARKER='action-ref-agreement: allow'
readonly _ARA_ALLOW_SEP='--'

# A `uses:` value that names a versioned action repository:
# `<owner>/<repo>[/<sub>...]@<ref>`. The first two path segments are the
# identity; everything after `@` is the ref.
readonly _ARA_USES_RE='^([A-Za-z0-9][A-Za-z0-9._-]*)/([A-Za-z0-9._-]+)(/[^@]*)?@(.+)$'

# ── The workflow reader ─────────────────────────────────────────────────────
#
# Flattens one workflow file into a tab-separated record stream, one
# record per `uses:` call site:
#
#   USES  <line-number>  <value>  <allow-marker-text-or-empty>
#
# The marker text is LAST so a tab inside it cannot shift a field.
#
# Written for busybox-awk / mawk / gawk alike (the three the test-tools
# image carries): no gensub, no three-argument match, no non-POSIX
# character classes.
#
# shellcheck disable=SC2016 # awk program; $-vars are awk's, not the shell's.
readonly _ARA_AWK='
function trim(s) {
  sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s
}
BEGIN { SQ = sprintf("%c", 39); pending = "" }
{
  t = trim($0)
  # A comment line. It opens or continues a block; a block that names the
  # marker arms the exception for the next call site.
  if (substr(t, 1, 1) == "#") {
    if (index(t, MARKER) > 0) pending = t
    next
  }
  # Anything that is not a comment ends the block -- so the exception
  # cannot outlive the comment it was written in.
  if (t == "") { pending = ""; next }
  if (t ~ /^-?[ \t]*uses:/) {
    v = t
    sub(/^-?[ \t]*uses:[ \t]*/, "", v)
    # Strip a trailing comment. The space before the `#` is required, so
    # a `#` inside a ref (a fragment, not a thing GitHub accepts, but
    # cheap to be right about) is not mistaken for one.
    p = index(v, " #")
    if (p > 0) v = substr(v, 1, p - 1)
    v = trim(v)
    gsub(/"/, "", v)
    gsub(SQ, "", v)
    print "USES\t" NR "\t" v "\t" pending
  }
  pending = ""
}
'

# ── Counters and the ref index ──────────────────────────────────────────────
#
# `-g` because this file is SOURCED, and a bare `declare -A` inside a
# function body (a bats `setup`, or any caller that sources drivers from a
# function) would make the map local to that call and leave the reporter
# reading an undefined name.
declare -gA _ARA_REFS=()
declare -gA _ARA_SITES=()
_ARA_ACTIONS=""
_ARA_CALL_SITES=0
_ARA_VERSIONED=0
_ARA_ALLOWED=0

# _ara_reset -- one place that defines "a fresh scan".
_ara_reset() {
  _ARA_REFS=()
  _ARA_SITES=()
  _ARA_ACTIONS=""
  _ARA_CALL_SITES=0
  _ARA_VERSIONED=0
  _ARA_ALLOWED=0
}

# ── Recording ───────────────────────────────────────────────────────────────

# _ara_record <file-rel> <line> <value> <marker>
#
# Index one call site, or return non-zero when the call site carries an
# allow marker with no reason (the one shape that is a finding in itself).
_ara_record() {
  local _file="${1}" _line="${2}" _value="${3}" _marker="${4}"
  local _id _ref _reason

  _ARA_CALL_SITES=$(( _ARA_CALL_SITES + 1 ))

  # Not a versioned action repository: a local call, a container action,
  # or a ref-less spelling. Nothing to compare.
  case "${_value}" in
    ./*|/*|docker://*) return 0 ;;
  esac
  [[ "${_value}" =~ ${_ARA_USES_RE} ]] || return 0

  _id="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  _ref="${BASH_REMATCH[4]}"
  _ARA_VERSIONED=$(( _ARA_VERSIONED + 1 ))

  if [[ -n "${_marker}" ]]; then
    _reason="${_marker#*"${_ARA_ALLOW_MARKER}"}"
    _reason="${_reason#*"${_ARA_ALLOW_SEP}"}"
    # No separator at all leaves the slice equal to the tail after the
    # marker; either way, an empty remainder means no reason was given.
    if [[ "${_marker}" != *"${_ARA_ALLOW_SEP}"* || -z "${_reason//[[:space:]]/}" ]]; then
      _die ci_action_ref_agreement \
        "${_file}:${_line}: the '${_ARA_ALLOW_MARKER}' marker carries no reason. Write it as '# ${_ARA_ALLOW_MARKER} ${_ARA_ALLOW_SEP} <why this call site holds back>'. A marker that only mutes rebuilds the hazard this lint exists for: a divergence nobody decided and no file explains."
      return 1
    fi
    _ARA_ALLOWED=$(( _ARA_ALLOWED + 1 ))
    return 0
  fi

  # First sighting of this action: remember the order actions appeared,
  # so the report is stable rather than hash-ordered.
  if [[ -z "${_ARA_REFS["${_id}"]:-}" ]]; then
    _ARA_ACTIONS+="${_id}"$'\n'
  fi
  case " ${_ARA_REFS["${_id}"]:-} " in
    *" ${_ref} "*) : ;;
    *) _ARA_REFS["${_id}"]="${_ARA_REFS["${_id}"]:-}${_ARA_REFS["${_id}"]:+ }${_ref}" ;;
  esac
  _ARA_SITES["${_id}|${_ref}"]="${_ARA_SITES["${_id}|${_ref}"]:-}${_ARA_SITES["${_id}|${_ref}"]:+ }${_file}:${_line}"
}

# ── The lint ────────────────────────────────────────────────────────────────

_run_action_ref_agreement() {
  echo "--- Running action ref agreement lint ---"

  local _dir="${REPO_ROOT}/${_ARA_WORKFLOW_DIR_REL}"
  if [[ ! -d "${_dir}" ]]; then
    _die ci_action_ref_agreement \
      "workflow directory '${_ARA_WORKFLOW_DIR_REL}/' not found under ${REPO_ROOT} -- there is nothing to scan, so the lint would pass vacuously."
    return 1
  fi

  local -a _files=()
  local _file
  while IFS= read -r -d '' _file; do
    _files+=("${_file}")
  done < <(find "${_dir}" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) \
             -print0 2>/dev/null | sort -z)
  if [[ "${#_files[@]}" -eq 0 ]]; then
    _die ci_action_ref_agreement \
      "no workflow under '${_ARA_WORKFLOW_DIR_REL}/' -- nothing was scanned, so the lint would pass vacuously."
    return 1
  fi

  _ara_reset

  local _rel _tag _line _value _marker
  for _file in "${_files[@]}"; do
    _rel="${_file#"${REPO_ROOT}"/}"
    while IFS=$'\t' read -r _tag _line _value _marker; do
      [[ "${_tag}" == "USES" ]] || continue
      _ara_record "${_rel}" "${_line}" "${_value}" "${_marker}" || return 1
    done < <(awk -v MARKER="${_ARA_ALLOW_MARKER}" "${_ARA_AWK}" "${_file}")
  done

  # Non-vacuity. A reader regression that stopped recognising `uses:`
  # would report no disagreement forever, in silence -- the same
  # unnoticed green the split itself had, one level up.
  if [[ "${_ARA_VERSIONED}" -eq 0 ]]; then
    _die ci_action_ref_agreement \
      "the ${#_files[@]} workflow(s) under '${_ARA_WORKFLOW_DIR_REL}/' yielded no versioned action call at all (${_ARA_CALL_SITES} \`uses:\` line(s) seen) -- nothing was compared, so the lint would pass vacuously. The record reader, not the workflows, is what to look at."
    return 1
  fi

  local _id _ref _report="" _split=0 _actions=0
  while IFS= read -r _id; do
    [[ -n "${_id}" ]] || continue
    _actions=$(( _actions + 1 ))
    local -a _refs=()
    read -r -a _refs <<<"${_ARA_REFS["${_id}"]}"
    [[ "${#_refs[@]}" -gt 1 ]] || continue
    _split=$(( _split + 1 ))
    _report+="  ${_id} is used at ${#_refs[@]} refs:"$'\n'
    for _ref in "${_refs[@]}"; do
      _report+="    @${_ref} at ${_ARA_SITES["${_id}|${_ref}"]}"$'\n'
    done
  done <<<"${_ARA_ACTIONS}"

  if [[ "${_split}" -gt 0 ]]; then
    _die ci_action_ref_agreement \
      "${_split} action(s) are called at more than one ref across '${_ARA_WORKFLOW_DIR_REL}/':
${_report}A ref is a tag on the action's repository, so two refs in one tree means two versions of the same action run depending on which workflow fires. Move every call site to one ref. If one of them genuinely has to hold back, record it AT the call site:
    # ${_ARA_ALLOW_MARKER} ${_ARA_ALLOW_SEP} <why this call site holds back>
Do not expect dependabot to raise this again: it never re-proposes a version pair whose pull request was closed, and .github/dependabot.yml shows no trace of that."
    return 1
  fi

  echo "action ref agreement lint: clean (${_ARA_VERSIONED} versioned call site(s) across ${#_files[@]} workflow(s); ${_actions} action(s), each on one ref; ${_ARA_ALLOWED} allowed by marker)"
}
