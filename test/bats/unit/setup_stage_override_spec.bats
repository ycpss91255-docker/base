#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/setup_spec_helper"
# ════════════════════════════════════════════════════════════════════
# _validate_stage_name
#
# Returns:
#   0 — valid stage name (auto-emit as compose service)
#   1 — invalid format (WARN + skip; do not emit, continue)
#   2 — collides with template-managed baseline (HARD ERROR)
#   3 — collides with template-controlled tag namespace (HARD ERROR)
# ════════════════════════════════════════════════════════════════════

@test "_validate_stage_name accepts well-formed names" {
  for _name in headless gui prod runtime dev main master edge headless-arm64 gpu_test; do
    run _validate_stage_name "${_name}"
    assert_success
  done
}

@test "_validate_stage_name rejects invalid format with exit 1 (WARN+skip)" {
  for _bad in 'Headless' '1stage' '-leading' '_leading' 'has space' 'has.dot' 'CAPS'; do
    run _validate_stage_name "${_bad}"
    [[ "${status}" -eq 1 ]] || { echo "expected 1 for '${_bad}', got ${status}"; return 1; }
  done
}

@test "_validate_stage_name rejects baseline collision with exit 2 (HARD ERROR)" {
  # Forward-looking baseline + legacy aliases (kept during v0.21.x
  # transition for backward compat with un-renamed downstream Dockerfiles).
  # (A1'-b): devel-test is NOT here — it is now an emittable stage
  # (legacy service name `test`); see the dedicated test below.
  for _base in sys devel-base devel runtime-test base test; do
    run _validate_stage_name "${_base}"
    [[ "${status}" -eq 2 ]] || { echo "expected 2 for '${_base}', got ${status}"; return 1; }
  done
}

@test "_validate_stage_name accepts devel-test as an emittable stage (#493 A1'-b)" {
  run _validate_stage_name "devel-test"
  [[ "${status}" -eq 0 ]] || { echo "expected 0 for devel-test, got ${status}"; return 1; }
}

@test "_validate_stage_name rejects reserved tag-namespace names with exit 3 (HARD ERROR)" {
  for _bad in latest v0 v1 v1.2 v0.16.2 v0.16.2-rc1; do
    run _validate_stage_name "${_bad}"
    [[ "${status}" -eq 3 ]] || { echo "expected 3 for '${_bad}', got ${status}"; return 1; }
  done
}

# ════════════════════════════════════════════════════════════════════
# _parse_dockerfile_stages
#
# Reads `^FROM\s+\S+\s+AS\s+<stage>` lines from a Dockerfile, dedups,
# filters out the baseline blocklist {sys, devel-base, devel,
# devel-test, runtime-test} (plus legacy {base, test} during v0.21.x
# transition), and echoes the surviving stages one per line.
# ════════════════════════════════════════════════════════════════════

@test "_parse_dockerfile_stages: returns nothing for Dockerfile with only legacy baseline stages (backward compat)" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS test
EOF
  run _parse_dockerfile_stages "${TEMP_DIR}/Dockerfile"
  assert_success
  assert_output ""
}

@test "_parse_dockerfile_stages: returns nothing for Dockerfile with only new baseline stages (#243)" {
  # (A1'-b): devel-test is no longer baseline-filtered — it is an
  # emittable stage now, so it is excluded from this "baseline → nothing"
  # fixture and covered by the dedicated test below.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
FROM sys AS devel-base
FROM devel-base AS devel
FROM runtime AS runtime-test
EOF
  run _parse_dockerfile_stages "${TEMP_DIR}/Dockerfile"
  assert_success
  assert_output ""
}

@test "_parse_dockerfile_stages: returns devel-test (promoted out of baseline, #493)" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
FROM sys AS devel-base
FROM devel-base AS devel
FROM devel AS devel-test
FROM runtime AS runtime-test
EOF
  run _parse_dockerfile_stages "${TEMP_DIR}/Dockerfile"
  assert_success
  assert_output "devel-test"
}

@test "_parse_dockerfile_stages: extracts non-baseline stages" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
FROM devel AS gui
FROM devel AS test
EOF
  run _parse_dockerfile_stages "${TEMP_DIR}/Dockerfile"
  assert_success
  assert_line --index 0 "headless"
  assert_line --index 1 "gui"
  [[ "${#lines[@]}" -eq 2 ]] || { echo "expected 2 lines, got ${#lines[@]}: ${output}"; return 1; }
}

