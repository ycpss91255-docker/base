#!/usr/bin/env bats
#
# code_lines_spec.bats -- unit tests for the comment-stripped file views in
# test/bats/unit/test_helper.bash (strip_comments / only_comments /
# code_lines / code_grep / yaml_job_{text,lines} / yaml_top_{text,lines}),
# and for yaml_step_id_for, the step-scoped reader built on top of them.
#
# These helpers exist because a structural spec that greps a WHOLE file lets
# a string appearing only in a COMMENT satisfy an assertion about CODE, and
# the comments in this repo name, in prose, exactly what the specs assert
# about. Guards written that way stayed green while the property they named
# was deleted.
#
# The conversion has a mirror-image failure mode, and it is the more
# dangerous one: a stripper that also removes a line which is genuinely code
# turns a working guard into one that cannot match its subject -- the same
# defect with the sign flipped, and it fails CLOSED only until someone
# "fixes" the now-failing assertion by weakening it. So both directions are
# pinned here:
#
#   * UNDER-strict (the original defect): a comment-only line -- YAML,
#     Dockerfile, or a shell comment inside a `run: |` block scalar -- must
#     be gone.
#   * OVER-strict (the inverse): a `#` that follows anything else on the
#     line must survive. A trailing `# v1.2.2` after an action pin, a `#`
#     inside a quoted string, a `#` inside a block scalar's shell code --
#     those lines ARE code, and a naive `s/#.*//` would silently shorten
#     them into assertions that no longer match.
#
# The rule the helpers implement is deliberately the narrowest one that can
# be applied without parsing the host language: a line is a comment when its
# first non-blank character is `#`, and nothing else is touched.
#
# why: The comment-stripped file views in `test/bats/unit/test_helper.bash`
# (`strip_comments` / `only_comments` / `code_lines` / `code_grep` /
# `yaml_job_{text,lines}` / `yaml_top_{text,lines}` / `yaml_step_id_for`),
# which the workflow and template structural specs assert against instead of
# the raw file.
#
# They exist because a spec that greps a WHOLE file lets a string appearing
# only in a COMMENT satisfy an assertion about CODE, and this repo's
# comments name in prose exactly what its specs pin. Measured, not
# theorised: deleting both real `_transcript_begin` / `_transcript_detach`
# calls from `setup_tui.sh`, the active `logging.sh` COPY from the template
# Dockerfile, and `hook.sh`'s `DRY_RUN` early return each left the guard
# named for it green, matching a comment instead.
#
# The conversion has a mirror-image failure mode, and it is the more
# dangerous one: a stripper that also eats a line which is genuinely code
# turns a working guard into one that cannot match its subject -- and the
# natural "fix" for the resulting red is to weaken the assertion. Both
# directions are therefore pinned here, against one fixture carrying every
# shape that can be got wrong.
#
# A third direction is pinned alongside them: the STATUS these views hand
# back. `grep` prints the same nothing for "this file has no such line" and
# for "there was no file", and the guards in this tree branch on that status
# to tell the two apart -- so a subject that was renamed away must arrive as
# 2 (not read) rather than as 1 (read, no match), and an all-comment file
# must still arrive as 1.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  SCRATCH="$(mktemp -d)"
  FIXTURE="${SCRATCH}/workflow.yaml"
  cat > "${FIXTURE}" << 'YAML'
# A leading comment paragraph naming delete-package-versions, the action
# this workflow must never use.
on:
  # An indented comment inside a top-level block.
  schedule:
    - cron: '17 4 * * 0'

env:
  MARKER: keep-me

jobs:
  build:
    # A comment paragraph inside the job, explaining that `docker tag`
    # cannot add a label.
    runs-on: ubuntu-latest
    steps:
      - uses: dataaxiom/ghcr-cleanup-action@0123456789abcdef # v1.2.2
        with:
          heading: "a # inside a double-quoted string"
          fragment: 'a # inside a single-quoted string'
      - name: Run
        run: |
          # A shell comment inside a block scalar.
          echo "# not a comment: a markdown heading"
          printf 'colour=#ff0000\n'
          docker build -q -t "${IMG}" -

  other:
    runs-on: ubuntu-latest
