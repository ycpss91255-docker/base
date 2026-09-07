#!/usr/bin/env bash
# verify-tag-on-main.sh -- refuse to cut a release from a commit that is not
# on the default branch.
#
# ── Why the question needs a home ────────────────────────────────────────
#
# The org's tag rulesets (base#1124) require a green CI status check before a
# `v*` tag is admitted, which closes "tag an untested commit". A tag ruleset
# cannot also express "and this commit is on main": it asks only whether the
# TARGET COMMIT passed its checks, and a commit that went green inside a pull
# request keeps that green check forever -- even if the PR was rejected and
# the commit never reached main. Anyone with push access can then put a `v*`
# tag on that off-main commit, the caller's `call-release` fires, and this
# worker publishes a GitHub Release from code that was never reviewed to
# merge (base#1143).
#
# The invariant this asserts is the one the ruleset cannot: the commit being
# released is an ancestor of the remote's main. It is deliberately ONE rule,
# with no branch on how the run reached this worker:
#
#   tag push      GITHUB_SHA is the tagged commit -- on main it is admitted,
#                 off main it is refused.
#   direct call   the auto-release path (release-version.sh's `version`
#                 input) runs on a push to main, so GITHUB_SHA is main's own
#                 tip, trivially an ancestor of origin/main, and the same
#                 single rule admits it with no special case to keep honest.
#
# A commit that is NOT on main is refused however the run got here.
#
# ── Why it does not fetch ────────────────────────────────────────────────
#
# This runs a git query and nothing else. The release job's checkout is
# shallow and carries no remote main ref, so release-worker.yaml fetches
# origin/main and THEN runs this -- the same split preflight.sh /
# release-archive.sh use, logic here and wiring in the YAML. Keeping the
# network out makes the decision host-testable against a local repo with no
# remote. If the main ref is absent the query fails CLOSED: a refusal, never
# a pass, because failing to know is not evidence the commit is on main.
#
# Input : GITHUB_SHA    the commit under release (required)
#         VTM_MAIN_REF  the ref whose history defines "on main"
#                       (default: origin/main; overridable so a test can name
#                       a local branch, and so a repo whose default branch is
#                       not `main` can point this at the right one)
# Output: nothing on success. A refusal writes to stderr, naming the commit.
# Exit  : 0 when the commit is on main; 1 when it is not, when GITHUB_SHA is
#         unset, or when the main ref cannot be read. CI-host-agnostic: only
#         release-worker.yaml binds GITHUB_SHA and the fetch to GitHub.

# Strict mode only when executed directly; when sourced (tests), respect the
# caller's settings. Same guard release-ref.sh uses.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

readonly _VTM_DEFAULT_MAIN_REF='origin/main'

# _vtm_main -- assert GITHUB_SHA is an ancestor of the main ref, or refuse.
_vtm_main() {
  local sha main_ref
  sha="${GITHUB_SHA:-}"
  main_ref="${VTM_MAIN_REF:-${_VTM_DEFAULT_MAIN_REF}}"

  if [[ -z "${sha}" ]]; then
    printf 'verify-tag-on-main: GITHUB_SHA is unset -- there is no commit to check. This runs in the release job, where GitHub sets it to the commit under release.\n' >&2
    return 1
  fi

  # The main ref must resolve to a commit in this checkout. An absent ref
  # (main was never fetched, or the name is wrong) is refused rather than
  # answered "not an ancestor": not knowing where main is does not make the
  # commit off-main, and treating it that way would fail every legitimate
  # release the day a fetch step was renamed. Refuse loudly instead.
  if ! git rev-parse --verify --quiet "${main_ref}^{commit}" > /dev/null; then
    printf 'verify-tag-on-main: %s does not name a commit in this checkout. The release step must fetch main (git fetch --no-tags origin main) before this runs; refusing rather than assuming the commit is on main.\n' \
      "${main_ref}" >&2
    return 1
  fi

  if git merge-base --is-ancestor "${sha}" "${main_ref}"; then
    return 0
  fi

  printf 'verify-tag-on-main: %s is not an ancestor of %s. It passed CI -- which is why the tag ruleset (base#1124) admitted the tag -- but it is not on main: a commit that went green inside a PR that was never merged can still be tagged. Refusing to cut a release from code that is not on main (base#1143).\n' \
    "${sha}" "${main_ref}" >&2
  return 1
}

# Only run when executed directly, not when sourced (for testing).
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  _vtm_main "$@"
fi
