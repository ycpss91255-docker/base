#!/usr/bin/env bats
#
# dockerfile_migrate_spec.bats - unit tests for the declarative
# Dockerfile-migration list (folds facet B).
#
# lib/dockerfile_migrate.sh exposes a small interface --
# `apply_migrations <dockerfile_path>` -- backed by an ordered, data-driven
# list of {detect, transform} migrations. Each migration heals one
# v0.41.0-fanout Dockerfile/entrypoint breakage. These tests drive each
# {detect, transform} unit in isolation via before/after fixtures, plus the
# dispatcher's apply/skip/idempotency contract.
#
# Apply policy (inherited from upgrade.sh's Step-5 convention):
#   - detect matches a known shape  -> transform auto-applies, idempotent
#   - structure absent / ambiguous  -> _log_warn + SKIP (never force-rewrite)

bats_require_minimum_version 1.5.0

LIB="/source/dist/script/docker/lib"

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  TEMP_DIR="$(mktemp -d)"
  export TEMP_DIR
  DF="${TEMP_DIR}/Dockerfile"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# _run_migrate <fn> [args...]
#   Source the lib in a fresh shell and invoke one of its functions, so
#   each test exercises the real function body (not a copy). _lib.sh
#   brings in _log_* for the warn/skip messaging.
_src() {
  printf 'source %s/_lib.sh; source %s/dockerfile_migrate.sh' "${LIB}" "${LIB}"
}

# ── dispatcher contract: apply_migrations ───────────────────────────────────

@test "apply_migrations is the public dispatcher entry (#567)" {
  run bash -c "$(_src); declare -F apply_migrations"
  assert_success
}

@test "apply_migrations skips cleanly when path does not exist (#567)" {
  run bash -c "$(_src); apply_migrations '${TEMP_DIR}/nope'"
  assert_success
  assert_output --partial "no Dockerfile"
}

@test "_MIGRATIONS is a non-empty ordered list (#567)" {
  run bash -c "$(_src); printf '%s\n' \"\${_MIGRATIONS[@]}\""
  assert_success
  [ "${#lines[@]}" -ge 1 ]
}

# ── migration 0: shipped-tree dir rename .base/downstream/ -> .base/dist/ ────
# base's shipped tree was renamed downstream/ -> dist/. A consumer
# Dockerfile that hand-references the lint-stage lib/wrapper dir COPY under
# .base/downstream/ breaks with "COPY source not found" after the rename;
# every .base/downstream/ COPY source heals to .base/dist/.

