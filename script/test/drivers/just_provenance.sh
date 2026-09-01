#!/usr/bin/env bash
# drivers/just_provenance.sh - "every site that obtains the `just` runner
# names the one pinned version" per-tool driver for the self-test
# dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_just_provenance. Follows drivers/arch_literal.sh /
# drivers/action_ref_agreement.sh conventions (sourced lib, uses
# ${REPO_ROOT}, _log_* / _die, no main, region-delimited opt-out).
#
# ── The hazard ──────────────────────────────────────────────────────────────
#
# `just` is this project's only control surface: every container operation
# is a recipe, so the runner IS the interface. It reached a developer
# through four independent provenance paths that shared no version with
# one another -- a bare `apk add` of alpine's package in the tooling
# image, `extractions/setup-just` with its version input omitted, the
# official installer with no --tag, and whatever a host package manager
# carried, all four presented as interchangeable. Measured 2026-08-28 the
# spread was 37 minors.
#
# That is not cosmetic. A recipe using newer syntax passes on a developer
# host and fails in CI; a semantic change between the versions makes an
# in-image test assert something the real user path no longer does, and
# stay green while doing it. A floating CI install turns the suite red on
# a day nobody touched the repo, with an unrelated diff apparently to
# blame.
#
# Three mechanisms should each have caught it and each was individually
# blind: DL3018 ("pin versions in apk add") is disabled by policy in
# dist/.hadolint.yaml; the release smoke check asserted only that the
# runner exited 0, which catches removal and never staleness; and the
# tooling image's tag is a content hash of its Dockerfile, which by
# construction cannot see what the package manager resolved to. Nothing
# in the tree compared any pair of the four.
#
# ── Why this is a lint and not a list ───────────────────────────────────────
#
# The site set is COMPUTED from the tree: every file under the scanned
# roots is read, and every logical line carrying an acquisition marker is
# a site. A guard named for "every path that installs the runner" that
# instead consulted a remembered list of four would pass on exactly the
# fifth path added tomorrow -- the failure it exists to prevent.
#
# What IS a fixed table is the vocabulary of acquisition: the markers
# below name package-manager verbs and the two upstream sources. That is
# the detector, not the population, in the same way arch_literal.sh
# carries a table of architecture spellings and computes the Dockerfile
# set. The residual limit, stated rather than papered over: an acquisition
# mechanism spelled in none of these ways (a package manager not listed, a
# vendored binary committed to the tree) is not detected. Every mechanism
# this tree has ever used is here, and widening it to shapes with no
# instances would trade measured precision for guesswork.
#
# ── What counts as pinned ───────────────────────────────────────────────────
#
# Per mechanism, because the evidence differs per mechanism:
#
#   the upstream release URL   the version must come from the declaration,
#                              so the URL names JUST_VERSION, not a literal
#   the setup action           a `just-version:` input
#   the official installer     a `--tag` argument
#   a package manager          NOTHING pins it -- the registry decides.
#                              Such a site must be advisory (below)
#
# Evidence is looked for in the site's LOGICAL line (backslash
# continuations joined, which is how both the Dockerfile RUN and the
# shipped installer pipeline are written) plus the following non-comment
# lines up to the first blank one, which is how a YAML `uses:` reaches the
# `with:` block underneath it.
#
# Comment lines are not sites: a comment installs nothing, and prose about
# this rule (this header, the accessor's, the ADR) must not violate it.
# The advisory markers are the one exception, being comments by design.
#
# ── The advisory marker ─────────────────────────────────────────────────────
#
# A path that CANNOT be pinned is legitimate -- init.sh prints apt / brew
# / cargo for a user who has no runner at all -- but it must say so where
# it is written, and say why:
#
#   # just-provenance: advisory-begin -- <why this cannot be pinned>
#   ...
#   # just-provenance: advisory-end
#
# A region, not a per-line note, because these sites live inside heredocs
# whose body is printed to the user: the marker has to sit outside the
# text it exempts. A marker with no reason after `--` is refused; a mute
# nobody has to justify is how the four paths came to read as equivalent
# in the first place. Unbalanced markers (an unterminated begin, an
# unmatched end) fail the lint -- a silently swallowed region would
# re-open exactly this hole.
#
# ── Scope ───────────────────────────────────────────────────────────────────
#
# The trees that actually provision: dockerfile/ (the tooling and smoke
# images), .github/workflows/ (CI), dist/ (the shipped tree every
# downstream repo executes) and script/ (base's own tooling). NOT doc/ or
# test/: a README sentence and a spec fixture install nothing.
#
# This file excludes ITSELF, by its own resolved path rather than by a
# hardcoded name. It is the one file in the scanned trees whose text names
# every marker by construction, so scanning it would let the driver's own
# table satisfy the non-vacuity floor below -- the scan would then be
# green because it found itself, which is the failure mode this driver
# exists to refuse.

