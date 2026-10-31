#!/usr/bin/env bash
#
# config_gen_mutation_targets.sh -- the host-side mutation baseline of the
# config generator (base#1464).
#
# Usage:
#   CONFIG_GEN_MUTATION_CONTEXT=pr|main-push \
#     ./script/test/config_gen_mutation_targets.sh [--repo <dir>] <out-dir>
#
# The build context has no Git history, so "which Go files changed" is
# decided here, on the host, and handed to the build as files. <dir>
# (default: this checkout) must be the top of a Git work tree.
#
# Base, by CONFIG_GEN_MUTATION_CONTEXT (pr when unset; empty or any other
# value is refused):
#   pr         git merge-base HEAD origin/main
#   main-push  HEAD^1
#   CONFIG_GEN_MUTATION_BASE, when set, replaces either rule; it must be a
#   commit and an ancestor of HEAD.
# A shallow clone, a missing ref, a base that is not an ancestor: each is
# refused as config_gen_mutation_base_unreachable, rc 1, never written as
# "none".
#
# <out-dir> is replaced whole with three files:
#   manifest        `base=<sha> head=<sha> dirty=yes|no context=<ctx>`, then
#                   `git diff --name-status -M <base> -- dockerfile/config-gen/`
#                   and `A\t<path>` per untracked module file; or, with no
#                   line, `none: no-go-change`.
#   visible.sha256  `<path>\t<sha256>` per present tracked or untracked
#                   (not ignored) module file.
#   ignored.sha256  the same for present Git-ignored module files.
# Paths are enumerated NUL-delimited and spelled one way in all three files:
# as is, unless the path holds a control byte, a double quote or a
# backslash, in which case it is C-quoted as Git does with
# core.quotePath=false (`"`, \a \b \t \n \v \f \r \" \\, other control
# bytes as \ooo). The caller's core.quotePath has no effect.
# Publication renames the old directory aside, renames the new one in and
# only then removes the old one; a failed install puts the old one back.
#
# Exit: 0 written; 1 base unreachable, none beside a Go diff or a failed
# publication; 2 usage, context or repository invalid.
#
# Style: Google Shell Style Guide.

# Only set strict mode when running directly; when sourced, respect caller's settings
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

_CGM_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
readonly _CGM_SCRIPT_DIR
# shellcheck source=dist/script/docker/lib/log.sh
source "${_CGM_SCRIPT_DIR}/../../dist/script/docker/lib/log.sh"

readonly _CGM_SERVICE='config-gen'
readonly _CGM_MOD='dockerfile/config-gen/'
readonly _CGM_NONE='none: no-go-change'

# The scratch directory a refusal must remove; cleared once installed.
_CGM_TMP=""

_cgm_cleanup() {
  [[ -z "${_CGM_TMP}" ]] || rm -rf "${_CGM_TMP}"
}

# _cgm_usage <reason> <display> -- refuse the argv, rc 2.
_cgm_usage() {
  _log_err "${_CGM_SERVICE}" config_gen_mutation_usage_invalid "reason=${1}" \
    "display=config_gen_mutation_targets.sh: ${2}; usage: config_gen_mutation_targets.sh [--repo <dir>] <out-dir>"
  exit 2
}

# _cgm_unreachable <ref> <reason> -- refuse the base, rc 1.
_cgm_unreachable() {
  _log_err "${_CGM_SERVICE}" config_gen_mutation_base_unreachable "ref=${1}" "reason=${2}" \
    "display=config-gen mutation base ${1} is unreachable (${2}); refusing rather than reporting no change"
  exit 1
}

# _cgm_base <repo> <ctx> -- print the base commit, or refuse.
_cgm_base() {
  local repo="${1}" ctx="${2}" ref base
  if [[ -n "${CONFIG_GEN_MUTATION_BASE+x}" ]]; then
    ref="${CONFIG_GEN_MUTATION_BASE}"
  elif [[ "${ctx}" == main-push ]]; then
    ref='HEAD^1'
  else
    ref='origin/main'
  fi
  # A shallow clone answers merge-base with HEAD and may lack HEAD^1's
  # history: refused by name before any rule runs.
  if [[ "$(git -C "${repo}" rev-parse --is-shallow-repository)" == true ]]; then
    _cgm_unreachable "${ref}" shallow
  fi
  git -C "${repo}" rev-parse --verify -q 'HEAD^{commit}' >/dev/null \
    || _cgm_unreachable HEAD missing
  if [[ -n "${CONFIG_GEN_MUTATION_BASE+x}" ]]; then
    base="$(git -C "${repo}" rev-parse --verify -q "${ref}^{commit}")" \
      || _cgm_unreachable "${ref}" missing
    git -C "${repo}" merge-base --is-ancestor "${base}" HEAD \
      || _cgm_unreachable "${ref}" not_ancestor
  elif [[ "${ctx}" == main-push ]]; then
    base="$(git -C "${repo}" rev-parse --verify -q 'HEAD^1^{commit}')" \
      || _cgm_unreachable "${ref}" missing
  else
    git -C "${repo}" rev-parse --verify -q 'refs/remotes/origin/main^{commit}' >/dev/null \
      || _cgm_unreachable "${ref}" missing
    base="$(git -C "${repo}" merge-base HEAD refs/remotes/origin/main)" \
      || _cgm_unreachable "${ref}" no_merge_base
  fi
  printf '%s\n' "${base}"
}

