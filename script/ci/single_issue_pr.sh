#!/usr/bin/env bash
# single_issue_pr.sh - Fail a pull request whose merge would close more
# than one issue.
#
# Usage: PR_CLOSING_REFS=<owner/repo#N per line> single_issue_pr.sh
#
# Exits 1 and names every issue on stderr when PR_CLOSING_REFS holds more
# than one distinct reference, base#1629.

set -euo pipefail

main() {
  local -a refs=()
  local ref
  while IFS= read -r ref; do
    [[ -n "${ref}" ]] && refs+=("${ref}")
  done < <(printf '%s\n' "${PR_CLOSING_REFS:-}" | sort -u)

  if ((${#refs[@]} > 1)); then
    printf 'single-issue-pr: this PR closes %d issues: %s\n' \
      "${#refs[@]}" "${refs[*]}" >&2
    return 1
  fi
  return 0
}

main "$@"
