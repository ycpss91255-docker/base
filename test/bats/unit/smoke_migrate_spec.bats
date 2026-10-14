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

# why: The move itself: every spec lands in the shared baseline
@test "_migrate_smoke_tree moves flat specs into the shared baseline (#1044)" {
  _seed_flat ros_env camera_config
  run bash -c "$(_src); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/test/bats/smoke/shared/ros_env.bats" ]
  assert [ -f "${TEMP_DIR}/test/bats/smoke/shared/camera_config.bats" ]
  assert [ ! -e "${TEMP_DIR}/test/smoke" ]
}

# why: A moved spec is the same file, not a regenerated one
@test "_migrate_smoke_tree preserves spec contents verbatim (#1044)" {
  _seed_flat ros_env
  printf '@test "mine" { [ 1 = 1 ]; }\n' > "${TEMP_DIR}/test/smoke/ros_env.bats"
  run bash -c "$(_src); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/test/bats/smoke/shared/ros_env.bats"
  assert_output --partial '@test "mine"'
}

# why: Helpers move with the specs that load them
@test "_migrate_smoke_tree carries a non-.bats helper across too (#1044)" {
  _seed_flat ros_env
  printf 'helper() { :; }\n' > "${TEMP_DIR}/test/smoke/test_helper.bash"
  run bash -c "$(_src); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/test/bats/smoke/shared/test_helper.bash" ]
}

# why: The migrated repo gains the folders a fresh one has
@test "_migrate_smoke_tree creates the per-stage folders a fresh repo has (#1044)" {
  _seed_flat ros_env
  run bash -c "$(_src); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/test/bats/smoke/devel-test/.gitkeep" ]
  assert [ -f "${TEMP_DIR}/test/bats/smoke/runtime-test/.gitkeep" ]
}

# ── inertness ───────────────────────────────────────────────────────────────

# why: Nothing to migrate creates nothing
@test "_migrate_smoke_tree is inert when there is no flat tree (#1044)" {
  run bash -c "$(_src); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  assert [ ! -e "${TEMP_DIR}/test/bats" ]
}

# why: Idempotent: a second run neither moves nor clobbers
@test "_migrate_smoke_tree is inert on a second run (#1044)" {
  _seed_flat ros_env
  bash -c "$(_src); _migrate_smoke_tree '${TEMP_DIR}'"
  run bash -c "$(_src); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/test/bats/smoke/shared/ros_env.bats"
  assert_output --partial '@test "ros_env"'
}

# why: A repo past this migration is not disturbed by it
@test "_migrate_smoke_tree leaves a repo already on the new layout alone (#1044)" {
  mkdir -p "${TEMP_DIR}/test/bats/smoke/shared"
  printf 'mine\n' > "${TEMP_DIR}/test/bats/smoke/shared/keep.bats"
  run bash -c "$(_src); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  run cat "${TEMP_DIR}/test/bats/smoke/shared/keep.bats"
  assert_output --partial 'mine'
}

# why: test/smoke_helpers merely starts with the retired name
@test "_migrate_smoke_tree does not claim a prefix-sharing sibling (#1044)" {
  mkdir -p "${TEMP_DIR}/test/smoke_helpers"
  printf 'sibling\n' > "${TEMP_DIR}/test/smoke_helpers/x.bash"
  run bash -c "$(_src); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/test/smoke_helpers/x.bash" ]
  assert [ ! -e "${TEMP_DIR}/test/bats" ]
}

# ── conflict: never destroy ─────────────────────────────────────────────────

# why: A name collision destroys neither file
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

# why: The declined file is named, so the user can act on it
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

# why: Move and COPY rewrite stay coupled: neither happens alone
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

# why: The stock COPY shape is recognised, so the move runs
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

# why: No reference to the tree means nothing to keep in step
@test "_migrate_smoke_tree proceeds when the Dockerfile never names the tree (#1044)" {
  _seed_flat ros_env
  printf 'FROM scratch AS devel-test\n' > "${TEMP_DIR}/Dockerfile"
  run bash -c "$(_src_both); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/test/bats/smoke/shared/ros_env.bats" ]
}

