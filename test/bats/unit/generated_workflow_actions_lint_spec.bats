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

  # This driver walks the pin registry's population, which is the set of
  # files the tree TRACKS -- so the fixture is a real repository. The
  # container's host-computed handoff is left in place: it is keyed to
  # /source and cannot reach a scratch tree, and the real-tree case at the
  # bottom of this file reads it.
  SCRATCH="$(mktemp -d)"
  git -C "${SCRATCH}" init -q
  mkdir -p "${SCRATCH}/.github/workflows" "${SCRATCH}/dist"
  REPO_ROOT="${SCRATCH}"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# Run the lint over the fixture as the repo would see it: everything
# written so far is tracked. See pin_coverage_lint_spec.bats's `_lint`.
_gwa_lint() {
  git -C "${SCRATCH}" add -A
  run _run_generated_workflow_actions
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

# _write_upstream_slug <slug> -- the tree's single declaration of the
# `<owner>/<repo>` this repo is served from. base is its own upstream, so
# that slug is this repo's own name, and the driver SOURCES this file and
# reads `BASE_UPSTREAM_SLUG` out of it rather than carrying a copy.
#
# The slug is an argument, the variable name is not, and that asymmetry is
# the point. upgrade.sh, init.sh and check-base-version.sh all source this
# file and read that one name, so the name is the file's published
# interface -- asking it the same way they do is exact where a text scan
# was a heuristic. What a repo RENAME moves is the value, and that is what
# the spec below moves.
_write_upstream_slug() {
  local _slug="${1}"
  mkdir -p "${SCRATCH}/dist/script/base"
  {
    printf '#!/usr/bin/env bash\n'
    printf "BASE_UPSTREAM_SLUG='%s'\n" "${_slug}"
  } > "${SCRATCH}/dist/script/base/upstream.sh"
}

# _write_generator_raw <line>... -- a generator written out verbatim, for
# the cases whose defect IS the file's shape: where an assignment sits
# relative to the heredoc that uses it, and what it sits inside.
_write_generator_raw() {
  printf '%s\n' "$@" > "${SCRATCH}/dist/init.sh"
}

# ── The drift the lint exists to catch ──────────────────────────────────

# why: The drift itself -- dependabot bumps the workflows and cannot reach
# the heredoc
@test "generated-workflow-actions: fails when a generated ref is behind this repo's own (#950)" {
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator '      - uses: actions/checkout@v7'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'actions/checkout'
  assert_output --partial 'v7'
  assert_output --partial 'v8'
  assert_output --partial 'dist/init.sh'
}

# why: A bump proposal is actionable only if it says which line to edit
@test "generated-workflow-actions: names the generated ref's file and line (#950)" {
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator '      - uses: actions/checkout@v7'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'dist/init.sh:7'
}

# why: Lockstep is the whole assertion; the lint owns no opinion on which
# version is right
@test "generated-workflow-actions: passes when the two copies agree (#950)" {
  _load_driver
  _write_workflow 'actions/checkout@v8' 'actions/upload-artifact@v7'
  _write_generator '      - uses: actions/checkout@v8'

  _gwa_lint
  [ "${status}" -eq 0 ]
  assert_output --partial 'clean'
}

# why: Direction-agnostic: a hand-edit past the workflows is the same
# defect, other sign
@test "generated-workflow-actions: a ref ahead of this repo's own fails too (#950)" {
  # Direction-agnostic on purpose: the failure is disagreement, not
  # staleness. A generated copy edited past the workflows is the same
  # defect wearing the other sign, and it is the shape a hand-fix takes.
  _load_driver
  _write_workflow 'actions/checkout@v7'
  _write_generator '      - uses: actions/checkout@v8'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'actions/checkout'
}

# ── What is deliberately not a generated pin ────────────────────────────

# why: A call home has an owner -- upgrade.sh rewrites it -- so the exclusion
# is keyed on the callee being ours, not on the ref being interpolated
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
  _write_upstream_slug 'ycpss91255-docker/base'
  _write_own_reusable_workflow 'build-worker.yaml'
  _write_generator \
    '      - uses: ${BASE_UPSTREAM_SLUG}/.github/workflows/build-worker.yaml@${ref}' \
    '      - uses: actions/checkout@v8'

  _gwa_lint
  [ "${status}" -eq 0 ]
}

# why: The hole: nine of our workflow basenames are names anybody would
# pick, so a basename-keyed exclusion exempts a stranger's copy in silence
@test "generated-workflow-actions: somebody else's copy of one of our workflow filenames is not excluded (#950)" {
  # The hole this closes. The exclusion used to key on the callee's
  # BASENAME alone, and this repo ships nine of them -- build-worker,
  # release-worker, self-test, publish-worker, ghcr-cleanup and friends,
  # names anybody would pick. A call to somebody ELSE's build-worker.yaml
  # was therefore exempted for being spelled like ours, with no diagnostic:
  # a literal, fully readable ref left the population in silence. The
  # reason for the exclusion -- upgrade.sh rewrites `<worker>.yaml@vX.Y.Z`
  # in every downstream main.yaml -- only holds when the owner is us.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_upstream_slug 'ycpss91255-docker/base'
  _write_own_reusable_workflow 'build-worker.yaml'
  _write_generator \
    '      - uses: evilorg/evilrepo/.github/workflows/build-worker.yaml@v1' \
    '      - uses: actions/checkout@v8'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'evilorg/evilrepo'
}

