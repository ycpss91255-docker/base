#!/usr/bin/env bash
# release-archive.sh - release archive payload assembler for the reusable
# release worker.
#
# The reusable release worker builds the tarball / zip a consumer publishes
# at tag time. It used to assemble that payload by naming every standard
# path as an operand of one `cp -r`: `cp` aborts non-zero on the first
# missing operand and the `run:` step is `bash -e`, so a consumer that
# legitimately lacked ONE path lost its whole release -- at tag push, the
# worst moment to discover anything. That shipped twice, on a different path
# each time, and both fixes edited the operand list to match base's own
# current layout, which is exactly what makes a base layout change a
# breaking change for every consumer whose tree is shaped differently.
#
# This script is the replacement. The payload is DECLARED in a manifest
# (script/ci/release/archive.manifest) rather than spelled out in shell, and
# absence has two meanings instead of one:
#
#   required  the archive is unusable without it, no matter how the
#             consumer's tree is shaped -> fail, naming the path, the item
#             and what its absence costs. Never a bare `cp: cannot stat`.
#   optional  the archive is degraded without it -> report the absence by
#             name and cut the release anyway.
#
# A payload item may declare several CANDIDATE paths, which is how one
# workflow serves both historical layouts of a moved directory (e.g. smoke
# specs at `test/bats/smoke/` and at `test/smoke/`) with no consumer having
# to restructure. Every candidate that exists is archived, each at its own
# relative path.
#
# Keeping the logic here (host-testable under `just test`) keeps the GHA
# wiring in release-worker.yaml thin -- the same split preflight.sh uses --
# and, more to the point, makes the absent-path cases testable at all: they
# are driven against synthesised consumer trees by
# test/bats/unit/release_archive_spec.bats and
# test/bats/integration/release_archive_contract_spec.bats.
#
# Usage:
#   release-archive.sh <manifest> <archive-dir>   # assemble the payload
#   release-archive.sh --list <manifest>          # print the payload contract
#
# Run from the consumer checkout root; every path is resolved relative to
# the current directory. Caller-supplied extras come from the environment:
#   RELEASE_EXTRA_FILES  space-separated repo-relative paths; each is
#                        archived when present and skipped when not.
#
# Exit status:
#   0  archive assembled
#   1  a required path is missing, or a declared path is unsafe
#   2  configuration error (manifest missing, malformed, or empty)

set -euo pipefail

# ── manifest reading ─────────────────────────────────────────────────────────

_read_manifest() {
  # Emit the manifest with comments / blank lines stripped, so the list and
  # assemble paths iterate the same cleaned view.
  local manifest="$1" line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    printf '%s\n' "${line}"
  done < "${manifest}"
}

# ── path safety ──────────────────────────────────────────────────────────────