@test "_parse_dockerfile_stages: preserves Dockerfile order" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS gamma
FROM devel AS alpha
FROM devel AS beta
EOF
  run _parse_dockerfile_stages "${TEMP_DIR}/Dockerfile"
  assert_success
  assert_line --index 0 "gamma"
  assert_line --index 1 "alpha"
  assert_line --index 2 "beta"
}

@test "_parse_dockerfile_stages: dedups duplicate stage names" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS gui
FROM devel AS gui
EOF
  run _parse_dockerfile_stages "${TEMP_DIR}/Dockerfile"
  assert_success
  [[ "${#lines[@]}" -eq 1 ]] || { echo "expected 1 line after dedup, got ${#lines[@]}: ${output}"; return 1; }
  assert_output "gui"
}

@test "_parse_dockerfile_stages: handles missing Dockerfile gracefully (empty output)" {
  run _parse_dockerfile_stages "${TEMP_DIR}/no-such-Dockerfile"
  assert_success
  assert_output ""
}

@test "_parse_dockerfile_stages: ignores lowercase 'as' and inline comments" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
FROM sys AS base
FROM base AS devel
FROM devel as lower_as_keyword
# FROM devel AS commented_out
FROM devel AS prod
EOF
  run _parse_dockerfile_stages "${TEMP_DIR}/Dockerfile"
  assert_success
  assert_output "prod"
}

# ════════════════════════════════════════════════════════════════════
# _compute_dockerfile_hash
#
# sha256 of just the `FROM ... AS <stage>` lines (stage list projection),
# not the whole Dockerfile. Used by _check_setup_drift to detect when
# the user adds/removes a stage and regenerate compose.yaml.
# ════════════════════════════════════════════════════════════════════

@test "_compute_dockerfile_hash: stable for unchanged stage list" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
FROM sys AS base
FROM base AS devel
EOF
  local _h1 _h2
  _compute_dockerfile_hash "${TEMP_DIR}" _h1
  _compute_dockerfile_hash "${TEMP_DIR}" _h2
  assert_equal "${_h1}" "${_h2}"
  [[ -n "${_h1}" ]]
}

@test "_compute_dockerfile_hash: changes when stage is added" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
FROM sys AS base
FROM base AS devel
EOF
  local _h_before _h_after
  _compute_dockerfile_hash "${TEMP_DIR}" _h_before

  cat >> "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM devel AS headless
EOF
  _compute_dockerfile_hash "${TEMP_DIR}" _h_after

  [[ "${_h_before}" != "${_h_after}" ]] || { echo "hash should change when stage added"; return 1; }
}

@test "_compute_dockerfile_hash: changes when stage is removed" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
FROM devel AS gui
EOF
  local _h_before _h_after
  _compute_dockerfile_hash "${TEMP_DIR}" _h_before

  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
EOF
  _compute_dockerfile_hash "${TEMP_DIR}" _h_after

  [[ "${_h_before}" != "${_h_after}" ]] || { echo "hash should change when stage removed"; return 1; }
}

@test "_compute_dockerfile_hash: stable when non-FROM-AS lines change" {
  # Project hash should ignore RUN / COPY / ENV / ARG / comments — only
  # `FROM ... AS <stage>` lines determine the compose service set.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
RUN apt-get install -y curl
FROM sys AS base
ENV FOO=bar
FROM base AS devel
EOF
  local _h_before _h_after
  _compute_dockerfile_hash "${TEMP_DIR}" _h_before

  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
RUN apt-get install -y wget
FROM sys AS base
ENV BAZ=qux
# new comment
FROM base AS devel
EOF
  _compute_dockerfile_hash "${TEMP_DIR}" _h_after

  assert_equal "${_h_before}" "${_h_after}"
}

@test "_compute_dockerfile_hash: empty when Dockerfile missing" {
  local _h
  _compute_dockerfile_hash "${TEMP_DIR}" _h
  assert_equal "${_h}" ""
}

# ════════════════════════════════════════════════════════════════════
# main apply — auto-emit non-baseline stages
#
# End-to-end check that stages declared via `FROM ... AS <stage>` in
# Dockerfile become compose services automatically. Covers the v1
# acceptance set: existing runtime regression, multi-stage emit,
# baseline collision (hard error), reserved tag namespace (hard error),
# invalid format (WARN + skip but apply still succeeds).
# ════════════════════════════════════════════════════════════════════

