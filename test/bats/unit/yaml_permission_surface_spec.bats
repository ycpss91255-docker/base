#!/usr/bin/env bats
#
# yaml_permission_surface_spec.bats -- unit tests for the DERIVED job and
# permission surfaces in test/bats/unit/test_helper.bash
# (yaml_job_names / yaml_job_permission_entries / yaml_permission_surface /
# reusable_workflow_files), and for the boundary yaml_job_text draws
# between two jobs.
#
# Every least-privilege guard in this repo is a scan over one of those four
# derivations, and every one of them is an assertion that the scan came back
# EMPTY. That shape has exactly one way to fail silently: a derivation that
# stops seeing part of the file reports the same empty result as a file with
# nothing wrong in it. So the derivations themselves need tests whose
# fixtures contain the elevation, and which fail when the elevation is not
# reported.
#
# The four spellings pinned below are not hypothetical. Each of them is a
# shape a real GitHub workflow may legitimately carry, and each made a whole
# job or a whole grant invisible to the hand-rolled awk these helpers used
# to be:
#
#   * a trailing comment on a job key (`sign-artifacts: # signs them`)
#     -- the job-key pattern was anchored at end of line, so the job was
#     not a job;
#   * a trailing comment or a quoted level on a permission entry
#     (`packages: write # cache push`, `packages: "write"`) -- an entry the
#     pattern did not match ENDED the block, dropping it and everything
#     after it;
#   * a job id that does not start with a lowercase letter (`Sign:`,
#     `_pub:`) -- both are legal ids, and neither terminated the previous
#     job, so the previous job reported the next one's grants as its own;
#   * `"on":` in quotes, or `on: {workflow_call: null}` in flow style --
#     the reusable-worker derivation matched `^on:` as text, so a worker
#     written either way was not a reusable worker and was scanned by
#     nothing.
#
# The fixtures are written to a scratch directory, never to the checkout:
# these are tests OF the extractor, so they need shapes the real workflows
# do not have.
#
# why: Unit tests for the DERIVED job and permission surfaces in
# `test/bats/unit/test_helper.bash` (`yaml_job_names` /
# `yaml_job_permission_entries` / `yaml_permission_surface` /
# `reusable_workflow_files`) and for the boundary `yaml_job_text` draws
# between two jobs.
#
# Every least-privilege guard in this repo is a scan over one of those
# derivations, and every one of them asserts the scan came back EMPTY -- so
# a derivation that stops seeing part of the file reports exactly what a
# clean file reports. The derivations therefore need tests whose fixtures
# CONTAIN the elevation and which fail when it is not reported.
#
# The four shapes pinned here are all legal GitHub workflow, and each made a
# whole job or a whole grant invisible to the hand-rolled awk these helpers
# used to be: a trailing comment on a job key (the key pattern was anchored
# at end of line, so the job was not a job); a trailing comment or a quoted
# level on a permission entry (an entry the pattern rejected ENDED the
# block, dropping it and everything after it, so whether an elevation was
# seen depended on where in the block it sat); a job id that does not begin
# with a lowercase letter (`Sign:`, `_pub:` did not terminate the job above
# them, which then reported their grants as its own); and `"on":` or a
# flow-style `on:` mapping (the reusable-worker derivation matched `^on:` as
# text, so a worker written either way was scanned by nothing). The helpers
# now query a YAML parser (`yq`, added to `dockerfile/Dockerfile.test-tools`
# as Alpine's `yq-go`), which also fails CLOSED: a file it cannot parse is a
# `BUG:` line and a non-zero status, where the awk simply produced a shorter
# answer.
#
# A fifth derivation joins them: `spec_permission_surface_subjects`, which
# answers "which workflow file is this spec's surface call applied TO". The
# class-level guard used to answer that with two independent substring
# questions of the same file -- does it contain the string
# `yaml_permission_surface`, and does it contain the worker's path -- so any
# spec answering both certified a worker whose surface it never reads.
# Appending one call about worker A to a spec that merely MENTIONS worker B
# certified B. The derivation resolves the call's own ARGUMENT (a literal,
# or a variable with exactly one unambiguous literal assignment in the same
# file), and everything it cannot resolve is reported as `UNRESOLVED:` or as
# `BUG:` rather than assumed either way.
#
# Which occurrences ARE call sites is decided by a lexer over the shell
# text, not by matching the name: an occurrence inside quotes, inside a
# heredoc BODY or after a word-initial `#` is text. The heredoc half is
# where that reading either holds or fails open, so it follows bash exactly
# -- a terminator may be bare, `\`-escaped or quoted with either character
# and is read literally; a body ends at a line that is EXACTLY the
# terminator (`<<-` strips leading TABS, nothing else does); `<<<` opens
# nothing and `<<` inside `$(( ))` is a shift; and a `<<` whose terminator
# this cannot read opens a heredoc no line closes, spending the rest of the
# file rather than handing a fixture body back as code.
#
# Fixtures are written to a scratch directory, never to the checkout: these
# are tests OF the extractor, so they need shapes the real workflows do not
# have. The fixtures' own `@test` headers are indented one space, because
# the doc count generator counts a spec's tests with `grep -c '^@test'`.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  SCRATCH="$(mktemp -d)"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _fixture <name> -- write the heredoc on stdin to <name> under SCRATCH and
# print its path.
_fixture() {
  local _path="${SCRATCH}/${1}"
  cat > "${_path}"
  printf '%s\n' "${_path}"
}

