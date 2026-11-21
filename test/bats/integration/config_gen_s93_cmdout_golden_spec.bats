#!/usr/bin/env bats
#
# config_gen_s93_cmdout_golden_spec.bats -- the s93 corpus of host command
# output against what today's shell makes of it (base#2068, S93a of
# base#1829 under base#1395).
#
# why: Before any Go code reads `docker info` or `dpkg-query` output, the
# shell's reading of it is pinned. Each corpus file under
# dockerfile/config-gen/testdata/corpus/s93 is the text a stubbed `docker`
# (s93_docker_*) or `dpkg-query` (s93_dpkg_*) prints; the golden under
# testdata/golden/s93/<stem>.golden is the one line `detect_docker_hub_user`
# / `detect_gpu` (dist/script/docker/lib/setup_detect.sh) leaves in its
# outvar, followed by a newline. The spec regenerates every golden from the
# shell and fails on any byte difference, on a corpus file with no golden,
# and on a golden with no corpus file.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  TESTDATA="/source/dockerfile/config-gen/testdata"
  CORPUS="${TESTDATA}/corpus/s93"
  GOLDEN="${TESTDATA}/golden/s93"
}

# _shell_result <stem> -- print what the shell function leaves in its outvar
# for the corpus file <stem>.txt, then a newline. USER is envuser.
_shell_result() {
  local _stem="${1}"
  CORPUS_FILE="${CORPUS}/${_stem}.txt" STEM="${_stem}" USER=envuser \
    bash -c '
      source /source/dist/script/docker/lib/setup_detect.sh
      docker() { cat -- "${CORPUS_FILE}"; }
      dpkg-query() { cat -- "${CORPUS_FILE}"; }
      case "${STEM}" in
        s93_docker_*) detect_docker_hub_user _out ;;
        s93_dpkg_*)   detect_gpu _out ;;
        *) printf "unknown stem: %s\n" "${STEM}" >&2; exit 2 ;;
      esac
      printf "%s\n" "${_out}"
    '
}

# _check_prefix <stem-prefix> -- every corpus file with the prefix has a
# golden and the shell result matches it byte for byte. Prints one line per
# violation; returns 1 on any.
_check_prefix() {
  local _prefix="${1}" _f _stem _bad=0
  for _f in "${CORPUS}/${_prefix}"*.txt; do
    [[ -e "${_f}" ]] || continue
    _stem="$(basename -- "${_f}" .txt)"
    if [[ ! -f "${GOLDEN}/${_stem}.golden" ]]; then
      printf 'corpus with no golden: %s\n' "${_stem}"
      _bad=1
      continue
    fi
    _shell_result "${_stem}" > "${BATS_TEST_TMPDIR}/got"
    if ! cmp -s -- "${BATS_TEST_TMPDIR}/got" "${GOLDEN}/${_stem}.golden"; then
      printf 'golden differs: %s\n' "${_stem}"
      _bad=1
    fi
  done
  return "${_bad}"
}

# why: the issue names nine corpus files; a missing one would silently
# shrink what is pinned.
@test "s93: the nine named corpus files exist" {
  local _s
  for _s in s93_docker_user_logged_in s93_docker_user_absent \
            s93_docker_user_empty_value s93_docker_user_extra_word \
            s93_dpkg_ii s93_dpkg_rc s93_dpkg_un s93_dpkg_empty \
            s93_dpkg_ii_then_rc; do
    [[ -f "${CORPUS}/${_s}.txt" ]] || { echo "missing corpus: ${_s}"; return 1; }
  done
}

# why: detect_docker_hub_user reads the second field of the Username line and
# falls back to USER when the line or the value is absent.
@test "s93: detect_docker_hub_user result matches every golden" {
  run _check_prefix s93_docker_
  [ "${status}" -eq 0 ] || { printf '%s\n' "${output}"; return 1; }
}

# why: detect_gpu is true only when some status line starts with ii.
@test "s93: detect_gpu result matches every golden" {
  run _check_prefix s93_dpkg_
  [ "${status}" -eq 0 ] || { printf '%s\n' "${output}"; return 1; }
}

# why: a golden whose corpus file was deleted would stand for nothing.
@test "s93: every golden has a corpus file" {
  local _g _stem _bad=0
  for _g in "${GOLDEN}"/*.golden; do
    [[ -e "${_g}" ]] || continue
    _stem="$(basename -- "${_g}" .golden)"
    if [[ ! -f "${CORPUS}/${_stem}.txt" ]]; then
      printf 'golden with no corpus: %s\n' "${_stem}"
      _bad=1
    fi
  done
  [ "${_bad}" -eq 0 ]
}
