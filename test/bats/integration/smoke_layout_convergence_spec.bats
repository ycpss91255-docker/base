#!/usr/bin/env bats
#
# Integration test: a repo CREATED on this tree and a repo MIGRATED onto it
# end up with the same smoke layout.
#
# init.sh has two paths -- _create_new_repo and _init_existing_repo -- and
# nothing was comparing their outputs. v0.42.0 split the smoke tree per
# Dockerfile stage; the new-repo path was updated and the existing-repo
# path was not, so every repo upgraded from v0.41.0 kept a flat test/smoke/
# that a fresh bootstrap of the same tag never produces. A unit
# test of either path alone cannot see that: each was internally
# consistent. Only the comparison shows it.
#
# Level 1 (file generation, no Docker), same as init_new_repo_spec.
#
# why: The two init.sh paths must converge on the smoke layout. Divergence
# here is invisible to per-path unit tests and only surfaces on a real
# downstream repo months later, which is exactly how this was found.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  TMP_ROOT="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP_ROOT}"
}

# _stage_subtree <repo_dir>
#   Vendor this tree at <repo_dir>/.base the way a real consumer carries
#   it. Mirrors init_new_repo_spec's fixture, including stripping the .git
#   the self-run guard would read as "this is the base source".
_stage_subtree() {
  local _dir="$1"
  mkdir -p "${_dir}/.base"
  cp -a /source/. "${_dir}/.base/"
  rm -rf "${_dir}/.base/.git"
}

# _fresh_repo
#   A repo built by the NEW-repo path. Echoes its directory.
_fresh_repo() {
  local _dir="${TMP_ROOT}/fresh_repo"
  mkdir -p "${_dir}"
  _stage_subtree "${_dir}"
  ( cd "${_dir}" && bash .base/dist/script/base/init.sh ) >/dev/null 2>&1
  printf '%s' "${_dir}"
}

# _migrated_repo
#   A repo shaped the way v0.41.0 left one -- a Dockerfile that copies the
#   flat tree, and the flat tree itself -- run through the EXISTING-repo
#   path. Echoes its directory.
#
#   The Dockerfile carries the two smoke COPY spellings a v0.41.0 consumer
#   actually has: base's shipped tree and the repo's own, in one stage.
_migrated_repo() {
  local _dir="${TMP_ROOT}/migrated_repo"
  mkdir -p "${_dir}/test/smoke"
  _stage_subtree "${_dir}"
  cat > "${_dir}/Dockerfile" <<'EOF'
FROM scratch AS devel
FROM devel AS devel-test
COPY .base/test/smoke/ /smoke_test/
COPY test/smoke/ /smoke_test/
RUN bats /smoke_test/
EOF
  printf '@test "repo owned" { :; }\n' \
    > "${_dir}/test/smoke/migrated_repo_env.bats"
  ( cd "${_dir}" && bash .base/dist/script/base/init.sh ) >/dev/null 2>&1
  printf '%s' "${_dir}"
}

# _smoke_tree <repo_dir>
#   The repo-owned smoke tree as a sorted, repo-relative path list.
#
#   The seed spec is dropped from the listing on purpose: init.sh names it
#   after the repo (<name>_env.bats), so two repos are SUPPOSED to differ
#   there and comparing it would report the fixture's own naming as a
#   layout divergence. That the seed survives the move is a separate
#   assertion below, where it can be stated directly.
_smoke_tree() {
  ( cd "$1" && find test -path 'test/bats/smoke*' -o -path 'test/smoke*' ) \
    | grep -v '_env\.bats$' | LC_ALL=C sort
}

# _smoke_sources <repo_dir>
#   The repo-owned smoke COPY sources the Dockerfile names, sorted.
#
#   Sources only, for two reasons. The migration deliberately preserves
#   each consumer's column alignment, so whole-line comparison would report
#   formatting as layout. And commented-out lines are skipped: a fresh
#   Dockerfile carries a commented runtime-test COPY block for the opt-in
#   split, which is documentation, not a directive Docker acts on.
_smoke_sources() {
  grep -vE '^[[:space:]]*#' "$1/Dockerfile" \
    | grep -oE '(^|[[:space:]])test/bats/smoke/[a-z-]+/' \
    | sed 's/^[[:space:]]*//' | LC_ALL=C sort -u
}

# why: The two init.sh paths converge on the layout
@test "created and migrated repos agree on the smoke tree layout (#1044)" {
  local _fresh _migrated
  _fresh="$(_fresh_repo)"
  _migrated="$(_migrated_repo)"
  run diff <(_smoke_tree "${_fresh}") <(_smoke_tree "${_migrated}")
  assert_success
}

# why: The two init.sh paths converge on the COPY sources
@test "created and migrated repos agree on the Dockerfile smoke sources (#1044)" {
  local _fresh _migrated
  _fresh="$(_fresh_repo)"
  _migrated="$(_migrated_repo)"
  run diff <(_smoke_sources "${_fresh}") <(_smoke_sources "${_migrated}")
  assert_success
}

# why: The repo own spec survives the move
@test "the migrated repo keeps its own spec, moved rather than dropped (#1044)" {
  local _migrated
  _migrated="$(_migrated_repo)"
  assert [ -f "${_migrated}/test/bats/smoke/shared/migrated_repo_env.bats" ]
  run cat "${_migrated}/test/bats/smoke/shared/migrated_repo_env.bats"
  assert_output --partial '@test "repo owned"'
}

# why: Placeholders come from one definition, so they cannot drift
@test "the migrated repo's per-stage placeholders match a created one byte for byte (#1044)" {
  local _fresh _migrated _stage
  _fresh="$(_fresh_repo)"
  _migrated="$(_migrated_repo)"
  for _stage in devel-test runtime-test; do
    run diff "${_fresh}/test/bats/smoke/${_stage}/.gitkeep" \
             "${_migrated}/test/bats/smoke/${_stage}/.gitkeep"
    assert_success
  done
}

# why: Idempotent end to end, not only per function
@test "migrating twice is the same as migrating once (#1044)" {
  local _migrated _once
  _migrated="$(_migrated_repo)"
  _once="$(_smoke_tree "${_migrated}")"
  ( cd "${_migrated}" && bash .base/dist/script/base/init.sh ) >/dev/null 2>&1
  run diff <(printf '%s\n' "${_once}") <(_smoke_tree "${_migrated}")
  assert_success
}
