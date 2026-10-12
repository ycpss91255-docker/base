#!/usr/bin/env bats
#
# toml_config_wiring_spec.bats -- verify setup_conf.sh / gitignore.sh wire
# the TOML config SOURCES (setup.toml, setup.local.toml) instead of their
# legacy INI counterparts.
#
# D1: setup.toml as the primary config source.
# D2: the gitignore entries for the local TOML overrides.
#
# `env.toml` / `env.local.toml` are NOT in scope, and that is the honest
# scope rather than a gap: nothing in the tree reads either file, so there
# is no wiring here to verify (base#1168). The generated `.env` /
# `.env.local` that compose does load are env_emit.sh's, and they are
# covered in env_emit_spec.bats against the paths production passes -- see
# the retirement note at D2 below (base#1163).
#
# Pure path + file tests -- no docker interaction needed.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  TEMP_DIR="$(mktemp -d)"
  export _SETUP_SCRIPT_DIR="${TEMP_DIR}/dist/script/docker/setup"
  mkdir -p "${_SETUP_SCRIPT_DIR}"
  # The template dist root is three levels above _SETUP_SCRIPT_DIR.
  DIST_ROOT="${TEMP_DIR}/dist"
  mkdir -p "${DIST_ROOT}"

  BASE_PATH="${TEMP_DIR}/repo"
  mkdir -p "${BASE_PATH}"

  # Source libs under test.
  # shellcheck source=dist/script/docker/lib/setup_conf.sh
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/setup_conf.sh
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# ════════════════════════════════════════════════════════════════════
# D1: _setup_conf_layers emits TOML paths
# ════════════════════════════════════════════════════════════════════

# why: The layer chain must resolve to setup.toml paths; a stale .setup.conf path silently bypasses the TOML parser.
@test "_setup_conf_layers returns setup.toml layer chain" {
  local -a layers=()
  _setup_conf_layers "${BASE_PATH}" layers

  # Template layer: <dist>/setup.toml
  assert_equal "${layers[0]}" "${DIST_ROOT}/setup.toml"
  # Repo layer: <base>/setup.toml
  assert_equal "${layers[1]}" "${BASE_PATH}/setup.toml"
  # Local layer: <base>/setup.local.toml
  assert_equal "${layers[2]}" "${BASE_PATH}/setup.local.toml"
}

# why: An explicit template_dist override must land in the layer chain, not silently fall back to the default.
@test "_setup_conf_layers with explicit template_dist uses that dir's setup.toml" {
  local _alt_dist="${TEMP_DIR}/alt_dist"
  mkdir -p "${_alt_dist}"

  local -a layers=()
  _setup_conf_layers "${BASE_PATH}" layers "${_alt_dist}"

  assert_equal "${layers[0]}" "${_alt_dist}/setup.toml"
  assert_equal "${layers[1]}" "${BASE_PATH}/setup.toml"
  assert_equal "${layers[2]}" "${BASE_PATH}/setup.local.toml"
}

# why: A missing template dir must shrink the chain rather than inject a nonexistent path that breaks conf loading.
@test "_setup_conf_layers omits template when no _SETUP_SCRIPT_DIR and no explicit dist" {
  unset _SETUP_SCRIPT_DIR

  local -a layers=()
  _setup_conf_layers "${BASE_PATH}" layers

  # Only repo + local layers, no template.
  assert_equal "${#layers[@]}" 2
  assert_equal "${layers[0]}" "${BASE_PATH}/setup.toml"
  assert_equal "${layers[1]}" "${BASE_PATH}/setup.local.toml"
}

# ════════════════════════════════════════════════════════════════════
# D1: _setup_conf_local_path returns setup.local.toml
# ════════════════════════════════════════════════════════════════════

# why: The per-worktree override must resolve to setup.local.toml; a stale .setup.conf.local path loses operator overrides.
@test "_setup_conf_local_path returns setup.local.toml" {
  run _setup_conf_local_path "${BASE_PATH}"
  assert_success
  assert_output "${BASE_PATH}/setup.local.toml"
}

