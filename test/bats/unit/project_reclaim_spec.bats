#!/usr/bin/env bats
#
# project_reclaim_spec.bats - the scoped reclaim: what it collects, and
# every input it refuses to collect.
#
# The subject is dist/script/docker/lib/project_reclaim.sh, which removes a
# compose artifact only when it can PROVE the artifact belongs to a base
# checkout that no longer exists. The host these run on is shared -- a
# self-hosted runner tree, a GitLab runner, ollama, buildx state -- so the
# failure this file is mostly about is not "litter survived", it is "the
# collector removed something it could not prove was its own". Every
# refusal below is therefore a test in its own right, not a footnote to the
# happy path.
#
# The fake daemon. Rows are `<kind>|<id>|<name>|<project label>|<age
# seconds>`; the shim records every argv so a test can assert what was
# never issued at all. It is deliberately MORE permissive than the real
# daemon in one place: `docker network ls --filter label=<key>` excludes an
# unlabelled network at the daemon, so a faithful shim would make the
# "unlabelled artifact is left alone" assertion measure docker's filter
# rather than this script's refusal. The shim emits unlabelled rows too, so
# what the assertion measures is the script.
#
# The fake git supplies the live worktree list -- one path per line of
# ${GIT_WORKTREES} -- and fails outright when GIT_FAKE_FAIL=1, which is the
# case that must ABORT rather than conclude "no live worktrees, so
# everything is an orphan".

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  LIB=/source/dist/script/docker/lib/project_reclaim.sh

  TEMP_DIR="$(mktemp -d)"
  export TEMP_DIR

  DOCKER_STATE="${TEMP_DIR}/docker-state"
  DOCKER_CALLS="${TEMP_DIR}/docker-calls"
  DOCKER_REMOVED="${TEMP_DIR}/docker-removed"
  GIT_WORKTREES="${TEMP_DIR}/git-worktrees"
  export DOCKER_STATE DOCKER_CALLS DOCKER_REMOVED GIT_WORKTREES
  : > "${DOCKER_STATE}"
  : > "${DOCKER_CALLS}"
  : > "${DOCKER_REMOVED}"
  : > "${GIT_WORKTREES}"

  # The checkout the reclaim is invoked for. Real directory: the tool-tag
  # rules read a Dockerfile out of each live path.
  ROOT="${TEMP_DIR}/root"
  mkdir -p "${ROOT}/dockerfile"
  printf 'FROM alpine\n' > "${ROOT}/dockerfile/Dockerfile.test-tools"
  export ROOT

  BIN_DIR="${TEMP_DIR}/bin"
  mkdir -p "${BIN_DIR}"

  cat > "${BIN_DIR}/docker" <<'EOS'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${DOCKER_CALLS}"
_now="$(date +%s)"

# What `docker <kind> inspect --format '{{json .Created}}'` emits: a QUOTED
# RFC3339 string. The unquoted `{{.Created}}` is not interchangeable -- on a
# network it renders a Go time value (`2026-09-03 11:07:45.1237 +0800 CST`)
# that `date -d` refuses outright, which is how a real network's age became
# unreadable and the orphan was spared instead of collected. The shim emits
# the real shape so every age-dependent case below is a guard on that.
_created() { printf '"%s"\n' "$(date -u -d "@${1}" +%Y-%m-%dT%H:%M:%SZ)"; }

