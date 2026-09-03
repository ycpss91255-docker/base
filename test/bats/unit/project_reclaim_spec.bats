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
# THE PROOF IS ON THE ARTIFACT. base's compose.yaml stamps the absolute
# path of the checkout that ran it onto the network, as the label
# `base.checkout.path`; the collector reads that path back and asks whether
# anything is still there. So the shape of every fixture below is a network
# row carrying a path, and the assertions are about which paths make it a
# candidate. Two of them exist because the enumerating rule this replaced
# got them wrong with a real `docker network rm` issued: a sweep launched
# from an unrelated repository, and a live checkout whose path contains a
# newline.
#
# The fake daemon. Rows are
# `<kind>|<id>|<name>|<project label>|<age seconds>|<checkout label>`;
# a literal `\n` inside the checkout field becomes a real newline, which is
# how a line-based fixture file can describe a path that is not
# line-shaped. The shim records every argv so a test can assert what was
# never issued at all, and it FAILS the run if `network inspect` is asked
# for anything but the JSON-marshalled creation time plus both labels --
# the template is what makes a real network's age readable and its path
# unambiguous, so a change to it must not pass silently here.
#
# It is deliberately MORE permissive than the real daemon in one place:
# `docker network ls --filter label=<key>` excludes an unlabelled network
# at the daemon, so a faithful shim would make the "unattributable artifact
# is left alone" assertion measure docker's filter rather than this
# script's refusal. The shim lists every network, so what the assertion
# measures is the script.
#
# The fake git exists only to be ignored: the collector consults no git at
# all, and two tests below prove it by handing it a git that describes a
# DIFFERENT repository, and by removing git from PATH entirely.

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

  # The checkout a sweep is invoked from. A real directory: the tool-tag
  # rules read a Dockerfile out of each live path.
  ROOT="${TEMP_DIR}/root"
  mkdir -p "${ROOT}/dockerfile"
  printf 'FROM alpine\n' > "${ROOT}/dockerfile/Dockerfile.test-tools"
  export ROOT

  # An unrelated git repository to launch a sweep from. The rule this
  # replaced answered with THIS repo's worktrees and deleted every base
  # project outside them.
  FOREIGN="${TEMP_DIR}/foreign"
  mkdir -p "${FOREIGN}"
  export FOREIGN

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
# unreadable and the orphan was spared instead of collected.
_created() { printf '"%s"\n' "$(date -u -d "@${1}" +%Y-%m-%dT%H:%M:%SZ)"; }
# A `\n` in a fixture's checkout field is a real newline in the label.
_unesc() { local _s="${1}"; printf '%s' "${_s//\\n/$'\n'}"; }