YAML

  STEPS="${SCRATCH}/steps.yaml"
  cat > "${STEPS}" << 'YAML'
jobs:
  acceptance:
    runs-on: ubuntu-latest
    env:
      ABOVE: ./above-the-steps.sh
    steps:
      - name: Resolve the pin
        id: resolver
        run: |
          printf 'version=%s\n' "$(./accessor.sh)"
      - name: Consume it
        uses: some/setup-action@v4
        with:
          version: ${{ steps.resolver.outputs.version }}
      # A comment paragraph that names ./commented-only.sh, which no step
      # in this job runs.
      - name: A later step that carries no id
        run: |
          echo "a later mention of ./accessor.sh"
      - name: Nested lists live INSIDE a step
        id: nested_owner
        uses: other/action@v4
        with:
          args:
            - --marker
            - ./nested-only.sh
      - name: An action input that happens to be called id
        uses: third/action@v4
        with:
          id: not-a-step-id
          script: ./with-input-only.sh
    outputs:
      note: ./below-the-steps.sh

  other:
    runs-on: ubuntu-latest
    steps:
      - name: A step in a different job
        id: elsewhere
        run: ./other-job-only.sh
YAML

  # The job's FIRST sequence dash is SHALLOWER than its step dashes. Both
  # spellings below are valid YAML and valid GitHub Actions; each is the
  # ordinary way somebody writes the key it uses.
  #
  #   SHALLOW -- a block-style `needs:` sits at the job-key indent (4),
  #              two levels above the step dashes (6).
  #   DEEP    -- a `strategy.matrix` sequence written at its parent's
  #              indent (6) sits above a steps list indented one level
  #              deeper than usual (8).
  SHALLOW="${SCRATCH}/shallow-first-dash.yaml"
  cat > "${SHALLOW}" << 'YAML'
jobs:
  acceptance:
    needs:
    - actionlint
    - classify
    steps:
      - name: Resolve the pin
        id: resolver
        run: ./accessor.sh
      - name: A later step that carries no id
        run: |
          echo "a later mention of ./accessor.sh"
YAML

  DEEP="${SCRATCH}/deep-steps.yaml"
  cat > "${DEEP}" << 'YAML'
jobs:
  acceptance:
    strategy:
      matrix:
      - os: ubuntu-latest
    steps:
        - name: Resolve the pin
          id: resolver
          run: ./accessor.sh
        - name: A later step that carries no id
          run: |
            echo "a later mention of ./accessor.sh"
YAML
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# ── UNDER-strict direction: comment-only lines are gone ──────────────

# why: The base case: a file-header paragraph naming the action the workflow
# must never use
@test "code_lines: drops an unindented comment-only line" {
  run code_lines "${FIXTURE}"
  assert_success
  refute_output --partial 'delete-package-versions'
}

# why: The form that matters most -- a workflow's explanatory prose sits at
# the indentation of the block it explains
@test "code_lines: drops an INDENTED comment-only line" {
  # The form that matters most: a workflow's explanatory paragraphs sit
  # inside the block they explain, at the block's own indentation.
  run code_lines "${FIXTURE}"
  assert_success
  refute_output --partial 'An indented comment inside a top-level block'
}

# why: A `#` line inside a `run:` block scalar is a shell comment: prose, in
# the exact place a workflow explains the command it is about to run
@test "code_lines: drops a shell comment inside a run: block scalar" {
  # A `#` line inside `run: |` is a shell comment: prose, in the exact
  # place a workflow explains the command it is about to run.
  run code_lines "${FIXTURE}"
  assert_success
  refute_output --partial 'A shell comment inside a block scalar'
}

