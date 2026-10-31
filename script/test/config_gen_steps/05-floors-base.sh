#!/usr/bin/env bash
#
# 05-floors-base.sh -- config-gen step: the base's coverage floors
# (base#1465).
#
# Run by script/test/config_gen_gates.sh with CONFIG_GEN_CTX set, after
# 00-manifest wrote $CONFIG_GEN_CTX/mutation. Writes
# $CONFIG_GEN_CTX/mutation/floors.base from the base commit the manifest's
# header names (the one 00-manifest diffed against):
#
#   the concatenation, in lexical order, of every
#   `git show <base>:dockerfile/config-gen/coverage-floors.d/<slice>.txt`,
#   each ending in LF; or the single line `absent` when the base has no
#   coverage-floors.d.
#
# The coverage RUN binds the mutation context and hands floors.base to
# `cg-gates ratchet --base`, so a floor lower than the base's is refused.
#
# A refusal is the event config_gen_floors_base_failed with reason=, rc 1,
# and floors.base as it was (bytes and mode); the new file is written
# beside it and renamed over it only once complete:
#
#   base_missing      the manifest header names no commit of this checkout
#   git_failed        a git command failed
#   not_tree          coverage-floors.d is not a directory at the base
#   fragment_invalid  an entry in it is not a file named <slice>.txt
#
# Style: Google Shell Style Guide.

set -euo pipefail

_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/../../.." && pwd -P)"
# shellcheck source=dist/script/docker/lib/log.sh
source "${_root}/dist/script/docker/lib/log.sh"

readonly _CGF_DIR='dockerfile/config-gen/coverage-floors.d'
# The scratch directory main writes in, beside floors.base; removed on exit.
_cgf_tmp=''

_cgf_cleanup() {
  [[ -z "${_cgf_tmp}" ]] || rm -rf -- "${_cgf_tmp}"
}

# _cgf_refuse <reason> -- refuse, rc 1.
_cgf_refuse() {
  _log_err config-gen config_gen_floors_base_failed "reason=${1}" \
    "display=config-gen floors.base not written: ${1}"
  exit 1
}

main() {
  local out="${CONFIG_GEN_CTX:?config_gen_steps run under CONFIG_GEN_CTX}/mutation"
  local header='' base mode type name entry
  local -a entries=()
  IFS= read -r header <"${out}/manifest" 2>/dev/null || true
  base="${header#base=}"
  base="${base%% *}"
  [[ "${header}" == base=* && "${base}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] \
    || _cgf_refuse base_missing
  git -C "${_root}" rev-parse --verify -q "${base}^{commit}" >/dev/null \
    || _cgf_refuse base_missing
  trap _cgf_cleanup EXIT
  _cgf_tmp="$(mktemp -d "${out}/.floors.base.XXXXXX")" || _cgf_refuse git_failed
  git -C "${_root}" ls-tree -z "${base}" -- "${_CGF_DIR}" >"${_cgf_tmp}/dir" \
    || _cgf_refuse git_failed
  if [[ ! -s "${_cgf_tmp}/dir" ]]; then
    printf 'absent\n' >"${_cgf_tmp}/floors.base"
  else
    read -r mode type _ <"${_cgf_tmp}/dir" || true
    [[ "${mode}" == 040000 && "${type}" == tree ]] || _cgf_refuse not_tree
    git -C "${_root}" ls-tree -z "${base}:${_CGF_DIR}" >"${_cgf_tmp}/list" \
      || _cgf_refuse git_failed
    mapfile -d '' -t entries <"${_cgf_tmp}/list"
    : >"${_cgf_tmp}/floors.base"
    for entry in "${entries[@]}"; do
      read -r mode type _ <<<"${entry%%$'\t'*}"
      name="${entry#*$'\t'}"
      [[ "${type}" == blob && ( "${mode}" == 100644 || "${mode}" == 100755 ) \
        && "${name}" =~ ^[a-z0-9][a-z0-9-]*\.txt$ ]] || _cgf_refuse fragment_invalid
      git -C "${_root}" show "${base}:${_CGF_DIR}/${name}" >>"${_cgf_tmp}/floors.base" \
        || _cgf_refuse git_failed
      [[ ! -s "${_cgf_tmp}/floors.base" \
        || "$(tail -c 1 -- "${_cgf_tmp}/floors.base" | od -An -tx1)" == ' 0a' ]] \
        || printf '\n' >>"${_cgf_tmp}/floors.base"
    done
  fi
  chmod 0644 "${_cgf_tmp}/floors.base"
  mv -f -T -- "${_cgf_tmp}/floors.base" "${out}/floors.base" || _cgf_refuse git_failed
}

main "$@"