# why: The obvious repair for that hole is the same hole one layer up --
# "any variable, since it might be us" exempts ${OTHER_SLUG} too
@test "generated-workflow-actions: an unresolved variable is not a stand-in for our own slug (#950)" {
  # The obvious repair for the basename hole is its own hole: init.sh HAS
  # to spell the owner as `${BASE_UPSTREAM_SLUG}`, so a reader that accepts
  # "any variable, since it might be us" re-opens the same exemption one
  # layer up -- `${OTHER_SLUG}` is not this repo, and the tree never says
  # it is. Only the variable the tree declares its own slug in stands in.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_upstream_slug 'ycpss91255-docker/base'
  _write_own_reusable_workflow 'build-worker.yaml'
  _write_generator \
    '      - uses: ${OTHER_SLUG}/.github/workflows/build-worker.yaml@${ref}' \
    '      - uses: actions/checkout@v8'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'OTHER_SLUG'
}

# why: The other half of the owner check -- an exclusion that only survives
# interpolation would fire on the literal spelling of the same call home
@test "generated-workflow-actions: our own slug spelled out is excluded (#950)" {
  # The other half of the owner check: written literally, with no variable
  # anywhere, the call home is still a call home.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_upstream_slug 'ycpss91255-docker/base'
  _write_own_reusable_workflow 'build-worker.yaml'
  _write_generator \
    '      - uses: ycpss91255-docker/base/.github/workflows/build-worker.yaml@v1.2.3' \
    '      - uses: actions/checkout@v8'

  _gwa_lint
  [ "${status}" -eq 0 ]
  assert_output --partial '1 generated ref'
}

# why: A repo rename must move the exclusion with it; a driver holding a
# copy of either literal fails one of these two halves
@test "generated-workflow-actions: the owner is read off the tree, not carried in the driver (#950)" {
  # Derived, not hardcoded. Move the slug the upstream file declares -- a
  # repo rename -- and the exclusion follows it: the new one is excluded
  # and the OLD one, which the tree no longer declares, is not. A driver
  # holding a copy of either literal fails one of these two.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_upstream_slug 'someone/elsewhere'
  _write_own_reusable_workflow 'build-worker.yaml'
  _write_generator \
    '      - uses: someone/elsewhere/.github/workflows/build-worker.yaml@v1' \
    '      - uses: actions/checkout@v8'

  _gwa_lint
  [ "${status}" -eq 0 ]

  _write_generator \
    '      - uses: ycpss91255-docker/base/.github/workflows/build-worker.yaml@v1' \
    '      - uses: actions/checkout@v8'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'ycpss91255-docker/base'
}

# why: Fail-closed is the only safe direction for an exemption -- an
# unreadable upstream file must switch it off, not leave every call exempt
@test "generated-workflow-actions: an upstream file declaring no slug excludes nothing (#987)" {
  # The exclusion is switched OFF by an unreadable upstream file, not left
  # on: a file that stops declaring the name its three consumers source it
  # for makes every call home a finding, rather than making every call
  # exempt. Fail-closed is the only safe direction for an exemption.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_own_reusable_workflow 'build-worker.yaml'
  mkdir -p "${SCRATCH}/dist/script/base"
  printf '#!/usr/bin/env bash\n' > "${SCRATCH}/dist/script/base/upstream.sh"
  _write_generator \
    '      - uses: ycpss91255-docker/base/.github/workflows/build-worker.yaml@v1' \
    '      - uses: actions/checkout@v8'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'build-worker.yaml'
}

# why: Reading the basename off the tail of an arbitrary path is how
# .../workflows/vendor/build-worker.yaml claimed our exemption
@test "generated-workflow-actions: a deeper path under .github/workflows/ is not excluded (#950)" {
  # `<owner>/<repo>/.github/workflows/<file>` is the only shape GitHub
  # calls a reusable workflow by, so a nested path is not that call at all
  # -- and reading the basename off the tail of an arbitrary path is how
  # `.../workflows/vendor/build-worker.yaml` claimed our exemption.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_upstream_slug 'ycpss91255-docker/base'
  _write_own_reusable_workflow 'build-worker.yaml'
  _write_generator \
    '      - uses: ${BASE_UPSTREAM_SLUG}/.github/workflows/sub/build-worker.yaml@v1' \
    '      - uses: actions/checkout@v8'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'sub/build-worker.yaml'
}

# why: Nothing rewrites somebody else's reusable workflow, so it stays in
# the population rather than inheriting our upgrade.sh justification
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

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'not-ours.yaml'
}

# why: Prose quoting a step is not a step; a lint that fails on its own docs
# gets muted
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

  _gwa_lint
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

# why: Quoting is legal Actions syntax, so a matcher that only reads bare values
# is narrower than the name it carries
@test "generated-workflow-actions: a double-quoted generated ref is compared, not skipped (#950)" {
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator '      - uses: "actions/checkout@v7"'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'actions/checkout'
  assert_output --partial 'v7'
  assert_output --partial 'v8'
}

# why: The other quote character, because a matcher fixed for one and not the
# other is the same silent skip wearing a different mark
@test "generated-workflow-actions: a single-quoted generated ref is compared, not skipped (#950)" {
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator "      - uses: 'actions/checkout@v7'"

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'v7'
  assert_output --partial 'v8'
}