case "${1-} ${2-}" in
  "network ls")
    [[ "${DOCKER_FAIL_NETWORK_LS:-0}" == 1 ]] && exit 1
    while IFS='|' read -r _k _id _name _proj _age _ck; do
      [[ "${_k}" == network ]] || continue
      printf '%s\n' "${_id}"
    done < "${DOCKER_STATE}"
    ;;
  "network inspect")
    [[ "${DOCKER_FAIL_INSPECT:-0}" == 1 ]] && exit 1
    case "$*" in
      *'{{json .Created}}'*'com.docker.compose.project'*'base.checkout.path'*) ;;
      *) printf 'fake docker: unexpected network inspect format: %s\n' "$*" >&2; exit 2 ;;
    esac
    _target="${!#}"
    while IFS='|' read -r _k _id _name _proj _age _ck; do
      [[ "${_k}" == network && "${_id}" == "${_target}" ]] || continue
      _created "$(( _now - _age ))"
      printf '%s\n' "${_proj}"
      _unesc "${_ck}"; printf '\n'
      printf '%s\n' '--- end of network facts ---'
    done < "${DOCKER_STATE}"
    ;;
  "network rm")
    shift 2
    for _t in "$@"; do printf 'network %s\n' "${_t}" >> "${DOCKER_REMOVED}"; done
    ;;
  "image inspect")
    _target="${!#}"
    # Two readers, told apart by the template they ask for: the tag
    # retention wants only the creation time, the orphan-image rule wants
    # the creation time plus the checkout label with a terminator after it
    # (the path is the field that may contain a newline).
    case "$*" in
      *'end of image facts'*)
        while IFS='|' read -r _k _id _name _proj _age _ck; do
          [[ "${_k}" == image && "${_name}" == "${_target}" ]] || continue
          _created "$(( _now - _age ))"
          _unesc "${_ck}"; printf '\n'
          printf '%s\n' '--- end of image facts ---'
        done < "${DOCKER_STATE}"
        ;;
      *)
        while IFS='|' read -r _k _id _name _proj _age _ck; do
          [[ "${_k}" == image && "${_name}" == "${_target}" ]] || continue
          _created "$(( _now - _age ))"
        done < "${DOCKER_STATE}"
        ;;
    esac
    ;;
  *)
    case "${1-}" in
      ps)
        [[ "${DOCKER_FAIL_PS:-0}" == 1 ]] && exit 1
        while IFS='|' read -r _k _id _name _proj _age _ck; do
          [[ "${_k}" == container ]] || continue
          printf '%s\n' "${_proj}"
        done < "${DOCKER_STATE}"
        ;;
      images)
        [[ "${DOCKER_FAIL_IMAGES:-0}" == 1 ]] && exit 1
        # `--filter label=base.checkout.path` is the daemon's own
        # narrowing to images that carry the provenance; the shim honours
        # it so a fixture without a path label is invisible to the
        # orphan-image rule exactly as it is to a real docker.
        _labelled_only=0
        case "$*" in *base.checkout.path*) _labelled_only=1 ;; esac
        while IFS='|' read -r _k _id _name _proj _age _ck; do
          [[ "${_k}" == image ]] || continue
          if (( _labelled_only )) && [[ -z "${_ck}" ]]; then continue; fi
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

# _net <id> <checkout path> <age seconds> -- a network row for a checkout.
_net() {
  printf 'network|%s|%s_default|%s|%s|%s\n' \
    "${1}" "$(_project "${2}")" "$(_project "${2}")" "${3}" "${2}"
}

_reclaim() {
  run bash -c "source ${LIB}; _reclaim_orphan_projects \"\${GRACE:-6h}\""
}

# _img <ref> <checkout path> <age seconds> -- a build image row carrying
# the provenance label. The empty project field is deliberate: nothing in
# the image rule reads it, and the proof is the path.
_img() {
  printf 'image|%s|%s||%s|%s\n' "${1//[^a-z0-9]/}" "${1}" "${3}" "${2}"
}

# ── the derivations base's self-test mints artifacts by ────────────────────

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

# ── what it collects ───────────────────────────────────────────────────────

@test "a network whose recorded checkout is gone is collected" {
  _net n1 "${TEMP_DIR}/gone" 86400 > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  assert_output --partial "network n1"
}

# ── the two shapes the enumerating rule got wrong ──────────────────────────

@test "a sweep launched from an unrelated repository spares every live checkout" {
  # THE BLOCKER this design closes. The rule this replaced built its live
  # set from `git worktree list` at the caller's root; run from a different
  # repository -- which is exactly where the shipped stop.sh runs it -- the
  # live set was that repo's worktrees, base's own checkouts appeared in
  # none of them, and their networks were removed. The fixture arms the
  # same trap: a git that describes only the foreign repo, and a cwd inside
  # it. The live networks must survive AND the dead one must still go, so a
  # passing run cannot be a run that did nothing.
  local _live="${TEMP_DIR}/live"
  mkdir -p "${_live}"
  printf '%s\n' "${FOREIGN}" > "${GIT_WORKTREES}"
  {
    _net n1 "${_live}" 86400
    _net n2 "${ROOT}" 86400
    _net n3 "${TEMP_DIR}/gone" 86400
  } > "${DOCKER_STATE}"
  run bash -c "cd '${FOREIGN}' && source ${LIB} && _reclaim_orphan_projects"
  assert_success
  run cat "${DOCKER_REMOVED}"
  refute_output --partial "network n1"
  refute_output --partial "network n2"
  assert_output --partial "network n3"
}

