#!/usr/bin/env bats
#
# action_ref_agreement_lint_spec.bats -- "every call site of the same
# GitHub Action agrees on one ref", and the lint that enforces it
# (script/test/drivers/action_ref_agreement.sh).
#
# The defect this pins: `docker/build-push-action` was used at eleven
# call sites across .github/workflows/, five of them on `@v6` and six on
# `@v7`, so which major version built an image depended on which
# workflow ran. The split sat green for months because nothing compares
# refs ACROSS files -- actionlint validates each `uses:` in isolation,
# and dependabot, having had its v6 -> v7 pull request closed, never
# raises that version pair again, at any call site, ever. Closing a
# dependabot pull request is not deferring a bump; it is opting out of
# it permanently, and .github/dependabot.yml records nothing about it.
#
# Two claims, deliberately proved by two readers:
#
#   1. The REAL tree carries one ref per action. Proved by a small
#      pipeline written here, independent of the lint -- a lint that
#      agrees with itself proves nothing about the tree.
#   2. The LINT fails when they disagree. Proved against controlled
#      fixtures, because the live tree can only ever show the passing
#      case once it is fixed.
#
# Shape mirrors self_hosted_guard_lint_spec.bats: a scratch REPO_ROOT
# for the detection cases, then the real tree at the end.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  WF_DIR="/source/.github/workflows"
  DRIVER="/source/script/test/drivers/action_ref_agreement.sh"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the lint runs against a controlled scratch tree.
  if [[ -f "${DRIVER}" ]]; then
    # shellcheck disable=SC1091
    source /source/dist/script/docker/lib/_lib.sh
    _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
    # shellcheck disable=SC1090
    source "${DRIVER}"
  fi

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/.github/workflows"
  REPO_ROOT="${SCRATCH}"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _require_driver -- the lint has to exist before any case below can say
# anything. Spelled as an assertion rather than a `skip` so its absence
# is a red test, not a silently green suite.
_require_driver() {
  declare -F _run_action_ref_agreement >/dev/null \
    || fail "no action-ref-agreement lint at ${DRIVER}: nothing in the tree compares one action's refs across workflows, so a partial bump stays green exactly the way the v6/v7 split did"
}

# _workflow <name> <line>... -- create a workflow fixture.
_workflow() {
  local _name="${1}"; shift
  printf '%s\n' "$@" > "${SCRATCH}/.github/workflows/${_name}"
}

# ── The real tree: one ref per action ──────────────────────────────

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
  assert_spec_subject_dir "${WF_DIR}" \
      "the workflow tree every uses: ref in this spec is read from"
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

# ── The lint: detection ────────────────────────────────────────────

@test "_run_action_ref_agreement: FAILS when two workflows disagree on an action's ref (#949)" {
  _require_driver
  _workflow a.yaml 'jobs:' '  a:' '    steps:' '      - uses: docker/build-push-action@v6'
  _workflow b.yaml 'jobs:' '  b:' '    steps:' '      - uses: docker/build-push-action@v7'

  run _run_action_ref_agreement
  assert_failure
}

@test "_run_action_ref_agreement: names the action, both refs and every call site (#949)" {
  _require_driver
  _workflow a.yaml 'jobs:' '  a:' '    steps:' '      - uses: docker/build-push-action@v6'
  _workflow b.yaml 'jobs:' '  b:' '    steps:' '      - uses: docker/build-push-action@v7'

  run _run_action_ref_agreement
  assert_failure
  assert_output --partial 'docker/build-push-action'
  assert_output --partial 'v6'
  assert_output --partial 'v7'
  assert_output --partial '.github/workflows/a.yaml:4'
  assert_output --partial '.github/workflows/b.yaml:4'
}

@test "_run_action_ref_agreement: PASSES when every call site agrees (#949)" {
  _require_driver
  _workflow a.yaml 'jobs:' '  a:' '    steps:' '      - uses: docker/build-push-action@v7'
  _workflow b.yaml 'jobs:' '  b:' '    steps:' '      - uses: docker/build-push-action@v7'

  run _run_action_ref_agreement
  assert_success
  assert_output --partial 'action ref agreement lint: clean'
}

