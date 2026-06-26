#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/setup_spec_helper"
# ════════════════════════════════════════════════════════════════════
# Subcommand dispatch (Phase B-1)
#
# setup.sh grew a git-style subcommand dispatcher so build.sh / run.sh
# stop sourcing it (which historically caused's _msg shadow bug).
# Subcommands wired in B-1: `apply` (default) + `check-drift`. Legacy
# flag-only invocation (`setup.sh --base-path X --lang Y`) still maps
# to apply for backward compat.
# ════════════════════════════════════════════════════════════════════

@test "main no-arg prints help and exits 0 (#49 Phase B-4 BREAKING)" {
  # Pre-B-4 the no-arg path silently aliased to `apply`. Now it prints
  # the same help screen as -h, so accidental invocations don't
  # clobber .env / compose.yaml without an explicit subcommand.
  run main
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "Subcommands:"
}

@test "main legacy flag-only invocation now errors (#49 Phase B-4 BREAKING)" {
  # `setup.sh --base-path X --lang Y` (no subcommand) used to alias to
  # apply. B-4 removes that; the user must type `apply` explicitly.
  run main --base-path "${TEMP_DIR}" --lang en
  assert_failure
  assert_output --partial "Unknown subcommand"
}

@test "main apply subcommand regenerates .env + compose.yaml" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  assert [ -f "${TEMP_DIR}/.env.generated" ]
  assert [ -f "${TEMP_DIR}/compose.yaml" ]
}

@test "main rejects unknown subcommand" {
  run main bogus-subcommand
  assert_failure
  assert_output --partial "Unknown subcommand"
}

@test "main check-drift returns 0 when .env missing (no-op)" {
  run main check-drift --base-path "${TEMP_DIR}"
  assert_success
}

@test "main check-drift returns 0 when nothing changed" {
  local _h=""
  _compute_conf_hash "${TEMP_DIR}" _h
  write_env "${TEMP_DIR}/.env.generated" \
    "user" "group" "$(id -u)" "$(id -g)" \
    "x86_64" "hub" "false" \
    "img" "${TEMP_DIR}" \
    "tw.archive.ubuntu.com" "mirror.twds.com.tw" "Asia/Taipei" \
    "host" "host" "private" "true" "all" "gpu" \
    "false" "${_h}" ""
  detect_gui() { local -n _o=$1; _o="false"; }
  detect_gpu() { local -n _o=$1; _o="false"; }

  run main check-drift --base-path "${TEMP_DIR}"
  assert_success
}

@test "main check-drift returns non-zero when conf hash drifts" {
  local _h_old=""
  _compute_conf_hash "${TEMP_DIR}" _h_old
  write_env "${TEMP_DIR}/.env.generated" \
    "user" "group" "$(id -u)" "$(id -g)" \
    "x86_64" "hub" "false" \
    "img" "${TEMP_DIR}" \
    "tw.archive.ubuntu.com" "mirror.twds.com.tw" "Asia/Taipei" \
    "host" "host" "private" "true" "all" "gpu" \
    "false" "${_h_old}" ""
  detect_gui() { local -n _o=$1; _o="false"; }
  detect_gpu() { local -n _o=$1; _o="false"; }

  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gpu]
mode = off
EOF

  run main check-drift --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "drift detected"
}

@test "check-drift prints WARN when per-repo setup.conf is missing (#186)" {
  # No TEMP_DIR/config/docker/setup.conf created — check-drift should announce the
  # template-default fallback the same way `apply` does, so users
  # running the build.sh drift-check path see the heads-up too.
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main check-drift --base-path '${TEMP_DIR}' 2>&1
  "
  assert_output --partial "[setup] WARN :"
  assert_output --partial "no per-repo setup.conf"
}

@test "check-drift prints WARN when per-repo setup.conf has no section headers (#186)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
# only comments, no [section] headers
EOF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main check-drift --base-path '${TEMP_DIR}' 2>&1
  "
  assert_output --partial "[setup] WARN :"
  assert_output --partial "per-repo setup.conf has no section"
}

@test "check-drift stays silent when per-repo setup.conf has at least one section" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gpu]
mode = auto
EOF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main check-drift --base-path '${TEMP_DIR}' 2>&1
  "
  refute_output --partial "no per-repo setup.conf"
  refute_output --partial "per-repo setup.conf has no section"
}

