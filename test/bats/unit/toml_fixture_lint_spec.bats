#!/usr/bin/env bats
#
# why: The gate that keeps a file named `.toml` from holding INI. A body
# the bridge refuses leaves an EMPTY config handle, so every value falls
# back to its schema default -- and a test asserting that default goes
# green without its fixture ever being read. 152 such bodies were
# measured across 17 spec files and nothing in the tree could tell the
# difference, which is why the rule is a gate and not a convention.
#
# Unit tests for script/test/drivers/toml_fixture.sh and the engine it
# names, script/test/toml_fixture_lint.sh.
#
# Every case drives a SCRATCH scan root holding synthetic spec files. The
# synthetic specs are built line by line with printf, never with a
# heredoc, for the same reason this file carries no `cat > x.toml`
# heredoc of its own: this spec is itself scanned by the gate, and a
# fixture written here as a literal would make the shipped tree fail its
# own lint. Building the lines at run time keeps the refused shapes out
# of the scanned text while still handing the extractor exactly them.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver sources the engine, so both surfaces are live.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/toml_fixture.sh

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/test/bats/unit"
  REPO_ROOT="${SCRATCH}"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _spec <name> <line>... -- write one synthetic spec under the scan root.
_spec() {
  local _name="${1}"; shift
  printf '%s\n' "$@" > "${SCRATCH}/test/bats/unit/${_name}"
}

# _toml <basename> -- the scratch path a synthetic fixture writes to,
# assembled so the suffix never sits next to a redirect in this file.
_toml() {
  printf '"${D}/%s.%s"' "${1}" "toml"
}

# ════════════════════════════════════════════════════════════════════
# Heredoc fixtures, literal delimiter
# ════════════════════════════════════════════════════════════════════

# why: The defect itself -- an INI body under a TOML name
@test "_toml_fixture_lint: refuses an INI body written to a .toml path" {
  _spec a_spec.bats \
    '@test "x" {' \
    "  cat > $(_toml setup) <<'EOF'" \
    '[network]' \
    'mode = bridge' \
    'EOF' \
    '}'
  run _toml_fixture_lint "${SCRATCH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"a_spec.bats:2"* ]]
}

# why: The control group -- a correct fixture must not be reported
@test "_toml_fixture_lint: passes a TOML body written to a .toml path" {
  _spec a_spec.bats \
    '@test "x" {' \
    "  cat > $(_toml setup) <<'EOF'" \
    '[network]' \
    'mode = "bridge"' \
    'EOF' \
    '}'
  run _toml_fixture_lint "${SCRATCH}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"1 fixture bodies"* ]]
}

# why: An append fragment has to stand alone, because it is appended to a file
# that already parses
@test "_toml_fixture_lint: checks an appended body on its own" {
  _spec a_spec.bats \
    '@test "x" {' \
    "  cat >> $(_toml setup) <<'EOF'" \
    'mount_1 = /a:/b' \
    'EOF' \
    '}'
  run _toml_fixture_lint "${SCRATCH}"
  [ "${status}" -ne 0 ]
}

# why: `<<-` indents the body with tabs the shell strips, and so must the gate
@test "_toml_fixture_lint: strips the leading tabs of a <<- body" {
  printf '%s\n' \
    '@test "x" {' \
    "  cat > $(_toml setup) <<-'EOF'" \
    "$(printf '\t[network]')" \
    "$(printf '\tmode = "bridge"')" \
    "$(printf '\tEOF')" \
    '}' > "${SCRATCH}/test/bats/unit/a_spec.bats"
  run _toml_fixture_lint "${SCRATCH}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"1 fixture bodies"* ]]
}

# ════════════════════════════════════════════════════════════════════
# Heredoc fixtures, expanding delimiter
# ════════════════════════════════════════════════════════════════════

# why: An unquoted heredoc expands at test time, so a quoted reference is a
# string and must not be reported
@test "_toml_fixture_lint: a quoted variable reference parses" {
  _spec a_spec.bats \
    '@test "x" {' \
    "  cat > $(_toml setup) <<EOF" \
    '[project]' \
    'name = "${_name}"' \
    'EOF' \
    '}'
  run _toml_fixture_lint "${SCRATCH}"
  [ "${status}" -eq 0 ]
}