# why: The bare form of the defect behind quotes -- nothing bumps it, and the
# quotes must not be what hides it
@test "generated-workflow-actions: a quoted ref to an action this repo never uses fails (#950)" {
  # The bare form of the defect, behind quotes: nothing bumps it, and the
  # quotes must not be what hides it.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator \
    '      - uses: "actions/setup-node@v1"' \
    '      - uses: actions/checkout@v8'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'actions/setup-node'
}

# why: The partial silent drop: a tree whose other refs agree is exactly where a
# skipped ref reports clean, and the count backstop cannot see it
@test "generated-workflow-actions: one unreadable ref among readable ones still fails (#950)" {
  # The partial silent drop: a tree whose OTHER refs are in lockstep is
  # exactly where a skipped ref reports clean. The count backstop cannot
  # see this -- it only fires when every ref is unreadable.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator \
    '      - uses: actions/checkout@v8' \
    '      - uses: "actions/checkout@v3"'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'v3'
}

# why: Refusing to guess is the point, and the message has to name the line it
# could not read or the reader has nowhere to go
@test "generated-workflow-actions: a uses: value it cannot resolve fails by name (#950)" {
  # Not a versioned action, not a documented exclusion: refusing to guess
  # is the point, and the message has to say which line it could not read.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator \
    '      - uses: actions/checkout@v8' \
    '      - uses: not-an-action-reference'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'not-an-action-reference'
  assert_output --partial 'dist/init.sh'
}

# why: An unreadable value carries an empty action field, and dropping that field
# re-routes the finding into a sentence about an action nobody wrote
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

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'not a versioned action reference'
  refute_output --partial 'never uses'
}

# why: This repo plainly does use actions/checkout, so calling it an action this
# repo never uses states something false and sends the reader elsewhere
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

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'not a versioned action reference'
  refute_output --partial 'never uses actions/checkout'
}

# why: A ./ callee is this tree at this commit; excluding it by name keeps the pass
# from riding on the matcher merely declining to match
@test "generated-workflow-actions: a local ./ callee is skipped by name, not by accident (#950)" {
  # `uses: ./.github/workflows/x.yaml` carries no ref: the callee is this
  # tree at this commit. A named exclusion, so it does not ride on the
  # matcher declining to match.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator \
    '      - uses: ./.github/workflows/local.yaml' \
    '      - uses: actions/checkout@v8'

  _gwa_lint
  [ "${status}" -eq 0 ]
}

# why: An image reference has no owner/repo reading for a workflow ref to agree
# with, so it is excluded by name rather than by accident
@test "generated-workflow-actions: a docker:// container action is skipped by name (#950)" {
  # An image reference, not a repository tag: it has no <owner>/<repo>
  # reading for a workflow ref to agree with.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator \
    '      - uses: docker://alpine:3.21' \
    '      - uses: actions/checkout@v8'

  _gwa_lint
  [ "${status}" -eq 0 ]
}

# why: The same matcher reads both sides; a quoted ref dropped from the expected
# set turns a real disagreement into the right verdict for the wrong reason
@test "generated-workflow-actions: a quoted ref in this repo's own workflow is read too (#950)" {
  # The same matcher reads both sides. A quoted ref in .github/workflows/
  # dropped from the expected set turns a real disagreement into "this
  # repo never uses it", i.e. the right verdict for the wrong reason.
  _load_driver
  _write_workflow '"actions/checkout@v8"'
  _write_generator '      - uses: actions/checkout@v8'

  _gwa_lint
  [ "${status}" -eq 0 ]
}

# why: A shipped release cannot be re-pinned, so scanning it fails a lint no
# edit can satisfy
@test "generated-workflow-actions: ignores a generator under .prev-release/ (#950)" {
  # The self-test materialises PAST releases into .prev-release/, and a
  # shipped release's refs are stale BY DEFINITION -- a release cannot be
  # re-pinned. Scanning it would mean the first dependabot bump after any
  # release fails a lint that no edit in the tree can satisfy.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator '      - uses: actions/checkout@v8'
  git -C "${SCRATCH}" add -A
  # Materialised by the suite, never committed -- which is now the whole
  # of why it is out of the walk.
  mkdir -p "${SCRATCH}/.prev-release/v0.1.0"
  printf '      - uses: actions/checkout@v6\n' \
    > "${SCRATCH}/.prev-release/v0.1.0/init.sh"

  run _run_generated_workflow_actions
  [ "${status}" -eq 0 ]
  assert_output --partial '1 generated ref'
}

# ── A ref the pin registry declares ─────────────────────────────────────
#
# "Interpolated from a shell variable" is not the same property as "cannot
# be known". A generator that hoists its ref into `readonly NAME='lit'`
# above the heredoc -- which is what init.sh does -- writes exactly the
# same ref into the generated workflow as if it had been spelled inline.
# Excluding it removes a ref from the population instead of checking it,
# which is the fail-open direction: the one ref this lint was built for
# stops being covered by the very edit that documents it.
#
# So the ref is resolved -- from the PIN REGISTRY, which already holds a
# record naming the file and line of every declaration site and the value
# on that line, because a human wrote a `tool-pin:` marker there under a
# lint that fails when it is missing. The driver looks the answer up; it
# does not re-derive which assignment is live.

