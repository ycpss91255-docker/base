#!/usr/bin/env bash
# single_issue_pr.sh - Fail a pull request whose merge would close more
# than one issue.
#
# Usage: PR_CLOSING_REFS=<owner/repo#N per line> [PR_COMMITS=<messages>] single_issue_pr.sh
#
# Exits 1 and names every issue on stderr when PR_CLOSING_REFS holds more
# than one distinct reference, base#1629. Closing keywords in PR_COMMITS
# count too: the repo squashes with COMMIT_MESSAGES.

set -euo pipefail

main() {
  local -a refs=()
  local ref
  while IFS= read -r ref; do
    [[ -n "${ref}" ]] && refs+=("${ref}")
  done < <({
    printf '%s\n' "${PR_CLOSING_REFS:-}"
    printf '%s\n' "${PR_COMMITS:-}" |
      { grep -oiE '\b(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#[0-9]+' || true; } |
      grep -oE '#[0-9]+'
  } | sort -u)

  if ((${#refs[@]} > 1)); then
    printf 'single-issue-pr: this PR closes %d issues: %s\n' \
      "${#refs[@]}" "${refs[*]}" >&2
    return 1
  fi
  return 0
}

main "$@"
