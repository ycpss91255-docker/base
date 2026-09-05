# ADR numbers are allocated by every branch at once, so the collision is kept and the repair is a verb

> Serves: PRD invariant 2 (never fail silently) -- the half of it that
> says a repair done incompletely must be visible. It establishes no
> invariant: an ADR number is a naming mechanism, and this decision is
> about what happens when a naming mechanism has no allocator.

- **Date:** 2026-09-04
- **Status:** Accepted
- **Relates to:** **#1021** (the collision this records the answer to);
  **#1024** (its sibling in the same wave -- a stored number every branch
  edits, one level down); ADR-00000028 (documentation is derived, not
  duplicated -- the rule that says a figure about a moving tree has no
  business being hand-kept, and the reason the catalogues here are
  regenerated rather than rewritten); ADR-00000011 (the `just` command
  model this adds the `adr` namespace to).

## Context

The rule for allocating an ADR number is "read `doc/adr/`, take the next
free one". It is written down, and it is the rule that produced the
defect.

On 2026-09-03 three branches in flight each created
`doc/adr/00000030-<slug>.md`: a config-layout record, a
dependency-bump-automation record, and an entry-point record. Each branch
read the tree, saw 00000029 as the highest, and took 00000030. **Every
one of them was right.** Nothing allocates the number, and a directory
listing is a snapshot of one worktree, so parallel work collides by
construction rather than by mistake.

The numbering lint runs against one tree. On each branch alone the number
is unique and every gate is green; the collision exists only in the union,
and the union first exists when the second branch merges -- at which point
the repair falls to whoever is landing it, under a red required check, on
a branch whose author has moved on.

Two of the three were renumbered by hand. The second one touched **14
files**: `CONTEXT.md`, the ADR index's row, its audit keep-list and two of
its "postdates the audit" notes, the changelog, an amended record's
forward pointer, six spec files, three generated catalogues, a lib and a
workflow. It was left incomplete in three of them -- the index row and two
audit conclusions still named 00000030 -- and every gate stayed green,
because a stale ADR number in prose was read by nothing. That state
survived until this ADR's own branch found it.

## Decision

**Keep the collision. Make the repair one command, and make an incomplete
repair fail a gate.**

Four parts.

1. **`just adr renumber <record> <number>`** (`script/adr/renumber.sh`)
   moves a record and rewrites every reference to it. The reference set is
   DERIVED -- the population in part 3 is swept for the reference forms --
   never
   listed, because a list of the 14 places is the same defect one level up
   and would have been written the day before the fifteenth appeared.

   The classes are told apart rather than sed'ed over, and that is the
   substance of the tool:

   - `ADR-NNNNNNNN` and `doc/adr/NNNNNNNN-<slug>.md` are rewritten
     wherever they appear.
   - A BARE eight-digit number is rewritten in `doc/adr/README.md` and
     nowhere else. That document's eight-digit runs are all ADR numbers;
     an eight-digit run standing on its own anywhere else is not a
     reference to anything -- it is a version, a count, an argument.
   - The generated documents are REGENERATED, never rewritten. One of the
     14 sites was a `@test` NAME carrying the number, and a test name is a
     row in a generated catalogue: editing the row puts a hand edit into a
     generated file, which the next regeneration reverts. The generator is
     asked which files those are, so this tool holds no second copy of the
     answer.

   Afterwards it re-reads the tree and fails if any reference to the old
   number survived, so a class nobody thought of surfaces as a failure
   rather than as a green run with a stale pointer.

2. **The registry lint reads the pointers, not just the registry.**
   `drivers/adr_numbering.sh` additionally fails on a reference to a
   number no record claims, on a `doc/adr/` path whose number and slug are
   not a file, and on an index table that has lost a row, gained one for
   no record, or carries two rows on one number. The last is the check
   that would have caught the incomplete repair above.