@test "a live checkout whose path contains a newline is NOT collected" {
  # `git worktree list --porcelain` does not escape a newline in a path, so
  # the enumerating rule read this live checkout as a shorter path that did
  # not exist and removed its network. The label is read per artifact with
  # the free-form field last, so every byte of the path survives.
  local _live="${TEMP_DIR}/live"$'\n'"newline"
  mkdir -p "${_live}"
  printf 'network|n1|weird_default|weird-project|86400|%s\\nnewline\n' \
    "${TEMP_DIR}/live" > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

@test "an orphan whose path contains a newline IS collected" {
  # The pair to the case above: a newline is not a reason to refuse, it is
  # a reason to read the whole field. Read wrongly in EITHER direction the
  # collector is broken, so both directions are pinned.
  printf 'network|n1|weird_default|weird-project|86400|%s\\nnewline\n' \
    "${TEMP_DIR}/gone" > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  assert_output --partial "network n1"
}

@test "the sweep consults no git at all" {
  # With git gone from PATH the answer must not change. The rule this
  # replaced could not run at all without it -- and that dependency is what
  # made its answer depend on which repository it was standing in.
  local _live="${TEMP_DIR}/live"
  mkdir -p "${_live}"
  rm -f "${BIN_DIR}/git"
  {
    _net n1 "${_live}" 86400
    _net n2 "${TEMP_DIR}/gone" 86400
  } > "${DOCKER_STATE}"
  run bash -c "PATH='${BIN_DIR}:/usr/bin:/bin'; source ${LIB}; _reclaim_orphan_projects"
  assert_success
  run cat "${DOCKER_REMOVED}"
  refute_output --partial "network n1"
  assert_output --partial "network n2"
}

# ── every input it refuses to place ────────────────────────────────────────

@test "a network whose recorded checkout still exists is NOT collected" {
  local _live="${TEMP_DIR}/live"
  mkdir -p "${_live}"
  _net n1 "${_live}" 86400 > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

@test "a path that exists but is no longer a checkout is spared" {
  # An empty directory where a checkout used to be is indistinguishable
  # from a checkout mid-clone or mid-`git worktree add`, and the run that
  # owns it may be about to fill it. The test is existence, never
  # checkout-ness.
  local _empty="${TEMP_DIR}/emptied"
  mkdir -p "${_empty}"
  _net n1 "${_empty}" 86400 > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

@test "a network with NO checkout-path label is left alone" {
  # Every network created before this change is this shape. The existing
  # litter is not collected by this mechanism, on purpose: an artifact that
  # does not say who made it cannot be attributed, and the daemon-wide
  # prune is what clears it.
  printf 'network|n1|base-4cc8dca8596c_default|base-4cc8dca8596c|86400|\n' \
    > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

@test "a checkout label that is not an absolute path is left alone" {
  printf 'network|n1|x_default|someproject|86400|../relative\n' > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

@test "another tenant's network is left alone" {
  printf 'network|n1|gitlab_runner_default|gitlab_runner|86400|\n' > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

@test "a project with a container attached is NOT collected" {
  local _dead="${TEMP_DIR}/gone"
  {
    _net n1 "${_dead}" 86400
    printf 'container|c1|whatever|%s|86400|\n' "$(_project "${_dead}")"
  } > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

@test "an orphan created inside the grace window is NOT collected" {
  _net n1 "${TEMP_DIR}/gone" 60 > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

@test "a network whose facts cannot be read is left alone" {
  _net n1 "${TEMP_DIR}/gone" 86400 > "${DOCKER_STATE}"
  DOCKER_FAIL_INSPECT=1 _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

@test "an unreadable network listing ABORTS rather than collecting everything" {
  _net n1 "${TEMP_DIR}/gone" 86400 > "${DOCKER_STATE}"
  DOCKER_FAIL_NETWORK_LS=1 _reclaim
  assert_failure
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

@test "an unreadable network listing issues no removal command at all" {
  _net n1 "${TEMP_DIR}/gone" 86400 > "${DOCKER_STATE}"
  DOCKER_FAIL_NETWORK_LS=1 _reclaim
  assert_failure
  # Word-anchored: the listing argv this abort DOES record contains
  # `--format`, and a substring match on `rm` would call that a removal.
  run grep -cE '\b(rm|rmi)\b' "${DOCKER_CALLS}"
  assert_output "0"
}

@test "an unreadable container listing ABORTS -- it cannot say nothing is attached" {
  # Read as "no container is attached to anything", a failed container
  # listing turns a broken daemon connection into a reason to delete a
  # running project's network.
  _net n1 "${TEMP_DIR}/gone" 86400 > "${DOCKER_STATE}"
  DOCKER_FAIL_PS=1 _reclaim
  assert_failure
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

@test "an unparseable grace aborts before any docker call" {
  _net n1 "${TEMP_DIR}/gone" 86400 > "${DOCKER_STATE}"
  GRACE=seven-hours _reclaim
  assert_failure
  run cat "${DOCKER_CALLS}"
  assert_output ""
}

@test "a PROJECT label on an image is not a proof, whatever it says" {
  # test-tools is content-hash tagged, so its project label names the
  # checkout that happened to build it, never the checkouts that use it --
  # and the checkout that built it being gone says nothing about the
  # checkouts that still resolve the tag. The only image label that IS a
  # proof is the checkout path, which compose.yaml stamps on the
  # per-checkout build image and deliberately not on this one (asserted in
  # reclaim_wiring_spec). So the fixture carries the project label of a
  # dead checkout and no path label, which is the shape of a real tooling
  # image, and nothing may act on it.
  printf 'image|i1|test-tools:aaaaaaaaaaaa|%s|86400|\n' \
    "$(_project "${TEMP_DIR}/gone")" > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

@test "the fact read asks for the JSON creation time and both labels" {
  # The shim refuses any other template, so this passing is the assertion.
  # `{{.Created}}` on a network renders a Go time value date(1) rejects;
  # reading the labels inline in `network ls` output is what a newline in a
  # path corrupts.
  _net n1 "${TEMP_DIR}/gone" 86400 > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run grep -c 'json .Created' "${DOCKER_CALLS}"
  refute_output "0"
}

# ── the live set is read off the artifacts ─────────────────────────────────

@test "the live-checkout set comes from the artifacts, not from any worktree list" {
  local _live="${TEMP_DIR}/live"
  mkdir -p "${_live}"
  printf '%s\n' "${TEMP_DIR}/somewhere-nobody-asked" > "${GIT_WORKTREES}"
  {
    _net n1 "${_live}" 86400
    _net n2 "${TEMP_DIR}/gone" 86400
  } > "${DOCKER_STATE}"
  run bash -c "source ${LIB}; declare -a _p=(); _reclaim_live_checkouts _p; printf '%s\n' \"\${_p[@]}\""
  assert_success
  assert_output "${_live}"
}

# ── test-tools tag retention ───────────────────────────────────────────────

# _tag <content> -- the tag a Dockerfile of that content resolves to.
_tag() {
  local _h
  _h="$(printf '%s' "${1}" | sha256sum | cut -d' ' -f1)"
  printf 'test-tools:%s\n' "${_h:0:12}"
}

@test "tag retention keeps the current tree's tag and the last N and retires the rest" {
  local _cur
  _cur="$(_tag 'FROM alpine
')"
  {
    printf 'image|i0|%s||10|\n'                 "${_cur}"
    printf 'image|i1|test-tools:111111111111||100|\n'
    printf 'image|i2|test-tools:222222222222||200|\n'
    printf 'image|i3|test-tools:333333333333||300|\n'
    printf 'image|i4|test-tools:444444444444||400|\n'
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

@test "tag retention keeps a tag a live checkout still resolves to" {
  local _other="${TEMP_DIR}/other"
  mkdir -p "${_other}/dockerfile"
  printf 'FROM debian\n' > "${_other}/dockerfile/Dockerfile.test-tools"
  local _cur _live
  _cur="$(_tag 'FROM alpine
')"
  _live="$(_tag 'FROM debian
')"
  {
    _net n1 "${_other}" 86400
    printf 'image|i0|%s||10|\n'  "${_cur}"
    printf 'image|i1|%s||9999|\n' "${_live}"
    printf 'image|i2|test-tools:222222222222||8888|\n'
  } > "${DOCKER_STATE}"
  # keep=0 empties the recency window, so the ONLY thing that can spare
  # ${_live} here -- the oldest of the three -- is a live checkout the
  # ARTIFACTS say still resolves it.
  run bash -c "source ${LIB}; _reclaim_tool_tags '${ROOT}' 0"
  assert_success
  run cat "${DOCKER_REMOVED}"
  refute_output --partial "${_live}"
  assert_output --partial "test-tools:222222222222"
}

@test "tag retention drops a checkout whose path is gone" {
  # The other half of the rule above: a labelled path that no longer exists
  # pins nothing, or the retention would keep every tag ever built.
  local _other="${TEMP_DIR}/other"
  mkdir -p "${_other}/dockerfile"
  printf 'FROM debian\n' > "${_other}/dockerfile/Dockerfile.test-tools"
  local _live
  _live="$(_tag 'FROM debian
')"
  {
    _net n1 "${_other}" 86400
    printf 'image|i1|%s||9999|\n' "${_live}"
  } > "${DOCKER_STATE}"
  rm -rf "${_other}"
  run bash -c "source ${LIB}; _reclaim_tool_tags '${ROOT}' 0"
  assert_success
  run cat "${DOCKER_REMOVED}"
  assert_output --partial "${_live}"
}

@test "tag retention leaves a tag it cannot place alone" {
  # A published / pinned tag is nothing this derivation mints.
  {
    printf 'image|i1|test-tools:local||9999|\n'
    printf 'image|i2|ghcr.io/x/test-tools:v1.2.3||9999|\n'
    printf 'image|i3|ollama/ollama:latest||9999|\n'
  } > "${DOCKER_STATE}"
  run bash -c "source ${LIB}; _reclaim_tool_tags '${ROOT}' 0"
  assert_success
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

@test "tag retention ABORTS when the artifacts cannot be listed" {
  printf 'image|i1|test-tools:111111111111||9999|\n' > "${DOCKER_STATE}"
  run bash -c "export DOCKER_FAIL_NETWORK_LS=1; source ${LIB}; _reclaim_tool_tags '${ROOT}' 0"
  assert_failure
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

@test "tag retention ABORTS when the image listing fails" {
  printf 'image|i1|test-tools:111111111111||9999|\n' > "${DOCKER_STATE}"
  run bash -c "export DOCKER_FAIL_IMAGES=1; source ${LIB}; _reclaim_tool_tags '${ROOT}' 0"
  assert_failure
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

@test "the retained-tag count is derived from the live checkouts, not a buried literal" {
  run bash -c "source ${LIB}; _reclaim_keep_window 2"
  assert_success
  assert_output "3"
  run bash -c "source ${LIB}; _reclaim_keep_window 7"
  assert_success
  assert_output "7"
}

@test "the retained-tag count is overridable by the environment" {
  run bash -c "export BASE_TOOL_TAGS_KEEP=9; source ${LIB}; _reclaim_keep_window 2"
  assert_success
  assert_output "9"
}

@test "the pinned tag set is the invoking tree plus every live checkout" {
  local _other="${TEMP_DIR}/other"
  mkdir -p "${_other}/dockerfile"
  printf 'FROM debian\n' > "${_other}/dockerfile/Dockerfile.test-tools"
  _net n1 "${_other}" 86400 > "${DOCKER_STATE}"
  run bash -c "source ${LIB}; declare -a _t=(); _reclaim_pinned_tool_tags '${ROOT}' _t; printf '%s\n' \"\${_t[@]}\""
  assert_success
  assert_line "$(_tag 'FROM alpine
')"
  assert_line "$(_tag 'FROM debian
')"
}

# ── the per-checkout BUILD image ──────────────────────────────────────────
#
# The survey behind this found one artifact class that no verb reclaimed:
# `just test smoke` builds the smoke harness through compose, which tags
# it `<project>-smoke` -- one image per checkout, 275MB measured on the
# development host, produced by a build whose whole result is pass or fail
# and consumed by nothing afterwards. The orphan sweep did not collect it
# (it removes networks), and the tooling-tag retention does not either (it
# matches `test-tools:<12hex>` by name).
#
# WHY THIS IMAGE AND NOT THE TOOLING IMAGE. The header of the file under
# test argues that a project label on an image names its BUILDER and not
# its users, so collecting on it would delete an image live checkouts
# still resolve. That argument is about the TOOLING tag, which is
# content-hash shared on purpose: one image, many checkouts. It does not
# transfer to an image that carries the checkout path stamped at build
# time -- that label names the one checkout that can ever ask for it,
# because the tag itself is derived from that checkout's project name. So
# the proof here is the same proof the network rule acts on, on an
# artifact where nothing is shared, and the rule stays out of the tooling
# image's way by only ever looking at what carries the label.

@test "an image whose checkout is gone is retired" {
  _img "base-deadbeef1234-smoke:latest" "${TEMP_DIR}/gone" 86400 > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  assert_output --partial "image base-deadbeef1234-smoke:latest"
}

@test "an image whose checkout still exists is kept" {
  _img "base-deadbeef1234-smoke:latest" "${ROOT}" 86400 > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  refute_output --partial "base-deadbeef1234-smoke"
}

@test "an image inside the grace window is kept" {
  _img "base-deadbeef1234-smoke:latest" "${TEMP_DIR}/gone" 60 > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  refute_output --partial "base-deadbeef1234-smoke"
}

@test "the tooling image carries no checkout label and is never a candidate here" {
  # Content-hash shared on purpose: one image, many checkouts, and no
  # artifact can name all of its users. It is retired by --tool-tags or
  # not at all.
  printf 'image|i1|test-tools:111111111111||99999|\n' > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  refute_output --partial "test-tools"
}

@test "an image whose path label is not absolute is left alone" {
  _img "base-deadbeef1234-smoke:latest" "relative/path" 86400 > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  refute_output --partial "base-deadbeef1234-smoke"
}

@test "a dangling labelled image is left alone rather than removed by id" {
  # `<none>:<none>` has no name that can be removed safely: the id behind
  # it may carry other tags, so `docker rmi <id>` would reach beyond the
  # artifact this rule can prove. The daemon-wide prune clears it.
  _img "<none>:<none>" "${TEMP_DIR}/gone" 86400 > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  refute_output --partial "<none>"
}

@test "an image whose live checkout path contains a newline is NOT retired" {
  # The same failure shape the network rule was built around: a shorter,
  # non-existent path read out of a truncated field is very plausibly
  # absent, and absent is what makes an artifact a candidate. The label is
  # read per artifact with the path last, so every byte survives.
  local _live="${TEMP_DIR}/line1"$'\n'"line2"
  mkdir -p "${_live}"
  printf 'image|i9|base-deadbeef1234-smoke:latest||86400|%s\\nline2\n' \
    "${TEMP_DIR}/line1" > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  refute_output --partial "base-deadbeef1234-smoke"
}

@test "an image whose DEAD checkout path contains a newline IS retired" {
  # The pair to the case above: read wrongly in either direction the rule
  # is broken, so both directions are pinned.
  printf 'image|i9|base-deadbeef1234-smoke:latest||86400|%s\\nline2\n' \
    "${TEMP_DIR}/gone" > "${DOCKER_STATE}"
  _reclaim
  assert_success
  run cat "${DOCKER_REMOVED}"
  assert_output --partial "image base-deadbeef1234-smoke:latest"
}

@test "an unreadable image listing retires nothing" {
  _img "base-deadbeef1234-smoke:latest" "${TEMP_DIR}/gone" 86400 > "${DOCKER_STATE}"
  DOCKER_FAIL_IMAGES=1 run bash -c "source ${LIB}; _reclaim_orphan_projects 6h"
  assert_failure
  run cat "${DOCKER_REMOVED}"
  refute_output --partial "base-deadbeef1234-smoke"
}

@test "a dry run names the image it would retire and removes nothing" {
  _img "base-deadbeef1234-smoke:latest" "${TEMP_DIR}/gone" 86400 > "${DOCKER_STATE}"
  DRY_RUN=true run bash -c "source ${LIB}; DRY_RUN=true _reclaim_orphan_projects 6h"
  assert_success
  assert_output --partial "base-deadbeef1234-smoke:latest"
  run cat "${DOCKER_REMOVED}"
  refute_output --partial "base-deadbeef1234-smoke"
}