# why: A BARE reference is refused for the same reason the real file would be
@test "_toml_fixture_lint: an unquoted variable reference is refused" {
  _spec a_spec.bats \
    '@test "x" {' \
    "  cat > $(_toml setup) <<EOF" \
    '[project]' \
    'name = ${_name}' \
    'EOF' \
    '}'
  run _toml_fixture_lint "${SCRATCH}"
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# printf / echo fixtures
# ════════════════════════════════════════════════════════════════════

# why: The second form the tree uses; 26 of the measured bodies were written
# this way
@test "_toml_fixture_lint: refuses an INI body written with printf" {
  _spec a_spec.bats \
    '@test "x" {' \
    "  printf '%s\\n' '[gui]' 'mode = auto' > $(_toml setup)" \
    '}'
  run _toml_fixture_lint "${SCRATCH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"a_spec.bats:2"* ]]
}

# why: The printf control group -- the format string is honoured, not guessed at
@test "_toml_fixture_lint: passes a TOML body written with printf" {
  _spec a_spec.bats \
    '@test "x" {' \
    "  printf '%s\\n' '[gui]' 'mode = \"auto\"' > $(_toml setup)" \
    '}'
  run _toml_fixture_lint "${SCRATCH}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"1 fixture bodies"* ]]
}

# why: A gate that runs what it reads takes instructions from the text it is
# auditing; it must refuse instead
@test "_toml_fixture_lint: refuses a printf body it would have to run a command for" {
  _spec a_spec.bats \
    '@test "x" {' \
    "  printf '%s\\n' \"\$(cat /etc/hostname)\" > $(_toml setup)" \
    '}'
  run _toml_fixture_lint "${SCRATCH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"statically"* ]]
}

# ════════════════════════════════════════════════════════════════════
# Variable and helper targets
# ════════════════════════════════════════════════════════════════════

# why: The form that holds two of the eleven tests this issue was measured by
@test "_toml_fixture_lint: reads a heredoc redirected through a .toml variable" {
  _spec a_spec.bats \
    '@test "x" {' \
    "  local _repo=\"\${D}/setup.$(printf toml)\"" \
    "  cat > \"\${_repo}\" <<'EOF'" \
    '[network]' \
    'mode = bridge' \
    'EOF' \
    '}'
  run _toml_fixture_lint "${SCRATCH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"a_spec.bats:3"* ]]
}

# why: One spec spells the same name as a .toml literal in one test and
# $(mktemp) in another; a file-wide verdict would read the second test's
# unrelated heredoc as a fixture
@test "_toml_fixture_lint: a name reassigned in its own block is not a .toml target" {
  _spec a_spec.bats \
    '@test "other" {' \
    "  local f=\"\${D}/a.$(printf toml)\"" \
    '}' \
    '@test "x" {' \
    '  f="$(mktemp)"' \
    '  cat > "${f}" <<EOF' \
    'not toml at all' \
    'EOF' \
    '}'
  run _toml_fixture_lint "${SCRATCH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"refusing to pass a gate over nothing"* ]]
}

# why: A heredoc fed to a spec-local writer helper is as much a fixture as a
# direct redirect
@test "_toml_fixture_lint: reads a heredoc fed to a spec-local .toml writer" {
  _spec a_spec.bats \
    '_stage_conf() {' \
    "  cat > $(_toml setup)" \
    '}' \
    '@test "x" {' \
    "  _stage_conf <<'EOF'" \
    '[network]' \
    'mode = bridge' \
    'EOF' \
    '}'
  run _toml_fixture_lint "${SCRATCH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"a_spec.bats:5"* ]]
}

# ════════════════════════════════════════════════════════════════════
# Heredoc bodies are text, not code
# ════════════════════════════════════════════════════════════════════

# why: A spec that writes a SCRIPT which writes a setup.toml must not have the
# inner line read as a fixture of the spec -- it writes nothing at scan time
@test "_toml_fixture_lint: a .toml write inside another heredoc is not a fixture" {
  _spec a_spec.bats \
    '@test "x" {' \
    "  cat > \"\${D}/gen.sh\" <<'SH'" \
    "cat > \"\${HOME}/setup.$(printf toml)\" <<'EOF'" \
    '[network]' \
    'mode = bridge' \
    'EOF' \
    'SH' \
    '}'
  run _toml_fixture_lint "${SCRATCH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"refusing to pass a gate over nothing"* ]]
}

# ════════════════════════════════════════════════════════════════════
# The deliberate-exemption marker
# ════════════════════════════════════════════════════════════════════

# why: A spec whose SUBJECT is the refusal of a malformed file needs a
# malformed file, and needs to say so
@test "_toml_fixture_lint: an allow marker with a reason exempts the body" {
  _spec a_spec.bats \
    '@test "x" {' \
    '  # toml-fixture-lint: allow the refusal is the assertion' \
    "  cat > $(_toml setup) <<'EOF'" \
    'invalid = [toml' \
    'EOF' \
    '}'
  run _toml_fixture_lint "${SCRATCH}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"1 deliberately exempt"* ]]
}

# why: An opt-out nobody has to justify is the shape every such hole starts as
@test "_toml_fixture_lint: an allow marker with no reason is itself a failure" {
  _spec a_spec.bats \
    '@test "x" {' \
    '  # toml-fixture-lint: allow' \
    "  cat > $(_toml setup) <<'EOF'" \
    '[network]' \
    'mode = "bridge"' \
    'EOF' \
    '}'
  run _toml_fixture_lint "${SCRATCH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"carries no reason"* ]]
}

# why: A marker must reach the fixture below it and no further, or one
# exemption would silently cover the next body too
@test "_toml_fixture_lint: an allow marker does not leak to the next fixture" {
  _spec a_spec.bats \
    '@test "x" {' \
    '  # toml-fixture-lint: allow the refusal is the assertion' \
    "  cat > $(_toml one) <<'EOF'" \
    'invalid = [toml' \
    'EOF' \
    "  cat > $(_toml two) <<'EOF'" \
    '[network]' \
    'mode = bridge' \
    'EOF' \
    '}'
  run _toml_fixture_lint "${SCRATCH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"a_spec.bats:6"* ]]
}

# ════════════════════════════════════════════════════════════════════
# Unusable scan roots
# ════════════════════════════════════════════════════════════════════

# why: A gate over nothing is green for the wrong reason -- the exact failure
# mode this gate exists to name
@test "_toml_fixture_lint: refuses a spec tree holding no fixture at all" {
  _spec a_spec.bats \
    '@test "x" {' \
    '  true' \
    '}'
  run _toml_fixture_lint "${SCRATCH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"refusing to pass a gate over nothing"* ]]
}

# why: A missing spec tree is a rename nobody noticed, not a clean tree
@test "_toml_fixture_lint: refuses a root with no test/bats" {
  rm -rf "${SCRATCH}/test"
  run _toml_fixture_lint "${SCRATCH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"nothing to gate"* ]]
}

# why: A path that is not a directory is a caller bug, and a silent pass would
# hide it
@test "_toml_fixture_lint: refuses a scan root that is not a directory" {
  run _toml_fixture_lint "${SCRATCH}/test/bats/unit/absent"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"is not a directory"* ]]
}

