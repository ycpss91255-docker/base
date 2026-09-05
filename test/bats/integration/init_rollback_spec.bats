#!/usr/bin/env bats
#
# Integration tests: init.sh's existing-repo resync must leave the
# consumer's files exactly as it found them when one of its own mutations
# fails partway.
#
# The resync rewrites files the consumer owns -- the Dockerfile's COPY
# sources, .gitignore / .dockerignore, the wrapper symlinks -- and it runs
# inside an upgrade that has ALREADY committed the subtree pull. Whether
# anything undoes a half-finished rewrite used to depend entirely on WHICH
# caller drove it: the current upgrade.sh arms an EXIT trap around the whole
# post-pull window, the vendored v0.41.0 copy that the deployed repos still
# run has no trap at all, and `just base init` has none either. So the
# protection existed only on the one caller those repos do not use.
#
# These tests drive a real mid-mutation failure through all three callers
# and assert the consumer's files are BYTE-IDENTICAL to before the run.
# Exit status alone is not the assertion: a non-zero exit over a
# half-rewritten Dockerfile is exactly the state being guarded against.
#
# The failure is injected by shadowing `sed` with a stub that forwards
# every call except the ONE belonging to a specific Dockerfile migration.
# Nothing test-only is added to the shipped scripts, and the failure lands
# where a real one would: after an earlier migration has already rewritten
# the file, with the rewrite half-applied.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"

  CONSUMER="${BATS_TEST_TMPDIR}/consumer"
  BEFORE="${BATS_TEST_TMPDIR}/before"
  STUB_DIR="${BATS_TEST_TMPDIR}/stub_bin"

  TMPL_WORK="${BATS_TEST_TMPDIR}/template_work"
  TMPL_BARE="${BATS_TEST_TMPDIR}/template.git"
}

# ── Fixture helpers ─────────────────────────────────────────────────────────

# _stub_failing_sed
#   A `sed` that behaves exactly like the real one until it is handed the
#   program belonging to the flat-layout Dockerfile migration, at which
#   point it fails. By then the FIRST migration in the ordered list has
#   already rewritten the same file, so the abort lands mid-rewrite rather
#   than before it -- the state that makes "the exit status was non-zero"
#   an insufficient assertion.
#
#   Echoes a PATH value for the caller to scope to a single invocation.
_stub_failing_sed() {
  mkdir -p "${STUB_DIR}"
  local _real
  _real="$(command -v sed)"
  cat > "${STUB_DIR}/sed" <<STUB
#!/usr/bin/env bash
if [[ "\$*" == *'.base/dist/config'* ]]; then
  echo "stub sed: injected mid-migration failure" >&2
  exit 1
fi
exec "${_real}" "\$@"
STUB
  chmod 755 "${STUB_DIR}/sed"
  printf '%s' "${STUB_DIR}:${PATH}"
}

