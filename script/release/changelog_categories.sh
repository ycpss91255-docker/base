#!/usr/bin/env bash
#
# changelog_categories.sh - the locked changelog category roster, in the
# order a release page emits them.
#
# One definition, three consumers: script/release/release_notes.sh orders a
# release's merged sections by it, script/test/drivers/changelog_entry.sh
# refuses an [Unreleased] heading outside it, and the same driver checks
# that the roster doc/changelog/CHANGELOG.md prints for contributors names
# exactly these seven. A roster nothing checks is a roster that drifts, and
# a roster copied into each consumer drifts one consumer at a time.
#
# The axis is `BREAKING` plus the Keep a Changelog six. Conventional-commit
# types (`feat` / `fix` / `test` / `chore` / `refactor`) were considered and
# rejected: they answer "what kind of work was this", the author's view,
# where a changelog answers "what changed for me", the reader's. Filing by
# commit type institutionalises putting `test:` / `chore:` / `refactor:`
# work into the changelog, which is part of how this file reached 641 KB. A
# refactor a reader must know about -- a new lint that can fail their CI --
# is `Added`; one they need not know about is not an entry at all.
#
# BREAKING sorts first and is first-class because this project's dominant
# risk is breaking the downstream repos that carry `.base/`. It was already
# in ad-hoc use three times before it was named here.
#
# The headings this replaces -- `Documentation`, `Tests`, `Migration`,
# `Migration notes`, `Performance`, `Known issues`, `Release summary`, and
# the one-offs carrying a date or a parenthetical -- are twenty variants
# where seven will do. Migration instructions belong INSIDE the BREAKING
# entry they serve, not in a parallel section a reader can miss.
#
# Scope: [Unreleased] only, per #917. A released section is a historical
# record and rewriting a shipped heading falsifies it, so the roster is
# forward-looking and the assembler tolerates a historical heading it does
# not know (emitting it after the roster ones, in first-seen order).
#
# Sourceable: no main, no strict mode at file scope. A sourced file that
# turns nounset on leaves it on in its caller.

# The roster, in emission order.
# shellcheck disable=SC2034  # read by the files that source this one.
CHANGELOG_CATEGORIES=(
  BREAKING
  Added
  Changed
  Deprecated
  Removed
  Fixed
  Security
)
