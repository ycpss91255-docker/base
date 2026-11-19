#!/usr/bin/env bats
#
# Unit tests for script/ci/check_commit_attribution.sh -- the CI check that
# fails a pull request or merge_group run when a commit in its range carries
# AI attribution, base#1989.
#
# Each spec builds a throwaway repository in BATS_TEST_TMPDIR, makes a base
# commit and the commits under test, and runs the script from inside it with
# EVENT_NAME, BASE_SHA and HEAD_SHA set the way the workflow sets them. The
# result is read from the exit code and the `::error::commit <sha>` lines.
#
# The marker strings are built from parts at runtime (_cab, _model, _addr) so
# the repository's own attribution guards do not fire on this file.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  CHECK="/source/script/ci/check_commit_attribution.sh"

  REPO="${BATS_TEST_TMPDIR}/repo"
  git init -q -b main "${REPO}"
  git -C "${REPO}" config user.email t@example.com
  git -C "${REPO}" config user.name t
  git -C "${REPO}" commit -q --allow-empty -m "base"
  BASE="$(git -C "${REPO}" rev-parse HEAD)"
}

# Marker parts, joined at runtime.
_cab() { printf '%s-%s-%s' "Co" "Authored" "By"; }
_model() { printf '%s%s' "Cla" "ude"; }
_addr() { printf '%s@%s.%s' "noreply" "anthropic" "com"; }

# _commit <message>: an empty commit in REPO with that message.
_commit() {
  git -C "${REPO}" commit -q --allow-empty -m "$1"
}

# _run_pr: run the check over BASE..HEAD as a pull_request event.
_run_pr() {
  cd "${REPO}" || return 1
  export EVENT_NAME=pull_request
  export BASE_SHA="${BASE}"
  HEAD_SHA="$(git rev-parse HEAD)"
  export HEAD_SHA
  run bash "${CHECK}"
}

# why: The trailer the agent tooling adds by default is the case the check
# exists for. A check that always passed would pass every clean-commit spec,
# so this one pins exit 1 and the offending sha in the output (base#1989).
@test "check_commit_attribution.sh: a co-author trailer naming the model fails and names the sha (base#1989)" {
  _commit "$(printf 'feat: x\n\n%s: %s X <%s>' "$(_cab)" "$(_model)" "$(_addr)")"
  local _sha
  _sha="$(git -C "${REPO}" rev-parse HEAD)"

  _run_pr
  assert_equal "${status}" 1
  assert_output --partial "::error::commit ${_sha}: attribution marker in message"
}

# why: The address is attribution under any trailer key, not only the
# co-author one. A check that ran the marker list alone would pass a
# `Reviewed-by:` trailer carrying it, so this pins exit 1 and the sha for a
# trailer the marker list does not name (base#1989).
@test "check_commit_attribution.sh: a non-co-author trailer with the noreply address fails and names the sha (base#1989)" {
  _commit "$(printf 'feat: x\n\nReviewed-by: Bot <%s>' "$(_addr)")"
  local _sha
  _sha="$(git -C "${REPO}" rev-parse HEAD)"

  _run_pr
  assert_equal "${status}" 1
  assert_output --partial "::error::commit ${_sha}: noreply address in message"
}

# why: Email addresses are matched without regard to case, so the noreply
# address written in upper case is the same address. A check that matched it
# case-sensitively would pass an upper-case `Reviewed-by:` trailer, which the
# marker list does not name, so this pins exit 1 and the sha (base#1989).
@test "check_commit_attribution.sh: an upper-case noreply address in a trailer fails and names the sha (base#1989)" {
  local _uc
  _uc="$(_addr | tr '[:lower:]' '[:upper:]')"
  _commit "$(printf 'feat: x\n\nReviewed-by: Bot <%s>' "${_uc}")"
  local _sha
  _sha="$(git -C "${REPO}" rev-parse HEAD)"

  _run_pr
  assert_equal "${status}" 1
  assert_output --partial "::error::commit ${_sha}: noreply address in message"
}

# why: Git accepts a space before a trailer's colon and prints the trailer in
# canonical `key: value` form. A check that ran the marker list over the raw
# body alone would pass `<key> : <model> <other address>`, which names the
# model and carries no noreply address, so this pins exit 1 and the sha
# (base#1989).
@test "check_commit_attribution.sh: a co-author trailer with a space before the colon naming the model fails and names the sha (base#1989)" {
  _commit "$(printf 'feat: x\n\n%s : %s <x@example.com>' "$(_cab)" "$(_model)")"
  local _sha
  _sha="$(git -C "${REPO}" rev-parse HEAD)"

  _run_pr
  assert_equal "${status}" 1
  assert_output --partial "::error::commit ${_sha}: attribution marker in message"
}

