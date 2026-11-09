#!/usr/bin/env bash
# install-just.sh - Install the pinned just release and put it on PATH.
#
# Usage: install-just.sh <version>
#
# Every CI job (hosted and self-hosted alike) installs just with this
# script, so each fetch rides on script/ci/retry.sh and one upstream 5xx
# does not fail the job, base#1562.
set -euo pipefail

JUST_VERSION="${1:?usage: install-just.sh <version>}"
: "${RUNNER_TEMP:?RUNNER_TEMP is not set}"
: "${GITHUB_PATH:?GITHUB_PATH is not set}"

retry="$(dirname "${BASH_SOURCE[0]:-$0}")/retry.sh"

arch="$(uname -m)"
asset="just-${JUST_VERSION}-${arch}-unknown-linux-musl.tar.gz"
rel="https://github.com/casey/just/releases/download/${JUST_VERSION}"

dl="${RUNNER_TEMP}/just-${JUST_VERSION}-dl"
bin="${RUNNER_TEMP}/just-${JUST_VERSION}/bin"
mkdir -p "${dl}" "${bin}"

"${retry}" 5 5 -- curl -fsSL --max-time 60 -o "${dl}/${asset}" "${rel}/${asset}"
"${retry}" 5 5 -- curl -fsSL --max-time 60 -o "${dl}/SHA256SUMS" "${rel}/SHA256SUMS"

# The tarball must be the release's bytes: its SHA256SUMS line must be
# present and match, or nothing reaches PATH, base#1562.
sum_line="$(awk -v a="${asset}" '$2 == a || $2 == "*" a' "${dl}/SHA256SUMS")"
[[ -n "${sum_line}" ]] \
  || { printf 'install-just: %s is not listed in SHA256SUMS\n' "${asset}" >&2; exit 1; }
(cd "${dl}" && printf '%s\n' "${sum_line}" | sha256sum -c --quiet -)

tar -xzf "${dl}/${asset}" -C "${bin}" just

printf '%s\n' "${bin}" >> "${GITHUB_PATH}"