# _cgm_write_manifest <repo> <base> <header> <dest> [<line>...] -- write the
# manifest. With no line the none marker is written only after the module
# is checked, independently of the lines, to equal <base> with no
# untracked file; otherwise it refuses, rc 1, and writes nothing.
_cgm_write_manifest() {
  local repo="${1}" base="${2}" header="${3}" dest="${4}"
  shift 4
  if (( $# == 0 )); then
    if ! git -C "${repo}" diff --quiet "${base}" -- "${_CGM_MOD}" \
        || [[ -n "$(git -C "${repo}" ls-files -o --exclude-standard -- "${_CGM_MOD}")" ]]; then
      _log_err "${_CGM_SERVICE}" config_gen_mutation_none_beside_diff "base=${base}" "path=${_CGM_MOD}" \
        "display=config-gen mutation manifest would say none while ${_CGM_MOD} differs from ${base}"
      return 1
    fi
    printf '%s\n' "${header}" "${_CGM_NONE}" >"${dest}"
    return 0
  fi
  printf '%s\n' "${header}" "$@" >"${dest}"
}

# _cgm_quote <path> -- print <path> in the one spelling every output file
# uses (see the header); no trailing newline.
_cgm_quote() {
  local p="${1}" LC_ALL=C q='' c i
  case "${p}" in
    *[[:cntrl:]\"\\]*) ;;
    *)
      printf '%s' "${p}"
      return 0
      ;;
  esac
  for (( i = 0; i < ${#p}; i++ )); do
    c="${p:i:1}"
    case "${c}" in
      $'\a') q+='\a' ;;
      $'\b') q+='\b' ;;
      $'\t') q+='\t' ;;
      $'\n') q+='\n' ;;
      $'\v') q+='\v' ;;
      $'\f') q+='\f' ;;
      $'\r') q+='\r' ;;
      '"') q+='\"' ;;
      \\) q+="\\\\" ;;
      [[:cntrl:]]) q+="$(printf '\\%03o' "'${c}")" ;;
      *) q+="${c}" ;;
    esac
  done
  printf '"%s"' "${q}"
}