# why: Blank lines are neither code nor documentation and would pad any
# count assertion
@test "code_lines: drops blank lines" {
  local _blank
  _blank="$(code_lines "${FIXTURE}" | grep -c '^[[:space:]]*$' || true)"
  [ "${_blank}" -eq 0 ] || fail "code_lines emitted ${_blank} blank line(s)"
}

# why: The live hazard in this repo's template Dockerfile: the same COPY
# appears twice, once active and once as a worked example
@test "code_lines: drops a Dockerfile comment, including a commented-out directive" {
  # The commented-out worked example is the live hazard in this repo's
  # Dockerfile: the same COPY appears twice, once active and once as prose.
  local _df="${SCRATCH}/Dockerfile"
  cat > "${_df}" << 'DOCKERFILE'
# A worked example of the runtime stage:
# COPY --chmod=0755 lib/logging.sh /usr/local/lib/base/logging.sh
COPY --chmod=0755 lib/logging.sh /usr/local/lib/base/logging.sh
DOCKERFILE
  run code_lines "${_df}"
  assert_success
  assert_output 'COPY --chmod=0755 lib/logging.sh /usr/local/lib/base/logging.sh'
}

# ── OVER-strict direction: real code survives intact ─────────────────

# why: Over-strict direction. The `# v1.2.2` after a pinned action SHA is
# code's, not prose's -- a spec asserts the pin and its version comment
# together
@test "code_lines: keeps a trailing comment on a code line, verbatim" {
  # The `# v1.2.2` after a pinned action SHA is the form Dependabot
  # rewrites on bump; a stripper that removed it would break the spec that
  # asserts the pin and its version comment together.
  run code_lines "${FIXTURE}"
  assert_success
  assert_output --partial 'uses: dataaxiom/ghcr-cleanup-action@0123456789abcdef # v1.2.2'
}

# why: Over-strict direction. A naive `s/#.*//` would silently shorten the
# line into something no assertion matches
@test "code_lines: keeps a # inside a double-quoted string" {
  run code_lines "${FIXTURE}"
  assert_success
  assert_output --partial 'heading: "a # inside a double-quoted string"'
}

# why: Same, for the other quoting style
@test "code_lines: keeps a # inside a single-quoted string" {
  run code_lines "${FIXTURE}"
  assert_success
  assert_output --partial "fragment: 'a # inside a single-quoted string'"
}

# why: `echo "# heading"` is code whose payload opens with a hash; the
# line's first non-blank character is `e`, so it stays
@test "code_lines: keeps a block-scalar line whose STRING starts with #" {
  # `echo "# ..."` is code whose payload happens to open with a hash. The
  # first non-blank character of the LINE is `e`, so it stays.
  run code_lines "${FIXTURE}"
  assert_success
  assert_output --partial 'echo "# not a comment: a markdown heading"'
}

# why: A colour literal, a fragment, an anchor -- a `#` mid-value never
# begins a comment
@test "code_lines: keeps a # that is part of a value, not a comment" {
  run code_lines "${FIXTURE}"
  assert_success
  assert_output --partial "printf 'colour=#ff0000\\n'"
}

# ── code_grep ────────────────────────────────────────────────────────

# why: The defect itself, at the call site every converted spec uses
@test "code_grep: a string present only in a comment does not match" {
  run code_grep -F 'delete-package-versions' "${FIXTURE}"
  assert_failure
}

# why: Non-vacuity: the filter must still find what is really there
@test "code_grep: a string present in code does match" {
  run code_grep -F 'MARKER: keep-me' "${FIXTURE}"
  assert_success
}

# why: The signature mirrors grep's own, so a conversion is a one-word edit;
# `-c` counts over code lines only
@test "code_grep: passes its flags through and takes the file last" {
  run code_grep -cE '^ +runs-on: ubuntu-latest$' "${FIXTURE}"
  assert_success
  assert_output '2'
}

