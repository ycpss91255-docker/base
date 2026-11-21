#!/usr/bin/env bash
#
# config_gen_digest.sh -- print the config-gen digest of this checkout
# (base#2042, part of base#2037 / base#1848).
#
# Prints the 12 hex digits after the colon of `tool_image_derive config_gen`
# (the shell shim's own derivation), one line, exit 0. When no digest can be
# derived it prints nothing on stdout, exits non-zero and leaves the
# library's refusal on stderr.

set -euo pipefail

_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"

# shellcheck source=dist/script/docker/lib/config_gen.sh
source "${_here}/../../dist/script/docker/lib/config_gen.sh"

_tag="$(tool_image_derive config_gen)" || exit 1
printf '%s\n' "${_tag#*:}"
