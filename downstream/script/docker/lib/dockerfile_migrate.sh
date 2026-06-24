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

# _dfm_entrypoint_path <dockerfile>
#   Resolve the conventional sibling entrypoint (script/entrypoint.sh) next
#   to a repo-root Dockerfile. Echoes the path (whether or not it exists).
_dfm_entrypoint_path() {
  local _file="$1"
  printf '%s/script/entrypoint.sh' "$(dirname -- "${_file}")"
}

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
  _entry="$(_dfm_entrypoint_path "${_file}")"
  if [[ -f "${_entry}" ]] && grep -q '_entrypoint_logging\.sh' "${_entry}"; then
    sed -i 's|/usr/local/lib/base/_entrypoint_logging\.sh|/usr/local/lib/base/logging.sh|g' "${_entry}"
    _log_info upgrade upgrade_started "display=  entrypoint patched: _entrypoint_logging.sh -> logging.sh source (#567 m4)"
  fi
  _log_info upgrade upgrade_started "display=  Dockerfile patched: _entrypoint_logging.sh -> runtime/logging.sh (#567 m4)"
}

# ── Migration 5: hadolint rules surfaced by the slimmed .hadolint.yaml ──────
#
# v0.41.0 slimmed .hadolint.yaml (#466) so it no longer ignores a batch of
# rules the v0.41.0 template Dockerfile already satisfies but older
# downstream Dockerfiles do not. This migration mechanically heals the same
# violations the ad-hoc fanout fixed by hand (each sub-fix is idempotent):
#   DL3007  pin `FROM bats/bats:latest` / `FROM alpine:latest` helper stages
#   DL3046  `useradd -u`  -> `useradd -l -u`
#   DL3003  `RUN cd /lint && hadolint ...` -> `WORKDIR /lint` + `RUN hadolint`
#   DL3042  `pip install -r` -> `pip install --no-cache-dir -r`
#   DL4006  alpine lint-tools stage gains a `SHELL [ash -o pipefail]`
#   DL3006  parameterized `FROM ${BASE_IMAGE}` / `${TEST_TOOLS_IMAGE}` gains
#           an inline `# hadolint ignore=DL3006` (an ARG-driven base image
#           cannot be explicitly tagged)
_migrate_hadolint_detect() {
  local _file="$1"
  grep -Eq '^FROM (bats/bats|alpine):latest' "${_file}" && return 0
  grep -Eq 'useradd[[:space:]]+-u[[:space:]]' "${_file}" && return 0
  grep -Eq '^[[:space:]]*RUN[[:space:]]+cd[[:space:]]+/lint[[:space:]]+&&[[:space:]]+hadolint' "${_file}" && return 0
  grep -Eq 'pip install[[:space:]]+-r' "${_file}" && return 0
  _dfm_needs_dl4006 "${_file}" && return 0
  _dfm_needs_dl3006 "${_file}" && return 0
  return 1
}

# _dfm_needs_dl4006 <file>
#   True when an `alpine ... AS lint-tools` stage is present without a
#   following SHELL ash-pipefail directive.
_dfm_needs_dl4006() {
  local _file="$1"
  grep -Eq '^FROM alpine:[^[:space:]]+ AS lint-tools' "${_file}" \
    && ! grep -Fq 'SHELL ["/bin/ash", "-o", "pipefail", "-c"]' "${_file}"
}

# _dfm_needs_dl3006 <file>
#   True when a parameterized `FROM ${IMAGE}` lacks a preceding inline ignore.
_dfm_needs_dl3006() {
  local _file="$1"
  awk '
    /^FROM \$\{[A-Za-z_]+\}/ && prev !~ /hadolint ignore=DL3006/ { found=1 }
    { prev=$0 }
    END { exit (found ? 0 : 1) }
  ' "${_file}"
}

