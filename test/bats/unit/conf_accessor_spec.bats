#!/usr/bin/env bats
#
# Unit tests for the conf.sh opaque accessor interface.
#
# The accessor verbs (_conf_load / _conf_get / _conf_list / _conf_sections)
# hide conf.sh's internal parallel-array + namespacing representation: callers
# load a handle once and query it by (section, key) without touching arrays.
#
# why: Unit tests for the `conf.sh` opaque accessor interface (#564 / #563):
# `_conf_load` loads a file into a named handle, `_conf_get` reads a value
# by (section, key) with an optional default, `_conf_sections` lists section
# names, `_conf_list` lists a section's keys, `_conf_load_merged` loads a
# template+repo section-replace merge into a handle, and `_conf_list_sorted`
# returns `prefix_N` values in numeric order (skipping empties) -- all
# without callers touching the internal parallel-array representation or the
# `<section>.<key>` namespacing rule. Also the low-level INI reader the
# accessor is built on: `_parse_ini_section` (per-section key/value
# extraction, section isolation, comment/whitespace handling, dotted
# sub-sections, duplicate/reopened sections) and the shared single-pass core
# `_ini_tokenize` (relocated here from `setup_spec` in P1b, #758 -- they
# test `lib/conf.sh`).
#
# Dirty-input + error-path coverage (#689) pins the parser/accessor
# contracts on hand-edited / malformed setup.conf:

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  # shellcheck source=dist/script/docker/lib/conf.sh
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/conf.sh
  FIX="$(mktemp)"
  cat > "${FIX}" <<'EOF'
[deploy]
gpu_runtime = auto
gpu_count = 2

[network]
net = host
EOF
  # The _parse_ini_section / _ini_tokenize specs write fixtures under
  # ${TEMP_DIR}/config/docker/; mirror the path setup the shared
  # setup_spec_helper provides so those tests resolve their conf files.
  TEMP_DIR="$(mktemp -d)"
  mkdir -p "${TEMP_DIR}"
}

teardown() {
  rm -f "${FIX}"
  rm -rf "${TEMP_DIR}"
}

@test "_conf_get returns a value by section and key" {
  _conf_load "${FIX}" H
  run _conf_get H deploy gpu_runtime
  assert_success
  assert_output "auto"
}

@test "_conf_get_into writes the value into the named outvar, no subshell (#742)" {
  # Outvar variant of _conf_get: lets a hot resolver read many keys from one
  # parsed handle without a $() fork per lookup. Same lookup + default
  # semantics as _conf_get.
  _conf_load "${FIX}" H
  local _v="sentinel"
  _conf_get_into H deploy gpu_runtime "" _v
  assert_equal "${_v}" "auto"
  # default applies when the key is absent
  _conf_get_into H deploy nope "fallback" _v
  assert_equal "${_v}" "fallback"
}

@test "_conf_sections lists section names in first-appearance order" {
  _conf_load "${FIX}" H
  run _conf_sections H
  assert_success
  assert_line --index 0 "deploy"
  assert_line --index 1 "network"
}

@test "_conf_list lists a section's keys in file order" {
  _conf_load "${FIX}" H
  run _conf_list H deploy
  assert_success
  assert_line --index 0 "gpu_runtime"
  assert_line --index 1 "gpu_count"
}

@test "_conf_load_merged: repo section replaces template section wholesale" {
  local _tpl _repo
  _tpl="$(mktemp)"; _repo="$(mktemp)"
  cat > "${_tpl}" <<'EOF'
[deploy]
gpu_runtime = auto
gpu_count = 0

[build]
arg_1 = FROM_TEMPLATE
EOF
  cat > "${_repo}" <<'EOF'
[deploy]
gpu_runtime = nvidia
EOF
  _conf_load_merged "${_tpl}" "${_repo}" M
  run _conf_get M deploy gpu_runtime
  assert_success
  assert_output "nvidia"
  run _conf_get M deploy gpu_count missing
  assert_output "missing"
  run _conf_get M build arg_1
  assert_output "FROM_TEMPLATE"
  rm -f "${_tpl}" "${_repo}"
}

# why: Override semantics (merge + re-save)
@test "_conf_get: duplicate key within a section -- last occurrence wins (#689)" {
  # _conf_get documents 'Last occurrence wins (override semantics)'. The
  # setup.conf merge + re-save legitimately produce duplicate keys within
  # one section, so this is load-bearing. Pin it so a regression returning
  # the FIRST value (or concatenating) is caught.
  local _f
  _f="$(mktemp)"
  cat > "${_f}" <<'EOF'
[deploy]
gpu_runtime = auto
gpu_runtime = nvidia
EOF
  _conf_load "${_f}" H
  run _conf_get H deploy gpu_runtime
  assert_success
  assert_output "nvidia"
  rm -f "${_f}"
}

