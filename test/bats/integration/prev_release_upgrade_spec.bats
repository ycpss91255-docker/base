#!/usr/bin/env bats
#
# Integration test: a RELEASED upgrade.sh must still drive THIS tree.
#
# An upgrade is never driven by the code in this repo. It is driven by the
# consumer's own vendored copy of upgrade.sh, which shipped in an older
# release and cannot be changed retroactively. Every other spec in this
# suite runs the CURRENT upgrade.sh against the CURRENT tree, so a file
# move that an old caller names by hand is invisible here and only shows up
# at a consumer's terminal -- after the subtree pull has already committed.
#
# So these tests do the only thing that can see it: take the real released
# tree, stand it up as a consumer's `.base/`, and let ITS scripts drive the
# upgrade to a tree built out of this working copy.
#
# The released trees are materialised host-side by
# script/test/prepare-prev-release.sh into /source/.prev-release/ (the
# suite's container cannot reach the git object store of a worktree
# checkout, whose `.git` is a file pointing outside the mount). Which
# releases those are is resolved from the repo's own tags every run, never
# hardcoded.
#
# The "next release" the consumer upgrades INTO is this working tree with
# its .version rewritten to a synthetic version and tagged as such -- the
# only two synthetic bytes in the fixture. Everything else on both sides is
# the real thing.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"

  PREV_RELEASE_DIR="/source/.prev-release"
  TAGS_FILE="${PREV_RELEASE_DIR}/tags.txt"
  # The version the working tree pretends to be released as. Must differ
  # from every real tag so the upgrade is a real forward move, and it must
  # match the tree's own .version or the released upgrade.sh's post-pull
  # integrity check reports a version mismatch and rolls back.
  NEXT_VER="v99.0.0"

  CUR_BARE="${BATS_TEST_TMPDIR}/current.git"
  OLD_BARE="${BATS_TEST_TMPDIR}/released.git"
  CONSUMER="${BATS_TEST_TMPDIR}/consumer"
}

# ── Fixture helpers ─────────────────────────────────────────────────────────

# _release_tag <n>
#   The n-th newest stable release tag (1 = newest), as resolved on the
#   host. Fails loudly rather than skipping: a silently empty tag list would
#   turn both tests into no-ops, which is the exact failure shape this spec
#   exists to prevent.
_release_tag() {
  local _n="${1:?BUG: _release_tag expects an index}"
  [[ -f "${TAGS_FILE}" ]] \
    || fail "missing ${TAGS_FILE} -- run the suite through 'just test' (script/test/prepare-prev-release.sh populates it host-side)"
  local _tag
  _tag="$(sed -n "${_n}p" "${TAGS_FILE}")"
  [[ -n "${_tag}" ]] \
    || fail "${TAGS_FILE} has no line ${_n} -- fewer release tags than the compatibility window claims"
  printf '%s' "${_tag}"
}

# _copy_tree <src> <dest> [tar_exclude...]
#   Copy a directory tree, preserving modes and symlinks but NOT ownership.
#   `-o` (no-same-owner) is the load-bearing flag: the suite runs as root
#   over a checkout owned by the host user, so a preserved uid makes every
#   subsequent git command in the copy fail with "detected dubious
#   ownership" -- a failure that has nothing to do with what is being
#   tested.
_copy_tree() {
  local _src="${1:?BUG: _copy_tree expects a source}"
  local _dest="${2:?BUG: _copy_tree expects a destination}"
  shift 2
  mkdir -p "${_dest}"
  tar -C "${_src}" "$@" -cf - . | tar -C "${_dest}" -x -o -f -
}

# _git_init_repo <dir>
#   A repo with an identity, so git-subtree's internal commit-tree works.
_git_init_repo() {
  local _dir="${1:?BUG: _git_init_repo expects a dir}"
  mkdir -p "${_dir}"
  git -C "${_dir}" init -q -b main
  git -C "${_dir}" config user.email t@t
  git -C "${_dir}" config user.name t
}