_migrate_hadolint_apply() {
  local _file="$1"
  # DL3007: pin the helper-stage :latest tags.
  sed -i -E 's|^FROM bats/bats:latest|FROM bats/bats:1.11.0|; s|^FROM alpine:latest|FROM alpine:3.21|' "${_file}"
  # DL3046: useradd -l (idempotent — only adds when not already present).
  sed -i -E 's|useradd[[:space:]]+-u[[:space:]]|useradd -l -u |' "${_file}"
  sed -i -E 's|useradd -l[[:space:]]+-l |useradd -l |' "${_file}"
  # DL3042: pip --no-cache-dir (idempotent).
  sed -i -E 's|pip install[[:space:]]+-r|pip install --no-cache-dir -r|' "${_file}"
  sed -i -E 's|pip install --no-cache-dir --no-cache-dir|pip install --no-cache-dir|' "${_file}"
  # DL3003: cd /lint -> WORKDIR /lint + RUN.
  sed -i -E 's|^([[:space:]]*)RUN[[:space:]]+cd[[:space:]]+/lint[[:space:]]+&&[[:space:]]+hadolint[[:space:]]+(.*)$|\1WORKDIR /lint\n\1RUN hadolint \2|' "${_file}"

  # DL4006: SHELL ash-pipefail right after the alpine lint-tools FROM.
  if _dfm_needs_dl4006 "${_file}"; then
    sed -i -E '/^FROM alpine:[^[:space:]]+ AS lint-tools/a SHELL ["/bin/ash", "-o", "pipefail", "-c"]' "${_file}"
  fi

  # DL3006: inline ignore before each unguarded parameterized FROM.
  if _dfm_needs_dl3006 "${_file}"; then
    local _tmp
    _tmp="$(mktemp)"
    awk '
      /^FROM \$\{[A-Za-z_]+\}/ && prev !~ /hadolint ignore=DL3006/ { print "# hadolint ignore=DL3006" }
      { print; prev=$0 }
    ' "${_file}" > "${_tmp}"
    mv "${_tmp}" "${_file}"
  fi
  _log_info upgrade upgrade_started "display=  Dockerfile patched: hadolint DL3007/DL3046/DL3003/DL3042/DL4006/DL3006 (#567 m5)"
}

# ── Migration 6: noetic entrypoint SC1090 directive ─────────────────────────
#
# The noetic sensor entrypoints `source "/opt/ros/${ROS_DISTRO}/setup.bash"`
# with a stale `# shellcheck disable=SC1091` directive. The non-constant
# path triggers SC1090 (not SC1091), so the slimmed v0.41.0 lint stage fails.
# Broaden the directive to `SC1090,SC1091` on the sibling entrypoint.
_migrate_sc1090_detect() {
  local _entry
  _entry="$(_dfm_entrypoint_path "$1")"
  [[ -f "${_entry}" ]] || return 1
  grep -Eq '^[[:space:]]*#[[:space:]]*shellcheck disable=SC1091[[:space:]]*$' "${_entry}"
}

_migrate_sc1090_apply() {
  local _entry
  _entry="$(_dfm_entrypoint_path "$1")"
  sed -i -E 's|^([[:space:]]*#[[:space:]]*shellcheck disable=)SC1091([[:space:]]*)$|\1SC1090,SC1091\2|' "${_entry}"
  _log_info upgrade upgrade_started "display=  entrypoint patched: shellcheck SC1091 -> SC1090,SC1091 (#567 m6)"
}

# ── Migration 7 (#579 facet B): ARG USER -> ARG USER="${USER_NAME}" ─────────
#
# v0.41.0 compose/CI pass the build args USER_NAME / USER_GROUP / USER_UID /
# USER_GID. A downstream Dockerfile still declaring a bare `ARG USER`
# receives no value, so the image builds the default `initial` user and its
# /home/initial home — mismatching the compose `/home/${USER_NAME}/work`
# bind mount. Re-declare the arg to default from USER_NAME so the existing
# user-creation block (which references ${USER}) keeps working unchanged.
_migrate_arg_user_detect() {
  local _file="$1"
  grep -Eq '^[[:space:]]*ARG[[:space:]]+USER[[:space:]]*$' "${_file}"
}

_migrate_arg_user_apply() {
  local _file="$1"
  sed -i -E 's|^([[:space:]]*)ARG[[:space:]]+USER[[:space:]]*$|\1ARG USER="${USER_NAME}"|' "${_file}"
  _log_info upgrade upgrade_started "display=  Dockerfile patched: ARG USER -> ARG USER=\${USER_NAME} (#567 m7 / #579)"
}

# Ordered migration list. Append new {detect, transform} pairs here; the
# order is load-bearing (earlier normalisations feed later ones).
_MIGRATIONS=(
  wrapper_copy
  pip_helper
  explicit_copy
  logging_rename
  hadolint
  sc1090
  arg_user
)
