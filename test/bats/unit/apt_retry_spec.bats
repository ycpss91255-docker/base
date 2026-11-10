#!/usr/bin/env bats
#
# Unit tests for dist/script/docker/build/apt-retry.sh -- the bounded
# retry the template Dockerfile wraps around each apt update + install
# layer, base#1602.
#
# `apt-get` and `sleep` are PATH stubs: apt-get appends its first argument
# (update / install) to a log and fails a scripted number of installs, so
# a test asserts the exit code and the exact order of apt calls without a
# network or a wait.
#
# why: An image build failed on one `404 Not Found` from a skewed apt
# mirror (base run 42770963035, devel-base layer) because the layer ran
# one update and one install, so the first failed fetch was final. A fresh
# `apt-get update` before each retried install lets a skewed index
# recover, base#1602.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  APT_RETRY="/source/dist/script/docker/build/apt-retry.sh"

  APT_LOG="${BATS_TEST_TMPDIR}/apt-log"
  INSTALL_COUNT="${BATS_TEST_TMPDIR}/install-count"
  SLEEP_LOG="${BATS_TEST_TMPDIR}/sleep-log"
  export APT_LOG INSTALL_COUNT SLEEP_LOG
  : > "${APT_LOG}"
  : > "${INSTALL_COUNT}"
  : > "${SLEEP_LOG}"

  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  # apt-get stub: logs its subcommand; `install` fails with
  # ${INSTALL_FAILS_RC} for the first ${INSTALL_FAILS} runs, then passes.
  cat > "${BATS_TEST_TMPDIR}/bin/apt-get" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${APT_LOG}"
if [[ "$1" == install ]]; then
  printf 'run\n' >> "${INSTALL_COUNT}"
  _n="$(wc -l < "${INSTALL_COUNT}")"
  if (( _n <= ${INSTALL_FAILS:-0} )); then
    exit "${INSTALL_FAILS_RC:-100}"
  fi
fi
exit 0
EOS
  cat > "${BATS_TEST_TMPDIR}/bin/sleep" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SLEEP_LOG}"
EOS
  chmod +x "${BATS_TEST_TMPDIR}/bin/apt-get" "${BATS_TEST_TMPDIR}/bin/sleep"
}

# why: The reported 404 is a transient mirror skew: one failed install
# followed by a passing one must leave the layer green, and the retry must
# refresh the index first, so the call order is update, install, update,
# install -- not a bare second install against the same stale index,
# base#1602.
@test "apt-retry.sh: an install that fails once (exit 100) then passes exits 0, with a fresh update before each install (base#1602)" {
  INSTALL_FAILS=1 INSTALL_FAILS_RC=100 \
    PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" \
    run "${APT_RETRY}" 4 15 -- apt-get install -y --no-install-recommends curl
  assert_success
  # Worked by hand: attempt 1 = update + install (fails 100),
  # attempt 2 = update + install (passes).
  run cat "${APT_LOG}"
  assert_output "$(printf 'update\ninstall\nupdate\ninstall')"
}
