#!/usr/bin/env bash
#
# coverage_badge.sh - render the RELEASE coverage badge as a self-contained
# SVG committed to the repo (doc/badge/coverage.svg).
#
# WHY (ADR-00000008, per-release coverage figure amendment): the README used
# to draw a STATIC `Coverage-Kcov` shields.io badge. It read the same string
# whatever coverage did, so it looked like information and carried none. The
# figure itself is computed on every coverage run by
# script/test/drivers/coverage_gate.sh and then discarded with the CI run.
#
# The three properties that decided the shape:
#
#   - SELF-CONTAINED SVG, committed. Nothing external renders it, so it
#     needs no public repo (most downstream repos are private) and no
#     `raw.githubusercontent.com` URL, which would break on the move to the
#     company GitLab -- the exact coupling the self-hosted gate removed.
#   - REGENERATED IN THE RELEASE COMMIT, by the release bump, alongside
#     `.version` and the CHANGELOG promotion. Refreshing it per merge would
#     produce a commit per merge whose whole content is one digit moving.
#   - STAMPED WITH ITS VERSION. The badge reads `coverage vX.Y.Z`, so a
#     figure that is one release old cannot be misread as the coverage of
#     `main`. A bare percentage is the same failure as the static badge: it
#     looks current and is not.
#
# WHERE THE NUMBER COMES FROM: this script re-runs the gate's OWN merge math
# (it sources coverage_gate.sh; the per-line union and the path-alias
# canonicalisation are not re-implemented here) over the kcov reports in
# <root>/coverage/ -- the output of `just test coverage`. That is the only
# source with no CI coupling at all: it works identically on a workstation,
# under GitHub Actions and under GitLab CI, and needs no API, token or
# artifact download. The cost is a local kcov run before a release, which is
# minutes; releases are rare.
#
# THE REFUSAL IS THE POINT: a release whose coverage never ran must not
# publish a stale or an invented number. This script refuses -- writing
# nothing, leaving any existing badge untouched -- when there is no report,
# when the reports are older than the commit being released, or when
# instrumented sources are modified in the worktree. `--unmeasured` renders
# "not measured" for the current version: it states the absence rather than
# inventing or silently keeping a figure.
#
# Usage:
#   coverage_badge.sh [options]
#
# Options:
#   --repo-root <path>   Repo to render for (default: git toplevel of cwd).
#   --version <vX.Y.Z>   Version the figure belongs to (default: <root>/.version).
#   --out <path>         SVG to write (default: <root>/doc/badge/coverage.svg).
#   --report <path>      Cobertura report to read (repeatable). Default:
#                        discovered under <root>/coverage/.
#   --unmeasured         Render "not measured" for <version> instead of a
#                        figure. Never used by the release bump.
#   -h, --help           Show this help.
#
# Exit:
#   0 = badge written
#   1 = refused (no usable measurement of the commit being released)
#   2 = arg / environment error

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" &> /dev/null && pwd)"
readonly SCRIPT_DIR

# The gate is the single implementation of the merge math (per-line union
# across shard reports + kcov path-alias canonicalisation). Sourcing it --
# rather than re-deriving a rate here -- is what keeps the badge and the
# gate from ever disagreeing about what the project rate is.
readonly GATE="${SCRIPT_DIR}/../test/drivers/coverage_gate.sh"

readonly DEFAULT_OUT_REL="doc/badge/coverage.svg"

# Paths whose content the coverage run measures or builds. A modification to
# any of them makes an existing report a measurement of a DIFFERENT tree.
# Everything else (`.version`, the CHANGELOG, the badge itself) is a release
# edit and must NOT count: the bump makes those edits before this step runs.
readonly SOURCE_PATHSPEC=('*.sh' '*.bats' '*.bash' '*justfile*' '*Dockerfile*')

# The header block from `# Usage:` to the first non-comment line is the
# help text: one source, so an option cannot be documented in the file and
# missing from `--help`.
usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
}

err() { printf '[coverage-badge] %s\n' "$*" >&2; }

# ── Measurement ──────────────────────────────────────────────────────────────

