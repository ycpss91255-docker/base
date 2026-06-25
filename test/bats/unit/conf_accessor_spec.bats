#!/usr/bin/env bats
#
# Unit tests for the conf.sh opaque accessor interface.
#
# The accessor verbs (_conf_load / _conf_get / _conf_list / _conf_sections)
# hide conf.sh's internal parallel-array + namespacing representation: callers
# load a handle once and query it by (section, key) without touching arrays.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  # shellcheck source=downstream/script/docker/lib/conf.sh
  # shellcheck disable=SC1091
  source /source/downstream/script/docker/lib/conf.sh
  FIX="$(mktemp)"
  cat > "${FIX}" <<'EOF'
[deploy]
gpu_runtime = auto
gpu_count = 2

[network]
net = host
EOF
}

teardown() {
  rm -f "${FIX}"
}

@test "_conf_get returns a value by section and key" {
  _conf_load "${FIX}" H
  run _conf_get H deploy gpu_runtime
  assert_success
  assert_output "auto"
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
