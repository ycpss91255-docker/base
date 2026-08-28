#!/usr/bin/env bash
# drivers/generated_workflow_actions.sh - "a generated workflow's action
# refs stay in lockstep with this repo's own" per-tool driver for the
# self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_generated_workflow_actions.
#
# Contract: pure bash over the checkout, so it runs host-direct as well as
# inside the ci (test-tools) container. References ${REPO_ROOT} (a global
# exported by test.sh).
#
# ── The gap ─────────────────────────────────────────────────────────────
#
# dependabot reads WORKFLOW FILES. `init.sh` writes a workflow into every
# downstream repo out of a heredoc, and a ref inside a shell script is not
# a workflow file, so dependabot cannot see it. Three other candidate
# owners do not have it either:
#
#   - the upstream-release watch declines a `uses:` VERSION ref on
#     purpose, because those are dependabot's and two mechanisms with
#     opinions about one dependency is worse than one that works;
#   - `init.sh` generates no dependabot config into the downstream repo,
#     so nothing bumps the copy where it lands;
#   - `init.sh` skips the generated file when it already exists, so the
#     subtree upgrade that refreshes everything else never refreshes it.
#
# That ref is watched by nothing. It is not a hypothetical: dependabot
# bumped actions/checkout 6 -> 7 across this repo's workflows on
# 2026-06-29 and the generated workflow was authored the day after, so it
# reads v7 by an accident of ordering. Nothing holds it there.
#
# ── Why a lint here rather than a lookup in init.sh ─────────────────────
#
# Reading the number out of the workflows at generation time would be the
# better shape -- it is what the e2e job does for the pinned `just`
# version -- but init.sh runs from the `.base` subtree inside a DOWNSTREAM
# repo, and that subtree carries no `.github/workflows/`. There is nothing
# to read there. In this repo both copies are present, so the agreement is
# checkable here and only here, and checking it is what drags the heredoc
# into dependabot's reach: its own bump PR turns this lint red until the
# heredoc moves with it.
#
# ── What is asserted, and what is not ───────────────────────────────────
#
# Agreement, not currency. This driver holds no opinion about which
# version is right; dependabot owns that question and answers it well
# here. It asserts only that the generated copy names the same ref the
# real workflows do, so whatever dependabot decides propagates. That is
# also why the check is direction-agnostic: a generated ref AHEAD of the
# workflows is the same defect with the opposite sign, and it is the shape
# a well-meant hand-edit takes.
#
# Three cases have no single ref to inherit, and each fails with its own
# sentence rather than being guessed at:
#
#   - this repo pins the action at two different refs (it does today, for
#     docker/build-push-action) -- there is no answer to "which one";
#   - this repo never calls the action itself -- there is no dependabot PR
#     for the generated ref to follow, which is the bare form of the
#     defect;
#   - the scan matched nothing anywhere -- a renamed generator or a
#     matcher that stopped matching, where silence would otherwise read as
#     lockstep.
#
# Deliberately NOT a pin: an interpolated ref, e.g. this repo calling its
# own reusable workflow at the pinned subtree version. Both halves are
# shell variables, there is no literal to compare, and upgrade.sh already
# rewrites that ref on every upgrade. Nor is a ref quoted inside a shell
# or YAML COMMENT: prose explaining what a step looks like is not a step,
# and a lint that fails on its own documentation gets muted.
#
# Style: Google Shell Style Guide.

# Where this repo's own workflows live. A directory, not a file list, so a
# workflow added tomorrow is read without touching this driver.
readonly _GWA_WORKFLOW_DIR_REL='.github/workflows'

# One `uses:` reference to a versioned action, as a literal.
#
# Capture 1 is the action (`owner/repo`, optionally with a subpath) and
# capture 3 is the ref. Neither character class admits `$`, so an
# interpolated owner or ref cannot match, and the required `/` keeps a
# bare word ahead of an `@` from being read as an action.
readonly _GWA_USES_RE='uses:[[:space:]]+([A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9._-]+)+)@([A-Za-z0-9._-]+)'

# Generated trees the walk must not descend into, by directory basename.
#
# The walk is the whole repository, so this is a PRUNE list rather than a
# roster of scanned directories: a generator added tomorrow at any depth
# is covered without editing this file, and forgetting to prune a new
# generated tree makes the lint fire rather than quietly exempting
# something. Every entry is gitignored.
#
# `.prev-release/` is the one that matters. The self-test materialises
# PAST releases into it, and their refs are stale BY DEFINITION -- a
# release cannot be re-pinned. Scanning it means the first dependabot bump
# after a release fails a lint no edit can satisfy. The same set is pruned
# by the upstream-release watch's pin registry, for the same reason.
readonly _GWA_SCAN_PRUNE=('.git' 'log' '.prev-release')

# _gwa_is_comment <line> -- true when the line's first non-blank
# character opens a comment. The same test serves shell and YAML.
_gwa_is_comment() {
  local _l="${1}"
  _l="${_l#"${_l%%[![:space:]]*}"}"
  [[ "${_l}" == '#'* ]]
}

# _gwa_hits <glob> -- every candidate line under REPO_ROOT in files
# matching <glob>, as `<relative-path>:<lineno>:<content>`.
#
# grep pre-filters so only files that mention `uses:` are read at all;
# without it this walks every line of every script in the tree on each
# lint run. A tree with no match is not an error here -- the callers
# decide what an empty result means, and they mean different things.
_gwa_hits() {
  local _glob="${1}" _dir="${2}" _p
  [[ -d "${_dir}" ]] || return 0
  local -a _prune=()
  for _p in "${_GWA_SCAN_PRUNE[@]}"; do
    _prune+=("--exclude-dir=${_p}")
  done
  grep -rn --include="${_glob}" "${_prune[@]}" -E 'uses:[[:space:]]' \
    "${_dir}" 2>/dev/null | sed "s|^${REPO_ROOT}/||"
}

