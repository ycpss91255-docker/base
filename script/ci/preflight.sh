#!/usr/bin/env bash
# preflight.sh - caller-contract validator for the reusable workers.
#
# The reusable build / release workers must self-validate the caller
# contract before doing any real work, and never fail silently. This
# script is that validator: given a declared requirement manifest (the
# explicit, self-describing list of what a caller must provide) it checks
# each entry against an environment variable the worker populates from the
# real inputs / permission probes, and on any missing item exits non-zero
# with a plain-language message telling the caller exactly what to add to
# their main.yaml.
#
# Keeping the logic here (host-testable under `just test`) keeps the GHA
# wiring in build-worker.yaml / release-worker.yaml thin: the workflow only
# exports the env vars the manifest names and calls this script.
#
# Usage:
#   preflight.sh <manifest>          # validate; exit 1 with guidance on gaps
#   preflight.sh --list <manifest>   # print the requirement list, exit 0
#
# Manifest format (one requirement per line; `#` comments + blank lines
# ignored). Adding a future requirement is a single new line:
#   <kind>|<key>|<envvar>|<description>|<hint>
#     kind        input       -> <envvar> must be non-empty
#                 permission  -> <envvar> must equal "granted"
#     key         short requirement name (e.g. image_name, packages)
#     envvar      environment variable the worker exports the real value to
#     description one-line human description of what the requirement is
#     hint        plain-language fix; `\n` is expanded to a newline so a
#                 hint can show a multi-line main.yaml snippet

set -euo pipefail

_check() {
  # Return 0 when the requirement identified by <kind>/<envvar> is
  # satisfied by the current environment, non-zero otherwise.
  local kind="$1" envvar="$2"
  case "${kind}" in
    input) [[ -n "${!envvar:-}" ]] ;;
    permission) [[ "${!envvar:-}" == "granted" ]] ;;
    *) return 0 ;;
  esac
}

_reason() {
  # One-line explanation of why <kind>/<envvar> is unsatisfied, so the
  # failure message states the observed problem, not just the fix.
  local kind="$1" envvar="$2"
  case "${kind}" in
    input) printf 'required input is missing or empty (env %s)' "${envvar}" ;;
    permission)
      printf 'permission not granted (probe env %s=%s)' \
        "${envvar}" "${!envvar:-<unset>}" ;;
    *) printf 'unsatisfied' ;;
  esac
}

_read_manifest() {
  # Emit the manifest with comments / blank lines stripped, so both the
  # validate and list paths iterate the same cleaned view.
  local manifest="$1" line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    printf '%s\n' "${line}"
  done < "${manifest}"
}

_list() {
  local manifest="$1" kind key envvar desc hint
  printf 'Caller contract -- this worker requires:\n\n'
  while IFS='|' read -r kind key envvar desc hint; do
    printf '  [%s] %s -- %s\n' "${kind}" "${key}" "${desc}"
  done < <(_read_manifest "${manifest}")
}

_validate() {
  local manifest="$1" kind key envvar desc hint
  local failures=0
  while IFS='|' read -r kind key envvar desc hint; do
    if ! _check "${kind}" "${envvar}"; then
      if [[ "${failures}" -eq 0 ]]; then
        printf 'Preflight failed: this worker call is missing part of its caller contract.\n'
        printf 'Fix your .github/workflows/main.yaml as described below, then re-run.\n\n'
      fi
      failures=$((failures + 1))
      printf '  x %s (%s)\n' "${key}" "${desc}"
      printf '    reason: %s\n' "$(_reason "${kind}" "${envvar}")"
      printf '    fix:\n'
      printf '%b\n' "${hint}" | while IFS= read -r hint_line; do
        printf '      %s\n' "${hint_line}"
      done
      printf '\n'
    fi
  done < <(_read_manifest "${manifest}")

  if [[ "${failures}" -gt 0 ]]; then
    printf 'Preflight: %d requirement(s) unmet -- see above.\n' "${failures}" >&2
    return 1
  fi
  printf 'Preflight OK: caller contract satisfied.\n'
}

main() {
  local mode="validate" manifest=""
  case "${1:-}" in
    --list|list) mode="list"; manifest="${2:-}" ;;
    "") printf 'usage: preflight.sh [--list] <manifest>\n' >&2; return 2 ;;
    *) manifest="${1}" ;;
  esac

  if [[ -z "${manifest}" || ! -f "${manifest}" ]]; then
    printf 'preflight: manifest not found: %s\n' "${manifest}" >&2
    return 2
  fi

  case "${mode}" in
    list) _list "${manifest}" ;;
    validate) _validate "${manifest}" ;;
  esac
}

main "$@"