# ── job derivation: a job key the pattern must still see ──────────────

# why: `sign-artifacts: # signs the images` is a job. The old key pattern
# was anchored at end of line, so it was not one -- and its `packages:
# write` was scanned by nothing
@test "yaml_job_names: a trailing comment on the job key does not hide the job (#957)" {
  local _f
  _f="$(_fixture jobs-with-trailing-comment.yaml << 'YAML'
jobs:
  build:
    runs-on: ubuntu-latest
  sign-artifacts: # signs the images
    runs-on: ubuntu-latest
YAML
)"
  run yaml_job_names "${_f}"
  assert_success
  assert_output 'build
sign-artifacts'
}

# why: The same shape end to end: an elevation on a job the derivation
# cannot see is an elevation no assertion over the surface can fail on
@test "yaml_permission_surface: a job whose key carries a trailing comment reports its grants (#957)" {
  # The whole point of the surface: an elevation on a job the derivation
  # cannot see is an elevation no assertion over the surface can fail on.
  local _f
  _f="$(_fixture surface-with-trailing-comment.yaml << 'YAML'
jobs:
  build:
    permissions:
      contents: read
  sign-artifacts: # signs the images
    permissions:
      contents: write
      packages: write
YAML
)"
  run yaml_permission_surface "${_f}"
  assert_success
  assert_output 'build: contents: read
sign-artifacts: contents: write
sign-artifacts: packages: write'
}

# why: `Sign` and `_pub` are legal GitHub job ids and must appear in the
# derived list
@test "yaml_job_names: a job id that does not start with a lowercase letter is a job (#957)" {
  # `Sign` and `_pub` are both legal GitHub job ids.
  local _f
  _f="$(_fixture uppercase-job.yaml << 'YAML'
jobs:
  a:
    runs-on: ubuntu-latest
  Sign:
    runs-on: ubuntu-latest
  _pub:
    runs-on: ubuntu-latest
YAML
)"
  run yaml_job_names "${_f}"
  assert_success
  assert_output 'a
Sign
_pub'
}

# why: The mis-attribution is worse than a miss: the job with NO block of
# its own reported the next job's grants, so it looked bounded while it was
# the one running on the caller's whole token
@test "yaml_permission_surface: an uppercase-initial job does not lend its grants to the job above it (#957)" {
  # The mis-attribution is worse than a miss: the job with NO block of its
  # own reports the next job's grants, so it looks bounded while it is the
  # one running on the caller's whole token.
  local _f
  _f="$(_fixture uppercase-job-surface.yaml << 'YAML'
jobs:
  a:
    runs-on: ubuntu-latest
  Sign:
    permissions:
      contents: write
  _pub:
    permissions:
      packages: write
YAML
)"
  run yaml_permission_surface "${_f}"
  assert_success
  assert_output 'a: <no entries>
Sign: contents: write
_pub: packages: write'
}

# why: The boundary underneath that mis-attribution: the terminator is any
# two-space-indented key, not a lowercase-initial one (a two-space comment
# line still does not terminate)
@test "yaml_job_text: stops at a job key that does not start with a lowercase letter (#957)" {
  local _f
  _f="$(_fixture uppercase-job-text.yaml << 'YAML'
jobs:
  a:
    runs-on: ubuntu-latest
  Sign:
    runs-on: macos-latest
YAML
)"
  run yaml_job_text "${_f}" a
  assert_success
  assert_output --partial 'runs-on: ubuntu-latest'
  refute_output --partial 'macos-latest'
}

