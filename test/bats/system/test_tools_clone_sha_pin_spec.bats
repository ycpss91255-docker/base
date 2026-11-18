#!/usr/bin/env bats
#
# System-level regression: the git clones in Dockerfile.test-tools are bound
# to a pinned commit SHA, so a retagged or force-moved upstream tag fails the
# build instead of silently producing a different image (base#1674).
# Drives `docker buildx build --target <stage>` so the real RUN line is
# exercised, not a text scan of the Dockerfile.
#
# Requires the ci-system compose service (docker socket + network).
# Skips explicitly when the socket or the docker CLI is absent.

setup_file() {
  if [[ ! -S /var/run/docker.sock ]]; then
    skip "system test: /var/run/docker.sock not mounted (run via 'just test system')"
  fi
  if ! command -v docker >/dev/null 2>&1; then
    skip "system test: docker CLI not present"
  fi
}

# why: a wrong pinned kcov commit must fail the kcov-builder build (base#1674)
@test "kcov-builder build fails when the KCOV_COMMIT pin is wrong" {
  run docker buildx build \
    --builder template-system \
    --target kcov-builder \
    --build-arg "KCOV_COMMIT=0000000000000000000000000000000000000000" \
    --progress=plain \
    --no-cache-filter kcov-builder \
    -f /source/dockerfile/Dockerfile.test-tools \
    /source 2>&1

  # A failing build alone could be a network flake; the mismatch message
  # proves the build failed at the commit gate.
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"commit mismatch"* ]]
}

# why: a wrong pinned bats-support commit must fail the bats-extensions build (base#1674)
@test "bats-extensions build fails when the BATS_SUPPORT_COMMIT pin is wrong" {
  run docker buildx build \
    --builder template-system \
    --target bats-extensions \
    --build-arg "BATS_SUPPORT_COMMIT=0000000000000000000000000000000000000000" \
    --progress=plain \
    --no-cache-filter bats-extensions \
    -f /source/dockerfile/Dockerfile.test-tools \
    /source 2>&1

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"bats-support: commit mismatch"* ]]
}
