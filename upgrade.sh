#!/usr/bin/env bash
# upgrade.sh - Upgrade template subtree to the latest version
#
# Run from the repo root:
#   ./template/upgrade.sh              # upgrade to latest tag
#   ./template/upgrade.sh v0.3.0       # upgrade to specific version
#   ./template/upgrade.sh --check      # check if update available

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
readonly REPO_ROOT
TEMPLATE_REMOTE="git@github.com:ycpss91255-docker/template.git"
readonly TEMPLATE_REMOTE
VERSION_FILE="${REPO_ROOT}/template/VERSION"
readonly VERSION_FILE
LEGACY_VERSION_FILE="${REPO_ROOT}/.template_version"
readonly LEGACY_VERSION_FILE

cd "${REPO_ROOT}"

_log() { printf "[upgrade] %s\n" "$*"; }
_error() { printf "[upgrade] ERROR: %s\n" "$*" >&2; exit 1; }

# ── Get versions ─────────────────────────────────────────────────────────────

_get_local_version() {
  if [[ -f "${VERSION_FILE}" ]]; then
    tr -d '[:space:]' < "${VERSION_FILE}"
  elif [[ -f "${LEGACY_VERSION_FILE}" ]]; then
    tr -d '[:space:]' < "${LEGACY_VERSION_FILE}"
  else
    echo "unknown"
  fi
}

_get_latest_version() {
  git ls-remote --tags --sort=-v:refname "${TEMPLATE_REMOTE}" \
    | grep -oP 'refs/tags/v\d+\.\d+\.\d+$' \
    | head -1 \
    | sed 's|refs/tags/||'
}

# ── Check mode ───────────────────────────────────────────────────────────────

_check() {
  local local_ver latest_ver
  local_ver="$(_get_local_version)"
  latest_ver="$(_get_latest_version)"

  if [[ -z "${latest_ver}" ]]; then
    _error "Could not fetch latest version from ${TEMPLATE_REMOTE}"
  fi

  _log "Local:  ${local_ver}"
  _log "Latest: ${latest_ver}"

  if [[ "${local_ver}" == "${latest_ver}" ]]; then
    _log "Already up to date."
    return 0
  else
    _log "Update available: ${local_ver} → ${latest_ver}"
    return 1
  fi
}

# ── Upgrade ──────────────────────────────────────────────────────────────────

_upgrade() {
  local target_ver="$1"
  local local_ver
  local_ver="$(_get_local_version)"

  if [[ "${local_ver}" == "${target_ver}" ]]; then
    _log "Already at ${target_ver}. Nothing to do."
    return 0
  fi

  _log "Upgrading: ${local_ver} → ${target_ver}"

  # Snapshot the pre-pull tree hash of template/config so we can tell
  # the user if their seeded <repo>/config is now out of sync with the
  # upstream baseline. Git tree hashes are stable and cheap (no blob
  # compare); if HEAD has no template/config yet (initial setup),
  # leave _pre_config_hash empty.
  local _pre_config_hash=""
  # --verify: print the resolved hash on success, print nothing on
  # failure. Without it, git's default mode echoes the unresolved ref
  # back to stdout for unknown paths, which would be mistaken for a
  # hash later by _warn_config_drift.
  _pre_config_hash="$(git rev-parse --verify "HEAD:template/config" 2>/dev/null || true)"

  # Step 1: subtree pull
  _log "Step 1/4: git subtree pull"
  git subtree pull --prefix=template \
    "${TEMPLATE_REMOTE}" "${target_ver}" --squash \
    -m "chore: upgrade template subtree to ${target_ver}"

  # Step 2: re-run init.sh to sync symlinks (in case template structure changed)
  _log "Step 2/3: re-run init.sh to sync symlinks"
  ./template/init.sh

  # Step 3: update main.yaml @tag references
  _log "Step 3/3: update workflow @tag references"
  local main_yaml="${REPO_ROOT}/.github/workflows/main.yaml"
  if [[ -f "${main_yaml}" ]]; then
    # Replace @vX.Y.Z with new version in reusable workflow references.
    # Match each worker file by name to avoid greedy patterns clobbering siblings.
    sed -i "s|build-worker\.yaml@v[0-9.]*|build-worker.yaml@${target_ver}|g" "${main_yaml}"
    sed -i "s|release-worker\.yaml@v[0-9.]*|release-worker.yaml@${target_ver}|g" "${main_yaml}"
    git add "${main_yaml}"
  fi

  # cleanup legacy .template_version if present
  if [[ -f "${LEGACY_VERSION_FILE}" ]]; then
    git rm -f "${LEGACY_VERSION_FILE}" 2>/dev/null || rm -f "${LEGACY_VERSION_FILE}"
  fi

  # Commit workflow updates
  git commit -m "$(cat <<COMMIT
chore: update template references to ${target_ver}

- main.yaml: workflow @tag updated to ${target_ver}
COMMIT
)" || _log "No additional changes to commit"

  # Post-pull: warn when the upstream config baseline moved so the
  # user can reconcile <repo>/config/ (seeded by init.sh, user-owned
  # afterwards) against the new template/config/. Silent when the
  # baseline didn't change or there was no prior baseline.
  _warn_config_drift "${_pre_config_hash}"

  _log "Done! Upgraded to ${target_ver}"
  _log ""
  _log "Next steps:"
  _log "  1. Run ./build.sh test to verify"
  _log "  2. git push"
}