# _seed_consumer_files <dir>
#   The consumer content the resync touches, in the shape a deployed
#   v0.41.0 repo actually has.
#
#   Dockerfile carries BOTH a `.base/downstream/` COPY (rewritten by the
#   first migration in the list) and a `.base/config` COPY (rewritten by
#   the one the stub kills), so the abort is genuinely mid-file.
#
#   compose.yaml is tracked: it is a canonical derived artifact, so the
#   resync `git rm --cached`es it, and restoring the working tree without
#   restoring the index would leave a staged deletion the consumer never
#   asked for.
#
#   .env is hand-written, gitignored and therefore unrecoverable from git
#   -- the file the env-naming rename moves, and the reason "restore"
#   cannot mean `git reset`.
#
#   script/hooks/pre/build.sh is user-authored and must survive untouched;
#   the root build.sh symlink is the pre-relocation wrapper the resync
#   deletes, and must come back.
#
#   test/smoke/ is the flat pre-v0.42.0 layout. The migration that moves it
#   runs immediately BEFORE the Dockerfile rewrite the stub kills, so at
#   abort time the tree has already moved -- and a rollback that restores
#   the Dockerfile's old COPY over a tree that stayed moved leaves a build
#   that dies with "COPY source not found". The specs are repo-owned and
#   the only copy of themselves, so this is data loss, not layout drift.
_seed_consumer_files() {
  local _dir="${1:?BUG: _seed_consumer_files expects a dir}"
  mkdir -p "${_dir}/script/hooks/pre" "${_dir}/test/smoke"

  cat > "${_dir}/Dockerfile" <<'EOF'
FROM busybox AS lint
COPY .base/downstream/script/docker/lib /lint/lib
COPY .base/config /tmp/config
EOF

  cat > "${_dir}/.gitignore" <<'EOF'
.env
EOF

  cat > "${_dir}/compose.yaml" <<'EOF'
services:
  devel: {}
EOF

  cat > "${_dir}/.env" <<'EOF'
IMAGE_NAME=hand-written
USER_NAME=operator
EOF

  cat > "${_dir}/script/hooks/pre/build.sh" <<'EOF'
#!/usr/bin/env bash
# user-authored hook -- must survive a failed resync untouched
exit 0
EOF
  chmod 755 "${_dir}/script/hooks/pre/build.sh"

  # printf, not a heredoc: a `@test` line at column zero inside this file
  # is counted by the doc-catalogue marker scan as one of this spec's own.
  printf '%s\n' '@test "repo-owned smoke spec" { [ 1 = 1 ]; }' \
    > "${_dir}/test/smoke/repo_env.bats"

  echo "CONSUMER" > "${_dir}/README.md"
  ln -sf README.md "${_dir}/build.sh"
}

# _seed_subtree <dir>
#   Lay the working tree down as the consumer's `.base/`: the real dist/
#   payload plus the `.version` marker init.sh walks up to find.
_seed_subtree() {
  local _dir="${1:?BUG: _seed_subtree expects a dir}"
  mkdir -p "${_dir}/.base"
  cp -a /source/dist "${_dir}/.base/dist"
  echo "v0.0.0-test" > "${_dir}/.base/.version"
}

# _git_init_repo <dir>
_git_init_repo() {
  local _dir="${1:?BUG: _git_init_repo expects a dir}"
  mkdir -p "${_dir}"
  git -C "${_dir}" init -q -b main
  git -C "${_dir}" config user.email t@t
  git -C "${_dir}" config user.name t
}

# _snapshot_before
#   A copy of the consumer as the run found it, for byte comparison after.
_snapshot_before() {
  mkdir -p "${BEFORE}"
  cp -a "${CONSUMER}/Dockerfile" "${BEFORE}/Dockerfile"
  cp -a "${CONSUMER}/.gitignore" "${BEFORE}/.gitignore"
  cp -a "${CONSUMER}/.env" "${BEFORE}/.env"
  cp -a "${CONSUMER}/script/hooks/pre/build.sh" "${BEFORE}/build_hook.sh"
  cp -a "${CONSUMER}/test/smoke/repo_env.bats" "${BEFORE}/repo_env.bats"
}

