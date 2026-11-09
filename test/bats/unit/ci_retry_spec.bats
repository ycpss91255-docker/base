#!/usr/bin/env bats
#
# Unit tests for script/ci/retry.sh -- the one bounded-retry helper CI
# wraps around a network fetch (the actionlint image pull, the just
# install), base#1562.
#
# The command under retry is a fake: a script that counts its own runs in
# a file and fails a scripted number of times before it succeeds, so a
# test asserts both the exit code and how many attempts were made.
#
# why: A CI job failed on one upstream 5xx (a Docker Hub 502 on the
# actionlint pull, a GitHub API 504 in the just install) because no step
# retried the fetch. These specs pin the retry contract by behaviour:
# a transient failure then success passes, a persistent failure still
# fails loud with its own exit code, base#1562.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  RETRY="/source/script/ci/retry.sh"

  FAKE_COUNT="${BATS_TEST_TMPDIR}/fake-count"
  export FAKE_COUNT
  : > "${FAKE_COUNT}"

  # fake <failures> <fail-rc>: each run appends one line to FAKE_COUNT;
  # the first <failures> runs exit <fail-rc>, every later run exits 0.
  FAKE="${BATS_TEST_TMPDIR}/fake"
  cat > "${FAKE}" <<'EOS'
#!/usr/bin/env bash
printf 'run\n' >> "${FAKE_COUNT}"
_n="$(wc -l < "${FAKE_COUNT}")"
if (( _n <= $1 )); then
  exit "$2"
fi
exit 0
EOS
  chmod +x "${FAKE}"
}

@test "retry.sh: a command that fails twice then succeeds exits 0 after 3 runs (base#1562)" {
  run "${RETRY}" 5 0 -- "${FAKE}" 2 22
  assert_success
  # 3 = the fake's two scripted failures + the one run that succeeds.
  run wc -l < "${FAKE_COUNT}"
  assert_output "3"
}
