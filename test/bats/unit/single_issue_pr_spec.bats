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

# why: The same issue reached two ways (GitHub's qualified reference and
# a bare `#1` in a commit message) is one issue. A script that counted
# distinct strings would fail a PR that closes exactly one issue
# (base#1629).
@test "single_issue_pr.sh: the same issue as a qualified ref and a bare commit ref passes (base#1629)" {
  export PR_CLOSING_REFS="ycpss91255-docker/base#1"
  export PR_COMMITS=$'fix: only\n\nCloses #1'

  run --separate-stderr bash "${CHECK}"
  assert_success
}

# why: A closing keyword inside a fenced code block is quoted text, not
# a directive, and GitHub does not act on it. A script that grepped raw
# text would fail a PR that closes exactly one issue because a commit
# message quotes an example (base#1629).
@test "single_issue_pr.sh: a closing keyword inside a fenced code block is ignored (base#1629)" {
  export PR_CLOSING_REFS=""
  export PR_COMMITS=$'fix: only\n\nCloses #1\n\n```\nCloses #2\n```'

  run --separate-stderr bash "${CHECK}"
  assert_success
}

# why: Inline code is quoted text too. A script that only stripped fenced
# blocks would fail a PR that closes exactly one issue because a commit
# message mentions `Closes #2` in backticks (base#1629).
@test "single_issue_pr.sh: a closing keyword inside inline code is ignored (base#1629)" {
  export PR_CLOSING_REFS=""
  export PR_COMMITS=$'fix: only\n\nCloses #1\n\nDo not write `Closes #2` here.'

  run --separate-stderr bash "${CHECK}"
  assert_success
}

# why: An HTML comment is not rendered and GitHub does not act on a
# closing keyword inside it (PR templates ship such comments). A script
# that only stripped code would fail a PR that closes exactly one issue
# because a commit message carries a commented-out example (base#1629).
@test "single_issue_pr.sh: a closing keyword inside an HTML comment is ignored (base#1629)" {
  export PR_CLOSING_REFS=""
  export PR_COMMITS=$'fix: only\n\nCloses #1\n\n<!-- Closes #2 -->'

  run --separate-stderr bash "${CHECK}"
  assert_success
}
