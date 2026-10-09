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

  # Force the docker path so mock_cmd "docker" is exercised; the native
  # toml-bridge binary IS available in the test-tools container but
  # these tests specifically verify the containerised fallback.
  export TOML_BRIDGE_FORCE_DOCKER=1

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
# Seam 6: toml_bridge_merge (type-aware multi-file merge, ADR-37)
# ════════════════════════════════════════════════════════════════════

# why: ADR-37 mandates type-aware merge: tables key-level, arrays replace;
#      the Python bridge must accept --merge to drive this from bash
@test "toml-bridge: Python bridge script supports --merge mode" {
  assert_spec_subject "${BRIDGE_PY}" \
    "the Python bridge script (merge mode for multi-file layers)"
  run grep -- '--merge' "${BRIDGE_PY}"
  assert_success
  run grep '_merge_toml' "${BRIDGE_PY}"
  assert_success
}

# why: the bash shim must expose a merge entry point for conf.sh layers
@test "toml-bridge: bash shim defines toml_bridge_merge function" {
  assert_spec_subject "${SHIM}" \
    "the toml_bridge.sh bash shim (merge function)"
  run grep 'toml_bridge_merge' "${SHIM}"
  assert_success
}

# why: key-level merge for tables -- upper overrides only what it defines;
#      keys absent from the upper layer must inherit from the lower layer
@test "merge: scalar key-level merge overrides only defined keys" {
  assert_spec_subject "${SHIM}" \
    "the toml_bridge.sh bash shim (merge)"

  local lower="${BATS_TEST_TMPDIR}/lower.toml"
  local upper="${BATS_TEST_TMPDIR}/upper.toml"
  printf '[gui]\nmode = "auto"\nresolution = "1080p"\n' > "${lower}"
  printf '[gui]\nmode = "wayland"\n' > "${upper}"

  create_mock_dir
  mock_cmd "docker" \
    'if [[ " $* " == *" --merge "* ]] && [[ " $* " == *" --kv "* ]]; then
       printf "gui\tmode\twayland\ngui\tresolution\t1080p\n"
     else
       echo "EXPECTED --merge --kv" >&2; exit 1
     fi'

  # shellcheck disable=SC1090
  source "${SHIM}"
  run toml_bridge_merge --kv "${lower}" "${upper}"
  assert_success
  assert_line --index 0 $'gui\tmode\twayland'
  assert_line --index 1 $'gui\tresolution\t1080p'

  cleanup_mock_dir
}

# why: array-of-tables replace -- the entire array from the highest layer
#      that defines it wins (ADR-37 sec. Merge semantics)
@test "merge: array of tables replaced entirely by upper layer" {
  assert_spec_subject "${SHIM}" \
    "the toml_bridge.sh bash shim (merge)"

  local lower="${BATS_TEST_TMPDIR}/lower.toml"
  local upper="${BATS_TEST_TMPDIR}/upper.toml"
  printf '[[volumes]]\nsource = "/a"\ntarget = "/b"\n\n[[volumes]]\nsource = "/c"\ntarget = "/d"\n' > "${lower}"
  printf '[[volumes]]\nsource = "/x"\ntarget = "/y"\n' > "${upper}"

  create_mock_dir
  mock_cmd "docker" \
    'if [[ " $* " == *" --merge "* ]] && [[ " $* " == *" --kv "* ]]; then
       printf "volumes\tsource\t/x\nvolumes\ttarget\t/y\n"
     else
       echo "EXPECTED --merge --kv" >&2; exit 1
     fi'

  # shellcheck disable=SC1090
  source "${SHIM}"
  run toml_bridge_merge --kv "${lower}" "${upper}"
  assert_success
  assert_line --index 0 $'volumes\tsource\t/x'
  assert_line --index 1 $'volumes\ttarget\t/y'
  assert_equal "${#lines[@]}" 2

  cleanup_mock_dir
}

