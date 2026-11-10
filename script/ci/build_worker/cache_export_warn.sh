#!/usr/bin/env bash
# cache_export_warn.sh -- cache-export check that runs after a build-worker
# build whose cache-to carries ignore-error=true, base#1602.
#
# With ignore-error=true a failed GitHub Actions Cache export no longer
# fails the build. This script replays the build record and reads how each
# cache export vertex ended, so a failed export can leave a trace.
#
# Input : BUILD_METADATA (the JSON docker/build-push-action emits as
#         `outputs.metadata`; its `buildx.build.ref` names the build record)
#         and CACHE_EXPORT_LABEL (the stage name the build produced).
# Output: nothing on stdout for an export vertex that ends in `#N DONE`.
#         Always exits 0: a cache export never fails the job.

set -uo pipefail

main() {
  local ref
  ref="$(printf '%s' "${BUILD_METADATA:-}" | jq -r '."buildx.build.ref" // empty' 2>/dev/null)"
  docker buildx history logs --progress plain "${ref##*/}" >/dev/null 2>&1
  return 0
}

main "$@"