# ════════════════════════════════════════════════════════════════════
# The driver
# ════════════════════════════════════════════════════════════════════

# why: The dispatcher entry point has to fail the branch, not just print, and
# has to say what to do about it
@test "_run_toml_fixture: fails and names the remedy on a bad fixture" {
  _spec a_spec.bats \
    '@test "x" {' \
    "  cat > $(_toml setup) <<'EOF'" \
    '[network]' \
    'mode = bridge' \
    'EOF' \
    '}'
  run _run_toml_fixture
  [ "${status}" -ne 0 ]
  # The event id itself is asserted separately (the text log format
  # prints the display line, not the id); what this case pins is that the
  # driver turns the engine's report into a failure carrying the remedy.
  [[ "${output}" == *"a_spec.bats:2"* ]]
  [[ "${output}" == *"re-derive the assertion"* ]]
}

# why: And has to stay quiet on a clean tree, or the gate is noise
@test "_run_toml_fixture: reports clean when every body parses" {
  _spec a_spec.bats \
    '@test "x" {' \
    "  cat > $(_toml setup) <<'EOF'" \
    '[network]' \
    'mode = "bridge"' \
    'EOF' \
    '}'
  run _run_toml_fixture
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# ════════════════════════════════════════════════════════════════════
# Run as its own command
# ════════════════════════════════════════════════════════════════════

# why: The engine is runnable on its own, and standalone it arms
# `set -euo pipefail` -- which a sourced case never sees. A clean tree
# counts zero failures, `grep -c` exits 1 on a count of zero, and the run
# ended with status 1 and not one line of output. Only an exec case can
# catch that, so there is one.
@test "toml_fixture_lint.sh: exits 0 and reports on a clean tree, run as a command" {
  local _engine="/source/script/test/toml_fixture_lint.sh"
  assert_spec_subject "${_engine}" "the engine this driver names"
  _spec a_spec.bats \
    '@test "x" {' \
    "  cat > $(_toml setup) <<'EOF'" \
    '[network]' \
    'mode = "bridge"' \
    'EOF' \
    '}'
  run bash "${_engine}" "${SCRATCH}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"all parse as TOML"* ]]
}

# why: And exits 1 WITH the offending body named, rather than dying mute
@test "toml_fixture_lint.sh: exits 1 and names the body, run as a command" {
  _spec a_spec.bats \
    '@test "x" {' \
    "  cat > $(_toml setup) <<'EOF'" \
    '[network]' \
    'mode = bridge' \
    'EOF' \
    '}'
  run bash /source/script/test/toml_fixture_lint.sh "${SCRATCH}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"a_spec.bats:2"* ]]
}

# ════════════════════════════════════════════════════════════════════
# Wiring
# ════════════════════════════════════════════════════════════════════

# why: A lint nobody runs is a comment
@test "toml-fixture: is a member of the lint phase's tool table" {
  # _LINT_TOOLS is the one table every lint-phase caller dispatches
  # through, and it is also what the self-test.yaml completeness guard
  # reads -- so membership here is what makes the CI join mandatory.
  #
  # PARSED, never sourced: sourcing test.sh drags in the whole lib chain,
  # which reads BASH_SOURCE unguarded, and under the kcov-instrumented
  # bash of the coverage shard that aborts.
  local _test_sh="/source/script/test/test.sh"
  assert_spec_subject "${_test_sh}" "the test runner whose _LINT_TOOLS table this lint joins"
  run awk '
    /^readonly _LINT_TOOLS=\(/ { inside = 1; next }
    inside && /^\)/            { inside = 0 }
    inside {
      sub(/#.*/, "")
      gsub(/[[:space:]]+/, "")
      if ($0 != "") print
    }
  ' "${_test_sh}"
  assert_success
  assert_line "toml-fixture"
}

# why: One plain-runner lint group, no docker -- and exactly one, because none
# gates nothing and two pays twice
@test "toml-fixture: has a lint-static CI join" {
  local _wf="/source/.github/workflows/self-test.yaml"
  assert_spec_subject "${_wf}" "the workflow whose lint-static groups this lint joins"
  local _hits
  _hits="$(lint_group_hits toml-fixture "${_wf}")"
  [ "${_hits}" -eq 1 ] \
    || fail "the toml-fixture lint is in ${_hits} lint-static groups; in none, the next INI body under a TOML name reaches main with nothing watching it"
}

# why: An unregistered event id is an anonymous exit: the log line carries no
# name a reader can look up
@test "toml-fixture: its failure event id is registered" {
  run grep -qx 'ci_toml_fixture' /source/dist/script/docker/lib/log-events.txt
  assert_success
}
