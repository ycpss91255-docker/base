#!/usr/bin/env bash
#
# dockerfile_migrate.sh - declarative Dockerfile-migration list.
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

# ── Migration 0: shipped-tree dir rename .base/downstream/ -> .base/dist/ ────
#
# base's shipped tree was renamed downstream/ -> dist/ (terminology
# de-overload: "downstream" now means only the repo). A consumer Dockerfile
# that hand-references the subtree interior -- the lint-stage
#   COPY .base/downstream/script/docker/lib    /lint/lib
#   COPY .base/downstream/script/docker/wrapper /lint/wrapper
# (the Region C path the earlier base/downstream split wrote in) -- breaks
# with "COPY source not found" once the directory is gone. Rewrite every
# .base/downstream/ COPY source to .base/dist/. Runs first so any later
# migration sees the canonical dist/ path. Idempotent: once rewritten no
# .base/downstream/ remains, so detect returns non-zero on a second run.
_migrate_downstream_to_dist_detect() {
  local _file="$1"
  grep -q '\.base/downstream/' "${_file}"
}

_migrate_downstream_to_dist_apply() {
  local _file="$1"
  sed -i 's#\.base/downstream/#.base/dist/#g' "${_file}"
  _log_info upgrade upgrade_started "display=  Dockerfile patched: .base/downstream/ -> .base/dist/ (#714)"
}

# ── Migration 1: wrapper COPY shape A/B -> wrapper/*.sh ─────────────────────
#
# v0.41.0 moved the user-facing wrappers (build/run/exec/stop/prune.sh) out
# of the flat .base/script/docker/ root into .base/script/docker/wrapper/.
# Two pre-v0.41.0 lint-stage COPY shapes then resolve to zero files:
#   A  COPY *.sh /lint/                       (root-anchored, the shape)
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
# (a bare file directly under docker) whose COPY destination is the lint
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
# and relocated under runtime/ (-> current). Two downstream references
# break: the Dockerfile COPY of the helper into /usr/local/lib/base/, and
# the entrypoint's `source /usr/local/lib/base/_entrypoint_logging.sh`. The
# Dockerfile COPY is healed in place; when a sibling script/entrypoint.sh
# exists next to the Dockerfile, its source line is healed too (the helper's
# baked path /usr/local/lib/base/_entrypoint_logging.sh -> .../logging.sh).
_migrate_logging_rename_detect() {
  local _file="$1"
  # Fire when EITHER the Dockerfile COPY or the sibling entrypoint still
  # references the retired helper name. A partial migration (Dockerfile
  # hand-fixed to runtime/logging.sh, entrypoint still sourcing the old
  # /usr/local/lib/base/_entrypoint_logging.sh) must still heal the
  # entrypoint, otherwise the container cannot source the renamed helper.
  grep -q '_entrypoint_logging\.sh' "${_file}" && return 0
  local _entry
  _entry="$(_dfm_entrypoint_path "${_file}")"
  [[ -f "${_entry}" ]] && grep -q '_entrypoint_logging\.sh' "${_entry}"
}

