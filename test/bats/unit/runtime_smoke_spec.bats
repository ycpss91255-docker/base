#!/usr/bin/env bats
#
# Unit tests for dist/test/bats/smoke/smoke.sh -- the runtime-test
# smoke check that catches missing shared library dependencies.
#
# why: Unit tests for the runtime `.so` dependency smoke scanner
# (`smoke.sh`, #430) and its wiring into `Dockerfile.example`'s
# `runtime-test` stage: non-zero exit on a missing-dep `.so`, clean-link
# pass, empty/absent-root no-ops, and the ldd-skip + accumulate-all
# behaviour (#692).

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  SMOKE_SH="/source/dist/test/bats/smoke/smoke.sh"
  SCAN_ROOT="$(mktemp -d)"
  export SCAN_ROOT
}

teardown() {
  rm -rf "${SCAN_ROOT}"
}

# ──ldd-based missing-dep detection ──────────────────────────

# why: Missing-dep failure
@test "smoke.sh exits non-zero when a .so has 'not found' dep (#430)" {
  # Create a fake .so file and a stub `ldd` that reports a missing dep.
  mkdir -p "${SCAN_ROOT}/lib"
  : > "${SCAN_ROOT}/lib/libbroken.so"
  local _stub_dir
  _stub_dir="$(mktemp -d)"
  cat > "${_stub_dir}/ldd" <<'EOS'
#!/usr/bin/env bash
# Simulate a missing shared lib for any input.
echo "    libmissing.so.1 => not found"
EOS
  chmod +x "${_stub_dir}/ldd"
  PATH="${_stub_dir}:${PATH}" run bash "${SMOKE_SH}" "${SCAN_ROOT}"
  rm -rf "${_stub_dir}"
  assert_failure
  assert_output --partial "MISSING"
}

# why: No-.so pass
@test "smoke.sh exits 0 when scan root has no .so files (#430)" {
  # Empty directory — nothing to check, no failure.
  run bash "${SMOKE_SH}" "${SCAN_ROOT}"
  assert_success
}

# why: Absent-root pass
@test "smoke.sh exits 0 when scan root does not exist (#430)" {
  # Missing dir — non-fatal, just skipped (default has multiple roots).
  run bash "${SMOKE_SH}" "${SCAN_ROOT}/nonexistent"
  assert_success
}

# why: Default cmd wiring
@test "Dockerfile.example runtime-test default RUNTIME_SMOKE_CMD calls smoke.sh (#430)" {
  # Default should invoke the helper script, not just the old
  # 'whoami && bash --version' that missed libboost_regex (ros1_bridge#123).
  run grep -E '^# ARG RUNTIME_SMOKE_CMD=.*smoke\.sh' /source/dist/dockerfile/Dockerfile
  assert_success
}

# why: COPY wiring
@test "Dockerfile.example commented runtime-test COPY brings smoke.sh into image (#430)" {
  run grep -F 'COPY' /source/dist/dockerfile/Dockerfile
  # Find the smoke.sh COPY (commented in template; downstream uncomments)
  run grep -F '.base/dist/test/bats/smoke/smoke.sh' /source/dist/dockerfile/Dockerfile
  assert_success
}

# why: Clean-link pass
@test "smoke.sh exits 0 when all .so files link cleanly (#430)" {
  mkdir -p "${SCAN_ROOT}/lib"
  : > "${SCAN_ROOT}/lib/libgood.so"
  local _stub_dir
  _stub_dir="$(mktemp -d)"
  cat > "${_stub_dir}/ldd" <<'EOS'
#!/usr/bin/env bash
echo "    libfoo.so => /usr/lib/libfoo.so (0x00007fff)"
EOS
  chmod +x "${_stub_dir}/ldd"
  PATH="${_stub_dir}:${PATH}" run bash "${SMOKE_SH}" "${SCAN_ROOT}"
  rm -rf "${_stub_dir}"
  assert_success
}

# why: ldd-fail skip
@test "smoke.sh: documented behaviour -- a .so whose ldd exits non-zero is skipped (#692)" {
  # smoke.sh does `_ldd_out="$(ldd ...)" || continue`: when ldd itself exits
  # non-zero (file not a dynamic executable, or ldd errors), that .so is
  # skipped and treated clean -- even if the output mentions 'not found'.
  # Pin this swallow as the documented behaviour (the loop trusts ldd's exit
  # status over its text); a future hardening would surface the hard error.
  mkdir -p "${SCAN_ROOT}/lib"
  : > "${SCAN_ROOT}/lib/libbroken.so"
  local _stub_dir
  _stub_dir="$(mktemp -d)"
  cat > "${_stub_dir}/ldd" <<'EOS'
#!/usr/bin/env bash
echo "    libmissing.so.1 => not found"
exit 1
EOS
  chmod +x "${_stub_dir}/ldd"
  PATH="${_stub_dir}:${PATH}" run bash "${SMOKE_SH}" "${SCAN_ROOT}"
  rm -rf "${_stub_dir}"
  assert_success
  refute_output --partial "MISSING DEP"
}

# why: Accumulate-all reporting
@test "smoke.sh: accumulates _exit=1 and reports every bad .so (#692)" {
  # Multiple libs with 'not found' deps: the loop must report ALL of them
  # (one MISSING DEP line each) and still exit non-zero once.
  mkdir -p "${SCAN_ROOT}/lib"
  : > "${SCAN_ROOT}/lib/libbad1.so"
  : > "${SCAN_ROOT}/lib/libbad2.so"
  local _stub_dir
  _stub_dir="$(mktemp -d)"
  cat > "${_stub_dir}/ldd" <<'EOS'
#!/usr/bin/env bash
echo "    libmissing.so.1 => not found"
EOS
  chmod +x "${_stub_dir}/ldd"
  PATH="${_stub_dir}:${PATH}" run bash "${SMOKE_SH}" "${SCAN_ROOT}"
  rm -rf "${_stub_dir}"
  assert_failure
  assert_equal "$(grep -c 'MISSING DEP' <<< "${output}")" "2"
}
