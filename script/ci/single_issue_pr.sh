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
  local -A by_num=()
  local -a refs=()
  local ref num
  while IFS= read -r ref; do
    [[ -n "${ref}" ]] || continue
    num="${ref##*#}"
    # One issue named two ways is one issue; keep the qualified form.
    if [[ -z "${by_num[${num}]:-}" || "${ref}" == */* ]]; then
      by_num[${num}]="${ref}"
    fi
  done < <({
    printf '%s\n' "${PR_CLOSING_REFS:-}"
    # Text inside a fenced code block, inline code or an HTML comment is
    # quoted or hidden, not a directive.
    printf '%s\n' "${PR_COMMITS:-}" |
      awk '/^[[:space:]]*```/ { infence = !infence; next } !infence' |
      sed 's/`[^`]*`//g' |
      sed -e ':a' -e 'N' -e '$!ba' -e 's/<!--[^>]*-->//g' |
      { grep -oiE '\b(close[sd]?|fix(e[sd])?|resolve[sd]?):?[[:space:]]+#[0-9]+(,[[:space:]]*#[0-9]+)*' || true; } |
      grep -oE '#[0-9]+'
  } | sort -u)

  for num in "${!by_num[@]}"; do
    refs+=("${by_num[${num}]}")
  done

  if ((${#refs[@]} > 1)); then
    printf 'single-issue-pr: this PR closes %d issues: %s\n' \
      "${#refs[@]}" "${refs[*]}" >&2
    return 1
  fi
  return 0
}

main "$@"