# why: An empty derivation satisfies every "the scan came back empty"
# assertion in the repo, so it may never be a silent success
@test "yaml_job_names: a file with no jobs: mapping fails loudly rather than returning nothing (#957)" {
  # An empty derivation satisfies every "the scan came back empty"
  # assertion in the repo, so it may never be a silent success.
  local _f
  _f="$(_fixture no-jobs.yaml << 'YAML'
on:
  push:
    branches: [main]
YAML
)"
  run yaml_job_names "${_f}"
  assert_failure
  assert_output --partial 'BUG:'
}

# ── permission entries: an entry the block must not end on ────────────

# why: `packages: write # cache push` is an entry. The old scanner read a
# line it could not match as the END of the block, dropping that entry and
# every one after it
@test "yaml_job_permission_entries: a trailing comment on an entry does not truncate the block (#957)" {
  local _f
  _f="$(_fixture entry-trailing-comment.yaml << 'YAML'
jobs:
  build:
    permissions:
      contents: read
      packages: write # needed for the registry cache
YAML
)"
  run yaml_job_permission_entries "${_f}" build
  assert_success
  assert_output 'contents: read
packages: write'
}

# why: `packages: "write"` is the same grant written differently; a text
# match on the level missed it
@test "yaml_job_permission_entries: a quoted level is still an entry (#957)" {
  local _f
  _f="$(_fixture entry-quoted-level.yaml << 'YAML'
jobs:
  build:
    permissions:
      contents: read
      packages: "write"
YAML
)"
  run yaml_job_permission_entries "${_f}" build
  assert_success
  assert_output 'contents: read
packages: write'
}

# why: Order-dependence is the tell of a scanner that ends its block on the
# first line it cannot read: the same entry was reported when it came last
# and swallowed the whole block when it came first
@test "yaml_job_permission_entries: an elevation is reported wherever it sits in the block (#957)" {
  # Order-dependence is the tell of a scanner that ends its block on the
  # first line it cannot read: the same entry was reported when it came
  # last and swallowed the whole block when it came first.
  local _f
  _f="$(_fixture entry-order.yaml << 'YAML'
jobs:
  build:
    permissions:
      packages: write # needed for the registry cache
      contents: read
YAML
)"
  run yaml_job_permission_entries "${_f}" build
  assert_success
  assert_output 'packages: write
contents: read'
}

# why: The fail-open direction as its own property: a file the extractor
# cannot parse must not reach a caller as a clean, under-reported grant set
@test "yaml_job_permission_entries: an unreadable file fails loudly instead of reporting a short block (#957)" {
  # The fail-open direction, stated as its own property: a file the
  # extractor cannot parse must not arrive at a caller as a clean,
  # under-reported grant set.
  local _f
  _f="$(_fixture unparsable.yaml << 'YAML'
jobs:
  build:
    permissions:
      contents: read
     packages: write
YAML
)"
  run yaml_job_permission_entries "${_f}" build
  assert_failure
  assert_output --partial 'BUG:'
}

# why: A spec naming a job that was renamed is a defect, not an absence --
# it must not return an empty entry set
@test "yaml_job_permission_entries: a job that is not in the file fails loudly (#957)" {
  local _f
  _f="$(_fixture missing-job.yaml << 'YAML'
jobs:
  build:
    permissions:
      contents: read
YAML
)"
  run yaml_job_permission_entries "${_f}" renamed
  assert_failure
  assert_output --partial 'BUG:'
}

# why: `permissions: read-all` / `permissions: {}` name no scope, so they
# bound nothing: the job has to be VISIBLE as unbounded rather than absent
# from the listing
@test "yaml_permission_surface: an inline permissions scalar surfaces as no entries (#957)" {
  # `permissions: read-all` names no scope, so it bounds nothing this
  # spec suite can assert against -- it has to be visible, not absent.
  local _f
  _f="$(_fixture inline-permissions.yaml << 'YAML'
jobs:
  build:
    permissions: read-all
  other:
    permissions: {}
YAML
)"
  run yaml_permission_surface "${_f}"
  assert_success
  assert_output 'build: <no entries>
other: <no entries>'
}