# _cgm_lines <repo> <base> -- the manifest's change lines: `git diff
# --name-status -M <base>` over the module (a rename or copy keeps both
# paths), then `A\t<path>` per untracked module file. Read NUL-delimited,
# so no path is ever Git-quoted before _cgm_quote spells it.
_cgm_lines() {
  local repo="${1}" base="${2}" i=0 st
  local -a f=()
  mapfile -d '' -t f < <(git -C "${repo}" diff --name-status -z -M "${base}" -- "${_CGM_MOD}")
  while (( i < ${#f[@]} )); do
    st="${f[i]}"
    case "${st}" in
      R*|C*)
        printf '%s\t%s\t%s\n' "${st}" "$(_cgm_quote "${f[i+1]}")" "$(_cgm_quote "${f[i+2]}")"
        i=$(( i + 3 ))
        ;;
      *)
        printf '%s\t%s\n' "${st}" "$(_cgm_quote "${f[i+1]}")"
        i=$(( i + 2 ))
        ;;
    esac
  done
  mapfile -d '' -t f < <(git -C "${repo}" ls-files -z -o --exclude-standard -- "${_CGM_MOD}")
  for st in "${f[@]}"; do
    printf 'A\t%s\n' "$(_cgm_quote "${st}")"
  done
}

# _cgm_hashes <repo> <dest> <ls-files args...> -- `<path>\t<sha256>` for
# each listed module file that is present, sorted by raw path bytes. The
# list is read NUL-delimited, so the -f test sees the path on disk.
_cgm_hashes() {
  local repo="${1}" dest="${2}" path sum
  shift 2
  : >"${dest}"
  while IFS= read -r -d '' path; do
    [[ -f "${repo}/${path}" ]] || continue
    sum="$(sha256sum <"${repo}/${path}")"
    printf '%s\t%s\n' "$(_cgm_quote "${path}")" "${sum%% *}" >>"${dest}"
  done < <(git -C "${repo}" ls-files -z "$@" -- "${_CGM_MOD}" | LC_ALL=C sort -zu)
}

# _cgm_publish_failed <stage> <restored> [attr...] -- refuse, rc 1.
_cgm_publish_failed() {
  local stage="${1}" restored="${2}"
  shift 2
  _log_err "${_CGM_SERVICE}" config_gen_mutation_publish_failed "stage=${stage}" "restored=${restored}" "$@" \
    "display=config-gen mutation baseline publication failed at ${stage} (restored=${restored})"
}

# _cgm_publish <tmp> <out> -- replace <out> with <tmp> whole. Every mv's
# status is consumed by an `if`, so no exit lies between a successful aside
# and the install that skips the restore; the backup is removed only after
# the install succeeded.
_cgm_publish() {
  local tmp="${1}" out="${2}" old=""
  if [[ -e "${out}" ]]; then
    # A failed mktemp leaves old empty; a failed aside leaves out in place.
    if ! old="$(mktemp -d "$(dirname -- "${out}")/.cgm-old.XXXXXX")" \
        || ! mv -T "${out}" "${old}/o"; then
      rm -rf "${tmp}"
      [[ -z "${old}" ]] || rm -rf "${old}"
      _cgm_publish_failed aside n/a "out=${out}"
      return 1
    fi
  fi
  if ! mv -T "${tmp}" "${out}"; then
    rm -rf "${tmp}"
    if [[ -z "${old}" ]]; then
      _cgm_publish_failed install n/a "out=${out}"
      return 1
    fi
    if mv -T "${old}/o" "${out}"; then
      rmdir "${old}"
      _cgm_publish_failed install yes "out=${out}"
      return 1
    fi
    _cgm_publish_failed install no "out=${out}" "backup=${old}/o"
    return 1
  fi
  [[ -z "${old}" ]] || rm -rf "${old}"
}

main() {
  local repo="${_CGM_SCRIPT_DIR}/../.." out="" have_out=0 ctx top want
  while (( $# > 0 )); do
    case "${1}" in
      --repo)
        (( $# >= 2 )) || _cgm_usage repo_value "--repo expects a directory"
        repo="${2}"
        shift 2
        ;;
      -*)
        _cgm_usage unknown_option "unknown option ${1}"
        ;;
      *)
        (( have_out == 0 )) || _cgm_usage extra_arg "unexpected argument ${1}"
        out="${1}"
        have_out=1
        shift
        ;;
    esac
  done
  (( have_out == 1 )) || _cgm_usage missing_out "no <out-dir> given"
  if [[ -L "${out}" ]] || { [[ -e "${out}" ]] && [[ ! -d "${out}" ]]; }; then
    _cgm_usage out_not_dir "<out-dir> ${out} exists and is not a directory"
  fi

  ctx="${CONFIG_GEN_MUTATION_CONTEXT-pr}"
  case "${ctx}" in
    pr|main-push) ;;
    *)
      _log_err "${_CGM_SERVICE}" config_gen_mutation_context_invalid "context=${ctx}" \
        "display=CONFIG_GEN_MUTATION_CONTEXT='${ctx}' is neither pr nor main-push"
      exit 2
      ;;
  esac

  top="$(git -C "${repo}" rev-parse --show-toplevel 2>/dev/null)" || top=""
  want="$(cd -- "${repo}" 2>/dev/null && pwd -P)" || want=""
  if [[ -z "${top}" || "${top}" != "${want}" ]]; then
    _log_err "${_CGM_SERVICE}" config_gen_mutation_repo_invalid "repo=${repo}" \
      "display=config-gen mutation repo ${repo} is not the top of a Git work tree"
    exit 2
  fi

  local base head dirty=no
  base="$(_cgm_base "${repo}" "${ctx}")"
  head="$(git -C "${repo}" rev-parse --verify 'HEAD^{commit}')"
  [[ -z "$(git -C "${repo}" status --porcelain -- "${_CGM_MOD}")" ]] || dirty=yes

  local -a lines=()
  mapfile -t lines < <(_cgm_lines "${repo}" "${base}")

  local parent
  parent="$(dirname -- "${out}")"
  mkdir -p -- "${parent}"
  trap _cgm_cleanup EXIT
  _CGM_TMP="$(mktemp -d "${parent}/.cgm-new.XXXXXX")"
  _cgm_write_manifest "${repo}" "${base}" \
    "base=${base} head=${head} dirty=${dirty} context=${ctx}" \
    "${_CGM_TMP}/manifest" "${lines[@]}"
  _cgm_hashes "${repo}" "${_CGM_TMP}/visible.sha256" -co --exclude-standard
  _cgm_hashes "${repo}" "${_CGM_TMP}/ignored.sha256" -o -i --exclude-standard
  _cgm_publish "${_CGM_TMP}" "${out}"
  _CGM_TMP=""
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  main "$@"
fi
