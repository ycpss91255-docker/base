#!/usr/bin/env bats
#
# Unit tests for script/ci/single_issue_pr.sh -- the check that fails a
# pull request whose merge would close more than one issue, base#1629.
#
# The script is pure bash. Inputs arrive in the environment:
# PR_CLOSING_REFS (GitHub's closingIssuesReferences, one `owner/repo#N`
# per line), PR_COMMITS, PR_BODY, REPO. The verdict is the exit code and
# stderr.
#
# why: Nothing read what a PR will close, so "Closes #1 Closes #2"
# passed every check. These specs pin the verdict at the script's
# public interface, base#1629.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  CHECK="/source/script/ci/single_issue_pr.sh"

  export REPO="ycpss91255-docker/base"
  unset PR_CLOSING_REFS PR_COMMITS PR_BODY
}

# why: The whole point of the check. A script that always exited 0 would
# leave the bundled-PR habit unenforced; the message must name both
# issues so the author knows what to split (base#1629).
@test "single_issue_pr.sh: two closing references fail and the message names both (base#1629)" {
  export PR_CLOSING_REFS=$'ycpss91255-docker/base#1\nycpss91255-docker/base#2'

  run --separate-stderr bash "${CHECK}"
  assert_failure 1
  [[ "${stderr}" == *"base#1"* ]]
  [[ "${stderr}" == *"base#2"* ]]
}

# why: The repo squashes with COMMIT_MESSAGES, so a closing keyword in a
# branch commit closes the issue even when GitHub's reference list for
# the PR is empty. A script that ignored PR_COMMITS would pass a bundled
# squash body (base#1629).
@test "single_issue_pr.sh: two closing keywords in commit messages fail with empty closing refs (base#1629)" {
  export PR_CLOSING_REFS=""
  export PR_COMMITS=$'fix: first\n\nCloses #1\n\nfix: second\n\nFixes #2'

  run --separate-stderr bash "${CHECK}"
  assert_failure 1
  [[ "${stderr}" == *"#1"* ]]
  [[ "${stderr}" == *"#2"* ]]
}
