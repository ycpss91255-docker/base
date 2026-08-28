#!/usr/bin/env bash
#
# check.sh - compare every declared pin against its upstream.
#
# The network half of the upstream-release watch. pins.sh says what this
# checkout pins; this says what upstream ships, and the difference is the
# work. It opens no PR and merges nothing: the workflow that calls it turns
# each drifted pin into ONE PR whose CI run is the answer to "does the new
# version break us", and a human reads that answer.
#
# ── Resolution, per source ──────────────────────────────────────────────────
#
#   github-release <owner>/<repo>
#       GET api.github.com/repos/<owner>/<repo>/releases/latest -> tag_name.
#       That endpoint already excludes drafts and pre-releases, which is
#       the property wanted: a release-candidate tag must never become a
#       PR against this repo's gates. GITHUB_TOKEN is sent when present
#       (the anonymous limit is 60/h and this walks ~10 repos).
#
#   dockerhub <namespace>/<repo> [pattern=<ERE>]
#       GET hub.docker.com/v2/repositories/<ns>/<repo>/tags, newest first,
#       filtered by <pattern> and reduced by version sort. The pattern is
#       what makes "latest alpine" mean the newest 3.x SERIES tag rather
#       than `edge` or `latest`: which tags are comparable is a property of
#       the upstream's tagging scheme, so it is declared per pin.
#
# ── When a source cannot be reached ─────────────────────────────────────────
#
# The pin is reported UNRESOLVED and the run FAILS (exit 1). It is not
# reported as up to date, and it is not skipped quietly. A watch whose
# silence is indistinguishable from "nothing to do" is the exact defect
# this mechanism exists to end -- three of the drifts it was built for had
# a mechanism that would have caught them and said nothing. A source that
# answers but yields no comparable tag is treated the same way, because a
# filter that matches nothing is a broken filter, not an absence of
# releases.
#
# Exit codes:
#   0   every pinned entry is current (or its upstream is on a skip list)
#   10  at least one pin has drifted
#   1   at least one source could not be resolved, OR the pin table itself
#       could not be read (a renamed tree, a marker that does not parse).
#       Both mean "this run proves nothing", and both must be impossible
#       to mistake for the clean-week 0.
#   2   a usage error
#
# Usage:
#   ./script/watch/check.sh              # human report on stdout
#   ./script/watch/check.sh --drift-tsv  # drifted pins, TSV on stdout;
#                                        # the full report on stderr
#
# Style: Google Shell Style Guide.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

_CHECK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
readonly _CHECK_DIR
# shellcheck source=script/watch/lib.sh
source "${_CHECK_DIR}/lib.sh"

PIN_REPO_ROOT="${PIN_REPO_ROOT:-$(cd -- "${_CHECK_DIR}/../.." && pwd)}"

# Exit code for "a pin has drifted". Distinct from 1 so a caller can tell
# "the watch worked and found work" from "the watch could not run".
readonly _WATCH_EXIT_DRIFT=10

# curl, spelled once. Retries because a transient 5xx from either API
# would otherwise fail the run and cost a human a look at a green problem.
readonly _WATCH_CURL_OPTS=(
  --fail --silent --show-error --location
  --retry 3 --retry-all-errors --retry-delay 2 --max-time 30
)

# Overridable so a spec can point the resolvers at a local fixture server
# instead of the real APIs.
WATCH_GITHUB_API="${WATCH_GITHUB_API:-https://api.github.com}"
WATCH_DOCKERHUB_API="${WATCH_DOCKERHUB_API:-https://hub.docker.com/v2}"

# _watch_fetch <url> -- print the body, or fail.
_watch_fetch() {
  local _url="${1}"
  local -a _args=("${_WATCH_CURL_OPTS[@]}")
  if [[ "${_url}" == "${WATCH_GITHUB_API}"* && -n "${GITHUB_TOKEN:-}" ]]; then
    _args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl "${_args[@]}" -- "${_url}"
}