# ── reusable-worker derivation: every spelling of the trigger key ─────

# why: Quoting `on` is the standard workaround for YAML 1.1 reading it as a
# boolean, and what several formatters emit; the old `^on:` text anchor
# exempted such a worker from every least-privilege scan
@test "reusable_workflow_files: a worker spelling the trigger \"on\": is still a worker (#957)" {
  # `"on"` in quotes is the standard workaround for YAML 1.1 reading a
  # bare `on` as a boolean, and it is what several formatters emit.
  local _dir="${SCRATCH}/quoted"
  mkdir -p "${_dir}"
  cat > "${_dir}/quoted-on-worker.yaml" << 'YAML'
"on":
  workflow_call:
    inputs: {}
jobs:
  build:
    runs-on: ubuntu-latest
YAML
  run reusable_workflow_files "${_dir}"
  assert_success
  assert_output "${_dir}/quoted-on-worker.yaml"
}

# why: `on: {workflow_call: null}` is the same declaration in flow style
@test "reusable_workflow_files: a flow-style on mapping is still read (#957)" {
  local _dir="${SCRATCH}/flow"
  mkdir -p "${_dir}"
  cat > "${_dir}/flow-worker.yml" << 'YAML'
on: {workflow_call: null}
jobs:
  build:
    runs-on: ubuntu-latest
YAML
  run reusable_workflow_files "${_dir}"
  assert_success
  assert_output "${_dir}/flow-worker.yml"
}

# why: The other direction: a `push`-only workflow runs on its own repo's
# token and is not part of this population
@test "reusable_workflow_files: a workflow that is not callable is not listed (#957)" {
  local _dir="${SCRATCH}/plain"
  mkdir -p "${_dir}"
  cat > "${_dir}/push-only.yaml" << 'YAML'
on:
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
YAML
  run reusable_workflow_files "${_dir}"
  assert_success
  assert_output ''
}

# ── the file set both readings of the directory share ────────────────

# why: One reading of which files a workflow directory holds, so a third
# extension cannot reach the derivation and miss the cross-check that
# re-reads the same directory raw
@test "workflow_files: lists .yaml and .yml, and nothing else (#957)" {
  # The extension set is one reading, not two. reusable_workflow_files
  # globbed the directory, and the cross-check that re-reads the same
  # directory raw -- the one that catches a worker the trigger derivation
  # stopped seeing -- globbed it again with its own copy of the pair. A
  # directory that grew a third spelling would have been seen by one of
  # them and not the other, in exactly the direction that cross-check
  # exists to detect.
  local _dir="${SCRATCH}/wf"
  mkdir -p "${_dir}/nested"
  printf 'on:\n  push:\n' > "${_dir}/alpha.yaml"
  printf 'on:\n  push:\n' > "${_dir}/beta.yml"
  printf 'not a workflow\n' > "${_dir}/notes.md"
  run workflow_files "${_dir}"
  assert_success
  assert_output "${_dir}/alpha.yaml
${_dir}/beta.yml"
}

# why: The consequence of the shared reading: a worker written with the
# other extension is derived, because one place says which extensions a
# workflow file may carry
@test "reusable_workflow_files: draws its candidates from workflow_files (#957)" {
  # The consequence of the shared reading: a worker written with the OTHER
  # extension is derived, because there is only one place that says which
  # extensions a workflow file may carry.
  local _dir="${SCRATCH}/wf-yml"
  mkdir -p "${_dir}"
  printf 'on:\n  workflow_call:\n' > "${_dir}/gamma.yml"
  run reusable_workflow_files "${_dir}"
  assert_success
  assert_output "${_dir}/gamma.yml"
}

# why: A worker the derivation cannot parse is a worker nothing downstream
# scans, so it joins the listing as a `BUG:` line
@test "reusable_workflow_files: an unreadable workflow is reported, not skipped (#957)" {
  local _dir="${SCRATCH}/broken"
  mkdir -p "${_dir}"
  cat > "${_dir}/broken.yaml" << 'YAML'
on:
  workflow_call:
 inputs: {}
YAML
  run reusable_workflow_files "${_dir}"
  assert_output --partial 'BUG:'
}