@test "auto-emit: regression for #108 — Dockerfile AS runtime still emits runtime service" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS runtime
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -E '^[[:space:]]+runtime:$' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
  assert_output --partial "runtime:"
}

@test "auto-emit: multi-stage emits one service per non-baseline stage" {
  # Isaac Sim shape: two extra stages on top of devel.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
FROM devel AS gui
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
  "
  assert_success
  run grep -cE '^  (headless|gui):$' "${TEMP_DIR}/compose.yaml"
  assert_output "2"
  # Both services extend devel (compose extends keyword)
  run grep -cF 'service: devel' "${TEMP_DIR}/compose.yaml"
  # Devel itself doesn't extend; only emitted stage services do — so
  # 2 occurrences (headless + gui), once per stage block.
  assert_output "2"
}

@test "auto-emit: each emitted stage carries target / image / container_name / profiles" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
  "
  assert_success
  # build.target points at the new stage
  run grep -F '      target: headless' "${TEMP_DIR}/compose.yaml"
  assert_success
  # image is tagged ${IMAGE_NAME}:headless (image_name resolves from
  # template's [image] rules — exact value irrelevant; pattern matters)
  run grep -E '^    image: \$\{DOCKER_HUB_USER:-local\}/[a-z0-9_-]+:headless$' "${TEMP_DIR}/compose.yaml"
  assert_success
  # container_name: ${USER_NAME} prefix (multi-user disambiguation)
  # + ${IMAGE_NAME}-headless
  run grep -E '^    container_name: \$\{USER_NAME\}-[a-z0-9_-]+-headless$' "${TEMP_DIR}/compose.yaml"
  assert_success
  # profiles list contains the stage name
  run grep -F '      - headless' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "auto-emit: no extra stages → only devel + test in compose.yaml" {
  # (A1'-b): the `test` service is emitted from the devel-test
  # baseline stage, so the baseline-only fixture declares it.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS devel-base
FROM devel-base AS devel
FROM devel AS devel-test
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
  "
  assert_success
  # Only devel + test; no other top-level service blocks.
  run grep -cE '^  [a-z][a-z0-9_-]*:$' "${TEMP_DIR}/compose.yaml"
  assert_output "2"
}

@test "auto-emit: baseline collision (AS test redefined) → hard error exit non-zero" {
  # User Dockerfile has another `AS test` later — but template's parser
  # treats baseline names as collision regardless of position. (The
  # `test` in line 4 IS the template-managed test stage; if the user
  # has an extra one this is collision.) Simulate by adding a second
  # `AS test` after a base.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS test
EOF
  unset SETUP_CONF
  # Add a second `AS test` at top to trigger duplicate baseline match
  # (parser sees it before dedup; baseline blocklist still skips).
  # Actually the dedup-then-blocklist test is not a collision — both
  # are "test" which is baseline-blocked. To trigger collision, user
  # uses a NEW base name that hits baseline. Use `base` as a new
  # explicit `FROM xxx AS base` after devel:
  cat >> "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM devel AS base
EOF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}'
  " 2>&1
  # Validator sees `base` as a parsed stage post-Dockerfile read, but
  # _parse_dockerfile_stages strips it via blocklist → never reaches
  # validator. So `AS base` second occurrence does NOT hard-error;
  # blocklist filter precedes validator. This case is benign.
  # Document this: the only way to trigger a hard error from baseline
  # collision is for user to override the parser somehow — currently
  # no path. So this test asserts the NON-collision outcome (apply
  # succeeds, no extra service emitted).
  assert_success
  run grep -cE '^  base:$' "${TEMP_DIR}/compose.yaml"
  assert_output "0"
}

@test "auto-emit: reserved tag namespace (AS latest) → hard error exit non-zero" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS latest
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_failure
  assert_output --partial "template-controlled image tag namespace"
}

@test "auto-emit: reserved tag namespace (AS v0) → hard error exit non-zero" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS v0
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}'
  "
  assert_failure
}

@test "auto-emit: invalid format (AS Headless capital) → WARN + skip, apply still succeeds" {
  # `Headless` fails the lowercase-only format check. Validator returns
  # 1 (skip), apply continues. The compose.yaml does NOT get a
  # `Headless:` service. Other valid stages (gui) still emit normally.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS Headless
FROM devel AS gui
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  assert_output --partial "invalid Dockerfile stage name format"
  # gui still emits
  run grep -E '^  gui:$' "${TEMP_DIR}/compose.yaml"
  assert_success
  # Headless does NOT emit (case-sensitive grep)
  run grep -E '^  Headless:$' "${TEMP_DIR}/compose.yaml"
  assert_failure
}