# why: a real config has both table and array sections; the merge must
#      apply the correct rule to each (key-level for tables, replace for
#      arrays) in the same invocation
@test "merge: mixed file with both table and array sections" {
  assert_spec_subject "${SHIM}" \
    "the toml_bridge.sh bash shim (merge)"

  local lower="${BATS_TEST_TMPDIR}/lower.toml"
  local upper="${BATS_TEST_TMPDIR}/upper.toml"
  printf '[gui]\nmode = "auto"\nresolution = "1080p"\n\n[[volumes]]\nsource = "/a"\ntarget = "/b"\n' > "${lower}"
  printf '[gui]\nmode = "wayland"\n\n[[volumes]]\nsource = "/x"\ntarget = "/y"\n' > "${upper}"

  create_mock_dir
  mock_cmd "docker" \
    'if [[ " $* " == *" --merge "* ]] && [[ " $* " == *" --kv "* ]]; then
       printf "gui\tmode\twayland\ngui\tresolution\t1080p\nvolumes\tsource\t/x\nvolumes\ttarget\t/y\n"
     else
       echo "EXPECTED --merge --kv" >&2; exit 1
     fi'

  # shellcheck disable=SC1090
  source "${SHIM}"
  run toml_bridge_merge --kv "${lower}" "${upper}"
  assert_success
  assert_line --index 0 $'gui\tmode\twayland'
  assert_line --index 1 $'gui\tresolution\t1080p'
  assert_line --index 2 $'volumes\tsource\t/x'
  assert_line --index 3 $'volumes\ttarget\t/y'
  assert_equal "${#lines[@]}" 4

  cleanup_mock_dir
}

# why: an empty override layer (e.g. a local.toml with no sections) must
#      not clobber the baseline -- every key from the lower layer survives
@test "merge: empty upper layer preserves all lower keys" {
  assert_spec_subject "${SHIM}" \
    "the toml_bridge.sh bash shim (merge)"

  local lower="${BATS_TEST_TMPDIR}/lower.toml"
  local upper="${BATS_TEST_TMPDIR}/upper.toml"
  printf '[gui]\nmode = "auto"\nresolution = "1080p"\n' > "${lower}"
  printf '' > "${upper}"

  create_mock_dir
  mock_cmd "docker" \
    'if [[ " $* " == *" --merge "* ]] && [[ " $* " == *" --kv "* ]]; then
       printf "gui\tmode\tauto\ngui\tresolution\t1080p\n"
     else
       echo "EXPECTED --merge --kv" >&2; exit 1
     fi'

  # shellcheck disable=SC1090
  source "${SHIM}"
  run toml_bridge_merge --kv "${lower}" "${upper}"
  assert_success
  assert_line --index 0 $'gui\tmode\tauto'
  assert_line --index 1 $'gui\tresolution\t1080p'
  assert_equal "${#lines[@]}" 2

  cleanup_mock_dir
}

# why: a section defined only in the lower layer must survive untouched --
#      the upper layer's silence about a section is not a deletion
@test "merge: missing section in upper inherits from lower" {
  assert_spec_subject "${SHIM}" \
    "the toml_bridge.sh bash shim (merge)"

  local lower="${BATS_TEST_TMPDIR}/lower.toml"
  local upper="${BATS_TEST_TMPDIR}/upper.toml"
  printf '[gui]\nmode = "auto"\n\n[network]\nnet = "host"\nipc = "host"\n' > "${lower}"
  printf '[gui]\nmode = "wayland"\n' > "${upper}"

  create_mock_dir
  mock_cmd "docker" \
    'if [[ " $* " == *" --merge "* ]] && [[ " $* " == *" --kv "* ]]; then
       printf "gui\tmode\twayland\nnetwork\tnet\thost\nnetwork\tipc\thost\n"
     else
       echo "EXPECTED --merge --kv" >&2; exit 1
     fi'

  # shellcheck disable=SC1090
  source "${SHIM}"
  run toml_bridge_merge --kv "${lower}" "${upper}"
  assert_success
  assert_line --index 0 $'gui\tmode\twayland'
  assert_line --index 1 $'network\tnet\thost'
  assert_line --index 2 $'network\tipc\thost'
  assert_equal "${#lines[@]}" 3

  cleanup_mock_dir
}