# discover_reports <root> -- print one cobertura path per line.
#   A local `just test coverage` run writes kcov's own merged report at
#   coverage/kcov-merged/cobertura.xml; that ALONE is the project report.
#   A sharded layout (CI artifacts unpacked locally) has one report per
#   shard directory. Exactly ONE report per shard is taken: a directory can
#   hold both a per-run and a kcov-merged report, and passing both would
#   feed the same shard's lines in twice.
discover_reports() {
  local _root="$1" _dir _xml
  if [[ -f "${_root}/coverage/kcov-merged/cobertura.xml" ]]; then
    printf '%s\n' "${_root}/coverage/kcov-merged/cobertura.xml"
    return 0
  fi
  for _dir in "${_root}"/coverage/*/; do
    [[ -d "${_dir}" ]] || continue
    if [[ -f "${_dir}kcov-merged/cobertura.xml" ]]; then
      printf '%s\n' "${_dir}kcov-merged/cobertura.xml"
      continue
    fi
    while IFS= read -r _xml; do
      printf '%s\n' "${_xml}"
      break
    done < <(find "${_dir}" -name cobertura.xml -type f | sort)
  done
}

# head_epoch <root> -- commit time of HEAD, in seconds.
head_epoch() {
  git -C "$1" log -1 --format=%ct HEAD 2>/dev/null
}

# assert_measures_head <root> <report>... -- return 1 (with a reason on
# stderr) unless the reports can be shown to describe HEAD's tree.
#
# Two facts, both local and both CI-agnostic. A report written BEFORE the
# commit being released measured an older tree. A modified instrumented
# source means the worktree is not the commit either -- and the release
# commit will contain it, so the figure would describe neither.
assert_measures_head() {
  local _root="$1"; shift
  local _head _mtime _report _dirty

  _head="$(head_epoch "${_root}")"
  if [[ -z "${_head}" ]]; then
    err "REFUSING: ${_root} has no HEAD commit, so there is nothing to" \
        "attribute a coverage figure to."
    return 1
  fi

  for _report in "$@"; do
    _mtime="$(stat -c %Y "${_report}" 2>/dev/null)"
    if [[ -z "${_mtime}" ]]; then
      err "REFUSING: cannot read the mtime of ${_report}."
      return 1
    fi
    if (( _mtime < _head )); then
      err "REFUSING: ${_report} is older than the commit being released;" \
          "it measured an earlier tree. Re-run \`just test coverage\`."
      return 1
    fi
  done

  _dirty="$(git -C "${_root}" status --porcelain --untracked-files=no \
    -- "${SOURCE_PATHSPEC[@]}" 2>/dev/null)"
  if [[ -n "${_dirty}" ]]; then
    err "REFUSING: instrumented sources are modified in the worktree, so" \
        "the reports do not describe the tree being released:"
    printf '%s\n' "${_dirty}" >&2
    return 1
  fi

  return 0
}

# measured_rate <report>... -- print the merged project line rate.
# Delegates to the gate. The gate exits 1 when the rate is BELOW
# COVERAGE_MIN, which is a release decision, not a rendering one: the figure
# is still the figure, and it renders red. Only exit 2 (no/unreadable/empty
# reports) means there is no rate to publish.
measured_rate() {
  local _out _rc
  _out="$(_coverage_gate_run "$@" 2>/dev/null)"
  _rc=$?
  if (( _rc >= 2 )); then
    return 1
  fi
  if [[ "${_out}" =~ merged\ line\ rate\ ([0-9.]+)% ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# ── Rendering ────────────────────────────────────────────────────────────────

# grade_colour <rate> -- shields' own flat palette, so the badge reads the
# way the removed Codecov one did.
grade_colour() {
  awk -v r="$1" 'BEGIN {
    if (r + 0 >= 90) { print "#4c1";     exit }
    if (r + 0 >= 80) { print "#97ca00";  exit }
    if (r + 0 >= 70) { print "#a4a61d";  exit }
    if (r + 0 >= 60) { print "#dfb317";  exit }
    if (r + 0 >= 50) { print "#fe7d37";  exit }
    print "#e05d44"
  }'
}

# render_svg <label> <value> <colour> -- a flat-square badge, matching the
# `style=flat-square` the README's other badges use. No gradient, no
# external font file, no network reference: everything a renderer needs is
# in the file.
render_svg() {
  local _label="$1" _value="$2" _colour="$3"
  # 11px DejaVu Sans averages a shade under 7px per character; 7 with a
  # 12px pad is a hair generous, which is the safe direction (text inside
  # its block rather than clipped by it).
  local _lw=$(( ${#_label} * 7 + 12 ))
  local _vw=$(( ${#_value} * 7 + 12 ))
  local _w=$(( _lw + _vw ))
  cat <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="${_w}" height="20"
     role="img" aria-label="${_label}: ${_value}">
  <title>${_label}: ${_value}</title>
  <rect width="${_lw}" height="20" fill="#555"/>
  <rect x="${_lw}" width="${_vw}" height="20" fill="${_colour}"/>
  <g font-family="DejaVu Sans,Verdana,Geneva,sans-serif" font-size="11"
     fill="#fff" text-anchor="middle">
    <text x="$(( _lw / 2 ))" y="14">${_label}</text>
    <text x="$(( _lw + _vw / 2 ))" y="14">${_value}</text>
  </g>
</svg>
SVG
}

# write_badge <out> <label> <value> <colour> -- render to a temp file and
# move it into place, so a failed render never leaves a half-written badge
# where the previous good one was.
write_badge() {
  local _out="$1"; shift
  local _tmp
  mkdir -p "$(dirname "${_out}")" || return 1
  _tmp="$(mktemp "${_out}.XXXXXX")" || return 1
  if ! render_svg "$@" > "${_tmp}"; then
    rm -f "${_tmp}"
    return 1
  fi
  mv -f "${_tmp}" "${_out}"
}

# ── Entry ────────────────────────────────────────────────────────────────────

main() {
  # Strict mode is set HERE, not at file scope: this file carries the
  # `BASH_SOURCE == $0` guard, so it is sourceable, and a sourced file that
  # turns nounset on leaves it on in its caller (ADR-00000013's sibling
  # contract, asserted by sourceable_scripts_spec).
  set -uo pipefail

  local _root="" _version="" _out="" _unmeasured=0 _line=""
  local -a _reports=()

  while (( $# > 0 )); do
    case "$1" in
      --repo-root) _root="${2:?--repo-root expects <path>}"; shift 2 ;;
      --version)   _version="${2:?--version expects <vX.Y.Z>}"; shift 2 ;;
      --out)       _out="${2:?--out expects <path>}"; shift 2 ;;
      --report)    _reports+=("${2:?--report expects <path>}"); shift 2 ;;
      --unmeasured) _unmeasured=1; shift ;;
      -h|--help)   usage; return 0 ;;
      *)           err "unknown option: $1"; usage >&2; return 2 ;;
    esac
  done

  if [[ -z "${_root}" ]]; then
    _root="$(git rev-parse --show-toplevel 2>/dev/null)"
    if [[ -z "${_root}" ]]; then
      err "not inside a git repo and no --repo-root given"
      return 2
    fi
  fi
  if [[ ! -d "${_root}" ]]; then
    err "no such repo root: ${_root}"
    return 2
  fi
  [[ -n "${_out}" ]] || _out="${_root}/${DEFAULT_OUT_REL}"

  if [[ -z "${_version}" ]]; then
    if [[ -r "${_root}/.version" ]]; then
      read -r _version < "${_root}/.version"
    fi
    if [[ -z "${_version}" ]]; then
      err "no --version given and ${_root}/.version is missing or empty;" \
          "the figure must name the release it belongs to"
      return 2
    fi
  fi

  if (( _unmeasured == 1 )); then
    write_badge "${_out}" "coverage ${_version}" "not measured" "#9f9f9f" \
      || return 2
    printf 'coverage badge: %s -> not measured\n' "${_version}"
    return 0
  fi

  if (( ${#_reports[@]} == 0 )); then
    while IFS= read -r _line; do
      [[ -n "${_line}" ]] && _reports+=("${_line}")
    done < <(discover_reports "${_root}")
  fi
  if (( ${#_reports[@]} == 0 )); then
    err "REFUSING: no coverage report under ${_root}/coverage/. Run" \
        "\`just test coverage\` on the commit being released; the badge is" \
        "never carried over from the previous release."
    return 1
  fi

  assert_measures_head "${_root}" "${_reports[@]}" || return 1

  # shellcheck source=../test/drivers/coverage_gate.sh disable=SC1091
  if ! source "${GATE}"; then
    err "cannot source the coverage gate at ${GATE}"
    return 2
  fi

  local _rate
  _rate="$(measured_rate "${_reports[@]}")"
  if [[ -z "${_rate}" ]]; then
    err "REFUSING: the reports under ${_root}/coverage/ yielded no line" \
        "rate. Re-run \`just test coverage\`."
    return 1
  fi

  local _value _colour
  _value="$(awk -v r="${_rate}" 'BEGIN{printf "%.1f", r}')%"
  _colour="$(grade_colour "${_rate}")"
  write_badge "${_out}" "coverage ${_version}" "${_value}" "${_colour}" \
    || return 2
  printf 'coverage badge: %s -> %s (%s)\n' "${_version}" "${_value}" "${_out}"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
