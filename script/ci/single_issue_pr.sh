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
  local -A seen=()
  local -a refs=()
  local ref other dup
  while IFS= read -r ref; do
    [[ -n "${ref}" ]] || continue
    seen[${ref}]=1
  done < <({
    printf '%s\n' "${PR_CLOSING_REFS:-}"
    # Text inside a fenced code block, inline code or an HTML comment is
    # quoted or hidden, not a directive.
    {
      printf '%s\n' "${PR_COMMITS:-}"
      # Offline fallback: with PR_CLOSING_REFS unset the PR body is parsed.
      if [[ -z "${PR_CLOSING_REFS+x}" ]]; then
        printf '%s\n' "${PR_BODY:-}"
      fi
    } |
      awk '/^[[:space:]]*```/ { infence = !infence; next } !infence' |
      sed 's/`[^`]*`//g' |
      sed -e ':a' -e 'N' -e '$!ba' -e 's/<!--[^>]*-->//g' |
      { grep -oiE '\b(close[sd]?|fix(e[sd])?|resolve[sd]?)(\*\*|__)?:?(\*\*|__)?[[:space:]]+#[0-9]+(,[[:space:]]*#[0-9]+)*' || true; } |
      grep -oE '#[0-9]+'
  } | sort -u)

  # Issue numbers are per repository: owner/repo#N values stay distinct.
  # A bare #N is the same issue as a qualified ref with that number.
  for ref in "${!seen[@]}"; do
    dup=0
    if [[ "${ref}" != */* ]]; then
      for other in "${!seen[@]}"; do
        if [[ "${other}" == */* && "${other##*#}" == "${ref##*#}" ]]; then
          dup=1
        fi
      done
    fi
    ((dup)) || refs+=("${ref}")
  done

  if ((${#refs[@]} > 1)); then
    local reason
    reason="$(printf '%s\n' "${PR_BODY:-}" |
      sed -n 's/^Single-issue-exempt:[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p' |
      head -n 1)"
    if [[ -n "${reason}" ]]; then
      printf 'single-issue-pr: exempt: %s\n' "${reason}" >&2
      return 0
    fi
    printf 'single-issue-pr: this PR closes %d issues: %s\n' \
      "${#refs[@]}" "${refs[*]}" >&2
    return 1
  fi
  return 0
}

main "$@"
