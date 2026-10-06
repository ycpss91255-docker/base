#!/usr/bin/env bats
#
# ghcr_cleanup_yaml_spec.bats — structural assertions for this repo's GHCR
# package-DELETION surface.
#
# A workflow here DELETES package versions from a registry on a schedule.
# It cannot be exercised end to end from here: there is no local GHCR,
# and a real run's only honest test is a real run. What a spec CAN do is
# make the workflow's shape a gated invariant, so the ways this goes
# catastrophically wrong fail in CI instead of on ghcr.io.
#
# ── What the spec's SUBJECT is, and why it is derived ─────────────────
#
# The subject is DERIVED from `.github/workflows/`, not written here: a
# workflow is a DELETION SURFACE if, on a code line, it performs a GHCR
# package-version deletion — it calls one of the package-pruning actions,
# or it hand-rolls the packages-API `DELETE`. The classification keys on
# the OPERATION, exactly as `ghcr_publish_surface_spec.bats` (base#1186)
# classifies a publisher by the push it performs.
#
# It used to be a declared path. That is the defect base#1089 is about,
# and it had two halves. The first was a fail-open precondition
# (`[[ -f "${WF}" ]] || skip`), which turned all 22 cases into
# `ok ... # skip` the moment the file moved; base#953 closed that half
# with `assert_spec_subject`. The second half survived it: a DECLARED
# path scopes every assertion below to one FILENAME, while the hazard
# belongs to the OPERATION. Measured on 26ce9f9 — a second workflow
# carrying the base#813 footgun verbatim
# (`actions/delete-package-versions` with
# `delete-only-untagged-versions: true`) left the whole unit suite at
# `1..4552`, 4552 ok, 0 not ok, and the lint phase clean, because the
# case named "never uses actions/delete-package-versions" read one file
# and that file was still innocent.
#
# So the population is derived, and the derivation REFUSES two states
# rather than reporting over them:
#
#   * ZERO deletion surfaces. The workflow was deleted, renamed, or its
#     delete step was moved somewhere the scan does not recognise. A gate
#     over an empty population is not a passing gate, it is no gate
#     (design principle P3), and this is the shape base#1089, base#1115,
#     base#1108 and base#1090 are all instances of.
#   * MORE THAN ONE deletion surface. The property cases below read ONE
#     file, so a second one would inherit a gate nobody applied to it. It
#     is also a hazard in its own right: the concurrency group that
#     serialises deletion is per-workflow, so two deletion workflows do
#     not serialise against each other, and two actors computing
#     candidate sets against a package the other is mutating is precisely
#     the state the concurrency case below exists to prevent. The refusal
#     says what to do — fold the step into the one deletion workflow, or
#     extend this spec to loop over the population.
#
# The residual cost is stated rather than hidden: a pruner this scan does
# not recognise by name, and a packages-API call assembled entirely out of
# expressions, are not seen. The recognised set is written once, below,
# with the reason each entry is in it, and the hand-rolled REST form is
# matched generically so a bespoke deleter does not need to be a known
# action to be caught.
#
# ── The four assertion classes, in descending cost if they stop holding
#
# 1. **The footgun.** `actions/delete-package-versions` with
#    `delete-only-untagged-versions` deletes the per-arch child
#    manifests of a LIVE tag, because it calls anything the packages
#    API reports as untagged a candidate without ever opening a
#    manifest. That breaks `docker pull <live tag>` with a 404. The spec
#    asserts that action appears in NO workflow here — the ban is
#    repo-wide, because the hazard is the action running at all — and
#    that the manifest-aware action is the one in use.
#
# 2. **The safety inputs.** `delete-untagged` is the only delete rule;
#    the tag-matching and partial-image rules stay off; `older-than`
#    keeps a retention window; `exclude-tags` preserves the tags
#    downstream consumers pin; `validate` reports a lost platform child
#    in the log. An edit that flips any of these is the edit this spec
#    exists to catch.
#
# 3. **Dry-run defaults.** Enforcement is opt-in via the
#    `GHCR_CLEANUP_ENFORCE` repository variable, so a scheduled run
#    deletes nothing until a human has read a dry run and enabled it.
#    An edit that hardcodes `dry-run: false` removes the whole rollout
#    safety net.
#
# 4. **Scope and pinning.** One package (`test-tools`), one owner, no
#    wildcard expansion; the action pinned to an immutable commit SHA
#    rather than a floating tag it does not control.
#
# why: Structural assertions for this repo's GHCR package-DELETION
# surface, DERIVED from `.github/workflows/` by the deletion operation a
# workflow performs rather than read from a path written here — the same
# classify-by-operation shape `ghcr_publish_surface_spec.bats` uses for
# publishers. A scheduled job against a real registry cannot be exercised
# from here, so the spec pins the SHAPE, on the theory that the ways this
# goes catastrophically wrong are all edits to a workflow:
#
# - **The population.** A declared path scoped every assertion here to one
# FILENAME while the hazard belongs to the OPERATION: on 26ce9f9 a second
# workflow carrying the base#813 footgun verbatim left the unit suite at
# 4552 ok, 0 not ok (base#1089). The scan now reports every workflow that
# deletes package versions, and REFUSES both an empty population (a gate
# over nothing is no gate) and a second surface (the cases here read one
# file, and two deletion workflows do not serialise against each other).
#
# - **The footgun.** `actions/delete-package-versions` with
# `delete-only-untagged-versions` calls anything the packages API reports
# as untagged a candidate without opening a manifest, so it deletes the
# per-arch children of a LIVE tag and `docker pull` starts 404ing. The ban
# is repo-wide; comment lines are dropped first, because the workflow's own
# header names both on purpose, to say why they are absent.
#
# - **The safety inputs.** `delete-untagged` is the only delete rule
# enabled, `older-than` keeps a retention window, `exclude-tags` preserves
# the tags downstream Dockerfiles pin, `validate` surfaces a lost platform
# child in the log, and the tagged / partial-image rules stay off.
#
# - **Dry-run defaults.** Enforcement is opt-in through the
# `GHCR_CLEANUP_ENFORCE` repository variable, so a scheduled run deletes
# nothing until a human has read a dry run. `dry-run` is resolved in a step
# rather than an `a && b || c` expression, because that idiom collapses to
# `c` exactly on the dispatch-with-dry-run-false branch.
#
# - **Scope and pinning.** One owner, one package, no wildcard expansion;
# the action pinned to an immutable commit SHA rather than a floating tag a
# third party can move under a job holding `packages: write`.

