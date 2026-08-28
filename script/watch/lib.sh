#!/usr/bin/env bash
#
# watch/lib.sh - the pin registry: it reads the declaration sites, it is
# not a list of them.
#
# Sourced library (no main). Provides the marker grammar, the reader that
# derives the watched-tool table from the files that declare each version,
# and the detector that finds a version declaration NOT covered by a
# marker. pins.sh (CLI), check.sh (upstream comparison) and
# script/test/drivers/pin_coverage.sh (the lint) all read this one file.
#
# ── Why derived rather than listed ──────────────────────────────────────────
#
# A hand-maintained roster of "tools we watch" decays the moment somebody
# adds a pin without opening it -- the same failure mode as the downstream
# roster, the release archive's path list and the lint-tool table, each of
# which this repo has already had to convert from a list into a derivation.
# So there is no roster. Every watched version is declared where it is
# USED, on a marker comment attached to the line that names the version,
# and the table is whatever those markers say today.
#
# That alone would still decay in the other direction -- a pin added with
# no marker is invisible, and invisible is exactly the state this whole
# mechanism exists to end. So the derivation is paired with a DETECTOR:
# every line in the scanned trees whose shape is "a third-party version
# this repo names" must be the target of a marker. The pin-coverage lint
# fails the build when one is not. Adding a pin without declaring how to
# watch it is therefore not something a reviewer has to notice.
#
# ── The marker grammar ──────────────────────────────────────────────────────
#
# A marker is a comment line. Its TARGET is the next line that is neither
# blank nor a comment, and the version lives on that target line:
#
#   # tool-pin: <name> <resolver> <coordinate> [pattern=<re>] [skip=<v>,...]
#   ARG FOO_VERSION=1.2.3
#
#   # tool-pin: unpinned <name> -- <why it cannot be pinned here>
#   RUN apk add --no-cache bash git
#
#   # tool-pin: ignore -- <why this is not a third-party version>
#   ARG OURS=1.0
#
# `unpinned` is not an off switch. It is a DECLARATION that this dependency
# floats, and `check.sh` prints every one of them on every run, under its
# own heading, forever. Silence is what the audit found; a floating
# dependency that nobody has to be reminded of is how it got there.
#
# `skip=<v>[,<v>...]` records a version this repo has deliberately refused.
# It exists because of the opposite defect: dependabot never re-raises a
# version pair whose PR was closed, so closing one PR opts the repo out of
# that bump permanently and NOTHING in the config says so. Here the refusal
# is a line in the file that declares the pin, next to the version it
# refuses, visible to the next reader and checked by the lint.
#
# ── Resolvers ───────────────────────────────────────────────────────────────
#
#   github-release <owner>/<repo>   the latest non-prerelease release's tag
#   dockerhub <namespace>/<repo>    the highest tag matching `pattern=`
#
# `pattern=` is a POSIX ERE anchored by the resolver against a whole tag.
# It is what makes "latest alpine" mean the latest 3.x SERIES tag rather
# than `edge` or `latest`, and it is per-pin because what counts as a
# comparable tag is a property of the upstream, not of this repo.

# Sourced more than once in one shell (pins.sh from a spec that has
# already sourced the lint driver, say), the `readonly` declarations below
# would abort the caller. Guard rather than drop the readonly: the
# constants being immutable is what stops a caller from redefining the
# grammar out from under the lint.
if [[ -n "${_PIN_LIB_SOURCED:-}" ]]; then
  return 0
fi
_PIN_LIB_SOURCED=1

# ── Marker vocabulary ───────────────────────────────────────────────────────

# The marker's opening token. One string, so the reader, the lint's
# failure message and the specs cannot spell it three ways.
readonly _PIN_MARKER='tool-pin:'

# A marker is a comment whose BODY OPENS with that token. Prose that
# merely mentions it -- this file, a Dockerfile header explaining the
# convention, a failure message quoting it -- is not a marker. Anchoring
# rather than substring-matching is what lets the mechanism be documented
# in the same trees it scans.
readonly _PIN_MARKER_RE="^[[:space:]]*#+[[:space:]]*${_PIN_MARKER}"

