#!/usr/bin/env bats
#
# Integration: how the repo-root compose.yaml forwards APK_MIRROR to the
# tooling build.
#
# The knob itself -- the default, the skip at the default, the reach over
# every apk stage -- is dockerfile/Dockerfile.test-tools' and is asserted
# in test/bats/unit/apk_mirror_spec.bats. What is asserted HERE is the
# other half of the contract: the build path forwards the arg ONLY when
# the caller set one, so the upstream host keeps being named in exactly
# one place. Passing it unconditionally would put an empty --build-arg in
# front of the image's own default on every machine that needs no
# override, and a `${APK_MIRROR:-dl-cdn.alpinelinux.org}` here would move
# the declaration of the upstream host out of the Dockerfile into a file
# the Dockerfile cannot see.
#
# Compose's own interpolation decides that, not the file's text, so these
# assertions drive `docker compose config` rather than grepping. Both
# local build paths -- `just test` (script/test/test.sh's
# _ensure_test_tools_image) and `just docker build --target test-tools`
# -- build this service, so the forwarding belongs to the service and
# both inherit it.
#
# `docker compose config` is pure client-side interpolation: it needs the
# compose CLI (baked into the test-tools image this suite runs in) but no
# daemon and no docker socket, so this spec belongs to the plain `ci`
# service rather than the socket-mounted `ci-system` one. Same reasoning,
# and same shape, as compose_test_tools_image_spec.bats.
#
# why: The FORWARDING half of the APK_MIRROR contract -- the repo-root
# `compose.yaml` passes the arg to the tooling build only when the caller
# set one, so the upstream host keeps being named in exactly one place,
# the Dockerfile. Passing it unconditionally would put an empty
# `--build-arg` in front of the image's own default on every machine that
# needs no override, and a `:-` default here would move the declaration of
# the upstream host into a file the Dockerfile cannot see.
#
# Compose's own interpolation is what decides this, not the file's text,
# so the assertions drive `docker compose config` rather than grepping.
# The knob itself -- the default, the skip at the default, the reach over
# every apk stage -- is test/bats/unit/apk_mirror_spec.bats'.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  ROOT=/source
}

# _forwarded_args [mirror] -- every build arg compose resolves for the
# `test-tools` service, one `KEY=VALUE` per line. With no argument the
# variable is REMOVED from the environment, which is the state a machine
# that needs no override is in; with one it is exported, which is the
# state a machine that does need one is in. TEST_TOOLS_IMAGE is supplied
# because the service refuses an unset one by design (its own spec pins
# that); a placeholder is enough, since `config` builds nothing.
#
# BASE_CHECKOUT_PATH is supplied for the same reason, and it belongs to a
# different variable's requirement: compose interpolates the WHOLE file
# whatever service is named, and the default network's
# `base.checkout.path` label carries a `:?` of its own -- so leaving it
# unset would make every assertion here describe THAT refusal instead of
# the mirror arg. A placeholder is again enough.
_forwarded_args() {
  local _out
  if [ "$#" -gt 0 ]; then
    _out="$(APK_MIRROR="${1}" TEST_TOOLS_IMAGE=test-tools:spec \
      BASE_CHECKOUT_PATH=/source docker compose \
      -f "${ROOT}/compose.yaml" config 2>/dev/null)" \
      || { echo "BUG: docker compose config failed on ${ROOT}/compose.yaml"; return 1; }
  else
    _out="$(env -u APK_MIRROR TEST_TOOLS_IMAGE=test-tools:spec \
      BASE_CHECKOUT_PATH=/source docker compose \
      -f "${ROOT}/compose.yaml" config 2>/dev/null)" \
      || { echo "BUG: docker compose config failed on ${ROOT}/compose.yaml"; return 1; }
  fi
  printf '%s\n' "${_out}" \
    | yq '.services.test-tools.build.args // {} | to_entries | .[] | .key + "=" + (.value // "")' -
}

# why: Unset has to mean "the Dockerfile's default", not "an empty
# override the Dockerfile then has to defend itself against". This is the
# case every machine that can reach dl-cdn is in, so an unconditional
# forward would put an empty `--build-arg` in front of the image's own
# default everywhere and be noticed nowhere.
@test "compose.yaml: with APK_MIRROR unset the tooling build receives no mirror arg (#1008)" {
  # Unset must mean "the Dockerfile's default", not "an empty override
  # that the Dockerfile then has to defend itself against".
  run _forwarded_args
  assert_success
  refute_output --partial "APK_MIRROR"
}

# why: The other direction, and what makes the case above non-vacuous:
# a `build.args` entry deleted outright would also forward nothing when
# unset. Both halves together are what says the bare `- APK_MIRROR` form
# is doing its job -- override through, nothing through otherwise.
@test "compose.yaml: the caller's APK_MIRROR reaches the tooling build (#1008)" {
  run _forwarded_args mirror.example.invalid
  assert_success
  assert_output --partial "APK_MIRROR=mirror.example.invalid"
}