bats_require_minimum_version 1.5.0

# The GHCR pruning actions this scan recognises, matched on the `uses:`
# line so a workflow's prose about one of them is not a call to it, and so
# the cleanup workflow's own `group: ghcr-cleanup-test-tools` is not
# mistaken for the action whose name it echoes.
#
# Why each entry is here:
#   delete-package-versions      the base#813 footgun itself — the first
#                                action anybody reaches for, and the one
#                                this whole spec exists because of.
#   ghcr-cleanup-action          the manifest-aware action this repo uses.
#   container-retention-policy   the other widely used GHCR pruner, so the
#                                obvious substitution is seen too.
#
# The owner is matched loosely (`<anything>/<name>@`) on purpose: a fork of
# the footgun deletes exactly what the original does. An optional quote
# after `uses:` is accepted in both styles, because a quoted scalar is an
# ordinary YAML spelling of the same call and the guard exists to catch a
# deleter added by accident, not one written in the idiom the guard happened
# to expect.
readonly _DELETION_ACTION="uses:[[:space:]]*['\"]?[A-Za-z0-9._-]+/(delete-package-versions|ghcr-cleanup-action|container-retention-policy)@"

# The hand-rolled form: a `DELETE` against the packages API. Matched as two
# independent per-FILE conditions rather than one per-line pattern, because
# a `gh api` call spreads the verb and the path over separate continued
# lines. Generic by design — a bespoke deleter does not have to be a known
# action to be reported.
#
# The leading slash is OPTIONAL: `gh api orgs/<org>/packages/...` is as valid
# as `gh api /orgs/...` and is the spelling GitHub's own examples use. What
# precedes the endpoint is therefore required to be a non-path character, so
# `superusers/x/packages/` is not read as `users/x/packages/`.
readonly _DELETION_API_PATH='(^|[^A-Za-z0-9._/-])/?(user|users/[^/[:space:]]+|orgs/[^/[:space:]]+)/packages/'
# The separator between the flag and its value is NOT part of the operation:
# `--method DELETE`, `--method=DELETE` and `-XDELETE` are one flag written
# three ways, and a pattern keyed on the whitespace reads the third as no
# deletion at all. Zero or more of space and `=` is deliberately permissive —
# over-matching a verb costs nothing, since a file is a surface only when it
# also carries the packages path.
readonly _DELETION_API_VERB='(--method|-X)[[:space:]=]*DELETE|method:[[:space:]]*.?DELETE'

