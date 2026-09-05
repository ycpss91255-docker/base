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
  # A second synthetic release beyond it, so "upgrade again" below is a real
  # forward move rather than a no-op the driver could shortcut.
  NEXT_VER_2="v99.0.1"

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
  # ... and the release after it, identical but for the version file. An
  # upstream a consumer can upgrade to twice is what lets the repeatability
  # arm below drive a second REAL upgrade; every other arm names its target
  # explicitly and never sees this tag.
  printf '%s\n' "${NEXT_VER_2}" > "${_work}/.version"
  git -C "${_work}" commit -q -a -m "${NEXT_VER_2}"
  git -C "${_work}" tag "${NEXT_VER_2}"
  git init --bare -q "${CUR_BARE}"
  git -C "${_work}" push -q "${CUR_BARE}" "${NEXT_VER}" "${NEXT_VER_2}"
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

# ── Making the fixture consumer-shaped ──────────────────────────────────────
#
# _seed_consumer leaves a repo whose Dockerfile is base's OWN -- init.sh
# copies it out of the release being seeded. Base ships both halves of
# every `.base/` path in that file, so every COPY source in it resolves by
# construction, and _assert_dockerfile_copy_sources_exist below can only
# ever report what base already knows about itself.
#
# Real consumers do not have that Dockerfile. They have a DERIVATIVE, and
# where base copied a subtree directory wholesale they hand-listed its
# files -- two spellings are in the wild, one COPY per file and every file
# on a single COPY. Those references break on a base file move exactly the
# same way the wholesale one does, and nothing here was asking about them.
#
# So the fixture is re-spelled before the upgrade runs. Which statements
# get re-spelled is DERIVED from the Dockerfile plus the vendored subtree,
# never listed: a wholesale-directory COPY qualifies when hand-listing its
# contents is EQUIVALENT to it, which Docker makes true exactly when the
# destination ends in `/` (a multi-source COPY flattens into a destination
# directory; without the trailing slash the hand-listed form is a
# different statement, not a different spelling of the same one). A tree
# that stops offering such a statement fails rather than quietly
# consumerising nothing.

# The tree the hand-listed smoke heal under repair acts on. Named
# once because two things below have to agree about it: whether this arm's
# release still ships it, and whether the re-spelling covered it.
_RETIRED_SMOKE_TREE=".base/test/smoke"