@test "check-drift --lang zh-TW prints WARN in Traditional Chinese when setup.conf missing (#186)" {
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main check-drift --base-path '${TEMP_DIR}' --lang zh-TW 2>&1
  "
  assert_output --partial "[setup] WARN :"
  assert_output --partial "未找到"
}

@test "main check-drift rejects unknown flag" {
  run main check-drift --bogus
  assert_failure
  assert_output --partial "Unknown argument"
}

@test "setup.sh check-drift via subprocess emits stderr + non-zero exit on drift" {
  # End-to-end: invoke the script as a subprocess (the way build.sh / run.sh
  # do after B-1) instead of `source` + function call. Validates the
  # subcommand dispatch path actually works when the script is executed.
  mkdir -p "${TEMP_DIR}/sandbox/.base/dist/script/docker/lib" \
           "${TEMP_DIR}/sandbox/.base/dist/script/docker/wrapper" \
           "${TEMP_DIR}/sandbox/.base/dist/config/docker"
  cp /source/dist/script/docker/wrapper/setup.sh "${TEMP_DIR}/sandbox/.base/dist/script/docker/wrapper/setup.sh"
  cp /source/dist/script/docker/lib/i18n.sh "${TEMP_DIR}/sandbox/.base/dist/script/docker/lib/i18n.sh"
  cp /source/dist/script/docker/lib/_tui_conf.sh "${TEMP_DIR}/sandbox/.base/dist/script/docker/lib/_tui_conf.sh"
  # setup.sh sources _lib.sh for the _log_* helpers; _lib.sh
  # is an umbrella that sources lib/*.sh sub-libs
  cp /source/dist/script/docker/lib/_lib.sh "${TEMP_DIR}/sandbox/.base/dist/script/docker/lib/_lib.sh"
  cp /source/dist/script/docker/lib/* "${TEMP_DIR}/sandbox/.base/dist/script/docker/lib/"
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/sandbox/.base/dist/config/docker/setup.conf"

  bash "${TEMP_DIR}/sandbox/.base/dist/script/docker/wrapper/setup.sh" apply \
    --base-path "${TEMP_DIR}/sandbox" >/dev/null 2>&1

  # drift hash covers template + setup.conf. Mutating .local
  # after apply triggers detection.
  cat > "${TEMP_DIR}/sandbox/config/docker/setup.conf" <<'EOF'
[gpu]
mode = off
EOF

  run bash "${TEMP_DIR}/sandbox/.base/dist/script/docker/wrapper/setup.sh" \
    check-drift --base-path "${TEMP_DIR}/sandbox"
  assert_failure
  assert_output --partial "drift detected"
}

# ════════════════════════════════════════════════════════════════════
# Subcommand: set / show / list (Phase B-2)
#
# `setup.sh set <section>.<key> <value>` writes to setup.conf via
# `_upsert_conf_value` (no .env regen — `apply` is the explicit gate).
# `show` and `list` read setup.conf via `_load_setup_conf_full` so
# they share the TUI's view of the file.
# ════════════════════════════════════════════════════════════════════

@test "set writes a value into an existing section, round-trip via show" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set deploy.gpu_count all --base-path "${TEMP_DIR}"
  assert_success
  run main show deploy.gpu_count --base-path "${TEMP_DIR}"
  assert_success
  assert_output "all"
}

@test "set creates a new key when section exists but key is absent" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[network]
mode = host
EOF
  run main set network.privileged true --base-path "${TEMP_DIR}"
  assert_success
  run main show network.privileged --base-path "${TEMP_DIR}"
  assert_success
  assert_output "true"
}

@test "set creates section + key when section is absent" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[image]
rule_1 = @basename
EOF
  run main set resources.shm_size 512m --base-path "${TEMP_DIR}"
  assert_success
  run main show resources.shm_size --base-path "${TEMP_DIR}"
  assert_success
  assert_output "512m"
}

@test "set rejects an unknown section with non-zero exit + Unknown section stderr" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set bogus.key value --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Unknown section"
}

@test "set rejects an invalid gpu_count value" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set deploy.gpu_count -1 --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "set rejects an invalid mount string" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set volumes.mount_5 not-a-mount --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "set rejects an invalid cgroup_rule" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set devices.cgroup_rule_1 "garbage rule" --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "set rejects an invalid env_kv" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set environment.env_5 "missing-equals" --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "set rejects an invalid port mapping" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set network.port_5 "abc:def" --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

# ──────────────────────────────────────────────────────────────────
# setup.sh routes through the shared schema registry, so `set` /
# `add` now reject the same values the TUI already rejected. These keys
# were historically free-form in setup.sh (the divergence closes).
# ──────────────────────────────────────────────────────────────────

@test "set rejects an invalid target_arch (#560 schema unification)" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set build.target_arch sparc --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "set rejects an invalid build network (#560 schema unification)" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set build.network carrier-pigeon --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "set rejects an invalid gpu_runtime (#560 schema unification)" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set deploy.gpu_runtime podman --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "set rejects an invalid network_name (#560 schema unification)" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set network.network_name "-bad" --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "set rejects an invalid device mount (#560 schema unification)" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set devices.device_1 noslash --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "add rejects an invalid capability (#560 schema unification)" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main add security.cap_add lowercase --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "set rejects a malformed dotted key (no dot)" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set deploy_gpu_count all --base-path "${TEMP_DIR}"
  assert_failure
}

@test "set rejects a newline-bearing value rather than corrupting setup.conf (#688)" {
  # _validate_env_kv accepts an embedded newline (regex `.*$` matches up
  # to a newline), so a value like $'A=b\nstray' passes validation. Left
  # unguarded, _upsert_conf_value's `printf '%s = %s\n'` would write the
  # stray second line as an orphan, un-keyed entry that corrupts the INI
  # on the next read. The writer must refuse such a value loudly; the
  # file must keep exactly one env_1 line and gain no orphan line.
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[environment]
env_1 = A=b
EOF
  run main set environment.env_1 $'BAZ=qux\nmalicious_section_break' --base-path "${TEMP_DIR}"
  assert_failure
  # No orphan line: the corrupting payload must not reach the file.
  run grep -c 'malicious_section_break' "${TEMP_DIR}/config/docker/setup.conf"
  assert_output "0"
  # The original clean value is untouched.
  run grep -c '^env_1 = A=b$' "${TEMP_DIR}/config/docker/setup.conf"
  assert_output "1"
}

@test "set with no arguments fails clean (no shell error)" {
  run main set
  assert_failure
  refute_output --partial "unbound variable"
  refute_output --partial "syntax error"
}

@test "set does NOT regenerate .env (mtime unchanged after set)" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  # Seed .env via apply so it exists.
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
  "
  assert_success
  assert [ -f "${TEMP_DIR}/.env.generated" ]
  local _before
  _before="$(stat -c %Y "${TEMP_DIR}/.env.generated")"
  # Wait one second so mtime resolution can register a difference if regen happened.
  sleep 1
  run main set network.mode host --base-path "${TEMP_DIR}"
  assert_success
  local _after
  _after="$(stat -c %Y "${TEMP_DIR}/.env.generated")"
  assert_equal "${_before}" "${_after}"
}

@test "show prints the value of a single key" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[network]
mode = host
ipc = host
EOF
  run main show network.mode --base-path "${TEMP_DIR}"
  assert_success
  assert_output "host"
}

@test "show prints all entries of a whole section in on-disk order" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[network]
mode = host
ipc = host
privileged = true
EOF
  run main show network --base-path "${TEMP_DIR}"
  assert_success
  assert_line --index 0 "mode = host"
  assert_line --index 1 "ipc = host"
  assert_line --index 2 "privileged = true"
}

@test "show returns non-zero on a missing key" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[network]
mode = host
EOF
  run main show network.nope --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "not found"
}

@test "show falls back to template baseline when section absent in .local (#174)" {
  # this test asserted that show fails when the requested
  # section is missing from the per-repo file. Now show reads
  # the merged view (template ← .local), so the template baseline
  # always provides the section even when .local omits it. Switching
  # the assertion: show succeeds and surfaces the template's keys.
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[network]
mode = host
EOF
  run main show resources --base-path "${TEMP_DIR}"
  assert_success
  assert_output --partial "shm_size"
}

@test "show rejects an unknown section name" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main show bogus.key --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Unknown section"
}

@test "show with no arguments fails clean" {
  run main show
  assert_failure
}

@test "list with no arg prints every section header + key" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[image]
rule_1 = @basename

[network]
mode = host
ipc = host
EOF
  run main list --base-path "${TEMP_DIR}"
  assert_success
  assert_output --partial "[image]"
  assert_output --partial "rule_1 = @basename"
  assert_output --partial "[network]"
  assert_output --partial "mode = host"
}

@test "list <section> mirrors show <section>" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[network]
mode = host
ipc = host
EOF
  run main list network --base-path "${TEMP_DIR}"
  assert_success
  assert_line --index 0 "mode = host"
  assert_line --index 1 "ipc = host"
}

@test "list <section> rejects an unknown section" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main list bogus --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Unknown section"
}

@test "set / show / list run end-to-end via subprocess" {
  mkdir -p "${TEMP_DIR}/sandbox/.base/dist/script/docker/lib" \
           "${TEMP_DIR}/sandbox/.base/dist/script/docker/wrapper" \
           "${TEMP_DIR}/sandbox/config/docker"
  cp /source/dist/script/docker/wrapper/setup.sh "${TEMP_DIR}/sandbox/.base/dist/script/docker/wrapper/setup.sh"
  cp /source/dist/script/docker/lib/i18n.sh "${TEMP_DIR}/sandbox/.base/dist/script/docker/lib/i18n.sh"
  cp /source/dist/script/docker/lib/_tui_conf.sh "${TEMP_DIR}/sandbox/.base/dist/script/docker/lib/_tui_conf.sh"
  # setup.sh sources _lib.sh for the _log_* helpers; _lib.sh
  # is an umbrella that sources lib/*.sh sub-libs
  cp /source/dist/script/docker/lib/_lib.sh "${TEMP_DIR}/sandbox/.base/dist/script/docker/lib/_lib.sh"
  cp /source/dist/script/docker/lib/* "${TEMP_DIR}/sandbox/.base/dist/script/docker/lib/"
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/sandbox/config/docker/setup.conf"

  run bash "${TEMP_DIR}/sandbox/.base/dist/script/docker/wrapper/setup.sh" \
    set network.mode bridge --base-path "${TEMP_DIR}/sandbox"
  assert_success

  run bash "${TEMP_DIR}/sandbox/.base/dist/script/docker/wrapper/setup.sh" \
    show network.mode --base-path "${TEMP_DIR}/sandbox"
  assert_success
  assert_output "bridge"
}

# ════════════════════════════════════════════════════════════════════
# Subcommand: add / remove (Phase B-3)
#
# `setup.sh add <section>.<list> <value>` finds the next `<list>_N`
# (max+1) and writes via `_upsert_conf_value`.
# `setup.sh remove <section>.<key>` deletes a single keyed entry.
# `setup.sh remove <section>.<list> <value>` deletes the first key
# under <section> matching `<list>_*` whose value equals <value>.
# Validators wired through the same `_setup_validate_kv` table B-2
# uses for `set`. No .env regen — `apply` is still the explicit gate.
# ════════════════════════════════════════════════════════════════════

@test "main add appends mount to next available slot" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[volumes]
mount_1 = /a:/a
EOF
  run main add volumes.mount /b:/b --base-path "${TEMP_DIR}"
  assert_success
  run main show volumes.mount_2 --base-path "${TEMP_DIR}"
  assert_success
  assert_output "/b:/b"
}

@test "main add to empty section creates _1" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[environment]
EOF
  run main add environment.env FOO=bar --base-path "${TEMP_DIR}"
  assert_success
  run main show environment.env_1 --base-path "${TEMP_DIR}"
  assert_success
  assert_output "FOO=bar"
}

@test "main add bootstraps setup.conf empty when missing (#174)" {
  rm -f "${TEMP_DIR}/config/docker/setup.conf" "${TEMP_DIR}/config/docker/setup.conf"
  run main add volumes.mount /foo:/bar --base-path "${TEMP_DIR}"
  assert_success
  assert [ -f "${TEMP_DIR}/config/docker/setup.conf" ]
  # show reads template ← .local merge; the new mount lands in .local
  # and the merged view surfaces it through the next mount_<N> slot.
  run main show volumes.mount_1 --base-path "${TEMP_DIR}"
  assert_success
  assert_output --partial "/foo:/bar"
}

@test "main add picks max+1 even with gap from prior remove" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[volumes]
mount_1 = /a:/a
mount_3 = /c:/c
EOF
  run main add volumes.mount /d:/d --base-path "${TEMP_DIR}"
  assert_success
  run main show volumes.mount_4 --base-path "${TEMP_DIR}"
  assert_success
  assert_output "/d:/d"
}

@test "main add rejects unknown section" {
  : > "${TEMP_DIR}/config/docker/setup.conf"
  run main add bogus.list /a:/a --base-path "${TEMP_DIR}"
  assert_failure
  [[ "${status}" -eq 2 ]]
  assert_output --partial "Unknown section"
}

@test "main add rejects invalid mount value" {
  : > "${TEMP_DIR}/config/docker/setup.conf"
  run main add volumes.mount not-a-mount --base-path "${TEMP_DIR}"
  assert_failure
  [[ "${status}" -eq 2 ]]
}

@test "main add rejects missing list / value" {
  run main add --base-path "${TEMP_DIR}"
  assert_failure
  run main add volumes.mount --base-path "${TEMP_DIR}"
  assert_failure
}

@test "main add does not regen .env" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[volumes]
mount_1 = /a:/a
EOF
  : > "${TEMP_DIR}/.env.generated"
  local _before
  _before="$(stat -c '%Y' "${TEMP_DIR}/.env.generated")"
  sleep 1
  run main add volumes.mount /b:/b --base-path "${TEMP_DIR}"
  assert_success
  local _after
  _after="$(stat -c '%Y' "${TEMP_DIR}/.env.generated")"
  assert_equal "${_before}" "${_after}"
}

@test "main remove drops keyed entry" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[volumes]
mount_1 = /a:/a
mount_2 = /b:/b
EOF
  run main remove volumes.mount_1 --base-path "${TEMP_DIR}"
  assert_success
  run main show volumes.mount_1 --base-path "${TEMP_DIR}"
  assert_failure
  run main show volumes.mount_2 --base-path "${TEMP_DIR}"
  assert_success
  assert_output "/b:/b"
}

@test "main remove by value finds matching key in list" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[volumes]
mount_1 = /a:/a
mount_2 = /b:/b
mount_3 = /c:/c
EOF
  run main remove volumes.mount /b:/b --base-path "${TEMP_DIR}"
  assert_success
  run main show volumes.mount_2 --base-path "${TEMP_DIR}"
  assert_failure
  run main show volumes.mount_1 --base-path "${TEMP_DIR}"
  assert_success
  assert_output "/a:/a"
}

@test "main remove fails when key missing" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[volumes]
mount_1 = /a:/a
EOF
  run main remove volumes.mount_99 --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "not found"
}

@test "main remove by value fails when no value matches" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[volumes]
mount_1 = /a:/a
EOF
  run main remove volumes.mount /nonexistent:/x --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "not found"
}

@test "main remove rejects unknown section" {
  : > "${TEMP_DIR}/config/docker/setup.conf"
  run main remove bogus.key --base-path "${TEMP_DIR}"
  assert_failure
  [[ "${status}" -eq 2 ]]
  assert_output --partial "Unknown section"
}

@test "main remove preserves comments + remaining keys" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
# Top-of-file comment
[volumes]
# inline comment
mount_1 = /a:/a
mount_2 = /b:/b

[network]
mode = host
EOF
  run main remove volumes.mount_1 --base-path "${TEMP_DIR}"
  assert_success
  # remove modifies setup.conf in-place; comments and
  # untouched keys survive the rewrite.
  run cat "${TEMP_DIR}/config/docker/setup.conf"
  assert_output --partial "Top-of-file comment"
  assert_output --partial "inline comment"
  assert_output --partial "mount_2 = /b:/b"
  assert_output --partial "mode = host"
  refute_output --partial "mount_1"
}

@test "main add then remove round-trips" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[environment]
EOF
  run main add environment.env FOO=bar --base-path "${TEMP_DIR}"
  assert_success
  run main add environment.env BAZ=qux --base-path "${TEMP_DIR}"
  assert_success
  run main show environment --base-path "${TEMP_DIR}"
  assert_success
  assert_output --partial "env_1 = FOO=bar"
  assert_output --partial "env_2 = BAZ=qux"
  run main remove environment.env_1 --base-path "${TEMP_DIR}"
  assert_success
  run main add environment.env NEW=val --base-path "${TEMP_DIR}"
  assert_success
  run main show environment.env_3 --base-path "${TEMP_DIR}"
  assert_success
  assert_output "NEW=val"
}

@test "main add validates env_kv format" {
  : > "${TEMP_DIR}/config/docker/setup.conf"
  run main add environment.env "no-equals-sign" --base-path "${TEMP_DIR}"
  assert_failure
  [[ "${status}" -eq 2 ]]
}

@test "main add free-form image rule accepts arbitrary string" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[image]
rule_1 = @basename
EOF
  run main add image.rule "prefix:my_" --base-path "${TEMP_DIR}"
  assert_success
  run main show image.rule_2 --base-path "${TEMP_DIR}"
  assert_success
  assert_output "prefix:my_"
}

# ════════════════════════════════════════════════════════════════════
# Subcommand: reset (Phase B-4)
#
# `setup.sh reset [--yes]` overwrites <base-path>/config/docker/setup.conf with the
# template default. Existing setup.conf → setup.conf.bak; existing
# .env → .env.bak (one-shot rollback path). Does NOT regenerate .env
# — the user invokes apply afterwards, or build/run will trigger
# auto-regen via drift detection on next run. --yes skips the
# interactive confirmation prompt; non-tty without --yes refuses to
# proceed (safety guard against accidental invocation in pipelines).
# ════════════════════════════════════════════════════════════════════

@test "main reset --yes clears setup.conf + setup.conf so next apply rebuilds (#174)" {
  mkdir -p "${TEMP_DIR}/.base/dist/config/docker"
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/.base/dist/config/docker/setup.conf"
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
# user-customized
[network]
mode = bridge
EOF
  : > "${TEMP_DIR}/config/docker/setup.conf"
  run bash -c "
    _SETUP_SCRIPT_DIR='${TEMP_DIR}/.base/script/docker'
    mkdir -p \"\${_SETUP_SCRIPT_DIR}\"
    source /source/dist/script/docker/wrapper/setup.sh
    main reset --yes --base-path '${TEMP_DIR}'
  "
  assert_success
  # Override + materialized snapshot both removed — the next apply will
  # rebuild setup.conf purely from the template baseline.
  refute [ -f "${TEMP_DIR}/config/docker/setup.conf" ]
  refute [ -f "${TEMP_DIR}/config/docker/setup.conf" ]
}

@test "main reset --yes backs up prior setup.conf to .local.bak (#174)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
# CUSTOM_MARKER
[network]
mode = bridge
EOF
  run main reset --yes --base-path "${TEMP_DIR}"
  assert_success
  assert [ -f "${TEMP_DIR}/config/docker/setup.conf.bak" ]
  run grep CUSTOM_MARKER "${TEMP_DIR}/config/docker/setup.conf.bak"
  assert_success
}

@test "main reset --yes backs up prior .env.generated to .env.generated.bak" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  printf 'IMAGE_NAME=customimg\n' > "${TEMP_DIR}/.env.generated"
  run main reset --yes --base-path "${TEMP_DIR}"
  assert_success
  assert [ -f "${TEMP_DIR}/.env.generated.bak" ]
  run grep "IMAGE_NAME=customimg" "${TEMP_DIR}/.env.generated.bak"
  assert_success
}

@test "main reset --yes does NOT regenerate .env" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  : > "${TEMP_DIR}/.env.generated"
  local _before
  _before="$(stat -c '%Y' "${TEMP_DIR}/.env.generated")"
  sleep 1
  run main reset --yes --base-path "${TEMP_DIR}"
  assert_success
  # Either .env still has its prior mtime (file untouched), or it was
  # moved to .env.bak — but a fresh derived .env should NOT exist yet.
  if [[ -f "${TEMP_DIR}/.env.generated" ]]; then
    local _after
    _after="$(stat -c '%Y' "${TEMP_DIR}/.env.generated")"
    assert_equal "${_before}" "${_after}"
  fi
}

@test "main reset without --yes refuses non-tty (no confirmation possible)" {
  cp /source/dist/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  # Bats runs without a controlling TTY — without --yes the handler
  # must refuse rather than silently destroy state.
  run main reset --base-path "${TEMP_DIR}"
  assert_failure
  refute [ -f "${TEMP_DIR}/config/docker/setup.conf.bak" ]
}

@test "main reset rejects unknown flag" {
  run main reset --bogus --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Unknown argument"
}

