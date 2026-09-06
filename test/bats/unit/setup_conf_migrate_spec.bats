#!/usr/bin/env bats
#
# why: Mirrors `lib/setup_conf_migrate.sh`. The per-repo `setup.conf`
# override moved out of the hand-editable `config/` surface to the
# repo-root `.setup.conf` dotfile, and the migration that relocates a
# downstream still carrying the old path shipped in `upgrade.sh` -- where
# the population it exists for can never run it, because a cross-version
# upgrade is driven by the CONSUMER'S OWN vendored copy (base#1086).
#
# These are the unit-level assertions about the relocation itself. The
# question they answer that the old implementation never had to face is
# what happens when BOTH files exist: the old code warned and proceeded
# with the wrong one, which is how a repo ended up named after the
# directory it was cloned into with an empty `[environment]`.
#
# The decision is per SECTION, because section-replace is the conf chain's
# one rule (lib/conf.sh `_conf_load_layers`): a layer that defines a
# section supplies it wholesale. A root section identical to the shipped
# template's asserts nothing the template does not already say, so the
# legacy file's section wins; a root section that differs is the user's
# and is never overwritten.

bats_require_minimum_version 1.5.0

LIB="/source/dist/script/docker/lib"

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  TEMP_DIR="$(mktemp -d)"
  export TEMP_DIR
  TPL_DIR="${TEMP_DIR}/.base/dist"
  mkdir -p "${TPL_DIR}"
  export TPL_DIR
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# _src
#   Source the lib in a fresh shell so each test drives the real function
#   body. _lib.sh brings in the INI primitives and _log_* messaging.
_src() {
  printf 'source %s/_lib.sh; source %s/setup_conf_migrate.sh' "${LIB}" "${LIB}"
}

# _seed_template
#   The shipped default, as the freshly pulled subtree carries it. Kept
#   synthetic rather than copied from dist/.setup.conf: the migration must
#   decide from the file in front of it, not from today's real defaults.
_seed_template() {
  cat > "${TPL_DIR}/.setup.conf" <<'EOF'
[image]
rule_1 = prefix:docker_

[deploy]
gpu_mode = auto

[gui]
mode = auto

[lifecycle]
restart = unless-stopped

[volumes]
mount_1 =
EOF
}

# _seed_legacy
#   The pre-relocation per-repo override, at the path a v0.41.0 consumer
#   still carries it.
_seed_legacy() {
  mkdir -p "${TEMP_DIR}/config/docker"
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[image]
rule_1 = string:omniverse_web_viewer

[deploy]
gpu_mode = off

[environment]
env_1 = SIGNALING_SERVER=localhost
EOF
}

# _git_init
#   A repo with an identity, so `git mv` has somewhere to record the move.
_git_init() {
  git -C "${TEMP_DIR}" init -q -b main
  git -C "${TEMP_DIR}" config user.email t@t
  git -C "${TEMP_DIR}" config user.name t
}

# ── the relocation itself ───────────────────────────────────────────────────

# why: The whole point: a repo carrying only the legacy override keeps its
# config, at the name the current tree reads
@test "_migrate_legacy_setup_conf relocates a legacy override to the repo root (#1086)" {
  _seed_template
  _seed_legacy
  run bash -c "$(_src); _migrate_legacy_setup_conf '${TEMP_DIR}' '${TPL_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/.setup.conf" ]
  assert [ ! -e "${TEMP_DIR}/config/docker/setup.conf" ]
  run cat "${TEMP_DIR}/.setup.conf"
  assert_output --partial "rule_1 = string:omniverse_web_viewer"
  assert_output --partial "env_1 = SIGNALING_SERVER=localhost"
}

# why: A repo already on the new layout must not be told it is being
# migrated -- the announcement is what a reader trusts
@test "_migrate_legacy_setup_conf is inert when there is no legacy file (#1086)" {
  _seed_template
  printf '[image]\nrule_1 = string:mine\n' > "${TEMP_DIR}/.setup.conf"
  run bash -c "$(_src); _migrate_legacy_setup_conf '${TEMP_DIR}' '${TPL_DIR}'"
  assert_success
  refute_output --partial "relocating per-repo setup.conf override"
  run cat "${TEMP_DIR}/.setup.conf"
  assert_output --partial "rule_1 = string:mine"
}