# why: grep prints the same nothing for "no match" and for "no file", so the
# status has to split them: 1 is a readable subject without the string, 2 is
# a subject that was never read
@test "code_grep: a subject it cannot read exits 2, not grep's no-match status" {
  # The two readings a caller must never confuse. `grep` prints the same
  # nothing for "this file does not contain the string" and for "there was
  # no file", and the whole pipeline's status is grep's -- so a subject that
  # was renamed away arrives at the caller as status 1 and is counted as a
  # file that simply lacks the string. Every least-privilege guard in this
  # tree branches on exactly that status, so the split has to be real:
  # 1 is a readable subject with no match, 2 is a subject that was not read.
  run code_grep -F 'MARKER: keep-me' "${SCRATCH}/no-such-file.yaml"
  [ "${status}" -eq 2 ] \
    || fail "code_grep exited ${status} for a missing file; expected 2, and 1 would be read as 'no match'"
}

# why: The sibling shape: the redirection fails rather than the file being
# absent, and bash's own status for that is 1 as well
@test "code_grep: a directory named as the subject exits 2, not 1" {
  # The sibling shape of the same mistake: the redirection fails rather than
  # the file being absent, and bash's status for that is 1 as well.
  run code_grep -F 'MARKER: keep-me' "${SCRATCH}"
  [ "${status}" -eq 2 ] \
    || fail "code_grep exited ${status} for a directory; expected 2, and 1 would be read as 'no match'"
}

# why: code_grep's stdout is grep's -- lines, or a count under `-c` -- so
# the reason a subject could not be read goes to stderr beside the status,
# never into the data a caller counts
@test "code_grep: an unreadable subject reports on stderr, leaving the grep-shaped output empty" {
  # code_grep's stdout is DATA -- lines, or a count under `-c` -- and every
  # call site reads it as such: `assert_output '2'`, an arithmetic
  # comparison, a `| head -1`. A `BUG:` line printed there arrives as a
  # match that is not a match and as a count that is not a number. The
  # status (2) is what says the subject was not read, and the reason
  # belongs on stderr next to it.
  #
  # code_lines is deliberately the other way round: its stdout IS its
  # report, and its callers print what they captured. So the split is
  # written here in both directions rather than left to whoever reads one
  # of them next.
  run --separate-stderr code_grep -c 'MARKER: keep-me' "${SCRATCH}/no-such-file.yaml"
  [ "${status}" -eq 2 ] \
    || fail "code_grep exited ${status} for a missing file; expected 2"
  assert_output ''
  [[ "${stderr}" == *'BUG:'* ]] \
    || fail "expected a BUG: line on stderr, got: ${stderr}"
}

# why: The sibling shape: the redirection fails rather than the file being
# absent, and a caller counting matches must not receive prose either way
@test "code_grep: a directory subject reports the same way, on stderr" {
  # The sibling shape of the same statement: the redirection fails rather
  # than the file being absent, and a caller counting matches must not
  # receive prose either way.
  run --separate-stderr code_grep -c 'MARKER: keep-me' "${SCRATCH}"
  [ "${status}" -eq 2 ] \
    || fail "code_grep exited ${status} for a directory; expected 2"
  assert_output ''
  [[ "${stderr}" == *'BUG:'* ]] \
    || fail "expected a BUG: line on stderr, got: ${stderr}"
}

# why: The complement, so the split cannot spread by symmetry: code_lines'
# stdout IS its report, and its callers print what they captured
@test "code_lines: an unreadable subject keeps its BUG line on stdout" {
  # The complement, pinned so the change above cannot spread by symmetry.
  # code_lines is the reporting view: `spec_permission_surface_subjects`
  # captures it and PRINTS what it captured when the status says the file
  # was not read, which is how the reason reaches a caller reading a
  # pipeline where the status is already gone.
  run --separate-stderr code_lines "${SCRATCH}/no-such-file.yaml"
  [ "${status}" -eq 2 ] \
    || fail "code_lines exited ${status} for a missing file; expected 2"
  assert_output --partial 'BUG:'
}

