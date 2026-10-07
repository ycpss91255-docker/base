#!/usr/bin/env bats
#
# The toml-bridge the tooling image BUNDLES really parses TOML -- the
# behavioural half of the test-tools seam in
# test/bats/unit/toml_bridge_spec.bats.
#
# why: The suite runs INSIDE the test-tools image, so
# `/usr/local/bin/toml-bridge` on this filesystem is the copy every
# downstream repo inherits through the test-tools-stage pattern. What
# stood for that seam was a grep for the `COPY --from=` line in the
# Dockerfile, and a grep cannot tell a parser from a file: the final stage
# installed no interpreter, so the bundled bridge answered
# `env: 'python3': No such file or directory` on four published tags while
# the grep stayed green and the ADR went on saying the capability was
# there.
#
# So these cases RUN it and read what it printed. An exit status alone
# would not have separated the two states either: the shebang's failure
# and a parse are both "the process ended", and only the parsed output
# says which one happened. The last case drives the bridge to a
# non-zero exit on purpose, so a probe that could not fail cannot be
# mistaken for one that passed.
#
# DELIBERATELY FAIL-CLOSED, for the reason its pin sibling states
# (test/bats/integration/test_tools_pins_spec.bats): an image that cannot
# run the parser it ships is exactly the drift this exists to report, and
# a skip would restore the silence.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  DECL=/source/dockerfile/Dockerfile.test-tools
  assert_spec_subject "${DECL}" \
    "the tooling Dockerfile that declares this image bundles the parser"
  BUNDLED=/usr/local/bin/toml-bridge
}

# why: The JSON contract is what the shim's non-KV mode returns to its
# callers, and the expectation is a worked example rather than a second
# parse of the same input -- a bridge that echoed its stdin, or one whose
# interpreter was missing, answers neither.
@test "test-tools image: the bundled toml-bridge parses TOML from stdin to JSON (#1222)" {
  local _toml
  _toml="$(mktemp --suffix=.toml)"
  printf '[gui]\nmode = "wayland"\n' > "${_toml}"

  run --separate-stderr "${BUNDLED}" < "${_toml}"
  assert_success
  assert_output '{"gui": {"mode": "wayland"}}'

  rm -f "${_toml}"
}

# why: KV is the mode conf.sh actually loads a config through, and it is
# the one that carries a TYPE decision across the boundary: an unquoted
# TOML integer has to arrive as the bare digits bash compares, not as a
# quoted string or a Python repr.
@test "test-tools image: the bundled toml-bridge emits the KV lines conf.sh reads (#1222)" {
  local _toml
  _toml="$(mktemp --suffix=.toml)"
  printf '[deploy]\ngpu_runtime = "auto"\ngpu_count = 2\n' > "${_toml}"

  run --separate-stderr "${BUNDLED}" --kv < "${_toml}"
  assert_success
  assert_line "deploy	gpu_runtime	auto"
  assert_line "deploy	gpu_count	2"

  rm -f "${_toml}"
}

# why: The case that keeps the two above from being satisfied by anything
# that merely produces bytes. A real parser REFUSES malformed input and
# says so under its own name; an interpreter that never started fails too,
# which is why the message is read and not just the status.
@test "test-tools image: the bundled toml-bridge refuses malformed TOML under its own name (#1222)" {
  local _toml
  _toml="$(mktemp --suffix=.toml)"
  printf 'invalid = [toml\n' > "${_toml}"

  run --separate-stderr "${BUNDLED}" < "${_toml}"
  assert_failure
  [[ "${stderr}" == *'toml-bridge:'* ]] || fail \
    "malformed TOML was not refused by the bridge itself -- stderr was '${stderr}'. A failure that does not come from the parser is the interpreter never starting, which is the state this spec exists to report."

  rm -f "${_toml}"
}
