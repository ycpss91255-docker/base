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

# _stub_gh -- a `gh` on PATH that logs every call to ${CALLS}, answers the
# GraphQL read with ${GQL_FIXTURE}, answers the comment listing with
# ${LIST_FIXTURE} ([] when unset) and keeps the body of `pr comment` in
# ${POSTED}. `git` is stubbed to fail so a checkout or push is noticed.
_stub_gh() {
  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  CALLS="${BATS_TEST_TMPDIR}/calls"
  POSTED="${BATS_TEST_TMPDIR}/posted"
  GQL_FIXTURE="${BATS_TEST_TMPDIR}/gql.json"
  LIST_FIXTURE="${BATS_TEST_TMPDIR}/list.json"
  mkdir -p "${STUB_BIN}"
  : >"${CALLS}"
  cat >"${STUB_BIN}/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${CALLS}"
case "$1 $2" in
  "api graphql") cat "${GQL_FIXTURE}" ;;
  "pr comment")
    while [ $# -gt 0 ]; do
      [ "$1" = "--body-file" ] && cp "$2" "${POSTED}"
      shift
    done ;;
  "api --paginate") if [ -f "${LIST_FIXTURE}" ]; then cat "${LIST_FIXTURE}"; else echo '[]'; fi ;;
  *) echo "unexpected gh call: $*" >&2; exit 99 ;;
esac
STUB
  printf '#!/usr/bin/env bash\necho "git $*" >>"${CALLS}"\nexit 97\n' \
    >"${STUB_BIN}/git"
  chmod +x "${STUB_BIN}/gh" "${STUB_BIN}/git"
  export CALLS POSTED GQL_FIXTURE LIST_FIXTURE
}

# _run_step -- run the workflow's one step under the stubs.
_run_step() {
  local _body
  _body="$(yaml_step_run "${WF}" comment "Announce the merge")"
  PATH="${STUB_BIN}:${PATH}" GH_TOKEN=t REPO=me/base PR=42 \
    MERGE_SHA="${MERGE_SHA-deadbeefdeadbeefdeadbeefdeadbeefdeadbeef}" \
    run bash -c "${_body}"
}

# why: The comment is the owner's notification, so it must say WHICH merge
# and WHICH issues it closed. A closing issue of this repo reads `#7`; one
# of another repo must keep its owner/repo, or `#9` would point at the wrong
# tracker. The fixture carries a sha and refs no default could produce
# (base#2012)
@test "merged-pr-comment: the comment names the merge sha and the closing issues" {
  _stub_gh
  cat >"${GQL_FIXTURE}" <<'JSON'
{"data":{"repository":{"pullRequest":{"closingIssuesReferences":{"nodes":[
  {"number":7,"repository":{"nameWithOwner":"me/base"}},
  {"number":9,"repository":{"nameWithOwner":"other/repo"}}]}}}}}
JSON
  _run_step
  assert_success
  [ "$(cat "${POSTED}")" = "$(printf '%s\n%s\n%s' \
    '<!-- merged-pr-comment -->' \
    'Merged as deadbeefdeadbeefdeadbeefdeadbeefdeadbeef.' \
    'Closes: #7, other/repo#9.')" ]
}

# why: A merge that closes no issue still has to notify the owner, and a
# valid empty answer must not read as "Closes: ." (base#2012)
@test "merged-pr-comment: a PR that closes no issue says so" {
  _stub_gh
  echo '{"data":{"repository":{"pullRequest":{"closingIssuesReferences":{"nodes":[]}}}}}' \
    >"${GQL_FIXTURE}"
  _run_step
  assert_success
  [ "$(cat "${POSTED}")" = "$(printf '%s\n%s\n%s' \
    '<!-- merged-pr-comment -->' \
    'Merged as deadbeefdeadbeefdeadbeefdeadbeefdeadbeef.' \
    'This PR closes no issue.')" ]
}

# why: A merge event always carries merge_commit_sha. An empty one means the
# event is not what the workflow expects, and "Merged as ." would tell the
# owner nothing, so the step fails and posts nothing (base#2012)
@test "merged-pr-comment: an empty merge sha fails and posts nothing" {
  _stub_gh
  echo '{"data":{"repository":{"pullRequest":{"closingIssuesReferences":{"nodes":[]}}}}}' \
    >"${GQL_FIXTURE}"
  MERGE_SHA="" _run_step
  [ "${status}" -ne 0 ]
  [ ! -e "${POSTED}" ]
}
