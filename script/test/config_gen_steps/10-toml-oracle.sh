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
# answers one `<rel>\taccept|refuse\t<sha256>` line per file, from
# `tomllib.loads` on the file's bytes, with the SHA-256 of the bytes it
# parsed, so the differential test can hold each verdict to the file it
# reads (review round 2, base#1851). Those answers are written to
# $CONFIG_GEN_CTX/toml-oracle/verdicts.tsv.
#
# Refusal: an input path with a character outside [A-Za-z0-9._/-] is
# config_gen_toml_oracle_failed reason=name file=<rel>, before any
# `docker run` and before the toml-oracle directory exists: a verdict row
# is keyed by path, and such a name may not survive the tar, the
# container's loop and the TSV unchanged. An image that cannot be derived
# or built, and a container that exits non-zero, are
# config_gen_toml_oracle_failed reason=image, and the toml-oracle
# directory is removed, so the build has no verdicts to read. Inside the
# container a file's verdict is the word the oracle program printed after
# tomllib answered; an interpreter that exits non-zero, or is killed, on
# any file fails the container, so it is reason=image too, never a
# `refuse` row. An answer whose line count differs from the number of
# files handed in is config_gen_toml_oracle_failed reason=count, with the
# same removal. A row that is not three fields, whose second field is
# neither `accept` nor `refuse`, or whose third is not 64 lower-case hex
# digits, is config_gen_toml_oracle_failed reason=token, with the
# directory removed the same way.
#
# Calibration: the oracle program stands in for the real bridge only while
# it sits at the bridge's Python call depth, which tomllib's depth refusals
# depend on. So for every file under internal/gate/testdata/forms the
# container also runs the image's real `toml-bridge --tables` and answers
# `calibration\t<rel>\taccept|refuse` after the verdict rows (exit 0 is
# accept, 1 refuse, anything else fails the container). Those lines are
# not verdicts: they are left out of verdicts.tsv and of the row count.
# Calibration lines that do not name every forms file exactly once, in
# order, or a run with no forms file to calibrate with, are
# config_gen_toml_oracle_failed reason=calibration: a calibration that did
# not run compared nothing. A calibration answer that differs from that
# file's verdict row is config_gen_toml_oracle_failed reason=calibration
# file=<rel>. Each removes the directory the same way (review round 1,
# base#1851).
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
# (<module> -> main() -> tomllib.loads); the digest is taken after main()
# returns, from the bytes main() handed tomllib.
# shellcheck disable=SC2016 # expanded by the container's shell, not here.
readonly _TO_CONTAINER_SCRIPT='set -eu
w="$(mktemp -d)"
cd "$w"
tar -xf -
find . -type f -name "*.toml" | LC_ALL=C sort | while IFS= read -r f; do
  rel="${f#./}"
  v="$(python3 -I -c "
import hashlib, sys, tomllib
def main():
    raw = sys.stdin.buffer.read()
    try:
        tomllib.loads(raw.decode())
    except Exception:
        return \"refuse\", raw
    return \"accept\", raw
v, raw = main()
print(v + chr(9) + hashlib.sha256(raw).hexdigest())
" < "$f")" || { printf "toml-oracle: python3 failed on %s\n" "$rel" >&2; exit 1; }
  printf "%s\t%s\n" "$rel" "$v"
done
find . -type f -path "./internal/gate/testdata/forms/*" -name "*.toml" | LC_ALL=C sort | while IFS= read -r f; do
  rel="${f#./}"
  rc=0
  python3 -I /usr/local/bin/toml-bridge --tables < "$f" > /dev/null 2>&1 || rc=$?
  case "$rc" in
    0) v=accept ;;
    1) v=refuse ;;
    *) printf "toml-oracle: toml-bridge exited %s on %s\n" "$rc" "$rel" >&2; exit 1 ;;
  esac
  printf "calibration\t%s\t%s\n" "$rel" "$v"
done'

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
  bad="$(awk -F'\t' 'NF != 3 || ($2 != "accept" && $2 != "refuse") \
    || length($3) != 64 || $3 ~ /[^0-9a-f]/ { print NR; exit }' "${out}/verdicts.tsv")"
  if [[ -n "${bad}" ]]; then
    rm -rf -- "${out}"
    _log_err "${_TO_SERVICE}" config_gen_toml_oracle_failed reason=token \
      "display=config_gen_toml_oracle_failed: line ${bad} of the toml-bridge container's answer is not <rel>, accept or refuse, and a SHA-256"
    return 1
  fi

  local f want=''
  for f in "${files[@]}"; do
    [[ "${f}" == internal/gate/testdata/forms/* ]] && want+="${f}"$'\n'
  done
  if [[ -z "${want}" ]] \
    || [[ "$(cut -f2 "${out}/calibration.tsv")"$'\n' != "${want}" ]]; then
    rm -rf -- "${out}"
    _log_err "${_TO_SERVICE}" config_gen_toml_oracle_failed reason=calibration \
      "display=config_gen_toml_oracle_failed: the toml-bridge container's calibration lines do not name every forms file once; nothing was calibrated against the real toml-bridge --tables"
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
