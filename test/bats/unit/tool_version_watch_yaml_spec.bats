#!/usr/bin/env bats
#
# Structural assertions for `.github/workflows/tool-version-watch.yaml`
# -- the scheduled upstream-release watch.
#
# The workflow's whole value is a boundary: it detects a new upstream
# release, proposes the bump, lets CI prove it, and STOPS. Everything
# asserted here is about that boundary holding, because the failure mode
# of the alternative is not a broken build -- it is a third-party version
# landing on main without anyone reading the diff.
#
# So the spec is written mostly as prohibitions (nothing merges, nothing
# arms auto-merge, the scan job cannot write) and as the two decisions
# that are easy to quietly reverse: one proposal per tool rather than one
# for all of them, and an unreachable upstream FAILING rather than looking
# like a clean week.
#
# Shape mirrors self_test_yaml_spec.bats.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WF="/source/.github/workflows/tool-version-watch.yaml"
  # The subject is TRACKED, so its absence is a rename nobody noticed, not
  # a condition to tolerate. A `|| skip` here would report a green suite
  # for a watch that no longer exists -- the one outcome every prohibition
  # below is written to prevent.
  assert [ -f "${WF}" ]
}

# _job <name> -- the body of one job block.
_job() {
  awk -v j="  ${1}:" '$0 == j {flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
}

# ════════════════════════════════════════════════════════════════════
# It runs on a schedule, and by hand
# ════════════════════════════════════════════════════════════════════

# why: No PR exists on the day a pinned tool goes stale, so a PR gate cannot catch
# this class at all
@test "tool-version-watch: runs on a schedule" {
  # A gate on a PR cannot catch this class: there is no PR on the day a
  # pinned tool goes stale, and a stale linter never turns anything red.
  run awk '/^on:/{flag=1; next} /^[a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'schedule:'
  assert_output --partial 'cron:'
}

# why: The by-hand path is how the watch is exercised without waiting a week, and
# the dry run is what makes trying it safe
@test "tool-version-watch: can also be dispatched by hand, with a dry run" {
  run awk '/^on:/{flag=1; next} /^[a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'workflow_dispatch:'
  assert_output --partial 'dry-run:'
}

# ════════════════════════════════════════════════════════════════════
# The boundary: it proposes, it never lands
# ════════════════════════════════════════════════════════════════════

# why: The settled boundary: the automation stops at verification and a human
# audits and merges
@test "tool-version-watch: never merges anything" {
  # The settled rule, shared with the downstream fanout: the automation
  # stops at verification and a human audits and merges.
  run grep -nE 'gh pr merge|--auto|--squash --delete-branch|auto-merge-on-green' "${WF}"
  assert_failure
}

# why: The same boundary through the other door -- the API can arm auto-merge
# without any of the CLI spellings above appearing
@test "tool-version-watch: never enables auto-merge through the API either" {
  run grep -nE 'enablePullRequestAutoMerge|automerge|autoMerge' "${WF}"
  assert_failure
}

# why: The default is what every job inherits, so a write here quietly widens jobs
# that were never reviewed for it
@test "tool-version-watch: the workflow's default permission is read-only" {
  run awk '/^permissions:/{flag=1; next} /^[a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'contents: read'
  refute_output --partial 'write'
}

# why: A scan job that could write is a scan job that could land something; it
# resolves upstream versions and nothing else
@test "tool-version-watch: the scan job inherits read-only permissions" {
  # It resolves upstream versions and nothing else. A scan job that could
  # write is a scan job that could land something.
  run _job scan
  assert_success
  refute_output --partial 'permissions:'
}

# why: The grant block is what GitHub actually reads, and the scopes deliberately
# omitted are only visible as an absence
@test "tool-version-watch: the bump job takes exactly contents+pull-requests write" {
  # The grant itself, not the job body: the block is what GitHub reads,
  # and the surrounding comment names the scopes it deliberately omits.
  run awk '/^    permissions:/{flag=1; next} /^    [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'contents: write'
  assert_output --partial 'pull-requests: write'
  run grep -cE '^ +(checks|statuses|actions|packages|id-token|administration): write' "${WF}"
  assert_output '0'
}

