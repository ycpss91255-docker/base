#!/usr/bin/env bash
#
# 00-manifest.sh -- config-gen step: the host mutation baseline (base#1464).
#
# Run by script/test/config_gen_gates.sh with CONFIG_GEN_CTX set; writes
# $CONFIG_GEN_CTX/mutation/{manifest,visible.sha256,ignored.sha256} from
# the checkout this step sits in, which the runner hands the build as
# `--build-context mutation=...`. CONFIG_GEN_MUTATION_CONTEXT and
# CONFIG_GEN_MUTATION_BASE pass through; see config_gen_mutation_targets.sh.
#
# Style: Google Shell Style Guide.

set -euo pipefail

_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/../../.." && pwd -P)"
exec bash "${_root}/script/test/config_gen_mutation_targets.sh" \
  --repo "${_root}" "${CONFIG_GEN_CTX:?config_gen_steps run under CONFIG_GEN_CTX}/mutation"