# The footgun, named in two parts: the action, and the input that makes it
# destructive. Named separately so a swap back is caught even if either
# moves independently of the other.
readonly _FOOTGUN_ACTION='delete-package-versions'
readonly _FOOTGUN_INPUT='delete-only-untagged-versions'

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WF_DIR=/source/.github/workflows
  assert_spec_subject_dir "${WF_DIR}" \
      "the workflow directory whose GHCR deletion surfaces this spec derives"

  # The subject, DERIVED. A verdict that is not a single surface is this
  # spec's own failure, reported with its reason rather than skipped: the
  # cases below assert properties OF a deletion surface, and over zero of
  # them every one of them would pass for the wrong reason.
  local _verdict
  _verdict="$(_deletion_surface_verdict "${WF_DIR}")" || fail "${_verdict}"
  WF="${_verdict}"

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/wf"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _deletion_surfaces <dir>
#   Every workflow file in <dir> that, on a CODE line, performs a GHCR
#   package-version deletion, one path per line.
#
#   Comment lines are dropped before the match. The cleanup workflow's
#   header names the footgun action and its input in prose, to say why they
#   are absent, and this spec's header quotes the measurement that found
#   base#1089; a scan that could not tell prose from code would classify
#   the explanation as the thing it explains, and the reasoning would
#   become unwritable.
#
#   A file that cannot be READ contributes a `BUG:` line rather than being
#   skipped: a workflow the scan cannot parse is a workflow nothing below
#   gates, and that has to be loud. `code_lines` reserves status 2 for
#   exactly that reading and 1 for a file that was read and held no code.
_deletion_surfaces() {
  local _dir="${1}" _f _code _status
  while IFS= read -r _f; do
    [[ -n "${_f}" ]] || continue
    _status=0
    _code="$(code_lines "${_f}")" || _status=$?
    if [[ "${_status}" -gt 1 ]]; then
      printf 'BUG: %s\n' "${_code}"
      continue
    fi
    if printf '%s\n' "${_code}" | grep -qE "${_DELETION_ACTION}"; then
      printf '%s\n' "${_f}"
      continue
    fi
    if printf '%s\n' "${_code}" | grep -qE "${_DELETION_API_PATH}" \
        && printf '%s\n' "${_code}" | grep -qE "${_DELETION_API_VERB}"; then
      printf '%s\n' "${_f}"
    fi
  done <<< "$(workflow_files "${_dir}")"
}

# _deletion_surface_verdict <dir>
#   The ONE deletion surface in <dir> on stdout, status 0 — or, status 1,
#   the reason there is not exactly one.
#
#   A function with a status rather than a bare `fail` so the refusal itself
#   is testable: the two states it exists to refuse each have a case below,
#   and a refusal nothing exercises is the same unverified guard this spec
#   is a fix for.
_deletion_surface_verdict() {
  local _dir="${1}" _surfaces _n
  _surfaces="$(_deletion_surfaces "${_dir}")"
  if printf '%s\n' "${_surfaces}" | grep -q 'BUG:'; then
    printf 'the deletion-surface scan could not read part of %s: %s\n' \
        "${_dir}" "${_surfaces}"
    return 1
  fi
  _n="$(printf '%s\n' "${_surfaces}" | awk 'NF { n++ } END { print n + 0 }')"
  case "${_n}" in
    1)
      printf '%s\n' "${_surfaces}"
      return 0
      ;;
    0)
      printf 'no workflow in %s deletes GHCR package versions, so the assertions in this spec have no subject. The cleanup workflow was deleted, renamed, or its delete step moved to a form this scan does not recognise: restore it, or teach the scan the new operation. Failing rather than passing is deliberate -- a gate over an empty population is not a passing gate.\n' \
          "${_dir}"
      return 1
      ;;
    *)
      printf '%s workflows in %s delete GHCR package versions, and this spec asserts its safety properties against ONE:\n%s\nEach surface needs those properties, and two deletion workflows do not serialise against each other -- a concurrency group is per-workflow. Fold the delete step into the single deletion workflow, or extend this spec to loop over the population.\n' \
          "${_n}" "${_dir}" "${_surfaces}"
      return 1
      ;;
  esac
}

# _footgun_hits <dir> <pattern>
#   One `<file>: <line>` for every CODE line in every workflow under <dir>
#   that names <pattern>. The file is named because the ban is repo-wide:
#   "the footgun is somewhere in this directory" is not an actionable
#   failure, naming the workflow and the line is.
_footgun_hits() {
  local _dir="${1}" _pattern="${2}" _f _code _status _line
  while IFS= read -r _f; do
    [[ -n "${_f}" ]] || continue
    _status=0
    _code="$(code_lines "${_f}")" || _status=$?
    if [[ "${_status}" -gt 1 ]]; then
      printf 'BUG: %s\n' "${_code}"
      continue
    fi
    while IFS= read -r _line; do
      case "${_line}" in
        *"${_pattern}"*) printf '%s: %s\n' "${_f##*/}" "${_line}" ;;
      esac
    done <<< "${_code}"
  done <<< "$(workflow_files "${_dir}")"
}