# ── which FILE a spec's surface call is applied to ───────────────────
#
# The class-level guard in reusable_worker_permissions_spec asks "does some
# other spec pin this worker's grants". It used to ask that as two
# independent substring questions of the same file -- does it contain the
# string `yaml_permission_surface`, and does it contain the worker's path --
# which any spec satisfying both answered YES for a worker whose surface it
# never reads. Appending one call about worker A to a spec that merely
# MENTIONS worker B certified B. So the derivation below resolves the call's
# own ARGUMENT, and everything it cannot resolve is reported rather than
# assumed.
#
# The fixtures' own `@test` headers are indented by one space: the doc/test
# count generator counts a spec's tests with `grep -c '^@test'`, so a
# fixture written at column 0 would be counted as a test of this file.

# why: The defect the class-level guard shipped with: a spec that MENTIONS a
# worker and separately calls the surface on another one certified both. The
# subject is resolved from the call's own argument
@test "spec_permission_surface_subjects: a mentioned path is not a subject (#957)" {
  # The defect itself. The fixture names beta.yaml twice -- an assignment
  # and a call to another helper -- and applies the surface only to alpha.
  local _spec
  _spec="$(_fixture 'mentions_spec.bats' << 'SPEC'
setup() {
  WF="/fixture/workflows/alpha.yaml"
  OTHER="/fixture/workflows/beta.yaml"
}

 @test "beta yields jobs" {
  run yaml_job_names "${OTHER}"
}

 @test "alpha pins its grants" {
  run yaml_permission_surface "${WF}"
}
SPEC
)"
  run spec_permission_surface_subjects "${_spec}"
  assert_success
  assert_output '/fixture/workflows/alpha.yaml'
}

# why: A call site that names the workflow inline needs no resolution
@test "spec_permission_surface_subjects: a literal argument resolves to itself (#957)" {
  local _spec
  _spec="$(_fixture 'literal_spec.bats' << 'SPEC'
 @test "gamma pins its grants" {
  run yaml_permission_surface /fixture/workflows/gamma.yaml
}
SPEC
)"
  run spec_permission_surface_subjects "${_spec}"
  assert_success
  assert_output '/fixture/workflows/gamma.yaml'
}

# why: The shape the scanning specs use: the argument carries the
# substitution's closing paren and the line continues after it
@test "spec_permission_surface_subjects: reads a call inside a process substitution (#957)" {
  # The call shape the scanning specs use: the argument carries the
  # substitution's closing paren, and the line continues afterwards.
  local _spec
  _spec="$(_fixture 'procsub_spec.bats' << 'SPEC'
setup() {
  WF="/fixture/workflows/delta.yaml"
}

 @test "delta" {
  while IFS= read -r _line; do
    printf '%s\n' "${_line}"
  done < <(yaml_permission_surface "${WF}")
}
SPEC
)"
  run spec_permission_surface_subjects "${_spec}"
  assert_success
  assert_output '/fixture/workflows/delta.yaml'
}

# why: A prose paragraph naming a worker is not a pin -- the same reason
# every structural assertion here reads code lines
@test "spec_permission_surface_subjects: a path named only in a comment is not a subject (#957)" {
  local _spec
  _spec="$(_fixture 'comment_spec.bats' << 'SPEC'
# This spec is about /fixture/workflows/epsilon.yaml and its grants.
setup() {
  WF="/fixture/workflows/zeta.yaml"
}

 @test "zeta" {
  run yaml_permission_surface "${WF}"
}
SPEC
)"
  run spec_permission_surface_subjects "${_spec}"
  assert_success
  assert_output '/fixture/workflows/zeta.yaml'
}

# why: A generated fixture path is a legitimate subject that is no tracked
# workflow; it reads as UNRESOLVED, never as one of the paths the file
# happens to mention and never as nothing
@test "spec_permission_surface_subjects: an argument it cannot resolve says so (#957)" {
  # A generated fixture path is a legitimate subject that is not a tracked
  # workflow. It must read as UNRESOLVED -- never as one of the paths the
  # file happens to mention, and never as nothing at all, because a caller
  # that silently drops it cannot tell an unpinnable call from no call.
  local _spec
  _spec="$(_fixture 'unresolved_spec.bats' << 'SPEC'
setup() {
  WF="/fixture/workflows/eta.yaml"
}

 @test "a generated fixture" {
  local _f="${SCRATCH}/generated.yaml"
  run yaml_permission_surface "${_f}"
}
SPEC
)"
  run spec_permission_surface_subjects "${_spec}"
  assert_success
  assert_output 'UNRESOLVED: ${_f}'
}