# why: The address as the author identity is attribution even when the
# message is clean. A check that read the message alone would pass a commit
# authored as the noreply address, so this pins exit 1 and the sha for a
# clean message with that author email (base#1989).
@test "check_commit_attribution.sh: an author email equal to the noreply address fails and names the sha (base#1989)" {
  GIT_AUTHOR_EMAIL="$(_addr)" git -C "${REPO}" commit -q --allow-empty -m "feat: x"
  local _sha
  _sha="$(git -C "${REPO}" rev-parse HEAD)"

  _run_pr
  assert_equal "${status}" 1
  assert_output --partial "::error::commit ${_sha}: noreply address as author email"
}

# why: The address as the committer identity is attribution too, and a
# commit can carry it there with a clean message and a human author. A check
# that read the author email for both identities would pass such a commit,
# so this pins exit 1 and the sha when only the committer email is the
# noreply address (base#1989).
@test "check_commit_attribution.sh: a committer email equal to the noreply address fails and names the sha (base#1989)" {
  GIT_COMMITTER_EMAIL="$(_addr)" git -C "${REPO}" commit -q --allow-empty -m "feat: x"
  local _sha
  _sha="$(git -C "${REPO}" rev-parse HEAD)"

  _run_pr
  assert_equal "${status}" 1
  assert_output --partial "::error::commit ${_sha}: noreply address as committer email"
}

# why: Email addresses are matched without regard to case, so an author
# email that spells the noreply address in mixed case is the same address.
# A check that compared the author email case-sensitively would pass a
# commit authored as `NoReply@Anthropic.com` with a clean message, so this
# pins exit 1 and the sha for it (base#1989).
@test "check_commit_attribution.sh: a mixed-case author email equal to the noreply address fails and names the sha (base#1989)" {
  GIT_AUTHOR_EMAIL="$(printf '%s@%s.%s' "NoReply" "Anthropic" "com")" \
    git -C "${REPO}" commit -q --allow-empty -m "feat: x"
  local _sha
  _sha="$(git -C "${REPO}" rev-parse HEAD)"

  _run_pr
  assert_equal "${status}" 1
  assert_output --partial "::error::commit ${_sha}: noreply address as author email"
}

# why: The committer email is compared on its own, and without regard to
# case like the author email. A check that compared it case-sensitively
# would pass a commit with a human author and a clean message committed as
# `NoReply@Anthropic.com`, so this pins exit 1 and the sha for it
# (base#1989).
@test "check_commit_attribution.sh: a mixed-case committer email equal to the noreply address fails and names the sha (base#1989)" {
  GIT_COMMITTER_EMAIL="$(printf '%s@%s.%s' "NoReply" "Anthropic" "com")" \
    git -C "${REPO}" commit -q --allow-empty -m "feat: x"
  local _sha
  _sha="$(git -C "${REPO}" rev-parse HEAD)"

  _run_pr
  assert_equal "${status}" 1
  assert_output --partial "::error::commit ${_sha}: noreply address as committer email"
}

# why: The author rule is an email equal to the noreply address, not one
# that merely contains it. A check that matched the address anywhere in the
# author email would fail a commit authored under another domain that ends
# in the address's text, so this pins exit 0 and no author-email error for
# `noreply@anthropic.com.example.org` with a clean message (base#1989).
@test "check_commit_attribution.sh: an author email that only contains the noreply address passes (base#1989)" {
  GIT_AUTHOR_EMAIL="$(_addr).example.org" \
    git -C "${REPO}" commit -q --allow-empty -m "feat: x"

  _run_pr
  assert_equal "${status}" 0
  refute_output --partial "noreply address as author email"
  assert_output --partial "no AI attribution in 1 commit(s)"
}

# why: The workflow also runs on push and on release tags, where there is no
# pull request range to walk. A check that demanded BASE_SHA and HEAD_SHA on
# every event would fail those runs, so this pins exit 0 and the no-range
# notice for a push event with neither sha set (base#1989).
@test "check_commit_attribution.sh: a push event has no range to check and passes with a notice (base#1989)" {
  cd "${REPO}" || return 1
  unset BASE_SHA HEAD_SHA
  export EVENT_NAME=push

  run bash "${CHECK}"
  assert_equal "${status}" 0
  assert_output --partial "no range"
}