# _assert_consumer_unchanged
#   The load-bearing assertion. Every file the resync can rewrite is
#   byte-identical to the pre-run copy, every path it creates is gone, and
#   every path it deletes is back -- including the index entry it removed.
_assert_consumer_unchanged() {
  cmp -s "${CONSUMER}/Dockerfile" "${BEFORE}/Dockerfile" \
    || fail "Dockerfile was left rewritten: $(cat "${CONSUMER}/Dockerfile")"
  cmp -s "${CONSUMER}/.gitignore" "${BEFORE}/.gitignore" \
    || fail ".gitignore was left rewritten: $(cat "${CONSUMER}/.gitignore")"
  cmp -s "${CONSUMER}/.env" "${BEFORE}/.env" \
    || fail ".env was left rewritten -- it is hand-written and gitignored"
  cmp -s "${CONSUMER}/script/hooks/pre/build.sh" "${BEFORE}/build_hook.sh" \
    || fail "the user's own pre-build hook was not preserved"
  cmp -s "${CONSUMER}/test/smoke/repo_env.bats" "${BEFORE}/repo_env.bats" \
    || fail "the repo's own smoke tree was left migrated -- the restored Dockerfile still names test/smoke"

  assert [ ! -e "${CONSUMER}/test/bats/smoke" ]
  assert [ ! -e "${CONSUMER}/.env.local" ]
  assert [ ! -e "${CONSUMER}/justfile" ]
  assert [ ! -e "${CONSUMER}/script/justfile" ]
  assert [ ! -e "${CONSUMER}/script/hooks/pre/run.sh" ]
  assert [ ! -e "${CONSUMER}/script/local" ]
  assert [ ! -e "${CONSUMER}/config" ]
  assert [ ! -e "${CONSUMER}/.dockerignore" ]
  assert [ ! -e "${CONSUMER}/.github/workflows/base-version-monitor.yaml" ]

  # The pre-relocation root wrapper the resync deletes before relinking.
  assert [ -L "${CONSUMER}/build.sh" ]
  [ "$(readlink "${CONSUMER}/build.sh")" = "README.md" ]

  # The index removal is state too: a staged deletion left behind is a
  # change the consumer did not make and cannot see in the working tree.
  [ -n "$(git -C "${CONSUMER}" ls-files -- compose.yaml)" ] \
    || fail "compose.yaml was left removed from the index"
}

# ══════════════════════════════════════════════════════════════════════
# Caller 1: `just base init` (no trap anywhere)
# ══════════════════════════════════════════════════════════════════════

# The `base` namespace recipe is a bare passthrough, so running init.sh
# directly IS what `just base init` runs. Pinned here so the claim above
# cannot quietly stop being true.
@test "just base init: the recipe passes straight through to init.sh (#937)" {
  run grep -A1 '^init \*args:' /source/dist/script/base/justfile.base
  assert_success
  assert_output --partial "./.base/dist/script/base/init.sh {{args}}"
}

@test "just base init: a mid-migration failure leaves the consumer byte-identical (#937)" {
  _git_init_repo "${CONSUMER}"
  _seed_subtree "${CONSUMER}"
  _seed_consumer_files "${CONSUMER}"
  git -C "${CONSUMER}" add -A
  git -C "${CONSUMER}" commit -q -m "consumer at v0.41.0"
  _snapshot_before

  local _head
  _head="$(git -C "${CONSUMER}" rev-parse HEAD)"

  cd "${CONSUMER}"
  run env PATH="$(_stub_failing_sed)" ./.base/dist/script/base/init.sh
  assert_failure

  _assert_consumer_unchanged

  # The resync never touches history -- that is the caller's to own, and
  # the reason this rollback cannot be a `git reset`.
  [ "$(git -C "${CONSUMER}" rev-parse HEAD)" = "${_head}" ]
}

@test "just base init: the failed resync says it restored the files (#937)" {
  _git_init_repo "${CONSUMER}"
  _seed_subtree "${CONSUMER}"
  _seed_consumer_files "${CONSUMER}"
  git -C "${CONSUMER}" add -A
  git -C "${CONSUMER}" commit -q -m "consumer at v0.41.0"

  cd "${CONSUMER}"
  run env PATH="$(_stub_failing_sed)" ./.base/dist/script/base/init.sh
  assert_failure
  assert_output --partial "resync failed"
  assert_output --partial "resync aborted"
}

# ══════════════════════════════════════════════════════════════════════
# Caller 2: a v0.41.0-style upgrade.sh -- commits the pull, then calls
# init.sh, with no trap of any kind
# ══════════════════════════════════════════════════════════════════════
#
# The deployed repos run their OWN vendored copy of upgrade.sh, which
# shipped before the post-pull EXIT trap existed. This stand-in reproduces
# the only two properties of it that matter here: the subtree pull is
# already a commit when init.sh runs, and nothing will undo anything if it
# fails. Verified against the vendored copy -- `grep -c 'trap .*EXIT'`
# reports 0 and init.sh is invoked at its Step 3.
_write_untrapped_caller() {
  cat > "${CONSUMER}/vendored_upgrade.sh" <<'CALLER'
#!/usr/bin/env bash
set -euo pipefail
git commit -q --allow-empty -m "chore: upgrade .base subtree"
./.base/dist/script/base/init.sh
CALLER
  chmod 755 "${CONSUMER}/vendored_upgrade.sh"
}