# why: Two assignments and two literals: which one the call site saw is not
# decidable from the text, and guessing would certify a worker on a coin
# flip
@test "spec_permission_surface_subjects: an ambiguous variable is not resolved (#957)" {
  # Two assignments, two different literals: which one the call site saw is
  # not decidable from the text, and guessing either would certify a worker
  # on the strength of a coin flip.
  local _spec
  _spec="$(_fixture 'ambiguous_spec.bats' << 'SPEC'
setup() {
  WF="/fixture/workflows/theta.yaml"
}

teardown() {
  WF="/fixture/workflows/iota.yaml"
}

 @test "theta or iota" {
  run yaml_permission_surface "${WF}"
}
SPEC
)"
  run spec_permission_surface_subjects "${_spec}"
  assert_success
  assert_output 'UNRESOLVED: ${WF}'
}

# why: A call whose argument cannot be seen must not be dropped -- dropping
# it is how a spec that pins a worker stops counting as its pin
@test "spec_permission_surface_subjects: a call with no argument is a BUG line (#957)" {
  # A call this cannot see the argument of must not be dropped: dropping it
  # is exactly how a spec that pins a worker stops counting as its pin.
  # Written with printf rather than a heredoc, and deliberately: a heredoc
  # would put the argument-less call at the end of a CODE line of THIS
  # spec, where the same derivation would read it as this file's own
  # unreadable call site. Ending the line with the closing quote keeps the
  # shape inside the fixture and out of the fixture's author.
  local _spec="${SCRATCH}/noarg_spec.bats"
  printf '%s\n' \
    ' @test "piped" {' \
    "  printf '%s' /fixture/workflows/kappa.yaml | xargs yaml_permission_surface" \
    '}' > "${_spec}"
  run spec_permission_surface_subjects "${_spec}"
  assert_failure
  assert_output --partial 'BUG:'
}

# why: The status splits "read, no call site" from "not read", so a caller
# cannot count an unreadable spec as one that pins nothing
@test "spec_permission_surface_subjects: a spec that never calls it prints nothing and exits 1 (#957)" {
  local _spec
  _spec="$(_fixture 'silent_spec.bats' << 'SPEC'
 @test "unrelated" {
  run yaml_job_names /fixture/workflows/lambda.yaml
}
SPEC
)"
  run spec_permission_surface_subjects "${_spec}"
  [ "${status}" -eq 1 ] \
    || fail "expected 1 (read, no call site), got ${status}"
  assert_output ''
}

# why: The other half of that split, and the one that would otherwise shrink
# the certified population silently
@test "spec_permission_surface_subjects: a spec it cannot read is a BUG line, not silence (#957)" {
  run spec_permission_surface_subjects "${SCRATCH}/no-such-spec.bats"
  [ "${status}" -eq 2 ] \
    || fail "expected 2 (not read), got ${status}"
  assert_output --partial 'BUG:'
}

# ── an occurrence that is not a call ────────────────────────────────
#
# The derivation above resolves an ARGUMENT, which closed "a spec that
# merely names a worker". It left the mirror open: text that is not a CALL
# at all -- a path inside a quoted string, a path inside a heredoc BODY, a
# path after a trailing `#` -- still looked like `<name> <token>` on a code
# line, so it resolved to a subject and certified a worker whose surface
# nothing reads. The heredoc case is not hypothetical: the fixtures in this
# very file are heredocs carrying that exact call shape, and only the
# ambiguity of their `WF` kept them from certifying a real workflow.
#
# So the shell text is read the way a shell reads it: an occurrence counts
# as a call site only where quoting, a heredoc body and a comment say it is
# code.

# why: A quoted occurrence is text, not a call -- and a path in a message
# string certified a worker nothing reads
@test "spec_permission_surface_subjects: a path inside a double-quoted string is not a subject (#957)" {
  local _spec
  _spec="$(_fixture 'quoted_spec.bats' << 'SPEC'
 @test "prints its own usage" {
  run printf '%s\n' "usage: yaml_permission_surface /fixture/workflows/mu.yaml"
}
SPEC
)"
  run spec_permission_surface_subjects "${_spec}"
  [ "${status}" -eq 1 ] \
    || fail "expected 1 (read, no call site), got ${status} with output: ${output}"
  assert_output ''
}

