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
# Four properties are pinned here, and the rewrite ones are executed
# rather than grepped: the rewrite is a shell rule, so the way to assert
# what it does at the default is to RUN it over a repositories file.
#
#   - The default is the upstream CDN, declared once. A machine that can
#     reach dl-cdn sees no change.
#   - The alpine that stage is FROM is the pinned ARG, and no other stage
#     names an alpine of its own. Every apk stage derives from this one,
#     so this is the tree's only tie between the tooling image's alpine
#     and ARG ALPINE_VERSION -- template_spec's kcov-builder assertion
#     used to carry it and cannot any more.
#   - At the default the rewrite is SKIPPED, rather than running a sed
#     that replaces the host with itself. Comparing BYTES cannot tell
#     those two apart -- a sed rewriting the host to itself emits the
#     same bytes, so an unguarded rule passes a byte comparison. What is
#     compared instead is the file's IDENTITY: inode and mtime. `sed -i`
#     renames a fresh file over the target, so the inode moves; any
#     writer that edits in place moves the mtime. Unchanged identity is
#     the executable form of "the stage touched nothing at all", and what
#     that buys is reach: on the default path the repositories file is
#     the one alpine shipped, so a mistake in the rewrite rule can only
#     ever reach a build that asked for a mirror. What it does NOT buy
#     is build cache: BuildKit keys a RUN on its parent's CACHE KEY, not
#     on the parent's content, so an inserted stage that writes nothing
#     still rebuilds every stage below it -- an empty layer carries
#     nothing through, and no cache argument should be built on top of
#     this one.
#   - Every stage that installs packages inherits that choice. The file
#     has four such stages; a knob wired into one of them leaves the
#     other three unbuildable, which is the failure this file's stage
#     attribution exists to catch when a fifth stage is added.
#
# The forwarding half -- the build path passes the arg only when the
# caller set one, so the upstream host keeps being named in exactly one
# place -- is compose's own interpolation and is asserted by driving it,
# in test/bats/integration/apk_mirror_spec.bats.
#
# why: APK_MIRROR is the Alpine mirror knob on
# dockerfile/Dockerfile.test-tools -- the image the WHOLE local gate runs
# inside. Without it a host that cannot reach dl-cdn.alpinelinux.org
# cannot build the gate at all, and the only thing it is told is `no such
# package` for every package after ~480s, because an unreachable index
# reads as an empty one rather than as a network failure.
#
# The rewrite properties are EXECUTED rather than grepped: the rewrite is
# a shell rule, so the way to assert what it does at the default is to run
# the extracted rule over a repositories file. What is pinned: the default
# is the upstream CDN declared once; the mirror stage's alpine is the
# pinned ARG and no other stage names an alpine of its own (this file
# holds the tree's only such tie, which template_spec's kcov-builder
# assertion used to carry); the rewrite is skipped at the default, checked
# by the file's inode and mtime because a sed replacing the host with
# itself is byte-identical; and every stage that installs packages derives
# from the one stage that declares the arg. The forwarding half is
# test/bats/integration/apk_mirror_spec.bats'.

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

# _mirror_stage -- the name of the stage that declares APK_MIRROR, read
# out of the file rather than spelled here: the mirror stage IS the stage
# that declares the arg, so renaming it moves every assertion with it.
_mirror_stage() {
  awk '
    tolower($1) == "from" { name = (tolower($3) == "as") ? $4 : ""; next }
    /^ARG[[:space:]]+APK_MIRROR=/ { print name; exit }
  ' "${DOCKERFILE}"
}