# why: The decline keys off the repo path, not smoke_copy s
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

# why: No Dockerfile means no COPY that could be left dangling
@test "_migrate_smoke_tree proceeds when there is no Dockerfile at all (#1044)" {
  _seed_flat ros_env
  run bash -c "$(_src_both); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/test/bats/smoke/shared/ros_env.bats" ]
}

# ── the move rides the caller's commit, through the record ──────

# why: The rename rides the caller commit instead of surfacing later --
#      recorded for the resync's stager, not staged here (base#1160)
@test "_migrate_smoke_tree records both ends of the move (#1044, base#1160)" {
  # This arm used to assert the migration had STAGED the move itself, with
  # an inline `git add` that ran inside the resync's rollback bracket. A
  # rolled-back resync therefore restored every file byte for byte and
  # left the rename in the index (base#1160). `git status` does report
  # that, as `RD` plus a `??`; nothing in the run treats it as a failure,
  # and the rollback arms that existed assert the FILES.
  #
  # The guarantee is unchanged -- the rename still rides the caller's
  # commit -- but it is now delivered by `_init_record_write`, which
  # `_stage_resync_output` reads AFTER the bracket closes. So this arm
  # asks the record, and `init_rollback_spec.bats` asserts the end of the
  # chain against a real resync.
  git -C "${TEMP_DIR}" init --quiet -b main
  git -C "${TEMP_DIR}" config user.name t
  git -C "${TEMP_DIR}" config user.email t@e
  _seed_flat ros_env
  git -C "${TEMP_DIR}" add -A
  git -C "${TEMP_DIR}" commit --quiet -m seed

  # `REC ` prefix: the migration writes its own MIGRATION warning to the
  # same stream `run` captures, so the record has to be told apart from
  # the narration before it can be compared as a set.
  run bash -c "$(_src)
    declare -gA _INIT_WROTE=()
    _init_record_write() { _INIT_WROTE[\"\${1}\"]=1; }
    _migrate_smoke_tree '${TEMP_DIR}'
    printf 'REC %s\n' \"\${!_INIT_WROTE[@]}\" | sort"
  assert_success

  local _rec
  _rec="$(printf '%s\n' "${output}" | sed -n 's/^REC //p' | sort)"
  # The EXACT set, not four `assert_line`s. Inclusion alone would accept a
  # record that also named `test/` or `test/smoke`, and a broad entry here
  # becomes a broad `git add` at the stager -- the sweep that commits the
  # consumer's half-finished work under a release message, which
  # `_stage_resync_output`'s own header forbids in as many words.
  #
  # Both ends of the move: the old path exists nowhere but the index once
  # the file has moved, so a record naming only the new one leaves the
  # delete behind. Plus the placeholders the same call seeds.
  assert_equal "${_rec}" "test/bats/smoke/devel-test/.gitkeep
test/bats/smoke/runtime-test/.gitkeep
test/bats/smoke/shared/ros_env.bats
test/smoke/ros_env.bats"

  # And it stages nothing on its own account -- that is the whole point.
  run git -C "${TEMP_DIR}" diff --cached --name-only
  assert_output ""
}

# why: An absent record degrades to a plain move, not an error
@test "_migrate_smoke_tree moves the tree with no recorder loaded (#1044, base#1160)" {
  # `_init_record_write` lives in init.sh, and this lib is reachable
  # without it -- a spec, or a conversion run outside a resync. The
  # recorder is a no-op there, the same shape and the same reason as
  # ini_to_toml_migrate.sh's `_ini_to_toml_record`. The move still
  # happens; there is simply no commit to stage into.
  #
  # This replaces the old "works outside a git tree" arm, which asserted
  # the same resilience against a dependency the function no longer has.
  _seed_flat ros_env
  run bash -c "$(_src); _migrate_smoke_tree '${TEMP_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/test/bats/smoke/shared/ros_env.bats" ]
  assert [ ! -e "${TEMP_DIR}/test/smoke/ros_env.bats" ]
}
