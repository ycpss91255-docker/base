#!/usr/bin/env bats
#
# Integration test: the manifest init.sh PRINTS must equal the set of
# committable files its existing-repo resync actually WRITES.
#
# This is the anti-decay half of `--list-installed-paths`. A manifest that
# is maintained by hand stops being true the first time init.sh learns to
# install one more file, and nothing notices -- which is the exact failure
# mode a delivery audit exists to catch, reproduced one layer down. So the
# list is not trusted: a real resync runs against a real consumer fixture
# and the files it leaves behind are diffed against what init.sh claims.
#
# Committable is the right set to compare, because that is the set a remote
# audit can observe. Derived artifacts the resync also materialises (.env,
# compose.yaml, the log tree) are excluded by asking git, not by a second
# hand-written list -- init.sh writes the consumer's .gitignore during the
# same run, so the fixture answers the question itself.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"

  CONSUMER="${BATS_TEST_TMPDIR}/consumer"
  # The consumer's OWN vendored copy, not /source: base's checkout carries
  # .git, which the self-run guard reads as "this is the template source"
  # and refuses. The vendored copy is also what a real upgrade executes.
  INIT="./.base/dist/script/base/init.sh"
}

# _seed_consumer
#   An existing repo in the shape init.sh's resync path expects: a git repo
#   with a Dockerfile at the root (the existing-vs-new discriminator) and a
#   vendored `.base/` carrying the real dist payload. Deliberately seeded
#   with NOTHING the resync installs, so every path it creates shows up as
#   new and the comparison has no pre-filled holes.
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

  git -C "${CONSUMER}" add -A
  git -C "${CONSUMER}" commit -q -m "consumer before resync"
}

# _list_tree <dir>
#   Every path under the consumer except its own git metadata and the
#   vendored subtree -- neither is something the resync installs.
_list_tree() {
  local _dir="$1"
  (
    cd "${_dir}" || exit 1
    find . -mindepth 1 \
      \( -path ./.git -o -path ./.base \) -prune -o -print \
      | sed 's|^\./||' \
      | LC_ALL=C sort
  )
}

# _committable_new_paths
#   The paths the resync added that a git-hosted audit could actually see:
#   plain directories dropped (a manifest lists files, and every parent dir
#   is implied), and anything the freshly written .gitignore claims dropped
#   too. Symlinks survive the directory filter on purpose -- a symlink to a
#   directory is a committed blob, and several of them are the delivery.
_committable_new_paths() {
  local _before="$1" _after="$2" _p
  while IFS= read -r _p; do
    [[ -n "${_p}" ]] || continue
    if [[ -d "${CONSUMER}/${_p}" && ! -L "${CONSUMER}/${_p}" ]]; then
      continue
    fi
    if git -C "${CONSUMER}" check-ignore -q -- "${_p}"; then
      continue
    fi
    printf '%s\n' "${_p}"
  done < <(LC_ALL=C comm -13 "${_before}" "${_after}")
}

@test "the printed manifest equals what the resync installs (refs #927)" {
  _seed_consumer

  local _before="${BATS_TEST_TMPDIR}/before"
  local _after="${BATS_TEST_TMPDIR}/after"
  local _created="${BATS_TEST_TMPDIR}/created"
  local _claimed="${BATS_TEST_TMPDIR}/claimed"

  _list_tree "${CONSUMER}" > "${_before}"

  cd "${CONSUMER}"
  run bash "${INIT}"
  assert_success

  _list_tree "${CONSUMER}" > "${_after}"
  _committable_new_paths "${_before}" "${_after}" | LC_ALL=C sort > "${_created}"

  run bash "${INIT}" --list-installed-paths
  assert_success
  printf '%s\n' "${lines[@]}" | LC_ALL=C sort > "${_claimed}"

  # Both directions matter. A path installed but not claimed is a file no
  # audit will ever look for; a path claimed but not installed is an audit
  # that reports every repo as broken.
  run diff -u "${_claimed}" "${_created}"
  assert_success
}