# The three declaration states. `pinned` is comparable against upstream;
# `unpinned` is reported as floating and never compared; `ignore` is "this
# line's shape matched the detector but it is not a third-party version".
readonly _PIN_STATE_PINNED='pinned'
readonly _PIN_STATE_UNPINNED='unpinned'
readonly _PIN_STATE_IGNORE='ignore'

# Every resolver `check.sh` implements. Named here rather than there
# because the LINT has to reject an unknown resolver at the declaration
# site: a typo caught weeks later by a scheduled run is a pin nobody was
# watching in the meantime. A unit spec asserts check.sh dispatches every
# entry.
readonly _PIN_RESOLVERS=(
  github-release
  dockerhub
)

# What is NOT walked -- and nothing else. There is deliberately no list of
# trees to look in.
#
# A roster of scan roots is the same artefact as a roster of tools, one
# level up: it is hand-kept, it is edited by different people on different
# days from the trees it describes, and when it falls behind, the thing it
# stops covering goes silent rather than red. This repo had exactly that
# defect while the roots were `dockerfile`, `dist/dockerfile` and
# `.github/workflows` -- two live third-party versions sat outside them,
# both of them versions this repo BAKES INTO FILES IT SHIPS DOWNSTREAM,
# and one had drifted two minors behind base's own pin with nothing
# reporting it.
#
# So the walk is the whole repository and this is a PRUNE list. The
# failure mode inverts with it: forgetting to touch this file when a tree
# is added means the new tree IS scanned and the lint fires, rather than
# the new tree being quietly exempt.
#
# Every entry is a machine-local tree that is gitignored, and the lint
# asserts exactly that -- so this list cannot quietly grow to cover
# something the repo actually ships. `.prev-release/` earns its place
# twice over: it is `git archive` of PAST releases, and the versions in it
# are supposed to be stale. `.claude/` is the agent harness a checkout may
# or may not carry; scanning it would make the lint's verdict depend on
# whose machine it ran on, which is the one thing a gate must not do.
readonly _PIN_SCAN_PRUNE=('.git' 'log' '.prev-release' '.claude')

# The file shapes a version declaration can live in. `.sh` is here because
# of the two escapes above: a script that writes a `uses:` ref into a
# generated workflow, or seds an image tag into a downstream Dockerfile,
# is a declaration site exactly like the Dockerfile that spells it out --
# and it is one dependabot has no way to read at all.
readonly _PIN_SCAN_SHAPES=(
  -name 'Dockerfile' -o -name 'Dockerfile.*' -o -name '*.Dockerfile'
  -o -name '*.yaml' -o -name '*.yml' -o -name '*.sh'
)

# ── Declaration shapes the detector recognises ──────────────────────────────
#
# Deliberately NOT "every version-shaped token anywhere". The boundary is
# a third-party version THIS REPO NAMES THAT DEPENDABOT CANNOT BUMP:
# dependabot reads `uses:` version refs in WORKFLOW FILES and does that job
# well (its login-action PR is open and current), so duplicating it would
# produce two mechanisms disagreeing about one dependency. What it provably
# cannot see is a Dockerfile ARG, a FROM tag, an image named inside a
# `run:` step, a release-download URL, a `git clone -b <tag>`, a `uses:`
# ref that is a BRANCH rather than a version, and ANY of those written
# inside a shell script that generates a file.
#
# The three shapes after the original four were not additions of scope.
# They were the forms the staleness this whole mechanism was built for was
# ACTUALLY written in: hadolint and shellcheck were release-download URLs
# and the three bats helpers were `clone -b` tags, all of which this change
# hoisted into ARGs -- while the guard meant to stop them coming back could
# not see any of them. A guard blind to the shape of the defect it exists
# to prevent is worth very little.

# An `ARG <NAME>=<value>` whose value is a version number (`1.2.3`,
# `v0.10.0`, `3.21`) -- at least one dot, so `ARG USER_UID=1000` is not a
# version and needs no marker.
readonly _PIN_ARG_VERSION_RE='^v?[0-9]+(\.[0-9]+)+([+~.-][A-Za-z0-9.]+)?$'

