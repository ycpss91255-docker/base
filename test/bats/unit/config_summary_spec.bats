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
# fresh shell under LOG_FORMAT=json; its status is the run's status, and
# stdout and stderr are captured apart, so a refusal is judged by the
# five points of `assert_refusal` (base#1400).
_summary_probe() {
  run --separate-stderr env LOG_FORMAT=json bash -c "
    source ${LIB}
    FILE_PATH='${1}'
    _print_config_summary build"
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
  assert_output --partial "mode = off"

  # An absent file: rc 0.
  rm -f "${_fp}/setup.toml"
  _summary_probe "${_fp}"
  assert_success

  # A malformed file: rc 1, and the parse failure named by its event.
  # toml-fixture-lint: allow the parser's refusal of this layer IS the assertion
  printf '[gui]\nmode = "off\n' > "${_fp}/setup.toml"
  _summary_probe "${_fp}"
  assert_refusal 1 conf_toml_parse_failed "path=${_fp}/setup.toml"
}

# why: The empty-file hint is chosen by a header grep, and a malformed
# file the grep does not recognise (`[gui` unclosed, or a bare unterminated
# `mode = "off`) took that branch: it printed "no section overrides --
# using template defaults" with rc 0 and never parsed the file. The parse
# decides, not the grep (base#1398).
@test "_print_config_summary refuses a malformed setup.toml with no recognised header (base#1398)" {
  local _fp="${BATS_TEST_TMPDIR}" _bad

  # A comments-only file parses to nothing: the empty hint, rc 0.
  printf '# nothing set here\n' > "${_fp}/setup.toml"
  _summary_probe "${_fp}"
  assert_success
  assert_output --partial "no section overrides"
  refute_stderr_contains "conf_toml_parse_failed"

  # toml-fixture-lint: allow the parser's refusal of these layers IS the assertion
  for _bad in '[gui\nmode = "off"\n' 'mode = "off\n'; do
    # shellcheck disable=SC2059  # the fixture is the format string
    printf "${_bad}" > "${_fp}/setup.toml"
    _summary_probe "${_fp}"
    assert_refusal 1 conf_toml_parse_failed "path=${_fp}/setup.toml"
    refute_stderr_contains "no section overrides"
  done
}