# _seed_current_remote
#   Publish THIS working tree as the next release: a bare repo carrying one
#   commit of the checkout, tagged NEXT_VER, served over file:// so nothing
#   here touches the network.
_seed_current_remote() {
  local _work="${BATS_TEST_TMPDIR}/current"
  # .git is a whole object store in CI and a dangling worktree pointer
  # locally; .prev-release/ holds the released trees this very spec reads;
  # coverage/ and log/ are run artifacts. None of them is part of what a
  # consumer receives.
  _copy_tree /source "${_work}" \
    --exclude=./.git \
    --exclude=./.prev-release \
    --exclude=./coverage \
    --exclude=./log
  printf '%s\n' "${NEXT_VER}" > "${_work}/.version"

  _git_init_repo "${_work}"
  git -C "${_work}" add -A
  git -C "${_work}" commit -q -m "${NEXT_VER}"
  git -C "${_work}" tag "${NEXT_VER}"
  git init --bare -q "${CUR_BARE}"
  git -C "${_work}" push -q "${CUR_BARE}" "${NEXT_VER}"
}

# _seed_released_remote <tag>
#   Same, for the released tree the consumer is sitting on. Its history is
#   irrelevant -- only the tree the tag names ever reaches the consumer --
#   so one commit is enough.
_seed_released_remote() {
  local _tag="${1:?BUG: _seed_released_remote expects a tag}"
  local _work="${BATS_TEST_TMPDIR}/released"
  local _src="${PREV_RELEASE_DIR}/${_tag}"
  [[ -d "${_src}" ]] \
    || fail "missing ${_src} -- script/test/prepare-prev-release.sh did not materialise ${_tag}"
  _copy_tree "${_src}" "${_work}"
  _git_init_repo "${_work}"
  git -C "${_work}" add -A
  git -C "${_work}" commit -q -m "${_tag}"
  git -C "${_work}" tag "${_tag}"
  git init --bare -q "${OLD_BARE}"
  git -C "${_work}" push -q "${OLD_BARE}" "${_tag}"
}

# _seed_consumer <tag>
#   A repo bootstrapped exactly the way the README tells a user to: empty
#   commit, subtree add, run the template's init.sh. Which path init.sh
#   lives at is the release's business, not ours -- probe both, because
#   moving it is precisely what this spec is here to survive.
_seed_consumer() {
  local _tag="${1:?BUG: _seed_consumer expects a tag}"
  _git_init_repo "${CONSUMER}"
  git -C "${CONSUMER}" commit -q --allow-empty -m "chore: initial commit"
  git -C "${CONSUMER}" subtree add -q --prefix=.base \
    "file://${OLD_BARE}" "${_tag}" --squash

  local _init
  _init="$(_released_entry init.sh)"
  ( cd "${CONSUMER}" && "${_init}" ) >/dev/null 2>&1 \
    || fail "${_tag}: its own ${_init} failed to bootstrap a consumer"
  git -C "${CONSUMER}" add -A
  git -C "${CONSUMER}" commit -q -m "chore: bootstrap at ${_tag}"
}

# _released_entry <script>
#   Repo-root-relative path to one of the released tree's entry points,
#   flat root first (pre-dist releases) then the dist/ location.
_released_entry() {
  local _name="${1:?BUG: _released_entry expects a script name}"
  if [[ -x "${CONSUMER}/.base/${_name}" ]]; then
    printf '%s' "./.base/${_name}"
  else
    printf '%s' "./.base/dist/script/base/${_name}"
  fi
}

# _dangling_symlinks
#   Every symlink in the consumer that resolves to nothing. This is the
#   assertion that matters: it names no path, so it keeps working across
#   any future layout, and a half-finished upgrade shows up here as the
#   wrapper set the user actually types (justfile, script/*.sh) pointing
#   into a tree that no longer has them.
_dangling_symlinks() {
  local _link
  while IFS= read -r _link; do
    [[ -e "${CONSUMER}/${_link}" ]] || printf '%s\n' "${_link}"
  done < <(cd "${CONSUMER}" && find . -path ./.git -prune -o -type l -print)
}

# _dockerfile_copy_sources
#   Every build-context path the consumer's post-upgrade Dockerfile hands to
#   a COPY, one per line. Backslash continuations are folded first, so a
#   hand-listed multi-line COPY is read as the one statement it is; a COPY
#   with N sources contributes all N (the last argument is the destination).
#
#   Two classes are deliberately NOT emitted, because neither is a path in
#   the build context:
#     --from=<stage|image>  resolves inside another stage, not on disk
#     an argument containing $  is a build ARG (ENTRYPOINT_FILE, CONFIG_SRC)
#                               whose value only exists at build time
_dockerfile_copy_sources() {
  local _file="${1:?BUG: _dockerfile_copy_sources expects a Dockerfile}"
  awk '
    { line = line $0 }
    /\\[[:space:]]*$/ { sub(/\\[[:space:]]*$/, " ", line); next }
    { print line; line = "" }
    END { if (line != "") print line }
  ' "${_file}" \
    | awk '
        /^[[:space:]]*COPY[[:space:]]/ {
          if ($0 ~ /--from=/) { next }
          n = 0
          for (i = 2; i <= NF; i++) {
            if ($i ~ /^--/) { continue }
            arg[++n] = $i
          }
          for (i = 1; i < n; i++) {
            src = arg[i]
            gsub(/^"|"$/, "", src)
            if (src ~ /\$/) { continue }
            print src
          }
        }
      '
}

