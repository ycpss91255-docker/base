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
# Output: nothing on stdout for an export vertex that ends in `#N DONE`;
#         one `::warning title=cache export::<label>: <error>` line for an
#         export vertex that ends in `#N ERROR: <error>`, or for one the
#         record never ends (no final `#N DONE` or `#N ERROR:` line), or
#         when the record shows no cache export vertex at all, or when the
#         metadata names no build record, or when the history call fails.
#         Always exits 0: a cache export never fails the job.

set -uo pipefail

main() {
  local ref logs
  ref="$(printf '%s' "${BUILD_METADATA:-}" | jq -r '."buildx.build.ref" // empty' 2>/dev/null)"
  # No build record ref: no record can be read, so a success cannot be shown.
  if [[ -z "${ref}" ]]; then
    printf '::warning title=cache export::%s: the build metadata names no build record (buildx.build.ref)\n' "${CACHE_EXPORT_LABEL:-}"
    return 0
  fi
  # A history call that fails cannot vouch for the record, whatever it
  # printed before failing. `history logs` prints the record on stderr
  # (observed in the base#1602 system spec), so both streams are read.
  if ! logs="$(docker buildx history logs --progress plain "${ref##*/}" 2>&1)"; then
    printf '::warning title=cache export::%s: docker buildx history logs failed for build record %s\n' "${CACHE_EXPORT_LABEL:-}" "${ref##*/}"
    return 0
  fi
  # Each cache export vertex (`exporting to GitHub Actions Cache` for
  # type=gha, `exporting cache ...` for the other cache backends): remember
  # its number, then report the error text of an `#N ERROR: ...` line that
  # ends it. A vertex the record never ends (no `#N DONE`, no `#N ERROR:`)
  # cannot be shown to have succeeded, so it warns too.
  printf '%s\n' "${logs}" | awk -v label="${CACHE_EXPORT_LABEL:-}" '
    $0 ~ /^#[0-9]+ (exporting to GitHub Actions Cache|exporting cache( to .+)?)$/ {
      export[$1] = 1; order[++n] = $1; next
    }
    ($1 in export) && $2 == "DONE" { ended[$1] = 1; next }
    ($1 in export) && $2 == "ERROR:" {
      ended[$1] = 1
      msg = $0
      sub(/^#[0-9]+ ERROR: /, "", msg)
      printf "::warning title=cache export::%s: %s\n", label, msg
    }
    END {
      if (n == 0) {
        printf "::warning title=cache export::%s: the build record shows no cache export vertex\n", label
      }
      for (i = 1; i <= n; i++) {
        if (!(order[i] in ended)) {
          printf "::warning title=cache export::%s: cache export vertex %s has no final DONE or ERROR line\n", label, order[i]
        }
      }
    }
  '
  return 0
}

main "$@"