# why: The other emitter of the same status; code_grep reads this one's, so
# both draw the line in the same place
@test "code_lines: a subject it cannot read exits 2, not 1" {
  # The other emitter of the same status. code_grep reads code_lines', so
  # both have to draw the line in the same place or the pipeline re-merges
  # the two readings one level down.
  run code_lines "${SCRATCH}/no-such-file.yaml"
  [ "${status}" -eq 2 ] \
    || fail "code_lines exited ${status} for a missing file; expected 2"
}

# why: The complement, so the fix cannot be "return 2 whenever nothing came
# back": an all-comment file HAS been read
@test "code_lines: a readable file with no code line exits 1, not 2" {
  # The complement, so the fix cannot be "return 2 whenever nothing came
  # back". A file that is all comments HAS been read, and its emptiness is
  # a fact about the file rather than a failed scan.
  local _all_comments="${SCRATCH}/comments-only.yaml"
  printf '# only prose\n\n# and more prose\n' > "${_all_comments}"
  run code_lines "${_all_comments}"
  [ "${status}" -eq 1 ] \
    || fail "code_lines exited ${status} for an all-comment file; expected 1"
  assert_output ''
}

# ── only_comments: the mirror ────────────────────────────────────────

# why: The mirror view, for the rare assertion genuinely about what a file
# SAYS
@test "only_comments: keeps the comment-only lines and nothing else" {
  local _out
  _out="$(only_comments < "${FIXTURE}")"
  [[ "${_out}" == *'delete-package-versions'* ]] \
    || fail "only_comments dropped an unindented comment"
  [[ "${_out}" == *'An indented comment inside a top-level block'* ]] \
    || fail "only_comments dropped an indented comment"
  [[ "${_out}" != *'MARKER: keep-me'* ]] \
    || fail "only_comments kept a code line"
}

# why: No line may be dropped by both filters or counted by both -- the
# invariant that makes "code" and "documentation" an exhaustive split
@test "only_comments: is the exact complement of strip_comments" {
  # Together the two filters must reproduce the file's non-blank lines --
  # no line may be dropped by both, and none counted by both.
  local _code _comments _all
  _code="$(strip_comments < "${FIXTURE}" | wc -l)"
  _comments="$(only_comments < "${FIXTURE}" | wc -l)"
  _all="$(grep -cvE '^[[:space:]]*$' "${FIXTURE}")"
  [ "$(( _code + _comments ))" -eq "${_all}" ] \
    || fail "code ${_code} + comments ${_comments} != non-blank ${_all}"
}

# why: A trailing-comment line belongs to the code view alone; counting it
# as documentation would let a pin's version comment satisfy a prose
# assertion
@test "only_comments: keeps a trailing-comment line out of the comment view" {
  # A line with a trailing comment belongs to the CODE view and to it
  # alone; counting it as documentation would let a pin's version comment
  # satisfy a prose assertion.
  local _out
  _out="$(only_comments < "${FIXTURE}")"
  [[ "${_out}" != *'ghcr-cleanup-action@'* ]] \
    || fail "only_comments claimed a trailing-comment code line"
}

# ── block extractors ─────────────────────────────────────────────────

# why: The workflow specs' main entry point, replacing the awk block
# extractor each file used to carry
@test "yaml_job_lines: returns the job's code and drops its comment paragraph" {
  run yaml_job_lines "${FIXTURE}" build
  assert_success
  assert_output --partial 'runs-on: ubuntu-latest'
  refute_output --partial 'cannot add a label'
}

# why: Block scoping: an assertion about one job must not be satisfied by
# the next
@test "yaml_job_lines: stops at the next job" {
  run yaml_job_lines "${FIXTURE}" build
  assert_success
  refute_output --partial 'other:'
}

# why: The escape hatch. Keeping it a separate call makes "asserted against
# a comment" a visible choice
@test "yaml_job_text: keeps the job's comment paragraph verbatim" {
  # The escape hatch for the rare assertion that is genuinely about what a
  # workflow SAYS. Keeping it separate makes that a visible choice.
  run yaml_job_text "${FIXTURE}" build
  assert_success
  assert_output --partial 'cannot add a label'
}

