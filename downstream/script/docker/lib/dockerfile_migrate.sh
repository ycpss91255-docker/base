#!/usr/bin/env bash
#
# dockerfile_migrate.sh - declarative Dockerfile-migration list (#567).
#
# A deep module behind a small interface: `apply_migrations <dockerfile>`
# iterates an ordered, data-driven list of {detect, transform} migrations
# and applies each migration whose `detect` matches. It replaces the
# accreting pile of one-off seds that upgrade.sh Step 5 used to carry to
# heal downstream Dockerfiles after a base contract change.
#
# Each migration `X` is two functions:
#   _migrate_X_detect <file>   exit 0 -> migration applies to this file
#   _migrate_X_apply  <file>   perform the (idempotent) rewrite
# and one entry in the ordered `_MIGRATIONS` array. apply_migrations runs
# them in array order; this lets later migrations build on the shape an
# earlier one normalised (e.g. the lib-COPY split before the wrapper-COPY
# rename).
#
# Apply policy (inherited from upgrade.sh's Step-5 convention):
#   - `detect` matches a known shape -> `apply` runs and is IDEMPOTENT
#     (a second run is a no-op).
#   - structure does not match / anchor missing / ambiguous -> `detect`
#     returns non-zero so the migration is SKIPPED; where a partial /
#     custom shape is recognised the `apply` _log_warn's and leaves the
#     file untouched rather than force-rewriting.
#
# Compatible with ADR-00000006: the `.base` path contract is frozen; this
# restructures the heal MECHANISM, not the frozen paths.
#
# Style: Google Shell Style Guide.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_DOCKERFILE_MIGRATE_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_DOCKERFILE_MIGRATE_SOURCED=1

# ── Internal helpers ────────────────────────────────────────────────────────

# _dfm_join_copy_statements <file>
#   Emit the file with backslash-continued lines folded into single logical
#   lines, so a detect grep can reason about a whole COPY statement (multi-
#   distro repos hand-list moved files across continuation lines).
_dfm_join_copy_statements() {
  local _file="$1"
  awk '
    { line = line $0 }
    /\\[[:space:]]*$/ { sub(/\\[[:space:]]*$/, " ", line); next }
    { print line; line = "" }
    END { if (line != "") print line }
  ' "${_file}"
}

# ── Dispatcher ──────────────────────────────────────────────────────────────

# apply_migrations <dockerfile_path>
#   Iterate _MIGRATIONS in order; for each whose _migrate_<name>_detect
#   matches the file, run _migrate_<name>_apply. Migrations that do not
#   detect are silently skipped (not applicable to this repo's shape).
#   Returns 0 unless the path is unusable.
apply_migrations() {
  local _file="${1:?apply_migrations requires a Dockerfile path}"

  if [[ ! -f "${_file}" ]]; then
    _log_info upgrade upgrade_started "display=  no Dockerfile at ${_file} — skip migrations"
    return 0
  fi

  local _name
  for _name in "${_MIGRATIONS[@]}"; do
    if "_migrate_${_name}_detect" "${_file}"; then
      "_migrate_${_name}_apply" "${_file}"
    fi
  done
}

# ── Migration 1: wrapper COPY shape A/B -> wrapper/*.sh ─────────────────────
#
# v0.41.0 moved the user-facing wrappers (build/run/exec/stop/prune.sh) out
# of the flat .base/script/docker/ root into .base/script/docker/wrapper/.
# Two pre-v0.41.0 lint-stage COPY shapes then resolve to zero files:
#   A  COPY *.sh /lint/                       (root-anchored, the #399 shape)
#   B  COPY .base/script/docker/*.sh /lint/   (flat top-level glob)
# Both heal to the current wrapper-glob shape:
#   COPY .base/script/docker/wrapper/*.sh /lint/
# Idempotent: a Dockerfile already on the wrapper/ shape is not detected.
_migrate_wrapper_copy_detect() {
  local _file="$1"
  grep -qE '^[[:space:]]*COPY[[:space:]]+\*\.sh[[:space:]]+/lint/' "${_file}" \
    || grep -qE '^[[:space:]]*COPY[[:space:]]+\.base/script/docker/\*\.sh[[:space:]]+/lint/' "${_file}"
}

_migrate_wrapper_copy_apply() {
  local _file="$1"
  # Shape A: root-anchored glob.
  sed -i -E 's|^([[:space:]]*)COPY[[:space:]]+\*\.sh[[:space:]]+/lint/|\1COPY .base/script/docker/wrapper/*.sh /lint/|' "${_file}"
  # Shape B: flat top-level .base glob.
  sed -i -E 's|^([[:space:]]*)COPY[[:space:]]+\.base/script/docker/\*\.sh[[:space:]]+/lint/|\1COPY .base/script/docker/wrapper/*.sh /lint/|' "${_file}"
  _log_info upgrade upgrade_started "display=  Dockerfile patched: wrapper COPY -> .base/script/docker/wrapper/*.sh (#567 m1)"
}

# ── Migration 2: retired .base/dockerfile/setup pip helper ──────────────────
#
# v0.41.0 retired the .base/dockerfile/setup pip flow. The downstream RUN
#   RUN PIP_BREAK_SYSTEM_PACKAGES=1 pip install --no-cache-dir \
#       -r "${CONFIG_DIR}"/pip/requirements.txt
# (optionally preceded by a "# Setup pip packages" comment) only ever
# installed base's empty placeholder, so it is a no-op once the helper is
# gone — and a hard failure if CONFIG_DIR/pip/requirements.txt is absent.
# Drop both lines; a repo with a real requirements file re-adds an explicit
# pip step pointing at its own path.
_migrate_pip_helper_detect() {
  local _file="$1"
  grep -qE 'pip install .*-r[[:space:]]+.*\$\{?CONFIG_DIR\}?.*/pip/requirements\.txt' "${_file}"
}