# An `ARG <NAME>=<value>` whose value is an image reference with an
# explicit tag (`ubuntu:24.04`).
readonly _PIN_ARG_IMAGE_RE='^[a-z0-9]+([._/-][a-z0-9]+)*:[A-Za-z0-9][A-Za-z0-9._-]*$'

# A registry reference with an explicit numeric tag, as written inside a
# workflow `run:` step (`rhysd/actionlint:1.7.7`). Numeric-leading tag
# only: `${TEST_TOOLS_IMAGE}` and `image:latest` are not versions this can
# compare, and the first is our own image anyway.
readonly _PIN_RUN_IMAGE_RE='(^|[[:space:]"'"'"'])[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*:[0-9][A-Za-z0-9._-]*'

# A `uses:` ref that is neither a version tag nor a 40-hex commit --
# i.e. a branch, which dependabot has no way to advance.
readonly _PIN_USES_RE='uses:[[:space:]]*[A-Za-z0-9][A-Za-z0-9._-]*/[^[:space:]@]+@([^[:space:]#]+)'
readonly _PIN_USES_VERSION_RE='^(v?[0-9]+([._][0-9A-Za-z.-]*)?|[0-9a-f]{40})$'

# A release asset URL that names the version in its PATH:
# `.../releases/download/v2.12.0/hadolint-Linux-x86_64`. This is not a
# fifth shape bolted on -- it is the shape three of this repo's four
# staleness cases were actually written in before they were hoisted into
# ARGs, and the guard that is supposed to stop them coming back could not
# see it. Only a LITERAL counts: `releases/download/${FOO_VERSION}/` is
# the ARG's version, already covered by the ARG's own marker.
readonly _PIN_RELEASE_URL_RE='releases/download/v?[0-9][A-Za-z0-9._-]*/'

# `git clone --depth 1 -b v2.1.0 ...` -- the other pre-hoist shape, and
# the one the three bats helper libraries were pinned in. Anchored on the
# word `clone` by the caller so a `-b` flag to some other command cannot
# masquerade as a tag.
readonly _PIN_CLONE_REF_RE='(^|[[:space:]])(-b|--branch)[[:space:]]+["'"'"']?v?[0-9][A-Za-z0-9._-]*'

# An OFFICIAL image, which has no namespace and therefore no slash for the
# registry-reference shape above to anchor on (`alpine:3.21`, not
# `bats/bats:1.13.0`). The `docker run|pull|create|build` context is what
# keeps `sha256:1234...`, a `<host>:<port>` example and a `key: 3.11`
# mapping out of it.
readonly _PIN_DOCKER_CMD_RE='docker[[:space:]]+(run|pull|create|build)'
readonly _PIN_BARE_IMAGE_RE='(^|[[:space:]])[a-z0-9][a-z0-9._-]*:[0-9][A-Za-z0-9._-]*'

# The assignment shapes whose version is the WHOLE right-hand side: a
# Dockerfile `ARG`, and a shell assignment with or without a declaration
# keyword. Both DECOUPLE the version from the marker's coordinate, which
# is what lets a marker name `library/alpine` upstream while the line
# spells `3.21`. That decoupling is why hoisting a literal onto a line of
# its own is the standard fix for a version the reader cannot address.
readonly _PIN_ASSIGN_RE='^([[:space:]]*(ARG|local|readonly|declare|export)?[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=)(.*)$'

# ── Reader ──────────────────────────────────────────────────────────────────

# _pin_files <repo-root>
#
# Print every scanned file, repo-root-relative, one per line, sorted.
# Every file of a scanned SHAPE anywhere under <repo-root>, minus the
# pruned trees -- so a Dockerfile, workflow or script added tomorrow, at
# any depth, is scanned without touching this file.
#
# A tree that yields nothing at all is an error rather than an empty
# table: every caller would read "no pins declared" as a clean repo, which
# is the one answer this mechanism must never give by accident.
_pin_files() {
  local _root="${1}"
  local _abs _p
  local -a _found=() _prune=()
  for _p in "${_PIN_SCAN_PRUNE[@]}"; do
    _prune+=(-name "${_p}" -prune -o)
  done
  while IFS= read -r -d '' _abs; do
    _found+=("${_abs#"${_root}/"}")
  done < <(find "${_root}" "${_prune[@]}" -type f \
    \( "${_PIN_SCAN_SHAPES[@]}" \) -print0)
  if [[ "${#_found[@]}" -eq 0 ]]; then
    printf 'pin registry: no Dockerfile, workflow or script under %s\n' \
      "${_root}" >&2
    return 1
  fi
  printf '%s\n' "${_found[@]}" | LC_ALL=C sort
}

