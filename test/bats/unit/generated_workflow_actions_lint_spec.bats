#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/generated_workflow_actions.sh -- the
# "a generated workflow's action refs stay in lockstep with this repo's
# own" lint.
#
# The gap this closes. dependabot reads WORKFLOW FILES. `init.sh` writes a
# workflow into every downstream repo from a heredoc, and a `uses:` ref
# inside a shell script is not a workflow file, so dependabot cannot see
# it. It is also outside the upstream-release watch, which declines
# `uses:` version refs precisely because they are dependabot's. And
# `init.sh` generates no dependabot config downstream, and skips the file
# when it already exists, so the downstream copy is never refreshed
# either. That ref is watched by nothing at all.
#
# It is not hypothetical. dependabot bumped actions/checkout 6 -> 7 across
# this repo's workflows on 2026-06-29; the generated workflow was written
# the NEXT day and says v7 only because it was authored after the bump.
# Nothing holds it there. The next bump edits the workflows, leaves the
# heredoc behind, and goes green.
#
# The fix has to be a lint in THIS repo rather than a lookup in init.sh:
# the `.base` subtree a downstream repo receives carries no
# `.github/workflows/`, so init.sh has nothing to read at generation
# time. Here, both files are present, and dependabot's own bump PR turns
# red until the heredoc is bumped with them -- which is the only way a ref
# dependabot structurally cannot parse ends up inside its reach.
#
# What "in lockstep" means, and why it is not "current". This lint owns no
# opinion about which version is right; dependabot owns that. It asserts
# only that the two copies agree, so the generated one inherits whatever
# dependabot decided for the real workflows.
#
# Detection runs against a controlled temp REPO_ROOT so the spec is
# independent of the live tree; a final case drives the REAL tree. Shape
# mirrors changelog_entry_lint_spec.bats / home_literal_lint_spec.bats.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the function runs against a controlled scratch tree.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }

  DRIVER=/source/script/test/drivers/generated_workflow_actions.sh

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/.github/workflows" "${SCRATCH}/dist"
  REPO_ROOT="${SCRATCH}"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _load_driver -- source the driver under test.
#
# Guarded rather than sourced in setup() so a missing driver reports the
# defect being tested ("nothing detects the drift") instead of erroring
# out as a harness failure with no statement of what is wrong.
_load_driver() {
  [[ -f "${DRIVER}" ]] || fail \
    "nothing holds a generated workflow's action refs in lockstep with this repo's own: ${DRIVER} does not exist"
  # shellcheck disable=SC1090
  source "${DRIVER}"
}

# _write_workflow <uses-line>... -- this repo's own workflow, whose refs
# are the ones dependabot maintains and the generated copy must match.
_write_workflow() {
  {
    printf 'name: Self Test\n'
    printf 'on: push\n'
    printf 'jobs:\n'
    printf '  build:\n'
    printf '    runs-on: ubuntu-latest\n'
    printf '    steps:\n'
    local _u
    for _u in "$@"; do
      printf '      - uses: %s\n' "${_u}"
    done
  } > "${SCRATCH}/.github/workflows/self-test.yaml"
}

