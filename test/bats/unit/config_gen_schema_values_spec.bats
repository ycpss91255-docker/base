#!/usr/bin/env bats
#
# config_gen_schema_values_spec.bats -- the shell half of "Validation
# matches schema.sh" (base#1442).
#
# why: The Go generator's schema.Validate and the shell's _schema_validate
# must accept and refuse the same values. Both read one shared table,
# dockerfile/config-gen/testdata/corpus/s6/s6_scalar_values.tsv; the Go
# half asserts what Validate answers, and this half asserts that every
# verdict in the table is what the shell answers on the bridge's text, so
# the table is the shell's word and not the Go package's.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  TEMP_DIR="$(mktemp -d)"
  LIB=/source/dist/script/docker/lib
  TABLE=/source/dockerfile/config-gen/testdata/corpus/s6/s6_scalar_values.tsv
  TEXTS=/source/dockerfile/config-gen/testdata/corpus/s6/s6_scalar_texts.tsv
  LAYERS=/source/dockerfile/config-gen/testdata/corpus/s6/s6_layers.tsv
  export LC_ALL=C
  # shellcheck disable=SC1091
  source "${LIB}/schema.sh"
  # shellcheck disable=SC1091
  source "${LIB}/toml_bridge.sh"
  # shellcheck disable=SC1091
  source "${LIB}/setup_cmd.sh"
}