# why: The shape init.sh actually uses -- a hoisted ref writes the same value as an
# inline one, so excluding it would drop the ref this lint was built for
@test "generated-workflow-actions: a declared readonly literal is resolved and compared (#950)" {
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var \
    '# tool-pin: unpinned monitor-checkout -- a major ref on purpose' \
    "readonly _MONITOR_REF='actions/checkout@v7'" \
    -- '      - uses: ${_MONITOR_REF}'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'actions/checkout'
  assert_output --partial 'v7'
  assert_output --partial 'v8'
}

# why: Not merely "does not fail": a resolved ref that is silently dropped also
# passes, and the count is what separates the two
@test "generated-workflow-actions: a resolved ref that agrees enters the population (#950)" {
  # Not just "does not fail": the ref has to be COUNTED. A resolved ref
  # that is silently dropped also passes, and the count is what separates
  # the two.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var \
    '# tool-pin: unpinned monitor-checkout -- a major ref on purpose' \
    "readonly _MONITOR_REF='actions/checkout@v8'" \
    -- '      - uses: ${_MONITOR_REF}'

  _gwa_lint
  [ "${status}" -eq 0 ]
  assert_output --partial '1 generated ref'
}

# why: readonly is a hardening detail of the declaration; what makes the value
# readable is the marker, not the keyword
@test "generated-workflow-actions: the declaration keyword decides nothing (#950)" {
  # `readonly` is a hardening detail of the declaration, not what makes the
  # value readable. What makes it readable is the marker.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var \
    '# tool-pin: unpinned monitor-checkout -- a major ref on purpose' \
    "_MONITOR_REF='actions/checkout@v7'" \
    -- '      - uses: ${_MONITOR_REF}'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'v7'
}

# why: The single-variable shape, with no neighbour to collide with: the rule is
# "a bare name", not "a bare name that could collide"
@test "generated-workflow-actions: an unbraced \$NAME is refused with no neighbour to collide with (#987)" {
  # This used to assert the opposite -- that the bare spelling RESOLVES --
  # and the driver was narrowed to read only `${NAME}` because the bare
  # form has no terminator: see the prefix-collision case below, where a
  # short name substituted into a longer one it prefixes and fabricated a
  # ref that appeared in no declaration. The rule the driver now applies
  # is not "a bare name that could collide", it is "a bare name", so the
  # single-variable shape -- nothing here for it to run into -- is the one
  # worth stating separately from the collision that motivated it.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var \
    '# tool-pin: unpinned monitor-checkout -- a major ref on purpose' \
    "readonly _MONITOR_REF='actions/checkout@v7'" \
    -- '      - uses: $_MONITOR_REF'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'not a versioned action reference'
  assert_output --partial '_MONITOR_REF'
  refute_output --partial 'v7'
}

# why: The variable need not be the whole value; actions/checkout@${_V} is the same
# static ref written differently
@test "generated-workflow-actions: resolves the ref half alone (#950)" {
  # The variable need not be the whole value. `actions/checkout@${V}` is
  # the same static ref written differently -- and `v7` is a version, so
  # the registry demands a marker on that line anyway.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var \
    '# tool-pin: unpinned checkout-major -- a major ref on purpose' \
    "readonly _V='v7'" \
    -- '      - uses: actions/checkout@${_V}'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'v7'
}

# why: Resolution feeds the ordinary comparison rather than bypassing it, or the
# registry would become a way to opt a ref out
@test "generated-workflow-actions: a resolved ref to an action this repo never uses still fails (#950)" {
  # Resolution feeds the ordinary comparison; it is not a bypass around it.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var \
    '# tool-pin: unpinned monitor-node -- a major ref on purpose' \
    "readonly _MONITOR_REF='actions/setup-node@v3'" \
    -- '      - uses: ${_MONITOR_REF}'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'never uses'
  assert_output --partial 'actions/setup-node'
}

# why: The record names a file AND a line; matching on the name alone throws away
# the half that makes the lookup better than the scanner it replaced
@test "generated-workflow-actions: a declaration in ANOTHER file does not resolve (#987)" {
  # The record names a FILE and a line, and resolution uses both. A marker
  # in dist/constants.sh says what THAT file's `_MONITOR_REF` holds; it
  # says nothing about a `${_MONITOR_REF}` written in dist/init.sh, which
  # is a different variable that happens to be spelled the same. Matching
  # on the name alone throws away the half of the record that makes the
  # lookup better than the scanner it replaced.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# tool-pin: unpinned monitor-checkout -- a major ref on purpose' \
    "readonly _MONITOR_REF='actions/checkout@v7'" \
    > "${SCRATCH}/dist/constants.sh"
  _write_generator_var -- '      - uses: ${_MONITOR_REF}'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'not a versioned action reference'
  assert_output --partial '_MONITOR_REF'
}

# why: What name-keyed resolution costs: a marked constant in a sibling file
# answers for a runtime value here, and reports lockstep over it
@test "generated-workflow-actions: a marked name elsewhere does not vouch for a runtime value here (#987)" {
  # What name-keyed resolution costs, in the shape it actually arrives in.
  # dist/init.sh computes its own `_MONITOR_REF` at run time and carries
  # no marker -- `$(...)` is neither a version nor an action ref, so
  # nothing else asks it for one. Keyed on the name, the marked constant
  # in the sibling file answers for it and the lint reports lockstep over
  # a value this generator may never write. The competing assignment is
  # invisible to the ambiguity test, which only ever sees MARKED sites.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# tool-pin: unpinned monitor-checkout -- a major ref on purpose' \
    "readonly _MONITOR_REF='actions/checkout@v8'" \
    > "${SCRATCH}/dist/constants.sh"
  _write_generator_raw \
    '#!/usr/bin/env bash' \
    '_gen() {' \
    '  local _MONITOR_REF' \
    '  _MONITOR_REF="$(_pick_checkout_ref)"' \
    '  cat > "${_wf}" <<YAML' \
    '      - uses: ${_MONITOR_REF}' \
    'YAML' \
    '}'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'not a versioned action reference'
  assert_output --partial '_MONITOR_REF'
}