# _watch_latest_github_release <owner/repo>
_watch_latest_github_release() {
  local _coord="${1}" _body _tag
  _body="$(_watch_fetch "${WATCH_GITHUB_API}/repos/${_coord}/releases/latest")" || return 1
  _tag="$(printf '%s' "${_body}" \
    | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed -e 's/.*"\([^"]*\)"$/\1/')" || return 1
  [[ -n "${_tag}" ]] || return 1
  printf '%s\n' "${_tag}"
}

# _watch_latest_dockerhub <namespace/repo> <pattern>
#
# The highest tag matching <pattern>. Version sort, not "the first page's
# first entry": Docker Hub orders by push time, and a patch release to an
# older series is pushed after a newer series' first tag.
_watch_latest_dockerhub() {
  local _coord="${1}" _pattern="${2}" _body _tags
  _body="$(_watch_fetch \
    "${WATCH_DOCKERHUB_API}/repositories/${_coord}/tags?page_size=100")" || return 1
  _tags="$(printf '%s' "${_body}" \
    | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed -e 's/.*"\([^"]*\)"$/\1/' \
    | grep -E "${_pattern}" \
    | LC_ALL=C sort -V)" || return 1
  [[ -n "${_tags}" ]] || return 1
  printf '%s\n' "${_tags}" | tail -n 1
}

# _watch_latest <resolver> <coordinate> <pattern>
_watch_latest() {
  local _resolver="${1}" _coord="${2}" _pattern="${3}"
  case "${_resolver}" in
    github-release) _watch_latest_github_release "${_coord}" ;;
    dockerhub)
      [[ "${_pattern}" == "-" ]] && _pattern='.'
      _watch_latest_dockerhub "${_coord}" "${_pattern}"
      ;;
    *)
      printf 'watch: unknown resolver %s\n' "${_resolver}" >&2
      return 1
      ;;
  esac
}

# _watch_is_newer <current> <candidate>
#
# True when <candidate> sorts strictly above <current>. Both are compared
# with any leading `v` removed, so `v0.10.0` and `0.10.0` are one version;
# equal strings are never newer, which is what keeps a re-run of a current
# pin from proposing itself.
_watch_is_newer() {
  local _cur="${1#v}" _new="${2#v}" _top
  [[ "${_cur}" == "${_new}" ]] && return 1
  _top="$(printf '%s\n%s\n' "${_cur}" "${_new}" | LC_ALL=C sort -V | tail -n 1)"
  [[ "${_top}" == "${_new}" ]]
}

# _watch_is_skipped <skip-field> <version> -- is <version> on the pin's
# declared refusal list?
_watch_is_skipped() {
  local _skip="${1}" _version="${2}" _one
  [[ "${_skip}" == "-" ]] && return 1
  local _old_ifs="${IFS}"
  IFS=','
  # shellcheck disable=SC2206 # deliberate word-split on the comma IFS.
  local _list=(${_skip})
  IFS="${_old_ifs}"
  for _one in "${_list[@]}"; do
    [[ "${_one}" == "${_version}" || "${_one#v}" == "${_version#v}" ]] && return 0
  done
  return 1
}

# ── The run ─────────────────────────────────────────────────────────────────

_WATCH_DRIFT=()
_WATCH_UNRESOLVED=()
_WATCH_CURRENT=()
_WATCH_REFUSED=()
_WATCH_FLOATING=()

# _watch_scan -- fill the five report buckets. Returns non-zero when the
# pin TABLE could not be read at all, which is a different failure from an
# upstream that did not answer and must stay distinguishable from it.
_watch_scan() {
  local _state _name _resolver _coord _pattern _skip _current _file _line
  local _latest _table

  # Command substitution, NOT `done < <(_pin_read ...)`. A process
  # substitution discards the producer's status, so an unreadable tree --
  # a renamed directory, a marker with a typo'd option that stops the
  # reader mid-file -- would end this loop quietly with every bucket
  # empty. That prints DRIFTED (0) / UNRESOLVED (0) / CURRENT (0) and
  # exits 0: `count=0` in the workflow, the bump skipped, the job green,
  # and INDISTINGUISHABLE from a clean week, on the one run nobody reads
  # precisely because it normally does nothing. lib.sh avoids the same
  # hazard in _pin_read and _pin_uncovered for the same reason; this was
  # the single line that decided the exit code and did not.
  _table="$(_pin_read "${PIN_REPO_ROOT}")" || return 1

  while IFS=$'\t' read -r _state _name _resolver _coord _pattern _skip \
      _current _file _line; do
    # A table with no records still yields one empty line through a
    # here-string.
    [[ -z "${_state}" ]] && continue
    case "${_state}" in
      "${_PIN_STATE_IGNORE}") continue ;;
      "${_PIN_STATE_UNPINNED}")
        _WATCH_FLOATING+=("${_name}"$'\t'"${_file}:${_line}")
        continue
        ;;
    esac
    if ! _latest="$(_watch_latest "${_resolver}" "${_coord}" "${_pattern}")"; then
      _WATCH_UNRESOLVED+=("${_name}"$'\t'"${_resolver} ${_coord}"$'\t'"${_current}")
      continue
    fi
    if [[ "${_current}" == "${_latest}" ]] || ! _watch_is_newer "${_current}" "${_latest}"; then
      _WATCH_CURRENT+=("${_name}"$'\t'"${_current}")
    elif _watch_is_skipped "${_skip}" "${_latest}"; then
      _WATCH_REFUSED+=("${_name}"$'\t'"${_current}"$'\t'"${_latest}"$'\t'"${_file}:${_line}")
    else
      _WATCH_DRIFT+=("${_name}"$'\t'"${_current}"$'\t'"${_latest}"$'\t'"${_file}"$'\t'"${_line}")
    fi
  done <<< "${_table}"
}

