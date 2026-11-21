#!/usr/bin/env bats
#
# conf_ini_golden_spec.bats -- the INI corpus held to recorded bytes
# (base#2053, S25a under #1757).
#
# why: `_ini_tokenize` is the single shell INI tokenizer. The Go reader
# that replaces it (the later `ini tokens` slice) must match it byte for
# byte, so the shell's answer for every corpus input is recorded once in
# dockerfile/config-gen/testdata/golden/s25/<stem>.tokens.golden and this
# spec holds the shell to that record. A golden is tab-separated lines:
# `section<TAB><name>` per section, then
# `entry<TAB><section><TAB><key><TAB><value>` per entry.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  # shellcheck source=dist/script/docker/lib/conf.sh
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/conf.sh
  CORPUS=/source/dockerfile/config-gen/testdata/corpus/s25
  GOLDEN=/source/dockerfile/config-gen/testdata/golden/s25
}

# _tokens_of <file> -- print the golden-format rendering of what
# _ini_tokenize reads from <file>.
_tokens_of() {
  local -a _s=() _es=() _k=() _v=()
  local _i
  _ini_tokenize "${1}" _s _es _k _v
  for _i in "${!_s[@]}"; do
    printf 'section\t%s\n' "${_s[_i]}"
  done
  for _i in "${!_k[@]}"; do
    printf 'entry\t%s\t%s\t%s\n' "${_es[_i]}" "${_k[_i]}" "${_v[_i]}"
  done
}

@test "the s25 corpus holds its eight inputs" {
  local -a _f=("${CORPUS}"/*.ini)
  assert_equal "${#_f[@]}" "8"
}

@test "every s25 input has a golden, and no golden is orphaned" {
  local _f _stem _missing=""
  for _f in "${CORPUS}"/*.ini; do
    _stem="$(basename "${_f}" .ini)"
    [[ -s "${GOLDEN}/${_stem}.tokens.golden" ]] || _missing+=" ${_stem}"
  done
  [[ -z "${_missing}" ]] || {
    echo "inputs without a non-empty golden:${_missing}" >&2
    return 1
  }
  local _g
  for _g in "${GOLDEN}"/*.tokens.golden; do
    [[ -f "${_g}" ]] || continue
    _stem="$(basename "${_g}" .tokens.golden)"
    [[ -f "${CORPUS}/${_stem}.ini" ]] || return 1
  done
}

@test "_ini_tokenize over every s25 input matches its golden byte for byte" {
  local _f _stem _bad=""
  for _f in "${CORPUS}"/*.ini; do
    _stem="$(basename "${_f}" .ini)"
    if ! cmp -s <(_tokens_of "${_f}") "${GOLDEN}/${_stem}.tokens.golden"; then
      _bad+=" ${_stem}"
    fi
  done
  [[ -z "${_bad}" ]] || {
    echo "differs from golden:${_bad}" >&2
    return 1
  }
}
