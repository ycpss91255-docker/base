# Early return is the default shape of every function, not a remedy applied when a threshold is breached

> Serves: PRD design principle P1 (early return is the default shape of
> every function) -- this is the decision that established it. It serves
> no invariant directly: it is the source shape ADR-00000014's
> decomposition already assumes, and so it stands behind invariant 7's
> testability rather than beside it.

- **Date:** 2026-09-03
- **Status:** Accepted
- **Relates to:** **#994** (the epic this is decision 1 of; the
  implementation thresholds, the design-principle layer and the ADR
  structure lint land under it); ADR-00000014 (the decomposition into
  subsystem libs whose seams this is the function-level shape of);
  ADR-00000015 (test files mirror source -- the reason a split is decided
  by design and never by test convenience); PRD invariant 7 (the test bar
  a splittable function is what makes reachable).

## Context

base's shipped code is 809 functions. Measured across them:

| threshold | value | today |
|---|---|---|
| nesting depth | <= 3 | 44 at >= 4, 7 at 5, 1 at 6 |
| function length | <= 50 lines | 151 over (18%), worst 515 |
| positional parameters | <= 5 | 7 over, worst 31 |

The numbers are not the subject of this ADR. What they are evidence of
is: those functions were not written with a guard clause at the top and
then grew past a limit -- they were written body-first, with the
validation folded into the branch structure, and depth 4 is simply what
that produces. No threshold was breached; a shape was never chosen.

An earlier audit of the nesting figure treated it the other way round: as
a list of 44 violations, to be ranked by severity and fixed. That framing
is what this ADR corrects. It yields 44 fixes and then, some months
later, 44 more, because nothing in it reaches the next function anybody
writes. The 44 are a symptom that was measured; the thing to change is
the default shape, and the measurement's job is to tell us when the
default was not applied.

The objection this had to survive is real and was argued on its merits:
splitting `compose_emit.sh::generate_compose_yaml` -- 31 positional
parameters -- or a 515-line function is a risky change to make against
code that currently works, and the risk is borne by every downstream that
vendors it. The answer, from the repo owner:

> A function that is hard to split correctly is already defective; the
> difficulty is the finding, not an exemption from it.

That is the load-bearing sentence, and it is not rhetorical. A function
that cannot be split correctly is one whose pieces are not separable --
its branches share mutable state, its parameters are positional because
no group of them has a name, and no part of it can be exercised without
the whole. Every one of those is the same property stated differently,
and every one of them is what makes the function untestable, unreviewable
and unsafe to change for any other reason too. The difficulty of the
split is a measurement of that property. Declining the split on the
grounds that it is difficult keeps precisely the code the difficulty was
telling us about, and leaves it where the next person to need a change
there will find it, with no record that anyone looked.

## Decision

**Early return is the default shape of every function in base. A guard
clause at the top -- validate the precondition, reject, return -- is how
a function is written here. It is not a remedy applied to a function that
has crossed a threshold.**

Three consequences of stating it that way rather than as a limit:

1. **The thresholds are a net, not a target.** Depth <= 3, length <= 50,
   parameters <= 5. A function at depth 3 is not thereby correct and a
   function at depth 1 is not thereby exemplary; the numbers exist to
   report where the default shape was not applied, and they are set where
   an unguarded function reliably lands. Aiming at a threshold produces
   code shaped to pass it, which is the failure mode the earlier audit
   framing had built in.

2. **Difficulty is a finding, and it is recorded as one.** Where a
   function resists a correct split, the resistance is the result: the
   change that follows is a design change to the code that resists, and
   the reason it resisted is written down. "This one is too risky to
   split" is not an outcome this ADR admits; "this one shares mutable
   state across four branches, so the split is the extraction of that
   state" is.

