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
# LS_REMOTE_FAILS exists; `archive` emits a release tree whose .version is
# the tag. Everything else succeeds silently.
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

# why: with upstream unreachable the owed set cannot be read, and treating
# that as "nothing owed" lets the local tags alone define the window -- a
# checkout holding only v0.44.0 would go green having never driven
# v0.43.0. Offline the run is degraded, says so, and still refuses a
# window missing the minimum the tree alone implies: v0.m.0 for every
# 43 <= m < tree minor, here v0.43.0 and v0.44.0 (base#1041).
@test "prepare-prev-release: with upstream unreachable a window missing a v0.m.0 below the tree fails as degraded, naming it (base#1729)" {
  printf '%s\n' v0.44.0 > "${LOCAL_TAGS}"
  printf '%s\n' v0.44.0 v0.43.0 > "${UPSTREAM_TAGS}"
  printf '%s\n' v0.45.0-rc1 > "${ROOT}/.version"
  : > "${BATS_TEST_TMPDIR}/ls-remote.fails"

  run bash "${ROOT}/script/test/prepare-prev-release.sh"
  assert_failure
  assert_output --partial "degraded"
  assert_output --partial "v0.43.0"
}
