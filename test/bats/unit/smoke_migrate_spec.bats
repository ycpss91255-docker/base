#!/usr/bin/env bats
#
# why: Mirrors `lib/smoke_migrate.sh`. v0.42.0 moved the repo-owned smoke
# tree from a flat `test/smoke/` to the per-stage `test/bats/smoke/` layout
# and shipped no migration for it, so a repo upgraded from v0.41.0 keeps a
# shape a fresh bootstrap of the same tag never produces.
#
# The move is behaviour-preserving by construction: the pre-v0.42.0
# Dockerfile copies the whole flat tree into EVERY `-test` stage, and
# `shared/` is defined as "runs on every stage". So every spec lands in
# `shared/` -- deciding which ones belong to one stage is a per-repo
# judgement this migration deliberately does not make.
#
# Apply policy follows _migrate_env_to_local: a shape it recognises is
# healed idempotently; anything ambiguous is warned about and left alone,
# never force-rewritten.

bats_require_minimum_version 1.5.0

LIB="/source/dist/script/docker/lib"

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  TEMP_DIR="$(mktemp -d)"
  export TEMP_DIR
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# _src
#   Source the lib in a fresh shell so each test drives the real function
#   body. _lib.sh brings in _log_* for the warn/skip messaging.
_src() {
  printf 'source %s/_lib.sh; source %s/smoke_migrate.sh' "${LIB}" "${LIB}"
}

# _seed_flat <spec-name>...
#   Lay down the pre-v0.42.0 shape: a flat test/smoke/ holding the named
#   specs.
_seed_flat() {
  mkdir -p "${TEMP_DIR}/test/smoke"
  local _n
  for _n in "$@"; do
    printf '@test "%s" { :; }\n' "${_n}" > "${TEMP_DIR}/test/smoke/${_n}.bats"
  done
}

# ── the move itself ─────────────────────────────────────────────────────────

@test "_migrate_smoke_tree moves flat specs into the shared baseline (#1044)" {
  _seed_flat ros_env camera_config
  run bash -c "$(_src); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/test/bats/smoke/shared/ros_env.bats" ]
  assert [ -f "${TEMP_DIR}/test/bats/smoke/shared/camera_config.bats" ]
  assert [ ! -e "${TEMP_DIR}/test/smoke" ]
}

@test "_migrate_smoke_tree preserves spec contents verbatim (#1044)" {
  _seed_flat ros_env
  printf '@test "mine" { [ 1 = 1 ]; }\n' > "${TEMP_DIR}/test/smoke/ros_env.bats"
  run bash -c "$(_src); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/test/bats/smoke/shared/ros_env.bats"
  assert_output --partial '@test "mine"'
}

@test "_migrate_smoke_tree carries a non-.bats helper across too (#1044)" {
  _seed_flat ros_env
  printf 'helper() { :; }\n' > "${TEMP_DIR}/test/smoke/test_helper.bash"
  run bash -c "$(_src); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/test/bats/smoke/shared/test_helper.bash" ]
}

@test "_migrate_smoke_tree creates the per-stage folders a fresh repo has (#1044)" {
  _seed_flat ros_env
  run bash -c "$(_src); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/test/bats/smoke/devel-test/.gitkeep" ]
  assert [ -f "${TEMP_DIR}/test/bats/smoke/runtime-test/.gitkeep" ]
}

# ── inertness ───────────────────────────────────────────────────────────────

@test "_migrate_smoke_tree is inert when there is no flat tree (#1044)" {
  run bash -c "$(_src); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  assert [ ! -e "${TEMP_DIR}/test/bats" ]
}

@test "_migrate_smoke_tree is inert on a second run (#1044)" {
  _seed_flat ros_env
  bash -c "$(_src); _migrate_smoke_tree '${TEMP_DIR}'"
  run bash -c "$(_src); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/test/bats/smoke/shared/ros_env.bats"
  assert_output --partial '@test "ros_env"'
}

@test "_migrate_smoke_tree leaves a repo already on the new layout alone (#1044)" {
  mkdir -p "${TEMP_DIR}/test/bats/smoke/shared"
  printf 'mine\n' > "${TEMP_DIR}/test/bats/smoke/shared/keep.bats"
  run bash -c "$(_src); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/test/bats/smoke/shared/keep.bats"
  assert_output --partial 'mine'
}

@test "_migrate_smoke_tree does not claim a prefix-sharing sibling (#1044)" {
  mkdir -p "${TEMP_DIR}/test/smoke_helpers"
  printf 'sibling\n' > "${TEMP_DIR}/test/smoke_helpers/x.bash"
  run bash -c "$(_src); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/test/smoke_helpers/x.bash" ]
  assert [ ! -e "${TEMP_DIR}/test/bats" ]
}

