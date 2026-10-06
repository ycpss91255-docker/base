#!/usr/bin/env bats
#
# Unit tests for check-base-version.sh — the per-repo base version
# monitor shipped via the subtree. Two surfaces:
#
#   * `compare <local> <remote>` — pure semver comparison, no network.
#     Exit 0 when <remote> is strictly newer (this repo is behind).
#   * `run` — full flow: resolve the local .base/.version, query base's
#     releases/latest, dedupe open tracking issues, file one when behind.
#
# `gh` is stubbed via mock_cmd so `run` never touches the network. The
# stub dispatches on "$1:$2" and reads its fixtures from MOCK_* env vars
# so each test can vary latest-release / existing-issues without
# rewriting the stub body.
#
# why: Version-compare + issue-open logic of the pull-based base version
# monitor: semver ordering (numeric, not lexical), a missing leading `v`,
# and the `run` path that opens exactly one labelled tracking issue per
# target version (dedup on an already-open one, no issue when up to date,
# loud failure on an empty API answer).

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  create_mock_dir

  SCRIPT="/source/dist/script/base/check-base-version.sh"

  # Deterministic local version via env override (the real script walks
  # up to .base/.version; tests pin it to a temp file instead).
  VERSION_FILE="${BATS_TEST_TMPDIR}/.version"
  export BASE_VERSION_FILE="${VERSION_FILE}"
  export MONITOR_LABEL="base-upgrade"

  # `gh issue create` invocations land here for assertion.
  export MOCK_CALLS="${BATS_TEST_TMPDIR}/gh-calls"
  : > "${MOCK_CALLS}"
}

teardown() { cleanup_mock_dir; }

# Stub `gh`: `api` echoes ${MOCK_LATEST}; `issue list` echoes
# ${MOCK_EXISTING} (newline-separated open-issue titles); `issue create`
# records its argv to ${MOCK_CALLS}. Single-quoted body so the env refs
# expand at stub runtime, not at mock_cmd authoring time.
_stub_gh() {
  mock_cmd "gh" '
case "$1:$2" in
  api:*)        printf "%s\n" "${MOCK_LATEST}" ;;
  issue:list)   printf "%s" "${MOCK_EXISTING:-}"
                # Opt-in late write (${MOCK_EXISTING_LATE_FILE}): titles
                # that arrive only after a reader which stops reading has
                # already left, so the write finds no reader. `exec` so
                # the SIGPIPE becomes the exit status of this stub.
                if [[ -n "${MOCK_EXISTING_LATE_FILE:-}" ]]; then
                  sleep 0.2
                  exec cat "${MOCK_EXISTING_LATE_FILE}"
                fi
                ;;
  issue:create) printf "create %s\n" "$*" >> "${MOCK_CALLS}"; printf "https://x/issues/1\n" ;;
  *)            printf "unexpected gh %s\n" "$*" >&2; exit 9 ;;
esac
'
}

# ════════════════════════════════════════════════════════════════════
# compare — pure semver, numeric per-field (not lexical)
# ════════════════════════════════════════════════════════════════════

@test "compare: newer minor is behind (v0.41.0 < v0.42.0)" {
  run bash "${SCRIPT}" compare v0.41.0 v0.42.0
  assert_success
}

@test "compare: equal versions are not behind" {
  run bash "${SCRIPT}" compare v0.41.0 v0.41.0
  assert_failure
}

@test "compare: older remote is not behind" {
  run bash "${SCRIPT}" compare v0.42.0 v0.41.0
  assert_failure
}

@test "compare: newer patch is behind" {
  run bash "${SCRIPT}" compare v0.41.0 v0.41.1
  assert_success
}

@test "compare: numeric not lexical (v0.9.7 < v0.10.0)" {
  run bash "${SCRIPT}" compare v0.9.7 v0.10.0
  assert_success
}

@test "compare: newer major is behind (v0.41.0 < v1.0.0)" {
  run bash "${SCRIPT}" compare v0.41.0 v1.0.0
  assert_success
}

