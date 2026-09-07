#!/usr/bin/env bats
#
# toml_config_template_spec.bats -- TOML template structural tests
# (ADR-37 service boundary split).
#
# Verifies:
#   - setup.toml template exists with all 15 INI-equivalent sections
#   - .env.toml template exists with its [environment] section
#   - The two files have no overlapping [environment] keys (boundary)
#
# Pure file reads, no mocks: Unit level (ADR-00000018).

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  ROOT=/source
  SETUP_TOML="${ROOT}/dist/setup.toml"
  ENV_TOML="${ROOT}/dist/.env.toml"
}

# ════════════════════════════════════════════════════════════════════
# Seam 1: setup.toml template existence and section coverage
# ════════════════════════════════════════════════════════════════════

# why: ADR-37 mandates a TOML template alongside the INI template
@test "setup.toml: template exists" {
  assert_spec_subject "${SETUP_TOML}" \
    "the setup.toml template (ADR-37 TOML config unification)"
}

# why: the 15 INI sections must all be represented in the TOML template;
#      scalar sections use [table] headers

# why: [project] owns the compose project name
@test "setup.toml: has [project] table" {
  run grep '^\[project\]' "${SETUP_TOML}"
  assert_success
}

# why: [image] detection rules are list-shaped -> [[image.rules]]
@test "setup.toml: has image section via [[image.rules]]" {
  run grep '^\[\[image\.rules\]\]' "${SETUP_TOML}"
  assert_success
}

# why: [build] owns build args + arch + network
@test "setup.toml: has [build] table" {
  run grep '^\[build\]' "${SETUP_TOML}"
  assert_success
}

# why: build args are list-shaped -> [[build.args]]
@test "setup.toml: has build args via [[build.args]]" {
  run grep '^\[\[build\.args\]\]' "${SETUP_TOML}"
  assert_success
}

# why: [deploy] owns GPU reservation
@test "setup.toml: has [deploy] table" {
  run grep '^\[deploy\]' "${SETUP_TOML}"
  assert_success
}

# why: [lifecycle] owns restart policy, init, watchdog
@test "setup.toml: has [lifecycle] table" {
  run grep '^\[lifecycle\]' "${SETUP_TOML}"
  assert_success
}

# why: [gui] owns display mode
@test "setup.toml: has [gui] table" {
  run grep '^\[gui\]' "${SETUP_TOML}"
  assert_success
}

# why: [network] owns network mode, IPC, PID, port mappings
@test "setup.toml: has [network] table" {
  run grep '^\[network\]' "${SETUP_TOML}"
  assert_success
}

# why: [security] owns privilege, capabilities, security_opt
@test "setup.toml: has [security] table" {
  run grep '^\[security\]' "${SETUP_TOML}"
  assert_success
}

# why: [resources] owns container resource limits (shm_size)
@test "setup.toml: has [resources] table" {
  run grep '^\[resources\]' "${SETUP_TOML}"
  assert_success
}

# why: [environment] for INFRASTRUCTURE env (DISPLAY, NVIDIA_*);
#      service runtime env belongs in .env.toml, not here
@test "setup.toml: has [environment] table for infrastructure env" {
  run grep '^\[environment\]' "${SETUP_TOML}"
  assert_success
}

# why: [logging] owns Docker logging driver + rotation + transcripts
@test "setup.toml: has [logging] table" {
  run grep '^\[logging\]' "${SETUP_TOML}"
  assert_success
}

# why: tmpfs, devices, volumes, additional_contexts are list-shaped
#      sections that may ship empty; verify they are at least documented
#      (as comments or active [[array of tables]])

@test "setup.toml: documents tmpfs section" {
  run grep -i 'tmpfs' "${SETUP_TOML}"
  assert_success
}

@test "setup.toml: documents devices section" {
  run grep -i 'devices' "${SETUP_TOML}"
  assert_success
}

@test "setup.toml: documents volumes section" {
  run grep -i 'volumes' "${SETUP_TOML}"
  assert_success
}

@test "setup.toml: documents additional_contexts section" {
  run grep -i 'additional_contexts' "${SETUP_TOML}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Seam 2: .env.toml template existence and structure
# ════════════════════════════════════════════════════════════════════

# why: ADR-37 splits service runtime env into .env.toml
@test ".env.toml: template exists" {
  assert_spec_subject "${ENV_TOML}" \
    "the .env.toml template (ADR-37 service runtime env)"
}

# why: .env.toml must carry its own [environment] section for service vars
@test ".env.toml: has [environment] table for service runtime env" {
  run grep '^\[environment\]' "${ENV_TOML}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Seam 3: service boundary -- no overlapping [environment] keys
# ════════════════════════════════════════════════════════════════════

# why: ADR-37 mandates zero intersection between setup.toml infra env
#      and .env.toml service runtime env; an overlapping key would mean
#      a variable is owned by both files, violating the service boundary.
#      Both sections ship with commented-out examples; the test extracts
#      those example key names and verifies they are disjoint.
@test "boundary: setup.toml and .env.toml have no overlapping env keys" {
  local -a setup_keys=() env_keys=()
  local in_env=0 line

  # Extract commented example key names from setup.toml [environment]
  while IFS= read -r line; do
    if [[ "${line}" =~ ^\[.+\] ]]; then
      [[ "${line}" == "[environment]" ]] && in_env=1 || in_env=0
      continue
    fi
    if (( in_env )) && [[ "${line}" =~ ^#[[:space:]]*([A-Z][A-Z0-9_]*)[[:space:]]*= ]]; then
      setup_keys+=("${BASH_REMATCH[1]}")
    fi
  done < "${SETUP_TOML}"

  # Extract commented example key names from .env.toml [environment]
  in_env=0
  while IFS= read -r line; do
    if [[ "${line}" =~ ^\[.+\] ]]; then
      [[ "${line}" == "[environment]" ]] && in_env=1 || in_env=0
      continue
    fi
    if (( in_env )) && [[ "${line}" =~ ^#[[:space:]]*([A-Z][A-Z0-9_]*)[[:space:]]*= ]]; then
      env_keys+=("${BASH_REMATCH[1]}")
    fi
  done < "${ENV_TOML}"

  # Both files must document at least one example key
  assert [ "${#setup_keys[@]}" -gt 0 ]
  assert [ "${#env_keys[@]}" -gt 0 ]

  # Check for intersection
  local overlap="" sk ek
  for sk in "${setup_keys[@]}"; do
    for ek in "${env_keys[@]}"; do
      [[ "${sk}" == "${ek}" ]] && overlap="${overlap} ${sk}"
    done
  done

  if [[ -n "${overlap}" ]]; then
    fail "overlapping [environment] keys between setup.toml and .env.toml:${overlap}"
  fi
}