# ── The trade, made checkable ───────────────────────────────────────────
#
# The registry proves a DECLARATION EXISTS AT A LINE. It does not prove
# that assignment is live at the use, and this is what that costs: a
# declaration below the heredoc that reads it resolves anyway. The
# scanner that refused this shape did so on three heuristics over text,
# and four ways to fool them all failed OPEN. What is bought is that the
# property is declared by the author rather than inferred here, and that
# an undeclared one fails instead of being resolved in silence.

# why: The stated cost of trusting a declaration -- a declaration below the heredoc
# that reads it still resolves, and that is bought knowingly
@test "generated-workflow-actions: a declaration BELOW the use still resolves (#987)" {
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_raw \
    '#!/usr/bin/env bash' \
    '_gen() {' \
    '  cat > "${_wf}" <<YAML' \
    '      - uses: ${_MONITOR_REF}' \
    'YAML' \
    '}' \
    '# tool-pin: unpinned monitor-checkout -- a major ref on purpose' \
    "readonly _MONITOR_REF='actions/checkout@v7'"

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'v7'
  assert_output --partial 'v8'
}

# ── What the registry does not declare stays a FINDING ──────────────────
#
# Each of these could be waved through as "interpolated, cannot know", and
# each would take a real pin out of the population. The safe default on an
# unrecognised shape is to refuse it, so it is reported with the raw value
# and the reader decides.

# why: Which declaration reaches the use is the question this driver no longer
# answers, so it says so rather than picking one
@test "generated-workflow-actions: two declarations that disagree are a finding (#950)" {
  # Which one reaches this use is exactly the question this driver no
  # longer answers, so it says so rather than picking.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var \
    '# tool-pin: unpinned monitor-checkout -- a major ref on purpose' \
    "_MONITOR_REF='actions/checkout@v7'" \
    '# tool-pin: unpinned monitor-checkout-2 -- a major ref on purpose' \
    "_MONITOR_REF='actions/checkout@v6'" \
    -- '      - uses: ${_MONITOR_REF}'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'not a versioned action reference'
  assert_output --partial '_MONITOR_REF'
}

# why: Declared and still not a value -- what the line holds is decided at run
# time, so there is nothing to hold in lockstep
@test "generated-workflow-actions: a declared command substitution is a finding (#950)" {
  # Declared, and still not a value: what the line holds is decided at run
  # time, so there is nothing here to hold in lockstep with anything.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var \
    '# tool-pin: unpinned monitor-checkout -- read at run time' \
    '_MONITOR_REF="$(cat .checkout-ref)"' \
    -- '      - uses: ${_MONITOR_REF}'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'not a versioned action reference'
  assert_output --partial '_MONITOR_REF'
}

# why: A second hop is not a value, and refusing it is also what keeps resolution
# terminating rather than substituting forever
@test "generated-workflow-actions: a declared value that is itself a variable is a finding (#950)" {
  # `_A='actions/checkout@v7'` is a value; `_B="${_A}"` is a second hop.
  # Refusing it is also what keeps resolution terminating: a declared
  # value carrying a `$` could substitute itself forever.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var \
    '# tool-pin: unpinned monitor-a -- a major ref on purpose' \
    "_A='actions/checkout@v7'" \
    '# tool-pin: unpinned monitor-checkout -- a major ref on purpose' \
    '_MONITOR_REF="${_A}"' \
    -- '      - uses: ${_MONITOR_REF}'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'not a versioned action reference'
}

# why: A value built at run time from an interpolation is not a static ref, so
# resolving it would compare a string the generator never writes
@test "generated-workflow-actions: a declared value with an interpolation is a finding (#950)" {
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var \
    '# tool-pin: unpinned monitor-checkout -- built at run time' \
    '_MONITOR_REF="actions/checkout@${CHECKOUT_MAJOR}"' \
    -- '      - uses: ${_MONITOR_REF}'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'not a versioned action reference'
}

# why: A variable nothing declares is the fail-open case: resolving it to nothing
# would drop the ref from the population in silence
@test "generated-workflow-actions: a variable nothing in the tree declares is a finding (#950)" {
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var -- '      - uses: ${_MONITOR_REF}'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'not a versioned action reference'
  assert_output --partial '_MONITOR_REF'
}

# why: The mirror of the cross-file case -- resolution reads the registry, not the
# tree, so an unclaimed assignment contributes nothing wherever it sits
@test "generated-workflow-actions: an UNDECLARED assignment in another file is a finding (#987)" {
  # The mirror of the cross-file case above. Tree-wide resolution reads
  # the registry, not the tree: an assignment no marker claims contributes
  # nothing wherever it sits.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  printf "#!/usr/bin/env bash\nreadonly _MONITOR_REF='actions/checkout@v8'\n" \
    > "${SCRATCH}/dist/constants.sh"
  _write_generator_var -- '      - uses: ${_MONITOR_REF}'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'not a versioned action reference'
}