# why: The other spelling of the same shape, so a resolver that learns only
# about double quotes cannot pass
@test "spec_permission_surface_subjects: a path inside a single-quoted string is not a subject (#957)" {
  # The other spelling of the same shape. A resolver that learns only about
  # double quotes reports this one as a call site, so both are pinned.
  local _spec
  _spec="$(_fixture 'squoted_spec.bats' << 'SPEC'
 @test "prints its own usage" {
  run printf '%s\n' 'usage: yaml_permission_surface /fixture/workflows/nu.yaml'
}
SPEC
)"
  run spec_permission_surface_subjects "${_spec}"
  [ "${status}" -eq 1 ] \
    || fail "expected 1 (read, no call site), got ${status} with output: ${output}"
  assert_output ''
}

# why: A heredoc body is data the spec writes, not code it runs; this tree's
# own fixtures carry that exact call shape
@test "spec_permission_surface_subjects: a call inside a heredoc body is not a subject (#957)" {
  # A spec that WRITES another spec. The heredoc body is data this file
  # emits, not code this file runs, so the worker it names is pinned by
  # nothing here -- while the call on the last line is a real one.
  local _spec
  _spec="$(_fixture 'heredoc_spec.bats' << 'SPEC'
setup() {
  WF="/fixture/workflows/xi.yaml"
}

 @test "writes a spec and reads a surface" {
  cat > "${SCRATCH}/inner_spec.bats" << 'INNER'
 @test "omicron pins its grants" {
  run yaml_permission_surface /fixture/workflows/omicron.yaml
}
INNER
  run yaml_permission_surface "${WF}"
}
SPEC
)"
  run spec_permission_surface_subjects "${_spec}"
  assert_success
  assert_output '/fixture/workflows/xi.yaml'
}

# why: `code_lines` drops comment-ONLY lines by design, so a trailing
# comment reaches the derivation and the shell's word-initial `#` rule
# decides it
@test "spec_permission_surface_subjects: a path after a trailing # is not a subject (#957)" {
  # `code_lines` drops comment-ONLY lines, deliberately: a `#` after code
  # may be inside a string. So a trailing comment reaches this derivation,
  # and the shell rule -- a `#` that STARTS a word opens a comment -- is
  # what decides it here.
  local _spec
  _spec="$(_fixture 'trailing_comment_spec.bats' << 'SPEC'
setup() {
  WF="/fixture/workflows/pi.yaml"
}

 @test "pi" {
  run yaml_job_names "${WF}"  # yaml_permission_surface /fixture/workflows/sigma.yaml
}
SPEC
)"
  run spec_permission_surface_subjects "${_spec}"
  [ "${status}" -eq 1 ] \
    || fail "expected 1 (read, no call site), got ${status} with output: ${output}"
  assert_output ''
}

# why: The over-strict failure is the same defect with the sign flipped: `$(
# )` opened inside a double-quoted assignment is build_worker_yaml_spec's
# own shape
@test "spec_permission_surface_subjects: a call inside a command substitution IS a subject (#957)" {
  # The over-strict failure is the same defect with the sign flipped. This
  # is build_worker_yaml_spec's own shape -- a `$( )` opened inside a
  # double-quoted assignment -- and a resolver that treats every character
  # after a `"` as string text would drop the pin that certifies today's
  # most-scanned worker.
  local _spec
  _spec="$(_fixture 'cmdsub_spec.bats' << 'SPEC'
setup() {
  WF="/fixture/workflows/rho.yaml"
}

 @test "rho" {
  local _out
  _out="$(yaml_permission_surface "${WF}" | head -1)"
  [ -n "${_out}" ]
}
SPEC
)"
  run spec_permission_surface_subjects "${_spec}"
  assert_success
  assert_output '/fixture/workflows/rho.yaml'
}

# The three shapes below are the same defect as the ones above with the
# terminator, rather than the quoting, misread: a heredoc this reader does
# not OPEN, or one it CLOSES early, hands a fixture body back as code, and
# a path a spec merely writes into a fixture certifies the worker it names.
# The fourth is that defect with the sign flipped -- a `<<` that is not a
# heredoc at all swallows the rest of the file, so a real call site stops
# counting as the pin it is.