@test "compare: tolerates a missing leading v" {
  run bash "${SCRIPT}" compare 0.41.0 0.42.0
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# run — end-to-end with stubbed gh
# ════════════════════════════════════════════════════════════════════

@test "run: behind -> opens a tracking issue naming the target version" {
  echo "v0.41.0" > "${VERSION_FILE}"
  export MOCK_LATEST="v0.42.0" MOCK_EXISTING=""
  _stub_gh

  run bash "${SCRIPT}" run
  assert_success
  assert_output --partial "v0.42.0"

  run cat "${MOCK_CALLS}"
  assert_output --partial "create"
  assert_output --partial "v0.42.0"
}

@test "run: opened issue carries the base-upgrade label" {
  echo "v0.41.0" > "${VERSION_FILE}"
  export MOCK_LATEST="v0.42.0" MOCK_EXISTING=""
  _stub_gh

  run bash "${SCRIPT}" run
  assert_success
  run cat "${MOCK_CALLS}"
  assert_output --partial "base-upgrade"
}

@test "run: up to date -> no issue created" {
  echo "v0.42.0" > "${VERSION_FILE}"
  export MOCK_LATEST="v0.42.0" MOCK_EXISTING=""
  _stub_gh

  run bash "${SCRIPT}" run
  assert_success
  [ ! -s "${MOCK_CALLS}" ]
}

@test "run: existing open issue for the target -> skip (dedup)" {
  echo "v0.41.0" > "${VERSION_FILE}"
  export MOCK_LATEST="v0.42.0" \
         MOCK_EXISTING="chore: .base behind base — upgrade v0.41.0 -> v0.42.0"
  _stub_gh

  run bash "${SCRIPT}" run
  assert_success
  [ ! -s "${MOCK_CALLS}" ]
}

@test "run: a gh still listing titles cannot make the dedupe gate miss an open issue (#905)" {
  # `gh issue list ... | <reader>` where the reader stops reading: it
  # leaves on the matching title, the gh still writing the rest of the
  # list takes SIGPIPE and exits 141, check-base-version.sh's file-scope
  # `pipefail` makes 141 the pipeline's status, and the `if` reads an
  # ALREADY-OPEN tracking issue as absent. The monitor then files a
  # second one -- and it runs weekly in every downstream repo, so the
  # duplicate is filed again on every poll until someone upgrades.
  echo "v0.41.0" > "${VERSION_FILE}"
  # Trailing newline on the early half: the late half is a separate
  # title, not a continuation of this one.
  export MOCK_LATEST="v0.42.0" \
         MOCK_EXISTING="chore: .base behind base — upgrade v0.41.0 -> v0.42.0
"
  export MOCK_EXISTING_LATE_FILE="${BATS_TEST_TMPDIR}/gh-issue-list.late"
  printf '%s\n' "chore: unrelated open issue" > "${MOCK_EXISTING_LATE_FILE}"
  _stub_gh

  run bash "${SCRIPT}" run
  assert_success
  assert_output --partial "already open"
  [ ! -s "${MOCK_CALLS}" ]
}

# _just_recipe_defined <word>... -> 0 iff `just <word>...` resolves in the
# justfile layering a CONSUMER actually gets: <repo>/justfile is a symlink
# to script/justfile (dist/script/justfile), and each leading word has to be
# a namespace that file's `mod?` lines register, with the last word a recipe
# in the namespace justfile that was walked to. `mod?` paths are
# repo-root-relative, and in a consumer every one of them is a symlink back
# into dist/, so dist/ is where the real file is read from.
_just_recipe_defined() {
  local _file="/source/dist/script/justfile"
  local _rel _word
  while (( $# > 1 )); do
    _word="${1}"; shift
    _rel="$(sed -nE "s/^mod\\??[[:space:]]+${_word}[[:space:]]+'([^']+)'.*/\\1/p" \
      "${_file}" | head -n1)"
    [[ -n "${_rel}" ]] || return 1
    _file="/source/dist/${_rel}"
    [[ -f "${_file}" ]] || return 1
  done
  grep -qE "^${1}([[:space:]]|:)" "${_file}"
}

# why: the command the monitor tells a human to run has to be a recipe
@test "run: the filed issue names an upgrade command a consumer's justfile defines (#1111)" {
  # The monitor's whole output is one issue in someone else's repo, and the
  # only actionable line in it is the command. `just upgrade` is not a
  # recipe in the layering a consumer gets -- that namespace is `base` --
  # so the reminder answered its own instruction with
  # `error: justfile does not contain recipe 'upgrade'`.
  #
  # Resolved against the shipped justfiles rather than compared to a string
  # copied out of the script: the justfiles are the independent source of
  # truth for what `just` accepts, so a later namespace rename turns this
  # red instead of agreeing with the stale body.
  echo "v0.41.0" > "${VERSION_FILE}"
  export MOCK_LATEST="v0.42.0" MOCK_EXISTING=""
  _stub_gh

  run bash "${SCRIPT}" run
  assert_success

  local _line
  _line="$(grep -m1 -E '^just[[:space:]]' "${MOCK_CALLS}")" \
    || { echo "the filed issue body names no 'just' command"; return 1; }

  # Drop `just` itself and the version argument; what is left is the
  # namespace path plus the recipe.
  local -a _words=() _path=()
  local _word
  read -r -a _words <<< "${_line}"
  for _word in "${_words[@]:1}"; do
    [[ "${_word}" =~ ^v?[0-9] ]] && continue
    _path+=("${_word}")
  done
  (( ${#_path[@]} > 0 )) \
    || { echo "no recipe words in: ${_line}"; return 1; }

  _just_recipe_defined "${_path[@]}" \
    || { echo "'just ${_path[*]}' is not a recipe a consumer's justfile defines"; return 1; }
}

@test "run: empty latest from API -> fails without creating an issue" {
  echo "v0.41.0" > "${VERSION_FILE}"
  export MOCK_LATEST="" MOCK_EXISTING=""
  _stub_gh

  run bash "${SCRIPT}" run
  assert_failure
  [ ! -s "${MOCK_CALLS}" ]
}