# ── The just provenance pin lint ─────────────────────────────────────────────

# The scanned trees, repo-root-relative. Each must exist AND hold at least
# one file: an empty root would make the scan pass vacuously.
readonly _JP_SCAN_ROOTS=('dockerfile' '.github/workflows' 'dist' 'script')

# Marker text for the advisory region, and the separator its reason must
# follow. advisory-begin / advisory-end are tested before anything else so
# the shared prefix cannot make one read as the other.
readonly _JP_ADVISORY_BEGIN='just-provenance: advisory-begin'
readonly _JP_ADVISORY_END='just-provenance: advisory-end'
readonly _JP_ADVISORY_SEP='--'

# How far past the logical line pin evidence may sit. A YAML step reaches
# its `with:` block in two lines; the window stops at the first blank line
# so it cannot wander into an unrelated step.
readonly _JP_WINDOW=8

# The acquisition vocabulary, and the pin evidence each mechanism admits.
# Parallel arrays (not one packed string) because every marker here is
# itself a regex full of alternation, and a packed field separator would
# have to be chosen against them.
readonly _JP_MARKER_RE=(
  '(casey/just|releases/download/[^"]*just)'
  'setup-just'
  'just\.systems/install\.sh'
  '(apk add|apt-get install|apt install|brew install|cargo install|dnf install|yum install|pacman -S|snap install|pkg install|port install|choco install|scoop install|winget install|npm install|pipx install|go install|asdf install|mise install|mise use|nix-env)([^a-zA-Z0-9_-]|.*[^a-zA-Z0-9_-])just([^a-zA-Z0-9_.-]|$)'
)
# Empty = the mechanism has no pinnable form at all; such a site must be
# advisory.
readonly _JP_PIN_RE=(
  'JUST_VERSION'
  'just-version:'
  '--tag'
  ''
)

# ── Counters ────────────────────────────────────────────────────────────────

_JP_SITES=0
_JP_PINNED=0
_JP_ADVISORY=0
_JP_FILES=0
_JP_CANDIDATES=0

_jp_reset() {
  _JP_SITES=0
  _JP_PINNED=0
  _JP_ADVISORY=0
  _JP_FILES=0
  _JP_CANDIDATES=0
}

# _jp_has_reason <line> <marker> -- does the marker carry a `-- <why>`?
_jp_has_reason() {
  local _line="${1}" _marker="${2}" _tail
  _tail="${_line#*"${_marker}"}"
  [[ "${_tail}" =~ ^[[:space:]]*${_JP_ADVISORY_SEP}[[:space:]]*[^[:space:]] ]]
}

# _jp_is_comment <line> -- is this line's first non-blank character a `#`?
_jp_is_comment() {
  local _t="${1#"${1%%[![:space:]]*}"}"
  [[ "${_t}" == '#'* ]]
}