# why: Reopened section appends; header deduped
@test "_conf_list: a section reopened later in the file keeps entries from both occurrences (#689)" {
  # A reopened [deploy] header appends to the same section. _conf_load /
  # _conf_list must surface keys from both occurrences in file order.
  local _f
  _f="$(mktemp)"
  cat > "${_f}" <<'EOF'
[deploy]
gpu_runtime = auto

[network]
net = host

[deploy]
gpu_count = 2
EOF
  _conf_load "${_f}" H
  run _conf_list H deploy
  assert_success
  assert_line --index 0 "gpu_runtime"
  assert_line --index 1 "gpu_count"
  # Section header is deduped (listed once).
  run _conf_sections H
  assert_line --index 0 "deploy"
  assert_line --index 1 "network"
  assert_equal "${#lines[@]}" 2
  rm -f "${_f}"
}

# why: Trailing `# ...` is literal (only leading-# stripped)
@test "_conf_get: inline '#' comment text is KEPT in the value (no inline-comment support) (#689)" {
  # _ini_tokenize strips only lines that START with optional-ws-then-#
  # (conf.sh leading-# rule); a TRAILING inline comment is NOT stripped.
  # Inline comments are intentionally unsupported, so the literal value
  # (including ` # ...`) is the pinned contract -- a future 'fix' to strip
  # inline comments would then be a conscious, test-breaking choice.
  local _f
  _f="$(mktemp)"
  cat > "${_f}" <<'EOF'
[deploy]
gpu_runtime = nvidia # use jetson
EOF
  _conf_load "${_f}" H
  run _conf_get H deploy gpu_runtime
  assert_success
  assert_output "nvidia # use jetson"
  rm -f "${_f}"
}

# why: Interior spaces kept in captured name
@test "_conf_sections: section header with internal whitespace is NOT trimmed ([ deploy ] != deploy) (#689)" {
  # The greedy `^\[(.+)\]$` capture runs AFTER trimming the whole line,
  # but only the LINE's outer whitespace is trimmed -- the captured name
  # keeps interior spaces. So `[ deploy ]` yields section ` deploy ` and
  # silently does NOT match `deploy`. Pin so a hand-edited stray space is
  # a known (surfaceable) failure, not a silent surprise.
  local _f
  _f="$(mktemp)"
  cat > "${_f}" <<'EOF'
[ deploy ]
gpu_runtime = auto
EOF
  _conf_load "${_f}" H
  run _conf_sections H
  assert_success
  assert_output " deploy "
  # The canonical name does not resolve...
  run _conf_get H deploy gpu_runtime MISS
  assert_output "MISS"
  # ...only the spaced literal does.
  run _conf_get H " deploy " gpu_runtime MISS
  assert_output "auto"
  rm -f "${_f}"
}