# _wf <name> <line>... -- a workflow fixture, written verbatim.
_wf() {
  local _name="${1}"; shift
  printf '%s\n' "$@" > "${SCRATCH}/wf/${_name}.yaml"
}

# _code_lines -- the derived deletion surface with comment-only and blank
# lines dropped.
#
# The workflow's header comment names the unsafe action and its input on
# purpose, to say why they are absent. A naive `grep -F` over the whole
# file would therefore match the WARNING and report the footgun as present,
# so every must-not-appear assertion runs against this instead. Trailing
# comments on a real line (the `# v1.2.2` after the pin) survive, because
# that line is code. The stripping itself lives in test_helper.bash, where
# the whole workflow spec family shares one copy of it.
_code_lines() {
  code_lines "${WF}"
}

# _block <top-level-key> -- the body of a top-level mapping (`on`,
# `permissions`, `concurrency`), comment and blank lines dropped. The
# stripping matters: a comment paragraph sitting between two top-level
# keys is not indented-out by the terminator, so without it a block would
# carry the prose that follows it.
_block() {
  yaml_top_lines "${WF}" "${1}"
}

# _with_block -- the `with:` mapping of the cleanup step, comments and
# blank lines stripped. Asserting against this rather than the whole file
# keeps a value that merely appears in the prose from satisfying a test
# about what the action is actually configured with.
_with_block() {
  awk '/^        with:$/{flag=1; next} /^[^ ]|^      - /{flag=0} flag' "${WF}" \
    | strip_comments
}

# _exclude_tags -- just the comma-separated value of `exclude-tags`, on
# one line, so a per-tag assertion can anchor on `,` and end-of-string
# instead of pattern-matching across a multi-line blob.
_exclude_tags() {
  _with_block | sed -n 's/^[[:space:]]*exclude-tags:[[:space:]]*//p'
}

# ── The scan classifies by operation ─────────────────────────────────

# why: The footgun in a workflow this spec never named is the live
# fail-open base#1089 measured: a declared path left it green
@test "GHCR deletion surface: a workflow calling the footgun action is a surface (#1089)" {
  # The measured defect, as a fixture: a second cleanup workflow carrying
  # `actions/delete-package-versions`. Under a declared path that file was
  # invisible and the suite stayed green; the scan reports it because the
  # OPERATION decides which files this spec is about.
  _wf purge \
    'name: GHCR test-tools purge' \
    'on:' \
    '  schedule:' \
    "    - cron: '41 4 * * 2'" \
    'jobs:' \
    '  purge:' \
    '    steps:' \
    '      - uses: actions/delete-package-versions@e5bc658cc4c965c472efe991f8beea3981499c55 # v5.0.0' \
    '        with:' \
    '          delete-only-untagged-versions: true'
  run _deletion_surfaces "${SCRATCH}/wf"
  assert_success
  assert_output "${SCRATCH}/wf/purge.yaml"
}

# why: The action this repo actually uses has to classify as a surface, or
# the live gate reads an empty population
@test "GHCR deletion surface: the manifest-aware cleanup action is a surface (#1089)" {
  # The other half of a usable rule: the shape this repo is SUPPOSED to
  # have must land in the population, or the live verdict refuses a tree
  # that is correct.
  _wf cleanup \
    'jobs:' \
    '  cleanup:' \
    '    steps:' \
    '      - uses: dataaxiom/ghcr-cleanup-action@d52806a0dc70b430571a37da1fde39733ffd640f # v1.2.2'
  run _deletion_surfaces "${SCRATCH}/wf"
  assert_success
  assert_output "${SCRATCH}/wf/cleanup.yaml"
}

# why: A hand-rolled packages-API DELETE deletes just as hard as an action
# does, and needs no third party to recognise
@test "GHCR deletion surface: a hand-rolled packages-API DELETE is a surface (#1089)" {
  # The generic arm. A bespoke `gh api` deleter is not a known action and
  # would be invisible to a name-only scan, so the verb and the packages
  # path are matched per file -- a continued `gh api` call puts them on
  # different lines.
  _wf bespoke \
    'jobs:' \
    '  prune:' \
    '    steps:' \
    '      - run: |' \
    '          gh api \' \
    '            --method DELETE \' \
    '            "/orgs/ycpss91255-docker/packages/container/test-tools/versions/${id}"'
  run _deletion_surfaces "${SCRATCH}/wf"
  assert_success
  assert_output "${SCRATCH}/wf/bespoke.yaml"
}