# _jp_scan_file <abs-path> <rel-path> <report-varname>
#
# Appends one line per finding to the named report variable.
_jp_scan_file() {
  local _abs="${1}" _rel="${2}"
  local -n _jp_report="${3}"

  local -a _lines=()
  mapfile -t _lines < "${_abs}"
  local _n="${#_lines[@]}"
  if [[ "${_n}" -eq 0 ]]; then
    return 0
  fi
  _JP_FILES=$(( _JP_FILES + 1 ))

  local _i=0 _lineno _line _joined _window _in_advisory=0 _begin_line=0
  local _m _w _hit
  while [[ "${_i}" -lt "${_n}" ]]; do
    _lineno=$(( _i + 1 ))
    _line="${_lines[_i]}"

    if [[ "${_line}" == *"${_JP_ADVISORY_BEGIN}"* ]]; then
      if ! _jp_has_reason "${_line}" "${_JP_ADVISORY_BEGIN}"; then
        _jp_report+="${_rel}:${_lineno}: advisory-begin with no stated reason (append \" ${_JP_ADVISORY_SEP} <why this path cannot be pinned>\")"$'\n'
      fi
      _in_advisory=1
      _begin_line="${_lineno}"
      _i=$(( _i + 1 ))
      continue
    fi
    if [[ "${_line}" == *"${_JP_ADVISORY_END}"* ]]; then
      if [[ "${_in_advisory}" -eq 0 ]]; then
        _jp_report+="${_rel}:${_lineno}: unmatched advisory-end (no open advisory-begin)"$'\n'
      fi
      _in_advisory=0
      _i=$(( _i + 1 ))
      continue
    fi
    if _jp_is_comment "${_line}"; then
      _i=$(( _i + 1 ))
      continue
    fi

    # Join backslash continuations, so an instruction split across
    # physical lines is classified as one thing.
    _joined="${_line}"
    while [[ "${_joined}" == *\\ && $(( _i + 1 )) -lt "${_n}" ]]; do
      _joined="${_joined%\\} ${_lines[_i + 1]}"
      _i=$(( _i + 1 ))
    done

    # The evidence window: the logical line plus the following non-comment
    # lines, up to the first blank one.
    _window="${_joined}"
    for (( _w = _i + 1; _w < _n && _w <= _i + _JP_WINDOW; _w++ )); do
      if [[ -z "${_lines[_w]//[[:space:]]/}" ]]; then
        break
      fi
      if _jp_is_comment "${_lines[_w]}"; then
        continue
      fi
      _window+=$'\n'"${_lines[_w]}"
    done

    for _m in "${!_JP_MARKER_RE[@]}"; do
      if [[ ! "${_joined}" =~ ${_JP_MARKER_RE[_m]} ]]; then
        continue
      fi
      _hit="${BASH_REMATCH[0]}"
      _JP_SITES=$(( _JP_SITES + 1 ))

      if [[ "${_in_advisory}" -eq 1 ]]; then
        _JP_ADVISORY=$(( _JP_ADVISORY + 1 ))
      elif [[ -z "${_JP_PIN_RE[_m]}" ]]; then
        _jp_report+="${_rel}:${_lineno}: a package manager cannot be pointed at the pin -- '${_hit}'. Obtain the runner from the pinned upstream release instead, or record this site as advisory."$'\n'
      elif [[ "${_window}" =~ ${_JP_PIN_RE[_m]} ]]; then
        _JP_PINNED=$(( _JP_PINNED + 1 ))
      else
        _jp_report+="${_rel}:${_lineno}: unpinned -- '${_hit}' names no version; the site carries no '${_JP_PIN_RE[_m]}'."$'\n'
      fi
      break
    done

    _i=$(( _i + 1 ))
  done

  if [[ "${_in_advisory}" -eq 1 ]]; then
    _jp_report+="${_rel}:${_begin_line}: unterminated advisory-begin (no closing advisory-end)"$'\n'
  fi
  return 0
}

# _jp_candidates <outarray> <file>... -- the files worth reading: those
# whose text mentions the runner's name at all. Every marker above
# requires it, and so does every advisory marker, so a file without it
# cannot hold a site. A prefilter, not an exclusion list: it is derived
# from the files' own contents.
_jp_candidates() {
  local -n _jpc_out="${1}"; shift
  local _tmp _status=0 _f
  _jpc_out=()
  # grep writes to a temp file rather than into a pipe or a command
  # substitution: its status has to be read DIRECTLY, because status 2
  # (an unreadable file, a bad invocation) must never be
  # indistinguishable from status 1 ("nothing matched"). A command
  # substitution would also drop the NUL separators -Z emits.
  _tmp="$(mktemp)"
  grep -lIZ -e 'just' -- "$@" > "${_tmp}" || _status=$?
  if [[ "${_status}" -gt 1 ]]; then
    rm -f "${_tmp}"
    return 2
  fi
  while IFS= read -r -d '' _f; do
    _jpc_out+=("${_f}")
  done < "${_tmp}"
  rm -f "${_tmp}"
  return 0
}

