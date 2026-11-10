#!/usr/bin/env bats
#
# System-level check of the cache-export path, base#1602: a real
# `docker buildx build` whose cache export fails. With
# `ignore-error=true` on the cache-to the build stays green, and
# script/ci/build_worker/cache_export_warn.sh, reading that build's own
# record, leaves a `::warning::` that names the export's failure. Without
# `ignore-error=true` the same failed export fails the build.
#
# The export target is `localhost:1` inside the builder's own container,
# a registry nothing listens on, so the export fails every time without a
# network or a credential. The image itself builds.
#
# Requires the ci-system compose service (host /var/run/docker.sock and
# the template-system builder that test.sh _system_setup creates and
# `use`s). Skips when the socket is absent.

bats_require_minimum_version 1.5.0

# No test_helper: this level's specs assert with plain `[ ]` on docker's
# status and output, like their siblings here, and load nothing.

setup_file() {
  if [[ ! -S /var/run/docker.sock ]]; then
    skip "system test: /var/run/docker.sock not mounted (run via 'just test system')"
  fi
  if ! command -v docker >/dev/null 2>&1; then
    skip "system test: docker CLI not present"
  fi
  FIXTURE_DIR="$(mktemp -d -t base-1602-cache-export-XXXXXX)"
  export FIXTURE_DIR
  # A layer of its own, so a mode=max export has a blob to write.
  cat > "${FIXTURE_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS probe
RUN echo base-1602 > /probe
EOF
}

teardown_file() {
  [[ -n "${FIXTURE_DIR:-}" && -d "${FIXTURE_DIR}" ]] && rm -rf "${FIXTURE_DIR}"
}

# _build_with_cache_to <cache-to> <metadata-file>
_build_with_cache_to() {
  docker buildx build \
    --builder template-system \
    --target probe \
    --cache-to "${1}" \
    --metadata-file "${2}" \
    --progress=plain \
    -f "${FIXTURE_DIR}/Dockerfile" \
    "${FIXTURE_DIR}" 2>&1
}

# why: The reported failure (isaac run 42753553284, `#26 exporting to
# GitHub Actions Cache` / `#26 ERROR: error writing layer blob`) was an
# image that BUILT and a cache export that failed, and the export error
# became the build's error. ignore-error=true must keep such a build
# green, and the warn script must then find the failed export vertex in
# that build's record and report it -- not fall back to "no export
# vertex" or "history call failed", which would warn for a reason that
# has nothing to do with the export. The control without ignore-error is
# the reported red, base#1602.
@test "a failed cache export with ignore-error=true leaves a green build and one ::warning:: from the export vertex; without it the build fails (base#1602)" {
  local _warn="/source/script/ci/build_worker/cache_export_warn.sh"
  local _meta="${BATS_TEST_TMPDIR}/m.json" _warns

  run _build_with_cache_to \
    'type=registry,ref=localhost:1/none,ignore-error=true' "${_meta}"
  [ "${status}" -eq 0 ]

  BUILD_METADATA="$(cat "${_meta}")" CACHE_EXPORT_LABEL=probe \
    run bash "${_warn}"
  echo "warn script output: ${output}"
  [ "${status}" -eq 0 ]
  _warns="$(grep -E '^::warning title=cache export::' <<<"${output}" || true)"
  [ "$(grep -c . <<<"${_warns}")" -eq 1 ]
  [[ "${_warns}" == "::warning title=cache export::probe: "* ]]
  # The warning must come from the export vertex itself, not from one of
  # the script's fallbacks.
  [[ "${_warns}" != *"shows no cache export vertex"* ]]
  [[ "${_warns}" != *"history logs failed"* ]]
  [[ "${_warns}" != *"names no build record"* ]]

  run _build_with_cache_to \
    'type=registry,ref=localhost:1/none' "${BATS_TEST_TMPDIR}/m2.json"
  [ "${status}" -ne 0 ]
}
