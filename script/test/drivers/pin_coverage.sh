#!/usr/bin/env bash
# drivers/pin_coverage.sh - "every third-party version this repo names is
# declared to the watch" per-tool driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_pin_coverage. Follows drivers/self_hosted_guard.sh conventions
# (sourced lib, uses ${REPO_ROOT}, _log_* / _die, no main).
#
# ── Why this lint is the load-bearing half of the watch ─────────────────────
#
# The watch reads a table of pins. Where that table comes from decides
# whether the mechanism survives contact with the next year of edits.
#
# A hand-maintained roster is the version of this that fails, and it fails
# the same way every time it has been tried in this tree: the roster and
# the thing it describes are edited by different people on different days,
# so the roster silently stops describing anything. The downstream repo
# list, the release archive's path list and the lint-tool table all had to
# be converted from lists into derivations for exactly that reason.
#
# So the table is DERIVED: every watched version carries a `tool-pin:`
# marker on the line that declares it, and the table is whatever those
# markers say. That removes the "roster forgot a tool" failure but opens
# its mirror image -- a pin added with NO marker is simply not in the
# table, and an unwatched dependency is precisely the state the watch
# exists to end. Nothing about a derivation makes it complete.
#
# This lint is what makes it complete. It reads the same trees, recognises
# the SHAPES a third-party version declaration takes, and fails when one is
# not some marker's target. Adding a pin without saying how to watch it
# therefore fails a PR check rather than depending on a reviewer noticing.
#
# ── What counts as a declaration, and why the boundary sits there ───────────
#
# The scope is "a third-party version this repo names THAT DEPENDABOT
# CANNOT BUMP". Dependabot reads `uses:` version refs IN WORKFLOW FILES
# and does that job well -- its open login-action PR is the evidence -- so
# covering them here would produce two mechanisms with opinions about one
# dependency, which is worse than one. What it provably cannot see is a
# Dockerfile ARG, a FROM tag, an image named inside a `run:` step, a
# release-download URL, a `git clone -b <tag>`, a `uses:` ref pinned to a
# BRANCH, and any of those written inside a shell script that GENERATES a
# file. Those shapes are the detector, and they live in
# script/watch/lib.sh alongside the grammar so the lint and the watch can
# never disagree about what a pin is.
#
# The release-URL and `clone -b` shapes are worth naming separately,
# because leaving them out was not a gap at the margin: they are the forms
# hadolint, shellcheck and the three bats helpers were pinned in before
# this change hoisted them into ARGs. A guard that cannot see the shape of
# the defect it exists to prevent only appears to work.
#
# ── What it checks ──────────────────────────────────────────────────────────
#
#   1. The markers parse. A malformed one is a lint failure, not a pin
#      quietly missing from the table.
#   2. Every pinned entry names a resolver check.sh implements. A typo
#      caught by a scheduled run weeks later is weeks of not watching.
#   3. Names are unique. Two markers sharing a name make `pins.sh --value`
#      and `--set` ambiguous, and the ambiguity resolves silently.
#   4. No declaration in the scanned trees lacks a marker.
#   5. It is not vacuous: the walk yielded files, and the table yielded
#      pinned entries. A reader regression that matched nothing would
#      otherwise report a clean tree forever.
#   6. Every pruned tree is one git ignores. The walk covers the whole
#      repository, so the prune list is the only way to remove something
#      from all of the above -- and it must not become the quiet place to
#      put an awkward pin.

# The pin registry: grammar, reader and detector. Sourced rather than
# re-implemented so the lint and the watch cannot drift apart about what a
# declaration is.
# shellcheck source=script/watch/lib.sh
source "${SCRIPT_DIR}/../watch/lib.sh"

