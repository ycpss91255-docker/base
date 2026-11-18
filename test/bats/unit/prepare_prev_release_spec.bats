#!/usr/bin/env bats
#
# Unit tests for the released-tree window that
# script/test/prepare-prev-release.sh resolves (base#1729).
#
# The window is every stable release from the support floor up to, but not
# including, the tree under test (base#1055, base#1041). Which tags those
# are is a fact about UPSTREAM, not about whatever tags this checkout
# happens to hold, so these tests drive the script through its own entry
# point from a scratch root -- a copy of the script, `dist` linked to the
# real one, a written .version -- with `git` mocked to stand in for the
# local object store and for upstream separately.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  create_mock_dir

  ROOT="${BATS_TEST_TMPDIR}/root"
  mkdir -p "${ROOT}/script/test"
  cp /source/script/test/prepare-prev-release.sh "${ROOT}/script/test/"
  ln -s /source/dist "${ROOT}/dist"

  LOCAL_TAGS="${BATS_TEST_TMPDIR}/local.tags"
  UPSTREAM_TAGS="${BATS_TEST_TMPDIR}/upstream.tags"
  : > "${LOCAL_TAGS}"
  : > "${UPSTREAM_TAGS}"
  _mock_git
}

teardown() {
  cleanup_mock_dir
}

