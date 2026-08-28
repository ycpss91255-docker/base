#!/usr/bin/env bats
#
# action_ref_agreement_lint_spec.bats -- "every call site of the same
# GitHub Action agrees on one ref".
#
# The defect this pins: `docker/build-push-action` was used at eleven
# call sites across .github/workflows/, five of them on `@v6` and six on
# `@v7`, so which major version built an image depended on which
# workflow ran. The split sat green for months because nothing compares
# refs ACROSS files -- actionlint validates each `uses:` in isolation,
# and dependabot, having had its v6 -> v7 pull request closed, never
# raises that version pair again.
#
# This spec drives the REAL tree, which is the only place the claim
# means anything: a fixture can only prove the reader works, and the
# reader is not what drifted.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WF_DIR="/source/.github/workflows"
  [[ -d "${WF_DIR}" ]] || skip "workflow directory not at expected path"
}

# _action_ref_pairs -- print one `<owner>/<repo><TAB><ref>` record per
# DISTINCT (action, ref) pair used anywhere under .github/workflows/.
#
# The identity is `<owner>/<repo>`, not the full `uses:` path: a ref is a
# git tag on the ACTION'S REPOSITORY, so `actions/cache/save@v6` and
# `actions/cache/restore@v6` name two entry points of one versioned
# thing and must move together. Local calls (`./...`) carry no ref and
# are skipped; a trailing `# comment` after the value is stripped, which
# is what keeps the sha-pinned + annotated form readable.
_action_ref_pairs() {
  grep -rhE '^[[:space:]]*(-[[:space:]]+)?uses:' "${WF_DIR}" \
    | sed -E 's/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*//' \
    | sed -E 's/[[:space:]]+#.*$//' \
    | sed -E "s/[\"']//g" \
    | grep -E '^[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+@' \
    | awk -F'@' '{ split($1, p, "/"); print p[1] "/" p[2] "\t" $2 }' \
    | sort -u
}

@test "workflows: every action is used at exactly one ref (#949)" {
  local -a _pairs=()
  mapfile -t _pairs < <(_action_ref_pairs)

  # Non-vacuity. A reader that stopped recognising `uses:` would report
  # no disagreement forever, in silence -- the same shape of unnoticed
  # green the split itself had.
  [ "${#_pairs[@]}" -ge 10 ] \
    || fail "the workflow tree yielded ${#_pairs[@]} (action, ref) pairs; the reader, not the workflows, is what to look at"

  local -a _split=()
  mapfile -t _split < <(printf '%s\n' "${_pairs[@]}" | cut -f1 | uniq -d)

  if [ "${#_split[@]}" -gt 0 ]; then
    local _action _refs _report=""
    for _action in "${_split[@]}"; do
      _refs="$(printf '%s\n' "${_pairs[@]}" \
        | awk -F'\t' -v a="${_action}" '$1 == a { printf "%s ", $2 }')"
      _report+="  ${_action} is used at these refs: ${_refs}"$'\n'
    done
    fail "action(s) used at more than one ref across .github/workflows/:
${_report}A ref is a tag on the action's repository, so two refs in one tree means two different versions of the same action run depending on which workflow fires."
  fi
}
