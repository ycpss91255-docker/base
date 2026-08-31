#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/changelog_entry.sh -- the "an
# [Unreleased] changelog entry is not a PR body" lint.
#
# This repo already decided that the PR body is the canonical decision
# record, enforced by a hook on `gh pr create`. The reasoning, the
# alternatives considered and the measurements belong there, and the
# changelog entry already links to it by number. What drifted is that the
# same prose got pasted into the changelog too, so the argument lives twice
# and the changelog copy is the one nobody can read.
#
# Two design decisions this spec pins, both measured rather than argued:
#
#   - The measure is the whole ENTRY, not a line. A per-line cap is
#     satisfiable by rewrapping the same text, which improves nothing; an
#     entry is the lead bullet plus every continuation line and sub-bullet
#     up to the next top-level bullet or heading, so neither rewrapping nor
#     re-shaping the same prose into a sub-list buys any budget. The two
#     "rewrapped / re-shaped text still fails" cases below are the ones
#     that make that claim testable rather than asserted.
#
#   - Whitespace is COLLAPSED before counting. Counting raw bytes would
#     charge an author for wrapping at 79 columns and for indenting a
#     sub-list -- i.e. it would reward the single unwrapped 6000-character
#     line that made the file unreadable in the first place. The measure is
#     therefore invariant under re-indentation and re-wrapping, which is
#     asserted in both directions.
#
# Scope is the `[Unreleased]` section ALONE. A released section is a
# historical record and rewriting a shipped entry falsifies it -- and that
# scoping is also what keeps the lint honest, since it governs only the
# section still being written and so can never fail on something nobody is
# allowed to fix. The section ends at the next `## [` heading; a lint that
# walks past that boundary into a released section is the failure mode
# here, so it gets its own case.
#
# Detection runs against a controlled temp REPO_ROOT so the spec is
# independent of the live tree's contents; a final case drives the REAL
# tree. Shape mirrors home_literal_lint_spec.bats / i18n_orphan_lint_spec.bats.

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
  source /source/script/test/drivers/changelog_entry.sh

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/doc/changelog"
  REPO_ROOT="${SCRATCH}"
  CHANGELOG="${SCRATCH}/doc/changelog/CHANGELOG.md"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _write_changelog <line>... -- a scratch CHANGELOG with the standard