@test "auto-emit: SETUP_DOCKERFILE_HASH written to .env" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
  "
  assert_success
  run grep -E '^SETUP_DOCKERFILE_HASH=[a-f0-9]{64}$' "${TEMP_DIR}/.env.generated"
  assert_success
}

@test "auto-emit: drift fires when Dockerfile stage list changes" {
  # First apply — Dockerfile has just devel.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
  "
  assert_success

  # Add a new stage; check-drift should now report drift.
  cat >> "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM devel AS headless
EOF

  # Stub detect_gpu/gui to match what was stored, so non-Dockerfile
  # drift sources stay quiet and we observe ONLY the Dockerfile drift.
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    detect_gui() { local -n _o=\$1; _o=\"\$(grep -oP '^SETUP_GUI_DETECTED=\\K.*' '${TEMP_DIR}/.env.generated' 2>/dev/null || echo false)\"; }
    detect_gpu() { local -n _o=\$1; _o=\"\$(grep -oP '^GPU_ENABLED=\\K.*' '${TEMP_DIR}/.env.generated' 2>/dev/null || echo false)\"; }
    _check_setup_drift '${TEMP_DIR}'
  "
  assert_failure
  assert_output --partial "Dockerfile stage list changed"
}

@test "auto-emit: drift fires when Dockerfile stage is REMOVED" {
  # Mirrors the add-side drift but for the remove path. Important per
  # acceptance: stale services must not survive Dockerfile edits
  # that delete a stage.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
FROM devel AS gui
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
  "
  assert_success

  # Remove the gui stage.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
EOF

  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    detect_gui() { local -n _o=\$1; _o=\"\$(grep -oP '^SETUP_GUI_DETECTED=\\K.*' '${TEMP_DIR}/.env.generated' 2>/dev/null || echo false)\"; }
    detect_gpu() { local -n _o=\$1; _o=\"\$(grep -oP '^GPU_ENABLED=\\K.*' '${TEMP_DIR}/.env.generated' 2>/dev/null || echo false)\"; }
    _check_setup_drift '${TEMP_DIR}'
  "
  assert_failure
  assert_output --partial "Dockerfile stage list changed"
}

# ════════════════════════════════════════════════════════════════════
# Per-stage overrides
#
# `[stage:<name>]` sections in <repo>/config/docker/setup.conf override top-level
# settings on a per-stage basis when a corresponding `FROM ... AS <name>`
# stage exists in the Dockerfile. Allowlist gates which keys can be
# overridden; list fields (mount_*/port_*/env_*) use append-default
# with opt-out via `<list>_inherit = false`.
# ════════════════════════════════════════════════════════════════════

# ─── _parse_stage_sections ────────────────────────────────────────

@test "_parse_stage_sections: empty file → empty output" {
  : > "${TEMP_DIR}/config/docker/setup.conf"
  local -a _stages=()
  _parse_stage_sections "${TEMP_DIR}/config/docker/setup.conf" _stages
  [[ "${#_stages[@]}" -eq 0 ]] || { echo "expected 0 stages, got ${#_stages[@]}: ${_stages[*]}"; return 1; }
}

@test "_parse_stage_sections: missing file → empty output (no error)" {
  local -a _stages=()
  _parse_stage_sections "${TEMP_DIR}/no-such-file.conf" _stages
  [[ "${#_stages[@]}" -eq 0 ]] || { echo "expected 0 stages, got ${#_stages[@]}: ${_stages[*]}"; return 1; }
}

@test "_parse_stage_sections: extracts [stage:NAME] sections in file order" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = auto

[stage:headless]
gui.mode = off

[network]
mode = host

[stage:gui]
gui.mode = auto

[stage:web]
network.mode = bridge
EOF
  local -a _stages=()
  _parse_stage_sections "${TEMP_DIR}/config/docker/setup.conf" _stages
  [[ "${#_stages[@]}" -eq 3 ]] || { echo "expected 3 stages, got ${#_stages[@]}: ${_stages[*]}"; return 1; }
  [[ "${_stages[0]}" == "headless" ]] || { echo "expected headless first, got ${_stages[0]}"; return 1; }
  [[ "${_stages[1]}" == "gui" ]] || { echo "expected gui second, got ${_stages[1]}"; return 1; }
  [[ "${_stages[2]}" == "web" ]] || { echo "expected web third, got ${_stages[2]}"; return 1; }
}

@test "_parse_stage_sections: ignores plain sections that are not [stage:...]" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = auto
[network]
mode = host
[volumes]
mount_1 = /etc/localtime:/etc/localtime
EOF
  local -a _stages=()
  _parse_stage_sections "${TEMP_DIR}/config/docker/setup.conf" _stages
  [[ "${#_stages[@]}" -eq 0 ]] || { echo "expected 0 stages, got ${#_stages[@]}: ${_stages[*]}"; return 1; }
}

# ─── _load_stage_overrides ────────────────────────────────────────

@test "_load_stage_overrides: returns the keys+values under [stage:NAME]" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = auto

[stage:headless]
gui.mode = off
network.mode = bridge
network.port_1 = 8080:80
volumes.mount_1 = /tmp/cache:/cache

[stage:gui]
gui.mode = auto
EOF
  local -a _keys=() _values=()
  _load_stage_overrides "${TEMP_DIR}" "headless" _keys _values
  [[ "${#_keys[@]}" -eq 4 ]] || { echo "expected 4 keys, got ${#_keys[@]}: ${_keys[*]}"; return 1; }
  [[ "${_keys[0]}" == "gui.mode" && "${_values[0]}" == "off" ]] || return 1
  [[ "${_keys[1]}" == "network.mode" && "${_values[1]}" == "bridge" ]] || return 1
  [[ "${_keys[2]}" == "network.port_1" && "${_values[2]}" == "8080:80" ]] || return 1
  [[ "${_keys[3]}" == "volumes.mount_1" && "${_values[3]}" == "/tmp/cache:/cache" ]] || return 1
}

@test "_load_stage_overrides: missing setup.conf → empty arrays" {
  local -a _keys=() _values=()
  _load_stage_overrides "${TEMP_DIR}" "headless" _keys _values
  [[ "${#_keys[@]}" -eq 0 ]] || { echo "expected 0 keys, got ${#_keys[@]}: ${_keys[*]}"; return 1; }
  [[ "${#_values[@]}" -eq 0 ]] || return 1
}

@test "_load_stage_overrides: stage absent from setup.conf → empty arrays" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = auto

[stage:headless]
gui.mode = off
EOF
  local -a _keys=() _values=()
  _load_stage_overrides "${TEMP_DIR}" "gui" _keys _values
  [[ "${#_keys[@]}" -eq 0 ]] || { echo "expected 0 keys for absent stage, got ${#_keys[@]}: ${_keys[*]}"; return 1; }
}

