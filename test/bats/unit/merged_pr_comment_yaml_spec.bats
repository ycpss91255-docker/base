#!/usr/bin/env bats
#
# merged_pr_comment_yaml_spec.bats -- a merge into main leaves a bot-authored
# event, so the owner is notified (base#2012).
#
# GitHub never notifies an account about its own actions, and the owner
# merges through the merge queue. A workflow that comments on the merged PR
# as github-actions gives the owner a notification. These cases read the
# workflow file itself through `yq`, the seam triage_label_yaml_spec.bats
# uses.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  REPO=/source
  WF="${REPO}/.github/workflows/merged-pr-comment.yaml"
}

# why: Only `pull_request: closed` on main fires for a manual, an auto and a
# queue merge alike. Any other event, another activity type or another base
# branch would comment on something that is not a merge into main (base#2012)
@test "merged-pr-comment: triggers only on pull_request closed into main" {
  assert_spec_subject "${WF}" "the post-merge bot comment"
  run yq '.on | keys | .[]' "${WF}"
  assert_success
  [ "${output}" = "pull_request" ]
  run yq '.on.pull_request.types[]' "${WF}"
  assert_success
  [ "${output}" = "closed" ]
  run yq '.on.pull_request.branches[]' "${WF}"
  assert_success
  [ "${output}" = "main" ]
}
