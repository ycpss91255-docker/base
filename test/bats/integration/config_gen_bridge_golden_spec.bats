#!/usr/bin/env bats
#
# config_gen_bridge_golden_spec.bats -- the s1 corpus of `config-gen tables`
# against the bridge's `--tables` goldens (base#1469, slice S1i of base#1395).
#
# why: Every fixture under dockerfile/config-gen/testdata/corpus/s1 carries
# one explicit expectation class in testdata/golden/s1/EXPECT, one row per
# fixture, `<fixture>\t<class>`:
#
#   parity                      bridge and config-gen print the golden
#   parity-refused              both sides give rc 1
#   bridge-refused-go-accepted  config-gen gives rc 0 and its golden, the
#                               bridge gives rc 1; only toml11_* fixtures
#                               may carry it (today's known divergence,
#                               not a parity claim)
#
# A fixture with no row, a row with no fixture, or the divergent class on
# any other name fails the spec, so a new fixture can never be read without
# a stated expectation and a stale row can never stand for a deleted one.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  TESTDATA="/source/dockerfile/config-gen/testdata"
  S="${BATS_TEST_TMPDIR}"
}

# ── the partition check ─────────────────────────────────────────────────────

# _expect_partition <corpus-dir> <expect-file> -- succeed only when every
# <corpus-dir>/*.toml stem has exactly one well-formed EXPECT row, every row
# names an existing fixture, and bridge-refused-go-accepted sits only on a
# toml11_* name. Prints one line per violation; returns 1 on any.
_expect_partition() {
  local _corpus="${1}" _expect="${2}" _line _name _class _f _stem _bad=0
  local _re=$'^([^\t]+)\t(parity|parity-refused|bridge-refused-go-accepted)$'
  local -A _row=()
  if [[ ! -f "${_expect}" ]]; then
    printf 'EXPECT file missing: %s\n' "${_expect}"
    return 1
  fi
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    if [[ ! "${_line}" =~ ${_re} ]]; then
      printf 'EXPECT row malformed: %q\n' "${_line}"
      _bad=1
      continue
    fi
    _name="${BASH_REMATCH[1]}"
    _class="${BASH_REMATCH[2]}"
    if [[ -n "${_row["${_name}"]+set}" ]]; then
      printf 'EXPECT row repeated: %s\n' "${_name}"
      _bad=1
    fi
    _row["${_name}"]="${_class}"
    if [[ ! -f "${_corpus}/${_name}.toml" ]]; then
      printf 'EXPECT row with no fixture: %s\n' "${_name}"
      _bad=1
    fi
    if [[ "${_class}" == bridge-refused-go-accepted && "${_name}" != toml11_* ]]; then
      printf 'bridge-refused-go-accepted on a non-toml11_* fixture: %s\n' "${_name}"
      _bad=1
    fi
  done < "${_expect}"
  for _f in "${_corpus}"/*.toml; do
    [[ -e "${_f}" ]] || continue
    _stem="$(basename -- "${_f}" .toml)"
    if [[ -z "${_row["${_stem}"]+set}" ]]; then
      printf 'fixture with no EXPECT row: %s\n' "${_stem}"
      _bad=1
    fi
  done
  return "${_bad}"
}

# _mini <name>... -- a scratch corpus ${S}/c holding <name>.toml for each
# name, for the partition check's own rows.
_mini() {
  local _n
  mkdir -p "${S}/c"
  for _n in "$@"; do
    printf 'x = 1\n' > "${S}/c/${_n}.toml"
  done
}

@test "partition: a fixture with no EXPECT row fails" {
  _mini a b
  printf 'a\tparity\n' > "${S}/EXPECT"
  run _expect_partition "${S}/c" "${S}/EXPECT"
  assert_failure
  assert_output --partial "fixture with no EXPECT row: b"
}

@test "partition: an EXPECT row with no fixture fails" {
  _mini a
  printf 'a\tparity\nghost\tparity-refused\n' > "${S}/EXPECT"
  run _expect_partition "${S}/c" "${S}/EXPECT"
  assert_failure
  assert_output --partial "EXPECT row with no fixture: ghost"
}

@test "partition: bridge-refused-go-accepted on a non-toml11_* fixture fails" {
  _mini a toml11_ok
  printf 'a\tbridge-refused-go-accepted\ntoml11_ok\tbridge-refused-go-accepted\n' > "${S}/EXPECT"
  run _expect_partition "${S}/c" "${S}/EXPECT"
  assert_failure
  assert_output "bridge-refused-go-accepted on a non-toml11_* fixture: a"
}

@test "partition: one well-formed row per fixture passes" {
  _mini a b toml11_ok
  printf 'a\tparity\nb\tparity-refused\ntoml11_ok\tbridge-refused-go-accepted\n' > "${S}/EXPECT"
  run _expect_partition "${S}/c" "${S}/EXPECT"
  assert_success
  assert_output ""
}

@test "the s1 corpus is partitioned by golden/s1/EXPECT, one row per fixture" {
  run _expect_partition "${TESTDATA}/corpus/s1" "${TESTDATA}/golden/s1/EXPECT"
  assert_success
  assert_output ""
}

# ── per class: bridge and binary each against the golden ────────────────────

# why: the golden is the bridge's own `--tables` answer captured once; this
# re-runs BOTH sides over every s1 fixture and compares each one's bytes to
# that file with cmp, never through $(...), which would drop trailing LFs
# and hide a missing or extra final newline. The binary is the built
# config-gen that script/test/test.sh provisions as CONFIG_GEN_BIN; an
# unprovisioned binary fails the spec (ci_config_gen_unprovisioned), it is
# never skipped, so a run without it can not pass by testing nothing.
@test "per EXPECT class, the bridge and the config-gen binary each match golden/s1" {
  local _bridge="/source/dockerfile/toml_bridge.py"
  local _row _name _class _in _gold _rc _bad=0
  if [[ -z "${CONFIG_GEN_BIN:-}" || ! -x "${CONFIG_GEN_BIN}" ]]; then
    fail "ci_config_gen_unprovisioned: CONFIG_GEN_BIN='${CONFIG_GEN_BIN:-}' is not an executable config-gen binary; script/test/test.sh _prepare_config_gen_bin must provision it (base#1469)"
  fi
  while IFS= read -r _row || [[ -n "${_row}" ]]; do
    _name="${_row%%$'\t'*}"
    _class="${_row#*$'\t'}"
    _in="${TESTDATA}/corpus/s1/${_name}.toml"
    _gold="${TESTDATA}/golden/s1/${_name}.golden"

    _rc=0
    python3 "${_bridge}" --tables < "${_in}" > "${S}/bridge.out" 2> "${S}/bridge.err" || _rc=$?
    case "${_class}" in
      parity | parity-refused)
        if [[ "${_class}" == parity ]]; then
          if (( _rc != 0 )) || ! cmp -s "${_gold}" "${S}/bridge.out"; then
            printf '%s: bridge rc=%d or stdout differs from golden\n' "${_name}" "${_rc}"
            _bad=1
          fi
        elif (( _rc != 1 )); then
          printf '%s: bridge rc=%d, want 1\n' "${_name}" "${_rc}"
          _bad=1
        fi
        ;;
      bridge-refused-go-accepted)
        if (( _rc != 1 )); then
          printf '%s: bridge rc=%d, want 1\n' "${_name}" "${_rc}"
          _bad=1
        fi
        ;;
    esac

    _rc=0
    "${CONFIG_GEN_BIN}" tables --name "${_name}" "${_in}" > "${S}/bin.out" 2> "${S}/bin.err" || _rc=$?
    if [[ "${_class}" == parity-refused ]]; then
      if (( _rc != 1 )) || [[ -s "${S}/bin.out" ]]; then
        printf '%s: config-gen rc=%d (want 1) or stdout not empty\n' "${_name}" "${_rc}"
        _bad=1
      fi
    elif (( _rc != 0 )) || [[ -s "${S}/bin.err" ]] || ! cmp -s "${_gold}" "${S}/bin.out"; then
      printf '%s: config-gen rc=%d, stderr bytes=%d, or stdout differs from golden\n' \
        "${_name}" "${_rc}" "$(wc -c < "${S}/bin.err")"
      _bad=1
    fi
  done < "${TESTDATA}/golden/s1/EXPECT"
  (( _bad == 0 ))
}
