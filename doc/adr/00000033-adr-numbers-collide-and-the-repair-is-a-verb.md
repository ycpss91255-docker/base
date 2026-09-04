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

Three parts.

1. **`just adr renumber <record> <number>`** (`script/adr/renumber.sh`)
   moves a record and rewrites every reference to it. The reference set is
   DERIVED -- the tracked files are swept for the reference forms -- never
   listed, because a list of the 14 places is the same defect one level up
   and would have been written the day before the fifteenth appeared.

   The classes are told apart rather than sed'ed over, and that is the
   substance of the tool:

   - `ADR-NNNNNNNN` and `doc/adr/NNNNNNNN-<slug>.md` are rewritten
     wherever they appear.
   - A BARE eight-digit number is rewritten in `doc/adr/README.md` and
     nowhere else. That document's eight-digit runs are all ADR numbers;
     elsewhere they are the throwaway registries the lint specs build, and
     rewriting those would corrupt the tests that guard this.
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

3. **A number claimed by two records is refused, not guessed at.** With
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
