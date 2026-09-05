#!/usr/bin/env bats
#
# Integration test: every path the existing-repo resync touches must lie
# under a root init.sh names as protected.
#
# `_init_protected_paths` is the rollback surface. `_init_snapshot` copies
# exactly those roots before the first mutation and `_init_restore_tree`
# puts back exactly those roots on failure, so a mutation whose root is
# absent from the list survives a rollback that undoes everything around
# it. That is not a partial restore; it is a tree in a state no run ever
# produced, which is worse than either endpoint -- a Dockerfile restored
# to a COPY whose source the un-rolled-back half already moved away.
#
# The unit half of this used to `assert_line` a handful of entries copied
# out of the list. Restating a subset of a list cannot detect an addition
# to the code the list describes, which is how a whole new migration
# arrived with neither of its two roots protected and every spec green.
# So nothing here names a path: a real resync runs against a real consumer
# fixture, the tree is hashed before and after, and every entry that moved
# is required to fall under some root the function itself prints.
#
# SCOPE is `_init_existing_repo`, not `main`. The rollback bracket opens
# and closes inside that function; what `main` does afterwards (`_call_setup`
# and the artifacts it generates) is outside the bracket by design and is
# not the rollback's to restore.
#
# Directories are compared only through their contents. An empty directory
# left behind by a rollback carries nothing a consumer can lose and git
# does not record one, so the manifest holds files and symlinks -- a
# symlink to a directory included, several of them being the delivery.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"

  CONSUMER="${BATS_TEST_TMPDIR}/consumer"
  # The consumer's OWN vendored copy, not /source: base's checkout carries
  # .git, which the self-run guard reads as "this is the template source".
  # The vendored copy is also what a real upgrade executes, and sourcing it
  # from that path is what resolves REPO_ROOT to the fixture.
  INIT="./.base/dist/script/base/init.sh"
}

# _seed_consumer
#   A repo carrying the shapes the resync has migrations for, so the run
#   both CREATES and DELETES: a pre-relocation root wrapper and Makefile
#   that `_create_symlinks` removes on sight, a hand-written `.env` from
#   before the name meant "ours", and the flat `test/smoke/` tree the
#   per-stage migration moves. A fixture seeded with none of these would
#   exercise only the create half and pass over every deletion.
_seed_consumer() {
  mkdir -p "${CONSUMER}/.base"
  git -C "${CONSUMER}" init -q -b main
  git -C "${CONSUMER}" config user.email t@t
  git -C "${CONSUMER}" config user.name t

  cp -a /source/dist "${CONSUMER}/.base/dist"
  echo "v0.0.0-test" > "${CONSUMER}/.base/.version"

  cat > "${CONSUMER}/Dockerfile" <<'EOF'
FROM busybox AS devel
EOF
  printf 'IMAGE_NAME=hand-written\n' > "${CONSUMER}/.env"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${CONSUMER}/build.sh"
  printf 'all:\n\t@true\n' > "${CONSUMER}/Makefile"
  mkdir -p "${CONSUMER}/test/smoke"
  printf '@test "env" { :; }\n' > "${CONSUMER}/test/smoke/env.bats"

  git -C "${CONSUMER}" add -A
  git -C "${CONSUMER}" commit -q -m "consumer before resync"
}

# _manifest <dir> <out>
#   path + content identity for every non-directory entry outside the
#   consumer's git metadata and vendored subtree. A symlink is recorded by
#   its target, so a wrapper repointed in place reads as changed.
_manifest() {
  local _dir="$1" _out="$2" _p
  : > "${_out}"
  while IFS= read -r _p; do
    [[ -n "${_p}" ]] || continue
    if [[ -L "${_dir}/${_p}" ]]; then
      printf '%s\tlink:%s\n' "${_p}" "$(readlink -- "${_dir}/${_p}")" >> "${_out}"
    else
      printf '%s\tfile:%s\n' \
        "${_p}" "$(sha256sum -- "${_dir}/${_p}" | cut -d' ' -f1)" >> "${_out}"
    fi
  done < <(
    cd "${_dir}" || exit 1
    find . -mindepth 1 \
      \( -path ./.git -o -path ./.base \) -prune -o ! -type d -print \
      | sed 's|^\./||' \
      | LC_ALL=C sort
  )
}

# _changed_paths <before> <after>
#   Every path whose presence or content differs. A line unique to either
#   manifest means created, deleted or rewritten -- all three are things a
#   rollback has to be able to undo, so all three are held to the same rule.
_changed_paths() {
  LC_ALL=C sort "$1" "$2" | uniq -u | cut -f1 | LC_ALL=C sort -u
}

# _uncovered <changed-file> <roots-file>
#   The changed paths that no protected root contains. A root covers itself
#   and everything beneath it, which is the same containment
#   `_init_restore_tree` implements when it replaces a whole root.
_uncovered() {
  local _p _root _covered
  while IFS= read -r _p; do
    [[ -n "${_p}" ]] || continue
    _covered=false
    while IFS= read -r _root; do
      _root="${_root%/}"
      [[ -n "${_root}" ]] || continue
      if [[ "${_p}" == "${_root}" || "${_p}" == "${_root}/"* ]]; then
        _covered=true
        break
      fi
    done < "$2"
    [[ "${_covered}" == "true" ]] || printf '%s\n' "${_p}"
  done < "$1"
}

# why: The rollback surface is derived from what the resync does, not from
# a list restated in the spec
@test "every path the resync touches lies under a protected root (refs #1050)" {
  _seed_consumer

  local _before="${BATS_TEST_TMPDIR}/before"
  local _after="${BATS_TEST_TMPDIR}/after"
  local _changed="${BATS_TEST_TMPDIR}/changed"
  local _roots="${BATS_TEST_TMPDIR}/roots"

  _manifest "${CONSUMER}" "${_before}"

  # Sourced and called directly: the bracket this invariant belongs to is
  # `_init_existing_repo`, and running the script would also run the
  # post-bracket setup whose artifacts are deliberately unprotected.
  run bash -c "cd '${CONSUMER}' && source '${INIT}' && _init_existing_repo"
  assert_success

  _manifest "${CONSUMER}" "${_after}"
  _changed_paths "${_before}" "${_after}" > "${_changed}"

  # Guard against a vacuous pass. An empty diff, or a fixture whose
  # migrations all declined, would satisfy the assertion below without
  # having tested anything, so require the two mutations this fixture was
  # built to trigger to have actually happened.
  assert [ -s "${_changed}" ]
  assert [ -f "${CONSUMER}/test/bats/smoke/shared/env.bats" ]
  assert [ ! -e "${CONSUMER}/test/smoke" ]
  assert [ -f "${CONSUMER}/.env.local" ]

  run bash -c "source '${CONSUMER}/${INIT#./}' && _init_protected_paths"
  assert_success
  printf '%s\n' "${lines[@]}" > "${_roots}"

  run _uncovered "${_changed}" "${_roots}"
  assert_success
  assert_output ""
}