3. **The gate lands on a clean tree.** The thresholds are wired into
   `just test` and CI only once the tree passes them (#994 phase 4). A
   gate that lands red is a gate that is muted on the day it lands, and a
   muted gate is a gate that has been removed with the maintenance cost
   left in.

   **Amendment (#994, 2026-09-03): a clean tree is what the gate needed
   to land GREEN, and an adoption ceiling supplies that without one.**
   The reason above is intact and it is the reason: a gate must not be
   red on the day it lands. What phase 3 found is that "the tree is
   clean" was one way to get there and not the property being asked for.
   Each lint now judges by a per-metric CEILING -- the count of functions
   still past the threshold, one readonly integer in
   `script/test/drivers/shell_metrics.sh`, which may only ever go down --
   so it is green on arrival, fails the moment a change adds a
   violation, and tightens as each slice lands. The thresholds
   themselves do not move; that is the distinction the next section
   turns on.

   This matters because of what the original wording implied about
   ordering: it made the whole 108-function flattening a prerequisite of
   any enforcement at all, so until the last slice landed nothing
   stopped the next function from being written at depth 5 -- and the
   flattening is measured in months of slices. The ceiling reverses that:
   enforcement arrives first and the population drains under it.

## Consequences

- The three metric lints (nesting, length, parameters) are written before
  the tree is clean and are deliberately **not** gating on arrival
  (#994 phase 2). They report, and their own specs prove each can fail by
  mutation, so what they measure is trustworthy before anything depends
  on it.
- The flattening happens in reviewable slices ordered by leverage rather
  than by file (#994 phase 3): the 7 parameter violations first, since
  they are the smallest and most localised, then depth, then length. Each
  slice is a PR with its own review, per ADR-00000014 rule 3 -- behaviour
  identical, the existing specs standing as the regression net.
- A split that changes behaviour is a bug in the split, not an accepted
  cost. This is the same rule ADR-00000014's relocate-first slices ran
  under, and it is what makes the slices reviewable at all.
- Cyclomatic complexity stays out of scope. No shell tool measures it and
  writing one is more work than it adds while depth and length are
  unbounded; it is revisited once the flattening lands.
- Some functions will get more, smaller functions with names, and the
  file-level line count will rise in places. That is accepted, and the
  unit is the point: every threshold here is per-function, because file
  size points at the wrong target. base's largest shipped file
  (`setup_tui.sh`, 2862 lines) averages 53 lines across 54 named
  functions; `wrapper/run.sh`, a quarter its size, averages 73 across 9.
  The bigger file is the better-shaped one, and a per-file limit would
  have ranked them the other way round. Nothing here is a limit on a
  file.

## Alternatives

**A baseline file listing today's violations, gating only new code.**
Rejected, and it is the alternative that most needed rejecting because it
is the standard answer. A baseline is a hand-kept roster: it has to be
regenerated when a file moves, it drifts against the tree silently (PRD
design principle P2 -- derive the population, never enumerate it), and
nothing in it distinguishes "this was fixed" from "this line no longer
matches". Worse than the maintenance is what it does to the gate's
meaning: a gate with a baseline no longer says "base holds this
standard", it says "base holds this standard except in the 202 places
recorded here", and that file is a permanent, tracked, growing record of
what we decided not to do. It converts a quality bar into an inventory of
debt with an accountant attached. The tree is made clean instead, and the
gate lands on a clean tree.

> **Amendment (#994, 2026-09-03): the single-integer CEILING phase 3
> adopted is not this alternative, and here is the test that separates
> them.** Every reason above is a property of a per-SITE roster, and
> each fails to attach to one number. It has to be regenerated when a
> file moves -- a count does not know what a file is. It drifts silently
> against the tree -- a count is recomputed from the tree on every run.
> Nothing in it distinguishes "fixed" from "no longer matches" -- a
> count has no entries to be stale about. It says "the standard holds
> except in these 108 places" -- a count names no place, so it can
> excuse no particular function; what it says is "the standard holds,
> and 108 functions have not been brought to it yet", which is a true
> statement about a migration rather than a permanent exemption. P2 is
> the sharpest of these and it comes out the same way: the population is
> still derived from the git index every run, and the only hand-kept
> figure is how far the migration has got.
>
> The concession, stated because an amendment that only argues its own
> side is worth nothing: a ceiling has SLACK. Flatten one function
> without lowering the number and a new violation can land green in the
> room that opens. A per-site baseline would have caught that. What
> bounds it is that the slack is printed on every run, clean or not, and
> that lowering the number is a one-line change any reviewer can ask
> for; what makes it acceptable is that the alternative on offer was not
> a per-site baseline but no enforcement for the length of the
> migration.
>
> The instrument is not new here. `drivers/catalog_description.sh` (#999)
> carries the same one-number transition ceiling for the same reason,
> with the same argument and the same disclosed cost -- so this is base
> applying a mechanism it had already settled, not inventing an
> exception for its own metrics.

**Gate new and changed code only, with no baseline file** -- compute the
violation set against the merge base and fail only on additions. Rejected
for the same reason with a different mechanism: the exemption is now
implicit rather than tracked, which is worse, not better. It also makes
the gate's result depend on which commit you are branched from, so the
same file passes on one branch and fails on another, and it rewards
touching a bad function as little as possible -- exactly backwards from
what a function that resists change needs.

**Raise the thresholds to where the tree already sits** (depth 6, length
515, parameters 31). This is the honest version of doing nothing, and
saying it plainly is what disqualifies it: thresholds set to the current
worst case cannot report anything, because nothing can exceed them
without first becoming the new worst case.

**Keep the thresholds as advisory, reported but never failing.** Rejected
by base's own experience with the coverage figure: a non-gating metric
(#377 made coverage exactly that) was ignored for as long as it was
non-gating, and it took ADR-00000008 promoting it to an enforced PR gate
before anything moved. An advisory threshold is a threshold whose only
consumer is somebody who was already going to comply.

**Treat this as a style guide entry rather than an ADR.** Rejected
because the thing being decided is not a formatting preference that a
reader can take or leave -- it is the answer to "what do we do about a
function that is hard to split", and that answer had a defensible
alternative that was argued and lost. A decision with a rejected
alternative is an ADR by definition; a style guide entry would record the
conclusion and lose the argument, which is the half a future reader needs.