# _pin_unquote <value> -- strip one layer of matching quotes.
_pin_unquote() {
  local _v="${1}"
  if [[ "${_v}" == \"*\" || "${_v}" == \'*\' ]]; then
    _v="${_v:1:${#_v}-2}"
  fi
  printf '%s' "${_v}"
}

# _pin_rhs_value <rhs> -- the value on an assignment's right-hand side,
# with any trailing comment AND the whitespace in front of it removed.
# Dropping the comment alone leaves that whitespace attached to the
# version, and it does not stay local: it flows into the reported
# `from` field, into the branch name a bump builds and into whatever CI
# feeds from `pins.sh --value`.
_pin_rhs_value() {
  local _v="${1%%[[:space:]]#*}"
  _v="${_v%"${_v##*[![:space:]]}"}"
  printf '%s' "${_v}"
}

# _pin_rhs_tail <rhs> -- everything _pin_rhs_value dropped: the spacing
# and the trailing comment. `--set` puts it back verbatim, because the
# comment on a pin's line is where a "held at this version because ..."
# rationale lives -- the one line a reviewer of a bump proposal most needs
# to still be there.
_pin_rhs_tail() {
  local _v
  _v="$(_pin_rhs_value "${1}")"
  printf '%s' "${1#"${_v}"}"
}

# _pin_extract_value <target-line> <coordinate>
#
# The version the target line currently carries.
#
#   ARG <NAME>=<value>   ->  <value>, unquoted, comment stripped
#   <NAME>=<value>       ->  the same, for a shell declaration site
#   anything else        ->  the token following <coordinate>, separated by
#                            `:` (an image tag) or `@` (a ref)
#
# Anchoring the second form on the coordinate is what keeps extraction
# precise on a line that also carries flags, paths and other colons.
_pin_extract_value() {
  local _line="${1}" _coord="${2}"
  if [[ "${_line}" =~ ${_PIN_ASSIGN_RE} ]]; then
    _pin_unquote "$(_pin_rhs_value "${BASH_REMATCH[3]}")"
    return 0
  fi
  local _re="${_coord}[:@]([A-Za-z0-9][A-Za-z0-9._-]*)"
  if [[ "${_line}" =~ ${_re} ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# _pin_read <repo-root>
#
# THE table. One TSV record per marker:
#
#   <state> <name> <resolver> <coordinate> <pattern> <skip> <current> <file> <line>
#
# Empty fields are written as `-` so the record always has nine columns and
# `read` never collapses two of them. <line> is the TARGET line's number,
# because that is the line a bump rewrites.
_pin_read() {
  local _root="${1}"
  local _file _abs _lineno _line _target _target_no _rest _list
  local _state _name _resolver _coord _pattern _skip _current
  local -a _fields=()

  # Command substitution, not a process substitution feeding the loop: a
  # `< <(...)` redirection discards the producer's exit status, so a
  # missing scan root would end the loop quietly and this would return a
  # table of nothing with status 0 -- which every caller would read as
  # "the repo declares no pins" rather than "the reader could not look".
  _list="$(_pin_files "${_root}")" || return 1

  while IFS= read -r _file; do
    _abs="${_root}/${_file}"
    _lineno=0
    _state=""
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
      _lineno=$(( _lineno + 1 ))
      if [[ -z "${_state}" ]]; then
        [[ "${_line}" =~ ${_PIN_MARKER_RE} ]] || continue
        _rest="${_line#*"${_PIN_MARKER}"}"
        # shellcheck disable=SC2206 # deliberate word-split of the marker body.
        _fields=(${_rest%%--*})
        if [[ "${#_fields[@]}" -eq 0 ]]; then
          printf '%s:%d: %s marker carries no body\n' \
            "${_file}" "${_lineno}" "${_PIN_MARKER}" >&2
          return 1
        fi
        _pattern=""
        _skip=""
        case "${_fields[0]}" in
          "${_PIN_STATE_IGNORE}")
            _state="${_PIN_STATE_IGNORE}"
            _name="${_file}:${_lineno}"
            _resolver=""
            _coord=""
            ;;
          "${_PIN_STATE_UNPINNED}")
            _state="${_PIN_STATE_UNPINNED}"
            _name="${_fields[1]:-}"
            _resolver=""
            _coord=""
            if [[ -z "${_name}" ]]; then
              printf '%s:%d: unpinned marker names no dependency\n' \
                "${_file}" "${_lineno}" >&2
              return 1
            fi
            ;;
          *)
            _state="${_PIN_STATE_PINNED}"
            _name="${_fields[0]}"
            _resolver="${_fields[1]:-}"
            _coord="${_fields[2]:-}"
            if [[ -z "${_resolver}" || -z "${_coord}" ]]; then
              printf '%s:%d: pin %s names no resolver and coordinate\n' \
                "${_file}" "${_lineno}" "${_name}" >&2
              return 1
            fi
            local _kv
            for _kv in "${_fields[@]:3}"; do
              case "${_kv}" in
                pattern=*) _pattern="${_kv#pattern=}" ;;
                skip=*)    _skip="${_kv#skip=}" ;;
                *)
                  printf '%s:%d: pin %s carries unknown option %s\n' \
                    "${_file}" "${_lineno}" "${_name}" "${_kv}" >&2
                  return 1
                  ;;
              esac
            done
            ;;
        esac
        _target=""
        _target_no=0
        continue
      fi
      # Looking for the marker's target: the next line that is neither
      # blank nor another comment. A SECOND marker before that line is an
      # error, not a silent loss: both would otherwise claim one target
      # and only the first would ever be read.
      if [[ "${_line}" =~ ${_PIN_MARKER_RE} ]]; then
        printf '%s:%d: %s marker follows another with no target between them\n' \
          "${_file}" "${_lineno}" "${_PIN_MARKER}" >&2
        return 1
      fi
      [[ -z "${_line//[[:space:]]/}" ]] && continue
      [[ "${_line}" =~ ^[[:space:]]*# ]] && continue
      _target="${_line}"
      _target_no="${_lineno}"
      _current=""
      if [[ "${_state}" == "${_PIN_STATE_PINNED}" ]]; then
        if ! _current="$(_pin_extract_value "${_target}" "${_coord}")"; then
          printf '%s:%d: pin %s: no version for %s on its target line\n' \
            "${_file}" "${_target_no}" "${_name}" "${_coord}" >&2
          return 1
        fi
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\n' \
        "${_state}" "${_name}" "${_resolver:--}" "${_coord:--}" \
        "${_pattern:--}" "${_skip:--}" "${_current:--}" "${_file}" "${_target_no}"
      _state=""
    done < "${_abs}"
    if [[ -n "${_state}" ]]; then
      printf '%s: %s marker for %s has no target line after it\n' \
        "${_file}" "${_PIN_MARKER}" "${_name}" >&2
      return 1
    fi
  done <<< "${_list}"
}

# ── Detector ────────────────────────────────────────────────────────────────

# _pin_is_declaration <file> <line>
#
# True when the line declares a third-party version this repo names and
# dependabot cannot bump. See the shape table above for the forms and why
# the boundary sits where it does.
_pin_is_declaration() {
  local _file="${1}" _line="${2}"
  local _value _ref

  # Two shapes mean the same thing wherever they are written -- a release
  # asset URL and a `git clone -b <tag>` NAME a version in a Dockerfile
  # RUN and in a shell script alike -- so they are tested before the
  # per-file-kind split rather than duplicated into each arm.
  [[ "${_line}" =~ ${_PIN_RELEASE_URL_RE} ]] && return 0
  if [[ "${_line}" == *clone* && "${_line}" =~ ${_PIN_CLONE_REF_RE} ]]; then
    return 0
  fi
  if [[ "${_line}" =~ ${_PIN_DOCKER_CMD_RE} \
     && "${_line}" =~ ${_PIN_BARE_IMAGE_RE} ]]; then
    return 0
  fi

  if [[ "${_file}" == *Dockerfile* ]]; then
    if [[ "${_line}" =~ ^[[:space:]]*ARG[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=(.+)$ ]]; then
      _value="$(_pin_unquote "$(_pin_rhs_value "${BASH_REMATCH[1]}")")"
      [[ "${_value}" =~ ${_PIN_ARG_VERSION_RE} ]] && return 0
      [[ "${_value}" =~ ${_PIN_ARG_IMAGE_RE} ]] && return 0
      return 1
    fi
    # shellcheck disable=SC2016 # the literal expression opener, not an expansion.
    if [[ "${_line}" =~ ^[[:space:]]*FROM[[:space:]] && "${_line}" != *'${'* ]]; then
      [[ "${_line}" =~ ^[[:space:]]*FROM[[:space:]]+[^[:space:]]+:[^[:space:]]+ ]] && return 0
    fi
    return 1
  fi

  if [[ "${_file}" == *.sh ]]; then
    # A script that WRITES a version into a file it generates declares
    # that version as surely as the generated file would. Both live
    # instances were of this kind, and the `uses:` exemption below does
    # NOT carry over to them: dependabot reads workflow files, and a
    # `uses:` ref inside a shell heredoc is not one -- neither this repo's
    # updater nor the generated repo's (there is none) can advance it. So
    # here every `uses:` ref counts, version-shaped or not.
    [[ "${_line}" =~ ${_PIN_RUN_IMAGE_RE} ]] && return 0
    if [[ "${_line}" =~ ${_PIN_USES_RE} ]]; then
      _ref="${BASH_REMATCH[1]}"
      # shellcheck disable=SC2016 # the literal expression opener, not an expansion.
      [[ "${_ref}" == *'${'* ]] && return 1
      [[ "${_ref}" == './'* ]] && return 1
      return 0
    fi
    return 1
  fi

  # Workflows.
  [[ "${_line}" =~ ${_PIN_RUN_IMAGE_RE} ]] && return 0
  if [[ "${_line}" =~ ${_PIN_USES_RE} ]]; then
    _ref="${BASH_REMATCH[1]}"
    [[ "${_ref}" == './'* ]] && return 1
    [[ "${_ref}" =~ ${_PIN_USES_VERSION_RE} ]] && return 1
    return 0
  fi
  return 1
}

# _pin_uncovered <repo-root>
#
# Print `<file>:<line>: <text>` for every declaration that is not some
# marker's target. Prints nothing when the trees are fully declared.
#
# It re-walks the files rather than reusing _pin_read's records because
# the question is different: the reader asks "what did the markers say",
# and this asks "what did they NOT say". A shared walk would answer the
# second question with the first one's blind spots.
_pin_uncovered() {
  local _root="${1}"
  local _file _abs _lineno _line _key _covered_list _list
  local -A _covered=()

  # Both producers run in a command substitution for the reason spelled
  # out in _pin_read: a redirection would swallow their exit status.
  _covered_list="$(_pin_read "${_root}" | awk -F'\t' '{print $8 ":" $9}')" \
    || return 1
  _list="$(_pin_files "${_root}")" || return 1

  while IFS= read -r _key; do
    [[ -n "${_key}" ]] && _covered["${_key}"]=1
  done <<< "${_covered_list}"

  while IFS= read -r _file; do
    _abs="${_root}/${_file}"
    _lineno=0
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
      _lineno=$(( _lineno + 1 ))
      [[ "${_line}" =~ ^[[:space:]]*# ]] && continue
      if _pin_is_declaration "${_file}" "${_line}" \
         && [[ -z "${_covered["${_file}:${_lineno}"]:-}" ]]; then
        printf '%s:%d: %s\n' "${_file}" "${_lineno}" \
          "${_line#"${_line%%[![:space:]]*}"}"
      fi
    done < "${_abs}"
  done <<< "${_list}"
}
