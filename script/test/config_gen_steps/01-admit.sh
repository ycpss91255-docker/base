#!/usr/bin/env bash
#
# 01-admit.sh -- config-gen step: the admission checker (base#1465).
#
# Run by script/test/config_gen_gates.sh with CONFIG_GEN_CTX set, after
# 00-manifest wrote $CONFIG_GEN_CTX/mutation. Installs this checkout's
# script/test/config_gen_admit.sh as $CONFIG_GEN_CTX/mutation/admit.sh, and
# the constructor library it sources (config_gen_mutation_lang.sh, the one
# the producer wrote the baseline with) beside it; the Dockerfile's admit
# stage runs the checker against the build context. Both come from the
# host checkout, never from the build context they judge.
#
# Style: Google Shell Style Guide.

set -euo pipefail

_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/../../.." && pwd -P)"
_dst="${CONFIG_GEN_CTX:?config_gen_steps run under CONFIG_GEN_CTX}/mutation"
install -m 0644 "${_root}/script/test/config_gen_admit.sh" "${_dst}/admit.sh"
install -m 0644 "${_root}/script/test/config_gen_mutation_lang.sh" \
  "${_dst}/config_gen_mutation_lang.sh"
