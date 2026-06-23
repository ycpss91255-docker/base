#!/usr/bin/env bash
# new.sh -- scaffold a repo-local just command group (ADR-00000010).
#
# `just template new <name>` runs this (via the `template` namespace's
# `[no-cd]` recipe, so cwd is the repo root). It creates
# script/local/<name>/justfile.<name> + <name>.sh from the skeleton, and
# registers the group by appending one `mod?` line to
# script/local/justfile.local -- after which `just <name> <recipe>` works.
#
# Refuses to clobber an existing group; the registry append is idempotent.
# The skel/ templates are located relative to this script, so it works
# through the consumer's symlink into .base/downstream/script/template/.
set -euo pipefail

main() {
  local name="${1:-}"
  if [[ -z "${name}" ]]; then
    printf 'usage: just template new <name>\n' >&2
    return 2
  fi
  if [[ ! "${name}" =~ ^[a-z][a-z0-9_-]*$ ]]; then
    printf 'invalid group name %q (must match ^[a-z][a-z0-9_-]*$)\n' "${name}" >&2
    return 2
  fi

  local self_dir skel dest reg line
  self_dir="$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd -P)"
  skel="${self_dir}/skel"
  dest="script/local/${name}"
  reg="script/local/justfile.local"

  if [[ -e "${dest}" ]]; then
    printf 'group %q already exists at %s -- refusing to clobber\n' "${name}" "${dest}" >&2
    return 1
  fi

  mkdir -p "${dest}" script/local
  sed "s/__NAME__/${name}/g" "${skel}/justfile.skel" > "${dest}/justfile.${name}"
  sed "s/__NAME__/${name}/g" "${skel}/skel.sh" > "${dest}/${name}.sh"
  chmod +x "${dest}/${name}.sh"

  line="mod? ${name} '${name}/justfile.${name}'"
  if [[ -f "${reg}" ]] && grep -qF "${line}" "${reg}"; then
    printf 'group %q already registered in %s\n' "${name}" "${reg}"
  else
    printf '%s\n' "${line}" >> "${reg}"
  fi
  printf 'created group %q -- run: just %s <recipe>\n' "${name}" "${name}"
}

main "$@"
