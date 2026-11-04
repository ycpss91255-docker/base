#!/usr/bin/env bats
#
# config_gen_s7_verdicts_spec.bats -- the bridge half of the verdict each
# corpus/s7 fixture states for itself (base#1443).
#
# why: Every corpus/s7 fixture carries its expected verdict on one
# `# expect:` comment line, so the readers discover fixtures by globbing
# and no index or manifest file lists them, as the base#1395 plan's
# corpus rule asks (base#1443 review round 4 finding 1). The Go half
# (TestCheckS7Corpus) holds `config-gen check` on each fixture to the
# line's verdict, event, position and key. This half holds the same line
# to the bridge's own output, so it is not the Go package's word: a refuse
# verdict's event and key are read off the bridge's refusal message, an
# accept or a differs:<exception> verdict is one the bridge's --kv
# accepts, and apply is what apply's per-layer checks (_layer_verdict)
# give the fixture. Line and column are counted from the fixture bytes,
# since the bridge reports no position.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  LIB=/source/dist/script/docker/lib
  BRIDGE_PY=/source/dockerfile/toml_bridge.py
  CORPUS=/source/dockerfile/config-gen/testdata/corpus/s7
  export LC_ALL=C
  # shellcheck disable=SC1091
  source "${LIB}/schema.sh"
  # shellcheck disable=SC1091
  source "${LIB}/toml_bridge.sh"
  # shellcheck disable=SC1091
  source "${LIB}/setup_cmd.sh"
  load "${BATS_TEST_DIRNAME}/config_gen_layer_helper"
}

# _bridge_event <message> -- print "<event> <key>" for the first line of
# a bridge --kv refusal, read by the phrase the bridge words each
# refusal with, or nothing when no phrase matches. The phrases are
# written here, apart from the Go side's events, so a verdict is held to
# what the bridge says. A message naming several fields names them
# sorted, and the key is the first of them (base#1443 review round 1
# finding 1).
_bridge_event() {
  local _m="${1%%$'\n'*}"
  _m="${_m#toml-bridge: }"
  local _entry='^entry ([0-9]+) of ([^ ]+) '
  if [[ "${_m}" =~ ${_entry}is\ .*,\ not\ a\ table ]]; then
    printf 'conf_entry_not_table %s[%s]\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}"
  elif [[ "${_m}" =~ ${_entry}carries\ none\ of\ the\ fields ]]; then
    printf 'conf_entry_no_gating_field %s[%s]\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}"
  elif [[ "${_m}" =~ ${_entry}carries\ ([^ ,]+)(,\ [^ ,]+)*,\ which\ its\ family\ does\ not\ read ]]; then
    printf 'conf_entry_unknown_field %s[%s].%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
  elif [[ "${_m}" =~ ${_entry}gives\ ([^ ,]+)(,\ [^ ,]+)*\ an\ array\ or\ a\ table ]]; then
    printf 'conf_value_type_refused %s[%s].%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
  elif [[ "${_m}" =~ ${_entry}carries\ ([^ ]+)\ without\ ([^ ,]+), ]]; then
    printf 'conf_entry_field_needs %s[%s].%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
  elif [[ "${_m}" =~ ^([^ ]+)\ is\ carried\ two\ ways ]]; then
    printf 'conf_family_two_spellings %s\n' "${BASH_REMATCH[1]}"
  elif [[ "${_m}" =~ ^([^ ]+)\ is\ an\ array,\ and\ no\ numbered\ family ]]; then
    printf 'conf_unknown_key %s\n' "${BASH_REMATCH[1]}"
  fi
}