# why: Idempotence: the resync runs on every hop, so a second pass over an
# already-migrated repo must change nothing
@test "_migrate_legacy_setup_conf is a no-op on a second run (#1086)" {
  _seed_template
  _seed_legacy
  bash -c "$(_src); _migrate_legacy_setup_conf '${TEMP_DIR}' '${TPL_DIR}'"
  local _before
  _before="$(cat "${TEMP_DIR}/.setup.conf")"
  run bash -c "$(_src); _migrate_legacy_setup_conf '${TEMP_DIR}' '${TPL_DIR}'"
  assert_success
  [ "$(cat "${TEMP_DIR}/.setup.conf")" = "${_before}" ]
}

# why: The emptied legacy directory is a working-tree tidy git cannot do
# for us, and a leftover `config/docker/` reads as "still there"
@test "_migrate_legacy_setup_conf clears the emptied legacy directory (#1086)" {
  _seed_template
  _seed_legacy
  run bash -c "$(_src); _migrate_legacy_setup_conf '${TEMP_DIR}' '${TPL_DIR}'"
  assert_success
  assert [ ! -d "${TEMP_DIR}/config/docker" ]
}

# why: config/ is the repo's own hand-editable surface; emptying the one
# subdirectory the migration owns must never take a sibling with it
@test "_migrate_legacy_setup_conf keeps a config/ that holds anything else (#1086)" {
  _seed_template
  _seed_legacy
  printf 'x\n' > "${TEMP_DIR}/config/keep.txt"
  run bash -c "$(_src); _migrate_legacy_setup_conf '${TEMP_DIR}' '${TPL_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/config/keep.txt" ]
}

# ── BOTH files exist ────────────────────────────────────────────────────────

# why: The recovery case. A repo damaged by the hop that skipped the
# migration has a root file it never wrote; without this it stays wrong
# forever, because every later upgrade sees BOTH and declines
@test "_migrate_legacy_setup_conf adopts the legacy file over a root file that is the shipped default (#1086)" {
  _seed_template
  _seed_legacy
  cp "${TPL_DIR}/.setup.conf" "${TEMP_DIR}/.setup.conf"
  run bash -c "$(_src); _migrate_legacy_setup_conf '${TEMP_DIR}' '${TPL_DIR}'"
  assert_success
  assert [ ! -e "${TEMP_DIR}/config/docker/setup.conf" ]
  run cat "${TEMP_DIR}/.setup.conf"
  assert_output --partial "rule_1 = string:omniverse_web_viewer"
  assert_output --partial "gpu_mode = off"
  assert_output --partial "env_1 = SIGNALING_SERVER=localhost"
}

# why: The tool writes `[volumes] mount_1` into every freshly seeded root
# file, so a section both files spell the same way must not be read as a
# choice the user made -- otherwise the recovery above never fires in
# practice
@test "_migrate_legacy_setup_conf adopts when the two files already agree on a non-default section (#1086)" {
  _seed_template
  _seed_legacy
  printf '\n[volumes]\nmount_1 = ${WS_PATH}:/home/${USER_NAME}/work\n' \
    >> "${TEMP_DIR}/config/docker/setup.conf"
  # The root file the way `setup.sh` actually leaves one: the template
  # copied, then `mount_1` REWRITTEN in place by _upsert_conf_value. An
  # appended second `[volumes]` would be a reopened section, which is a
  # different file rather than a differently-seeded one.
  cp "${TPL_DIR}/.setup.conf" "${TEMP_DIR}/.setup.conf"
  sed -i 's|^mount_1 =$|mount_1 = ${WS_PATH}:/home/${USER_NAME}/work|' \
    "${TEMP_DIR}/.setup.conf"
  grep -Fq 'mount_1 = ${WS_PATH}' "${TEMP_DIR}/.setup.conf"
  run bash -c "$(_src); _migrate_legacy_setup_conf '${TEMP_DIR}' '${TPL_DIR}'"
  assert_success
  assert [ ! -e "${TEMP_DIR}/config/docker/setup.conf" ]
  run cat "${TEMP_DIR}/.setup.conf"
  assert_output --partial "rule_1 = string:omniverse_web_viewer"
}