# _alpine_bases_off_the_arg -- every `FROM alpine:<tag>` whose tag is not
# the ARG. Comment lines are skipped, as in _stages_off_the_mirror.
_alpine_bases_off_the_arg() {
  awk '
    /^[[:space:]]*#/ { next }
    tolower($1) == "from" && $2 ~ /^alpine:/ && $2 != "alpine:${ALPINE_VERSION}" {
      print $2 " (" ((tolower($3) == "as") ? $4 : "<final stage>") ")"
    }
  ' "${DOCKERFILE}"
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

# why: The upstream host is declared in exactly ONE place, so nothing
# else has to be kept in agreement with it. A second ARG, or a default
# spelled elsewhere, is how the two start disagreeing silently -- and the
# default has to BE the CDN, or a machine that named no mirror gets one.
@test "APK_MIRROR: declared exactly once, defaulting to the upstream CDN (#1008)" {
  run grep -cE '^ARG[[:space:]]+APK_MIRROR=' "${DOCKERFILE}"
  assert_success
  assert_output "1"
  assert_equal "$(_declared_default)" "${UPSTREAM_CDN}"
}

# why: The tree's ONLY tie between a tooling stage's alpine and
# ARG ALPINE_VERSION, after template_spec's kcov-builder assertion had to
# give it up (that stage is `FROM alpine-apk` now). Nothing else in the
# gate catches a divergent one: hadolint refuses `:latest` but not a
# `FROM alpine:3.20` sitting next to `ARG ALPINE_VERSION=3.21`, which
# builds green and ships tooling on a release the file does not declare.
@test "APK_MIRROR: the mirror stage's alpine is the pinned ARG, and so is every other (#1008)" {
  # The tree's only assertion tying a tooling stage's alpine to
  # ARG ALPINE_VERSION. template_spec carried it on kcov-builder, which is
  # `FROM alpine-apk` now and can no longer say anything about alpine at
  # all; the pin belongs on the stage every apk stage derives from, which
  # is this file's subject. Nothing else in the gate catches a divergent
  # one: hadolint refuses `:latest` (DL3007) but not a `FROM alpine:3.20`
  # sitting next to `ARG ALPINE_VERSION=3.21`, which builds green on a
  # release the file does not declare and ships tooling nobody chose.
  local _stage _base
  _stage="$(_mirror_stage)"
  [ -n "${_stage}" ] \
    || fail "no shared mirror stage in ${DOCKERFILE}: nothing declares the repositories rewrite once for every apk stage to derive from"
  _base="$(awk -v want="${_stage}" '
    tolower($1) == "from" && tolower($3) == "as" && $4 == want { print $2; exit }
  ' "${DOCKERFILE}")"
  assert_equal "${_base}" 'alpine:${ALPINE_VERSION}'
  # The arg it reads is a pinned release, not a floating tag.
  run grep -cE '^ARG[[:space:]]+ALPINE_VERSION=[0-9]+\.[0-9]+$' "${DOCKERFILE}"
  assert_success
  assert_output "1"
  # And no stage reaches an alpine of its own behind that pin's back.
  run _alpine_bases_off_the_arg
  assert_success
  assert_output ""
}

# why: What keeps "declared once" true across FILES. A
# `${APK_MIRROR:-dl-cdn.alpinelinux.org}` in compose.yaml would move the
# upstream host's declaration into a file the Dockerfile cannot see, so
# the Dockerfile could no longer change it -- the failure the APT_MIRROR_*
# pair already has in the emitted downstream compose.
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

# why: The load-bearing case, and the one a byte comparison cannot make.
# Dropping the guard leaves a sed that replaces the host with ITSELF --
# the exact rule the guard prevents -- and its output is byte-identical,
# so bytes green-light it. Identity (inode, mtime) is what says the
# rewrite never ran, and that is what buys reach: a mistake in the rule
# can then only be reached by a caller who asked for a mirror.
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
    || fail "the default REWROTE the repositories file (inode/mtime ${_ident} -> ${_ident_after}); byte-identical output is not a skip, and a rule that runs at the default puts itself in the path of every build, including the ones that named no mirror"
}

# why: EVERY line moves, not just the first. The seed file carries two
# repositories because that is the shape alpine ships, and a rule that
# stops after `main` leaves `community` pointing at the host the caller
# cannot reach -- a build that then dies halfway through, on the mirror
# that was supposed to have fixed it.
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

# why: An empty value is the one input that would REPRODUCE the bug this
# knob removes: rewriting the host to nothing hands back the same
# misleading `no such package`, now with a mirror set, which is the worst
# place to leave the reader. Refusing it by name is what separates a
# caller mistake from the original defect.
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

# why: The file runs apk in four stages, so a knob wired into one leaves
# the build dying in the next -- later, and with the same misleading
# message. This is the assertion that names a newly added alpine stage
# here, on any machine, rather than on the one host that cannot reach
# dl-cdn and would otherwise be the only place it shows up.
@test "APK_MIRROR: every stage that installs packages inherits the mirror choice (#1008)" {
  # A knob on one stage of four leaves the other three pinned to the CDN,
  # so the build still dies -- later, and with the same message. The
  # mirror stage is the single parent, so a new alpine stage that
  # `apk add`s without deriving from it is named here rather than
  # discovered on the host that cannot reach dl-cdn.
  local _stage
  _stage="$(_mirror_stage)"
  [ -n "${_stage}" ] \
    || fail "no shared mirror stage in ${DOCKERFILE}: nothing declares the repositories rewrite once for every apk stage to derive from"
  run _stages_off_the_mirror "${_stage}"
  assert_success
  assert_output ""
}