# why: `gh api` takes the endpoint with or without a leading slash, and the
# slashless spelling is the one in GitHub's own examples
@test "GHCR deletion surface: a packages-API DELETE with no leading slash is a surface (#1089)" {
  # `gh api orgs/...` is as valid as `gh api /orgs/...` and is what GitHub's
  # own documentation writes. A pattern that required the slash left the
  # slashless deleter out of the population entirely.
  _wf slashless \
    'jobs:' \
    '  prune:' \
    '    steps:' \
    '      - run: gh api --method DELETE orgs/ycpss91255-docker/packages/container/test-tools/versions/123'
  run _deletion_surfaces "${SCRATCH}/wf"
  assert_success
  assert_output "${SCRATCH}/wf/slashless.yaml"
}

# why: `--method=DELETE` is the same flag as `--method DELETE`, and a
# classifier keyed on the separator is keyed on nothing that matters
@test "GHCR deletion surface: an --method=DELETE packages call is a surface (#1089)" {
  # The attached-value spelling of the same flag, and the refusal it has to
  # produce: beside the one gated surface it makes the population two, which
  # is the state that must be reported rather than passed over.
  _wf cleanup \
    '      - uses: dataaxiom/ghcr-cleanup-action@d52806a0dc70b430571a37da1fde39733ffd640f # v1.2.2'
  _wf attached \
    'jobs:' \
    '  prune:' \
    '    steps:' \
    '      - run: gh api --method=DELETE orgs/ycpss91255-docker/packages/container/test-tools/versions/123'
  run _deletion_surfaces "${SCRATCH}/wf"
  assert_success
  assert_output --partial "${SCRATCH}/wf/attached.yaml"
  run _deletion_surface_verdict "${SCRATCH}/wf"
  assert_failure
  assert_output --partial '2 workflows in'
  assert_output --partial 'attached.yaml'
}

# why: `-XDELETE` is how the short flag is normally written, value attached
# with no separator at all
@test "GHCR deletion surface: an -XDELETE packages call is a surface (#1089)" {
  # The short flag with its value attached -- the spelling curl taught
  # everyone and the one a hand-rolled deleter is most likely to carry.
  _wf cleanup \
    '      - uses: dataaxiom/ghcr-cleanup-action@d52806a0dc70b430571a37da1fde39733ffd640f # v1.2.2'
  _wf short \
    'jobs:' \
    '  prune:' \
    '    steps:' \
    '      - run: gh api -XDELETE orgs/ycpss91255-docker/packages/container/test-tools/versions/123'
  run _deletion_surfaces "${SCRATCH}/wf"
  assert_success
  assert_output --partial "${SCRATCH}/wf/short.yaml"
  run _deletion_surface_verdict "${SCRATCH}/wf"
  assert_failure
  assert_output --partial '2 workflows in'
  assert_output --partial 'short.yaml'
}

# why: A quoted `uses:` is an ordinary YAML spelling of the same call, and a
# classifier that reads one quote style is a classifier with a hole
@test "GHCR deletion surface: a double-quoted action reference is a surface (#1089)" {
  # The guard exists to catch a deleter added by accident, not one written
  # in the idiom the guard happened to expect. The OPERATION decides; the
  # quoting around the reference is not part of it.
  _wf quoted \
    'jobs:' \
    '  cleanup:' \
    '    steps:' \
    '      - uses: "dataaxiom/ghcr-cleanup-action@d52806a0dc70b430571a37da1fde39733ffd640f"' \
    '        with:' \
    '          delete-tags: "*"'
  run _deletion_surfaces "${SCRATCH}/wf"
  assert_success
  assert_output "${SCRATCH}/wf/quoted.yaml"
}

# why: The other quote style, pinned on its own so the match cannot quietly
# accept one and miss the other
@test "GHCR deletion surface: a single-quoted action reference is a surface (#1089)" {
  _wf squoted \
    'jobs:' \
    '  purge:' \
    '    steps:' \
    "      - uses: 'actions/delete-package-versions@e5bc658cc4c965c472efe991f8beea3981499c55'"
  run _deletion_surfaces "${SCRATCH}/wf"
  assert_success
  assert_output "${SCRATCH}/wf/squoted.yaml"
}

# why: The packages path alone is a READ; classifying it as a deletion
# surface would make listing versions a hazard
@test "GHCR deletion surface: reading the packages API is not a deletion (#1089)" {
  # Half the hand-rolled pattern is not the pattern. Listing versions is
  # what a dry run does, and a scan that called it a deletion would report
  # a second surface for a workflow that deletes nothing.
  _wf lister \
    'jobs:' \
    '  list:' \
    '    steps:' \
    '      - run: gh api "/orgs/ycpss91255-docker/packages/container/test-tools/versions"'
  run _deletion_surfaces "${SCRATCH}/wf"
  assert_success
  assert_output ''
}

