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

@test "spec_permission_surface_subjects: a call with no argument is a BUG line (#957)" {
  # A call this cannot see the argument of must not be dropped: dropping it
  # is exactly how a spec that pins a worker stops counting as its pin.
  local _spec
  _spec="$(_fixture 'noarg_spec.bats' << 'SPEC'
 @test "piped" {
  printf '%s\n' /fixture/workflows/kappa.yaml \
    | xargs yaml_permission_surface
}
SPEC
)"
  run spec_permission_surface_subjects "${_spec}"
  assert_failure
  assert_output --partial 'BUG:'
}

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

@test "spec_permission_surface_subjects: a spec it cannot read is a BUG line, not silence (#957)" {
  run spec_permission_surface_subjects "${SCRATCH}/no-such-spec.bats"
  [ "${status}" -eq 2 ] \
    || fail "expected 2 (not read), got ${status}"
  assert_output --partial 'BUG:'
}