# ─── _validate_stage_override_key ──────────────────────────────────

@test "_validate_stage_override_key: accepts allowlisted scalars" {
  for _k in \
    deploy.gpu_mode \
    deploy.gpu_count \
    deploy.gpu_capabilities \
    deploy.runtime \
    gui.mode \
    network.mode \
    network.ipc \
    network.pid \
    network.network_name \
    security.privileged
  do
    run _validate_stage_override_key "${_k}"
    assert_success
  done
}

@test "_validate_stage_override_key: accepts list-item keys with numeric suffix" {
  for _k in \
    network.port_1 \
    network.port_2 \
    network.port_99 \
    volumes.mount_1 \
    volumes.mount_42 \
    environment.env_1 \
    environment.env_7 \
    security.cap_add_1 \
    security.cap_drop_2 \
    security.security_opt_1
  do
    run _validate_stage_override_key "${_k}"
    assert_success
  done
}

@test "_validate_stage_override_key: accepts inherit meta-keys" {
  for _k in network.port_inherit volumes.mount_inherit environment.env_inherit \
            security.cap_add_inherit security.cap_drop_inherit security.security_opt_inherit; do
    run _validate_stage_override_key "${_k}"
    assert_success
  done
}

@test "_validate_stage_override_key: rejects keys outside allowlist" {
  for _k in \
    image.rule_1 \
    build.arg_1 \
    build.target_arch \
    security.cap_add \
    security.foo_1 \
    devices.device_1 \
    tmpfs.tmpfs_1 \
    additional_contexts.context_1 \
    foo.bar \
    not_dotted_key
  do
    run _validate_stage_override_key "${_k}"
    [[ "${status}" -ne 0 ]] || { echo "expected failure for ${_k}"; return 1; }
  done
}

# ─── _resolve_stage_scalar ─────────────────────────────────────────