# why: The cleanup workflow's header NAMES the footgun to say why it is
# absent; prose must not read as the operation it describes
@test "GHCR deletion surface: a comment naming a pruner is not a call to it (#1089)" {
  # The live workflow's header spells out `actions/delete-package-versions`
  # to explain why it is not used, and this spec's header quotes the
  # measurement. A scan that could not tell prose from code would classify
  # both as deletion surfaces and push authors to delete the reasoning.
  _wf prose \
    '# Deliberately NOT uses: actions/delete-package-versions@v5 --' \
    '# its delete-only-untagged-versions filter never opens a manifest.' \
    '#       --method DELETE /orgs/ycpss91255-docker/packages/container/x' \
    'name: Something else' \
    'jobs:' \
    '  build:' \
    '    steps:' \
    '      - run: docker pull ghcr.io/ycpss91255-docker/test-tools:main'
  run _deletion_surfaces "${SCRATCH}/wf"
  assert_success
  assert_output ''
}

# why: A consumer contributes no surface, or every workflow naming the
# package would be gated as a deleter
@test "GHCR deletion surface: a workflow that only pulls is not a surface (#1089)" {
  _wf consumer \
    'jobs:' \
    '  build:' \
    '    env:' \
    '      TEST_TOOLS_IMAGE: "ghcr.io/ycpss91255-docker/test-tools:main"' \
    '    steps:' \
    '      - run: docker pull "${TEST_TOOLS_IMAGE}"'
  run _deletion_surfaces "${SCRATCH}/wf"
  assert_success
  assert_output ''
}

# ── The verdict refuses the two states it cannot report over ──────────

# why: The load-bearing case: deleting the subject must be red, and under a
# declared path it was 22 green skips
@test "GHCR deletion surface: an empty population is refused, never passed (#1089)" {
  # base#1089's own verification, run as a test instead of by hand: with no
  # deletion surface in the tree there is nothing for the property cases to
  # be about, and every one of them would pass for the wrong reason. The
  # refusal names the three ways it happens.
  run _deletion_surface_verdict "${SCRATCH}/wf"
  assert_failure
  assert_output --partial 'no workflow in'
  assert_output --partial 'deletes GHCR package versions'
  assert_output --partial 'a gate over an empty population is not a passing gate'
}

# why: A second deleter would inherit a gate nobody applied to it, and two
# of them do not serialise against each other
@test "GHCR deletion surface: a second deletion surface is refused (#1089)" {
  # The property cases read ONE file. A second deletion workflow is
  # therefore ungated by construction -- and is a hazard on its own,
  # because a concurrency group is per-workflow, so two schedulers compute
  # candidate sets against a package the other is mutating.
  _wf cleanup \
    '      - uses: dataaxiom/ghcr-cleanup-action@d52806a0dc70b430571a37da1fde39733ffd640f # v1.2.2'
  _wf purge \
    '      - uses: actions/delete-package-versions@e5bc658cc4c965c472efe991f8beea3981499c55 # v5.0.0'
  run _deletion_surface_verdict "${SCRATCH}/wf"
  assert_failure
  assert_output --partial '2 workflows in'
  assert_output --partial 'cleanup.yaml'
  assert_output --partial 'purge.yaml'
}

# why: One surface is what a correct tree looks like, and the verdict has
# to name it rather than merely accept it
@test "GHCR deletion surface: exactly one surface resolves to that file (#1089)" {
  # The passing shape, pinned: the verdict IS the subject the property
  # cases run against, so it has to be the path and not merely a status.
  _wf cleanup \
    '      - uses: dataaxiom/ghcr-cleanup-action@d52806a0dc70b430571a37da1fde39733ffd640f # v1.2.2'
  run _deletion_surface_verdict "${SCRATCH}/wf"
  assert_success
  assert_output "${SCRATCH}/wf/cleanup.yaml"
}

# ── The live tree ────────────────────────────────────────────────────

# why: The non-vacuity case: an empty scan satisfies every refute here, so
# the population and the subject it resolved to are asserted
@test "GHCR deletion surface: the scan walked this repo and found the real one (#1089)" {
  # A `refute_output` passes whether the scan read every workflow or none
  # of them. Assert the population it walked, and that the surface it
  # resolved to is the workflow this repo actually deletes with -- the day
  # that stops being true this fails and says so instead of reporting a
  # clean surface it no longer looks at.
  local _n=0 _f
  while IFS= read -r _f; do
    [[ -n "${_f}" ]] || continue
    _n=$(( _n + 1 ))
  done <<< "$(workflow_files "${WF_DIR}")"
  [ "${_n}" -ge 5 ] || {
    echo "only ${_n} workflow(s) walked"
    return 1
  }
  [ "${WF}" = "${WF_DIR}/ghcr-cleanup.yaml" ] || {
    echo "the derived deletion surface is ${WF}, not the expected ghcr-cleanup.yaml"
    return 1
  }
}

