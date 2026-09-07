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
# Seam 4: --kv output mode (conf.sh integration)
# ════════════════════════════════════════════════════════════════════

# why: conf.sh needs line-oriented output to fill bash parallel arrays;
#      JSON requires jq (not on host), so --kv emits section/key/value TSV
@test "toml-bridge: Python bridge script supports --kv output mode" {
  assert_spec_subject "${BRIDGE_PY}" \
    "the Python bridge script (KV output for bash consumers)"
  run grep -- '--kv' "${BRIDGE_PY}"
  assert_success
}

# why: the shim must pass --kv to docker run so bash callers get TSV
@test "toml-bridge: shim KV mode passes --kv to docker run" {
  assert_spec_subject "${SHIM}" \
    "the toml_bridge.sh bash shim (KV mode)"

  local toml_file
  toml_file="$(mktemp)"
  printf '[deploy]\ngpu_runtime = "auto"\n' > "${toml_file}"

  create_mock_dir
  mock_cmd "docker" \
    'if [[ " $* " == *" --kv "* ]]; then printf "deploy\tgpu_runtime\tauto\n"; else echo "NO_KV_FLAG"; fi'

  # shellcheck disable=SC1090
  source "${SHIM}"
  run toml_bridge_parse "${toml_file}" --kv
  assert_success
  assert_output "deploy	gpu_runtime	auto"

  cleanup_mock_dir
  rm -f "${toml_file}"
}

# ════════════════════════════════════════════════════════════════════
# Seam 5: _toml_tokenize fills parallel arrays (ADR-37 conf.sh)
# ════════════════════════════════════════════════════════════════════

# why: _toml_tokenize is the drop-in replacement for _ini_tokenize --
#      it must fill the same 4 parallel arrays from bridge KV output
@test "toml-bridge: _toml_tokenize fills sections/keys/values from KV output" {
  local conf_sh="${ROOT}/dist/script/docker/lib/conf.sh"
  assert_spec_subject "${conf_sh}" \
    "conf.sh _toml_tokenize function"

  local toml_file
  toml_file="$(mktemp --suffix=.toml)"
  printf '[deploy]\ngpu_runtime = "auto"\ngpu_count = 2\n\n[network]\nnet = "host"\n' > "${toml_file}"

  create_mock_dir
  mock_cmd "docker" \
    'printf "deploy\tgpu_runtime\tauto\ndeploy\tgpu_count\t2\nnetwork\tnet\thost\n"'

  # shellcheck disable=SC1090
  source "${conf_sh}"
  local -a sects es keys vals
  _toml_tokenize "${toml_file}" sects es keys vals

  assert_equal "${#sects[@]}" 2
  assert_equal "${sects[0]}" "deploy"
  assert_equal "${sects[1]}" "network"

  assert_equal "${#keys[@]}" 3
  assert_equal "${es[0]}" "deploy"
  assert_equal "${keys[0]}" "gpu_runtime"
  assert_equal "${vals[0]}" "auto"
  assert_equal "${es[2]}" "network"
  assert_equal "${keys[2]}" "net"
  assert_equal "${vals[2]}" "host"

  cleanup_mock_dir
  rm -f "${toml_file}"
}

# why: _conf_load must auto-dispatch to TOML for .toml files so the
#      accessor API works without callers changing their code
@test "toml-bridge: _conf_load dispatches to _toml_tokenize for .toml files" {
  local conf_sh="${ROOT}/dist/script/docker/lib/conf.sh"
  assert_spec_subject "${conf_sh}" \
    "conf.sh _conf_load TOML dispatch"

  local toml_file
  toml_file="$(mktemp --suffix=.toml)"
  printf '[gui]\nmode = "wayland"\n' > "${toml_file}"

  create_mock_dir
  mock_cmd "docker" \
    'printf "gui\tmode\twayland\n"'

  # shellcheck disable=SC1090
  source "${conf_sh}"
  _conf_load "${toml_file}" THDL

  run _conf_get THDL gui mode
  assert_success
  assert_output "wayland"

  run _conf_sections THDL
  assert_success
  assert_output "gui"

  cleanup_mock_dir
  rm -f "${toml_file}"
}