@test "migration 0 (downstream-to-dist): rewrites lib/wrapper COPY sources to .base/dist/ (#714)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/downstream/script/docker/lib /lint/lib
COPY .base/downstream/script/docker/wrapper /lint/wrapper
RUN shellcheck -S warning /lint/*.sh
EOF
  run bash -c "$(_src); _migrate_downstream_to_dist_detect '${DF}' && _migrate_downstream_to_dist_apply '${DF}'"
  assert_success
  grep -Fq "COPY .base/dist/script/docker/lib /lint/lib" "${DF}"
  grep -Fq "COPY .base/dist/script/docker/wrapper /lint/wrapper" "${DF}"
  ! grep -q '\.base/downstream/' "${DF}"
}

@test "migration 0 (downstream-to-dist): detect false when no .base/downstream/ reference (#714)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/dist/script/docker/lib /lint/lib
EOF
  run bash -c "$(_src); _migrate_downstream_to_dist_detect '${DF}'"
  assert_failure
}

@test "migration 0 (downstream-to-dist): idempotent — second run is a no-op (#714)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/downstream/script/docker/lib /lint/lib
EOF
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  cp "${DF}" "${DF}.orig"
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  diff "${DF}" "${DF}.orig"
}

# ── migration 1: wrapper COPY shape A/B -> wrapper/*.sh ──────────────────────
# v0.41.0 moved the user-facing wrappers into .base/script/docker/wrapper/.
# Two pre-v0.41.0 lint-stage shapes break:
#   A  COPY *.sh /lint/                       (root-anchored, era)
#   B  COPY .base/script/docker/*.sh /lint/   (flat top-level glob)
# Both heal to the wrapper-glob shape COPY .base/script/docker/wrapper/*.sh.

@test "migration 1 (wrapper-copy): rewrites shape A 'COPY *.sh /lint/' (#567)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY *.sh /lint/
RUN shellcheck -S warning /lint/*.sh
EOF
  run bash -c "$(_src); _migrate_wrapper_copy_detect '${DF}' && _migrate_wrapper_copy_apply '${DF}'"
  assert_success
  grep -Fq "COPY .base/script/docker/wrapper/*.sh /lint/" "${DF}"
  ! grep -Eq '^[[:space:]]*COPY[[:space:]]+\*\.sh[[:space:]]+/lint/' "${DF}"
}

@test "migration 1 (wrapper-copy): rewrites shape B 'COPY .base/script/docker/*.sh /lint/' (#567)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/script/docker/*.sh /lint/
RUN shellcheck -S warning /lint/*.sh
EOF
  run bash -c "$(_src); _migrate_wrapper_copy_detect '${DF}' && _migrate_wrapper_copy_apply '${DF}'"
  assert_success
  grep -Fq "COPY .base/script/docker/wrapper/*.sh /lint/" "${DF}"
  ! grep -Eq '^[[:space:]]*COPY[[:space:]]+\.base/script/docker/\*\.sh[[:space:]]+/lint/' "${DF}"
}

# The settled shape is the DIST one: wrapper_copy writes the flat
# .base/script/docker/wrapper/*.sh and flat_to_dist (which runs later in
# the list, by design) carries it the rest of the way. A Dockerfile already
# on the flat path is therefore not a fixed point of the dispatcher -- that
# path no longer exists -- so the no-op fixture is the dist spelling.
@test "migration 1 (wrapper-copy): idempotent — second run is a no-op (#567)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/dist/script/docker/wrapper/*.sh /lint/
RUN shellcheck -S warning /lint/*.sh
EOF
  cp "${DF}" "${DF}.orig"
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  diff "${DF}" "${DF}.orig"
}

@test "migration 1 (wrapper-copy): the dispatcher lands shape A on the dist wrapper glob (#915)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY *.sh /lint/
RUN shellcheck -S warning /lint/*.sh
EOF
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  grep -Fq "COPY .base/dist/script/docker/wrapper/*.sh /lint/" "${DF}"
}

@test "migration 1 (wrapper-copy): detect is false when no legacy wrapper COPY present (#567)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/script/docker/wrapper/*.sh /lint/
EOF
  run bash -c "$(_src); _migrate_wrapper_copy_detect '${DF}'"
  assert_failure
}

# ── migration 2: retired .base/dockerfile/setup pip helper ──────────────────
# v0.41.0 retired the .base/dockerfile/setup pip flow. The downstream line
#   RUN PIP_BREAK_SYSTEM_PACKAGES=1 pip install --no-cache-dir -r "${CONFIG_DIR}"/pip/requirements.txt
# (+ a preceding "# Setup pip packages" comment) installed base's empty
# placeholder — a no-op once the helper is gone. Drop both lines; the user
# re-adds an explicit pip step if they have a real requirements file.

@test "migration 2 (pip-helper): drops the retired CONFIG_DIR pip install line (#567)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS sys
# Setup pip packages
RUN PIP_BREAK_SYSTEM_PACKAGES=1 pip install --no-cache-dir -r "${CONFIG_DIR}"/pip/requirements.txt
RUN echo done
EOF
  run bash -c "$(_src); _migrate_pip_helper_detect '${DF}' && _migrate_pip_helper_apply '${DF}'"
  assert_success
  ! grep -q 'CONFIG_DIR.*pip/requirements.txt' "${DF}"
  ! grep -q '# Setup pip packages' "${DF}"
  grep -Fq "RUN echo done" "${DF}"
}

@test "migration 2 (pip-helper): idempotent — no pip line means detect false (#567)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS sys
RUN echo done
EOF
  run bash -c "$(_src); _migrate_pip_helper_detect '${DF}'"
  assert_failure
}

# ── migration 3: explicit hand-listed lib/wrapper COPYs ─────────────────────
# Multi-distro repos (ros_distro / ros2_distro / ros1_bridge) hand-listed the
# now-moved top-level files in their lint stage, e.g.
#   COPY .base/script/docker/_lib.sh .base/script/docker/i18n.sh /lint/
#   COPY .base/script/docker/build.sh .base/script/docker/run.sh ... /lint/
# These resolve to zero files post-v0.41.0. The stage already pulls
# 'COPY .base/script/docker/lib /lint/lib' + 'COPY script/*.sh /lint/', so
# the explicit COPYs are redundant and broken — drop them. Multi-line
# backslash-continued forms are handled too.

@test "migration 3 (explicit-copy): drops single-line explicit top-level .sh COPY (#567)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/script/docker/_lib.sh .base/script/docker/i18n.sh /lint/
COPY .base/script/docker/lib /lint/lib
RUN shellcheck -S warning /lint/*.sh /lint/lib/*.sh
EOF
  run bash -c "$(_src); _migrate_explicit_copy_detect '${DF}' && _migrate_explicit_copy_apply '${DF}'"
  assert_success
  ! grep -Eq 'COPY .*\.base/script/docker/[A-Za-z_]+\.sh' "${DF}"
  grep -Fq "COPY .base/script/docker/lib /lint/lib" "${DF}"
}

@test "migration 3 (explicit-copy): drops multi-line backslash-continued COPY block (#567)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/script/docker/_lib.sh \
     .base/script/docker/i18n.sh \
     .base/script/docker/_tui_conf.sh \
     /lint/
COPY .base/script/docker/lib /lint/lib
RUN shellcheck -S warning /lint/*.sh /lint/lib/*.sh
EOF
  run bash -c "$(_src); _migrate_explicit_copy_detect '${DF}' && _migrate_explicit_copy_apply '${DF}'"
  assert_success
  ! grep -Eq 'COPY .*\.base/script/docker/[A-Za-z_]+\.sh' "${DF}"
  ! grep -q '_tui_conf.sh' "${DF}"
  grep -Fq "COPY .base/script/docker/lib /lint/lib" "${DF}"
}

@test "migration 3 (explicit-copy): detect false when lint stage uses lib/wrapper dir COPYs only (#567)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/script/docker/lib /lint/lib
COPY .base/script/docker/wrapper/*.sh /lint/
EOF
  run bash -c "$(_src); _migrate_explicit_copy_detect '${DF}'"
  assert_failure
}

# ── migration 4: _entrypoint_logging.sh -> runtime/logging.sh rename ─────────
# The host-log helper was renamed _entrypoint_logging.sh -> logging.sh and
# relocated under runtime/. Two references break in a downstream:
#   - the Dockerfile COPY of the helper into /usr/local/lib/base/
#   - the entrypoint that sources /usr/local/lib/base/_entrypoint_logging.sh
# Migration heals the COPY in the Dockerfile AND (when a sibling
# script/entrypoint.sh exists) its source line.

@test "migration 4 (logging-rename): rewrites the Dockerfile COPY to runtime/logging.sh (#567)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/script/docker/_entrypoint_logging.sh /usr/local/lib/base/_entrypoint_logging.sh
EOF
  run bash -c "$(_src); _migrate_logging_rename_detect '${DF}' && _migrate_logging_rename_apply '${DF}'"
  assert_success
  grep -Fq "COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh" "${DF}"
  ! grep -q '_entrypoint_logging.sh' "${DF}"
}

@test "migration 4 (logging-rename): rewrites a sibling entrypoint source line (#567)" {
  mkdir -p "${TEMP_DIR}/script"
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/script/docker/_entrypoint_logging.sh /usr/local/lib/base/_entrypoint_logging.sh
EOF
  cat > "${TEMP_DIR}/script/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
. /usr/local/lib/base/_entrypoint_logging.sh
exec "$@"
EOF
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  grep -Fq ". /usr/local/lib/base/logging.sh" "${TEMP_DIR}/script/entrypoint.sh"
  ! grep -q '_entrypoint_logging.sh' "${TEMP_DIR}/script/entrypoint.sh"
}

@test "migration 4 (logging-rename): detect false when already on new name (#567)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
EOF
  run bash -c "$(_src); _migrate_logging_rename_detect '${DF}'"
  assert_failure
}

@test "migration 4 (logging-rename): heals a stale entrypoint when the Dockerfile is already migrated (#692)" {
  # Partial-migration state: a downstream repo hand-fixed the Dockerfile COPY
  # to runtime/logging.sh, but its sibling entrypoint still sources the old
  # baked /usr/local/lib/base/_entrypoint_logging.sh path. detect must still
  # fire (so apply runs and heals the entrypoint), otherwise the container
  # cannot source the renamed helper.
  mkdir -p "${TEMP_DIR}/script"
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
EOF
  cat > "${TEMP_DIR}/script/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
. /usr/local/lib/base/_entrypoint_logging.sh
exec "$@"
EOF
  run bash -c "$(_src); _migrate_logging_rename_detect '${DF}'"
  assert_success
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  grep -Fq ". /usr/local/lib/base/logging.sh" "${TEMP_DIR}/script/entrypoint.sh"
  ! grep -q '_entrypoint_logging.sh' "${TEMP_DIR}/script/entrypoint.sh"
}

# ── migration (smoke-copy): flat .base/test/smoke/ -> per-stage dist tree ────
# v0.41.0 shipped one flat smoke tree and the consumer Dockerfile copied it
# whole. The shipped specs now live under dist/test/bats/smoke/ split into
# shared/ + one folder per Dockerfile stage, so the flat COPY source is
# gone. The migration rewrites the single COPY into the shared baseline
# plus the enclosing stage's own folder, keeping the specs that stage used
# to run instead of quietly dropping them.

@test "migration (smoke-copy): rewrites the flat COPY into shared + the stage's own folder (#915)" {
  mkdir -p "${TEMP_DIR}/.base/dist/test/bats/smoke/shared" \
    "${TEMP_DIR}/.base/dist/test/bats/smoke/devel-test"
  cat > "${DF}" <<'EOF'
FROM devel AS devel-test
COPY .base/test/smoke/ /smoke_test/
COPY test/smoke/ /smoke_test/
EOF
  run bash -c "$(_src); _migrate_smoke_copy_detect '${DF}' && _migrate_smoke_copy_apply '${DF}'"
  assert_success
  grep -Fq "COPY .base/dist/test/bats/smoke/shared/ /smoke_test/" "${DF}"
  grep -Fq "COPY .base/dist/test/bats/smoke/devel-test/ /smoke_test/" "${DF}"
  ! grep -q '\.base/test/smoke/' "${DF}"
  # The repo's OWN smoke COPY is not a base path and is left alone.
  grep -Fq "COPY test/smoke/ /smoke_test/" "${DF}"
}

@test "migration (smoke-copy): emits only the shared baseline when the stage ships no folder (#915)" {
  mkdir -p "${TEMP_DIR}/.base/dist/test/bats/smoke/shared"
  cat > "${DF}" <<'EOF'
FROM devel AS custom-test
COPY .base/test/smoke/ /smoke_test/
EOF
  run bash -c "$(_src); _migrate_smoke_copy_apply '${DF}'"
  assert_success
  grep -Fq "COPY .base/dist/test/bats/smoke/shared/ /smoke_test/" "${DF}"
  ! grep -q 'smoke/custom-test/' "${DF}"
}

@test "migration (smoke-copy): idempotent — detect false once already on the dist tree (#915)" {
  cat > "${DF}" <<'EOF'
FROM devel AS devel-test
COPY .base/dist/test/bats/smoke/shared/ /smoke_test/
COPY .base/dist/test/bats/smoke/devel-test/ /smoke_test/
EOF
  run bash -c "$(_src); _migrate_smoke_copy_detect '${DF}'"
  assert_failure
}

# The same tree was also reached FILE BY FILE. Two consumer repos hand-list
# the specs instead of copying the directory -- one COPY per spec, and every
# spec on a single COPY -- and those sources died in the same relocation.
# The migration resolves each named spec against the freshly pulled subtree
# by basename, so what heals them is where the tree says the spec now is.

@test "migration (smoke-copy): rewrites a hand-listed spec to where the subtree ships it (#928)" {
  mkdir -p "${TEMP_DIR}/.base/dist/test/bats/smoke/shared" \
    "${TEMP_DIR}/.base/dist/test/bats/smoke/devel-test"
  : > "${TEMP_DIR}/.base/dist/test/bats/smoke/shared/test_helper.bash"
  : > "${TEMP_DIR}/.base/dist/test/bats/smoke/devel-test/script_help.bats"
  cat > "${DF}" <<'DOCKERFILE'
FROM devel AS devel-test
COPY .base/test/smoke/test_helper.bash /smoke_test/test_helper.bash
COPY .base/test/smoke/script_help.bats /smoke_test/script_help.bats
DOCKERFILE
  run bash -c "$(_src); _migrate_smoke_copy_detect '${DF}' && _migrate_smoke_copy_apply '${DF}'"
  assert_success
  # Each spec lands where the subtree actually ships it -- the two are in
  # DIFFERENT folders, so a single blanket prefix could not have done this.
  grep -Fq "COPY .base/dist/test/bats/smoke/shared/test_helper.bash /smoke_test/test_helper.bash" "${DF}"
  grep -Fq "COPY .base/dist/test/bats/smoke/devel-test/script_help.bats /smoke_test/script_help.bats" "${DF}"
  ! grep -q '\.base/test/smoke/' "${DF}"
}

@test "migration (smoke-copy): rewrites every source of a multi-source hand-listed COPY (#928)" {
  mkdir -p "${TEMP_DIR}/.base/dist/test/bats/smoke/shared" \
    "${TEMP_DIR}/.base/dist/test/bats/smoke/devel-test"
  : > "${TEMP_DIR}/.base/dist/test/bats/smoke/shared/test_helper.bash"
  : > "${TEMP_DIR}/.base/dist/test/bats/smoke/devel-test/script_help.bats"
  cat > "${DF}" <<'DOCKERFILE'
FROM devel AS devel-test
COPY .base/test/smoke/test_helper.bash .base/test/smoke/script_help.bats /smoke_test/
DOCKERFILE
  run bash -c "$(_src); _migrate_smoke_copy_detect '${DF}' && _migrate_smoke_copy_apply '${DF}'"
  assert_success
  grep -Fq "COPY .base/dist/test/bats/smoke/shared/test_helper.bash .base/dist/test/bats/smoke/devel-test/script_help.bats /smoke_test/" "${DF}"
  ! grep -q '\.base/test/smoke/' "${DF}"
}

@test "migration (smoke-copy): declines a hand-listed spec the subtree no longer ships (#928)" {
  mkdir -p "${TEMP_DIR}/.base/dist/test/bats/smoke/shared"
  : > "${TEMP_DIR}/.base/dist/test/bats/smoke/shared/test_helper.bash"
  cat > "${DF}" <<'DOCKERFILE'
FROM devel AS devel-test
COPY .base/test/smoke/retired.bats /smoke_test/retired.bats
DOCKERFILE
  run bash -c "$(_src); _migrate_smoke_copy_apply '${DF}'"
  assert_success
  # Left as written, and SAID so: a guessed destination would resolve to a
  # path the subtree does not ship, which is the failure this heals.
  grep -Fq "COPY .base/test/smoke/retired.bats /smoke_test/retired.bats" "${DF}"
  assert_output --partial "resolve it by hand"
}

@test "migration (smoke-copy): declines a hand-listed spec the subtree ships at two paths (#928)" {
  mkdir -p "${TEMP_DIR}/.base/dist/test/bats/smoke/shared" \
    "${TEMP_DIR}/.base/dist/test/bats/smoke/devel-test"
  : > "${TEMP_DIR}/.base/dist/test/bats/smoke/shared/ambiguous.bats"
  : > "${TEMP_DIR}/.base/dist/test/bats/smoke/devel-test/ambiguous.bats"
  cat > "${DF}" <<'DOCKERFILE'
FROM devel AS devel-test
COPY .base/test/smoke/ambiguous.bats /smoke_test/ambiguous.bats
DOCKERFILE
  run bash -c "$(_src); _migrate_smoke_copy_apply '${DF}'"
  assert_success
  grep -Fq "COPY .base/test/smoke/ambiguous.bats /smoke_test/ambiguous.bats" "${DF}"
  assert_output --partial "resolve it by hand"
}

# ── migration (flat-to-dist): v0.41.0 flat .base/ layout -> .base/dist/ ──────
# The stable layout deployed on every consumer is the FLAT one: .base/config,
# .base/script/... . The dist relocation deleted both. downstream_to_dist
# only ever matched .base/downstream/, a layout that shipped as a
# prerelease and that no stable consumer is on -- so nothing migrated the
# layout that is actually out there, and the upgrade completed cleanly onto
# a Dockerfile whose every base COPY source had just been deleted.

@test "migration (flat-to-dist): rewrites the flat lint-stage lib/wrapper COPYs (#915)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/script/docker/lib /lint/lib
COPY .base/script/docker/wrapper /lint/wrapper
EOF
  run bash -c "$(_src); _migrate_flat_to_dist_detect '${DF}' && _migrate_flat_to_dist_apply '${DF}'"
  assert_success
  grep -Fq "COPY .base/dist/script/docker/lib /lint/lib" "${DF}"
  grep -Fq "COPY .base/dist/script/docker/wrapper /lint/wrapper" "${DF}"
  ! grep -q '\.base/script/' "${DF}"
}

@test "migration (flat-to-dist): rewrites the flat config COPY (#915)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chown="${USER}":"${GROUP}" --chmod=0755 .base/config "${CONFIG_DIR}"
EOF
  run bash -c "$(_src); _migrate_flat_to_dist_apply '${DF}'"
  assert_success
  grep -Fq '.base/dist/config "${CONFIG_DIR}"' "${DF}"
}

@test "migration (flat-to-dist): idempotent — detect false on an already-dist Dockerfile (#915)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/dist/script/docker/lib /lint/lib
COPY .base/dist/config /tmp/config
EOF
  run bash -c "$(_src); _migrate_flat_to_dist_detect '${DF}'"
  assert_failure
}

@test "migration (flat-to-dist): dispatcher run twice rewrites exactly once (#915)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS lint
COPY .base/script/docker/lib /lint/lib
EOF
  run bash -c "$(_src); apply_migrations '${DF}'; apply_migrations '${DF}'"
  assert_success
  grep -Fq "COPY .base/dist/script/docker/lib /lint/lib" "${DF}"
  ! grep -q '\.base/dist/dist/' "${DF}"
}

# ── dispatcher over the whole v0.41.0 shape ─────────────────────────────────
# The unit tests above drive one {detect, transform} pair each. This one
# drives the dispatcher over the shape a real v0.41.0 consumer carries,
# because ORDER is what decides whether the logrotate / watchdog twins are
# generated from an already-dist-rooted logging COPY or from the flat one --
# and appending two more COPYs of paths that no longer exist is a strictly
# worse outcome than leaving the Dockerfile alone.

@test "apply_migrations leaves no .base COPY source behind on the v0.41.0 shape (#915)" {
  mkdir -p "${TEMP_DIR}/.base/dist/test/bats/smoke/shared" \
    "${TEMP_DIR}/.base/dist/test/bats/smoke/devel-test"
  cat > "${DF}" <<'EOF'
FROM ${BASE_IMAGE} AS devel
# hadolint ignore=DL3006
COPY --chmod=0755 .base/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
COPY --chown="${USER}":"${GROUP}" --chmod=0755 .base/config "${CONFIG_DIR}"

FROM devel AS devel-test
COPY .base/script/docker/lib /lint/lib
COPY .base/script/docker/wrapper /lint/wrapper
RUN shellcheck -S warning /lint/wrapper/*.sh /lint/lib/*.sh
COPY .base/test/smoke/ /smoke_test/
COPY test/smoke/ /smoke_test/
EOF
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  # Nothing may still name the deleted flat layout -- including the
  # logrotate / watchdog COPYs the dispatcher itself appends.
  run grep -nE '\.base/(config|script|test)/' "${DF}"
  assert_failure
  grep -Fq "COPY --chmod=0755 .base/dist/script/docker/runtime/logrotate.sh /usr/local/lib/base/logrotate.sh" "${DF}"
  grep -Fq "COPY --chmod=0755 .base/dist/script/docker/runtime/watchdog.sh /usr/local/lib/base/watchdog.sh" "${DF}"
}

# ── migration (logrotate-copy): logging.sh's logrotate.sh sibling ────────────
# runtime/logging.sh now sources a sibling logrotate.sh from the in-image
# helper dir. A downstream Dockerfile that COPYs logging.sh but predates the
# split lacks the logrotate.sh COPY, so the container tee degrades. This
# migration inserts the sibling COPY after the logging.sh COPY.

@test "migration (logrotate-copy): inserts logrotate.sh COPY after the logging.sh COPY (#805)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
EOF
  run bash -c "$(_src); _migrate_logrotate_copy_detect '${DF}' && _migrate_logrotate_copy_apply '${DF}'"
  assert_success
  grep -Fq "COPY --chmod=0755 .base/dist/script/docker/runtime/logrotate.sh /usr/local/lib/base/logrotate.sh" "${DF}"
  # The original logging.sh COPY is preserved.
  grep -Fq "COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh" "${DF}"
}

@test "migration (logrotate-copy): detect false when logrotate COPY already present (idempotent) (#805)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
COPY --chmod=0755 .base/dist/script/docker/runtime/logrotate.sh /usr/local/lib/base/logrotate.sh
EOF
  run bash -c "$(_src); _migrate_logrotate_copy_detect '${DF}'"
  assert_failure
}

@test "migration (logrotate-copy): detect false when no logging.sh COPY present (#805)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
RUN echo hi
EOF
  run bash -c "$(_src); _migrate_logrotate_copy_detect '${DF}'"
  assert_failure
}

@test "migration (logrotate-copy): dispatcher run twice inserts the COPY exactly once (#805)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
EOF
  run bash -c "$(_src); apply_migrations '${DF}'; apply_migrations '${DF}'"
  assert_success
  local _n
  _n="$(grep -cF '/usr/local/lib/base/logrotate.sh' "${DF}")"
  [ "${_n}" -eq 1 ]
}

# ── migration (watchdog-copy): watchdog.sh runtime helper sibling ────────────
# The generic watchdog ships runtime/watchdog.sh, COPY'd next to
# logging.sh at /usr/local/lib/base/. A downstream Dockerfile that COPYs
# logging.sh but predates the watchdog lacks the watchdog.sh COPY; this
# migration inserts the sibling COPY after the logging.sh COPY.

@test "migration (watchdog-copy): inserts watchdog.sh COPY after the logging.sh COPY (#797)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
EOF
  run bash -c "$(_src); _migrate_watchdog_copy_detect '${DF}' && _migrate_watchdog_copy_apply '${DF}'"
  assert_success
  grep -Fq "COPY --chmod=0755 .base/dist/script/docker/runtime/watchdog.sh /usr/local/lib/base/watchdog.sh" "${DF}"
  # The original logging.sh COPY is preserved.
  grep -Fq "COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh" "${DF}"
}

@test "migration (watchdog-copy): detect false when watchdog COPY already present (idempotent) (#797)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
COPY --chmod=0755 .base/dist/script/docker/runtime/watchdog.sh /usr/local/lib/base/watchdog.sh
EOF
  run bash -c "$(_src); _migrate_watchdog_copy_detect '${DF}'"
  assert_failure
}

@test "migration (watchdog-copy): detect false when no logging.sh COPY present (#797)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
RUN echo hi
EOF
  run bash -c "$(_src); _migrate_watchdog_copy_detect '${DF}'"
  assert_failure
}

@test "migration (watchdog-copy): dispatcher run twice inserts the COPY exactly once (#797)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS devel
COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
EOF
  run bash -c "$(_src); apply_migrations '${DF}'; apply_migrations '${DF}'"
  assert_success
  local _n
  _n="$(grep -cF '/usr/local/lib/base/watchdog.sh' "${DF}")"
  [ "${_n}" -eq 1 ]
}

# ── migration 5: hadolint rules surfaced by the slimmed .hadolint.yaml ───────
# v0.41.0 slimmed .hadolint.yaml, no longer ignoring a batch of rules.
# Heal the mechanical violations the fanout fixed by hand:
#   DL3007  FROM bats/bats:latest / alpine:latest -> pinned tags
#   DL3046  useradd -u -> useradd -l -u
#   DL3003  RUN cd /lint && hadolint -> WORKDIR /lint + RUN hadolint
#   DL3042  pip install -r -> pip install --no-cache-dir -r
#   DL4006  alpine lint-tools stage gains SHELL ash -o pipefail
#   DL3006  parameterized FROM ${BASE_IMAGE} gains an inline ignore

@test "migration 5 (hadolint): DL3007 pins bats/alpine :latest tags (#567)" {
  cat > "${DF}" <<'EOF'
FROM bats/bats:latest AS bats-helper
FROM alpine:latest AS lint-tools
EOF
  run bash -c "$(_src); _migrate_hadolint_detect '${DF}' && _migrate_hadolint_apply '${DF}'"
  assert_success
  grep -Eq '^FROM bats/bats:[0-9]' "${DF}"
  grep -Eq '^FROM alpine:[0-9]' "${DF}"
  ! grep -Eq '^FROM (bats/bats|alpine):latest' "${DF}"
}

@test "migration 5 (hadolint): DL3046 adds useradd -l (#567)" {
  cat > "${DF}" <<'EOF'
RUN useradd -u "${UID}" -g "${GID}" "${USER}"
EOF
  run bash -c "$(_src); _migrate_hadolint_apply '${DF}'"
  assert_success
  grep -Fq 'useradd -l -u "${UID}"' "${DF}"
}

@test "migration 5 (hadolint): DL3003 cd /lint -> WORKDIR /lint + RUN (#567)" {
  cat > "${DF}" <<'EOF'
RUN cd /lint && hadolint Dockerfile
EOF
  run bash -c "$(_src); _migrate_hadolint_apply '${DF}'"
  assert_success
  grep -Fxq 'WORKDIR /lint' "${DF}"
  grep -Fxq 'RUN hadolint Dockerfile' "${DF}"
  ! grep -q 'cd /lint &&' "${DF}"
}

@test "migration 5 (hadolint): DL3042 adds pip --no-cache-dir (#567)" {
  cat > "${DF}" <<'EOF'
RUN pip install -r requirements.txt
EOF
  run bash -c "$(_src); _migrate_hadolint_apply '${DF}'"
  assert_success
  grep -Fq 'pip install --no-cache-dir -r requirements.txt' "${DF}"
}

@test "migration 5 (hadolint): DL4006 adds SHELL pipefail to alpine lint-tools (#567)" {
  cat > "${DF}" <<'EOF'
FROM alpine:3.21 AS lint-tools
RUN curl x | tar y
EOF
  run bash -c "$(_src); _migrate_hadolint_apply '${DF}'"
  assert_success
  grep -Fq 'SHELL ["/bin/ash", "-o", "pipefail", "-c"]' "${DF}"
}

@test "migration 5 (hadolint): DL3006 inline ignore before parameterized FROM (#567)" {
  cat > "${DF}" <<'EOF'
FROM ${BASE_IMAGE} AS sys
FROM ${TEST_TOOLS_IMAGE} AS devel-test
EOF
  run bash -c "$(_src); _migrate_hadolint_apply '${DF}'"
  assert_success
  [ "$(grep -c '# hadolint ignore=DL3006' "${DF}")" = "2" ]
}

@test "migration 5 (hadolint): DL3006 idempotent — does not double-insert (#567)" {
  cat > "${DF}" <<'EOF'
# hadolint ignore=DL3006
FROM ${BASE_IMAGE} AS sys
EOF
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  [ "$(grep -c '# hadolint ignore=DL3006' "${DF}")" = "1" ]
}

@test "migration 5 (hadolint): detect false on a clean Dockerfile (#567)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS sys
RUN echo hi
EOF
  run bash -c "$(_src); _migrate_hadolint_detect '${DF}'"
  assert_failure
}

# ── migration 6: noetic entrypoint SC1090 directive ─────────────────────────
# The noetic sensor entrypoints `source "/opt/ros/${ROS_DISTRO}/setup.bash"`
# with a stale `# shellcheck disable=SC1091` directive; the non-constant path
# triggers SC1090 (not SC1091), failing the v0.41.0 lint stage. Broaden the
# directive to SC1090,SC1091 on the sibling script/entrypoint.sh.

@test "migration 6 (sc1090): broadens the entrypoint directive to SC1090,SC1091 (#567)" {
  mkdir -p "${TEMP_DIR}/script"
  : > "${DF}"  # presence-only; the dispatcher needs a Dockerfile to run
  cat > "${TEMP_DIR}/script/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
# shellcheck disable=SC1091
source "/opt/ros/${ROS_DISTRO}/setup.bash"
EOF
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  grep -Fq '# shellcheck disable=SC1090,SC1091' "${TEMP_DIR}/script/entrypoint.sh"
}

@test "migration 6 (sc1090): idempotent when already SC1090,SC1091 (#567)" {
  mkdir -p "${TEMP_DIR}/script"
  : > "${DF}"
  cat > "${TEMP_DIR}/script/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
source "/opt/ros/${ROS_DISTRO}/setup.bash"
EOF
  cp "${TEMP_DIR}/script/entrypoint.sh" "${TEMP_DIR}/ep.orig"
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  diff "${TEMP_DIR}/script/entrypoint.sh" "${TEMP_DIR}/ep.orig"
}

@test "migration 6 (sc1090): detect false when no sibling entrypoint (#567)" {
  : > "${DF}"
  run bash -c "$(_src); _migrate_sc1090_detect '${DF}'"
  assert_failure
}

# ── migration 7 (facet B): ARG USER -> ARG USER="${USER_NAME}" ─────────
# v0.41.0 compose/CI pass USER_NAME (not USER) as the build arg; a Dockerfile
# still declaring a bare `ARG USER` builds the default `initial` user, which
# mismatches the compose /home/${USER_NAME}/work mount. Re-declare the arg to
# default from USER_NAME so the existing user-creation block keeps working.

@test "migration 7 (arg-user): rewrites bare 'ARG USER' to default from USER_NAME (#579)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS sys
ARG USER
RUN useradd "${USER}"
EOF
  run bash -c "$(_src); _migrate_arg_user_detect '${DF}' && _migrate_arg_user_apply '${DF}'"
  assert_success
  grep -Fxq 'ARG USER="${USER_NAME}"' "${DF}"
}

@test "migration 7 (arg-user): idempotent — already defaulted is not detected (#579)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS sys
ARG USER="${USER_NAME}"
EOF
  run bash -c "$(_src); _migrate_arg_user_detect '${DF}'"
  assert_failure
}

@test "migration 7 (arg-user): does not touch an unrelated ARG (#579)" {
  cat > "${DF}" <<'EOF'
FROM busybox AS sys
ARG USERLAND
ARG USER_NAME
EOF
  run bash -c "$(_src); _migrate_arg_user_detect '${DF}'"
  assert_failure
}

# ── migration 8 (facet B): entrypoint nounset-guard the ROS source ─────
# Under `set -u`, sourcing /opt/ros/$ROS_DISTRO/setup.bash dies on the
# unbound AMENT_TRACE_SETUP_FILES, so the container exits at start and
# `just run` fails (CI never catches it — smoke runs at build time, never
# starts the container). Bracket the source with `set +u` / `set -u` so the
# unbound vars inside setup.bash do not abort the entrypoint.

@test "migration 8 (nounset-source): brackets the ROS source with set +u/-u (#579)" {
  mkdir -p "${TEMP_DIR}/script"
  : > "${DF}"
  cat > "${TEMP_DIR}/script/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1090,SC1091
source "/opt/ros/${ROS_DISTRO}/setup.bash"
exec "$@"
EOF
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  # The source line is now wrapped: set +u immediately before, set -u after.
  run grep -n -E 'set \+u|setup\.bash|set -u' "${TEMP_DIR}/script/entrypoint.sh"
  assert_output --partial "set +u"
  # Ordering: +u line precedes the source, -u line follows it.
  local plus src minus
  plus="$(grep -n '^set +u' "${TEMP_DIR}/script/entrypoint.sh" | head -1 | cut -d: -f1)"
  src="$(grep -n 'setup.bash' "${TEMP_DIR}/script/entrypoint.sh" | head -1 | cut -d: -f1)"
  minus="$(grep -n '^set -u' "${TEMP_DIR}/script/entrypoint.sh" | tail -1 | cut -d: -f1)"
  [ "${plus}" -lt "${src}" ]
  [ "${minus}" -gt "${src}" ]
}

@test "migration 8 (nounset-source): idempotent — already-guarded source untouched (#579)" {
  mkdir -p "${TEMP_DIR}/script"
  : > "${DF}"
  cat > "${TEMP_DIR}/script/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
set +u
# shellcheck disable=SC1090,SC1091
source "/opt/ros/${ROS_DISTRO}/setup.bash"
set -u
exec "$@"
EOF
  cp "${TEMP_DIR}/script/entrypoint.sh" "${TEMP_DIR}/ep.orig"
  run bash -c "$(_src); apply_migrations '${DF}'"
  assert_success
  diff "${TEMP_DIR}/script/entrypoint.sh" "${TEMP_DIR}/ep.orig"
}

@test "migration 8 (nounset-source): detect false when no set -u in entrypoint (#579)" {
  mkdir -p "${TEMP_DIR}/script"
  : > "${DF}"
  cat > "${TEMP_DIR}/script/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
source "/opt/ros/${ROS_DISTRO}/setup.bash"
EOF
  run bash -c "$(_src); _migrate_nounset_source_detect '${DF}'"
  assert_failure
}