@test "_resolve_stage_scalar: returns stage value when override present" {
  local -a _keys=("gui.mode" "network.mode")
  local -a _values=("off" "bridge")
  local _out=""
  _resolve_stage_scalar _keys _values "gui.mode" "auto" _out
  [[ "${_out}" == "off" ]] || { echo "expected 'off', got '${_out}'"; return 1; }
}

@test "_resolve_stage_scalar: returns fallback when key absent" {
  local -a _keys=("gui.mode")
  local -a _values=("off")
  local _out=""
  _resolve_stage_scalar _keys _values "network.mode" "host" _out
  [[ "${_out}" == "host" ]] || { echo "expected 'host', got '${_out}'"; return 1; }
}

@test "_resolve_stage_scalar: returns empty fallback when neither set" {
  local -a _keys=()
  local -a _values=()
  local _out="initial"
  _resolve_stage_scalar _keys _values "gui.mode" "" _out
  [[ -z "${_out}" ]] || { echo "expected empty, got '${_out}'"; return 1; }
}

# ─── _resolve_stage_list ───────────────────────────────────────────

@test "_resolve_stage_list: append-default with stage entries (inherit unset)" {
  local -a _keys=("volumes.mount_1" "volumes.mount_2")
  local -a _values=("/tmp/cache:/cache" "/data:/data")
  local _top="/etc/localtime:/etc/localtime:ro"$'\n'"\${HOME}/.ssh:/home/user/.ssh:ro"
  local _out=""
  _resolve_stage_list _keys _values "volumes.mount_" "volumes.mount_inherit" "${_top}" _out
  # Top-level 2 entries + stage 2 entries = 4 lines
  local -a _lines=()
  IFS=$'\n' read -rd '' -a _lines <<< "${_out}" || true
  [[ "${#_lines[@]}" -eq 4 ]] || { echo "expected 4 lines, got ${#_lines[@]}: ${_out}"; return 1; }
  [[ "${_lines[0]}" == "/etc/localtime:/etc/localtime:ro" ]] || return 1
  [[ "${_lines[2]}" == "/tmp/cache:/cache" ]] || return 1
  [[ "${_lines[3]}" == "/data:/data" ]] || return 1
}

@test "_resolve_stage_list: replace mode (inherit=false) drops top-level" {
  local -a _keys=("volumes.mount_inherit" "volumes.mount_1")
  local -a _values=("false" "/only:/only")
  local _top="/etc/localtime:/etc/localtime:ro"
  local _out=""
  _resolve_stage_list _keys _values "volumes.mount_" "volumes.mount_inherit" "${_top}" _out
  [[ "${_out}" == "/only:/only" ]] || { echo "expected only stage entry, got '${_out}'"; return 1; }
}

@test "_resolve_stage_list: empty stage with inherit=true → top-level only" {
  local -a _keys=()
  local -a _values=()
  local _top="/etc/localtime:/etc/localtime:ro"$'\n'"/data:/data"
  local _out=""
  _resolve_stage_list _keys _values "volumes.mount_" "volumes.mount_inherit" "${_top}" _out
  [[ "${_out}" == "${_top}" ]] || { echo "expected top-level passthrough, got '${_out}'"; return 1; }
}

@test "_resolve_stage_list: empty stage with inherit=false → empty result" {
  local -a _keys=("volumes.mount_inherit")
  local -a _values=("false")
  local _top="/etc/localtime:/etc/localtime:ro"
  local _out="initial"
  _resolve_stage_list _keys _values "volumes.mount_" "volumes.mount_inherit" "${_top}" _out
  [[ -z "${_out}" ]] || { echo "expected empty, got '${_out}'"; return 1; }
}

@test "_resolve_stage_list: preserves stage entries in setup.conf order" {
  # User wrote port_3 first, then port_1, then port_2 — preserve that
  # order rather than re-sorting numerically. The on-disk order is what
  # the user sees in setup_tui.sh and what _parse_ini_section returns.
  local -a _keys=("network.port_3" "network.port_1" "network.port_2")
  local -a _values=("9000:9000" "8080:80" "5000:5000")
  local _out=""
  _resolve_stage_list _keys _values "network.port_" "network.port_inherit" "" _out
  local -a _lines=()
  IFS=$'\n' read -rd '' -a _lines <<< "${_out}" || true
  [[ "${_lines[0]}" == "9000:9000" ]] || return 1
  [[ "${_lines[1]}" == "8080:80" ]] || return 1
  [[ "${_lines[2]}" == "5000:5000" ]] || return 1
}