# why: NAME+= builds a value rather than declaring one, so reading only the NAME=
# line resolves to a prefix of what the generator writes
@test "generated-workflow-actions: an appended variable is a finding (#950)" {
  # `NAME+=` builds a value rather than declaring one, so it is not an
  # assignment to the registry either: reading only the `NAME=` line would
  # resolve to a PREFIX of what the generator writes -- a ref this lint
  # never saw, compared as though it had.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var \
    '# tool-pin: unpinned monitor-checkout -- built from two pieces' \
    "_MONITOR_REF='actions/checkout'" \
    "_MONITOR_REF+='@v7'" \
    -- '      - uses: ${_MONITOR_REF}'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'not a versioned action reference'
}

# ── The cases where there is no single ref to follow ────────────────────

# why: No answer to which ref the generated copy should carry, so it says so
# rather than guessing
@test "generated-workflow-actions: fails when this repo pins the action at two refs (#950)" {
  # With the workflows themselves disagreeing there is no answer to
  # "which ref should the generated copy carry", so the lint says that
  # rather than silently picking one.
  _load_driver
  _write_workflow 'docker/build-push-action@v6' 'docker/build-push-action@v7'
  _write_generator '      - uses: docker/build-push-action@v6'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'docker/build-push-action'
  assert_output --partial 'v6'
  assert_output --partial 'v7'
}

# why: No dependabot PR for the generated ref to inherit -- the bare form of
# the defect
@test "generated-workflow-actions: fails when this repo never uses the generated action (#950)" {
  # An action this repo does not call itself has no dependabot PR to
  # inherit from, so the generated ref is pinned by nobody -- the exact
  # condition the lint exists to refuse, in its purest form.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator '      - uses: actions/setup-node@v3'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'actions/setup-node'
}

# why: A renamed generator or a dead matcher must not read as lockstep
@test "generated-workflow-actions: refuses a tree it found no generated ref in (#950)" {
  # Reporting clean over a scan that read nothing is how a lint quietly
  # stops covering anything -- a renamed generator, a moved directory, a
  # matcher that stopped matching. Silence must not read as lockstep.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'no generated'
}

# ── The reader decides which assignment is live, and gets it wrong ──────
#
# The driver resolves a variable by SCANNING the generator for the one
# assignment it judges live at the use: file scope, unconditional, column
# 0, no `local`. That judgement is three heuristics over text, and each
# case below is a shape they read as file-scope-and-unconditional when it
# is not. The failure direction is the bad one -- the lint reports a ref it
# never actually resolved as being in lockstep.
#
# All three are green today. They are the reason the resolution question is
# handed to the pin registry, which answers it once, at the site, from an
# author's declaration, under a lint that fails when the declaration is
# missing.

# why: A bare brace group at column 0 drops the reader back to file scope for the
# rest of the body, so every later assignment is judged live
@test "generated-workflow-actions: a brace group at column 0 does not end a function (#987)" {
  # `}` at column 0 is read as the close of the enclosing function, so a
  # bare brace group written unindented inside one drops the reader back to
  # "file scope" for the REST of the body -- and every assignment after it
  # is then judged live at the heredoc.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_raw \
    '#!/usr/bin/env bash' \
    '_gen() {' \
    '{' \
    '  :' \
    '}' \
    "readonly _MONITOR_REF='actions/checkout@v8'" \
    '  cat > "${_wf}" <<YAML' \
    '      - uses: ${_MONITOR_REF}' \
    'YAML' \
    '}'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial '_MONITOR_REF'
}

# why: for((...)) carries no space, so the loop never counts as opened and an
# assignment that runs only inside it is read as unconditional
@test "generated-workflow-actions: a C-style for loop is a conditional block (#987)" {
  # The open-block counter matches `for ` with a space. `for((i=0;...))`
  # has none, so the loop is never counted as opened -- and an assignment
  # that runs only if the loop body runs is read as unconditional.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_raw \
    '#!/usr/bin/env bash' \
    'for((i=0;i<1;i++)); do' \
    "readonly _MONITOR_REF='actions/checkout@v8'" \
    'done' \
    '_gen() {' \
    '  cat > "${_wf}" <<YAML' \
    '      - uses: ${_MONITOR_REF}' \
    'YAML' \
    '}'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial '_MONITOR_REF'
}

# why: A tab after if is legal bash and does not match "if ", so the block never
# opens and the guarded assignment reads as unconditional
@test "generated-workflow-actions: a tab after if still opens a block (#987)" {
  # Same counter, same defect one character over: `if<TAB>` is legal bash
  # and does not match `if `, so the block never opens and the guarded
  # assignment below it is read as unconditional.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_raw \
    '#!/usr/bin/env bash' \
    "$(printf 'if\t[[ -n "${CI:-}" ]]; then')" \
    "readonly _MONITOR_REF='actions/checkout@v8'" \
    'fi' \
    '_gen() {' \
    '  cat > "${_wf}" <<YAML' \
    '      - uses: ${_MONITOR_REF}' \
    'YAML' \
    '}'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial '_MONITOR_REF'
}

