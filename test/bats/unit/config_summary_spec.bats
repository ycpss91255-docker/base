#!/usr/bin/env bats
#
# why: Mirrors `lib/config_summary.sh`. `_print_config_summary` is the one
# screen a user reads before a build or a run, and it must not render a
# setup.toml that could not be parsed as one that says nothing: it used to
# hand the bridge's empty stdout to the dump without looking at the
# bridge's status, print an empty setup.toml section and answer zero
# (base#1398).

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  LIB="/source/dist/script/docker/lib/_lib.sh"
}

# _summary_probe <file_path>
#
# Runs `_print_config_summary build` against <file_path>/setup.toml in a
# fresh shell under LOG_FORMAT=json and prints its status last.
_summary_probe() {
  run env LOG_FORMAT=json bash -c "
    source ${LIB}
    FILE_PATH='${1}'
    _print_config_summary build
    printf 'rc=%s\n' \"\$?\""
}

# why: The summary is the screen a user reads before a build; an empty
# setup.toml section over a file that failed to parse tells them their
# configuration is the template defaults when nothing was read (base#1398).
@test "_print_config_summary refuses a setup.toml that cannot be parsed (base#1398)" {
  local _fp="${BATS_TEST_TMPDIR}"

  # A valid file: rc 0, and its entry is printed.
  printf '[gui]\nmode = "off"\n' > "${_fp}/setup.toml"
  _summary_probe "${_fp}"
  assert_success
  assert_output --partial "rc=0"
  assert_output --partial "mode = off"

  # An absent file: rc 0.
  rm -f "${_fp}/setup.toml"
  _summary_probe "${_fp}"
  assert_success
  assert_output --partial "rc=0"

  # A malformed file: rc 1, and the parse failure named by its event.
  # toml-fixture-lint: allow the parser's refusal of this layer IS the assertion
  printf '[gui]\nmode = "off\n' > "${_fp}/setup.toml"
  _summary_probe "${_fp}"
  assert_success
  assert_output --partial "rc=1"
  assert_output --partial '"body":"conf_toml_parse_failed"'
  refute_output --partial "unregistered log body"
}