# ── conflict: never destroy ─────────────────────────────────────────────────

@test "_migrate_smoke_tree keeps both sides when a name already exists at the destination (#1044)" {
  _seed_flat ros_env
  mkdir -p "${TEMP_DIR}/test/bats/smoke/shared"
  printf 'destination\n' > "${TEMP_DIR}/test/bats/smoke/shared/ros_env.bats"
  run bash -c "$(_src); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  # The destination file is authoritative and is not overwritten.
  run cat "${TEMP_DIR}/test/bats/smoke/shared/ros_env.bats"
  assert_output --partial 'destination'
  # The source is left in place for the user to reconcile, not deleted.
  assert [ -f "${TEMP_DIR}/test/smoke/ros_env.bats" ]
}

@test "_migrate_smoke_tree names the conflict it declined (#1044)" {
  _seed_flat ros_env
  mkdir -p "${TEMP_DIR}/test/bats/smoke/shared"
  printf 'destination\n' > "${TEMP_DIR}/test/bats/smoke/shared/ros_env.bats"
  run bash -c "$(_src); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  assert_output --partial 'ros_env.bats'
}

# ── coupling: never move files the Dockerfile rewrite cannot follow ─────────
# The move and the COPY rewrite are two halves of one change. If the
# Dockerfile names the retired tree in a shape the rewriter does not
# recognise, moving the files anyway would leave a COPY pointing at a
# directory that no longer exists -- turning a cosmetic layout drift into a
# build that fails with "COPY source not found". Declining keeps the repo
# consistent and says why.
_src_both() {
  printf 'source %s/_lib.sh; source %s/dockerfile_migrate.sh; source %s/smoke_migrate.sh' \
    "${LIB}" "${LIB}" "${LIB}"
}

@test "_migrate_smoke_tree declines when the Dockerfile names the tree unrewritably (#1044)" {
  _seed_flat ros_env
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS devel-test
COPY ["test/smoke/", "/smoke_test/"]
EOF
  run bash -c "$(_src_both); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/test/smoke/ros_env.bats" ]
  assert [ ! -e "${TEMP_DIR}/test/bats/smoke/shared/ros_env.bats" ]
  assert_output --partial 'test/smoke'
}

@test "_migrate_smoke_tree proceeds on the shape the rewriter handles (#1044)" {
  _seed_flat ros_env
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS devel-test
COPY test/smoke/ /smoke_test/
EOF
  run bash -c "$(_src_both); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/test/bats/smoke/shared/ros_env.bats" ]
}

@test "_migrate_smoke_tree proceeds when the Dockerfile never names the tree (#1044)" {
  _seed_flat ros_env
  printf 'FROM scratch AS devel-test\n' > "${TEMP_DIR}/Dockerfile"
  run bash -c "$(_src_both); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/test/bats/smoke/shared/ros_env.bats" ]
}

@test "_migrate_smoke_tree does not decline over base's own shipped path (#1044)" {
  # The decline must key off the REPO's reference. A Dockerfile naming only
  # .base/test/smoke -- smoke_copy's business, not this one -- would
  # otherwise stop a move it has nothing to say about.
  _seed_flat ros_env
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS devel-test
COPY .base/test/smoke/ /smoke_test/
EOF
  run bash -c "$(_src_both); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/test/bats/smoke/shared/ros_env.bats" ]
}

@test "_migrate_smoke_tree proceeds when there is no Dockerfile at all (#1044)" {
  _seed_flat ros_env
  run bash -c "$(_src_both); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/test/bats/smoke/shared/ros_env.bats" ]
}

# ── git: the move rides the caller's commit ────────────────────

@test "_migrate_smoke_tree stages the move when the repo is a git tree (#1044)" {
  git -C "${TEMP_DIR}" init --quiet -b main
  git -C "${TEMP_DIR}" config user.name t
  git -C "${TEMP_DIR}" config user.email t@e
  _seed_flat ros_env
  git -C "${TEMP_DIR}" add -A
  git -C "${TEMP_DIR}" commit --quiet -m seed
  run bash -c "$(_src); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  run git -C "${TEMP_DIR}" status --porcelain
  # Nothing is left for the user to notice later: the rename is staged.
  refute_output --partial '??'
  assert_output --partial 'test/bats/smoke/shared/ros_env.bats'
}

@test "_migrate_smoke_tree works outside a git tree (#1044)" {
  _seed_flat ros_env
  run bash -c "$(_src); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/test/bats/smoke/shared/ros_env.bats" ]
}