# ── The footgun: the unsafe action must appear in NO workflow ─────────

# why: The unsafe action never returns: its untagged filter never opens a
# manifest, and a declared path left the ban scoped to one file
@test "GHCR deletion: no workflow here uses actions/delete-package-versions (#1089)" {
  # That action's untagged filter reads the packages API and never opens
  # a manifest, so it collects the per-arch children a live tag
  # references and breaks the tag. Repo-wide, because the hazard is the
  # action RUNNING -- which file it runs from is not the question.
  run _footgun_hits "${WF_DIR}" "${_FOOTGUN_ACTION}"
  assert_success
  assert_output ''
}

# why: The specific input that breaks live tags, named separately from the
# action and banned just as widely
@test "GHCR deletion: no workflow here sets delete-only-untagged-versions (#1089)" {
  # The specific input that makes the unsafe action destructive. Named
  # separately so a swap back is caught even if the action moves.
  run _footgun_hits "${WF_DIR}" "${_FOOTGUN_INPUT}"
  assert_success
  assert_output ''
}

# why: The repo-wide ban is worth exactly its ability to still see the
# footgun, and the live tree is clean so only a fixture can show it
@test "GHCR deletion: the footgun scan reports the workflow and the line (#1089)" {
  # The live cases above are `assert_output ''`, which an inert scan
  # satisfies. The fixture proves the scan bites and that its report is
  # actionable -- the file, and the line that carries it.
  _wf purge \
    '      - uses: actions/delete-package-versions@v5' \
    '        with:' \
    '          delete-only-untagged-versions: true'
  run _footgun_hits "${SCRATCH}/wf" "${_FOOTGUN_ACTION}"
  assert_success
  assert_output --partial 'purge.yaml: '
  assert_output --partial 'actions/delete-package-versions@v5'
  run _footgun_hits "${SCRATCH}/wf" "${_FOOTGUN_INPUT}"
  assert_success
  assert_output --partial 'delete-only-untagged-versions: true'
}

# why: The action that resolves manifest references is the one in use
@test "ghcr-cleanup.yaml: uses the manifest-aware dataaxiom/ghcr-cleanup-action" {
  run code_grep -F 'uses: dataaxiom/ghcr-cleanup-action@' "${WF}"
  assert_success
}

# ── Action pinning ───────────────────────────────────────────────────

# why: A moved tag would hand deletion rights over our package to unreviewed
# code
@test "ghcr-cleanup.yaml: pins the cleanup action to an immutable commit SHA" {
  # A floating tag on the one third-party action holding packages: write
  # over a package we publish means a moved tag hands deletion rights to
  # unreviewed code.
  run code_grep -E 'uses: dataaxiom/ghcr-cleanup-action@[0-9a-f]{40}( |$)' "${WF}"
  assert_success
}

# why: Keeps the SHA readable; the form Dependabot rewrites on bump
@test "ghcr-cleanup.yaml: records the pinned action's version in a trailing comment" {
  # Keeps the SHA readable and is the form Dependabot rewrites on bump.
  run code_grep -E 'uses: dataaxiom/ghcr-cleanup-action@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+' "${WF}"
  assert_success
}

# ── Safety inputs ────────────────────────────────────────────────────

# why: Untagged orphans are the only thing this job collects
@test "ghcr-cleanup.yaml: enables delete-untagged as the delete rule" {
  run _with_block
  assert_success
  assert_output --partial 'delete-untagged: true'
}

# why: `delete-tags` / ghost / partial / orphaned can remove TAGGED
# versions: absent
@test "ghcr-cleanup.yaml: leaves the tagged-image delete rules off" {
  # delete-tags / delete-ghost-images / delete-partial-images /
  # delete-orphaned-images can all remove TAGGED versions. Absent means
  # the action's own false default applies.
  run _with_block
  assert_success
  refute_output --partial 'delete-tags:'
  refute_output --partial 'delete-ghost-images:'
  refute_output --partial 'delete-partial-images:'
  refute_output --partial 'delete-orphaned-images:'
}

# why: Without it, a run overlapping a release eats the by-digest pushes
# pre-merge
@test "ghcr-cleanup.yaml: keeps a retention window via older-than" {
  # Without it, a cleanup overlapping a release deletes the by-digest
  # single-arch pushes before the merge job tags them.
  run _with_block
  assert_success
  assert_output --regexp 'older-than: [0-9]+ (day|days|week|weeks|month|months)'
}

# why: `latest`, `main` and the `v*` series are a strict preserve list
@test "ghcr-cleanup.yaml: preserves the tags downstream consumers pin" {
  # The three tag shapes release-test-tools.yaml publishes: the two
  # moving tags and the immutable release series.
  run _exclude_tags
  assert_success
  assert_output --regexp '(^|,)latest(,|$)'
  assert_output --regexp '(^|,)main(,|$)'
  assert_output --regexp '(^|,)v\*(,|$)'
}