# why: `on` / `env` / `permissions` / `concurrency`; a comment paragraph
# between two top-level keys is not indented out by the terminator
@test "yaml_top_lines: returns a top-level block's code without the prose between keys" {
  run yaml_top_lines "${FIXTURE}" on
  assert_success
  assert_output --partial "cron: '17 4 * * 0'"
  refute_output --partial 'An indented comment'
}

# why: Block scoping for the top-level mappings
@test "yaml_top_lines: stops at the next top-level key" {
  run yaml_top_lines "${FIXTURE}" env
  assert_success
  assert_output --partial 'MARKER: keep-me'
  refute_output --partial 'runs-on'
}

# why: The verbatim counterpart, for symmetry with `yaml_job_text`
@test "yaml_top_text: keeps the block's comments" {
  run yaml_top_text "${FIXTURE}" on
  assert_success
  assert_output --partial 'An indented comment'
}

# ── step-id derivation ───────────────────────────────────────────────
#
# `yaml_step_id_for` exists so an assertion can say "the consumer reads THE
# STEP THAT DID THE WORK" rather than the weaker "some step output reaches
# the consumer". Its predecessor was an inline awk that carried the last
# `id:` it had seen forward across step boundaries, so a match in a LATER,
# id-less step came back wearing an EARLIER step's id, and the assertion
# built on it vouched for a step that no longer contained its subject. Every
# case below that expects no output is that same fail-open direction closed:
# an unrecognised shape yields an empty id, and the caller's `[ -n ... ]`
# guard turns that into a loud failure.

# why: The step id an assertion needs to say "the consumer reads THE STEP
# THAT DID THE WORK", derived from the file so a rename moves the assertion
# with it
@test "yaml_step_id_for: names the step whose own body matches" {
  run yaml_step_id_for "${STEPS}" acceptance './accessor[.]sh'
  assert_success
  assert_output 'resolver'
}

# why: The regression it was extracted for: the inline awk carried the last
# id forward across step boundaries, so a match in a later id-less step wore
# an earlier step's id and the assertion vouched for a step that no longer
# contained its subject
@test "yaml_step_id_for: an id-less matching step yields nothing, it does not borrow the id of an earlier step" {
  # The regression this helper was extracted for: the mention lives in the
  # third step, which has no id at all. Answering `resolver` here is what
  # let the acceptance job restate the pinned version as a literal while
  # the guard still reported that the consumer read the resolve step.
  run yaml_step_id_for "${STEPS}" acceptance 'a later mention'
  assert_success
  assert_output ''
}

# why: The inverse mistake: resetting on every sequence dash loses the id of
# a step whose match sits in a `with:` list. Only a dash at the step indent
# is a boundary
@test "yaml_step_id_for: a nested list inside a step is not a step boundary" {
  # The inverse mistake: resetting on EVERY sequence dash would lose the id
  # of a step whose match sits in a `with:` list. That direction fails
  # closed, but it fails on shapes that are perfectly ordinary.
  run yaml_step_id_for "${STEPS}" acceptance './nested-only[.]sh'
  assert_success
  assert_output 'nested_owner'
}

# why: It reads the job's code lines, so the same prose hazard the rest of
# this file exists for cannot name a step either
@test "yaml_step_id_for: a match in a comment cannot name a step" {
  run yaml_step_id_for "${STEPS}" acceptance './commented-only[.]sh'
  assert_success
  assert_output ''
}

# why: An unattributable match is answered with an empty id, never a guessed
# one; the caller's `[ -n ... ]` turns that into a loud failure
@test "yaml_step_id_for: a pattern that matches nowhere in the job yields nothing" {
  run yaml_step_id_for "${STEPS}" acceptance './absent[.]sh'
  assert_success
  assert_output ''
}