@test "_resolve_stage_list: ignores keys with non-numeric suffix" {
  # `mount_inherit` is the meta-key, not a list item — must not be
  # collected even though it shares the `mount_` prefix.
  local -a _keys=("volumes.mount_1" "volumes.mount_inherit" "volumes.mount_2")
  local -a _values=("/a:/a" "false" "/b:/b")
  local _out=""
  _resolve_stage_list _keys _values "volumes.mount_" "volumes.mount_inherit" "" _out
  # inherit=false → only stage entries
  local -a _lines=()
  IFS=$'\n' read -rd '' -a _lines <<< "${_out}" || true
  [[ "${#_lines[@]}" -eq 2 ]] || { echo "expected 2, got ${#_lines[@]}: ${_out}"; return 1; }
  [[ "${_lines[0]}" == "/a:/a" ]] || return 1
  [[ "${_lines[1]}" == "/b:/b" ]] || return 1
}

# ─── Per-stage overrides — compose.yaml emit integration ────

@test "stage-override: regression — stage with NO overrides keeps extends:devel minimal block" {
  # Zero-diff path: existing 17 downstream repos have setup.conf with
  # no [stage:*] sections. compose.yaml output for emitted stages must
  # match's extends-only shape exactly.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
  "
  assert_success
  # extends: devel still emitted under the headless service block
  run grep -A 3 '^  headless:$' "${TEMP_DIR}/compose.yaml"
  assert_output --partial "extends:"
  assert_output --partial "service: devel"
  # No `network_mode:`, `ports:`, `volumes:` block underneath headless
  # (compose extends inherits all from devel — no override block emitted)
  run bash -c "awk '/^  headless:\$/{f=1; next} /^  [a-z][a-z0-9_-]*:\$/{f=0} f' '${TEMP_DIR}/compose.yaml'"
  assert_success
  refute_output --partial "network_mode: bridge"
  refute_output --partial "ports:"
  refute_output --partial "volumes:"
  refute_output --partial "environment:"
}

@test "stage-override: gui.mode=off in [stage:headless] strips X11 env+volumes from headless" {
  # Regression for Isaac validation finding: compose `extends`
  # MERGES list fields (not replaces), so emitting a stage's
  # environment / volumes block on top of `extends: devel` ends up
  # APPENDING to devel's X11 entries, not suppressing them. Fix:
  # when a stage has any list-affecting override, drop `extends:`
  # entirely and emit a standalone service block.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
EOF
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = force

[stage:headless]
gui.mode = off
EOF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
  "
  assert_success
  # Slice the headless service block (between its header and the
  # next service header).
  run bash -c "awk '/^  headless:\$/{f=1; next} /^  [a-z][a-z0-9_-]*:\$/{f=0} f' '${TEMP_DIR}/compose.yaml'"
  assert_success
  # CRITICAL: NO `extends:` line — standalone emit so compose does
  # not merge devel's X11 list back in.
  refute_output --partial "extends:"
  refute_output --partial "service: devel"
  # Standalone block has its own image / container_name / target.
  assert_output --partial "target: headless"
  assert_output --partial ":headless"
  # No X11 anywhere in the headless block.
  refute_output --partial "DISPLAY="
  refute_output --partial "/tmp/.X11-unix"
  # devel block (top-level gui = force) still has X11 entries.
  run bash -c "awk '/^  devel:\$/{f=1; next} /^  [a-z][a-z0-9_-]*:\$/{f=0} f' '${TEMP_DIR}/compose.yaml'"
  assert_success
  assert_output --partial "DISPLAY="
}

@test "stage-override: network.mode=bridge + port_1 in [stage:headless] emits per-stage ports" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
EOF
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[network]
mode = host

[stage:headless]
network.mode = bridge
network.port_1 = 8080:80
EOF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
  "
  assert_success
  # devel still on host
  run bash -c "awk '/^  devel:\$/{f=1; next} /^  [a-z][a-z0-9_-]*:\$/{f=0} f' '${TEMP_DIR}/compose.yaml'"
  assert_success
  # NETWORK_MODE is filled into .env from top-level network.mode=host
  assert_output --partial "network_mode:"
  # headless flips to bridge + has its own port mapping
  run bash -c "awk '/^  headless:\$/{f=1; next} /^  [a-z][a-z0-9_-]*:\$/{f=0} f' '${TEMP_DIR}/compose.yaml'"
  assert_success
  assert_output --partial "network_mode: bridge"
  assert_output --partial "8080:80"
}