# _write_generator <line>... -- a shell script that writes a workflow into
# a downstream repo from a heredoc, i.e. the shape dependabot cannot read.
_write_generator() {
  {
    printf '#!/usr/bin/env bash\n'
    printf '_gen() {\n'
    printf "  cat > \"\${_wf}\" <<'YAML'\n"
    printf 'jobs:\n'
    printf '  check:\n'
    printf '    steps:\n'
    [[ $# -gt 0 ]] && printf '%s\n' "$@"
    printf 'YAML\n'
    printf '}\n'
  } > "${SCRATCH}/dist/init.sh"
}

# ── The drift the lint exists to catch ──────────────────────────────────

@test "generated-workflow-actions: fails when a generated ref is behind this repo's own (#950)" {
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator '      - uses: actions/checkout@v7'

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  assert_output --partial 'actions/checkout'
  assert_output --partial 'v7'
  assert_output --partial 'v8'
  assert_output --partial 'dist/init.sh'
}

@test "generated-workflow-actions: names the generated ref's file and line (#950)" {
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator '      - uses: actions/checkout@v7'

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  assert_output --partial 'dist/init.sh:7'
}

@test "generated-workflow-actions: passes when the two copies agree (#950)" {
  _load_driver
  _write_workflow 'actions/checkout@v8' 'actions/upload-artifact@v7'
  _write_generator '      - uses: actions/checkout@v8'

  run _run_generated_workflow_actions
  [ "${status}" -eq 0 ]
  assert_output --partial 'clean'
}

@test "generated-workflow-actions: a ref ahead of this repo's own fails too (#950)" {
  # Direction-agnostic on purpose: the failure is disagreement, not
  # staleness. A generated copy edited past the workflows is the same
  # defect wearing the other sign, and it is the shape a hand-fix takes.
  _load_driver
  _write_workflow 'actions/checkout@v7'
  _write_generator '      - uses: actions/checkout@v8'

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  assert_output --partial 'actions/checkout'
}

# ── What is deliberately not a generated pin ────────────────────────────

@test "generated-workflow-actions: ignores an interpolated ref (#950)" {
  # `uses: ${SLUG}/.github/workflows/w.yaml@${ref}` is this repo calling
  # its OWN reusable workflow at the pinned subtree version. Both halves
  # are shell variables, there is no literal to compare, and upgrade.sh
  # already rewrites that ref on every subtree upgrade.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator \
    '      - uses: ${BASE_UPSTREAM_SLUG}/.github/workflows/build-worker.yaml@${ref}' \
    '      - uses: actions/checkout@v8'

  run _run_generated_workflow_actions
  [ "${status}" -eq 0 ]
}

@test "generated-workflow-actions: ignores a uses: ref inside a shell comment (#950)" {
  # Driver prose quotes `uses: owner/repo@ref` when explaining what it
  # scans. Prose is not a pin, and a lint that fails on its own
  # documentation gets muted.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  {
    printf '#!/usr/bin/env bash\n'
    printf '# A step is written `uses: actions/checkout@v1` in a workflow.\n'
    printf '   # indented prose about uses: actions/checkout@v2 as well\n'
  } > "${SCRATCH}/dist/init.sh"

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  # Fails because the tree holds NO generated ref at all, not because it
  # read either comment as one.
  refute_output --partial 'v1'
  refute_output --partial 'v2'
}

# ── The cases where there is no single ref to follow ────────────────────

@test "generated-workflow-actions: fails when this repo pins the action at two refs (#950)" {
  # With the workflows themselves disagreeing there is no answer to
  # "which ref should the generated copy carry", so the lint says that
  # rather than silently picking one.
  _load_driver
  _write_workflow 'docker/build-push-action@v6' 'docker/build-push-action@v7'
  _write_generator '      - uses: docker/build-push-action@v6'

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  assert_output --partial 'docker/build-push-action'
  assert_output --partial 'v6'
  assert_output --partial 'v7'
}

@test "generated-workflow-actions: fails when this repo never uses the generated action (#950)" {
  # An action this repo does not call itself has no dependabot PR to
  # inherit from, so the generated ref is pinned by nobody -- the exact
  # condition the lint exists to refuse, in its purest form.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator '      - uses: actions/setup-node@v3'

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  assert_output --partial 'actions/setup-node'
}

@test "generated-workflow-actions: refuses a tree it found no generated ref in (#950)" {
  # Reporting clean over a scan that read nothing is how a lint quietly
  # stops covering anything -- a renamed generator, a moved directory, a
  # matcher that stopped matching. Silence must not read as lockstep.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  assert_output --partial 'no generated'
}

# ── The real tree ───────────────────────────────────────────────────────

@test "generated-workflow-actions: the real repo is in lockstep (#950)" {
  _load_driver
  REPO_ROOT=/source

  run _run_generated_workflow_actions
  [ "${status}" -eq 0 ]
  assert_output --partial 'clean'
}