# ── A shell reference is read lexically, and quoting is not asked about ─
#
# There is no model of bash's heredoc grammar here any more. In a `uses:`
# value, `${{ ... }}` is a GitHub Actions expression and is excluded by
# name; any OTHER `${...}` or `$NAME` must resolve against a tool-pin
# declaration in the same file, and one that does not resolve is a
# finding. Whether the site the reference is written at EXPANDS is not
# asked, and the cases below are where that shows.

# why: A quoted heredoc writes the reference out verbatim, which is a broken
# generator rather than a ref to pass over -- the comparison is the same
@test "generated-workflow-actions: a reference in a QUOTED heredoc is compared like any other (#987)" {
  # `<<'YAML'` writes `${_MONITOR_REF}` out verbatim, and the previous
  # reader spent a bash model on saying so -- to exempt the line from the
  # comparison. Exempting it is the wrong answer twice over: the value is
  # still a ref this repo names and must keep in lockstep, and a workflow
  # whose `uses:` reads `${_MONITOR_REF}` names none of the three forms
  # `uses:` accepts, so it is a broken generator rather than a ref to pass
  # over. The comparison is what this lint owns, and it has the same
  # answer on both sides of the quote.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_raw \
    '#!/usr/bin/env bash' \
    '# tool-pin: unpinned monitor-checkout -- a major ref on purpose' \
    "readonly _MONITOR_REF='actions/checkout@v6'" \
    '_gen() {' \
    "  cat > \"\${_wf}\" <<'YAML'" \
    '      - uses: ${_MONITOR_REF}' \
    'YAML' \
    '}'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'the generated copy disagrees'
}

# why: The one dollar spelling in a uses: value that is not a shell reference at
# all, so it is excluded by name beside ./ and docker://
@test "generated-workflow-actions: a \${{ }} GitHub expression is excluded by name (#987)" {
  # The one `$` spelling in a `uses:` value that is not a shell reference
  # at all: GitHub resolves it, at run time, from a context this tree
  # cannot read. There is no ref here to hold in lockstep with anything,
  # so it is excluded the way a `./` callee and a `docker://` image are --
  # by name, in the classifier, next to its reason.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var \
    '# tool-pin: unpinned monitor-checkout -- a major ref on purpose' \
    "readonly _MONITOR_REF='actions/checkout@v8'" \
    -- '      - uses: ${{ matrix.action }}' \
       '      - uses: ${_MONITOR_REF}'

  _gwa_lint
  [ "${status}" -eq 0 ]
  assert_output --partial 'clean (1 generated ref(s) checked'
}

# why: The exclusion is of the expression, not of any value carrying one; it is
# what stops the new exclusion becoming a blanket pass
@test "generated-workflow-actions: a \${{ }} does not excuse a shell reference beside it (#987)" {
  # The exclusion is of the EXPRESSION, not of the value that carries
  # one. Shell references are resolved first and the exclusion is applied
  # after, so an undeclared `${_UNDECLARED}` is still a finding when a
  # GitHub expression shares the line. Green before this change and after
  # it: it is the guard that keeps the new exclusion from becoming a
  # blanket pass for any value with a `$` in it.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var \
    '# tool-pin: unpinned monitor-checkout -- a major ref on purpose' \
    "readonly _MONITOR_REF='actions/checkout@v8'" \
    -- '      - uses: ${_UNDECLARED}/checkout@${{ env.V }}' \
       '      - uses: ${_MONITOR_REF}'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial '_UNDECLARED'
}

# why: What the deleted heredoc model cost while working as designed -- a shift
# read as an unterminated heredoc refused every ref in the file
@test "generated-workflow-actions: an arithmetic left shift is not a reason to refuse a file (#987)" {
  # What the deleted model cost when it was working as designed. `1 << 3`
  # is a shift; a heredoc reader sees `<<` and opens a body on `3` that no
  # line ever closes, and failing closed on that meant refusing every
  # interpolated ref in the file -- here, the one real comparison the
  # fixture has. Nothing reads `<<` any more, so the shift is arithmetic
  # and the ref below it is compared.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_raw \
    '#!/usr/bin/env bash' \
    '# tool-pin: unpinned monitor-checkout -- a major ref on purpose' \
    "readonly _MONITOR_REF='actions/checkout@v7'" \
    '_gen() {' \
    '  local _mask=$(( 1 << 3 ))' \
    '  printf %s "${_mask}"' \
    '  cat > "${_wf}" <<YAML' \
    '      - uses: ${_MONITOR_REF}' \
    'YAML' \
    '}'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'the generated copy disagrees'
}

# ── A variable is what the pin registry says it is ──────────────────────
#
# The replacement contract, in one sentence: a `uses:` ref a shell script
# writes must be either a literal `<owner>/<repo>@<ref>`, or a variable
# whose value the PIN REGISTRY declares. The registry already returns a
# record naming the file and line of every declaration site, and already
# extracts the value on that line, because a human wrote a `tool-pin:`
# marker there under a lint that fails when it is missing.

# why: The replacement contract in one case: a variable is what the pin registry
# says it is, and the registry already names the file, line and value
@test "generated-workflow-actions: a variable the registry declares is resolved (#987)" {
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var \
    '# tool-pin: unpinned monitor-checkout -- a major ref on purpose' \
    "readonly _MONITOR_REF='actions/checkout@v7'" \
    -- '      - uses: ${_MONITOR_REF}'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'v7'
  assert_output --partial 'v8'
}

