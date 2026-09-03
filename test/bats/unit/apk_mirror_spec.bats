#!/usr/bin/env bats
#
# Unit tests for APK_MIRROR -- the Alpine spelling of the APT_MIRROR_*
# build args base already ships (the sibling knob in the shipped
# dist/dockerfile/Dockerfile is APT_MIRROR_UBUNTU alone; APT_MIRROR_DEBIAN
# is a build arg the setup / env emitters carry, not an ARG in that file).
#
# dockerfile/Dockerfile.test-tools builds the image the WHOLE local gate
# runs inside, and it had no mirror knob at all, so a host that cannot
# reach dl-cdn.alpinelinux.org could not run `just test` and had nothing
# to say about it from the command line. Measured on such a host: apk
# spends ~480s and then reports every package as `no such package`,
# because an unreachable index reads as an EMPTY one. That is the whole
# hazard -- not a timeout the reader can recognise, but a package list
# that appears not to contain `bash`, which sends the reader looking for
# a packaging mistake that does not exist.
#
# Three properties are pinned here, and the first two are executed rather
# than grepped: the rewrite is a shell rule, so the way to assert what it
# does at the default is to RUN it over a repositories file.
#
#   - The default is the upstream CDN, declared once. A machine that can
#     reach dl-cdn sees no change.
#   - At the default the rewrite is SKIPPED, rather than running a sed
#     that replaces the host with itself. Comparing BYTES cannot tell
#     those two apart -- a sed rewriting the host to itself emits the
#     same bytes, so an unguarded rule passes a byte comparison. What is
#     compared instead is the file's IDENTITY: inode and mtime. `sed -i`
#     renames a fresh file over the target, so the inode moves; any
#     writer that edits in place moves the mtime. Unchanged identity is
#     the executable form of "the stage touched nothing at all", which is
#     the property the image leans on -- an empty layer, so BuildKit
#     carries every downstream apk layer through unrebuilt.
#   - Every stage that installs packages inherits that choice. The file
#     has four such stages; a knob wired into one of them leaves the
#     other three unbuildable, which is the failure this file's stage
#     attribution exists to catch when a fifth stage is added.
#
# The forwarding half -- the build path passes the arg only when the
# caller set one, so the upstream host keeps being named in exactly one
# place -- is compose's own interpolation and is asserted by driving it,
# in test/bats/integration/apk_mirror_spec.bats.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  DOCKERFILE=/source/dockerfile/Dockerfile.test-tools
  COMPOSE=/source/compose.yaml
  UPSTREAM_CDN="dl-cdn.alpinelinux.org"
  SCRATCH="$(mktemp -d)"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _declared_default -- the ARG's default, quotes stripped.
_declared_default() {
  grep -E '^ARG[[:space:]]+APK_MIRROR=' "${DOCKERFILE}" \
    | head -n1 | cut -d= -f2- | tr -d '"'"'"'[:space:]'
}

# _mirror_rule <repositories-path> -- the guarded rewrite as a runnable
# shell script, with apk's system repositories path repointed at a file
# the test owns. Extraction is anchored on the first `RUN` line that
# mentions the arg and ends at the first line with no continuation, so
# the body under test is the one the image really runs rather than a
# transcription of it.
_mirror_rule() {
  local _repos="${1:?_mirror_rule requires <repositories-path>}"
  awk '
    !inblock && /^RUN .*APK_MIRROR/ { inblock = 1 }
    inblock { line = $0; sub(/^RUN /, "", line); print line }
    inblock && !/\\$/ { exit }
  ' "${DOCKERFILE}" | sed "s@/etc/apk/repositories@${_repos}@g"
}

# _seed_repositories -- an /etc/apk/repositories in the shape alpine
# ships it. Two lines, so a rewrite that stops after the first is visible.
_seed_repositories() {
  printf 'https://%s/alpine/v3.21/main\nhttps://%s/alpine/v3.21/community\n' \
    "${UPSTREAM_CDN}" "${UPSTREAM_CDN}" > "${SCRATCH}/repositories"
  printf '%s\n' "${SCRATCH}/repositories"
}

# _stages_off_the_mirror <stage> -- every stage that runs `apk add`
# without being FROM <stage>. Comment lines are skipped: this file
# discusses `apk add` in prose more often than it runs it, and prose is
# not a stage.
_stages_off_the_mirror() {
  awk -v want="${1:?_stages_off_the_mirror requires <stage>}" '
    /^[[:space:]]*#/ { next }
    tolower($1) == "from" {
      from = $2; name = "<final stage>"
      if (tolower($3) == "as") { name = $4 }
      next
    }
    /apk add/ { if (from != want) { print name " (FROM " from ")" } }
  ' "${DOCKERFILE}" | sort -u
}

# ════════════════════════════════════════════════════════════════════
# The declaration
# ════════════════════════════════════════════════════════════════════

@test "APK_MIRROR: declared exactly once, defaulting to the upstream CDN (#1008)" {
  run grep -cE '^ARG[[:space:]]+APK_MIRROR=' "${DOCKERFILE}"
  assert_success
  assert_output "1"
  assert_equal "$(_declared_default)" "${UPSTREAM_CDN}"
}