# _layer_verdict <file> -- print accept or refuse: the verdict the bridge
# and apply's per-layer checks give one layer. The bridge's --kv refusing
# it (a parse failure, a transport refusal) is refuse; so is a --tables
# table or a --kv row's section that _setup_known_section does not know, a
# key _setup_known_key does not know, or a value _schema_validate refuses.
# A [stage:*] table is skipped as _setup_conf_check_known skips it.
_layer_verdict() {
  local _file="${1}" _kv _tables _sect _key _val
  _kv="$(toml_bridge_parse "${_file}" --kv 2>/dev/null)" || { echo refuse; return 0; }
  _tables="$(toml_bridge_parse "${_file}" --tables 2>/dev/null)" || { echo refuse; return 0; }
  while IFS= read -r _sect; do
    [[ -z "${_sect}" || "${_sect}" == stage:* ]] && continue
    _setup_known_section "${_sect}" || { echo refuse; return 0; }
  done <<< "${_tables}"
  while IFS=$'\t' read -r _sect _key _val; do
    [[ -z "${_sect}${_key}" || "${_sect}" == stage:* ]] && continue
    _setup_known_section "${_sect}" || { echo refuse; return 0; }
    _setup_known_key "${_sect}" "${_key}" || { echo refuse; return 0; }
    _schema_validate "${_sect}" "${_key}" "${_val}" || { echo refuse; return 0; }
  done <<< "${_kv}"
  echo accept
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# _quoted_header <section> -- print the TOML header for a section text:
# each dot-separated part as a quoted key, so `stage:dev.logging` (the
# bridge's dotted name for `["stage:dev".logging]`) is
# `["stage:dev"."logging"]`. The Go half (rowText) writes the same header.
_quoted_header() {
  local -a _parts
  local _out
  IFS=. read -ra _parts <<< "${1}"
  printf -v _out '"%s".' "${_parts[@]}"
  printf '[%s]\n' "${_out%.}"
}

# why: Each class=value row's literal goes through the bridge's --kv, the
# text the shell reads, and _schema_validate on that text must give the
# row's verdict: rc 0 for accept, non-zero for refuse. The Go half holds
# schema.Validate on the same text to the same verdict, with no exception
# column: a value outside its field's type is s6_kinds.tsv's. The section
# column is the shell's section text, the bridge's dotted name for the
# table, so a stage or a per-service section (`stage:dev.logging`,
# `logging.web`) is the name _schema_validate is asked about; the bridge
# must name the written table exactly so (base#1442 review round 2).
@test "s6_scalar_values: every class=value verdict is _schema_validate's on the bridge text" {
  local _class _section _key _lit _verdict _event _branch _kv _text _rc
  local _rows=0 _bad=()
  while IFS=$'\t' read -r _class _section _key _lit _verdict _event _branch; do
    [[ "${_class}" == \#* ]] && continue
    [[ "${_class}" == value ]] || { _bad+=("class ${_class}"); continue; }
    # toml-fixture-lint: allow the body is built from a table row; the bridge parses each row and a refusal is reported
    { _quoted_header "${_section}"; printf '%s = %s\n' "${_key}" "${_lit}"; } > "${TEMP_DIR}/in.toml"
    _kv="$(toml_bridge_parse "${TEMP_DIR}/in.toml" --kv)" \
      || { _bad+=("${_section}.${_key}=${_lit}: bridge failed"); continue; }
    [[ "${_kv%%$'\t'*}" == "${_section}" ]] \
      || _bad+=("${_section}.${_key}=${_lit}: bridge section '${_kv%%$'\t'*}'")
    _text="${_kv#*$'\t'*$'\t'}"
    _rc=0
    _schema_validate "${_section}" "${_key}" "${_text}" || _rc=$?
    if [[ "${_verdict}" == accept && "${_rc}" -ne 0 ]] \
      || [[ "${_verdict}" == refuse && "${_rc}" -eq 0 ]]; then
      _bad+=("${_section}.${_key}=${_lit} (${_branch}): shell rc=${_rc}, table ${_verdict}")
    fi
    case "${_verdict}" in
      accept|refuse) ;;
      *) _bad+=("${_section}.${_key}=${_lit}: verdict ${_verdict}") ;;
    esac
    _rows=$((_rows + 1))
  done < "${TABLE}"
  printf '%s\n' "${_bad[@]}"
  [ "${#_bad[@]}" -eq 0 ]
  [ "${_rows}" -gt 0 ]
}

# why: Go's Scalar text for each TOML scalar kind (a local time, a local
# datetime, a fractional datetime among them) must be the text the shell
# reads from the bridge's --kv for the same literal; each row of the shared
# s6_scalar_texts.tsv names that text and the Go half asserts the same.
@test "s6_scalar_texts: every bridge-text column is the bridge's --kv text" {
  local _section _key _lit _kind _want _kv _text
  local _rows=0 _bad=()
  while IFS=$'\t' read -r _section _key _lit _kind _want; do
    [[ "${_section}" == \#* ]] && continue
    # toml-fixture-lint: allow the body is built from a table row; the bridge parses each row and a refusal is reported
    printf '[%s]\n%s = %s\n' "${_section}" "${_key}" "${_lit}" > "${TEMP_DIR}/in.toml"
    _kv="$(toml_bridge_parse "${TEMP_DIR}/in.toml" --kv)" \
      || { _bad+=("${_section}.${_key}=${_lit}: bridge failed"); continue; }
    _text="${_kv#*$'\t'*$'\t'}"
    [[ "${_text}" == "${_want}" ]] \
      || _bad+=("${_section}.${_key}=${_lit} (${_kind}): bridge text '${_text}', table '${_want}'")
    _rows=$((_rows + 1))
  done < "${TEXTS}"
  printf '%s\n' "${_bad[@]}"
  [ "${#_bad[@]}" -eq 0 ]
  [ "${_rows}" -gt 0 ]
}

# why: Go's schema.Decode must give the shell's verdict on a whole layer,
# not only on one value (base#1442 review round 2). Each row of the shared
# s6_layers.tsv is a layer written with printf %b escapes; the shell's
# verdict on it (_layer_verdict) must be the row's: accept for accept,
# refuse for refuse, and accept for a differs:<exception> row, which the
# generator refuses on purpose under ADR-00000039 (wrong type, U+0000)
# while the shell passes it. The Go half asserts Decode's verdict, event
# and line on the same rows.
@test "s6_layers: every layer verdict is the bridge's and apply's checks'" {
  local _class _layer _verdict _event _line _branch _got
  local _rows=0 _bad=()
  while IFS=$'\t' read -r _class _layer _verdict _event _line _branch; do
    [[ "${_class}" == \#* ]] && continue
    # toml-fixture-lint: allow the body is built from a table row; the bridge parses each row and a refusal is reported
    printf '%b' "${_layer}" > "${TEMP_DIR}/in.toml"
    _got="$(_layer_verdict "${TEMP_DIR}/in.toml")"
    case "${_verdict}" in
      accept|differs:*) [[ "${_got}" == accept ]] || _bad+=("${_branch}: shell ${_got}, table ${_verdict}") ;;
      refuse) [[ "${_got}" == refuse ]] || _bad+=("${_branch}: shell ${_got}, table ${_verdict}") ;;
      *) _bad+=("${_branch}: verdict ${_verdict}") ;;
    esac
    _rows=$((_rows + 1))
  done < "${LAYERS}"
  printf '%s\n' "${_bad[@]}"
  [ "${#_bad[@]}" -eq 0 ]
  [ "${_rows}" -gt 0 ]
}

# why: The Go half holds the sections Decode knows equal to the table's
# section:<name> rows; this half holds those rows equal to SCHEMA_SECTIONS,
# so a section added to schema.sh fails one of the two until both know it.
@test "s6_layers: the section:<name> rows are exactly SCHEMA_SECTIONS" {
  local _class _layer _verdict _event _line _branch
  local -a _rows=()
  while IFS=$'\t' read -r _class _layer _verdict _event _line _branch; do
    [[ "${_class}" == \#* ]] && continue
    [[ "${_branch}" == section:* && "${_branch}" != section:stage ]] || continue
    _rows+=("${_branch#section:}")
  done < "${LAYERS}"
  run diff <(printf '%s\n' "${_rows[@]}" | sort) <(printf '%s\n' "${SCHEMA_SECTIONS[@]}" | sort)
  [ "${status}" -eq 0 ]
}

# _check_known_events <file> -- print one "<event> <key>" line per
# refusal the real _setup_conf_check_known logs for <file> as a layer:
# apply_unknown_table as conf_unknown_table <table>, apply_unknown_key as
# conf_unknown_key <table>.<key>, sorted.
_check_known_events() {
  local _file="${1}" _base _line _body _table _key
  _base="$(mktemp -d "${TEMP_DIR}/base.XXXXXX")"
  cp "${_file}" "${_base}/setup.toml"
  while IFS= read -r _line; do
    [[ "${_line}" =~ \"body\":\"(apply_unknown_[a-z]+)\" ]] || continue
    _body="${BASH_REMATCH[1]}"
    [[ "${_line}" =~ \"table\":\"([^\"]*)\" ]] && _table="${BASH_REMATCH[1]}"
    case "${_body}" in
      apply_unknown_table) printf 'conf_unknown_table %s\n' "${_table}" ;;
      apply_unknown_key)
        [[ "${_line}" =~ \"key\":\"([^\"]*)\" ]] && _key="${BASH_REMATCH[1]}"
        printf 'conf_unknown_key %s.%s\n' "${_table}" "${_key}" ;;
    esac
  done < <(LOG_FORMAT=json bash -c 'source "$1/_lib.sh" && _setup_conf_check_known "$2"' _ "${LIB}" "${_base}" 2>&1) | sort
}

# why: The Go half (TestCheckSectionsCorpus) holds config-gen check on
# every corpus/s6/sections/ file equal to s6_sections.tsv. This half holds
# the table's source=shell rows equal to what the real
# _setup_conf_check_known reports for the same file, so the section-text
# classification ([logging.""], stage tables, empty arrays judged by
# their first entry's row) is the shell's, not the Go package's
# (base#1442 review round 3 finding 1).
@test "s6_sections: every source=shell row is what _setup_conf_check_known reports" {
  local _dir=/source/dockerfile/config-gen/testdata/corpus/s6/sections
  local _table=/source/dockerfile/config-gen/testdata/corpus/s6/s6_sections.tsv
  local _f _base _want _got _files=0 _bad=()
  for _f in "${_dir}"/*.toml; do
    _base="${_f##*/}"
    _want="$(awk -F'\t' -v f="${_base}" '$1 == f && $5 == "shell" && $2 != "-" { print $2 " " $4 }' "${_table}" | sort)"
    grep -q "^${_base}"$'\t' "${_table}" || _bad+=("${_base}: no row in s6_sections.tsv")
    _got="$(_check_known_events "${_f}")"
    [[ "${_got}" == "${_want}" ]] || _bad+=("${_base}: shell '${_got//$'\n'/; }', table '${_want//$'\n'/; }'")
    _files=$((_files + 1))
  done
  printf '%s\n' "${_bad[@]}"
  [ "${#_bad[@]}" -eq 0 ]
  [ "${_files}" -gt 0 ]
}

# _probe_kind <canonical key> -- print int, bool or string: how
# _schema_validate types the key on the pinned probe texts. A key is bool
# when it accepts exactly true and false, int when it accepts at least
# one probe and only decimal integers, string otherwise. The probe set
# holds a word, a size, a list and the GPU words (all, auto, 3,4) so a
# string key that also takes integers is not read as int (base#1442).
_probe_kind() {
  local _canon="${1}" _section _key _p _acc=()
  local -a _probes=(3 0 x 1g true false 3a 1.5 all video utility 3,4 auto)
  _section="${_canon%%.*}"
  _key="${_canon#*.}"
  [[ "${_key}" == *_ ]] && _key="${_key}1"
  for _p in "${_probes[@]}"; do
    _schema_validate "${_section}" "${_key}" "${_p}" && _acc+=("${_p}")
  done
  if [[ " ${_acc[*]} " == " true false " ]]; then
    echo bool
  elif [[ "${#_acc[@]}" -gt 0 && ! " ${_acc[*]} " =~ [^0-9\ ] ]]; then
    echo int
  else
    echo string
  fi
}

# why: The Go half (TestCheckKinds) refuses a value of another TOML kind
# at every key s6_kinds.tsv marks int or bool. This half holds that set
# equal to the keys schema.sh itself types, read off _schema_validate on a
# pinned probe set for every SCHEMA_VALIDATOR key, in both directions: a
# typed key added to schema.sh with no rows fails here, and so does a row
# marking a key the shell does not type. Each typed key must also carry
# every wrong-kind row for its kind (int: "3", 3.0, true, 1979-05-27;
# bool: "true", 1, 1.0) and an accept row (base#1442 review round 3).
@test "s6_kinds: the int and bool keys are the keys _schema_validate types, each with every wrong-kind row" {
  local _kinds=/source/dockerfile/config-gen/testdata/corpus/s6/s6_kinds.tsv
  local _canon _kind _lit _want _bad=() _probed="" _tabled=""
  for _canon in "${!SCHEMA_VALIDATOR[@]}"; do
    _kind="$(_probe_kind "${_canon}")"
    [[ "${_kind}" == string ]] && continue
    _probed+="${_canon} ${_kind}"$'\n'
    case "${_kind}" in
      int) _want=('"3"' '3.0' 'true' '1979-05-27') ;;
      bool) _want=('"true"' '1' '1.0') ;;
    esac
    for _lit in "${_want[@]}"; do
      awk -F'\t' -v c="${_canon}" -v l="${_lit}" -v k="${_kind}" \
        '$1 "." $2 == c && $3 == l && $4 == k && $5 == "conf_value_type_refused" { f = 1 } END { exit !f }' "${_kinds}" \
        || _bad+=("${_canon} (${_kind}): no conf_value_type_refused row for ${_lit}")
    done
    awk -F'\t' -v c="${_canon}" -v k="${_kind}" '$1 "." $2 == c && $4 == k && $5 == "-" { f = 1 } END { exit !f }' "${_kinds}" \
      || _bad+=("${_canon} (${_kind}): no accept row")
  done
  _tabled="$(awk -F'\t' '$1 !~ /^#/ && ($4 == "int" || $4 == "bool") { print $1 "." $2 " " $4 }' "${_kinds}" | sort -u)"
  _probed="$(printf '%s' "${_probed}" | sort -u)"
  [[ "${_probed}" == "${_tabled}" ]] \
    || _bad+=("typed keys differ: probe '${_probed//$'\n'/; }', table '${_tabled//$'\n'/; }'")
  printf '%s\n' "${_bad[@]}"
  [ "${#_bad[@]}" -eq 0 ]
  [ -n "${_probed}" ]
}
