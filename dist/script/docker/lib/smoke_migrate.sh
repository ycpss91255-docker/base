#!/usr/bin/env bash
#
# smoke_migrate.sh - the repo-owned smoke tree's layout, and the migration
# onto it.
#
# v0.42.0 split the smoke tree per Dockerfile `-test` stage. Base's own
# shipped half moved to dist/test/bats/smoke/ and lib/dockerfile_migrate.sh
# heals consumer references to it. The half the REPO owns moved the same
# way -- flat test/smoke/ -> test/bats/smoke/{shared,<stage>}/ -- and
# nothing migrated it, so a repo upgraded from v0.41.0 kept a shape a fresh
# bootstrap of the same tag never produces (#1044).
#
# Why the placeholder bodies live HERE rather than inline in init.sh's
# new-repo path: a fresh repo and an upgraded one have to end up with the
# same tree, and two copies of the same text are two things that can drift
# apart (ADR-00000028). init.sh seeds a new repo through the same function
# this migration calls, so "what the layout is" has one definition.
#
# The move is behaviour-preserving by construction. The pre-v0.42.0
# Dockerfile copies the whole flat tree into EVERY `-test` stage, and
# shared/ is defined as "runs on every stage", so every spec belongs in
# shared/ and nothing any repo currently tests changes. Deciding which
# specs should later drop into one stage's folder is a per-repo judgement
# this migration deliberately does not make.

# _smoke_stage_placeholder <stage>
#   The .gitkeep body for one per-stage folder. A placeholder rather than
#   an empty directory because git does not track those, and the folder has
#   to be present for the Dockerfile's per-stage COPY to resolve.
_smoke_stage_placeholder() {
  case "${1}" in
    devel-test)
      cat <<'KEEP'
# Reserved for devel-test-only smoke specs. Empty until a devel-test
# specific assertion is added; the shared/ baseline still runs here.
KEEP
      ;;
    runtime-test)
      cat <<'KEEP'
# Reserved for runtime-test-only smoke specs (opt-in runtime split). Empty
# until the runtime stage is enabled and a runtime-specific assertion is
# added; the shared/ baseline still runs here. The placeholder keeps the
# folder present so the Dockerfile's commented-out runtime-test COPY block
# resolves the moment the split is turned on.
KEEP
      ;;
    *)
      return 1
      ;;
  esac
}

# _smoke_seed_stage_dirs <repo_root>
#   Create the per-stage folders with their placeholders. Never overwrites:
#   a placeholder the user has replaced with real specs, or annotated, is
#   theirs. Idempotent, so both the new-repo path and the migration can
#   call it unconditionally.
_smoke_seed_stage_dirs() {
  local _root="${1:?"${FUNCNAME[0]}: missing repo_root"}"
  local _base="${_root%/}/test/bats/smoke"
  local _stage
  for _stage in devel-test runtime-test; do
    mkdir -p "${_base}/${_stage}"
    [[ -e "${_base}/${_stage}/.gitkeep" ]] && continue
    _smoke_stage_placeholder "${_stage}" > "${_base}/${_stage}/.gitkeep"
  done
}

# _migrate_smoke_tree <repo_root>
#   Move a flat test/smoke/ onto the per-stage layout.
#
#   Why HERE and not in upgrade.sh: an upgrade is driven by the CONSUMER'S
#   OWN vendored upgrade.sh, a copy that shipped in an older release and
#   cannot be changed retroactively. The one piece of current code such an
#   upgrade runs is the freshly pulled init.sh, re-executed as its resync
#   step -- the same reasoning _migrate_env_to_local spells out, and the
#   only seam that reaches a repo upgrading FROM an old release.
#
#   Apply policy matches the rest of the migration family: a shape it
#   recognises is healed idempotently, and anything ambiguous is warned
#   about and left alone rather than force-rewritten.
_migrate_smoke_tree() {
  local _root="${1:?"${FUNCNAME[0]}: missing repo_root"}"
  local _flat="${_root%/}/test/smoke"
  local _shared="${_root%/}/test/bats/smoke/shared"

  # Anchored at the directory itself, so a sibling merely PREFIXED by the
  # retired name -- test/smoke_helpers -- is not mistaken for it.
  [[ -d "${_flat}" ]] || return 0

  mkdir -p "${_shared}"

  local _src _name _declined=0
  for _src in "${_flat}"/* "${_flat}"/.[!.]*; do
    [[ -e "${_src}" ]] || continue
    _name="${_src##*/}"
    if [[ -e "${_shared}/${_name}" ]]; then
      # Two files claim one name. Overwriting would destroy one of them and
      # the migration cannot know which is wanted, so it keeps both and
      # says so.
      _declined=1
      _log_warn init smoke_tree_migration_conflict \
        "display=MIGRATION DECLINED for ${_name}: the smoke tree moved to test/bats/smoke/shared/, but a file of that name is already there. Both were kept -- yours at test/smoke/${_name}, the existing one at test/bats/smoke/shared/${_name}. Reconcile them by hand (diff the two), then delete test/smoke/${_name}." \
        "path=${_flat}/${_name}"
      continue
    fi
    mv -- "${_src}" "${_shared}/${_name}"
  done

  _smoke_seed_stage_dirs "${_root}"

  if (( _declined == 0 )); then
    rmdir -- "${_flat}" 2>/dev/null || true
    _log_warn init smoke_tree_migrated \
      "display=MIGRATION: test/smoke/ -> test/bats/smoke/shared/. The smoke tree is now split per Dockerfile -test stage; shared/ runs on every stage, which is what the flat tree did, so nothing this repo tests changed. Stage-specific specs can now move into test/bats/smoke/<stage>/." \
      "path=${_shared}"
  fi

  # A repo that tracked the flat tree needs the rename staged, so it rides
  # the caller's commit instead of surfacing later as an unexplained move
  # (refs #1036).
  if git -C "${_root}" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "${_root}" add -A -- test/smoke test/bats/smoke >/dev/null 2>&1 || true
  fi
}
