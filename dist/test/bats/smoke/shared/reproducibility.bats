#!/usr/bin/env bats
#
# Shared build-time smoke: the reproducibility manifest.
#
# The template's `sys` stage (and, when the optional runtime split is
# enabled, `runtime-base`) writes /usr/local/share/base/base-image.env and
# /usr/local/share/base/packages.txt so a built image can say what it was
# built from. Everything else that guards those two lives in base's own
# unit specs, which read the template as TEXT -- and text is exactly what
# cannot catch the failure this file exists for: the manifest being
# written from a stage where `${BASE_IMAGE}` expanded to the empty string
# (the pre-FROM ARG is FROM-scope only), so the file lands with an empty
# record and every static grep stays green.
#
# Runs in EVERY `-test` stage, so it only asserts what every real stage
# under test carries: devel-test inherits sys, and runtime-test inherits
# runtime-base's re-emit.
#
# Why the guard below skips rather than fails: this file is COPYed into a
# consumer's `-test` stage from `.base/dist/`, which `just upgrade`
# refreshes -- while the Dockerfile that would write the manifest is the
# consumer's own and hand-edited. The upgrade CAN rewrite that file
# (init.sh and upgrade.sh both run apply_migrations from
# dist/script/docker/lib/dockerfile_migrate.sh), but no migration was
# written for this record: every entry in that list anchors on a whole
# self-contained line, and the manifest splices into the middle of the
# sys stage's backslash-continued RUN chain, whose shape is the
# consumer's own. So a repo that has not yet hand-ported it gets this
# spec before it gets the manifest, and failing it would turn an upgrade
# into a broken build over a record the repo never claimed to keep.
#
# WHAT THE SKIP USED TO BE DECIDED BY, and why that was the defect
# base#1090 is about. It fired whenever NEITHER file was present -- the
# precondition was the absence of the spec's own subject, so "this repo has
# not ported the record yet" and "this repo ported the record and has lost
# it" were one state, and the second one is the live regression. Measured
# on 1c9ccb2, over a consumer-shaped image whose own Dockerfile writes both
# files and whose manifest was then left out: `1..4`, four `ok N # skip`,
# build exit 0.
#
# So the precondition is DERIVED from the artifact that DECIDES the
# property rather than from the one under assertion: the consumer's own
# Dockerfile, which the shipped devel-test stage puts at /lint/Dockerfile
# for its hadolint run. reproducibility_manifest_state in the shared helper
# reads it -- comment lines dropped, and only a redirection into one of the
# two paths counted, because the template names them in prose and a repo
# carrying only the prose must still get the skip. A Dockerfile that writes
# the manifest over an image that has neither file now FAILS, by name.
#
# The state no artifact in the image can answer -- neither file, and no
# Dockerfile either, which is the runtime-test stage and base's own smoke
# harness -- still skips, and says so. base's half of that is gated one tier
# up: test/bats/system/smoke_harness_spec.bats builds the harness and
# refuses any `# skip` in its output.
#
# A repo that writes one file and not the other, or writes an empty record,
# has adopted the manifest and broken it, and that fails.
#
# why: The reproducibility manifest the template's `sys` stage (and
# `runtime-base`, when the runtime split is enabled) writes:
# `base-image.env` and `packages.txt` under `/usr/local/share/base/`. Base's
# own unit specs read the template as TEXT, which cannot see the failure
# this file exists for — a manifest written from a stage where
# `${BASE_IMAGE}` expanded to the empty string, so the file lands with an
# empty record and every static grep stays green. Skips (rather than fails)
# when the repo has not ported the record yet: this spec reaches a consumer
# through `.base/dist/`, which `just upgrade` refreshes, while the Dockerfile that
# writes the manifest is the consumer's own and hand-edited. The upgrade can
# rewrite that file — `init.sh` and `upgrade.sh` both run `apply_migrations`
# — but no migration was written for this record, because it splices into
# the middle of the sys stage's continued `RUN` chain rather than onto an
# anchorable whole line, so the port is by hand. What decides that is the
# consumer's own Dockerfile at `/lint/Dockerfile`, not the absence of the
# files this spec came to read: a Dockerfile that writes the manifest over an
# image that has neither file is a record that was adopted and lost, and it
# FAILS. A repo that writes one file and not the other, or writes an empty
# record, has adopted the manifest and broken it, and fails too.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
}

REPRO_ENV="/usr/local/share/base/base-image.env"
REPRO_PKGS="/usr/local/share/base/packages.txt"
# The consumer's own Dockerfile, as the shipped devel-test stage places it
# (`COPY Dockerfile /lint/Dockerfile`, for that stage's hadolint run). It is
# the artifact that decides whether this image is supposed to carry the
# manifest at all, which is why the precondition below asks it instead of
# reading its own subject's absence as an answer.
REPRO_DOCKERFILE="/lint/Dockerfile"