# why: No header match -> keys lost, no crash
@test "_conf_load: an unterminated section header ([deploy without ]) drops its keys (#689)" {
  # A line missing its closing bracket is not a header match and (having
  # no `=`) is not a key line either, so it is dropped -- and because no
  # section is open, every key under it is lost. Pin this so a hand-edited
  # dropped bracket is a known behaviour: the keys vanish (no section,
  # no crash) rather than silently attaching somewhere.
  local _f
  _f="$(mktemp)"
  cat > "${_f}" <<'EOF'
[deploy
gpu_runtime = auto
gpu_count = 2
EOF
  _conf_load "${_f}" H
  # No section was opened.
  run _conf_sections H
  assert_success
  assert_output ""
  # Keys under the broken header are lost (treated as pre-section lines).
  run _conf_get H deploy gpu_runtime MISS
  assert_output "MISS"
  rm -f "${_f}"
}

@test "_conf_list_sorted returns prefix_N values in numeric order, skipping empties" {
  local _f
  _f="$(mktemp)"
  cat > "${_f}" <<'EOF'
[volumes]
mount_2 = b
mount_10 = c
mount_1 = a
mount_3 =
EOF
  _conf_load "${_f}" H
  local -a out=()
  _conf_list_sorted H volumes mount_ out
  assert_equal "${#out[@]}" 3
  assert_equal "${out[0]}" a
  assert_equal "${out[1]}" b
  assert_equal "${out[2]}" c
  rm -f "${_f}"
}

# why: Numeric-suffix guard reject path
@test "_conf_list_sorted skips non-numeric list suffixes (mount_x / mount_ / mount_2b) (#689)" {
  # The `=~ ^[0-9]+$` guard's reject path: a user/template typo like
  # `mount_abc`, a bare `mount_` (empty suffix), or `mount_2b` (trailing
  # junk) must be SKIPPED, not crash or be mis-sorted into the numeric
  # set. Pin so a regression dropping the numeric guard (which would feed
  # `mount_abc:val` into `sort -t: -k1,1n` and silently misorder) is
  # caught.
  local _f
  _f="$(mktemp)"
  cat > "${_f}" <<'EOF'
[volumes]
mount_2 = b
mount_x = junk
mount_1 = a
mount_ = bare
mount_2b = bad
mount_3 = c
EOF
  _conf_load "${_f}" H
  local -a out=()
  _conf_list_sorted H volumes mount_ out
  assert_equal "${#out[@]}" 3
  assert_equal "${out[0]}" a
  assert_equal "${out[1]}" b
  assert_equal "${out[2]}" c
  rm -f "${_f}"
}

# ── Destructive-failure guards for the INI writers ─────────────────────────
#
# Both writers must fail SAFELY: a failed temp-file creation (read-only
# dir / no inodes) or a mid-write error must never clobber or truncate
# the user's existing setup.conf. conf.sh references _log_err but does
# not define it (it is provided by the umbrella _lib.sh loader in
# production), so these tests stub it locally to capture the diagnostic.

# why: Guarded mktemp -> no clobber/truncate on temp-create failure
@test "_upsert_conf_value leaves the original file intact when mktemp fails (#700)" {
  # Skipped under kcov: the test overrides `mktemp` with a failing shell
  # function inside the sourced shell to simulate a no-inodes / read-only
  # temp-file creation; kcov's instrumentation perturbs that path.
  [ "${COVERAGE:-0}" = 1 ] && skip "mktemp-failure stub is kcov-fragile (#613)"

  local _f
  _f="$(mktemp)"
  cat > "${_f}" <<'EOF'
[volumes]
mount_1 = /a:/b
EOF
  local _orig
  _orig="$(cat "${_f}")"

  # Force the writer's internal `mktemp "${_file}.XXXXXX"` to fail without
  # touching the real filesystem. The bare `mktemp -d`-style fixture call
  # above already ran, so override only for the writer invocation.
  run bash -c "
    source /source/dist/script/docker/lib/conf.sh
    _log_err() { printf 'ERR: %s\n' \"\${*:3}\" >&2; }
    mktemp() { return 1; }
    _upsert_conf_value '${_f}' volumes mount_1 /c:/d
  "
  assert_failure
  assert_output --partial "cannot create temp file"
  # The original file must survive completely unchanged (not truncated).
  run cat "${_f}"
  assert_output "${_orig}"
  rm -f "${_f}"
}

# why: Temp+atomic-mv -> no in-place truncate data-loss window
@test "_write_setup_conf leaves the destination intact when its temp file cannot be created (#700)" {
  # Skipped under kcov: overrides `mktemp` with a failing shell function
  # to simulate temp-file-creation failure.
  [ "${COVERAGE:-0}" = 1 ] && skip "mktemp-failure stub is kcov-fragile (#613)"

  local _tpl _dst
  _tpl="$(mktemp)"
  _dst="$(mktemp)"
  cat > "${_tpl}" <<'EOF'
[deploy]
gpu_runtime = auto
EOF
  cat > "${_dst}" <<'EOF'
[deploy]
gpu_runtime = nvidia
EOF
  local _orig
  _orig="$(cat "${_dst}")"

  run bash -c "
    source /source/dist/script/docker/lib/conf.sh
    _log_err() { printf 'ERR: %s\n' \"\${*:3}\" >&2; }
    mktemp() { return 1; }
    declare -a _keys=() _values=()
    _write_setup_conf '${_dst}' '${_tpl}' _keys _values
  "
  assert_failure
  assert_output --partial "cannot create temp file"
  # The destination must NOT be truncated by an in-place `: > dst`.
  run cat "${_dst}"
  assert_output "${_orig}"
  rm -f "${_tpl}" "${_dst}"
}

# ── Atomic-mv failure guards for the INI writers ───────────────────────────
#
# The full rewrite goes to a sibling temp; the final `mv tmp dst` is what
# makes it visible. A failed mv (e.g. dst on a read-only mount) must NOT
# leave the orphan temp behind silently AND must surface a clear error,
# while the original file stays untouched. Stub `mv` to fail.

# why: Failed atomic mv -> orphan temp removed + error logged + original
# unchanged
@test "_upsert_conf_value cleans the orphan temp + errors when the final mv fails (#702)" {
  # Skipped under kcov: overrides `mv` with a failing shell function to
  # simulate a read-only destination; kcov's instrumentation perturbs
  # that stub path.
  [ "${COVERAGE:-0}" = 1 ] && skip "mv-failure stub is kcov-fragile (#613)"

  local _f
  _f="$(mktemp)"
  cat > "${_f}" <<'EOF'
[volumes]
mount_1 = /a:/b
EOF
  local _orig
  _orig="$(cat "${_f}")"

  run bash -c "
    source /source/dist/script/docker/lib/conf.sh
    _log_err() { printf 'ERR: %s\n' \"\${*:3}\" >&2; }
    mv() { return 1; }
    _upsert_conf_value '${_f}' volumes mount_1 /c:/d
  "
  assert_failure
  assert_output --partial "could not replace"
  # The original file must survive completely unchanged.
  run cat "${_f}"
  assert_output "${_orig}"
  # No orphan temp left next to the destination.
  run bash -c "ls '${_f}'.* 2>/dev/null | wc -l"
  assert_output "0"
  rm -f "${_f}"
}

# why: Failed atomic mv -> orphan temp removed + error logged + destination
# unchanged
@test "_write_setup_conf cleans the orphan temp + errors when the final mv fails (#702)" {
  # Skipped under kcov: overrides `mv` with a failing shell function to
  # simulate a read-only destination.
  [ "${COVERAGE:-0}" = 1 ] && skip "mv-failure stub is kcov-fragile (#613)"

  local _tpl _dst
  _tpl="$(mktemp)"
  _dst="$(mktemp)"
  cat > "${_tpl}" <<'EOF'
[deploy]
gpu_runtime = auto
EOF
  cat > "${_dst}" <<'EOF'
[deploy]
gpu_runtime = nvidia
EOF
  local _orig
  _orig="$(cat "${_dst}")"

  run bash -c "
    source /source/dist/script/docker/lib/conf.sh
    _log_err() { printf 'ERR: %s\n' \"\${*:3}\" >&2; }
    mv() { return 1; }
    declare -a _keys=() _values=()
    _write_setup_conf '${_dst}' '${_tpl}' _keys _values
  "
  assert_failure
  assert_output --partial "could not replace"
  # The destination must survive completely unchanged.
  run cat "${_dst}"
  assert_output "${_orig}"
  # No orphan temp left next to the destination.
  run bash -c "ls '${_dst}'.* 2>/dev/null | wc -l"
  assert_output "0"
  rm -f "${_tpl}" "${_dst}"
}

# why: The rewrite comes from a bare mktemp (0600) and takes the
# destination's mode just before the mv (base#1356). When that chmod
# fails, landing the rewrite anyway would leave the user's setup.toml at
# 0600 -- the very defect the chmod is there to stop. The replacement is
# abandoned instead: the destination keeps its bytes and its mode, the
# temp is removed, and the writer reports failure.
@test "_upsert_conf_value refuses the replacement, cleans the temp + errors when the mode cannot be restored (base#1356)" {
  # Skipped under kcov: overrides `chmod` with a failing shell function,
  # the same stub shape as the mv-failure specs above.
  [ "${COVERAGE:-0}" = 1 ] && skip "chmod-failure stub is kcov-fragile (#613)"

  local _d _f
  _d="$(mktemp -d)"
  _f="${_d}/setup.toml"
  printf '[network]\nmode = "host"\n' > "${_f}"
  chmod 664 "${_f}"
  local _orig
  _orig="$(cat "${_f}")"

  run bash -c "
    source /source/dist/script/docker/lib/conf.sh
    _log_err() { printf 'ERR: %s\n' \"\${*:3}\" >&2; }
    chmod() { return 1; }
    _upsert_conf_value '${_f}' network mode bridge
  "
  assert_failure
  assert_output --partial "could not give the rewrite"
  run cat "${_f}"
  assert_output "${_orig}"
  run stat -c '%a' "${_f}"
  assert_output "664"
  run bash -c "ls '${_f}'.* 2>/dev/null | wc -l"
  assert_output "0"
  rm -rf "${_d}"
}

# why: Same contract for the template-rewrite writer behind TUI Save and
# `setup.sh remove` (base#1356).
@test "_write_setup_conf refuses the replacement, cleans the temp + errors when the mode cannot be restored (base#1356)" {
  [ "${COVERAGE:-0}" = 1 ] && skip "chmod-failure stub is kcov-fragile (#613)"

  local _d _tpl _dst
  _d="$(mktemp -d)"
  _tpl="${_d}/tpl.toml"
  _dst="${_d}/setup.toml"
  printf '[network]\nmode = "host"\n' > "${_tpl}"
  printf '[network]\nmode = "host"\n' > "${_dst}"
  chmod 644 "${_dst}"
  local _orig
  _orig="$(cat "${_dst}")"

  run bash -c "
    source /source/dist/script/docker/lib/conf.sh
    _log_err() { printf 'ERR: %s\n' \"\${*:3}\" >&2; }
    chmod() { return 1; }
    declare -a _keys=(network.mode) _values=(bridge)
    _write_setup_conf '${_dst}' '${_tpl}' _keys _values
  "
  assert_failure
  assert_output --partial "could not give the rewrite"
  run cat "${_dst}"
  assert_output "${_orig}"
  run stat -c '%a' "${_dst}"
  assert_output "644"
  run bash -c "ls '${_dst}'.* 2>/dev/null | wc -l"
  assert_output "0"
  rm -rf "${_d}"
}

# ════════════════════════════════════════════════════════════════════
# _parse_ini_section
#
# The fixtures below are NOT named setup.toml, and that is the point:
# _parse_ini_section and _ini_tokenize are the INI primitives, so an INI
# body is what they are meant to be handed. Naming such a body `.toml`
# claims a format the file does not hold -- the defect base#1164 is about
# -- and the dispatching reader (_parse_conf_section) would hand the same
# bytes to the bridge and get a refusal. These tests reach the INI
# primitive directly; their fixture carries the INI name to match.
# ════════════════════════════════════════════════════════════════════
@test "_parse_ini_section reads keys and values for one section" {
  local _conf="${TEMP_DIR}/setup.conf"
  cat > "${_conf}" <<'EOF'
[gpu]
mode = auto
count = all
capabilities = gpu
EOF
  local -a _k=() _v=()
  _parse_ini_section "${_conf}" "gpu" _k _v
  assert_equal "${#_k[@]}" "3"
  assert_equal "${_k[0]}" "mode"
  assert_equal "${_v[0]}" "auto"
  assert_equal "${_k[1]}" "count"
  assert_equal "${_v[1]}" "all"
}

@test "_parse_ini_section isolates sections (entries from other sections ignored)" {
  local _conf="${TEMP_DIR}/setup.conf"
  cat > "${_conf}" <<'EOF'
[gpu]
mode = auto

[gui]
mode = off
EOF
  local -a _k=() _v=()
  _parse_ini_section "${_conf}" "gui" _k _v
  assert_equal "${#_k[@]}" "1"
  assert_equal "${_k[0]}" "mode"
  assert_equal "${_v[0]}" "off"
}

@test "_parse_ini_section skips comment and empty lines" {
  local _conf="${TEMP_DIR}/setup.conf"
  cat > "${_conf}" <<'EOF'
# top comment
[network]
# inside comment
mode = host

ipc = host

# trailing
EOF
  local -a _k=() _v=()
  _parse_ini_section "${_conf}" "network" _k _v
  assert_equal "${#_k[@]}" "2"
  assert_equal "${_k[0]}" "mode"
  assert_equal "${_k[1]}" "ipc"
}

@test "_parse_ini_section trims whitespace around key and value" {
  local _conf="${TEMP_DIR}/setup.conf"
  printf '[gpu]\n  mode  =  force  \n' > "${_conf}"
  local -a _k=() _v=()
  _parse_ini_section "${_conf}" "gpu" _k _v
  assert_equal "${_k[0]}" "mode"
  assert_equal "${_v[0]}" "force"
}

@test "_parse_ini_section returns empty arrays for missing file" {
  local -a _k=() _v=()
  _parse_ini_section "${TEMP_DIR}/missing.conf" "gpu" _k _v
  assert_equal "${#_k[@]}" "0"
  assert_equal "${#_v[@]}" "0"
}

@test "_parse_ini_section returns empty arrays for absent section" {
  local _conf="${TEMP_DIR}/setup.conf"
  cat > "${_conf}" <<'EOF'
[gpu]
mode = auto
EOF
  local -a _k=() _v=()
  _parse_ini_section "${_conf}" "gui" _k _v
  assert_equal "${#_k[@]}" "0"
}

# A section like [logging] must NOT absorb entries from a distinct
# dotted sub-section [logging.web]. Section matching is exact, not
# prefix-based. conf_logging.sh relies on this: it reads the global
# [logging] block and per-service [logging.<svc>] blocks separately.
@test "_parse_ini_section does not absorb dotted sub-sections" {
  local _conf="${TEMP_DIR}/setup.conf"
  cat > "${_conf}" <<'EOF'
[logging]
driver = json-file

[logging.web]
driver = local
EOF
  local -a _k=() _v=()
  _parse_ini_section "${_conf}" "logging" _k _v
  assert_equal "${#_k[@]}" "1"
  assert_equal "${_k[0]}" "driver"
  assert_equal "${_v[0]}" "json-file"
}

@test "_parse_ini_section reads a dotted section name" {
  local _conf="${TEMP_DIR}/setup.conf"
  cat > "${_conf}" <<'EOF'
[logging]
driver = json-file

[logging.web]
driver = local
max_size = 5m
EOF
  local -a _k=() _v=()
  _parse_ini_section "${_conf}" "logging.web" _k _v
  assert_equal "${#_k[@]}" "2"
  assert_equal "${_k[0]}" "driver"
  assert_equal "${_v[0]}" "local"
  assert_equal "${_k[1]}" "max_size"
  assert_equal "${_v[1]}" "5m"
}

# Duplicate keys and a reopened section are preserved in file order
# (the original single-pass reader appended every matching line).
@test "_parse_ini_section preserves duplicate keys and reopened sections in order" {
  local _conf="${TEMP_DIR}/setup.conf"
  cat > "${_conf}" <<'EOF'
[volumes]
mount_1 = a:a

[other]
x = y

[volumes]
mount_1 = b:b
mount_2 = c:c
EOF
  local -a _k=() _v=()
  _parse_ini_section "${_conf}" "volumes" _k _v
  assert_equal "${#_k[@]}" "3"
  assert_equal "${_k[0]}" "mount_1"
  assert_equal "${_v[0]}" "a:a"
  assert_equal "${_k[1]}" "mount_1"
  assert_equal "${_v[1]}" "b:b"
  assert_equal "${_k[2]}" "mount_2"
  assert_equal "${_v[2]}" "c:c"
}

# ════════════════════════════════════════════════════════════════════
# _ini_tokenize (shared single-pass core)
# ════════════════════════════════════════════════════════════════════
@test "_ini_tokenize tracks the owning section per entry and dedups headers" {
  local _conf="${TEMP_DIR}/setup.conf"
  cat > "${_conf}" <<'EOF'
[gpu]
mode = auto

[gui]
mode = off

[gpu]
count = all
EOF
  local -a _s=() _es=() _k=() _v=()
  _ini_tokenize "${_conf}" _s _es _k _v
  # sections[] dedups by first appearance.
  assert_equal "${#_s[@]}" "2"
  assert_equal "${_s[0]}" "gpu"
  assert_equal "${_s[1]}" "gui"
  # entries keep their owning section even across a reopened header.
  assert_equal "${#_k[@]}" "3"
  assert_equal "${_es[0]}" "gpu"
  assert_equal "${_k[0]}" "mode"
  assert_equal "${_es[1]}" "gui"
  assert_equal "${_es[2]}" "gpu"
  assert_equal "${_k[2]}" "count"
}

@test "_ini_tokenize keeps dotted keys verbatim (per-stage override keys)" {
  local _conf="${TEMP_DIR}/setup.conf"
  cat > "${_conf}" <<'EOF'
[stage:headless]
gui.mode = off
deploy.gpu_mode = force
EOF
  local -a _s=() _es=() _k=() _v=()
  _ini_tokenize "${_conf}" _s _es _k _v
  assert_equal "${_es[0]}" "stage:headless"
  assert_equal "${_k[0]}" "gui.mode"
  assert_equal "${_v[0]}" "off"
  assert_equal "${_k[1]}" "deploy.gpu_mode"
  assert_equal "${_v[1]}" "force"
}

# ════════════════════════════════════════════════════════════════════
# One numbered family, one spelling: the two accessors agree (base#1243)
# ════════════════════════════════════════════════════════════════════

# why: THE DEFECT WAS THE DISAGREEMENT, so this is the assertion that
# closes it, on the same file that produced it. A `[security]` carrying
# `cap_drop_1` as a table scalar AND a `[[security.cap_drop]]` block made
# the bridge emit that key twice, and the two accessors read the doubling
# differently: `_conf_get` keeps assigning as it walks and answered
# `SYS_ADMIN` -- the last occurrence, ONE entry -- while
# `_conf_list_sorted` collects every non-empty entry and answered
# `NET_RAW SYS_ADMIN` -- TWO. One file, two effective configurations,
# decided by which reader asked. `_resolve_docker_conf` reads all three
# `[security]` lists through the list accessor and `setup.sh show` and
# the validators read keys, so both answers were live at once.
# The agreement is now that the LOAD fails: `_conf_load` propagates the
# bridge's refusal, which is why this asserts the status and not only the
# values. The accessors answering their defaults on a failed load is the
# half that must not be mistaken for a loaded configuration, and
# `_toml_tokenize` says so in its own voice -- see its header.
@test "the two accessors agree on a numbered family carried both ways: the load is refused (base#1243)" {
  local _f="${TEMP_DIR}/ambiguous.toml"
  cat > "${_f}" << 'EOF'
[security]
privileged = false
cap_drop_1 = "NET_RAW"

[[security.cap_drop]]
cap = "SYS_ADMIN"
EOF

  run _conf_load "${_f}" AMB
  assert_failure

  _conf_load "${_f}" AMB || true
  run _conf_get AMB security cap_drop_1
  assert_success
  assert_output ""

  local -a _got=()
  _conf_list_sorted AMB security "cap_drop_" _got
  assert_equal "${#_got[@]}" 0
}

# why: The control for the case above, and the proof the agreement is not
# bought by refusing every file. The SAME section spelled ONE way loads,
# and the two accessors answer the same configuration: the key lookup
# reads entry 1 and the list reads the entries in index order. Both
# spellings are asserted because both are readable -- the array one is
# what the writers and the converter produce, the scalar one is what a
# family with no array home still uses -- and a refusal that caught
# either would make every repo's configuration unloadable.
@test "_conf_get and _conf_list_sorted agree on a family spelled one way, in either spelling (base#1243)" {
  local _f="${TEMP_DIR}/single.toml"
  local -a _got=()

  cat > "${_f}" << 'EOF'
[security]
privileged = false

[[security.cap_drop]]
cap = "SYS_ADMIN"

[[security.cap_drop]]
cap = "NET_RAW"
EOF
  _conf_load "${_f}" ARR
  run _conf_get ARR security cap_drop_1
  assert_success
  assert_output "SYS_ADMIN"
  _got=()
  _conf_list_sorted ARR security "cap_drop_" _got
  assert_equal "${#_got[@]}" 2
  assert_equal "${_got[0]}" "SYS_ADMIN"
  assert_equal "${_got[1]}" "NET_RAW"

  cat > "${_f}" << 'EOF'
[security]
privileged = false
cap_drop_1 = "SYS_ADMIN"
cap_drop_2 = "NET_RAW"
EOF
  _conf_load "${_f}" SCA
  run _conf_get SCA security cap_drop_1
  assert_success
  assert_output "SYS_ADMIN"
  _got=()
  _conf_list_sorted SCA security "cap_drop_" _got
  assert_equal "${#_got[@]}" 2
  assert_equal "${_got[0]}" "SYS_ADMIN"
  assert_equal "${_got[1]}" "NET_RAW"
}

# why: base#1185 -- the splitter hard-codes `logging` as the only
#      sub-sectioned name, so the whole base.* namespace cannot land
@test "_conf_split_nskey: today's answers are pinned, so a refactor that changes one is loud (base#1185)" {
  # This arm changes nothing on its own. It is here so the arms below --
  # which move WHERE the rule comes from -- cannot quietly move WHAT the
  # rule says. Every row is the current tree's answer, including the two
  # the docstring names and the `stage:` shape, which has a dot in its
  # KEY rather than its section.
  source /source/dist/script/docker/lib/schema.sh
  local _s="" _k=""

  _conf_split_nskey "logging.web.driver" _s _k
  assert_equal "${_s}|${_k}" "logging.web|driver"

  _conf_split_nskey "logging.max_size" _s _k
  assert_equal "${_s}|${_k}" "logging|max_size"

  _conf_split_nskey "stage:headless.gui.mode" _s _k
  assert_equal "${_s}|${_k}" "stage:headless|gui.mode"

  _conf_split_nskey "lifecycle.restart" _s _k
  assert_equal "${_s}|${_k}" "lifecycle|restart"

  # A name with no dot is not a split at all, and both outvars are
  # cleared rather than left holding the caller's previous answer.
  _s="stale"; _k="stale"
  run _conf_split_nskey "logging" _s _k
  assert_failure
  _conf_split_nskey "logging" _s _k || true
  assert_equal "${_s}|${_k}" "|"
}

# why: base#1185 -- the set of sub-sectioned names must come from the
#      registry, or base#1152 / base#1184 cannot add one
@test "_conf_split_nskey: follows the registry, so a new sub-sectioned name needs no edit here (base#1185)" {
  # THE arm for this issue. A fix that merely moves the string `logging`
  # into a variable passes every other check in this file; only this one
  # fails it. The registry is extended in the FIXTURE -- nothing under
  # dist/ is touched -- and the splitter has to follow.
  #
  # `base` rather than `base.watchdog`: the registry names the PARENT
  # that has sub-sections, which is what the splitter can see before it
  # has split anything. The name is base#1152's and is deliberately NOT
  # added to the shipped registry by this slice.
  source /source/dist/script/docker/lib/schema.sh
  local _s="" _k=""

  _conf_split_nskey "base.watchdog.check" _s _k
  assert_equal "${_s}|${_k}" "base|watchdog.check"

  SCHEMA_SUBSECTIONED+=( base )

  _conf_split_nskey "base.watchdog.check" _s _k
  assert_equal "${_s}|${_k}" "base.watchdog|check"

  # One dot is still one dot. Registering a parent must not drag its own
  # scalars into a sub-section that does not exist -- the exact failure
  # the docstring rules out for a prefix match.
  _conf_split_nskey "base.project" _s _k
  assert_equal "${_s}|${_k}" "base|project"

  # And the name that was already there is unaffected by the new one.
  _conf_split_nskey "logging.web.driver" _s _k
  assert_equal "${_s}|${_k}" "logging.web|driver"

  # The other direction, and the reason this arm is not satisfied by
  # "recognise `logging` AND consult the registry": TAKING logging out
  # has to change its answer too. An implementation that keeps the
  # literal as a floor passes every assertion above and fails this one.
  SCHEMA_SUBSECTIONED=( base )
  _conf_split_nskey "logging.web.driver" _s _k
  assert_equal "${_s}|${_k}" "logging|web.driver"
  _conf_split_nskey "base.watchdog.check" _s _k
  assert_equal "${_s}|${_k}" "base.watchdog|check"

  # A registry that names NOTHING is a registry, not a missing one: it
  # answers "no" for every name and the split falls to the first dot.
  # This is what distinguishes it from the refusal arm below.
  SCHEMA_SUBSECTIONED=()
  _conf_split_nskey "logging.web.driver" _s _k
  assert_equal "${_s}|${_k}" "logging|web.driver"
}

# why: base#1185 -- conf.sh gains its first dependency on schema.sh, and
#      it must declare that itself rather than trust the caller
@test "_conf_split_nskey: sourcing conf.sh alone carries the registry with it (base#1185)" {
  # This file sources conf.sh ALONE, and so do five libraries under
  # dist/ -- setup_conf.sh, conf_logging.sh, config_summary.sh,
  # setup_conf_migrate.sh, ini_to_toml_migrate.sh -- one of which
  # (config_summary.sh) calls the splitter. Had the dependency been left
  # to the caller, every one of those would have stopped splitting, so
  # conf.sh sources schema.sh at its own foot.
  #
  # Asserted from THIS file's setup, which names conf.sh and nothing
  # else: if the source line at the foot of conf.sh is removed, this is
  # the arm that says so.
  declare -F _schema_is_subsectioned > /dev/null
  assert_equal "${SCHEMA_SUBSECTIONED[*]}" "logging"

  local _s="" _k=""
  _conf_split_nskey "logging.web.driver" _s _k
  assert_equal "${_s}|${_k}" "logging.web|driver"
}

# why: base#1185 -- an unloaded registry must not read as "nothing is
#      sub-sectioned", an answer worse than the literal it replaced
@test "_conf_split_nskey: refuses rather than guessing when the registry is gone (base#1185)" {
  # With the predicate absent, "is this name sub-sectioned?" has no
  # answer, and the cheap reading of no answer is `no` -- which files
  # `logging.web.driver` under `[logging]` again and says nothing. That
  # is worse than the literal it replaced, which at least got `logging`
  # right, so a missing registry is a REFUSAL.
  #
  # What callers do with that refusal is NOT uniform, which is why the
  # refusal has to be loud on its own account: of the twenty call sites,
  # sixteen `|| continue` and drop the key, three reject with a usage
  # message, and `show` decides between a section and a key -- that one
  # reads the shape of its SPEC rather than the status, so a refusal
  # does not read as "this names a whole section".
  #
  # Reached by removing the registry rather than by withholding the
  # source, because conf.sh now brings it in itself (arm above). Both
  # halves are checked separately: a predicate with no array is not a
  # registry, it is a predicate that answers "no" to everything.
  local _s="stale" _k="stale"

  unset -f _schema_is_subsectioned
  run _conf_split_nskey "logging.web.driver" _s _k
  assert_failure
  assert_output --partial "conf_subsection_registry_missing"

  # Re-sourcing needs the guard cleared first: schema.sh returns at its
  # second line when _DOCKER_SCHEMA_SOURCED is set, so a bare `source`
  # here would restore neither half and this would re-test the arm
  # above. Found by mutation -- with the guard left set, a conf.sh that
  # checked only the predicate passed this.
  unset _DOCKER_SCHEMA_SOURCED
  source /source/dist/script/docker/lib/schema.sh
  declare -F _schema_is_subsectioned > /dev/null

  unset SCHEMA_SUBSECTIONED
  run _conf_split_nskey "logging.web.driver" _s _k
  assert_failure
  assert_output --partial "conf_subsection_registry_missing"
}