_run_pin_coverage() {
  echo "--- Running pin-coverage lint ---"

  local _table
  if ! _table="$(_pin_read "${REPO_ROOT}")"; then
    _die ci_pin_coverage \
      "the tool-pin markers did not parse (the reader's complaint is above). A marker that does not parse is a dependency that is not being watched, so this is a failure rather than a skipped entry."
    return 1
  fi

  local -a _files=()
  local _f _file_list
  _file_list="$(_pin_files "${REPO_ROOT}")" || _file_list=""
  while IFS= read -r _f; do
    [[ -n "${_f}" ]] && _files+=("${_f}")
  done <<< "${_file_list}"
  if [[ "${#_files[@]}" -eq 0 ]]; then
    _die ci_pin_coverage \
      "the walk yielded no Dockerfile, workflow or script at all -- nothing was read, so this lint would pass vacuously. script/watch/lib.sh's scanned shapes and prune list, not the tree, are what to look at."
    return 1
  fi

  local _state _name _resolver _coord _pattern _skip _current _file _line
  local _pinned=0 _unpinned=0 _known _r
  local -A _seen=()
  local -a _bad_resolver=() _duplicate=()
  while IFS=$'\t' read -r _state _name _resolver _coord _pattern _skip \
      _current _file _line; do
    # An empty table still yields one empty record through a here-string,
    # and an empty name is not a subscript.
    [[ -z "${_name}" ]] && continue
    if [[ -n "${_seen["${_name}"]:-}" ]]; then
      _duplicate+=("${_name} (${_seen["${_name}"]} and ${_file}:${_line})")
    fi
    _seen["${_name}"]="${_file}:${_line}"
    case "${_state}" in
      "${_PIN_STATE_PINNED}")
        _pinned=$(( _pinned + 1 ))
        _known=0
        for _r in "${_PIN_RESOLVERS[@]}"; do
          [[ "${_resolver}" == "${_r}" ]] && _known=1
        done
        if [[ "${_known}" -eq 0 ]]; then
          _bad_resolver+=("${_file}:${_line}: ${_name} names resolver '${_resolver}'")
        fi
        ;;
      "${_PIN_STATE_UNPINNED}") _unpinned=$(( _unpinned + 1 )) ;;
    esac
  done <<< "${_table}"

  if [[ "${#_duplicate[@]}" -gt 0 ]]; then
    _die ci_pin_coverage \
      "two tool-pin markers share a name:
$(printf '  %s\n' "${_duplicate[@]}")
\`pins.sh --value\` and \`--set\` address a pin BY NAME, so a shared name makes both of them read and rewrite whichever record came first -- silently. Give each declaration its own name."
    return 1
  fi

  if [[ "${#_bad_resolver[@]}" -gt 0 ]]; then
    _die ci_pin_coverage \
      "a tool-pin marker names a resolver the watch does not implement:
$(printf '  %s\n' "${_bad_resolver[@]}")
Known resolvers: $(printf '%s ' "${_PIN_RESOLVERS[@]}"). An unknown one is not a pin that fails later -- it is a pin nothing checks in the meantime."
    return 1
  fi

  if [[ "${_pinned}" -eq 0 ]]; then
    _die ci_pin_coverage \
      "the ${#_files[@]} scanned file(s) yielded no PINNED entry at all -- the reader, not the tree, is what to look at. A table with no pins would make every watch run come back clean."
    return 1
  fi

  # The prune list is the one hand-kept thing left in the registry, and an
  # entry added to it silently removes a whole tree from every check
  # above. So it is checked rather than trusted: every entry must be a
  # tree git already ignores (i.e. generated), which makes "prune the
  # directory the awkward pin lives in" fail here instead of passing
  # quietly. Skipped when REPO_ROOT is not a readable git repository --
  # the container mounts the worktree without its git dir, and a guard
  # that cannot run must not invent a verdict.
  local _entry
  local -a _tracked_prune=()
  if git -C "${REPO_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
    for _entry in "${_PIN_SCAN_PRUNE[@]}"; do
      [[ "${_entry}" == '.git' ]] && continue
      [[ -e "${REPO_ROOT}/${_entry}" ]] || continue
      git -C "${REPO_ROOT}" check-ignore -q "${_entry}" \
        || _tracked_prune+=("${_entry}")
    done
  fi
  if [[ "${#_tracked_prune[@]}" -gt 0 ]]; then
    _die ci_pin_coverage \
      "script/watch/lib.sh prunes a tree that git does NOT ignore:
$(printf '  %s\n' "${_tracked_prune[@]}")
The prune list exists for generated trees. Pruning a tree the repo ships removes every version in it from the watch AND from this lint, and nothing else would report that."
    return 1
  fi

  local _uncovered
  _uncovered="$(_pin_uncovered "${REPO_ROOT}")"
  if [[ -n "${_uncovered}" ]]; then
    _die ci_pin_coverage \
      "a third-party version is declared with no tool-pin marker:
${_uncovered}
Nothing watches these. Add a comment line ABOVE each one -- a \`#\` followed
by one of these bodies. (Written without the leading \`#\` on purpose: this
file is one of the files the reader scans, and a line-leading marker in it
would be read as a real pin.)
  ${_PIN_MARKER} <name> github-release <owner>/<repo>
  ${_PIN_MARKER} <name> dockerhub <namespace>/<repo> pattern=<ERE>
or, when the dependency genuinely cannot name a version here (an apt/apk
package, a moving base tag, a branch ref), declare it so the watch keeps
reporting it:
  ${_PIN_MARKER} unpinned <name> -- <why>
\`${_PIN_MARKER} ignore -- <why>\` is for a line whose shape matched but
which is not a third-party version. See script/watch/lib.sh."
    return 1
  fi

  echo "pin-coverage lint: clean (${_pinned} pinned, ${_unpinned} declared unpinned, across ${#_files[@]} file(s); no undeclared version)"
}
