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

# why: A real outage must still fail the job loud. If retry.sh swallowed
# the failure (exit 0), replaced the command's code with a generic 1, or
# ran one attempt too few or too many, a broken fetch would pass or burn
# CI time unbounded, base#1562.
@test "retry.sh: a command that always fails exits with its own code after exactly <attempts> runs and says so (base#1562)" {
  run --separate-stderr "${RETRY}" 3 0 -- "${FAKE}" 99 7
  # 7 = the fake's scripted exit code, not a generic 1 and not 0.
  assert_failure 7
  # The last attempt is reported on stderr in the documented shape.
  [[ "${stderr}" == *"retry: attempt 3/3 failed (exit 7)"* ]] \
    || fail "stderr lacks 'retry: attempt 3/3 failed (exit 7)': ${stderr}"
  # 3 = <attempts>: no run is skipped and no fourth run is made.
  run wc -l < "${FAKE_COUNT}"
  assert_output "3"
}

# why: A 5xx outage needs time to clear. A fixed or zero delay would burn
# every attempt inside the same outage; the delay doubles from
# <first-delay-s> between attempts and no sleep follows the last attempt,
# so a persistent failure is reported without a wasted wait, base#1562.
@test "retry.sh: the delay doubles from <first-delay-s> between attempts and none follows the last (base#1562)" {
  # Stub sleep on PATH: logs each argument instead of waiting.
  SLEEP_LOG="${BATS_TEST_TMPDIR}/sleep-log"
  export SLEEP_LOG
  : > "${SLEEP_LOG}"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  cat > "${BATS_TEST_TMPDIR}/bin/sleep" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SLEEP_LOG}"
EOS
  chmod +x "${BATS_TEST_TMPDIR}/bin/sleep"

  PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" run "${RETRY}" 4 5 -- "${FAKE}" 99 7
  assert_failure 7
  # 5 10 20 worked by hand: first delay 5, doubled after each of the
  # first three failures; the fourth (last) failure sleeps no more.
  run cat "${SLEEP_LOG}"
  assert_output "$(printf '5\n10\n20')"
}

# why: A typo in a workflow call (a non-integer count, a count of 0, a
# dropped `--`) must not quietly turn the retry into zero or one attempt,
# or run the wrong argv as the command. Every malformed call is refused
# with exit 2 before the command runs at all, base#1562.
@test "retry.sh: a malformed call exits 2 and never runs the command (base#1562)" {
  # Each row breaks the documented usage
  # `retry.sh <attempts> <first-delay-s> -- <cmd...>` in one way.
  local -a rows=(
    "x 0 --"   # attempts is not an integer
    "0 0 --"   # attempts < 1
    "3 0"      # no `--` before the command
    "3 y --"   # first-delay-s is not an integer
  )
  local row
  for row in "${rows[@]}"; do
    : > "${FAKE_COUNT}"
    # shellcheck disable=SC2086  # row is split into argv on purpose
    run "${RETRY}" ${row} "${FAKE}" 0 0
    [[ "${status}" -eq 2 ]] \
      || fail "retry.sh ${row} <cmd>: exit ${status}, want 2"
    # 0 = the fake never ran: a refused call must not run the command.
    [[ "$(wc -l < "${FAKE_COUNT}")" -eq 0 ]] \
      || fail "retry.sh ${row} <cmd>: the command ran $(wc -l < "${FAKE_COUNT}") time(s), want 0"
  done
}