@test "a v0.41.0-style upgrade.sh (no trap): the consumer is left byte-identical (#937)" {
  _git_init_repo "${CONSUMER}"
  _seed_subtree "${CONSUMER}"
  _seed_consumer_files "${CONSUMER}"
  _write_untrapped_caller
  git -C "${CONSUMER}" add -A
  git -C "${CONSUMER}" commit -q -m "consumer at v0.41.0"
  _snapshot_before

  cd "${CONSUMER}"
  run env PATH="$(_stub_failing_sed)" ./vendored_upgrade.sh
  assert_failure

  _assert_consumer_unchanged

  # The caller's own commit is untouched: undoing it belongs to whoever
  # made it, and this caller has decided not to.
  [ "$(git -C "${CONSUMER}" log -1 --format=%s)" = "chore: upgrade .base subtree" ]
}

# ══════════════════════════════════════════════════════════════════════
# Caller 3: the CURRENT upgrade.sh -- an outer EXIT trap is already armed
# ══════════════════════════════════════════════════════════════════════
#
# Both rollbacks fire on the same failure. They must compose, not fight:
# the inner one restores the files it rewrote and touches no history, then
# the outer one undoes the commit the pull made. The consumer ends up
# where it started, and both say so.

# _seed_template_remote
#   A bare remote carrying two tags. v0.9.5 is what the consumer is on and
#   is where its upgrade.sh comes from -- the REAL current one, so the
#   outer trap under test is the shipped code. v0.9.7 ships the real dist/
#   payload too, so Step 3 runs the real init.sh.
_seed_template_remote() {
  mkdir -p "${TMPL_WORK}"
  _git_init_repo "${TMPL_WORK}"

  cp -a /source/dist "${TMPL_WORK}/dist"
  echo "v0.9.5" > "${TMPL_WORK}/.version"
  git -C "${TMPL_WORK}" add -A
  git -C "${TMPL_WORK}" commit -q -m "v0.9.5"
  git -C "${TMPL_WORK}" tag v0.9.5

  echo "v0.9.7" > "${TMPL_WORK}/.version"
  git -C "${TMPL_WORK}" add -A
  git -C "${TMPL_WORK}" commit -q -m "v0.9.7"
  git -C "${TMPL_WORK}" tag v0.9.7

  git init --bare -q "${TMPL_BARE}"
  git -C "${TMPL_WORK}" push -q "${TMPL_BARE}" v0.9.5 v0.9.7 main
}

@test "the current upgrade.sh: inner and outer rollback compose, not fight (#937)" {
  _seed_template_remote

  _git_init_repo "${CONSUMER}"
  _seed_consumer_files "${CONSUMER}"
  git -C "${CONSUMER}" add -A
  git -C "${CONSUMER}" commit -q -m "consumer"
  git -C "${CONSUMER}" subtree add -q --prefix=.base \
    "file://${TMPL_BARE}" v0.9.5 --squash
  _snapshot_before

  local _pre_head
  _pre_head="$(git -C "${CONSUMER}" rev-parse HEAD)"

  cd "${CONSUMER}"
  run env PATH="$(_stub_failing_sed)" \
      TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_failure
  # Both spoke. An inner rollback that swallowed the failure, or an outer
  # one that never heard about it, would fail one of these.
  assert_output --partial "resync aborted"
  assert_output --partial "upgrade aborted"

  # Inner: the files it rewrote are back.
  _assert_consumer_unchanged
  # Outer: the commit the pull made is gone and the version claim is true.
  [ "$(git -C "${CONSUMER}" rev-parse HEAD)" = "${_pre_head}" ]
  [ "$(cat "${CONSUMER}/.base/.version")" = "v0.9.5" ]
  run git -C "${CONSUMER}" status --porcelain
  assert_output ""
}