# why: The line the merge must never cross. A root section the user edited
# is theirs; keeping BOTH files loses nothing, and the message is what
# tells them a decision is waiting
@test "_migrate_legacy_setup_conf keeps both files when the root file carries an edited section (#1086)" {
  _seed_template
  _seed_legacy
  cp "${TPL_DIR}/.setup.conf" "${TEMP_DIR}/.setup.conf"
  printf '\n[gui]\nmode = off\n' >> "${TEMP_DIR}/.setup.conf"
  run bash -c "$(_src); _migrate_legacy_setup_conf '${TEMP_DIR}' '${TPL_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/config/docker/setup.conf" ]
  assert_output --partial "gui"
  run cat "${TEMP_DIR}/.setup.conf"
  assert_output --partial "mode = off"
  refute_output --partial "rule_1 = string:omniverse_web_viewer"
}

# why: A section only the root file defines disappears when the legacy
# file replaces it; that is safe exactly when the template already says
# the same thing, and it is a silent loss when it does not
@test "_migrate_legacy_setup_conf keeps both files when the root file alone defines an edited section (#1086)" {
  _seed_template
  _seed_legacy
  cp "${TPL_DIR}/.setup.conf" "${TEMP_DIR}/.setup.conf"
  printf '\n[network]\nmode = host\n' >> "${TEMP_DIR}/.setup.conf"
  run bash -c "$(_src); _migrate_legacy_setup_conf '${TEMP_DIR}' '${TPL_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/config/docker/setup.conf" ]
  assert_output --partial "network"
}

# why: Without the shipped baseline nothing can tell a default from a
# choice, so the fail-safe direction is to decide nothing and keep both
@test "_migrate_legacy_setup_conf refuses to adopt when the template baseline is missing (#1086)" {
  _seed_legacy
  cp /dev/null "${TEMP_DIR}/.setup.conf"
  printf '[image]\nrule_1 = prefix:docker_\n' > "${TEMP_DIR}/.setup.conf"
  run bash -c "$(_src); _migrate_legacy_setup_conf '${TEMP_DIR}' '${TPL_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/config/docker/setup.conf" ]
  run cat "${TEMP_DIR}/.setup.conf"
  refute_output --partial "rule_1 = string:omniverse_web_viewer"
}

# ── what the caller has to commit ───────────────────────────────────────────

# why: The consumer's own released upgrade.sh makes the commit and stages
# nothing of this by name, so a move left unstaged is a commit that
# describes a tree that does not exist (ADR-00000006)
@test "_migrate_legacy_setup_conf stages the move when the legacy file was tracked (#1086)" {
  _seed_template
  _git_init
  _seed_legacy
  git -C "${TEMP_DIR}" add -A
  git -C "${TEMP_DIR}" commit -q -m "legacy override"

  run bash -c "$(_src); _migrate_legacy_setup_conf '${TEMP_DIR}' '${TPL_DIR}'"
  assert_success
  run git -C "${TEMP_DIR}" status --porcelain
  assert_output --partial ".setup.conf"
  refute_output --partial "??"
}

# why: An untracked legacy override is just as much the user's config, and
# the file it becomes has to reach the same commit
@test "_migrate_legacy_setup_conf stages the move when the legacy file was untracked (#1086)" {
  _seed_template
  _git_init
  git -C "${TEMP_DIR}" commit -q --allow-empty -m "init"
  _seed_legacy

  run bash -c "$(_src); _migrate_legacy_setup_conf '${TEMP_DIR}' '${TPL_DIR}'"
  assert_success
  run git -C "${TEMP_DIR}" diff --cached --name-only
  assert_output --partial ".setup.conf"
}