# why: Job scoping, inherited from `yaml_job_lines`: a step in a
# neighbouring job cannot supply this job's id
@test "yaml_step_id_for: does not reach into another job for its match" {
  run yaml_step_id_for "${STEPS}" acceptance './other-job-only[.]sh'
  assert_success
  assert_output ''
}

# ── the steps list is the anchor, not "the shallowest dash so far" ───
#
# The rule above was once "a dash at the shallowest indent the job has
# shown", latched from the job's FIRST dash. That reads the boundary off
# whichever list the job happened to write first, and a job's first list is
# not always its steps: a block-style `needs:`, or a `strategy.matrix`
# sequence above a deeper-indented steps list, puts a dash ABOVE the step
# indent. No step dash then counted as a boundary, so one id was carried
# across every step in the job -- byte for byte the fail-open the helper was
# extracted to close, and invisible because both spellings are ordinary
# YAML that actionlint accepts.
#
# The boundary is therefore taken from the first dash AFTER the `steps:`
# key. Each shape below is pinned in both directions: the id-less step must
# yield nothing, AND the step that really matches must still be named -- a
# helper that answered "" to everything would satisfy the first assertion
# alone.

# why: The escape the #948 fix left open: taking the boundary from the
# shallowest dash the job had shown read it off the block-style `needs:` at
# indent 4, so no step dash at 6 was ever a boundary and one id ran the
# length of the job
@test "yaml_step_id_for: a block-style needs: above the steps is not the step indent (#993)" {
  run yaml_step_id_for "${SHALLOW}" acceptance 'a later mention'
  assert_success
  assert_output ''
}

# why: Non-vacuity for the row above -- a helper that answered nothing to
# everything would satisfy it, and refusing every shape is the same guard
# deleted
@test "yaml_step_id_for: the matching step is still named when a block-style needs: precedes it (#993)" {
  run yaml_step_id_for "${SHALLOW}" acceptance './accessor[.]sh'
  assert_success
  assert_output 'resolver'
}

# why: The same escape without `needs:`: a `strategy.matrix` sequence
# written at its parent's indent, above a steps list indented one level
# deeper. The anchor is the `steps:` key, not any one spelling
@test "yaml_step_id_for: a shallower list above a deeper steps list is not the step indent (#993)" {
  run yaml_step_id_for "${DEEP}" acceptance 'a later mention'
  assert_success
  assert_output ''
}

# why: Non-vacuity for the row above, on the second shape
@test "yaml_step_id_for: the matching step is still named when a shallower list precedes a deeper steps list (#993)" {
  run yaml_step_id_for "${DEEP}" acceptance './accessor[.]sh'
  assert_success
  assert_output 'resolver'
}

# why: `id` is an ordinary action input; read as the step's own key it
# renames the step to a string no `steps.<id>.outputs` reference resolves. A
# step's own keys sit at the indent its dash set, a `with:` input deeper
@test "yaml_step_id_for: an action input named id does not become the step name (#993)" {
  # `id` is an ordinary input name for an action. Read as the step's own
  # key it renames the step to a string no `steps.<id>.outputs` reference
  # can resolve -- an id the function invented rather than read.
  run yaml_step_id_for "${STEPS}" acceptance './with-input-only[.]sh'
  assert_success
  assert_output ''
}

# why: The job keys above `steps:` are outside the region the helper can
# attribute, so nothing there is answered with an id
@test "yaml_step_id_for: a match above the job's first step names no step (#993)" {
  run yaml_step_id_for "${STEPS}" acceptance './above-the-steps[.]sh'
  assert_success
  assert_output ''
}

# why: The other end of that region: a job key after the steps list ends
# attribution, so the id of the last step does not follow the scan out
@test "yaml_step_id_for: a match below the steps list names no step (#993)" {
  # A job key AFTER the steps list is out of the region again; the last
  # step's id must not follow the scan out of it.
  run yaml_step_id_for "${STEPS}" acceptance './below-the-steps[.]sh'
  assert_success
  assert_output ''
}
