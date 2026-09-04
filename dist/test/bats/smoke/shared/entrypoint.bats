#!/usr/bin/env bats
#
# Shared build-time smoke: the "does it even come up" baseline that runs
# inside EVERY Dockerfile `-test` stage (devel-test and runtime-test),
# so it must only assert things present in every real stage under test.
# It therefore avoids /lint (populated only in devel-test) and touches
# just the universal surface: both halves of the installed entrypoint +
# bash on PATH.
#
# Both halves, because the entry point is two files (ADR-00000032): the
# base-owned orchestrator at /usr/local/lib/base/entrypoint.sh is what the
# Dockerfile names as ENTRYPOINT, and it SOURCES the repo-owned bringup at
# /entrypoint.sh. Asserting only the bringup left the file the image
# actually starts -- and the runtime-dir COPY that installs it -- pinned by
# nothing, so dropping it produced a container that would not start and a
# green build.
#
# The orchestrator half is guarded, for the same reason
# reproducibility.bats guards the manifest: THIS FILE arrives through
# `.base/dist/`, which `just upgrade` refreshes, while the Dockerfile that
# installs the orchestrator is the consumer's own. On the runtime stage
# that install is opt-in -- the scaffold ships the directory COPY
# commented out, and the migration that collapses the per-file helper
# COPYs preserves whatever comment state it found -- so a repo running the
# optional runtime-test bats smoke without it would get this spec before
# it gets the file. An unconditional assertion there is a red build on a
# repo that has adopted nothing, which is exactly what ADR-00000032 and
# the CHANGELOG promise cannot happen. The guard is narrow: it fires only
# for a /entrypoint.sh that still execs, i.e. one that is itself the
# container's entry point. A repo whose bringup no longer execs has
# adopted the two-file model, and an orchestrator missing under it is a
# container that will not start -- so that fails, including in base's own
# smoke image, whose seeded bringup carries no exec.
#
# Loaded together with the shared test_helper.bash (both live under
# smoke/shared/ and are COPYed into /smoke_test/ by each `-test` stage).
#
# why: The cross-stage baseline that runs inside every `-test` stage
# (devel-test and runtime-test). Asserts only the universal surface — both
# halves of the installed entry point (ADR-00000032) and bash on PATH — so
# it never touches `/lint` (populated only in devel-test).
#
# The orchestrator half skips (rather than fails) on an image whose
# `/entrypoint.sh` still execs, i.e. one running the pre-ADR-00000032
# single-file model. This file reaches a consumer through `.base/dist/`,
# which `just upgrade` refreshes, while the Dockerfile that installs the
# orchestrator is the consumer's own — and on the optional runtime stage
# that install is opt-in. Without the guard, a repo running the optional
# runtime-test bats smoke would go red on the upgrade that delivers this
# spec, over a model it has not adopted. The guard is narrow: once the
# bringup stops execing, the repo has adopted the model and a missing
# orchestrator is a container that will not start, so it fails.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
}

BRINGUP="/entrypoint.sh"
ORCHESTRATOR="/usr/local/lib/base/entrypoint.sh"

# why: The half the container actually starts (ADR-00000032). Without this
# the runtime-directory COPY that installs the orchestrator is pinned by
# nothing, so dropping it gives a green build and a container that will not
# start. Guarded, not unconditional: an image whose bringup still execs is
# its own ENTRYPOINT and has adopted nothing, and failing it there would
# break the promise that this release leaves an existing repo unchanged.
@test "the base entrypoint orchestrator is installed and executable" {
  if entrypoint_is_single_file "${BRINGUP}"; then
    skip "image predates ADR-00000032: ${BRINGUP} still execs, so it is the ENTRYPOINT (migrate: README, Container entrypoint)"
  fi
  assert_file_exists "${ORCHESTRATOR}"
  assert [ -x "${ORCHESTRATOR}" ]
}

# why: Entrypoint present -- the repo-owned bringup half, which every image
# carries whichever entry-point model it is on.
@test "entrypoint.sh is installed and executable" {
  assert_file_exists "${BRINGUP}"
  assert [ -x "${BRINGUP}" ]
}

# why: Core shell present
@test "bash is available on PATH" {
  assert_cmd_installed bash
}