_path_is_unsafe() {
  # A payload path must stay inside the checkout AND inside the archive.
  # An absolute path or one climbing through `..` lands outside the archive
  # directory, so the copy would write into the checkout and the tarball
  # would silently not contain what was asked for.
  local path="$1"
  [[ "${path}" == /* ]] && return 0
  case "/${path}/" in
    */../*) return 0 ;;
  esac
  return 1
}

# ── copying ──────────────────────────────────────────────────────────────────

_archive_path() {
  # Copy <src> into <dest> AT ITS OWN RELATIVE PATH. `cp -r a/b/c dest/`
  # would flatten to `dest/c`, which makes two candidate layouts of the same
  # item collide on one destination and loses which layout the consumer
  # actually has.
  #
  # `cp -r` (not -a, not -L) is deliberate: it copies a symlink as a symlink,
  # which is what the wrappers under `script/` are. They resolve in the
  # unpacked archive because the subtree they point into is a required entry
  # that travels with them.
  local src="$1" dest="$2" parent
  parent="$(dirname "${src%/}")"
  if [[ "${parent}" == "." ]]; then
    mkdir -p "${dest}"
    cp -r "${src}" "${dest}/"
  else
    mkdir -p "${dest}/${parent}"
    cp -r "${src}" "${dest}/${parent}/"
  fi
}

# ── the payload contract, printed ────────────────────────────────────────────

_list() {
  local manifest="$1" kind key paths desc consequence
  printf 'Release archive payload -- this worker archives:\n\n'
  while IFS='|' read -r kind key paths desc consequence; do
    printf '  [%s] %s -- %s\n' "${kind}" "${key}" "${desc}"
    printf '        paths: %s\n' "${paths}"
    printf '        without it: %s\n' "${consequence}"
  done < <(_read_manifest "${manifest}")
}

# ── assembly ─────────────────────────────────────────────────────────────────

_assemble() {
  local manifest="$1" dest="$2"
  local kind key paths desc consequence
  local -a present=() missing_required=() absent_optional=() extras=()
  local declared=0 candidate found

  # Pass 1 -- resolve the whole manifest before touching the filesystem. A
  # half-built archive directory left behind by a run that then failed is
  # worse than no archive: it tars up clean and breaks at the consumer.
  while IFS='|' read -r kind key paths desc consequence; do
    case "${kind}" in
      required|optional) ;;
      *)
        # Fail closed. A typo'd kind column must never quietly decide
        # whether a path is archived. Same class as preflight.sh's
        # unknown-kind guard: a config error, not a payload gap.
        printf "release-archive: malformed manifest '%s': unknown kind '%s' (expected 'required' or 'optional') on line: %s|%s|%s|%s|%s\n" \
          "${manifest}" "${kind}" "${kind}" "${key}" "${paths}" "${desc}" \
          "${consequence}" >&2
        return 2
        ;;
    esac
    declared=$((declared + 1))

    found=0
    for candidate in ${paths}; do
      if _path_is_unsafe "${candidate}"; then
        printf "release-archive: malformed manifest '%s': path '%s' (item %s) escapes the archive directory\n" \
          "${manifest}" "${candidate}" "${key}" >&2
        return 1
      fi
      if [[ -e "${candidate}" ]]; then
        present+=("${candidate}")
        found=1
      fi
    done

    if [[ "${found}" -eq 0 ]]; then
      if [[ "${kind}" == "required" ]]; then
        missing_required+=("${key}|${paths}|${desc}|${consequence}")
      else
        absent_optional+=("${key}|${paths}|${desc}")
      fi
    fi
  done < <(_read_manifest "${manifest}")

  if [[ "${declared}" -eq 0 ]]; then
    # A manifest that exists but declares nothing must not produce an empty
    # archive that uploads as if it were a release.
    printf "release-archive: manifest '%s' declares no payload (empty or all comments) -- nothing to archive\n" \
      "${manifest}" >&2
    return 2
  fi

  # Caller-supplied extras are resolved in the same pass-1 spirit: an unsafe
  # path is refused before anything is copied, an absent one is skipped (as
  # it always was -- extras have never been mandatory).
  local extra
  for extra in ${RELEASE_EXTRA_FILES:-}; do
    if _path_is_unsafe "${extra}"; then
      printf "release-archive: extra_files entry '%s' escapes the archive directory -- refusing\n" \
        "${extra}" >&2
      return 1
    fi
    if [[ -e "${extra}" ]]; then
      extras+=("${extra}")
    else
      printf 'release-archive: extra_files entry absent, not archived: %s\n' "${extra}"
    fi
  done

  if [[ "${#missing_required[@]}" -gt 0 ]]; then
    local entry m_key m_paths m_desc m_consequence
    printf 'Release archive failed: this repository is missing a REQUIRED path.\n\n'
    for entry in "${missing_required[@]}"; do
      IFS='|' read -r m_key m_paths m_desc m_consequence <<< "${entry}"
      printf '  x %s -- %s\n' "${m_key}" "${m_desc}"
      printf '    missing: %s\n' "${m_paths}"
      printf '    without it: %s\n' "${m_consequence}"
      printf '\n'
    done
    printf 'release-archive: %d required path(s) missing -- see above.\n' \
      "${#missing_required[@]}" >&2
    return 1
  fi

  if [[ "$((${#present[@]} + ${#extras[@]}))" -eq 0 ]]; then
    # Every declared path was optional and none of them exist. Tarring the
    # empty directory would upload an artifact that looks like a release and
    # contains nothing -- the silent-broken-artifact outcome the required /
    # optional split exists to prevent. Refuse instead.
    printf "release-archive: nothing was archived -- no declared path in '%s' exists in %s\n" \
      "${manifest}" "${PWD}" >&2
    return 1
  fi

  # Pass 2 -- the payload is known good; build it.
  mkdir -p "${dest}"

  local path
  for path in ${present[@]+"${present[@]}"}; do
    _archive_path "${path}" "${dest}"
    printf 'release-archive: archived %s\n' "${path}"
  done
  for path in ${extras[@]+"${extras[@]}"}; do
    _archive_path "${path}" "${dest}"
    printf 'release-archive: archived %s (extra_files)\n' "${path}"
  done

  # Absence is reported, never silent: tolerance that says nothing is how a
  # payload path that stopped being copied stays invisible until someone
  # unpacks the tarball.
  local a_key a_paths a_desc
  for entry in ${absent_optional[@]+"${absent_optional[@]}"}; do
    IFS='|' read -r a_key a_paths a_desc <<< "${entry}"
    printf 'release-archive: optional path absent, not archived: %s (%s -- %s)\n' \
      "${a_paths}" "${a_key}" "${a_desc}"
  done

  printf 'release-archive: %s assembled (%d path(s) archived, %d optional path(s) absent).\n' \
    "${dest}" "$((${#present[@]} + ${#extras[@]}))" "${#absent_optional[@]}"
}

main() {
  local mode="assemble" manifest="" dest=""
  case "${1:-}" in
    --list|list) mode="list"; manifest="${2:-}" ;;
    "")
      printf 'usage: release-archive.sh [--list] <manifest> [<archive-dir>]\n' >&2
      return 2
      ;;
    *) manifest="${1}"; dest="${2:-}" ;;
  esac

  if [[ -z "${manifest}" || ! -f "${manifest}" ]]; then
    printf 'release-archive: manifest not found: %s\n' "${manifest}" >&2
    return 2
  fi

  case "${mode}" in
    list) _list "${manifest}" ;;
    assemble)
      if [[ -z "${dest}" ]]; then
        printf 'release-archive: no archive directory given\n' >&2
        return 2
      fi
      _assemble "${manifest}" "${dest}"
      ;;
  esac
}

main "$@"