@test "_run_action_ref_agreement: FAILS when two entry points of ONE action repo disagree (#949)" {
  # `actions/cache/save` and `actions/cache/restore` are two paths inside
  # one repository, and a ref is a tag on that repository -- so they are
  # one versioned thing, and the identity the lint groups by has to drop
  # the sub-path. Grouping by the full `uses:` string would call this
  # pair agreement.
  _require_driver
  _workflow a.yaml 'jobs:' '  a:' '    steps:' \
    '      - uses: actions/cache/save@v6' \
    '      - uses: actions/cache/restore@v7'

  run _run_action_ref_agreement
  assert_failure
  assert_output --partial 'actions/cache'
}

@test "_run_action_ref_agreement: reads the block uses: form, not only the compact one (#949)" {
  _require_driver
  _workflow a.yaml 'jobs:' '  a:' '    steps:' \
    '      - name: Build' \
    '        uses: docker/build-push-action@v6'
  _workflow b.yaml 'jobs:' '  b:' '    steps:' '      - uses: docker/build-push-action@v7'

  run _run_action_ref_agreement
  assert_failure
  assert_output --partial 'docker/build-push-action'
}

@test "_run_action_ref_agreement: ignores a local ./ call, which carries no ref (#949)" {
  _require_driver
  _workflow a.yaml 'jobs:' '  a:' '    uses: ./.github/workflows/build-worker.yaml'
  _workflow b.yaml 'jobs:' '  b:' '    steps:' '      - uses: docker/build-push-action@v7'

  run _run_action_ref_agreement
  assert_success
}

@test "_run_action_ref_agreement: ignores a commented-out uses line (#949)" {
  _require_driver
  _workflow a.yaml 'jobs:' '  a:' '    steps:' \
    '      # - uses: docker/build-push-action@v6' \
    '      - uses: docker/build-push-action@v7'

  run _run_action_ref_agreement
  assert_success
}

@test "_run_action_ref_agreement: strips a trailing comment, so an annotated sha pin still compares (#949)" {
  # The repo's one sha-pinned action carries its human-readable tag as a
  # trailing comment. Left unstripped, the comment becomes part of the
  # ref and every such pin looks like its own version.
  _require_driver
  _workflow a.yaml 'jobs:' '  a:' '    steps:' \
    '      - uses: dataaxiom/ghcr-cleanup-action@d52806a # v1.2.2'
  _workflow b.yaml 'jobs:' '  b:' '    steps:' \
    '      - uses: dataaxiom/ghcr-cleanup-action@d52806a'

  run _run_action_ref_agreement
  assert_success
}

@test "_run_action_ref_agreement: FAILS when a sha pin and a tag name the same action (#949)" {
  _require_driver
  _workflow a.yaml 'jobs:' '  a:' '    steps:' \
    '      - uses: dataaxiom/ghcr-cleanup-action@d52806a # v1.2.2'
  _workflow b.yaml 'jobs:' '  b:' '    steps:' \
    '      - uses: dataaxiom/ghcr-cleanup-action@v1.2.2'

  run _run_action_ref_agreement
  assert_failure
  assert_output --partial 'dataaxiom/ghcr-cleanup-action'
}

# ── The lint: the recorded exception ───────────────────────────────

@test "_run_action_ref_agreement: an allow marker carrying a reason excludes that call site (#949)" {
  # The escape hatch is deliberately a comment AT the call site, not a
  # config entry: the whole hazard is a divergence with no written
  # record, and a closed dependabot pull request is invisible precisely
  # because it lives nowhere in the tree. A marker here is a divergence
  # you read while looking at the line that diverges.
  _require_driver
  _workflow a.yaml 'jobs:' '  a:' '    steps:' \
    '      # action-ref-agreement: allow -- pinned until the runner image ships node 24' \
    '      - uses: docker/build-push-action@v6'
  _workflow b.yaml 'jobs:' '  b:' '    steps:' '      - uses: docker/build-push-action@v7'

  run _run_action_ref_agreement
  assert_success
  assert_output --partial '1 allowed'
}

@test "_run_action_ref_agreement: an allow marker with NO reason is itself a failure (#949)" {
  # A marker that only mutes is the closed-pull-request hazard rebuilt
  # inside the repo. The reason is the entire point of the mechanism.
  _require_driver
  _workflow a.yaml 'jobs:' '  a:' '    steps:' \
    '      # action-ref-agreement: allow' \
    '      - uses: docker/build-push-action@v6'
  _workflow b.yaml 'jobs:' '  b:' '    steps:' '      - uses: docker/build-push-action@v7'

  run _run_action_ref_agreement
  assert_failure
  assert_output --partial 'reason'
}

