#!/usr/bin/env bats
#
# config_gen_bin_provision_spec.bats -- test.sh's _prepare_config_gen_bin
# copies the binary out of THIS checkout's config generator image, whatever
# the calling shell inherited (base#1469).
#
# The binary is what config_gen_bridge_golden_spec.bats compares to the
# bridge's golden bytes. If the resolve honoured a CONFIG_GEN_IMAGE pin, or
# a _CONFIG_GEN_RESOLVED memo, left in the environment by whoever started
# `just test`, the spec would cmp some other build's binary to this
# checkout's goldens and its verdict would describe that build. So the
# expected image is the one config_gen_resolve answers in a clean
# environment (`env -i`), with no override and no memo.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC2154
  TEMP_DIR="$(mktemp -d)"
  export TEMP_DIR
  DOCKER_STUB_DIR="${TEMP_DIR}/stub"
  export DOCKER_STUB_DIR
  mkdir -p "${DOCKER_STUB_DIR}"

  BIN_DIR="${TEMP_DIR}/bin"
  mkdir -p "${BIN_DIR}"
  # A daemon that has every image already, so the resolve never builds.
  # Every call's argv goes to ${DOCKER_STUB_DIR}/calls.
  cat > "${BIN_DIR}/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_STUB_DIR}/calls"
case "${1:-}" in
  create) printf 'cid-stub\n' ;;
esac
exit 0
STUB
  chmod +x "${BIN_DIR}/docker"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# The image config_gen_resolve answers in a clean environment (env -i, no
# override, no memo), then the image _prepare_config_gen_bin passed to
# `docker create` when the calling shell exported <var>=<value>.
_resolve_clean() {
  run env -i PATH="${BIN_DIR}:${PATH}" DOCKER_STUB_DIR="${DOCKER_STUB_DIR}" \
    LOG_FORMAT=text bash -c \
    'source /source/dist/script/docker/lib/config_gen.sh && config_gen_resolve && printf "%s" "${_CONFIG_GEN_RESOLVED}"'
  assert_success
  _expected="${output}"
  [[ "${_expected}" =~ ^config-gen:[0-9a-f]{12}$ ]] \
    || fail "clean resolve answered '${_expected}', not a config-gen:<12 hex> tag"
  rm -f "${DOCKER_STUB_DIR}/calls"
}

_provision_with() {
  run bash -c "
    export PATH='${BIN_DIR}:'\"\${PATH}\"
    export DOCKER_STUB_DIR='${DOCKER_STUB_DIR}'
    export LOG_FORMAT=text
    export ${1}=${2}
    source /source/script/test/test.sh
    declare -F _prepare_config_gen_bin >/dev/null || exit 99
    _prepare_config_gen_bin
  " 2>&1
  assert_success
  run grep -E '^create( |$)' "${DOCKER_STUB_DIR}/calls"
  assert_success
}

# why: a CONFIG_GEN_IMAGE pin inherited from the caller must not choose
# which binary the golden spec runs; it is the only poison, so a resolve
# that drops the memo but keeps the override names the poison image.
@test "the provisioned binary comes from this checkout's image, not an inherited CONFIG_GEN_IMAGE override" {
  local _expected
  _resolve_clean
  _provision_with CONFIG_GEN_IMAGE poison-override:latest
  assert_output "create ${_expected}"
}

# why: a _CONFIG_GEN_RESOLVED memo inherited from the caller must not
# choose which binary the golden spec runs; it is the only poison, so a
# resolve that drops the override but keeps the memo names the poison image.
@test "the provisioned binary comes from this checkout's image, not an inherited _CONFIG_GEN_RESOLVED memo" {
  local _expected
  _resolve_clean
  _provision_with _CONFIG_GEN_RESOLVED poison-memo:latest
  assert_output "create ${_expected}"
}
