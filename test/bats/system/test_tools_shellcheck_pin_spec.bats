#!/usr/bin/env bats
#
# System-level regression: the lint-tools stage of Dockerfile.test-tools
# verifies the shellcheck release asset against a pinned sha256 before it
# installs it (base#1648). Drives `docker buildx build --target lint-tools`
# so the real RUN line is exercised, not a text scan of the Dockerfile.
#
# The behaviour of the helper itself is covered by verify_extract_spec.bats
# in the plain `ci` lane; this file only guards the wiring: that the
# Dockerfile feeds the pinned value to the helper for the host arch.
#
# Requires the ci-system compose service (docker socket + network).
# Skips explicitly when the socket, the docker CLI or the builder is absent.

setup_file() {
  if [[ ! -S /var/run/docker.sock ]]; then
    skip "system test: /var/run/docker.sock not mounted (run via 'just test system')"
  fi
  if ! command -v docker >/dev/null 2>&1; then
    skip "system test: docker CLI not present"
  fi
}

# why: a wrong pinned sha256 must fail the lint-tools build (base#1648)
@test "lint-tools build fails when the shellcheck sha256 pin is wrong" {
  local _arch
  case "$(uname -m)" in
    x86_64) _arch=AMD64 ;;
    aarch64 | arm64) _arch=ARM64 ;;
    *) skip "unsupported host arch $(uname -m)" ;;
  esac

  run docker buildx build \
    --builder template-system \
    --target lint-tools \
    --build-arg "SHELLCHECK_SHA256_${_arch}=0000000000000000000000000000000000000000000000000000000000000000" \
    --progress=plain \
    --no-cache-filter lint-tools \
    -f /source/dockerfile/Dockerfile.test-tools \
    /source 2>&1

  # A failing build alone could be a network flake; the mismatch message
  # from the helper proves the build failed at the checksum gate.
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"sha256 mismatch"* ]]
}
