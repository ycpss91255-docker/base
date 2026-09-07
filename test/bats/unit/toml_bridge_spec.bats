#!/usr/bin/env bats
#
# toml_bridge_spec.bats -- unit tests for the toml-bridge containerised
# TOML parser (ADR-37 sec. Containerised parsing).
#
# Seam 1: Dockerfile.toml-bridge structure (tool-pin markers, Python
#          version, tomli vendoring).
# Seam 2: toml_bridge.sh bash shim (TOML in -> JSON out via docker run).
# Seam 3: Dockerfile.test-tools COPY --from=toml-bridge integration.
#
# Pure file reads + mocked docker: Unit level (ADR-00000018).

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  ROOT=/source
  DOCKERFILE="${ROOT}/dockerfile/Dockerfile.toml-bridge"
  BRIDGE_PY="${ROOT}/dockerfile/toml_bridge.py"
  SHIM="${ROOT}/dist/script/docker/lib/toml_bridge.sh"
  TEST_TOOLS="${ROOT}/dockerfile/Dockerfile.test-tools"
}

# ════════════════════════════════════════════════════════════════════
# Seam 1: Dockerfile.toml-bridge structure
# ════════════════════════════════════════════════════════════════════

# why: ADR-37 mandates a standalone toml-bridge image for containerised parsing
@test "toml-bridge: Dockerfile exists" {
  assert_spec_subject "${DOCKERFILE}" \
    "the toml-bridge Dockerfile (ADR-37 containerised parsing)"
}

# why: reproducible builds require a pinned Python base with tool-pin marker
@test "toml-bridge: Python version pinned with tool-pin marker" {
  assert_spec_subject "${DOCKERFILE}" \
    "the toml-bridge Dockerfile"
  run grep 'tool-pin:.*python' "${DOCKERFILE}"
  assert_success
  run grep '^ARG PYTHON_VERSION=' "${DOCKERFILE}"
  assert_success
}

# why: reproducible builds require a pinned tomli dependency with tool-pin marker
@test "toml-bridge: tomli version pinned with tool-pin marker" {
  assert_spec_subject "${DOCKERFILE}" \
    "the toml-bridge Dockerfile"
  run grep 'tool-pin:.*tomli' "${DOCKERFILE}"
  assert_success
  run grep '^ARG TOMLI_VERSION=' "${DOCKERFILE}"
  assert_success
}

# why: the Dockerfile COPY needs the script present in the build context
@test "toml-bridge: Python bridge script exists in build context" {
  assert_spec_subject "${BRIDGE_PY}" \
    "the Python bridge script that Dockerfile.toml-bridge COPYs"
}

# ════════════════════════════════════════════════════════════════════
# Seam 2: toml_bridge.sh bash shim
# ════════════════════════════════════════════════════════════════════

# why: the shim is the host-side entry point sourced by all TOML consumers
@test "toml-bridge: bash shim exists and is sourceable" {
  assert_spec_subject "${SHIM}" \
    "the toml_bridge.sh bash shim (host-side entry point)"
  run bash -n "${SHIM}"
  assert_success
}

# why: golden-path contract -- TOML in, JSON out, via docker run
@test "toml-bridge: shim converts TOML to JSON via docker run" {
  assert_spec_subject "${SHIM}" \
    "the toml_bridge.sh bash shim"

  local toml_file
  toml_file="$(mktemp)"
  printf '[gui]\nmode = "wayland"\n' > "${toml_file}"

  create_mock_dir
  mock_cmd "docker" \
    'echo "{\"gui\": {\"mode\": \"wayland\"}}"'

  # shellcheck disable=SC1090
  source "${SHIM}"
  run toml_bridge_parse "${toml_file}"
  assert_success
  assert_output '{"gui": {"mode": "wayland"}}'

  cleanup_mock_dir
  rm -f "${toml_file}"
}

# why: callers rely on non-zero exit to detect parse failures
@test "toml-bridge: shim returns non-zero when docker run fails" {
  assert_spec_subject "${SHIM}" \
    "the toml_bridge.sh bash shim"

  local toml_file
  toml_file="$(mktemp)"
  printf 'invalid = [toml\n' > "${toml_file}"

  create_mock_dir
  mock_cmd "docker" \
    'echo "parse error" >&2; exit 1'

  # shellcheck disable=SC1090
  source "${SHIM}"
  run toml_bridge_parse "${toml_file}"
  assert_failure

  cleanup_mock_dir
  rm -f "${toml_file}"
}

# why: callers rely on non-zero exit for missing input before docker starts
@test "toml-bridge: shim returns non-zero for missing file" {
  assert_spec_subject "${SHIM}" \
    "the toml_bridge.sh bash shim"

  # shellcheck disable=SC1090
  source "${SHIM}"
  run toml_bridge_parse "/nonexistent/file.toml"
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# Seam 3: test-tools COPY --from integration
# ════════════════════════════════════════════════════════════════════

# why: downstream repos inherit the parser via test-tools without building toml-bridge
@test "toml-bridge: test-tools Dockerfile has COPY --from for toml-bridge" {
  assert_spec_subject "${TEST_TOOLS}" \
    "the test-tools Dockerfile"
  run grep 'COPY --from=.*toml-bridge' "${TEST_TOOLS}"
  assert_success
}