# why: The relocation has to work for a repo that is not a git repo at all
# -- `just base init` on a hand-bootstrapped tree -- and it must not reach
# into a surrounding repository's index to do it
@test "_migrate_legacy_setup_conf relocates outside a git work tree without staging (#1086)" {
  _seed_template
  _seed_legacy
  run bash -c "$(_src); _migrate_legacy_setup_conf '${TEMP_DIR}' '${TPL_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/.setup.conf" ]
  assert [ ! -e "${TEMP_DIR}/config/docker/setup.conf" ]
}

# why: The test above says "without staging" but stands in a directory no
# repository contains, so it never asks the question. `git -C <root>`
# answers for the nearest ENCLOSING work tree, and a hand-bootstrapped
# repo living inside somebody else's checkout has one -- which is the
# whole reason _setup_conf_git_can_stage exists (ADR-00000006). A `git
# mv` reached without that fence writes the relocation into a third
# party's index, and the person who ran `just base init` on their own
# tree finds it in someone else's `git status`.
@test "_migrate_legacy_setup_conf leaves a surrounding repository's index alone (#1086)" {
  local _outer="${TEMP_DIR}/outer"
  local _root="${_outer}/inner"
  mkdir -p "${_root}/.base/dist" "${_root}/config/docker"
  git -C "${_outer}" init -q -b main
  git -C "${_outer}" config user.email t@t
  git -C "${_outer}" config user.name t
  TPL_DIR="${_root}/.base/dist" _seed_template
  cat > "${_root}/config/docker/setup.conf" <<'CONF'
[image]
rule_1 = string:inside_someone_elses_checkout
CONF
  git -C "${_outer}" add -A
  git -C "${_outer}" commit -q -m "the surrounding checkout, as its owner left it"

  run bash -c "$(_src); _migrate_legacy_setup_conf '${_root}' '${_root}/.base/dist'"
  assert_success
  # The relocation itself still happens -- the repo gets its config back.
  run cat "${_root}/.setup.conf"
  assert_output --partial "rule_1 = string:inside_someone_elses_checkout"
  # ... but nothing of it is written into the enclosing repository's
  # index. Its owner's `git status` shows unstaged worktree changes at
  # most, never a staged rename they did not make.
  run git -C "${_outer}" diff --cached --name-only
  assert_output ""
}

# why: A symlink is a POINTER, and a relative one is spelled against the
# directory it sits in. `git mv`/`mv` move the pointer, so an override
# reached through `config/docker/setup.conf -> setup.conf.real` arrives at
# the repo root still naming `setup.conf.real` -- which is not there. The
# repo ends up with a DANGLING `.setup.conf`, running on the template
# defaults, under a log line announcing that its configuration was
# relocated. So the CONTENT moves, and the file the link named is left
# exactly where its owner put it.
@test "_migrate_legacy_setup_conf relocates a symlinked override by content (#1086)" {
  _seed_template
  _seed_legacy
  mv "${TEMP_DIR}/config/docker/setup.conf" \
     "${TEMP_DIR}/config/docker/setup.conf.real"
  ln -s "setup.conf.real" "${TEMP_DIR}/config/docker/setup.conf"

  run bash -c "$(_src); _migrate_legacy_setup_conf '${TEMP_DIR}' '${TPL_DIR}'"
  assert_success
  assert [ -f "${TEMP_DIR}/.setup.conf" ]
  assert [ ! -L "${TEMP_DIR}/.setup.conf" ]
  run cat "${TEMP_DIR}/.setup.conf"
  assert_output --partial "rule_1 = string:omniverse_web_viewer"
  assert_output --partial "env_1 = SIGNALING_SERVER=localhost"
  # The link is consumed; the file it named is not the migration's to
  # touch.
  assert [ ! -e "${TEMP_DIR}/config/docker/setup.conf" ]
  assert [ -f "${TEMP_DIR}/config/docker/setup.conf.real" ]
}
