#!/usr/bin/env bash
#
# 01-admit.sh -- config-gen step: the admission checker (base#1465).
#
# Run by script/test/config_gen_gates.sh with CONFIG_GEN_CTX set, after
# 00-manifest wrote $CONFIG_GEN_CTX/mutation. Installs this checkout's
# script/test/config_gen_admit.sh as $CONFIG_GEN_CTX/mutation/admit.sh,
# which the Dockerfile's admit stage runs against the build context. The
# checker comes from the host checkout, never from the build context it
# judges.
#
# Style: Google Shell Style Guide.

set -euo pipefail

_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/../../.." && pwd -P)"
install -m 0644 "${_root}/script/test/config_gen_admit.sh" \
  "${CONFIG_GEN_CTX:?config_gen_steps run under CONFIG_GEN_CTX}/mutation/admit.sh"
