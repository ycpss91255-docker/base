#!/usr/bin/env bats
#
# Unit tests for script/ci/install-just.sh -- the pinned just install
# every CI job runs (hosted and self-hosted alike) in place of
# extractions/setup-just, base#1562.
#
# The network is a PATH stub `curl`: it logs every URL it is asked for,
# fails each URL per a scripted plan, and otherwise serves the file from
# a fixture dir by the URL's basename. The fixture is a release tarball
# holding a `just` shell script that prints `just 9.9.9`, plus its
# SHA256SUMS, both built in the test with the real tar and sha256sum.
# `sleep` is stubbed so a retry does not wait, and `uname` is stubbed so
# the asset name is fixed whatever host runs the spec.
#
# why: A CI job failed on one upstream 5xx (a GitHub API 504 inside
# setup-just) because the just install had no retry we control. These
# specs run the real install script against a failing download, so the
# retry is proven by behaviour, base#1562.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  INSTALL_JUST="/source/script/ci/install-just.sh"

  # The URLs the release lists for a version (the shape of
  # `gh api repos/casey/just/releases/tags/1.58.0`), for the fixture
  # version 9.9.9 on an x86_64 runner.
  REL="https://github.com/casey/just/releases/download/9.9.9"
  TARBALL_URL="${REL}/just-9.9.9-x86_64-unknown-linux-musl.tar.gz"
  SUMS_URL="${REL}/SHA256SUMS"

  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  FIXTURE="${BATS_TEST_TMPDIR}/fixture"
  CURL_LOG="${BATS_TEST_TMPDIR}/curl-log"
  CURL_FAILS="${BATS_TEST_TMPDIR}/curl-fails"
  export FIXTURE CURL_LOG CURL_FAILS
  mkdir -p "${STUB_BIN}" "${FIXTURE}/src"
  : > "${CURL_LOG}"
  : > "${CURL_FAILS}"

  # Fixture release: a tarball with `just` at its root, and SHA256SUMS
  # listing it in sha256sum's own two-space format.
  cat > "${FIXTURE}/src/just" <<'EOS'
#!/usr/bin/env bash
printf 'just 9.9.9\n'
EOS
  chmod +x "${FIXTURE}/src/just"
  tar -czf "${FIXTURE}/just-9.9.9-x86_64-unknown-linux-musl.tar.gz" \
    -C "${FIXTURE}/src" just
  (cd "${FIXTURE}" && sha256sum just-9.9.9-x86_64-unknown-linux-musl.tar.gz) \
    > "${FIXTURE}/SHA256SUMS"

  # Stub curl: log the URL; while the URL has fewer logged calls than its
  # scripted failure count in CURL_FAILS (lines `<n> <url>`), exit 22 as
  # `curl -f` does on an HTTP error; otherwise copy the fixture file named
  # by the URL's basename to the `-o` path.
  cat > "${STUB_BIN}/curl" <<'EOS'
#!/usr/bin/env bash
out="" url=""
while (( $# > 0 )); do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "${url}" >> "${CURL_LOG}"
calls="$(grep -cxF -- "${url}" "${CURL_LOG}")"
fails="$(awk -v u="${url}" '$2 == u { print $1 }' "${CURL_FAILS}")"
if (( calls <= ${fails:-0} )); then
  printf 'curl: (22) The requested URL returned error: 502\n' >&2
  exit 22
fi
[[ -f "${FIXTURE}/${url##*/}" ]] || exit 22
cp "${FIXTURE}/${url##*/}" "${out}"
EOS
  cat > "${STUB_BIN}/sleep" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
  cat > "${STUB_BIN}/uname" <<'EOS'
#!/usr/bin/env bash
printf 'x86_64\n'
EOS
  chmod +x "${STUB_BIN}/curl" "${STUB_BIN}/sleep" "${STUB_BIN}/uname"

  RUNNER_TEMP="${BATS_TEST_TMPDIR}/runner-temp"
  GITHUB_PATH="${BATS_TEST_TMPDIR}/github-path"
  export RUNNER_TEMP GITHUB_PATH
  mkdir -p "${RUNNER_TEMP}"
}

# _calls <url>: how many times the stub curl was asked for <url>.
_calls() {
  grep -cxF -- "$1" "${CURL_LOG}" || true
}

# why: The just install must ride out one upstream 5xx on EITHER of its
# two fetches (the tarball and its SHA256SUMS) instead of failing the
# job, and must publish a PATH dir only once that dir holds a working
# binary. A retry on just one fetch, a swap to a tool other than curl, or
# a PATH entry without the binary would each leave a job red or wrong,
# base#1562.
@test "install-just.sh: one failed fetch of the tarball and of SHA256SUMS is retried and just lands on GITHUB_PATH (base#1562)" {
  printf '1 %s\n1 %s\n' "${TARBALL_URL}" "${SUMS_URL}" > "${CURL_FAILS}"

  PATH="${STUB_BIN}:${PATH}" run "${INSTALL_JUST}" 9.9.9
  assert_success

  # > 1 = the scripted failure plus at least the one call that served it.
  [[ "$(_calls "${TARBALL_URL}")" -gt 1 ]] \
    || fail "tarball fetched $(_calls "${TARBALL_URL}") time(s), want > 1; curl log: $(cat "${CURL_LOG}")"
  [[ "$(_calls "${SUMS_URL}")" -gt 1 ]] \
    || fail "SHA256SUMS fetched $(_calls "${SUMS_URL}") time(s), want > 1; curl log: $(cat "${CURL_LOG}")"

  # The last GITHUB_PATH line is a dir whose just is the fixture's.
  [[ -s "${GITHUB_PATH}" ]] || fail "GITHUB_PATH is empty or absent"
  local just_dir
  just_dir="$(tail -n 1 "${GITHUB_PATH}")"
  run "${just_dir}/just" --version
  assert_success
  # `just 9.9.9` = the literal the fixture's just script prints.
  assert_output "just 9.9.9"
}

# why: A download that arrives but is not the release's bytes (a proxy
# error page, a truncated or tampered tarball) must fail the job, not be
# installed. The install checks the tarball against the release's
# SHA256SUMS before it publishes a PATH dir, base#1562.
@test "install-just.sh: a tarball whose digest does not match SHA256SUMS fails and leaves GITHUB_PATH untouched (base#1562)" {
  # 64 zeros = a digest no real tarball has, in sha256sum's own
  # two-space line format for the asset.
  printf '%s  %s\n' \
    "0000000000000000000000000000000000000000000000000000000000000000" \
    "just-9.9.9-x86_64-unknown-linux-musl.tar.gz" > "${FIXTURE}/SHA256SUMS"

  PATH="${STUB_BIN}:${PATH}" run "${INSTALL_JUST}" 9.9.9
  assert_failure

  [[ ! -s "${GITHUB_PATH}" ]] \
    || fail "GITHUB_PATH was written on a digest mismatch: $(cat "${GITHUB_PATH}")"
}