# _assert_dockerfile_copy_sources_exist
#   Every COPY source the post-upgrade Dockerfile names must be present in
#   the consumer. This is the assertion the rest of this spec structurally
#   could not make: exit status, .version, dangling symlinks and
#   `just --list` are all satisfied by a consumer whose Dockerfile still
#   names the pre-move layout, and the first thing that notices is
#   BuildKit refusing to compute a cache key -- at the user's terminal,
#   after the subtree pull has already committed.
#
#   It names no path of its own: it reads whatever the Dockerfile ends up
#   saying and asks the filesystem, so it keeps working across any future
#   relocation instead of encoding today's one.
_assert_dockerfile_copy_sources_exist() {
  local _missing=()
  local _src _ok
  while IFS= read -r _src; do
    [[ -n "${_src}" ]] || continue
    # A glob source is satisfied by any match; a plain source by itself.
    # `compgen -G` is used ONLY for real globs: handed a pattern with no
    # metacharacter but a trailing slash it reports success for a path that
    # does not exist, which is precisely how `.base/test/smoke/` would slip
    # through the assertion written to catch it.
    _ok=0
    if [[ "${_src}" == *[*?[]* ]]; then
      compgen -G "${CONSUMER}/${_src}" > /dev/null 2>&1 && _ok=1
    elif [[ -e "${CONSUMER}/${_src%/}" ]]; then
      _ok=1
    fi
    [[ "${_ok}" -eq 1 ]] || _missing+=("${_src}")
  done < <(_dockerfile_copy_sources "${CONSUMER}/Dockerfile")

  [[ "${#_missing[@]}" -eq 0 ]] \
    || fail "post-upgrade Dockerfile COPYs sources that do not exist -- the consumer cannot build: ${_missing[*]}"
}

# ── The compatibility contract ──────────────────────────────────────────────

# _assert_release_can_upgrade <tag>
#   Drive the whole thing and assert the consumer is left WORKING, not just
#   left with a bumped version file.
_assert_release_can_upgrade() {
  local _tag="${1:?BUG: _assert_release_can_upgrade expects a tag}"

  _seed_current_remote
  _seed_released_remote "${_tag}"
  _seed_consumer "${_tag}"

  local _upgrade
  _upgrade="$(_released_entry upgrade.sh)"

  cd "${CONSUMER}"
  run env TEMPLATE_REMOTE="file://${CUR_BARE}" "${_upgrade}" "${NEXT_VER}"
  assert_success

  # The version claim is true.
  [ "$(cat "${CONSUMER}/.base/.version")" = "${NEXT_VER}" ]

  # Nothing the user types is broken. In the failure this spec was written
  # for, .version already said the new version while justfile and all seven
  # script/*.sh wrappers dangled.
  run _dangling_symlinks
  assert_output ""

  # The single documented entry point still resolves.
  run just --list
  assert_success

  # The repo can still be BUILT. Everything above is satisfied by a
  # consumer whose Dockerfile names the layout the release just deleted.
  _assert_dockerfile_copy_sources_exist
}
# NOTE: a clean `git status` is deliberately NOT asserted. A released
# upgrade.sh stages only the specific paths it rewrites, so a genuine
# layout change legitimately leaves the init.sh resync (re-pointed
# wrappers, newly seeded files) uncommitted for the user to review. That
# is review-able output, not damage. The failure this spec guards is the
# opposite shape: a CLEAN tree whose version file claims a release the
# upgrade never finished reaching.

@test "the newest released upgrade.sh drives the current tree to a working consumer" {
  _assert_release_can_upgrade "$(_release_tag 1)"
}

@test "the previous released upgrade.sh drives the current tree to a working consumer (N-1)" {
  _assert_release_can_upgrade "$(_release_tag 2)"
}
