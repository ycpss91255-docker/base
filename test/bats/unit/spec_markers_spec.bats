#!/usr/bin/env bats
#
# Unit tests for script/test/spec-markers.sh -- the ONE reader of the
# `# why:` description markers a spec file carries beside its tests.
#
# why: The grammar this reader implements is the whole of the contract
# between an author and doc/test/*.md: a description is authored on the
# lines above the `@test` and rendered from there, so what counts as
# "attached", what counts as a continuation and what counts as detached
# decides whether a sentence reaches the catalogue at all.
#
# Both the generator and the description lint call this one function, so a
# case here is a case for both. That is deliberate -- a second copy of the
# attachment loop would agree on the day it was pasted and drift
# afterwards, which is the defect class the whole change removes.
#
# The findings get as much room as the happy path because each one is a
# silent failure otherwise: a detached block still looks like a
# description in the file and renders as nothing, and an orphan is what a
# rename leaves behind.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  READER="/source/script/test/spec-markers.sh"
}

# _scan <line>... -- write the lines as a fixture spec and scan it. Records
# come back with TABs rendered as `~` so an assertion can name a whole one.
_scan() {
  local _f="${BATS_TEST_TMPDIR}/a_spec.bats"
  printf '%s\n' "$@" > "${_f}"
  run bash -c '
    source "$1"
    declare -a T=() F=()
    B=""
    _spec_markers_scan "$2" T F B
    printf "BLURB:%s\n" "${B}"
    (( ${#T[@]} )) && printf "TEST:%s\n" "${T[@]}"
    (( ${#F[@]} )) && printf "FIND:%s\n" "${F[@]}"
    true
  ' _ "${READER}" "${_f}" 
  output="${output//$'\t'/\~}"
}

# why: The ordinary case, and the one every other case is a deviation
# from: one comment line, one test, the prose arriving as that test's
# description with the marker flag set.
@test "_spec_markers_scan: a one-line block above a test is that test's description" {
  _scan '#!/usr/bin/env bats' '' '# why: the load-bearing case' \
    '@test "a" {' '  true' '}'
  assert_success
  assert_output --partial 'TEST:4~1~a~the load-bearing case'
}

# why: Multi-line is what makes the marker usable at this tree's ~76-column
# norm; if continuations were dropped rather than joined, every description
# longer than one line would silently lose its tail.
@test "_spec_markers_scan: continuation lines join with a single space" {
  _scan '#!/usr/bin/env bats' '' \
    '# why: an empty scan root is how this lint silently stopped' \
    '# covering anything -- it must fail, not pass over nothing.' \
    '@test "a" {' '}'
  assert_success
  assert_output --partial 'an empty scan root is how this lint silently stopped covering anything -- it must fail, not pass over nothing.'
}

# why: The block starts at `# why:`, not at the top of the comment run.
# Without that, the section dividers this tree already uses would be
# swallowed into the description of whichever test follows them.
@test "_spec_markers_scan: comment lines ABOVE the marker are not part of it" {
  _scan '#!/usr/bin/env bats' '' '# -- a divider --' '# why: only this' \
    '@test "a" {' '}'
  assert_success
  assert_output --partial 'TEST:5~1~a~only this'
  refute_output --partial 'divider'
}

# why: A blank line is what separates a block from its test, and the
# failure it causes is invisible: the prose is still in the file, still
# reads as a description, and reaches nothing. Both halves are asserted --
# the test comes back UNMARKED and the block is reported as an orphan --
# because either one alone would let the other regress.
@test "_spec_markers_scan: a blank line between block and test detaches it, and the block is an orphan" {
  _scan '#!/usr/bin/env bats' '' '# why: stranded' '' '@test "a" {' '}'
  assert_success
  assert_output --partial 'TEST:5~0~a~'
  assert_output --partial 'FIND:3~orphan~'
}

# why: A bare `#` inside a block is how a description detaches without a
# blank line, and it is the shape a re-wrap or a paste produces. It is a
# finding rather than a paragraph break precisely because it looks like
# formatting.
@test "_spec_markers_scan: a bare '#' inside a test's block is a detached finding" {
  _scan '#!/usr/bin/env bats' '' '# why: first half' '#' '# second half' \
    '@test "a" {' '}'
  assert_success
  assert_output --partial 'FIND:4~detached~'
}

# why: Two markers for one test are two answers, and the renderer can only
# use one. Reporting it is what keeps the second from being silently
# absorbed into the first as prose.
@test "_spec_markers_scan: a second '# why:' inside one block is a nested-marker finding" {
  _scan '#!/usr/bin/env bats' '' '# why: first' '# why: second' \
    '@test "a" {' '}'
  assert_success
  assert_output --partial 'FIND:4~nested-marker~'
}

# why: THE load-bearing case for the counts. The per-spec heading count is
# `grep -c '^@test'`, so a line the counter counts and the reader skips
# would put the heading and the rows out of step with every gate green.
# The reader opens on the counter's own anchor and REFUSES what it cannot
# read; it must not quietly pass over it.
@test "_spec_markers_scan: a '@test' line the canonical form cannot read is a finding, not a skip" {
  _scan '#!/usr/bin/env bats' '' '@test "a name that' 'spans two lines" {' '}'
  assert_success
  assert_output --partial 'FIND:3~noncanonical~'
  refute_output --partial 'TEST:'
}

# why: The file-level block is the section blurb, and it is told apart from
# a test's description by POSITION alone -- so the opening comment run has
# to be read as its own site rather than as the first test's marker.
@test "_spec_markers_scan: a '# why:' in the opening comment run is the file blurb" {
  _scan '#!/usr/bin/env bats' '#' '# a_spec.bats - fixture.' \
    '# why: what this file covers' '' 'bats_require_minimum_version 1.5.0' \
    '' '@test "a" {' '}'
  assert_success
  assert_output --partial 'BLURB:what this file covers'
  assert_output --partial 'TEST:8~0~a~'
}

# why: Twenty-one section blurbs in this tree are two or more paragraphs.
# Flattening them would destroy structure the generator can reproduce
# exactly, so a bare `#` means something different here than it does above
# a test -- there is no `@test` beneath it to detach from.
@test "_spec_markers_scan: a bare '#' in the FILE block is a paragraph break, not a finding" {
  _scan '#!/usr/bin/env bats' '# why: first paragraph' '#' '# second paragraph' \
    '' 'setup() { :; }' '' '@test "a" {' '}'
  assert_success
  assert_output --partial 'BLURB:first paragraph'
  assert_output --partial 'second paragraph'
  refute_output --partial 'detached'
}

# why: When the opening run touches the first `@test`, the file blurb and
# that test's description are the same lines and no reading of them is
# right. Guessing either way would put the generator and the lint on
# different answers, so the ambiguity is reported and the positional rule
# (attached wins) is applied deterministically.
@test "_spec_markers_scan: an opening run touching the first @test is an ambiguous-blurb finding" {
  _scan '#!/usr/bin/env bats' '# why: ambiguous' '@test "a" {' '}'
  assert_success
  assert_output --partial 'FIND:2~ambiguous-blurb~'
  assert_output --partial 'BLURB:'
  assert_output --partial 'TEST:3~1~a~ambiguous'
}

# why: A row's identity is the name bats reports, so a row can be pasted
# into `--filter`. The unescaping has to happen in the reader, because the
# reader is now the only thing that sees the raw `@test` line.
@test "_spec_markers_scan: a backslash-escaped name resolves to what bats reports" {
  _scan '#!/usr/bin/env bats' '' '# why: escaped' \
    '@test "says \"hi\" loudly" {' '}'
  assert_success
  assert_output --partial 'TEST:4~1~says "hi" loudly~escaped'
}

# why: A file with no markers at all must come back empty rather than
# failing: the reader answers about one path, and only the CALLER knows
# whether an empty answer is vacuous.
@test "_spec_markers_scan: a spec with no markers yields tests, no blurb and no findings" {
  _scan '#!/usr/bin/env bats' '' '@test "a" {' '}' '' '@test "b" {' '}'
  assert_success
  assert_output --partial 'BLURB:'
  assert_output --partial 'TEST:3~0~a~'
  assert_output --partial 'TEST:6~0~b~'
  refute_output --partial 'FIND:'
}