# why: A Docker Hub 502 on the actionlint image pull failed the lint job
# because the only pull was the implicit `--pull missing` of the
# `docker run`, with no retry. Every step that names ACTIONLINT_IMAGE
# must pre-pull it through retry.sh (more than one attempt) before the
# run, and the run must say `--pull never`, so dropping the pre-pull or
# its retry fails loud instead of falling back to the unretried pull,
# base#1562.
@test "workflows: every ACTIONLINT_IMAGE step pulls via script/ci/retry.sh before a --pull never run (base#1562)" {
  local wf found=0 run_text pull_line run_line n
  for wf in /source/.github/workflows/*.yaml; do
    while IFS= read -r -d '' run_text; do
      [[ -n "${run_text}" ]] || continue
      found=$((found + 1))
      pull_line="$(printf '%s\n' "${run_text}" \
        | grep -nE 'script/ci/retry\.sh [0-9]+ [0-9]+ -- docker pull "\$\{ACTIONLINT_IMAGE\}"' \
        | head -n 1)"
      [[ -n "${pull_line}" ]] \
        || fail "${wf##*/}: an ACTIONLINT_IMAGE step has no retry.sh docker pull: ${run_text}"
      n="$(printf '%s\n' "${pull_line}" | sed -E 's/.*retry\.sh ([0-9]+) .*/\1/')"
      # >= 2 = at least one retry after the first pull.
      [[ "${n}" -ge 2 ]] \
        || fail "${wf##*/}: the actionlint pull makes ${n} attempt(s), want >= 2"
      run_line="$(printf '%s\n' "${run_text}" | grep -n 'docker run' | head -n 1)"
      [[ -n "${run_line}" ]] \
        || fail "${wf##*/}: an ACTIONLINT_IMAGE step has no docker run"
      [[ "${pull_line%%:*}" -lt "${run_line%%:*}" ]] \
        || fail "${wf##*/}: the retried pull does not precede the docker run"
      [[ "${run_line}" == *"--pull never"* ]] \
        || fail "${wf##*/}: the actionlint docker run lacks --pull never: ${run_line#*:}"
    done < <(yq -0 '.jobs[].steps[] | select(.env.ACTIONLINT_IMAGE != null) | .run' "${wf}")
  done
  # >= 1 = the step exists, so the check cannot pass vacuously.
  [[ "${found}" -ge 1 ]] || fail "no workflow step names ACTIONLINT_IMAGE"
}

# why: A GitHub API 504 in extractions/setup-just failed the just install
# after three quick tries a `uses:` step gives the workflow no way to
# extend. Every job that checks the just on PATH is the pin must install
# it through script/ci/install-just.sh (which fetches through retry.sh),
# fed the pin step's output, and no workflow may keep the unretried
# action -- so one job (the self-hosted coverage-local one included)
# reverting to setup-just is a finding, base#1562.
@test "workflows: every just-pin job installs just via script/ci/install-just.sh and none uses extractions/setup-just (base#1562)" {
  local wf found=0 job hits
  for wf in /source/.github/workflows/*.yaml; do
    hits="$(yq '[.jobs[].steps[] | select((.uses // "") | test("^extractions/setup-just"))] | length' "${wf}")"
    # 0 = the unretried action is gone from this file.
    [[ "${hits}" -eq 0 ]] \
      || fail "${wf##*/}: ${hits} step(s) still use extractions/setup-just"
    while IFS= read -r job; do
      [[ -n "${job}" ]] || continue
      found=$((found + 1))
      hits="$(J="${job}" yq '[.jobs[strenv(J)].steps[]
        | select(.run == "./script/ci/install-just.sh \"${JUST_VERSION}\"")
        | select(.env.JUST_VERSION == "${{ steps.just-pin.outputs.version }}")] | length' "${wf}")"
      # 1 = exactly one install step, in the documented shape.
      [[ "${hits}" -eq 1 ]] \
        || fail "${wf##*/}: job ${job} has ${hits} install-just.sh step(s) fed by steps.just-pin, want 1"
    done < <(yq '.jobs | to_entries[]
      | select([.value.steps[] | select(.name == "Check the just on PATH is the pin")] | length > 0)
      | .key' "${wf}")
  done
  # >= 1 = a pin-check job exists, so the check cannot pass vacuously.
  [[ "${found}" -ge 1 ]] || fail "no workflow job checks the just on PATH is the pin"
}
