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
# dependency, which is worse than one. What it provably cannot see is an
# assignment whose value is a version WHATEVER ITS KEYWORD, an image
# reference at a version tag WHEREVER it is written, a release-download
# URL, a `git clone -b <tag>`, a `uses:` ref pinned to a BRANCH, and any
# `uses:` ref outside .github/workflows/ -- notably one a shell script
# writes into a file it GENERATES. Those shapes are the detector, and they
# live in script/watch/lib.sh alongside the grammar so the lint and the
# watch can never disagree about what a pin is.
#
# "Whatever its keyword" was learned the same hard way as "wherever it is
# written". The detector recognised `ARG` and nothing else, while the
# registry's reader already EXTRACTED a version from `local`, `readonly`,
# `declare` and `export` -- and while this file's own advice for a version
# a marker cannot address is to hoist it onto a line of its own, which is
# how you write one of those four. Deleting the markers from the two the
# repo ships downstream left the lint clean.
#
# "Wherever it is written" is load-bearing and was learned the hard way.
# The detector recognised a namespace-less image only with a `docker
# run|pull|create|build` on the same line, which is a roster of CONTEXTS,
# and it failed the way every roster in this mechanism has failed: a
# compose `image:`, a job `container:` and the `sed` that rewrites a
# downstream `FROM` line all passed in silence. What keeps that from being
# paid for in false positives is a set of exemptions on the TOKEN -- a
# numeric name is a port or a UID:GID, a 32+-hex tag is a digest, a
# `-t`-introduced name is an image this repo BUILDS -- rather than another
# test on the line around it.
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
#   6. Every tree the prune list removes -- at any depth, since the
#      entries are basenames -- is one git ignores and does not track. The
#      walk covers the whole repository, so the prune list is the only way
#      to remove something from all of the above, and it must not become
#      the quiet place to put an awkward pin. It has no environment in
#      which it is skipped: where git cannot answer, the verdict is
#      carried in from the host, and where neither can, this DIES.
#   7. No `tool-pin:` marker sits in a file the walk EXEMPTS. The scan is
#      whole-tree minus prose and specs, and that exemption list is the
#      other way to remove something from every check above. A marker
#      written in an exempt file is a pin its author believes is watched
#      and which nothing reads -- the precise belief this mechanism
#      exists to make impossible -- so it fails here.

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
      "the walk yielded no scannable file at all -- nothing was read, so this lint would pass vacuously. script/watch/lib.sh's exempt shapes and prune list, not the tree, are what to look at."
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
  # above. So it is checked rather than trusted: every directory the prune
  # MATCHES -- at any depth, which is how `-name <entry> -prune` behaves --
  # must be a tree git ignores and does not track. That is what makes
  # "prune the directory the awkward pin lives in" fail here instead of
  # passing quietly.
  #
  # Where the verdict comes from, and why it is never absent. The check
  # needs git, and the suite's own container bind-mounts the checkout
  # WITHOUT a resolvable .git -- a worktree's `.git` is a file naming a
  # path outside the mount. This used to be an `if git ...` around the
  # whole guard, i.e. a pass on the environment the repo's local gate
  # actually runs in: a guard whose default on an environment it cannot
  # inspect is "clean" is fail-open, and this one guards the mechanism
  # that removes trees from every other check.
  #
  # So the answer is computed where git works and carried to where it does
  # not. `PIN_PRUNE_TRACKED` is set by test.sh on the HOST before the
  # compose run: `-` for clean, the offending paths otherwise. git wins
  # when it is readable, so a stale or hand-set value can never silence a
  # tree git can see. When neither source can answer, this DIES.
  local _prune_offenders
  if ! _prune_offenders="$(_pin_prune_offenders "${REPO_ROOT}")"; then
    if [[ -z "${PIN_PRUNE_TRACKED:-}" ]]; then
      _die ci_pin_coverage \
        "this lint cannot check its prune list: ${REPO_ROOT} is not a readable git repository and no host-computed verdict arrived in PIN_PRUNE_TRACKED. The prune list removes whole trees from the walk, from this lint and from the watch, so an unchecked one is the failure this guard exists for -- not a detail to skip. Run './script/test/test.sh --pin-coverage-only' on the host, or set PIN_PRUNE_TRACKED (\`-\` when clean) the way test.sh does for the compose run."
      return 1
    fi
    _prune_offenders="${PIN_PRUNE_TRACKED}"
    [[ "${_prune_offenders}" == '-' ]] && _prune_offenders=""
  fi
  if [[ -n "${_prune_offenders}" ]]; then
    local _off
    local -a _prune_bad=()
    while IFS= read -r _off; do
      [[ -n "${_off}" ]] && _prune_bad+=("${_off}")
    done <<< "${_prune_offenders}"
    _die ci_pin_coverage \
      "script/watch/lib.sh prunes a tree the repo tracks or does not ignore:
$(printf '  %s\n' "${_prune_bad[@]}")
The prune list exists for machine-local trees. Pruning a tree the repo ships removes every version in it from the watch AND from this lint, and nothing else would report that. Note the entries are BASENAMES: \`-name <entry> -prune\` matches at any depth, so an entry that is harmless at the root can still remove a tree deeper in."
    return 1
  fi

  # The exemption list is the other hand-kept thing in the scan surface,
  # and it removes a whole SHAPE from every check above. So it gets the
  # prune list's treatment: a marker written where the reader never looks
  # is caught here, by name, rather than becoming a pin its author
  # believes is watched and which nothing reads.
  local _exempt
  local -a _stray=()
  while IFS= read -r _exempt; do
    [[ -n "${_exempt}" ]] || continue
    grep -qE "${_PIN_MARKER_RE}" "${REPO_ROOT}/${_exempt}" 2>/dev/null \
      && _stray+=("${_exempt}")
  done <<< "$(_pin_exempt_files "${REPO_ROOT}")"
  if [[ "${#_stray[@]}" -gt 0 ]]; then
    _die ci_pin_coverage \
      "a ${_PIN_MARKER} marker sits in a file that is not scanned:
$(printf '  %s\n' "${_stray[@]}")
Prose and .bats specs are exempt from the walk (script/watch/lib.sh says why), so a marker in one is read by NOTHING: the watch never compares it, this lint never counts it, and the person who wrote it has every reason to believe otherwise. Move the declaration to a file the walk reads, or drop the marker."
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