# why: the INI path must survive so callers using .conf files keep working
@test "toml-bridge: _conf_load still uses _ini_tokenize for .conf files" {
  local conf_sh="${ROOT}/dist/script/docker/lib/conf.sh"
  assert_spec_subject "${conf_sh}" \
    "conf.sh _conf_load INI backward compat"

  local ini_file
  ini_file="$(mktemp --suffix=.conf)"
  printf '[deploy]\ngpu_runtime = auto\ngpu_count = 2\n' > "${ini_file}"

  # shellcheck disable=SC1090
  source "${conf_sh}"
  _conf_load "${ini_file}" IHDL

  run _conf_get IHDL deploy gpu_runtime
  assert_success
  assert_output "auto"

  run _conf_get IHDL deploy gpu_count
  assert_success
  assert_output "2"

  rm -f "${ini_file}"
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

# ════════════════════════════════════════════════════════════════════
# Seam 6: toml_bridge_merge shim (D4 ADR-37 type-aware merge)
# ════════════════════════════════════════════════════════════════════

# why: type-aware merge is the D4 core contract -- scalar keys within a
#      [table] get key-level merge: upper layer overrides only the keys it
#      defines, unmentioned keys inherit from the lower layer
@test "toml-bridge: merge shim scalar key-level merge via --kv" {
  assert_spec_subject "${SHIM}" \
    "the toml_bridge.sh bash shim (merge mode)"

  local base_toml upper_toml
  base_toml="$(mktemp --suffix=.toml)"
  upper_toml="$(mktemp --suffix=.toml)"
  printf '[gui]\nmode = "x11"\ntheme = "dark"\n' > "${base_toml}"
  printf '[gui]\nmode = "wayland"\n' > "${upper_toml}"

  create_mock_dir
  mock_cmd "docker" \
    'printf "gui\tmode\twayland\ngui\ttheme\tdark\n"'

  # shellcheck disable=SC1090
  source "${SHIM}"
  run toml_bridge_merge --kv "${base_toml}" "${upper_toml}"
  assert_success
  assert_line "gui	mode	wayland"
  assert_line "gui	theme	dark"

  cleanup_mock_dir
  rm -f "${base_toml}" "${upper_toml}"
}

# why: [[array of tables]] must be replaced wholesale by the upper layer --
#      per-element merge of ordered lists is broken (ADR-25 sec.3 rationale)
@test "toml-bridge: merge shim array replace for [[array of tables]]" {
  assert_spec_subject "${SHIM}" \
    "the toml_bridge.sh bash shim (merge array replace)"

  local base_toml upper_toml
  base_toml="$(mktemp --suffix=.toml)"
  upper_toml="$(mktemp --suffix=.toml)"
  printf '[[volumes]]\nmount = "/data"\n\n[[volumes]]\nmount = "/log"\n' > "${base_toml}"
  printf '[[volumes]]\nmount = "/scratch"\n' > "${upper_toml}"

  create_mock_dir
  mock_cmd "docker" \
    'printf "volumes\tmount\t/scratch\n"'

  # shellcheck disable=SC1090
  source "${SHIM}"
  run toml_bridge_merge --kv "${base_toml}" "${upper_toml}"
  assert_success
  assert_output "volumes	mount	/scratch"

  cleanup_mock_dir
  rm -f "${base_toml}" "${upper_toml}"
}

# why: absent layers must be silently skipped so callers can pass the
#      whole chain unconditionally (matching _conf_load_layers convention)
@test "toml-bridge: merge shim skips missing files silently" {
  assert_spec_subject "${SHIM}" \
    "the toml_bridge.sh bash shim (merge missing-file skip)"

  local base_toml
  base_toml="$(mktemp --suffix=.toml)"
  printf '[gui]\nmode = "x11"\n' > "${base_toml}"

  create_mock_dir
  mock_cmd "docker" \
    'printf "gui\tmode\tx11\n"'

  # shellcheck disable=SC1090
  source "${SHIM}"
  run toml_bridge_merge --kv "${base_toml}" "/nonexistent/upper.toml"
  assert_success
  assert_output "gui	mode	x11"

  cleanup_mock_dir
  rm -f "${base_toml}"
}

# ════════════════════════════════════════════════════════════════════
# Seam 7: _conf_load_layers TOML dispatch (D4 type-aware merge)
# ════════════════════════════════════════════════════════════════════

# why: _conf_load_layers must dispatch to toml_bridge_merge when all files
#      are .toml, producing type-aware merge (key-level for tables, array
#      replace for arrays) instead of bash section-replace
@test "toml-bridge: _conf_load_layers merges .toml files via bridge" {
  local conf_sh="${ROOT}/dist/script/docker/lib/conf.sh"
  assert_spec_subject "${conf_sh}" \
    "conf.sh _conf_load_layers TOML dispatch"

  local base_toml upper_toml
  base_toml="$(mktemp --suffix=.toml)"
  upper_toml="$(mktemp --suffix=.toml)"
  printf '[gui]\nmode = "x11"\ntheme = "dark"\n[network]\nnet = "bridge"\n' > "${base_toml}"
  printf '[gui]\nmode = "wayland"\n' > "${upper_toml}"

  create_mock_dir
  mock_cmd "docker" \
    'printf "gui\tmode\twayland\ngui\ttheme\tdark\nnetwork\tnet\tbridge\n"'

  # shellcheck disable=SC1090
  source "${conf_sh}"
  _conf_load_layers MHDL "${base_toml}" "${upper_toml}"

  run _conf_get MHDL gui mode
  assert_success
  assert_output "wayland"

  run _conf_get MHDL gui theme
  assert_success
  assert_output "dark"

  run _conf_get MHDL network net
  assert_success
  assert_output "bridge"

  cleanup_mock_dir
  rm -f "${base_toml}" "${upper_toml}"
}

# why: the INI section-replace path must survive so existing .conf callers
#      keep working -- mixed .conf/.toml chains also fall through to INI
@test "toml-bridge: _conf_load_layers uses INI path for .conf files" {
  local conf_sh="${ROOT}/dist/script/docker/lib/conf.sh"
  assert_spec_subject "${conf_sh}" \
    "conf.sh _conf_load_layers INI backward compat"

  local base_conf upper_conf
  base_conf="$(mktemp --suffix=.conf)"
  upper_conf="$(mktemp --suffix=.conf)"
  printf '[gui]\nmode = x11\ntheme = dark\n' > "${base_conf}"
  printf '[gui]\nmode = wayland\n' > "${upper_conf}"

  # shellcheck disable=SC1090
  source "${conf_sh}"
  _conf_load_layers IHDL "${base_conf}" "${upper_conf}"

  run _conf_get IHDL gui mode
  assert_success
  assert_output "wayland"

  # section-replace: theme from base is gone because upper defined [gui]
  run _conf_get IHDL gui theme ""
  assert_success
  assert_output ""

  rm -f "${base_conf}" "${upper_conf}"
}

# why: the Python bridge must declare --merge mode so the shim can invoke it
@test "toml-bridge: Python bridge script supports --merge mode" {
  assert_spec_subject "${BRIDGE_PY}" \
    "the Python bridge script (--merge mode declaration)"
  run grep -- '--merge' "${BRIDGE_PY}"
  assert_success
}