@test "_run_action_ref_agreement: an allow marker two comment lines above still applies (#949)" {
  _require_driver
  _workflow a.yaml 'jobs:' '  a:' '    steps:' \
    '      # action-ref-agreement: allow -- pinned until the runner image ships node 24' \
    '      # (revisit when the self-hosted fleet updates)' \
    '      - uses: docker/build-push-action@v6'
  _workflow b.yaml 'jobs:' '  b:' '    steps:' '      - uses: docker/build-push-action@v7'

  run _run_action_ref_agreement
  assert_success
}

@test "_run_action_ref_agreement: an allow marker does NOT leak to the next call site (#949)" {
  # An exception scoped to a comment block must end with that block, or
  # one recorded divergence quietly licenses every later one.
  _require_driver
  _workflow a.yaml 'jobs:' '  a:' '    steps:' \
    '      # action-ref-agreement: allow -- pinned until the runner image ships node 24' \
    '      - uses: docker/build-push-action@v6' \
    '      - uses: docker/build-push-action@v5'
  _workflow b.yaml 'jobs:' '  b:' '    steps:' '      - uses: docker/build-push-action@v7'

  run _run_action_ref_agreement
  assert_failure
  assert_output --partial 'v5'
}

# ── The lint: non-vacuity ──────────────────────────────────────────

@test "_run_action_ref_agreement: dies when .github/workflows/ is missing (#949)" {
  _require_driver
  rm -rf "${SCRATCH}/.github"

  run _run_action_ref_agreement
  assert_failure
  assert_output --partial 'vacuous'
}

@test "_run_action_ref_agreement: dies when the workflow directory holds no workflow (#949)" {
  _require_driver

  run _run_action_ref_agreement
  assert_failure
  assert_output --partial 'vacuous'
}

@test "_run_action_ref_agreement: dies when no workflow names a versioned action (#949)" {
  # A reader regression that stopped recognising `uses:` would report no
  # disagreement forever, in silence -- which is the failure this lint
  # exists to prevent, one level up.
  _require_driver
  _workflow a.yaml 'jobs:' '  a:' '    steps:' '      - run: echo hi'

  run _run_action_ref_agreement
  assert_failure
  assert_output --partial 'vacuous'
}

# ── The lint: the real tree ────────────────────────────────────────

@test "_run_action_ref_agreement: reports the real workflow tree clean (#949)" {
  _require_driver
  assert_spec_subject_dir "${WF_DIR}" \
      "the workflow tree every uses: ref in this spec is read from"
  REPO_ROOT="/source"

  run _run_action_ref_agreement
  assert_success
  assert_output --partial 'action ref agreement lint: clean'
}

# ── The lint: wiring ───────────────────────────────────────────────

@test "action-ref-agreement: is a member of the lint phase's tool table (#949)" {
  # A lint nobody runs is a comment. _LINT_TOOLS is the one table every
  # lint-phase caller dispatches through, and it is also what the
  # self-test.yaml completeness guard reads -- so membership here is what
  # makes the CI join mandatory rather than optional.
  #
  # PARSED, never sourced: sourcing test.sh drags in the whole lib chain,
  # which reads BASH_SOURCE unguarded, and under the kcov-instrumented
  # bash of the coverage shard that aborts.
  local _test_sh="/source/script/test/test.sh"
  assert_spec_subject "${_test_sh}" "the test runner whose _LINT_TOOLS table this lint joins"
  run awk '
    /^readonly _LINT_TOOLS=\(/ { inside = 1; next }
    inside && /^\)/            { inside = 0 }
    inside {
      sub(/#.*/, "")
      gsub(/[[:space:]]+/, "")
      if ($0 != "") print
    }
  ' "${_test_sh}"
  assert_success
  assert_line "action-ref-agreement"
}

@test "action-ref-agreement: has a lint-static CI join (#949)" {
  # Belt to the completeness guard's braces: that check proves EVERY
  # table entry has some join, this one names the join this lint needs --
  # a plain-runner matrix entry, because the driver is pure bash over the
  # checkout and touches no docker.
  local _wf="/source/.github/workflows/self-test.yaml"
  assert_spec_subject "${_wf}" "the workflow whose lint-static matrix this lint joins"
  run awk '/^  lint-static:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${_wf}"
  assert_success
  assert_output --partial '- action-ref-agreement'
}

@test "action-ref-agreement: its failure event id is registered (#949)" {
  # An unregistered event id is an anonymous exit: the log line carries
  # no name a reader can look up.
  run grep -qx 'ci_action_ref_agreement' /source/dist/script/docker/lib/log-events.txt
  assert_success
}