# why: A pull request run whose base sha does not name a commit in the clone
# has no range git can walk. A check that walked `git rev-list` without
# verifying the shas would see an empty list and pass, so this pins a
# non-zero exit for a pull_request event whose BASE_SHA does not resolve
# (base#1989).
@test "check_commit_attribution.sh: a pull_request event whose base sha does not resolve fails (base#1989)" {
  cd "${REPO}" || return 1
  export EVENT_NAME=pull_request
  export BASE_SHA="0123456789abcdef0123456789abcdef01234567"
  HEAD_SHA="$(git rev-parse HEAD)"
  export HEAD_SHA

  run bash "${CHECK}"
  assert_not_equal "${status}" 0
}

# why: The head end needs the same guard as the base end. A check that
# verified only BASE_SHA would hand an unresolvable HEAD_SHA to
# `git rev-list`, read an empty walk and print "no AI attribution in 0
# commit(s)" with exit 0. So a pull_request event whose HEAD_SHA does not
# resolve must exit non-zero without that pass line (base#1989).
@test "check_commit_attribution.sh: a pull_request event whose head sha does not resolve fails (base#1989)" {
  _commit "feat: x"
  cd "${REPO}" || return 1
  export EVENT_NAME=pull_request
  export BASE_SHA="${BASE}"
  export HEAD_SHA="0123456789abcdef0123456789abcdef01234567"

  run bash "${CHECK}"
  assert_not_equal "${status}" 0
  refute_output --partial "no AI attribution in"
}

# why: Every other pull_request spec expects a failure, so a check that
# reported every commit in a resolvable range and exited 1 would pass them
# all. A range of clean commits must exit 0 with no `::error::` line and
# the commit count, which pins the pass case the issue asks for (base#1989).
@test "check_commit_attribution.sh: a range of clean commits passes with no error line (base#1989)" {
  _commit "feat: x"
  _commit "fix: y"

  _run_pr
  assert_equal "${status}" 0
  refute_output --partial "::error::"
  assert_output --partial "no AI attribution in 2 commit(s)"
}

# why: The repository keeps agent tooling under a directory named after the
# model, and commits that touch it name that path. A check that grepped the
# message for the model name alone would block them, so a commit whose
# subject and body only name such a path must exit 0 (base#1989).
@test "check_commit_attribution.sh: a commit that only names the model's hooks path passes (base#1989)" {
  local _dir
  _dir=".$(_model | tr '[:upper:]' '[:lower:]')"
  _commit "$(printf 'chore: tidy %s/hooks\n\nTouches %s/hooks/x.sh only.' "${_dir}" "${_dir}")"

  _run_pr
  assert_equal "${status}" 0
  refute_output --partial "::error::"
}

# why: The marker list has two alternatives, and the generated-with footer
# is the one the co-author specs never reach. A check that dropped it would
# pass a commit whose only attribution is that footer, so this pins exit 1,
# the sha and the marker label for it (base#1989).
@test "check_commit_attribution.sh: a generated-with footer naming the model fails and names the sha (base#1989)" {
  _commit "$(printf 'feat: x\n\n%s with [%s Code](https://example.com/x)' "Generated" "$(_model)")"
  local _sha
  _sha="$(git -C "${REPO}" rev-parse HEAD)"

  _run_pr
  assert_equal "${status}" 1
  assert_output --partial "::error::commit ${_sha}: attribution marker in message"
}

# why: The tooling has written the co-author key in lower case. A check that
# matched the marker list case-sensitively would pass a lower-case key and
# model name with no noreply address, so this pins exit 1 for it
# (base#1989).
@test "check_commit_attribution.sh: a lower-case co-author trailer naming the model fails (base#1989)" {
  local _lc
  _lc="$(printf '%s: %s <x@example.com>' "$(_cab)" "$(_model)" | tr '[:upper:]' '[:lower:]')"
  _commit "$(printf 'feat: x\n\n%s' "${_lc}")"
  local _sha
  _sha="$(git -C "${REPO}" rev-parse HEAD)"

  _run_pr
  assert_equal "${status}" 1
  assert_output --partial "::error::commit ${_sha}: attribution marker in message"
}