_migrate_logging_rename_apply() {
  local _file="$1"
  # Dockerfile COPY: old flat helper path -> new runtime/ path, both src and
  # the baked dest filename.
  sed -i -E \
    's#\.base/(downstream/|dist/)?script/docker/(runtime/)?_entrypoint_logging\.sh#.base/dist/script/docker/runtime/logging.sh#g' \
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
# v0.41.0 slimmed .hadolint.yaml so it no longer ignores a batch of
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
#   DL3066  a literal `USER root` gains an inline `# hadolint ignore=DL3066`
#           (the rule postdates hadolint 2.12.0, so no existing consumer
#           Dockerfile answers it, and every one of them has the line)
_migrate_hadolint_detect() {
  local _file="$1"
  grep -Eq '^FROM (bats/bats|alpine):latest' "${_file}" && return 0
  _dfm_needs_dl3046 "${_file}" && return 0
  grep -Eq '^[[:space:]]*RUN[[:space:]]+cd[[:space:]]+/lint[[:space:]]+&&[[:space:]]+hadolint' "${_file}" && return 0
  grep -Eq 'pip install[[:space:]]+-r' "${_file}" && return 0
  _dfm_needs_dl4006 "${_file}" && return 0
  _dfm_needs_dl3006 "${_file}" && return 0
  _dfm_needs_dl3066 "${_file}" && return 0
  return 1
}

# _dfm_needs_dl3046 <file>
#   True when a `useradd` that sets a uid carries no `-l`, whatever order
#   its flags are in. Same head/tail split as the transform, so detect and
#   apply cannot disagree about which line is a candidate.
_dfm_needs_dl3046() {
  local _file="$1"
  awk '
    {
      if (match($0, /(^|[[:space:]])useradd[[:space:]]+/)) {
        _tail = substr($0, RSTART + RLENGTH)
        if (_tail ~ /(^|[[:space:]])(-[[:alnum:]]*u|--uid)([[:space:]]|=)/ &&
            _tail !~ /(^|[[:space:]])(-[[:alnum:]]*l|--no-log-init)([[:space:]]|$)/) {
          found = 1
        }
      }
    }
    END { exit (found ? 0 : 1) }
  ' "${_file}"
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

# _dfm_needs_dl3066 <file>
#   True when a literal `USER root` is present whose preceding line does not
#   already ignore DL3066.
#
#   Only the literal `root` is in scope. DL3066 asks for a NUMERIC user-id so
#   a host or orchestrator can resolve the identity a container runs as, and
#   `root` is the one name every image resolves by definition. Any other
#   literal user is the case the rule is worth having, and `USER "${USER}"`
#   -- the identity these images actually ship with -- is a parameter
#   hadolint does not evaluate. Neither is touched.
_dfm_needs_dl3066() {
  local _file="$1"
  awk '
    /^[[:space:]]*USER[[:space:]]+"?root"?[[:space:]]*$/ &&
      prev !~ /hadolint ignore=[A-Za-z0-9,]*DL3066/ { found=1 }
    { prev=$0 }
    END { exit (found ? 0 : 1) }
  ' "${_file}"
}

_migrate_hadolint_apply() {
  local _file="$1"
  # DL3007: pin the helper-stage :latest tags.
  # The alpine series here is the one base itself builds on -- see
  # ARG ALPINE_VERSION in dockerfile/Dockerfile.test-tools, whose recorded
  # end-of-life fails base's own suite 180 days out. Keeping the two equal
  # is asserted by dockerfile_migrate_spec.bats, so this literal cannot
  # quietly become the older of two dates: it wrote an end-of-life series
  # into every consumer Dockerfile it healed, during an upgrade, which is
  # the moment nobody reads the diff.
  sed -i -E 's|^FROM bats/bats:latest|FROM bats/bats:1.11.0|; s|^FROM alpine:latest|FROM alpine:3.24|' "${_file}"
  # DL3046: useradd -l (idempotent — only adds when not already present).
  #
  # `-l` goes directly after the `useradd` token, not in front of `-u`.
  # Anchoring on `useradd -u` matches only the order base's own template
  # happens to use; a downstream repo writes
  # `useradd -m -s /bin/bash -u ...` and the anchored form walks past it,
  # leaving DL3046 live in a Dockerfile the migration reported as patched.
  # Rewriting the head of the command instead makes the position of the
  # flag being answered irrelevant. Scoped to the text AFTER the useradd
  # token so a sibling `usermod -l` on the same line cannot be read as
  # this command already carrying the flag.
  local _tmp3046
  _tmp3046="$(mktemp)"
  awk '
    {
      if (match($0, /(^|[[:space:]])useradd[[:space:]]+/)) {
        _head = substr($0, 1, RSTART + RLENGTH - 1)
        _tail = substr($0, RSTART + RLENGTH)
        if (_tail ~ /(^|[[:space:]])(-[[:alnum:]]*u|--uid)([[:space:]]|=)/ &&
            _tail !~ /(^|[[:space:]])(-[[:alnum:]]*l|--no-log-init)([[:space:]]|$)/) {
          $0 = _head "-l " _tail
        }
      }
      print
    }
  ' "${_file}" > "${_tmp3046}"
  mv "${_tmp3046}" "${_file}"
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
  # DL3066: inline ignore before each unguarded literal `USER root`.
  #
  # A pragma already sitting above the instruction is EXTENDED, never
  # displaced: hadolint binds an ignore to the NEXT LINE, so inserting a
  # second pragma between an existing one and its instruction would silently
  # re-arm the rule that pragma was answering (the shipped shape of a real
  # downstream Dockerfile is `# hadolint ignore=DL3002` directly above
  # `USER root`). The inserted line copies the USER line's own indentation
  # so the pragma cannot land outside a block it was meant to sit in.
  if _dfm_needs_dl3066 "${_file}"; then
    local _tmp3066
    _tmp3066="$(mktemp)"
    awk '
      function flush(  ) { if (have) { print held; have = 0 } }
      {
        if ($0 ~ /^[[:space:]]*USER[[:space:]]+"?root"?[[:space:]]*$/) {
          if (have && held ~ /hadolint ignore=/) {
            if (held !~ /hadolint ignore=[A-Za-z0-9,]*DL3066/) {
              sub(/hadolint ignore=[A-Za-z0-9,]+/, "&,DL3066", held)
            }
            print held
            have = 0
          } else {
            flush()
            match($0, /^[[:space:]]*/)
            print substr($0, 1, RLENGTH) "# hadolint ignore=DL3066"
          }
          print $0
          next
        }
        flush()
        held = $0
        have = 1
      }
      END { flush() }
    ' "${_file}" > "${_tmp3066}"
    mv "${_tmp3066}" "${_file}"
  fi
  _log_info upgrade upgrade_started "display=  Dockerfile patched: hadolint DL3007/DL3046/DL3003/DL3042/DL4006/DL3006/DL3066 (#567 m5, #946)"
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

# ── Migration 7 (facet B): ARG USER -> ARG USER="${USER_NAME}" ─────────
#
# v0.41.0 compose/CI pass the build args USER_NAME / USER_GROUP / USER_UID /
# USER_GID. A downstream Dockerfile still declaring a bare `ARG USER`
# receives no value, so the image builds the default `initial` user, whose
# home directory mismatches the compose `/home/${USER_NAME}/work` bind
# mount. Re-declare the arg to default from USER_NAME so the existing
# user-creation block (which references ${USER}) keeps working unchanged.
#
# home-literal-lint: allow-begin -- naming the WRONG home directory is the
# whole point of the note below; it is prose about a defect, not a path any
# shipped code reads.
# The mismatching home directory is literally /home/initial.
# home-literal-lint: allow-end
_migrate_arg_user_detect() {
  local _file="$1"
  grep -Eq '^[[:space:]]*ARG[[:space:]]+USER[[:space:]]*$' "${_file}"
}

_migrate_arg_user_apply() {
  local _file="$1"
  # SC2016: the ${USER_NAME} must be written LITERALLY into the Dockerfile
  # (Docker, not this shell, resolves the build arg), so single quotes are
  # intentional.
  # shellcheck disable=SC2016
  sed -i -E 's|^([[:space:]]*)ARG[[:space:]]+USER[[:space:]]*$|\1ARG USER="${USER_NAME}"|' "${_file}"
  _log_info upgrade upgrade_started "display=  Dockerfile patched: ARG USER -> ARG USER=\${USER_NAME} (#567 m7 / #579)"
}

# ── Migration 8 (facet B): nounset-guard the entrypoint ROS source ─────
#
# Under `set -u`, sourcing /opt/ros/$ROS_DISTRO/setup.bash dies on the
# unbound AMENT_TRACE_SETUP_FILES the ament setup chain references, so the
# container exits the instant it starts and `just run` fails. CI never
# catches this — smoke runs at Dockerfile build time and never starts the
# container / runs the ENTRYPOINT. Bracket the source with `set +u` before
# and `set -u` after so unbound vars inside setup.bash do not abort PID 1.
#
# Only fires when the entrypoint actually runs under nounset (`set -u` /
# `set -eu` / `set -euo pipefail`) AND the source is not already guarded by
# an immediately-preceding `set +u`.
_migrate_nounset_source_detect() {
  local _entry
  _entry="$(_dfm_entrypoint_path "$1")"
  [[ -f "${_entry}" ]] || return 1
  grep -Eq '^[[:space:]]*set[[:space:]]+-[a-z]*u' "${_entry}" || return 1
  # An un-guarded source is one whose nearest preceding non-shellcheck-comment
  # line is NOT `set +u` (a shellcheck directive sits between guard and source
  # and must be treated as transparent so re-runs stay idempotent).
  awk '
    /\/opt\/ros\/.*setup\.bash/ {
      if (guard != "+u") { found=1 }
    }
    /^[[:space:]]*#[[:space:]]*shellcheck/ { next }   # transparent: keep guard
    /^[[:space:]]*set[[:space:]]+\+u[[:space:]]*$/ { guard="+u"; next }
    { guard="" }
    END { exit (found ? 0 : 1) }
  ' "${_entry}"
}

_migrate_nounset_source_apply() {
  local _entry
  _entry="$(_dfm_entrypoint_path "$1")"
  local _tmp
  _tmp="$(mktemp)"
  # Wrap each un-guarded setup.bash source with `set +u` / `set -u`,
  # preserving any preceding shellcheck-directive comment line directly above
  # the source (do not split the directive from its target).
  awk '
    /\/opt\/ros\/.*setup\.bash/ && prev !~ /^[[:space:]]*set[[:space:]]+\+u[[:space:]]*$/ {
      # If the previous emitted line was a shellcheck directive for this
      # source, the +u must go ABOVE the directive. Re-buffer it.
      if (held != "") { print "set +u"; print held; held = ""; print; print "set -u"; prev=$0; next }
      print "set +u"; print; print "set -u"; prev=$0; next
    }
    {
      if (held != "") { print held; held = "" }
      if ($0 ~ /^[[:space:]]*#[[:space:]]*shellcheck/) { held=$0; prev=$0; next }
      print; prev=$0
    }
    END { if (held != "") print held }
  ' "${_entry}" > "${_tmp}"
  mv "${_tmp}" "${_entry}"
  _log_info upgrade upgrade_started "display=  entrypoint patched: nounset-guard ROS setup.bash source (#567 m8 / #579)"
}

# ── Migration (smoke-copy): flat .base/test/smoke/ -> per-stage dist tree ────
#
# Up to v0.41.0 base shipped ONE flat smoke tree and the consumer Dockerfile
# copied it whole:
#   COPY .base/test/smoke/ /smoke_test/
# The shipped specs now live under dist/test/bats/smoke/, split into a
# shared/ baseline plus one folder per Dockerfile stage, so that source is
# gone. Rewriting it to the shared baseline alone would build, but would
# silently drop the specs the stage used to run -- so the statement is
# replaced by the shared baseline PLUS the enclosing stage's own folder,
# which is what the current template Dockerfile writes by hand.
#
# The stage folder is emitted only when the freshly pulled subtree actually
# ships one for that stage: a stage base has no specs for (or an unnamed
# final stage) gets the shared baseline and nothing else, rather than a COPY
# of a directory that does not exist. Runs BEFORE flat_to_dist so the
# generic .base/script rewrite never sees these lines.
# Idempotent: once rewritten no flat .base/test/smoke reference remains.
_migrate_smoke_copy_detect() {
  local _file="$1"
  grep -qE '^[[:space:]]*COPY[[:space:]][^#]*\.base/test/smoke/?[[:space:]]' "${_file}"
}

_migrate_smoke_copy_apply() {
  local _file="$1"

  # Which stage folders the subtree ships, as a ":a:b:" membership string
  # awk can test with index(). Read from the tree next to the Dockerfile,
  # i.e. the subtree the upgrade just pulled.
  local _root
  _root="$(dirname -- "${_file}")"
  local _stages=":"
  local _dir
  for _dir in "${_root}"/.base/dist/test/bats/smoke/*/; do
    [[ -d "${_dir}" ]] || continue
    _stages+="$(basename -- "${_dir}"):"
  done

  local _tmp
  _tmp="$(mktemp)"
  # Track the enclosing build stage (`FROM ... AS <name>`) so each rewritten
  # COPY can name its own folder. Substituting into a COPY of the original
  # line preserves whatever flags, destination and column alignment the
  # consumer had.
  awk -v stages="${_stages}" '
    toupper($1) == "FROM" {
      stage = ""
      for (i = 2; i < NF; i++) {
        if (toupper($i) == "AS") { stage = $(i + 1) }
      }
    }
    /^[[:space:]]*COPY[[:space:]]/ && $0 ~ /\.base\/test\/smoke\/?[[:space:]]/ {
      shared = $0
      sub(/\.base\/test\/smoke\/?/, ".base/dist/test/bats/smoke/shared/", shared)
      print shared
      if (stage != "" && index(stages, ":" stage ":") > 0) {
        own = $0
        sub(/\.base\/test\/smoke\/?/, ".base/dist/test/bats/smoke/" stage "/", own)
        print own
      }
      next
    }
    { print }
  ' "${_file}" > "${_tmp}"
  mv "${_tmp}" "${_file}"
  _log_info upgrade upgrade_started "display=  Dockerfile patched: .base/test/smoke/ -> per-stage dist smoke COPYs (#915)"
}

# ── Migration (flat-to-dist): pre-dist .base/ layout -> .base/dist/ ──────────
#
# base's shipped tree moved under dist/. downstream_to_dist above heals the
# `.base/downstream/` spelling, but that layout only ever shipped as a
# prerelease: the layout every stable consumer is actually sitting on is the
# FLAT one that v0.41.0 shipped --
#   COPY .base/script/docker/runtime/logging.sh ...
#   COPY .base/config "${CONFIG_DIR}"
#   COPY .base/script/docker/lib     /lint/lib
#   COPY .base/script/docker/wrapper /lint/wrapper
# -- and the relocation deleted every one of those paths. Nothing migrated
# it, so the upgrade completed cleanly onto a Dockerfile whose first COPY
# BuildKit resolves does not exist, and the repo could not be built.
#
# Rewrites both prefixes wherever they appear, comments included, so the
# commented-out runtime-stage hints a consumer later uncomments are correct
# too. `.base/test` is deliberately NOT in this table: the smoke tree did not
# just move, it was restructured, and smoke_copy above owns it.
#
# Order is load-bearing. It runs AFTER the migrations whose detect anchors on
# the flat spelling (wrapper_copy, explicit_copy) so those still recognise it,
# and BEFORE logrotate_copy / watchdog_copy, which clone the logging.sh COPY
# line -- from the flat path they would append two MORE COPYs of files that
# no longer exist. Idempotent: `.base/dist/...` does not match.
_migrate_flat_to_dist_detect() {
  local _file="$1"
  grep -qE '\.base/(config|script)' "${_file}"
}

_migrate_flat_to_dist_apply() {
  local _file="$1"
  sed -i -e 's#\.base/config#.base/dist/config#g' \
    -e 's#\.base/script#.base/dist/script#g' "${_file}"
  _log_info upgrade upgrade_started "display=  Dockerfile patched: flat .base/{config,script} -> .base/dist/ (#915)"
}

# ── Migration (logrotate-copy): logging.sh's logrotate.sh sibling ────────────
#
# runtime/logging.sh now sources a sibling logrotate.sh from the in-image
# helper dir (the shared per-start-file + symlink + retention primitives).
# A downstream Dockerfile that COPYs logging.sh into /usr/local/lib/base/
# but predates the split lacks the logrotate.sh COPY, so the container tee
# degrades to no rotation/prune. Insert the sibling COPY right after the
# logging.sh COPY, reusing that line's own flag/src shape. Runs after
# logging_rename so the logging COPY is already in its canonical
# runtime/logging.sh -> /usr/local/lib/base/logging.sh form.
_migrate_logrotate_copy_detect() {
  local _file="$1"
  # Fire only on an ACTIVE (non-commented) COPY of the logging helper into
  # its baked dest, with the logrotate sibling not yet COPY'd. Anchoring on
  # the stable dest path (not the src) heals a hand-relocated src too.
  grep -Eq '^[[:space:]]*COPY[^#]*/usr/local/lib/base/logging\.sh([[:space:]]|$)' "${_file}" || return 1
  grep -Eq '^[[:space:]]*COPY[^#]*/usr/local/lib/base/logrotate\.sh([[:space:]]|$)' "${_file}" && return 1
  return 0
}

_migrate_logrotate_copy_apply() {
  local _file="$1"
  # Emit each active logging.sh COPY line, then a logrotate.sh twin with
  # both the src basename and the baked dest rewritten logging -> logrotate.
  local _tmp
  _tmp="$(mktemp)"
  awk '
    { print }
    /^[[:space:]]*COPY[^#]*\/usr\/local\/lib\/base\/logging\.sh([[:space:]]|$)/ {
      twin=$0
      gsub(/logging\.sh/, "logrotate.sh", twin)
      print twin
    }
  ' "${_file}" > "${_tmp}"
  mv "${_tmp}" "${_file}"
  _log_info upgrade upgrade_started "display=  Dockerfile patched: added runtime/logrotate.sh COPY sibling (#805)"
}

# ── Migration (watchdog-copy): watchdog.sh runtime helper sibling ────────────
#
# The generic single-service watchdog ships a new runtime helper
# watchdog.sh, COPY'd next to logging.sh / logrotate.sh at
# /usr/local/lib/base/. A downstream Dockerfile that COPYs logging.sh but
# predates the watchdog lacks the watchdog.sh COPY, so a repo that adds
# `. /usr/local/lib/base/watchdog.sh` to its entrypoint would source a
# missing file. Insert the sibling COPY right after the logging.sh COPY,
# reusing that line's own flag/src shape. Mirrors the logrotate-copy
# migration; runs after logging_rename / logrotate_copy so the logging
# COPY is already canonical. Idempotent: skipped once watchdog.sh is COPY'd.
_migrate_watchdog_copy_detect() {
  local _file="$1"
  # Fire only on an ACTIVE (non-commented) COPY of the logging helper into
  # its baked dest, with the watchdog sibling not yet COPY'd. Anchoring on
  # the stable dest path heals a hand-relocated src too.
  grep -Eq '^[[:space:]]*COPY[^#]*/usr/local/lib/base/logging\.sh([[:space:]]|$)' "${_file}" || return 1
  grep -Eq '^[[:space:]]*COPY[^#]*/usr/local/lib/base/watchdog\.sh([[:space:]]|$)' "${_file}" && return 1
  return 0
}

_migrate_watchdog_copy_apply() {
  local _file="$1"
  # Emit each active logging.sh COPY line, then a watchdog.sh twin with both
  # the src basename and the baked dest rewritten logging -> watchdog.
  local _tmp
  _tmp="$(mktemp)"
  awk '
    { print }
    /^[[:space:]]*COPY[^#]*\/usr\/local\/lib\/base\/logging\.sh([[:space:]]|$)/ {
      twin=$0
      gsub(/logging\.sh/, "watchdog.sh", twin)
      print twin
    }
  ' "${_file}" > "${_tmp}"
  mv "${_tmp}" "${_file}"
  _log_info upgrade upgrade_started "display=  Dockerfile patched: added runtime/watchdog.sh COPY sibling (#797)"
}

# Ordered migration list. Append new {detect, transform} pairs here; the
# order is load-bearing (earlier normalisations feed later ones).
_MIGRATIONS=(
  downstream_to_dist
  wrapper_copy
  pip_helper
  explicit_copy
  logging_rename
  smoke_copy
  flat_to_dist
  logrotate_copy
  watchdog_copy
  hadolint
  sc1090
  arg_user
  nounset_source
)
