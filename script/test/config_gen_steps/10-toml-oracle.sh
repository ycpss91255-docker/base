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
# to one `docker run`, --network none, as a tar on stdin. The container
# runs the oracle program as `python3 -I -c`, which answers one
# `<rel>\taccept|refuse\t<sha256>` line per file, in the tar's order:
# `tomllib.loads` on the file's bytes decoded strictly as UTF-8, a TOML
# file's encoding, so a byte that is not UTF-8 is refuse, with the SHA-256
# of the bytes as read from the tar, so the differential test can hold
# each verdict to the file it reads (review round 2, base#1851). Those
# answers are written to $CONFIG_GEN_CTX/toml-oracle/verdicts.tsv.
#
# Refusal: an input path with a character outside [A-Za-z0-9._/-] is
# config_gen_toml_oracle_failed reason=name file=<rel>, before any
# `docker run` and before the toml-oracle directory exists: a verdict row
# is keyed by path, and such a name may not survive the tar, the oracle
# program and the TSV unchanged. An image that cannot be derived or built,
# and a container that exits non-zero, are config_gen_toml_oracle_failed
# reason=image, and the toml-oracle directory is removed, so the build has
# no verdicts to read. An answer whose line count differs from the number
# of files handed in is config_gen_toml_oracle_failed reason=count, with
# the same removal. A row that is not three fields, whose second field is
# neither `accept` nor `refuse`, or whose third is not 64 lower-case hex
# digits, is config_gen_toml_oracle_failed reason=token, with the
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

# The oracle program the bridge image's python3 runs: read the tar on
# stdin member by member and print each file's verdict row.
readonly _TO_PROGRAM='import hashlib, sys, tarfile, tomllib
with tarfile.open(fileobj=sys.stdin.buffer, mode="r|") as tar:
    for member in tar:
        if not member.isfile():
            continue
        raw = tar.extractfile(member).read()
        try:
            tomllib.loads(raw.decode("utf-8"))
            verdict = "accept"
        except Exception:
            verdict = "refuse"
        sys.stdout.write(member.name + "\t" + verdict + "\t" + hashlib.sha256(raw).hexdigest() + "\n")'

main() {
  local image module dir out
  local -a dirs=() files=()

  if ! image="$(tool_image_derive toml_bridge)" \
    || ! tool_image_ensure toml_bridge "${image}"; then
    _log_err "${_TO_SERVICE}" config_gen_toml_oracle_failed reason=image \
      "display=config_gen_toml_oracle_failed: the pinned toml-bridge image could not be derived or built; there is no tomllib to ask"
    return 1
  fi

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
        --entrypoint python3 "${image}" -I -c "${_TO_PROGRAM}" > "${out}/verdicts.tsv"; then
    rm -rf -- "${out}"
    _log_err "${_TO_SERVICE}" config_gen_toml_oracle_failed reason=image \
      "display=config_gen_toml_oracle_failed: the toml-bridge container ${image} exited non-zero; what it printed is not tomllib's verdict"
    return 1
  fi

  local rows
  rows="$(wc -l < "${out}/verdicts.tsv")"
  if (( rows != ${#files[@]} )); then
    rm -rf -- "${out}"
    _log_err "${_TO_SERVICE}" config_gen_toml_oracle_failed reason=count \
      "display=config_gen_toml_oracle_failed: the toml-bridge container answered ${rows} lines for ${#files[@]} files"
    return 1
  fi

  local bad
  bad="$(awk -F'\t' 'NF != 3 || ($2 != "accept" && $2 != "refuse") \
    || length($3) != 64 || $3 ~ /[^0-9a-f]/ { print NR; exit }' "${out}/verdicts.tsv")"
  if [[ -n "${bad}" ]]; then
    rm -rf -- "${out}"
    _log_err "${_TO_SERVICE}" config_gen_toml_oracle_failed reason=token \
      "display=config_gen_toml_oracle_failed: line ${bad} of the toml-bridge container's answer is not <rel>, accept or refuse, and a SHA-256"
    return 1
  fi
}

main "$@"
