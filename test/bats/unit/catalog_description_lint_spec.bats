#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/catalog_description.sh -- the "a test
# says why its case matters" lint.
#
# why: The rule is base#922's and the first implementation was base#976's,
# which scanned the RENDERED catalogue. That made the rule opt-outable by
# table shape: a section answering with a summary took its tests out of a
# required field with every gate green, 1499 of 3700 on the tree this
# replaced it on. The population here is `^@test` over the spec trees, so
# there is no shape to hide behind, and these cases exist to keep it that
# way.
#
# The cases split into two kinds, and the split is the design. Everything
# spec-markers.sh REPORTS -- an orphan, a detached block, an unreadable
# `@test` line, a marker that says nothing -- fails at any count, because
# each is an edit somebody made. Only the ABSENCE of a marker is under the
# transition ceiling, because that is the debt the migration inherited.
#
# Detection runs against a controlled temp REPO_ROOT so the spec is
# independent of the live tree; a final case drives the REAL tree.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the function runs against a controlled scratch tree.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/catalog_description.sh

  SCRATCH="$(mktemp -d)"
  REPO_ROOT="${SCRATCH}"
  mkdir -p "${SCRATCH}/test/bats/unit"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _spec <name> <line>... -- write a fixture spec. printf, never a heredoc:
# a literal `@test` at column 0 anywhere in this file is picked up by bats'
# own preprocessor as a test definition of THIS file.
_spec() {
  local _name="$1"
  shift
  # The shebang and the blank line are not decoration: a `# why:` in the
  # file's OPENING comment run is the file blurb, and one that touches the
  # first `@test` is the ambiguity the reader reports. Every fixture here
  # is about a TEST's marker, so each one starts below a real file header.
  {
    printf '%s\n' '#!/usr/bin/env bats' ''
    printf '%s\n' "$@"
  } > "${SCRATCH}/test/bats/unit/${_name}"
}

# why: The clean line is the load-bearing part of this design, not the
# verdict. Slack is the cost the ceiling accepts, and a cost nobody can see
# is one nobody closes -- so the counts print on every run and this case
# pins that they do.
@test "_run_catalog_description: a fully described tree is clean and prints the counts" {
  _spec 'a_spec.bats' '# why: a real reason' '@test "a" {' '}'
  run _run_catalog_description
  assert_success
  assert_output --partial 'tests=1 described=1 undescribed=0'
  assert_output --partial 'catalog description lint: clean'
}

# why: The transition, stated out loud. Moving the rule from the row to the
# test enlarged the debt by definition, so an undescribed test under the
# ceiling is REPORTED in the counts and does not fail. Anyone reading this
# case sees the weakening rather than discovering it from a green run.
@test "_run_catalog_description: an undescribed test under the ceiling counts but does not fail" {
  _spec 'a_spec.bats' '@test "a" {' '}'
  run _run_catalog_description
  assert_success
  assert_output --partial 'tests=1 described=0 undescribed=1'
}

# why: The other half of the ceiling, and the one that makes it a guard at
# all. It fails, and it names every offender by `<spec>:<line>: <name>` --
# uncapped, because a truncated list is one somebody's test can fall off
# the end of.
@test "_run_catalog_description: breaching the ceiling FAILS and names the undescribed tests" {
  local _f="${SCRATCH}/test/bats/unit/big_spec.bats" _i
  : > "${_f}"
  for (( _i = 0; _i <= _CATALOG_DESC_UNDESCRIBED_CEILING; _i++ )); do
    printf '@test "t%s" {\n}\n' "${_i}" >> "${_f}"
  done
  run _run_catalog_description
  assert_failure
  assert_output --partial "undescribed=$(( _CATALOG_DESC_UNDESCRIBED_CEILING + 1 ))"
  assert_output --partial 'test/bats/unit/big_spec.bats:1: t0'
}

# why: The orphan is what a rename leaves behind, and it is the check that
# keeps the guard non-vacuous in the other direction: without it a
# description that will never render reads as a described test. It is NOT
# under the ceiling -- somebody wrote it.
@test "_run_catalog_description: a '# why:' block with no @test beneath it FAILS" {
  _spec 'a_spec.bats' '# why: described' '@test "a" {' '}' '' \
    '# why: left behind by a rename'
  run _run_catalog_description
  assert_failure
  assert_output --partial 'orphan'
}

# why: A bare `#` inside a block detaches the description from its test
# while leaving prose that still looks like one in the file. Nothing
# renders, and nothing else would report it.
@test "_run_catalog_description: a detached block FAILS" {
  _spec 'a_spec.bats' '# why: first half' '#' '# second half' '@test "a" {' '}'
  run _run_catalog_description
  assert_failure
  assert_output --partial 'detached'
}

# why: The non-answer floor. A cell that clears a red build without saying
# anything is the cheapest way out of one, so `-`, `TBD` and `...` are
# refused as the missing sentence wearing less ink -- and refused at any
# count, because writing one is an edit, not inherited debt.
@test "_run_catalog_description: a marker that says nothing FAILS at any count" {
  _spec 'a_spec.bats' '# why: TBD' '@test "a" {' '}'
  run _run_catalog_description
  assert_failure
  assert_output --partial 'empty-marker'
}

# why: An honest six-character description says something the test name
# does not, and this driver's own header argues that a guard whose false
# positives are the good rows is worse than no guard. The floor is "has a
# word in it", and this pins that the line is drawn there and not at a
# length.
@test "_run_catalog_description: a short but real description passes the floor" {
  _spec 'a_spec.bats' '# why: GPU on' '@test "a" {' '}'
  run _run_catalog_description
  assert_success
  assert_output --partial 'described=1'
}

# why: A `@test` line the canonical form cannot read is counted by the
# heading count and skipped by the reader, which would put the two out of
# step with every gate green. Failing closed here is what makes the
# refusal in spec-markers.sh reach a person.
@test "_run_catalog_description: an unreadable '@test' line FAILS" {
  _spec 'a_spec.bats' '@test "a name that' 'spans two lines" {' '}'
  run _run_catalog_description
  assert_failure
  assert_output --partial 'noncanonical'
}

# why: A scan that finds nothing must DIE, not report clean. This is the
# failure mode the whole repo keeps paying for: a relocated tree, a lint
# that quietly covers zero files, and a green line that reads as a verdict
# over the suite.
@test "_run_catalog_description: a spec-free scan root dies rather than passing vacuously" {
  run _run_catalog_description
  assert_failure
  assert_output --partial 'no spec files'
}

# why: The same non-vacuity in its other spelling -- a root that is not
# there at all. Reporting "0 undescribed" for a path that does not exist is
# the same false green with a different cause.
@test "_run_catalog_description: a nonexistent scan root dies, naming it" {
  REPO_ROOT="${SCRATCH}/nope"
  run _run_catalog_description
  assert_failure
  assert_output --partial 'does not exist'
}

# why: The one case that is about THIS tree rather than about a fixture:
# the ceiling in the driver has to match what the specs actually carry, or
# the number is a claim nobody checked. It also proves the lint passes on
# the tree it ships in, which no fixture can.
@test "_run_catalog_description: the real tree passes, at or under the declared ceiling" {
  REPO_ROOT=/source
  run _run_catalog_description
  assert_success
  assert_output --partial "ceiling=${_CATALOG_DESC_UNDESCRIBED_CEILING}"
  assert_output --partial 'catalog description lint: clean'
}