case "${1-} ${2-}" in
  "network ls")
    while IFS='|' read -r _k _id _name _proj _age; do
      [[ "${_k}" == network ]] || continue
      printf '%s|%s|%s\n' "${_id}" "${_name}" "${_proj}"
    done < "${DOCKER_STATE}"
    ;;
  "network inspect")
    _target="${!#}"
    while IFS='|' read -r _k _id _name _proj _age; do
      [[ "${_k}" == network && "${_id}" == "${_target}" ]] || continue
      _created "$(( _now - _age ))"
    done < "${DOCKER_STATE}"
    ;;
  "network rm")
    shift 2
    for _t in "$@"; do printf 'network %s\n' "${_t}" >> "${DOCKER_REMOVED}"; done
    ;;
  "image inspect")
    _target="${!#}"
    while IFS='|' read -r _k _id _name _proj _age; do
      [[ "${_k}" == image && "${_name}" == "${_target}" ]] || continue
      _created "$(( _now - _age ))"
    done < "${DOCKER_STATE}"
    ;;
  *)
    case "${1-}" in
      ps)
        while IFS='|' read -r _k _id _name _proj _age; do
          [[ "${_k}" == container ]] || continue
          printf '%s\n' "${_proj}"
        done < "${DOCKER_STATE}"
        ;;
      images)
        while IFS='|' read -r _k _id _name _proj _age; do
          [[ "${_k}" == image ]] || continue
          printf '%s\n' "${_name}"
        done < "${DOCKER_STATE}"
        ;;
      rmi)
        shift
        for _t in "$@"; do
          [[ "${_t}" == -* ]] && continue
          printf 'image %s\n' "${_t}" >> "${DOCKER_REMOVED}"
        done
        ;;
      *) exit 0 ;;
    esac
    ;;
esac
EOS
  chmod +x "${BIN_DIR}/docker"

  cat > "${BIN_DIR}/git" <<'EOS'
#!/usr/bin/env bash
set -u
if [[ "${GIT_FAKE_FAIL:-0}" == "1" ]]; then
  exit 128
fi
while IFS= read -r _p; do
  [[ -n "${_p}" ]] || continue
  printf 'worktree %s\nHEAD 0000000000000000000000000000000000000000\nbranch refs/heads/x\n\n' "${_p}"
done < "${GIT_WORKTREES}"
EOS
  chmod +x "${BIN_DIR}/git"

  export PATH="${BIN_DIR}:${PATH}"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# _project <path> -- the project name a path resolves to, computed the way
# script/test/test.sh computes it, so a fixture row can be written for a
# path without asking the code under test what it thinks that path is.
_project() {
  local _h
  _h="$(printf '%s' "${1}" | sha256sum | cut -d' ' -f1)"
  printf 'base-%s\n' "${_h:0:12}"
}

_reclaim() {
  run bash -c "source ${LIB}; _reclaim_orphan_projects '${ROOT}' \"\${GRACE:-6h}\""
}

# ── the derivation is ONE rule, shared with its producer ────────────────────

@test "_reclaim_project_for_path derives the same base-<12hex> name test.sh does" {
  run bash -c "source ${LIB}; _reclaim_project_for_path '/some/checkout'"
  assert_success
  assert_output "$(_project /some/checkout)"
}

@test "script/test/test.sh derives its compose project name through the shared producer" {
  # Two implementations of one rule is how they come to disagree: test.sh
  # must DELEGATE, not re-hash.
  run grep -n '_reclaim_project_for_path' /source/script/test/test.sh
  assert_success
}

@test "script/test/test.sh derives its test-tools tag through the shared producer" {
  run grep -nE '_reclaim_tool_(tag_for_path|dockerfile_hash)' /source/script/test/test.sh
  assert_success
}

# ── what it collects ────────────────────────────────────────────────────────

@test "an orphan project's network is collected" {
  local _dead="${TEMP_DIR}/gone"
  printf '%s\n' "${ROOT}" > "${GIT_WORKTREES}"
  printf 'network|n1|%s_default|%s|86400\n' "$(_project "${_dead}")" "$(_project "${_dead}")" \
    > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  assert_output --partial "network n1"
}

# ── every input it refuses to place ─────────────────────────────────────────