_migrate_pip_helper_apply() {
  local _file="$1"
  sed -i -E '/pip install .*-r[[:space:]]+.*\$\{?CONFIG_DIR\}?.*\/pip\/requirements\.txt/d' "${_file}"
  sed -i '/^# Setup pip packages$/d' "${_file}"
  _log_warn upgrade upgrade_started "display=  Dockerfile patched: dropped retired CONFIG_DIR pip helper line (#567 m2) — re-add an explicit pip step if you ship a real requirements file"
}

# ── Migration 3: explicit hand-listed lib/wrapper COPYs ─────────────────────
#
# Multi-distro repos hand-listed the moved top-level files in their lint
# stage, e.g. `COPY .base/script/docker/_lib.sh .base/script/docker/i18n.sh
# /lint/` or a backslash-continued block of build/run/exec/stop.sh. All
# moved under lib/ and wrapper/ in v0.41.0, so these resolve to zero files.
# The stage already pulls them via the `lib` dir COPY + the wrapper glob, so
# the explicit COPYs are redundant and broken — delete the whole COPY
# statement (handling backslash continuation).
#
# The match anchors on a top-level `.base/script/docker/<name>.sh` reference
# (a bare file directly under docker/) whose COPY destination is the lint
# sandbox `/lint/`. The `/lint/` constraint scopes this to the lint-stage
# redundant COPYs and deliberately spares unrelated runtime helper COPYs
# (e.g. `_entrypoint_logging.sh` -> /usr/local/lib/base/, healed by
# migration 4). It also does NOT match migration-1's output
# `.base/script/docker/wrapper/*.sh` (path segment + glob) nor the
# `.base/script/docker/lib` dir COPY (no `.sh`).
_migrate_explicit_copy_detect() {
  local _file="$1"
  local _stmt
  _stmt="$(_dfm_join_copy_statements "${_file}")"
  grep -qE 'COPY[[:space:]]+.*\.base/script/docker/[A-Za-z_]+\.sh.*[[:space:]]/lint/' <<<"${_stmt}"
}

_migrate_explicit_copy_apply() {
  local _file="$1"
  local _tmp
  _tmp="$(mktemp)"
  # awk state machine: when a COPY statement (possibly spanning backslash
  # continuations) references a top-level .base/script/docker/<name>.sh AND
  # targets the /lint/ sandbox, drop every physical line of that statement;
  # otherwise pass through verbatim.
  awk '
    /^[[:space:]]*COPY[[:space:]]/ {
      stmt = $0; buf = $0 ORS; cont = ($0 ~ /\\[[:space:]]*$/)
      while (cont) {
        if ((getline nxt) <= 0) { break }
        stmt = stmt " " nxt; buf = buf nxt ORS
        cont = (nxt ~ /\\[[:space:]]*$/)
      }
      if (stmt ~ /\.base\/script\/docker\/[A-Za-z_]+\.sh/ && stmt ~ /[[:space:]]\/lint\//) { next }
      printf "%s", buf; next
    }
    { print }
  ' "${_file}" > "${_tmp}"
  mv "${_tmp}" "${_file}"
  _log_info upgrade upgrade_started "display=  Dockerfile patched: dropped redundant explicit lib/wrapper COPY(s) (#567 m3)"
}

# ── Migration 4: _entrypoint_logging.sh -> runtime/logging.sh rename ────────
#
# The host-log helper was renamed `_entrypoint_logging.sh` -> `logging.sh`
# and relocated under runtime/ (#368 -> current). Two downstream references
# break: the Dockerfile COPY of the helper into /usr/local/lib/base/, and
# the entrypoint's `source /usr/local/lib/base/_entrypoint_logging.sh`. The
# Dockerfile COPY is healed in place; when a sibling script/entrypoint.sh
# exists next to the Dockerfile, its source line is healed too (the helper's
# baked path /usr/local/lib/base/_entrypoint_logging.sh -> .../logging.sh).
_migrate_logging_rename_detect() {
  local _file="$1"
  grep -q '_entrypoint_logging\.sh' "${_file}"
}

_migrate_logging_rename_apply() {
  local _file="$1"
  # Dockerfile COPY: old flat helper path -> new runtime/ path, both src and
  # the baked dest filename.
  sed -i -E \
    's|\.base/(downstream/)?script/docker/(runtime/)?_entrypoint_logging\.sh|.base/downstream/script/docker/runtime/logging.sh|g' \
    "${_file}"
  sed -i 's|/usr/local/lib/base/_entrypoint_logging\.sh|/usr/local/lib/base/logging.sh|g' "${_file}"

  # Heal the sibling entrypoint's baked source path, if present. The
  # Dockerfile sits at the repo root; the entrypoint is the conventional
  # script/entrypoint.sh.
  local _entry
  _entry="$(dirname -- "${_file}")/script/entrypoint.sh"
  if [[ -f "${_entry}" ]] && grep -q '_entrypoint_logging\.sh' "${_entry}"; then
    sed -i 's|/usr/local/lib/base/_entrypoint_logging\.sh|/usr/local/lib/base/logging.sh|g' "${_entry}"
    _log_info upgrade upgrade_started "display=  entrypoint patched: _entrypoint_logging.sh -> logging.sh source (#567 m4)"
  fi
  _log_info upgrade upgrade_started "display=  Dockerfile patched: _entrypoint_logging.sh -> runtime/logging.sh (#567 m4)"
}

# Ordered migration list. Append new {detect, transform} pairs here; the
# order is load-bearing (earlier normalisations feed later ones).
_MIGRATIONS=(
  wrapper_copy
  pip_helper
  explicit_copy
  logging_rename
)