# why: A short name substituted into a longer one it prefixes fabricated a ref that
# appears in no declaration, and the backstop found nothing to refuse
@test "generated-workflow-actions: a bare \$NAME is a finding, not a resolution (#987)" {
  # why: the bare spelling has no terminator, so a global substitution of a
  # SHORT name reached into a LONGER name it prefixes. With A declared as
  # `v` and A7 as `v6`, `$A/checkout@$A7` resolved to `v/checkout@v7` -- a
  # ref that appears in no declaration -- and the trailing `$` backstop
  # found nothing left to refuse, so a fabricated ref reached the
  # comparison. Only `${NAME}` is read now: it is a closed token, so a
  # substitution of it cannot reach a neighbour. The bare spelling lands in
  # the finding branch, and the fix at any call site is one character.
  _load_driver
  _write_workflow 'actions/checkout@v7'
  _write_generator_var \
    '# tool-pin: unpinned monitor-checkout -- a major ref on purpose' \
    "readonly A='actions'" \
    '# tool-pin: unpinned monitor-ref -- a major ref on purpose' \
    "readonly A7='v6'" \
    -- '      - uses: $A/checkout@$A7'

  _gwa_lint
  [ "${status}" -ne 0 ]
  refute_output --partial 'v7'
}

# why: The whole trade in one case: file-scope, unconditional, column 0, above the
# use -- and still refused, because nothing declares it to the watch
@test "generated-workflow-actions: an assignment no marker claims is a finding (#987)" {
  # The whole trade in one case. The assignment below is file-scope,
  # unconditional, at column 0 and above the use -- everything the deleted
  # scanner asked for -- and it is still refused, because nothing declares
  # it to the watch. A ref resolved from an undeclared line is a ref this
  # repo cannot bump and nothing reports: exactly what the lint exists for.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_var \
    "readonly _MONITOR_REF='actions/checkout@v8'" \
    -- '      - uses: ${_MONITOR_REF}'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial '_MONITOR_REF'
}

# why: The two lints disagreed about what an assignment is, so one marker on a
# local produced a record the watch read and this lint refused
@test "generated-workflow-actions: one reader -- a declared local resolves too (#987)" {
  # The two lints used to disagree about what an assignment IS. The pin
  # registry's regex accepts `local`; this driver's scanner marked it
  # unusable on sight. So a `tool-pin:` marker on a `local` produced a
  # record the watch reads and this lint refused -- one line, two verdicts.
  # There is one reader now, and this is what it says.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator_raw \
    '#!/usr/bin/env bash' \
    '_helper() {' \
    '  # tool-pin: unpinned monitor-checkout -- a major ref on purpose' \
    "  local _MONITOR_REF='actions/checkout@v7'" \
    '  echo "${_MONITOR_REF}"' \
    '}' \
    '_gen() {' \
    '  cat > "${_wf}" <<YAML' \
    '      - uses: ${_MONITOR_REF}' \
    'YAML' \
    '}'

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'v7'
  assert_output --partial 'v8'
}

# ── The population is derived, not a glob ───────────────────────────────

# why: A *.sh glob is a roster of file shapes, and the non-vacuity backstop cannot
# notice the gap because the one known generator keeps the count at 1
@test "generated-workflow-actions: a generator that is not named *.sh is scanned (#987)" {
  # `*.sh` is a roster of the file shapes a generator may take, and this
  # repo has retired that roster twice already for the same reason: an
  # extensionless script, a `.bash`, a justfile recipe writing a workflow
  # -- each is invisible, and the non-vacuity backstop cannot notice
  # because the one known generator keeps the count at 1.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator '      - uses: actions/checkout@v8'
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '_gen() {' \
    '  cat > "${_wf}" <<YAML' \
    '      - uses: actions/checkout@v3' \
    'YAML' \
    '}' \
    > "${SCRATCH}/dist/gen-workflow"

  _gwa_lint
  [ "${status}" -ne 0 ]
  assert_output --partial 'v3'
}

# why: This driver shares the pin registry's walk, so an untracked generator is
# outside its population too -- one population, not two that can drift (#987)
@test "generated-workflow-actions: ignores an UNTRACKED generator (#987)" {
  # `.claude/` is the agent harness a checkout may or may not carry, and
  # nothing tracks it here. It used to be exempt because the registry's
  # prune roster named it; it is exempt now because it is untracked, which
  # is the same verdict reached without a roster to keep. The property
  # being relied on is that this driver reads THE registry's population --
  # two walks over one tree with two exemption rules is how "the verdict
  # must not depend on whose machine it ran on" stops applying to half of
  # them.
  _load_driver
  _write_workflow 'actions/checkout@v8'
  _write_generator '      - uses: actions/checkout@v8'
  git -C "${SCRATCH}" add -A
  mkdir -p "${SCRATCH}/.claude/scripts"
  printf '      - uses: actions/checkout@v6\n' \
    > "${SCRATCH}/.claude/scripts/gen.sh"

  run _run_generated_workflow_actions
  [ "${status}" -eq 0 ]
  assert_output --partial '1 generated ref'
}

# ── The real tree ───────────────────────────────────────────────────────

# why: Drives the live tree, so the fixtures cannot drift away from what
# ships
@test "generated-workflow-actions: the real repo is in lockstep (#950)" {
  _load_driver
  REPO_ROOT=/source

  _gwa_lint
  [ "${status}" -eq 0 ]
  assert_output --partial 'clean'
}