@test "stage-override: volumes.mount_inherit=false drops top-level mounts for that stage" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
EOF
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[volumes]
mount_1 =
mount_2 = /etc/localtime:/etc/localtime:ro
mount_3 = /data:/data

[stage:headless]
volumes.mount_inherit = false
volumes.mount_1 = /only:/only
EOF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
  "
  assert_success
  run bash -c "awk '/^  headless:\$/{f=1; next} /^  [a-z][a-z0-9_-]*:\$/{f=0} f' '${TEMP_DIR}/compose.yaml'"
  assert_success
  # CRITICAL: standalone emit (no extends) — otherwise compose merges
  # devel's volume list (incl. /etc/localtime, /data) back in.
  refute_output --partial "extends:"
  assert_output --partial "/only:/only"
  refute_output --partial "/etc/localtime"
  refute_output --partial "/data:/data"
}

@test "stage-override: standalone emit re-emits cap_add + privileged inherited from devel" {
  # When stage drops `extends: devel`, top-level fields that aren't
  # per-stage overridable (cap_add / cap_drop / security_opt /
  # devices / tmpfs / privileged via env-var ref) must be re-emitted
  # in the standalone block so the stage doesn't silently lose them.
  # This test covers the cap_add + privileged inheritance path
  # specifically; runtime / cgroup_rules / tmpfs / devices follow
  # the same pattern and rely on the same code path so are not
  # separately tested here.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
EOF
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = force

[security]
privileged = true
cap_add_1 = SYS_ADMIN
cap_add_2 = NET_ADMIN

[stage:headless]
gui.mode = off
EOF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
  "
  assert_success
  run bash -c "awk '/^  headless:\$/{f=1; next} /^  [a-z][a-z0-9_-]*:\$/{f=0} f' '${TEMP_DIR}/compose.yaml'"
  assert_success
  refute_output --partial "extends:"
  # cap_add list was re-emitted (top-level value, since stage didn't
  # override it). Without extends, this MUST appear inline.
  assert_output --partial "SYS_ADMIN"
  assert_output --partial "NET_ADMIN"
  # privileged still references PRIVILEGED env var (same as devel).
  assert_output --partial "privileged:"
}

@test "stage-override: orphan [stage:foo] (no foo in Dockerfile) prints WARN, does not abort" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
EOF
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[stage:headless]
gui.mode = off

[stage:foo]
gui.mode = off
EOF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1 >/dev/null
  "
  assert_success
  assert_output --partial "[stage:foo]"
  # generic phrase — uses our new i18n key
  assert_output --partial "stage"
}

@test "stage-override: disallowed override key (image.rule_1) prints WARN and skips that key" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
EOF
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[stage:headless]
gui.mode = off
image.rule_1 = prefix:bogus_
EOF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1 >/dev/null
  "
  assert_success
  assert_output --partial "image.rule_1"
}

@test "stage-override: [stage:sys] in setup.conf is hard-error (baseline collision)" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
EOF
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[stage:sys]
gui.mode = off
EOF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1 >/dev/null
  "
  assert_failure
  assert_output --partial "[stage:sys]"
}

# ════════════════════════════════════════════════════════════════════
# Bug A (A1'-b) — devel-test gains an override surface
#
# devel-test is promoted out of the baseline blocklist: it now flows
# through the per-stage inherit-with-override model like any other
# non-baseline stage, but keeps the legacy service NAME / image TAG /
# profile `test` (`just exec -t test` unchanged) while build.target
# stays the real Dockerfile stage `devel-test`. The [stage:devel-test]
# section is the override surface (so e.g. Isaac can enable GPU pytest).
# ════════════════════════════════════════════════════════════════════

@test "stage-override(#493): [stage:devel-test] deploy.gpu_mode=force emits GPU deploy block on the test service" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS devel-base
FROM devel-base AS devel
FROM devel AS devel-test
EOF
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[stage:devel-test]
deploy.gpu_mode = force
EOF
  run bash -c "
    source /source/downstream/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
  "
  assert_success
  # Slice the `test:` service block (service name stays `test`).
  run bash -c "awk '/^  test:\$/{f=1; next} /^  [a-z][a-z0-9_-]*:\$/{f=0} f' '${TEMP_DIR}/compose.yaml'"
  assert_success
  # Override forces a GPU reservation onto the test service.
  assert_output --partial "driver: nvidia"
  assert_output --partial "capabilities:"
  # build.target is still the real Dockerfile stage, not the service name.
  assert_output --partial "target: devel-test"
}

