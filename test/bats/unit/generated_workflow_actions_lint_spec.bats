#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/generated_workflow_actions.sh -- the
# "a generated workflow's action refs stay in lockstep with this repo's
# own" lint.
#
# The gap this closes. dependabot reads WORKFLOW FILES. `init.sh` writes a
# workflow into every downstream repo from a heredoc, and a `uses:` ref
# inside a shell script is not a workflow file, so dependabot cannot see
# it. It is outside `action-ref-agreement` too, which compares call sites
# within `.github/workflows/` and so cannot see a ref in a shell script.
# And `init.sh` generates no dependabot config downstream, and skips the file
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

# _write_generator_var <decl>... -- <uses line>... -- a generator that
# hoists its ref into a shell variable ABOVE an INTERPOLATING heredoc,
# which is the shape init.sh uses for the base-version-monitor workflow:
# the `uses:` line needs a declaration site of its own for a `tool-pin:`
# marker to attach to, so the ref moves one indirection away from the
# heredoc. The heredoc is unquoted here (`<<YAML`, not `<<'YAML'`)
# because that is what makes the variable expand into the generated file.
_write_generator_var() {
  local -a _decls=() _uses=()
  local _seen_sep=0 _a
  for _a in "$@"; do
    if [[ "${_a}" == '--' && "${_seen_sep}" -eq 0 ]]; then
      _seen_sep=1
      continue
    fi
    if [[ "${_seen_sep}" -eq 0 ]]; then
      _decls+=("${_a}")
    else
      _uses+=("${_a}")
    fi
  done
  {
    printf '#!/usr/bin/env bash\n'
    [[ ${#_decls[@]} -gt 0 ]] && printf '%s\n' "${_decls[@]}"
    printf '_gen() {\n'
    printf '  cat > "${_wf}" <<YAML\n'
    printf 'jobs:\n'
    printf '  check:\n'
    printf '    steps:\n'
    [[ ${#_uses[@]} -gt 0 ]] && printf '%s\n' "${_uses[@]}"
    printf 'YAML\n'
    printf '}\n'
  } > "${SCRATCH}/dist/init.sh"
}

# _write_own_reusable_workflow <basename> -- a worker workflow this repo
# ships itself, so a generated call to it is a call home rather than a
# marketplace action.
_write_own_reusable_workflow() {
  printf 'name: Worker\non: workflow_call\njobs:\n  w:\n    runs-on: ubuntu-latest\n' \
    > "${SCRATCH}/.github/workflows/${1}"
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

@test "generated-workflow-actions: ignores a call to a reusable workflow this repo ships (#950)" {
  # `${SLUG}/.github/workflows/build-worker.yaml@${ref}` is this repo
  # calling its OWN worker at the pinned subtree version. The exclusion is
  # keyed on the callee being a workflow FILE this repo ships, not on the
  # ref being interpolated: upgrade.sh rewrites `build-worker.yaml@vX.Y.Z`
  # in every downstream main.yaml on every upgrade, so that ref has an
  # owner. It is also not a marketplace action, so `.github/workflows/`
  # holds no ref for it to be in lockstep with -- this repo calls the same
  # worker locally, as `./`.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_own_reusable_workflow 'build-worker.yaml'
  _write_generator \
    '      - uses: ${BASE_UPSTREAM_SLUG}/.github/workflows/build-worker.yaml@${ref}' \
    '      - uses: actions/checkout@v8'

  run _run_generated_workflow_actions
  [ "${status}" -eq 0 ]
}

@test "generated-workflow-actions: a reusable workflow this repo does NOT ship is not excluded (#950)" {
  # The exclusion above is derived from the tree -- the callee has to be a
  # workflow this repo actually ships. A call to somebody else's reusable
  # workflow has no upgrade.sh rewrite behind it, so it stays in the
  # population and is refused when nothing can read it.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator \
    '      - uses: ${OTHER_SLUG}/.github/workflows/not-ours.yaml@${ref}' \
    '      - uses: actions/checkout@v8'

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  assert_output --partial 'not-ours.yaml'
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

# ── Unrecognised input must fail, not be skipped ────────────────────────
#
# The matcher decides the POPULATION, so anything it declines is a ref the
# lint stops covering in silence. Quoting a `uses:` value is legal YAML and
# legal Actions syntax, so a matcher that only reads bare values is
# narrower than "a `uses:` ref a shell script writes" -- the name it
# carries. These pin the two halves: a quoted ref is COMPARED like any
# other, and a value the matcher cannot resolve at all FAILS rather than
# passing.

@test "generated-workflow-actions: a double-quoted generated ref is compared, not skipped (#950)" {
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator '      - uses: "actions/checkout@v7"'

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  assert_output --partial 'actions/checkout'
  assert_output --partial 'v7'
  assert_output --partial 'v8'
}

@test "generated-workflow-actions: a single-quoted generated ref is compared, not skipped (#950)" {
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator "      - uses: 'actions/checkout@v7'"

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  assert_output --partial 'v7'
  assert_output --partial 'v8'
}

@test "generated-workflow-actions: a quoted ref to an action this repo never uses fails (#950)" {
  # The bare form of the defect, behind quotes: nothing bumps it, and the
  # quotes must not be what hides it.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator \
    '      - uses: "actions/setup-node@v1"' \
    '      - uses: actions/checkout@v8'

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  assert_output --partial 'actions/setup-node'
}

@test "generated-workflow-actions: one unreadable ref among readable ones still fails (#950)" {
  # The partial silent drop: a tree whose OTHER refs are in lockstep is
  # exactly where a skipped ref reports clean. The count backstop cannot
  # see this -- it only fires when every ref is unreadable.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator \
    '      - uses: actions/checkout@v8' \
    '      - uses: "actions/checkout@v3"'

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  assert_output --partial 'v3'
}

@test "generated-workflow-actions: a uses: value it cannot resolve fails by name (#950)" {
  # Not a versioned action, not a documented exclusion: refusing to guess
  # is the point, and the message has to say which line it could not read.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator \
    '      - uses: actions/checkout@v8' \
    '      - uses: not-an-action-reference'

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  assert_output --partial 'not-an-action-reference'
  assert_output --partial 'dist/init.sh'
}

@test "generated-workflow-actions: an unreadable value is reported as unreadable, not as an unused action (#950)" {
  # The three outcomes of _gwa_classify exist so that "excluded by name"
  # and "cannot read this at all" take OPPOSITE defaults. Collapsing them
  # is only half the risk; the other half is reporting one as the other.
  # An unreadable value carries a record with an EMPTY action field, and a
  # reader that drops that field silently re-routes the finding into the
  # "this repo never uses that action" branch -- a sentence about an
  # action nobody wrote, pointing at a fix that does not apply.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator \
    '      - uses: actions/checkout@v8' \
    '      - uses: not-an-action-reference'

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  assert_output --partial 'not a versioned action reference'
  refute_output --partial 'never uses'
}

@test "generated-workflow-actions: an action named with no ref is not called unused (#950)" {
  # `uses: actions/checkout` is unreadable -- there is no ref to compare --
  # but this repo plainly DOES use actions/checkout. Reporting it as an
  # action this repo never uses states something false about the tree and
  # sends the reader to the wrong file.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator \
    '      - uses: actions/checkout@v8' \
    '      - uses: actions/checkout'

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  assert_output --partial 'not a versioned action reference'
  refute_output --partial 'never uses actions/checkout'
}

@test "generated-workflow-actions: a local ./ callee is skipped by name, not by accident (#950)" {
  # `uses: ./.github/workflows/x.yaml` carries no ref: the callee is this
  # tree at this commit. A named exclusion, so it does not ride on the
  # matcher declining to match.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator \
    '      - uses: ./.github/workflows/local.yaml' \
    '      - uses: actions/checkout@v8'

  run _run_generated_workflow_actions
  [ "${status}" -eq 0 ]
}

@test "generated-workflow-actions: a docker:// container action is skipped by name (#950)" {
  # An image reference, not a repository tag: it has no <owner>/<repo>
  # reading for a workflow ref to agree with.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator \
    '      - uses: docker://alpine:3.21' \
    '      - uses: actions/checkout@v8'

  run _run_generated_workflow_actions
  [ "${status}" -eq 0 ]
}

@test "generated-workflow-actions: a quoted ref in this repo's own workflow is read too (#950)" {
  # The same matcher reads both sides. A quoted ref in .github/workflows/
  # dropped from the expected set turns a real disagreement into "this
  # repo never uses it", i.e. the right verdict for the wrong reason.
  _load_driver
  _write_workflow '"actions/checkout@v8"'
  _write_generator '      - uses: actions/checkout@v8'

  run _run_generated_workflow_actions
  [ "${status}" -eq 0 ]
}

@test "generated-workflow-actions: ignores a generator under .prev-release/ (#950)" {
  # The self-test materialises PAST releases into .prev-release/, and a
  # shipped release's refs are stale BY DEFINITION -- a release cannot be
  # re-pinned. Scanning it would mean the first dependabot bump after any
  # release fails a lint that no edit in the tree can satisfy.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator '      - uses: actions/checkout@v8'
  mkdir -p "${SCRATCH}/.prev-release/v0.1.0"
  printf '      - uses: actions/checkout@v6\n' \
    > "${SCRATCH}/.prev-release/v0.1.0/init.sh"

  run _run_generated_workflow_actions
  [ "${status}" -eq 0 ]
  assert_output --partial '1 generated ref'
}

# ── A ref one static indirection away ───────────────────────────────────
#
# "Interpolated from a shell variable" is not the same property as "cannot
# be known". A generator that hoists its ref into `readonly NAME='lit'`
# thirty lines above the heredoc -- which is what init.sh does, so the
# `uses:` line has a declaration site a `tool-pin:` marker can sit on --
# writes exactly the same ref into the generated workflow as if it had been
# spelled inline. Excluding it removes a ref from the population instead of
# checking it, which is the fail-open direction: the one ref this lint was
# built for stops being covered by the edit that documents it.
#
# So the reader resolves what is genuinely static, and refuses the rest.

@test "generated-workflow-actions: resolves a same-file readonly literal and compares it (#950)" {
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var \
    "readonly _MONITOR_REF='actions/checkout@v7'" \
    -- '      - uses: ${_MONITOR_REF}'

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  assert_output --partial 'actions/checkout'
  assert_output --partial 'v7'
  assert_output --partial 'v8'
}

@test "generated-workflow-actions: a resolved ref that agrees enters the population (#950)" {
  # Not just "does not fail": the ref has to be COUNTED. A resolved ref
  # that is silently dropped also passes, and the count is what separates
  # the two.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var \
    "readonly _MONITOR_REF='actions/checkout@v8'" \
    -- '      - uses: ${_MONITOR_REF}'

  run _run_generated_workflow_actions
  [ "${status}" -eq 0 ]
  assert_output --partial '1 generated ref'
}

@test "generated-workflow-actions: resolves a plain single-quoted assignment, not only readonly (#950)" {
  # `readonly` is a hardening detail of the declaration, not what makes the
  # value static. One assignment of a single-quoted literal is.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var \
    "_MONITOR_REF='actions/checkout@v7'" \
    -- '      - uses: ${_MONITOR_REF}'

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  assert_output --partial 'v7'
}

@test "generated-workflow-actions: resolves an unbraced \$NAME reference (#950)" {
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var \
    "readonly _MONITOR_REF='actions/checkout@v7'" \
    -- '      - uses: $_MONITOR_REF'

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  assert_output --partial 'v7'
}

@test "generated-workflow-actions: resolves the ref half alone (#950)" {
  # The variable need not be the whole value. `actions/checkout@${V}` is
  # the same static ref written differently.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var \
    "readonly _V='v7'" \
    -- '      - uses: actions/checkout@${_V}'

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  assert_output --partial 'v7'
}

@test "generated-workflow-actions: a resolved ref to an action this repo never uses still fails (#950)" {
  # Resolution feeds the ordinary comparison; it is not a bypass around it.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var \
    "readonly _MONITOR_REF='actions/setup-node@v3'" \
    -- '      - uses: ${_MONITOR_REF}'

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  assert_output --partial 'never uses'
  assert_output --partial 'actions/setup-node'
}

# ── Everything that is not genuinely static stays a FINDING ─────────────
#
# Each of these could be waved through as "interpolated, cannot know", and
# each would take a real pin out of the population. The safe default on an
# unrecognised shape is to refuse it, so it is reported with the raw value
# and the reader decides.

@test "generated-workflow-actions: a variable assigned twice is a finding, not an exclusion (#950)" {
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var \
    "_MONITOR_REF='actions/checkout@v7'" \
    "_MONITOR_REF='actions/checkout@v6'" \
    -- '      - uses: ${_MONITOR_REF}'

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  assert_output --partial 'not a versioned action reference'
  assert_output --partial '_MONITOR_REF'
}

@test "generated-workflow-actions: a variable assigned from a command substitution is a finding (#950)" {
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var \
    '_MONITOR_REF="$(cat .checkout-ref)"' \
    -- '      - uses: ${_MONITOR_REF}'

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  assert_output --partial 'not a versioned action reference'
  assert_output --partial '_MONITOR_REF'
}

@test "generated-workflow-actions: a variable assigned from another variable is a finding (#950)" {
  # `_A='actions/checkout@v7'` is static; `_B="${_A}"` is a second hop the
  # reader does not follow. Following one hop and refusing the next is the
  # line, and it is drawn where the value stops being visible in one place.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var \
    "_A='actions/checkout@v7'" \
    '_MONITOR_REF="${_A}"' \
    -- '      - uses: ${_MONITOR_REF}'

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  assert_output --partial 'not a versioned action reference'
}

@test "generated-workflow-actions: a double-quoted assignment with an interpolation is a finding (#950)" {
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var \
    '_MONITOR_REF="actions/checkout@${CHECKOUT_MAJOR}"' \
    -- '      - uses: ${_MONITOR_REF}'

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  assert_output --partial 'not a versioned action reference'
}

@test "generated-workflow-actions: a variable the file never assigns is a finding (#950)" {
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var -- '      - uses: ${_MONITOR_REF}'

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  assert_output --partial 'not a versioned action reference'
  assert_output --partial '_MONITOR_REF'
}

@test "generated-workflow-actions: resolution is same-file only (#950)" {
  # A value assigned in ANOTHER file is not visible at the use site. The
  # reader would have to guess which of the tree's scripts is in scope at
  # generation time, and guessing wrong is how a lint reports a ref it
  # never actually read.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  printf "#!/usr/bin/env bash\nreadonly _MONITOR_REF='actions/checkout@v7'\n" \
    > "${SCRATCH}/dist/upstream.sh"
  _write_generator_var -- '      - uses: ${_MONITOR_REF}'

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  assert_output --partial 'not a versioned action reference'
}

@test "generated-workflow-actions: an appended variable is a finding (#950)" {
  # `NAME+=` builds a value rather than declaring one, and reading only the
  # `NAME=` line would resolve to a prefix of what the generator writes --
  # a ref this lint never saw, compared as though it had.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var \
    "_MONITOR_REF='actions/checkout'" \
    "_MONITOR_REF+='@v7'" \
    -- '      - uses: ${_MONITOR_REF}'

  run _run_generated_workflow_actions
  [ "${status}" -ne 0 ]
  assert_output --partial 'not a versioned action reference'
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