# Gate the calling test on the manifest's adoption state. Asserts when the
# record is there, FAILS when the Dockerfile writes it and the image has it
# not, and skips -- saying which of the two unanswerable states it is in --
# otherwise.
_require_manifest_adopted() {
  local _state
  _state="$(reproducibility_manifest_state \
    "${REPRO_ENV}" "${REPRO_PKGS}" "${REPRO_DOCKERFILE}")"
  case "${_state}" in
    adopted) return 0 ;;
    missing)
      fail "${REPRO_DOCKERFILE} writes the reproducibility manifest, and this image has neither ${REPRO_ENV} nor ${REPRO_PKGS}: the record was adopted and has been lost, so the stage that writes it no longer runs or no longer writes there. This is not the un-ported case -- that one skips." ;;
    unported)
      skip "${REPRO_DOCKERFILE} does not write the manifest, so this repo has not ported the record yet (run 'just upgrade', then re-apply .base/dist/dockerfile/Dockerfile)" ;;
    *)
      skip "no manifest, and no ${REPRO_DOCKERFILE} in this image to ask whether one is expected -- the state this spec cannot report over. base's own smoke harness is gated one tier up, by test/bats/system/smoke_harness_spec.bats refusing any skip in its output" ;;
  esac
}

# why: Both manifest files land in every `-test` stage
@test "the reproducibility manifest is complete" {
  _require_manifest_adopted
  assert_file_exists "${REPRO_ENV}"
  assert_file_exists "${REPRO_PKGS}"
}

# why: Non-empty `base_image_ref` value plus a `base_image_pin` verdict —
# the empty-expansion failure
@test "the manifest names the base image this stage was built from" {
  _require_manifest_adopted
  # Non-empty VALUE, not merely a present key: `base_image_ref=` with
  # nothing after it is what an unscoped ${BASE_IMAGE} produces, and it is
  # indistinguishable from a complete manifest to anything that only
  # checks the file exists.
  run grep -E '^base_image_ref=[^[:space:]]+$' "${REPRO_ENV}"
  assert_success
  # Whether that reference was pinned is the other half of the record: an
  # unpinned reference names an image that may already have moved.
  run grep -E '^base_image_pin=(digest|none)$' "${REPRO_ENV}"
  assert_success
  # The digest field has to hold a DIGEST when it holds anything. ONE
  # expression fills it -- the BASE_IMAGE_DIGEST build arg -- and the
  # same value is what the sys stage puts in the OCI `base.digest`
  # annotation, where OCI defines a digest and not a reference. A
  # BASE_IMAGE that carries its own digest does not fill it by a second
  # route, because the annotation is written by a LABEL and a LABEL
  # cannot branch on whether the reference carries one: the expression
  # that strips a digest returns the whole reference when there is none.
  # So the arg is emitted verbatim, and a caller who pastes a
  # `docker image inspect --format '{{index .RepoDigests 0}}'` out
  # (`ubuntu@sha256:...`, a REFERENCE) records a reference where a digest
  # belongs -- in both sinks at once, which is what this assertion
  # catches. Empty stays legal: that is the shipped default's truthful
  # "not recorded", and equally the truthful record of an image pinned by
  # reference whose builder passed no second argument.
  run grep -E '^base_image_digest=(sha256:[0-9a-f]{64})?$' "${REPRO_ENV}"
  assert_success
}

# why: Where the record states the digest twice -- inside `base_image_ref`
# and in `base_image_digest` -- the two must agree; stating only the
# reference half is a blank field, not a contradiction, and passes
@test "the manifest's digest field does not contradict the reference" {
  _require_manifest_adopted
  # The record can state the digest TWICE: once inside `base_image_ref`
  # when the reference is digest-pinned, once in `base_image_digest`. One
  # image, one base, so where both are stated they are the same value or
  # the record is false -- and a false record is worse than the blank one
  # it was meant to improve on, because it reads as an answer.
  #
  # Stating only the reference half is NOT the failure: an empty digest
  # field beside a pinned reference is "not separately recorded", the
  # same answer the OCI annotation gives, and the build is right not to
  # stop over it. Only disagreement fails, which is why this is asserted
  # HERE, over the record, rather than by refusing to build: it fails the
  # `-test` stage of the image whose record is actually wrong.
  local _ref _digest _from_ref
  _ref="$(sed -n 's/^base_image_ref=//p' "${REPRO_ENV}")"
  _digest="$(sed -n 's/^base_image_digest=//p' "${REPRO_ENV}")"
  case "${_ref}" in
    *@sha256:*) _from_ref="sha256:${_ref##*@sha256:}" ;;
    *)          _from_ref="" ;;
  esac
  if [ -n "${_from_ref}" ] && [ -n "${_digest}" ]; then
    assert_equal "${_digest}" "${_from_ref}"
  fi
}

# why: `dpkg-query -W` name/version pairs, not a bare name list
@test "the manifest records package versions, not just package names" {
  _require_manifest_adopted
  # `dpkg-query -W` prints "<name><TAB><version>". A file of bare names --
  # the shape a mis-typed format string produces -- answers "what is
  # installed" but not "which build am I looking at", which is the whole
  # point of recording it. Counted with awk rather than grep -P: busybox
  # grep has no -P, and a `-test` stage is whatever the consumer's base
  # image ships.
  run awk -F'\t' 'NF == 2 && $1 != "" && $2 != "" { n++ } END { print n + 0 }' \
    "${REPRO_PKGS}"
  assert_success
  refute_output "0"
}
