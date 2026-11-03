#!/usr/bin/env bats
#
# config_gen_array_homes_spec.bats -- the shell half of the array homes
# the Go schema judges (base#1443).
#
# why: The Go generator's schema tests iterate schema.Homes() and take
# each home's expected bodies from one fixture table,
# dockerfile/config-gen/testdata/corpus/s7/s7_array_homes.tsv. This half
# holds that table to the shell's word, so it is not the Go package's:
# its `writer` rows are exactly what the shell writers name and spell,
# and every row's bodies get from the bridge the verdict the Go tests
# expect of schema.Decode -- an entry without its field and a string
# entry refused, a field-less and an all-empty entry kept as one empty
# row, the populated entry kept, and an unknown field beside it refused
# by name.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  ROOT=/source
  BRIDGE_PY="${ROOT}/dockerfile/toml_bridge.py"
  TABLE="${ROOT}/dockerfile/config-gen/testdata/corpus/s7/s7_array_homes.tsv"
  F="${BATS_TEST_TMPDIR}/home.toml"
  export LC_ALL=C
}

# _rows <kind> -- print the table's rows of <kind> (writer|legacy) as
# path TAB prefix TAB empty TAB full, `\n` decoded in the bodies only
# when read by the caller.
_rows() {
  awk -F '\t' -v k="${1}" '!/^#/ && $5 == k { print $1 "\t" $2 "\t" $3 "\t" $4 }' "${TABLE}"
}

# _kv <body> -- run the bridge's --kv on <body> (printf %b), leaving
# status, output and stderr.
_kv() {
  printf '%b' "${1}" > "${F}"
  run --separate-stderr python3 "${BRIDGE_PY}" --kv < "${F}"
}

# why: The Go half iterates schema.Homes() and takes each home's
# all-empty and populated bodies from the table's rows. This half holds
# the `writer` rows equal, in order, to what _conf_toml_aot_section over
# SCHEMA_SECTIONS names and _conf_toml_aot_fields spells for "" and for
# "a=b:c:d", so a home the writers gain, or a body they spell another
# way, fails here until the table knows it (base#1443).
@test "array homes: the writer rows are what the shell writers name and spell (base#1443)" {
  # shellcheck disable=SC1091
  source "${ROOT}/dist/script/docker/lib/conf.sh"
  # shellcheck disable=SC1091
  source "${ROOT}/dist/script/docker/lib/schema.sh"
  local _sect _pair _path _e _f _shell=''
  local -a _fams=()
  for _sect in "${SCHEMA_SECTIONS[@]}"; do
    _fams=()
    _conf_toml_aot_section "${_sect}" _fams || continue
    for _pair in "${_fams[@]}"; do
      _path="${_pair#*=}"
      _conf_toml_aot_fields "${_path}" "" _e
      _conf_toml_aot_fields "${_path}" "a=b:c:d" _f
      _shell+="${_path}"$'\t'"${_pair%%=*}"$'\t'"${_e//$'\n'/\\n}"$'\t'"${_f//$'\n'/\\n}"$'\n'
    done
  done
  [[ -n "${_shell}" ]] || fail "the shell writers named no array home"
  assert_equal "$(_rows writer)" "${_shell%$'\n'}"
}

# why: The Go half expects schema.Decode to refuse an entry without its
# field and a string entry, to keep a field-less and an all-empty entry as
# one empty entry, to keep the populated entry and to refuse an unknown
# field beside it. Each of those verdicts is the bridge's --kv verdict on
# the same body for every row, the legacy [[devices]] included, so the
# table the Go tests read is the shell's word (base#1443).
@test "array homes: every row's bodies get from the bridge the verdict the Go schema tests expect (base#1443)" {
  local _path _prefix _empty _full _kind _leaf _section _str _n=0
  while IFS=$'\t' read -r _path _prefix _empty _full _kind; do
    [[ "${_path}" == \#* ]] && continue
    _section="${_path%%.*}"
    _leaf="${_path##*.}"

    _kv "[[${_path}]]\nzz = \"x\"\n"
    assert_failure 1
    [[ "${stderr}" == *"entry 1 of ${_path} carries none of the fields it is read from"* ]] \
      || fail "${_path}: zz was not refused for lacking its field: ${stderr}"

    if [[ "${_path}" == *.* ]]; then _str="[${_section}]\n${_leaf} = [\"x\"]\n"; else _str="${_path} = [\"x\"]\n"; fi
    _kv "${_str}"
    assert_failure 1
    [[ "${stderr}" == *"entry 1 of ${_path} is 'x', not a table"* ]] \
      || fail "${_path}: the string entry was not refused as not a table: ${stderr}"

    _kv "[[${_path}]]\n"
    assert_success
    assert_equal "${output}" "${_section}"$'\t'"${_prefix}_1"$'\t'

    _kv "[[${_path}]]\n${_empty}\n"
    assert_success
    assert_equal "${output}" "${_section}"$'\t'"${_prefix}_1"$'\t'

    _kv "[[${_path}]]\n${_full}\n"
    assert_success
    assert_equal "${output}" "${_section}"$'\t'"${_prefix}_1"$'\t''a=b:c:d'

    _kv "[[${_path}]]\n${_full}\nzz = \"x\"\n"
    assert_failure 1
    [[ "${stderr}" == *"entry 1 of ${_path} carries zz, which its family does not read"* ]] \
      || fail "${_path}: zz beside the populated entry was not refused by name: ${stderr}"
    _n=$(( _n + 1 ))
  done < "${TABLE}"
  (( _n == $(grep -c -v '^#' "${TABLE}") )) || fail "read ${_n} rows of the table"
  (( _n > 0 )) || fail "the table names no array home"
}