# why: _conf_load_layers with all-TOML layers must dispatch to the
#      containerised merge so the accessor API reads the merged result
@test "merge: _conf_load_layers dispatches to TOML merge for .toml layers" {
  local conf_sh="${ROOT}/dist/script/docker/lib/conf.sh"
  assert_spec_subject "${conf_sh}" \
    "conf.sh _conf_load_layers TOML merge dispatch"

  local lower="${BATS_TEST_TMPDIR}/lower.toml"
  local upper="${BATS_TEST_TMPDIR}/upper.toml"
  printf '[gui]\nmode = "auto"\nresolution = "1080p"\n\n[network]\nnet = "host"\n' > "${lower}"
  printf '[gui]\nmode = "wayland"\n' > "${upper}"

  create_mock_dir
  mock_cmd "docker" \
    'if [[ " $* " == *" --merge "* ]] && [[ " $* " == *" --kv "* ]]; then
       printf "gui\tmode\twayland\ngui\tresolution\t1080p\nnetwork\tnet\thost\n"
     else
       echo "EXPECTED --merge --kv" >&2; exit 1
     fi'

  # shellcheck disable=SC1090
  source "${conf_sh}"
  _conf_load_layers MHDL "${lower}" "${upper}"

  run _conf_get MHDL gui mode
  assert_success
  assert_output "wayland"

  run _conf_get MHDL gui resolution
  assert_success
  assert_output "1080p"

  run _conf_get MHDL network net
  assert_success
  assert_output "host"

  run _conf_sections MHDL
  assert_success
  assert_line --index 0 "gui"
  assert_line --index 1 "network"

  cleanup_mock_dir
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
@test "toml-bridge: Python bridge script declares --merge flag" {
  assert_spec_subject "${BRIDGE_PY}" \
    "the Python bridge script (--merge mode declaration)"
  run grep -- '--merge' "${BRIDGE_PY}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Seam 8: _emit_kv array serialization (D1 setup.toml migration)
# ════════════════════════════════════════════════════════════════════

# why: [[array of tables]] in TOML must become numbered-key KV lines
#      (mount_1, arg_1, etc.) for backward compat with compose_emit.sh
@test "toml-bridge: Python _emit_kv has array serialization spec" {
  assert_spec_subject "${BRIDGE_PY}" \
    "the Python bridge script (array serialization)"
  run grep '_ARRAY_SPEC' "${BRIDGE_PY}"
  assert_success
}

# why: nested [[build.args]] array must serialize to arg_1, arg_2 lines
#      under the parent section so compose_emit.sh sees the same format
@test "toml-bridge: _emit_kv nested array produces numbered keys under parent section" {
  assert_spec_subject "${BRIDGE_PY}" \
    "the Python bridge script (nested array KV)"

  local toml_file
  toml_file="$(mktemp --suffix=.toml)"
  cat > "${toml_file}" << 'EOF'
[build]
target_arch = ""
network = "auto"

[[build.args]]
key = "TZ"
value = "Asia/Taipei"

[[build.args]]
key = "APT_MIRROR"
value = "tw.archive.ubuntu.com"
EOF

  create_mock_dir
  mock_cmd "docker" \
    'printf "build\ttarget_arch\t\nbuild\tnetwork\tauto\nbuild\targ_1\tTZ=Asia/Taipei\nbuild\targ_2\tAPT_MIRROR=tw.archive.ubuntu.com\n"'

  # shellcheck disable=SC1090
  source "${SHIM}"
  run toml_bridge_parse "${toml_file}" --kv
  assert_success
  assert_line "build	target_arch	"
  assert_line "build	network	auto"
  assert_line "build	arg_1	TZ=Asia/Taipei"
  assert_line "build	arg_2	APT_MIRROR=tw.archive.ubuntu.com"

  cleanup_mock_dir
  rm -f "${toml_file}"
}

# ════════════════════════════════════════════════════════════════════
# Seam 9: setup.toml template (D1 setup.toml migration)
# ════════════════════════════════════════════════════════════════════

# why: the TOML template must mirror all 15 INI sections so the format
#      migration is complete and no section is silently dropped
@test "toml-bridge: setup.toml template has all 15 sections" {
  local setup_toml="${ROOT}/dist/setup.toml"
  assert_spec_subject "${setup_toml}" \
    "the setup.toml template (format migration D1)"

  local -a expected_sections=(
    project image build deploy lifecycle
    gui network security resources environment
    tmpfs devices volumes additional_contexts logging
  )
  local sect
  for sect in "${expected_sections[@]}"; do
    run grep -E "^\[${sect}( |\])" "${setup_toml}"
    if [[ "${status}" -ne 0 ]]; then
      run grep -E "^\[\[${sect}(\.|]])" "${setup_toml}"
    fi
    if [[ "${status}" -ne 0 ]]; then
      run grep -E "^# *\[\[${sect}" "${setup_toml}"
    fi
    assert_success "section [${sect}] or [[${sect}...]] missing from setup.toml"
  done
}

# why: D1 acceptance criterion -- numbered-key patterns (_N =) must be
#      eliminated, replaced by [[array of tables]]
@test "toml-bridge: setup.toml has zero numbered-key patterns" {
  local setup_toml="${ROOT}/dist/setup.toml"
  assert_spec_subject "${setup_toml}" \
    "the setup.toml template (no numbered keys)"

  run grep -cE '^[a-z_]+_[0-9]+ *=' "${setup_toml}"
  if [[ "${status}" -eq 0 && "${output}" -gt 0 ]]; then
    fail "setup.toml still has ${output} numbered-key patterns (_N =)"
  fi
}

# ════════════════════════════════════════════════════════════════════
# Seam 10: _conf_load_layers with array KV (D1 integration)
# ════════════════════════════════════════════════════════════════════

# why: when toml_bridge_merge --kv emits numbered keys from [[array of
#      tables]], _conf_load_layers must populate the accessor arrays so
#      compose_emit.sh sees the same format as from INI numbered keys
@test "toml-bridge: _conf_load_layers reads array-produced numbered keys from TOML" {
  local conf_sh="${ROOT}/dist/script/docker/lib/conf.sh"
  assert_spec_subject "${conf_sh}" \
    "conf.sh _conf_load_layers (array KV from TOML)"

  local toml_file
  toml_file="$(mktemp --suffix=.toml)"
  cat > "${toml_file}" << 'EOF'
[build]
network = "auto"

[[build.args]]
key = "TZ"
value = "Asia/Taipei"

[[image.rules]]
rule = "prefix:docker_"
EOF

  create_mock_dir
  mock_cmd "docker" \
    'printf "build\tnetwork\tauto\nbuild\targ_1\tTZ=Asia/Taipei\nimage\trule_1\tprefix:docker_\n"'

  # shellcheck disable=SC1090
  source "${conf_sh}"
  _conf_load_layers AKHDL "${toml_file}"

  run _conf_get AKHDL build network
  assert_success
  assert_output "auto"

  run _conf_get AKHDL build arg_1
  assert_success
  assert_output "TZ=Asia/Taipei"

  run _conf_get AKHDL image rule_1
  assert_success
  assert_output "prefix:docker_"

  cleanup_mock_dir
  rm -f "${toml_file}"
}

# ════════════════════════════════════════════════════════════════════
# Seam 11: the bridge's own CLI, run for real
# ════════════════════════════════════════════════════════════════════
#
# Every merge / KV case above mocks `docker` with a printf of the answer
# the bridge is supposed to give, so it asserts the shim's plumbing and
# nothing about the parser -- a bridge that exits 1 without printing a
# byte passes all of them. The cases below run the tracked script in THIS
# checkout through the interpreter the test-tools image ships (ADR-37: the
# bridge is Python, and Dockerfile.test-tools installs python3 for it), so
# the TOML going in and the TSV coming out are the bridge's own.

# why: the merge is the whole contract the shell layer reads -- a table's
#      keys merge key-level while an array of tables is replaced wholesale,
#      and the winner arrives as the numbered keys _conf_list_sorted
#      matches. Asserting that against a mocked answer proves none of it.
@test "toml-bridge: --merge --kv merges layers into the numbered-key shape" {
  assert_spec_subject "${BRIDGE_PY}" \
    "the Python bridge script (--merge --kv contract)"

  local lower="${BATS_TEST_TMPDIR}/lower.toml"
  local upper="${BATS_TEST_TMPDIR}/upper.toml"
  cat > "${lower}" << 'EOF'
[gui]
mode = "x11"
theme = "dark"

[[image.rules]]
rule = "prefix:stale_"

[[devices]]
path = "/dev/dri"
EOF
  cat > "${upper}" << 'EOF'
[gui]
mode = "wayland"

[[image.rules]]
rule = "prefix:docker_"

[[image.rules]]
rule = "@basename"
EOF

  run python3 "${BRIDGE_PY}" --merge --kv "${lower}" "${upper}"
  assert_success
  # Table: key-level. The upper layer moves `mode` and says nothing about
  # `theme`, which therefore survives from the lower layer.
  assert_line "gui	mode	wayland"
  assert_line "gui	theme	dark"
  # Array of tables: replaced wholesale, numbered from the winning layer.
  assert_line "image	rule_1	prefix:docker_"
  assert_line "image	rule_2	@basename"
  refute_output --partial "prefix:stale_"
  # A top-level array of tables is numbered the same way, and the upper
  # layer's silence about it is not a deletion.
  assert_line "devices	device_1	/dev/dri"
}

# why: doc/deprecations.md publishes that `[deploy] runtime` is consumed
#      when `gpu_runtime` is absent, and the shipped template always
#      supplies `gpu_runtime = "auto"`. Deciding "absent" on the MERGED
#      result makes that branch unreachable: the inherited canonical
#      default masks the legacy key a consumer wrote one layer up, so
#      `runtime = "runc"` silently resolved to `auto`. Absence is per
#      LAYER -- the highest layer that spells the setting out decides it.
@test "toml-bridge: --merge a legacy alias one layer up drops the inherited canonical key" {
  assert_spec_subject "${BRIDGE_PY}" \
    "the Python bridge script (--merge deprecated-alias precedence)"

  local lower="${BATS_TEST_TMPDIR}/lower.toml"
  local upper="${BATS_TEST_TMPDIR}/upper.toml"
  printf '[deploy]\ngpu_mode = "auto"\ngpu_runtime = "auto"\n' > "${lower}"
  printf '[deploy]\nruntime = "runc"\n' > "${upper}"

  run python3 "${BRIDGE_PY}" --merge --kv "${lower}" "${upper}"
  assert_success
  assert_line "deploy	runtime	runc"
  refute_output --partial "gpu_runtime"
  # Only the aliased pair is unmasked; every other inherited key stays.
  assert_line "deploy	gpu_mode	auto"
}

# why: `gpu_runtime` wins when both spellings appear in ONE layer
#      (doc/deprecations.md), so the alias rule must not strip a canonical
#      key the layer itself supplied -- only one it merely inherited.
@test "toml-bridge: --merge keeps a canonical key the same layer supplies" {
  assert_spec_subject "${BRIDGE_PY}" \
    "the Python bridge script (--merge deprecated-alias precedence)"

  local lower="${BATS_TEST_TMPDIR}/lower.toml"
  local upper="${BATS_TEST_TMPDIR}/upper.toml"
  printf '[deploy]\ngpu_runtime = "auto"\n' > "${lower}"
  printf '[deploy]\ngpu_runtime = "nvidia"\nruntime = "off"\n' > "${upper}"

  run python3 "${BRIDGE_PY}" --merge --kv "${lower}" "${upper}"
  assert_success
  assert_line "deploy	gpu_runtime	nvidia"
  assert_line "deploy	runtime	off"
}

# why: `devices` hosts two independently replaceable lists -- host bindings
#      and cgroup rules -- so each gets its own nested array, the shape
#      `security` already uses for cap_add / security_opt. One array at the
#      section meant the two could not be expressed in one document at all.
#      Both still have to arrive on the shell side under the `<prefix>_N`
#      names every ordered-list reader matches, and each has to replace
#      atomically without touching the other.
@test "toml-bridge: --merge --kv numbers devices.bindings and devices.cgroup_rules apart" {
  assert_spec_subject "${BRIDGE_PY}" \
    "the Python bridge script (devices namespace)"

  local lower="${BATS_TEST_TMPDIR}/lower.toml"
  local upper="${BATS_TEST_TMPDIR}/upper.toml"
  cat > "${lower}" << 'EOF'
[[devices.bindings]]
path = "/dev/dri"

[[devices.bindings]]
path = "/dev/snd"

[[devices.cgroup_rules]]
rule = "c 189:* rwm"
EOF
  cat > "${upper}" << 'EOF'
[[devices.cgroup_rules]]
rule = "b 8:0 rw"
EOF

  run python3 "${BRIDGE_PY}" --merge --kv "${lower}" "${upper}"
  assert_success
  # The bindings the upper layer says nothing about survive, numbered.
  assert_line "devices	device_1	/dev/dri"
  assert_line "devices	device_2	/dev/snd"
  # The rules it DOES define replace the lower layer's list entirely.
  assert_line "devices	cgroup_rule_1	b 8:0 rw"
  refute_output --partial "c 189:* rwm"
}

# why: ADR-00000037's table rule is unqualified, and a nested table is a
#      table, so `[logging.web]` merges key by key across layers like
#      every other. The merge used a shallow dict update, which replaced
#      the whole sub-table: a setup.local.toml naming one key of
#      `[logging.web]` silently dropped every other key the repo set for
#      that service. An array is still replaced whole, at any depth.
@test "toml-bridge: --merge merges a nested table key by key" {
  assert_spec_subject "${BRIDGE_PY}" \
    "the Python bridge script (--merge recursive table merge)"

  local lower="${BATS_TEST_TMPDIR}/lower.toml"
  local upper="${BATS_TEST_TMPDIR}/upper.toml"
  cat > "${lower}" << 'EOF'
[logging]
driver = "json-file"

[logging.web]
driver = "local"
max_size = "20m"
max_file = "3"
EOF
  cat > "${upper}" << 'EOF'
[logging.web]
max_size = "100m"
EOF

  run python3 "${BRIDGE_PY}" --merge --kv "${lower}" "${upper}"
  assert_success
  assert_line "logging.web	max_size	100m"
  # The keys the upper layer says nothing about survive the sub-table.
  assert_line "logging.web	driver	local"
  assert_line "logging.web	max_file	3"
  # The parent table is untouched by a write to its child.
  assert_line "logging	driver	json-file"
}

# why: arrays stay atomic at every depth -- the recursion must not start
#      merging a nested array element by element. `[[logging.web.sinks]]`
#      is not a shape the schema has, so `[[build.args]]` one level down
#      from a table that IS merged is the case that pins it.
@test "toml-bridge: --merge replaces a nested array whole while merging around it" {
  assert_spec_subject "${BRIDGE_PY}" \
    "the Python bridge script (--merge recursive table merge)"

  local lower="${BATS_TEST_TMPDIR}/lower.toml"
  local upper="${BATS_TEST_TMPDIR}/upper.toml"
  cat > "${lower}" << 'EOF'
[build]
target_arch = "arm64"
network = "host"

[[build.args]]
key = "TZ"
value = "Asia/Taipei"

[[build.args]]
key = "APT_MIRROR_UBUNTU"
value = "tw.archive.ubuntu.com"
EOF
  cat > "${upper}" << 'EOF'
[build]
network = "bridge"

[[build.args]]
key = "TZ"
value = "UTC"
EOF

  run python3 "${BRIDGE_PY}" --merge --kv "${lower}" "${upper}"
  assert_success
  # Table keys merge...
  assert_line "build	network	bridge"
  assert_line "build	target_arch	arm64"
  # ...and the array the upper layer defines replaces the list entirely.
  assert_line "build	arg_1	TZ=UTC"
  refute_output --partial "tw.archive.ubuntu.com"
}

# why: a TOML boolean reaches the shell as the string the shell compares
#      against, and Python's str(True) is `True`. Every `== true` on the
#      shell side reads that as false, so the setting arrives inverted and
#      says nothing about it -- the one failure mode a type-aware bridge
#      exists to prevent.
@test "toml-bridge: --kv renders a TOML boolean lowercase" {
  assert_spec_subject "${BRIDGE_PY}" \
    "the Python bridge script (boolean KV rendering)"

  local toml_file="${BATS_TEST_TMPDIR}/lifecycle.toml"
  printf '[lifecycle]\ninit = true\ntty = false\n' > "${toml_file}"

  run python3 "${BRIDGE_PY}" --kv < "${toml_file}"
  assert_success
  assert_line "lifecycle	init	true"
  assert_line "lifecycle	tty	false"
}

# why: a bridge that fails prints nothing and says so with its exit status.
#      Read through a process substitution that status is out of reach, and
#      the caller is handed a handle with nothing in it -- indistinguishable
#      from a config whose every value is the default. That is what turned a
#      totally broken merge into a silent, plausible-looking run, so the
#      status has to reach the caller.
@test "toml-bridge: _conf_load_layers fails when the bridge exits non-zero" {
  local conf_sh="${ROOT}/dist/script/docker/lib/conf.sh"
  assert_spec_subject "${conf_sh}" \
    "conf.sh _conf_load_layers (bridge failure propagation)"

  local toml_file="${BATS_TEST_TMPDIR}/layer.toml"
  printf '[gui]\nmode = "x11"\n' > "${toml_file}"

  # shellcheck disable=SC1090
  source "${conf_sh}"
  # The exact failure shape the botched merge produced: exit 1, stdout empty.
  toml_bridge_merge() { return 1; }

  run _conf_load_layers FHDL "${toml_file}"
  assert_failure
}

# why: the shell view has no nesting -- a section is one flat name -- and
#      `[logging.web]` is the per-service spelling the template documents and
#      `_conf_toml_header` writes. str()-ing the dict hands the shell
#      `logging<TAB>web<TAB>{'driver': 'local'}`: the section `logging.web`
#      never exists, so `_load_setup_conf <base> logging.web` reads nothing,
#      and the global `[logging]` gains a key whose value is a Python repr.
@test "toml-bridge: --kv flattens a nested table into its own dotted section" {
  assert_spec_subject "${BRIDGE_PY}" \
    "the Python bridge script (nested table flattening)"

  local toml_file="${BATS_TEST_TMPDIR}/logging.toml"
  cat > "${toml_file}" << 'EOF'
[logging]
driver = "json-file"
max_size = "10m"

[logging.web]
driver = "local"
local_path = "./log/web"
EOF

  run python3 "${BRIDGE_PY}" --kv < "${toml_file}"
  assert_success
  assert_line "logging	driver	json-file"
  assert_line "logging	max_size	10m"
  assert_line "logging.web	driver	local"
  assert_line "logging.web	local_path	./log/web"
  # The nested table is NOT also a key of its parent, and never a repr.
  refute_output --partial "{"
  refute_line --regexp $'^logging\tweb\t'
}

# why: `[[security.cap_add]]` / `[[security.security_opt]]` are written with
#      the field names the shipped template documents and both writers emit
#      (`cap` / `opt`) -- the INI-to-TOML converter writes the same. Reading
#      a `name` field finds nothing, so every capability a repo opts into
#      arrives as an empty numbered key and the container runs without it.
@test "toml-bridge: --kv reads the cap / opt fields the writers emit" {
  assert_spec_subject "${BRIDGE_PY}" \
    "the Python bridge script (security array field names)"

  local toml_file="${BATS_TEST_TMPDIR}/security.toml"
  cat > "${toml_file}" << 'EOF'
[security]
privileged = false

[[security.cap_add]]
cap = "SYS_ADMIN"

[[security.cap_add]]
cap = "NET_ADMIN"

[[security.security_opt]]
opt = "seccomp:unconfined"
EOF

  run python3 "${BRIDGE_PY}" --kv < "${toml_file}"
  assert_success
  assert_line "security	privileged	false"
  assert_line "security	cap_add_1	SYS_ADMIN"
  assert_line "security	cap_add_2	NET_ADMIN"
  assert_line "security	security_opt_1	seccomp:unconfined"
}

# why: `docker run -v <src>:<dst>` refuses a destination that is not
#      absolute, so a layer named relatively -- which is what the chain
#      carries whenever the caller passed a relative --base-path -- made the
#      containerised merge fail on a file that was right there. The native
#      path never saw it, so the failure only appeared on hosts without the
#      bridge binary: exactly the hosts the docker path exists for.
@test "toml-bridge: merge shim mounts a relatively named layer by absolute path" {
  assert_spec_subject "${SHIM}" \
    "the toml_bridge.sh bash shim (merge mount paths)"

  local _dir="${BATS_TEST_TMPDIR}/rel"
  mkdir -p "${_dir}"
  printf '[gui]\nmode = "x11"\n' > "${_dir}/setup.toml"

  create_mock_dir
  # Echo the -v arguments back so the mount spec itself is the assertion.
  mock_cmd "docker" \
    'while (( $# )); do if [[ "$1" == "-v" ]]; then printf "MOUNT=%s\n" "$2"; shift 2; else shift; fi; done'

  # shellcheck disable=SC1090
  source "${SHIM}"
  run bash -c "cd '${_dir}' && source '${SHIM}' && toml_bridge_merge --kv setup.toml"
  assert_success
  assert_line "MOUNT=${_dir}/setup.toml:${_dir}/setup.toml:ro"
  refute_line "MOUNT=setup.toml:setup.toml:ro"

  cleanup_mock_dir
}