# ════════════════════════════════════════════════════════════════════
# The proposal must arrive WITH CI -- the run is the output
# ════════════════════════════════════════════════════════════════════

# why: GitHub creates no run from an event GITHUB_TOKEN triggered, so a proposal
# opened with it arrives with zero checks -- silence read as green
@test "tool-version-watch: the proposal is opened with a credential that is NOT GITHUB_TOKEN" {
  # GitHub creates no workflow run from an event GITHUB_TOKEN triggered
  # (workflow_dispatch and repository_dispatch are the only exceptions).
  # A proposal opened with it therefore arrives with ZERO checks -- and a
  # PR with no checks reads as nothing-is-wrong, which is the same
  # silence-as-green defect the watch exists to end. This is asserted
  # rather than reviewed because no local run can observe it: the branch
  # pushes, the PR opens, and the only symptom is a checks list that is
  # empty.
  run _job bump
  assert_success
  assert_output --partial 'GH_TOKEN: ${{ secrets.'
  refute_output --partial 'GH_TOKEN: ${{ github.token }}'
  refute_output --partial 'GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}'
}

# why: Ordering is the whole assertion: a push before the credential check leaves
# a branch with no proposal pointing at it
@test "tool-version-watch: it verifies that credential BEFORE it pushes anything" {
  # Ordering is the whole assertion. A run that discovers the missing
  # secret after the push leaves a branch on the remote with no proposal
  # pointing at it -- the one state a reader of the pull-request list
  # cannot see, and the state that then wedges the pin.
  run awk '/needs a credential that is not GITHUB_TOKEN/{print "token-check"}
           /git push --set-upstream/{print "push"}' "${WF}"
  assert_success
  assert_equal "${lines[0]}" 'token-check'
  assert_equal "${lines[1]}" 'push'
}

# why: An abandoned branch makes every later run a non-fast-forward, failing that
# pin every week until a human deletes it by hand
@test "tool-version-watch: an abandoned branch is replaced, not left to wedge the pin" {
  # The remote branch exists and no OPEN proposal points at it, so an
  # earlier run pushed and stopped short. Every later run rebuilds the
  # commit from a fresh checkout, gets a different SHA and is rejected as
  # a non-fast-forward -- that pin failing every week until a human
  # deletes the branch by hand.
  run _job bump
  assert_success
  assert_output --partial 'git ls-remote --exit-code --heads origin'
  assert_output --partial 'git push --delete origin'
}

# ════════════════════════════════════════════════════════════════════
# One proposal per tool
# ════════════════════════════════════════════════════════════════════

# why: One shared branch conflates N questions into one red/green, so a safe bump
# cannot land while another is held
@test "tool-version-watch: the bump job is a matrix over the drifted pins" {
  # One shared branch would conflate N questions into one red/green: the
  # safe bumps could not land while one was held, and the CI log would no
  # longer say which version broke it.
  run _job bump
  assert_success
  assert_output --partial 'pin: ${{ fromJSON(needs.scan.outputs.drift) }}'
}

# why: One held bump must not take the others down with it; the matrix exists to
# keep the questions separate
@test "tool-version-watch: one failing bump does not cancel the others" {
  run _job bump
  assert_success
  assert_output --partial 'fail-fast: false'
}

# why: A per-tool branch that omitted the version would make the second bump of a
# tool collide with the first one's open proposal
@test "tool-version-watch: the branch name carries the tool AND the version" {
  # A per-tool branch that did not name the version would make the second
  # bump of the same tool collide with the first one's open proposal.
  run grep -F 'branch="watch/${PIN_NAME}-${PIN_TO}"' "${WF}"
  assert_success
}