# _warn_config_drift <pre_pull_tree_hash>
#
# When the upstream template/config/ tree changed during this pull,
# print a WARNING pointing the user at the diff so they can merge into
# their <repo>/config/ manually. Never fails the upgrade (config is
# user-owned — we only report, not force).
_warn_config_drift() {
  local _pre="${1:-}"
  local _post
  _post="$(git rev-parse --verify "HEAD:template/config" 2>/dev/null || true)"
  [[ -z "${_post}" ]] && return 0         # no config in new subtree
  [[ "${_pre}" == "${_post}" ]] && return 0   # unchanged
  _log ""
  _log "WARNING: template/config/ changed upstream since the last pull."
  _log "         Your <repo>/config/ is user-owned and was NOT updated."
  _log "         Review the diff and port any upstream changes you want:"
  _log ""
  _log "           diff -ruN template/config config"
  if [[ -n "${_pre}" ]]; then
    _log ""
    _log "         Upstream-only diff (what moved in template/config/):"
    _log "           git diff ${_pre:0:12}..${_post:0:12} -- template/config"
  fi
}

# ── Help ─────────────────────────────────────────────────────────────────────

_usage() {
  cat >&2 <<'EOF'
Usage: ./template/upgrade.sh [VERSION|--check|--gen-conf]

Upgrade template subtree to the latest (or specified) version.

Arguments:
  VERSION       Target version (e.g. v0.5.0). Defaults to latest tag.
  --check       Check if an update is available (no changes made)
  --gen-conf    Copy template/setup.conf to repo root for per-repo
                configuration overrides (delegates to init.sh --gen-conf)
  -h, --help    Show this help

Examples:
  ./template/upgrade.sh               # upgrade to latest
  ./template/upgrade.sh v0.5.0        # upgrade to specific version
  ./template/upgrade.sh --check       # check only
  ./template/upgrade.sh --gen-conf    # copy setup.conf to repo root
EOF
  exit 0
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  case "${1:-}" in
    -h|--help) _usage ;;
  esac

  [[ ! -d template ]] && _error "template/ not found. Run from repo root."

  case "${1:-}" in
    --check) _check ;;
    --gen-conf) ./template/init.sh --gen-conf ;;
    v*)
      _upgrade "$1"
      ;;
    "")
      local latest
      latest="$(_get_latest_version)"
      [[ -z "${latest}" ]] && _error "Could not fetch latest version"
      _upgrade "${latest}"
      ;;
    *) _error "Unknown argument: $1" ;;
  esac
}

main "$@"