# A git that holds LOCAL_TAGS in its object store and reaches an upstream
# listing UPSTREAM_TAGS. `fetch` copies the tags its refspecs name from
# upstream into the local store, or fails without touching it when
# FETCH_FAILS exists; `ls-remote` exits 128 (upstream unreachable) when
# LS_REMOTE_FAILS exists; `rev-parse` succeeds only for a tag the local
# store holds; `archive` emits a release tree whose .version is the tag.
# Everything else succeeds silently.
_mock_git() {
  mock_cmd "git" '
    _local="'"${LOCAL_TAGS}"'"
    _up="'"${UPSTREAM_TAGS}"'"
    _fail="'"${BATS_TEST_TMPDIR}/fetch.fails"'"
    _lsfail="'"${BATS_TEST_TMPDIR}/ls-remote.fails"'"
    _args=" ${*} "
    case "${_args}" in
      *" tag "*)
        cat "${_local}"
        exit 0 ;;
      *" ls-remote "*)
        [[ -e "${_lsfail}" ]] && exit 128
        while IFS= read -r _t; do
          printf "0000000000000000000000000000000000000000\trefs/tags/%s\n" "${_t}"
        done < "${_up}"
        exit 0 ;;
      *" fetch "*)
        [[ -e "${_fail}" ]] && exit 128
        for _a in "$@"; do
          case "${_a}" in
            *"refs/tags/v*:"*) cat "${_up}" >> "${_local}" ;;
            *refs/tags/*:*)
              _want="${_a##*:refs/tags/}"
              grep -qxF "${_want}" "${_up}" && printf "%s\n" "${_want}" >> "${_local}" ;;
          esac
        done
        sort -u "${_local}" | sort -rV -o "${_local}"
        exit 0 ;;
      *" rev-parse "*)
        _ref="${!#}"
        _ref="${_ref#refs/tags/}"
        _ref="${_ref%"^{commit}"}"
        grep -qxF "${_ref}" "${_local}"
        exit ;;
      *" archive "*)
        _tag="${!#}"
        _tree="$(mktemp -d)"
        printf "%s\n" "${_tag}" > "${_tree}/.version"
        tar -c -C "${_tree}" .version
        exit 0 ;;
    esac
    exit 0'
}

# why: a window read from the local store alone is satisfied by whatever
# tags an earlier fetch left behind. A self-hosted workspace or an old clone
# that already carries v0.43.0 would never learn that upstream has since
# released v0.43.1, and the spec would stop driving the release a consumer
# on the 0.43 line is most likely sitting on. Expected window from
# base#1041 ("every release from the floor onward"): both 0.43 releases.
@test "prepare-prev-release: an owed upstream release missing locally is fetched into the window (base#1729)" {
  printf '%s\n' v0.43.0 > "${LOCAL_TAGS}"
  printf '%s\n' v0.43.1 v0.43.0 > "${UPSTREAM_TAGS}"
  printf '%s\n' v0.44.0-rc1 > "${ROOT}/.version"

  run bash "${ROOT}/script/test/prepare-prev-release.sh"
  assert_success

  run cat "${ROOT}/.prev-release/tags.txt"
  assert_output "$(printf '%s\n' v0.43.1 v0.43.0)"
}

# why: the window is every stable release from the v0.43.0 floor below the
# tree (base#1055, base#1041), not a count of the newest tags. With more
# than two releases owed, a newest-two slice drops v0.43.1 and v0.43.0 --
# the floor a consumer on the 0.43 line sits on -- and a window with no
# upper bound would add the tree's own release line. Here the tree is
# v0.44.1-rc1, so v0.44.1 sits above it and v0.42.0 below the floor: the
# window is exactly v0.44.0 v0.43.2 v0.43.1 v0.43.0. Upstream lists them
# oldest first, so the order comes from the version, not the listing.
@test "prepare-prev-release: the window is every release from v0.43.0 below an rc tree, newest first (base#1729)" {
  printf '%s\n' v0.42.0 > "${LOCAL_TAGS}"
  printf '%s\n' v0.42.0 v0.43.0 v0.43.1 v0.43.2 v0.44.0 v0.44.1 > "${UPSTREAM_TAGS}"
  printf '%s\n' v0.44.1-rc1 > "${ROOT}/.version"

  run bash "${ROOT}/script/test/prepare-prev-release.sh"
  assert_success

  run cat "${ROOT}/.prev-release/tags.txt"
  assert_output "$(printf '%s\n' v0.44.0 v0.43.2 v0.43.1 v0.43.0)"
}

# why: a window that includes the tree's own release resolves a driver arm
# to the tree under test, and that arm then upgrades the tree onto itself
# and asserts nothing. Built as v0.44.0 with the v0.44.0 tag present, the
# window holds only v0.43.0 (base#1041 table: releasing v0.44.0 drives
# v0.43.0).
@test "prepare-prev-release: the window leaves out the tree's own release (base#1729)" {
  printf '%s\n' v0.44.0 v0.43.0 v0.42.0 > "${LOCAL_TAGS}"
  printf '%s\n' v0.44.0 v0.43.0 v0.42.0 > "${UPSTREAM_TAGS}"
  printf '%s\n' v0.44.0 > "${ROOT}/.version"

  run bash "${ROOT}/script/test/prepare-prev-release.sh"
  assert_success

  run cat "${ROOT}/.prev-release/tags.txt"
  assert_output "v0.43.0"
}

# why: when an owed release cannot be fetched, carrying on with the local
# tags shrinks the window silently -- the suite goes green having never
# driven the release a consumer on the 0.43 line most likely sits on. The
# guard must name what is missing and refuse to write a window at all.
@test "prepare-prev-release: an owed release the fetch cannot bring in fails naming it, with no window (base#1729)" {
  printf '%s\n' v0.43.0 > "${LOCAL_TAGS}"
  printf '%s\n' v0.43.1 v0.43.0 > "${UPSTREAM_TAGS}"
  printf '%s\n' v0.44.0-rc1 > "${ROOT}/.version"
  : > "${BATS_TEST_TMPDIR}/fetch.fails"

  run bash "${ROOT}/script/test/prepare-prev-release.sh"
  assert_failure
  assert_output --partial "v0.43.1"
  assert [ ! -e "${ROOT}/.prev-release/tags.txt" ]
}

# why: with upstream unreachable the owed set cannot be read, and no rule
# the tree alone implies replaces it: a v0.43.1-rc1 tree owes v0.43.0, and
# any minimum built from the tree's minor misses patch releases like that
# one. Carrying on with the local tags then writes an empty window and goes
# green having driven nothing. The run must refuse, say upstream could not
# be listed, and write no tags.txt.
@test "prepare-prev-release: with upstream unreachable the run fails with no window (base#1729)" {
  printf '%s\n' v0.42.0 > "${LOCAL_TAGS}"
  printf '%s\n' v0.43.0 v0.42.0 > "${UPSTREAM_TAGS}"
  printf '%s\n' v0.43.1-rc1 > "${ROOT}/.version"
  : > "${BATS_TEST_TMPDIR}/ls-remote.fails"

  run bash "${ROOT}/script/test/prepare-prev-release.sh"
  assert_failure
  assert_output --partial "cannot list upstream release tags"
  assert [ ! -e "${ROOT}/.prev-release/tags.txt" ]
}

# why: membership is a fact about upstream. A tag only this checkout holds
# (a deleted upstream tag, or one made by hand) is not a release a consumer
# can be sitting on, and driving it tests nothing anyone runs. Upstream
# lists only v0.43.0, so the window is exactly that, whatever else the
# local store carries.
@test "prepare-prev-release: a tag only the checkout holds stays out of the window (base#1729)" {
  printf '%s\n' v0.43.9 v0.43.0 > "${LOCAL_TAGS}"
  printf '%s\n' v0.43.0 > "${UPSTREAM_TAGS}"
  printf '%s\n' v0.44.0-rc1 > "${ROOT}/.version"

  run bash "${ROOT}/script/test/prepare-prev-release.sh"
  assert_success

  run cat "${ROOT}/.prev-release/tags.txt"
  assert_output "v0.43.0"
}

# why: the window fills as soon as the floor is tagged below the tree, not
# only once the next minor ships (base#1041 table). A v0.44.0-rc1 tree with
# v0.43.0 and v0.42.0 upstream owes exactly v0.43.0; v0.42.0 is below the
# floor.
@test "prepare-prev-release: an rc tree one minor past the floor owes the floor alone (base#1729)" {
  printf '%s\n' v0.42.0 > "${LOCAL_TAGS}"
  printf '%s\n' v0.43.0 v0.42.0 > "${UPSTREAM_TAGS}"
  printf '%s\n' v0.44.0-rc1 > "${ROOT}/.version"

  run bash "${ROOT}/script/test/prepare-prev-release.sh"
  assert_success

  run cat "${ROOT}/.prev-release/tags.txt"
  assert_output "v0.43.0"
}

# why: an upstream that answers but lists no stable release is not an
# upstream that owes nothing -- it is a wrong remote or a broken listing.
# Reading that empty answer as "nothing owed" hands the window back to the
# local tags, so a checkout holding v0.43.0 goes green on whatever it
# happens to carry while the owed set was never read. The run must refuse
# and say upstream listed no stable release tags (base#1729 design).
@test "prepare-prev-release: an upstream that lists no stable release tags fails rather than falling back to local tags (base#1729)" {
  printf '%s\n' v0.44.0 v0.43.0 > "${LOCAL_TAGS}"
  printf '%s\n' v0.44.0-rc1 v0.43.0-rc5 > "${UPSTREAM_TAGS}"
  printf '%s\n' v0.44.0-rc1 > "${ROOT}/.version"

  run bash "${ROOT}/script/test/prepare-prev-release.sh"
  assert_failure
  assert_output --partial "upstream lists no stable release tags"
  assert [ ! -e "${ROOT}/.prev-release/tags.txt" ]
}

# why: the support floor is a 0.x rule, so a tree past 0.x has no window
# the rule can name. If that refusal only leaves a subshell, the run goes on
# to write an empty window and exit 0, and every driver arm then passes
# having driven nothing -- a silent green on a tree the rule does not cover.
@test "prepare-prev-release: a tree past 0.x fails with no window (base#1729)" {
  printf '%s\n' v0.44.0 v0.43.0 > "${LOCAL_TAGS}"
  printf '%s\n' v0.44.0 v0.43.0 > "${UPSTREAM_TAGS}"
  printf '%s\n' v1.0.0 > "${ROOT}/.version"

  run bash "${ROOT}/script/test/prepare-prev-release.sh"
  assert_failure
  assert_output --partial "v1.0.0"
  assert [ ! -e "${ROOT}/.prev-release/tags.txt" ]
}

# why: a .version that is not vX.Y.Z cannot be placed against the floor, so
# no owed set can be derived from it. Reading it as "nothing owed" writes an
# empty window and goes green; the run must refuse, naming the bad version.
@test "prepare-prev-release: a tree .version that is not vX.Y.Z fails with no window (base#1729)" {
  printf '%s\n' v0.44.0 v0.43.0 > "${LOCAL_TAGS}"
  printf '%s\n' v0.44.0 v0.43.0 > "${UPSTREAM_TAGS}"
  printf '%s\n' 0.44.0 > "${ROOT}/.version"

  run bash "${ROOT}/script/test/prepare-prev-release.sh"
  assert_failure
  assert_output --partial "'0.44.0' is not a vX.Y.Z version"
  assert [ ! -e "${ROOT}/.prev-release/tags.txt" ]
}

# why: a bad .version must refuse before upstream is asked anything, so an
# unreachable upstream cannot mask it behind a different failure.
@test "prepare-prev-release: with upstream unreachable a tree past 0.x still fails with no window (base#1729)" {
  printf '%s\n' v0.44.0 v0.43.0 > "${LOCAL_TAGS}"
  printf '%s\n' v1.0.0 > "${ROOT}/.version"
  : > "${BATS_TEST_TMPDIR}/ls-remote.fails"

  run bash "${ROOT}/script/test/prepare-prev-release.sh"
  assert_failure
  assert_output --partial "v1.0.0"
  assert [ ! -e "${ROOT}/.prev-release/tags.txt" ]
}