3. **What a reference IS is defined once, for both of them.**
   `script/adr/references.sh` answers which files can carry one, and the
   verb and the lint both source it. Two answers is not a detail: the
   verb swept `git ls-files` and the lint grepped the whole filesystem,
   so a repair the verb reported complete -- with its own survivor check
   green -- failed the lint on `.prev-release/` and `log/`, the two roots
   this repo's `.gitignore` parks at the top precisely so an old release
   is not read as current source. A red gate with no repair path through
   the documented verb.

   The population is every file under the root that the tree does not
   DECLARE derived. Where git can answer it is asked, for the tracked
   files and the untracked ones it does not exclude; where it cannot -- a
   fixture tree, or this checkout seen from inside the test container,
   where a worktree's `.git` names a gitdir that was never mounted -- the
   walk prunes what the root `.gitignore` declares, trailing slash or not,
   because git needs none and this repo's own file writes `.claude` and
   `CLAUDE.md` without one. That is a reader of the repo's own
   declaration, not a second opinion about what is derived.

   > **Amended (base#1021, same wave).** This section first read "where
   > git can answer, the tracked files ARE what this repo keeps true",
   > and the verb asked `git ls-files` bare. That does not hold, because
   > only ONE of the two tiers can ask git at all: a walk cannot tell an
   > untracked file from a tracked one, so tracked-only reproduced the
   > split this section is about, one tier over. The walk is also the
   > tier the LOCAL gate takes, so the divergence ran in the worse
   > direction -- an untracked scratch note carrying a dangling
   > `ADR-NNNNNNNN` reddened `just test lint --adr-numbering` while
   > `just adr renumber`, which runs on the host where git answers, never
   > swept it. A red gate with no repair path through the verb, which is
   > the defect this whole section exists to remove. Not yet tracked is
   > not derived, and it is the state a freshly authored ADR and its first
   > references are in.

   A file that builds its own throwaway `doc/adr/` DECLARES the NUMBERS
   that registry uses, on a comment line naming them. Declared and not
   inferred, because both attempts to infer it failed in the same
   direction. The lint read a `doc/adr/` path preceded by `}` as a shell
   expansion and therefore as somebody's fixture -- which silently
   dropped `"${REPO}/doc/adr/00000008-coverage-sharded-pr-gate.md"`, a
   live pointer at this tree's own registry, and would have read an
   unbraced expansion as a reference. The verb inferred per class instead,
   rewriting the `ADR-<n>` and `adr/<n>-` forms inside a spec while
   leaving the bare numbers that spec passes to it as ARGUMENTS, so a
   renumber left the setup and the command naming different records. A
   declared number is dropped in EVERY class, which is what the per-class
   guess got wrong.

   **Amended: the declaration is about numbers, not about the file.** It
   first dropped the whole FILE, on the reading that "a file is either
   this tree's or its own, and there is no reference class for which the
   answer differs". That reading is false, and both of this tree's
   declaring specs falsify it. `adr_structure_spec.bats` builds fixture
   records and also names, in a comment, the real record whose three
   column-0 Status lines the check was written for. `adr_numbering_spec.bats`
   builds fixture registries and also carries a `# why:` block citing
   `doc/adr/00000008-coverage-sharded-pr-gate.md` -- and the generator
   publishes that marker verbatim as a `doc/test/unit.md` row, which is a
   file in the population. Whole-file, renumbering that record had no
   consistent state to reach: the sweep rewrote the row, the regeneration
   in part 1 put the old number straight back from the marker the sweep
   was forbidden to touch, and the verb aborted on a survivor with the
   record already moved and 25 files rewritten -- the red gate with no
   repair path through the documented verb that this very part exists to
   remove. The first case is quieter and worse: neither tool sees the
   pointer, so it rots under a green gate.

   Per number, the default also points the safe way. Whole-file, an
   undeclared live pointer was silently exempt; per number, an undeclared
   fixture number is swept and, where it names no record, reported.

   > **Amended (base#1021, same wave): a declared number the declaring
   > file PUBLISHES is a finding.** Per number closed the case above and
   > left its mirror open. A declaration is per FILE, and a `# why:`
   > marker -- or a `@test` name -- is the one thing in a spec that LEAVES
   > the file: the generator in part 1 copies the blurb, every
   > description and every name verbatim into a doc/test catalogue, which
   > declares nothing. A DECLARED number written at one of those three
   > sites therefore arrives in the catalogue as a reference to this tree,
   > and the verb has no consistent state to reach: it rewrites the
   > published row, the regeneration puts the number straight back from
   > the marker it may not touch, and the run aborts on a survivor with
   > the record already moved -- the same half-applied tree the whole-file
   > reading produced, one level in. This tree shipped one:
   > `adr_renumber_spec.bats` declares 00000030 and a marker of its own
   > spelled it out, so `just adr renumber 30 <n>` aborted on
   > doc/test/unit.md.
   >
   > The lint reports it (`captive`) and the verb's survivor message now
   > names the declaring file. Both name the MARKER rather than the row,
   > because the row is generated: a hand edit there is undone by the next
   > `just test sync-docs`, and rewording the marker is the only repair.
   > That is the residue this rule keeps, and it is one line wide -- write
   > the number a fixture uses only where the catalogue does not carry it.

4. **A number claimed by two records is refused, not guessed at.** With
   two claimants, a bare `ADR-00000030` in a sentence names whichever of
   them its author meant and nothing in the merged tree records which.
   The tool refuses before writing anything and names the resolution that
   IS derivable: renumber on the branch, where the record is the only
   claimant of its number, and merge afterwards.

## Consequences

A collision still reaches a red check. That is unchanged and deliberate:
this decision buys a cheap repair, not an absence of collisions.

The repair is now one command whose coverage is derived, and an
incomplete one fails a gate for the two classes a checkout can recognise.

The verb and the gate cannot disagree about what they swept, because
neither of them decides. The cost is a shared file both must keep
correct, and a `.gitignore` reader that is only as good as the shapes it
reads. That reader does not SKIP a shape it cannot read: it applies the
forms whose meaning `find`'s matcher and git's share -- plain paths, and
a wildcard with no separator -- and REPORTS the rest (a negation, a
wildcard beside a separator, a nested `.gitignore`) as a finding saying
its population is wider than the verb's. Modelling gitignore in shell was
rejected for the reason the rest of this record argues: a model is right
about the forms somebody thought of and silently wrong about the others,
which is the failure this reader exists to remove, while a tree told
which line to spell differently has a repair it can make. Where git can
answer, none of it runs -- git applies every form itself.

A file that builds its own registry now carries a declaration, and a file
that acquires one later without declaring it becomes a lint finding
rather than a silent exemption. That is the direction the residue should
point: the failure is visible and its repair is one line. A declaration
the reader cannot parse is a finding for the same reason -- it exempts
nothing, and saying so is what keeps a marker that has stopped
protecting its fixtures from being discovered by a rewritten fixture.

The residue the per-number rule keeps: a fixture number that happens to
BE a real record's number, and is left undeclared, is rewritten in the
token and path classes and not in the bare-argument one. That is the
pre-existing per-class failure, now reachable only by omitting the one
line that prevents it, and it surfaces as a spec whose setup and command
name different records.

The residue, stated rather than papered over: a prose `ADR-NNNNNNNN`
whose number EXISTS but names a different record than its author meant is
indistinguishable from a correct one. After a collision is repaired by
renumbering one of two claimants, that is exactly what a missed reference
looks like. No lint can settle it, which is the argument for renumbering
on the branch -- where the rewrite is mechanical -- rather than after the
merge.

The index table is now load-bearing: deleting it disables the row check.
That is a document's spine going missing in a diff, where a single missed
row is invisible, and the invisible failure is the one the check is for.

This ADR allocated its own number by the rule it is about, from a tree
that already carried a wave of parallel branches. If it collides, the
verb it introduces is the repair.

## Alternatives

**Allocate from the remote.** `git ls-remote` plus the merged history
gives the numbers open branches have claimed. Rejected: it puts a network
call in the ADR creation path, it is still racy for two branches created
in the same minute, and it makes authoring a record depend on being
online -- for a saving of one red check that already reports the problem
precisely.

**Do not number until merge.** Author as `doc/adr/draft-<slug>.md` and
have a merge-time hook assign the number. Rejected: the record's identity
is unstable for the whole time it is under review, which is when it is
read and cited most; every cross-reference has to be by slug until then
and be rewritten afterwards -- the same sweep this ADR is about, made
mandatory instead of occasional; and the hook is a new failure mode on
the merge path.

**Number by content.** A short hash of the slug. Rejected: it destroys
the chronological ordering that makes `doc/adr/` readable in a directory
listing, and every existing reference is to a sequential number, so the
migration is the 14-file sweep times thirty-two.

**A per-branch reserved range.** Rejected outright: it is a roster, the
defect class this repo has now paid for three times, and it needs a
person to keep the reservations true.