# ════════════════════════════════════════════════════════════════════
# D2: _scaffold_env_local -- RETIRED here, held in env_emit_spec.bats
#
# Two arms stood here, "_scaffold_env_local creates env.local.toml when
# absent" and "... does not overwrite existing env.local.toml". Both
# handed the function a path THIS FILE chose -- `${BASE_PATH}/env.local.toml`
# -- and `_scaffold_env_local` writes whatever path it is given, so they
# passed whatever path production used. Production uses neither: both
# callers pass `.env.local` (setup_cmd.sh, deploy.sh), which is what the
# `env_file:` block loads and what compose parses as dotenv. The name of
# each arm therefore asserted a wiring the tree does not have, and the
# first one's "the scaffold should contain TOML guidance" check was
# `grep -i toml` over a scaffold whose only TOML is the two sentences
# pointing at `setup.toml` -- it stayed green through the rewrite that took
# every line of TOML guidance OUT of that file (base#1163; the readers are
# base#1168).
#
# Both properties are held against the path production passes, in
# env_emit_spec.bats: "_scaffold_env_local is idempotent (never
# overwrites)", "_scaffold_env_local creates a comment-only override file
# naming .env", and "_scaffold_env_local / write_container_env: the
# guidance names only files the env_file block loads" -- the last of which
# DERIVES the permitted file set from `_emit_env_file_block` rather than
# naming it, so it moves with the readers instead of having to be rewritten
# for them.
# ════════════════════════════════════════════════════════════════════

# ════════════════════════════════════════════════════════════════════
# D2: gitignore includes TOML local overrides
# ════════════════════════════════════════════════════════════════════

# why: A missing gitignore entry lets the per-worktree TOML override get committed, leaking local config into the repo.
@test "canonical gitignore entries include setup.local.toml" {
  # shellcheck source=dist/script/docker/lib/gitignore.sh
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/gitignore.sh

  run _canonical_gitignore_entries
  assert_success
  assert_line "setup.local.toml"
}

# why: Without this entry the service env override file gets committed, leaking secrets or per-machine tuning.
@test "canonical gitignore entries include .env.local.toml" {
  # shellcheck source=dist/script/docker/lib/gitignore.sh
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/gitignore.sh

  run _canonical_gitignore_entries
  assert_success
  assert_line ".env.local.toml"
}

# why: base#1167 renamed the per-instance TOML source to the dotless
# `env.local.toml`, so the canonical set has to ignore the name the
# toolchain will write. The dotted spelling stays in the SAME set rather
# than moving to _retired_gitignore_entries, and that is the load-bearing
# half: v0.43.0-rc1 and -rc2 shipped a template whose own header documents
# `<repo>/.env.local.toml` as the gitignored per-instance override, so an
# operator who followed the shipped instructions has that file on disk with
# their service env in it. Retiring the entry would PRUNE the line out of
# their .gitignore on the next resync and leave those values reachable by
# `git add .` and shipped in the build context -- the outcome
# _canonical_gitignore_entries' own header forbids, and the reason the
# sibling rename (.setup.conf.local -> setup.local.toml, base#1148) kept
# both spellings too. Asserting the pair together, and asking the
# retirement list as well, is what stops a later tidy-up from "finishing"
# the rename by deleting the old line.
@test "canonical gitignore entries add env.local.toml and keep the dotted spelling (base#1167)" {
  # shellcheck source=dist/script/docker/lib/gitignore.sh
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/gitignore.sh

  run _canonical_gitignore_entries
  assert_success
  assert_line "env.local.toml"
  assert_line ".env.local.toml"

  # `refute_line` is not usable here: the retired list is EMPTY today, so
  # `run` leaves `${lines}` unset and refute_line dies on the unset array
  # instead of passing -- an assertion that cannot answer for the state it
  # is written about. The whole stdout is the pruning population, so refute
  # against that; it reads correctly when the list is empty and still fires
  # the day the entry is added to it.
  run _retired_gitignore_entries
  assert_success
  refute_output --partial ".env.local.toml"
}

# ════════════════════════════════════════════════════════════════════
# D1: _is_self_managed_repo checks setup.toml
# ════════════════════════════════════════════════════════════════════

# why: A repo with setup.toml is template-managed; misclassifying it skips the conf layer chain entirely.
@test "_is_self_managed_repo is false when setup.toml exists" {
  # shellcheck source=dist/script/docker/lib/compose.sh
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/compose.sh 2>/dev/null || true

  local _repo="${TEMP_DIR}/consumer_repo"
  mkdir -p "${_repo}/.base"
  touch "${_repo}/setup.toml"

  run _is_self_managed_repo "${_repo}"
  assert_failure
}

# why: The complement of the previous test; a bare directory with no template markers must be classified as self-managed.
@test "_is_self_managed_repo is true when neither .base nor setup.toml exist" {
  source /source/dist/script/docker/lib/compose.sh 2>/dev/null || true

  local _repo="${TEMP_DIR}/self_managed"
  mkdir -p "${_repo}"

  run _is_self_managed_repo "${_repo}"
  assert_success
}