@test "APK_MIRROR: the build path names no alpine mirror of its own (#1008)" {
  # The default lives in the Dockerfile and nowhere else. A
  # `\${APK_MIRROR:-dl-cdn.alpinelinux.org}` in compose would be a second
  # declaration of the upstream host that the Dockerfile could no longer
  # move -- the failure the APT_MIRROR_* pair already has in the emitted
  # downstream compose, and not one to repeat here.
  run grep -n "${UPSTREAM_CDN}" "${COMPOSE}"
  assert_failure
  [ "${status}" -eq 1 ] || fail "grep errored (${status}), it did not merely fail to match"
}

# ════════════════════════════════════════════════════════════════════
# The rewrite, executed
# ════════════════════════════════════════════════════════════════════

@test "APK_MIRROR: at the default the repositories file is not touched at all (#1008)" {
  # Identity, not bytes. Dropping the `!= dl-cdn.alpinelinux.org` guard
  # leaves a sed that replaces the host with ITSELF, whose output is
  # byte-identical -- so a byte comparison green-lights exactly the rule
  # the guard exists to prevent. An in-place sed renames a new file over
  # the target (the inode moves) and any other in-place writer moves the
  # mtime, so an unchanged (inode, mtime) pair is what actually says the
  # rewrite did not run, and with it that the stage adds nothing to the
  # image layer.
  local _repos _rule _before _ident _ident_after
  _repos="$(_seed_repositories)"
  _before="$(cat "${_repos}")"
  _ident="$(stat -c '%i %y' "${_repos}")"
  _rule="$(_mirror_rule "${_repos}")"
  [ -n "${_rule}" ] \
    || fail "no guarded APK_MIRROR rule in ${DOCKERFILE} -- nothing was executed, so this test asserted nothing"
  APK_MIRROR="$(_declared_default)" sh -c "${_rule}"
  assert_equal "$(cat "${_repos}")" "${_before}"
  _ident_after="$(stat -c '%i %y' "${_repos}")"
  [ "${_ident_after}" = "${_ident}" ] \
    || fail "the default REWROTE the repositories file (inode/mtime ${_ident} -> ${_ident_after}); byte-identical output is not a skip, and a stage that rewrites the file busts every downstream apk layer's cache"
}

@test "APK_MIRROR: an override repoints every repository line (#1008)" {
  local _repos _rule
  _repos="$(_seed_repositories)"
  _rule="$(_mirror_rule "${_repos}")"
  [ -n "${_rule}" ] \
    || fail "no guarded APK_MIRROR rule in ${DOCKERFILE} -- nothing was executed, so this test asserted nothing"
  APK_MIRROR=mirrors.edge.kernel.org sh -c "${_rule}"
  run grep -c '^https://mirrors\.edge\.kernel\.org/alpine/' "${_repos}"
  assert_success
  assert_output "2"
  run grep -n "${UPSTREAM_CDN}" "${_repos}"
  assert_failure
  [ "${status}" -eq 1 ] || fail "grep errored (${status}), it did not merely fail to match"
}

@test "APK_MIRROR: an empty override is refused by name, not turned into an empty host (#1008)" {
  # `--build-arg APK_MIRROR=` would otherwise rewrite the host to nothing
  # and hand back the SAME misleading `no such package` this knob exists
  # to remove. An empty value is a caller mistake and gets said out loud.
  local _repos _rule
  _repos="$(_seed_repositories)"
  _rule="$(_mirror_rule "${_repos}")"
  [ -n "${_rule}" ] \
    || fail "no guarded APK_MIRROR rule in ${DOCKERFILE} -- nothing was executed, so this test asserted nothing"
  run env APK_MIRROR= sh -c "${_rule}"
  assert_failure
  assert_output --partial "APK_MIRROR"
  run grep -c "${UPSTREAM_CDN}" "${_repos}"
  assert_success
  assert_output "2"
}

# ════════════════════════════════════════════════════════════════════
# Reach: every stage that installs packages
# ════════════════════════════════════════════════════════════════════

@test "APK_MIRROR: every stage that installs packages inherits the mirror choice (#1008)" {
  # A knob on one stage of four leaves the other three pinned to the CDN,
  # so the build still dies -- later, and with the same message. The
  # mirror stage is the single parent, so a new alpine stage that
  # `apk add`s without deriving from it is named here rather than
  # discovered on the host that cannot reach dl-cdn.
  local _stage
  # Derived from the file, not spelled here: the mirror stage IS the stage
  # that declares the arg, so renaming it moves this assertion with it.
  _stage="$(awk '
    tolower($1) == "from" { name = (tolower($3) == "as") ? $4 : ""; next }
    /^ARG[[:space:]]+APK_MIRROR=/ { print name; exit }
  ' "${DOCKERFILE}")"
  [ -n "${_stage}" ] \
    || fail "no shared mirror stage in ${DOCKERFILE}: nothing declares the repositories rewrite once for every apk stage to derive from"
  run _stages_off_the_mirror "${_stage}"
  assert_success
  assert_output ""
}