# _copy_expandable_source <line>
#   The single `.base/`-rooted directory source of a one-line COPY whose
#   destination ends in `/`. Non-zero when the line is not that shape.
#   Quoted and `$`-bearing arguments are out by construction: their value
#   exists only at build time, so neither side of the equivalence above
#   can be checked against the tree.
_copy_expandable_source() {
  local _line="$1"
  [[ "${_line}" =~ ^[[:space:]]*COPY[[:space:]] ]] || return 1
  # A backslash-continued statement spans lines; re-spelling it in place
  # would need the fold, and no shipped Dockerfile writes one. The
  # "expanded nothing" failure below is what reports it if that changes.
  [[ "${_line}" == *'\' ]] && return 1

  local -a _args=()
  read -r -a _args <<< "${_line}"
  local -a _pos=()
  local _a
  for _a in "${_args[@]:1}"; do
    [[ "${_a}" == --* ]] && continue
    _pos+=("${_a}")
  done
  (( ${#_pos[@]} == 2 )) || return 1

  local _src="${_pos[0]}" _dst="${_pos[1]}"
  [[ "${_dst}" == */ ]] || return 1
  [[ "${_src}" == .base/* ]] || return 1
  [[ "${_src}" == *'$'* ]] && return 1
  printf '%s' "${_src}"
}

# _consumerise_dir_copies
#   Re-spell every qualifying wholesale-directory COPY in the seeded
#   consumer's Dockerfile as the two hand-listed spellings real consumers
#   wrote. Fails when it re-spelled nothing: a fixture that silently
#   consumerises zero statements is the vacuous pass this exists to end.
#
#   A non-zero total is not by itself proof that the hand-listed HEAL runs
#   in this arm. The heal only fires on the retired flat
#   `.base/test/smoke` tree, and whether the seeded release ships one is a
#   property of the release, not something to list here: the N-1 release
#   (flat tree) does, the N release (already on `.base/dist/test/bats/smoke`)
#   does not. So the retired tree is asked for on disk, and where it is
#   present the re-spelling must have covered it -- otherwise this arm
#   re-spells only statements the migration never touches while its counter
#   still reads healthy. Where it is absent the heal is genuinely not
#   exercised by that arm, and the arm still asserts what it can: that every
#   hand-listed source survives the upgrade.
_consumerise_dir_copies() {
  local _df="${CONSUMER}/Dockerfile"
  local _tmp="${BATS_TEST_TMPDIR}/Dockerfile.consumerised"
  local _count=0
  local _retired=0
  : > "${_tmp}"

  local _line _src _rel _all
  local -a _files=()
  while IFS= read -r _line; do
    if ! _src="$(_copy_expandable_source "${_line}")" \
      || [[ ! -d "${CONSUMER}/${_src%/}" ]]; then
      printf '%s\n' "${_line}" >> "${_tmp}"
      continue
    fi
    _files=()
    mapfile -t _files < <(cd "${CONSUMER}" && find "${_src%/}" -type f | sort)
    if (( ${#_files[@]} == 0 )); then
      printf '%s\n' "${_line}" >> "${_tmp}"
      continue
    fi
    # One COPY per file, then every file on one COPY. Substituting into
    # the original line keeps that statement's own flags, destination and
    # column alignment, so what changes is the spelling and nothing else.
    for _rel in "${_files[@]}"; do
      printf '%s\n' "${_line/"${_src}"/"${_rel}"}" >> "${_tmp}"
    done
    _all="${_files[*]}"
    printf '%s\n' "${_line/"${_src}"/"${_all}"}" >> "${_tmp}"
    _count=$(( _count + 1 ))
    [[ "${_src%/}" == "${_RETIRED_SMOKE_TREE}" ]] && _retired=$(( _retired + 1 ))
  done < "${_df}"

  (( _count > 0 )) \
    || fail "consumerised nothing: the seeded Dockerfile has no wholesale-directory .base/ COPY with a directory destination, so this arm would assert against the same shape base itself ships"
  if [[ -d "${CONSUMER}/${_RETIRED_SMOKE_TREE}" ]]; then
    (( _retired > 0 )) \
      || fail "consumerised ${_count} statement(s) but none of ${_RETIRED_SMOKE_TREE}, which this release ships: the hand-listed smoke heal is what this arm exists to drive, and nothing here would reach it"
  fi
  mv "${_tmp}" "${_df}"
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
  # Ask the delivery guard below about a shape a consumer actually has,
  # not about base's own Dockerfile handed back to base.
  _consumerise_dir_copies
  git -C "${CONSUMER}" commit -q -a \
    -m "chore: hand-list the subtree COPY sources"

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

# _assert_release_migrates_env <tag>
#   The consumer is sitting on a release whose rule was ".env is YOURS", so
#   it has a hand-written, gitignored, unrecoverable .env. The upgrade that
#   flips the rule is driven by THAT release's upgrade.sh, which knows
#   nothing about the migration -- so the migration has to ride something
#   the old driver still calls into on the new tree.
_assert_release_migrates_env() {
  local _tag="${1:?BUG: _assert_release_migrates_env expects a tag}"

  _seed_current_remote
  _seed_released_remote "${_tag}"
  _seed_consumer "${_tag}"

  printf '# my machine\nROS_DOMAIN_ID=42\nAPI_TOKEN=secret\n' > "${CONSUMER}/.env"

  local _upgrade
  _upgrade="$(_released_entry upgrade.sh)"
  cd "${CONSUMER}"
  run env TEMPLATE_REMOTE="file://${CUR_BARE}" "${_upgrade}" "${NEXT_VER}"
  assert_success

  # The user's file survived, under the name that is now the user's.
  assert [ -f "${CONSUMER}/.env.local" ]
  run cat "${CONSUMER}/.env.local"
  assert_output --partial "ROS_DOMAIN_ID=42"
  assert_output --partial "API_TOKEN=secret"
  # The name it vacated is ours again: init.sh's own `setup apply` has
  # already regenerated `.env` by the time the upgrade returns, and that
  # regeneration carries none of the user's values -- which is precisely
  # the overwrite the migration exists to get ahead of.
  assert [ -f "${CONSUMER}/.env" ]
  run cat "${CONSUMER}/.env"
  assert_output --partial "Auto-generated"
  refute_output --partial "API_TOKEN=secret"
}

# _assert_release_stages_migrated_files <tag>
#   The upgrade COMMITS what its migrations rewrote, and commits nothing
#   else. The failure this arm exists for is not a broken tree: it is a
#   tree that builds locally and pushes a lie -- the commit says
#   "template references to <ver>" while the path migration that makes
#   the repo buildable is still sitting unstaged, and the same run's last
#   words are "git push".
#
#   Which release drives is the whole point. The consumer's own vendored
#   upgrade.sh does the committing, and it stages a pair of filenames
#   hardcoded when it shipped, so the run that rewrote the files is the
#   only party that can stage them for every driver at once.
#
#   EVERY release in the window drives this, not just the oldest, and the
#   difference matters because the obvious reading of the paragraph above
#   is wrong. The oldest release is the only one whose Step 5 misses the
#   DOCKERFILE -- v0.42.0's reaches it -- so an arm that asserted only
#   "the Dockerfile is in the commit" really would go quiet as the window
#   slides forward. What this arm asserts is the whole listing, and no
#   released Step 5 stages `.dockerignore`, the re-pointed wrappers or the
#   monitor workflow, whatever its vintage. Measured, not assumed:
#   disabling the staging in `init.sh` and driving with the NEWEST release
#   fails here on ` M .dockerignore`. Pinning both ends is what stops the
#   next reader from narrowing this back to one tag on the premise the
#   first paragraph suggests.
_assert_release_stages_migrated_files() {
  local _tag="${1:?BUG: _assert_release_stages_migrated_files expects a tag}"

  _seed_current_remote
  _seed_released_remote "${_tag}"
  _seed_consumer "${_tag}"
  _consumerise_dir_copies

  git -C "${CONSUMER}" commit -q -a \
    -m "chore: hand-list the subtree COPY sources"

  # A file of the user's own, sitting in the tree while they upgrade.
  # Nothing migrates it, so nothing may stage it. Untracked rather than
  # modified-and-tracked because `git subtree pull` refuses to run at all
  # over unstaged changes -- an untracked file it does not mind, and a
  # `git add -A` sweep would take it just the same.
  printf 'notes I have not committed yet\n' > "${CONSUMER}/NOTES.md"

  # And a file of the user's own that IS one of the paths the resync
  # publishes. NOTES.md alone cannot see the difference between "stages
  # its own output" and "stages the published list wholesale": it is
  # outside that list either way, so a sweep of the list passes it. A hook
  # stub is inside the list AND never overwritten -- init.sh seeds it once
  # and leaves it alone forever after -- so whatever is in one is the
  # user's. Dropped from the index rather than modified in place for the
  # reason above: `git subtree pull` refuses to run over a modified
  # tracked file, and untracked is the same shape to the staging step.
  git -C "${CONSUMER}" rm -q --cached script/hooks/pre/build.sh
  git -C "${CONSUMER}" commit -q -m "chore: take a hook stub back"
  printf '# my own hook step\n' >> "${CONSUMER}/script/hooks/pre/build.sh"

  local _before
  _before="$(cat "${CONSUMER}/Dockerfile")"

  local _upgrade
  _upgrade="$(_released_entry upgrade.sh)"
  cd "${CONSUMER}"
  run env TEMPLATE_REMOTE="file://${CUR_BARE}" "${_upgrade}" "${NEXT_VER}"
  assert_success

  # This arm only says something where the migrations actually rewrote
  # the Dockerfile; a release that stops migrating anything must fail
  # here rather than pass with nothing to stage.
  [[ "$(cat "${CONSUMER}/Dockerfile")" != "${_before}" ]] \
    || fail "${_tag}: the upgrade rewrote nothing in the Dockerfile, so this arm asserts nothing about staging it"

  # The rewrite is IN the commit the upgrade made ...
  run git -C "${CONSUMER}" show --format= --name-only HEAD
  assert_line "Dockerfile"
  # ... and the working tree no longer disagrees with it.
  run git -C "${CONSUMER}" status --porcelain -- Dockerfile
  assert_output ""
  # The user's own two files are still the user's to commit -- and they are
  # the ONLY things the upgrade left behind. Everything else in that listing
  # would be the resync's own output: re-pointed wrappers, the justfile
  # layering, the monitor workflow. Mechanical output of the run the commit
  # claims to be, so a commit that says "template references to <ver>" while
  # they sit unstaged describes a tree that does not exist. Both directions
  # are in this one assertion: too little staged adds a line, and the
  # customised hook stub swept into the commit removes one.
  run git -C "${CONSUMER}" status --porcelain
  assert_output "?? NOTES.md
?? script/hooks/pre/build.sh"
}

# _assert_upgrade_leaves_an_upgradable_tree <tag>
#   Upgrade, then upgrade AGAIN -- driving the second run with the SAME
#   command that drove the first.
#
#   Every other arm in this file asks whether ONE upgrade succeeds, and
#   answers it about the tree the upgrade STARTED from. A frozen path that
#   is missing from the tree the upgrade PRODUCES is invisible to all of
#   them: the run exits 0, `.version` is true, no symlink dangles, the
#   Dockerfile builds -- and the next time the user types the command their
#   release documented, it is gone. `.base/upgrade.sh` was absent for two
#   release candidates with this suite green for exactly that reason -- the
#   same blindness that let the v0.42.0 `init.sh` breakage ship, and the
#   arm names below carry the issue refs.
#
#   The command is RE-RUN, never re-resolved. Re-resolving asks "does the
#   new tree have SOME upgrade entry point", which is true of the broken
#   tree too; what a consumer holds is the one path their own release told
#   them to type. So this names no file of its own -- the path comes from
#   the release under test -- and a roster of "files that must exist" is
#   exactly what it refuses to be: it goes stale the day a third frozen
#   path appears, which is the failure this repo keeps repeating. "The tree
#   an upgrade produces can be upgraded from" covers the next one for free.
#
#   The support window is the scope, and it is the right one. `_release_tag`
#   resolves from the repo's real tags, so once no supported release names a
#   given path these arms stop saying anything about it -- which is exactly
#   when ADR-00000006 stops requiring a forwarder for it. An arm that goes
#   quiet about one path is that boundary moving, not this guard decaying.
_assert_upgrade_leaves_an_upgradable_tree() {
  local _tag="${1:?BUG: _assert_upgrade_leaves_an_upgradable_tree expects a tag}"

  _seed_current_remote
  _seed_released_remote "${_tag}"
  _seed_consumer "${_tag}"

  # Resolved ONCE, from the release the consumer is actually sitting on.
  # Every invocation below is this same string.
  local _upgrade
  _upgrade="$(_released_entry upgrade.sh)"

  cd "${CONSUMER}"
  run env TEMPLATE_REMOTE="file://${CUR_BARE}" "${_upgrade}" "${NEXT_VER}"
  assert_success

  # The resync legitimately leaves review-able output behind (see the NOTE
  # above), and `git subtree` refuses to start against a dirty tree. So the
  # fixture does what the upgrade's own closing instructions tell the user
  # to do before they carry on.
  git -C "${CONSUMER}" add -A
  git -C "${CONSUMER}" commit -q -m "chore: commit the resync" || true

  # The same command, on the tree it just produced.
  run env TEMPLATE_REMOTE="file://${CUR_BARE}" "${_upgrade}" "${NEXT_VER_2}"
  assert_success
  [ "$(cat "${CONSUMER}/.base/.version")" = "${NEXT_VER_2}" ]
}

# why: An upgrade that deletes the command that performed it passes every
# other arm here -- one successful run over a tree nobody asks to upgrade
# again -- and fails at the consumer's terminal on their next release
@test "the newest released upgrade.sh leaves a tree its own command can upgrade again (#1077)" {
  _assert_upgrade_leaves_an_upgradable_tree "$(_release_tag 1)"
}

# why: The newest release is already on the path the current tree ships, so
# only the older driver names a path that has to be kept alive by a
# forwarder; pinning both ends is what stops this narrowing to one tag
@test "the previous released upgrade.sh leaves a tree its own command can upgrade again (N-1, #1077)" {
  _assert_upgrade_leaves_an_upgradable_tree "$(_release_tag 2)"
}

# why: The commit is made by the consumer's OWN released upgrade.sh, so
# the only proof that the migrated Dockerfile lands in it is to let that
# script drive; a unit test on the staging helper passes while the real
# upgrade still leaves the file behind
@test "the oldest supported upgrade.sh commits what the migrations rewrote (#1036)" {
  _assert_release_stages_migrated_files "$(_release_tag 2)"
}

# why: The oldest driver is the only one whose own Step 5 misses the
# Dockerfile, so an arm that ran only there would go quiet as the window
# slides forward and the fix could be deleted with the suite green; the
# newest driver still leaves the rest of the resync unstaged without it
@test "the newest supported upgrade.sh commits what the migrations rewrote (#1036)" {
  _assert_release_stages_migrated_files "$(_release_tag 1)"
}

@test "a released upgrade.sh still migrates a hand-written .env to .env.local (#868)" {
  _assert_release_migrates_env "$(_release_tag 1)"
}

@test "the newest released upgrade.sh drives the current tree to a working consumer" {
  _assert_release_can_upgrade "$(_release_tag 1)"
}

@test "the previous released upgrade.sh drives the current tree to a working consumer (N-1)" {
  _assert_release_can_upgrade "$(_release_tag 2)"
}