# preamble, the [Unreleased] heading, the given lines, and a released
# section after them so every case also exercises the section boundary.
_write_changelog() {
  {
    printf '# Changelog\n\n'
    printf 'All notable changes to this project will be documented in this file.\n\n'
    printf '## [Unreleased]\n\n'
    [[ $# -gt 0 ]] && printf '%s\n' "$@"
    printf '\n## [v0.1.0] - 2026-03-28\n\n'
    printf '### Added\n'
    printf -- '- initial release\n'
  } > "${CHANGELOG}"
}

# _chars <n> -- n spaceless characters, for building an entry of an exact
# measured length.
_chars() {
  printf '%*s' "${1}" '' | tr ' ' 'x'
}

# _long_prose -- ~900 characters of realistic multi-sentence prose with
# spaces, the shape a pasted PR body actually takes.
_long_prose() {
  local _i _out=''
  for _i in $(seq 1 30); do
    _out+="This sentence explains a rejected alternative in detail. "
  done
  printf '%s' "${_out}"
}

# ════════════════════════════════════════════════════════════════════
# _run_changelog_entry: findings in [Unreleased]
# ════════════════════════════════════════════════════════════════════

@test "_run_changelog_entry: FAILS on an [Unreleased] entry over the cap (#917)" {
  _write_changelog '### Added' "- **a thing** -- $(_long_prose)"
  run _run_changelog_entry
  assert_failure
  assert_output --partial 'a thing'
}

@test "_run_changelog_entry: names the entry's line, its measured length and the cap (#917)" {
  _write_changelog '### Added' "- **a thing** -- $(_long_prose)"
  # The expected line comes from the fixture via grep, not from arithmetic
  # over the driver's own scan, so the assertion cannot agree with a
  # miscounted offset.
  local _line
  _line="$(grep -n -- '- \*\*a thing\*\*' "${CHANGELOG}" | cut -d: -f1)"
  run _run_changelog_entry
  assert_failure
  assert_output --partial "CHANGELOG.md:${_line}:"
  assert_output --regexp "[0-9]+ chars \(max ${_CHANGELOG_ENTRY_MAX}\)"
}

@test "_run_changelog_entry: reports EVERY over-long entry, not just the first (#917)" {
  _write_changelog '### Added' \
    "- **alpha entry** -- $(_long_prose)" \
    "- **beta entry** -- $(_long_prose)"
  run _run_changelog_entry
  assert_failure
  assert_output --partial 'alpha entry'
  assert_output --partial 'beta entry'
}

# ════════════════════════════════════════════════════════════════════
# The acceptance criterion: rewrapping the same text must not satisfy it
# ════════════════════════════════════════════════════════════════════

@test "_run_changelog_entry: the SAME text rewrapped across continuation lines still FAILS (#917)" {
  # A per-LINE cap passes this and nothing improved. The entry is one
  # markdown list item either way, so the measure is the same.
  local _one_line _wrapped
  _one_line="- **a thing** -- $(_long_prose)"
  _wrapped="$(printf '%s' "${_one_line}" | fold -s -w 72 | sed '2,$s/^/  /')"
  _write_changelog '### Added' "${_wrapped}"
  run _run_changelog_entry
  assert_failure
  assert_output --partial 'a thing'
}

@test "_run_changelog_entry: the SAME text re-shaped into sub-bullets still FAILS (#917)" {
  # The other escape hatch: chop the prose into a nested list and each
  # individual bullet is short. Sub-bullets count toward their parent.
  local _i _sub=()
  for _i in $(seq 1 12); do
    _sub+=("  - This sentence explains a rejected alternative in some detail, again.")
  done
  _write_changelog '### Added' '- **a thing** -- background:' "${_sub[@]}"
  run _run_changelog_entry
  assert_failure
  assert_output --partial 'a thing'
}

@test "_run_changelog_entry: the measure is unchanged by re-indenting a passing entry (#917)" {
  # Wrap-invariance in the other direction: an entry that passes must not
  # start failing because the author wrapped it politely.
  local _one_line _wrapped
  _one_line="- **a thing** -- $(_chars 300)"
  _wrapped="$(printf '%s' "${_one_line}" | fold -w 60 | sed '2,$s/^/      /')"
  _write_changelog '### Added' "${_wrapped}"
  run _run_changelog_entry
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# The cap itself
# ════════════════════════════════════════════════════════════════════

@test "_run_changelog_entry: PASSES an entry of exactly the cap (#917)" {
  _write_changelog '### Added' "- $(_chars $(( _CHANGELOG_ENTRY_MAX - 2 )))"
  run _run_changelog_entry
  assert_success
}

@test "_run_changelog_entry: FAILS an entry one character over the cap (#917)" {
  _write_changelog '### Added' "- $(_chars $(( _CHANGELOG_ENTRY_MAX - 1 )))"
  run _run_changelog_entry
  assert_failure
}

@test "_run_changelog_entry: PASSES a structured entry -- short lead plus a sub-list (#917)" {
  # The stated cost of measuring the whole entry is that it could block a
  # legitimately structured entry. At this cap it does not: a lead plus a
  # four-item migration list is well inside budget.
  _write_changelog '### Changed' \
    '- **BREAKING: the target moves to a `-t` flag** (closes #NNN) -- migrate:' \
    '  - `run.sh runtime` becomes `run.sh -t runtime`; the default is `devel`.' \
    '  - positional args after the options are the CMD, as in `exec.sh`.' \
    '  - `-d` together with a CMD is an error and points at `exec.sh`.' \
    '  - plain `run.sh` still drops into devel bash.'
  run _run_changelog_entry
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Scope: the [Unreleased] section alone
# ════════════════════════════════════════════════════════════════════

@test "_run_changelog_entry: an over-long entry in a RELEASED section is never checked (#917)" {
  {
    printf '# Changelog\n\n'
    printf '## [Unreleased]\n\n'
    printf '### Added\n'
    printf -- '- **a short entry** -- fine.\n\n'
    printf '## [v0.42.0] - 2026-08-25\n\n'
    printf '### Added\n'
    printf -- '- **a shipped entry** -- %s\n' "$(_long_prose)"
  } > "${CHANGELOG}"
  run _run_changelog_entry
  assert_success
  refute_output --partial 'a shipped entry'
}

@test "_run_changelog_entry: stops at the next '## [' heading, not at the end of file (#917)" {
  # The failure mode: a section walker that keeps going past the boundary
  # reports entries nobody is allowed to rewrite. Two released sections
  # follow, so a walker that runs off the end trips on the second too.
  {
    printf '# Changelog\n\n'
    printf '## [Unreleased]\n\n'
    printf '## [v0.42.0] - 2026-08-25\n\n'
    printf -- '- **first shipped entry** -- %s\n\n' "$(_long_prose)"
    printf '## [v0.41.0] - 2026-06-10\n\n'
    printf -- '- **second shipped entry** -- %s\n' "$(_long_prose)"
  } > "${CHANGELOG}"
  run _run_changelog_entry
  assert_success
  refute_output --partial 'first shipped entry'
  refute_output --partial 'second shipped entry'
}

@test "_run_changelog_entry: an empty [Unreleased] passes and SAYS it checked nothing (#917)" {
  # Legitimate right after a release. Reported explicitly rather than
  # silently, so a green line is never mistaken for a green verdict.
  _write_changelog
  run _run_changelog_entry
  assert_success
  assert_output --partial 'no entries'
}

# ════════════════════════════════════════════════════════════════════
# The opt-out region
# ════════════════════════════════════════════════════════════════════

@test "_run_changelog_entry: an allow region suppresses the entry inside it (#917)" {
  _write_changelog '### Added' \
    '<!-- changelog-entry-lint: allow-begin -- migration guide -->' \
    "- **a thing** -- $(_long_prose)" \
    '<!-- changelog-entry-lint: allow-end -->'
  run _run_changelog_entry
  assert_success
}

@test "_run_changelog_entry: FAILS on an over-long entry AFTER an allow-end (the region does not leak) (#917)" {
  _write_changelog '### Added' \
    '<!-- changelog-entry-lint: allow-begin -- migration guide -->' \
    "- **allowed entry** -- $(_long_prose)" \
    '<!-- changelog-entry-lint: allow-end -->' \
    "- **leaked entry** -- $(_long_prose)"
  run _run_changelog_entry
  assert_failure
  assert_output --partial 'leaked entry'
  refute_output --partial 'allowed entry'
}

@test "_run_changelog_entry: FAILS on an unterminated allow-begin (#917)" {
  _write_changelog '### Added' \
    '<!-- changelog-entry-lint: allow-begin -- migration guide -->' \
    '- **a short entry** -- fine.'
  run _run_changelog_entry
  assert_failure
  assert_output --partial 'unterminated allow-begin'
}

@test "_run_changelog_entry: FAILS on an allow-end with no open allow-begin (#917)" {
  _write_changelog '### Added' \
    '- **a short entry** -- fine.' \
    '<!-- changelog-entry-lint: allow-end -->'
  run _run_changelog_entry
  assert_failure
  assert_output --partial 'unmatched allow-end'
}

@test "_run_changelog_entry: an entry that QUOTES the allow markers is prose, not a region (#917)" {
  # The one entry certain to contain both marker strings is the entry that
  # documents this lint's own escape hatch -- and the convention note at the
  # top of the changelog hands the contributor the exact string to paste. A
  # substring match reads that prose as an opening marker and fails a clean
  # file, which is the muted-lint outcome this lint exists to prevent.
  _write_changelog '### Added' \
    '- **the lint** -- opt out with `<!-- changelog-entry-lint: allow-begin -- why -->` / `<!-- changelog-entry-lint: allow-end -->`.'
  run _run_changelog_entry
  assert_success
  refute_output --partial 'unterminated'
}

@test "_run_changelog_entry: a quoted allow marker does not silence the entries after it (#917)" {
  # The second half, and the worse one: prose read as an opening marker
  # leaves the region open, so every remaining line of the section is
  # skipped and an over-long entry below it is never measured.
  _write_changelog '### Added' \
    '- **the lint** -- opt out with `<!-- changelog-entry-lint: allow-begin -- why -->` / `<!-- changelog-entry-lint: allow-end -->`.' \
    "- **a long one** -- $(_long_prose)"
  run _run_changelog_entry
  assert_failure
  assert_output --partial 'a long one'
  refute_output --partial 'unterminated allow-begin'
}

@test "_run_changelog_entry: an unterminated allow-begin is reported AND what follows is still measured (#917)" {
  # A dangling marker is a violation on its own; it must not also buy the
  # rest of the section a free pass, or fixing the marker is the only way
  # to discover the entries it was hiding.
  _write_changelog '### Added' \
    '<!-- changelog-entry-lint: allow-begin -- migration guide -->' \
    "- **a long one** -- $(_long_prose)"
  run _run_changelog_entry
  assert_failure
  assert_output --partial 'unterminated allow-begin'
  assert_output --partial 'a long one'
}

@test "_run_changelog_entry: FAILS on one comment carrying BOTH allow markers (#917)" {
  # Recognising a marker by "the line is a lone HTML comment" leaves one
  # ambiguous shape. Picking a side silently would re-open the swallowed
  # region hole, so it is refused by name.
  _write_changelog '### Added' \
    '<!-- changelog-entry-lint: allow-begin -- why -- changelog-entry-lint: allow-end -->' \
    "- **a long one** -- $(_long_prose)"
  run _run_changelog_entry
  assert_failure
  assert_output --partial 'malformed allow marker'
}

@test "_run_changelog_entry: the clean line reports how many entries an allow region suppressed (#917)" {
  _write_changelog '### Added' \
    '- **a small honest entry** -- fine.' \
    '<!-- changelog-entry-lint: allow-begin -- migration guide -->' \
    "- **an allowed entry** -- $(_long_prose)" \
    '<!-- changelog-entry-lint: allow-end -->'
  run _run_changelog_entry
  assert_success
  assert_output --partial '1 entries checked'
  assert_output --partial '1 suppressed'
}

@test "_run_changelog_entry: a section whose only entry is allowed says so, not 'nothing to check' (#917)" {
  # Zero entries CHECKED is not the same fact as zero entries PRESENT, and
  # a line that reports the second when the first is true is the vacuous
  # pass in its purest form.
  _write_changelog '### Added' \
    '<!-- changelog-entry-lint: allow-begin -- migration guide -->' \
    "- **an allowed entry** -- $(_long_prose)" \
    '<!-- changelog-entry-lint: allow-end -->'
  run _run_changelog_entry
  assert_success
  assert_output --partial 'allow region'
  refute_output --partial 'nothing to check'
}

# ════════════════════════════════════════════════════════════════════
# Fenced code blocks: an example of markdown is not markdown
# ════════════════════════════════════════════════════════════════════

@test "_run_changelog_entry: a heading shown inside a fenced example does not relocate the section (#917)" {
  # The changelog's own convention note is one edit away from this: extend
  # its ```markdown example to show the surrounding heading and a prefix
  # match latches onto the example, making the REAL section the boundary
  # and scanning two lines of sample text.
  {
    printf '# Changelog\n\n'
    printf '## Writing an entry\n\n'
    printf '```markdown\n'
    printf '## [Unreleased]\n\n'
    printf '### Added\n'
    printf -- '- **One sentence on what changed** -- who is affected.\n'
    printf '```\n\n'
    printf '## [Unreleased]\n\n'
    printf '### Added\n'
    printf -- '- **a long one** -- %s\n' "$(_long_prose)"
    printf '\n## [v0.1.0] - 2026-03-28\n'
  } > "${CHANGELOG}"
  run _run_changelog_entry
  assert_failure
  assert_output --partial 'a long one'
}

@test "_run_changelog_entry: a released heading inside a fenced example does not truncate the section (#917)" {
  {
    printf '# Changelog\n\n'
    printf '## [Unreleased]\n\n'
    printf '### Added\n'
    printf -- '- **the heading shape** -- a released section opens with:\n\n'
    printf '```markdown\n'
    printf '## [v9.9.9] - 2026-01-01\n'
    printf '```\n\n'
    printf -- '- **a long one** -- %s\n' "$(_long_prose)"
    printf '\n## [v0.1.0] - 2026-03-28\n'
  } > "${CHANGELOG}"
  run _run_changelog_entry
  assert_failure
  assert_output --partial 'a long one'
}

@test "_run_changelog_entry: a '- ' line inside a fenced example counts toward its entry, not as a new one (#917)" {
  # The mirror of the two above, and the third escape hatch: fencing the
  # prose must neither open an entry per line nor buy the entry above it
  # any budget.
  local _i _fence=()
  for _i in $(seq 1 12); do
    _fence+=('- This sentence explains a rejected alternative in some detail, again.')
  done
  _write_changelog '### Added' \
    '- **a thing** -- the shape is:' \
    '' \
    '```markdown' \
    "${_fence[@]}" \
    '```'
  run _run_changelog_entry
  assert_failure
  assert_output --partial 'a thing'
}

# ════════════════════════════════════════════════════════════════════
# Content the parser does not recognise is never a silent pass
# ════════════════════════════════════════════════════════════════════

@test "_run_changelog_entry: FAILS on a bullet marker the parser does not recognise (#917)" {
  # '*' and '+' are valid CommonMark bullets that render identically, and a
  # two-space indent is a routine auto-format outcome. Each used to leave
  # the section measuring nothing while reporting that it holds no entries.
  local _marker
  for _marker in '*' '+' '  -'; do
    _write_changelog '### Added' "${_marker} **a thing** -- $(_long_prose)"
    run _run_changelog_entry
    assert_failure
    assert_output --partial 'unrecognised'
  done
}

@test "_run_changelog_entry: FAILS on unrecognised content that FOLLOWS a valid entry (#917)" {
  # Worse than the hedge: with one honest entry present the driver reported
  # an affirmative 'clean (1 entries)' over a 900-character bullet it never
  # looked at, so nothing in the output hinted anything had been skipped.
  _write_changelog '### Added' \
    '- **a small honest entry** -- fine.' \
    '' \
    "* **a thing** -- $(_long_prose)"
  run _run_changelog_entry
  assert_failure
  assert_output --partial 'unrecognised'
}

# ════════════════════════════════════════════════════════════════════
# Orphaned wrap lines
#
# The length measure collapses whitespace on purpose, so it is blind to
# how the entry is wrapped -- and markdown collapses the same whitespace
# when it renders, so a hand-edit that leaves one word alone on its line
# is invisible in both places and survives review. The source is where the
# file is read while it is being written, so that is where the rule bites.
# It is narrow by design: one word on the line AND more of the same
# paragraph on the very next SOURCE line. Anything else -- a short final
# line, a table row, a fenced line, an HTML comment -- is left alone,
# which the cases below pin one by one.
# ════════════════════════════════════════════════════════════════════

@test "_run_changelog_entry: FAILS on a single word orphaned above the rest of its paragraph (#927)" {
  _write_changelog '### Documentation' \
    '- **an entry that was edited and not re-wrapped** -- the prose runs on' \
    '  for a while and then the tail was rewritten in place, leaving one' \
    '  word behind.' \
    '  Affects' \
    '  anyone reading the source.'
  run _run_changelog_entry
  assert_failure
  assert_output --partial 'orphaned wrap line'
  assert_output --partial "'Affects'"
}

@test "_run_changelog_entry: names the orphan's real line number in the file (#927)" {
  # Reported against the CHANGELOG's own numbering, not an offset within
  # the section -- the author has to be able to jump straight to it.
  _write_changelog '### Documentation' \
    '- **an entry** -- prose.' \
    '  Affects' \
    '  anyone reading the source.'
  run _run_changelog_entry
  assert_failure
  # preamble (4 lines) + heading + blank + '### Documentation' + bullet = 8.
  assert_output --partial 'CHANGELOG.md:9:'
}

@test "_run_changelog_entry: a one-word FINAL line of an entry is not an orphan (#927)" {
  # A paragraph is allowed to end on a short line; nothing follows it to
  # re-flow into, so there is nothing to fix.
  _write_changelog '### Documentation' \
    '- **an entry** -- the prose runs on for a while and then ends on a' \
    '  word.'
  run _run_changelog_entry
  assert_success
}

@test "_run_changelog_entry: a one-word line above a BLANK line is not an orphan (#927)" {
  # The next source line is not more of the same paragraph, so the two
  # were never one wrapped run. Contiguity is the whole test.
  _write_changelog '### Documentation' \
    '- **an entry** -- prose that ends on a' \
    '  word.' \
    '' \
    '  A second paragraph of the same entry.'
  run _run_changelog_entry
  assert_success
}

@test "_run_changelog_entry: an unbreakable token alone on its line is not an orphan (#927)" {
  # A long URL or code span is alone on its line because nothing else fits
  # there -- that is wrapping working, not wrapping skipped. Caught by the
  # re-indentation case, which builds its fixture out of 60-character
  # spaceless chunks and would otherwise report four orphans in an entry
  # the lint is asserting PASSES.
  _write_changelog '### Documentation' \
    '- **an entry with a long span** -- see' \
    "  \`$(_chars 60)\`" \
    '  for the details.'
  run _run_changelog_entry
  assert_success
}

@test "_run_changelog_entry: an orphan is one that could have joined the line below (#927)" {
  # The pair has to FIT: 79 columns is the file's wrap, and a word that
  # cannot go anywhere is not a word left behind.
  _write_changelog '### Documentation' \
    '- **an entry** -- prose.' \
    '  Affects' \
    "  $(_chars 74)"
  run _run_changelog_entry
  assert_success
}

@test "_run_changelog_entry: a table separator row is not an orphaned word (#927)" {
  # '|---|---|' is one whitespace-delimited word and always will be; a
  # table is not a paragraph that failed to re-flow.
  _write_changelog '### Documentation' \
    '- **an entry with a table** -- the shapes:' \
    '' \
    '  | Tag | Bump |' \
    '  |---|---|' \
    '  | `vX.Y.Z` | Z |'
  run _run_changelog_entry
  assert_success
}

@test "_run_changelog_entry: a single-word line inside a fenced block is not an orphan (#927)" {
  # Inside a fence the line is code, and code is not wrapped prose. The
  # fence delimiters are single "words" of their own, too.
  _write_changelog '### Documentation' \
    '- **an entry with a snippet** -- like so:' \
    '' \
    '  ```bash' \
    '  make' \
    '  test' \
    '  ```'
  run _run_changelog_entry
  assert_success
}

@test "_run_changelog_entry: an orphan inside an allow region is suppressed like any other defect (#927)" {
  _write_changelog '<!-- changelog-entry-lint: allow-begin -- pinned quotation -->' \
    '- **an entry** -- prose.' \
    '  Affects' \
    '  anyone reading the source.' \
    '<!-- changelog-entry-lint: allow-end -->'
  run _run_changelog_entry
  assert_success
}

@test "_run_changelog_entry: an orphan in a RELEASED section is never checked (#927)" {
  # Same scoping as the length cap: a shipped entry is history, and a lint
  # that fails on something nobody may fix gets muted.
  {
    printf '# Changelog\n\n'
    printf '## [Unreleased]\n\n'
    printf '## [v0.1.0] - 2026-03-28\n\n'
    printf '### Documentation\n'
    printf -- '- **a shipped entry** -- prose.\n'
    printf '  Affects\n'
    printf '  anyone reading the source.\n'
  } > "${CHANGELOG}"
  run _run_changelog_entry
  assert_success
}

@test "_run_changelog_entry: reports EVERY orphan in the section, not just the first (#927)" {
  _write_changelog '### Documentation' \
    '- **first** -- prose.' \
    '  Affects' \
    '  one reader.' \
    '- **second** -- prose.' \
    '  Breaks' \
    '  another reader.'
  run _run_changelog_entry
  assert_failure
  assert_output --partial "'Affects'"
  assert_output --partial "'Breaks'"
}

# ════════════════════════════════════════════════════════════════════
# The measure is characters, in every locale
# ════════════════════════════════════════════════════════════════════

@test "_changelog_entry_measure: counts characters, not bytes, whatever the locale (#917)" {
  # bash's parameter-length expansion counts characters under a UTF-8
  # locale and BYTES under C/POSIX, and the two execution paths do not
  # share one: the lint-static CI job runs on a bare runner with no LANG
  # (glibc -> POSIX -> bytes), the local gate runs inside the musl
  # test-tools image (-> characters). Written as raw UTF-8 bytes so the
  # fixture does not itself depend on the locale that built it.
  local _text
  _text=$'- \xe4\xb8\xad\xe6\x96\x87\xe5\xad\x97\xe5\x85\x83'
  local _utf8 _c
  export LC_ALL=C.UTF-8
  _utf8="$(_changelog_entry_measure "${_text}")"
  export LC_ALL=C
  _c="$(_changelog_entry_measure "${_text}")"
  unset LC_ALL
  # Four characters of twelve bytes, plus the two-character bullet marker.
  assert_equal "${_utf8}" 6
  assert_equal "${_c}" 6
}

@test "_run_changelog_entry: a non-ASCII entry under the cap PASSES under a C locale too (#917)" {
  # End to end: 402 characters, 1202 bytes. Measured as bytes this fails in
  # CI and passes on the contributor's desktop, with no diff to point at.
  local _cjk
  _cjk="$(printf '\xe4\xb8\xad%.0s' $(seq 1 400))"
  _write_changelog '### Added' "- ${_cjk}"
  export LC_ALL=C
  run _run_changelog_entry
  unset LC_ALL
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Non-vacuity
# ════════════════════════════════════════════════════════════════════

@test "_run_changelog_entry: DIES when the CHANGELOG is missing rather than passing vacuously (#917)" {
  rm -f "${CHANGELOG}"
  run _run_changelog_entry
  assert_failure
  assert_output --partial 'not found'
}

@test "_run_changelog_entry: DIES when the [Unreleased] heading is missing rather than passing vacuously (#917)" {
  # No heading means the file's shape changed, and a lint that scans
  # nothing and reports clean is exactly the vacuous pass this repo keeps
  # having to fix. Distinct from an empty-but-present section, which is a
  # legitimate state and passes.
  {
    printf '# Changelog\n\n'
    printf '## [v0.42.0] - 2026-08-25\n\n'
    printf -- '- **a shipped entry** -- fine.\n'
  } > "${CHANGELOG}"
  run _run_changelog_entry
  assert_failure
  assert_output --partial 'Unreleased'
}

# ════════════════════════════════════════════════════════════════════
# A duplicated entry
# ════════════════════════════════════════════════════════════════════
#
# Landing branches serially against `strict` protection merges origin/main
# into every branch, and two branches that each APPEND to [Unreleased]
# merge cleanly with BOTH sides kept. Nothing conflicts, so nothing
# prompts a human -- the shape had produced a duplicated entry four times
# in one cycle, caught by eye every time, and two instances were sitting on
# main when this was written.

@test "_run_changelog_entry: FAILS on two entries with an identical lead bullet (#959)" {
  _write_changelog '### Added' \
    '- **a duplicated thing** -- what a merge keeps twice.' \
    '- **a duplicated thing** -- what a merge keeps twice.'
  run _run_changelog_entry
  assert_failure
  assert_output --partial 'duplicate entry'
}

@test "_run_changelog_entry: names BOTH lines of a duplicate, and both are findable (#959)" {
  # A message naming only the copy leaves the reader to find the original
  # by eye, which is the manual step this check removes. Both numbers come
  # from the fixture via grep, so the assertion cannot agree with a
  # miscounted offset -- and each is read back out of the file, so a number
  # the reader could not find fails here.
  _write_changelog '### Added' \
    '- **a duplicated thing** -- what a merge keeps twice.' \
    '- **a duplicated thing** -- what a merge keeps twice.'
  local -a _hits=()
  mapfile -t _hits < <(grep -n -- '- \*\*a duplicated thing\*\*' "${CHANGELOG}" | cut -d: -f1)
  assert_equal "${#_hits[@]}" 2
  local _first="${_hits[0]}" _second="${_hits[1]}" _text
  _text="$(sed -n "${_second}p" "${CHANGELOG}")"
  assert_equal "${_text}" '- **a duplicated thing** -- what a merge keeps twice.'
  _text="$(sed -n "${_first}p" "${CHANGELOG}")"
  assert_equal "${_text}" '- **a duplicated thing** -- what a merge keeps twice.'
  run _run_changelog_entry
  assert_failure
  assert_output --partial "CHANGELOG.md:${_second}: duplicate entry"
  assert_output --partial "already opened at doc/changelog/CHANGELOG.md:${_first}"
}

@test "_run_changelog_entry: the same entry RE-WRAPPED is still a duplicate (#959)" {
  # The lead LINE stops being the same string once a copy is re-wrapped,
  # so the lead-bullet key alone would go quiet on it. The whole-entry key
  # behind it is what keeps the answer the same.
  local _one _wrapped
  _one='- **a duplicated thing** -- the same sentence appears in both copies of this entry.'
  _wrapped="$(printf '%s' "${_one}" | fold -s -w 40 | sed '2,$s/^/  /')"
  _write_changelog '### Added' "${_one}" "${_wrapped}"
  run _run_changelog_entry
  assert_failure
  assert_output --partial 're-wrapped'
}

@test "_run_changelog_entry: two DIFFERENT entries are not a duplicate (#959)" {
  # The other direction: a check that fires on entries which merely look
  # alike is a check that gets muted.
  _write_changelog '### Added' \
    '- **the first thing** -- what a merge keeps once.' \
    '- **the second thing** -- what a merge keeps once.'
  run _run_changelog_entry
  assert_success
  refute_output --partial 'duplicate entry'
}

@test "_run_changelog_entry: a duplicate planted in a RELEASED section is NOT a finding (#959)" {
  # Same rule as the length cap, same reason: a released section is a
  # historical record, a duplicate that shipped is a fact about what
  # shipped, and rewriting it falsifies the record. A repeated category
  # heading there is exempt for the same reason.
  {
    printf '# Changelog\n\n'
    printf '## [Unreleased]\n\n'
    printf '### Added\n'
    printf -- '- **a short entry** -- fine.\n\n'
    printf '## [v0.42.0] - 2026-08-25\n\n'
    printf '### Added\n'
    printf -- '- **a shipped entry** -- fine.\n'
    printf -- '- **a shipped entry** -- fine.\n\n'
    printf '### Added\n'
    printf -- '- **another shipped entry** -- fine.\n'
  } > "${CHANGELOG}"
  run _run_changelog_entry
  assert_success
  refute_output --partial 'duplicate entry'
  refute_output --partial 'repeated category heading'
}

@test "_run_changelog_entry: a bullet and a heading shown inside a fenced example are not structure (#959)" {
  # The changelog documents its own format in fenced examples, and that
  # block deliberately carries a '- **' bullet and headings. Parsed as
  # structure, the example IS a byte-identical second copy of the entry
  # that introduces it, and its '### Added' IS a second opening -- a
  # failure on a clean file, which is how a lint gets muted.
  _write_changelog '### Added' \
    '- **a thing** -- the shape a duplicate takes is:' \
    '' \
    '```markdown' \
    '### Added' \
    '- **a thing** -- the shape a duplicate takes is:' \
    '```'
  run _run_changelog_entry
  assert_success
  refute_output --partial 'duplicate entry'
  refute_output --partial 'repeated category heading'
}

@test "_run_changelog_entry: an allow region suppresses a deliberate second copy (#959)" {
  # The opt-out means the same thing here as for the cap: an entry inside
  # a region is not measured, and a region is a visible line in the diff
  # carrying a stated reason.
  _write_changelog '### Added' \
    '- **a thing** -- fine.' \
    '<!-- changelog-entry-lint: allow-begin -- a deliberate second copy -->' \
    '- **a thing** -- fine.' \
    '<!-- changelog-entry-lint: allow-end -->'
  run _run_changelog_entry
  assert_success
  refute_output --partial 'duplicate entry'
}

# ════════════════════════════════════════════════════════════════════
# A category heading that opens twice
# ════════════════════════════════════════════════════════════════════

@test "_run_changelog_entry: FAILS when a category opens twice, naming both lines (#959)" {
  _write_changelog \
    '### Added' \
    '- **the first thing** -- fine.' \
    '### Fixed' \
    '- **the second thing** -- fine.' \
    '### Added' \
    '- **the third thing** -- fine.'
  # The released tail _write_changelog appends carries a '### Added' too,
  # so the first two matches are the ones inside [Unreleased].
  local -a _hits=()
  mapfile -t _hits < <(grep -n '^### Added$' "${CHANGELOG}" | cut -d: -f1)
  local _first="${_hits[0]}" _second="${_hits[1]}" _text
  _text="$(sed -n "${_second}p" "${CHANGELOG}")"
  assert_equal "${_text}" '### Added'
  run _run_changelog_entry
  assert_failure
  assert_output --partial "CHANGELOG.md:${_second}: repeated category heading"
  assert_output --partial "### Added already opened at doc/changelog/CHANGELOG.md:${_first}"
}

@test "_run_changelog_entry: the SAME category in a different release block is fine (#959)" {
  # The rule is per release block, not per file: every release adds
  # things, so '### Added' appearing once in each is the normal shape.
  _write_changelog '### Added' '- **a thing** -- fine.'
  local _count
  _count="$(grep -c '^### Added$' "${CHANGELOG}")"
  assert_equal "${_count}" 2
  run _run_changelog_entry
  assert_success
  refute_output --partial 'repeated category heading'
}

@test "_run_changelog_entry: the clean line says how many category headings it compared (#959)" {
  # Non-vacuity: a check that scanned nothing reports the same green line
  # as a check that scanned the file, unless the line carries the count.
  _write_changelog \
    '### Added' \
    '- **the first thing** -- fine.' \
    '### Fixed' \
    '- **the second thing** -- fine.'
  run _run_changelog_entry
  assert_success
  assert_output --partial '2 category headings compared'
}

# ════════════════════════════════════════════════════════════════════
# The real tree
# ════════════════════════════════════════════════════════════════════

@test "_run_changelog_entry: the real repo tree's [Unreleased] section is clean (#917)" {
  REPO_ROOT=/source
  run _run_changelog_entry
  assert_success
}