@test "a live worktree's project is NOT collected" {
  local _live="${TEMP_DIR}/live"
  mkdir -p "${_live}"
  printf '%s\n%s\n' "${ROOT}" "${_live}" > "${GIT_WORKTREES}"
  printf 'network|n1|%s_default|%s|86400\n' "$(_project "${_live}")" "$(_project "${_live}")" \
    > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

@test "the checkout the reclaim runs in is never collected, worktree list or not" {
  # A throwaway copy is a path that exists right now and is in nobody's
  # worktree list. The one it is certainly running in is its own.
  printf '%s\n' "${TEMP_DIR}/somewhere-else" > "${GIT_WORKTREES}"
  printf 'network|n1|%s_default|%s|86400\n' "$(_project "${ROOT}")" "$(_project "${ROOT}")" \
    > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

@test "a project with a container attached is NOT collected" {
  local _dead="${TEMP_DIR}/gone"
  printf '%s\n' "${ROOT}" > "${GIT_WORKTREES}"
  {
    printf 'network|n1|%s_default|%s|86400\n' "$(_project "${_dead}")" "$(_project "${_dead}")"
    printf 'container|c1|whatever|%s|86400\n' "$(_project "${_dead}")"
  } > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

@test "an artifact with no com.docker.compose.project label is NOT collected" {
  printf '%s\n' "${ROOT}" > "${GIT_WORKTREES}"
  printf 'network|n1|some_default||86400\n' > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

@test "an artifact whose project label is not base- prefixed is NOT collected" {
  printf '%s\n' "${ROOT}" > "${GIT_WORKTREES}"
  printf 'network|n1|gitlab_runner_default|gitlab_runner|86400\n' > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

@test "a base- label whose suffix is not 12 hex digits is NOT collected" {
  printf '%s\n' "${ROOT}" > "${GIT_WORKTREES}"
  printf 'network|n1|base-release_default|base-release|86400\n' > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

@test "an orphan created inside the grace window is NOT collected" {
  # A throwaway copy running `just test` right now is a path that exists
  # and that no worktree list names. Its project is minutes old.
  local _dead="${TEMP_DIR}/gone"
  printf '%s\n' "${ROOT}" > "${GIT_WORKTREES}"
  printf 'network|n1|%s_default|%s|60\n' "$(_project "${_dead}")" "$(_project "${_dead}")" \
    > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

@test "an unreadable worktree list ABORTS rather than collecting everything" {
  local _dead="${TEMP_DIR}/gone"
  printf 'network|n1|%s_default|%s|86400\n' "$(_project "${_dead}")" "$(_project "${_dead}")" \
    > "${DOCKER_STATE}"
  GIT_FAKE_FAIL=1 run bash -c "source ${LIB}; _reclaim_orphan_projects '${ROOT}'"
  assert_failure
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

@test "an unreadable worktree list issues no removal command at all" {
  local _dead="${TEMP_DIR}/gone"
  printf 'network|n1|%s_default|%s|86400\n' "$(_project "${_dead}")" "$(_project "${_dead}")" \
    > "${DOCKER_STATE}"
  GIT_FAKE_FAIL=1 run bash -c "source ${LIB}; _reclaim_orphan_projects '${ROOT}'"
  assert_failure
  run grep -c 'rm' "${DOCKER_CALLS}"
  assert_output "0"
}

@test "images are never collected by the project rule (the tooling tag is shared)" {
  # test-tools is content-hash tagged, so its project label names the
  # checkout that happened to build it, never the checkouts that use it.
  local _dead="${TEMP_DIR}/gone"
  printf '%s\n' "${ROOT}" > "${GIT_WORKTREES}"
  printf 'image|i1|test-tools:aaaaaaaaaaaa|%s|86400\n' "$(_project "${_dead}")" \
    > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

# ── test-tools tag retention ────────────────────────────────────────────────

# _tag <content> -- the tag a Dockerfile of that content resolves to.
_tag() {
  local _h
  _h="$(printf '%s' "${1}" | sha256sum | cut -d' ' -f1)"
  printf 'test-tools:%s\n' "${_h:0:12}"
}

@test "tag retention keeps the current tree's tag and the last N and retires the rest" {
  printf '%s\n' "${ROOT}" > "${GIT_WORKTREES}"
  local _cur
  _cur="$(_tag 'FROM alpine
')"
  {
    printf 'image|i0|%s||10\n'                 "${_cur}"
    printf 'image|i1|test-tools:111111111111||100\n'
    printf 'image|i2|test-tools:222222222222||200\n'
    printf 'image|i3|test-tools:333333333333||300\n'
    printf 'image|i4|test-tools:444444444444||400\n'
  } > "${DOCKER_STATE}"
  run bash -c "source ${LIB}; _reclaim_tool_tags '${ROOT}' 2"
  assert_success
  run cat "${DOCKER_REMOVED}"
  refute_output --partial "${_cur}"
  refute_output --partial "test-tools:111111111111"
  refute_output --partial "test-tools:222222222222"
  assert_output --partial "test-tools:333333333333"
  assert_output --partial "test-tools:444444444444"
}

@test "tag retention keeps a tag a live worktree still resolves to" {
  local _other="${TEMP_DIR}/other"
  mkdir -p "${_other}/dockerfile"
  printf 'FROM debian\n' > "${_other}/dockerfile/Dockerfile.test-tools"
  printf '%s\n%s\n' "${ROOT}" "${_other}" > "${GIT_WORKTREES}"
  local _cur _live
  _cur="$(_tag 'FROM alpine
')"
  _live="$(_tag 'FROM debian
')"
  {
    printf 'image|i0|%s||10\n'  "${_cur}"
    printf 'image|i1|%s||9999\n' "${_live}"
    printf 'image|i2|test-tools:222222222222||8888\n'
  } > "${DOCKER_STATE}"
  # keep=0 empties the recency window, so the ONLY thing that can spare
  # ${_live} here -- the oldest of the three -- is a live checkout still
  # resolving it.
  run bash -c "source ${LIB}; _reclaim_tool_tags '${ROOT}' 0"
  assert_success
  run cat "${DOCKER_REMOVED}"
  refute_output --partial "${_live}"
  assert_output --partial "test-tools:222222222222"
}

@test "tag retention leaves a tag it cannot place alone" {
  # A published / pinned tag is nothing this derivation mints.
  printf '%s\n' "${ROOT}" > "${GIT_WORKTREES}"
  {
    printf 'image|i1|test-tools:local||9999\n'
    printf 'image|i2|ghcr.io/x/test-tools:v1.2.3||9999\n'
    printf 'image|i3|ollama/ollama:latest||9999\n'
  } > "${DOCKER_STATE}"
  run bash -c "source ${LIB}; _reclaim_tool_tags '${ROOT}' 0"
  assert_success
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

@test "tag retention ABORTS on an unreadable worktree list" {
  printf 'image|i1|test-tools:111111111111||9999\n' > "${DOCKER_STATE}"
  GIT_FAKE_FAIL=1 run bash -c "source ${LIB}; _reclaim_tool_tags '${ROOT}' 0"
  assert_failure
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

@test "the retained-tag count is derived from the live checkouts, not a buried literal" {
  local _a="${TEMP_DIR}/a" _b="${TEMP_DIR}/b"
  mkdir -p "${_a}/dockerfile" "${_b}/dockerfile"
  printf 'FROM debian\n' > "${_a}/dockerfile/Dockerfile.test-tools"
  printf 'FROM ubuntu\n' > "${_b}/dockerfile/Dockerfile.test-tools"
  printf '%s\n%s\n%s\n' "${ROOT}" "${_a}" "${_b}" > "${GIT_WORKTREES}"
  run bash -c "source ${LIB}; _reclaim_tool_tags_default_keep '${ROOT}'"
  assert_success
  assert_output "3"
}

@test "the retained-tag count is overridable by the environment" {
  printf '%s\n' "${ROOT}" > "${GIT_WORKTREES}"
  run bash -c "export BASE_TOOL_TAGS_KEEP=9; source ${LIB}; _reclaim_tool_tags_default_keep '${ROOT}'"
  assert_success
  assert_output "9"
}