# why: bash quotes a terminator three ways and `<<\INNER` is the third.
# Reading no terminator opened no heredoc and emitted the body as code, so a
# worker named only in a fixture the spec WRITES was certified
@test "spec_permission_surface_subjects: a backslash-quoted heredoc body is not code (#957)" {
  # `<<\INNER` is bash's third spelling of a QUOTED terminator, beside
  # `<< 'INNER'` and `<< "INNER"`. A reader that knows only the other two
  # reads no terminator, opens no heredoc, and emits the whole body as
  # code -- so the worker named in the fixture this spec WRITES is
  # certified by a file that never reads it.
  local _spec
  _spec="$(_fixture 'bslash_heredoc_spec.bats' << 'SPEC'
setup() {
  WF="/fixture/workflows/upsilon.yaml"
}

 @test "writes a spec and reads a surface" {
  cat > "${SCRATCH}/inner_spec.bats" <<\INNER
 @test "phi pins its grants" {
  run yaml_permission_surface /fixture/workflows/phi.yaml
}
INNER
  run yaml_permission_surface "${WF}"
}
SPEC
)"
  run spec_permission_surface_subjects "${_spec}"
  assert_success
  assert_output '/fixture/workflows/upsilon.yaml'
}

# why: A body ends at a line that is EXACTLY the terminator (`<<-` strips
# leading TABS, never spaces). Trimming the line first ended the body at the
# fixture's own indented mention of it and read the rest as code
@test "spec_permission_surface_subjects: an indented terminator does not end a heredoc (#957)" {
  # bash ends a `<<WORD` body at a line that is EXACTLY WORD -- column 0,
  # no trailing blank (`<<-WORD` strips leading TABS, never spaces). A
  # reader that trims the line before comparing ends the body at the
  # fixture's own indented mention of it and reads the remainder as code.
  local _spec
  _spec="$(_fixture 'indented_terminator_spec.bats' << 'SPEC'
setup() {
  WF="/fixture/workflows/chi.yaml"
}

 @test "writes a spec and reads a surface" {
  cat > "${SCRATCH}/inner_spec.bats" << 'INNER'
 @test "psi pins its grants" {
   INNER
  run yaml_permission_surface /fixture/workflows/psi.yaml
}
INNER
  run yaml_permission_surface "${WF}"
}
SPEC
)"
  run spec_permission_surface_subjects "${_spec}"
  assert_success
  assert_output '/fixture/workflows/chi.yaml'
}

# why: The unreadable case stated as a direction: a `<<` this cannot finish
# reading still opens a heredoc, one no line closes. It spends the rest of
# the file, which fails loudly, rather than handing a fixture body back as
# code
@test "spec_permission_surface_subjects: a terminator it cannot read opens an unmatchable heredoc (#957)" {
  # A `<<` whose terminator this cannot read -- here one carried onto the
  # next line by a `\` continuation -- is still a heredoc. Opening one
  # whose terminator nothing matches costs the rest of the file, which
  # reads as UNPINNED and fails loudly; declining to open one hands the
  # body back as code, which certifies a worker nothing reads.
  local _spec
  _spec="$(_fixture 'unreadable_terminator_spec.bats' << 'SPEC'
 @test "writes a spec" {
  cat > "${SCRATCH}/inner_spec.bats" << \
INNER
 run yaml_permission_surface /fixture/workflows/omega.yaml
INNER
}
SPEC
)"
  run spec_permission_surface_subjects "${_spec}"
  [ "${status}" -eq 1 ] \
    || fail "expected 1 (read, no call site), got ${status} with output: ${output}"
  assert_output ''
}

# why: `$(( 1 << 2 ))` and `(( n <<= 1 ))` are shifts. Read as openers they
# made every later line data, so a spec that DOES pin its worker reported
# pinning nothing
@test "spec_permission_surface_subjects: an arithmetic left shift is not a heredoc (#957)" {
  # `$(( a << b ))` and `(( a <<= b ))` are shifts, not redirections. Read
  # as a heredoc opener, the operand becomes a terminator no line matches
  # and every later call site in the file is data -- so a spec that DOES
  # pin its worker reports pinning nothing.
  local _spec
  _spec="$(_fixture 'arith_shift_spec.bats' << 'SPEC'
 @test "counts, then reads a surface" {
  local _n=$(( 1 << 2 ))
  (( _n <<= 1 ))
  run yaml_permission_surface /fixture/workflows/tau.yaml
}
SPEC
)"
  run spec_permission_surface_subjects "${_spec}"
  assert_success
  assert_output '/fixture/workflows/tau.yaml'
}
