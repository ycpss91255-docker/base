#!/usr/bin/env bash
#
# 10-toml-oracle.sh -- ask the pinned tomllib for its verdict on every TOML
# file the gate is held to (base#1441).
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
# the shared corpus internal/testcorpus.Glob reads (base#1441). It goes
# to one `docker run`,
# --network none, as a tar on stdin; the container answers one
# `<rel>\taccept|refuse` line per file, from `tomllib.loads` on the file's
# bytes. Those answers are written verbatim to
# $CONFIG_GEN_CTX/toml-oracle/verdicts.tsv, which config_gen_gates.sh
# hands to the build as the `toml-oracle` context.
#
# Refusal: an input path with a character outside [A-Za-z0-9._/-] is
# config_gen_toml_oracle_failed reason=name file=<rel>, before any
# `docker run` and before the toml-oracle directory exists: a verdict row
# is keyed by path, and such a name may not survive the tar, the
# container's loop and the TSV unchanged. A container that exits non-zero is config_gen_toml_oracle_failed
# reason=image, and the toml-oracle directory is removed, so the build has
# no verdicts to read. An answer whose line count is not the number of
# files handed over is config_gen_toml_oracle_failed reason=count, with the
# directory removed the same way. A row whose second field is neither
# `accept` nor `refuse` is config_gen_toml_oracle_failed reason=token,
# with the directory removed the same way.
#
# Calibration: the oracle program stands in for the real bridge only while
# it sits at the bridge's Python call depth, which tomllib's depth refusals
# depend on. So for every file under internal/gate/testdata/forms/depth the
# container also runs the image's real `toml-bridge --tables` and answers
# `calibration\t<rel>\taccept|refuse` after the verdict rows. Those lines
# are not verdicts: they are left out of verdicts.tsv and of the row count.
# A calibration answer that differs from that file's verdict row is
# config_gen_toml_oracle_failed reason=calibration file=<rel>, with the
# directory removed the same way.
#
# Exit: 0 verdicts written; 1 otherwise.
#
# Style: Google Shell Style Guide.

set -euo pipefail

_TO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
readonly _TO_DIR
_TO_ROOT="$(cd -- "${_TO_DIR}/../../.." && pwd -P)"
readonly _TO_ROOT
# shellcheck source=dist/script/docker/lib/toml_bridge.sh
source "${_TO_ROOT}/dist/script/docker/lib/toml_bridge.sh"

readonly _TO_SERVICE='config-gen'
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
done
find . -type f -path "./internal/gate/testdata/forms/depth/*" -name "*.toml" | LC_ALL=C sort | while IFS= read -r f; do
  rel="${f#./}"
  if python3 -I /usr/local/bin/toml-bridge --tables < "$f" > /dev/null 2>&1; then
    printf "calibration\t%s\taccept\n" "$rel"
  else
    printf "calibration\t%s\trefuse\n" "$rel"
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

  local f
  for f in "${files[@]}"; do
    if [[ ! "${f}" =~ ^[A-Za-z0-9._/-]+$ ]]; then
      _log_err "${_TO_SERVICE}" config_gen_toml_oracle_failed reason=name "file=${f}" \
        "display=config_gen_toml_oracle_failed: ${f} has a character outside [A-Za-z0-9._/-]; its verdict row could not be keyed by path"
      return 1
    fi
  done

  out="${CONFIG_GEN_CTX:?config_gen_steps run under CONFIG_GEN_CTX}/toml-oracle"
  mkdir -p -- "${out}"
  if ! tar -C "${module}" -cf - --no-recursion -- "${files[@]}" \
    | docker run --rm -i --network none --user "$(id -u):$(id -g)" \
        --entrypoint /bin/sh "${image}" -c "${_TO_CONTAINER_SCRIPT}" > "${out}/answer.raw"; then
    rm -rf -- "${out}"
    _log_err "${_TO_SERVICE}" config_gen_toml_oracle_failed reason=image \
      "display=config_gen_toml_oracle_failed: the toml-bridge container ${image} exited non-zero; what it printed is not tomllib's verdict"
    return 1
  fi

  grep -v $'^calibration\t' "${out}/answer.raw" > "${out}/verdicts.tsv" || true
  grep $'^calibration\t' "${out}/answer.raw" > "${out}/calibration.tsv" || true
  rm -f -- "${out}/answer.raw"

  local rows
  rows="$(wc -l < "${out}/verdicts.tsv")"
  if (( rows != ${#files[@]} )); then
    rm -rf -- "${out}"
    _log_err "${_TO_SERVICE}" config_gen_toml_oracle_failed reason=count \
      "display=config_gen_toml_oracle_failed: the toml-bridge container answered ${rows} lines for ${#files[@]} files"
    return 1
  fi

  local bad
  bad="$(awk -F'\t' '$2 != "accept" && $2 != "refuse" { print NR; exit }' "${out}/verdicts.tsv")"
  if [[ -n "${bad}" ]]; then
    rm -rf -- "${out}"
    _log_err "${_TO_SERVICE}" config_gen_toml_oracle_failed reason=token \
      "display=config_gen_toml_oracle_failed: line ${bad} of the toml-bridge container's answer has a verdict that is neither accept nor refuse"
    return 1
  fi

  local drift
  drift="$(awk -F'\t' 'FILENAME == ARGV[1] { v[$1] = $2; next }
    v[$2] != $3 { print $2; exit }' "${out}/verdicts.tsv" "${out}/calibration.tsv")"
  rm -f -- "${out}/calibration.tsv"
  if [[ -n "${drift}" ]]; then
    rm -rf -- "${out}"
    _log_err "${_TO_SERVICE}" config_gen_toml_oracle_failed reason=calibration "file=${drift}" \
      "display=config_gen_toml_oracle_failed: the real toml-bridge --tables and the oracle program disagree on ${drift}; the oracle no longer stands for the bridge"
    return 1
  fi
}

main "$@"