# why: Re-opening a proposal that is already open is how a weekly schedule turns
# into weekly noise
@test "tool-version-watch: it skips a version pair that is already open" {
  run _job bump
  assert_success
  assert_output --partial '--state open --head'
}

# why: A closed proposal is dependabot's silent opt-out; the refusal here has to be
# skip= in the file that declares the pin
@test "tool-version-watch: it does NOT treat a closed proposal as a refusal" {
  # dependabot never re-raises a closed version pair, which is how this
  # repo opted out of a major bump at five call sites for months with
  # nothing in any config recording it. The refusal here is `skip=`, in
  # the file that declares the pin.
  run _job bump
  assert_success
  refute_output --partial '--state closed'
  refute_output --partial '--state all'
  assert_output --partial 'skip='
}

# ════════════════════════════════════════════════════════════════════
# Silence must not read as "up to date"
# ════════════════════════════════════════════════════════════════════

# why: Exit 1 means a source did not answer, and treating that as an empty matrix
# would look exactly like a clean week
@test "tool-version-watch: an unresolved upstream FAILS the scan job" {
  # Exit 1 from check.sh means a source did not answer. Treating that as
  # an empty matrix would look exactly like a clean week -- the precise
  # failure this whole mechanism exists to end.
  run _job scan
  assert_success
  assert_output --partial 'status}" -eq 1'
  assert_output --partial '::error::'
  assert_output --partial 'exit 1'
}

# why: Drift and unresolved take opposite actions, so collapsing the two exit codes
# would either skip real bumps or bump on no answer
@test "tool-version-watch: it separates 'drift found' from 'could not resolve'" {
  run _job scan
  assert_success
  assert_output --partial '-ne 10'
}

# why: Two walks can disagree, and each costs a request per pin against a 60/hour
# anonymous limit
@test "tool-version-watch: it walks the upstream APIs once per run" {
  # Two walks can disagree, and each one costs a request per pin against
  # a 60/hour anonymous limit.
  run grep -c 'watch/check.sh' "${WF}"
  assert_success
  assert_output '1'
}

# why: An anonymous walk runs out of quota mid-run, which surfaces as an upstream
# that did not answer rather than as the quota problem it is
@test "tool-version-watch: it authenticates to the GitHub API" {
  run _job scan
  assert_success
  assert_output --partial 'GITHUB_TOKEN: ${{ github.token }}'
}

# why: The report is the run's human output; buried in the log it is read only by
# whoever already suspected something
@test "tool-version-watch: the report reaches the run summary, not just the log" {
  run _job scan
  assert_success
  assert_output --partial 'GITHUB_STEP_SUMMARY'
}

# ════════════════════════════════════════════════════════════════════
# It derives the table rather than carrying one
# ════════════════════════════════════════════════════════════════════

# why: A roster kept in the workflow is one more thing to fall behind the
# Dockerfile -- the exact defect class the watch is built against
@test "tool-version-watch: the workflow names no individual tool" {
  # A roster kept here would be one more thing to fall behind the
  # Dockerfile -- the exact defect class the watch is built against. Every
  # tool name reaches the workflow through the matrix.
  run grep -nE '^ *- (hadolint|shellcheck|alpine|kcov|bats|just|actionlint)$' "${WF}"
  assert_failure
}

# why: The scheduled path and the human path must be one script, or the bump CI
# proves is not the bump a person can reproduce
@test "tool-version-watch: the bump is performed by the same script a human runs" {
  run _job bump
  assert_success
  assert_output --partial './script/watch/pins.sh --set'
}

# why: Both jobs check out and execute repository code, so a self-hosted runner
# would run it on hardware this repo does not control
@test "tool-version-watch: it runs on a reserved GitHub-hosted runner" {
  # Both jobs check out and execute repository code; the self-hosted guard
  # lint proves the rule generally, this pins the intent for this file.
  run grep -c 'runs-on: ubuntu-latest' "${WF}"
  assert_success
  assert_output '2'
}