_run_just_provenance() {
  echo "--- Running just provenance pin lint ---"

  local _self_dir _self
  _self_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
  _self="${_self_dir}/$(basename -- "${BASH_SOURCE[0]:-$0}")"

  local -a _files=()
  local _root _abs_root _file
  for _root in "${_JP_SCAN_ROOTS[@]}"; do
    _abs_root="${REPO_ROOT}/${_root}"
    if [[ ! -d "${_abs_root}" ]]; then
      _die ci_just_provenance \
        "scan root '${_root}/' not found under ${REPO_ROOT} -- the lint would pass vacuously. Point it at the trees that provision the runner."
      return 1
    fi
    local -a _root_files=()
    while IFS= read -r -d '' _file; do
      if [[ "${_file}" == "${_self}" ]]; then
        continue
      fi
      _root_files+=("${_file}")
    done < <(find "${_abs_root}" -type f -print0 2>/dev/null | sort -z)
    if [[ "${#_root_files[@]}" -eq 0 ]]; then
      _die ci_just_provenance \
        "scan root '${_root}/' holds no file the lint can read -- it would pass vacuously. Either the tree moved, or everything under it was excluded."
      return 1
    fi
    _files+=("${_root_files[@]}")
  done

  _jp_reset
  local -a _candidates=()
  if ! _jp_candidates _candidates "${_files[@]}"; then
    _die ci_just_provenance \
      "the candidate prefilter could not read the ${#_files[@]} file(s) under '${_JP_SCAN_ROOTS[*]}' -- treat that as 'the scan did not run', never as 'nothing matched'."
    return 1
  fi
  _JP_CANDIDATES="${#_candidates[@]}"

  local _report="" _rel
  for _file in "${_candidates[@]}"; do
    _rel="${_file#"${REPO_ROOT}"/}"
    _jp_scan_file "${_file}" "${_rel}" _report
  done

  if [[ -n "${_report}" ]]; then
    _die ci_just_provenance \
      "the runner is obtained without naming the pinned version:
${_report}One declaration (ARG JUST_VERSION in dockerfile/Dockerfile.test-tools) is read by every path, through dist/script/base/just-version.sh; nothing restates it. A path that genuinely cannot be pinned -- a host package manager installs whatever its registry carries -- is recorded where it is written, with its reason:
    # ${_JP_ADVISORY_BEGIN} ${_JP_ADVISORY_SEP} <why this path cannot be pinned>
    ...
    # ${_JP_ADVISORY_END}"
    return 1
  fi

  # Non-vacuity, both halves. A reader regression that stopped
  # recognising the markers would report agreement forever, in silence --
  # the same unnoticed green the four-way spread itself had.
  if [[ "${_JP_SITES}" -eq 0 ]]; then
    _die ci_just_provenance \
      "the ${_JP_CANDIDATES} candidate file(s) under '${_JP_SCAN_ROOTS[*]}' yielded no site that obtains the runner at all -- nothing was checked, so the lint would pass vacuously. The acquisition table, not the tree, is what to look at."
    return 1
  fi
  if [[ "${_JP_PINNED}" -eq 0 ]]; then
    _die ci_just_provenance \
      "${_JP_SITES} provenance site(s) found but no PINNED site among them -- 'every path names the pin' is an empty statement here. Either the pinned fetch was removed, or the evidence patterns stopped matching it."
    return 1
  fi

  echo "just provenance lint: clean (${_JP_SITES} site(s) across ${_JP_FILES} file(s); ${_JP_PINNED} pinned, ${_JP_ADVISORY} advisory)"
}
