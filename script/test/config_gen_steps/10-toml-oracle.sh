#!/usr/bin/env bash
#
# 10-toml-oracle.sh -- ask the pinned tomllib for its verdict on every TOML
# file the gate is held to (base#1851).
#
# A config-gen step: script/test/config_gen_gates.sh runs it before the
# gates, in every environment `just test go` reaches, and the redpath runs
# it again on each scratch copy. It reads everything relative to its own
# root (three directories up), never the caller's checkout.
#
# The oracle is the toml-bridge image pinned by dockerfile/
# Dockerfile.toml-bridge, named by the content-digest tag tool_image_derive
# computes and built by tool_image_ensure when absent. derive+ensure, not
# tool_image_resolve: a TOML_BRIDGE_IMAGE override must not swap in a
# parser that is not the pinned one.
#
# The input set, relative to dockerfile/config-gen and in C-locale order:
# every *.toml at any depth under internal/gate/testdata/forms and
# internal/gate/testdata/toml-test, and every testdata/corpus/s*/*.toml,
# the shared corpus internal/testcorpus.Glob reads (base#1851). It goes
# to one `docker run`, --network none, as a tar on stdin; the container
# answers one `<rel>\taccept|refuse` line per file, from `tomllib.loads`
# on the file's bytes. Those answers are written to
# $CONFIG_GEN_CTX/toml-oracle/verdicts.tsv.
#
# Exit: 0 verdicts written; non-zero otherwise.
#
# Style: Google Shell Style Guide.

set -euo pipefail

_TO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
readonly _TO_DIR
_TO_ROOT="$(cd -- "${_TO_DIR}/../../.." && pwd -P)"
readonly _TO_ROOT
# shellcheck source=dist/script/docker/lib/toml_bridge.sh
source "${_TO_ROOT}/dist/script/docker/lib/toml_bridge.sh"

readonly _TO_MODULE_REL='dockerfile/config-gen'
readonly -a _TO_INPUT_DIRS=(
  'internal/gate/testdata/forms'
  'internal/gate/testdata/toml-test'
)
# The shared corpus: one level of slice directories, TOML files directly
# inside each, the shape testcorpus.Glob(t, "corpus/s*/*.toml") matches.
readonly _TO_CORPUS_DIR='testdata/corpus'

# What runs inside the bridge image: extract the tar, then one
# `python3 -I` per file, with the bridge's call shape
# (<module> -> main() -> tomllib.loads).
# shellcheck disable=SC2016 # expanded by the container's shell, not here.
readonly _TO_CONTAINER_SCRIPT='set -eu
mkdir -p /tmp/w
cd /tmp/w
tar -xf -
find . -type f -name "*.toml" | LC_ALL=C sort | while IFS= read -r f; do
  rel="${f#./}"
  if python3 -I -c "
import sys, tomllib
def main():
    raw = sys.stdin.buffer.read()
    try:
        tomllib.loads(raw.decode())
    except Exception:
        raise SystemExit(1)
main()
" < "$f"; then
    printf "%s\taccept\n" "$rel"
  else
    printf "%s\trefuse\n" "$rel"
  fi
done'

main() {
  local image module dir out
  local -a dirs=() files=()

  image="$(tool_image_derive toml_bridge)"
  tool_image_ensure toml_bridge "${image}"

  module="${_TO_ROOT}/${_TO_MODULE_REL}"
  for dir in "${_TO_INPUT_DIRS[@]}"; do
    [[ -d "${module}/${dir}" ]] && dirs+=("${dir}")
  done
  local corpus=''
  [[ -d "${module}/${_TO_CORPUS_DIR}" ]] && corpus="${_TO_CORPUS_DIR}"
  if (( ${#dirs[@]} > 0 )) || [[ -n "${corpus}" ]]; then
    mapfile -t files < <(cd -- "${module}" && {
      (( ${#dirs[@]} == 0 )) || find "${dirs[@]}" -type f -name '*.toml'
      [[ -z "${corpus}" ]] || find "${corpus}" -mindepth 2 -maxdepth 2 -type f \
        -path "${corpus}/s*/*.toml"
    } | LC_ALL=C sort)
  fi

  out="${CONFIG_GEN_CTX:?config_gen_steps run under CONFIG_GEN_CTX}/toml-oracle"
  mkdir -p -- "${out}"
  tar -C "${module}" -cf - --no-recursion -- "${files[@]}" \
    | docker run --rm -i --network none --user "$(id -u):$(id -g)" \
        --entrypoint /bin/sh "${image}" -c "${_TO_CONTAINER_SCRIPT}" > "${out}/verdicts.tsv"
}

main "$@"