# why: A lost platform child shows in the log, not at someone's `docker
# pull`
@test "ghcr-cleanup.yaml: enables the post-run multi-arch validate scan" {
  run _with_block
  assert_success
  assert_output --partial 'validate: true'
}

# ── Dry-run defaults ─────────────────────────────────────────────────

# why: The rollout safety net cannot be removed by flipping one literal
@test "ghcr-cleanup.yaml: dry-run is computed, never hardcoded false" {
  run _with_block
  assert_success
  refute_output --partial 'dry-run: false'
  assert_output --partial 'dry-run: ${{ steps.mode.outputs.dry-run }}'
}

# why: A manual run previews unless the operator asks otherwise
@test "ghcr-cleanup.yaml: workflow_dispatch dry-run input defaults to true" {
  run _block on
  assert_success
  assert_output --partial 'dry-run:'
  assert_output --partial 'default: true'
}

# why: An unfinished rollout costs sprawl, never a broken tag
@test "ghcr-cleanup.yaml: scheduled runs stay dry until GHCR_CLEANUP_ENFORCE opts in" {
  # Enforcement is opt-in, so forgetting the rollout review costs
  # continued sprawl rather than a broken tag.
  run code_grep -F 'vars.GHCR_CLEANUP_ENFORCE' "${WF}"
  assert_success
  run code_grep -F 'ENFORCE}" == "true"' "${WF}"
  assert_success
}

# why: Fail-safe, not fail-open: an unexpected input value resolves to
# dry-run
@test "ghcr-cleanup.yaml: a dispatch deletes only on a literal false, not on anything-but-true" {
  # Fail-safe rather than fail-open: the dispatch branch opts INTO
  # deleting on an exact `false` and treats every other value -- empty
  # included, which is what an input declaration change would produce --
  # as dry-run.
  run _code_lines
  assert_success
  assert_output --partial 'INPUT_DRY_RUN}" == "false"'
  refute_output --partial 'INPUT_DRY_RUN}" == "true"'
}

# why: `a && b || c` collapses to `c` on the one branch that deletes
@test "ghcr-cleanup.yaml: resolves dry-run in a step, not an && || expression" {
  # `a && b || c` collapses to `c` when b is false -- which here is the
  # dispatch-with-dry-run-false branch, the one case where getting it
  # wrong deletes what nobody asked to delete.
  run code_grep -E '^[[:space:]]+id: mode$' "${WF}"
  assert_success
  run _code_lines
  assert_success
  refute_output --partial 'inputs.dry-run ||'
}

# ── Scope ────────────────────────────────────────────────────────────

# why: One owner, one package: the one base publishes and owns
@test "ghcr-cleanup.yaml: targets exactly the test-tools package" {
  run _with_block
  assert_success
  assert_output --partial 'package: test-tools'
  assert_output --partial 'owner: ycpss91255-docker'
}

# why: `expand-packages` would widen this to every package in the org
@test "ghcr-cleanup.yaml: does not enable wildcard package expansion" {
  # expand-packages would let one edit widen this from base's own
  # package to every package in the org.
  run _code_lines
  assert_success
  refute_output --partial 'expand-packages'
}

# ── Trigger surface and permissions ──────────────────────────────────

# why: The job is scheduled, not merely dispatchable
@test "ghcr-cleanup.yaml: runs on a cron schedule" {
  run _block on
  assert_success
  assert_output --partial 'schedule:'
  assert_output --regexp "cron: '[0-9*]"
}

# why: GitHub delays scheduled runs that pile onto `:00`
@test "ghcr-cleanup.yaml: cron avoids the top of the hour" {
  # GitHub delays scheduled runs that pile onto :00.
  run _code_lines
  assert_success
  refute_output --regexp "cron: '0 "
}

# why: The dry-run review and one-off cleans need a manual entry point
@test "ghcr-cleanup.yaml: supports manual workflow_dispatch" {
  run _block on
  assert_success
  assert_output --partial 'workflow_dispatch:'
}

# why: Enough to delete package versions, no more
@test "ghcr-cleanup.yaml: declares packages: write and no broader write scope" {
  run _block permissions
  assert_success
  assert_output --partial 'packages: write'
  assert_output --partial 'contents: read'
  refute_output --partial 'contents: write'
}

# why: Two actors mutating the package concurrently, or a killed delete, is
# not a state to design for
@test "ghcr-cleanup.yaml: serialises runs and never cancels one mid-delete" {
  run _block concurrency
  assert_success
  assert_output --partial 'group:'
  assert_output --partial 'cancel-in-progress: false'
}