# _gwa_split <hit> -- set _GWA_FILE / _GWA_LINENO / _GWA_TEXT from one
# `<path>:<lineno>:<content>` record. Split by hand rather than by IFS
# because the content half routinely contains colons of its own.
_gwa_split() {
  local _hit="${1}" _rest
  _GWA_FILE="${_hit%%:*}"
  _rest="${_hit#*:}"
  _GWA_LINENO="${_rest%%:*}"
  _GWA_TEXT="${_rest#*:}"
}

# _gwa_workflow_refs -- `<action>\t<ref>` for every literal `uses:` this
# repo's own workflows declare. Duplicates are left in; the caller folds
# them, because "the same ref at forty call sites" and "two different
# refs" are different facts and only the second is a problem.
_gwa_workflow_refs() {
  local _hit
  while IFS= read -r _hit; do
    _gwa_split "${_hit}"
    _gwa_is_comment "${_GWA_TEXT}" && continue
    [[ "${_GWA_TEXT}" =~ ${_GWA_USES_RE} ]] || continue
    printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
  done < <(_gwa_hits '*.yaml' "${REPO_ROOT}/${_GWA_WORKFLOW_DIR_REL}"
           _gwa_hits '*.yml' "${REPO_ROOT}/${_GWA_WORKFLOW_DIR_REL}")
}

# _gwa_generated_refs -- `<file>\t<lineno>\t<action>\t<ref>` for every
# literal `uses:` written by a shell script, i.e. every ref that ends up
# in a workflow dependabot will never read here.
_gwa_generated_refs() {
  local _hit
  while IFS= read -r _hit; do
    _gwa_split "${_hit}"
    _gwa_is_comment "${_GWA_TEXT}" && continue
    [[ "${_GWA_TEXT}" =~ ${_GWA_USES_RE} ]] || continue
    printf '%s\t%s\t%s\t%s\n' \
      "${_GWA_FILE}" "${_GWA_LINENO}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
  done < <(_gwa_hits '*.sh' "${REPO_ROOT}")
}

# _run_generated_workflow_actions -- the lint.
_run_generated_workflow_actions() {
  echo "--- Running generated-workflow action ref lockstep lint ---"

  local -A _own=()
  local _action _ref
  while IFS=$'\t' read -r _action _ref; do
    [[ -n "${_action}" ]] || continue
    case " ${_own[${_action}]:-} " in
      *" ${_ref} "*) ;;
      *) _own["${_action}"]="${_own[${_action}]:-}${_own[${_action}]:+ }${_ref}" ;;
    esac
  done < <(_gwa_workflow_refs)

  local _file _lineno _checked=0 _violations=0 _expected
  while IFS=$'\t' read -r _file _lineno _action _ref; do
    [[ -n "${_action}" ]] || continue
    _checked=$(( _checked + 1 ))
    _expected="${_own[${_action}]:-}"

    if [[ -z "${_expected}" ]]; then
      printf '%s:%s: %s@%s -- this repo never uses %s itself, so no dependabot PR ever bumps this ref\n' \
        "${_file}" "${_lineno}" "${_action}" "${_ref}" "${_action}"
      _violations=$(( _violations + 1 ))
      continue
    fi
    if [[ "${_expected}" == *' '* ]]; then
      printf '%s:%s: %s@%s -- this repo pins %s at more than one ref (%s), so there is no single ref for the generated copy to follow\n' \
        "${_file}" "${_lineno}" "${_action}" "${_ref}" "${_action}" "${_expected}"
      _violations=$(( _violations + 1 ))
      continue
    fi
    if [[ "${_ref}" != "${_expected}" ]]; then
      printf '%s:%s: %s@%s -- %s/ pins %s@%s; the generated copy disagrees\n' \
        "${_file}" "${_lineno}" "${_action}" "${_ref}" \
        "${_GWA_WORKFLOW_DIR_REL}" "${_action}" "${_expected}"
      _violations=$(( _violations + 1 ))
    fi
  done < <(_gwa_generated_refs)

  if [[ "${_violations}" -gt 0 ]]; then
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_generated_workflow_actions \
      "${_violations} generated workflow action ref(s) out of lockstep with ${_GWA_WORKFLOW_DIR_REL}/. A shell script that writes a workflow puts its \`uses:\` refs outside dependabot, which reads workflow FILES -- and outside the upstream-release watch, which leaves \`uses:\` version refs to dependabot. Holding the generated copy equal to this repo's own is what makes dependabot's bump reach it: bump both in the same commit."
    return 1
  fi

  if [[ "${_checked}" -eq 0 ]]; then
    # A clean line over a scan that read nothing is how a lint silently
    # stops covering anything -- a renamed generator, a moved directory, a
    # matcher that no longer matches. Silence must not read as lockstep.
    _die ci_generated_workflow_actions \
      "no generated workflow action ref found anywhere under ${REPO_ROOT}. This lint exists because a script that writes a workflow hides its \`uses:\` refs from dependabot; finding none means the scan stopped matching, not that the repo is clean."
    return 1
  fi

  echo "generated-workflow action ref lockstep lint: clean (${_checked} generated ref(s) checked against ${_GWA_WORKFLOW_DIR_REL}/)"
}