# _expect <fixture> <outvar> -- read the fixture's one `# expect:` line
# into the associative array <outvar>, name to value. Returns 1, with
# the reason on stdout, when the fixture carries no such line or more
# than one, or a field that is not one name=value.
_expect() {
  local _file="${1}" _line _field _n
  local -n _ex_out="${2}"
  _ex_out=()
  _n="$(grep -c '^# expect: ' "${_file}")"
  [[ "${_n}" -eq 1 ]] || { echo "${_n} '# expect:' lines, want exactly one"; return 1; }
  _line="$(grep '^# expect: ' "${_file}")"
  for _field in ${_line#\# expect: }; do
    [[ "${_field}" =~ ^([a-z]+)=(.+)$ && -z "${_ex_out[${BASH_REMATCH[1]}]+x}" ]] \
      || { echo "field '${_field}' is not one name=value"; return 1; }
    _ex_out[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
  done
}

# why: Each fixture's verdict is the bridge's --kv status on it: 1 for
# refuse, 0 for accept and for a differs:<exception> verdict, which the
# generator refuses on purpose while the bridge reads it. A refuse
# verdict's event and key are the ones the bridge's refusal message
# names, and every fixture's apply is _layer_verdict's verdict on it, so
# a fixture the generator accepts and apply refuses is recorded as such.
# A fixture with no `# expect:` line fails here, as in the Go half
# (base#1443 review round 4 finding 1).
@test "s7 corpus: every fixture's own verdict, event and key are the bridge's, its apply _layer_verdict's" {
  local _f _base _rc _err _got _n=0
  local _why="${BATS_TEST_TMPDIR}/expect_why"
  local -A _ex=()
  local _bad=()
  for _f in "${CORPUS}"/*.toml; do
    _base="${_f##*/}"
    # Not in $(...): _expect fills _ex through a nameref, which a
    # subshell would drop, so its reason goes through a file instead.
    _expect "${_f}" _ex > "${_why}" || { _bad+=("${_base}: $(< "${_why}")"); continue; }
    _rc=0
    _err="$(python3 "${BRIDGE_PY}" --kv < "${_f}" 2>&1 >/dev/null)" || _rc=$?
    case "${_ex[verdict]-}" in
      refuse)
        [[ "${_rc}" -eq 1 ]] || _bad+=("${_base}: bridge rc=${_rc}, expect refuse")
        _got="$(_bridge_event "${_err}")"
        [[ "${_got}" == "${_ex[event]-} ${_ex[key]-}" ]] \
          || _bad+=("${_base}: bridge says '${_got}' (${_err%%$'\n'*}), expect '${_ex[event]-} ${_ex[key]-}'") ;;
      accept)
        [[ "${_rc}" -eq 0 ]] || _bad+=("${_base}: bridge rc=${_rc}, expect accept: ${_err%%$'\n'*}")
        [[ -z "${_ex[event]-}${_ex[line]-}${_ex[col]-}${_ex[key]-}" ]] || _bad+=("${_base}: an accept verdict names a refusal") ;;
      differs:?*)
        [[ "${_rc}" -eq 0 ]] || _bad+=("${_base}: bridge rc=${_rc}, expect ${_ex[verdict]}: ${_err%%$'\n'*}")
        [[ -n "${_ex[event]-}" && -n "${_ex[key]-}" ]] || _bad+=("${_base}: a differs verdict names no refusal") ;;
      *) _bad+=("${_base}: verdict '${_ex[verdict]-}'") ;;
    esac
    _got="$(_layer_verdict "${_f}")"
    [[ "${_got}" == "${_ex[apply]-}" ]] || _bad+=("${_base}: _layer_verdict ${_got}, expect apply '${_ex[apply]-}'")
    _n=$((_n + 1))
  done
  printf '%s\n' "${_bad[@]}"
  [ "${#_bad[@]}" -eq 0 ]
  [ "${_n}" -gt 0 ]
}

# why: The base#1395 plan's corpus rule: readers discover fixtures by
# globbing and no index or manifest file lists them, so adding a fixture
# touches no shared file. No other file of corpus/s7 names a corpus/s7
# fixture (base#1443 review round 4 finding 1).
@test "s7 corpus: no file of corpus/s7 but a fixture names a fixture" {
  local _other _f
  local _bad=()
  for _other in "${CORPUS}"/*; do
    [[ "${_other}" == *.toml ]] && continue
    for _f in "${CORPUS}"/*.toml; do
      grep -qF -- "${_f##*/}" "${_other}" && _bad+=("${_other##*/} names ${_f##*/}")
    done
  done
  printf '%s\n' "${_bad[@]}"
  [ "${#_bad[@]}" -eq 0 ]
}