_watch_report() {
  local _row
  printf '=== upstream-release watch ===\n\n'

  printf 'DRIFTED (%d) -- one PR each, CI decides, a human merges\n' \
    "${#_WATCH_DRIFT[@]}"
  for _row in "${_WATCH_DRIFT[@]+"${_WATCH_DRIFT[@]}"}"; do
    printf '  %s\n' "${_row}" | awk -F'\t' \
      '{printf "%-16s %-12s -> %-12s  %s:%s\n", $1, $2, $3, $4, $5}'
  done
  printf '\n'

  printf 'UNRESOLVED (%d) -- the source did not answer; this is a FAILURE,\n' \
    "${#_WATCH_UNRESOLVED[@]}"
  printf '  not a clean run. An unreachable upstream must never read as current.\n'
  for _row in "${_WATCH_UNRESOLVED[@]+"${_WATCH_UNRESOLVED[@]}"}"; do
    printf '  %s\n' "${_row}" | awk -F'\t' \
      '{printf "%-16s via %-40s pinned at %s\n", $1, $2, $3}'
  done
  printf '\n'

  printf 'REFUSED (%d) -- upstream moved, this repo declared skip=<version>\n' \
    "${#_WATCH_REFUSED[@]}"
  for _row in "${_WATCH_REFUSED[@]+"${_WATCH_REFUSED[@]}"}"; do
    printf '  %s\n' "${_row}" | awk -F'\t' \
      '{printf "%-16s %-12s (upstream %s, refused at %s)\n", $1, $2, $3, $4}'
  done
  printf '\n'

  printf 'FLOATING (%d) -- declared unpinned: no version to compare, so this\n' \
    "${#_WATCH_FLOATING[@]}"
  printf '  list is what the watch cannot watch. It is printed every run on purpose.\n'
  for _row in "${_WATCH_FLOATING[@]+"${_WATCH_FLOATING[@]}"}"; do
    printf '  %s\n' "${_row}" | awk -F'\t' '{printf "%-24s %s\n", $1, $2}'
  done
  printf '\n'

  printf 'CURRENT (%d)\n' "${#_WATCH_CURRENT[@]}"
  for _row in "${_WATCH_CURRENT[@]+"${_WATCH_CURRENT[@]}"}"; do
    printf '  %s\n' "${_row}" | awk -F'\t' '{printf "%-16s %s\n", $1, $2}'
  done
}

_watch_exit_status() {
  if [[ "${#_WATCH_UNRESOLVED[@]}" -gt 0 ]]; then
    return 1
  fi
  if [[ "${#_WATCH_DRIFT[@]}" -gt 0 ]]; then
    return "${_WATCH_EXIT_DRIFT}"
  fi
  return 0
}

main() {
  local _mode="${1:---report}"
  case "${_mode}" in
    --report|--drift-tsv) : ;;
    -h|--help)
      printf 'Usage: ./script/watch/check.sh [--report|--drift-tsv]\n' >&2
      return 2
      ;;
    *)
      printf 'watch: unknown option %s\n' "${_mode}" >&2
      return 2
      ;;
  esac

  if ! _watch_scan; then
    printf 'watch: the pin table could not be read -- NOTHING was compared,\n' >&2
    printf '  so this run says nothing about any pin. The reader complaint is above.\n' >&2
    return 1
  fi

  if [[ "${_mode}" == "--drift-tsv" ]]; then
    # stdout is the machine answer, stderr is the whole report -- INCLUDING
    # the unresolved and floating sections. A caller that reads only the
    # drift list would otherwise never see the two states that matter most:
    # a source that did not answer, and a dependency with no version to
    # compare. One invocation, because each one costs a walk of every
    # upstream API and two walks can disagree.
    _watch_report >&2
    local _row
    for _row in "${_WATCH_DRIFT[@]+"${_WATCH_DRIFT[@]}"}"; do
      printf '%s\n' "${_row}"
    done
  else
    _watch_report
  fi

  _watch_exit_status
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