# why: Git reads an indented line after a trailer as its continuation, so a
# trailer can put the model name on the next line. A check that ran the
# marker list over the raw body alone would miss the split, so this pins
# exit 1 for a folded co-author trailer with another address (base#1989).
@test "check_commit_attribution.sh: a folded co-author trailer naming the model fails (base#1989)" {
  _commit "$(printf 'feat: x\n\n%s:\n  %s <x@example.com>' "$(_cab)" "$(_model)")"
  local _sha
  _sha="$(git -C "${REPO}" rev-parse HEAD)"

  _run_pr
  assert_equal "${status}" 1
  assert_output --partial "::error::commit ${_sha}: attribution marker in message"
}

# why: The same fold can put the noreply address on the continuation line.
# A check that matched a trailer as one `key: name <address>` line would
# miss it, so this pins exit 1 for a folded trailer whose address sits on
# the next line (base#1989).
@test "check_commit_attribution.sh: a folded trailer with the noreply address on the next line fails (base#1989)" {
  _commit "$(printf 'feat: x\n\n%s: Bot\n  <%s>' "$(_cab)" "$(_addr)")"
  local _sha
  _sha="$(git -C "${REPO}" rev-parse HEAD)"

  _run_pr
  assert_equal "${status}" 1
  assert_output --partial "::error::commit ${_sha}: noreply address in message"
}

# why: main already holds attributed commits the check must not re-judge.
# A check that walked HEAD's whole history would fail on an offender at or
# below BASE_SHA, so a range whose only offender is the base commit itself
# must exit 0 (base#1989).
@test "check_commit_attribution.sh: an offender at the base sha with clean commits after it passes (base#1989)" {
  _commit "$(printf 'feat: old\n\n%s: %s X <%s>' "$(_cab)" "$(_model)" "$(_addr)")"
  BASE="$(git -C "${REPO}" rev-parse HEAD)"
  _commit "feat: x"

  _run_pr
  assert_equal "${status}" 0
  refute_output --partial "::error::"
}

# why: The output has to list every offending commit, not the first one.
# A check that exited on its first hit would name only one of two
# offenders, so this pins both shas with their marker labels in one range
# (base#1989).
@test "check_commit_attribution.sh: two offending commits in one range are both listed (base#1989)" {
  _commit "$(printf 'feat: x\n\nReviewed-by: Bot <%s>' "$(_addr)")"
  local _first
  _first="$(git -C "${REPO}" rev-parse HEAD)"
  _commit "fix: clean"
  _commit "$(printf 'fix: y\n\n%s with [%s Code](https://example.com/x)' "Generated" "$(_model)")"
  local _second
  _second="$(git -C "${REPO}" rev-parse HEAD)"

  _run_pr
  assert_equal "${status}" 1
  assert_output --partial "::error::commit ${_first}: noreply address in message"
  assert_output --partial "::error::commit ${_second}: attribution marker in message"
}

# _run_mg: run the check over BASE..HEAD as a merge_group event.
_run_mg() {
  cd "${REPO}" || return 1
  export EVENT_NAME=merge_group
  export BASE_SHA="${BASE}"
  HEAD_SHA="$(git rev-parse HEAD)"
  export HEAD_SHA
  run bash "${CHECK}"
}

# why: The merge queue runs the check too, over its own base_sha..head_sha
# range. A check that walked a range for pull_request alone would give every
# merge_group run the no-range notice and pass, so a merge_group range that
# holds an offender must exit 1 and name the sha (base#1989).
@test "check_commit_attribution.sh: a merge_group range with an offender fails and names the sha (base#1989)" {
  _commit "fix: clean"
  _commit "$(printf 'feat: x\n\n%s: %s X <%s>' "$(_cab)" "$(_model)" "$(_addr)")"
  local _sha
  _sha="$(git -C "${REPO}" rev-parse HEAD)"

  _run_mg
  assert_equal "${status}" 1
  assert_output --partial "::error::commit ${_sha}: attribution marker in message"
}

# why: A merge_group run walks its range rather than passing on the no-range
# notice. A clean merge_group range must exit 0 with the walked commit count
# and no notice, so a check that skipped merge_group cannot pass it
# (base#1989).
@test "check_commit_attribution.sh: a clean merge_group range passes with the commit count (base#1989)" {
  _commit "feat: x"
  _commit "fix: y"

  _run_mg
  assert_equal "${status}" 0
  refute_output --partial "::error::"
  refute_output --partial "no range to check"
  assert_output --partial "no AI attribution in 2 commit(s)"
}
