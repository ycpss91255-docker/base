# Unit Tests

Unit specs under `test/bats/unit/`: **3985 tests**.

> Part of the `just test` self-test suite — what runs in the `Self Test`
> CI job. See [TEST.md](TEST.md) for the index across all test types and
> the self-test grand total.

## How this catalogue is maintained

**Every section below is generated, and nothing in it is authored here.**
The heading, the count, the blurb and one row per `@test` are produced by
`script/test/sync-doc-counts.sh` (`just test sync-docs`) from the spec files
themselves, and validated by its read-only twin
`script/test/check_test_md_drift.sh` (`just test sync-docs-check`).

**A description is authored in the spec file, above the test it describes.**
It is a `# why:` comment block on the lines immediately above the `@test`; a
spec file's own blurb is a `# why:` block in the file's opening comment run.
You write it where you are already typing, in the same keystroke run as the
test:

```bash
# why: an empty scan root is how this lint silently stopped covering
# anything -- it must fail, not pass over nothing.
@test "just provenance: a missing scan root fails rather than passing vacuously" {
```

Continuation lines are joined with a single space, so wrap them at the file's
normal width. A bare `#` line between the `# why:` line and the `@test`
detaches the description from its test and is a lint finding; so is a `# why:`
block with no `@test` beneath it, which is what a rename used to leave behind.
A `|` is typed raw -- the generator escapes it when it renders the row.

**What a description says: WHY THIS CASE MATTERS** -- what it defends, whether
it is the load-bearing one, what breaks without it. NOT what the test does;
the name already says that, at length. Compare:

```text
name: build.sh test: a fully CACHED verification stage is not reported as a pass
desc: The load-bearing case: every check CACHED reports that nothing ran
```

A required field people do not know how to fill produces filler that restates
the name, which is worse than no description because it looks like information
and passes every mechanical check.

**Editing the generated region does nothing.** Everything between
`<!-- generated: catalogue sections -->` and `<!-- /generated -->` is replaced
wholesale on every run: a row you delete here comes back byte-for-byte, a
description you reword here is overwritten, and a description you delete from a
spec turns its row into `-` and fails the drift gate. Renaming a test now
carries its description with it, because the description moved with the lines
above it.

**Rows follow spec file order; sections follow the level's glob order.** The
catalogue reads the way the tree reads, and neither ordering is a placement
anybody maintains.

## The setup.sh-derived unit specs

The setup.sh decomposition (ADR-00000014) split one god-source into
subsystem libs; these specs mirror those libs per ADR-00000015 (test
files mirror source — one lib maps to one `<name>_spec.bats`, a lib with
multiple sub-unit specs gets a `<name>/` folder, source is never split
for tests). They share one `setup_spec_helper.bash` (common `setup()` /
`teardown()`); behaviour and total test count are unchanged across the
re-split. P1a (refs #758) relocated the compose / stage / setup_cmd
specs; P1b (closes #758) split the remaining `setup_spec.bats` /
`setup_emit_spec.bats` god-files into one spec per leaf lib (`resolve` /
`drift` / `setup_detect` / `setup_conf` / `env_emit`), slimming
`setup_spec.bats` to the orchestrator (`main` dispatch, `usage`,
`_setup_msg`, the `apply` pipeline integration tests) and retiring
`setup_emit_spec.bats`. P1b also returned the remaining isolated unit
tests to their owning lib's spec: the `_parse_ini_section` /
`_ini_tokenize` INI-parser tests to `conf_accessor_spec.bats`
(`lib/conf.sh`), `_setup_known_section` to `setup_cmd_spec.bats`
(`lib/setup_cmd.sh`), and the `_setup_ssh_x11_cookie` helper tests to
`setup_detect_spec.bats` (`lib/setup_detect.sh`).

## Test Files

<!-- generated: catalogue sections -->

### test/bats/unit/abi_gate_spec.bats (18)

Unit tests for `script/ci/abi-gate.sh`, the shared gate a downstream repo
asks before auto-releasing a merged dependency bump (#829). The question it
answers is narrow on purpose -- is this old -> new pin change ABI-safe by
the rule this dependency itself follows -- and every other question (which
version to cut, whether to fan out) belongs to the caller.

The fail-open direction here is declaring a breaking change safe, so "cannot
determine" resolves to NOT releasing, always: an unparseable version, a
missing declaration, an axis this cannot read, a downgrade, a pair the
upstream never sanctioned. There is deliberately no default for the ABI axis
-- which component of a version is that dependency's ABI is a fact about the
dependency (librealsense's SONAME carries its minor, plenty of libraries
only their major), and base guessing it is exactly the fail-open this gate
exists to prevent.

A refusal exits non-zero and prints NOTHING on stdout, so a caller appending
stdout to GITHUB_OUTPUT gets no `decision` key -- both the
`steps.x.outputs.decision == 'release'` wiring and the bare exit status read
a refusal as "do not release".

| Test | Description |
|------|-------------|
| `abi-gate: a patch bump under a major.minor ABI is released` | The case the whole mechanism exists for: a patch bump of a dependency whose ABI is its major.minor. Nothing about the interface moved, so the repo may cut a Z without a human (ADR-00000027 sec.1). |
| `abi-gate: a minor bump under a major-only ABI is released` | The same bump judged by a dependency whose ABI is only its major. The axis is the caller's declaration, so a minor move is safe here and is not safe above -- one rule, two answers, which is why the axis has no default. |
| `abi-gate: an approval prints exactly a decision and a one-line reason` | GITHUB_OUTPUT is line-oriented, so the reason has to be one line or the key after it is lost. Also pins the shape a caller reads: exactly a decision and a reason. |
| `abi-gate: refuses a minor bump under a major.minor ABI` | The bump this gate is for: the minor moved on a dependency whose SONAME carries the minor, so the ABI changed and a downstream rebuild is not a formality. Refused by name, with the axis in the message. |
| `abi-gate: refuses a major bump` | The unambiguous break, under any convention. |
| `abi-gate: refuses when no ABI axis is declared, naming what to declare` | The gate cannot know which component is a given dependency's ABI, and a default would be a guess that silently releases a break. Absent means refuse, and the message has to say what to declare. |
| `abi-gate: refuses an ABI axis it does not recognise` | An axis the gate does not recognise is the #1012 shape -- an unrecognised input must not resolve to the permissive branch. It refuses instead of falling back to either known axis. |
| `abi-gate: refuses an unparseable new version, naming it` | A version the gate cannot parse cannot be compared, and an uncomparable pair is the definition of "cannot determine". Named in the message so the reader sees which side was unreadable. |
| `abi-gate: refuses an unparseable old version` | The same rule on the other side. An old pin recorded as a commit sha says nothing about the interface it carried. |
| `abi-gate: refuses a version carrying a suffix` | A suffixed upstream version is a prerelease or a vendor build, not a released interface. It is refused rather than compared on its numbers. |
| `abi-gate: refuses when the version did not change` | Nothing changed, so there is nothing to release. Silence here would cut a release whose changelog says a dependency moved when it did not. |
| `abi-gate: refuses a downgrade the axis test would call safe` | A downgrade is never a routine bump -- it is a revert or a mistake, and either way it is a person's call. The component test alone would call 2.56.2 -> 2.56.1 a safe patch move. |
| `abi-gate: refuses a 0.x pair declared with a major-only ABI` | Under 0.x a major carries no compatibility promise, so `major` is not a meaningful axis for such a pin. Refused with the fix rather than silently re-read as major.minor: a declaration nobody corrected would keep meaning something other than what it says. |
| `abi-gate: a 0.x patch bump under a major.minor ABI is released` | The same 0.x dependency declared correctly still auto-releases its patch bumps -- the rule above is about the declaration, not a blanket ban on 0.x. |
| `abi-gate: refuses a bump only the upstream compat declaration stops` | A wrapper declares the dependency version it was tested against, and a pair upstream never shipped together is not made safe by each half being ABI-clean on its own. When the caller supplies that declaration, the new pin has to agree with it on the ABI axis. The bump here is one the axis test alone would release -- 2.56.1 -> 2.56.4 leaves the major.minor untouched -- so only the declaration (2.55.0) can be refusing it. A pair the axis check already stops would hold with this rule deleted, and pin nothing. |
| `abi-gate: releases a bump the upstream compat declaration sanctions` | The sanctioned pair passes -- the declaration is a constraint, not a second reason to refuse everything. |
| `abi-gate: refuses an unparseable upstream compat declaration` | A declaration the gate cannot parse is not a satisfied constraint. It is refused rather than dropped, which is what an ignored unreadable input amounts to. |
| `abi-gate: a refusal prints nothing on stdout and names the dependency` | The fail-closed property the wiring rests on. A refusal that printed a partial decision would leave an output key for a later job to gate on. It writes to stderr only, so there is no `decision` key at all, and the dependency is named there for whoever reads the log. |

### test/bats/unit/action_ref_agreement_lint_spec.bats (21)

| Test | Description |
|------|-------------|
| `workflows: every action is used at exactly one ref (#949)` | The real tree, read independently of the lint |
| `_run_action_ref_agreement: FAILS when two workflows disagree on an action's ref (#949)` | The v6/v7 split, as a fixture |
| `_run_action_ref_agreement: names the action, both refs and every call site (#949)` | A finding you can act on without grepping |
| `_run_action_ref_agreement: PASSES when every call site agrees (#949)` | The fixed state is green |
| `_run_action_ref_agreement: FAILS when two entry points of ONE action repo disagree (#949)` | A ref is a tag on the repo, so the sub-path is dropped |
| `_run_action_ref_agreement: reads the block uses: form, not only the compact one (#949)` | Both step spellings are call sites |
| `_run_action_ref_agreement: ignores a local ./ call, which carries no ref (#949)` | The callee is this tree, at this commit |
| `_run_action_ref_agreement: ignores a commented-out uses line (#949)` | A comment is not a call site |
| `_run_action_ref_agreement: strips a trailing comment, so an annotated sha pin still compares (#949)` | Otherwise every annotated pin is its own version |
| `_run_action_ref_agreement: FAILS when a sha pin and a tag name the same action (#949)` | Two ways of saying which code runs still disagree |
| `_run_action_ref_agreement: an allow marker carrying a reason excludes that call site (#949)` | A hold-back is recorded where it happens |
| `_run_action_ref_agreement: an allow marker with NO reason is itself a failure (#949)` | A bare mute rebuilds the hazard inside the repo |
| `_run_action_ref_agreement: an allow marker two comment lines above still applies (#949)` | The whole comment block carries the exception |
| `_run_action_ref_agreement: an allow marker does NOT leak to the next call site (#949)` | One recorded divergence licenses no others |
| `_run_action_ref_agreement: dies when .github/workflows/ is missing (#949)` | Nothing scanned is an error, not a pass |
| `_run_action_ref_agreement: dies when the workflow directory holds no workflow (#949)` | Same, one level in |
| `_run_action_ref_agreement: dies when no workflow names a versioned action (#949)` | A reader regression cannot report silence forever |
| `_run_action_ref_agreement: reports the real workflow tree clean (#949)` | The lint agrees with the tree it ships with |
| `action-ref-agreement: is a member of the lint phase's tool table (#949)` | A lint nobody runs is a comment |
| `action-ref-agreement: has a lint-static CI join (#949)` | Named plain-runner matrix entry, no docker |
| `action-ref-agreement: its failure event id is registered (#949)` | An unregistered id is an anonymous exit |

### test/bats/unit/adr_doc_claims_spec.bats (17)

| Test | Description |
|------|-------------|
| `doc/adr: every record's workflow and quotation claims hold against the tree (#927)` | - |
| `doc/adr: the scan is not vacuous -- ADR-00000027 is read and holds blocks (#927)` | - |
| `release-worker.yaml is workflow_call-only, so no base tag reaches it (#927)` | - |
| `self-test.yaml IS tag-triggered, so it is what a base tag runs (#927)` | - |
| `R1: FAILS a tag claim that names a workflow with no tag trigger (#927)` | - |
| `R1: PASSES the same claim once the block states the real trigger (#927)` | - |
| `R1: PASSES a tag claim about a workflow that IS tag-triggered (#927)` | - |
| `R1: IGNORES a workflow named with no trigger claim in the block (#927)` | - |
| `R1: IGNORES a name this repo has no workflow for (#927)` | - |
| `R1: a workflow named inside a fenced example is inert (#927)` | - |
| `R2: FAILS attributing the payload manifest to a workflow that never reads it (#927)` | - |
| `R2: a workflow that only MENTIONS the manifest in a comment does not count (#927)` | - |
| `R2: PASSES the attribution against the workflow that does read it (#927)` | - |
| `R2: a separate bullet is a separate claim (#927)` | - |
| `R3: FAILS a verbatim claim about a file outside this repo (#927)` | - |
| `R3: PASSES a verbatim claim about a file this repo carries (#927)` | - |
| `R3: IGNORES verbatim used about behaviour rather than a quotation (#927)` | - |

### test/bats/unit/adr_numbering_spec.bats (37)

Unit tests for `script/test/drivers/adr_numbering.sh` (`_run_adr_numbering`,
refs #808), the ADR-numbering lint. The registry is the filesystem
(`doc/adr/NNNNNNNN-<slug>.md`): the lint FAILS on a duplicate ADR number or
a malformed filename and WARNS (exit 0) on a numbering gap. Driven at the
driver CLI over throwaway fixture `doc/adr/` trees, plus a real-tree guard
that the live `doc/adr/` passes today with the intentional `00000009` gap
warned.

| Test | Description |
|------|-------------|
| `_run_adr_numbering: FAILS on a duplicate ADR number, naming both files (#808)` | Duplicate number fails, both files named |
| `_run_adr_numbering: FAILS on a malformed filename, naming the file (#808)` | Malformed filename fails, file named |
| `_run_adr_numbering: FAILS on a too-short (non-8-digit) number prefix (#808)` | Non-8-digit prefix fails |
| `_run_adr_numbering: EXEMPTS doc/adr/README.md (the index), not flagged malformed (#808)` | README.md index exempt from the naming contract |
| `_run_adr_numbering: PASSES a clean set WITH a gap, warning the gap (exit 0) (#808)` | Gap warned, exit 0 |
| `_run_adr_numbering: PASSES a clean contiguous set with no gap warning (#808)` | Contiguous set clean, no gap line |
| `_run_adr_numbering: does NOT flag a gap as a duplicate or malformed (#808)` | Gaps are advisory, not failures |
| `_run_adr_numbering: an early-closing reader cannot abort the min/max scan (#898)` | No pipeline status owned by a departing reader |
| `_run_adr_numbering: min/max stay correct with sort/head unusable (#898)` | In-shell range still bounds the gap scan |
| `_run_adr_numbering: FAILS on an ADR- reference to a number no record claims (#1021)` | The reference that outlives its record. A renumber frees the old number, so every `ADR-<old>` left behind names nothing -- and this is the only shape of missed reference a checkout can still recognise. |
| `_run_adr_numbering: FAILS on a doc/adr path whose number and slug name no file (#1021)` | The shape that survives a collision repair. The number still resolves -- another record took it -- so nothing about the number is wrong; the SLUG beside it is what says the pointer no longer names what the author meant. |
| `_run_adr_numbering: a number a file declares its own is not scanned (#1021)` | The difference between a reference and a FIXTURE, DECLARED rather than guessed at -- and declared per NUMBER. Every reference form carrying a declared number is dropped, not the ones some heuristic recognised, which is what let a renumber rewrite half of one and leave the assertions naming the other record. |
| `_run_adr_numbering: a number the declaration does not name is this tree's (#1021)` | The half a whole-FILE drop resolved to "pass". A spec that builds a throwaway registry still says things about THIS tree's -- a `# why:` block naming the record a case came from, a comment naming the record whose shape the check was written for -- and dropping the file whole made those pointers invisible here and unreachable by the verb, which is the stale-pointer-under-a-green-gate this check exists to prevent. The declaration names numbers; a number it does not name is this tree's. |
| `_run_adr_numbering: a declaration that names no number exempts nothing (#1021)` | Where the grammar's residue points. A declaration this reader cannot parse -- no number list, the shape the whole-file drop used -- exempts NOTHING and is itself a finding. The alternative is a marker that has quietly stopped protecting the fixtures it was written for while every gate stays green, which is the failure mode the declaration exists to remove. |
| `_run_adr_numbering: FAILS on a declared number a test's marker publishes (#1021)` | The residue the per-number rule keeps, and the only site at which it bites. A declaration is per FILE, and a `# why:` marker is the one thing in a spec that LEAVES the file: the catalogue generator publishes it verbatim into doc/test, a document that declares nothing. A DECLARED number written there therefore arrives in the catalogue as this tree's reference, and the verb has no state to reach -- it rewrites the published row, the regeneration puts the number straight back from the marker it may not touch, and the run aborts half-way with the record already moved. The marker is the one thing a repair can edit, so the finding names it. |
| `_run_adr_numbering: FAILS on a declared number the file blurb publishes (#1021)` | The same shape at the file-level marker, which the generator publishes as the section BLURB rather than a row. One grammar, two sites, and a rule that read only the attached blocks would leave the other half of the published text unchecked. |
| `_run_adr_numbering: FAILS on a declared number a test name publishes (#1021)` | The third published site, and the one ADR-00000034 records as having actually cost: a `@test` NAME carrying the number is a ROW in a generated catalogue, published whether the test carries a marker or not. A check that read only the prose would pass a spec whose names are the half that comes straight back after every regeneration. |
| `_run_adr_numbering: FAILS on a doc/adr path rooted in a shell expansion (#1021)` | The blind spot the guess created, and it was live. The rule was a two-character lookback: a `doc/adr/` path preceded by `}` was taken for somebody's fixture. coverage_badge_spec.bats writes `"${REPO}/doc/adr/00000008-coverage-sharded-pr-gate.md"` as a pointer at this tree's OWN registry, so a renumber of that record would leave a stale pointer under a green lint -- and a rule whose default on the shape it does not recognise is "pass" is not a check. |
| `_run_adr_numbering: FAILS when the index has no row for a record (#1021)` | The site the hand renumber actually missed. The index row is the one place every record is named exactly once, so a record with no row is a record the index has lost track of. |
| `_run_adr_numbering: FAILS when the index carries a row for no record (#1021)` | The same failure in its other direction, and the exact state the 00000030 renumber left behind: the record moved and its row did not, so the index names a number that is nobody's. |
| `_run_adr_numbering: FAILS when two index rows carry the same number (#1021)` | Two rows on one number is what a collision looks like in the index, and taking the first would make the check agree with whichever row was written first rather than with the tree. |
| `_run_adr_numbering: FAILS on a bare number outside a row that no record claims (#1021)` | Two of the three sites the 00000030 hand repair actually left stale were audit-conclusion bullets, not table rows -- and the row check reads only `^\| NNNNNNNN `, so a recurrence in exactly those two lines stayed green. `just adr renumber` disagrees: it rewrites a BARE number ANYWHERE in this document, on the stated ground that its 8-digit runs are all ADR numbers, its rows opening with one AND its audit conclusions enumerating them. Half a document guarded is the same defect one line down. |
| `_run_adr_numbering: FAILS on an emphasised bare number no record claims (#1021)` | The other spelling the live document actually uses for the same conclusion, emphasised rather than bare-leading. One reading of "a bare 8-digit run", not a list of the shapes somebody happened to write. |
| `_run_adr_numbering: FAILS on a bare number in a row's note cell (#1021)` | The same rule inside a row, where the note cell carries the numbers a verdict points at (`keep (amended by 00000023)`). The row check reads the number the row OPENS with and nothing else, so a stale cross- reference three columns along is the audit-conclusion gap again. |
| `_run_adr_numbering: reads a bare number in prose as prose, not a row (#1021)` | The boundary, and it is load-bearing rather than a concession. The index deliberately names a number no record claims -- "`00000009` is an intentional gap ... do not invent a `00000009`", twice, in free prose -- and running the bare check over the whole document reddens the live tree on exactly those two lines. That is the one place this lint and the verb cannot share a rule: the verb rewrites the number it is MOVING, which has a record by construction, and this asks which numbers have none. |
| `_run_adr_numbering: PASSES when every record has one row and every reference resolves (#1021)` | The passing shape, so the three failures above are read as a contract rather than as a lint that dislikes index tables. |
| `_run_adr_numbering: a tree the checkout declares derived carries no reference (#1021)` | The tier the local run actually takes -- a checkout whose git the reader cannot query (a worktree inside the test container). What the tree DECLARES derived is still not source: an old release and a transcript are records of what was said once, and the verb cannot reach either, so a finding in one is a red gate with no way to clear it. |
| `_run_adr_numbering: a symlink is read as the file it points at (#1021)` | A symlink is a file this repo keeps true. `git ls-files` lists the eight wrapper links at the root, so the git tier reads them; the walk printed only `-type f` and did not, which made the two tiers' populations differ by eight files -- and a lint and a verb that read one population is the whole point of the shared reader. The reference here is reachable ONLY through the link, so nothing but the link can report it. |
| `_run_adr_numbering: an ignored path written without a trailing slash is not read (#1021)` | The tree's own declaration, read the way the tree actually writes it. git needs no trailing slash, and this repo's root .gitignore uses none for `.claude` or `CLAUDE.md`. A pattern the reader does not recognise is a path this lint scans and the verb never sweeps -- a finding with no repair path through the documented command, which is the whole reason the two read one population. The residue is unchanged: only the root file, and only patterns with no wildcard and no negation. |
| `_run_adr_numbering: an untracked file in a checkout is read like any other (#1021)` | The two tiers have to name ONE population, and only one of them can ask git. `just test` reads this checkout from inside the container, where a worktree's `.git` is a file naming a gitdir that was never mounted, so the WALK is the tier the local gate takes -- and a walk cannot tell a tracked file from an untracked one. Dropping the untracked ones where git DOES answer therefore made the host verb sweep less than the container lint reads: a scratch file citing a dangling number reddens the local gate and `just adr renumber` never touches it, which is the red-with-no- repair-path the shared population exists to prevent. Not yet tracked is not derived. |
| `_run_adr_numbering: an untracked but ignored path is still not read (#1021)` | The other half of the same rule, and the half that keeps it from collapsing into "grep everything". Untracked is read; DECLARED DERIVED is still not, and in the git tier it is git's own exclude machinery that says so rather than this file's reader. A materialised old release and a wrapper transcript are records of what WAS said, so a verb that rewrote them would falsify them -- the reason the population is pruned at all. |
| `_run_adr_numbering: a root git answers for but lists nothing is not an empty tree (#1021)` | An empty answer from the probe is not the answer that the tree is empty. `git rev-parse` succeeds anywhere INSIDE a checkout, so a scan root that is a subdirectory the checkout declares derived -- a materialised release under .prev-release/, a vendored tree -- answers the probe and then lists nothing: nothing under it is tracked, and git's own excludes drop it from `--others`. Taking that for the population turns every file in the tree into no files at all, and a lint over no files is clean over anything, silently. Falling back to the walk is how "cannot tell" refuses instead of passing, and the verb reads the same population, so a sweep cannot go quiet here either. |
| `_run_adr_numbering: a wildcard the tree writes without a separator is read (#1021)` | The trailing-slash defect's remaining siblings. A pattern with a wildcard and no separator is what git matches against a basename at any depth, which is exactly what `find -name` matches: read it, and the tier that cannot ask git stops keeping a file git drops. The residue this leaves is not the same shape as the one it removes -- see the two cases below. |
| `_run_adr_numbering: a declaration this reader cannot apply is reported (#1021)` | What a reader that cannot apply a declaration must do instead of quietly widening its population: SAY SO. A negation and a pattern whose wildcard sits beside a separator are the two forms whose meaning `find` does not reproduce -- git's `*` stops at a `/` and find's does not, and nothing in a prune expression re-includes. Skipped silently they put files in this lint's population that `just adr renumber` never sweeps, which is the red-gate-with-no-repair-path the shared reader exists to close; reported, the tree is told which line to spell differently. |
| `_run_adr_numbering: a nested .gitignore is reported, not ignored (#1021)` | The same report for the declaration this reader never opens at all. Only the root file is read, so a nested one is a rule the walk cannot apply and git can -- the population splits on it exactly as it split on a trailing slash, and the finding is what keeps the split from being discovered by a red gate no documented command can clear. |
| `_run_adr_numbering: a checkout reports no unreadable declaration (#1021)` | And the report is about the WALK, not about the tree. Where git answers, git applies every one of these forms itself -- that is the tier whose exclusion the walk is only ever approximating -- so reporting them there would fail a checkout for a declaration nothing in it gets wrong. |
| `_run_adr_numbering: the REAL doc/adr/ passes today (00000009 gap warned) (#808)` | Live tree clean, 00000009 gap warned |

### test/bats/unit/adr_renumber_spec.bats (19)

Nothing allocates an ADR number, so parallel branches collide by
construction (base#1021: three took 00000030 on one day, each right by the
only rule there is). The collision reaches a red check; the REPAIR was what
cost -- 14 files, three of them left incomplete and green. The cases here
are about the property that makes the repair trustworthy: the reference set
is DERIVED, the classes are told apart rather than sed'ed over, and a state
the tool cannot resolve without guessing is refused whole rather than
half-applied.

The fixture roots are not git checkouts. That is deliberate: it exercises
the same code path a checkout takes apart from the rename verb, and it keeps
the cases about references rather than about git.

| Test | Description |
|------|-------------|
| `adr renumber: moves the record and rewrites ADR- references (#1021)` | The record itself, and the reference class that carries most of them. If the tool did only this it would already be the whole 14-file sweep for most files -- the interesting part is what it does NOT do to the other classes. |
| `adr renumber: rewrites a doc/adr path reference, slug and all (#1021)` | The path form carries the slug, which is what makes it the one reference class that stays unambiguous even where the number does not -- and the class a rewrite of `ADR-<n>` alone would leave behind. |
| `adr renumber: rewrites the bare number in the index and nowhere else (#1021)` | The index writes its numbers bare, and everywhere else a bare 8-digit run is not a reference at all. Rewriting bare numbers tree-wide is how a renumber would corrupt the fixture registries the lint specs build, so the class is scoped to the one document whose 8-digit runs are all ADR numbers. |
| `adr renumber: regenerates the catalogue instead of editing it (#1021)` | The site a blind sed gets wrong. One of the 14 was a `@test` NAME carrying the number, and a test name is a ROW in a generated catalogue: rewriting the row directly puts a hand edit into a generated file, which the next regeneration reverts. The spec is a source and is rewritten; the catalogue is rebuilt from it. The stale count proves the rebuild happened rather than a substitution that only looked like one. |
| `adr renumber: rewrites the hand-written half of a generated document (#1021)` | A generated document is only PARTLY generated -- its preamble is hand-written prose outside the fence, and the generator does not own a word of it. Skipping the file because the generator writes part of it left a reference standing there, found by running the tool over a copy of the real tree. Both halves are covered: the prose is rewritten, and the fenced half is rebuilt afterwards from the specs. |
| `adr renumber: leaves a number a file declares its own alone (#1021)` | The tool corrupting its own spec. A file that builds a throwaway registry declares the NUMBERS it uses, and a reference carrying one of them is left alone in every class at once. Rewriting only the classes a heuristic recognised is worse than rewriting none of them: the `ADR-<n>` and `adr/<n>-` forms moved and the bare numbers a spec passes to this tool as ARGUMENTS did not, so the setup and the command named different records, with the survivor self-check and the lint both green. |
| `adr renumber: a declaration exempts its numbers, not its file (#1021)` | The half of that rule the verb can lose on its own. A declaration exempts the NUMBERS it names, not the file that carries one: both of this tree's declaring specs also point at real records, so a whole-file drop leaves a live pointer unswept -- and where that pointer is a `# why:` block, the generator publishes it as a catalogue row, the rewrite fixes the row, the regeneration puts the old number straight back, and the run ends on a survivor with the record already moved. Asserted here on the VERB because nothing else runs it: the lint reads the same declaration through the same reader, and its half is asserted in adr_numbering_spec.bats, so without this case the verb could go back to a whole-file exemption with every spec green. |
| `adr renumber: a declaration that names no number hides no reference (#1021)` | The whole-file drop's other half, and the state it left behind. A spec that builds a throwaway registry still carries pointers at THIS tree's -- a `# why:` block naming the record a case came from, which the generator then publishes verbatim as a catalogue row. Dropped whole, the marker was never rewritten, so the rewrite pass fixed the catalogue and the regeneration immediately put the old number back: the verb aborted on a survivor no message could attribute, with the record already moved and 25 files rewritten. A declaration exempts the numbers it NAMES, and one that names none exempts nothing. |
| `adr renumber: a survivor in a generated file names the marker it came from (#1021)` | The residue the per-number rule keeps, and the message it has to carry. A declaration is per FILE, and a marker is the one thing in a spec that LEAVES the file: the generator publishes it verbatim into a catalogue that declares nothing. So a DECLARED number written in a marker arrives there as this tree's reference, the sweep rewrites the published row, the regeneration puts the old number straight back from the marker this verb may not touch, and the run aborts on a survivor. Naming only the generated file misdirects the repair: a hand edit there is undone by the next `just test sync-docs`, and the marker is the one thing that can be changed. |
| `adr renumber: leaves a tree the checkout declares derived alone (#1021)` | The population, and the property that keeps this verb and the ADR lint from disagreeing about what a reference is -- they read one. A tree the checkout declares derived is not swept: a materialised old release and a wrapper transcript are records of what WAS said, so rewriting one falsifies it, and a finding the verb cannot reach is a red gate with no repair path through the verb. |
| `adr renumber: sweeps an untracked file in a checkout (#1021)` | The verb's half of the population the lint reads. A file that is in the working tree and not yet in the index is not derived -- nothing declares it so -- and the walk tier, which is the tier `just test` takes from inside the container, cannot tell it from a tracked one anyway. So the verb has to sweep it here, where git CAN answer, or the local gate reddens on a finding no documented command repairs. |
| `adr renumber: a tracked symlink is not replaced by a copy of its target (#1021)` | What `sed -i` does to a symlink, which is replace it with a regular copy of its target and report success. A symlink has no content of its own, so there is nothing here to rewrite: the bytes belong to the target, and the target is swept like any other file. base survived this only by an ordering accident -- all eight of its wrapper links sort after their `dist/` targets in `git ls-files`, so the pattern no longer matched by the time the link was reached. This case pins the opposite order. |
| `adr renumber: REFUSES a reference reachable only through a symlink (#1021)` | The other half of not writing through a link: a reference reachable only through one is a reference this verb cannot repair, because the file holding the bytes is a tree the checkout declares derived and rewriting it would falsify a record of what was said. Refused and named, rather than reported as a complete sweep -- the lint reads the same link and would fail on it, so a silent pass here is the disagreement the shared population exists to prevent. |
| `adr renumber: REFUSES a target number a record already claims, changing nothing (#1021)` | A target somebody else already claims is the collision again, one move later. Refusing BEFORE the first write is what keeps a refusal from leaving a half-renumbered tree somebody has to unpick by hand. |
| `adr renumber: REFUSES a number two records claim, naming both (#1021)` | The state a collision merge actually lands in, and the one the tool must not guess its way through: with two records on one number, a prose ADR-00000030 names whichever the author had in mind and nothing in the tree records which. The refusal names both and points at the resolution that IS derivable -- renumber on the branch, where the number has one claimant. |
| `adr renumber: moves a record git does not track yet (#1021)` | The record this verb exists for is the one a branch authored this morning, and `git add` is not part of authoring an ADR. `git mv` refuses a path it does not track, so the git tier renamed nothing, ignored the refusal and reported a renumber -- leaving the record at its old number with every reference in the tree rewritten to the new one, and the survivor check unable to see it because the survivor check greps for the number the sweep has just removed everywhere. |
| `adr renumber: REFUSES when the rename fails, changing nothing (#1021)` | A rename that did not happen is not a renumber. `_renumber_move` ran `git mv` and returned 0 whatever it said, so any failure -- a concurrent `index.lock`, a permission, a repository state -- came back as "N reference file(s) rewritten" and exit 0, with the record still at its old number and every pointer at the tree moved to the new one. The header promises the opposite ("a refusal leaves nothing half-renumbered") and the rename is now the FIRST write, so there is nothing to unpick. |
| `adr renumber: REFUSES a record no file matches, naming what it looked for (#1021)` | A record that is not there is a typo, and a tool that renamed nothing and reported success would leave the operator believing a sweep had happened. |
| `adr renumber: reports the files it rewrote and leaves no reference behind (#1021)` | The self-check, and the reason the tool can be trusted with a 14-file sweep: it re-reads the tree afterwards and fails if any reference to the old number survived. A class nobody thought of shows up as a failure here rather than as a green run with a stale pointer. |

### test/bats/unit/adr_structure_spec.bats (27)

| Test | Description |
|------|-------------|
| `_run_adr_structure: FAILS on a missing '> Serves:' back-pointer, naming the file (#994)` | - |
| `_run_adr_structure: a '> Serves:' that is not at line start does NOT count (#994)` | - |
| `_run_adr_structure: FAILS on a missing '## Context' (#994)` | - |
| `_run_adr_structure: FAILS on a missing '## Decision' (#994)` | - |
| `_run_adr_structure: FAILS on a missing '## Consequences' (#994)` | - |
| `_run_adr_structure: FAILS on a missing '## Alternatives' -- required, not advisory (#994)` | - |
| `_run_adr_structure: ACCEPTS the house heading variants with trailing text (#994)` | - |
| `_run_adr_structure: a required heading appearing TWICE at column 0 is refused (#994)` | - |
| `_run_adr_structure: indenting the illustrated heading is the whole fix (#994)` | - |
| `_run_adr_structure: a second '> Serves:' at column 0 is refused (#994)` | - |
| `_run_adr_structure: a second '- **Status:**' at column 0 is refused (#994)` | - |
| `_run_adr_structure: an illustrated ADR template is refused on the parts the file DOES carry (#994)` | - |
| `_run_adr_structure: KNOWN FAIL-OPEN -- a part omitted AND illustrated at column 0 reads as compliant (#994)` | - |
| `_run_adr_structure: FAILS on free text after Accepted (#994)` | - |
| `_run_adr_structure: FAILS on free text after Rejected (#994)` | - |
| `_run_adr_structure: FAILS on a Status line that is absent entirely (#994)` | - |
| `_run_adr_structure: FAILS on 'Proposed', which is not one of the three values (#994)` | - |
| `_run_adr_structure: FAILS on a supersession pointing at a non-8-digit number (#994)` | - |
| `_run_adr_structure: FAILS on a supersession carrying a trailing date (#994)` | - |
| `_run_adr_structure: ACCEPTS all three contract values (#994)` | - |
| `_run_adr_structure: EXEMPTS doc/adr/README.md (the index) (#994)` | - |
| `_run_adr_structure: names EVERY offending file, not just the first (#994)` | - |
| `_run_adr_structure: reports how many ADRs it examined (#994)` | - |
| `_run_adr_structure: REFUSES when doc/adr/ holds no ADR at all (#994)` | - |
| `_run_adr_structure: REFUSES when doc/adr/ holds ONLY the exempt README (#994)` | - |
| `_run_adr_structure: REFUSES when doc/adr/ does not exist (#994)` | - |
| `_run_adr_structure: the REAL doc/adr/ passes today (#994)` | - |

### test/bats/unit/alpine_eol_spec.bats (9)

| Test | Description |
|------|-------------|
| `alpine eol: the test-tools Dockerfile records its series' end-of-life (#946)` | The expiry is written next to the pin as a marker, not left in a commit message |
| `alpine eol: the recorded series is the series actually pinned (#946)` | A date attached to a series this image is not built on would arm the alarm for the wrong pin |
| `alpine eol: the recorded date is parseable, not merely present (#946)` | Present-but-unreadable is the state a presence check would pass |
| `alpine eol: the pinned series is more than the lead time from expiry (#946)` | The scheduled alarm itself: red 180 days out, so the bump is planned work rather than an incident |
| `alpine eol reader: a Dockerfile with NO marker fails, it does not pass (#946)` | Fail-closed: a missing marker is a defect, never an absent constraint |
| `alpine eol reader: TWO disagreeing markers fail rather than a side being picked (#946)` | Two dates for one pin is ambiguity the reader must refuse, not resolve |
| `alpine eol reader: a marker naming a series the ARG does not pin is visible (#946)` | Proves the agreement check can actually see a disagreement |
| `alpine eol reader: an already-expired date reads as negative days (#946)` | The past side of the window, exercised rather than assumed |
| `alpine eol reader: a malformed date FAILS, it does not read as far away (#946)` | A typo must not disarm the alarm by parsing as a distant future |

### test/bats/unit/apk_mirror_spec.bats (7)

APK_MIRROR is the Alpine mirror knob on dockerfile/Dockerfile.test-tools --
the image the WHOLE local gate runs inside. Without it a host that cannot
reach dl-cdn.alpinelinux.org cannot build the gate at all, and the only
thing it is told is `no such package` for every package after ~480s, because
an unreachable index reads as an empty one rather than as a network failure.

The rewrite properties are EXECUTED rather than grepped: the rewrite is a
shell rule, so the way to assert what it does at the default is to run the
extracted rule over a repositories file. What is pinned: the default is the
upstream CDN declared once; the mirror stage's alpine is the pinned ARG and
no other stage names an alpine of its own (this file holds the tree's only
such tie, which template_spec's kcov-builder assertion used to carry); the
rewrite is skipped at the default, checked by the file's inode and mtime
because a sed replacing the host with itself is byte-identical; and every
stage that installs packages derives from the one stage that declares the
arg. The forwarding half is test/bats/integration/apk_mirror_spec.bats'.

| Test | Description |
|------|-------------|
| `APK_MIRROR: declared exactly once, defaulting to the upstream CDN (#1008)` | The upstream host is declared in exactly ONE place, so nothing else has to be kept in agreement with it. A second ARG, or a default spelled elsewhere, is how the two start disagreeing silently -- and the default has to BE the CDN, or a machine that named no mirror gets one. |
| `APK_MIRROR: the mirror stage's alpine is the pinned ARG, and so is every other (#1008)` | The tree's ONLY tie between a tooling stage's alpine and ARG ALPINE_VERSION, after template_spec's kcov-builder assertion had to give it up (that stage is `FROM alpine-apk` now). Nothing else in the gate catches a divergent one: hadolint refuses `:latest` but not a `FROM alpine:3.20` sitting next to `ARG ALPINE_VERSION=3.21`, which builds green and ships tooling on a release the file does not declare. |
| `APK_MIRROR: the build path names no alpine mirror of its own (#1008)` | What keeps "declared once" true across FILES. A `${APK_MIRROR:-dl-cdn.alpinelinux.org}` in compose.yaml would move the upstream host's declaration into a file the Dockerfile cannot see, so the Dockerfile could no longer change it -- the failure the APT_MIRROR_* pair already has in the emitted downstream compose. |
| `APK_MIRROR: at the default the repositories file is not touched at all (#1008)` | The load-bearing case, and the one a byte comparison cannot make. Dropping the guard leaves a sed that replaces the host with ITSELF -- the exact rule the guard prevents -- and its output is byte-identical, so bytes green-light it. Identity (inode, mtime) is what says the rewrite never ran, and that is what buys reach: a mistake in the rule can then only be reached by a caller who asked for a mirror. |
| `APK_MIRROR: an override repoints every repository line (#1008)` | EVERY line moves, not just the first. The seed file carries two repositories because that is the shape alpine ships, and a rule that stops after `main` leaves `community` pointing at the host the caller cannot reach -- a build that then dies halfway through, on the mirror that was supposed to have fixed it. |
| `APK_MIRROR: an empty override is refused by name, not turned into an empty host (#1008)` | An empty value is the one input that would REPRODUCE the bug this knob removes: rewriting the host to nothing hands back the same misleading `no such package`, now with a mirror set, which is the worst place to leave the reader. Refusing it by name is what separates a caller mistake from the original defect. |
| `APK_MIRROR: every stage that installs packages inherits the mirror choice (#1008)` | The file runs apk in four stages, so a knob wired into one leaves the build dying in the next -- later, and with the same misleading message. This is the assertion that names a newly added alpine stage here, on any machine, rather than on the one host that cannot reach dl-cdn and would otherwise be the only place it shows up. |

### test/bats/unit/arch_literal_lint_spec.bats (20)

| Test | Description |
|------|-------------|
| `_run_arch_literal: FAILS on a bare Docker architecture literal, naming file and line (#939)` | - |
| `_run_arch_literal: FAILS on the uname spelling of the same assumption (#939)` | - |
| `_run_arch_literal: FAILS on a mixed-case release-asset spelling (#939)` | - |
| `_run_arch_literal: FAILS on a platform pair literal (#939)` | - |
| `_run_arch_literal: FAILS on a literal inside a comment too (#939)` | - |
| `_run_arch_literal: names the offending literal and points at TARGETARCH (#939)` | - |
| `_run_arch_literal: FAILS on a literal AFTER an allow-end (region does not leak) (#939)` | - |
| `_run_arch_literal: FAILS on an unterminated allow-begin region (#939)` | - |
| `_run_arch_literal: FAILS on an allow-end with no matching allow-begin (#939)` | - |
| `_run_arch_literal: FAILS on an allow-begin carrying no stated reason (#939)` | - |
| `_run_arch_literal: FAILS on a per-line allow carrying no stated reason (#939)` | - |
| `_run_arch_literal: PASSES a Dockerfile that expresses architecture via TARGETARCH (#939)` | - |
| `_run_arch_literal: PASSES a two-spelling mapping table inside an allow region (#939)` | - |
| `_run_arch_literal: PASSES a single line carrying a per-line allow with a reason (#939)` | - |
| `_run_arch_literal: PASSES a Dockerfile that names no architecture at all (#939)` | - |
| `_run_arch_literal: ignores non-Dockerfile files under the scan roots (#939)` | - |
| `_run_arch_literal: scans the repo-root dockerfile/ tree too (#939)` | - |
| `_run_arch_literal: FAILS when a scan root is missing (#939)` | - |
| `_run_arch_literal: FAILS when a scan root holds no Dockerfile (#939)` | - |
| `_run_arch_literal: the REAL shipped Dockerfiles pass today (#939)` | - |

### test/bats/unit/base_docker_namespace_spec.bats (16)

base's self-use of the `docker` namespace (#713, ADR-00000011 sec.2/4/5):
root justfile `mod? docker`, the committed `script/docker/justfile.docker` +
flat `script/<verb>.sh` symlinks resolving into `dist/` (no `.base/` hop),
the `test-tools` compose service building `Dockerfile.test-tools`, and `just
test system` building it via the docker namespace. Also pins the
naming-isolation shape (#891): the build-only `test-tools` service reads the
same `TEST_TOOLS_IMAGE` its consumers read instead of a fixed
`test-tools:local` literal, and the `system` recipe derives that tag from
the tooling Dockerfile's content instead of hardcoding it, and names the
compose project instead of inheriting the checkout directory's basename.
Tightened by #896: EVERY `image:` line must name that variable and NONE may
carry a `:-` default, since two different defaults are what let the build
write one tag while the run read another.

| Test | Description |
|------|-------------|
| `base root justfile mods the docker namespace (#713)` | - |
| `base ships script/docker/justfile.docker as a symlink into dist/ (no .base/)` | - |
| `base ships flat wrapper symlinks resolving into dist/script/docker/wrapper` | - |
| `base compose.yaml declares a test-tools service building Dockerfile.test-tools` | - |
| `just test system builds test-tools via the docker namespace, not a raw docker build (#713, ADR-00000011 sec.5)` | - |
| `base compose.yaml names every image with TEST_TOOLS_IMAGE and gives it no default (#891, #896)` | - |
| `just test system derives the local test-tools tag instead of hardcoding it (#891)` | - |
| `base compose.yaml carries no fallback identity for the mounted checkout (#895)` | - |
| `base root justfile exports the host identity every compose read needs (#895)` | - |
| `just test system supplies the host identity its bare compose run needs (#895)` | - |
| `just test system names the compose project instead of inheriting the basename (#891)` | - |
| `just docker stop builds a compose command with no .env.generated (#1015)` | the env-load half: base never writes an interpolation cache, so a stop that dies sourcing one is a flow `just docker build` can start and no verb can end. Says only that the wrapper gets as far as building a compose command -- `--dry-run` returns before compose is called, so it cannot speak for what compose is handed. That is the test below. |
| `just docker exec reaches compose in a checkout with no .env.generated (#1015)` | exec carried the same unconditional source as stop, so the whole build -> run -> exec -> stop flow was dead in a self-managed checkout, not just its last verb. |
| `just docker run reaches compose in a checkout with no .env.generated (#1015)` | the third wrapper with the same defect. Fixing only the verb named in the report would have left the flow it belongs to still broken. |
| `just docker stop hands compose the tooling tag its compose.yaml demands (#1015)` | the verb that ENDS the flow has to hand compose the one value its compose.yaml refuses to be read without, and it has to be the value the checkout's own resolver produces -- a second derivation would agree today and drift tomorrow. |
| `just docker exec hands compose the tooling tag its compose.yaml demands (#1015)` | exec asks the same file the same way (its running-service precheck is a `compose ps`), so fixing only stop would leave the flow broken one verb earlier. |

### test/bats/unit/base_version_monitor_spec.bats (13)

Version-compare + issue-open logic of the pull-based base version monitor:
semver ordering (numeric, not lexical), a missing leading `v`, and the `run`
path that opens exactly one labelled tracking issue per target version
(dedup on an already-open one, no issue when up to date, loud failure on an
empty API answer).

| Test | Description |
|------|-------------|
| `compare: newer minor is behind (v0.41.0 < v0.42.0)` | - |
| `compare: equal versions are not behind` | - |
| `compare: older remote is not behind` | - |
| `compare: newer patch is behind` | - |
| `compare: numeric not lexical (v0.9.7 < v0.10.0)` | - |
| `compare: newer major is behind (v0.41.0 < v1.0.0)` | - |
| `compare: tolerates a missing leading v` | - |
| `run: behind -> opens a tracking issue naming the target version` | - |
| `run: opened issue carries the base-upgrade label` | - |
| `run: up to date -> no issue created` | - |
| `run: existing open issue for the target -> skip (dedup)` | - |
| `run: a gh still listing titles cannot make the dedupe gate miss an open issue (#905)` | - |
| `run: empty latest from API -> fails without creating an issue` | - |

### test/bats/unit/bash_source_guard_lint_spec.bats (18)

| Test | Description |
|------|-------------|
| `_run_bash_source_guard: FAILS on a bare indexed read, naming file and line (#869)` | - |
| `_run_bash_source_guard: FAILS on a suffix-stripped read (${BASH_SOURCE[0]%/*}) (#869)` | - |
| `_run_bash_source_guard: FAILS on a caller-frame read (${BASH_SOURCE[1]}) (#869)` | - |
| `_run_bash_source_guard: FAILS on a subscript-less read (${BASH_SOURCE}) (#869)` | - |
| `_run_bash_source_guard: FAILS on a read in base's own tooling tree, not just dist/ (#869)` | - |
| `_run_bash_source_guard: names the default form in the failure message (#869)` | - |
| `_run_bash_source_guard: FAILS on a read AFTER an allow-end (region does not leak) (#869)` | - |
| `_run_bash_source_guard: FAILS on an unterminated allow-begin region (#869)` | - |
| `_run_bash_source_guard: FAILS on an allow-end with no matching allow-begin (#869)` | - |
| `_run_bash_source_guard: PASSES the $0-defaulted read (#869)` | - |
| `_run_bash_source_guard: PASSES the empty-defaulted sourced-vs-executed guard (#869)` | - |
| `_run_bash_source_guard: PASSES a defaulted higher frame (${BASH_SOURCE[2]:-unknown}) (#869)` | - |
| `_run_bash_source_guard: PASSES whole-array expansions, which nounset tolerates (#869)` | - |
| `_run_bash_source_guard: PASSES a comment that merely names the array (#869)` | - |
| `_run_bash_source_guard: EXEMPTS a read inside an allow-begin/allow-end region (#869)` | - |
| `_run_bash_source_guard: ignores non-.sh files and files outside the scanned trees (#869)` | - |
| `_run_bash_source_guard: FAILS when a scan root is missing (no vacuous pass) (#869)` | - |
| `_run_bash_source_guard: the REAL shipped + tooling trees pass today (#869)` | - |

### test/bats/unit/bashrc_spec.bats (15)

| Test | Description |
|------|-------------|
| `defines alias_func` | Function definition |
| `defines color_git_branch` | Function definition |
| `defines ebc alias` | Alias definition |
| `defines sbc alias` | Alias definition |
| `alias_func is called` | Function call |
| `color_git_branch is called` | Function call |
| `color_git_branch sets PS1` | PS1 setting |
| `bashrc has bashrc.d bootstrap loop sourcing ~/.bashrc.d/*.sh` | - |
| `bashrc.d bootstrap loop guards on directory existing` | - |
| `bashrc.d/ directory exists in .base/dist/config/shell/` | - |
| `host-group drop-in exists` | #589 drop-in shipped |
| `host-group drop-in defines name_host_groups and invokes it only when interactive` | #589 structure |
| `host-group drop-in uses getent + sudo groupadd` | #589 mechanism |
| `name_host_groups: a nameless gid triggers sudo groupadd hostgrp<gid>` | #589 behaviour (mocked) |
| `name_host_groups: a named gid does not trigger groupadd` | #589 idempotent skip (mocked) |

### test/bats/unit/build_sh_base_self_spec.bats (2)

build.sh in the base self-use topology (#713): base is the template SOURCE,
so its tree has no `.base/` subtree, no setup.conf, no .env.generated, and a
hand-authored compose.yaml. Covers lib resolution via the base-self path and
`--target test-tools` dispatching `docker compose build` while skipping the
setup-sync lifecycle.

| Test | Description |
|------|-------------|
| `build.sh --help resolves its libs in the base-self topology (no .base/)` | - |
| `build.sh --target test-tools (base self) dispatches compose build, skips setup.sh` | - |

### test/bats/unit/build_sh_prune_spec.bats (7)

Unit tests for `build.sh`'s #387 post-build prune-predecessor logic.
Separate spec so the docker stub can be tailored to image-inspect /
images-filter / rmi semantics without bloating the default build_sh_spec
stub (which only logs argv). Smart docker stub branches on `image inspect`
(returns `DOCKER_INSPECT_PRE_ID` on the first call, `DOCKER_INSPECT_POST_ID`
on the second — defaults to PRE_ID for the cache-hit case), `images --filter
reference=<id>` (emits the `<none>:<none>` self-entry plus
`DOCKER_IMAGES_OUTPUT` lines so the multi-tag-still-references case can be
simulated), and `rmi` (appends the id to `DOCKER_RMI_LOG` so tests assert
presence/absence).

Covers: first-build path (`docker image inspect` exits 1 → no
`_pre_build_id` → prune skipped, no rmi), cache-hit rebuild (`pre == post` →
cache-hit guard returns early), successful displaced rebuild (`pre != post`,
old id has no other tag → `docker rmi <old-id>` fires), multi-tag guard (old
id still referenced elsewhere → "skip prune: predecessor still tagged" log +
no rmi), `--no-prune` opt-out (no inspect calls + no rmi even when ids would
have moved), `--dry-run` (planned-action line `[dry-run] docker rmi
<old-id-of ... if displaced>` visible + zero real rmi), and `--help`
mentions the `--no-prune` flag.

| Test | Description |
|------|-------------|
| `build.sh first build (no prior image) skips prune` | - |
| `build.sh cache-hit rebuild (same id) skips prune` | - |
| `build.sh successful rebuild with displaced id rmi's old id` | - |
| `build.sh skips prune when old id still tagged by another reference` | - |
| `build.sh --no-prune skips prune even when id displaced` | - |
| `build.sh --dry-run prints planned prune step + does not rmi` | - |
| `build.sh --help mentions --no-prune (#387)` | - |

### test/bats/unit/build_sh_spec.bats (58)

Unit tests for `build.sh` argument handling and control flow. Uses a sandbox
tree mirroring the expected layout (build.sh + `template/` subtree with real
`_lib.sh` / `i18n.sh`, mock `setup.sh`). `docker` is PATH-shimmed so the
stub captures argv; `build.sh` is symlinked (not copied) so kcov attributes
coverage to the real source file.

Covers: `--help` (en/zh/zh-CN/ja), `--setup`/`-s`, auto-bootstrap on missing
`.env` / `setup.conf` / `compose.yaml`, drift-check path when all three are
present, bootstrap staying non-interactive (setup.sh direct, not
`setup_tui.sh`), defensive guard when setup produces no `.env`, TARGETARCH
build-arg forwarding, `--no-cache`, `--clean-tools`, positional `TARGET`,
**`-t` / `--target TARGET` alias** (#280: short + long form, last-wins
resolution against positional `[TARGET]` in both orderings, `-t`
value-required guard, usage help mention), `--lang` argument validation,
fallback `_detect_lang` branches (zh_TW/zh_CN/ja), real (non-dry-run) docker
build invocation, **version-scoped local test-tools tag** (#828: the
internal build derives `test-tools:<version>` from `.base/.version` and
forwards it as the `TEST_TOOLS_IMAGE` build-arg; fails loud on a missing
version, no bare-tag fallback), **the self-managed-repo tooling tag** (#896:
a repo with no `.base/` subtree has no pinned version to scope a local tag
by, so build.sh asks that repo's own `script/test/test.sh
--test-tools-image` rather than deriving a second tag, and forwards the
result on BOTH channels -- the `--build-arg` a consumer Dockerfile reads and
the exported environment a self-managed `compose.yaml` interpolates; repos
that do carry `.base/` keep the version-scoped derivation), **runtime
log-line i18n** (bootstrap / drift-regen / err_no_env messages translate in
all four languages via the local `_msg()` table; English remains the
default), and **`-C` / `--chdir` flag** (docker_harness#53: pre-pass
overrides FILE_PATH to redirect the wrapper to a different repo, both short
and long form, value-required and directory-existence guards, usage help
mention), and **`-v` / `--verbose` / `-vv` / `--very-verbose` flag** (#311:
exports `BUILDKIT_PROGRESS=plain` so a hung `docker build`'s RUN step output
is visible; `-vv` adds `set -x` on the wrapper itself; usage help mentions
all four spellings), and **#690 pre-build hook abort** (a failing
`script/hooks/pre/build.sh` makes the wrapper exit the hook's rc via
`_run_pre_hook build "$@" || exit $?` AND `docker compose build` never
runs).

| Test | Description |
|------|-------------|
| `build.sh --help exits 0 and shows usage` | - |
| `build.sh --setup forces setup.sh to run` | - |
| `build.sh -s short flag is equivalent to --setup` | - |
| `build.sh bootstraps setup.sh when .env is missing` | - |
| `build.sh auto-regens .env / compose.yaml when drift detected` | - |
| `build.sh skips setup.sh when .env AND setup.conf AND compose.yaml exist (drift-check path)` | - |
| `build.sh bootstraps setup.sh when setup.conf is missing (even if .env exists)` | - |
| `build.sh bootstraps setup.sh when compose.yaml is missing (fresh clone)` | - |
| `build.sh bootstrap calls setup.sh directly, not setup_tui.sh` | - |
| `build.sh fails with clear error if setup.sh produced no .env` | - |
| `build.sh --no-cache is forwarded to docker build and compose` | - |
| `build.sh --clean-tools schedules docker rmi via trap` | - |
| `build.sh accepts positional TARGET argument` | - |
| `build.sh -t TARGET (short form) selects the build target (#280)` | - |
| `build.sh --target TARGET (long form) selects the build target (#280)` | - |
| `build.sh -t + positional: last positional wins (#280)` | - |
| `build.sh positional + -t: last -t wins (#280)` | - |
| `build.sh -t with no value errors clearly (#280)` | - |
| `build.sh --help mentions -t / --target (#280)` | - |
| `build.sh passes --build-arg TARGETARCH=<value> when TARGET_ARCH set in .env` | - |
| `build.sh omits --build-arg TARGETARCH when TARGET_ARCH absent from .env` | - |
| `build.sh passes --network <value> to docker build when BUILD_NETWORK set in .env` | - |
| `build.sh omits --network when BUILD_NETWORK absent from .env` | - |
| `build.sh --lang zh-TW prints Chinese usage text` | - |
| `build.sh --lang requires a value` | - |
| `build.sh --lang zh-CN prints Simplified Chinese usage text` | - |
| `build.sh --lang ja prints Japanese usage text` | - |
| `build.sh --help documents QUIET in every locale (#895)` | - |
| `build.sh in /lint/ layout maps zh_TW.UTF-8 to zh-TW` | - |
| `build.sh in /lint/ layout maps zh_CN.UTF-8 to zh-CN` | - |
| `build.sh in /lint/ layout maps ja_JP.UTF-8 to ja` | - |
| `build.sh calls real docker build when --dry-run is not set` | - |
| `build.sh fails loud when .base/.version is missing (no bare test-tools:local fallback)` | - |
| `build.sh skips internal test-tools build when TEST_TOOLS_IMAGE is set (#317 P2)` | - |
| `build.sh takes a self-managed repo's tooling tag from that repo's own resolver (#896)` | - |
| `build.sh exports the tooling tag so a self-managed compose.yaml interpolates it (#896)` | - |
| `build.sh keeps deriving the version-scoped tag for a repo that has a .base subtree (#896)` | - |
| `build.sh --lang zh-TW prints Chinese bootstrap log` | - |
| `build.sh --lang zh-CN prints Simplified Chinese bootstrap log` | - |
| `build.sh --lang ja prints Japanese bootstrap log` | - |
| `build.sh default bootstrap log is English` | - |
| `build.sh --lang zh-TW prints Chinese drift-regen log` | - |
| `build.sh --lang zh-TW prints Chinese err_no_env on failed bootstrap` | - |
| `build.sh --lang ja prints Japanese err_no_env on failed bootstrap` | - |
| `build.sh --reset-conf --yes --dry-run prints init.sh --gen-conf --force cmd` | - |
| `build.sh --reset-conf is mentioned in usage help` | - |
| `build.sh --reset-conf with no existing setup.conf / .env skips prompt` | - |
| `build.sh --reset-conf without -y on closed stdin aborts cleanly, no set-e crash (#702, #700)` | - |
| `build.sh -C <dir> redirects FILE_PATH to <dir>` | - |
| `build.sh --chdir <dir> long form is equivalent to -C` | - |
| `build.sh -C without a value exits 2` | - |
| `build.sh -C with a non-existent directory exits 2` | - |
| `build.sh -C is mentioned in usage help` | - |
| `build.sh -v / --verbose / -vv / --very-verbose are mentioned in usage help (#311)` | - |
| `build.sh -v --dry-run is accepted and exits 0 (#311)` | - |
| `build.sh --verbose long form is accepted (#311)` | - |
| `build.sh -vv --dry-run enables bash trace (set -x output on stderr) (#311)` | - |
| `build.sh aborts on a failing pre-build hook and skips docker build (#690)` | - |

### test/bats/unit/build_sh_verify_spec.bats (17)

| Test | Description |
|------|-------------|
| `build.sh test: a fully CACHED verification stage is not reported as a pass` | The load-bearing case: every check CACHED reports that nothing ran |
| `build.sh test: an executed verification stage reports every check as executed` | A real run says so, and says nothing about caching |
| `build.sh test: a partially cached stage names which checks were CACHED` | Per-step truth: a re-run bats over cached linters names both |
| `build.sh field-test: the template's own RUNTIME_SMOKE_CMD style is a check` | The shipped `-test` idiom names none of the three known tools |
| `build.sh e2e-test: a Playwright gate's own steps are what is reported` | A live consumer stage base has never seen, reported not failed |
| `build.sh cli-test: a heredoc RUN step is reported like any other` | BuildKit shows only the header, so no rule may read the command |
| `build.sh custom-test: a verification stage with no RUN step warns, it does not fail` | base can say nothing was checked, not that the stage is worthless |
| `build.sh test: an install step in a side stage is not a check that ran` | A re-run toolchain stage may not read as a check over cached ones |
| `build.sh test: a -test stage that only INSTALLS a tool is not reported as running it` | Installing shellcheck is not shellcheck running |
| `build.sh test: a tool named only as an argument is not a step of the check` | Command position, not word presence, is what names an invocation |
| `build.sh test: build output with no BuildKit progress lines fails the build` | The mechanism failing is the one thing still worth a non-zero exit |
| `build.sh test: a step with no CACHED/DONE state fails the build` | An unresolved step proves neither branch, so neither is claimed |
| `build.sh test: pins BUILDKIT_PROGRESS=plain for a verification target` | The parsed progress mode is pinned, not inherited from the caller |
| `build.sh devel: a non-verification target gets no verification report` | Scope: a plain devel build is unchanged |
| `build.sh --target test-tools: the tooling image build is not a verification target` | The tooling image `just test` builds first runs no checks |
| `build.sh smoke: base's own smoke harness IS a verification target` | base's `just test smoke` had the identical hole |
| `build.sh --dry-run test: no build ran, so nothing is reported about one` | Nothing executed, so nothing is claimed about execution |

### test/bats/unit/build_worker_cache_scope_spec.bats (4)

Unit tests for `script/ci/build_worker/cache_scope.sh`, the buildx
cache-scope base-key resolver extracted out of build-worker.yaml's inline
`Compute cache scope` step (#802). Locks the
`${image_name}[-${cache_variant}]-${hardware}` shape (with its #272 / #378
bug history): the optional `cache_variant` segment single-call callers omit,
the per-arch hardware suffix, and the distro-in-image_name case that needs
no variant.

| Test | Description |
|------|-------------|
| `cache_scope: single-call caller (no cache_variant) -> image-hardware key` | - |
| `cache_scope: aarch64 hardware threads through unchanged` | - |
| `cache_scope: cache_variant is inserted between image and hardware (#272)` | - |
| `cache_scope: distro-in-image_name repos need no variant (per-scope already unique)` | - |

### test/bats/unit/build_worker_compute_matrix_spec.bats (8)

Unit tests for `script/ci/build_worker/compute_matrix.sh`, the platform ->
build matrix resolver extracted out of build-worker.yaml's inline
`compute-matrix` step (#802). Pushes the "a matrix condition that produces
no jobs" semantic break down the pyramid (System-level worker logic -> Unit
level, ADR-00000018): each supported platform maps to the right native
runner + HARDWARE (`linux/amd64` -> ubuntu-latest / x86_64, `linux/arm64` ->
ubuntu-24.04-arm / aarch64), whitespace + empty comma segments are
tolerated, an unsupported platform fails with a naming plain-language error,
and an empty / all-empty list fails the no-jobs guard instead of fanning out
to zero build jobs.

| Test | Description |
|------|-------------|
| `compute_matrix: linux/amd64 -> single include entry on ubuntu-latest / x86_64` | - |
| `compute_matrix: linux/arm64 -> single include entry on ubuntu-24.04-arm / aarch64` | - |
| `compute_matrix: both platforms -> two ordered include entries` | - |
| `compute_matrix: tolerates whitespace around comma-separated platforms` | - |
| `compute_matrix: skips empty segments (trailing comma) without emitting an empty entry` | - |
| `compute_matrix: unsupported platform fails with a naming, plain-language error` | - |
| `compute_matrix: empty platform list fails (no matrix -> no jobs guard)` | - |
| `compute_matrix: all-empty segments fail (whitespace-only -> no jobs guard)` | - |

### test/bats/unit/build_worker_runtime_stages_spec.bats (16)

`script/ci/build_worker/runtime_stages.sh`, the resolver that decides
whether build-worker.yaml runs its `runtime-test` / `runtime` targets
(#925). Whether those stages exist is a fact only the Dockerfile holds; it
used to be stated a second time as the caller's `build_runtime` input, with
nothing checking the two agreed -- the shipped Dockerfile ships its runtime
blocks commented out while the input defaulted to true, so every repo
created from the template asked buildx for a target that did not exist. Both
shapes of the shipped file are covered here: runtime blocks commented out
(the default new-repo shape, previously untested) and uncommented.

| Test | Description |
|------|-------------|
| `runtime_stages: a Dockerfile with no runtime stages resolves to false` | The four-stage default shape skips the runtime build steps |
| `runtime_stages: a Dockerfile declaring runtime + runtime-test resolves to true` | A declared pair enables the runtime build with no second edit |
| `runtime_stages: commented-out runtime stages do not count as declared` | A `#`-prefixed `FROM ... AS runtime` is documentation, not a stage |
| `runtime_stages: a lowercase 'from ... as' line declares nothing, here as everywhere (#1013)` | The one shape where this resolver used to disagree with every other FROM-line reader in the tree. Losing it would let the resolver grow a second case-insensitive regex again and hand CI a runtime image that compose has no service for. |
| `runtime_stages: the cross-build --platform FROM form declares the pair (#1013)` | The shape the arm64 matrix invites, and the one shape the sibling extra-stages loop got wrong. The old regex here read it correctly, so this case is what stops the delegation to the shared matcher regressing the half that already worked. |
| `runtime_stages: a Dockerfile with no trailing newline declares the pair (#1013)` | The reader's `while read` loop drops a final unterminated line, and a Dockerfile that ends without a newline is ordinary. Here that turns a COMPLETE runtime pair into a half-declared one and fails the build naming a stage the file plainly declares -- a failure whose message points at the author's Dockerfile rather than at the reader that lost the line. |
| `runtime_stages: a stray bare token before AS declares nothing (#1013)` | The over-reading direction, which widening a pattern is how you acquire. `FROM <image> <junk> AS <stage>` is not a directive docker accepts, so seeing a stage there makes the worker ask buildx for a target no Dockerfile can produce -- an invented pair, not a missed one. |
| `runtime_stages: the shipped dist Dockerfile (runtime blocks commented out) resolves to false` | The real default artifact, the shape that shipped red |
| `runtime_stages: the shipped dist Dockerfile with its runtime blocks uncommented resolves to true` | Uncommenting is sufficient to get a runtime build |
| `runtime_stages: build_runtime=false opts out even when both stages exist` | The surviving flag is an opt-out and is honoured |
| `runtime_stages: build_runtime=true with no runtime stage resolves to false, not a buildx failure` | The Dockerfile wins the disagreement that used to fail the build |
| `runtime_stages: an unparseable build_runtime value fails loudly` | Anything other than true / false is a config error, not a default |
| `runtime_stages: runtime without runtime-test fails naming both stages and the Dockerfile` | Half a pair silently loses the install-check, so it fails here |
| `runtime_stages: runtime-test without runtime fails naming both stages and the Dockerfile` | The mirror case, which cannot build at all |
| `runtime_stages: a missing Dockerfile fails naming the path it looked for` | A wrong `context_path` / `dockerfile_path` is reported by path |
| `runtime_stages: an empty DOCKERFILE path fails loudly` | No path means no source of truth to read |

### test/bats/unit/build_worker_stage_names_spec.bats (6)

Two worker steps need that answer: the extra_stages loop (is there a
<stage>-test companion to build?) and runtime_stages.sh (are runtime and
runtime-test declared?). Each used to carry a regex of its own, and each
carried a comment claiming it was the same regex the compose emitter's stage
parser uses. Neither was. The loop matched ONE token between FROM and AS, so
the cross-build `FROM --platform=... AS x-test` form declared nothing to it
and a stage's smoke test was silently not built; the resolver's was looser
than the emitter's in the other direction.

This script ends that by CALLING the shared matcher
(dist/script/docker/lib/stage.sh's _dockerfile_stage_from_line) rather than
restating it, so there is one grammar with one owner. The agreement is
asserted where it belongs -- stage_spec.bats runs every call site, this one
included, over one corpus of FROM lines and demands a single verdict. What
is left here is this script's OWN contract: which stages it emits, in what
order, and what it does when it cannot read the file.

The roster is deliberately UNFILTERED, unlike _parse_dockerfile_stages'
projection: the worker asks about runtime / runtime-test / devel-test by
name, which is exactly the set the compose emitter drops.

| Test | Description |
|------|-------------|
| `stage_names: lists every declared stage in file order` | The roster the worker's two steps read, in the order the file declares it -- the base case everything else here is a deviation from. |
| `stage_names: keeps the stages the compose parser filters out` | runtime-test / devel-test are the very names the worker asks about, and they are the ones the compose emitter's projection drops. Inheriting that filter would answer "no runtime-test stage" about a Dockerfile that declares one. |
| `stage_names: a Dockerfile declaring no stages is an empty roster, not an error` | Draws the line between the two empty answers this reader can give. "No extra stages" is legitimate and the caller decides what it means; only an unreadable file is a failure. Collapsing the two is what the refusal cases below defend. |
| `stage_names: the last line declares a stage even with no trailing newline (#1013)` | The blind spot a `while read` loop has and the grep this reader replaced did not: a Dockerfile that ends without a newline silently loses its last stage. That is the #1013 symptom from the other end -- no smoke test built for a last-line `<stage>-test`, and a complete runtime pair read as half-declared -- so it must be pinned at the reader itself. |
| `stage_names: a missing Dockerfile fails naming the path it looked for` | An unreadable Dockerfile is not "no stages", it is "we do not know". Answering an empty roster there is how a worker skips a build and calls it a pass, and the path has to be in the message or the operator cannot tell which file it failed to find. |
| `stage_names: an empty DOCKERFILE path fails loudly` | The unset-input case, which a workflow reaches by forgetting one `env:` line. It has to fail at the reader naming the variable, because the alternative -- an empty roster from an empty path -- is a build the worker quietly declines to run. |

### test/bats/unit/build_worker_yaml_spec.bats (69)

Structural assertions for `.github/workflows/build-worker.yaml` (#195 + #243
+ #272 + #273 + #378 b1). Reusable workflows are not exec'd by these tests;
instead grep patterns lock the YAML invariants — `context_path` /
`dockerfile_path` inputs declared with the right defaults, all 4
`docker/build-push-action` steps (devel-test / devel / runtime-test /
runtime after #243) forwarding those inputs, no leftover `context: .` /
`file: ./Dockerfile` literals, the GHA-cache plumbing (#272: `cache_variant`
input, `Compute cache scope` step; #378 b1: per-target scope suffix so a
late-stage COPY change in one target no longer cascades into siblings'
manifests; #801: `cache_backend` input selecting the gha default or a GHCR
registry backend via a per-step ternary, a guarded `docker/login-action`
step), and the #273 doc-only PR fast-pass (`path-filter` job; Phase 2
classifier is pure shell via `git diff --name-only base...head` + `case`
glob, no `dorny/paths-filter` dependency; 6-path allowlist; compute-matrix +
build gated on `code_changed`; docker-build aggregator short-circuits on
doc-only PRs).

Grouped by concern:

- `inputs.context_path` declared with `default: "."`

- `inputs.dockerfile_path` declared with `default: ""`

- 4 build steps reference `inputs.context_path` (#243 added runtime-test)

- 4 build steps reference `inputs.dockerfile_path` with `format()` fallback

- No leftover `context: .` literals

- No leftover `file: ./Dockerfile` literals

- Default values together preserve repo-root-Dockerfile callers

- User build-args use long form matching Dockerfile.example sys stage (#198:
USER_NAME / USER_GROUP / USER_UID / USER_GID across 4 build steps + no
short-form regression)

- `build_contexts` input forwards to docker/build-push-action
`build-contexts:` (#207: input declared with empty default, 4 build steps
forward, default preserves zero-diff)

- #243 stage rename + runtime-test smoke: `target: devel-test` (renamed from
`test`), no leftover `target: test`, `target: runtime-test` exists,
runtime-test gated on the resolved runtime answer (>=2 occurrences shared
with runtime gate)

- #272 + #378 b1 GHA buildx cache: `cache_variant` input declared with empty
default, `Compute cache scope` step emits `id: cache` + base key (no
`-cache` suffix; per-target suffix appended at use site), 4 build steps use
per-target `<base>-<target>-cache` gha scopes in the default ternary branch,
no legacy shared-scope leftover (negative regression), 4 build steps
preserve `mode=max` on both branches, default preserves zero-diff for
single-call callers

- #801 registry cache backend: `cache_backend` input declared `type: string`
default `"gha"` (default preserves the gha backend for existing callers),
all 4 build steps emit a
`type=registry,ref=ghcr.io/<repo>/buildcache:<scope>` ref in the registry
branch, cache-from/cache-to select the backend on `inputs.cache_backend` (8
lines), the `extra_stages` buildx loop honors `cache_backend` too
(shell-side selection, no hardwired gha ref), GHCR `docker/login-action`
step gated on `cache_backend == 'registry'`

- #273 doc-only PR fast-pass (Phase 1 + Phase 2 shell rewrite):
`path-filter` job declared, classifier is pure shell (`git diff --name-only
base...head` + `case` glob; no `dorny/paths-filter` dependency), reads
EVENT_NAME / BASE_SHA / HEAD_SHA from env: keys so the case body stays
portable, non-PR event short-circuits before git diff (BASE_SHA / HEAD_SHA
empty on push / tag / workflow_dispatch), 6-path allowlist (`**/*.md`,
`doc/**`, `LICENSE`, `.gitignore`, `.github/CODEOWNERS`,
`.github/dependabot.yml`) in a single `case` arm, `compute-matrix` + `build`
jobs gated on `code_changed == 'true'` (2 occurrences), `docker-build`
aggregator handles `code_changed == 'false'` short-circuit + `needs:
[path-filter, build]`, non-PR triggers always set `code_changed=true`

- #470 opt-in `free_disk_space` for large BASE_IMAGE repos: input declared
`type: boolean` default `false`, step gated on `inputs.free_disk_space`,
uses `jlumbroso/free-disk-space@...`, positioned before `Set up Docker
Buildx` so the overlayfs snapshot dir has room

- #925 runtime gate read from the Dockerfile: a `Resolve runtime stages`
step delegates to `runtime_stages.sh`, exports `build_runtime` to
`GITHUB_OUTPUT`, both runtime build steps gate on
`steps.runtime.outputs.build_runtime`, and no build step gates on
`inputs.build_runtime` directly

- #802 push worker logic down: `compute-matrix` delegates to
`compute_matrix.sh` (no inline platform fan-out) and version-matches it via
`job_workflow_sha` into `.worker-base`, `Compute cache scope` delegates to
`cache_scope.sh` (feeds IMAGE_NAME / CACHE_VARIANT / HARDWARE, no inline
derivation), build job checks out base worker source into `.worker-base`

- #957 per-job least privilege, over a job list DERIVED from the workflow
(never a roster in the spec -- the five-name loop this replaced stayed green
when a sixth job asking `contents: write` was appended): every job declares
its own `permissions:` block (a bare job inherits the CALLER's grant), no
job names `packages: write` (a called job that asks for a scope its caller
did not grant fails the run instead of intersecting down), no job's entry
set is anything but `contents: read` (comments stripped so a rationale
quoting a grant cannot stand in for one; a job with no block surfaces as
`<no entries>` and fails the same way), and the `build` job's rationale
never cites the preflight probe as proof of a caller's package grant (the
preflight is capped at `contents: read` itself). Each of the four asserts
its own population first -- a floor on the derived job count, cross-checked
against a second reading of the file -- so an extractor that stopped
matching fails instead of reporting a clean scan

| Test | Description |
|------|-------------|
| `build-worker.yaml: declares context_path input with default '.'` | - |
| `build-worker.yaml: declares dockerfile_path input with empty default` | - |
| `build-worker.yaml: 4 build steps all reference inputs.context_path (#243 added runtime-test)` | - |
| `build-worker.yaml: 4 build steps all forward inputs.dockerfile_path with format() fallback` | - |
| `build-worker.yaml: no leftover hardcoded 'context: .' lines` | - |
| `build-worker.yaml: no hardcoded Dockerfile path bypassing the input` | - |
| `build-worker.yaml: defaults preserve repo-root-Dockerfile behavior` | - |
| `build-worker.yaml: 4 build steps pass USER_NAME=ci (long form, matching Dockerfile.example sys stage)` | - |
| `build-worker.yaml: 4 build steps pass USER_GROUP=ci (long form)` | - |
| `build-worker.yaml: 4 build steps pass USER_UID=1000 (long form)` | - |
| `build-worker.yaml: 4 build steps pass USER_GID=1000 (long form)` | - |
| `build-worker.yaml: no short-form USER=/GROUP=/UID=/GID= build-args (regression #198)` | - |
| `build-worker.yaml: declares build_contexts input with empty default` | - |
| `build-worker.yaml: 4 build steps forward inputs.build_contexts to docker/build-push-action build-contexts:` | - |
| `build-worker.yaml: devel-test build step uses target: devel-test (renamed from target: test)` | - |
| `build-worker.yaml: no leftover target: test (the renamed stage)` | - |
| `build-worker.yaml: runtime-test build step exists and uses target: runtime-test` | - |
| `build-worker.yaml: runtime-test build step is gated on the resolved runtime answer` | - |
| `build-worker.yaml: resolves the runtime gate from the caller's Dockerfile (#925)` | - |
| `build-worker.yaml: the resolver step exports build_runtime to GITHUB_OUTPUT (#925)` | - |
| `build-worker.yaml: runtime + runtime-test build steps gate on the resolved value, not the raw input (#925)` | - |
| `build-worker.yaml: no build step gates on inputs.build_runtime directly (#925)` | - |
| `build-worker.yaml: build_contexts default preserves zero-diff for existing callers (#207)` | - |
| `build-worker.yaml: declares cache_variant input with empty default (#272)` | - |
| `build-worker.yaml: Compute cache scope step emits id: cache with base key in GITHUB_OUTPUT (#272 + #378 + #802)` | - |
| `build-worker.yaml: 4 build steps use per-target gha cache scopes in the default branch (#378 b1, #801 ternary)` | - |
| `build-worker.yaml: 4 build steps emit a type=registry GHCR buildcache ref when cache_backend is registry (#801)` | - |
| `build-worker.yaml: extra_stages loop honors cache_backend for both backends (#801)` | - |
| `build-worker.yaml: an extra stage's -test companion is found on a --platform FROM line (#1013)` | The reported #1013 miss, asserted on what the step BUILDS rather than on what its text says: the detector allowed one token between FROM and AS, so the cross-build form the arm64 matrix invites declared nothing and the stage's smoke test was silently not built. |
| `build-worker.yaml: an extra stage with no -test companion builds only itself (#1013)` | The cost of widening a detector, pinned in the opposite direction: inventing a `-test` target the Dockerfile does not declare fails the build outright, which is a worse outcome than the miss it was fixing. |
| `build-worker.yaml: the extra-stages roster comes from the shared resolver (#1013)` | The structural half, and the one that stops #1013 recurring: two readers of one fact with a comment asserting they agree is what produced the miss. This fails if the file grows a `FROM ... AS` pattern of its own again, which a behavioural case on a correct pattern cannot see. |
| `build-worker.yaml: an extra stage's name is matched literally, not as a regex (#1013)` | Docker allows `.` in a target name, so a membership test that reads the caller's stage name as a regex finds a DIFFERENT stage: `foo.bar` matches `fooxbar-test` and the step asks buildx for a target nothing declares, failing the build over a companion that was never there. |
| `build-worker.yaml: the extra-stages step does not pipe its roster into an early-closing reader (#1013)` | The early-close-reader lint cannot reach here -- it scans *.sh under dist/ and script/, and a workflow `run:` block is not a shell file -- so this is the only thing standing between the step and a `grep -q` whose SIGPIPE 141 becomes the pipeline's status under `pipefail`, turning a stage that WAS found into one that reads as absent. |
| `build-worker.yaml: cache lines select the backend on inputs.cache_backend (#801)` | - |
| `build-worker.yaml: 4 distinct cache scopes exist, no shared scope leftover (#378 b1)` | - |
| `build-worker.yaml: 4 build steps all set mode=max on cache-to for both backends (#272 preserved, #801)` | - |
| `build-worker.yaml: declares cache_backend input with default gha (#801)` | - |
| `build-worker.yaml: cache_backend default preserves the gha backend for existing callers (#801)` | - |
| `build-worker.yaml: GHCR login step is gated on cache_backend == registry (#801)` | - |
| `build-worker.yaml: cache_variant default preserves zero-diff for single-call callers (#272)` | - |
| `build-worker.yaml: declares path-filter job (#273)` | - |
| `build-worker.yaml: path-filter classifier is pure shell (#273 Phase 2: no dorny/paths-filter)` | - |
| `build-worker.yaml: classifier reads EVENT_NAME / BASE_SHA / HEAD_SHA from env (#273 Phase 2)` | - |
| `build-worker.yaml: non-pull_request event short-circuits to code_changed=true before git diff (#273 Phase 2)` | - |
| `build-worker.yaml: a git diff that FAILS fails the classifier, it does not read as doc-only (#1013)` | The load-bearing case of the three. A failed diff used to deliver zero lines through a process substitution the loop's status hides, so the step said doc-only and the REQUIRED docker-build check went green having built nothing. It asserts the step's OWN status, not merely non-zero, so a harness that could not lift a script cannot stand in for the step failing. |
| `build-worker.yaml: a diff of only allowlisted paths classifies doc-only (#1013)` | The guard against buying safety by classifying everything as code. Without this the failed-diff case is satisfied by a step that never says doc-only at all, and every doc PR pays for a full image build. |
| `build-worker.yaml: a diff carrying one non-allowlisted path classifies as code (#1013)` | The mixed diff, which is the shape most PRs have. One code path among documentation must carry the whole change into a build; an allowlist evaluated per file rather than per change-set would skip it. |
| `build-worker.yaml: doc-only allowlist case-glob covers all 6 documented paths (#273)` | - |
| `build-worker.yaml: compute-matrix and build are gated on code_changed (#273)` | - |
| `build-worker.yaml: docker-build aggregator short-circuits to success on doc-only (#273)` | - |
| `build-worker.yaml: non-pull_request event resolves code_changed=true (#273)` | - |
| `build-worker.yaml: declares free_disk_space input as boolean default false (#470)` | - |
| `build-worker.yaml: Free disk space step gated on inputs.free_disk_space (#470)` | - |
| `build-worker.yaml: Free disk space step uses jlumbroso/free-disk-space (#470)` | - |
| `build-worker.yaml: Free disk space step runs before Set up Docker Buildx (#470)` | - |
| `build-worker.yaml: compute-matrix delegates to the extracted compute_matrix.sh (#802)` | - |
| `build-worker.yaml: compute-matrix version-matches the script via job_workflow_sha (#802)` | - |
| `build-worker.yaml: Compute cache scope delegates to the extracted cache_scope.sh (#802)` | - |
| `build-worker.yaml: build job checks out base worker source at job_workflow_sha into .worker-base (#802)` | - |
| `build-worker.yaml: the workspace path it writes is keyed to the run (#900)` | - |
| `build-worker.yaml: the build job reclaims its own leftovers on if: always() (#900)` | - |
| `build-worker.yaml: downstream cleanup is ownership-scoped too (#900)` | - |
| `build-worker.yaml: the build job carries the same-repo guard AND-ed with its code_changed gate (#766)` | - |
| `build-worker.yaml: the guard tests the FORK, not the PR (#766)` | - |
| `build-worker.yaml: every job declares its own permissions block (#957)` | - |
| `build-worker.yaml: no job requests packages: write (#957)` | - |
| `build-worker.yaml: the build job asks for contents: read alone (#957)` | - |
| `build-worker.yaml: no job in the worker grants more than contents: read (#957)` | - |
| `build-worker.yaml: the build job never cites the preflight as proof of a package grant (#957)` | - |

### test/bats/unit/catalog_description_lint_spec.bats (11)

The rule is base#922's and the first implementation was base#976's, which
scanned the RENDERED catalogue. That made the rule opt-outable by table
shape: a section answering with a summary took its tests out of a required
field with every gate green, 1499 of 3700 on the tree this replaced it on.
The population here is `^@test` over the spec trees, so there is no shape to
hide behind, and these cases exist to keep it that way.

The cases split into two kinds, and the split is the design. Everything
spec-markers.sh REPORTS -- an orphan, a detached block, an unreadable
`@test` line, a marker that says nothing -- fails at any count, because each
is an edit somebody made. Only the ABSENCE of a marker is under the
transition ceiling, because that is the debt the migration inherited.

Detection runs against a controlled temp REPO_ROOT so the spec is
independent of the live tree; a final case drives the REAL tree.

| Test | Description |
|------|-------------|
| `_run_catalog_description: a fully described tree is clean and prints the counts` | The clean line is the load-bearing part of this design, not the verdict. Slack is the cost the ceiling accepts, and a cost nobody can see is one nobody closes -- so the counts print on every run and this case pins that they do. |
| `_run_catalog_description: an undescribed test under the ceiling counts but does not fail` | The transition, stated out loud. Moving the rule from the row to the test enlarged the debt by definition, so an undescribed test under the ceiling is REPORTED in the counts and does not fail. Anyone reading this case sees the weakening rather than discovering it from a green run. |
| `_run_catalog_description: breaching the ceiling FAILS and names the undescribed tests` | The other half of the ceiling, and the one that makes it a guard at all. It fails, and it names every offender by `<spec>:<line>: <name>` -- uncapped, because a truncated list is one somebody's test can fall off the end of. |
| `_run_catalog_description: a '# why:' block with no @test beneath it FAILS` | The orphan is what a rename leaves behind, and it is the check that keeps the guard non-vacuous in the other direction: without it a description that will never render reads as a described test. It is NOT under the ceiling -- somebody wrote it. |
| `_run_catalog_description: a detached block FAILS` | A bare `#` inside a block detaches the description from its test while leaving prose that still looks like one in the file. Nothing renders, and nothing else would report it. |
| `_run_catalog_description: a marker that says nothing FAILS at any count` | The non-answer floor. A cell that clears a red build without saying anything is the cheapest way out of one, so `-`, `TBD` and `...` are refused as the missing sentence wearing less ink -- and refused at any count, because writing one is an edit, not inherited debt. |
| `_run_catalog_description: a short but real description passes the floor` | An honest six-character description says something the test name does not, and this driver's own header argues that a guard whose false positives are the good rows is worse than no guard. The floor is "has a word in it", and this pins that the line is drawn there and not at a length. |
| `_run_catalog_description: an unreadable '@test' line FAILS` | A `@test` line the canonical form cannot read is counted by the heading count and skipped by the reader, which would put the two out of step with every gate green. Failing closed here is what makes the refusal in spec-markers.sh reach a person. |
| `_run_catalog_description: a spec-free scan root dies rather than passing vacuously` | A scan that finds nothing must DIE, not report clean. This is the failure mode the whole repo keeps paying for: a relocated tree, a lint that quietly covers zero files, and a green line that reads as a verdict over the suite. |
| `_run_catalog_description: a nonexistent scan root dies, naming it` | The same non-vacuity in its other spelling -- a root that is not there at all. Reporting "0 undescribed" for a path that does not exist is the same false green with a different cause. |
| `_run_catalog_description: the real tree passes, at or under the declared ceiling` | The one case that is about THIS tree rather than about a fixture: the ceiling in the driver has to match what the specs actually carry, or the number is a claim nobody checked. It also proves the lint passes on the tree it ships in, which no fixture can. |

### test/bats/unit/cd_guard_spec.bats (7)

Behaviour of the shipped CD pre-deploy gate `dist/deploy/cd-guard.sh`
(ADR-00000023): refuse to deploy unless the tree is clean **and** HEAD sits
on a tag, so an automated field bundle is always traceable to a released
version. Four `mktemp` git fixtures drive the real script and assert exit
status **and** the specific refusal message — a status-only check passes
with the conditions inverted (dirty reported as untagged and vice versa).
Pure git + filesystem, no docker.

| Test | Description |
|------|-------------|
| `cd-guard: ships executable, so the documented ./.base/... invocation works` | - |
| `cd-guard: refuses outside a git repository (exit 1 + 'not inside a git repository')` | - |
| `cd-guard: refuses a dirty tree even when HEAD is on a tag (exit 1 + 'working tree is dirty')` | - |
| `cd-guard: refuses an untagged HEAD on a clean tree (exit 1 + 'HEAD is not on a tag')` | - |
| `cd-guard: a tag that does not point at HEAD is still an untagged HEAD` | - |
| `cd-guard: accepts a clean tree on a tag (exit 0 + names the tag)` | - |
| `cd-guard: the accept path reports the tag on stdout, refusals on stderr` | - |

### test/bats/unit/changelog_entry_lint_spec.bats (54)

| Test | Description |
|------|-------------|
| `_run_changelog_entry: FAILS on an [Unreleased] entry over the cap (#917)` | - |
| `_run_changelog_entry: names the entry's line, its measured length and the cap (#917)` | - |
| `_run_changelog_entry: reports EVERY over-long entry, not just the first (#917)` | - |
| `_run_changelog_entry: the SAME text rewrapped across continuation lines still FAILS (#917)` | - |
| `_run_changelog_entry: the SAME text re-shaped into sub-bullets still FAILS (#917)` | - |
| `_run_changelog_entry: the measure is unchanged by re-indenting a passing entry (#917)` | - |
| `_run_changelog_entry: PASSES an entry of exactly the cap (#917)` | - |
| `_run_changelog_entry: FAILS an entry one character over the cap (#917)` | - |
| `_run_changelog_entry: PASSES a structured entry -- short lead plus a sub-list (#917)` | - |
| `_run_changelog_entry: an over-long entry in a RELEASED section is never checked (#917)` | - |
| `_run_changelog_entry: stops at the next '## [' heading, not at the end of file (#917)` | - |
| `_run_changelog_entry: an empty [Unreleased] passes and SAYS it checked nothing (#917)` | - |
| `_run_changelog_entry: an allow region suppresses the entry inside it (#917)` | - |
| `_run_changelog_entry: FAILS on an over-long entry AFTER an allow-end (the region does not leak) (#917)` | - |
| `_run_changelog_entry: FAILS on an unterminated allow-begin (#917)` | - |
| `_run_changelog_entry: FAILS on an allow-end with no open allow-begin (#917)` | - |
| `_run_changelog_entry: an entry that QUOTES the allow markers is prose, not a region (#917)` | - |
| `_run_changelog_entry: a quoted allow marker does not silence the entries after it (#917)` | - |
| `_run_changelog_entry: an unterminated allow-begin is reported AND what follows is still measured (#917)` | - |
| `_run_changelog_entry: FAILS on one comment carrying BOTH allow markers (#917)` | - |
| `_run_changelog_entry: the clean line reports how many entries an allow region suppressed (#917)` | - |
| `_run_changelog_entry: a section whose only entry is allowed says so, not 'nothing to check' (#917)` | - |
| `_run_changelog_entry: a heading shown inside a fenced example does not relocate the section (#917)` | - |
| `_run_changelog_entry: a released heading inside a fenced example does not truncate the section (#917)` | - |
| `_run_changelog_entry: a '- ' line inside a fenced example counts toward its entry, not as a new one (#917)` | - |
| `_run_changelog_entry: FAILS on a bullet marker the parser does not recognise (#917)` | - |
| `_run_changelog_entry: FAILS on unrecognised content that FOLLOWS a valid entry (#917)` | - |
| `_run_changelog_entry: FAILS on a single word orphaned above the rest of its paragraph (#927)` | - |
| `_run_changelog_entry: names the orphan's real line number in the file (#927)` | - |
| `_run_changelog_entry: a one-word FINAL line of an entry is not an orphan (#927)` | - |
| `_run_changelog_entry: a one-word line above a BLANK line is not an orphan (#927)` | - |
| `_run_changelog_entry: an unbreakable token alone on its line is not an orphan (#927)` | - |
| `_run_changelog_entry: an orphan is one that could have joined the line below (#927)` | - |
| `_run_changelog_entry: a table separator row is not an orphaned word (#927)` | - |
| `_run_changelog_entry: a single-word line inside a fenced block is not an orphan (#927)` | - |
| `_run_changelog_entry: an orphan inside an allow region is suppressed like any other defect (#927)` | - |
| `_run_changelog_entry: an orphan in a RELEASED section is never checked (#927)` | - |
| `_run_changelog_entry: reports EVERY orphan in the section, not just the first (#927)` | - |
| `_changelog_entry_measure: counts characters, not bytes, whatever the locale (#917)` | - |
| `_run_changelog_entry: a non-ASCII entry under the cap PASSES under a C locale too (#917)` | - |
| `_run_changelog_entry: DIES when the CHANGELOG is missing rather than passing vacuously (#917)` | - |
| `_run_changelog_entry: DIES when the [Unreleased] heading is missing rather than passing vacuously (#917)` | - |
| `_run_changelog_entry: FAILS on two entries with an identical lead bullet (#959)` | - |
| `_run_changelog_entry: names BOTH lines of a duplicate, and both are findable (#959)` | - |
| `_run_changelog_entry: the same entry RE-WRAPPED is still a duplicate (#959)` | - |
| `_run_changelog_entry: two DIFFERENT entries are not a duplicate (#959)` | - |
| `_run_changelog_entry: a duplicate planted in a RELEASED section is NOT a finding (#959)` | - |
| `_run_changelog_entry: a bullet and a heading shown inside a fenced example are not structure (#959)` | - |
| `_run_changelog_entry: an allow region suppresses a deliberate second copy (#959)` | - |
| `_run_changelog_entry: FAILS when a category opens twice, naming both lines (#959)` | - |
| `_run_changelog_entry: the SAME category in a different release block is fine (#959)` | - |
| `_run_changelog_entry: the clean line says how many category headings it compared (#959)` | - |
| `_run_changelog_entry: the real repo tree's [Unreleased] section is clean (#917)` | - |
| `TEST.md's changelog-entry row names all three rules this lint enforces (#956)` | - |

### test/bats/unit/check_test_md_drift_spec.bats (14)

The read-only validating twin of `sync-doc-counts.sh`. It runs THAT
generator against a throwaway copy and diffs, so "byte-identical to what is
committed" is the whole gate and the validator cannot drift from the
generator. Covers the in-sync / drifted verdicts -- including a deleted `#
why:` block, which is the edit the catalogue is now the only place to notice
-- and the unusable-scan-root guards that keep the gate from passing
vacuously (relative root, missing root, no `doc/test/`, no specs).

The in-sync fixtures are BUILT BY THE GENERATOR rather than typed out.
Hand-writing what a generator emits is the habit this change exists to end,
and a fixture that only happens to match today would make every case here
fail on the next formatting change for a reason none of them is about.

| Test | Description |
|------|-------------|
| `_check_test_md_drift: exits 0 on an in-sync tree (#782)` | - |
| `_check_test_md_drift: exits non-zero and names the drifted doc on a stale count (#782)` | - |
| `_check_test_md_drift: FAILS when a '# why:' block is deleted from a spec` | THE case this change adds to the gate. A description now lives in one place, so deleting it has to be visible somewhere -- and the catalogue is that somewhere: the row falls back to `-` while the committed one still carries prose, and the drift diff fires. Without this, the one edit that silently empties the catalogue would be the one edit nothing checks. |
| `_check_test_md_drift: FAILS when the committed ceiling is not what the tree measures` | The ceiling became a generated figure (base#1024), and a gate that compared only doc/test would report a tree in sync while the number in the driver was one the specs no longer justify -- which is the slack nobody closes, back again as a green run. |
| `_check_test_md_drift: a regenerated ceiling verifies in sync` | The other side of the same gate. A tree the generator has just written must verify, or `just test sync-docs` would leave a red gate behind and the message telling people to run it would be a lie. |
| `_check_test_md_drift: compares every file the generator claims, not one it names (#1024)` | The gate's file set has to be the GENERATOR's answer and not a constant this file keeps beside it. The merge resolver was changed for exactly that reason -- a resolver carrying its own copy of "what is generated" refuses the one file whose conflicts it is best placed to settle -- and the gate names its single outside output twice instead. A further generated output is then covered on a merge and silently uncovered here, with pass as the default. The case swaps in a generator with a second output and asks the gate to notice it has gone stale. |
| `_check_test_md_drift: tolerates an empty acceptance level dir (count 0) (#782)` | - |
| `_check_test_md_drift: a RELATIVE root gives the same verdict as the absolute one (#848)` | - |
| `_check_test_md_drift: a RELATIVE root still detects real drift (#848)` | - |
| `_check_test_md_drift: FAILS on a nonexistent scan root, naming it (#848)` | - |
| `_check_test_md_drift: FAILS on a scan root with no doc/test (no vacuous pass) (#848)` | - |
| `_check_test_md_drift: FAILS on a spec-free scan root (no vacuous pass) (#848)` | - |
| `_check_test_md_drift: counts a shipped smoke spec as spec files (#848)` | - |
| `_check_test_md_drift: FAILS when a row is deleted from the generated region (#859)` | The rot this closes: the heading count was regenerated -- so the gate said in sync -- while the per-test table next to it stayed short, 36 rows against 43 tests. The region is generated wholesale now, so a hand-edited row IS drift, and the gate names it. |

### test/bats/unit/ci_preflight_spec.bats (18)

Unit tests for `script/ci/preflight.sh`, the caller-contract validator the
reusable build / release workers run before any real work. Drives the
pure-shell engine over synthetic requirement manifests: a present required
input passes; an empty required input, or an ungranted / unset permission
probe, fails non-zero with a plain-language message naming the gap and the
`main.yaml` fix; every unmet requirement is reported in one pass (not
fail-on-first); `--list` self-describes the manifest; comment / blank
manifest lines are ignored. Malformed-manifest guards keep the never-silent
thesis honest: an unknown requirement kind (a typo'd `kind` column) fails
loudly naming the offending kind, and a missing / empty / all-comment
(zero-requirement) manifest is a config error (exit 2) rather than a silent
green. Conditional requirements (#801): an optional 6th manifest field
`<condvar>=<value>` gates a requirement on another env var (e.g. `packages:
write` only when `cache_backend: registry`) -- a guard that does not match
is declared-but-skipped (never a failure), a matching guard enforces the
requirement without leaking the guard into the hint, and `--list` annotates
it as `(when <condvar>=<value>)`. A malformed guard field lacking `=` fails
loud as a config error (exit 2), never failing open.

| Test | Description |
|------|-------------|
| `preflight: passes when a required input is present` | - |
| `preflight: fails when a required input is empty, naming the input` | - |
| `preflight: passes when a permission probe reports granted` | - |
| `preflight: fails when a permission probe reports missing` | - |
| `preflight: an unset permission probe env fails (never silently green)` | - |
| `preflight: reports every unmet requirement in one pass` | - |
| `preflight --list: prints the requirement list and exits 0 (self-describing)` | - |
| `preflight: comment and blank lines in the manifest are ignored` | - |
| `preflight: missing manifest file is a usage error (exit 2)` | - |
| `preflight: an unknown manifest kind fails loudly, naming the offending kind (never silently green)` | - |
| `preflight: an unknown manifest kind is a config error (exit 2)` | - |
| `preflight: an empty manifest is a usage error (exit 2), never silently green` | - |
| `preflight: an all-comment manifest is a usage error (exit 2)` | - |
| `preflight: a conditional requirement is skipped when its guard env does not match (#801)` | - |
| `preflight: a conditional requirement is enforced when its guard env matches (#801)` | - |
| `preflight: a matched conditional requirement passes when it is satisfied (#801)` | - |
| `preflight --list: annotates a conditional requirement with its guard (#801)` | - |
| `preflight: a malformed conditional guard (no '=') fails loudly as a config error (exit 2), never silently skipped (#801)` | - |

### test/bats/unit/ci_reclaim_spec.bats (15)

Ownership-scoped CI-host garbage collection (`script/ci/reclaim.sh`, #900).
`runs-on: ubuntu-latest` gives every job a fresh single-tenant VM, so no run
on the current CI can exhibit either failure the collector exists to prevent
-- one run deleting a concurrent run's artifacts, and a killed runner
leaving artifacts nobody collects. A fake docker daemon (a PATH shim over a
state file) is what puts two runs' artifacts on ONE host so the boundary
between them can be asserted at all.

| Test | Description |
|------|-------------|
| `reclaim.sh --help exits 0 and shows usage` | - |
| `reclaim.sh with no scope refuses (a scopeless sweep is the trap)` | - |
| `reclaim.sh rejects a --stale window that is not a duration` | - |
| `reclaim.sh --run removes this run's artifacts across all four kinds` | - |
| `reclaim.sh --run leaves a CONCURRENT run's artifacts alone (the trap)` | - |
| `reclaim.sh --run does not mistake attempt 10 for attempt 1` | - |
| `reclaim.sh --run finds an artifact by its ownership label alone` | - |
| `reclaim.sh --run never issues a blanket prune` | - |
| `reclaim.sh --dry-run reports without removing anything` | - |
| `reclaim.sh --stale collects a killed runner's leftovers` | - |
| `reclaim.sh --stale spares an in-flight run inside the window` | - |
| `reclaim.sh --stale spares the current run even when its clock says old` | - |
| `reclaim.sh --stale ignores artifacts that are not CI-owned` | - |
| `reclaim.sh --stale delegates the unowned classes to prune.sh with the same window` | - |
| `reclaim.sh --stale never touches volumes` | - |

### test/bats/unit/ci_spec.bats (118)

| Test | Description |
|------|-------------|
| `_run_shellcheck: invokes shellcheck against every expected script` | Wired-file regression guard |
| `_run_shellcheck: picks up every .sh file in script/docker/` | `find` covers new scripts |
| `_run_shellcheck: picks up every .sh file in script/test/ (#876)` | - |
| `_run_shellcheck: exits non-zero when shellcheck fails on any script` | Strict-mode propagation |
| `_run_lint_tool: names the tool and the signal when a driver dies of SIGPIPE (#898)` | 141 reported as tool + command + SIGPIPE |
| `_run_lint_tool: names the tool when a driver fails without a signal (#898)` | Plain non-zero abort still names the tool |
| `_run_lint_tool: a clean driver reports nothing and leaves no ERR trap armed (#898)` | Silent on success, trap disarmed after |
| `_run_via_compose: routes default mode to the ci service with COVERAGE=0` | Service routing — fast path |
| `_run_via_compose: routes coverage mode to the coverage service with COVERAGE=1` | Service routing — coverage path |
| `main: dispatches no-flag default to the ci service` | End-to-end default dispatch |
| `_run_tests: passes --jobs N when parallel is on PATH` | Parallel-present branch |
| `_run_tests: omits --jobs when parallel is absent (graceful fallback)` | Parallel-missing branch |
| `main: dispatches --coverage to the coverage service` | End-to-end --coverage dispatch |
| `_shard_unit_files: a single shard returns real unit spec paths (#615)` | #615 coverage shard returns spec paths |
| `_shard_unit_files: partition is exhaustive + disjoint across all shards of T (#615, #724)` | #615 partition invariant (each slice runs once) |
| `_shard_unit_files: greedy weight-balance keeps every shard within 1.5x the partition bound (#677, #940)` | #677 live-tree probe through `_spec_weight`, at the eight shards CI runs |
| `_shard_unit_files: one slow low-@test spec balances by weight though the count axis calls it lopsided (#940)` | #940 skewed `SHARD_WEIGHTS_FILE`: the guard follows seconds, not `@test` count |
| `_shard_unit_files: a distribution no partition can balance is reported IMBALANCED (#940)` | #940 non-vacuity: N+1 equal heavy specs over eight shards must FAIL the guard |
| `_shard_unit_files: the same partition a four-shard probe calls balanced fails at eight (#940)` | #940 the probe's shard total is load-bearing: N=4 passes what N=8 catches |
| `_shard_unit_files: the live probe's total spans the partition pool, not test/bats/unit alone (#936, #940)` | #936 regression guard: a probe totalling `test/bats/unit/` alone is caught on the live tree |
| `_shard_unit_files: the loads that failed CI clear the bound once the total spans the whole pool (#936, #940)` | #936 arithmetic: the recorded loads clear the ceil'd bound once the total is pooled |
| `_shard_unit_files: rejects an out-of-range shard spec (#615, #692)` | #615 shard-spec validation (asserts message) |
| `_shard_unit_files: rejects a no-slash shard spec (#692)` | #692 missing-slash format guard |
| `_shard_unit_files: rejects a non-numeric shard spec (#692)` | #692 non-numeric guard |
| `_shard_unit_files: dies ci_empty_shard when a valid shard matches no files (#692)` | #692 empty-slice guard |
| `_spec_weight: returns the recorded seconds from SHARD_WEIGHTS_FILE (#724)` | - |
| `_spec_weight: falls back to @test count when the spec has no recorded time (#724)` | - |
| `_spec_weight: falls back to @test count when no SHARD_WEIGHTS_FILE is set (#724)` | - |
| `_spec_weight: reads the default repo weights file when SHARD_WEIGHTS_FILE is unset (#733)` | - |
| `_shard_unit_files: partitions by recorded time when SHARD_WEIGHTS_FILE is set (#724)` | - |
| `_junit_to_timings: emits <seconds> <basename> per testsuite, rounded and floored at 1 (#733)` | - |
| `_junit_to_timings: ignores the <testsuites> root and a missing file is a no-op (#733)` | - |
| `_run_coverage: writes coverage/timings.tsv from the bats junit report (#733)` | - |
| `_run_coverage: a full-suite run names every spec file, subfolders included (#952)` | - |
| `_run_coverage: the full run covers the pools the inventory reads (#952)` | - |
| `_shard_unit_files: integration specs are partitioned into the pool, not pinned to one shard (#724)` | - |
| `_run_coverage: shard N/T kcov's only that unit slice, not the whole tree (#615)` | #615 sharded kcov targets |
| `_run_coverage: shard targets are individual spec files, never the whole integration dir (#724)` | - |
| `_run_coverage: no argument keeps the full-suite path (unit + integration) (#615)` | #615 local full-coverage path |
| `main --coverage-shard: routes to the coverage service with COVERAGE_SHARD set (#615)` | #615 shard env plumbing |
| `main --ci with COVERAGE=1 skips the lint phase (lint is a separate matrix concern) (#615)` | #615 coverage path skips lint |
| `main --coverage-shard + --bats-path is rejected (coverage mode guard) (#615)` | #615 single-path/coverage combo guard |
| `no spec drives a coverage run against the mounted checkout (#952)` | - |
| `_fragile_unit_files: returns exactly the spec files with a kcov-skip guard (#677)` | #677 runtime fragile-set == anchored grep |
| `_fragile_unit_files: every kcov-skipped file is in the fragile set (no unit test goes unrun) (#677)` | #677 inverse-direction completeness guard |
| `_run_bats_fragile: runs bats over only the fragile spec files, not the whole unit tree (#677)` | #677 fragile job targets only fragile files |
| `_run_bats_fragile: does NOT set COVERAGE=1 so the kcov-skip guards fall through (#677)` | #677 plain mode runs the skipped tests |
| `main --bats-fragile: routes to the ci service with BATS_FRAGILE=1 + BATS_ONLY=1, no COVERAGE (#677)` | #677 fragile flag dispatch |
| `main --bats-path: dispatches a single spec to the ci service with BATS_FILE + BATS_ONLY=1` | #523 single-file dispatch |
| `main --bats-path: accepts a directory` | #523 directory path |
| `main --bats-path: non-existent path dies with ci_bats_path_not_found` | #523 missing-path guard |
| `main --bats-path: test/bats/system/ path dies with a clear hint` | #523 system guard |
| `main --bats-path + --coverage is rejected (ci_bats_path_coverage)` | #523 coverage-combo guard |
| `_run_coverage_path: writes nothing into the checkout's coverage/ (#887)` | The gate's artifacts stay untouched -- no figure can be fabricated from one spec |
| `_run_coverage_path: the kcov report dir is a throwaway outside the checkout, removed after the run (#887)` | Report lands in container-local scratch and is deleted |
| `_run_coverage_path: kcov's exactly the named spec, never a shard slice (#887)` | Shard independence: a planted .shard-weights pulls in nothing |
| `_run_coverage_path: instruments with the same include/exclude set a coverage shard uses (#887)` | Same instrumented tree as a shard, so the failure reproduces |
| `_run_coverage_path: propagates the spec's exit status so a red spec is a red run (#887)` | Exit-status propagation -- the loop is useless if failure is swallowed |
| `_run_coverage_path: BATS_FILTER appends a bats -f name filter (#887)` | Composes with --filter to instrument a single @test |
| `main --coverage-path: routes one spec to the coverage service with COVERAGE_PATH + BATS_ONLY=1 (#887)` | Dispatch: coverage service, COVERAGE_PATH plumbed, never a shard |
| `main --ci: COVERAGE=1 with COVERAGE_PATH runs the one spec and reports no coverage figure (#887)` | In-container branch sits ahead of _run_coverage; no report line |
| `main --coverage-path: non-existent path dies before docker is called (#887)` | Host-side missing-path guard |
| `main --coverage-path: test/bats/system/ dies with the ci-system hint (#887)` | Host-side system-spec guard (needs the ci-system service) |
| `main --coverage-path + --coverage-shard is rejected (#887)` | A figure over a partition and one instrumented spec are different asks |
| `main --coverage-path + --bats-path is rejected (#887)` | Two runners, two services -- refused by name |
| `main --bats-path + --coverage stays rejected: the fast loop is still kcov-free (#887)` | #523's refusal is intact; the combination is --coverage-path |
| `main: unknown option dies with ci_unknown_option (#692)` | #692 unknown-flag guard |
| `main: --hadolint without --lint dies (narrowing flag, not standalone) (#692)` | #692 narrowing-flag typo guard |
| `main --ci: unknown LINT_TOOL dies with ci_unknown_lint_tool (#692)` | #692 LINT_TOOL validation |
| `main --ci: LINT_TOOL=stale-setup-conf runs the stale setup.conf lint (#845)` | #845 stale setup.conf lint reaches the CI gate |
| `main --ci: LINT_TOOL=readme-sync runs the localized README sync lint (#846)` | #846 localized README sync lint reaches the CI gate |
| `main --ci: LINT_TOOL=doc-counts runs the doc/test count drift gate (#864)` | #864 doc/test count drift gate reaches the CI gate |
| `main --doc-counts-only: runs the drift gate on the host, no compose (#864)` | #864 host-direct primitive so a CI job can run the gate without compose |
| `main --issueref-only: runs the issue-ref comment lint on the host, no compose (#866)` | - |
| `main --adr-structure-only: runs the ADR-structure lint on the host, no compose (#994)` | - |
| `main --adr-numbering-only: runs the ADR-numbering lint on the host, no compose (#866)` | - |
| `main --stale-setup-conf-only: runs the stale setup.conf path lint on the host, no compose (#866)` | - |
| `main --home-literal-only: runs the hardcoded home path lint on the host, no compose (#799)` | - |
| `main --changelog-entry-only: runs the changelog entry-length lint on the host, no compose (#917)` | - |
| `main --action-ref-agreement-only: runs the action ref agreement lint on the host, no compose (#949)` | The CI join is host-direct, like its siblings |
| `main --readme-sync-only: runs the localized README sync lint on the host, no compose (#866)` | - |
| `main: _LINT_TOOLS is the one table every lint-phase caller dispatches through (#866)` | - |
| `main --filter: dispatches with BATS_FILTER + BATS_ONLY=1 and no BATS_FILE` | #523 filter-only dispatch |
| `_run_bats_path: BATS_FILE runs bats on that path; BATS_FILTER appends -f` | #523 single-path runner |
| `_run_bats_path: filter-only runs bats across unit + integration` | #523 filter-only runner |
| `drivers: bats.sh, shellcheck.sh and hadolint.sh driver files exist` | #650 driver files present (incl. hadolint) |
| `drivers: test.sh sources all per-tool drivers` | #650 dispatcher sources every driver |
| `drivers: the bats runners live in drivers/bats.sh, not test.sh` | #650 bats runners moved out |
| `drivers: _run_shellcheck lives in drivers/shellcheck.sh, not test.sh` | #650 shellcheck moved out |
| `drivers: _run_hadolint lives in drivers/hadolint.sh, not test.sh (#650)` | #650 hadolint in its driver |
| `drivers: are sourced libraries (no top-level main invocation)` | #650 driver is a library |
| `drivers: _run_shellcheck also lints the driver files themselves` | #650 driver self-shellcheck |
| `_run_hadolint: lints every Dockerfile in the tree with the shared config` | #650 single-source Dockerfile list + config |
| `_run_hadolint: the linted list is every Dockerfile the tree carries` | A Dockerfile added beside the others and never added to the list is a Dockerfile no lint pass names |
| `_run_hadolint: invokes hadolint once per Dockerfile (no extra targets)` | #650 one invocation per listed Dockerfile |
| `_run_hadolint: dies with a clear message when hadolint is absent` | #650 host-missing-binary guard |
| `_run_hadolint: exits non-zero when hadolint fails on any Dockerfile` | #650 propagates lint failure |
| `_system_setup: dies ci_no_docker_socket when the docker socket is absent (#692)` | #692 system socket guard |
| `_system_setup: dies ci_no_docker_cli when docker is not on PATH (#692)` | #692 system docker-CLI guard |
| `_resolve_test_tools_image: different tooling inputs resolve to different tags (#891)` | #891 content-keyed local tag cannot clobber |
| `_resolve_test_tools_image: identical inputs at different paths resolve to the same tag (#891)` | #891 same inputs -> cache hit, not a rebuild |
| `_resolve_test_tools_image: TEST_TOOLS_IMAGE wins verbatim (#891)` | #891 CI's pinned published tags untouched |
| `_resolve_test_tools_image: fails loud when the tooling Dockerfile is missing (#891)` | #891 no silent bare-literal fallback |
| `main --test-tools-image: prints the resolved tag for the justfile (#891)` | #891 one entry point for build + consumers |
| `_compute_compose_project_name: two checkouts sharing a basename get different names (#891)` | #891 path-keyed, not directory-basename |
| `_compute_compose_project_name: the same checkout path is stable across calls (#891)` | #891 one project per checkout, no per-commit churn |
| `_compute_compose_project_name: a hostile checkout path still yields a legal project name (#891)` | #891 compose grammar guaranteed, not hoped for |
| `_resolve_compose_project_name: COMPOSE_PROJECT_NAME wins verbatim (#891)` | #891 env override still wins |
| `_run_via_compose: passes an explicit -p so the project is not the directory basename (#891)` | #891 the missing -p is the defect |
| `_run_via_compose: honours COMPOSE_PROJECT_NAME (#891)` | #891 -p forwards the caller's name |
| `_run_via_compose: hands compose the very tag the tooling resolver prints (#896)` | #896 one derivation, exported for interpolation |
| `_ensure_test_tools_image: builds the derived tag when the host does not have it (#896)` | #896 a local-only tag absent means not built, not pull |
| `_ensure_test_tools_image: leaves a caller-pinned image alone (#896)` | #896 CI provisions its own |
| `_ensure_test_tools_image: does not rebuild a tag the host already has (#896)` | #896 identical inputs are a cache hit |
| `main --compose-project-name: prints the resolved project for the justfile (#891)` | #891 one entry point for both call sites |
| `_compute_compose_project_name: fails loud when the digest cannot be produced (#891)` | #891 no silent degrade to the shared bare prefix |
| `_run_via_compose: the real ids are in the environment compose interpolates (#895)` | - |
| `_fix_permissions: refuses a non-numeric id instead of handing it to chown (#895)` | - |

### test/bats/unit/code_lines_spec.bats (46)

The comment-stripped file views in `test/bats/unit/test_helper.bash`
(`strip_comments` / `only_comments` / `code_lines` / `code_grep` /
`yaml_job_{text,lines}` / `yaml_top_{text,lines}` / `yaml_step_id_for`),
which the workflow and template structural specs assert against instead of
the raw file.

They exist because a spec that greps a WHOLE file lets a string appearing
only in a COMMENT satisfy an assertion about CODE, and this repo's comments
name in prose exactly what its specs pin. Measured, not theorised: deleting
both real `_transcript_begin` / `_transcript_detach` calls from
`setup_tui.sh`, the active `logging.sh` COPY from the template Dockerfile,
and `hook.sh`'s `DRY_RUN` early return each left the guard named for it
green, matching a comment instead.

The conversion has a mirror-image failure mode, and it is the more dangerous
one: a stripper that also eats a line which is genuinely code turns a
working guard into one that cannot match its subject -- and the natural
"fix" for the resulting red is to weaken the assertion. Both directions are
therefore pinned here, against one fixture carrying every shape that can be
got wrong.

A third direction is pinned alongside them: the STATUS these views hand
back. `grep` prints the same nothing for "this file has no such line" and
for "there was no file", and the guards in this tree branch on that status
to tell the two apart -- so a subject that was renamed away must arrive as 2
(not read) rather than as 1 (read, no match), and an all-comment file must
still arrive as 1.

| Test | Description |
|------|-------------|
| `code_lines: drops an unindented comment-only line` | The base case: a file-header paragraph naming the action the workflow must never use |
| `code_lines: drops an INDENTED comment-only line` | The form that matters most -- a workflow's explanatory prose sits at the indentation of the block it explains |
| `code_lines: drops a shell comment inside a run: block scalar` | A `#` line inside a `run:` block scalar is a shell comment: prose, in the exact place a workflow explains the command it is about to run |
| `code_lines: drops blank lines` | Blank lines are neither code nor documentation and would pad any count assertion |
| `code_lines: drops a Dockerfile comment, including a commented-out directive` | The live hazard in this repo's template Dockerfile: the same COPY appears twice, once active and once as a worked example |
| `code_lines: keeps a trailing comment on a code line, verbatim` | Over-strict direction. The `# v1.2.2` after a pinned action SHA is code's, not prose's -- a spec asserts the pin and its version comment together |
| `code_lines: keeps a # inside a double-quoted string` | Over-strict direction. A naive `s/#.*//` would silently shorten the line into something no assertion matches |
| `code_lines: keeps a # inside a single-quoted string` | Same, for the other quoting style |
| `code_lines: keeps a block-scalar line whose STRING starts with #` | `echo "# heading"` is code whose payload opens with a hash; the line's first non-blank character is `e`, so it stays |
| `code_lines: keeps a # that is part of a value, not a comment` | A colour literal, a fragment, an anchor -- a `#` mid-value never begins a comment |
| `code_grep: a string present only in a comment does not match` | The defect itself, at the call site every converted spec uses |
| `code_grep: a string present in code does match` | Non-vacuity: the filter must still find what is really there |
| `code_grep: passes its flags through and takes the file last` | The signature mirrors grep's own, so a conversion is a one-word edit; `-c` counts over code lines only |
| `code_grep: a subject it cannot read exits 2, not grep's no-match status` | grep prints the same nothing for "no match" and for "no file", so the status has to split them: 1 is a readable subject without the string, 2 is a subject that was never read |
| `code_grep: a directory named as the subject exits 2, not 1` | The sibling shape: the redirection fails rather than the file being absent, and bash's own status for that is 1 as well |
| `code_grep: an unreadable subject reports on stderr, leaving the grep-shaped output empty` | code_grep's stdout is grep's -- lines, or a count under `-c` -- so the reason a subject could not be read goes to stderr beside the status, never into the data a caller counts |
| `code_grep: a directory subject reports the same way, on stderr` | The sibling shape: the redirection fails rather than the file being absent, and a caller counting matches must not receive prose either way |
| `code_lines: an unreadable subject keeps its BUG line on stdout` | The complement, so the split cannot spread by symmetry: code_lines' stdout IS its report, and its callers print what they captured |
| `code_lines: a subject it cannot read exits 2, not 1` | The other emitter of the same status; code_grep reads this one's, so both draw the line in the same place |
| `code_lines: a readable file with no code line exits 1, not 2` | The complement, so the fix cannot be "return 2 whenever nothing came back": an all-comment file HAS been read |
| `only_comments: keeps the comment-only lines and nothing else` | The mirror view, for the rare assertion genuinely about what a file SAYS |
| `only_comments: is the exact complement of strip_comments` | No line may be dropped by both filters or counted by both -- the invariant that makes "code" and "documentation" an exhaustive split |
| `only_comments: keeps a trailing-comment line out of the comment view` | A trailing-comment line belongs to the code view alone; counting it as documentation would let a pin's version comment satisfy a prose assertion |
| `yaml_job_lines: returns the job's code and drops its comment paragraph` | The workflow specs' main entry point, replacing the awk block extractor each file used to carry |
| `yaml_job_lines: stops at the next job` | Block scoping: an assertion about one job must not be satisfied by the next |
| `yaml_job_text: keeps the job's comment paragraph verbatim` | The escape hatch. Keeping it a separate call makes "asserted against a comment" a visible choice |
| `yaml_top_lines: returns a top-level block's code without the prose between keys` | `on` / `env` / `permissions` / `concurrency`; a comment paragraph between two top-level keys is not indented out by the terminator |
| `yaml_top_lines: stops at the next top-level key` | Block scoping for the top-level mappings |
| `yaml_top_text: keeps the block's comments` | The verbatim counterpart, for symmetry with `yaml_job_text` |
| `yaml_step_id_for: names the step whose own body matches` | The step id an assertion needs to say "the consumer reads THE STEP THAT DID THE WORK", derived from the file so a rename moves the assertion with it |
| `yaml_step_id_for: an id-less matching step yields nothing, it does not borrow the id of an earlier step` | The regression it was extracted for: the inline awk carried the last id forward across step boundaries, so a match in a later id-less step wore an earlier step's id and the assertion vouched for a step that no longer contained its subject |
| `yaml_step_id_for: a nested list inside a step is not a step boundary` | The inverse mistake: resetting on every sequence dash loses the id of a step whose match sits in a `with:` list. Only a dash at the step indent is a boundary |
| `yaml_step_id_for: a match in a comment cannot name a step` | It reads the job's code lines, so the same prose hazard the rest of this file exists for cannot name a step either |
| `yaml_step_id_for: a pattern that matches nowhere in the job yields nothing` | An unattributable match is answered with an empty id, never a guessed one; the caller's `[ -n ... ]` turns that into a loud failure |
| `yaml_step_id_for: does not reach into another job for its match` | Job scoping, inherited from `yaml_job_lines`: a step in a neighbouring job cannot supply this job's id |
| `yaml_step_id_for: a block-style needs: above the steps is not the step indent (#993)` | The escape the #948 fix left open: taking the boundary from the shallowest dash the job had shown read it off the block-style `needs:` at indent 4, so no step dash at 6 was ever a boundary and one id ran the length of the job |
| `yaml_step_id_for: the matching step is still named when a block-style needs: precedes it (#993)` | Non-vacuity for the row above -- a helper that answered nothing to everything would satisfy it, and refusing every shape is the same guard deleted |
| `yaml_step_id_for: a shallower list above a deeper steps list is not the step indent (#993)` | The same escape without `needs:`: a `strategy.matrix` sequence written at its parent's indent, above a steps list indented one level deeper. The anchor is the `steps:` key, not any one spelling |
| `yaml_step_id_for: the matching step is still named when a shallower list precedes a deeper steps list (#993)` | Non-vacuity for the row above, on the second shape |
| `yaml_step_id_for: an action input named id does not become the step name (#993)` | `id` is an ordinary action input; read as the step's own key it renames the step to a string no `steps.<id>.outputs` reference resolves. A step's own keys sit at the indent its dash set, a `with:` input deeper |
| `yaml_step_id_for: a match above the job's first step names no step (#993)` | The job keys above `steps:` are outside the region the helper can attribute, so nothing there is answered with an id |
| `yaml_step_id_for: a match below the steps list names no step (#993)` | The other end of that region: a job key after the steps list ends attribution, so the id of the last step does not follow the scan out |
| `yaml_step_run: returns the named step's run: script` | The base case the rest deviate from: the lifted script is the step's own body, so a spec can RUN what the workflow runs instead of asserting against a copy of it that drifts. |
| `yaml_step_run: names a step by its name: when it has no id:` | A step is only obliged to carry a `name:`. Requiring an `id:` would mean editing the workflow to make it testable, and the step under test would no longer be the step that runs. |
| `yaml_step_run: a step that carries no run: yields NOTHING, not 'null' (#1013)` | The load-bearing case for every caller's `[ -s ... ]` guard. yq answers a missing key with the literal `null` at status 0, which is a one-line script the guard accepts and bash runs as a command -- so a spec asserting "this step fails" passes on `null: command not found` against a workflow whose step runs no shell at all. |
| `yaml_step_run: a step name that matches nothing yields nothing (#1013)` | The other end of the same contract -- a step name that resolves to nothing (a rename, a typo) must be empty output, which is what turns a caller's guard into a loud failure instead of a silently empty run. |

### test/bats/unit/completions_spec.bats (15)

Unit tests for the opt-in shell tab-completion installer
`dist/script/base/completions.sh` (#653, ADR-00000011), reached as `just
base completions install|uninstall [--shell ...]`. Sandboxes HOME + the XDG
dirs to a temp tree and stubs `just` on PATH so `JUST_COMPLETE=<shell> just`
emits a per-shell marker; asserts the DYNAMIC loader is written to each
shell's standard auto-load dir (no rc edits), idempotency, the zsh fpath
hint, default `$SHELL` detection, and uninstall.

| Test | Description |
|------|-------------|
| `install bash writes the dynamic eval-loader file` | exact `eval "$(JUST_COMPLETE=bash just)"` content |
| `install fish writes the file with the dynamic completer output` | captures `JUST_COMPLETE=fish just` |
| `install zsh writes _just + prints the fpath hint when dir not on fpath` | `_just` + stdout fpath hint |
| `install zsh: a zsh still printing fpath cannot re-hint a dir already on it (#905)` | - |
| `uninstall removes the installed file` | removes the loader |
| `uninstall is idempotent when the file is absent (no error)` | safe no-op |
| `install --shell all installs all three shells` | bash + fish + zsh |
| `uninstall --shell all removes all three shells` | bash + fish + zsh removed |
| `default --shell detects bash from $SHELL basename` | `$SHELL`-driven detection |
| `default --shell detection errors on an unknown shell` | unknown -> error asking for --shell |
| `unknown argument is a usage error (exit 2), distinct from detection error (#692)` | exit 2 vs exit 1 |
| `missing action is a usage error (exit 2) (#692)` | missing install/uninstall -> exit 2 |
| `-h / --help exits 0 with usage` | help text |
| `install is idempotent: a re-run overwrites cleanly` | overwrite-on-reinstall |
| `--shell with no value is a usage error, not an infinite loop (#955)` | missing flag value -> exit 1, no arg-loop spin |

### test/bats/unit/compose_emit/blocks_spec.bats (30)

Covers the per-service compose emitter (`_emit_stage_service`) and its
shared leaf-emitter sub-seams, hoisted out of `generate_compose_yaml`
(#566). Each emitter is exercised in isolation -- build the inputs, call the
emitter, assert on the small fragment it returns -- instead of running the
whole ~900-line generator and grepping its YAML output.

| Test | Description |
|------|-------------|
| `_emit_gpu_deploy_block: gui=false emits nothing` | GPU off |
| `_emit_gpu_deploy_block: gui=true emits deploy reservation with count + caps` | GPU on |
| `_emit_caps_block: all empty emits nothing` | caps off |
| `_emit_caps_block: cap_add list emits cap_add block` | cap_add |
| `_emit_caps_block: cap_drop + security_opt emit their blocks` | cap_drop/sec_opt |
| `_emit_env_file_block: emits the generated .env then the operator's .env.local (#868)` | - |
| `_emit_env_file_block: 'own' drops the shared .env, keeping .env.local (#868)` | - |
| `_emit_target_arch_line: empty omits the line; set emits literal TARGET_ARCH ref` | - |
| `_emit_build_network_line: empty omits; set emits network line` | build.network |
| `_emit_runtime_line: empty omits; set emits runtime line` | runtime |
| `_emit_restart_line: 'no' omits; plain value plain; on-failure:N quoted` | #478 restart |
| `_emit_init_line: default/true emits init: true; false omits; garbage dropped (#792)` | - |
| `_emit_additional_contexts_block: empty omits; entries emit block` | additional_contexts |
| `_emit_cgroup_rules_block: empty omits; entries emit quoted rules` | cgroup rules |
| `_emit_tmpfs_block: empty omits; entries emit tmpfs list` | tmpfs |
| `_emit_group_add_block: gated on gui AND non-empty groups; emits quoted gids` | #496 group_add |
| `_emit_user_build_args: empty omits; entries emit KEY: ${KEY} pairs` | build args |
| `_logging_svc_kv: seeds from global then overlays per-service (key-level merge)` | logging merge |
| `_logging_svc_kv: a different service does not pick up another svc overlay` | svc keying |
| `_emit_logging_block: empty global + per-svc emits nothing` | logging off |
| `_emit_logging_block: driver + rotation maps to compose options block` | logging opts |
| `_emit_logging_block: keys off the service name for per-svc overrides` | per-svc |
| `_logging_svc_local_path_mount: empty local_path yields empty mount` | #328 off |
| `_logging_svc_local_path_mount: relative path resolves against base, mounts /var/log/<name>` | rel path |
| `_logging_svc_local_path_mount: absolute path passed verbatim (trailing slash stripped)` | abs path |
| `_emit_stage_service: zero-diff stage emits the extends:devel shape` | #215 zero-diff |
| `_emit_stage_service: zero-diff stage with per-svc logging override emits logging block` | zero-diff logging |
| `_emit_stage_service: stage with overrides emits a standalone block (no extends)` | #220 standalone |
| `_emit_stage_service: override stage GPU resolution emits deploy reservation` | standalone GPU |
| `_yaml_dq wraps a value as a double-quoted scalar, escaping \ then " (#698)` | YAML scalar quoting |

### test/bats/unit/compose_emit/gen_spec.bats (83)

Covers `generate_compose_yaml` conditional output: AUTO-GENERATED header,
baseline workspace volume, network/ipc/privileged env-var references,
conditional pid emission (only for `host`; omitted for `private` since
Docker rejects the literal), `test` service presence, image name threading,
conditional GPU deploy block + GUI env/volumes + extra volumes from
`[volumes]` section, and the deploy-scoped `[lifecycle] restart` emission
(never on devel, on a deployable stage in both the `extends: devel` and the
standalone shapes, absent on any `*-test` stage).

| Test | Description |
|------|-------------|
| `generate_compose_yaml outputs AUTO-GENERATED header` | Header check |
| `generate_compose_yaml emits top-level name: as the resolved PROJECT_NAME (#472)` | - |
| `generate_compose_yaml top-level name: precedes services: (#472)` | - |
| `generate_compose_yaml emits exactly one top-level name: (#472)` | - |
| `generate_compose_yaml named volume mount emits top-level volumes: stub (#482)` | - |
| `generate_compose_yaml bind mounts never enter top-level volumes: (#482)` | - |
| `generate_compose_yaml bind-only repo is zero-diff (no top-level volumes:) (#482)` | - |
| `generate_compose_yaml named volume with :mode strips mode from top-level name (#482)` | - |
| `generate_compose_yaml dedups a named volume referenced twice (#482)` | - |
| `generate_compose_yaml top-level volumes: stub has no driver/labels (#482)` | - |
| `generate_compose_yaml emits volumes: before networks: (#482)` | - |
| `generate_compose_yaml emits workspace mount when present in extras` | - |
| `generate_compose_yaml omits workspace when extras is empty (opt-out)` | - |
| `generate_compose_yaml default (no network_name) keeps network_mode env var` | - |
| `generate_compose_yaml with network_name emits networks list + bridge driver block (compose self-managed)` | - |
| `generate_compose_yaml omits devices block when both inputs empty` | - |
| `generate_compose_yaml emits devices: block from device list` | - |
| `generate_compose_yaml accepts /dev:/dev (full /dev tree bind)` | - |
| `generate_compose_yaml: device with propagation emits to volumes long-form (#450 P1)` | - |
| `generate_compose_yaml: device without propagation stays in devices: (#450 P1)` | - |
| `generate_compose_yaml: mixed devices split correctly (#450 P1)` | - |
| `generate_compose_yaml: device rw,rslave emits combined propagation (#450 P1)` | - |
| `generate_compose_yaml: device ro,rshared emits read_only + propagation (#450 P1)` | - |
| `generate_compose_yaml: propagation-only device creates volumes: header even without extras (#450)` | - |
| `generate_compose_yaml: all devices have propagation → no devices: section (#450)` | - |
| `generate_compose_yaml expands ${VAR} env cross-refs in a per-stage env_N addition (refs #955)` | append-mode tail expands against the shared prefix |
| `generate_compose_yaml expands cross-refs in a per-stage environment.env_N replacement (refs #955)` | stage replaces the list, its own env_N cross-refs |
| `generate_compose_yaml emits tmpfs block from tmpfs_ list` | - |
| `generate_compose_yaml emits ports block only under network_mode=bridge` | - |
| `generate_compose_yaml emits shm_size only when ipc_mode != host` | - |
| `generate_compose_yaml emits cap_add from security list` | - |
| `generate_compose_yaml emits cap_drop from security list` | - |
| `generate_compose_yaml emits security_opt from security list` | - |
| `generate_compose_yaml omits cap_add / cap_drop / security_opt blocks when empty` | - |
| `generate_compose_yaml per-stage security.cap_add_inherit=false clears inherited caps for that stage only (#526)` | per-stage caps clear |
| `generate_compose_yaml per-stage security.cap_add_N appends to inherited caps (#526)` | per-stage caps append emit |
| `generate_compose_yaml emits network_mode/ipc/privileged via env var` | env-var baked |
| `generate_compose_yaml omits pid when default private` | pid omit |
| `generate_compose_yaml emits pid env-var ref when host` | pid host |
| `generate_compose_yaml emits test service with profiles: [test]` | test service |
| `generate_compose_yaml image field contains repo name` | Image name |
| `generate_compose_yaml emits TZ build arg with Asia/Taipei default` | - |
| `generate_compose_yaml emits TARGETARCH build arg on devel (test inherits via extends, #493)` | - |
| `generate_compose_yaml omits TARGETARCH line when target_arch empty (BuildKit auto-fill)` | - |
| `generate_compose_yaml emits build.network on devel (test inherits via extends, #493)` | - |
| `generate_compose_yaml omits build.network line when build_network empty` | - |
| `generate_compose_yaml does NOT emit /dev:/dev by default (not in baseline)` | Baseline scope |
| `generate_compose_yaml GPU enabled => deploy block present` | GPU on |
| `generate_compose_yaml GPU disabled => no deploy block` | GPU off |
| `generate_compose_yaml GPU with specific count and capabilities` | GPU args |
| `generate_compose_yaml GUI enabled => DISPLAY env + X11 volumes present` | GUI on |
| `generate_compose_yaml GUI: xauth mounts at fixed neutral target, not host abs path (#582)` | #582 mount target |
| `generate_compose_yaml GUI: container XAUTHORITY points at the fixed mount target (#582)` | #582 env sync |
| `generate_compose_yaml GUI disabled => no DISPLAY env + no X11 volumes` | GUI off |
| `generate_compose_yaml GUI enabled => XDG_RUNTIME_DIR env (Wayland socket dir)` | - |
| `generate_compose_yaml GUI enabled => XDG_RUNTIME_DIR mounted rw at the same path` | - |
| `generate_compose_yaml GUI disabled => no XDG_RUNTIME_DIR env or mount` | - |
| `generate_compose_yaml emits no duplicate key within a service (GUI on)` | - |
| `generate_compose_yaml emits no duplicate key within a service (GUI off)` | - |
| `the duplicate-key detector actually fires on a duplicated service key` | - |
| `generate_compose_yaml extra volumes appended after baseline` | volumes list |
| `generate_compose_yaml empty extras => no extra mount lines` | empty list |
| `generate_compose_yaml with GUI+GPU+extras => all sections present` | fully loaded |
| `generate_compose_yaml emits device_cgroup_rules: when cgroup rules provided` | - |
| `generate_compose_yaml omits device_cgroup_rules: when rules list is empty` | - |
| `generate_compose_yaml omits runtime: when runtime arg is empty (desktop default)` | - |
| `generate_compose_yaml emits runtime: nvidia under devel when runtime=nvidia` | - |
| `generate_compose_yaml placement: runtime: appears between tty and cap_add region` | - |
| `generate_compose_yaml emits runtime service when Dockerfile has AS runtime` | #108 auto-emit |
| `generate_compose_yaml skips runtime service when Dockerfile lacks AS runtime` | opt-out by absence |
| `generate_compose_yaml skips runtime service when Dockerfile is absent` | no-Dockerfile guard |
| `runtime service extends devel and overrides target/image/tty/profile` | compose extends shape |
| `runtime service appears between devel and test blocks` | ordering |
| `runtime detection is robust against weird whitespace` | regex tolerance |
| `runtime detection ignores non-runtime stage names` | strict match |
| `generate_compose_yaml never emits restart: on the devel service (#840)` | - |
| `generate_compose_yaml emits restart: on a deployable stage service (#840)` | - |
| `generate_compose_yaml omits restart: on a *-test stage -- it exits by design (#840)` | - |
| `generate_compose_yaml emits restart: on a deployable stage that carries overrides (#840)` | - |
| `generate_compose_yaml quotes an on-failure:N policy on the deployable stage (#840)` | - |
| `generate_compose_yaml emits no restart: field at all for restart = no (#840)` | - |
| `generate_compose_yaml: runtime stage inherits device propagation from devel (#450 P3)` | - |
| `generate_compose_yaml per-stage emit is byte-identical via _resolve_docker_flags (#505 golden master)` | byte-identical golden |

### test/bats/unit/compose_emit/hostname_spec.bats (5)

The GUI-under-bridge `hostname:` injection: a bridge-network GUI container
pins its hostname to the host name so X11 authority matches, host-network
and GUI-off cases inject nothing, and a per-stage override decides per
stage.

| Test | Description |
|------|-------------|
| `GUI + bridge injects hostname pinned to the host name on devel (#794)` | - |
| `GUI + host mode injects NO hostname on devel (#794)` | - |
| `GUI off + bridge injects NO hostname on devel (#794)` | - |
| `per-stage GUI+bridge override injects hostname on that stage (#794)` | - |
| `per-stage GUI-off under bridge injects NO hostname (#794)` | - |

### test/bats/unit/compose_emit/overlay_guard_spec.bats (7)

Forward-invariant guard (ADR-00000022): base's emitted compose must never
bake a hardcoded per-instance literal over the interpolation-channel field
set, so base-generated stacks are multi_run-expandable by construction. A
predicate self-check proves the guard discriminates a baked literal from a
`${VAR:-default}` interpolation, so a future change that hardcodes a
per-instance field fails immediately.

| Test | Description |
|------|-------------|
| `overlay guard predicate rejects a baked literal, accepts an interpolation` | self-check discrimination |
| `overlay guard: project name: is an overlay interpolation` | name interpolated |
| `overlay guard: the dev-stack emitter emits no container_name at all (#920)` | no container name to collide on |
| `the field-deploy emitter's baked container_name is a STATED exemption (#920)` | deploy bundle exemption stated in README + ADR |
| `overlay guard: network_mode: is an env interpolation, never a baked literal` | network_mode interpolated |
| `overlay guard: no baked published-port literal anywhere (forward invariant)` | no baked port literal |
| `overlay guard: published ports are emitted as ${PORT_N:-default} on devel and stages` | ports overlay form |

### test/bats/unit/compose_logging_spec.bats (19)

Covers `[logging]` + `[logging.<svc>]` support in `generate_compose_yaml`
(#310). Tests the global emission on every service (devel / test /
auto-emitted stage), back-compat for repos not yet declaring `[logging]`,
per-service override key-level merge behaviour, and the two new setup.sh
helpers `_parse_logging_svc_sections` + `_collect_logging`.

| Test | Description |
|------|-------------|
| `generate_compose_yaml omits logging: block when both inputs empty (back-compat)` | Empty inputs no-op |
| `generate_compose_yaml emits logging: block on devel from global [logging]` | Global → devel |
| `generate_compose_yaml test service inherits global logging via extends:devel (#493)` | Global logging emitted once on devel; test inherits via extends |
| `generate_compose_yaml driver-only [logging] omits options: block` | No rotation keys |
| `generate_compose_yaml partial options emits only set keys` | Sparse override |
| `generate_compose_yaml per-svc [logging.<svc>] overrides global key on that svc` | Override semantics |
| `generate_compose_yaml per-svc [logging.<svc>] inherits keys absent in override` | Key-level merge |
| `local_path on global emits volumes mount + LOG_FILE_PATH env for devel (#328)` | Mount + env on devel |
| `local_path empty omits mount + env (back-compat) (#328)` | Empty fallback |
| `local_path emits CONTAINER_LOG_KEEP/DAYS retention env, default fallback (#805)` | - |
| `local_path retention env honors container_log_keep/days overrides (#805)` | - |
| `local_path on per-svc [logging.<svc>] emits LOG_FILE_PATH for that svc only (#328)` | Per-service emit |
| `local_path absolute path is passed through verbatim (#328)` | Absolute path |
| `local_path is NOT emitted as a logging.options key (driver-only options) (#328)` | local_path NOT a docker option |
| `local_path on test service emits standalone volumes block + env (#328)` | test service |
| `setup.conf [logging] comment block references in-image helper path (/usr/local/lib/base/, #368)` | Documented adoption path matches in-image COPY |
| `generate_compose_yaml emits per-stage LOG_FILE_PATH on extends:devel stage when [logging] local_path is set (#367)` | Per-svc LOG_FILE_PATH on auto-emitted extends-only stage |
| `generate_compose_yaml emits per-stage volume mount on extends:devel stage when [logging] local_path is set (#367)` | Per-svc volume mount on auto-emitted extends-only stage |
| `generate_compose_yaml does NOT emit LOG_FILE_PATH on extends:devel stage when [logging] local_path is unset (#367 back-compat)` | Zero-diff back-compat when feature unset |

### test/bats/unit/compose_watchdog_spec.bats (6)

Tests for `[lifecycle]` watchdog (#797) support in `generate_compose_yaml`
and its resolution in `_resolve_deploy_context`: the `WATCHDOG_*` service
environment is emitted (YAML-quoted) only when the master switch
`watchdog_check` is set, so the default-off case leaves `compose.yaml`
byte-identical (the #505 golden is unaffected); the env rides on devel and
extends:devel stages inherit it; and the resolver builds the env block only
for the knobs the conf sets.

| Test | Description |
|------|-------------|
| `watchdog env omitted from compose when disabled (default off, #505 golden) (#797)` | - |
| `watchdog env stays OUT of the compose environment: block so .env.local wins (#868)` | - |
| `a stage that replaced the inherited env list re-states WATCHDOG_* inline (#868)` | - |
| `a stage that APPENDS to the inherited env list keeps the shared .env (#868)` | - |
| `_resolve_deploy_context yields empty watchdog_env_str when check unset (#797)` | - |
| `_resolve_deploy_context builds WATCHDOG_* only for the set knobs (#797)` | - |

### test/bats/unit/conf_accessor_spec.bats (27)

Unit tests for the `conf.sh` opaque accessor interface (#564 / #563):
`_conf_load` loads a file into a named handle, `_conf_get` reads a value by
(section, key) with an optional default, `_conf_sections` lists section
names, `_conf_list` lists a section's keys, `_conf_load_merged` loads a
template+repo section-replace merge into a handle, and `_conf_list_sorted`
returns `prefix_N` values in numeric order (skipping empties) -- all without
callers touching the internal parallel-array representation or the
`<section>.<key>` namespacing rule. Also the low-level INI reader the
accessor is built on: `_parse_ini_section` (per-section key/value
extraction, section isolation, comment/whitespace handling, dotted
sub-sections, duplicate/reopened sections) and the shared single-pass core
`_ini_tokenize` (relocated here from `setup_spec` in P1b, #758 -- they test
`lib/conf.sh`).

Dirty-input + error-path coverage (#689) pins the parser/accessor contracts
on hand-edited / malformed setup.conf:

| Test | Description |
|------|-------------|
| `_conf_get returns a value by section and key` | - |
| `_conf_get_into writes the value into the named outvar, no subshell (#742)` | - |
| `_conf_sections lists section names in first-appearance order` | - |
| `_conf_list lists a section's keys in file order` | - |
| `_conf_load_merged: repo section replaces template section wholesale` | - |
| `_conf_get: duplicate key within a section -- last occurrence wins (#689)` | Override semantics (merge + re-save) |
| `_conf_list: a section reopened later in the file keeps entries from both occurrences (#689)` | Reopened section appends; header deduped |
| `_conf_get: inline '#' comment text is KEPT in the value (no inline-comment support) (#689)` | Trailing `# ...` is literal (only leading-# stripped) |
| `_conf_sections: section header with internal whitespace is NOT trimmed ([ deploy ] != deploy) (#689)` | Interior spaces kept in captured name |
| `_conf_load: an unterminated section header ([deploy without ]) drops its keys (#689)` | No header match -> keys lost, no crash |
| `_conf_list_sorted returns prefix_N values in numeric order, skipping empties` | - |
| `_conf_list_sorted skips non-numeric list suffixes (mount_x / mount_ / mount_2b) (#689)` | Numeric-suffix guard reject path |
| `_upsert_conf_value leaves the original file intact when mktemp fails (#700)` | Guarded mktemp -> no clobber/truncate on temp-create failure |
| `_write_setup_conf leaves the destination intact when its temp file cannot be created (#700)` | Temp+atomic-mv -> no in-place truncate data-loss window |
| `_upsert_conf_value cleans the orphan temp + errors when the final mv fails (#702)` | Failed atomic mv -> orphan temp removed + error logged + original unchanged |
| `_write_setup_conf cleans the orphan temp + errors when the final mv fails (#702)` | Failed atomic mv -> orphan temp removed + error logged + destination unchanged |
| `_parse_ini_section reads keys and values for one section` | - |
| `_parse_ini_section isolates sections (entries from other sections ignored)` | - |
| `_parse_ini_section skips comment and empty lines` | - |
| `_parse_ini_section trims whitespace around key and value` | - |
| `_parse_ini_section returns empty arrays for missing file` | - |
| `_parse_ini_section returns empty arrays for absent section` | - |
| `_parse_ini_section does not absorb dotted sub-sections` | - |
| `_parse_ini_section reads a dotted section name` | - |
| `_parse_ini_section preserves duplicate keys and reopened sections in order` | - |
| `_ini_tokenize tracks the owning section per entry and dedups headers` | - |
| `_ini_tokenize keeps dotted keys verbatim (per-stage override keys)` | - |

### test/bats/unit/conf_logging_spec.bats (9)

Unit tests for the logging-config collectors (`_parse_logging_svc_sections`
/ `_collect_logging`): per-service `[logging.<svc>]` enumeration in file
order, plain `[logging]` global handling, and empty-when-absent behaviour.

| Test | Description |
|------|-------------|
| `_parse_logging_svc_sections enumerates services in file order` | File-order service enumeration |
| `_parse_logging_svc_sections ignores plain [logging] section` | Global section not a service |
| `_parse_logging_svc_sections returns empty when file does not exist` | Missing-file empty |
| `_collect_logging reads global [logging] from per-repo setup.conf` | Global logging read |
| `_collect_logging reads per-service [logging.<svc>] sections` | Per-service logging read |
| `_collect_logging: .setup.conf.local replaces the [logging] section (#893)` | - |
| `_collect_logging: .setup.conf.local supplies a [logging.<svc>] override (#893)` | - |
| `_collect_logging ignores an ambient SETUP_CONF (#893 decision 7)` | - |
| `_collect_logging returns empty when no [logging] sections anywhere` | No-config empty |

### test/bats/unit/coverage_badge_spec.bats (45)

Unit tests for `script/release/coverage_badge.sh` (#952) -- the release
coverage badge generator that replaces the README's static `Coverage-Kcov`
shields.io badge with a self-contained SVG committed to the repo. It obtains
the figure by re-running `coverage_gate.sh`'s own merge math over the local
kcov reports and stamps the version the figure belongs to, so a per-release
number cannot be read as `main`'s. The load-bearing half is the refusal: a
release whose coverage never ran must not publish a stale or an invented
figure, so a missing or mismatched provenance stamp (`coverage/.head-sha`,
written by the coverage run), a report older than the commit being released,
or a modified instrumented source each refuse and write nothing. The last
three tests assert the repo's own published figure, not the generator.

| Test | Description |
|------|-------------|
| `coverage_badge: renders the measured rate into a self-contained SVG` | The output is an SVG carrying the measured percentage |
| `coverage_badge: the SVG carries the version the figure belongs to` | Defaults to `.version`, so the figure names its release |
| `coverage_badge: --version overrides the .version default` | The bump passes the version it is promoting to |
| `coverage_badge: the SVG references no external host` | No renderer, no fetch -- it ports to GitLab unchanged |
| `coverage_badge: the rate is the gate's own merge math, not a re-implementation` | Two shards over the same file: the per-line union (75%), not the root-counter sum (50%) |
| `coverage_badge: a high rate grades green` | Shields' own flat palette, as the removed Codecov badge read |
| `coverage_badge: a low rate grades red` | The bottom of the same grading |
| `coverage_badge: refuses when no coverage report exists` | No measurement means no figure, not the previous one |
| `coverage_badge: refuses when the reports predate the commit being released` | A report older than HEAD measured an earlier tree |
| `coverage_badge: refuses when the reports were produced from a different commit` | Measure one tree, check an older commit out: every timestamp check passes and the sha does not |
| `coverage_badge: refuses when the reports carry no provenance` | Reports with no recorded sha describe no particular tree |
| `coverage_badge: the coverage run records the sha its reports describe` | The producer half: without a writer the reader refuses every real release |
| `coverage_badge: a partial measurement is not certified whole, whatever the invocation said` | - |
| `coverage_badge: a run that recorded no measurement is certified as nothing` | - |
| `coverage_badge: a later partial measurement overwrites an earlier full one` | - |
| `coverage_badge: the measured-scope inventory is this repo's real spec tree` | - |
| `coverage_badge: the coverage run drops the old certificate before it starts` | - |
| `coverage_badge: the eraser drops the manifest the scope is derived from` | - |
| `coverage_badge: a manifest that outlives its erasure fails the run` | - |
| `coverage_badge: a certificate that outlives its erasure fails the run` | - |
| `coverage_badge: a failed coverage run leaves no certificate behind` | - |
| `coverage_badge: a coverage run that succeeds still writes its certificate` | - |
| `coverage_badge: a sourced dispatch withholds the certificate too` | - |
| `coverage_badge: --coverage-shard partitions the CONTAINER, and tells the writer nothing` | - |
| `coverage_badge: a full --coverage run hands the writer only the root` | - |
| `coverage_badge: a full --coverage run tells the CONTAINER no selector at all` | - |
| `coverage_badge: the coverage dispatch pins every selector the container reads` | - |
| `coverage_badge: refuses when the reports cover one shard, not the suite` | Every identity check passes and the figure is still a quarter of the suite |
| `coverage_badge: refuses when the stamp records no scope at all` | An unscoped stamp is no evidence of a release figure |
| `coverage_badge: the operator sequence shard-then-badge publishes nothing` | `just test coverage 1/4` then `just release coverage-badge` at one commit |
| `coverage_badge: refuses when instrumented sources are modified in the worktree` | The reports then describe neither the commit nor the tree |
| `coverage_badge: a release-bump edit is not a source change` | `.version` moving is the bump's own edit and must not block the step it runs |
| `coverage_badge: refuses to overwrite an existing badge when it cannot measure` | A refusal leaves the last good badge byte-identical |
| `coverage_badge: --unmeasured states the absence instead of inventing a figure` | The honest rendering for a version that has no measurement |
| `coverage_badge: rejects an unknown option` | Arg errors exit 2, distinct from a refusal's 1 |
| `coverage_badge: a missing option value is an arg error, not a refusal` | A typo'd flag must not wear the "re-run just test coverage" exit code |
| `coverage_badge: --help states the once-per-release cadence` | The claim itself, not the incidental word "release" |
| `coverage_badge: the un-wired release step is recorded as pending, with its issue` | The ADR and the recipe doc name docker_harness#289 instead of claiming a caller that does not exist |
| `coverage_badge: the generator header records the bump wiring as pending` | The property list is where the round-2 reword did not reach |
| `coverage_badge: the dirty check covers every source kcov instruments` | - |
| `coverage_badge: the roster's drift note promises only the guard it has` | - |
| `coverage_badge: the README shows the committed badge, not a static one` | The `Coverage-Kcov` badge is gone and the SVG is referenced |
| `coverage_badge: every localized README shows the committed badge` | All three translations, by their own relative path |
| `coverage_badge: the committed badge names the released version` | The published SVG and `.version` agree |
| `coverage_badge: every README records the release step as hand-run, not the bump's` | - |

### test/bats/unit/coverage_gate_spec.bats (21)

Unit tests for `script/test/drivers/coverage_gate.sh` (#710) -- the
self-hosted, CI-agnostic coverage-floor gate that replaces the removed
Codecov merge+status path. The gate MERGES the per-shard kcov cobertura
reports into ONE line-weighted project rate (summing covered/valid lines
across shards, NOT averaging the per-shard rates) and exits non-zero when
the merged rate is below `COVERAGE_MIN`. Driven against controlled cobertura
fixtures so the spec is independent of any live kcov run. Since #853 the
union key is CANONICALISED first: kcov reports one source file under several
prefix-truncated aliases, and each alias used to add its own full copy of
the file's lines to the denominator.

| Test | Description |
|------|-------------|
| `coverage_gate: passes when merged rate >= COVERAGE_MIN` | Floor pass |
| `coverage_gate: passes at exactly the floor (boundary)` | Boundary (==) pass |
| `coverage_gate: fails when merged rate < COVERAGE_MIN` | Floor fail (non-zero exit) |
| `coverage_gate: merges DISJOINT shards by union (= sum), not averaging` | - |
| `coverage_gate: SHARED source across shards is unioned, not double-counted (#730)` | - |
| `coverage_gate: four shards merge into one weighted total` | 4-shard merge total |
| `coverage_gate: prefix path aliases of one file are counted once (#853)` | Alias-inflated denominator (the bug) |
| `coverage_gate: different files sharing a basename stay separate (#853)` | Basename-only keying is wrong (the trap) |
| `coverage_gate: rate is unchanged when the suite is resharded under other aliases (#853)` | Shard-membership invariance |
| `coverage_gate: reports the collapsed-alias count as a diagnostic (#853)` | Alias-collapse diagnostic |
| `coverage_gate: reports zero collapsed aliases when nothing is aliased (#853)` | Diagnostic reports 0, not silence |
| `coverage_gate: errors when no report files are given` | No-args error |
| `coverage_gate: errors when a named report file is missing` | Missing-file error |
| `coverage_gate: errors when total valid lines is zero (empty report)` | Empty-report error |
| `coverage_gate: errors on a report missing the line counters` | Malformed-report error |
| `coverage_gate: default COVERAGE_MIN does not false-fail at the measured 84.72%` | Built-in default does not false-fail |
| `coverage_gate: default COVERAGE_MIN is 80 -- a report exactly at 80 passes` | Floor value pinned from below |
| `coverage_gate: default COVERAGE_MIN is 80 -- a report just under 80 fails` | Floor value pinned from above |
| `coverage_gate: emits a GitHub step summary table when GITHUB_STEP_SUMMARY is set` | GitHub visibility (no SaaS) |
| `coverage_gate --merge-timings: merges per-shard timings keeping max seconds per basename (#733)` | - |
| `coverage_gate --merge-timings: no input files yields an empty weights file (#733)` | - |

### test/bats/unit/deploy_hint_spec.bats (6)

Covers the "regenerate this artifact" hints stamped into what the deploy
generator emits -- the resolved `compose.yaml` header and the `deploy.sh`
launcher -- plus the sibling hint in the shipped `dist/deploy/cd-guard.sh`
(#843). The hints used to print a bare positional stage, which
`_setup_deploy` rejects as an unknown arg, so the printed command failed
when copy-pasted; these specs replay the emitted hint's own argument list
through the real parser instead of asserting a hand-copied duplicate.

| Test | Description |
|------|-------------|
| `resolved compose header hint uses --stage, not a bare positional stage (#843)` | compose header hint |
| `deploy.sh launcher hint uses --stage, not a bare positional stage (#843)` | launcher hint |
| `cd-guard.sh documents the --stage form of the deploy command (#843)` | cd-guard hint |
| `the compose-header hint's args are accepted by the deploy arg parser (#843)` | hint replayed through parser |
| `the launcher hint's args are accepted by the deploy arg parser (#843)` | hint replayed through parser |
| `no shipped artifact spells the deploy recipe without its module (#920)` | - |

### test/bats/unit/deploy_manifest_spec.bats (16)

Covers the per-component tunable-config manifest primitives (#833;
ADR-00000023 sec.5): `_parse_deploy_manifest` (a committed, downstream-owned
`config/<component>/deploy.manifest` declaring the container-internal paths
an operator may override per stage) and `_collect_deploy_binds` (aggregating
every component's declarations by basename, the name the file takes in the
bundle `config/` + its compose bind). base delivers files; it does not parse
content. A missing manifest is nothing-tunable (fail-safe); a malformed
manifest, or a duplicate basename across components, fails loud. Each
declaration also carries an access mode (#870): no flag means read-only,
`rw` opts that one path into container writes, and any other trailing token
is malformed -- reported with file and line, never skipped and never
downgraded in silence.

| Test | Description |
|------|-------------|
| `_parse_deploy_manifest: returns only the requested stage's paths (tunable-manifest)` | per-stage selection |
| `_parse_deploy_manifest: a path unlisted for the stage stays baked-only (tunable-manifest)` | unlisted = baked |
| `_parse_deploy_manifest: skips blank + comment lines and trims whitespace (tunable-manifest)` | lexing |
| `_parse_deploy_manifest: an unflagged path is read-only, an explicit rw opts in (tunable-manifest)` | access mode: ro default, rw opt-in |
| `_parse_deploy_manifest: an explicit ro flag is accepted (tunable-manifest)` | the default spelled out |
| `_parse_deploy_manifest: an unknown access flag fails loud naming file and line (tunable-manifest)` | bad flag, not a silent skip |
| `_parse_deploy_manifest: a trailing token after a valid flag fails loud (tunable-manifest)` | one flag only |
| `_parse_deploy_manifest: a missing manifest is not an error -> empty (tunable-manifest)` | missing = empty |
| `_parse_deploy_manifest: a malformed section header fails loud (tunable-manifest)` | bad section |
| `_parse_deploy_manifest: a non-absolute content line fails loud (tunable-manifest)` | non-absolute path |
| `_parse_deploy_manifest: a path before any section fails loud (tunable-manifest)` | orphan path |
| `_collect_deploy_binds: aggregates every component's stage paths keyed by basename (tunable-manifest)` | aggregation |
| `_collect_deploy_binds: carries each path's access mode keyed by basename (tunable-manifest)` | mode aggregation |
| `_collect_deploy_binds: no manifests -> empty map (nothing tunable) (tunable-manifest)` | nothing tunable |
| `_collect_deploy_binds: duplicate basename across components fails loud (tunable-manifest)` | basename collision |
| `_collect_deploy_binds: propagates a malformed manifest failure (tunable-manifest)` | fail propagation |

### test/bats/unit/deploy_spec.bats (66)

Covers the self-contained field-deploy generator (#832; ADR-3 amended by
ADR-00000023). Deploy produces an output FOLDER run via a fully-resolved,
self-contained `docker compose` (superseding the #497 raw `docker run`
tar.xz): `_resolve_deploy_version` (the `<repo>:<stage>-<version>` image
stamp), `_resolve_deploy_context` (the conf-resolution shared with apply),
`_generate_resolved_compose` (the resolved `compose.yaml` -- no variable
interpolation, no `setup.conf`/`.env` dependency, dev-host workspace bind
stripped, `restart: unless-stopped` added, tunable-manifest paths bound,
per-stage params carried, follows the stage for GUI/X11),
`_generate_deploy_launcher` (the thin up/down/logs `deploy.sh`), and
`_generate_deploy_bundle` (the folder orchestrator; docker/xz/cp steps
mocked via `_dry_run_cmd`, no real daemon). Also covers `_setup_deploy`'s
stage-eligibility guard (#841): the `--stage` a user names must satisfy
`_is_deployable_stage` (PRD invariant 8 / ADR-00000023 sec.4), so the
template-managed baseline, the legacy aliases and any `*-test` stage are
refused before any build or bundle step.

| Test | Description |
|------|-------------|
| `_resolve_deploy_version: returns the tag in a tagged git tree (field-deploy)` | version tag |
| `_resolve_deploy_version: appends -dirty when the tree has uncommitted changes (field-deploy)` | dirty stamp |
| `_resolve_deploy_version: falls back to the short commit SHA in a tagless clone (#844)` | tagless `--always` fallback |
| `_resolve_deploy_version: degrades to 'unknown' outside a git tree (field-deploy)` | non-git fallback |
| `_resolve_deploy_context: resolves scalars + list strings from setup.conf (#506)` | full resolution |
| `_resolve_deploy_context: applies effective defaults for a minimal repo conf (#506)` | template-merged defaults |
| `_resolve_deploy_context: a missing [lifecycle] restart falls back to the shipped default (#840)` | - |
| `_resolve_deploy_context: builds the WATCHDOG_* env block from [lifecycle] watchdog_* (#840)` | - |
| `_resolve_deploy_context: legacy [deploy] runtime alias resolves gpu_runtime_mode (#506/#481)` | legacy alias |
| `_resolve_deploy_context: dri_groups auto resolves host GIDs via the SETUP_DETECT_DRI_GROUPS operator override (#506/#496)` | dri auto |
| `_resolve_deploy_context: dri_groups off yields empty (#506/#496)` | dri off |
| `_generate_resolved_compose: self-contained -- no variable interpolation, restart present, image pinned (#832)` | resolved + self-contained |
| `_generate_resolved_compose: strips the dev-host workspace bind and bakes env (no -v/-e) (#832)` | dev-host strip |
| `_generate_resolved_compose: binds each tunable-manifest file mount-wins over the baked default (#833)` | tunable binds |
| `_generate_resolved_compose: a tunable bind is read-only unless the manifest declared rw (#870)` | :ro default, :rw when declared |
| `_generate_resolved_compose: carries the deployed stage's resolved params (privileged/gpu/devices) (#832)` | per-stage params |
| `_generate_resolved_compose: follows the stage -- gui off headless, gui force emits X11 (#832)` | follow-stage GUI |
| `_generate_resolved_compose: per-stage [stage:runtime] override is applied (#832)` | per-stage override |
| `_generate_resolved_compose: shm_size + ipc emitted as literals under non-host ipc (#832)` | ipc/shm literals |
| `_generate_resolved_compose: the watchdog env leaves environment: for the bundle .env (#868)` | - |
| `_generate_bundle_env writes the field .env with watchdog + [environment] defaults (#868)` | - |
| `_generate_resolved_compose: no environment: block when the watchdog is off and gui is off (#840)` | - |
| `_generate_resolved_compose: gui X11 still owns the environment: block (#840)` | - |
| `_generate_resolved_compose: restart defaults to unless-stopped, an explicit policy wins (#840)` | - |
| `_generate_resolved_compose: a malformed [lifecycle] restart falls back to the field default (#840)` | - |
| `_generate_deploy_launcher: writes an executable up/down/logs launcher (#832)` | launcher shape |
| `_generate_deploy_launcher: a no-arg invocation defaults to up without a set -e early exit (#832)` | no-arg default up |
| `_generate_deploy_launcher: generated launcher is ShellCheck-clean (#832)` | shellcheck-clean output |
| `_collect_config_components: names every config/*/ dir, sorted` | component population |
| `_collect_config_components: skips files and hidden entries` | dir-only discriminator |
| `_collect_config_components: empty result on a repo with no config/` | empty population |
| `_bake_config_copy: splices COPY config/<component> into the target stage (#506/#504/#1000)` | config COPY bake |
| `_bake_config_copy: handles src == out in place (#506/#504/#1000)` | in-place bake |
| `_bake_config_copy: bakes every component to its own destination (#1000)` | per-component target |
| `_bake_config_copy: bakes config/shell and config/pip too (#1000)` | no name list |
| `_bake_config_copy: returns 1 and writes nothing when no component dir exists (#1000)` | nothing-to-bake |
| `_collect_preset_selectors: a root symlink into config/ is a selector, other root symlinks are not (#826)` | selector derivation |
| `_collect_preset_selectors: collects a selector whose target does not exist (#826)` | dangling is collected, not hidden |
| `_collect_preset_selectors: a ./-prefixed link text is the same selector (#826)` | link-text normalisation |
| `_collect_preset_selectors: a repo with no selector yields nothing (#826)` | empty population |
| `_report_config_components: states which preset each selector currently selects (#826)` | which preset is live |
| `_report_config_components: WARNs a selector whose preset is missing (#826)` | dangling selector named |
| `_report_config_components: says nothing about presets when the repo has no selector (#826)` | silence when there is no selector |
| `_generate_deploy_bundle: dry-run plans build (versioned image) + save + xz + install (#832)` | bundle plan |
| `_generate_deploy_bundle: dry-run builds from the baked Dockerfile when [environment] is set (#832/#503)` | env-bake build |
| `_generate_deploy_bundle: dry-run plans a docker cp per tunable-manifest path (#833)` | tunable extract |
| `_generate_deploy_bundle: a malformed manifest fails loud before building (#833)` | fail-loud guard |
| `_generate_deploy_bundle: fails loud when the image bakes no file at a declared tunable path (#833)` | missing baked default |
| `_setup_deploy: --dry-run previews the resolved compose + prints the build plan (#832)` | deploy dry-run |
| `_setup_deploy: the preview shows each tunable bind at its declared access (#870)` | preview matches the bundle |
| `_setup_deploy: refuses while .setup.conf.local is present (#893)` | - |
| `_setup_deploy: --allow-local-override proceeds and says what it accepted (#893)` | - |
| `_setup_deploy: no refusal when there is no local override (#893)` | - |
| `_render_deploy_readme: records the untracked sections a bundle was built from (#893)` | - |
| `_render_deploy_readme: says nothing about local overrides when there were none (#893)` | - |
| `_generate_deploy_bundle: hands the untracked sections to the bundle README (#893)` | - |
| `_setup_deploy: refuses in a non-interactive shell without -y (#832)` | non-tty refuse |
| `_setup_deploy: errors when the repo has no Dockerfile (#832)` | no-Dockerfile guard |
| `_setup_deploy: rejects an unknown flag (#832)` | arg validation |
| `_setup_deploy: --stage selects the target stage (#832/#841)` | stage select |
| `_setup_deploy: refuses a template-baseline stage (#841)` | stage eligibility (baseline) |
| `_setup_deploy: refuses a legacy baseline alias (#841)` | stage eligibility (legacy alias) |
| `_setup_deploy: refuses a downstream-shaped <x>-test stage (#841)` | stage eligibility (*-test) |
| `_setup_deploy: a refused stage writes no bundle even with -y (#841)` | guard fires before build |
| `main deploy routes to _setup_deploy (#832 dispatch)` | dispatch wiring |
| `_resolve_deploy_context: warns when the legacy [deploy] runtime key is present but shadowed (#876)` | - |

### test/bats/unit/deploy_word_collision_spec.bats (12)

| Test | Description |
|------|-------------|
| `setup_tui accepts gpu as a subcommand (#879)` | - |
| `setup_tui still accepts deploy as a subcommand (alias kept) (#879)` | - |
| `gpu canonicalises to the deploy section editor (#879)` | - |
| `a non-aliased section canonicalises to itself (#879)` | - |
| `an unknown word is still rejected (#879)` | - |
| `the deploy spelling explains it is the GPU editor, not the bundle (#879)` | - |
| `the gpu spelling is silent -- the alias is the way out of the notice (#879)` | - |
| `no subcommand at all is silent (#879)` | - |
| `the disambiguation notice is translated in all four locales (#879)` | - |
| `setup_tui --help lists gpu and denies the field-bundle reading (#879)` | - |
| `setup_tui --help names the distinction in all four locales (#879)` | - |
| `setup.sh --help distinguishes the deploy subcommand from the section (#879)` | - |

### test/bats/unit/derived_figures_lint_spec.bats (20)

| Test | Description |
|------|-------------|
| `_derived_baseline_renderings: derives the forward-looking and legacy sets from _validate_stage_name (#874)` | - |
| `_derived_baseline_renderings: does NOT include devel-test -- the predicate emits it as a service (#874)` | - |
| `_derived_baseline_renderings: every derived name probes back as a baseline collision (#874)` | - |
| `_run_derived_figures: FAILS on a README baseline set that lists devel-test, naming file and line (#874)` | - |
| `_run_derived_figures: PASSES on the canonical forward-looking and legacy renderings (#874)` | - |
| `_run_derived_figures: ignores a brace set that names no baseline stage (#874)` | - |
| `_run_derived_figures: catches a stale set wrapped across markdown lines (#874)` | - |
| `_run_derived_figures: catches a stale set split by an escaped newline in a shell string (#874)` | - |
| `_run_derived_figures: catches a stale set wrapped across two shell comment lines (#874)` | - |
| `_run_derived_figures: ignores a brace EXPANSION glued to a path (#874)` | - |
| `_run_derived_figures: scans CONTEXT.md and the localized READMEs too (#874)` | - |
| `_run_derived_figures: ignores a ${VAR} expansion that is not a stage set (#874)` | - |
| `_run_derived_figures: FAILS when the README section count disagrees with SCHEMA_SECTIONS (#874)` | - |
| `_run_derived_figures: FAILS when the count is a number but the wrong one (#874)` | - |
| `_run_derived_figures: FAILS when the listed sections differ from SCHEMA_SECTIONS (#874)` | - |
| `_run_derived_figures: FAILS when the listed sections are out of template order (#874)` | - |
| `_run_derived_figures: FAILS when the section heading is absent (no vacuous pass) (#874)` | - |
| `_run_derived_figures: FAILS when a required doc file is missing (no vacuous pass) (#874)` | - |
| `_run_derived_figures: FAILS when the dist/ scan root is missing (no vacuous pass) (#874)` | - |
| `_run_derived_figures: the REAL tree passes today (#874)` | - |

### test/bats/unit/doc_counts_driver_spec.bats (1)

The driver is a thin wrapper around `_check_test_md_drift`, and the one
thing it owns is the message a red branch reads. That message is not
decoration: it is the whole repair instruction, and the gate's file set
outgrew it -- the generator writes the undescribed ceiling into its own
lint's driver as well as the `doc/test` catalogues, so a message naming
`doc/test/*.md` sends the reader to a file that is not the one that drifted.
The case here drives a ceiling-only drift and reads the message, not the
diff.

| Test | Description |
|------|-------------|
| `_run_doc_counts: the drift message names the files the generator writes (#1024)` | A drift the message used to describe wrongly. Only the ceiling is out of sync -- every `doc/test` document matches the tree -- so a message that names `doc/test/*.md` and tells the reader not to hand-edit a count or a catalogue row names neither the file that drifted nor the edit that would repair it. The set is the generator's own answer (`_sync_doc_counts_outputs`), so the next generated figure arrives in the message with it. Read from the stubbed `_die` alone: the unified diff on stderr already names the file, and asserting over both would pass on the diff. |

### test/bats/unit/doc_counts_spec.bats (29)

Unit coverage for the generator that derives ALL of doc/test/*.md from the
specs: the count figures (`grep -c '^@test'`) and the catalogue sections,
whose blurbs and per-test descriptions are read out of the spec files' own
`# why:` markers. `check_test_md_drift.sh` stays the validating safety net
and runs this same generator, so a case here is a case for the gate too.

The first half covers the count figures, which were generated first and for
the same reason: they were hand-edited every PR and went stale silently. The
second half covers the generated catalogue REGION, and every case in it is a
property the previous design could not have -- a rename carrying its prose,
a deleted row restored byte-for-byte, a description with a pipe in it that
the author did not have to escape.

| Test | Description |
|------|-------------|
| `_sync_doc_counts: rewrites a stale ### heading to the real @test count (#727)` | per-spec heading recompute |
| `_sync_doc_counts: every section heading is emitted at one derivable depth` | Heading DEPTH is uniform now, and that is a decision with a cost. Depth used to be whatever the document had, which is why eight sections sat at `####` -- an editorial grouping under a prose heading, not path nesting, so nothing in a checkout could derive it. A generator that emitted both depths would have to be told which, by a person, per section. One depth is derivable; the grouping prose moved to the hand-written preamble, where it enumerates nothing. |
| `_sync_doc_counts: rewrites the per-type total to the sum of the headings (#727)` | per-type total from grep-over-files |
| `_sync_doc_counts: is idempotent on an already-synced tree (#727)` | re-run no-op |
| `_sync_doc_counts: rewrites the system per-type total from test/bats/system/ (#782)` | - |
| `_sync_doc_counts: tolerates an empty acceptance dir (count 0, no error) (#782)` | - |
| `_sync_test_md_index: fills the system + acceptance rows, retires behavioural (#782)` | - |
| `_sync_test_md_index: regenerates the blockquote prose System/smoke pair (#843)` | - |
| `_sync_doc_counts: a '# why:' block above a test becomes that row's description` | The ordinary case end to end: a description authored above a test in the spec file arrives in the rendered row. Everything else here is a deviation from this one. |
| `_sync_doc_counts: renaming a test carries its description to the new name` | The whole point of moving the prose to the spec. A rename used to lose the description -- the catalogue documented that loss as a rule -- because the row was keyed on the name. The description now moves with the lines above the test, so this is the case the previous design could not satisfy at all. |
| `_sync_doc_counts: a row deleted from the catalogue is restored byte-for-byte` | The other direction of "the spec is the source": a row deleted from the committed catalogue is not a decision, it is damage, and the next run has to put it back exactly. Under the old design the description went with it and nothing could restore that half. |
| `_sync_doc_counts: deleting a '# why:' block turns its row back into the placeholder` | Deleting the marker is the one edit that SHOULD change the catalogue, and it must change it visibly: the row falls back to the placeholder rather than keeping prose the tree no longer holds. |
| `_sync_doc_counts: a pipe in a DESCRIPTION is escaped, so the row keeps two cells` | The load-bearing escaping case, and the one the migration had to get right: five committed descriptions carry a literal pipe. The author types it raw in the marker -- markdown is the RENDERER's problem -- so an unescaped one here would split the row into three cells and silently move every description one column left. |
| `_sync_doc_counts: a pipe in a test NAME is escaped so the table stays well formed` | A `\|` in a test NAME has always been escaped; the case stays because name and description are escaped by the same renderer now and a change to one is a change to the other. |
| `_sync_doc_counts: the file-level '# why:' block renders as the section blurb` | The file-level block is a different site with the same grammar, and it is what replaced the hand-written paragraph under each heading -- the half a merge used to be able to drop while keeping the heading. |
| `_sync_doc_counts: every spec the glob matches gets a section, in glob order` | Sections are derived from the glob, not from what the document already mentions. A spec that never got a heading used to be invisible to every gate -- the same rot one level up from a missing row. |
| `_sync_doc_counts: section order is the C collation, not the ambient locale's` | Section order is sorted explicitly under LC_ALL=C, not left to pathname expansion, and this pair is the one that caught it: bash sorts a glob by the AMBIENT collation, and under en_US the underscore is ignored at the primary level, so `logrotate_spec.bats` sorts BEFORE `log_spec.bats` while under C it sorts after. The generator runs in a musl container and on a glibc host, so the same untouched tree regenerated in the two places produced two byte sequences and the drift gate fired on a checkout nobody had edited. What this case can and cannot do: it pins the C order, which is the answer both runtimes must give. It cannot itself reproduce the disagreement, because musl collates by byte and the suite runs in the alpine test-tools image -- the discriminating run is the host one. |
| `_sync_doc_counts: rows follow spec file order, not alphabetical order` | Rows read the way the spec reads, so reordering a spec produces the matching doc diff instead of an unrelated scatter -- and the deliberate grouping of related cases survives into the catalogue. |
| `_sync_doc_counts: text outside the fence is left exactly as written` | Everything outside the fence is the author's, and the generator must not touch it -- that boundary is what lets the preamble hold prose no generator can write without becoming a merge surface again. |
| `_sync_doc_counts: FAILS naming the document when the generated fence is missing` | A catalogue that lost its fence must be an ERROR. Generating nothing into a document with no region is how a level silently stops being covered while the drift gate keeps reporting "in sync" -- the exact failure this whole mechanism exists to remove, one layer up. |
| `_sync_doc_counts: a second run over a generated catalogue changes nothing` | "Regenerating from scratch reproduces what is committed" is the gate check_test_md_drift.sh applies to the real tree, so a second run that moved a byte would make every branch red for a reason no diff explains. |
| `_sync_doc_counts: a shipped smoke spec lands in smoke.md` | A shipped smoke spec is the one level whose glob leaves test/ for dist/, and it was the case that caught the doc-to-glob map going stale before. It stays because the map is still hand-written. |
| `_sync_doc_counts: lowers the undescribed ceiling to what the tree measures` | The ordinary direction. A branch that describes tests should not also have to compute and hand-edit a number about the tree it just changed -- that hand-edit is the conflict this removes. |
| `_sync_doc_counts: REFUSES to raise the ceiling for a tree that breached it` | The load-bearing case. A generator that wrote whatever it measured would turn the ratchet into a mirror and the lint would stop bounding anything -- so a tree with MORE undescribed tests than the record leaves the record alone, and the breach reaches the lint. |
| `_sync_doc_counts: a regenerated tree that breached the ceiling still FAILS the lint` | The refusal proven where it matters -- through the lint, not just by reading the number back. A regeneration must not be a way to launder a breach into a green run, which is exactly what "the generator owns the ceiling" would mean if it wrote what it measured. |
| `_sync_doc_counts: a second run leaves an already-lowered ceiling alone` | Idempotence for the third figure. The drift gate is "regenerating reproduces what is committed", so a second run that moved this number would make every branch red for a reason no diff explains. |
| `_sync_doc_counts: FAILS naming the file when the ceiling cannot be read` | The number is a bound, so a value the reader cannot find is not a missing figure to fill in with a guess -- guessing high is a fail-open that silently unbounds the lint. A conflicted or hand-mangled record stops the generator instead. |
| `_sync_doc_counts: a root with no driver in it syncs the documents and skips the ceiling` | The generator runs against scratch trees that hold doc/test and the spec trees and nothing else -- the drift gate's copy and the resolver's two collapses. A root with no driver in it is those callers, not a broken checkout, so it is a skip and not a failure. |
| `_sync_doc_counts_outputs: names every file the generator writes, ceiling included` | What the resolver and the drift gate have to agree with the generator about is the OUTPUT SET, and a hand-kept second copy of it is the same defect one level up. The ceiling file is an output now, so it has to be in the answer. |

### test/bats/unit/dockerfile_migrate_spec.bats (116)

Unit tests for the declarative Dockerfile-migration list
`lib/dockerfile_migrate.sh` (#567, folds #579 facet B). The lib exposes a
small interface — `apply_migrations <dockerfile>` — over an ordered,
data-driven `_MIGRATIONS` table of `{detect, transform}` units, each healing
one v0.41.0-fanout Dockerfile/entrypoint breakage. upgrade.sh Step 5 sources
the lib and calls the dispatcher (replacing the old one-off seds). Each
migration is driven in isolation via before/after fixtures plus the
dispatcher's apply / skip / idempotency contract: a detected shape
auto-applies idempotently, a missing/ambiguous shape is skipped (warn, never
force-rewrite).

| Test | Description |
|------|-------------|
| `apply_migrations is the public dispatcher entry (#567)` | Small interface exists |
| `apply_migrations skips cleanly when path does not exist (#567)` | No-Dockerfile skip |
| `_MIGRATIONS is a non-empty ordered list (#567)` | Data-driven table is seeded |
| `migration 0 (downstream-to-dist): rewrites lib/wrapper COPY sources to .base/dist/ (#714)` | - |
| `migration 0 (downstream-to-dist): detect false when no .base/downstream/ reference (#714)` | - |
| `migration 0 (downstream-to-dist): idempotent — second run is a no-op (#714)` | - |
| `migration 1 (wrapper-copy): rewrites shape A 'COPY *.sh /lint/' (#567)` | - |
| `migration 1 (wrapper-copy): rewrites shape B 'COPY .base/script/docker/*.sh /lint/' (#567)` | - |
| `migration 1 (wrapper-copy): idempotent — second run is a no-op (#567)` | - |
| `migration 1 (wrapper-copy): the dispatcher lands shape A on the dist wrapper glob (#915)` | - |
| `migration 1 (wrapper-copy): detect is false when no legacy wrapper COPY present (#567)` | - |
| `migration 2 (pip-helper): drops the retired CONFIG_DIR pip install line (#567)` | - |
| `migration 2 (pip-helper): idempotent — no pip line means detect false (#567)` | - |
| `migration 2 (pip-helper): keeps a pip line whose requirements file carries real requirements (#956)` | - |
| `migration 2 (pip-helper): drops the line when the requirements file is comment/blank-only (#956)` | - |
| `migration 2 (pip-helper): keeps the line when the requirements file cannot be READ (#956)` | - |
| `migration 2 (pip-helper): an unreadable requirements file answers 2, not 1 (#956)` | - |
| `migration 2 (pip-helper): keeps the line when the pip directory cannot be traversed (#956)` | - |
| `migration 2 (pip-helper): an untraversable pip dir answers 2, an absent one 1 (#956)` | - |
| `migration 2 (pip-helper): keeps the line when a conf layer cannot be read (#956)` | - |
| `migration 2 (pip-helper): keeps the line when a conf layer's DIRECTORY cannot be read (#956)` | - |
| `migration 2 (pip-helper): keeps a pip line that closes a continued RUN (#956)` | - |
| `migration 2 (pip-helper): keeps a pip line that opens a continued RUN (#956)` | - |
| `migration 2 (pip-helper): the standalone check refuses a Dockerfile it cannot READ (#956)` | - |
| `migration 2 (pip-helper): keeps the line when the Dockerfile redirects CONFIG_SRC (#956)` | - |
| `migration 2 (pip-helper): keeps the line when .setup.conf redirects CONFIG_SRC (#956)` | - |
| `migration 2 (pip-helper): keeps the line when the TEMPLATE conf layer redirects CONFIG_SRC (#956)` | - |
| `migration 2 (pip-helper): keeps the line when the conf chain comes back truncated (#956)` | - |
| `migration 2 (pip-helper): keeps the line when a conf layer cannot be scanned (#956)` | - |
| `migration 2 (pip-helper): keeps the line when no config source dir is next to the Dockerfile (#956)` | - |
| `migration 3 (explicit-copy): drops single-line explicit top-level .sh COPY (#567)` | - |
| `migration 3 (explicit-copy): drops multi-line backslash-continued COPY block (#567)` | - |
| `migration 3 (explicit-copy): detect false when lint stage uses lib/wrapper dir COPYs only (#567)` | - |
| `migration 4 (logging-rename): rewrites the Dockerfile COPY to runtime/logging.sh (#567)` | - |
| `migration 4 (logging-rename): rewrites a sibling entrypoint source line (#567)` | - |
| `migration 4 (logging-rename): detect false when already on new name (#567)` | - |
| `migration 4 (logging-rename): heals a stale entrypoint when the Dockerfile is already migrated (#692)` | - |
| `migration (smoke-copy): rewrites the flat COPY into shared + the stage's own folder (#915)` | - |
| `migration (smoke-copy): emits only the shared baseline when the stage ships no folder (#915)` | - |
| `migration (smoke-copy): an unresolvable per-stage path costs the stage its own COPY (#956)` | - |
| `migration (smoke-copy): idempotent — detect false once already on the dist tree (#915)` | - |
| `migration (smoke-copy): rewrites a hand-listed spec to where the subtree ships it (#928)` | - |
| `migration (smoke-copy): rewrites every source of a multi-source hand-listed COPY (#928)` | - |
| `migration (smoke-copy): declines a hand-listed spec the subtree no longer ships (#928)` | - |
| `migration (smoke-copy): declines a hand-listed spec the subtree ships at two paths (#928)` | - |
| `migration (smoke-copy): heals hand-listed sources on a continuation line (#928)` | - |
| `migration (smoke-copy): detects a statement whose smoke sources are only on continuation lines (#928)` | - |
| `migration (smoke-copy): warns about an unresolvable spec on a continuation line (#928)` | - |
| `migration (smoke-copy): duplicates a continued wholesale COPY into shared + the stage's own folder (#928)` | - |
| `migration (smoke-copy): a .base/test/smoke-prefixed sibling path is not the retired tree (#928)` | - |
| `migration (flat-to-dist): rewrites the flat lint-stage lib/wrapper COPYs (#915)` | - |
| `migration (flat-to-dist): rewrites the flat config COPY (#915)` | - |
| `migration (flat-to-dist): idempotent — detect false on an already-dist Dockerfile (#915)` | - |
| `migration (flat-to-dist): dispatcher run twice rewrites exactly once (#915)` | - |
| `apply_migrations leaves no .base COPY source behind on the v0.41.0 shape (#915)` | - |
| `apply_migrations leaves every .base COPY source resolvable in the shipped tree (#969)` | - |
| `migration (runtime-moved-files): rewrites the smoke.sh source to the shipped test tree (#971)` | - |
| `migration (runtime-moved-files): rewrites the entrypoint.sh source at the pre-dist path (#971)` | - |
| `migration (runtime-moved-files): detect false once nothing names the old paths (#971)` | - |
| `migration (runtime-dir-copy): collapses the three per-file COPYs into one dir COPY (#971)` | - |
| `migration (runtime-dir-copy): collapses a subset in any order at the pre-dist path (#971)` | - |
| `migration (runtime-dir-copy): one dir COPY per stage, not one for the file (#971)` | - |
| `migration (runtime-dir-copy): a statement hand-listing two helpers collapses to one source (#971)` | - |
| `migration (runtime-dir-copy): a hand-relocated destination is preserved (#971)` | - |
| `migration (runtime-dir-copy): rewrites the commented runtime-stage example too (#971)` | - |
| `migration (runtime-dir-copy): an already-collapsed dir COPY is left alone (#971)` | - |
| `migration (runtime-dir-copy): dispatcher run twice collapses exactly once (#971)` | - |
| `migration (runtime-dir-copy): detect false when no helper COPY is present (#971)` | - |
| `apply_migrations heals the runtime COPYs every real consumer actually carries (#971)` | - |
| `migration 5 (hadolint): DL3007 pins bats/alpine :latest tags (#567)` | - |
| `migration 5 (hadolint): DL3046 adds useradd -l (#567)` | - |
| `migration 5 (hadolint): DL3003 cd /lint -> WORKDIR /lint + RUN (#567)` | - |
| `migration 5 (hadolint): DL3042 adds pip --no-cache-dir (#567)` | - |
| `migration 5 (hadolint): DL4006 adds SHELL pipefail to alpine lint-tools (#567)` | - |
| `migration 5 (hadolint): DL3006 inline ignore before parameterized FROM (#567)` | - |
| `migration 5 (hadolint): DL3006 idempotent — does not double-insert (#567)` | - |
| `migration 5 (hadolint): detect false on a clean Dockerfile (#567)` | - |
| `migration 6 (sc1090): broadens the entrypoint directive to SC1090,SC1091 (#567)` | - |
| `migration 6 (sc1090): idempotent when already SC1090,SC1091 (#567)` | - |
| `migration 6 (sc1090): detect false when no sibling entrypoint (#567)` | - |
| `migration 7 (arg-user): rewrites bare 'ARG USER' to default from USER_NAME (#579)` | - |
| `migration 7 (arg-user): idempotent — already defaulted is not detected (#579)` | - |
| `migration 7 (arg-user): does not touch an unrelated ARG (#579)` | - |
| `migration 8 (nounset-source): brackets the ROS source with set +u/-u (#579)` | - |
| `migration 8 (nounset-source): idempotent — already-guarded source untouched (#579)` | - |
| `migration 8 (nounset-source): detect false when no set -u in entrypoint (#579)` | - |
| `migration 8 (nounset-source): fires under the orchestrator when the bringup sets nothing (#945)` | The gap the branch's own README migration opens. Keying the guard on an in-file `set -u` covers nothing here -- the bringup seeded before this release has no `set` line at all, and the orchestrator imposes nounset from outside it. This is the FAILS-at-HEAD case; without it the migration stays silent on exactly the path base tells people to take |
| `migration 8 (nounset-source): brackets that bringup's source, directive and all (#945)` | Detecting is half of it; the write has to be correct for a file that never set nounset itself. The trailing `set -u` must RESTORE the mode the orchestrator was already in, which is checked by re-running detect on the rewritten file rather than by eyeballing the diff |
| `migration 8 (nounset-source): silent under the orchestrator with no ROS source (#945)` | Bounds the widened trigger. Now that an ENTRYPOINT can turn the migration on, the obvious over-reach is firing on the ENTRYPOINT alone -- which would bracket nothing and warn on every orchestrator repo for ever |
| `migration 8 (nounset-source): still silent pre-flip, where nothing imposes nounset (#945)` | The direction that would do harm rather than nothing. Pre-flip the repo's own file is the ENTRYPOINT and no nounset is in force, so writing a trailing `set -u` would TURN IT ON for the rest of a file that never asked -- a migration breaking the repo it was meant to protect |
| `migration (entrypoint-orchestrator): notices a repo still running its own entrypoint (#945)` | The positive case, on the shape every consumer repo is in today. A detect that never fires is a migration nobody is told about, and the adoption edits are the owner's to make |
| `migration (entrypoint-orchestrator): the notice changes nothing on disk (#945)` | The load-bearing claim of the whole release -- an existing repo comes out of `just upgrade` byte-identical and goes on working. Only the owner can tell a bringup line from base plumbing in a file hand-edited for a year, so an apply that rewrote anything here would break repos base cannot see. Both files are diffed, not just the Dockerfile |
| `migration (entrypoint-orchestrator): silent once the ENTRYPOINT is the orchestrator (#945)` | The notice has to stop. It runs on every `just upgrade` of every repo, so one that kept firing after the migration is one readers learn to ignore -- which costs the next migration its only channel |
| `migration (entrypoint-orchestrator): a commented ENTRYPOINT is not the live model (#945)` | Every repo generated from the shipped template carries a commented runtime-stage ENTRYPOINT, so a detect that read comments would fire on fully migrated repos for ever. The most likely wrong implementation is a plain grep, and this is the case that separates it from a correct one |
| `migration (entrypoint-orchestrator): an unrelated ENTRYPOINT is not this model (#945)` | A real repo in the org does this -- ros1_bridge's runtime stage runs the upstream image's /ros_entrypoint.sh. Detecting "an ENTRYPOINT that is not the orchestrator" instead of "the repo's own bringup" would nag that repo on every upgrade about a migration it has already made |
| `migration (bringup-residue): notices an exec left in a migrated repo's bringup (#945)` | The coupling between the two adoption edits, and the failure that hides. The orchestrator SOURCES the bringup, so a surviving exec fires mid-source: the watchdog never arms and the container looks healthy until the day it needed restarting |
| `migration (bringup-residue): notices a helper the orchestrator already sources (#945)` | The quieter half of the same residue. Sourced twice, logging.sh opens a SECOND per-start file and re-tees and watchdog.sh arms a second supervisor -- neither of which fails a build or a start, so nothing but this notice would ever surface it |
| `migration (bringup-residue): changes nothing on disk (#945)` | The warn-only claim for the residue pair specifically. This one is the more tempting to auto-fix -- deleting an exec line looks safe -- and it is not: the line may be the repo's own workload launch |
| `migration (bringup-residue): silent while the repo still owns the ENTRYPOINT (#945)` | Pre-flip the exec is CORRECT and the helper sources are the documented wiring, so this notice must be gated on the OTHER migration having happened. Ungated it would add a second warning to every upgrade of every un-migrated repo, about a file doing exactly what it should |
| `migration (bringup-residue): silent for a clean bringup (#945)` | The steady state after both edits. This is the shape every migrated repo upgrades in from then on, so a false positive here is a permanent notice on the correct outcome |
| `migration (bringup-residue): silent when the repo has no bringup at all (#945)` | A bringup is optional under the orchestrator, so the absent file is a supported shape and not an error. It is also the case a naive implementation turns into a stray grep diagnostic on stderr during an otherwise clean upgrade |
| `apply_migrations: an un-migrated repo keeps the entrypoint model it runs (#945)` | The claim a consumer actually cares about, asserted through the real dispatcher rather than the detect/apply pair: `just upgrade` as a whole leaves a repo running the model it was running. The pair-level tests cannot see a SIBLING migration rewriting the same files -- the sc1090 one does, which is why the entrypoint is compared over its code lines and the three surviving lines are named individually so an emptied file cannot pass |
| `migration 5 (hadolint): DL3007 pins alpine to the series this repo pins (#567)` | The series written into a consumer's Dockerfile is the one this repo builds, tests and dates |
| `migration 5 (hadolint): DL3007 leaves an already-pinned alpine alone (#567)` | Healing `:latest` is a lint fix; retagging a deliberate pin is not |
| `migration 5 (hadolint): DL3066 inline ignore before a literal USER root (#946)` | hadolint binds an ignore to the next LINE, so the pragma must sit directly above the instruction |
| `migration 5 (hadolint): DL3066 extends an existing pragma rather than displacing it (#946)` | The real downstream shape already has `# hadolint ignore=DL3002` there; inserting between would re-arm it |
| `migration 5 (hadolint): DL3066 idempotent — does not double-insert (#946)` | The migration pass runs on every upgrade, not once |
| `migration 5 (hadolint): DL3066 idempotent when merged into a sibling pragma (#946)` | The merge path needs its own proof; the insert path's says nothing about it |
| `migration 5 (hadolint): DL3066 leaves every non-root USER alone (#946)` | `root` resolves in every image by definition; any other literal name is the case the rule is worth having |
| `migration 5 (hadolint): DL3066 detect fires on an unguarded USER root (#946)` | Detect and apply must agree about which file is a candidate |
| `migration 5 (hadolint): DL3066 detect is quiet once the pragma is there (#946)` | A healed file must stop reporting as needing the migration |
| `migration 5 (hadolint): DL3046 adds -l when -u is not the first flag (#946)` | The shape downstream repos actually ship; the anchored match walked straight past it |
| `migration 5 (hadolint): DL3046 idempotent when -l already sits among the flags (#946)` | The flag can already be anywhere in the invocation, not only where the migration would put it |
| `migration 5 (hadolint): DL3046 leaves usermod -l alone (#946)` | The conflict-handling branch beside it is a different command; rewriting it would corrupt it |
| `migration 5 (hadolint): DL3046 detect sees the flags-before--u shape (#946)` | A detect blind to the shipped shape logs a patched Dockerfile with the finding still live |
| `migration 5 (hadolint): DL3046 heals a useradd whose own line also runs usermod -l (#946)` | A sibling flag after `&&` is not this command's flag; scanning to end of line left the finding live |

### test/bats/unit/dockerignore_spec.bats (11)

Unit tests for the `.dockerignore` canonical-sync helpers in
`script/docker/lib/gitignore.sh` (#604). `_canonical_dockerignore_entries`
delegates to `_canonical_gitignore_entries` (a derived artifact not worth
committing is not worth shipping in the build context, so the two share a
single source and never drift); `_sync_dockerignore` + `_sync_gitignore` are
thin wrappers over the shared `_sync_managed_entries` mechanism.

| Test | Description |
|------|-------------|
| `_canonical_dockerignore_entries: emits the derived-artifact set (#604)` | Membership |
| `_canonical_dockerignore_entries: shares the single canonical source with gitignore (no drift) (#604)` | Anti-drift invariant |
| `_canonical_dockerignore_entries: list is stable order (#604)` | Deterministic output |
| `_canonical_dockerignore_entries: includes log/ via the shared canonical source (#606) (#604)` | - |
| `_sync_dockerignore: creates the file when missing, with marker + all entries (#604)` | Greenfield |
| `_sync_dockerignore: file with all entries already present is a no-op (#604)` | Already-synced |
| `_sync_dockerignore: appends only missing entries when subset present (#604)` | Drift fill-in |
| `_sync_dockerignore: preserves hand-maintained build-context lines (#604)` | User-line preservation |
| `_sync_dockerignore: idempotent — second run leaves the file unchanged (#604)` | Idempotency |
| `_sync_dockerignore: marker added only once across re-syncs (#604)` | Single-marker invariant |
| `_sync_dockerignore: file without trailing newline gets one before append (#604)` | Trailing-newline guard |

### test/bats/unit/drift_spec.bats (4)

Mirrors `lib/drift.sh`. `_check_setup_drift` no-op / silent / non-zero paths
when the conf hash or GPU detection changes against a cached `.env`.

| Test | Description |
|------|-------------|
| `_check_setup_drift no-op when .env missing` | - |
| `_check_setup_drift silent when nothing changed` | - |
| `_check_setup_drift returns non-zero when conf hash changes` | - |
| `_check_setup_drift returns non-zero when GPU detection changes` | - |

### test/bats/unit/early_close_reader_lint_spec.bats (20)

| Test | Description |
|------|-------------|
| `_run_early_close_reader: FAILS on a pipeline into grep -q, naming file and line (#905)` | - |
| `_run_early_close_reader: FAILS on a clustered quiet flag (-qxF) (#905)` | - |
| `_run_early_close_reader: FAILS on a quiet flag that is not the first argument (#905)` | - |
| `_run_early_close_reader: FAILS on the long-form --quiet (#905)` | - |
| `_run_early_close_reader: FAILS on a pipeline into head, with or without -n (#905)` | - |
| `_run_early_close_reader: FAILS on a reader on its own continuation line (#905)` | - |
| `_run_early_close_reader: FAILS in base's own tooling tree, not just dist/ (#905)` | - |
| `_run_early_close_reader: PASSES a reader that drains the stream (grep -v, grep -c) (#905)` | - |
| `_run_early_close_reader: PASSES grep -q reading a FILE, which strands nobody (#905)` | - |
| `_run_early_close_reader: PASSES a logical OR that merely precedes grep -q (#905)` | - |
| `_run_early_close_reader: PASSES a here-string into grep -q (no writer process) (#905)` | - |
| `_run_early_close_reader: PASSES a comment that merely describes the shape (#905)` | - |
| `_run_early_close_reader: PASSES an in-shell drain (the shape the fixes use) (#905)` | - |
| `_run_early_close_reader: ignores non-.sh files and files outside the scanned trees (#905)` | - |
| `_run_early_close_reader: EXEMPTS a pipeline inside an allow-begin/allow-end region (#905)` | - |
| `_run_early_close_reader: FAILS on a pipeline AFTER an allow-end (region does not leak) (#905)` | - |
| `_run_early_close_reader: FAILS on an unterminated allow-begin region (#905)` | - |
| `_run_early_close_reader: FAILS on an allow-end with no matching allow-begin (#905)` | - |
| `_run_early_close_reader: FAILS when a scan root is missing (no vacuous pass) (#905)` | - |
| `_run_early_close_reader: the REAL shipped + tooling trees pass today (#905)` | - |

### test/bats/unit/entrypoint_logging_spec.bats (12)

Behaviour of `script/docker/_entrypoint_logging.sh` — the helper downstream
repos source from their `script/entrypoint.sh` so container stdout/stderr is
tee'd to the host bind-mounted log file when `[logging] local_path` is set
(#328). Tests source the helper under controlled `LOG_FILE_PATH` env in
subshells and assert both the host file content and the inherited stdout
(preserving `docker logs` parity).

| Test | Description |
|------|-------------|
| `entrypoint_logging is no-op when LOG_FILE_PATH unset (#328)` | Back-compat: do nothing |
| `entrypoint_logging writes a per-start file + points the stable symlink at it (#805)` | - |
| `entrypoint_logging second start adds a new per-start file + repoints symlink, keeps the old (#805)` | - |
| `entrypoint_logging same wall-clock second: second start bumps suffix, never truncates the first (#805)` | - |
| `entrypoint_logging captures stderr along with stdout in the per-start file (#328)` | 2>&1 redirect |
| `entrypoint_logging creates parent dir if missing (#328)` | mkdir -p safety net |
| `entrypoint_logging retention honors CONTAINER_LOG_KEEP, never the symlink (#805)` | - |
| `entrypoint_logging retention honors CONTAINER_LOG_DAYS by age (#805)` | - |
| `entrypoint_logging clamps a non-positive CONTAINER_LOG_KEEP back to the default (#805)` | - |
| `entrypoint_logging bumps past an occupied base per-start name, still tees (#805)` | - |
| `entrypoint_logging warns 'cannot create' + continues when parent dir is unmakeable (#691)` | mkdir-fail branch (parent is a regular file) |
| `entrypoint_logging warns 'tee binary missing' + continues when tee absent (#691)` | tee-missing branch (stub PATH) |

### test/bats/unit/entrypoint_spec.bats (10)

base's container ENTRYPOINT orchestrator, the base-owned half of the
two-file entrypoint model (ADR-00000032). It ships from `.base/dist/`, lands
at `/usr/local/lib/base/entrypoint.sh`, and SOURCES the repo-owned bringup
at `/entrypoint.sh` rather than executing it.

The subject is the ORDER, because each of the four steps depends on the one
before it: logging rebinds stdout/stderr, the bringup sets the env the
workload reads, the watchdog may take over the process, and the workload
execs last. The dispatcher takes its three paths as arguments so the REAL
function runs against a scratch tree; the frozen in-image literals live in
the file's bottom guard and are pinned separately.

| Test | Description |
|------|-------------|
| `orchestrator runs logging, then the bringup, then the watchdog, then the workload (#945)` | The load-bearing one. Every other ordering assertion is a consequence of this sequence, and a reordering that broke it would leave each step still working in isolation -- logging after the bringup loses the bringup's output, the watchdog before the bringup arms on stale knobs, and both stay green under a per-step test |
| `the watchdog sees a knob the bringup set, because bringup is sourced first (#945)` | The behavioural statement of the order rather than the positional one: a repo whose bringup decides WATCHDOG_CHECK is armed with that value. Arming the watchdog first disarms it silently, which no ordering assertion on printed lines would call wrong |
| `environment the bringup exports reaches the workload (#945)` | The whole point of sourcing rather than executing the bringup. Run as a child it would still print, still exit 0, and still lose every export -- the failure a repo only sees when its ROS overlay is missing from the running workload |
| `a non-executable bringup still runs, because it is sourced (#945)` | Nothing in the contract depends on the mode bit, and pinning that is what stops a later "just exec it" simplification from passing its own tests -- the shipped file happens to be COPY'd 0755, so the exec variant would look correct everywhere except a repo that ships its bringup 0644 |
| `a missing bringup and missing helpers still start the workload cleanly (#945)` | The shape most existing repos are actually in -- the runtime helper COPY is opt-in and a repo need not carry a bringup at all. Asserted with stderr separated and under the orchestrator's own strict mode, because the interesting failures here are a stray diagnostic and a nounset abort, neither of which changes the workload's exit status |
| `the workload's argv survives verbatim, spaces included (#945)` | The orchestrator sits between docker and CMD, so an unquoted `$@` anywhere in it re-splits the command a user typed. The embedded space is the only argument shape that catches that; a single-word workload passes through every wrong spelling |
| `executed directly with nothing installed, it still execs the workload (#945)` | The bottom guard driven for real instead of grepped. Every other test here calls the dispatcher with scratch paths, so nothing else exercises the frozen literals or the strict mode the shipped file turns on for itself -- and an image with none of the three installed is the ordinary pre-adoption shape, not a hypothetical |
| `executed directly, the orchestrator drives the in-image paths (#945)` | The Dockerfile contract in the one place it is spelled. The test above proves the guard RUNS but passes just as happily on a helper directory the Dockerfile never populates, so the two literals need pinning on their own: change one and the Dockerfile has to change with it |
| `the orchestrator ships with the executable bit set (#945)` | Its four runtime siblings are 644 because they are sourced; this one is executed. The Dockerfile's `COPY --chmod=0755` hides a committed 644, so nothing in a normal build goes red -- the file is simply not runnable from the subtree, and any consumer path that stops going through that COPY inherits an exit 126 |
| `the shared smoke baseline asserts the orchestrator's in-image path (#945)` | Joins the two files nothing else joins -- it reads the ENTRYPOINT out of the shipped Dockerfile and requires the shared build-time baseline to name that same path. Without it the half the container actually starts is asserted by nothing, and a dropped runtime-directory COPY stays invisible until a real container fails to come up |

### test/bats/unit/env_emit_spec.bats (27)

Mirrors `lib/env_emit.sh`. `write_env` (.env contents + SETUP_* metadata,
SSH X11 `XAUTHORITY` override #321) and `_scaffold_env_overlay` idempotency.

| Test | Description |
|------|-------------|
| `write_env emits XAUTHORITY=<rewritten> when _ssh_x11_xauth arg is set (#321)` | - |
| `write_env does NOT emit XAUTHORITY override when _ssh_x11_xauth arg is empty (#321)` | - |
| `write_env creates .env with all required variables and SETUP_* metadata` | - |
| `_scaffold_env_local is idempotent (never overwrites) (#868)` | - |
| `write_env emits PROJECT_NAME_PENDING only when a rename is deferred (#920)` | - |
| `_scaffold_env_local creates a comment-only override file naming .env (#868)` | - |
| `write_container_env emits the [environment] defaults it is given (#868)` | - |
| `write_container_env emits the WATCHDOG_* block into .env, not compose (#868)` | - |
| `write_container_env marks the file as ours and names .env.local (#868)` | - |
| `write_container_env rewrites the file on every call (it is ours) (#868)` | - |
| `write_container_env expands cross-references against the interpolation cache (#868)` | - |
| `write_container_env expands a cross-reference to an earlier sibling (#868)` | - |
| `write_container_env leaves a forward reference literal (#868)` | - |
| `write_container_env leaves an unknown reference literal (#868)` | - |
| `write_container_env expands multiple references in one value (#868)` | - |
| `write_container_env resolves a transitive reference chain (#868)` | - |
| `write_container_env quotes a value carrying an inline ' #' (#868)` | - |
| `write_container_env quotes a value carrying a colon-space (#868)` | - |
| `write_container_env passes a double quote and a backslash through (#868)` | - |
| `write_container_env escapes the delimiter inside a value (#868)` | - |
| `write_container_env keeps $ literal, unexpanded (#868)` | - |
| `_migrate_env_to_local renames a hand-written .env to .env.local (#868)` | - |
| `_migrate_env_to_local is inert on a second run (#868)` | - |
| `_migrate_env_to_local leaves a generated .env alone (#868)` | - |
| `_migrate_env_to_local leaves a comment-only scaffold alone (#868)` | - |
| `_migrate_env_to_local is a no-op when there is no .env (#868)` | - |
| `_migrate_env_to_local stages the removal when .env was git-tracked (#868)` | - |

### test/bats/unit/env_generated_claim_spec.bats (12)

| Test | Description |
|------|-------------|
| `just docker help: en setup summary names .env + .env.generated (#868)` | - |
| `just docker help: zh-TW setup summary names .env + .env.generated (#868)` | - |
| `just docker help: zh-CN setup summary names .env + .env.generated (#868)` | - |
| `just docker help: ja setup summary names .env + .env.generated (#868)` | - |
| `justfile.docker: the setup doc comment names .env + .env.generated (#868)` | - |
| `setup.sh --help: usage names .env + .env.generated (#868)` | - |
| `setup.sh set: the next hint names .env + .env.generated (#868)` | - |
| `setup.sh add: the next hint names .env + .env.generated (#868)` | - |
| `setup.sh remove: the next hint names .env + .env.generated (#868)` | - |
| `setup.sh env done message names .env.generated in all four locales (#868)` | - |
| `no shipped surface calls a bare .env hand-authored or a workload overlay (#868)` | - |
| `the shipped surfaces name .env.local as the override channel (#868)` | - |

### test/bats/unit/errexit_bang_lint_spec.bats (96)

| Test | Description |
|------|-------------|
| `_run_errexit_bang: FAILS on a non-final bang statement, naming file and line (#956)` | - |
| `_run_errexit_bang: FAILS on a bang statement buried mid-body (#956)` | - |
| `_run_errexit_bang: FAILS on a bang statement nested in a block (#956)` | - |
| `_run_errexit_bang: FAILS on the FIRST line of a continued bang statement that is not last (#956)` | - |
| `_run_errexit_bang: FAILS on a bang statement followed by another command via ';' (#956)` | - |
| `_run_errexit_bang: FAILS on a bang statement whose '\|\|' hands off the verdict (#956)` | - |
| `bash: a backgrounded '!' returns 0 whatever the command did (#956)` | Why `&` is a hand-off, run rather than asserted: an async list's status is the fork's |
| `_run_errexit_bang: FAILS on a bang statement handed to the background (#956)` | Inert in the one position the rule declines to judge -- the body's last statement |
| `_run_errexit_bang: FAILS when a '&' hands the statement to the next command (#956)` | The same discard as a `;`, spelled with the async operator |
| `_run_errexit_bang: FAILS on such a line even when the body continues past it (#956)` | - |
| `bash: a separator on the CONTINUATION line discards the negation too (#956)` | - |
| `_run_errexit_bang: FAILS when the ';' sits on a continuation line (#956)` | - |
| `_run_errexit_bang: FAILS when the '\|\| true' sits on a continuation line (#956)` | - |
| `_run_errexit_bang: FAILS when a BLANK line ends a continued bang statement (#956)` | bash joins the backslash-newline; the blank line ENDS the statement, and a statement judged nowhere is exempt from both rules |
| `_run_errexit_bang: FAILS when a COMMENT line ends a continued bang statement (#956)` | The same drop, spelled with a comment line |
| `_run_errexit_bang: PASSES when the blank line that ends a continued bang ends the BODY too (#956)` | The other direction: judging it there must not move its end line off the body's last statement |
| `bash: '! A && B' as the last statement still fails its test (#956)` | - |
| `bash: '! A \|\| return 1' DOES fail its test in the failing direction (#956)` | - |
| `_run_errexit_bang: PASSES on '\|\| return 1' / '\|\| fail', which CAN fail the test (#956)` | - |
| `_run_errexit_bang: still FAILS on '\|\| true' / '\|\| :', the operands that cannot fail (#956)` | - |
| `_run_errexit_bang: names a GROUP operand as unreadable, not as unfinished (#956)` | - |
| `_run_errexit_bang: PASSES on a ';' that sits in a trailing comment (#956)` | - |
| `_run_errexit_bang: PASSES on a ';' inside a quoted argument (#956)` | - |
| `_run_errexit_bang: FAILS on an '\|\|' that belongs to a command substitution (#956)` | A separator inside `( ... )` is the argument's, so the exemption for `! A \|\| B` does not reach it |
| `_run_errexit_bang: PASSES on a ';' that belongs to a command substitution (#956)` | The same flat match run the other way: a false positive on a blocking gate |
| `bash: '#' opens a comment only where a WORD opens (#956)` | The lexical rule the code scan implements, pinned by RUNNING the shell -- the `\|` spelling, the mid-word `#` that stays data, and the closing quote / backslash escape that continue a word |
| `bash: a ')' ends a word only when it closes a SUBSHELL (#956)` | The context-dependent half of the rule, run rather than asserted: a subshell's `)` ends a word, a `$( )` / `$(( ))` / `<( )` close does not |
| `bash: a backslash-newline SPLICES the text, so a '#' after it may be data (#956)` | - |
| `bash: an unfinished '\|\|', '&&' or '\|' continues onto the next line (#956)` | - |
| `_run_errexit_bang: PASSES on a bare trailing ';' followed by a comment (#956)` | `;#` is a terminator and prose, not a verdict handed to a second command |
| `_run_errexit_bang: PASSES on a comment that opens right after a ')' (#956)` | The same rule one metacharacter along |
| `_run_errexit_bang: FAILS on a ';' behind a '#' that follows a substitution's ')' (#956)` | That `)` leaves the word open, so the `#` is data and the separator behind it is real |
| `_run_errexit_bang: FAILS on a ';' behind a '#' that follows a FOLDED substitution's ')' (#956)` | - |
| `_run_errexit_bang: FAILS on a ';' behind a '#' inside a folded substitution (#956)` | - |
| `_run_errexit_bang: FAILS on a ';' behind an '\|\|' inside a folded substitution (#956)` | - |
| `_run_errexit_bang: PASSES on a ';' inside a folded substitution (#956)` | - |
| `_run_errexit_bang: FAILS on a ';' behind a '#' that follows a substitution, before a path (#956)` | - |
| `_run_errexit_bang: PASSES when a substitution spans lines with NO backslash (#956)` | - |
| `_run_errexit_bang: FAILS on a bang statement still open where the body closes (#956)` | - |
| `_run_errexit_bang: FAILS when an unreadable statement folds a '!' line into it (#956)` | - |
| `_run_errexit_bang: PASSES when an unreadable statement folds no '!' line in (#956)` | - |
| `_run_errexit_bang: FAILS on a ';' behind a '#' that follows a closing quote (#956)` | A closing quote does not end a word, so the `#` is data and the separator behind it is real |
| `_run_errexit_bang: FAILS on a ';' behind a '#' that follows an escape (#956)` | The same word rule for the other spelling that continues a word |
| `_run_errexit_bang: FAILS on a ';' behind a '#' spliced onto the word before it (#956)` | - |
| `_run_errexit_bang: PASSES when the splice leaves the '#' opening a word (#956)` | - |
| `_run_errexit_bang: FAILS on an '\|\| true' split across the operator (#956)` | - |
| `_run_errexit_bang: PASSES on a live '&&' split across the operator (#956)` | - |
| `_run_errexit_bang: PASSES on a pipeline split across its '\|' (#956)` | - |
| `_run_errexit_bang: FAILS on a ';' behind a pipeline split across its '\|' (#956)` | - |
| `_run_errexit_bang: FAILS on a ';' behind a '!' the operator fold pulled in (#956)` | The fold answers where a statement STARTS too: a `!` line read in as an operator's right operand is still judged, from the line it opens on |
| `_run_errexit_bang: FAILS on a '!' the fold pulled in that is not the body's last (#956)` | The position rule over the same fold |
| `_run_errexit_bang: FAILS on an async '&' behind a '!' the fold pulled in (#956)` | - |
| `_run_errexit_bang: FAILS on a '!' the fold pulled in that never finishes (#956)` | Reported as unfinished from the line the `!` opens on, not dropped as unreadable |
| `_run_errexit_bang: PASSES on a '!' the fold pulled in that IS the body's last (#956)` | Why a pulled-in `!` is judged rather than reported |
| `_run_errexit_bang: PASSES on a second '!' that is the first's '\|\|' operand, LAST (#956)` | - |
| `bash: a '!'-inverted RIGHT operand is exempt from errexit too (#956)` | - |
| `_run_errexit_bang: FAILS on '! A \|\| ! B' with a statement after it (#956)` | - |
| `_run_errexit_bang: FAILS on '! A \|\| ! B' written on ONE line (#956)` | - |
| `_run_errexit_bang: FAILS on a ';' behind '! A \|\| ! B' (#956)` | - |
| `_run_errexit_bang: FAILS on a '!' operand the '&&' arm short-circuits past (#956)` | - |
| `_run_errexit_bang: REPORTS a '!' operand chain that CAN still fail (#956)` | - |
| `_run_errexit_bang: PASSES on a bang statement with a bare trailing ';' (#956)` | - |
| `_run_errexit_bang: PASSES on the '&' spellings that background nothing (#956)` | `&&`, `2>&1`, `&>` and `\|&` are other operators; `[[ a&b ]]` is a syntax error and needs no exemption |
| `_run_errexit_bang: PASSES when the bang statement is the body's last (#956)` | - |
| `_run_errexit_bang: PASSES when only comments and blanks follow the bang (#956)` | - |
| `_run_errexit_bang: PASSES when the bang statement ends the body across a continuation (#956)` | - |
| `_run_errexit_bang: does not flag a bang that continues the previous line (#956)` | - |
| `_run_errexit_bang: does not flag a bang outside any test body (#956)` | - |
| `_run_errexit_bang: does not flag a commented-out bang (#956)` | - |
| `bash: a '!' that ends an 'if' body which ends the test body IS the verdict (base#991) (#956)` | - |
| `_run_errexit_bang: does not flag a '!' that ends a block which ends the body (base#991) (#956)` | - |
| `_run_errexit_bang: does not flag a '!' that ends a BRANCH of a block which ends the body (base#991) (#956)` | - |
| `_run_errexit_bang: still FLAGS a '!' buried earlier inside a block (base#991) (#956)` | - |
| `_run_errexit_bang: still FLAGS a '!' whose block is not the body's last statement (base#991) (#956)` | - |
| `_run_errexit_bang: a block the scan cannot balance reports every pending '!' (base#991) (#956)` | - |
| `_run_errexit_bang: REFUSES a *.bats with CRLF line endings, naming them (base#990) (#956)` | - |
| `_run_errexit_bang: the CRLF row is not silenced by an allow region (base#990) (#956)` | - |
| `_run_errexit_bang: FAILS on a ';' hand-off behind a live '\|\|' (base#992) (#956)` | - |
| `_run_errexit_bang: FAILS on a bang list whose final operand is an 'echo' (base#992) (#956)` | - |
| `_run_errexit_bang: FAILS on a bang list whose final operand is an unreadable group (base#992) (#956)` | - |
| `_run_errexit_bang: the widened always-zero set does not reach past the command word (base#992) (#956)` | - |
| `_run_errexit_bang: KNOWN MISS -- a ONE-LINE '{ ! A; }' brace group (base#991) (#956)` | - |
| `_run_errexit_bang: KNOWN OVER-REPORT -- a ';' behind an operand that transfers control (base#992) (#956)` | - |
| `_run_errexit_bang: FAILS when the repo holds no *.bats at all (#956)` | - |
| `_run_errexit_bang: FAILS when the spec directories are all empty (#956)` | - |
| `_run_errexit_bang: does NOT scan the released-tree archives (#956)` | - |
| `_run_errexit_bang: the clean line names every root it derived (#956)` | - |
| `_run_errexit_bang: FAILS on a body the parser opened and never closed (#956)` | - |
| `_run_errexit_bang: FAILS when a test header the parser never opened exists (#956)` | - |
| `_run_errexit_bang: FAILS on a violation in a bats tree outside test/bats (#956)` | - |
| `_run_errexit_bang: an allow region suppresses the finding (#956)` | - |
| `_run_errexit_bang: an allow region suppresses the unreadable-fold finding too (#956)` | - |
| `_run_errexit_bang: an allow region suppresses a folded-in '!' too (#956)` | - |
| `_run_errexit_bang: an unterminated allow region fails (#956)` | - |
| `_run_errexit_bang: an unmatched allow-end fails (#956)` | - |
| `_run_errexit_bang: the real bats tree is clean (#956)` | - |

### test/bats/unit/exec_sh_spec.bats (61)

Unit tests for `exec.sh` argument parsing, the container-running precheck,
and i18n. Sandbox tree mirrors build_sh_spec.bats; `docker ps` reads from a
controllable stub file so tests can toggle "container running" state without
a real docker daemon. `.env` is pre-seeded so `_load_env` /
`_compute_project_name` succeed without a bootstrap step.

Covers: `--help` (en/zh/zh-CN/ja), `--lang` / `--target` value validation,
English-default not-running error, Chinese / Simplified Chinese / Japanese
not-running error text, the `./run.sh` start hint (en + zh-TW), `--dry-run`
bypassing the guard, compose exec routing when container is running, **`--`
flag/CMD separator** (#289: standalone `--` consumed before CMD flows
through to `docker compose exec`, lets a dash-leading CMD pass through,
works after `-t TARGET` for run.sh parity, no-`--` positional path stays
backward-compatible, `-h` usage mentions `--`), fallback `_detect_lang`
branches when `template/` is absent, **`-C` / `--chdir` flag**
(docker_harness#53: redirect FILE_PATH so .env / project name come from the
alt repo, short + long form, value-required and directory guards, usage help
mention), **`-v` / `--verbose` / `-vv` / `--very-verbose` flag** (#311:
symmetry-only for exec since `docker exec` itself does not build, but flag
is accepted and `-vv` enables wrapper trace), and **`-T` / `--no-tty` + `-i`
/ `--tty` TTY-mode flags + auto-detect of `bash|sh|dash|zsh|ash|ksh -c
'...'`** (#382 Option 1+2: 17 assertions covering the no-CMD default (TTY),
interactive binary default (TTY), 4 shell flavours with `-c` auto-add `-T`,
`bash hello.sh` (no `-c`) keeps TTY, explicit `-T`/`--no-tty` forces no-TTY,
explicit `-i`/`--tty` overrides heuristic, last-wins precedence between `-T`
and `-i` in both orders, `-T` + `-t TARGET` attaches to the right service,
`-T` + `--` separator round-trip, `--help` mentions both flag pairs), and
**#690 exit-code forwarding + pre/post hook error paths** (the container
command's exit code is forwarded unchanged via `return "${_exec_rc}"` — 42 /
0 / 7 cases; a failing post-exec hook overrides the forwarded rc via `||
exit $?`; a failing pre-exec hook aborts before `compose exec` runs).

| Test | Description |
|------|-------------|
| `exec.sh --help exits 0 and shows usage` | - |
| `exec.sh --lang zh-TW prints Chinese usage text` | - |
| `exec.sh --lang zh-CN prints Simplified Chinese usage text` | - |
| `exec.sh --lang ja prints Japanese usage text` | - |
| `exec.sh --lang requires a value` | - |
| `exec.sh --target requires a value` | - |
| `exec.sh fails when container not running (default English)` | - |
| `exec.sh --lang zh-TW prints Chinese not-running error` | - |
| `exec.sh --lang zh-CN prints Simplified Chinese not-running error` | - |
| `exec.sh --lang ja prints Japanese not-running error` | - |
| `exec.sh prints start hint when container not running` | - |
| `exec.sh --lang zh-TW start hint translates` | - |
| `exec.sh --dry-run bypasses container-running check` | - |
| `exec.sh runs docker compose exec when the service is running` | - |
| `exec.sh -t <non-devel>: the precheck asks about the named service (#335)` | - |
| `exec.sh -t devel: the precheck asks about the devel service (parity, #335)` | - |
| `exec.sh: the precheck never names a reconstructed container (#920)` | - |
| `exec.sh -t <non-devel>: precheck passes when that service is running (#335)` | - |
| `exec.sh: another service being up does not satisfy the precheck (#920)` | - |
| `exec.sh: a probe still writing cannot make the precheck miss a running service (#905)` | - |
| `exec.sh -- separator: standalone -- is consumed, CMD flows through (#289)` | - |
| `exec.sh -- separator: lets a dash-leading CMD pass through (#289)` | - |
| `exec.sh -- separator: works after -t TARGET (run.sh parity, #289)` | - |
| `exec.sh: no -- still works for positional CMD (backward compat, #289)` | - |
| `exec.sh --help mentions the -- separator (#289)` | - |
| `exec.sh in /lint/ layout maps zh_TW.UTF-8 to zh-TW` | - |
| `exec.sh in /lint/ layout maps zh_CN.UTF-8 to zh-CN` | - |
| `exec.sh in /lint/ layout maps ja_JP.UTF-8 to ja` | - |
| `exec.sh -C <dir> redirects FILE_PATH to <dir>` | - |
| `exec.sh --chdir <dir> long form is equivalent to -C` | - |
| `exec.sh -C without a value exits 2` | - |
| `exec.sh -C with a non-existent directory exits 2` | - |
| `exec.sh -C is mentioned in usage help` | - |
| `exec.sh -v / --verbose / -vv / --very-verbose are mentioned in usage help (#311)` | - |
| `exec.sh -v --dry-run is accepted and exits 0 (#311)` | - |
| `exec.sh --verbose long form is accepted (#311)` | - |
| `exec.sh -vv --dry-run enables bash trace (set -x output on stderr) (#311)` | - |
| `exec.sh --dry-run with no CMD: no -T (default interactive bash entry, #382)` | - |
| `exec.sh --dry-run with interactive binary (htop): no -T (auto-detect doesn't fire, #382)` | - |
| `exec.sh --dry-run bash -c '...': auto-detect adds -T (#382 Option 2)` | - |
| `exec.sh --dry-run sh -c '...': auto-detect adds -T (#382 Option 2)` | - |
| `exec.sh --dry-run dash -c '...': auto-detect adds -T (#382 Option 2)` | - |
| `exec.sh --dry-run zsh -c '...': auto-detect adds -T (#382 Option 2)` | - |
| `exec.sh --dry-run bash hello.sh: no -T (no -c → not a one-shot, #382)` | - |
| `exec.sh --dry-run -T whoami: explicit -T forces no-TTY (#382 Option 1)` | - |
| `exec.sh --dry-run --no-tty long form forces no-TTY (#382)` | - |
| `exec.sh --dry-run -T env BAR=1 bash -c '...': covers auto-detect's heuristic gap (#382)` | - |
| `exec.sh --dry-run -i bash -c '...': explicit -i overrides heuristic (#382 Option 1)` | - |
| `exec.sh --dry-run --tty long form overrides heuristic (#382)` | - |
| `exec.sh --dry-run -T -i: last-wins gives TTY (#382)` | - |
| `exec.sh --dry-run -i -T: last-wins gives no-TTY (#382)` | - |
| `exec.sh --dry-run -T after -t TARGET still attaches to the right service (#382)` | - |
| `exec.sh --dry-run -- separator: -T propagates, CMD flows through (#382 + #289)` | - |
| `exec.sh --help mentions -T / --no-tty and -i / --tty flags (#382)` | - |
| `exec.sh forwards a non-zero container command exit code (#690)` | - |
| `exec.sh forwards exit code 0 on success (#690)` | - |
| `exec.sh forwards a distinct non-zero exit code unchanged (#690)` | - |
| `exec.sh post-exec hook failure overrides the forwarded rc (#690)` | - |
| `exec.sh runs the post-exec hook when the container command fails (#956)` | - |
| `exec.sh post-exec hook failure still overrides a non-zero container rc (#956)` | - |
| `exec.sh aborts on a failing pre-exec hook and skips compose exec (#690)` | - |

### test/bats/unit/generated_workflow_actions_lint_spec.bats (21)

| Test | Description |
|------|-------------|
| `generated-workflow-actions: fails when a generated ref is behind this repo's own (#950)` | The drift itself -- dependabot bumps the workflows and cannot reach the heredoc |
| `generated-workflow-actions: names the generated ref's file and line (#950)` | A bump proposal is actionable only if it says which line to edit |
| `generated-workflow-actions: passes when the two copies agree (#950)` | Lockstep is the whole assertion; the lint owns no opinion on which version is right |
| `generated-workflow-actions: a ref ahead of this repo's own fails too (#950)` | Direction-agnostic: a hand-edit past the workflows is the same defect, other sign |
| `generated-workflow-actions: ignores an interpolated ref (#950)` | This repo calling its OWN reusable workflow -- no literal to compare, upgrade.sh rewrites it |
| `generated-workflow-actions: ignores a uses: ref inside a shell comment (#950)` | Prose quoting a step is not a step; a lint that fails on its own docs gets muted |
| `generated-workflow-actions: a double-quoted generated ref is compared, not skipped (#950)` | - |
| `generated-workflow-actions: a single-quoted generated ref is compared, not skipped (#950)` | - |
| `generated-workflow-actions: a quoted ref to an action this repo never uses fails (#950)` | - |
| `generated-workflow-actions: one unreadable ref among readable ones still fails (#950)` | - |
| `generated-workflow-actions: a uses: value it cannot resolve fails by name (#950)` | - |
| `generated-workflow-actions: an unreadable value is reported as unreadable, not as an unused action (#950)` | - |
| `generated-workflow-actions: an action named with no ref is not called unused (#950)` | - |
| `generated-workflow-actions: a local ./ callee is skipped by name, not by accident (#950)` | - |
| `generated-workflow-actions: a docker:// container action is skipped by name (#950)` | - |
| `generated-workflow-actions: a quoted ref in this repo's own workflow is read too (#950)` | - |
| `generated-workflow-actions: ignores a generator under .prev-release/ (#950)` | A shipped release cannot be re-pinned, so scanning it fails a lint no edit can satisfy |
| `generated-workflow-actions: fails when this repo pins the action at two refs (#950)` | No answer to which ref the generated copy should carry, so it says so rather than guessing |
| `generated-workflow-actions: fails when this repo never uses the generated action (#950)` | No dependabot PR for the generated ref to inherit -- the bare form of the defect |
| `generated-workflow-actions: refuses a tree it found no generated ref in (#950)` | A renamed generator or a dead matcher must not read as lockstep |
| `generated-workflow-actions: the real repo is in lockstep (#950)` | Drives the live tree, so the fixtures cannot drift away from what ships |

### test/bats/unit/ghcr_cleanup_yaml_spec.bats (22)

Structural assertions for `.github/workflows/ghcr-cleanup.yaml`, the weekly
job that prunes untagged orphan digests from the base-owned `test-tools`
package on GHCR.

A scheduled job against a real registry cannot be exercised from here —
there is no local GHCR, and a real run's only honest test is a real run. So
the spec pins the workflow's SHAPE instead, on the theory that the ways this
goes catastrophically wrong are all edits to the file:

- **The footgun.** `actions/delete-package-versions` with
`delete-only-untagged-versions` calls anything the packages API reports as
untagged a candidate without opening a manifest, so it deletes the per-arch
children of a LIVE tag and `docker pull` starts 404ing. The spec asserts
neither the action nor that input appears in the file's code (the header
comment names both on purpose, to say why they are absent, so the assertions
run over comment-stripped lines).

- **The safety inputs.** `delete-untagged` is the only delete rule enabled,
`older-than` keeps a retention window, `exclude-tags` preserves the tags
downstream Dockerfiles pin, `validate` surfaces a lost platform child in the
log, and the tagged / partial-image rules stay off.

- **Dry-run defaults.** Enforcement is opt-in through the
`GHCR_CLEANUP_ENFORCE` repository variable, so a scheduled run deletes
nothing until a human has read a dry run. `dry-run` is resolved in a step
rather than an `a && b || c` expression, because that idiom collapses to `c`
exactly on the dispatch-with-dry-run-false branch.

- **Scope and pinning.** One owner, one package, no wildcard expansion; the
action pinned to an immutable commit SHA rather than a floating tag a third
party can move under a job holding `packages: write`.

| Test | Description |
|------|-------------|
| `ghcr-cleanup.yaml: never uses actions/delete-package-versions` | The unsafe action never returns: its untagged filter never opens a manifest |
| `ghcr-cleanup.yaml: never sets delete-only-untagged-versions` | The specific input that breaks live tags, named separately from the action |
| `ghcr-cleanup.yaml: uses the manifest-aware dataaxiom/ghcr-cleanup-action` | The action that resolves manifest references is the one in use |
| `ghcr-cleanup.yaml: pins the cleanup action to an immutable commit SHA` | A moved tag would hand deletion rights over our package to unreviewed code |
| `ghcr-cleanup.yaml: records the pinned action's version in a trailing comment` | Keeps the SHA readable; the form Dependabot rewrites on bump |
| `ghcr-cleanup.yaml: enables delete-untagged as the delete rule` | Untagged orphans are the only thing this job collects |
| `ghcr-cleanup.yaml: leaves the tagged-image delete rules off` | `delete-tags` / ghost / partial / orphaned can remove TAGGED versions: absent |
| `ghcr-cleanup.yaml: keeps a retention window via older-than` | Without it, a run overlapping a release eats the by-digest pushes pre-merge |
| `ghcr-cleanup.yaml: preserves the tags downstream consumers pin` | `latest`, `main` and the `v*` series are a strict preserve list |
| `ghcr-cleanup.yaml: enables the post-run multi-arch validate scan` | A lost platform child shows in the log, not at someone's `docker pull` |
| `ghcr-cleanup.yaml: dry-run is computed, never hardcoded false` | The rollout safety net cannot be removed by flipping one literal |
| `ghcr-cleanup.yaml: workflow_dispatch dry-run input defaults to true` | A manual run previews unless the operator asks otherwise |
| `ghcr-cleanup.yaml: scheduled runs stay dry until GHCR_CLEANUP_ENFORCE opts in` | An unfinished rollout costs sprawl, never a broken tag |
| `ghcr-cleanup.yaml: a dispatch deletes only on a literal false, not on anything-but-true` | Fail-safe, not fail-open: an unexpected input value resolves to dry-run |
| `ghcr-cleanup.yaml: resolves dry-run in a step, not an && \|\| expression` | `a && b \|\| c` collapses to `c` on the one branch that deletes |
| `ghcr-cleanup.yaml: targets exactly the test-tools package` | One owner, one package: the one base publishes and owns |
| `ghcr-cleanup.yaml: does not enable wildcard package expansion` | `expand-packages` would widen this to every package in the org |
| `ghcr-cleanup.yaml: runs on a cron schedule` | The job is scheduled, not merely dispatchable |
| `ghcr-cleanup.yaml: cron avoids the top of the hour` | GitHub delays scheduled runs that pile onto `:00` |
| `ghcr-cleanup.yaml: supports manual workflow_dispatch` | The dry-run review and one-off cleans need a manual entry point |
| `ghcr-cleanup.yaml: declares packages: write and no broader write scope` | Enough to delete package versions, no more |
| `ghcr-cleanup.yaml: serialises runs and never cancels one mid-delete` | Two actors mutating the package concurrently, or a killed delete, is not a state to design for |

### test/bats/unit/gitignore_spec.bats (47)

Unit tests for `template/script/docker/lib/gitignore.sh` — the canonical
`.gitignore` set + sync/untrack helpers introduced for issue #172.

| Test | Description |
|------|-------------|
| `_canonical_gitignore_entries: emits exactly the 12 canonical lines (#502, #507, #606, #832, #879, #893, #868)` | - |
| `_canonical_gitignore_entries: advertises .setup.conf.local again (#893)` | - |
| `no entry is both canonical and retired (#893)` | - |
| `_retired_gitignore_entries: retires nothing today (#893)` | - |
| `_sync_gitignore: a full sync leaves .setup.conf.local in the file, twice running (#893)` | - |
| `_sync_gitignore: prunes a retired entry from the managed block (#879)` | - |
| `_sync_gitignore: leaves a retired entry the user put ABOVE the marker alone (#879)` | - |
| `_prune_retired_entries: an early-closing reader cannot lose the managed marker (#905)` | - |
| `_sync_gitignore: pruning a retired entry is idempotent (#879)` | - |
| `_canonical_gitignore_entries: list is stable order` | Deterministic output |
| `_sync_gitignore: creates the file when missing, with marker block + all entries` | Greenfield |
| `_sync_gitignore: empty file gets marker block + all entries appended` | Empty file |
| `_sync_gitignore: file with all entries already present is a no-op` | Already-synced |
| `_sync_gitignore: appends only missing entries when subset already present` | Drift fill-in |
| `_sync_gitignore: preserves user-defined lines (bridge.yaml, .env.gpg, .claude/)` | User-line preservation |
| `_sync_gitignore: idempotent — second invocation produces no further changes` | Idempotency |
| `_sync_gitignore: no duplicate canonical lines after re-run` | No-dup invariant |
| `_sync_gitignore: documented constraint -- CRLF entries are not matched (LF-only) (#692)` | #692 LF-only presence-match constraint |
| `_sync_gitignore: ends with newline so future appends start on their own line` | Trailing-newline guarantee |
| `_untrack_canonical_in_repo: git rm --cached for tracked compose.yaml` | 15-repo drift fix |
| `_untrack_canonical_in_repo: leaves untracked files alone` | Scope guard |
| `_untrack_canonical_in_repo: no-op when no canonical files tracked` | Healthy-repo no-op |
| `_untrack_canonical_in_repo: handles tracked coverage/ directory` | Directory entry |
| `_untrack_canonical_in_repo: idempotent — second run succeeds without error` | Re-run safety |
| `_untrack_canonical_in_repo: untracks all canonical entries that match` | Multi-entry sweep |
| `_sync_logging_gitignore: tracer — relative local_path emitted in .gitignore (#402)` | - |
| `_sync_logging_gitignore appends relative local_path to .gitignore (#402, ex-#328)` | - |
| `_sync_logging_gitignore skips absolute paths (#402, ex-#328)` | - |
| `_sync_logging_gitignore skips ~ paths (#402, ex-#328)` | - |
| `_sync_logging_gitignore is idempotent (#402, ex-#328)` | - |
| `_sync_logging_gitignore: documented constraint -- a '..' traversal is wrapped verbatim (#692)` | #692 `..` path wrapped as-is |
| `_sync_logging_gitignore: documented constraint -- a space-bearing path is wrapped verbatim (#692)` | #692 space path wrapped as-is |
| `_sync_logging_gitignore collects from both global + per-svc (#402, ex-#328)` | - |
| `_sync_logging_gitignore is no-op when no local_path keys (#402, ex-#328)` | - |
| `_sync_logging_gitignore prunes stale managed entries on value change (#402, ex-#390)` | - |
| `_sync_logging_gitignore drops marker + entries when candidates become empty (#402, ex-#390)` | - |
| `_sync_logging_gitignore preserves user entries outside managed block (#402, ex-#390)` | - |
| `_sync_logging_gitignore: emits an explicit end marker bounding the block (#876)` | - |
| `_sync_logging_gitignore: preserves a user entry BELOW the managed block (#876)` | - |
| `_sync_logging_gitignore: user entry below the block survives a value change (#876)` | - |
| `_sync_logging_gitignore: an unterminated managed block is an error (#876)` | - |
| `_sync_logging_gitignore: an end marker with no begin marker is an error (#876)` | - |
| `_sync_logging_gitignore: migrates a legacy begin-marker-only block (#876)` | - |
| `_sync_logging_gitignore: legacy migration keeps a following canonical entry (#876)` | - |
| `_sync_logging_gitignore: legacy migration reports orphaned entries (#876)` | - |
| `_sync_managed_entries: appends without a spurious blank line (#876)` | - |
| `_sync_gitignore + _sync_logging_gitignore converge over repeated passes (#876)` | - |

### test/bats/unit/help_lang_spec.bats (20)

--help / --lang coverage across the recipe-backing scripts (#655,
ADR-00000011 §6). Runs each script directly (no `just`): asserts the
English-baseline usage on `-h`/`--help` (exit 0); the human-facing base /
template scripts (init / upgrade / completions / new) accept `--lang <code>`
and honor `SETUP_LANG`/`$LANG` via i18n.sh (validated, non-fatal fallback on
a bad value); and the machine/CI `test` namespace stays English-only
(rejects `--lang`). Namespace-level bare help + the `just`-driven forwarding
live in justfile_user_spec.bats.

| Test | Description |
|------|-------------|
| `test.sh --help exits 0 and prints usage` | English baseline usage |
| `test.sh -h exits 0 and prints usage` | short flag |
| `test.sh --help: the metric lints' verdict is the ceiling they judge by, not per-violation failure (base#994)` | The usage block is the only place a user is told what the three metric lints DO with a violation, and it is the copy that answers `--help` rather than a comment somebody has to go find. It promised a failure the driver stopped delivering when base#994 phase 3 gave each lint an adoption ceiling: the run prints every function over an implementation standard and still exits 0 while the count is under the ceiling, so a reader of this text believes a green run could not have contained one. The assertion reads the COLLAPSED text because the block is line-wrapped, and the wrapping is not the property. |
| `init.sh --help exits 0 and prints usage` | base ns usage |
| `upgrade.sh --help exits 0 and prints usage` | base ns usage |
| `completions.sh --help exits 0 and prints usage` | base ns usage |
| `completions.sh -h exits 0 and prints usage` | short flag |
| `new.sh --help exits 0 and prints usage (#655: gained -h/--help)` | #655 -- new.sh gained -h/--help |
| `new.sh -h exits 0 and prints usage` | short flag |
| `init.sh --help advertises --lang (#655 i18n namespace)` | i18n namespace |
| `upgrade.sh --help advertises --lang (#655 i18n namespace)` | i18n namespace |
| `completions.sh --help advertises --lang (#655 i18n namespace)` | i18n namespace |
| `new.sh --help advertises --lang (#655 i18n namespace)` | i18n namespace |
| `init.sh accepts a valid --lang without error (flag is stripped)` | flag stripped before dispatch |
| `upgrade.sh accepts a valid --lang without error` | flag stripped before dispatch |
| `completions.sh accepts a valid --lang without error` | flag accepted |
| `new.sh accepts a valid --lang and still scaffolds` | flag + positional name |
| `init.sh --lang bogus warns and falls back to en (non-fatal)` | _sanitize_lang fallback |
| `completions.sh --lang bogus warns and falls back to en (non-fatal)` | _sanitize_lang fallback |
| `test.sh rejects --lang (test namespace is English-only, #655)` | machine/CI namespace, no i18n |

### test/bats/unit/home_literal_lint_spec.bats (18)

Unit coverage for `script/test/drivers/home_literal.sh` -- the mechanical
half of the "bake self-built artifacts at `/opt`, not under `$HOME`"
convention (ADR-00000024). The container user is a BUILD arg, so a concrete
username in a shipped Dockerfile / entrypoint / in-image config file breaks
the moment the image is rebuilt or `docker save`+`load`'ed under a different
`USER_NAME`. The parameterised `${USER_NAME}` / escaped `\${USER_NAME}` /
`<placeholder>` forms and absolute `/opt` paths pass; a narrative mention
opts out through a bracketed allow region that must be balanced and does not
leak past its end; a missing scan root fails loudly instead of passing
vacuously; and a final case drives the REAL shipped tree.

| Test | Description |
|------|-------------|
| `_run_home_literal: FAILS on a hardcoded home path in the shipped Dockerfile, naming file and line (#799)` | - |
| `_run_home_literal: FAILS on a hardcoded home path in a runtime entrypoint (#799)` | - |
| `_run_home_literal: FAILS on a hardcoded home path in a non-.sh in-image config file (#799)` | - |
| `_run_home_literal: FAILS on a hardcoded home path inside a comment too (#799)` | - |
| `_run_home_literal: names the offending literal in the failure message (#799)` | - |
| `_run_home_literal: points at the /opt convention in the failure message (#799)` | - |
| `_run_home_literal: scans the repo-root dockerfile/ tree too (#799)` | - |
| `_run_home_literal: FAILS on a literal AFTER an allow-end (region does not leak) (#799)` | - |
| `_run_home_literal: FAILS on an unterminated allow-begin region (#799)` | - |
| `_run_home_literal: FAILS on an allow-end with no matching allow-begin (#799)` | - |
| `_run_home_literal: PASSES the ${USER_NAME} build-arg form (#799)` | - |
| `_run_home_literal: PASSES the backslash-escaped \${USER_NAME} form (#799)` | - |
| `_run_home_literal: PASSES the angle-bracket placeholder form (#799)` | - |
| `_run_home_literal: PASSES an absolute /opt artifact path (#799)` | - |
| `_run_home_literal: EXEMPTS a literal inside an allow-begin/allow-end region (#799)` | - |
| `_run_home_literal: ignores files OUTSIDE the shipped tree (#799)` | - |
| `_run_home_literal: FAILS when a scan root is missing (no vacuous pass) (#799)` | - |
| `_run_home_literal: the REAL shipped tree passes today (#799)` | - |

### test/bats/unit/hook_spec.bats (8)

Unit tests for the pre/post user-hook runners (`_run_pre_hook` /
`_run_post_hook`, #440): presence + executable-bit gating, exit-code
forwarding for caller abort, and DRY_RUN skip.

| Test | Description |
|------|-------------|
| `_run_pre_hook: returns success when no hook file present (#440)` | Absent hook is a no-op |
| `_run_pre_hook: present + +x + exit 0 -> runs and forwards args (#440)` | Runs and forwards argv |
| `_run_pre_hook: hook exit 7 -> helper returns 7 for caller to abort (#440)` | Exit-code propagation (pre) |
| `_run_post_hook: hook exit 11 -> helper returns 11 (#440)` | Exit-code propagation (post) |
| `_run_pre_hook: present but not executable -> hard fail with clear msg (#440)` | Non-exec hard fail (pre) |
| `_run_post_hook: present but not executable -> hard fail with clear msg (#440)` | Non-exec hard fail (post) |
| `_run_pre_hook: DRY_RUN=true -> hook skipped silently (#440)` | DRY_RUN skip (pre) |
| `_run_post_hook: DRY_RUN=true -> hook skipped silently (#440)` | DRY_RUN skip (post) |

### test/bats/unit/i18n_orphan_lint_spec.bats (22)

| Test | Description |
|------|-------------|
| `_run_i18n_orphan: FAILS on an env-var identifier in a fenced block that the English README never mentions (#902)` | - |
| `_run_i18n_orphan: FAILS on an env-var identifier in an INLINE code span, which a fence-only scan walks past (#902)` | - |
| `_run_i18n_orphan: FAILS on a long option the English README never mentions (#902)` | - |
| `_run_i18n_orphan: reports EVERY translation that carries an orphan, not just the first (#902)` | - |
| `_run_i18n_orphan: names both readings and the opt-out in the failure message (#902)` | - |
| `_run_i18n_orphan: PASSES when the identifier appears in English PROSE without backticks (#902)` | - |
| `_run_i18n_orphan: PASSES on an identifier-shaped token in translation prose OUTSIDE any code span (#902)` | - |
| `_run_i18n_orphan: PASSES on a path-shaped token absent from the English README (#902)` | - |
| `_run_i18n_orphan: PASSES on a bare '--' separator and on a lone hyphenated word (#902)` | - |
| `_run_i18n_orphan: does NOT flag a longer identifier as a match for a shorter English one (#902)` | - |
| `_run_i18n_orphan: an allow region suppresses the finding inside it (#902)` | - |
| `_run_i18n_orphan: FAILS on an orphan AFTER an allow-end (the region does not leak) (#902)` | - |
| `_run_i18n_orphan: FAILS on an unterminated allow-begin (#902)` | - |
| `_run_i18n_orphan: FAILS on an allow-end with no open allow-begin (#902)` | - |
| `_run_i18n_orphan: DIES when README.md is missing rather than passing vacuously (#902)` | - |
| `_run_i18n_orphan: DIES when the translation directory is missing (#902)` | - |
| `_run_i18n_orphan: DIES when the translation directory holds no translation (#902)` | - |
| `_run_i18n_orphan: DIES when the English README yields no identifier at all (#902)` | - |
| `_run_i18n_orphan: DIES when no translation yields a single scanned token (#902)` | - |
| `_run_i18n_orphan: catches the removed per-instance mechanism verbatim, as it stood before the hand fix (#902)` | - |
| `_run_i18n_orphan: catches the retired argv shim verbatim, as it stood before the hand fix (#902)` | - |
| `_run_i18n_orphan: the real repo tree carries no translation-only identifier (#902)` | - |

### test/bats/unit/init_existing_repo_signals_spec.bats (6)

| Test | Description |
|------|-------------|
| `init.sh --list-existing-repo-signals prints a non-empty list and exits 0` | The floor the rest of the mechanism stands on -- a discriminator that cannot be asked at all leaves the branch condition in the middle of `main` as its only statement, which is the state base#928 shipped in. |
| `init.sh --list-existing-repo-signals names the Dockerfile proxy (#928)` | The one signal that has already inverted is stated by name, so the template's shipped-file guard has something concrete to collide with rather than an empty list it can satisfy vacuously. |
| `init.sh --list-existing-repo-signals emits repo-relative paths only` | A consumer joins each entry onto its own repo root, so an absolute path, a trailing slash or a `.base/`-internal path names something the downstream checker cannot test and the guard silently covers nothing. |
| `init.sh --list-existing-repo-signals output is sorted and free of duplicates` | A stable, duplicate-free order is what lets a consumer compare the list with a plain `diff` across two base versions; without it every reader has to normalise first, and each reader normalises differently. |
| `init.sh --list-existing-repo-signals mutates nothing and never leaves its cwd` | The load-bearing one for asking base about itself: the answer has to come before the template self-run guard and before `cd "${REPO_ROOT}"`, or querying the discriminator would scaffold the checkout being queried. |
| `init.sh --help names --list-existing-repo-signals` | A query nobody can find is one nobody derives from, and a checker that restates the discriminator instead of reading it is the second statement this flag exists to remove. |

### test/bats/unit/init_installed_paths_spec.bats (6)

| Test | Description |
|------|-------------|
| `init.sh --list-installed-paths prints a non-empty manifest and exits 0` | - |
| `init.sh --list-installed-paths lists the base version monitor workflow` | - |
| `init.sh --list-installed-paths lists the wrapper symlinks and hook stubs` | - |
| `init.sh --list-installed-paths emits repo-relative paths only` | - |
| `init.sh --list-installed-paths output is sorted and free of duplicates` | - |
| `init.sh --list-installed-paths mutates nothing and never leaves its cwd` | - |

### test/bats/unit/init_spec.bats (69)

Unit coverage for `init.sh` helpers that previous rounds exercised only
through the Level-1 integration test. Complements
`test/bats/integration/init_new_repo_spec.bats` by locking edge cases that
are hard to trigger from a real `bash template/init.sh` invocation
(network-down version detection, main.yaml `@ref` fallback,
`_create_version_file` with no argument).

| Test | Description |
|------|-------------|
| `_detect_template_version: parses newest vX.Y.Z tag from git ls-remote` | Happy path + head -1 |
| `_detect_template_version: returns empty when git ls-remote fails` | Network-down fallback |
| `_detect_template_version: returns empty when no v*.*.* tags exist` | Nothing to match |
| `_detect_template_version: ignores non-semver tags (e.g. rc suffixes)` | Regex filters rc / pre-release |
| `_detect_template_version: an early-closing reader cannot empty the tag scan (#905)` | - |
| `_detect_template_version: reads .version file when present (no network)` | .version file priority |
| `_detect_template_version: .version file takes priority over git ls-remote` | Local-first resolution |
| `_create_new_repo: main.yaml uses given ref in workflow @ref` | Ref threading |
| `_create_new_repo: main.yaml falls back to @main when ref arg omitted` | Default ref |
| `_create_new_repo: main.yaml falls back to @main when ref arg is empty` | Empty-string → `@main` |
| `_create_new_repo: does NOT generate .env.example (image name via setup.conf)` | setup.conf rules drive IMAGE_NAME |
| `_create_symlinks: places 7 wrapper symlinks under script/ (#330)` | 7 wrappers under script/ with ../ targets; justfile at root, no Makefile |
| `_create_symlinks: places justfile at root with the direct .base/ target (#545)` | root justfile -> .base/script/docker/justfile |
| `_create_symlinks: does NOT symlink Makefile and cleans a stale root Makefile symlink (#546)` | Makefile retired; stale symlink dropped on upgrade |
| `_create_symlinks: replaces a stale file at the new symlink path under script/ (#330)` | Re-init over stale file at script/build.sh |
| `_create_symlinks: removes stale root *.sh symlinks left by pre-#330 init (#330 migration loop)` | Migration: plant 7 root symlinks, re-run, all gone + script/ created |
| `_create_symlinks: keeps custom .hadolint.yaml when it differs` | Custom-hadolint preservation |
| `_gen_setup_conf default refuses to overwrite existing setup.conf` | - |
| `_gen_setup_conf --force overwrites and backs up existing setup.conf` | - |
| `_gen_setup_conf --force also backs up .env to .env.bak` | - |
| `_gen_setup_conf errors when the template setup.conf is absent (#692)` | #692 missing-template _error |
| `_gen_setup_conf --force on clean repo does not create spurious .bak` | - |
| `TEMPLATE_REL: auto-detects to '.base' when init.sh lives in .base/` | - |
| `TEMPLATE_REL: re-sourcing init.sh from .base/ keeps detection stable` | - |
| `_create_symlinks: targets follow TEMPLATE_REL through .base/ (#330 script/ subfolder)` | - |
| `_create_new_repo: .gitignore includes .setup.conf.bak and .env.bak` | - |
| `_create_hook_stubs: creates script/hooks/{pre,post}/ with 14 stubs (#440)` | - |
| `_create_hook_stubs: each stub starts with shebang and ends with exit 0 (#440)` | - |
| `_create_hook_stubs: idempotent — preserves user-modified stub on re-run (#440)` | - |
| `_create_new_repo: includes hook stubs in new-repo layout (#440)` | - |
| `_init_existing_repo: creates missing hook stubs on upgrade (#440)` | - |
| `_sync_base_monitor_workflow: generates base-version-monitor.yaml` | - |
| `_sync_base_monitor_workflow: schedules weekly + manual dispatch` | - |
| `_sync_base_monitor_workflow: grants issues: write` | - |
| `_sync_base_monitor_workflow: runs the subtree-shipped checker via prefix` | - |
| `_sync_base_monitor_workflow: idempotent — never clobbers a user-tuned file` | - |
| `_create_new_repo: also generates base-version-monitor.yaml` | - |
| `_init_existing_repo: heals a Dockerfile still naming the pre-dist layout (#915)` | - |
| `_init_existing_repo: leaves an already-migrated Dockerfile untouched (#915)` | - |
| `_init_existing_repo: syncs base-version-monitor.yaml on upgrade (#777)` | - |
| `_preflight_just: warns and exits 0 when just is absent (#607)` | Missing runner -> non-fatal WARN |
| `_preflight_just: emits the init_just_missing event under LOG_FORMAT=json (#607)` | Structured event wired through |
| `_preflight_just: install hint points at the documented methods (#607)` | Warning carries install pointer |
| `_preflight_just: the install hint quotes the pin and calls package managers a fallback (#948)` | - |
| `_just_install_hint: degrades to a placeholder when the pin cannot be read (#948)` | - |
| `_preflight_just: silent and exits 0 when just is present (#607)` | Runner present -> no warning |
| `_bootstrap_just: no-op when just is already on PATH (#607)` | Opt-in bootstrap skips when installed |
| `_bootstrap_just: runs the official installer into ~/.local/bin when absent (#607)` | Opt-in installer pipeline to ~/.local/bin |
| `_bootstrap_just: installs the pinned version, not whatever is latest (#948)` | - |
| `_bootstrap_just: refuses to install anything when the pin cannot be resolved (#948)` | - |
| `_bootstrap_just: aborts with a clear error when the installer pipeline fails (#692)` | #692 installer-failure _error path |
| `_call_setup: warns but returns 0 when setup.sh exits non-zero (#692)` | #692 warn-on-failure degrade |
| `_call_setup: skips with a notice when setup.sh is absent (#692)` | #692 skip-when-absent branch |
| `_call_setup: returns 0 on a setup.sh that succeeds (#692)` | #692 happy path no-noise |
| `_smoke_test_count: sums ^@test across the per-stage smoke tree (S4 item 6)` | - |
| `_smoke_test_count: returns 0 when the smoke tree has no specs (S4 item 6)` | - |
| `_error: carries a registered event id under LOG_FORMAT=json (#876)` | - |
| `_error: text output is framed like every other init record (#876)` | - |
| `_error: the human message rides the display attribute (#876)` | - |
| `_init_protected_paths: covers the .env pair the env-naming rename moves (#937)` | - |
| `_init_protected_paths: covers every root the resync writes into (#937)` | - |
| `_init_restore_tree: an .env moved to .env.local is put back (#937)` | - |
| `_init_restore_tree: removes what the resync created (#937)` | - |
| `_init_restore_tree: restores a rewritten file byte for byte (#937)` | - |
| `_init_restore_tree: refuses to delete when its snapshot copy is missing (#937)` | - |
| `_init_existing_repo: hands back the caller's EXIT trap on success (#937)` | - |
| `_populate_config: the seeded placeholder names the config/<component>/ channel` | the seeded text names the structured channel |
| `_populate_config: the seeded placeholder still names the build-time overlay` | the seeded text keeps the build-time channel |
| `_populate_config: the seeded placeholder and ADR-00000030 name the convention identically` | seeded text and the record use one vocabulary |

### test/bats/unit/issueref_lint_spec.bats (20)

| Test | Description |
|------|-------------|
| `_run_issueref: flags a bare #NNN in a leading comment` | Leading comment ref detected |
| `_run_issueref: flags a bare #NNN in a trailing comment` | Trailing comment ref detected |
| `_run_issueref: flags the (#NNN) paren form in a comment` | Parenthesised ref detected |
| `_run_issueref: flags a bare 2-digit ref (lower accept boundary) (#692)` | #692 2-digit lower bound flagged |
| `_run_issueref: flags a bare 4-digit ref (upper accept boundary) (#692)` | #692 4-digit upper bound flagged |
| `_run_issueref: flags refs in .bats helper comments (not @test names)` | Helper comment flagged, @test name kept |
| `_run_issueref: does NOT flag a ref inside a '# why:' block in a .bats spec` | The `# why:` block is CATALOGUE PROSE authored at the site it describes and rendered into doc/test/*.md -- the same artifact class as the `@test` name below it, which this lint has always skipped. That prose used to live in a document this lint does not scan, and 147 of the sentences the migration moved name the issue they came from: if moving where a sentence is STORED changed whether it may say `#NNN`, the migration could only have landed by rewording them. |
| `_run_issueref: still flags a ref in an ordinary comment AFTER a '# why:' block` | The exemption is the BLOCK, not the file and not the token. It ends at the first non-comment line exactly as spec-markers.sh ends it, so an ordinary helper comment further down the same spec is still scanned -- otherwise one marker anywhere would switch the lint off for the file. |
| `_run_issueref: DOES flag a ref in a '# why:' comment in a .sh file` | A `# why:` in a shell script is a comment like any other. The exemption is scoped to `.bats` because that is where the marker grammar is read; widening it to every file would turn one spelling into a general opt-out from ADR-00000013. |
| `_run_issueref: passes clean on a tree with no comment refs` | Clean tree passes |
| `_run_issueref: does NOT flag a #NNN inside a string literal` | String-literal ref kept |
| `_run_issueref: does NOT flag ADR-0000xxxx references` | ADR refs kept |
| `_run_issueref: does NOT flag DL/SC directive codes or version tags` | DL/SC/version tokens kept |
| `_run_issueref: does NOT flag word-prefixed cross-repo refs` | Cross-repo refs kept |
| `_run_issueref: does NOT flag single-digit or 5+-digit numbers` | Out-of-range numbers kept |
| `_run_issueref: does NOT treat a ${#arr[@]} expansion as a comment` | Parameter expansion kept |
| `_run_issueref: does NOT flag a #NNN opener in heredoc usage prose` | Heredoc usage prose kept |
| `_ISSUEREF_AWK: flags a 3-digit ref identically under every awk engine` | Detection parity across busybox-awk / mawk / gawk |
| `_ISSUEREF_AWK: flags the 2-digit and 4-digit accept boundaries under every awk engine (#692)` | #692 boundary parity across engines |
| `_ISSUEREF_AWK: keeps the must-keep cases clean under every awk engine` | Exemption parity across busybox-awk / mawk / gawk |

### test/bats/unit/just_provenance_lint_spec.bats (24)

| Test | Description |
|------|-------------|
| `just provenance: a tree whose every site names the pin is clean (#948)` | - |
| `just provenance: setup-just with no just-version input is a finding (#948)` | - |
| `just provenance: the just.systems installer with no --tag is a finding (#948)` | - |
| `just provenance: a pinned release URL that drops the version arg is a finding (#948)` | - |
| `just provenance: a package-manager install of just needs an advisory marker (#948)` | - |
| `just provenance: a package-manager install inside a justified advisory region is allowed (#948)` | - |
| `just provenance: an advisory region with no stated reason is a finding (#948)` | - |
| `just provenance: an unterminated advisory region is a finding (#948)` | - |
| `just provenance: an unmatched advisory-end is a finding (#948)` | - |
| `just provenance: a step cannot borrow the NEXT step's just-version input (#948)` | - |
| `just provenance: the installer cannot borrow a --tag from a later command (#948)` | - |
| `just provenance: the installer cannot borrow a --tag from a command chained onto its own line (#948)` | - |
| `just provenance: a --tag after a ';' on a continued line is not the installer's either (#948)` | - |
| `just provenance: a second acquisition on one logical line is its own site (#948)` | - |
| `just provenance: the hidden second acquisition is found in either order (#948)` | - |
| `just provenance: a pinned release URL still counts when the version arg is on the same logical line (#948)` | - |
| `just provenance: an advisory region does not mute a mechanism that CAN be pinned (#948)` | - |
| `just provenance: a pointer to the project's homepage is not an acquisition site (#948)` | - |
| `just provenance: a missing scan root fails rather than passing vacuously (#948)` | - |
| `just provenance: an empty scan root fails rather than passing vacuously (#948)` | - |
| `just provenance: a tree with no provenance site at all fails vacuously-closed (#948)` | - |
| `just provenance: a tree where nothing is pinned fails vacuously-closed (#948)` | - |
| `just provenance: pin evidence on a backslash continuation still counts (#948)` | - |
| `just provenance: the live tree passes its own lint (#948)` | - |

### test/bats/unit/just_version_spec.bats (9)

| Test | Description |
|------|-------------|
| `just version: declared exactly once, as a semver ARG in the tooling Dockerfile (#948)` | - |
| `just version: the tooling image fetches the pinned release, never a bare apk add (#948)` | - |
| `just-version.sh: prints the declared pin (#948)` | - |
| `just-version.sh: reads its own tree, not the caller's cwd (#948)` | - |
| `just-version.sh: fails loud when the declaration file is gone (#948)` | - |
| `just-version.sh: fails loud when the declaration is duplicated (#948)` | - |
| `just-version.sh: fails loud when the declaration is empty (#948)` | - |
| `self-test.yaml: setup-just is pinned from the accessor, not left to install latest (#948)` | - |
| `release-test-tools.yaml: the just smoke check asserts the version, not exit 0 (#948)` | - |

### test/bats/unit/justfile_spec.bats (16)

Static content checks for the layered just entry (ADR-00000005 / #545,
ADR-00000010; ADR-00000011: docker + base are `mod?` namespaces, not a
top-level import). The entry `dist/script/justfile` mods the docker + base
modules; docker verbs forward 1:1 to `./script/<name>.sh` via `{{args}}`,
base verbs to `./.base/upgrade.sh`. Asserted by grep, not execution --
`just` is not in the test-tools image; downstream installs it.

| Test | Description |
|------|-------------|
| `layered entry + docker module exist` | both files present |
| `docker module declares args-passthrough recipes for every wrapper verb (#545)` | build/run/exec/stop/prune/setup/setup-tui `*args` |
| `docker module no longer carries upgrade/upgrade-check (moved to base ns, #652)` | #652 -- upgrade is a .base op |
| `docker module recipes forward to ./script/<wrapper>.sh with {{args}} (#545)` | forwarding bodies |
| `base module declares upgrade + update (apt-aligned) forwarding to .base/dist/script/base/upgrade.sh (#652, #654, ADR-00000011)` | - |
| `base update recipe forwards -h\|--help to upgrade.sh usage without the check (#789)` | - |
| `every shipped namespace module ships a help recipe + h alias (#789)` | - |
| `base module declares init + completions recipes (#653, ADR-00000011)` | #653 -- init -> .base/init.sh, completions -> script/base/completions.sh |
| `entry mods the base namespace (#652, ADR-00000011)` | #652 -- `mod? base` |
| `docker module owns a default recipe + pins cwd to repo root (#652, ADR-00000011)` | #652 -- mod default + `set working-directory := '../..'` |
| `entry mods the docker namespace + default recipe lists recipes (#652, ADR-00000011)` | #652 -- `mod? docker` + `default: @just --list` |
| `test / release namespaces own a default recipe (bare-namespace help, #655)` | #655 -- bare `just test` / `just release` |
| `test namespace: coverage-path demands its spec, coverage keeps its optional shard (#887)` | Required spec argument (a defaulted one would kcov the whole suite on a typo) |
| `test / release namespaces are English-only -- no --lang plumbing (#655)` | #655 -- ADR-00000011 i18n scope (machine/CI namespaces) |
| `consumer entry: every top-level mod? has one adjacent one-line doc comment (#720)` | #720 -- guards `just --list` descriptions (no blank-gap empty, no multi-line fragment) |
| `base root justfile: every top-level mod? has one adjacent one-line doc comment (#720)` | #720 -- same invariant for base's self-dev entry |

### test/bats/unit/justfile_user_spec.bats (33)

Executable tests for the user-facing layered entry + namespaces (#546 /
ADR-00000005; ADR-00000011: docker is a namespace, `just docker build`).
Parity with the removed `makefile_user_spec`: sandboxes a repo with the
entry + module symlink chain at root + stub `script/*.sh` recorders, and
RUNS `just <ns> <verb>` to assert 1:1 forwarding with `{{args}}`
passthrough. Skips when `just` is not yet in the test-tools image
(pre-release GHCR pull -- see template_spec for the pinned-fetch guard + the
release smoke check, which compares the version string rather than the exit
status).

| Test | Description |
|------|-------------|
| `just docker build forwards positional args to ./script/build.sh` | `just docker build test` -> build.sh test |
| `just docker build passes flags through verbatim (no -- separator needed)` | no `--` separator needed |
| `just docker exec passes = -bearing Kit-style args through (no EXEC_ARGS shim, #469)` | no EXEC_ARGS shim (#469) |
| `just docker run / stop / prune / setup forward to their wrappers` | wrapper dispatch |
| `just docker setup-tui forwards to ./script/setup_tui.sh` | - |
| `just docker start --help prints composite usage and does NOT build or run (#779)` | - |
| `just docker start -h short-circuits like --help (#779)` | - |
| `just base upgrade forwards to ./.base/dist/script/base/upgrade.sh (#652, #654, ADR-00000011)` | - |
| `just base update runs upgrade.sh --check (apt-aligned, #652)` | #652 -- apt-aligned check |
| `just base init forwards to ./.base/dist/script/base/init.sh (#653, #654, ADR-00000011)` | - |
| `just base completions forwards to script/base/completions.sh (#653, ADR-00000011)` | #653 -- opt-in completions installer dispatch |
| `bare just lists namespaces (replaces make help)` | replaces `make help`; lists `docker`/`base`/... |
| `bare just docker lists the docker verbs (namespace help, #655)` | #655 -- namespace help via module default (source_file() --list) |
| `bare just base lists the base verbs (namespace help, #655)` | #655 -- namespace help via module default |
| `just docker build --help forwards --help to the backing script (#655)` | #655 -- recipe `--help` reaches the script as an arg |
| `just docker build --lang ja forwards --lang to the backing script (#655)` | #655 -- recipe `--lang` forwarded |
| `just base completions --lang forwards --lang to completions.sh (#655)` | #655 -- base ns recipe `--lang` forwarded |
| `just base update --help reaches upgrade.sh usage, not the check (#789)` | - |
| `just base update -h reaches upgrade.sh usage (#789)` | - |
| `just docker help + h alias list the docker verbs (#789)` | - |
| `just base help + h alias list the base verbs (#789)` | - |
| `just template help + h alias print the template usage (#789)` | - |
| `just docker help renders zh-TW recipe summaries under LANG=zh-TW (i18n)` | - |
| `just docker help renders Japanese recipe summaries under LANG=ja (i18n)` | - |
| `just docker help --lang overrides LANG for the listing (i18n)` | - |
| `just docker help English default still renders the translated listing (i18n)` | - |
| `just base help renders zh-TW recipe summaries under LANG=zh-TW (i18n)` | - |
| `just template help renders zh-TW recipe summary under LANG=zh-TW (i18n)` | - |
| `dashed just <ns> --help errors but hints 'help' (documented just limit, #789)` | - |
| `just template new --help shows the recipe usage (recipe-level help, #789)` | - |
| `repo-local group via script/local/justfile.local resolves as a top-level namespace (#632)` | #632 `import?` registry + `mod?` group |
| `just template new <name> scaffolds a working repo-local group (#633, closes #594)` | #633 / closes #594 -- scaffold + immediately usable |
| `bare just template prints help (#633)` | #633 -- module default recipe |

### test/bats/unit/kcov_bash_instrumentation_spec.bats (2)

Asserts about the MEASURING INSTRUMENT rather than about the code, because
the instrument is the one input to the coverage gate that nothing was
watching. kcov reads bash coverage out of the xtrace stream and tracks
single-quote parity across lines; while it believes it is inside an
unterminated quote it discards every line it reads, markers included. bash
5.3 changed xtrace to ANSI-C quoting (`$'a\nb'`, embedded quotes written
`\'`), each of which flipped that counter -- so a burst of lines that had
just executed was reported as never run, silently, with the suite green.
`dockerfile/Dockerfile.test-tools` answers that by pinning an alpine series
on the bash 5.2 side of the boundary, which is at 3.23 (3.21 and 3.22 ship
5.2.37; 3.23 ships 5.3.3, 3.24 ships 5.3.9). These two tests are that
choice's acceptance, and they are behavioural (run the real kcov over a
fixture and read the report), so a bump onto a bash kcov misreads fails at
the bump rather than moving the coverage number by a plausible margin.

| Test | Description |
|------|-------------|
| `kcov: lines after an ANSI-C $'...' value are recorded as run (bash 5.3 xtrace quoting)` | The bug: an embedded `\'` must not flip the quote-parity counter and swallow the following lines |
| `kcov: a backslash inside a plain '...' value stays literal, so the next line is recorded` | The mirror case: inside `'...'` a backslash is literal, so a value ending in one really does close its quote |

### test/bats/unit/lib_spec.bats (67)

| Test | Description |
|------|-------------|
| `_resolve_lang sets 'en' when LANG is unset (#568)` | Default language |
| `_resolve_lang sets 'zh-TW' for zh_TW.UTF-8 (#568)` | Traditional Chinese |
| `_resolve_lang sets 'zh-CN' for zh_CN.UTF-8 (#568)` | Simplified Chinese |
| `_resolve_lang sets 'zh-CN' for zh_SG (Singapore) (#568)` | Singapore variant |
| `_resolve_lang sets 'ja' for ja_JP.UTF-8 (#568)` | Japanese |
| `_resolve_lang honors SETUP_LANG override (#568)` | Env override |
| `_lib.sh does NOT set _LANG at source time (#568 Part B)` | Load-time side-effect removed |
| `conf_logging.sh self-sources its conf.sh dependency in isolation (#568)` | Self-sourcing (load order not load-bearing) |
| `_lib.sh is idempotent when sourced twice` | Double-source guard |
| `_load_env exports variables from a .env file` | Env loader works |
| `_load_env errors when no path is given` | Required arg check |
| `_load_env round-trips shell-hostile values verbatim (no exec, no split) (#689)` | %q-quoted hostile value loads literally (no command-sub / word-split) |
| `_load_env aborts under set -euo pipefail when the file does not exist (#689)` | Missing-file error path (no `[[ -f ]]` guard) |
| `_compute_project_name produces clean PROJECT_NAME (single-instance #600)` | Project name (single-instance) |
| `_compute_project_name derives local-<basename> with nothing loaded (#920)` | The only path that reaches the `local` last resort |
| `_compute_project_name honours the PROJECT_NAME resolved into .env.generated (#893)` | - |
| `_compose_project passes the resolved PROJECT_NAME to -p (#893)` | - |
| `_resolve_project_name: a configured name is used verbatim (#893)` | - |
| `_resolve_project_name: empty configured name derives the historical default (#893)` | - |
| `_resolve_project_name: a configured name wins where the derivation cannot separate two users (#920)` | `[project] name` answers a shared Docker Hub login |
| `_env_file_value reads the last assignment, and empty when absent (#920)` | Reads the file, not the environment |
| `_carry_project_name: a checkout with no recorded name takes the resolved one (#920)` | Fresh checkout, nothing pending |
| `_carry_project_name: an unchanged resolution records nothing pending (#920)` | The ordinary apply |
| `_carry_project_name: a changed DERIVATION keeps the recorded name (#920)` | A rename nobody asked for waits |
| `_carry_project_name: a CONFIGURED name is taken at once (#920, #893)` | The setting is not deferred |
| `_recorded_project_name reads the PROJECT_NAME a repo already records (#920)` | The recorded key wins outright |
| `_recorded_project_name reconstructs the name a PRE-record env file runs under (#920)` | The previous release's file shape is not a fresh checkout |
| `_recorded_project_name answers empty when there is no name to reconstruct (#920)` | A genuinely fresh checkout, and both half-shapes |
| `_resolve_project_name: two OS users with no Docker Hub login derive distinct project names (#920)` | Multi-user isolation with no config, pinned through the detection that delivers it |
| `_resolve_project_name: falls back to local + directory basename with nothing to go on (#893)` | - |
| `_compute_project_name warns when .env.generated carries no PROJECT_NAME (#893)` | - |
| `_compute_project_name refuses to derive for a configured checkout with no cache (#1015)` | the missing-cache case the warning above does not cover. A configured checkout RECORDS its project name; deriving one over the gap invents a name this checkout never ran under, and acting on it can reach a different live checkout on a shared host. Only a self-managed checkout may derive. |
| `_compute_project_name still derives for a self-managed checkout (#1015)` | the same gap in a self-managed checkout is that checkout's normal state -- nothing writes the cache there and nothing ever will -- so the derivation is the answer rather than a guess over a missing one. |
| `_compose with DRY_RUN=true prints command instead of running` | DRY_RUN path |
| `_compose without DRY_RUN tries to invoke docker compose (sanity)` | Real-call branch |
| `_compose_project pre-fills -p / -f / --env-file from PROJECT_NAME and FILE_PATH` | Project wrapper |
| `_compose_project omits --env-file when .env.generated is absent (self-managed repo)` | - |
| `_sanitize_lang accepts en / zh-TW / zh-CN / ja unchanged` | Lang validator pass-through |
| `_sanitize_lang warns and falls back to 'en' for unsupported values (English default)` | Unknown lang fallback |
| `_sanitize_lang warns for the old bare 'zh' code (post zh→zh-TW rename)` | Legacy lang rejection |
| `_sanitize_lang warning is localized to system LANG (zh-TW)` | - |
| `_sanitize_lang warning is localized to system LANG (zh-CN)` | - |
| `_sanitize_lang warning is localized to system LANG (ja)` | - |
| `_dump_conf_section extracts keys from the named section` | INI section dump |
| `_dump_conf_section stops at the next section header` | Section boundary |
| `_dump_conf_section returns silent empty for missing file` | Missing file |
| `_dump_conf_section returns silent empty for unknown section` | Missing section |
| `_dump_conf_section hides keys with empty values (using default)` | - |
| `_print_config_summary prints files, identity, all populated sections, resolved` | Full config dump |
| `_print_config_summary names an active .setup.conf.local and its sections (#893)` | - |
| `_print_config_summary says nothing about a .setup.conf.local that is absent (#893)` | - |
| `_print_config_summary prints Variables block mapping setup.conf placeholders to detected values` | Variables block populated |
| `_print_config_summary Variables block falls back to '-' for unset values` | Variables fallback |
| `_print_config_summary hides sections that are empty in setup.conf` | Empty-section skip |
| `_print_config_summary warns when setup.conf is missing` | Missing-conf hint |
| `_print_config_summary wraps dividers + section headers in ANSI when FORCE_COLOR=1 (#309)` | Color migration via _log_plain |
| `_print_config_summary omits ANSI when NO_COLOR=1 overrides FORCE_COLOR=1 (#309)` | NO_COLOR precedence on summary |
| `_print_config_summary warns when setup.conf exists but has no [section] headers` | #157 empty-conf hint on build/run summary |
| `_lib_msg returns English by default` | - |
| `_lib_msg returns zh-TW translations` | - |
| `_lib_msg returns zh-CN translations` | - |
| `_lib_msg returns ja translations` | - |
| `_lib_msg returns count / caps across all languages` | - |
| `_lib_msg falls back to English for unknown _LANG value` | - |
| `_print_config_summary uses zh-TW labels when _LANG=zh-TW` | - |
| `_print_config_summary uses ja labels when _LANG=ja` | - |
| `_print_config_summary conf_missing hint is translated (zh-TW)` | - |

### test/bats/unit/lint_bare_stderr_spec.bats (6)

Unit tests for `script/test/lint_bare_stderr.sh` (#692), the "all stderr
goes through lib/log.sh helpers" lint. The lint takes the repo root as `$1`,
so the spec drives it against synthesized fixture trees laid out like the
real repo (sources under `dist/script/docker/**`, tests under
`script/test/**`). A real-repo-root clean-tree case guards against the
path-drift bug (an empty find root passing vacuously) by proving the scan
actually walks the populated `dist/script/docker` tree.

| Test | Description |
|------|-------------|
| `flags a bare 'printf ... >&2' under dist/script/docker (#692)` | exit 1 + violation line on the correct tree |
| `exits 0 on a clean tree (no bare stderr) (#692)` | clean fixture passes silently |
| `does NOT flag an allowlisted _log_* line (#692)` | `_log_*` line exempt |
| `does NOT flag an allowlisted getopts / [y/N] prompt line (#692)` | getopts / prompt lines exempt |
| `does NOT flag bare stderr in the standalone coverage_gate.sh CI tool (#710)` | standalone log.sh-free CI tool excluded |
| `the real repo tree (default root) is clean (#692)` | live-tree guard against path drift |

### test/bats/unit/log_spec.bats (69)

OTel-aligned logger (#423, #438). Single-sink tty-detect dispatch,
`LOG_FORMAT=auto|text|json` override, strict body enforcement (unregistered
body = fatal), `display=` attribute for i18n text in text mode, UTC
microsecond timestamps, `_log_plain` removed.

Grouped by concern:

- Text output format (`LOG_FORMAT=text`): timestamp + aligned level + tag,
multi-token join, attr=val skip, `display=` override

- Timestamp: UTC with microsecond precision in both text and JSON

- Stream routing: stdout for INFO/DEBUG, stderr for WARN/ERROR/FATAL

- Single-sink tty-detect dispatch (#438): non-TTY auto JSON,
`LOG_FORMAT=text` force, `LOG_FORMAT=json` force, `LOG_FORMAT=auto` equiv

- Startup TTY cache `_LOG_IS_TTY` (#605): helper defined +
cached-0/cached-nonzero/unset-fallback; auto-format honours cache +
unset-identity; explicit `LOG_FORMAT` bypasses cache; `_log_color_enabled`
cache read + NO_COLOR/FORCE_COLOR precedence over cache

- JSON escaping (`_log_json_escape`, #691): quote / lone-backslash double /
newline+tab+CR / substitution order; live `_log_info` attr value with
quote+backslash+tab stays well-formed

- JSON output: OTel fields, custom attributes, severity numbers, per-line
structure

- TRACEPARENT in JSON: trace_id/span_id present/absent

- Strict body enforcement (#438): unregistered fatal, registered OK, empty
OK, error names body + file

- Missing service rejected, `_log_fatal` does not auto-exit

- Scoped wrappers: `_log_with_trace` save/restore, `_log_with_span` trace_id

- `_log_plain` removed (#438)

- `_log_color_enabled`: TTY detect, FORCE_COLOR, NO_COLOR precedence

- FORCE_COLOR text: red bold ERROR, yellow WARN, NO_COLOR strips

- Event registry: registered/unregistered/comment detection

- lnav format file

| Test | Description |
|------|-------------|
| `_log_info text output has timestamp + aligned level + tag` | - |
| `_log_err text output to stderr with timestamp` | - |
| `_log_warn text output uses WARN (not WARNING)` | - |
| `_log_debug text output to stdout` | - |
| `_log_fatal text output to stderr` | - |
| `text levels are right-aligned to 5 chars` | - |
| `text output joins multi-token message with spaces` | - |
| `text output skips attr=val args in message` | - |
| `text output uses display= attribute over body when present` | - |
| `JSON includes display= as attribute alongside registered body` | - |
| `text timestamp is UTC with microsecond precision` | - |
| `JSON timestamp is UTC with microsecond precision` | - |
| `_log_info and _log_debug route to stdout` | - |
| `_log_warn _log_err _log_fatal route to stderr` | - |
| `non-TTY stdout emits JSON by default (auto-detect)` | - |
| `non-TTY stderr emits JSON for _log_err` | - |
| `LOG_FORMAT=text forces text output on non-TTY` | - |
| `LOG_FORMAT=json forces JSON output` | - |
| `LOG_FORMAT=auto is equivalent to unset (non-TTY -> JSON)` | - |
| `_log_is_tty helper is defined after sourcing (#605)` | - |
| `_log_is_tty: cached 0 wins over a non-TTY fd (#605)` | - |
| `_log_is_tty: cached non-zero wins over the live probe (#605)` | - |
| `_log_is_tty: unset falls back to live test -t (non-TTY pipe -> non-zero) (#605)` | - |
| `auto dispatch: _LOG_IS_TTY=0 forces text even on a non-TTY pipe (#605)` | - |
| `auto dispatch: _LOG_IS_TTY unset preserves live detection (non-TTY -> JSON) (#605)` | - |
| `explicit LOG_FORMAT=json ignores _LOG_IS_TTY=0 (cache scoped to auto) (#605)` | - |
| `explicit LOG_FORMAT=text ignores _LOG_IS_TTY=1 (cache scoped to auto) (#605)` | - |
| `_log_color_enabled honours _LOG_IS_TTY=0 on a non-TTY (#605)` | - |
| `_log_color_enabled with _LOG_IS_TTY=1 stays disabled (#605)` | - |
| `_log_color_enabled: NO_COLOR wins over _LOG_IS_TTY=0 (#605)` | - |
| `_log_color_enabled: FORCE_COLOR wins over _LOG_IS_TTY=1 (#605)` | - |
| `JSON output contains OTel fields` | - |
| `JSON output contains custom attributes` | - |
| `JSON severity_number: DEBUG=5 INFO=9 WARN=13 ERROR=17 FATAL=21` | - |
| `_log_json_escape escapes a double-quote` | - |
| `_log_json_escape doubles a lone backslash (no double-escape)` | - |
| `_log_json_escape escapes newline tab and carriage-return` | - |
| `_log_json_escape applies substitutions in order (backslash before quote)` | - |
| `JSON attribute value with quote/backslash/tab is escaped and line stays well-formed` | - |
| `JSON output is valid per-line (starts with { ends with })` | - |
| `JSON includes trace_id and span_id when TRACEPARENT is set` | - |
| `JSON omits trace_id when TRACEPARENT is unset` | - |
| `unregistered body causes fatal exit` | - |
| `registered body succeeds normally` | - |
| `empty body is allowed (no strict check)` | - |
| `strict body error names the offending body and log-events.txt` | - |
| `_log_info with no args exits non-zero` | - |
| `_log_err with no args exits non-zero` | - |
| `_log_fatal does not exit; caller controls exit` | - |
| `_log_with_trace sets TRACEPARENT and restores prior value` | - |
| `_log_with_trace without prior TRACEPARENT unsets on return` | - |
| `_log_with_span preserves trace_id from parent` | - |
| `_log_with_trace prints trace started message to stderr` | - |
| `_log_plain is no longer defined` | - |
| `_log_color_enabled returns non-zero on non-TTY without overrides` | - |
| `_log_color_enabled returns 0 with FORCE_COLOR=1` | - |
| `_log_color_enabled returns non-zero with NO_COLOR=1 + FORCE_COLOR=1` | - |
| `_log_err FORCE_COLOR=1 emits red bold ANSI in text` | - |
| `_log_warn FORCE_COLOR=1 emits yellow ANSI in text` | - |
| `NO_COLOR=1 text omits ANSI` | - |
| `log-events.txt is loaded and contains env_regenerated` | - |
| `unregistered event returns false` | - |
| `log-events.txt comment lines are not registered as events` | - |
| `log.lnav-format.json exists and contains format key` | - |
| `log.lnav-format.json declares json: true` | - |
| `_dry_run_cmd: DRY_RUN=true prints [dry-run] argv and does not execute` | - |
| `_dry_run_cmd: DRY_RUN=false executes the command` | - |
| `_dry_run_cmd: DRY_RUN unset defaults to executing` | - |
| `_dry_run_cmd: DRY_RUN=true %q-quotes args containing spaces` | - |

### test/bats/unit/logrotate_spec.bats (7)

Wrapper transcript retention: `_logrotate_repoint` (the stable `latest.log`
symlink follows the newest real file without deleting the previous one) and
`_logrotate_prune` (keep N most recent plus an age bound, never touch the
symlink itself or a sibling service's symlink sharing the directory, missing
directory is a no-op).

| Test | Description |
|------|-------------|
| `_logrotate_repoint: points the stable symlink at the newest real file (#805)` | - |
| `_logrotate_repoint: repointing to a newer file does NOT delete the old one (#805)` | - |
| `_logrotate_prune: keeps the N most recent real files, drops the rest (#805)` | - |
| `_logrotate_prune: drops files older than <days> regardless of count (#805)` | - |
| `_logrotate_prune: never removes the stable symlink itself (#805)` | - |
| `_logrotate_prune: never prunes a SIBLING service's symlink sharing the dir (#805)` | - |
| `_logrotate_prune: missing dir is a no-op (best-effort) (#805)` | - |

### test/bats/unit/multi_distro_build_worker_yaml_spec.bats (17)

Structural assertions for `.github/workflows/multi-distro-build-worker.yaml`
(#325 B-1 dispatcher, extended to N-D matrix-mode via #344 in v0.32.0). The
dispatcher fans a per-event `include`-shape matrix across
`build-worker.yaml` matrix shards so multi-distro / multi-variant caller
`main.yaml`s (`env/ros_distro`, `env/ros2_distro`, `app/ros1_bridge`) stop
copy-pasting a `${{ github.event_name == 'pull_request' && ... || ... }}`
expression. Three jobs:

1. **`resolve-matrix`** — pure-shell selector emitting a `matrix` JSON-array
output (`include`-shape, each entry has `name` + `build_args` plus arbitrary
additional fields). `pull_request` -> `pr_matrix` (subset); anything else
(tag push, main push, `workflow_dispatch`) -> `tag_matrix` (release
validation matrix).

2. **`call-build`** — strategy.matrix job invoking the local
`build-worker.yaml` per matrix cell. Derives per-shard `image_name` as
`<image_name>-<matrix.name>`, forwards `matrix.build_args` verbatim as
`build_args`, and shards buildx GHA cache by name via `cache_variant: ${{
matrix.name }}` (reuses #272's per-variant scope contract). `fail-fast:
false` so one shard's failure doesn't cancel siblings.

3. **`ci-passed`** — rollup gate for branch protection. Matches the existing
`ci-passed` rollup naming used by env/ros_distro / env/ros2_distro per
CLAUDE.md's status-check table, so downstream branch-protection contexts
don't change on adoption.

**BREAKING since v0.32.0 (#344)**: legacy 1D inputs `pr_distros` /
`tag_distros` / `distro_input_name` / `extra_build_args` were removed; the
14 v0.29-era tests covering those inputs are replaced by 16 tests covering
the new matrix-mode shape (incl. a negative assertion that the 1D inputs are
gone).

Grouped by concern:

- Declares `workflow_call`

- Required inputs: `pr_matrix`, `tag_matrix`, `image_name`

- Legacy 1D inputs gone (no `pr_distros` / `tag_distros` /
`distro_input_name` / `extra_build_args`)

- `pr_matrix` description documents required `name` + `build_args` fields

- `tag_matrix` description documents required `name` + `build_args` fields

- Passthrough inputs mirror build-worker (build_runtime / test_tools_version
/ platforms / context_path / dockerfile_path / build_contexts)

- `resolve-matrix` emits `matrix` output (include-shape)

- `resolve-matrix` branches on `github.event_name == 'pull_request'`

- `call-build` `uses: ./.github/workflows/build-worker.yaml`

- `call-build` matrix `include:
fromJSON(needs.resolve-matrix.outputs.matrix)`

- `call-build` per-shard `image_name: <image_name>-<matrix.name>` (hyphen)

- `call-build` forwards `build_args: ${{ matrix.build_args }}` verbatim

- `call-build` `cache_variant: ${{ matrix.name }}` (per-cell cache scope)

- `call-build` `fail-fast: false`

- `ci-passed` rollup depends on `call-build`, runs with `if: always()`

- `ci-passed` declares `name: ci-passed` to satisfy branch protection
contract

- Every job's grant pinned as an exact per-job entry set, over the job list
derived from the file (all three jobs `contents: read` -- the dispatcher
builds nothing and pushes nothing)

| Test | Description |
|------|-------------|
| `multi-distro-build-worker.yaml: declares workflow_call (#325 B-1)` | - |
| `multi-distro-build-worker.yaml: required inputs include pr_matrix + tag_matrix + image_name (#344 matrix-mode)` | - |
| `multi-distro-build-worker.yaml: legacy 1D inputs are gone (no pr_distros / tag_distros / distro_input_name / extra_build_args) (#344 BREAKING)` | - |
| `multi-distro-build-worker.yaml: pr_matrix description mentions required name + build_args fields per entry (#344)` | - |
| `multi-distro-build-worker.yaml: tag_matrix description mentions required name + build_args fields per entry (#344)` | - |
| `multi-distro-build-worker.yaml: passthrough inputs mirror build-worker (build_runtime / test_tools_version / platforms / context_path / dockerfile_path / build_contexts) (#325 B-1)` | - |
| `multi-distro-build-worker.yaml: resolve-matrix job emits matrix output (#344 include-shape)` | - |
| `multi-distro-build-worker.yaml: resolve-matrix branches on github.event_name == pull_request (#344)` | - |
| `multi-distro-build-worker.yaml: call-build uses local build-worker via ./.github/workflows/build-worker.yaml (#325 B-1)` | - |
| `multi-distro-build-worker.yaml: call-build matrix is include: fromJSON(needs.resolve-matrix.outputs.matrix) (#344 N-D)` | - |
| `multi-distro-build-worker.yaml: call-build derives per-shard image_name as <image_name>-<matrix.name> (hyphen, #344)` | - |
| `multi-distro-build-worker.yaml: call-build passes matrix.build_args verbatim as build_args (#344)` | - |
| `multi-distro-build-worker.yaml: call-build splits buildx cache by name via cache_variant: matrix.name (#272 reuse, #344)` | - |
| `multi-distro-build-worker.yaml: call-build has fail-fast: false so one shard's failure doesn't cancel siblings (#325 B-1)` | - |
| `multi-distro-build-worker.yaml: ci-passed rollup job exists, depends on call-build, runs even if matrix failed (#325 B-1)` | - |
| `multi-distro-build-worker.yaml: ci-passed job has explicit name: ci-passed (matches existing multi-distro rollup contract) (#325 B-1)` | - |
| `multi-distro-build-worker.yaml: every job's grant is pinned as an exact set (#957)` | - |

### test/bats/unit/network_ports_inert_spec.bats (15)

| Test | Description |
|------|-------------|
| `set network.port_N under the shipped host default warns (#879)` | - |
| `set network.port_N under mode = bridge stays quiet (#879)` | - |
| `add network.port under the shipped host default warns (#879)` | - |
| `add network.port under mode = bridge stays quiet (#879)` | - |
| `set network.mode host with ports already configured warns (#879)` | - |
| `set network.mode bridge with ports already configured stays quiet (#879)` | - |
| `set network.mode host with no ports configured stays quiet (#879)` | - |
| `--quiet suppresses the confirmation but never the port diagnostic (#879)` | - |
| `generate_compose_yaml warns when it drops ports under host mode (#879)` | - |
| `generate_compose_yaml stays quiet when it emits ports under bridge (#879)` | - |
| `generate_compose_yaml stays quiet under host mode with no ports (#879)` | - |
| `_generate_resolved_compose warns when the field bundle drops ports (#879)` | - |
| `_generate_resolved_compose stays quiet when the field bundle emits ports (#879)` | - |
| `the ports-inert diagnostic is translated in all four locales (#879)` | - |
| `the ports-inert diagnostic differs per locale (no untranslated arms) (#879)` | - |

### test/bats/unit/prev_release_gating_spec.bats (8)

| Test | Description |
|------|-------------|
| `prev-release gate: --bats-path over a unit spec dispatches with no release tags` | - |
| `prev-release gate: --bats-fragile dispatches with no release tags` | - |
| `prev-release gate: a shard that does not carry the spec dispatches with no release tags` | - |
| `prev-release gate: --lint dispatches with no release tags` | - |
| `prev-release gate: --bats-integration refuses to start when the tags cannot be resolved` | - |
| `prev-release gate: the shard that carries the spec refuses to start when the tags cannot be resolved` | - |
| `prev-release gate: under kcov the shard out-ranks a leftover BATS_FILE` | - |
| `prev-release gate: --bats-path over the spec itself refuses to start when the tags cannot be resolved` | - |

### test/bats/unit/probe_test_tools_spec.bats (25)

Unit tests for `script/ci/probe_test_tools.sh`, the CI-side verdict on
whether a pulled `test-tools:main` corresponds to the checkout that pulled
it. Presence answers the kcov race; the VERSION comparison answers the
quieter half, a lint gate silently running the rule set the repo just moved
off, and a runner older than `ARG JUST_VERSION` reddening a PR that touched
nothing related. The alpine SERIES is compared first and for the same
reason: it decides which bash the image ships, and bash decides whether kcov
reads this suite's coverage or under-reports it. The expectations are read
out of `dockerfile/Dockerfile.test-tools` -- the two linters from their
release URLs, the runner through `dist/script/base/just-version.sh` -- so
neither the probe nor this spec names a version. Docker is reached through a
single `_probe_run` seam, which is what lets the decision logic be driven
here with no daemon.

| Test | Description |
|------|-------------|
| `probe: reads the shellcheck pin out of the real Dockerfile (#947)` | Shape-asserted, not literal: naming a version here would be the second place to bump |
| `probe: reads the hadolint pin out of the real Dockerfile (#947)` | The pin that sat three and a half years stale, now read by the thing that accepts the image |
| `probe: reads the just pin through the one accessor, not a second reader (#948)` | The runner's pin is the one that is NOT in a release URL -- the URL names `${JUST_VERSION}` -- so it is read through the single accessor over `ARG JUST_VERSION`; a second sed here would be the fifth provenance path for the runner that #948 exists to close |
| `probe: a Dockerfile with no pinned URL FAILS rather than returning nothing (#947)` | A reader returning nothing would reduce the comparison to empty-vs-empty |
| `probe: a version is matched whole, not as a prefix of a longer one (#947)` | 0.11.0 must not be satisfied by 0.11.01 or by 10.11.0 |
| `probe: the dots in a version are literal, not any-character (#947)` | An unescaped regex dot would let 0x11x0 pass as 0.11.0 |
| `probe: reads the alpine series pin out of the real Dockerfile (#946)` | The third pin in the file, read from the checkout rather than restated in the probe |
| `probe: a Dockerfile with no ALPINE_VERSION FAILS rather than returning nothing (#946)` | A reader returning nothing would reduce the comparison to empty-vs-empty |
| `probe: two ALPINE_VERSION pins are refused, not silently the first (#946)` | Whichever one a reader picked, half the stages would be built on the other |
| `probe: an image carrying every tool at the pinned version is accepted (#947)` | The hot path: a matching `:main` must not cost every PR a local rebuild |
| `probe: an image shipping ANOTHER just is refused and both versions named (#948)` | The runner mismatch a presence-only probe cannot see: `just` is there, at the version published before the bump, and just_runner_version_spec is fail-closed on exactly that -- so accepting the image reddens a PR that touched nothing related |
| `probe: a MISSING tool is refused and named (#947)` | The kcov race the probe was originally written for |
| `probe: a tool at the WRONG version is refused and both versions are named (#947)` | The quiet failure: a lint gate on an older rule set under-reports rather than failing |
| `probe: a present-but-silent tool is refused, not read as agreement (#947)` | Empty output must not compare equal to a pin |
| `probe: an unreadable pin for a PINNED tool is a hard refusal (#947)` | The state a moved release URL produces; cannot-tell is not matches |
| `probe: an empty REQUIRED_TOOLS is refused rather than passing vacuously (#947)` | A probe over an empty list answers yes to every image |
| `probe: a PINNED tool absent from REQUIRED_TOOLS is refused as a contradiction (#947)` | A tool whose version matters that the probe never looks for is drift, not narrowing |
| `probe: an image built on ANOTHER alpine series is refused and both named (#946)` | Another series means another bash, which is what decides whether kcov can read this suite at all |
| `probe: an image that reports no alpine series is refused, not read as agreement (#946)` | A reading the image cannot produce is a mismatch, never an absent constraint |
| `probe: a series pin the probe cannot read is a hard refusal (#946)` | Cannot tell is not matches: exit 2 rather than a comparison with no expectation |
| `probe: a longer series is not satisfied by a prefix of it (#946)` | The comparison is on the whole series field, so 3.2 does not agree with a 3.22 image |
| `probe: main refuses an invocation that names no image (#947)` | A usage error is its own exit status, not a verdict about an image |
| `probe: end to end, an image reporting the pinned versions is accepted (#947)` | Drives the script as a program over a PATH-shimmed docker, so the one function that touches the daemon is actually entered |
| `probe: end to end, an image reporting a STALE version is refused (#947)` | The whole point of the probe, asserted end to end: present but out of date is a refusal, not a pass |
| `probe: the Dockerfile defaults to this checkout's, not the caller's cwd (#947)` | A cwd change must not silently turn the comparison into an unreadable-pin refusal |

### test/bats/unit/project_reclaim_spec.bats (42)

| Test | Description |
|------|-------------|
| `_reclaim_project_for_path derives the same base-<12hex> name test.sh does` | - |
| `script/test/test.sh derives its compose project name through the shared producer` | - |
| `script/test/test.sh derives its test-tools tag through the shared producer` | - |
| `a network whose recorded checkout is gone is collected` | - |
| `a sweep launched from an unrelated repository spares every live checkout` | - |
| `a live checkout whose path contains a newline is NOT collected` | - |
| `an orphan whose path contains a newline IS collected` | - |
| `the sweep consults no git at all` | - |
| `a network whose recorded checkout still exists is NOT collected` | - |
| `a path that exists but is no longer a checkout is spared` | - |
| `a network with NO checkout-path label is left alone` | - |
| `a checkout label that is not an absolute path is left alone` | - |
| `another tenant's network is left alone` | - |
| `a project with a container attached is NOT collected` | - |
| `an orphan created inside the grace window is NOT collected` | - |
| `a network whose facts cannot be read is left alone` | - |
| `an unreadable network listing ABORTS rather than collecting everything` | - |
| `an unreadable network listing issues no removal command at all` | - |
| `an unreadable container listing ABORTS -- it cannot say nothing is attached` | - |
| `an unparseable grace aborts before any docker call` | - |
| `a PROJECT label on an image is not a proof, whatever it says` | - |
| `the fact read asks for the JSON creation time and both labels` | - |
| `the live-checkout set comes from the artifacts, not from any worktree list` | - |
| `tag retention keeps the current tree's tag and the last N and retires the rest` | - |
| `tag retention keeps a tag a live checkout still resolves to` | - |
| `tag retention drops a checkout whose path is gone` | - |
| `tag retention leaves a tag it cannot place alone` | - |
| `tag retention ABORTS when the artifacts cannot be listed` | - |
| `tag retention ABORTS when the image listing fails` | - |
| `the retained-tag count is derived from the live checkouts, not a buried literal` | - |
| `the retained-tag count is overridable by the environment` | - |
| `the pinned tag set is the invoking tree plus every live checkout` | - |
| `an image whose checkout is gone is retired` | the case the whole image rule exists for: 275MB per dead checkout that ran `just test smoke`, which no verb could reclaim before. |
| `an image whose checkout still exists is kept` | the sparing side. A rule that collected a live checkout's image would cost a 275MB rebuild in the middle of someone's work. |
| `an image inside the grace window is kept` | the window covers a path that is momentarily absent because something is moving or recreating it while its run is in flight -- the one case the existence test cannot see. |
| `the tooling image carries no checkout label and is never a candidate here` | content-hash shared on purpose, so no artifact can name all its users. This is what keeps the image rule off the one image class where deletion would reach a live checkout. |
| `an image whose path label is not absolute is left alone` | a relative label names nothing testable, so it attributes nothing. On a shared host the fail-open direction is deleting what cannot be placed. |
| `a dangling labelled image is left alone rather than removed by id` | `<none>:<none>` has no name that can be removed safely -- the id behind it may carry other tags -- so acting on it would reach past what this rule can prove. |
| `an image whose live checkout path contains a newline is NOT retired` | the shape that got a live worktree's network removed under the rule this replaced: a truncated path is very plausibly absent, and absent is what makes an artifact a candidate. |
| `an image whose DEAD checkout path contains a newline IS retired` | the pair to the case above. Read wrongly in either direction the rule is broken, so both directions are pinned. |
| `an unreadable image listing retires nothing` | read as "nothing is labelled", a failed listing turns a broken daemon connection into a reason to delete. |
| `a dry run names the image it would retire and removes nothing` | the mode an operator uses to check the rule before trusting it with the removal, so it must name the victim rather than only counting it. |

### test/bats/unit/project_wait_spec.bats (14)

| Test | Description |
|------|-------------|
| `a project with nothing attached to its network is ready at once` | the ordinary case, and the one the cost lands on: every run pays this check, so it must not wait when there is nothing to wait for. |
| `a project with no network of its own at all is ready at once` | a first run on a fresh checkout has no artifacts, and must not be delayed by a mechanism built for a second one. |
| `the listing is filtered by both labels, so only this checkout's project is looked at` | ownership is exact and carried by the artifact. A prefix or a bare project filter would let another checkout's run block this one. |
| `a container still detaching is waited for, and the wait says what it waits for` | the load-bearing one. The wait is worthless if it is silent: the reader must be able to tell waiting from hanging. |
| `a container that never detaches fails naming it and the verb that clears it` | the bounded half. Waiting forever trades a confusing red for a hang, so the timeout has to produce an answer the operator can act on. |
| `the wedged run says no test failed, so the reader stops hunting for one` | the whole reason the issue was filed: the old failure reported rc=1 with not_ok=0, and the reader's first move was to look for a code defect that was not there. |
| `a running container is a concurrent run, not a wedge` | compose reuses a live network happily. Waiting here would be waiting for something that is not leaving. |
| `an unreadable docker is not evidence of a wedge` | a failed listing cannot say a container is attached, and refusing to start the suite over it would be a worse red than the one this replaces. |
| `a malformed wait window is named and the default is used, not the run refused` | declining to run the suite over a typo in a duration string would just be a different confusing red. |
| `a wedged project stops the dispatch before compose is called` | reaching compose anyway would emit the daemon's raw text again, which is the defect. Behaviour, not line order. |
| `a quiescent project lets the dispatch through` | the pair to the case above: a guard that blocked the ordinary run would be caught here rather than by every developer. |
| `test.sh --await-project answers for this checkout and exits` | it is a query, like --compose-project-name: the recipes that call it must not have it mint anything. |
| `test.sh --await-project refuses when the project is still held` | the flag is only worth having if its verdict reaches the caller; a query that always exits 0 would let system and smoke run into the wedge. |
| `system and smoke both ask before they build` | neither goes through the dispatcher, so neither inherits the question. They are the flows most likely to leave a container behind. |

### test/bats/unit/prune_sh_spec.bats (41)

Unit tests for the new `script/docker/prune.sh` wrapper (#319) — atomic
docker garbage cleanup with conservative per-target `--filter until=`
defaults (network=10m, image=24h, builder=24h, volume=no filter). Sandbox +
PATH-shimmed `docker` stub mirrors the build/run/exec/stop spec strategy;
`docker compose` is never invoked here so no `.env` seeding is required
beyond the sandbox layout.

Covers: `--help` (en/zh-TW/zh-CN/ja), no-target exit-2 hint (English +
zh-TW), `--until` / `--lang` value-required guards, unknown-flag exit-2,
individual `--networks` / `--images` / `--builder` / `--volumes` dry-run
output (each with its own default grace; volume output omits `--filter`),
**`--all` aggregator** (network + image + builder; volumes intentionally
excluded), **`--until <dur>` override** across all selected targets,
**volume confirmation prompt** (`n` aborts with exit-1 + i18n "aborted"
message; closed-stdin EOF aborts cleanly with no set-e crash (#702); `-y`
skips the prompt; zh-TW prompt body asserts), `-C` / `--chdir` parity
(accepted but no-op for daemon-wide prune; value-required + directory
guards), usage help mentions every flag family, and **#388
`--worktree-orphans` mode** (13 cases): per-test smart docker stub keyed on
`DOCKER_IMAGES_OUTPUT` / `DOCKER_RMI_LOG` mocks `docker images` + `rmi`;
fixtures construct real `<workspace>/worktree/<name>/` dirs so the existence
check has something to consult. Cases cover empty-list no-op, owner-match +
missing worktree → rmi, owner-match + worktree alive → keep, main-checkout
pattern (no hyphen) → keep, **two safety gates**: bare-name image → skip
("Skipping N bare-name image" log), other-owner image → skip ("Skipping N
image(s) owned by another user" log). Plus `--repo` filter, `--dry-run`
plan-only output, `-y` skip prompt, missing `--workspace` + empty `.env` →
exit 2, `--workspace` flag wins over `.env` `WS_PATH`, `--owner` flag wins
over `.env` `DOCKER_HUB_USER`, and `--help` mentions all four new flags.

Plus the **`--worktree-orphans` interactive confirmation gate (#699)** — the
destructive `docker rmi` loop only reaches its prompt when neither `-y` nor
`--dry-run` is given, a branch the cases above never exercised. Three cases
mirror the `--volumes` prompt pair for the more destructive image removal:
piped `y` confirms and the candidate lands in `DOCKER_RMI_LOG`; piped `n`
aborts with exit-1 + "aborted by user" and an empty `DOCKER_RMI_LOG`; closed
stdin (`</dev/null`, no `-y`) aborts cleanly with the same diagnostic
instead of dying on a `set -e` `read` EOF — prune.sh maps `read` EOF to an
empty reply (`read -r _reply || _reply=""`) so the default case treats it as
an explicit abort.

Regression guard for **issue #282** — the four user-facing wrappers
(`build.sh` / `run.sh` / `exec.sh` / `stop.sh`) must resolve `_lib.sh`
through the post-#263 `.base/` subtree prefix on a fresh clone of any
downstream repo. Pre-fix the wrappers hard-coded `template/` and a freshly
cloned downstream repo (where the subtree now lives under `.base/`) failed
at the `_lib.sh` source step with "cannot find _lib.sh".

Covers: `--help` succeeds for each wrapper when
`.base/script/docker/_lib.sh` exists alongside the wrapper symlink; the
documented "cannot find _lib.sh" error path still fires (with the new
`.base/...` path in the diagnostic) when neither `.base/` nor the sibling
fallback is present.

| Test | Description |
|------|-------------|
| `prune.sh --help exits 0 and shows usage` | - |
| `prune.sh --lang zh-TW prints Traditional Chinese usage text` | - |
| `prune.sh --lang zh-CN prints Simplified Chinese usage text` | - |
| `prune.sh --lang ja prints Japanese usage text` | - |
| `prune.sh with no target exits 2 with hint` | - |
| `prune.sh --until without a value exits non-zero` | - |
| `prune.sh --lang without a value exits non-zero` | - |
| `prune.sh unknown flag exits 2 with error` | - |
| `prune.sh --networks --dry-run prints network prune with default 10m filter` | - |
| `prune.sh --images --dry-run prints image prune with default 24h filter` | - |
| `prune.sh --builder --dry-run prints builder prune with default 24h filter` | - |
| `prune.sh --volumes -y --dry-run prints volume prune (no filter)` | - |
| `prune.sh --all --dry-run prints network + image + builder (NOT volumes)` | - |
| `prune.sh --networks --until 1h --dry-run overrides default 10m grace` | - |
| `prune.sh --all --until 1h --dry-run overrides all default graces` | - |
| `prune.sh --volumes without -y prompts and aborts on 'n'` | - |
| `prune.sh --volumes without -y on closed stdin aborts cleanly, no set-e crash (#702, #700)` | - |
| `prune.sh --volumes -y skips the prompt (dry-run for safety)` | - |
| `prune.sh no target with --lang zh-TW prints Chinese hint` | - |
| `prune.sh --volumes prompt with --lang zh-TW shows Chinese prompt` | - |
| `prune.sh -C <dir> --networks --dry-run is accepted (chdir parity)` | - |
| `prune.sh -C without a value exits 2` | - |
| `prune.sh -C with a non-existent directory exits 2` | - |
| `prune.sh -h mentions all flag families` | - |
| `prune.sh --worktree-orphans on empty image list → no rmi` | - |
| `prune.sh --worktree-orphans: owner match + missing worktree → rmi` | - |
| `prune.sh --worktree-orphans: owner match + worktree exists → keep` | - |
| `prune.sh --worktree-orphans: main-checkout pattern (no hyphen) → keep` | - |
| `prune.sh --worktree-orphans: bare-name image (no owner prefix) → SAFETY skip` | - |
| `prune.sh --worktree-orphans: other-owner image → SAFETY skip` | - |
| `prune.sh --worktree-orphans --repo <name> filter` | - |
| `prune.sh --worktree-orphans --dry-run prints plan, no real rmi` | - |
| `prune.sh --worktree-orphans -y skips confirmation` | - |
| `prune.sh --worktree-orphans without --workspace + empty .env → exit 2` | - |
| `prune.sh --worktree-orphans --workspace <flag> wins over .env WS_PATH` | - |
| `prune.sh --worktree-orphans --owner <flag> wins over .env DOCKER_HUB_USER` | - |
| `prune.sh --worktree-orphans without -y confirms 'y' and removes the image (#699)` | - |
| `prune.sh --worktree-orphans without -y aborts on 'n' and removes nothing (#699)` | - |
| `prune.sh --worktree-orphans without -y on closed stdin aborts cleanly, no set-e crash (#699)` | - |
| `prune.sh --help mentions --worktree-orphans (#388)` | - |
| `prune.sh aborts on a failing pre-prune hook and skips docker prune (#690)` | - |

### test/bats/unit/publish_worker_yaml_spec.bats (12)

Structural assertions for the `.github/workflows/publish-worker.yaml`
reusable `call-publish` workflow (foundational image repos push their
Dockerfile target stage to a registry on tag push; downstream app repos
consume via `FROM ${registry}/${owner}/<image>`). #602: the original
`publish` job had every matrix shard push the SAME computed tag(s) via
`push: true` + `tags:`, leaving a last-shard-wins single-arch tag on a
multi-platform call (no manifest merge). The fix mirrors the #587
release-test-tools pattern — each shard pushes by digest, uploads its
digest, and a `merge` job assembles the tagged manifest list via `docker
buildx imagetools create`. These guards lock that contract.

Grouped by concern:

- Stays a reusable `workflow_call` workflow; preserves the
registry-parameterised inputs

- Native-runner matrix: `compute-matrix` maps platforms to native runners;
build shards run on `matrix.runner`

- Push-by-digest per shard (#602): build pushes by digest; no shared
same-tag-per-shard push (regression guard); digest exported + uploaded as
artifact

- Merge job (#602): downloads digests + creates the manifest via
`imagetools`; resolves tags from inputs once; login uses the parameterised
registry

- Every job's grant pinned as an exact per-job entry set, over the job list
derived from the file -- `packages: write` on `publish` + `merge` only,
`compute-matrix` read-only. Replaces a `grep -c '^\s+packages:\s+write' >=
2` count, which was blind to WHICH job held the scope, to a third job
acquiring it, and to any other scope beside it

- Same-repo guard on the self-hosted-eligible `publish` job (#766)

| Test | Description |
|------|-------------|
| `publish-worker.yaml: stays a reusable workflow_call workflow` | - |
| `publish-worker.yaml: preserves the registry-parameterised inputs` | - |
| `publish-worker.yaml: compute-matrix maps platforms to native runners` | - |
| `publish-worker.yaml: build shards run on the matrix runner` | - |
| `publish-worker.yaml: build shards push per-platform BY DIGEST (#602)` | - |
| `publish-worker.yaml: shards do NOT push the same tag per shard (#602 regression guard)` | - |
| `publish-worker.yaml: each shard exports + uploads its digest as an artifact (#602)` | - |
| `publish-worker.yaml: merge job assembles the multi-arch manifest via imagetools (#602)` | - |
| `publish-worker.yaml: merge resolves tags from inputs (version + optional latest) once (#602)` | - |
| `publish-worker.yaml: merge login uses the parameterised registry (not hardcoded ghcr.io)` | - |
| `publish-worker.yaml: every job's grant is pinned as an exact set (#957)` | - |
| `publish-worker.yaml: the publish job carries the same-repo guard (#766)` | - |

### test/bats/unit/readme_file_table_spec.bats (2)

The "What's included" table in `README.md` is a file INDEX, so every row
names a real path -- and nothing checked that (#957). Item 3 of that issue
was one such row: it still called the per-repo runtime config `setup.conf`
long after the rename to `.setup.conf`, and the stale-path lint that would
normally catch it (`script/test/drivers/stale_setup_conf.sh`) scans
`dist/**/*.sh` only, so the row could be edited back to the old name with
the suite green. Rows mix two vantage points on purpose -- base-relative
paths and CONSUMER-relative ones (`build.sh`, `.setup.conf`, `config/`, what
a downstream repo sees once init.sh has run) -- so a row counts as resolved
under the repo root, `dist/` or `script/`.

| Test | Description |
|------|-------------|
| `README file table: every row names a path that exists (#957)` | Every row resolves under one of the three roots; a stale path is reported by name |
| `README file table: the scan actually finds the rows (#957)` | Floor on the row count, so a renamed heading cannot silence the check above |

### test/bats/unit/readme_sync_spec.bats (34)

Unit tests for the localized-README drift guard (refs #846, #873):
`script/test/sync-readme-hashes.sh` (`_sync_readme_hashes`, the generator
that stamps each translated section with the hash of the English section it
was translated against AND of the translated section itself) and
`script/test/drivers/readme_sync.sh` (`_run_readme_sync`, the read-only lint
that compares those records against the current `README.md`). The English
author changes nothing and the translator never types a hash, so the guard
has to answer three questions per translated file -- is this section stale,
is it missing, is it deliberately untranslated. A fourth block PERFORMS the
silencing case (refs #873) -- edit the English, run the generator, expect a
green tree -- and asserts it does not work, because recording only the
English hash made a bare re-stamp indistinguishable from a re-translation.
Driven over throwaway fixture trees, plus a real-tree pair proving
`doc/readme/` is stamped and clean today. That pair asserts on a CAPTURE of
the tracked files, never on the tree itself: the capture is taken twice and
accepted only when both passes agree, because four sequential reads of a
tree this spec does not own can return a `README.md` the translations beside
it were never stamped against, and the generator then correctly refuses to
re-stamp -- reporting a defect in the subject that was really a defect in
the capture (#965).

| Test | Description |
|------|-------------|
| `_run_readme_sync: FAILS when an English section is rewritten in place and the translation is untouched (#846)` | The drift that motivated the guard |
| `_run_readme_sync: names the drifted SECTION, not just the file (#846)` | Per-section reporting, untouched sections silent |
| `_run_readme_sync: FAILS on an English section with no marker in a translation (#846)` | Structural case: MISSING |
| `_run_readme_sync: PASSES a tree the generator has just stamped (#846)` | Clean after sync |
| `_run_readme_sync: PASSES again after an English edit, a re-translation and a re-run of the generator (#846)` | Re-stamp is the one-command fix, once the translation moved too |
| `_run_readme_sync: EXEMPTS a section declared untranslated with sync-skip (#846)` | Deliberate omission, declared not forgotten |
| `_run_readme_sync: FAILS on an UNSTAMPED marker (id written, generator never run) (#846)` | An id with no hash claims nothing |
| `_run_readme_sync: FAILS on a marker naming an id that is not an English section (#846)` | UNKNOWN id (rename / removal / typo) |
| `_run_readme_sync: FAILS on the same id claimed twice in one translation (#846)` | DUPLICATE claim |
| `_run_readme_sync: FAILS on a sync marker that is not followed by a heading (#846)` | MISPLACED marker |
| `_run_readme_sync: ignores ATX-looking lines inside fenced code blocks (#846)` | Fenced shell comments are not headings |
| `_run_readme_sync: trailing whitespace in the English body does not flip the hash (#846)` | Hash-input normalisation |
| `_run_readme_sync: a nested subsection is its own section, the parent body stops at it (#846)` | Section granularity |
| `_run_readme_sync: FAILS when two English headings share one slug (ambiguous id) (#846)` | AMBIGUOUS section id |
| `_sync_readme_hashes: stamps an id-only marker with the English section hash (#846)` | The translator writes the id, the tool writes the hash |
| `_sync_readme_hashes: re-stamps a stale hash (#846)` | Generator updates an existing record |
| `_sync_readme_hashes: is idempotent on an already-stamped tree (#846)` | No churn on a clean tree |
| `_sync_readme_hashes: leaves the translated prose untouched (stamps only markers) (#846)` | Only marker lines are rewritten |
| `_sync_readme_hashes: reports the sections a translation is still missing (#846)` | Advisory, never auto-declared |
| `_sync_readme_hashes: REFUSES to re-stamp a section whose English moved while the translation did not (#873)` | The silencing case, performed; the marker must not move |
| `_sync_readme_hashes: an English-only edit plus a sync run leaves the lint RED (#873)` | End to end: syncing does not buy a green tree |
| `_sync_readme_hashes: refusing one section still stamps the untouched ones (#873)` | Refusal is per section, not a whole-run abort |
| `_sync_readme_hashes: re-stamps when the translation moved together with the English (#873)` | The working case still takes one command |
| `_sync_readme_hashes: --accept records a reviewed no-op and clears the lint (#873)` | The English-typo escape hatch, explicit and by name |
| `_sync_readme_hashes: --accept clears only the section it names (#873)` | Accepting one section is not a blanket pass |
| `_sync_readme_hashes: records the translation's own hash beside the English one (#873)` | Both sides stored, so a diff shows which one moved |
| `_run_readme_sync: FAILS when the translated prose changed since it was stamped (#873)` | UNRECORDED: the translation-side record must stay fresh |
| `_run_readme_sync: FAILS when the English README is missing (#846)` | No vacuous pass without a source |
| `_run_readme_sync: FAILS when no translation files are found (#846)` | No vacuous pass without translations |
| `_run_readme_sync: the REAL doc/readme/ tree is stamped and clean today (#846)` | Live tree clean |
| `_assert_same_tree: a failure names WHAT differed, not just that something did (#965)` | - |
| `_sync_readme_hashes: is a no-op on the REAL tree (already stamped) (#846)` | Live tree already generator-exact |
| `_capture_readme_baseline: a capture the source changed under is DISCARDED, not used (#965)` | A torn read must never become the baseline a verdict rests on |
| `_capture_readme_baseline: a source that never settles FAILS loudly, it does not hand back a torn set (#965)` | No snapshot means nothing to assert on; say so rather than pick a read |

### test/bats/unit/reclaim_wiring_spec.bats (32)

| Test | Description |
|------|-------------|
| `compose.yaml records the checkout path on the network it creates` | - |
| `the label compose writes is the label the collector reads` | - |
| `a compose invocation that cannot say which checkout it is, is refused` | - |
| `every entry point that drives compose supplies the checkout path` | - |
| `no caller hands the project sweep a repo root` | - |
| `test.sh installs the reclaim as an EXIT handler on the direct-run path only` | - |
| `test.sh arms the reclaim where a compose project is actually minted` | - |
| `a dispatch that refuses to start reclaims nothing` | - |
| `a reclaim failure does not change the suite's verdict` | - |
| `a reclaim failure does not turn a green run red` | - |
| `a reclaim failure is reported rather than swallowed` | - |
| `the reclaim still runs when the suite FAILED -- litter from a red run is litter` | - |
| `retiring a tooling image is never automatic` | - |
| `a run that minted no compose project reclaims nothing` | - |
| `just test system reclaims when it is done, pass or fail` | - |
| `stop.sh reclaims after the project comes down` | - |
| `stop.sh's reclaim cannot fail the stop` | - |
| `the verbs that BEGIN a flow do not reclaim` | - |
| `prune.sh exposes the scoped reclaim as its own mode` | - |
| `every language's --orphan-projects help stamps the path on both artifacts (#997)` | the help is four translations of one promise, and a half-updated one is worse than an untouched one: it tells a reader the mode collects an image and then tells them only the network carries the proof of ownership, which is the sentence someone reaches for when deciding whether the mode can be trusted with an image. |
| `--all does not quietly acquire the scoped reclaim` | - |
| `the daemon-wide prune targets are untouched` | - |
| `the scoped reclaim is reachable through just, with no new namespace` | - |
| `just test stop ends this checkout's self-test project` | the verb the issue asked for. Run for real, because a recipe is a seam and a grep cannot tell a working seam from a broken one. |
| `just test stop asks the single producer for the name instead of deriving a second` | two derivations that agree today drift tomorrow, and a stop pointed at the wrong project silently tears down nothing. |
| `just test stop forwards its arguments to the wrapper` | -v and --dry-run are how an operator inspects a teardown before trusting it; a recipe that swallowed them would make the verb unusable for that. |
| `just test stop hands compose every value compose.yaml demands` | compose interpolates the whole file for `down` too, so a stop missing one `${VAR:?}` dies naming four services and tears nothing down. --dry-run cannot see it, which is how it shipped once. |
| `compose.yaml records the checkout path on the image it builds` | the producer side of the image rule: a collector can only read back what something recorded, so an unstamped image is uncollectable forever. |
| `the image stamp is refused rather than defaulted, like every other` | a default would create artifacts nobody can attribute, and the failure has to land on the invocation that would create them. |
| `the tooling image is NOT stamped, because it is shared on purpose` | one image serves every checkout whose inputs hash alike, so a checkout label there would name its builder and collecting on it would delete an image live checkouts still resolve. |
| `every recipe that reaches docker states its lifecycle` | the anti-decay mechanism. Every other assertion in this file names verbs by hand and so answers only for the recipes that existed when it was written -- which is the failure the issue is about. |
| `the derived population is not empty, and reaches both namespaces` | a parser that quietly matched nothing would make the check above pass for every tree, which is how a derived population fails. |

### test/bats/unit/release_archive_spec.bats (26)

Unit coverage for `script/ci/release-archive.sh`, the payload assembler the
reusable release worker runs at tag time. Synthetic manifests over
synthesised repo trees, so absence -- the case the previous hardcoded `cp
-r` list could never survive and no test ever drove -- is expressible: an
optional path missing degrades the archive, a required one missing fails
naming the path and what its absence costs.

| Test | Description |
|------|-------------|
| `release-archive: archives a required path that exists` | A declared required path present is copied into the archive |
| `release-archive: a missing required path fails naming that path, not a bare cp error (#914)` | Names the path, the item and the consequence; never a bare `cp: cannot stat` |
| `release-archive: a missing required path leaves no half-built archive (#914)` | Validation precedes any copy: no partial payload survives a failure |
| `release-archive: reports every missing required path in one pass (#914)` | Both gaps reported in one run, with the count |
| `release-archive: a consumer tree lacking an optional path still archives (#914)` | The regression class: one absent optional path no longer costs the release |
| `release-archive: an absent optional path is reported by name, never silently dropped (#914)` | Tolerance is not silence -- the tag log names what is not in the archive |
| `release-archive: names every archived path so the tag log shows the payload` | The tag log shows the payload that was assembled |
| `release-archive: an entry archives whichever candidate layout the consumer has (old) (#914)` | `test/smoke/` consumer archives at its own path |
| `release-archive: an entry archives whichever candidate layout the consumer has (new) (#914)` | `test/bats/smoke/` consumer archives at its own path |
| `release-archive: a tree carrying both candidate layouts archives both (#914)` | A mid-migration tree loses neither layout and they do not collide |
| `release-archive: a required entry with no candidate present names all of them (#914)` | Every candidate path is named in the failure |
| `release-archive: a nested path keeps its relative position in the archive (#914)` | A nested path is not flattened (which would collide the two layouts) |
| `release-archive: symlinked wrappers still resolve inside the archive (#914)` | `cp -r` keeps symlinks; they resolve because `.base/` is required and travels along |
| `release-archive: creates the archive directory when it does not exist` | The step no longer needs a separate `mkdir -p` |
| `release-archive: archives extra_files that exist` | Caller-supplied extras are archived |
| `release-archive: an absent extra_file is tolerated, as it always was` | Extras have never been mandatory, and still are not |
| `release-archive: an extra_file escaping the repo root is refused, not copied out (#914)` | `..` in a caller path would write outside the archive: refused |
| `release-archive: an absolute extra_file path is refused (#914)` | Same guard for an absolute caller path |
| `release-archive: an unknown manifest kind fails loudly, naming it (#914)` | Fail closed: a typo'd kind never decides whether a path is archived |
| `release-archive: an entry declaring no candidate path is a config error, not an absent path (#914)` | An empty `<paths>` column is a typo, and a typo is not an absence |
| `release-archive: an entry missing a column is a config error, not a nameless report (#914)` | A short line under-declares the entry: refused, never half-read |
| `release-archive: a manifest declaring nothing is a config error, not an empty archive (#914)` | An empty payload is a config error, not an empty release |
| `release-archive: an all-optional manifest matching nothing refuses to build an empty archive (#914)` | Tolerance stops short of uploading an empty tarball as a release |
| `release-archive: a missing manifest file is a config error` | Config error (exit 2), distinct from a payload gap |
| `release-archive: refuses a manifest path that escapes the repo root (#914)` | Same escape guard on the declared paths |
| `release-archive: --list prints the declared payload with its required/optional split` | The payload contract is readable without running an archive |

### test/bats/unit/release_test_tools_yaml_spec.bats (21)

Structural assertions for `.github/workflows/release-test-tools.yaml`. Locks
the publish surface that downstream Dockerfile.example's `FROM
${TEST_TOOLS_IMAGE} AS test-tools-stage` depends on. The workflow has three
publish modes:

1. **Tag push (`v*`)** — multi-arch `:<version>` + `:latest`. Cuts the
release downstream consumers pin via `inputs.test_tools_version`. 2. **Main
push** (#317 P2) — multi-arch `:main` rolling tag. Used by self-test.yaml's
Obtain step to skip from-source rebuilds. Paths filter (gotcha 3) restricts
to commits that touched `dockerfile/Dockerfile.test-tools` or this workflow.
3. **workflow_dispatch** — manual `:latest` republish, kept unfiltered for
bootstrap.

Smoke step uses `steps.tags.outputs.smoke` so it always pulls the tag the
current trigger produced (rather than statically pulling `:latest`, which
would leave a freshly-pushed `:main` unverified).

Grouped by concern:

- Triggers on `v*` tag push (existing)

- Triggers on main push (#317 P2)

- Main push trigger has `paths:` filter limiting to Dockerfile.test-tools +
workflow self (#317 P2 gotcha-3)

- Triggers on `workflow_dispatch` (existing)

- Resolve tags step: 3 publish modes (`v*` + `main` + dispatch) emit correct
tag sets and `smoke` output

- Smoke step pulls trigger's tag via `steps.tags.outputs.smoke` (#317 P2)

- Native-runner matrix (#587): drops `setup-qemu-action`; `compute-matrix`
maps platforms to native runners; build shards run on `matrix.runner`; build
per-platform + push by digest; `merge` job creates the manifest via
`imagetools`

- Declares `packages: write` permission

| Test | Description |
|------|-------------|
| `release-test-tools.yaml: triggers on tag push v* (existing)` | - |
| `release-test-tools.yaml: triggers on main push (#317 P2)` | - |
| `release-test-tools.yaml: main push trigger has paths filter limiting to Dockerfile.test-tools + workflow self (#317 P2 gotcha-3)` | - |
| `release-test-tools.yaml: triggers on workflow_dispatch (existing)` | - |
| `release-test-tools.yaml: Resolve tags step handles v* tag push -> :<ver> + :latest` | - |
| `release-test-tools.yaml: Resolve tags step handles main push -> :main rolling tag (#317 P2)` | - |
| `release-test-tools.yaml: Resolve tags step emits a smoke output tracking the current trigger's tag (#317 P2)` | - |
| `release-test-tools.yaml: smoke step pulls the trigger's tag (not statically :latest) (#317 P2)` | - |
| `release-test-tools.yaml: drops docker/setup-qemu-action (native arm64 runner, #587)` | - |
| `release-test-tools.yaml: compute-matrix job maps platforms to native runners (#587)` | - |
| `release-test-tools.yaml: build shards run on the matrix runner (#587)` | - |
| `release-test-tools.yaml: build shards build per-platform and push by digest (#587)` | - |
| `release-test-tools.yaml: merge job creates the multi-arch manifest via imagetools (#587)` | - |
| `release-test-tools.yaml: declares packages: write permission for GHCR push` | - |
| `release-test-tools.yaml: the build job carries the same-repo guard (#766)` | - |
| `release-test-tools.yaml: merge job checks out the repo so the smoke step can read the pins (#947)` | The precondition the other five rest on -- with no checkout in the merge job there is no Dockerfile to read the pins out of, and the whole comparison degrades to the exit-0 check it replaced |
| `release-test-tools.yaml: smoke step reads the shellcheck pin from the Dockerfile (#947)` | The expectation has to come from the pin: a version literal in the workflow would be a second place to bump, and two literals agreeing prove only that somebody edited both |
| `release-test-tools.yaml: smoke step reads the hadolint pin from the Dockerfile (#947)` | The pin that sat 3.8 years stale behind an exit-0 check -- the concrete drift this whole step was rewritten for, so its half of the comparison is asserted separately from shellcheck's |
| `release-test-tools.yaml: smoke step COMPARES the reported versions, not just exit 0 (#947)` | Reading two numbers is not comparing them: holding the pin and running `<tool> --version` still passes for an image whose linters are years old, which is exactly the state that shipped |
| `release-test-tools.yaml: smoke step fails loudly when a pin and a binary disagree (#947)` | A comparison whose mismatch branch only warns is not a gate -- the publish would go out with the wrong linters and a green log |
| `release-test-tools.yaml: smoke step refuses an unreadable pin rather than passing (#947)` | The failure mode a moved release URL produces: an empty expectation compared against an empty reading agrees with itself, which is the shape of pass the whole step exists to refuse |

### test/bats/unit/release_version_spec.bats (12)

Unit tests for `script/ci/release-version.sh`, the resolver that decides
WHICH version `release-worker.yaml` cuts and whether it is a prerelease
(#829). The worker used to read both off `github.ref_name`, which only
exists on a tag push; a downstream that wants to auto-release a merged
dependency bump cannot push a tag with `GITHUB_TOKEN` and have the tag event
fire (GitHub's recursion guard), so it calls the worker directly and the ref
is a BRANCH. The resolver takes the caller's `version` input when there is
one, falls back to the ref otherwise, and derives the prerelease flag from
the version it resolved rather than from the ref -- the same defect shape as
#1012, where a decision about a version was read off a ref that did not
carry one.

Every unresolvable case REFUSES: an input the resolver cannot read becomes
the name of a git tag and a published GitHub Release, so "cannot determine"
must not fall through to the ref, to a default, or to any name that is
already consumed (#1012's `else` arm resolved to `:latest`). A refusal
prints nothing on stdout, so a caller appending stdout to `GITHUB_OUTPUT`
ends up with no `version` key at all and every downstream `if:` on it is
false.

| Test | Description |
|------|-------------|
| `release-version: no input resolves the pushed tag, not a prerelease` | The pre-existing path: a tag push, no `version` input. The resolved version is the tag and the release is not a prerelease, so adding the input does not move what a tag-triggered release cuts today. |
| `release-version: no input marks an rc tag as a prerelease` | A hyphen in the resolved version is what marks a prerelease, which is the test `release-worker.yaml` already applied to `github.ref_name`. On the tag path the answer must not change. |
| `release-version: the version input wins over a branch ref` | The point of the input: called from a merged bump on the default branch, `github.ref_name` is `main`, which is not a version at all. The caller's version wins and the ref is never consulted. |
| `release-version: a prerelease input is a prerelease even from a branch ref` | The #1012 shape, in the direction that matters here: a prerelease cut from a branch. If the flag were still read off the ref, `main` carries no hyphen and an RC would publish as a full release. It is derived from the resolved version instead. |
| `release-version: a whitespace-only input means not supplied` | `version` is declared with an empty default, so "not supplied" reaches the resolver as an empty (or whitespace-only) string and must mean the tag path rather than a refusal. |
| `release-version: refuses an input that is not a version, naming it` | #1012's `else` arm resolved an unrecognised input to `:latest`, the most-consumed name in the registry. The inverse is the rule here: a version the resolver cannot read is refused by name, never resolved to anything. |
| `release-version: refuses a version missing the v prefix` | The resolved value becomes a git tag and downstream repos pin `vX.Y.Z` (ADR-00000002). A bare `1.2.3` is refused rather than silently prefixed: normalising would publish a tag the caller did not ask for. |
| `release-version: refuses a two-component version` | A two-component version cannot be classified -- there is no patch component to say whether this is the Z the caller means -- so it is refused rather than completed with a zero. |
| `release-version: refuses a version carrying shell metacharacters` | The resolved value is interpolated into a tag name and a release title. The shape check is what keeps caller-controlled text from carrying shell or ref metacharacters through, so a version with a command in it is refused. |
| `release-version: refuses a ref that is not a version` | The fallback is subject to the same rule as the input. A tag that is not a version reaches this worker whenever a repo pushes one (the caller's `call-release` fires on any tag), and releasing under a name nothing can pin is the failure being refused. |
| `release-version: refuses when neither input nor ref is supplied` | Neither source supplied is the caller-contract error, and it must be named as such rather than producing an empty version. |
| `release-version: a refusal prints nothing on stdout` | The fail-closed property the whole design rests on. The workflow appends this script's stdout to GITHUB_OUTPUT; a refusal that printed a partial `version=` line would leave a value for a later step to release under. A refusal writes to stderr only, so there is no output key and every `if:` reading it is false. |

### test/bats/unit/release_worker_yaml_spec.bats (14)

Structural assertions for `.github/workflows/release-worker.yaml`'s archive
step. The step used to hardcode the payload as operands of one `cp -r`; `cp`
aborts non-zero on a missing operand and the `run:` step is `bash -e`, so
any consumer lacking one standard path lost its release at tag push --
twice, on a different path each time (#558, then #914), each fixed by
re-editing the list to match base's own layout. The payload now lives in a
declared manifest assembled by `script/ci/release-archive.sh`; these tests
lock the workflow's half of that split (the payload's own behaviour is
covered by `release_archive_spec.bats` and
`release_archive_contract_spec.bats`).

Grouped by concern:

- No hardcoded payload path list survives in the workflow (#914)

- Archive step delegates to the assembler + its declared manifest

- Assembler is version-matched to the worker (`job_workflow_sha`, checkout
path)

- Caller input reaches the step via `env:`, never run-block interpolation

- Every job's grant pinned as an exact per-job entry set, over the job list
derived from the file (`preflight: contents: read`, `release: contents:
write`)

- The released version is RESOLVED (`script/ci/release-version.sh`) rather
than read off `github.ref_name`, so the worker can be called directly by a
downstream repo auto-releasing a merged dependency bump -- a run that has no
tag ref to read (#829)

| Test | Description |
|------|-------------|
| `release-worker.yaml: archive step names no hardcoded payload path list (#914)` | - |
| `release-worker.yaml: archive step delegates to script/ci/release-archive.sh (#914)` | - |
| `release-worker.yaml: archive step passes the declared payload manifest (#914)` | - |
| `release-worker.yaml: release job checks out base at github.job_workflow_sha (#914)` | - |
| `release-worker.yaml: the base checkout the archive step runs is the one it reads (#914)` | - |
| `release-worker.yaml: extra_files reaches the archive step via env (#914)` | - |
| `release-worker.yaml: no caller input is interpolated into the archive run block (#914)` | - |
| `release-worker.yaml: every job's grant is pinned as an exact set (#957)` | - |
| `release-worker.yaml: version is an optional input with an empty default (#829)` | The input that makes a direct call possible at all. A downstream repo cannot auto-release by pushing a tag -- an event created with the default GITHUB_TOKEN starts no workflow run -- so it calls this worker with the version it computed. Declared optional with an empty default, so every existing tag-triggered caller keeps working unchanged (#829). |
| `release-worker.yaml: the version is resolved by script/ci/release-version.sh (#829)` | The resolution is a tested script, not an expression in the YAML. Same split as the preflight validator and the archive assembler: the logic runs under `just test`, the workflow keeps the GITHUB_OUTPUT plumbing (#829). |
| `release-worker.yaml: the version input reaches the resolver via env (#829)` | The caller's input reaches the resolver through `env:`, the same rule the archive step follows -- an input interpolated into a `run:` block is caller-controlled text spliced into the shell before bash sees it (#829). |
| `release-worker.yaml: the release is cut for the resolved version (#829)` | Without an explicit tag_name the release action falls back to the ref that started the run, so a direct call would try to publish a release for a BRANCH. The tag is the resolved version, whichever source it came from (#829). |
| `release-worker.yaml: the archive is named from the resolved version (#829)` | The archive name and the release tag must be the one value. The step used to build the name from GITHUB_REF_NAME, which on a direct call is a branch name -- an archive called `<repo>-main` attached to a release tagged vX.Y.Z (#829). |
| `release-worker.yaml: prerelease is derived from the resolved version, not the ref (#829)` | The #1012 shape: a decision about a version read off a ref that does not carry one. `contains(github.ref_name, "-")` is false for every branch, so a direct call cutting an RC would publish it as a full release -- and `publish-worker` defaults consumers to whatever the newest full release left. The flag comes from the resolver, which derived it from the version actually being released (#829, refs #1012). |

### test/bats/unit/residue_guard_spec.bats (22)

The live-tree residue guard in `script/test/test.sh`: the EXECUTED answer to
"did a spec write into the checkout it does not own". Every compose dispatch
snapshots the checkout either side of the bats phase and fails naming any
path that differs -- no command list, no spelling to miss, and no false
positive on the suite's own setup, which is what a static scan of the specs
could never manage (it was widened three times and was still blind to six
spellings it claimed). Measured end to end: a planted spec writing into
`doc/readme/` ran GREEN with the guard off and left the file behind; with
the guard on the same run reported `ci_live_tree_residue` naming that path
and exited 1 while bats still said `ok 1`.

The check is TWO snapshots, not one, and that is its whole usability: a bare
"is the tree clean" check needs a clean tree and would red every developer
with work in flight, whereas an edit made BEFORE the run appears in both and
cancels. Each record is status code + content hash + path, so a spec
overwriting a file the developer was already editing still moves it. Ignored
trees (`coverage/`, `log/`, `.prev-release/`) are absent by construction --
the list is git's, and git's means all of it: `.gitignore`,
`.git/info/exclude` and `core.excludesFile` alike, so an ignore rule this
repo never wrote silences the guard for the paths it covers. It is inert
outside a git checkout, and it must run host-side: a worktree's `.git` is a
FILE naming a gitdir the container never mounts.

That same cancelling made the alarm ONE-SHOT, which is a hole in the shape
rather than a slip: residue left by run N is on disk before run N+1 starts,
so run N+1 read it as "in flight" and went green with the defect unchanged
-- measured, run 1 exit 1 naming the path, run 2 exit 0. The guard now
REMEMBERS what it named, in a record under the git dir (never in the working
tree, where it would be residue itself, and per-worktree, so two checkouts
do not inherit each other's). A remembered path is reported again on every
run while it is still changed in the checkout and drops out the moment it is
gone: cleaning up is the acknowledgement and nothing has to be typed for it.
Two other shapes were weighed and rejected -- taking the baseline from the
index removes the laundering and with it the whole reason the guard is
usable, and narrowing what BEFORE may cancel is a guess about which changes
are developer-shaped that is wrong for anyone adding a file.

The cost to the dirty working tree is unchanged: an edit made before a run
cancels, is never named, and is therefore never remembered. Only a path the
guard has already reported out loud can become sticky, which is the one
false positive two snapshots cannot cancel -- an edit made WHILE the suite
ran. That is what `TEST_RESIDUE_GUARD=0` is for, and it now drops the record
on its way past, so there is one knob rather than two.

The report keeps the two facts it now has apart. The lead sentence names
what THIS run wrote; a carried path gets a clause of its own that opens by
saying the run changed nothing when that is what happened. Built from the
union, as it first was, every re-run of an unfixed residue asserted a write
that did not happen in it.

Four blind spots and one price, stated because a guard whose limits are
implied gets believed past them, and each with a case that measures it
rather than an assurance.

- A spec that writes and then removes its own traces before the phase ends
is invisible; closing that means snapshotting per SPEC, in the in-container
driver, which cannot read a worktree's gitdir at all.

- Anything git ignores, through any of the files git reads to decide that.

- Anything under `.git/`: `git status` never reports it, so a planted hook,
config or alternates entry is unseen -- excluded with a reason rather than
closed, because git rewrites its own dir on almost any command (the guard's
own `git status` refreshes the index) and narrowing that to "the parts that
matter" is an open-set roster, the exact shape this round deleted. A case
pins both the silence and how narrow it is: one directory up, the same write
is still named.

- A permission change git does not track. Git records the exec bit and
nothing else of a file's mode, so 644 -> 755 IS named while 644 -> 600
leaves both the status line and the content hash where they were.

- The price: `TEST_RESIDUE_GUARD=0` ends the alarm permanently for a spec
that writes the SAME bytes every run, because the path is then identical in
both snapshots and no memory is left to say otherwise. It stays permanent
because an acknowledged path and an unfinished edit are the same thing at
the phase boundary -- same status line, same hash -- so expiring the
acknowledgement re-raises the developer's edit on a timer and scoping it
points at the same absent signal. The failure message now says what the flag
gives up at the moment it offers it, and a case pins the limit: bytes that
CHANGE after an acknowledgement are named again.

| Test | Description |
|------|-------------|
| `_residue_paths: a file the run CREATED is named (#965)` | The base case: an untracked file that was not there before |
| `_residue_paths: an edit already in flight before the run is NOT named (#965)` | The cry-wolf case; a guard that reds a dirty working tree is switched off within the week |
| `_residue_paths: a SECOND edit to an already-dirty file IS named (#965)` | Why the record carries a content hash: both snapshots show the same ` M` status line |
| `_residue_paths: a tracked file the run DELETED is named (#965)` | Residue is any difference, not only an addition |
| `_residue_paths: a gitignored path the run wrote is NOT named (#965)` | coverage/, log/ and .prev-release/ are the suite's own; git's ignore list is the allowlist |
| `_residue_paths: the ignore list is git's whole exclude stack, not .gitignore alone (#965)` | `.git/info/exclude` silences it too, and the same write one directory over is still named |
| `_residue_paths: a path containing a space is named whole (#965)` | Read NUL-separated with the path last, so porcelain quoting cannot truncate the report |
| `_residue_paths: a write the run UNDID before the snapshot is NOT named (#965)` | The first blind spot, measured: neither undo shape reaches `git status`, and the same write left in place is still named |
| `_residue_paths: a write under .git/ is EXCLUDED, and the exclusion is narrow (#965)` | - |
| `_residue_paths: a permission change is seen only where git tracks one (#965)` | 644 -> 600 is invisible, 644 -> 755 is named: the shape of the limit, not just its existence |
| `_residue_check: fails naming the path, and says what to do about it (#965)` | The report has to be actionable without opening the guard |
| `_residue_check: passes on a run that changed nothing (#965)` | The path every green gate takes |
| `_residue_check: a residue it already named is named AGAIN on the next run (#965)` | - |
| `_residue_check: a run that changed nothing does not report that it did (#965)` | The lead sentence is about THIS run; a carried path says so in its own clause |
| `_residue_check: the memory clears when the residue is GONE (#965)` | - |
| `_residue_forget: an acknowledged path goes quiet with the file still there (#965)` | - |
| `_residue_forget: an acknowledgement is permanent while the bytes stay the same (#965)` | The escape hatch's price, decided and pinned: silent for an identical rewrite, named again when the bytes change |
| `the pending record is kept OUTSIDE the working tree, so it is not residue itself (#965)` | - |
| `_residue_before_snapshot: a baseline it could not take is a FAILURE, not an empty one (#965)` | - |
| `_residue_guard_available: answers no outside a git checkout (#965)` | A released tarball still runs the suite; absence costs nothing |
| `_residue_guard_available: is switched off by TEST_RESIDUE_GUARD=0 (#965)` | The escape hatch for an edit made WHILE the suite runs, asserted in both directions |
| `the compose dispatch is what runs the guard, not a caller that could forget (#965)` | Wired into the one host-side point every bats dispatch passes through |

### test/bats/unit/resolve_doc_counts_spec.bats (11)

Unit coverage for `script/test/resolve-doc-counts.sh` -- the one command
that resolves a `doc/test/*.md` merge conflict. Two halves: the toil
(markers go, figures come back regenerated from the merged spec tree) and
the safety (a relative root, a surviving marker, an unhappy drift gate, and
any disagreement regeneration cannot settle are all refused loudly rather
than resolved to whichever side the collapse happened to keep).

| Test | Description |
|------|-------------|
| `_resolve_doc_counts: FAILS on a RELATIVE root, naming it (#857)` | - |
| `_resolve_doc_counts: FAILS on a nonexistent root, naming it (#857)` | - |
| `_resolve_doc_counts: resolves a ceiling conflict by recomputing, not by taking a side` | The conflict this tool did not cover, and the reason base#1024 exists: two branches that each described tests each lowered the ceiling, so the merge conflicts on that line and the right answer is NEITHER side's -- the descriptions compose, so the merged tree measures lower than both. Recomputing is the only resolution, which is exactly what this tool already does for the documents. |
| `_resolve_doc_counts: collapses a counter-only conflict and regenerates (#857)` | - |
| `_resolve_doc_counts: drops the diff3 base section too (#857)` | - |
| `_resolve_doc_counts: catalogue prose survives a conflict because both sides regenerate it (#857)` | What used to need reconciling, and no longer can. Each side's collapse used to carry hand-written descriptions the generator could not re-derive, so a mechanical collapse dropped a sentence nothing would put back and this script had to merge them row by row. Descriptions are authored in the specs now, so both collapses regenerate the SAME rows from the SAME merged spec tree -- whichever side a conflicted counter line came from. This case pins that the prose survives a conflict without any reconciliation code left to do it. |
| `_resolve_doc_counts: an unconflicted tree is verified, not rewritten (#857)` | - |
| `_resolve_doc_counts: FAILS when the sides differ in prose the generator does not derive (#857)` | - |
| `_resolve_doc_counts: FAILS when the sides of a generated file outside doc/test differ in prose (#1024)` | The same trap, in the file that is only ONE LINE generated. The ceiling lives in a 400-line hand-written driver (base#1024), so adopting a side there adopts an argument somebody wrote, not a figure -- the doc/test half of this refusal has a case and this half had none, which left the guard free to be deleted invisibly. The two sides here disagree about a comment AND about the ceiling: the ceiling alone would resolve by recomputation, so only the comment can make it refuse. |
| `_resolve_doc_counts: FAILS when the drift gate is unhappy afterwards (#857)` | - |
| `_resolve_assert_no_markers: FAILS naming the file and line of a survivor (#857)` | - |

### test/bats/unit/resolve_spec.bats (25)

Mirrors `lib/resolve.sh`. The host-detection resolvers in isolation:
`_resolve_gpu` / `_resolve_gui` (auto / force / off), `_resolve_runtime` and
`_resolve_build_network` over `_detect_jetson`, the documented
`SETUP_DETECT_JETSON` / `SETUP_DETECT_DRI_GROUPS` operator-override contract
(#760) for `_detect_jetson` / `_detect_dri_groups`, and
`_compute_conf_hash`.

| Test | Description |
|------|-------------|
| `SETUP_DETECT_DRI_GROUPS operator override forces the GID list verbatim (#496)` | - |
| `SETUP_DETECT_DRI_GROUPS override echoes repeated GIDs verbatim (no stat dedup) (#496)` | - |
| `_resolve_gpu auto + detected=true => enabled` | - |
| `_resolve_gpu auto + detected=false => disabled` | - |
| `_resolve_gpu force => enabled regardless of detection` | - |
| `_resolve_gpu off => disabled regardless of detection` | - |
| `_resolve_gui auto + detected=true => enabled` | - |
| `_resolve_gui force => enabled regardless` | - |
| `_resolve_gui off => disabled regardless` | - |
| `SETUP_DETECT_JETSON=true operator override forces Jetson detection` | - |
| `SETUP_DETECT_JETSON=false operator override forces non-Jetson detection` | - |
| `_resolve_runtime auto on Jetson => nvidia` | - |
| `_resolve_runtime auto off Jetson => empty` | - |
| `_resolve_runtime nvidia => always nvidia` | - |
| `_resolve_runtime off => empty` | - |
| `_resolve_runtime empty => empty` | - |
| `_resolve_runtime unknown mode falls through to empty (safe default)` | - |
| `_resolve_build_network auto on Jetson => host` | - |
| `_resolve_build_network auto off Jetson => empty` | - |
| `_resolve_build_network host => always host (explicit override wins)` | - |
| `_resolve_build_network bridge / none / default pass through` | - |
| `_resolve_build_network off / empty => empty (explicitly suppressed)` | - |
| `_resolve_build_network unknown mode falls through to empty` | - |
| `_compute_conf_hash returns a sha256-shaped hex string` | - |
| `_compute_conf_hash differs when per-repo setup.conf changes` | - |

### test/bats/unit/reusable_worker_permissions_spec.bats (3)

Least privilege across EVERY reusable workflow in `.github/workflows/`,
rather than the one file #957 was filed against. The population is derived:
each `*.yaml` / `*.yml` whose parsed `on:` mapping declares `workflow_call`,
so a reusable worker added tomorrow is covered the day it lands however its
author spelled the trigger key. A second reading over the raw text -- every
file whose code lines name `workflow_call` at all must be in the derived
list, and nothing else may be -- fails if the two disagree, so a spelling
the parser stopped resolving cannot drop a worker out of the scan silently.
That derivation is what found the rest of the gap --
`multi-distro-build-worker.yaml` had three jobs and no `permissions:` line
anywhere, and `publish-worker`'s `compute-matrix` and `release-worker`'s
`release` were two more, all of them running on the CALLING repo's whole
token while build-worker.yaml's own guard was green.

Which scopes a job may name is deliberately NOT asserted here
(publish-worker holds `packages: write` legitimately, release-worker
`contents: write`); the property here is that the grant is DECLARED rather
than inherited. The exact per-job sets live with each worker's own spec, and
the third test holds that delegation to its word: for every DERIVED reusable
worker it requires some other spec in the tree that APPLIES
`yaml_permission_surface` to that very file -- resolved from the call's own
argument -- and names the worker that has none. The division was prose three
times before it was a guard. As a promise about jobs, every grant outside
build-worker.yaml was pinned by nothing and widening one to `packages:
write` passed the whole suite; as a promise about FILES backed by an
enumeration of the four specs that existed, a fifth worker landing with an
unpinned `contents: write` still passed; and as two independent substring
questions of one file -- does its text name the function, does its text name
the worker -- a spec that pinned worker A while merely MENTIONING worker B
certified B, which two of today's four workers sit one line away from.

| Test | Description |
|------|-------------|
| `reusable workers: every one of them yields at least one job (#957)` | The guard for the guard: every assertion here is "nothing came back wrong", which an extractor returning nothing at all satisfies perfectly. Pairs with the population floor (at least the 4 reusable workers the repo ships, build-worker.yaml among them) that both tests assert before reading a scan |
| `reusable workers: no job inherits the caller's grant (#957)` | Names `<workflow>: <job>` for every job with no permission entry of its own -- no block, or an inline `permissions: read-all` that names no scope. Such a job runs under whatever the calling repo granted its calling job: a `contents: write` held to cut a release, a `packages: write` held to publish |
| `reusable workers: every one of them has a spec reading its permission surface (#957)` | The class-level half: a worker whose jobs all declare `contents: write` passes both tests above, so every derived worker must also have a spec that APPLIES `yaml_permission_surface` to it. Call sites are derived by `find` over the spec tree and resolved through each call's own argument, then matched against the worker's full path exactly, and the scan is floored at the derived worker count. Named for READING a surface, not for pinning a grant: whether the reader asserts the exact scope set is a property of the assertion, which no scan over call sites can see. This file is excluded because it reads every worker's surface to assert the complementary property (that a grant is declared, not which) |

### test/bats/unit/run_sh_spec.bats (70)

Unit tests for `run.sh`. Mirrors the build_sh_spec.bats harness; the `docker
compose ... ps` probe reads from a controllable stub file (one running
service per line, either bare `<service>` or `<project>/<service>` for the
tests that are about project scoping -- the qualified form is visible only
to a probe carrying that same `-p`) so tests can simulate "container already
running" scenarios.

Covers: `--help` (en/zh/zh-CN/ja), `--setup`/`-s`, bootstrap on missing
`.env` / `setup.conf` / `compose.yaml`, drift-check path, bootstrap staying
non-interactive (setup.sh, not TUI), defensive guard when setup produces no
`.env`, `--detach`, devel vs non-devel TARGET routing, already-running
guard, Wayland xhost path, `--lang` argument validation, fallback
`_detect_lang` branches, **runtime log-line i18n** (bootstrap +
already-running error translate in all four languages via the local `_msg()`
table), **#216/#429 auto-build gate** (image present → silent + no build,
image absent → auto-delegates to `./build.sh TARGET`, non-devel target
forwarded, build failure aborts run, per-target image inspect, `--build`
invokes `./build.sh test` before compose up, `--build` after check-drift),
and **`-C` / `--chdir` flag** (docker_harness#53: redirect FILE_PATH, short
+ long form, value-required and directory guards, usage help mention), and
**`-v` / `--verbose` / `-vv` / `--very-verbose` flag** (#311: same export +
trace pattern as build.sh, parity across wrappers), and **#386 foreground
exit auto compose-down** (default-on for devel + one-shot non-devel targets,
`--no-rm` opts out, `-d` suppresses the trap; the trap fires `down
--remove-orphans` to mirror stop.sh and close the
worktree-removed-before-stop network leak), and **#448 `--` CMD separator**
(`--` stops flag parsing so CMD flags like `--target` don't collide;
positional CMD also stops parsing; usage documents `--`), and **#580
interactive exit-code normalization** (`_normalize_interactive_rc` maps
clean-exit codes 0 and 130 to 0 on the no-CMD foreground paths -- devel
attached shell and one-shot stage `compose up` -- so a Ctrl-C-cleared line
carried out on exit isn't a recipe failure, while a genuine non-clean code
like 127 still propagates and command mode `just run <cmd>` keeps the real
exit code), and **#679 non-`devel` CMD-override dispatch** (a non-`devel`
one-shot target WITH a CMD dispatches `compose run --rm <SERVICE> <CMD…>` so
the ENTRYPOINT runs and the override replaces the default CMD — NOT the
pre-#679 `up -d` + `exec` pair that bypassed the ENTRYPOINT and
double-launched the default CMD; the #679 repro shape `-t runtime ros2
launch …` is asserted; `devel` + CMD still uses `up -d` + `exec`; the no-CMD
paths are unchanged; #580 exit-code propagation rides the `run` path for
non-`devel` command mode), and **#690 pre-run hook abort + foreground
post-run hook exit override** (a failing `script/hooks/pre/run.sh` aborts
the wrapper with the hook's rc before the build delegate / `compose up`; in
the foreground path a failing `script/hooks/post/run.sh` makes
`_app_cleanup` override the wrapper exit with the hook's rc while `compose
down --remove-orphans` still runs).

| Test | Description |
|------|-------------|
| `run.sh --help exits 0 and shows usage` | - |
| `run.sh --setup forces setup.sh to run` | - |
| `run.sh -s short flag triggers setup.sh` | - |
| `run.sh bootstraps setup.sh when .env is missing` | - |
| `run.sh auto-regens .env / compose.yaml when drift detected` | - |
| `run.sh skips setup.sh when .env AND setup.conf AND compose.yaml exist (drift-check path)` | - |
| `run.sh bootstraps setup.sh when setup.conf is missing (even if .env exists)` | - |
| `run.sh bootstraps setup.sh when compose.yaml is missing (fresh clone)` | - |
| `run.sh bootstrap calls setup.sh directly, not setup_tui.sh` | - |
| `run.sh fails with clear error if setup.sh produced no .env` | - |
| `run.sh --detach routes to 'compose up -d'` | - |
| `run.sh -d runs the repo-local post/run hook (#537)` | - |
| `run.sh devel target routes to 'compose up -d' + 'compose exec'` | - |
| `run.sh non-devel target without CMD uses 'compose up' foreground (#458)` | - |
| `run.sh non-devel target WITH CMD uses 'compose run --rm' (#679)` | - |
| `run.sh positional args after options become CMD passthrough (devel)` | - |
| `run.sh -t runtime with CMD overrides Dockerfile runtime CMD (#679 compose run --rm)` | - |
| `run.sh -- separates CMD from run.sh flags (#448)` | - |
| `run.sh positional CMD stops flag parsing — --target in CMD is not consumed (#448)` | - |
| `run.sh --help mentions -- CMD separator (#448)` | - |
| `run.sh default foreground (devel) installs auto-down trap` | - |
| `run.sh foreground non-devel target also installs auto-down trap` | - |
| `run.sh --no-rm disables auto-down trap` | - |
| `run.sh -d does not install auto-down trap` | - |
| `run.sh -d combined with CMD is rejected with exit 2` | - |
| `run.sh refuses to start when the service is already running (devel + no -d)` | - |
| `run.sh names the service and the project when it refuses (#920)` | - |
| `run.sh: a service running in ANOTHER project does not block this one (#920)` | - |
| `run.sh: the SAME project's running service still blocks (#920)` | - |
| `run.sh: a probe still writing cannot make the guard miss a running service (#905)` | - |
| `run.sh --lang zh-TW prints Chinese usage text` | - |
| `run.sh --lang requires a value` | - |
| `run.sh --lang zh-CN prints Simplified Chinese usage text` | - |
| `run.sh --lang ja prints Japanese usage text` | - |
| `run.sh --help documents QUIET in every locale (#895)` | - |
| `run.sh uses xhost +SI:localuser under Wayland session` | - |
| `run.sh in /lint/ layout maps zh_TW.UTF-8 to zh-TW` | - |
| `run.sh in /lint/ layout maps zh_CN.UTF-8 to zh-CN` | - |
| `run.sh in /lint/ layout maps ja_JP.UTF-8 to ja` | - |
| `run.sh --lang zh-TW prints Chinese bootstrap log` | - |
| `run.sh --lang zh-CN prints Simplified Chinese bootstrap log` | - |
| `run.sh --lang ja prints Japanese bootstrap log` | - |
| `run.sh default bootstrap log is English` | - |
| `run.sh --lang zh-TW prints Chinese already-running error` | - |
| `run.sh --lang ja prints Japanese already-running error` | - |
| `run.sh: image present → no build.sh invoked, no INFO printed` | - |
| `run.sh: image absent → auto-delegates to build.sh (#429)` | - |
| `run.sh: image absent + non-devel target → build.sh receives target (#429)` | - |
| `run.sh: image absent + build.sh fails → run.sh aborts (#429)` | - |
| `run.sh: image-inspect uses per-target tag (-t headless inspects :headless)` | - |
| `run.sh --build: invokes ./build.sh test before compose up` | - |
| `run.sh --build: always builds even if image cached (explicit opt-in)` | - |
| `run.sh --build: runs after check-drift (build sees regenerated state)` | - |
| `run.sh -C <dir> redirects FILE_PATH to <dir>` | - |
| `run.sh --chdir <dir> long form is equivalent to -C` | - |
| `run.sh -C without a value exits 2` | - |
| `run.sh -C with a non-existent directory exits 2` | - |
| `run.sh -C is mentioned in usage help` | - |
| `run.sh -v / --verbose / -vv / --very-verbose are mentioned in usage help (#311)` | - |
| `run.sh -v --dry-run is accepted and exits 0 (#311)` | - |
| `run.sh --verbose long form is accepted (#311)` | - |
| `run.sh -vv --dry-run enables bash trace (set -x output on stderr) (#311)` | - |
| `run.sh: interactive devel shell exiting 130 normalizes to 0 (#580)` | - |
| `run.sh: interactive devel shell exiting 0 stays 0 (#580)` | - |
| `run.sh: interactive devel shell exiting 127 still propagates (genuine breakage) (#580)` | - |
| `run.sh: command mode (devel WITH CMD) exiting 130 propagates, not normalized (#580)` | - |
| `run.sh: non-devel foreground up exiting 130 normalizes to 0 (#580)` | - |
| `run.sh: command mode (non-devel WITH CMD) exiting 130 propagates (#580)` | - |
| `run.sh aborts on a failing pre-run hook and skips compose up (#690)` | - |
| `run.sh foreground post-run hook failure overrides exit while teardown still runs (#690)` | - |

### test/bats/unit/runtime_smoke_spec.bats (8)

Unit tests for the runtime `.so` dependency smoke scanner (`smoke.sh`, #430)
and its wiring into `Dockerfile.example`'s `runtime-test` stage: non-zero
exit on a missing-dep `.so`, clean-link pass, empty/absent-root no-ops, and
the ldd-skip + accumulate-all behaviour (#692).

| Test | Description |
|------|-------------|
| `smoke.sh exits non-zero when a .so has 'not found' dep (#430)` | Missing-dep failure |
| `smoke.sh exits 0 when scan root has no .so files (#430)` | No-.so pass |
| `smoke.sh exits 0 when scan root does not exist (#430)` | Absent-root pass |
| `Dockerfile.example runtime-test default RUNTIME_SMOKE_CMD calls smoke.sh (#430)` | Default cmd wiring |
| `Dockerfile.example commented runtime-test COPY brings smoke.sh into image (#430)` | COPY wiring |
| `smoke.sh exits 0 when all .so files link cleanly (#430)` | Clean-link pass |
| `smoke.sh: documented behaviour -- a .so whose ldd exits non-zero is skipped (#692)` | ldd-fail skip |
| `smoke.sh: accumulates _exit=1 and reports every bad .so (#692)` | Accumulate-all reporting |

### test/bats/unit/schema_coverage_spec.bats (11)

Registry drift guards (#562, schema epic #559 phase 3): the registry must
stay internally consistent and in sync with the `setup.conf` template, so
drift fails CI. The deferred i18n coverage now lands via the `SCHEMA_I18N`
index column (#591): every registered key maps to a TUI message key (or an
explicit `""` opt-out for keys with no editor), and every mapped key is
present in all four locale tables (en / zh-TW / zh-CN / ja) -- a missing
translation in any locale fails CI.

| Test | Description |
|------|-------------|
| `every SCHEMA_VALIDATOR validator name resolves to a defined function (#562)` | no ghost validators (#562) |
| `SCHEMA_SECTIONS matches the setup.conf template headers in file order (#562)` | registry/template drift (#562) |
| `every SCHEMA_EMPTY key is a registered SCHEMA_VALIDATOR key (#562)` | no dead empty-policy entries (#562) |
| `every registered key is reachable via SCHEMA_SECTIONS (#562)` | no key stranded under an unlisted section (#562) |
| `every SCHEMA_VALIDATOR key has a SCHEMA_I18N index entry (#591)` | i18n-index is complete (#591) |
| `every SCHEMA_I18N key is a registered SCHEMA_VALIDATOR key (#591)` | no orphan index rows (#591) |
| `every SCHEMA_I18N message key exists in all four locale tables (#591)` | no missing translation in any locale (#591) |
| `_schema_i18n_key resolves scalar + list keys, falls back when free-form (#591)` | accessor the TUI routes through (#591) |
| `every shipped setup.conf key is registered or an explicit free-form opt-out (#876)` | - |
| `every SCHEMA_FREEFORM entry carries a written reason (#876)` | - |
| `no key is both SCHEMA_VALIDATOR-registered and SCHEMA_FREEFORM-opted-out (#876)` | - |

### test/bats/unit/schema_spec.bats (30)

Covers the setup.conf validation registry (`lib/schema.sh`, #560): the
single `_schema_validate <section> <key> <value>` gate that both setup.sh
(`set` / `add`) and the TUI route through. Verifies registry dispatch
(scalar exact-match + numbered-list prefix normalisation), per-service
`[logging.<svc>]` section normalisation, the empty-value policy (default
allow / clear; `deploy.gpu_count` rejects empty), and the full union of
validated keys -- including the keys that were historically free-form in
setup.sh (`build.network` / `build.arg_` / `deploy.gpu_runtime` + `runtime`
alias / `network.network_name` / `devices.device_` / `security.cap_add_` /
`cap_drop_`). Phase 2 (#561) adds the section-list single source:
`SCHEMA_SECTIONS` (ordered list), `_schema_is_section` (membership),
`_schema_section_keys` (a section's registered keys derived from
`SCHEMA_VALIDATOR`).

| Test | Description |
|------|-------------|
| `_schema_validate routes network.port_N to _validate_port_mapping (accept)` | - |
| `_schema_validate routes network.port_N to _validate_port_mapping (reject)` | - |
| `_schema_validate routes deploy.gpu_count to _validate_gpu_count (accept)` | - |
| `_schema_validate routes deploy.gpu_count to _validate_gpu_count (reject)` | - |
| `_schema_validate rejects empty deploy.gpu_count (empty policy = validate)` | empty exception |
| `_schema_validate routes logging.driver to _validate_log_driver (accept)` | - |
| `_schema_validate routes logging.driver to _validate_log_driver (reject)` | - |
| `_schema_validate allows empty logging.driver (empty policy = allow)` | empty default |
| `_schema_validate normalises logging.<svc> to the logging key set (reject)` | - |
| `_schema_validate normalises logging.<svc> to the logging key set (accept)` | - |
| `_schema_validate accepts every registered key's valid sample` | union coverage (accept) |
| `_schema_validate rejects every registered key's invalid sample` | union coverage (reject) |
| `_schema_validate rejects embedded-newline values (YAML injection) (#687)` | - |
| `_schema_validate numeric validators are shape-only, not range-bound (#687)` | - |
| `_schema_validate allows empty (clear) for every list + clearable scalar key` | clear-key semantics |
| `_schema_validate accepts free-form (unregistered) keys` | default-accept |
| `SCHEMA_SECTIONS lists every setup.conf section in file order (#561)` | ordered section list (#561) |
| `_schema_is_section accepts a registered section with typed keys (#561)` | membership accept (#561) |
| `_schema_is_section accepts a free-form-only section (image) (#561)` | membership accept, no keys (#561) |
| `_schema_is_section rejects an unknown section (#561)` | membership reject (#561) |
| `_schema_is_section rejects a per-service logging variant (#561)` | logging.<svc> not a base section (#561) |
| `_schema_is_section tracks SCHEMA_SECTIONS additions (single source) (#561)` | single source (#561) |
| `_schema_section_keys returns scalar+list keys for build (#561)` | keys by prefix (#561) |
| `_schema_section_keys returns all logging keys (#561, #606)` | keys by prefix (#561) |
| `_schema_section_keys returns deploy keys incl. legacy alias (#561)` | keys incl. runtime alias (#561) |
| `_schema_section_keys returns the rule_ list key for image (#561, #876)` | - |
| `_schema_validate gates gui.mode the way the --gui flag does (#876)` | - |
| `_schema_validate gates the [deploy] keys the resolver reads (#876)` | - |
| `_schema_validate gates the [security] keys the resolver reads (#876)` | - |
| `_schema_validate gates image.rule_N against the dispatch prefixes (#876)` | - |

### test/bats/unit/self_hosted_guard_lint_spec.bats (25)

| Test | Description |
|------|-------------|
| `self-hosted guard: FAILS on a new job with a literal self-hosted runs-on` | - |
| `self-hosted guard: FAILS on a new job whose runs-on is a label array` | - |
| `self-hosted guard: FAILS on the block-sequence runs-on form` | - |
| `self-hosted guard: FAILS on a runner GROUP, which has no hosted reading` | - |
| `self-hosted guard: FAILS when a literal matrix contributes a non-hosted label` | - |
| `self-hosted guard: FAILS when the matrix is computed at runtime (fromJSON)` | - |
| `self-hosted guard: FAILS when runs-on is a caller-supplied input expression` | - |
| `self-hosted guard: FAILS when runs-on reads a matrix key the job never declares` | - |
| `self-hosted guard: FAILS on a job calling a REMOTE reusable workflow` | - |
| `self-hosted guard: FAILS on a bare hostname label` | - |
| `self-hosted guard: names the exact condition to paste in the failure message` | - |
| `self-hosted guard: PASSES a literal GitHub-hosted runs-on with no guard` | - |
| `self-hosted guard: PASSES the arm + amd hosted families and a windows/macos runner` | - |
| `self-hosted guard: PASSES a literal matrix that resolves entirely to hosted labels` | - |
| `self-hosted guard: PASSES a LOCAL reusable-workflow call` | - |
| `self-hosted guard: PASSES an eligible job that carries the guard alone` | - |
| `self-hosted guard: PASSES an eligible job that ANDs the guard with its own gate` | - |
| `self-hosted guard: FAILS an eligible job whose if: is a near-miss reword` | - |
| `self-hosted guard: an unrelated job-level if: does not satisfy the guard` | - |
| `self-hosted guard: FAILS when the workflow directory is missing` | - |
| `self-hosted guard: FAILS when the workflow directory holds no workflow` | - |
| `self-hosted guard: FAILS when the workflows parse to zero jobs` | - |
| `self-hosted guard: scans every workflow in the directory, not a named list` | - |
| `self-hosted guard: the real repo tree has every eligible job guarded` | - |
| `self-hosted guard: the real tree's eligible set is the three runtime-matrix worker jobs` | - |

### test/bats/unit/self_test_yaml_spec.bats (113)

Structural assertions for `.github/workflows/self-test.yaml`. Locks fourteen
cumulative invariants:

1. **#305 actionlint gate** — `actionlint` job declared, runs
`rhysd/actionlint` via Docker pinned to an explicit version (`x.y.z`);
downstream jobs (`test`, `integration-e2e`, `system`) need it so the
workflow-validator class of regression that wedged v0.26.0-rc1 (refs #297)
is caught early.

2. **#317 P1 classifier + buildx GHA cache** — a `classify` job emits
`code_changed` + `system_relevant` outputs from PR diff against the doc-only
allow-list (`doc/**` + `README.md` + `LICENSE`) and system block-list
(entrypoint.sh + compose + Dockerfile.example/.test-tools + wrappers +
init/upgrade + `test/bats/system/**` + `.github/workflows/**`); the `test`
job always runs (required check) but short-circuits to SUCCESS on doc-only
PRs; `integration-e2e` and `system` gate via job-level `if:`; all three
test-tools image builds use `docker/build-push-action` with shared
`scope=test-tools` GHA cache.

3. **#317 P1 follow-up classifier hardening** — `classify` job is fail-open:
`set -uo pipefail` (no `-e`) so transient diff/fetch errors don't crash the
job and wedge every PR via the Q4 fail-closed chain. Explicit `git fetch
origin` of the base ref with `--depth=200` before diff so fork PRs (where
`actions/checkout@v6 fetch-depth: 0` only fetches the head branch) don't
trip on missing `origin/<base>`.

4. **#317 P2 Obtain step + rolling tag fallback** — each of the 3 downstream
jobs (`test`, `integration-e2e`, `system`) precedes its test-tools
provisioning with an `Obtain` step implementing the 3-layer fallback: PR
touched `dockerfile/Dockerfile.test-tools` -> rebuild local; else `docker
pull ghcr.io/ycpss91255-docker/test-tools:main` and re-tag; else fall back
to a from-source rebuild. For `test` + `system` (which `docker compose run`
test-tools), the buildx Build step gates on
`steps.obtain.outputs.build_local == 'true'` so the hot path skips it and
the cold path reuses P1's GHA cache. For `integration-e2e` (which `docker
compose build`, whose `FROM ${TEST_TOOLS_IMAGE}` resolves against the host
docker daemon), the buildx `driver: docker` override is preserved and the
rebuild fallback is inlined as plain `docker build` — GHA cache is not
available on this driver, accepted because the hot path is `docker pull
:main` and cold path matches pre-P2 cost. `integration-e2e` additionally
passes `TEST_TOOLS_IMAGE: test-tools:local` to `./build.sh test` so the
wrapper script skips its own internal test-tools build, reusing the image
populated by the Obtain step.

5. **#317 P3 system conditional + block-list expansion** — `system` job's
job-level `if:` tightens from `code_changed == 'true'` (P1) to
`system_relevant == 'true'` (the narrower output P1 already emitted but
didn't consume). PRs that change pure lint / unit-test paths covered by
`test` now skip the docker.sock-mounted compose run, saving ~3-5 min per
such PR. The system block-list in `classify` is extended with
`script/docker/setup.sh` + `script/docker/i18n.sh` + `script/docker/lib/**`
+ `script/docker/prune.sh` (gotcha-5): each affects `.env` / `compose.yaml`
generation or wrapper behaviour that the compose service exercises
end-to-end, so they must invalidate the system-skip optimization.

6. **#337 `ci-rollup` aggregator** — a single always-running (`if:
always()`) `ci-rollup` job sits downstream of every PR check and collapses
their results into one pass/fail signal that branch protection can require.
The verifier shell step consumes every `${{ needs.<job>.result }}` and
applies a 2-tier rule: `actionlint` / `classify` must be `success`;
conditionally-gated jobs (`shellcheck` / `hadolint` / `bats-unit` /
`bats-integration` / `coverage` / `integration-e2e` / `system`) may be
`success` or `skipped` (their job-level `if:` legitimately skips on doc-only
/ non-system PRs per #317 P1/P3, #376, #377, #615). Adding sub-jobs (#377)
to the rollup's `needs:` list becomes a workflow-internal change with no
branch-protection update required.

7. **#376 ShellCheck + Hadolint dedicated jobs** — `shellcheck` runs on
plain ubuntu-latest with the pre-installed binary (no buildx, no test-tools
image, ~30s feedback on a regression) via `test.sh --shellcheck-only`.
`hadolint` uses `hadolint/hadolint-action@v3.1.0` to lint
`dockerfile/Dockerfile.example` + `dockerfile/Dockerfile.test-tools` (both
template-owned; downstream Dockerfile.example consumers inherit the lint
pass). Both gate on `needs.classify.outputs.code_changed == 'true'` so
doc-only PRs SKIP them. Both join `ci-rollup`'s `needs:` list, and `release`
also gates on them so a tag with a lint regression doesn't publish a
Release.

8. **#377 Bats unit/integration split + Kcov coverage move** — the pre-#377
monolithic `test` job is fully removed and replaced by three sibling jobs: -
`bats-unit` (matrix `shard: ['1/2', '2/2']`, `fail-fast: false`): each shard
runs a round-robin partition of `test/bats/unit/*_spec.bats` via `test.sh
--bats-unit-shard ${{ matrix.shard }}`. Parallel execution drops PR
wall-time from ~5min to ~2min. - `bats-integration`: runs
`test/bats/integration/` via `test.sh --bats-integration`. Pulled out of the
unit serial path so each unit shard sees only its share. - `coverage`: #377
gated it to main pushes only and kept it out of `ci-rollup`'s `needs:` (a
non-gating metric). **Superseded by #615 (invariant 11): coverage is now a
sharded kcov PR gate in the rollup.** The #377-era posture (main-only `if:`,
"NOT in ci-rollup needs") is no longer asserted here.

9. **#579 integration-e2e runnability gate** — the e2e job drives build /
run / exec / stop through the documented `just` entry points (not raw
`script/*.sh`, so a broken container-ops justfile is caught) and ASSERTS the
runnability contract instead of only running the steps: the in-container
user equals the configured `USER_NAME` (catches the v0.41.0 user-args
`initial` bug), the detached container is still running (catches the
entrypoint `set -u` insta-exit class), the wired ENTRYPOINT is
`/entrypoint.sh`, the `~/work` mount is present and writable, and `just
stop` removes both the container and the compose project network. `just` is
installed via the `extractions/setup-just` action.

`ci-rollup needs:` is `[actionlint, classify, shellcheck, hadolint,
bats-unit, bats-integration, coverage, integration-e2e, system]` (9 jobs
post-#615) — every PR-check job. `release needs:` updates from `[shellcheck,
hadolint, test, integration-e2e, system]` → `[shellcheck, hadolint,
bats-unit, bats-integration, integration-e2e, system]`. Post-#377 only
`actionlint` + `classify` are hard-mandatory in `ci-rollup`'s verifier (the
always-running `test` job no longer exists).

10. **#603 native arm64 e2e matrix** — `integration-e2e` runs as a static
2-entry `strategy.matrix` (`linux/amd64` -> `ubuntu-latest`, `linux/arm64`
-> `ubuntu-24.04-arm`) with `fail-fast: false`, so the #579 runnability
contract is verified on both arches via native runners (no QEMU), mirroring
the platform->runner convention of build-worker / publish-worker /
release-test-tools (#587). The job `runs-on: ${{ matrix.runner }}` and the
Obtain step pulls `test-tools:main` for `${{ matrix.platform }}` (multi-arch
post-#587) so the arm64 shard gets the arm64 variant. `ci-rollup` aggregates
through `needs.integration-e2e.result` unchanged.

11. **#615 sharded kcov + coverage as an enforced PR gate (amends #377,
ADR-00000008)** — `coverage` is no longer the #377 main-only metric. It now
(a) runs as a kcov `strategy.matrix` (`shard: ['1/4', '2/4', '3/4', '4/4']`,
`fail-fast: false`) MIRRORING the `bats-unit` matrix via `test.sh
--coverage-shard ${{ matrix.shard }}` — each shard kcov's the same
round-robin unit slice the unit-test matrix runs (integration on the last
shard); (b) gates on `needs.classify.outputs.code_changed == 'true'` so it
runs on PRs (not just main push); and (c) joins `ci-rollup`'s `needs:` + the
verifier consumes `needs.coverage.result` (SKIPPED-as-pass for doc-only
PRs), so a kcov failure blocks PR merge. The old `if: push && ref ==
refs/heads/main` and the "NOT in ci-rollup needs" posture are gone.

> #710 self-hosted amendment: the per-shard external-SaaS upload + the >
SaaS `project` branch-protection status are REMOVED (the repo moves to > a
GitLab where that SaaS is unavailable and uploading coverage leaks > data).
Each shard instead uploads its kcov report as a CI ARTIFACT >
(`actions/upload-artifact`, keyed by `strategy.job-index`); a new >
`coverage-gate` job downloads every shard artifact and runs >
`script/test/drivers/coverage_gate.sh`, which MERGES the per-shard >
cobertura reports into one line-weighted project rate and fails below >
`COVERAGE_MIN`. `coverage-gate` joins `ci-rollup`'s `needs:`, so the > floor
gates merge with no external SaaS. The gate script is asserted > in
`coverage_gate_spec.bats`.

12. **#697 / #947 / #948 probe-and-rebuild against a `:main` that is not
this checkout's** — CI rebuilds the tooling image only for a PR that touches
`dockerfile/Dockerfile.test-tools`; every other PR pulls the rolling
`:main`, which is republished only by a push to main touching that same
file. Two ways the pulled image can fail to correspond to the checkout, and
only one is loud. ABSENT: `release-test-tools` republishes concurrently with
this workflow, so an Obtain step can fetch a pre-new-tool image (e.g.
pre-kcov) mid-flight and the coverage shards fast-fail with `kcov: command
not found`. STALE: the tool is present at the version the pin used to name —
`shellcheck` / `hadolint` are lint GATES, so an older rule set does not
fail, it under-reports, and the green check has examined something other
than what the checkout asked for, while a `just` older than `ARG
JUST_VERSION` reddens `test/bats/integration/just_runner_version_spec.bats`
on a PR that touched nothing related. After the pull + `docker tag`, every
`:main`-pulling Obtain step therefore runs `script/ci/probe_test_tools.sh`,
which requires every tool in `REQUIRED_TOOLS` to be present AND every tool
in `PINNED_TOOLS` to report the version this checkout pins (the two linters
out of their release URLs in the Dockerfile, the runner through
`dist/script/base/just-version.sh` — never restated). On any refusal it
emits `build_local=true` so the existing buildx Build step rebuilds from
`dockerfile/Dockerfile.test-tools` — self-correcting whatever the cause,
with layer-1 (PR touched Dockerfile -> build) and layer-3 (pull failed ->
build) intact. Applied to the five `build_local`-pattern obtain steps
(`hadolint`, `bats-fragile`, `bats-integration`, `coverage`, `system`) since
they pull the same tag and race identically, and asserted per job. The sixth
`:main`-pulling step, `acceptance`, carries no probe and needs none: the
probe is about the tools a job EXECUTES, and acceptance runs none of them --
it consumes the image only as the `FROM` base of the scaffolded consumer's
test stage. It is ONE script rather than a loop pasted into each step
because five copies is how the version blind spot survived: each copy asked
`command -v` and none of them looked wrong. The guard used to be a `grep -c`
== 5 over the whole workflow under the name "every `:main`-pulling Obtain
step", which named an invariant that did not hold (there are six such steps)
and was satisfied by any five occurrences wherever they sat.

13. **#677 CI double-run restructure (coverage = primary unit gate,
weight-balanced shards, single `bats-fragile` job)** — after #686 unified
the coverage job onto the same Alpine test-tools image, the 4-shard
`bats-unit` matrix and the 4-shard `coverage` matrix ran the SAME ~1991 unit
specs twice per PR (8 parallel jobs), differing only by `COVERAGE=1`. The
restructure: (a) the `coverage` matrix stays the PRIMARY unit gate (kcov
over every non-fragile test; codecov upload + the #615/ADR-00000008 project
gate untouched); (b) the `bats-unit` matrix is replaced by a SINGLE
`bats-fragile` job that runs ONLY the kcov-fragile specs the coverage matrix
skips via `[ "${COVERAGE:-0}" = 1 ] && skip` — in PLAIN mode, so the delta
is preserved with zero double-run. The fragile set is computed at RUNTIME
(`test.sh --bats-fragile` -> `_fragile_unit_files` greps a line-anchored
skip guard), so a new fragile-skip in a 10th file is picked up
automatically; (c) `_shard_unit_files` replaces round-robin with greedy
bin-packing by per-spec `@test` count (heaviest-first into the lightest
shard) so the slowest coverage shard approaches `total/N`. `ci-rollup
needs:` and `release needs:` swap `bats-unit` -> `bats-fragile`; `coverage`
joins the `release` chain (it is now the primary unit gate). Every unit test
still runs SOMEWHERE: non-fragile under coverage/kcov, the fragile files
under `bats-fragile` (plain).

14. **#1009 the gate rosters are DERIVED from the job graph** — every
assertion above about a `needs:` list named the roster it checked, so the
roster and the assertion were two hand-kept copies of the same thing and
adding a job updated neither. Three guards now read the roster out of the
file instead: every job the workflow declares is named DIRECTLY in
`ci-rollup`'s `needs:` (directly, because `if: always()` means it can only
see its own needs, and a job reached through a failed one arrives as
SKIPPED, which the tolerant bucket passes); every job `ci-rollup` needs is
bound to a `*_RESULT` and compared in EXACTLY ONE of the two result loops (a
needed job nothing compares is waited for and ignored); and `release`'s
transitive `needs:` closure equals the set `ci-rollup` names, since the tag
path does not go through `ci-rollup`. The two defects that motivated this
land with it: `compute-shards` joins `ci-rollup` in the STRICT loop, and
`coverage-gate` joins `release`'s `needs:` so a tag cannot cut a Release
below `COVERAGE_MIN`. Because the roster prose in this blurb is hand-kept in
exactly the way the guards forbid, the file -- not this paragraph -- is now
the record of who needs whom.

Grouped by concern:

- `actionlint` job declared

- `actionlint` step uses `rhysd/actionlint:<pinned-version>` Docker image

- `classify` job declared with `code_changed` + `system_relevant` outputs

- `classify` doc-only allow-list + system block-list + non-PR default

- `bats-fragile`/`bats-integration`/`integration-e2e`/`system` declare
`needs: [actionlint, classify]`

- `bats-fragile`/`bats-integration` job-level `if: code_changed == 'true'` +
no remaining monolithic `test:` job (#377, #677)

- `integration-e2e` job-level `if: code_changed == 'true'` + `system`
job-level `if: system_relevant == 'true'` (#317 P3 tightens)

- `bats-fragile`/`bats-integration`/`system` use
`docker/build-push-action@v6` with `scope=test-tools` GHA cache

- `classify` fail-open (`set -uo pipefail`) + pre-fetch base ref (#317
gotcha-1/2)

- `bats-fragile` Obtain step pulls `:main` with 3-layer fallback + Build
step gated on `build_local` (#317 P2 + #677)

- `bats-integration` Obtain step + 3-layer fallback (#317 P2 + #377)

- `integration-e2e` Obtain step + `TEST_TOOLS_IMAGE` env passthrough + no
`driver: docker` pin (#317 P2)

- `integration-e2e` native arm64 matrix (#603): amd64+arm64 native-runner
matrix with `fail-fast: false`; shards `runs-on: ${{ matrix.runner }}`;
Obtain pulls the matrix platform

- `system` Obtain step with 3-layer fallback (#317 P2)

- Obtain steps pre-fetch base ref (5 occurrences post-#377: classify + 4
jobs, #317 P2 reuses P1 gotcha-2 fix)

- `classify` system block-list extends to `setup.sh` + `i18n.sh` + `lib/**`
+ `prune.sh` (#317 P3 gotcha-5)

- `ci-rollup` declared + `needs: [actionlint, classify, shellcheck,
hadolint, bats-fragile, bats-integration, coverage, coverage-gate,
integration-e2e, system]` + `if: always()` (#337 + #376 + #377 + #615 + #677
+ #710)

- `ci-rollup` DOES need `coverage` now (#615 amends #377)

- `ci-rollup` verify step consumes every `needs.<job>.result` incl
`coverage` + `coverage-gate` + SKIPPED treated as pass for conditional jobs
+ `success` required for hard-mandatory jobs (#337 + #376 + #377 + #615 +
#677 + #710)

- `shellcheck` job declared + `needs: [actionlint, classify]` + `if:
code_changed == 'true'` + runs `test.sh --shellcheck-only` on plain
ubuntu-latest with no buildx (#376)

- `doc-counts` job declared + `needs: [actionlint, classify]` + runs
`test.sh --doc-counts-only` on plain ubuntu-latest with no buildx + carries
NO `code_changed` gate + is hard-mandatory in `ci-rollup` (#864)

- `hadolint` job declared + `needs: [actionlint, classify]` + `if:
code_changed == 'true'` + lints both template-owned Dockerfiles via
`hadolint-action` (#376)

- `bats-fragile` declared + is a single job (no shard matrix) + invokes
`test.sh --bats-fragile` + no `bats-unit` matrix remains (#677)

- `bats-integration` declared + invokes `test.sh --bats-integration` (#377)

- `coverage` declared (#377) + runs on PRs via `if: code_changed == 'true'`
(not main-only) + primary kcov unit gate over `matrix.shard: ['1/4'..'4/4']`
(greedy weight-balanced) + invokes `test.sh --coverage-shard ${{
matrix.shard }}` + uploads each shard report as a CI artifact (#615 + #677 +
#710)

- Self-hosted coverage (#710): NO codecov reference anywhere in the workflow
+ a `coverage-gate` job downloads the shard artifacts and runs
`coverage_gate.sh`

- `release` job needs `[shellcheck, hadolint, bats-fragile,
bats-integration, coverage, integration-e2e, system]` before publishing a
tag (#376 + #377 + #677)

- Probe-and-rebuild against a stale/racing `:main`: `bats-fragile` +
`coverage` Obtain probe for kcov and rebuild on a miss + `REQUIRED_TOOLS`
list is extensible + all five `build_local` obtain steps carry the guard
(#697)

| Test | Description |
|------|-------------|
| `self-test.yaml: declares actionlint job` | - |
| `self-test.yaml: actionlint job runs rhysd/actionlint via Docker with pinned tag` | - |
| `self-test.yaml: declares classify job (#317)` | - |
| `self-test.yaml: classify job declares code_changed output (#317)` | - |
| `self-test.yaml: classify job declares system_relevant output (#317)` | - |
| `self-test.yaml: classify uses doc-only allow-list 'doc/**' + 'README.md' + 'LICENSE' + 'CONTEXT.md' (#317)` | - |
| `self-test.yaml: classify uses system block-list entrypoint + compose + Dockerfile + wrappers + init/upgrade + workflows (#317)` | - |
| `self-test.yaml: classify defaults code_changed/system_relevant to true on non-PR events (#317)` | - |
| `self-test.yaml: classify omits set -e to fail-open on diff errors (#317 gotcha-1)` | - |
| `self-test.yaml: classify pre-fetches base ref before diff (#317 gotcha-2)` | - |
| `self-test.yaml: bats-fragile job declares needs on actionlint AND classify (#677)` | - |
| `self-test.yaml: bats-integration job declares needs on actionlint AND classify (#377)` | - |
| `self-test.yaml: acceptance job declares needs on actionlint AND classify (#317)` | - |
| `self-test.yaml: acceptance drives the container via just, not raw script/*.sh (#579)` | - |
| `self-test.yaml: acceptance asserts the runnability contract (#579)` | - |
| `self-test.yaml: acceptance pins the entry point the shipped Dockerfile wires (#945)` | The acceptance job's `.Path` check is a runnability assertion only while the literal it compares against is the one the template's ENTRYPOINT names. Reading BOTH here, rather than remembering one, is what makes a move of the entry point fail in the local gate instead of on the CI-only acceptance matrix that `just test` cannot see |
| `self-test.yaml: acceptance exercises the remaining downstream just commands for real (#769)` | - |
| ``self-test.yaml: acceptance drives `just template new` end-to-end and asserts the consumer artifact (#785)`` | - |
| `self-test.yaml: acceptance documents setup-tui as intentionally out of scope (#769)` | - |
| `self-test.yaml: acceptance runs as a native-runner matrix over amd64 + arm64 (#603)` | - |
| `self-test.yaml: acceptance shards run on the matrix runner (#603)` | - |
| `self-test.yaml: acceptance Obtain step pulls the matrix platform, not a hardcoded amd64 (#603)` | - |
| `self-test.yaml: system job declares needs on actionlint AND classify (#317)` | - |
| `self-test.yaml: bats-fragile job-level if: gates on code_changed (#677)` | - |
| `self-test.yaml: bats-integration job-level if: gates on code_changed (#377)` | - |
| ``self-test.yaml: no monolithic `test:` job remains after #377 split`` | - |
| `self-test.yaml: acceptance job-level if: gates on code_changed (#317)` | - |
| `self-test.yaml: system job-level if: gates on system_relevant (#317 P3)` | - |
| `self-test.yaml: classify system block-list extends to setup.sh + i18n.sh + lib/** + prune.sh (#317 P3 gotcha-5)` | - |
| `self-test.yaml: classify system block-list covers the CI scripts + self-test fixture (#802, #947)` | A PR touching only `script/ci/**` or the build-worker fixture would otherwise skip the System self-test that consumes them -- and since the system job now picks its image via `script/ci/probe_test_tools.sh`, the directory is listed rather than the one subdirectory, so the next CI script cannot land outside the gate by omission |
| `self-test.yaml: bats-fragile job uses docker/build-push-action with GHA cache scope=test-tools (#677)` | - |
| `self-test.yaml: bats-integration job uses docker/build-push-action with GHA cache scope=test-tools (#377)` | - |
| `self-test.yaml: system job uses docker/build-push-action with GHA cache scope=test-tools (#317)` | - |
| `self-test.yaml: bats-fragile job has Obtain step pulling :main with 3-layer fallback (#317 P2 + #677)` | - |
| `self-test.yaml: bats-fragile Build step is gated on steps.obtain.outputs.build_local == 'true' (#317 P2 + #677)` | - |
| `self-test.yaml: bats-integration job has Obtain step + 3-layer fallback (#317 P2 + #377)` | - |
| `self-test.yaml: acceptance job has Obtain step + TEST_TOOLS_IMAGE env passthrough (#317 P2)` | - |
| `self-test.yaml: acceptance job keeps buildx driver: docker for host-daemon visibility (#317 P2)` | - |
| `self-test.yaml: system job has Obtain step with 3-layer fallback (#317 P2)` | - |
| `self-test.yaml: bats-fragile Obtain probes the pulled :main and rebuilds on a miss (#697, #947)` | Named per job rather than counted: the fragile shard is one of the five that RUN the baked tools, so a `:main` that does not correspond to this checkout has to send it to a local rebuild, not into the suite |
| `self-test.yaml: coverage Obtain probes the pulled :main and rebuilds on a miss (#697, #947)` | The coverage shards are the ones that actually raced -- the kcov-not-found fast-fail is the incident this guard was written after -- and they are also the job whose numbers a wrong alpine series quietly changes, so their obtain step is pinned on its own |
| `self-test.yaml: the probe is ONE script, not a loop copied into every job (#947)` | Keeps the copies from growing back: five inline copies of the loop is how the presence-only blind spot survived, because no single copy looked wrong, and a re-inlined loop is invisible to the probe's own spec |
| `self-test.yaml: every job that RUNS the baked tools probes the pulled :main for them (#697)` | - |
| `self-test.yaml: every job that probes :main compares the runner VERSION, not just presence (#948)` | Presence is the dimension the tool roster can express and the version is not, so a `:main` published before a bump carries every required tool AND the wrong runner; the population is derived from the workflow so the sixth probing job cannot land outside the rule |
| `self-test.yaml: only classify fetches the base ref; image jobs read its testtools_changed output (#734)` | - |
| `self-test.yaml: classify emits testtools_changed from a full-history diff (#734)` | - |
| `self-test.yaml: image jobs gate the rebuild on classify's testtools_changed (#734)` | - |
| `self-test.yaml: coverage shards restore the shard-weights cache before partitioning (#733)` | - |
| `self-test.yaml: coverage-gate merges shard timings into the weights file (#733)` | - |
| `self-test.yaml: coverage-gate saves the shard-weights cache only on push (#733)` | - |
| `self-test.yaml: declares ci-rollup job (#337)` | - |
| `self-test.yaml: ci-rollup needs every sibling PR-check job incl coverage (#337 + #376 + #377 + #615 + #677)` | - |
| `self-test.yaml: ci-rollup DOES need coverage now (#615 amends #377)` | - |
| `self-test.yaml: ci-rollup runs unconditionally via if: always() (#337)` | - |
| `self-test.yaml: ci-rollup verify step consumes every needs result incl coverage (#337 + #376 + #377 + #615)` | - |
| `self-test.yaml: ci-rollup treats SKIPPED as pass for conditionally-gated jobs (#337 + #377)` | - |
| `self-test.yaml: ci-rollup requires hard-mandatory jobs to be success (#337 + #377)` | - |
| `self-test.yaml: ci-rollup treats compute-shards as hard-mandatory, not SKIPPED-tolerant (#1009)` | compute-shards carries no `if:` gate, so a SKIPPED there is a workflow bug and not a conditional job declining to run. It is also the one job whose FAILURE is otherwise invisible: coverage needs it and coverage-gate needs coverage, and both of those sit in the rollup's skipped-tolerant bucket, so putting compute-shards in the tolerant bucket too leaves the required check green with the entire unit suite and the coverage floor never run. |
| `self-test.yaml: every job the workflow declares is named directly in ci-rollup's needs (#1009)` | This is the guard that makes the merge gate's roster DERIVED rather than hand-kept, and it is the recurrence #1009 asks to close: adding a job to the workflow used to update neither ci-rollup's needs nor any assertion, so the new job gated nothing and every existing test stayed green. Directly and not transitively, because ci-rollup runs under `if: always()` and reads each upstream's `.result`: GitHub reports a job whose need failed as SKIPPED, and SKIPPED is pass-equivalent in the tolerant bucket, so a job reached only through another is invisible to it. |
| `self-test.yaml: ci-rollup inspects every job it needs, in exactly one result bucket (#1009)` | Joining `needs:` is only half a gate, so the guard above is not enough on its own. The rollup's verdict is the two loops over the `*_RESULT` variables: a job that is needed but compared in neither loop is waited for and then ignored, which is the same green as never having been needed, with a needs list that reads as correct. Exactly one bucket rather than at least one, because a variable in both is strict and tolerant at once. No pre-existing test caught a `*_RESULT` dropped from a loop. |
| `self-test.yaml: the tag path requires exactly what the merge gate requires (#1009)` | The two guards above cover the PR path only. `release` does not go through ci-rollup -- ci-rollup is not in its `needs:` -- so the merge gate and the tag path were independent hand-kept lists of the same thing with nothing making them agree, and coverage-gate sat in one of them only. That left the coverage floor enforced on every PR and unenforced on the one path that publishes a Release, which is the half of #1009 no assertion about either roster could have found. |
| `self-test.yaml: the closure walk reports a dangling needs: entry instead of walking forever (#1009)` | The guard above compares a transitive closure, so it is worth no more than the walk that computes it -- this is the test that keeps that one from being vacuous. `yaml_job_needs` answers an undeclared job id with a `BUG:` line and a non-zero status; a walk that reads the line and drops the status queues the diagnostic as another job id, and since each bogus id yields a new and longer line the seen-set never dedupes, the walk never ends. That turns exactly the roster drift this spec exists to catch -- a renamed job still named in a `needs:` entry -- into `just test` hanging with no TAP output and a container left spinning, which is the worst failure mode available to it. |
| `self-test.yaml: ci-rollup fails a fork PR instead of reporting a partial run as green (#766)` | - |
| `self-test.yaml: the fork-PR branch is a hard failure, not an advisory note (#766)` | - |
| `self-test.yaml: the self-hosted guard lint has a lint-static CI join (#766)` | - |
| `self-test.yaml: declares worker-selftest job that really invokes the shared build worker (#802)` | - |
| `self-test.yaml: worker-selftest drives the worker with a minimal fixture repo (#802)` | - |
| `self-test.yaml: worker-selftest needs actionlint + classify and gates on system_relevant (#802)` | - |
| `self-test.yaml: ci-rollup consumes worker-selftest as a SKIPPED-tolerant gate (#802)` | - |
| `self-test.yaml: release gate requires worker-selftest before publishing a tag (#802)` | - |
| `self-test.yaml: declares shellcheck job (#376)` | - |
| `self-test.yaml: shellcheck job needs actionlint + classify and gates on code_changed (#376)` | - |
| `self-test.yaml: shellcheck job runs test.sh --shellcheck-only on plain ubuntu-latest (#376)` | - |
| `self-test.yaml: declares doc-counts job (#864)` | - |
| `self-test.yaml: doc-counts job runs test.sh --doc-counts-only on plain ubuntu-latest (#864)` | - |
| `self-test.yaml: doc-counts carries NO code_changed gate (#864)` | - |
| `self-test.yaml: ci-rollup treats doc-counts as hard-mandatory, not SKIPPED-tolerant (#864)` | - |
| `self-test.yaml: declares lint-static job (#866)` | - |
| `self-test.yaml: lint-static runs one matrix entry per host-direct lint on a plain runner (#866)` | - |
| `self-test.yaml: lint-static carries NO code_changed gate (#866)` | - |
| `self-test.yaml: ci-rollup treats lint-static as hard-mandatory, not SKIPPED-tolerant (#866)` | - |
| `self-test.yaml: every lint the just test lint phase runs has a CI join (#866)` | - |
| `self-test.yaml: declares hadolint job (#376)` | - |
| `self-test.yaml: hadolint job needs actionlint + classify and gates on code_changed (#376)` | - |
| `self-test.yaml: hadolint job runs the driver, not the hadolint-action (#650)` | - |
| `self-test.yaml: release job gates on shellcheck + hadolint + bats-fragile + bats-integration + coverage + acceptance + system before publishing a tag (#376 + #377 + #677)` | - |
| `self-test.yaml: the release job assembles no source archive of its own (#924)` | - |
| `self-test.yaml: the release upload attaches no hand-built asset (#924)` | - |
| `self-test.yaml: declares bats-fragile job (#677)` | - |
| `self-test.yaml: bats-fragile is a single job (no shard matrix) (#677)` | - |
| `self-test.yaml: bats-fragile invokes test.sh --bats-fragile (#677)` | - |
| `self-test.yaml: no bats-unit shard matrix remains after #677` | - |
| `self-test.yaml: declares bats-integration job (#377)` | - |
| `self-test.yaml: bats-integration invokes test.sh --bats-integration (#377)` | - |
| `self-test.yaml: declares coverage job (#377)` | - |
| `self-test.yaml: coverage now runs on PRs (gated on code_changed), not main-only (#615 amends #377)` | - |
| `self-test.yaml: coverage runs as the primary kcov unit gate over a DYNAMIC shard matrix (#615 + #677 + #725)` | - |
| `self-test.yaml: compute-shards job emits a dynamic shard array from vars.CI_SHARDS (default 8, clamped) (#725)` | - |
| `self-test.yaml: coverage invokes test.sh --coverage-shard + uploads each shard report as a CI artifact (#710)` | - |
| `self-test.yaml: NO codecov reference anywhere in the workflow (#710)` | - |
| `self-test.yaml: declares a coverage-gate job that runs the self-hosted floor gate (#710)` | - |
| `self-test.yaml: the system job supplies HOST_UID / HOST_GID to its bare compose run (#895)` | - |
| `self-test.yaml: declares a workflow-level env block carrying the run identity (#900)` | - |
| `self-test.yaml: every name the workflow creates differs between two concurrent runs (#900)` | - |
| `self-test.yaml: every name also differs between two attempts of ONE run (#900)` | - |
| `self-test.yaml: run identity is not a timestamp and not the commit SHA (#900)` | - |
| `self-test.yaml: the run-scoped names come from ONE place, not per job (#900)` | - |
| `self-test.yaml: the test-tools image every job builds carries the ownership label (#900)` | - |
| `self-test.yaml: the acceptance scaffold is keyed to the run (#900)` | - |
| `self-test.yaml: every job that puts an image in the host daemon tears it down (#900)` | - |
| `self-test.yaml: teardown runs on failure too, not just on success (#900)` | - |
| `self-test.yaml: cleanup is ownership-scoped, never a blanket prune (#900)` | - |
| `self-test.yaml: the age-based backstop uses a CI window, not the local defaults (#900)` | - |

### test/bats/unit/setup_cmd_spec.bats (136)

Mirrors `lib/setup_cmd.sh`. The git-style subcommand dispatcher and its
mutating verbs (#49): dispatch (Phase B-1), `set` / `show` / `list` (Phase
B-2), `add` / `remove` (Phase B-3), and `reset` + BREAKING no-arg → help
(Phase B-4) — round-trips, validators, no-`.env`-regen, comment
preservation, and end-to-end subprocess cases. Also the per-section
setup.conf parameter end-to-end coverage (#202, merged from the former
`setup_section_validate_spec.bats`) exercising `_setup_validate_kv` /
`_setup_known_section`: one key per test asserted through to `compose.yaml`
/ `.env`, across `[deploy]`, `[gui]`, `[network]`, `[resources]`,
`[environment]`, `[tmpfs]`, `[devices]`, `[volumes] mount_2..N`, and
`[security]` privileged, with companion negatives for cleared keys, plus the
isolated `_setup_known_section` / `SCHEMA_SECTIONS` (#561) unit checks.

| Test | Description |
|------|-------------|
| `main no-arg prints help and exits 0 (#49 Phase B-4 BREAKING)` | - |
| `main legacy flag-only invocation now errors (#49 Phase B-4 BREAKING)` | - |
| `main apply subcommand regenerates .env + compose.yaml` | - |
| `main rejects unknown subcommand` | - |
| `main check-drift returns 0 when .env missing (no-op)` | - |
| `main check-drift returns 0 when nothing changed` | - |
| `main check-drift returns non-zero when conf hash drifts` | - |
| `check-drift prints WARN when per-repo setup.conf is missing (#186)` | - |
| `check-drift prints WARN when per-repo setup.conf has no section headers (#186)` | - |
| `check-drift stays silent when per-repo setup.conf has at least one section` | - |
| `check-drift --lang zh-TW prints WARN in Traditional Chinese when setup.conf missing (#186)` | - |
| `main check-drift rejects unknown flag` | - |
| `setup.sh check-drift via subprocess emits stderr + non-zero exit on drift` | - |
| `set writes a value into an existing section, round-trip via show` | - |
| `set creates a new key when section exists but key is absent` | - |
| `set creates section + key when section is absent` | - |
| `set project.name accepts a compose-legal name and show round-trips it (#893)` | - |
| `set project.name rejects a name docker compose would reject (#893)` | - |
| `apply records the resolved project name in .env.generated (#893)` | - |
| `apply keeps the recorded name when the DERIVATION changes, and carries the new one (#920)` | - |
| `apply carries the name a PRE-record env file runs under, rather than reading it as fresh (#920)` | - |
| `apply adds no pending name when a PRE-record env file still derives the same name (#920)` | - |
| `apply on a fresh checkout records the resolved name with nothing pending (#920)` | - |
| `apply drops a pending name once the derivation agrees again (#920)` | - |
| `apply takes a CONFIGURED rename at once and warns about the old project (#920, #893)` | - |
| `the shipped template ships [project] name empty, so an upgrade changes nothing (#893)` | - |
| `set --local writes .setup.conf.local and leaves .setup.conf alone (#893)` | - |
| `set without --local still writes .setup.conf (#893)` | - |
| `set --local reports the gitignored file it created (#893)` | - |
| `set warns, names the section and points at --local when .local shadows it (#893)` | - |
| `set does not warn about a section the local layer does not define (#893)` | - |
| `set --local does not warn about the file it is writing (#893)` | - |
| `add --local appends to the local layer's section (#893)` | - |
| `remove --local removes from the local layer (#893)` | - |
| `add warns when the local layer shadows the section it appends to (#893)` | - |
| `set rejects an unknown section with non-zero exit + Unknown section stderr` | - |
| `set rejects an invalid gpu_count value` | - |
| `set rejects an invalid mount string` | - |
| `set rejects an invalid cgroup_rule` | - |
| `set rejects an invalid env_kv` | - |
| `set rejects an invalid port mapping` | - |
| `set rejects an invalid target_arch (#560 schema unification)` | - |
| `set rejects an invalid build network (#560 schema unification)` | - |
| `set rejects an invalid gpu_runtime (#560 schema unification)` | - |
| `set rejects an invalid network_name (#560 schema unification)` | - |
| `set rejects an invalid device mount (#560 schema unification)` | - |
| `add rejects an invalid capability (#560 schema unification)` | - |
| `set rejects a malformed dotted key (no dot)` | - |
| `set rejects a newline-bearing value rather than corrupting setup.conf (#688)` | - |
| `set with no arguments fails clean (no shell error)` | - |
| `set does NOT regenerate .env (mtime unchanged after set)` | - |
| `show prints the value of a single key` | - |
| `show prints all entries of a whole section in on-disk order` | - |
| `show <section> keeps the per-service [logging.<svc>] keys out of the parent dump (#955)` | - |
| `show logging.<svc> dumps the sub-section it accepts as a valid section (#955)` | - |
| `show reports a typo under [logging] as a missing KEY, not an empty section (#955)` | - |
| `show returns non-zero on a missing key` | - |
| `show falls back to template baseline when section absent in .local (#174)` | - |
| `show rejects an unknown section name` | - |
| `show with no arguments fails clean` | - |
| `list with no arg prints every section header + key` | - |
| `list emits a per-service logging key once, under its own section (#955)` | - |
| `no setup.conf namespace-key reader re-derives section membership with a trailing-dot glob on a lone section variable (#955)` | - |
| `list <section> mirrors show <section>` | - |
| `list <section> rejects an unknown section` | - |
| `set / show / list run end-to-end via subprocess` | - |
| `main add appends mount to next available slot` | - |
| `main add to empty section creates _1` | - |
| `main add bootstraps setup.conf empty when missing (#174)` | - |
| `main add picks max+1 even with gap from prior remove` | - |
| `main add rejects unknown section` | - |
| `main add binds a logging.<svc> spec to the sub-section, not the parent (#955)` | - |
| `main add rejects invalid mount value` | - |
| `main add rejects missing list / value` | - |
| `main add does not regen .env` | - |
| `main remove drops keyed entry` | - |
| `main remove by value finds matching key in list` | - |
| `main remove fails when key missing` | - |
| `main remove by value fails when no value matches` | - |
| `main remove rejects unknown section` | - |
| `main remove preserves comments + remaining keys` | - |
| `main add then remove round-trips` | - |
| `main add validates env_kv format` | - |
| `main add free-form image rule accepts arbitrary string` | - |
| `main reset --yes clears setup.conf + setup.conf so next apply rebuilds (#174)` | - |
| `main reset --yes backs up prior setup.conf to .local.bak (#174)` | - |
| `main reset --yes backs up prior .env.generated to .env.generated.bak` | - |
| `main reset --yes does NOT regenerate .env` | - |
| `main reset without --yes refuses non-tty (no confirmation possible)` | - |
| `main reset rejects unknown flag` | - |
| `[deploy] gpu_mode = off omits deploy.resources block from compose.yaml` | - |
| `[deploy] gpu_mode = force emits deploy.resources GPU block` | - |
| `[deploy] gpu_count = 2 emits count: 2 in compose deploy block` | - |
| `[deploy] gpu_capabilities multi-value emits as YAML array` | - |
| `[deploy] runtime = nvidia emits runtime: nvidia at service level` | - |
| `[deploy] runtime = off omits runtime line entirely` | - |
| `[gui] mode = off omits X11 / DISPLAY env from compose` | - |
| `[gui] mode = force emits X11 environment + /tmp/.X11-unix mount` | - |
| `[network] mode = host writes NETWORK_MODE=host to .env` | - |
| `[network] ipc = private writes IPC_MODE=private to .env` | - |
| `[network] pid = host writes PID_MODE=host to .env` | - |
| `[network] pid default (private) writes PID_MODE=private to .env` | - |
| `[network] pid default (private) omits pid: line from compose.yaml` | - |
| `[network] pid = host emits pid: host in compose.yaml` | - |
| `[network] network_name = my_bridge under mode=bridge emits external network ref` | - |
| `[network] port_1 = 8080:80 emits ports: block under bridge mode` | - |
| `[network] port_* under mode=host is silently dropped` | - |
| `[resources] shm_size = 2gb under ipc=private emits shm_size: 2gb` | - |
| `[resources] shm_size empty omits shm_size line` | - |
| `[environment] env_1 = ROS_DOMAIN_ID=7 lands in the generated .env (#868)` | - |
| `[environment] empty section omits environment: block` | - |
| `[tmpfs] tmpfs_1 = /tmp emits tmpfs: block with the entry` | - |
| `[tmpfs] tmpfs_1 with size= suffix preserved verbatim` | - |
| `[tmpfs] empty section omits tmpfs: block` | - |
| `[devices] device_1 = /dev/video0:/dev/video0 emits devices: block` | - |
| `[devices] cgroup_rule_1 emits device_cgroup_rules: block` | - |
| `[volumes] mount_2 = /data:/data emits as additional volume entry` | - |
| `[volumes] mount_N supports :ro suffix` | - |
| `[security] privileged = false writes PRIVILEGED=false to .env` | - |
| `[environment] apply does NOT execute a command-substitution env value (#687)` | - |
| `[environment] apply emits an injection-style env value on a single line (#687)` | - |
| `[lifecycle] apply does not emit a restart: line for a malformed policy (#687)` | - |
| `[environment] apply carries an env value containing a colon-space into .env (#698)` | - |
| `[environment] apply carries an env value with a leading flow indicator into .env (#698)` | - |
| `[environment] apply carries an env value with an inline ' #' marker into .env (#698)` | - |
| `[environment] apply carries an embedded double-quote / backslash into .env (#698)` | - |
| `[network] apply does not emit a literal network_mode: line for a bogus hand-edited mode (#698)` | - |
| `[network] apply does not emit a literal ipc:/pid: line for a bogus hand-edited mode (#698)` | - |
| `_setup_known_section recognises additional_contexts` | - |
| `_setup_known_section recognises logging + [logging.<svc>] sub-section (#328)` | - |
| `_setup_known_section recognises every SCHEMA_SECTIONS member (#561)` | - |
| `_setup_known_section derives from SCHEMA_SECTIONS, not a copy (#561)` | - |
| `setup.sh runs the post-setup hook when the subcommand fails (#956)` | - |
| `setup.sh post-setup hook failure overrides a failing subcommand rc (#956)` | - |
| `setup.sh apply aborts where a handler command fails mid-apply (#956)` | - |
| `setup.sh finalizes the transcript when the post-setup hook fails (#956)` | - |

### test/bats/unit/setup_conf_spec.bats (33)

Mirrors `lib/setup_conf.sh`. setup.conf merging (`_load_setup_conf` replace
strategy) resolving the per-repo override from the repo-root `.setup.conf`
dotfile (a legacy `config/docker/setup.conf` is no longer read),
`_get_conf_value` / `_get_conf_list_sorted` (incl. empty-skip), and the
`_rule_basename` image-rule helper. Also guards the shipped `dist/` prose
against pre-relocation path names: the four `setup_tui.sh` usage heredocs
must advertise `.setup.conf`, and no shipped text may still say
`<repo>/setup.conf` or `.base/setup.conf` (#842).

| Test | Description |
|------|-------------|
| `_setup_conf_layers: an explicit dist dir places the template layer (#956)` | - |
| `_setup_conf_layers: _SETUP_SCRIPT_DIR still places the template layer when no dist dir is given (#956)` | - |
| `_setup_conf_layers: no _SETUP_SCRIPT_DIR and no dist dir omits the template layer (#956)` | - |
| `_load_setup_conf returns every entry of the per-repo section` | - |
| `_load_setup_conf ignores an ambient SETUP_CONF pointing at another file` | - |
| `_load_setup_conf does not resolve to an empty config when an ambient SETUP_CONF path is absent` | - |
| `_setup_conf_handle ignores an ambient SETUP_CONF` | - |
| `_compute_conf_hash ignores an ambient SETUP_CONF` | - |
| `_load_setup_conf uses per-repo setup.conf when section present` | - |
| `_load_setup_conf reads the per-repo override from repo-root .setup.conf` | - |
| `_load_setup_conf ignores a legacy config/docker/setup.conf override` | - |
| `setup_tui.sh usage names the repo-root .setup.conf in every language (#842)` | - |
| `no shipped dist/ text still points at the pre-relocation <repo>/setup.conf (#842)` | - |
| `no shipped dist/ text names the non-existent .base/setup.conf default (#842)` | - |
| `_load_setup_conf falls back to template when section absent per-repo` | - |
| `_load_setup_conf replace strategy: per-repo section fully replaces template section` | - |
| `_load_setup_conf: .setup.conf.local overrides the per-repo section` | - |
| `_load_setup_conf: .setup.conf.local overrides the template for a section the repo omits` | - |
| `_load_setup_conf: .setup.conf.local replaces a section wholesale, never per-key` | - |
| `_load_setup_conf: sections .setup.conf.local omits keep the layer below` | - |
| `_setup_conf_handle: .setup.conf.local wins over the per-repo layer` | - |
| `_compute_conf_hash: editing .setup.conf.local is drift` | - |
| `_setup_effective_full: show/list read the local layer too` | - |
| `_setup_conf_local_sections: names the sections the local layer shadows` | - |
| `_setup_conf_local_sections: empty when no local layer is present` | - |
| `_get_conf_value returns value for present key` | - |
| `_get_conf_value returns default for absent key` | - |
| `_get_conf_list_sorted returns values sorted by numeric suffix` | - |
| `_get_conf_list_sorted skips non-matching keys` | - |
| `_rule_basename returns last non-empty path component` | - |
| `_rule_basename skips trailing slashes` | - |
| `_rule_basename handles single-component path` | - |
| `_get_conf_list_sorted skips entries with empty value` | - |

### test/bats/unit/setup_detect_spec.bats (50)

Mirrors `lib/setup_detect.sh`. Isolated host-detection units:
`detect_user_info`, `detect_hardware`, `detect_docker_hub_user`,
`detect_gpu` / `detect_gpu_count` (incl. the nameref regression),
`detect_gui`, `_is_ssh_x11` (#321), the SSH X11 cookie rewrite
(`_setup_ssh_x11_cookie`, #321/#688), the `detect_image_name` rule engine +
sanitization, `detect_ws_path`, and `_reconcile_workspace_path` (#569).

| Test | Description |
|------|-------------|
| `detect_user_info uses USER env when set` | - |
| `detect_user_info falls back to id -un when USER unset` | - |
| `detect_user_info sets group uid gid correctly` | - |
| `detect_hardware returns uname -m output` | - |
| `detect_docker_hub_user uses docker info username when logged in` | - |
| `detect_docker_hub_user falls back to USER when docker returns empty` | - |
| `detect_docker_hub_user falls back to id -un when USER also unset` | - |
| `detect_gpu returns true when nvidia-container-toolkit is installed` | - |
| `detect_gpu returns false when nvidia-container-toolkit is not installed` | - |
| `detect_gpu: a dpkg-query still writing cannot report an installed toolkit as missing (#905)` | - |
| `detect_gpu_count returns count of GPUs from nvidia-smi -L output` | - |
| `detect_gpu_count returns 0 when nvidia-smi is missing` | - |
| `detect_gpu_count returns 0 when nvidia-smi fails (driver broken)` | - |
| `detect_gpu_count nameref survives caller-local named '_line' (regression)` | - |
| `detect_gui returns true when DISPLAY is set` | - |
| `detect_gui returns true when WAYLAND_DISPLAY is set` | - |
| `detect_gui returns false when both DISPLAY and WAYLAND_DISPLAY unset` | - |
| `_is_ssh_x11 true when SSH_CONNECTION set + DISPLAY=localhost:N (#321)` | - |
| `_is_ssh_x11 true when DISPLAY=localhost:N without fractional part (#321)` | - |
| `_is_ssh_x11 false when SSH_CONNECTION unset (#321)` | - |
| `_is_ssh_x11 false when DISPLAY is local socket (:0) (#321)` | - |
| `_is_ssh_x11 false when DISPLAY is unset (#321)` | - |
| `_is_ssh_x11 false when DISPLAY points to a remote host (#321)` | - |
| `detect_image_name uses template default rules (prefix:docker_ → strip)` | - |
| `detect_image_name uses template default rules (suffix:_ws → strip)` | - |
| `detect_image_name template default falls through to @basename for generic paths` | - |
| `detect_image_name honors per-repo setup.conf [image] rules` | - |
| `detect_image_name rules apply in order (first match wins)` | - |
| `detect_image_name @default:<value> used when no rule matches` | - |
| `detect_image_name lowercases the result` | - |
| `detect_image_name returns unknown when no rule matches and no @default` | - |
| `detect_ws_path strategy 1: docker_* finds sibling *_ws` | - |
| `detect_ws_path strategy 1: docker_* without sibling falls through` | - |
| `detect_ws_path strategy 2: finds _ws component in path` | - |
| `detect_ws_path strategy 3: falls back to base_path itself` | - |
| `detect_ws_path fails with ERROR when base_path does not exist` | - |
| `detect_image_name uses @basename rule alone (exercises _rule_basename)` | - |
| `detect_image_name replaces '.' with '-' (regression: tmp.abcdef → tmp-abcdef)` | - |
| `detect_image_name collapses runs of '-' and strips leading/trailing separators` | - |
| `detect_image_name string:<value> short-circuits path parsing` | - |
| `detect_image_name string value is still lowercased + sanitized` | - |
| `_reconcile_workspace_path: portable form detects WS_PATH locally, mount_1 untouched (#569)` | - |
| `_reconcile_workspace_path: absolute existing host path is honored as WS_PATH (#569)` | - |
| `_reconcile_workspace_path: stale absolute path warns + rewrites mount_1 to portable (#569)` | - |
| `_reconcile_workspace_path: empty mount_1 detects WS_PATH only, conf untouched (#569)` | - |
| `_reconcile_workspace_path: first-time bootstrap copies template + writes portable mount_1 (#569)` | - |
| `_setup_ssh_x11_cookie writes .docker.xauth and echoes its path (#321)` | - |
| `_setup_ssh_x11_cookie returns 1 with warning when nmerge writes 0-byte cookie (#321 hotfix)` | - |
| `_setup_ssh_x11_cookie returns 1 with warning when nmerge pipe exits non-zero (#688)` | - |
| `_setup_ssh_x11_cookie returns 1 with warning when xauth is not installed (#321)` | - |

### test/bats/unit/setup_spec.bats (123)

The `setup.sh` orchestrator spec. `main` subcommand dispatch (`set` / `show`
/ `remove` for `[logging]` #328 and `[lifecycle]` #478, `reset`, `--lang` /
error paths), `usage`, `_setup_msg` / `_msg` i18n, and the `apply` pipeline
integration tests that drive detect → resolve → write_env → compose emit
end-to-end: template-shipped defaults and emitted blocks for `[lifecycle]`
restart (#478), `[deploy]` `dri_groups` (#496) and `gpu_runtime` alias
(#481), `[additional_contexts]` (#199), `[build]` `arg_N` / `target_arch` /
`network`, `[security]` opt-in (#466), `config/<component>/` bind
(#504/#1000), `.env.generated` cache + `.env` overlay (#502), workspace
writeback (#174/#201), `--gui` / `--no-x11-cookie` / `--print-resolved`
flags (#338), `--quiet` confirmation lines (#285), #450 propagation +
duplicate-target guards, and S7 `runtime.env` retirement (#507).

| Test | Description |
|------|-------------|
| `template setup.conf devices opt-in (#466): device_1 is a commented example, not a default` | - |
| `[devices] opt-in (#466): empty section + slim template emits no devices block` | - |
| `template setup.conf [deploy] enables ALL GPU capabilities by default` | - |
| `setup.sh apply emits top-level name: in compose.yaml (#472)` | - |
| `[lifecycle] restart = always lands on the deployable stage, never on devel (#478, #840)` | - |
| `[lifecycle] restart = always emits nothing when no stage is deployable (#840)` | - |
| `[lifecycle] restart = no emits no restart: field (#478)` | - |
| `[lifecycle] restart = on-failure:3 emits quoted value (#478)` | - |
| `template setup.conf ships [lifecycle] restart = unless-stopped (#478, #840)` | - |
| `setup.sh set lifecycle.restart rejects an invalid policy (#478)` | - |
| `[lifecycle] init defaults ON: emits init: true under devel (#792)` | - |
| `[lifecycle] init = false omits init: field (#792)` | - |
| `template setup.conf ships [lifecycle] init = true (#792)` | - |
| `setup.sh set lifecycle.init rejects a non-boolean (#792)` | - |
| `setup.sh set lifecycle.restart accepts the 5 canonical values (#478)` | - |
| `[deploy] dri_groups = auto + GUI emits group_add with numeric GIDs (#496)` | - |
| `[deploy] dri_groups = auto with no /dev/dri emits no group_add (#496)` | - |
| `[deploy] dri_groups = off emits no group_add even with GUI (#496)` | - |
| `[deploy] dri_groups = auto without GUI emits no group_add (GUI-gated) (#496)` | - |
| `template setup.conf ships [deploy] dri_groups = auto (#496)` | - |
| `[deploy] gpu_runtime primary key emits runtime: nvidia (#481)` | - |
| `[deploy] legacy runtime key still works + warns (#481 W3 alias)` | - |
| `[deploy] gpu_runtime wins when both keys present (#481)` | - |
| `template setup.conf ships [deploy] gpu_runtime = auto (#481)` | - |
| `per-stage override accepts deploy.gpu_runtime (#481)` | - |
| `per-stage override still accepts legacy deploy.runtime (#481 alias)` | - |
| `[security] cap_add opt-in (#466): empty section + slim template emits no cap_add` | - |
| `[security] security_opt opt-in (#466): empty section + slim template emits no security_opt` | - |
| `[security] opt-in via wrapper: setup.sh add security.cap_add then apply emits cap_add (#466)` | - |
| `[security] privileged defaults to false when key absent (#466 opt-in)` | - |
| `[security] opt-in still works via explicit declaration (#466 regression)` | - |
| `[additional_contexts] omitted by default (back-compat: no block in compose.yaml)` | - |
| `[additional_contexts] context_1 = NAME=PATH emits block under devel/test build` | - |
| `[additional_contexts] runtime service inherits the block when Dockerfile declares AS runtime` | - |
| `[additional_contexts] entries sort by numeric suffix (context_2 / context_10)` | - |
| `[additional_contexts] empty value (cleared slot) is skipped` | - |
| `set logging.driver round-trips via show (#328)` | - |
| `set logging.compress accepts true/false; rejects others (#328)` | - |
| `set logging.max_file rejects non-positive integers (#328)` | - |
| `set logging.max_size accepts num+unit; rejects malformed (#328)` | - |
| `set logging.driver rejects whitespace/empty-shape names (#328)` | - |
| `set logging.<svc>.<key> writes to per-service section (#328)` | - |
| `remove logging.<svc>.<key> deletes the per-service key (#328)` | - |
| `show logging prints the whole resolved [logging] section (#328)` | - |
| `set logging.local_path accepts relative path (#328)` | - |
| `set logging.local_path accepts absolute path (#328)` | - |
| `set logging.local_path rejects whitespace-only value (#328)` | - |
| `set logging.<svc>.local_path writes to per-service section (#328)` | - |
| `[security] cap_add_* explicit override: user-provided list is honored (no template fallback)` | - |
| `main rejects bare flag without subcommand (#49 Phase B-4 BREAKING)` | - |
| `apply subcommand returns error when --base-path value is missing` | - |
| `apply subcommand returns error when --lang value is missing` | - |
| `apply --lang zh-TW sets Chinese messages for full run` | - |
| `apply prints WARN when per-repo setup.conf is missing (#186)` | - |
| `apply prints WARN when per-repo setup.conf has no section headers (#186)` | - |
| `apply stays silent when per-repo setup.conf has at least one section` | - |
| `apply --lang zh-TW prints WARN in Traditional Chinese when setup.conf missing (#186)` | - |
| `apply resolves default _base_path via BASH_SOURCE when --base-path omitted` | - |
| `apply writes the derived cache to .env.generated (not .env)` | - |
| `apply scaffolds .env.local when absent (#868)` | - |
| `apply does NOT overwrite an existing .env.local (#868)` | - |
| `apply migrates a legacy .env cache to .env.generated + backs it up` | - |
| `apply emits env_file: .env then .env.local on the devel service (#868)` | - |
| `apply generates .env and scaffolds .env.local (#868)` | - |
| `apply rewrites .env but never rewrites .env.local (#868)` | - |
| `apply routes [environment] env_N into .env, not the compose environment: block (#868)` | - |
| `apply dev-binds each config/<component>/ into the devel service (#504/#1000)` | - |
| `apply dev-binds two component dirs to two distinct destinations (#1000)` | - |
| `apply dev-binds config/shell and config/pip too, and says which (#1000)` | - |
| `apply omits the config bind when no component dir exists, and SAYS so (#504/#1000)` | - |
| `apply WARNs about config files sitting directly under config/ (#1000)` | - |
| `apply stays quiet about the config/.gitkeep placeholder (#1000)` | - |
| `apply names the preset selector and the file it resolves to (#826)` | the selector reaches the real apply path |
| `apply WARNs when the preset selector resolves to nothing (#826)` | a broken selector reaches the real apply path |
| `main reset --yes works on first-time bootstrap (no prior .local or setup.conf) (#174)` | - |
| `_setup_msg returns English messages by default` | - |
| `_setup_msg returns Traditional Chinese messages when _LANG=zh-TW` | - |
| `_setup_msg returns Simplified Chinese messages when _LANG=zh-CN` | - |
| `_setup_msg returns Japanese messages when _LANG=ja` | - |
| `_setup_msg env_comment and unknown_arg are defined in zh` | - |
| `_setup_msg env_comment and unknown_arg are defined in zh-CN` | - |
| `_setup_msg env_comment and unknown_arg are defined in ja` | - |
| `_msg falls back to English when _LANG is unknown` | - |
| `[build] template defaults ship TW mirrors via arg_N` | - |
| `[build] arg_N override replaces TW default when set` | - |
| `[build] back-compat: old apt_mirror_* named keys still read` | - |
| `[build] user-added arg_N propagates to .env` | - |
| `[build] target_arch = arm64 writes TARGET_ARCH to .env` | - |
| `[build] target_arch empty omits TARGET_ARCH from .env` | - |
| `[build] network = host writes BUILD_NETWORK to .env` | - |
| `[build] network empty omits BUILD_NETWORK from .env` | - |
| `workspace first-time: writes ${WS_PATH} variable form (portable)` | - |
| `workspace second-run: ${WS_PATH} form re-detects per machine` | - |
| `workspace second-run: respects user-pinned absolute path via setup.conf (#174)` | - |
| `workspace second-run: stale setup.conf path is harmlessly overwritten (#174)` | - |
| `fresh bootstrap: empty dir + main apply emits workspace mount in compose.yaml (#201 regression)` | - |
| `workspace opt-out: cleared mount_1 means no workspace mount in compose` | - |
| `setup.sh set: prints 3-line confirmation by default` | - |
| `setup.sh set --quiet: produces empty stdout` | - |
| `setup.sh set -q: short form also suppresses output` | - |
| `setup.sh set --quiet: still writes the value (mutation not skipped)` | - |
| `setup.sh add: prints 3-line confirmation by default` | - |
| `setup.sh add --quiet: produces empty stdout` | - |
| `setup.sh remove: prints 3-line confirmation by default` | - |
| `setup.sh remove --quiet: produces empty stdout` | - |
| `setup.sh reset --yes: prints next: hint and file: by default` | - |
| `setup.sh reset --yes --quiet: produces empty stdout` | - |
| `setup.sh apply --quiet: suppresses the env_done + USER=... summary` | - |
| `apply --gui off overrides [gui] mode via print-resolved (#338)` | - |
| `apply --gui=force enables GUI even when setup.conf says off (#338)` | - |
| `apply --gui rejects values outside auto\|force\|off (#338)` | - |
| `apply --print-resolved prints KEY=VALUE state without writing .env (#338)` | - |
| `apply --print-resolved respects --gui override in the dump (#338)` | - |
| `apply --no-x11-cookie records X11_COOKIE_SKIP=1 in print-resolved (#338)` | - |
| `apply without --no-x11-cookie records X11_COOKIE_SKIP=0 (default) (#338)` | - |
| `apply SETUP_GUI env var overrides setup.conf when --gui not passed (#338)` | - |
| `apply --gui CLI wins over SETUP_GUI env var (resolution order CLI > env) (#338)` | - |
| `apply warns when device propagation used without privileged (#450 P2)` | - |
| `apply suppresses propagation warning when privileged is true (#450 P2)` | - |
| `apply warns when device and volume have same target path (#450 P4)` | - |
| `apply does NOT warn duplicate when device and volume targets differ (#450 P4)` | - |
| `apply no longer emits runtime.env; [environment] still reaches the container (#868)` | - |
| `_write_runtime_env is removed (#507)` | - |

### test/bats/unit/shell_metrics_spec.bats (59)

| Test | Description |
|------|-------------|
| `population: a tracked .sh file is read (#994)` | - |
| `population: a tracked EXTENSIONLESS file whose first two bytes are '#!' is read (#994)` | - |
| `population: a tracked extensionless file WITHOUT a shebang is not read (#994)` | - |
| `population: a tracked SYMLINK ending .sh is not read (#994)` | - |
| `population: an UNTRACKED .sh file is not read (#994)` | - |
| `population: an EMPTY population is refused, never reported clean (#994)` | - |
| `parser: a shell KEYWORD USED AS AN ARGUMENT closes nothing (#994)` | - |
| `parser: double-quote scanning RECURSES into command substitution (#994)` | - |
| `parser: a dollar-single-quote holding an escaped quote does not swallow the file (#994)` | - |
| `parser: a heredoc body containing 'if' and 'done' is data, not syntax (#994)` | - |
| `parser: a heredoc body does not count toward function length (#994)` | - |
| `parser: a case pattern containing ')' does not end the pattern early (#994)` | - |
| `parser: a double-semicolon inside a string does not end a case arm (#994)` | - |
| `parser: a comment containing 'fi' closes nothing (#994)` | - |
| `parser: a comment-only line does not count toward length (#994)` | - |
| `parser: a function defined INSIDE a function yields two records (#994)` | - |
| `parser: an inner function definition adds a level to the OUTER depth (#994)` | - |
| `parser: 'function name {' with no parens is a function definition (#994)` | - |
| `parser: 'function name() {' is a function definition (#994)` | - |
| `parser: a one-line function body is measured as one line (#994)` | - |
| `parser: an array assignment is not read as a function definition (#994)` | - |
| `parser: an array literal's elements are DATA, not commands (#994)` | - |
| `parser: a SINGLE-LINE array literal's elements are data too (#994)` | - |
| `parser: an UNBALANCED keyword in an array literal is data too, not a finding (#994)` | - |
| `parser: a command substitution INSIDE an array literal is still a command context (#994)` | - |
| `parser: CRLF line endings are read like LF (#994)` | - |
| `parser: a construct opened and CLOSED inside a command substitution (#994)` | - |
| `parser: every closing keyword written against a ')' closes its own construct (#994)` | - |
| `counting: a case arm adds NO level, so case matches the if/elif chain it replaces (#994)` | - |
| `counting: a brace group and a subshell add no level; the construct inside them does (#994)` | - |
| `counting: length is body CODE lines, excluding the header and closing brace (#994)` | - |
| `counting: positional parameters are the HIGHEST index reached, not the count of distinct ones (#994)` | - |
| `counting: an unbraced positional takes ONE digit, the way bash reads it (#994)` | - |
| `counting: a forwarded argument list does not raise the count but marks the function variadic (#994)` | - |
| `counting: a 'shift' raises the index a later positional reaches (#994)` | - |
| `counting: a 'shift' inside a loop is unbounded, so the function is variadic (#994)` | - |
| `counting: a shift with a QUOTED non-literal count marks the function variadic (#994)` | - |
| `counting: a bare shift is still one position, not a non-literal count (#994)` | - |
| `counting: a nested function has its OWN positional parameters (#994)` | - |
| `refusal: an unbalanced construct is reported, and the file's records are dropped (#994)` | - |
| `refusal: an unterminated quote is reported (#994)` | - |
| `refusal: a legacy backtick substitution is reported rather than guessed at (#994)` | - |
| `limitation: a function body that is not a brace group is a finding, not a record (base#994)` | - |
| `limitation: an arithmetic left shift is misread as a heredoc, and errs toward a finding (base#994)` | - |
| `_run_nesting_depth: reports a depth-4 function by file, name and value whatever the verdict (#994)` | The row is what phase 3 works from, and it is printed whatever the verdict -- a run that showed the worklist only when the ceiling broke would be a lint nobody could act on between slices. The status is deliberately NOT asserted here: whether ONE violation fails depends on the ceiling, which every slice lowers, and pinning it would make this case need an edit each time. |
| `_run_nesting_depth: FAILS one over the adoption ceiling, naming both figures (#994)` | The ceiling is the verdict, so this is the case that says what the gate is FOR: one more violation than the tree is carrying today fails, and the failure names both figures so the reader knows whether to fix the function or lower the number. |
| `_run_nesting_depth: a population AT the ceiling passes (#994)` | The other side of the boundary, and the one that makes the ratchet usable at all: a population AT the ceiling passes, which is what lets a slice land without flattening all 23 functions at once. |
| `_run_nesting_depth: passes at depth 3 (#994)` | The threshold's own boundary from below, and the case that stops the reader drifting one level: a three-deep function is the shape the limit was set to admit (65 functions in the tree sit exactly here), so an off-by-one in the counter would be visible as a green tree turning red on code nobody changed. |
| `_run_function_length: reports a function at 51 body code lines (#994)` | The threshold's own boundary, one body code line over. It is the row and not the verdict for the same reason as the depth case above. |
| `_run_function_length: FAILS one over the adoption ceiling (#994)` | Length carries the largest unflattened population of the three, so it is the ceiling most likely to be reached for by a change that wants to add one more long function rather than split it. |
| `_run_function_length: passes at exactly 50 body code lines (#994)` | Exactly at the limit, which is where a length metric is most likely to be wrong by one -- the header line and the closing brace are both excluded, and this is the case that says so. |
| `_run_positional_params: reports a function at 6 positional parameters (#994)` | Six positions is the first value past the threshold, and the parameter metric is the one the epic sized its first slice from, so the row's exact wording is what that slice reads. |
| `_run_positional_params: FAILS one over the adoption ceiling (#994)` | The parameter ceiling is the lowest of the three and the first one a slice will drive to zero, so this is the case that will still be meaningful when the other two are still counting down. |
| `_run_positional_params: passes at exactly 5 (#994)` | Five is the widest signature base admits, and the case that keeps the in/out nameref shape legal: two arrays in, one out and two scalars is a real function here, not a violation waiting to be counted. |
| `the census names count, limit, ceiling and slack on a CLEAN run (#994)` | The census is the cost of the ceiling made visible -- slack is the room in which a new violation can land green -- and a cost nobody can see is one nobody closes. It prints on a CLEAN run too, which is the run where nobody would otherwise look. |
| `each ceiling is ONE readonly integer, and the driver carries no exemption vocabulary (#994)` | One number per metric is what "no roster" has to mean in the code, and it is checkable: a ceiling that named sites would need a data structure or a vocabulary of exemption, and this refuses both. The header argues the case; without this the argument is the only thing holding it. |
| `the three lints share ONE reader pass (#994)` | The one-reader claim in the driver header is the reason three lints live in one file, and it is a performance AND a correctness claim: three passes could disagree about where a function begins. This is the case that keeps the memoisation from being quietly lost. |
| `_run_shell_metrics: reports all three metrics in one run (#994)` | The combined report is what `just test metrics` runs, so it has to say all three states in one pass rather than stopping at the first -- a report that stopped would hide two thirds of the tree behind whichever metric ran first. |
| `_run_shell_metrics: FAILS when ONE metric is past its ceiling (#994)` | The combined report has three verdicts to reconcile and one exit status to say them in. Failing when ANY metric is past its own ceiling is what keeps it from being the loosest of the three -- the shape a caller would reach for if it reported the union but judged by the minimum. |

### test/bats/unit/smoke_harness_spec.bats (15)

| Test | Description |
|------|-------------|
| `the smoke harness ships a dockerfile and a compose service that builds it` | - |
| `just test smoke builds through the docker namespace, not a raw docker build (ADR-00000011 sec.5)` | - |
| `just test smoke resolves the tooling image and names the compose project (#896, #891)` | - |
| `just test smoke names the image it builds after the resolved project, not the directory (#891)` | - |
| `just test smoke is NOT wired into the default just test gate` | - |
| `the harness reproduces every devel-test COPY into /lint and /smoke_test` | - |
| `every harness COPY exemption is still a real devel-test COPY` | - |
| `the harness installs the entrypoint the shared smoke baseline asserts` | - |
| `the harness installs the orchestrator the shared smoke baseline asserts (#945)` | The orchestrator arrives in a consumer through a runtime-directory COPY that lands outside /lint and /smoke_test, so the COPY-set parity loop above cannot see it. Without this the harness silently stops installing the half the shared baseline asserts, and that assertion goes red here and green nowhere |
| `the harness Dockerfile writes the manifest before the specs read it (#951)` | The manifest and the OCI annotation the sys stage writes are mirrored here, and written before `RUN bats`; whether the specs then run rather than skip is asserted at system level, which builds this file |
| `the harness exports BATS_LIB_PATH like the devel-test stage does` | - |
| `the harness runs the specs as a non-root user, after the COPYs` | - |
| `the harness asserts at BUILD time, exactly like the stage it stands in for` | - |
| `the harness has no compose image name to displace a sibling checkout's (#891)` | - |
| `runtime-test ships no specs, which is why the harness covers devel-test only` | - |

### test/bats/unit/smoke_helper_spec.bats (33)

Exercises the runtime assertion helpers shipped in
`dist/test/bats/smoke/shared/test_helper.bash` (used by downstream-repo
smoke specs via `load "${BATS_TEST_DIRNAME}/test_helper"`).

| Test | Description |
|------|-------------|
| `assert_cmd_installed passes when cmd is on PATH` | Happy path |
| `assert_cmd_installed fails with descriptive message when cmd missing` | Missing cmd |
| `assert_cmd_installed errors when cmd arg missing` | Required arg check |
| `assert_cmd_runs passes when cmd exits 0` | Happy path |
| `assert_cmd_runs uses custom version flag when given` | Custom flag |
| `assert_cmd_runs fails when cmd exits non-zero` | Broken binary |
| `assert_cmd_runs fails when cmd is not installed` | Missing cmd |
| `assert_file_exists passes when file is a regular file` | Happy path |
| `assert_file_exists fails when path is missing` | Missing path |
| `assert_file_exists fails when path is a directory` | Type check |
| `assert_dir_exists passes when path is a directory` | Happy path |
| `assert_dir_exists fails when path is missing` | Missing path |
| `assert_dir_exists fails when path is a file` | Type check |
| `assert_file_owned_by passes when owner matches` | Happy path |
| `assert_file_owned_by fails with owner diff when user mismatches` | Owner mismatch |
| `assert_file_owned_by fails when path missing` | Missing path |
| `assert_pip_pkg passes when pip show returns 0` | Package installed |
| `assert_pip_pkg fails when pip show returns non-zero` | Package missing |
| `assert_pip_pkg fails when pip is not installed` | pip itself missing |
| `run_wrapper_xhost: wayland session grants +SI:localuser to the .env user` | - |
| `run_wrapper_xhost: x11 session grants +local:` | - |
| `run_wrapper_xhost: an unset XDG_SESSION_TYPE falls back to the X11 grant` | - |
| `run_wrapper_xhost: reports every xhost call, one per line` | - |
| `run_wrapper_xhost: fails loudly when the wrapper makes no xhost call` | - |
| `run_wrapper_xhost: fails when the wrapper exits non-zero` | - |
| `run_wrapper_xhost: fails when the wrapper path does not exist` | - |
| `run_wrapper_xhost: fails when the wrapper's lib/ cannot be located` | - |
| `run_wrapper_xhost: errors when the wrapper path arg is missing` | - |
| `entrypoint_is_single_file: true for a file that execs the workload` | The pre-ADR-00000032 model, which is what the guard exists for. A false answer here makes the shared baseline assert the orchestrator on a repo that never installed one, turning its next `just upgrade` into a red build over a model it did not adopt |
| `entrypoint_is_single_file: false for a bringup that only sets env` | The other direction, and the one that keeps the guard non-vacuous: a probe that answered true for everything would skip the orchestrator assertion everywhere and report green over an unchecked suite |
| `entrypoint_is_single_file: a commented exec is not an exec` | The seeded bringup template TALKS about the exec it must not have, and a repo that migrated by commenting the line out has migrated. A substring match on `exec` reads both as the old model and would skip the assertion on every correctly migrated repo -- the same code-versus-comment distinction dockerfile_migrate.sh's notice makes |
| `entrypoint_is_single_file: false when the path does not exist` | An image with no bringup at all is not on the old model, so the orchestrator assertion must still run there. Answering true on a missing path would silently exempt exactly the image most likely to be missing the orchestrator too |
| `entrypoint_is_single_file: errors when the path arg is missing` | The caller-error case, separated from the honest false above: a no-argument call must say so rather than answer "not the old model", which is the answer that turns a typo in a spec into a silent skip |

### test/bats/unit/sourceable_scripts_spec.bats (8)

| Test | Description |
|------|-------------|
| `sourceable scripts: the discovered set is non-empty and covers the known entry points (#869)` | - |
| `sourceable scripts: none leaves nounset or errexit on in its caller (#869)` | - |
| `sourceable scripts: each loads and returns control to the caller (#869)` | - |
| `self-location: the lib umbrella loads with BASH_SOURCE unpopulated (#869)` | - |
| `self-location: the TUI wrapper loads with BASH_SOURCE unpopulated (#869)` | - |
| `self-location: the setup wrapper loads with BASH_SOURCE unpopulated (#869)` | - |
| `self-location: the self-test dispatcher loads with BASH_SOURCE unpopulated (#869)` | - |
| `self-location: every docker lib module loads with BASH_SOURCE unpopulated (#869)` | - |

### test/bats/unit/spec_markers_spec.bats (12)

The grammar this reader implements is the whole of the contract between an
author and doc/test/*.md: a description is authored on the lines above the
`@test` and rendered from there, so what counts as "attached", what counts
as a continuation and what counts as detached decides whether a sentence
reaches the catalogue at all.

Both the generator and the description lint call this one function, so a
case here is a case for both. That is deliberate -- a second copy of the
attachment loop would agree on the day it was pasted and drift afterwards,
which is the defect class the whole change removes.

The findings get as much room as the happy path because each one is a silent
failure otherwise: a detached block still looks like a description in the
file and renders as nothing, and an orphan is what a rename leaves behind.

| Test | Description |
|------|-------------|
| `_spec_markers_scan: a one-line block above a test is that test's description` | The ordinary case, and the one every other case is a deviation from: one comment line, one test, the prose arriving as that test's description with the marker flag set. |
| `_spec_markers_scan: continuation lines join with a single space` | Multi-line is what makes the marker usable at this tree's ~76-column norm; if continuations were dropped rather than joined, every description longer than one line would silently lose its tail. |
| `_spec_markers_scan: comment lines ABOVE the marker are not part of it` | The block starts at `# why:`, not at the top of the comment run. Without that, the section dividers this tree already uses would be swallowed into the description of whichever test follows them. |
| `_spec_markers_scan: a blank line between block and test detaches it, and the block is an orphan` | A blank line is what separates a block from its test, and the failure it causes is invisible: the prose is still in the file, still reads as a description, and reaches nothing. Both halves are asserted -- the test comes back UNMARKED and the block is reported as an orphan -- because either one alone would let the other regress. |
| `_spec_markers_scan: a bare '#' inside a test's block is a detached finding` | A bare `#` inside a block is how a description detaches without a blank line, and it is the shape a re-wrap or a paste produces. It is a finding rather than a paragraph break precisely because it looks like formatting. |
| `_spec_markers_scan: a second '# why:' inside one block is a nested-marker finding` | Two markers for one test are two answers, and the renderer can only use one. Reporting it is what keeps the second from being silently absorbed into the first as prose. |
| `_spec_markers_scan: a '@test' line the canonical form cannot read is a finding, not a skip` | THE load-bearing case for the counts. The per-spec heading count is `grep -c '^@test'`, so a line the counter counts and the reader skips would put the heading and the rows out of step with every gate green. The reader opens on the counter's own anchor and REFUSES what it cannot read; it must not quietly pass over it. |
| `_spec_markers_scan: a '# why:' in the opening comment run is the file blurb` | The file-level block is the section blurb, and it is told apart from a test's description by POSITION alone -- so the opening comment run has to be read as its own site rather than as the first test's marker. |
| `_spec_markers_scan: a bare '#' in the FILE block is a paragraph break, not a finding` | Twenty-one section blurbs in this tree are two or more paragraphs. Flattening them would destroy structure the generator can reproduce exactly, so a bare `#` means something different here than it does above a test -- there is no `@test` beneath it to detach from. |
| `_spec_markers_scan: an opening run touching the first @test is an ambiguous-blurb finding` | When the opening run touches the first `@test`, the file blurb and that test's description are the same lines and no reading of them is right. Guessing either way would put the generator and the lint on different answers, so the ambiguity is reported and the positional rule (attached wins) is applied deterministically. |
| `_spec_markers_scan: a backslash-escaped name resolves to what bats reports` | A row's identity is the name bats reports, so a row can be pasted into `--filter`. The unescaping has to happen in the reader, because the reader is now the only thing that sees the raw `@test` line. |
| `_spec_markers_scan: a spec with no markers yields tests, no blurb and no findings` | A file with no markers at all must come back empty rather than failing: the reader answers about one path, and only the CALLER knows whether an empty answer is vacuous. |

### test/bats/unit/spec_source_isolation_spec.bats (4)

One repo-wide invariant over `test/bats/`: a spec may READ the live checkout
-- that is where its subject lives -- but may not settle an assertion by
COMPARING against it. "Every spec that touches `/source`" is not the
population: 125 of the 129 spec files reference it (measured 2026-08-31; the
same figures are stated in the spec's own header, and a drift between them
is drift, not a rounding). What separates the defect is who owns the answer,
and by that measure a live path as a comparison operand had exactly one
instance -- the `readme_sync` case that failed five gate runs.

This file used to carry a second invariant, a scan for WRITES into the live
tree, and it is gone. That one was a roster of the commands a write can be
spelled with, and three consecutive reviews each found another spelling it
CLAIMED and could not see (a third operand of `mv` or `install`, `dd`'s
`of=PATH`, `rsync` in no pattern at all) plus one it flagged for merely
READING. Its property now has an executed form with no roster and no false
positives: `script/test/test.sh` snapshots the checkout either side of the
bats phase and fails naming any path that differs -- see
`residue_guard_spec.bats`. The one spelling the snapshot cannot see is a
spec that writes and then removes its own traces, and the scan could not see
that reliably either.

The comparison scan stays because the snapshot cannot subsume it: a
comparison against the live tree leaves NOTHING behind, so there is no
residue to find. What it is NOT is a closed set, and two rounds of this
file's header said it was. That argument -- the write roster enumerated the
commands that can write, which is every binary that exists, while this
enumerates the places a shell can begin a command, which is the shell's
finite grammar -- holds for the POSITION axis alone. The scan has two more
axes and both are rosters: it matches two command NAMES, and the live path
as the first or second WORD after a run of flags -- not the first or second
OPERAND, which is a spelling it misses. A review planted 18 comparison
spellings and 16 went unseen -- a checksum pair, a comparison driven through
git, an equality test over two command substitutions, a live path that is
the second operand of a comparison and its third word because an option
ahead of it took an argument of its own. One derivable position is unscanned
by choice as well: a backtick, because every line the one-character widening
that sees it matched was this repo's own comment prose and no command at all
(three of them when re-measured 2026-09-01).

So the claim is the narrow one the body can carry: an over-approximation
that catches the COMMON spellings at the moment the line is written, and
names the line. Nothing executed stands behind it -- the residue guard holds
the WRITE property with no roster at all, and the comparison property has no
such backstop -- which is the reason not to overstate the scan rather than a
reason to widen it. What it misses is sampled, one per axis, in a case of
its own, so a later widening is a decision stated there and not a silent
edit to a regex. Like its sibling `spec_subject_guard_spec.bats`, it pins
the scan as well as the result: a population floor, `find` under `pipefail`,
and grep status exactly 1 (scanned, no match) rather than 2 (could not
scan).

| Test | Description |
|------|-------------|
| `no spec settles an assertion by comparing against the live checkout (#965)` | The defect this file was written for: a concurrent writer supplied half the verdict |
| `a scan of a tree that is not there answers 2, not 1 (#965)` | Pinning status 1 only means something while "could not scan" is reachable |
| `the comparison scan sees a live operand in each command position it names (#965)` | The positions come from the grammar, which makes that axis narrow rather than complete |
| `the comparison scan is an over-approximation, not a closed set (#965)` | A sample of what it misses, one per axis: the command name, the word position, line-wise literal matching, and the position omitted by choice |

### test/bats/unit/spec_subject_guard_spec.bats (11)

`assert_spec_subject` (test/bats/unit/test_helper.bash), the fail-closed
opening 54 guards across this suite now share, plus the repo-wide invariant
that no spec goes back to the fail-open form. Those guards used to read `[[
-f "${SUBJECT}" ]] || skip`, which cannot tell "absent by design" from
"renamed and nobody noticed" and answered the second with a green run:
renaming one workflow turned 52 assertions into `ok ... # skip` and the
suite still exited 0. Since a bats outcome cannot be observed from inside
the test that produces it, each case writes a one-test spec into
`BATS_TEST_TMPDIR` and asserts on the TAP the inner `bats` run emits.

| Test | Description |
|------|-------------|
| `assert_spec_subject: a present subject lets the test run to completion` | The normal path costs the caller nothing and skips nothing |
| `assert_spec_subject: a missing subject FAILS the test, it does not skip it` | The whole point: a skip here reports green for a spec that asserted nothing |
| `assert_spec_subject: the failure names the missing path and what it was` | The message has to be actionable without opening the spec |
| `assert_spec_subject: refuses an empty path rather than passing vacuously` | An unset caller variable is a loud bug, not a silent pass |
| `assert_spec_subject_dir: a present directory lets the test run to completion` | The directory form must not fail a subject that is there |
| `assert_spec_subject_dir: a missing directory FAILS the test, it does not skip it` | A tracked tree that vanished is a defect, never a context |
| `assert_spec_subject_dir: a FILE at the path is not the directory it asked for` | Why the guard is -d and not a widened -e |
| `no spec opens with a fail-open '\|\| skip' existence guard` | The repo-wide invariant, so the idiom cannot creep back in |
| `a scan that examined nothing answers 2, not 1` | Pinning "scanned, matched nothing" means something only while "could not scan" is reachable |
| `the fail-open guard scan sees each spelling of the check it claims to cover` | The invariant must be green because no guard exists, not because its pattern is blind |
| `the fail-open guard scan is an over-approximation, not a closed set` | A sample of what it misses, so the disclosure is never wider than the pattern |

### test/bats/unit/stage_spec.bats (104)

Mirrors `lib/stage.sh`. The per-stage engine: `_validate_stage_name` (#215),
`_parse_dockerfile_stages`, `_compute_dockerfile_hash`, `main apply`
auto-emit of non-baseline stages (#215), per-stage overrides #220
(`_parse_stage_sections` / `_load_stage_overrides` /
`_validate_stage_override_key` / `_resolve_stage_scalar` /
`_resolve_stage_list` + compose-emit integration, incl. #493 `devel-test`
override surface), the `_resolve_docker_flags` single per-stage
flag-resolution layer (#505/#526, relocated from the compose spec in P1a),
`_generate_runtime_dockerfile` ENV-bake (#503/#688, relocated from
setup_emit in P1a), and `_is_deployable_stage`, the ADR-00000023 sec.4
stage-eligibility predicate (`deployable = not devel and not *-test`,
widened in #841 to the whole template-managed baseline incl. the `sys` /
`devel-base` build intermediates) that both the deploy-scoped `[lifecycle]
restart` emission and the `setup deploy` stage guard gate on. Also carries
the #875 AGREEMENT spec for `_dockerfile_stage_from_line`, the one shared
"which line declares stage `<S>`" matcher: instead of testing each reader
against its own regex — the shape that let three regexes drift apart until a
`FROM --platform=... AS <stage>` line was a stage to one call site and
invisible to the others — it drives every call site off a single FROM line
and asserts one verdict per site.

| Test | Description |
|------|-------------|
| `_validate_stage_name accepts well-formed names` | - |
| `_validate_stage_name rejects invalid format with exit 1 (WARN+skip)` | - |
| `_validate_stage_name rejects baseline collision with exit 2 (HARD ERROR)` | - |
| `_validate_stage_name accepts devel-test as an emittable stage (#493 A1'-b)` | - |
| `_validate_stage_name rejects reserved tag-namespace names with exit 3 (HARD ERROR)` | - |
| `_parse_dockerfile_stages: returns nothing for Dockerfile with only legacy baseline stages (backward compat)` | - |
| `_parse_dockerfile_stages: returns nothing for Dockerfile with only new baseline stages (#243)` | - |
| `_parse_dockerfile_stages: returns devel-test (promoted out of baseline, #493)` | - |
| `_parse_dockerfile_stages: extracts non-baseline stages` | - |
| `_parse_dockerfile_stages: preserves Dockerfile order` | - |
| `_parse_dockerfile_stages: dedups duplicate stage names` | - |
| `_parse_dockerfile_stages: handles missing Dockerfile gracefully (empty output)` | - |
| `_parse_dockerfile_stages: ignores lowercase 'as' and inline comments` | - |
| `_compute_dockerfile_hash: stable for unchanged stage list` | - |
| `_compute_dockerfile_hash: changes when stage is added` | - |
| `_compute_dockerfile_hash: changes when stage is removed` | - |
| `_compute_dockerfile_hash: stable when non-FROM-AS lines change` | - |
| `_compute_dockerfile_hash: empty when Dockerfile missing` | - |
| `auto-emit: regression for #108 — Dockerfile AS runtime still emits runtime service` | - |
| `auto-emit: multi-stage emits one service per non-baseline stage` | - |
| `auto-emit: each emitted stage carries target / image / profiles and no container_name` | - |
| `the shipped stage-authoring comment promises no container_name override (#920)` | - |
| `auto-emit: no extra stages → only devel + test in compose.yaml` | - |
| `auto-emit: baseline collision (AS test redefined) → hard error exit non-zero` | - |
| `auto-emit: reserved tag namespace (AS latest) → hard error exit non-zero` | - |
| `auto-emit: reserved tag namespace (AS v0) → hard error exit non-zero` | - |
| `auto-emit: invalid format (AS Headless capital) → WARN + skip, apply still succeeds` | - |
| `auto-emit: SETUP_DOCKERFILE_HASH written to .env` | - |
| `auto-emit: drift fires when Dockerfile stage list changes` | - |
| `auto-emit: drift fires when Dockerfile stage is REMOVED` | - |
| `_parse_stage_sections: empty file → empty output` | - |
| `_parse_stage_sections: missing file → empty output (no error)` | - |
| `_parse_stage_sections: extracts [stage:NAME] sections in file order` | - |
| `_parse_stage_sections: ignores plain sections that are not [stage:...]` | - |
| `_load_stage_overrides: returns the keys+values under [stage:NAME]` | - |
| `_load_stage_overrides: .setup.conf.local replaces a [stage:NAME] section (#893)` | - |
| `_load_stage_overrides: a [stage:NAME] the local layer omits keeps the repo's (#893)` | - |
| `_load_stage_overrides: ignores an ambient SETUP_CONF (#893 decision 7)` | - |
| `_load_stage_overrides: missing setup.conf → empty arrays` | - |
| `_load_stage_overrides: stage absent from setup.conf → empty arrays` | - |
| `_validate_stage_override_key: accepts allowlisted scalars` | - |
| `_validate_stage_override_key: accepts list-item keys with numeric suffix` | - |
| `_validate_stage_override_key: accepts inherit meta-keys` | - |
| `_validate_stage_override_key: rejects keys outside allowlist` | - |
| `_resolve_stage_scalar: returns stage value when override present` | - |
| `_resolve_stage_scalar: returns fallback when key absent` | - |
| `_resolve_stage_scalar: returns empty fallback when neither set` | - |
| `_resolve_stage_list: append-default with stage entries (inherit unset)` | - |
| `_resolve_stage_list: replace mode (inherit=false) drops top-level` | - |
| `_resolve_stage_list: empty stage with inherit=true → top-level only` | - |
| `_resolve_stage_list: empty stage with inherit=false → empty result` | - |
| `_resolve_stage_list: preserves stage entries in setup.conf order` | - |
| `_resolve_stage_list: ignores keys with non-numeric suffix` | - |
| `stage-override: regression — stage with NO overrides keeps extends:devel minimal block` | - |
| `stage-override: gui.mode=off in [stage:headless] strips X11 env+volumes from headless` | - |
| `stage-override: network.mode=bridge + port_1 in [stage:headless] emits per-stage ports` | - |
| `stage-override: volumes.mount_inherit=false drops top-level mounts for that stage` | - |
| `stage-override: standalone emit re-emits cap_add + privileged inherited from devel` | - |
| `stage-override: orphan [stage:foo] (no foo in Dockerfile) prints WARN, does not abort` | - |
| `stage-override: disallowed override key (image.rule_1) prints WARN and skips that key` | - |
| `stage-override: [stage:sys] in setup.conf is hard-error (baseline collision)` | - |
| `stage-override(#493): [stage:devel-test] deploy.gpu_mode=force emits GPU deploy block on the test service` | - |
| `_resolve_docker_flags: no overrides => inherits all parent values (#505)` | - |
| `_resolve_docker_flags: gui.mode=off overrides parent gui=true (#505)` | - |
| `_resolve_docker_flags: gui.mode=force overrides parent gui=false (#505)` | - |
| `_resolve_docker_flags: deploy.gpu_mode=off overrides parent gpu=true (#505)` | - |
| `_resolve_docker_flags: deploy.gpu_count + gpu_capabilities overrides win (#505)` | - |
| `_resolve_docker_flags: deploy.gpu_runtime override wins (#505/#481)` | - |
| `_resolve_docker_flags: legacy deploy.runtime alias used when gpu_runtime absent (#505/#481)` | - |
| `_resolve_docker_flags: gpu_runtime beats the legacy deploy.runtime at per-stage scope (#505/#481, #876)` | - |
| `_resolve_docker_flags: network scalars + privileged override (#505)` | - |
| `_resolve_docker_flags: list fields append to top by default (#505)` | - |
| `_resolve_docker_flags: list *_inherit=false switches to replace mode (#505)` | - |
| `_resolve_docker_flags: security cap_add / cap_drop / security_opt append to top by default (#526)` | - |
| `_generate_runtime_dockerfile injects ENV after FROM ... AS runtime` | - |
| `_generate_runtime_dockerfile expands cross-refs in baked ENV` | - |
| `_generate_runtime_dockerfile escapes a double-quote in a baked ENV value (#688)` | - |
| `_generate_runtime_dockerfile neutralises $(...) / backtick in a baked ENV value (#688)` | - |
| `_generate_runtime_dockerfile returns 2 when no runtime stage` | - |
| `_generate_runtime_dockerfile returns 1 and stays quiet when [environment] empty` | - |
| `_generate_runtime_dockerfile bakes ENV into the caller's stage, not a literal runtime (#840)` | - |
| `_generate_runtime_dockerfile bakes into the named stage only, leaving siblings untouched (#840)` | - |
| `_generate_runtime_dockerfile names the absent stage instead of skipping it silently (#840/#875)` | - |
| `all FROM-line call sites agree a plain stage line declares the stage (#875)` | - |
| `all FROM-line call sites agree a --platform flagged line declares the stage (#875)` | - |
| `all FROM-line call sites agree on a multi-flag FROM line (#875)` | - |
| `all FROM-line call sites agree a lowercase 'as' line declares nothing (#875)` | - |
| `all FROM-line call sites agree a commented-out FROM declares nothing (#875)` | - |
| `all FROM-line call sites agree a stray bare token declares nothing (#875)` | - |
| `all FROM-line call sites agree an inline '#' declares nothing (#875)` | - |
| `_dockerfile_stage_from_line reports the declared stage name (#875)` | - |
| `_dockerfile_stage_from_line rejects a flag in the image-reference slot (#875)` | - |
| `_dockerfile_stage_from_line rejects a non-FROM line (#875)` | - |
| `_is_deployable_stage accepts a field-oriented stage (#840)` | - |
| `_is_deployable_stage rejects devel -- a devel container is an interactive shell (#840)` | - |
| `_is_deployable_stage rejects every *-test stage -- they exit by design (#840)` | - |
| `_is_deployable_stage rejects an empty stage name (#840)` | - |
| `_is_deployable_stage rejects the build-intermediate baseline stages (#841)` | - |
| `_resolve_docker_flags: gpu_runtime wins over the legacy alias, as the global resolver does (#876)` | - |
| `_resolve_docker_flags: legacy alias still applies when gpu_runtime is absent (#876)` | - |
| `_resolve_docker_flags: an empty gpu_runtime does not shadow the legacy alias (#876)` | - |
| `_resolve_docker_flags: the legacy alias emits the deprecation warning (#876)` | - |
| `_resolve_docker_flags: the legacy alias warns even when gpu_runtime shadows it (#876)` | - |
| `_resolve_docker_flags: no legacy alias, no deprecation warning (#876)` | - |

### test/bats/unit/stale_setup_conf_lint_spec.bats (11)

Unit tests for `script/test/drivers/stale_setup_conf.sh`
(`_run_stale_setup_conf`, refs #845), the "no stale
`config/docker/setup.conf` path in runtime shell code" lint. The per-repo
override and the template default now live at the repo-root `.setup.conf`
dotfile, so a hardcoded legacy path in `dist/**/*.sh` reads a location that
no longer exists and silently ignores the repo's knobs. The legacy-migration
block in `dist/script/base/upgrade.sh` is the one legitimate consumer and
opts out via explicit `allow-begin` / `allow-end` markers. Driven over
throwaway fixture `dist/` trees, plus a real-tree guard that the live
`dist/` passes today.

| Test | Description |
|------|-------------|
| `_run_stale_setup_conf: FAILS on a stale path in a dist/ script, naming file and line (#845)` | Stale path fails, file:line named |
| `_run_stale_setup_conf: names the replacement path in the failure message (#845)` | Message points at `.setup.conf` |
| `_run_stale_setup_conf: FAILS on a stale path inside a comment too (#845)` | Comments are in scope, not exempt |
| `_run_stale_setup_conf: FAILS on a stale path AFTER an allow-end (region does not leak) (#845)` | Allow region ends at the end marker |
| `_run_stale_setup_conf: FAILS on an unterminated allow-begin region (#845)` | Unbalanced begin marker fails loudly |
| `_run_stale_setup_conf: FAILS on an allow-end with no matching allow-begin (#845)` | Unmatched end marker fails loudly |
| `_run_stale_setup_conf: EXEMPTS a stale path inside an allow-begin/allow-end region (#845)` | Marked migration block exempt |
| `_run_stale_setup_conf: PASSES a dist/ tree that uses the repo-root dotfile (#845)` | `.setup.conf` tree clean |
| `_run_stale_setup_conf: ignores non-.sh files under dist/ (#845)` | Docs out of the lint's scope |
| `_run_stale_setup_conf: FAILS when the dist/ scan root is missing (no vacuous pass) (#845)` | Missing scan root fails, no vacuous pass |
| `_run_stale_setup_conf: the REAL dist/ passes today (migration block allowlisted) (#845)` | Live tree clean |

### test/bats/unit/stop_sh_spec.bats (31)

Unit tests for `stop.sh` argument parsing, the single-project teardown, and
i18n. `docker ps -a` output is PATH-shimmed via `${DOCKER_PS_A_FILE}` so
tests can seed the project container list for the verbose listing.

Covers: `--help` (en/zh/zh-CN/ja), `--lang` value validation, teardown via
`docker compose down` (base is single-instance, #600), fallback
`_detect_lang` branches, **`-C` / `--chdir` flag** (docker_harness#53:
redirect FILE_PATH so .env / project name come from the alt repo, short +
long form, value-required and directory guards, usage help mention), and
**`-v` / `--verbose` / `-vv` / `--very-verbose` flag** (#311: parity across
wrappers; flag is a no-op for `docker compose down` but `-vv` still enables
wrapper trace; the verbose path lists the project containers before tearing
them down), and **`--prune` flag** (#319: opt-in lightweight cleanup after
compose down — `docker network prune --filter until=10m` + `docker image
prune --filter until=24h`; usage help mentions `--prune` with the two grace
windows; the plain `stop.sh --dry-run` path emits no `docker prune`
commands), and **#690 pre-stop hook abort** (a failing
`script/hooks/pre/stop.sh` aborts with the hook's rc before `compose down`
runs).

| Test | Description |
|------|-------------|
| `stop.sh --help exits 0 and shows usage` | - |
| `stop.sh --lang zh-TW prints Chinese usage text` | - |
| `stop.sh --lang zh-CN prints Simplified Chinese usage text` | - |
| `stop.sh --lang ja prints Japanese usage text` | - |
| `stop.sh --lang requires a value` | - |
| `stop.sh stops the single project via docker compose down` | - |
| `stop.sh passes --remove-orphans to compose down (#341)` | - |
| `stop.sh -v lists project containers before down (#345)` | - |
| `stop.sh -v with no matching containers prints empty-project hint (#345)` | - |
| `stop.sh without -v does NOT emit the verbose container listing (#345 default)` | - |
| `stop.sh: an ambient VERBOSE does not reach the flag's behaviour (#895)` | - |
| `stop.sh in /lint/ layout maps zh_TW.UTF-8 to zh-TW` | - |
| `stop.sh in /lint/ layout maps zh_CN.UTF-8 to zh-CN` | - |
| `stop.sh in /lint/ layout maps ja_JP.UTF-8 to ja` | - |
| `stop.sh -C <dir> redirects FILE_PATH to <dir>` | - |
| `stop.sh --chdir <dir> long form is equivalent to -C` | - |
| `stop.sh -C without a value exits 2` | - |
| `stop.sh -C with a non-existent directory exits 2` | - |
| `stop.sh -C is mentioned in usage help` | - |
| `stop.sh -v / --verbose / -vv / --very-verbose are mentioned in usage help (#311)` | - |
| `stop.sh -v --dry-run is accepted and exits 0 (#311)` | - |
| `stop.sh --verbose long form is accepted (#311)` | - |
| `stop.sh -vv --dry-run enables bash trace (set -x output on stderr) (#311)` | - |
| `stop.sh --prune is mentioned in usage help (#319)` | - |
| `stop.sh --prune --dry-run prints down + network prune + image prune (#319)` | - |
| `stop.sh without --prune does NOT emit prune commands (#319)` | - |
| `stop.sh --prune --dry-run runs prune after compose down (#319)` | - |
| `stop.sh aborts on a failing pre-stop hook and skips compose down (#690)` | - |
| `stop.sh ends the project when a self-managed checkout has no .env.generated (#1015)` | the defect in its smallest form: the wrapper died on a missing file before it reached compose at all. The checkout is self-managed, which is the shape in which that file's absence is normal rather than a question. |
| `stop.sh refuses a derived name when a configured checkout lost its cache (#1015)` | the other half of that shape, and the destructive one. A CONFIGURED checkout records its project name in the cache; with the cache gone and no name handed in, the derived `local-<basename>` is a name this checkout never ran under and, on a shared host, one another checkout may be running under right now -- so `down --remove-orphans` against it reports success having ended the wrong thing, or nothing. |
| `stop.sh honours an ambient PROJECT_NAME with no .env.generated to read (#1015)` | the seam `just test stop` uses -- the caller that already knows the name hands it over, so no second derivation exists to drift. |

### test/bats/unit/template_guard_spec.bats (2)

Unit coverage for `lib/template_guard.sh` (`_assert_not_template_source`) --
the init/upgrade self-run guard (ADR-00000011 sec.8). A vendored `.base/`
subtree never carries `.git`; the base checkout/worktree does, so `.git` at
the resolved subtree root means "this is the base template source itself".

| Test | Description |
|------|-------------|
| `_assert_not_template_source: refuses when the subtree root carries .git (base self)` | `.git` present -> non-zero + actionable error |
| `_assert_not_template_source: passes when the subtree root has no .git (vendored subtree)` | real subtree -> no-op passthrough |

### test/bats/unit/template_new_spec.bats (9)

Unit tests for the repo-local command-group scaffolder
`dist/script/template/new.sh` (#633, closes #594). Runs `new.sh` directly
(no `just` needed): it creates `script/local/<name>/justfile.<name>` +
`<name>.sh` from `skel/` and registers the group in
`script/local/justfile.local`.

| Test | Description |
|------|-------------|
| `new.sh scaffolds script/local/<name>/{justfile.<name>,<name>.sh} from skel` | files created + executable |
| `new.sh substitutes __NAME__ in the scaffolded files` | placeholder replaced |
| `new.sh registers the group in script/local/justfile.local (mod? line)` | registry append |
| `new.sh refuses to clobber an existing group` | safe no-overwrite |
| `new.sh does not duplicate the registry line on a second distinct group` | one mod? per group |
| `new.sh rejects an invalid group name` | name validation |
| `new.sh errors with usage when no name given` | arg guard |
| `new.sh registers a real mod? line even when the seed registry only COMMENTS that name (#785)` | - |
| `new.sh source ships with the executable bit set (recipe invokes it directly) (#785)` | - |

### test/bats/unit/template_spec.bats (170)

| Test | Description |
|------|-------------|
| `build.sh exists and is executable` | File check |
| `run.sh exists and is executable` | File check |
| `exec.sh exists and is executable` | File check |
| `stop.sh exists and is executable` | File check |
| `setup.sh exists and is executable` | File check |
| `test.sh exists and is executable` | File check |
| `test.sh uses set -euo pipefail` | Shell convention |
| `justfile.test exists (template CI gate)` | File check |
| `Makefile.ci no longer exists (retired for justfile.test)` | File absence (single runner) |
| `justfile.test default recipe runs the suite (bare just test)` | just recipe |
| `justfile.test has lint recipe` | just recipe |
| `justfile.test lint recipe forwards args + runs all linters by default (#650)` | `lint *args` forwards --shellcheck/--hadolint |
| `justfile.test has coverage recipe` | just recipe |
| `justfile.test carries no stale init/upgrade recipes at nonexistent root scripts (#779)` | - |
| `dist smoke test_helper.bash exists under shared/` | Directory structure |
| `dist smoke shared entrypoint spec exists under shared/` | Directory structure |
| `dist smoke script_help.bats exists under devel-test/` | Directory structure |
| `dist smoke display_env.bats exists under devel-test/` | Directory structure |
| `old flat dist/test/smoke/ layout is gone` | Directory structure |
| `test/bats/unit/ directory exists` | Directory structure |
| `doc/readme/ directory exists` | Directory structure |
| `doc/test/ directory exists` | Directory structure |
| `doc/changelog/ directory exists` | Directory structure |
| `lib/wrapper.sh references .base/dist/script/docker/wrapper/setup.sh (#565)` | - |
| `build.sh + run.sh route setup/drift through _wrapper_setup_sync (#565)` | - |
| `build.sh uses set -euo pipefail` | Shell convention |
| `build.sh supports --no-cache flag` | Force rebuild flag |
| `build.sh passes --no-cache to docker compose build when set` | NO_CACHE forwarded |
| `build.sh keeps test-tools image by default (cleanup gated by CLEAN_TOOLS)` | Default keep tools |
| `build.sh supports --clean-tools flag` | Clean tools flag |
| `build.sh removes test-tools image when --clean-tools is set` | CLEAN_TOOLS forwarded |
| `run.sh uses set -euo pipefail` | Shell convention |
| `exec.sh uses set -euo pipefail` | Shell convention |
| `stop.sh uses set -euo pipefail` | Shell convention |
| `lib/compose.sh is the ONLY producer of a project name (#893)` | - |
| `every wrapper loads .env.generated through the shared optional loader (#1015)` | every wrapper loads the interpolation cache optionally, and none carries a bare `_load_env "` -- the shape that made `stop` die in a self-managed checkout. |
| `lib/env.sh defines _load_env helper` | - |
| `lib/compose.sh defines _compute_project_name helper` | - |
| `lib/compose.sh defines _compose wrapper` | - |
| `stop.sh no longer needs orphan cleanup (run.sh devel uses up not run)` | No more orphan |
| `run.sh devel target uses compose up -d (not compose run --name)` | up + exec model |
| `run.sh devel branch uses compose exec to enter shell` | up + exec model |
| `run.sh non-devel TARGET: foreground 'up', CMD-override 'run --rm' (#458/#679)` | One-shot stages: no-CMD up, CMD run --rm |
| `run.sh devel branch does not use 'compose run --name'` | Old pattern gone |
| `run.sh refuses when the default container is already running` | collision |
| `base is single-instance: no --instance flag remains (#600)` | single-instance (no flag) |
| `base is single-instance: no INSTANCE_SUFFIX remains (#600)` | single-instance (no suffix) |
| `build.sh supports --dry-run flag` | --dry-run |
| `run.sh supports --dry-run flag` | --dry-run |
| `exec.sh supports --dry-run flag` | --dry-run |
| `stop.sh supports --dry-run flag` | --dry-run |
| `build.sh -h shows --dry-run in help` | --dry-run help |
| `run.sh -h shows --dry-run in help` | --dry-run help |
| `exec.sh -h shows --dry-run in help` | --dry-run help |
| `stop.sh -h shows --dry-run in help` | --dry-run help |
| `exec.sh checks the service is running before exec (#920)` | precheck asks compose |
| `no wrapper or wrapper library reconstructs a container name from USER_NAME (#920)` | compose owns the derived name |
| `exec.sh precheck error mentions run.sh hint` | friendly hint |
| `exec.sh exits non-zero with friendly hint when container not running` | precheck e2e |
| `exec.sh --dry-run skips precheck and prints compose command` | dry-run e2e |
| `dist/script/docker/lib/i18n.sh exists` | - |
| `Dockerfile.test-tools includes bats-mock` | bats-mock available in test image |
| `Dockerfile.test-tools installs just from the PINNED release (#948)` | - |
| `Dockerfile.test-tools installs the docker compose plugin (docker-cli-compose)` | The fail-closed half of compose_host_identity_spec's runtime `docker compose version` skip |
| `Dockerfile.test-tools COPYs shellcheck + hadolint into the final image` | The fail-closed half of deploy_spec's runtime `command -v shellcheck` skip |
| `Dockerfile.test-tools source-builds kcov in a builder stage (#686)` | kcov compiled from source (not in alpine repos) |
| `Dockerfile.test-tools COPYs the kcov binary into the final image (#686)` | kcov binary present in final image |
| `Dockerfile.test-tools installs kcov's runtime shared libs in the final stage (#686)` | kcov runtime libs (libstdc++/libcurl/libdw/...) present |
| `Dockerfile.test-tools no longer installs make into the final image (single runner: just)` | dead make dependency stays out of final image |
| `Dockerfile.test-tools declares ARG TARGETARCH` | - |
| `Dockerfile.test-tools ARG TARGETARCH has no default value (must not shadow BuildKit auto-inject)` | multi-arch build regression |
| `Dockerfile.test-tools curl release downloads retry on transient failure (#550)` | - |
| `Dockerfile.test-tools branches case for amd64 and arm64` | - |
| `Dockerfile.test-tools fails loud on unsupported TARGETARCH` | - |
| `i18n.sh defines _detect_lang function` | _detect_lang in i18n.sh |
| `build.sh sources lib/bootstrap.sh (which sources _lib.sh)` | bootstrap dispatch, not the comment naming _lib.sh |
| `run.sh sources lib/bootstrap.sh (which sources _lib.sh)` | bootstrap dispatch, not the comment naming _lib.sh |
| `exec.sh sources lib/bootstrap.sh (which sources _lib.sh)` | bootstrap dispatch, not the comment naming _lib.sh |
| `stop.sh sources lib/bootstrap.sh (which sources _lib.sh)` | bootstrap dispatch, not the comment naming _lib.sh |
| `lib/bootstrap.sh sources _lib.sh (the claim the wrappers delegate)` | the _lib.sh claim asserted where it is true |
| `_lib.sh sources i18n.sh (delegates language detection)` | _lib delegates i18n |
| `setup.sh sources i18n.sh` | setup.sh uses shared i18n |
| `build.sh -h works in /lint/ layout (flat dir with _lib.sh + i18n.sh, issue #104)` | - |
| `run.sh -h works in /lint/ layout` | - |
| `exec.sh -h works in /lint/ layout` | - |
| `stop.sh -h works in /lint/ layout` | - |
| `build.sh errors with a clear diagnostic when bootstrap/_lib.sh missing (issue #104, #408)` | - |
| `Dockerfile.example copies lib/ and wrapper/ into /lint/ (#406)` | - |
| `Dockerfile.example copies the runtime helper dir into /usr/local/lib/base/ in devel stage (#971)` | - |
| `nothing in dist/script/docker/runtime/ has a destiny other than the helper dir (#971)` | - |
| `Dockerfile.example commented runtime stage shows the helper-dir COPY example (#971)` | - |
| `runtime/logging.sh header documents in-image source-line (no $USER, no work/.base) (#368)` | - |
| `the seeded bringup template carries no base plumbing and no exec (#945)` | init.sh seeds this file once and the repo owns it from then on -- no subtree pull ever rewrites it. So anything of base's left in it is frozen in every consumer for good, which is the defect the two-file model exists to remove. Asserted over code lines only, because the header deliberately NAMES the helpers and the exec to say they are not its job |
| `Dockerfile.example makes base's orchestrator the container ENTRYPOINT (#945)` | The wiring line of the two-file model (ADR-00000032): ENTRYPOINT names base's orchestrator, the repo's bringup is COPY'd to /entrypoint.sh but never named as ENTRYPOINT. Pointing ENTRYPOINT at the repo's own file is what froze base's plumbing in every consumer, so the retired shape is asserted absent rather than merely not asserted |
| `Dockerfile.example commented runtime stage runs the orchestrator too (#945)` | The runtime stage starts from a fresh BASE_IMAGE and inherits nothing from devel, so the commented scaffold is what a repo uncommenting it adopts. A scaffold still naming /entrypoint.sh teaches the retired one-file model, which is why the old line is asserted absent and not just the new one present |
| `no inline _detect_lang fallbacks remain after dedupe (issue #104)` | - |
| `setup.sh does not redefine _detect_lang` | No duplication |
| `setup.sh defines _setup_msg, not _msg (closes #101)` | - |
| `build.sh _msg keys survive sourcing setup.sh (#101 behavioral)` | - |
| `build.sh does not source setup.sh (#49 Phase B-1)` | structural guard for #101 class |
| `run.sh does not source setup.sh (#49 Phase B-1)` | structural guard for #101 class |
| `lib/wrapper.sh uses subprocess check-drift (#49 Phase B-1, #565)` | - |
| `.version file exists in template root` | Version file check |
| `upgrade.sh reads version from <subtree-prefix>/.version` | - |
| `upgrade.sh does not reference legacy VERSION or .template_version` | Legacy refs purged |
| `upgrade.sh runs init.sh after subtree pull` | Sync symlinks |
| `upgrade.sh supports --gen-conf flag` | Flag exists |
| `upgrade.sh --gen-conf delegates to init.sh --gen-conf` | Delegation |
| `upgrade.sh --help mentions --gen-conf` | Help text |
| `upgrade.sh updates main.yaml @tag without clobbering release-worker.yaml` | sed regression |
| `upgrade.sh main.yaml sed handles semver pre-release tags (RC → RC)` | `-rcN-rcN` regression |
| `upgrade.sh main.yaml sed handles stable → stable + RC → stable transitions` | RC → stable cleanup |
| `build-worker.yaml: no legacy in-job test-tools build step` | v0.9.13 GHCR migration |
| `build-worker.yaml: declares test_tools_version input` | v0.10.1 input replaces GITHUB_WORKFLOW_REF parse |
| `build-worker.yaml: does not resurrect the GITHUB_WORKFLOW_REF parse step` | regression guard |
| `build-worker.yaml: devel-test build passes TEST_TOOLS_IMAGE from inputs` | - |
| `Dockerfile.example has ARG TEST_TOOLS_IMAGE with no bare test-tools:local default` | version-scoped tag: no bare-tag ARG default (#828) |
| `Dockerfile.example FROM ${TEST_TOOLS_IMAGE} AS test-tools-stage` | named stage alias |
| `Dockerfile.example test stage copies from test-tools-stage, not test-tools:local` | stage rename migration |
| `Dockerfile.example runtime-test shows commented Bats COPY from test-tools-stage (#647)` | generalized -test toolchain (style (b) Bats smoke) |
| `Dockerfile.example documents -test stages stay FROM the real stage + heavier-is-fine (#647)` | anti-pattern guard + consumer-owns-flavour-tools |
| `Dockerfile.example states the /opt-not-$HOME baking convention (#799)` | - |
| `no shipped text repeats the claim a build disproves (#951)` | A LABEL does read a digest out of a reference (probed by build); it only cannot BRANCH. Sweeps a DERIVED roster -- the template, tooling, doc, workflow and spec trees, plus every file at the top of the checkout (`init.sh`, `justfile`, `compose.yaml`, `CONTEXT.md`, the READMEs) -- for the categorical claim, and demands the narrow one where the design rests on it |
| `the vocabulary marker guard reads order, not counts (#951)` | An inverted marker pair (`end` above its `begin`) counts 1 == 1 while `_df_flatten` still excises the file tail, so the balance guard reads the markers in order |
| `the top-level walk is read on its own, not off the roster (#951)` | The roster is two walks unioned; asking the roster for a single-component path shows the top-level walk ran only while every sweep root is a directory, so the walk is asked directly and each path it returns must reach the roster |
| `the flattener closes only a block it opened (#951)` | An `end` marker with no `begin` above it closed the vocabulary carve-out and took its own line with it, so prose sharing that line left the sweep; the flattener now closes only what it opened, while a real block is still excised |
| `the claim sweep refuses a pattern it could not read (#951)` | grep's exit 2 -- a pattern it could not evaluate -- shared an `if` branch with exit 1, so a sweep that never ran reported the file clean; `_df_claim_hits` returns that third answer and the caller fails loudly on it |
| `the note gives one [build] arg slot per key (#951)` | Derived from the note's own `arg_N = KEY=` lines: two paragraphs handing one slot to different keys is silent, because a `[build]` section in `.setup.conf.local` replaces the whole section |
| `the apt-layer guard sees the install shapes this template writes (#951)` | Reach and restraint of `_DF_APT_INSTALL_RE`: an option taking a separate argument (`-o Dpkg::Options::=` before the subcommand) is an install layer, while `apt-get clean` chains and `pip install` are not |
| `Dockerfile.example states the moving-BASE_IMAGE reproducibility trade-off (#951)` | read from the note's own comment window above `ARG BASE_IMAGE=`, since every path it names is also spelled in the code that implements it: the moving default, the recorded manifest and the digest escape hatch are stated where a downstream author edits |
| `Dockerfile.example states what the UNPINNED default does not record (#951)` | read from the note's own window: the digest half AC1 asks for is empty in the shipped default, the note says so, and the recipe it gives strips to `sha256:<hex>` so both routes record the same shape |
| `Dockerfile.example sys stage records the base ref it resolved (#951)` | bare in-stage `ARG BASE_IMAGE` re-declaration, `base-image.env` write, digest-pin flag, the digest on both routes it can be known, OCI base-name/base-digest labels |
| `Dockerfile.example rewrites the package manifest after every apt layer (#951)` | a relation over the apt layers, not a tally: every RUN block that installs apt packages (`apt-get install`, `apt install` or `rosdep install`, indented or not, live or commented-for-uncommenting) must refresh `packages.txt` |
| `_df_apt_run_blocks sees a BuildKit heredoc apt layer (#951)` | pins the helper behind that relation against a scratch fixture: `RUN <<EOF` / `<<-'EOF'` carries no backslash continuations, so the block must be closed by its delimiter -- live and commented, order enforced inside it, and `<<<` opening nothing |
| `Dockerfile.example commented runtime-base records its own manifest (#951)` | read from that stage's own window, since the same commented lines appear in devel's and builder's blocks: the optional fresh-`${BASE_IMAGE}` stage stays correct when uncommented |
| `.hadolint.yaml DL3008 ignore names its compensating control (#951)` | read from DL3008's own rationale block, and it must name the downstream repos the symlinked config reaches whose Dockerfile predates the manifest |
| `the shipped smoke spec demands the manifest's VALUE and fails closed on half of one (#951)` | the shipped spec asserts a non-empty `base_image_ref` and a `sha256:<hex>`-shaped digest, and its skip fires only when NEITHER manifest file exists |
| `build-worker.yaml: runtime-test build forwards TEST_TOOLS_IMAGE (#647 prerequisite)` | runtime-test COPY --from=test-tools-stage needs the pinned image too |
| `Dockerfile.example runtime-test uses bash -c wrapper (regression: #243 word-split + #57 dash-source bugs)` | - |
| `Dockerfile.example runtime-test does NOT use bare RUN ${RUNTIME_SMOKE_CMD} (v0.21.0 word-split regression guard)` | - |
| `Dockerfile.example runtime-test does NOT use sh -c wrapper (v0.21.1 -> v0.23.1 dash-source regression guard)` | - |
| `Dockerfile.example runtime-test does NOT set USER root (DL3002 regression guard)` | - |
| `Dockerfile.example top stage-list documents builder stage (#239)` | - |
| `Dockerfile.example documents 3 builder/runtime split lessons (#239)` | - |
| `Dockerfile.example has commented-out builder + runtime + COPY --from=builder reference (#239)` | - |
| `Dockerfile.example runtime documents 3-process-kinds env rationale (#657)` | PID 1 / interactive / non-interactive complementary mechanisms |
| `Dockerfile.example runtime shows commented /etc/bash.bashrc source example (#657)` | opt-in interactive-exec env source, consumer supplies ROS line |
| `Dockerfile.example runtime does NOT bake ROS env into ENV (#657 fragility guard)` | no ENV LD_LIBRARY_PATH / PYTHONPATH baked |
| `template no longer ships dockerfile/setup/ (#407, reverses #261)` | - |
| `template no longer ships config/pip/ (#261 relocation regression guard)` | - |
| `Dockerfile.example has no SETUP_DIR or pip references (#407)` | - |
| `Dockerfile.example declares ENV TZ (matches downstream fleet, #210)` | runtime $TZ alignment |
| `Dockerfile.example declares ENV LANGUAGE=en_US:en (matches downstream fleet, #210)` | runtime $LANGUAGE alignment |
| `release-test-tools.yaml exists and pushes to ghcr.io/ycpss91255-docker/test-tools` | GHCR publisher |
| `release-test-tools.yaml declares packages:write permission` | ghcr auth scope |
| `release-test-tools.yaml builds multi-arch (amd64 + arm64)` | arch coverage |
| `release-test-tools.yaml uses template-repo-local Dockerfile path` | no subtree path confusion |
| `release archive payload declares no derived per-host artifact` | no compose.yaml / .setup.conf in the manifest |
| `release archive payload still declares Dockerfile + script/ + .base/` | positive payload guard (no over-prune) |
| `release archive payload guard is not satisfied by another entry's description` | The `.base/` guard reads the paths column, not a neighbour's prose |
| `run.sh contains XDG_SESSION_TYPE check` | X11/Wayland branch |
| `run.sh contains xhost +SI:localuser for wayland` | Wayland xhost |
| `run.sh contains xhost +local: for X11` | X11 xhost |
| `setup.sh default _base_path uses /..` | Path resolution |
| `setup.sh default _base_path uses double parent traversal` | Repo root traversal |
| `all 7 wrappers call _run_pre_hook with their own name (#440)` | - |
| `all 7 wrappers call _run_post_hook with their own name (#440)` | - |
| `run.sh _app_cleanup runs post-hook before compose down (#440)` | - |
| `lib/hook.sh skips both helpers under DRY_RUN (#440, #13)` | - |
| `lib/hook.sh hard-fails on present-but-not-executable hook (#440, #11)` | - |

### test/bats/unit/terminator_config_spec.bats (10)

| Test | Description |
|------|-------------|
| `has [global_config] section` | Config section |
| `has [keybindings] section` | Config section |
| `has [profiles] section` | Config section |
| `has [layouts] section` | Config section |
| `has [plugins] section` | Config section |
| `profiles has [[default]]` | Default profile |
| `default profile disables system font` | Font setting |
| `default profile has infinite scrollback` | Scrollback setting |
| `layouts has Window type` | Window layout |
| `layouts has Terminal type` | Terminal layout |

### test/bats/unit/terminator_setup_spec.bats (8)

| Test | Description |
|------|-------------|
| `check_deps returns 0 when terminator is installed` | Dependency check |
| `check_deps fails when terminator is not installed` | Missing dep |
| `_entry_point calls main when deps pass` | Entry point |
| `_entry_point fails when deps missing` | Entry point fail |
| `main creates terminator config directory` | Config dir |
| `main copies terminator config file` | Config copy |
| `main calls chown with correct user and group` | Permissions |
| `script runs entry_point when executed directly` | Direct-run guard |

### test/bats/unit/tmux_conf_spec.bats (12)

| Test | Description |
|------|-------------|
| `defines prefix key` | tmux prefix |
| `sets default shell to bash` | Shell setting |
| `sets default terminal` | Terminal setting |
| `enables mouse support` | Mouse |
| `enables vi status-keys` | vi mode |
| `enables vi mode-keys` | vi mode |
| `defines split-window bindings` | Split bindings |
| `defines reload config binding` | Reload binding |
| `enables status bar` | Status bar |
| `sets status bar position` | Status bar position |
| `declares tpm plugin` | tpm plugin |
| `initializes tpm at end of file` | tpm init |

### test/bats/unit/tmux_setup_spec.bats (9)

| Test | Description |
|------|-------------|
| `check_deps returns 0 when tmux and git are installed` | Dependency check |
| `check_deps fails when tmux is not installed` | Missing tmux |
| `check_deps fails when git is not installed` | Missing git |
| `_entry_point calls main when deps pass` | Entry point |
| `_entry_point fails when deps missing` | Entry point fail |
| `main clones tpm repository` | tpm clone |
| `main creates tmux config directory` | Config dir |
| `main copies tmux.conf to config directory` | Config copy |
| `script runs entry_point when executed directly` | Direct-run guard |

### test/bats/unit/tool_pin_agreement_spec.bats (10)

| Test | Description |
|------|-------------|
| `tool pins: the shipped shellcheck is the version the Dockerfile pins` | Exit 0 says a binary exists; this says it is the one the pin asked for |
| `tool pins: the shipped hadolint is the version the Dockerfile pins` | The drift that let a 2022 rule set stay behind a green gate, now asserted every run |
| `tool pins reader: a Dockerfile with no pinned URL FAILS rather than returning nothing` | A reader returning nothing would reduce both checks to empty-vs-empty agreement |
| `tool pins reader: a version is matched whole, not as a prefix of a longer one` | 0.11.0 must not be satisfied by 0.11.01 or by 10.11.0 |
| `tool pins reader: the dots in a version are literal, not any-character` | An unescaped regex dot would let 0x11x0 pass as 0.11.0 |
| `tool pins: the alpine this image runs on is the series the Dockerfile pins` | The base every stage is built on, compared with the image the suite is actually running in |
| `tool pins: the bash this image ships is the series the pin's table records` | The bash-per-series table the series was chosen on, asserted rather than left as a comment |
| `tool pins reader: a series the table does not cover FAILS rather than returning nothing` | A pin the table has no row for is a choice nothing supports |
| `tool pins reader: a table row is matched whole, not as a prefix of a longer series` | A row for 3.2 must not answer for 3.22, nor one for 13.22 |
| `tool pins reader: an ALPINE_VERSION declared twice FAILS rather than picking one` | With two pins there is no single series for the image to agree with |

### test/bats/unit/transcript_lnav_spec.bats (8)

Regex-type lnav format for the plain-text wrapper transcript
(`transcript.lnav-format.json`, #609): parses `<ISO ts> [service] LEVEL:
msg` lines, coexisting with the JSON `log.lnav-format.json` (`*.jsonl`). The
CI image has no jq/lnav, so it is checked structurally (grep) + functionally
(the embedded regex, extracted and JSON-unescaped, must match real
transcript lines and the 5 levels via `grep -P`).

Grouped by concern:

- Declares the lnav schema + format key; is a regex format (not json)

- Maps all 5 levels; timestamp/level/body fields + `log/` file-pattern wired

- Regex matches real transcript lines incl. all 5 levels; raw docker line
does NOT match

- Every declared sample matches the pattern

- `log.lnav-format.json` (JSON) still coexists unchanged

| Test | Description |
|------|-------------|
| `transcript.lnav-format.json: declares the lnav format schema + format key (#609)` | - |
| `transcript.lnav-format.json: is a regex format (not json) (#609)` | - |
| `transcript.lnav-format.json: maps all 5 levels (#609)` | - |
| `transcript.lnav-format.json: timestamp/level/body fields + log/ file-pattern wired (#609)` | - |
| `transcript.lnav-format.json: regex matches real transcript lines, all 5 levels (#609)` | - |
| `transcript.lnav-format.json: a raw docker output line does NOT match (falls through as body) (#609)` | - |
| `transcript.lnav-format.json: every declared sample line matches the pattern (#609)` | - |
| `log.lnav-format.json (JSON) still coexists unchanged (#609)` | - |

### test/bats/unit/transcript_spec.bats (34)

Wrapper transcript capture (#606) + interactive orchestration capture
(#608): tees a verb's combined output to `log/<verb>/<ts>-<traceid8>.log`
(ANSI stripped) with a per-verb `latest.log` symlink, an exit-code+duration
closing line, retention, and an `_atexit` registry that owns the single EXIT
trap. Interactive verbs (run / exec / setup_tui) capture the orchestration
phase then `_transcript_detach` before the session. Pure helpers are
unit-tested; the tee + EXIT-finalize + detach are exercised end-to-end by
running a tiny harness in a subshell. Activation is execution-only
(`_transcript_begin` in each verb's `main()`), never at source time.

Grouped by concern:

- `_transcript_is_full_verb`: 5 captured verbs / interactive + unknown not

- `_transcript_is_interactive_verb` + `_transcript_is_capture_verb`
classification (#608)

- `_transcript_filename` path shape; `_transcript_meta_line` lnav-parseable
format

- `_transcript_resolve_traceid`: inherits TRACEPARENT trace_id / generates
32-hex

- `_transcript_enabled`: default true / `wrapper_transcript=false` kill
switch; `WRAPPER_TRANSCRIPT` env override wins over conf both ways (#622)

- `_atexit`: registered callbacks run LIFO on exit

- `_transcript_prune`: keep-N-most-recent + drop-older-than-D-days

- `_transcript_prune` keep=0 wipes all + read-side guard rejects hand-edited
`wrapper_transcript_keep=0` (falls back to 20) (#691)

- Degrade-to-no-op failure branches (#691): mkdir-fail / raw-file-unwritable
/ tee-missing each WARN + return 0, wrapper continues

- Non-zero wrapper exit recorded (`transcript_complete exit_code=7`) AND
propagated to caller (#691)

- End-to-end: file produced with combined content; ANSI stripped in file
(colour on terminal); exit-code+duration line; `latest.log` symlink;
`wrapper_transcript=false` no-op

- `_transcript_detach` (#608): no-detach full-captures (run -d path); detach
captures orchestration only (`transcript_detached`, not the session); no-op
when never begun

- Wiring guards: 5 full verbs call `_transcript_begin`; run/exec/setup_tui
call begin + detach

| Test | Description |
|------|-------------|
| `_transcript_is_full_verb: the 5 non-interactive verbs are captured (#606)` | - |
| `_transcript_is_full_verb: interactive verbs + unknown are NOT captured (#606)` | - |
| `_transcript_is_interactive_verb: run/exec/setup_tui yes; full verbs + unknown no (#608)` | - |
| `_transcript_is_capture_verb: every full + interactive verb captures; unknown does not (#608)` | - |
| `_transcript_filename: <root>/log/<verb>/<ts>-<traceid8>.log (#606)` | - |
| `_transcript_meta_line: formats an lnav-parseable level line (#606)` | - |
| `_transcript_resolve_traceid: inherits a well-formed TRACEPARENT trace_id (#606)` | - |
| `_transcript_resolve_traceid: generates a 32-hex id when TRACEPARENT absent (#606)` | - |
| `_transcript_enabled: true by default when no setup.conf (#606)` | - |
| `_transcript_enabled: false when wrapper_transcript = false (#606)` | - |
| `_transcript_enabled: WRAPPER_TRANSCRIPT=false env wins over conf=true (#622)` | - |
| `_transcript_enabled: WRAPPER_TRANSCRIPT=true env wins over conf=false (#622)` | - |
| `_transcript_enabled: a non-boolean WRAPPER_TRANSCRIPT is refused, not ignored (#895)` | - |
| `_transcript_enabled: an empty WRAPPER_TRANSCRIPT means unset, not invalid (#895)` | - |
| `_atexit: registered callbacks run LIFO on exit (#606)` | - |
| `_transcript_prune: keeps the N most recent, drops the rest (#606)` | - |
| `_transcript_prune: keep=0 would delete every transcript (#691)` | - |
| `_transcript_begin: hand-edited wrapper_transcript_keep=0 is rejected, falls back to 20 (#691)` | - |
| `_transcript_prune: drops files older than <days> regardless of count (#606)` | - |
| `transcript: a full verb produces log/<verb>/<ts>-<id>.log with content (#606)` | - |
| `transcript: the file is ANSI-stripped while the terminal keeps colour (#606)` | - |
| `transcript: closing line carries the exit code + duration (#606)` | - |
| `transcript: a non-zero wrapper exit is recorded AND propagated (#691)` | - |
| `_atexit_set_exit_code: a callback's rc wins WITHOUT skipping finalize (#956)` | - |
| `transcript: latest.log symlink points at the run's file (#606)` | - |
| `transcript: wrapper_transcript=false is a complete no-op (no file) (#606)` | - |
| `_transcript_begin: mkdir-fail degrades to no-op + WARN, wrapper continues (#691)` | - |
| `_transcript_begin: file-unwritable degrades to no-op + WARN (#691)` | - |
| `_transcript_begin: tee-missing degrades to no-op + WARN (#691)` | - |
| `transcript: an interactive verb without detach full-captures (the run -d path) (#608)` | - |
| `transcript: _transcript_detach captures orchestration only, not the interactive session (#608)` | - |
| `transcript: _transcript_detach is a no-op when the transcript never began (#608)` | - |
| `wiring: the 5 full verbs call _transcript_begin (#606)` | - |
| `wiring: run/exec/setup_tui call both _transcript_begin and _transcript_detach (#608)` | - |

### test/bats/unit/tui_backend_spec.bats (31)

Backend detection and wrapper-level arg forwarding. Uses a stub `dialog` /
`whiptail` binary installed on PATH that logs argv and echoes a canned
response; exercised with `TUI_STUB_RESPONSE` / `TUI_STUB_EXIT`.

Grouped by concern:

- `_backend_detect` (prefers dialog, falls back to whiptail, prints install
hint when neither)

- `_tui_guard` (rejects empty backend)

- `_tui_inputbox` (forwards title/prompt/initial, returns canned response,
propagates non-zero on cancel)

- `_tui_menu` (computes item count, forwards tag/label pairs;
`TUI_EXTRA_LABEL` no-op after #178; `--no-tags`, `--ok-label`)

- `_tui_radiolist` (forwards tag/label/state triples)

- `_tui_checklist` (passes `--separate-output`)

- `_tui_msgbox` / `_tui_yesno` (correct flags, propagates exit code)

- whiptail flag-spelling translation (#136: `--ok-button` /
`--cancel-button` instead of `--*-label`, no `--extra-button`) + Save-button
unification (#178: dialog also drops `--extra-button`)

| Test | Description |
|------|-------------|
| `_backend_detect picks dialog when present` | - |
| `_backend_detect falls back to whiptail when dialog absent` | - |
| `_backend_detect prints install hint and exits 2 when neither present` | - |
| `_tui_guard fails when backend not initialized` | - |
| `_tui_inputbox passes title, prompt, initial to backend and echoes response` | - |
| `_tui_inputbox non-zero when backend exits non-zero (cancel)` | - |
| `_tui_menu computes item count and passes tag/label pairs` | - |
| `_tui_menu never emits --extra-button on dialog even when TUI_EXTRA_LABEL is set (#178)` | - |
| `_tui_menu still omits --extra-button when TUI_EXTRA_LABEL is unset` | - |
| `_tui_menu forwards --no-tags when _TUI_NO_TAGS is set` | - |
| `_tui_menu omits --no-tags when _TUI_NO_TAGS unset` | - |
| `_tui_menu forwards --ok-label when _TUI_OK_LABEL set` | - |
| `_tui_menu forwards --cancel-label when _TUI_CANCEL_LABEL set` | - |
| `_tui_select marks current tag with '*' and dispatches via --menu` | - |
| `_tui_select passes --default-item with the current ON tag` | - |
| `_tui_run forwards --ok-label / --cancel-label from env vars` | - |
| `_tui_select with no ON item still forwards tags` | - |
| `_tui_menu omits ok-label / cancel-label when env vars unset` | - |
| `_tui_radiolist forwards tag/label/state triples` | - |
| `_tui_checklist uses --separate-output` | - |
| `_tui_msgbox invokes backend with --msgbox` | - |
| `_tui_yesno passes --yesno and returns backend exit code` | - |
| `_tui_run forwards --ok-button / --cancel-button spelling on whiptail` | - |
| `_tui_run keeps --ok-label / --cancel-label spelling on dialog` | - |
| `_tui_msgbox does not leak --ok-label / --cancel-label onto whiptail` | - |
| `_tui_inputbox uses --ok-button / --cancel-button on whiptail` | - |
| `_tui_menu uses --ok-button / --cancel-button on whiptail` | - |
| `_tui_backend: an ambient TUI_WIDTH / TUI_HEIGHT does not reach the backend (#895)` | - |
| `_tui_backend: an ambient TUI_NO_TAGS does not reach the backend (#895)` | - |
| `_tui_backend: an ambient TUI_OK_LABEL / TUI_CANCEL_LABEL does not reach the backend (#895)` | - |
| `_tui_menu omits --extra-button / --extra-label on whiptail even when TUI_EXTRA_LABEL is set` | - |

### test/bats/unit/tui_flow_spec.bats (106)

Interactive-flow tests for `setup_tui.sh` (#189). Sources `setup_tui.sh`
directly and overrides `_tui_menu` / `_tui_select` / `_tui_inputbox` /
`_tui_yesno` / `_tui_msgbox` / `_tui_radiolist` / `_tui_checklist` with
file-backed stubs (queue lines popped via `head -n 1` + `sed -i 1d` so state
survives the `$(...)` subshell calls). Each case scripts the user's click
path, calls one section editor, and asserts on the resulting `_TUI_OVR_*` /
`_TUI_REMOVED` / `_TUI_CURRENT` arrays — no real `dialog` / `whiptail` ever
launches. Lifts `setup_tui.sh` per-file coverage from 18% to 83% by
exercising the 5 high-value target areas the issue body called out.

Grouped by concern:

- `_load_current` (repo-conf wins; falls back to template; both missing →
silent return 0)

- `_render_main_menu` / `_render_advanced_menu` (#178 Save & Exit
unification, Cancel/Esc returns 1, navigation into section editor)

- `_edit_image_rule` (#177 site: add string/prefix/suffix/basename/default,
Cancel from radiolist or inputbox, `__remove`/`__move_up`/`__move_down`,
dedupe drops duplicate slot)

- `_compact_image_rules_after_remove` (mid-list shift down, last drop, empty
no-op, sparse-slot collapse)

- `_swap_image_rule` (both occupied / target empty / source empty / both
empty / m<1)

- `_edit_list_section` via `_edit_section_environment` (env_
add/edit/remove, invalid → msgbox+retry, max+1 indexing, Cancel/Esc)

- `_edit_section_image` top-level dispatch (add max+1, click rule_N, Back)

- `_edit_section_network` (host+host+pid no shm prompt, bridge prompts
name+ports, ipc=private prompts shm, empty network_name allowed)

- `_edit_section_deploy` (off short-circuits — only writes gpu_mode)

- Multi-section dispatch from main menu (network → host → save)

- Per-stage UI #220 (`_list_dockerfile_stages_available` from-Dockerfile +
baseline filter, `_count_stage_overrides` OVR+CURRENT dedup + empty skip,
`_edit_stage_gui` mode + __inherit, `_edit_stage_scalar` write +
empty-clears, `_edit_stage_list` inherit toggle + add)

- Menu restructure #221 (i18n keys for main.runtime/mounts/features × 4
langs; `_render_runtime_menu` / `_render_mounts_menu` /
`_render_features_menu` function existence; main-menu dispatch for
image/build/runtime/mounts/features + bare
network/deploy/gui/volumes/environment no longer dispatch from main; Runtime
sub-menu dispatch for network/deploy/gui/environment + __back/Cancel; Mounts
sub-menu dispatch for volumes/devices/tmpfs + __back/Cancel; Features
sub-menu __back, per_stage enabled enters editor, per_stage hidden shows
msgbox without entering editor; Advanced sub-menu image/build/devices/tmpfs
entries removed, security still dispatches)

- #328 logging menu dispatch (Runtime menu's `logging` entry calls
`_edit_section_logging`; `_edit_section_logging`'s top-level menu routes
`global` to `_edit_logging_keys logging` and `devel` / `test` / `runtime` to
`_edit_logging_keys logging.<svc>`)

- #561 `_tui_known_subcommand` derives CLI direct-jump subcommands from
`SCHEMA_SECTIONS` (accepts every section + `ports` pseudo-section, rejects
unknown args, tracks `SCHEMA_SECTIONS` additions)

| Test | Description |
|------|-------------|
| `_load_current: pulls keys from repo conf when present` | - |
| `_load_current: falls back to template conf when repo conf missing` | - |
| `_load_current: returns 0 silently when both files missing` | - |
| `_render_main_menu: __save returns 0 (Save & Exit path)` | - |
| `_render_main_menu: empty choice (Cancel) returns 1` | - |
| `_render_main_menu: non-zero rc (Esc) returns 1` | - |
| `_render_main_menu: navigates into _edit_section_<choice> then Save` | - |
| `_render_advanced_menu: __back exits the loop` | - |
| `_render_advanced_menu: Cancel (rc!=0) exits via break` | - |
| `_tui_known_subcommand accepts every SCHEMA_SECTIONS member (#561)` | - |
| `_tui_known_subcommand accepts the ports pseudo-section (#561)` | - |
| `_tui_known_subcommand rejects an unknown argument (#561)` | - |
| `_tui_known_subcommand derives from SCHEMA_SECTIONS (single source) (#561)` | - |
| `_edit_image_rule: add string rule writes prefix-free value` | - |
| `_edit_image_rule: add prefix rule prefixes the value` | - |
| `_edit_image_rule: add suffix rule prefixes the value` | - |
| `_edit_image_rule: add basename rule writes @basename and skips inputbox` | - |
| `_edit_image_rule: add default rule rewrites @default:<value>` | - |
| `_edit_image_rule: Cancel from radiolist returns without writing` | - |
| `_edit_image_rule: Cancel from inputbox returns without writing` | - |
| `_edit_image_rule: __remove triggers compaction (single rule → empty)` | - |
| `_edit_image_rule: __move_up at n=2 swaps with n=1` | - |
| `_edit_image_rule: __move_down at n=1 swaps with n=2` | - |
| `_edit_image_rule: dedupe — adding existing value drops the duplicate slot` | - |
| `_compact_image_rules_after_remove: shifts higher rules down by one slot` | - |
| `_compact_image_rules_after_remove: removing last rule just drops it` | - |
| `_compact_image_rules_after_remove: empty list is a no-op` | - |
| `_compact_image_rules_after_remove: collapses sparse slots above target` | - |
| `_swap_image_rule: both occupied — swaps values` | - |
| `_swap_image_rule: m < 1 is a silent no-op` | - |
| `_swap_image_rule: target empty — moves source into empty slot` | - |
| `_swap_image_rule: source empty — moves target into source slot` | - |
| `_swap_image_rule: both empty is a no-op` | - |
| `_edit_list_section env_: add then back writes env_1` | - |
| `_edit_list_section env_: invalid value shows msgbox + retries` | - |
| `_edit_list_section env_: empty input on existing entry marks removed` | - |
| `_edit_list_section env_: add → next free index is max+1` | - |
| `_edit_list_section env_: empty choice (Cancel) returns 0 immediately` | - |
| `_edit_list_section env_: rc!=0 (Esc) returns 0 immediately` | - |
| `_edit_list_section env_: edits existing entry replacing value` | - |
| `_edit_section_additional_contexts: add then back writes context_1` | - |
| `_edit_section_additional_contexts: invalid name shows msgbox + retries` | - |
| `_edit_section_additional_contexts: add → next free index is max+1` | - |
| `_edit_section_additional_contexts: empty input on existing entry marks removed` | - |
| `_edit_section_additional_contexts: edits existing entry replacing value` | - |
| `_edit_section_additional_contexts: empty choice (Cancel) returns 0 immediately` | - |
| `_edit_section_additional_contexts: rc!=0 (Esc) returns 0 immediately` | - |
| `_edit_section_additional_contexts: docker-image:// schemes accepted` | - |
| `_edit_list_entry validates via the schema registry, no validator arg (#560)` | - |
| `_render_advanced_menu: additional_contexts choice dispatches to its editor` | - |
| `_edit_section_image: add path appends rule at max+1` | - |
| `_edit_section_image: rule_1 click drills into _edit_image_rule` | - |
| `_edit_section_image: back returns immediately` | - |
| `_edit_section_network: host + host + private writes all modes, no shm prompt` | - |
| `_edit_section_network: bridge + host prompts for network_name + ports menu` | - |
| `_edit_section_network: ipc=private prompts for shm_size` | - |
| `_edit_section_network: empty network_name allowed (compose default bridge)` | - |
| `_edit_section_deploy: off short-circuits — only writes gpu_mode` | - |
| `_list_dockerfile_stages_available: returns non-baseline stages in file order` | - |
| `_list_dockerfile_stages_available: empty when only baseline stages` | - |
| `_list_dockerfile_stages_available: includes devel-test as an editable stage (#493)` | - |
| `_list_dockerfile_stages_available: offers a --platform flagged stage (#875)` | - |
| `_count_stage_overrides: counts unique non-empty keys across OVR + CURRENT` | - |
| `_count_stage_overrides: skips empty values` | - |
| `_edit_stage_gui: explicit mode write` | - |
| `_edit_stage_gui: __inherit clears any existing override` | - |
| `_edit_stage_scalar: writes the dotted key under stage namespace` | - |
| `_edit_stage_scalar: empty input clears (inherit)` | - |
| `_edit_stage_list: __inherit toggle flips false then back to true (clears flag)` | - |
| `_edit_stage_list: add appends a list entry under the stage namespace` | - |
| `i18n: main.runtime key exists across all 4 languages` | - |
| `i18n: main.mounts key exists across all 4 languages` | - |
| `i18n: main.features key exists across all 4 languages` | - |
| `_render_runtime_menu function is defined` | - |
| `_render_mounts_menu function is defined` | - |
| `_render_features_menu function is defined` | - |
| `_render_main_menu: image choice dispatches to _edit_section_image` | - |
| `_render_main_menu: build choice dispatches to _edit_section_build` | - |
| `_render_main_menu: runtime choice dispatches to _render_runtime_menu` | - |
| `_render_main_menu: mounts choice dispatches to _render_mounts_menu` | - |
| `_render_main_menu: features choice dispatches to _render_features_menu` | - |
| `_render_main_menu: bare network/deploy/gui/volumes/environment no longer dispatch from main` | - |
| `_render_runtime_menu: __back exits with 0` | - |
| `_render_runtime_menu: Cancel (rc!=0) exits via break` | - |
| `_render_runtime_menu: network choice dispatches to _edit_section_network` | - |
| `_render_runtime_menu: deploy choice dispatches to _edit_section_deploy` | - |
| `_render_runtime_menu: gui choice dispatches to _edit_section_gui` | - |
| `_render_runtime_menu: environment choice dispatches to _edit_section_environment` | - |
| `_render_runtime_menu: logging choice dispatches to _edit_section_logging (#328)` | - |
| `_edit_section_logging: global choice dispatches to _edit_logging_keys logging (#328)` | - |
| `_edit_section_logging: devel choice dispatches to _edit_logging_keys logging.devel (#328)` | - |
| `_edit_section_logging: test choice dispatches to _edit_logging_keys logging.test (#328)` | - |
| `_edit_section_logging: runtime choice dispatches to _edit_logging_keys logging.runtime (#328)` | - |
| `_render_mounts_menu: __back exits with 0` | - |
| `_render_mounts_menu: Cancel (rc!=0) exits via break` | - |
| `_render_mounts_menu: volumes choice dispatches to _edit_section_volumes` | - |
| `_render_mounts_menu: devices choice dispatches to _edit_section_devices` | - |
| `_render_mounts_menu: tmpfs choice dispatches to _edit_section_tmpfs` | - |
| `_render_features_menu: __back exits with 0` | - |
| `_render_features_menu: per_stage entry enters editor when stages exist` | - |
| `_render_features_menu: per_stage entry shows info msgbox + does NOT enter editor when no stages` | - |
| `_render_advanced_menu: image entry no longer dispatches` | - |
| `_render_advanced_menu: build entry no longer dispatches` | - |
| `_render_advanced_menu: devices entry no longer dispatches` | - |
| `_render_advanced_menu: tmpfs entry no longer dispatches` | - |
| `_render_advanced_menu: security still dispatches` | - |

### test/bats/unit/tui_mount_assembler_spec.bats (9)

Unit tests for the TUI mount-string assembler (`_assemble_mount_value` /
`_prompt_mount_with_picker`, #461): host:container[:mode] composition,
combined access/propagation modes, `_validate_mount` round-trip, and
space-bearing path rejection (#687).

| Test | Description |
|------|-------------|
| `_assemble_mount_value returns host:container when no mode (#461)` | Bare two-field mount |
| `_assemble_mount_value returns host:container:mode for single mode (#461)` | Single-mode suffix |
| `_assemble_mount_value accepts combined access,propagation (#461)` | Combined mode |
| `_assemble_mount_value output validates via _validate_mount (#461)` | Round-trip validation |
| `_assemble_mount_value empty mode means no suffix (#461)` | Empty-mode no suffix |
| `_assemble_mount_value space-bearing path is rejected by _validate_mount (#687)` | Space-path rejection |
| `_prompt_mount_with_picker assembles full mount string from picker steps (#461)` | Full picker assembly |
| `_prompt_mount_with_picker no propagation gives just host:container:access (#461)` | Access-only picker |
| `_prompt_mount_with_picker no access + no propagation gives just host:container (#461)` | Bare picker |

### test/bats/unit/tui_spec.bats (140)

Pure-logic unit tests for the TUI support libraries (`_tui_conf.sh`). No
dialog/whiptail invocations here — strictly validators, mount-string
parsers, and setup.conf round-trip.

Grouped by concern:

- `_validate_mount` (valid forms, env-var expansion, reject missing/extra
colons, invalid mode)

- `_validate_gpu_count` ('all', positive int, reject
0/negative/non-numeric/empty)

- `_validate_enum` (match, non-match, empty)

- `_mount_host_path` (plain, with mode, with env-var host)

- `_load_setup_conf_full` + `_write_setup_conf` (section order, kv, comment
preservation, untouched keys, round-trip, dst==tpl regression #187)

- `_upsert_conf_value` (updates existing, leaves other sections untouched)

- `_edit_image_rule __remove` index compaction (#177) — first / middle /
last / sole rule

- `_validate_additional_context` (#199: relative paths, BuildKit schemes,
name punctuation, reject empty / missing pieces, reject invalid name shapes)

- Per-stage `[stage:NAME]` round-trip (#220: namespaced load, append new
section, multi-section append, round-trip, in-place update of existing
section)

- `_validate_log_*` (#328: driver name shape, max_size num+unit, max_file
positive int, compress boolean; covers happy paths + rejection of empty /
whitespace / wrong unit / decimals / case mismatches)

- `_edit_section_lifecycle` (#514: restart radiolist writes simple policy +
default no; on-failure:N assembly; empty-N -> bare on-failure; invalid-N
re-prompt then accept)

- `_edit_section_deploy` legacy runtime->gpu_runtime migration (#517:
suggest msgbox when legacy [deploy] runtime present; silent when gpu_runtime
already used; writes canonical gpu_runtime key)

- `_show_runtime_env_info` (#497: info-only msgbox points at the .env
overlay; writes no override)

| Test | Description |
|------|-------------|
| `_validate_mount accepts simple host:container` | - |
| `_validate_mount accepts host:container:ro` | - |
| `_validate_mount accepts host:container:rw` | - |
| `_validate_mount accepts paths with env var expansion` | - |
| `_validate_mount rejects empty string` | - |
| `_validate_mount rejects missing colon` | - |
| `_validate_mount rejects invalid mode` | - |
| `_validate_mount rejects too many colons` | - |
| `_validate_mount accepts propagation mode rslave (#450)` | - |
| `_validate_mount accepts propagation mode rshared (#450)` | - |
| `_validate_mount accepts propagation mode rprivate (#450)` | - |
| `_validate_mount accepts combined rw,rslave (#450)` | - |
| `_validate_mount accepts combined ro,rshared (#450)` | - |
| `_validate_mount accepts non-recursive variants (#450)` | - |
| `_validate_mount accepts combined rw,slave non-recursive (#450)` | - |
| `_validate_mount rejects invalid propagation mode (#450)` | - |
| `_validate_mount rejects rw,bogus combo (#450)` | - |
| `_validate_mount rejects embedded newline (YAML injection) (#687)` | - |
| `_validate_restart accepts the four bare policies + on-failure:N (#687)` | - |
| `_validate_restart rejects on-failure:0 (docker forbids zero retries) (#687)` | - |
| `_validate_restart rejects leading-zero retry count on-failure:01 (#687)` | - |
| `_validate_restart rejects malformed on-failure values (#687)` | - |
| `_validate_restart rejects an unknown bare policy (#687)` | - |
| `_validate_init accepts true/false and rejects everything else (#792)` | - |
| `_validate_shm_size accepts sizes with units (2gb, 512mb, 1024k, 8g, 100b)` | - |
| `_validate_shm_size accepts uppercase units (2GB, 512MB)` | - |
| `_validate_shm_size rejects missing unit` | - |
| `_validate_shm_size rejects non-numeric / bad unit / empty` | - |
| `_validate_port_mapping accepts host:container` | - |
| `_validate_port_mapping accepts optional /tcp or /udp` | - |
| `_validate_port_mapping rejects bad formats` | - |
| `_validate_env_kv accepts KEY=VALUE and KEY= (empty value)` | - |
| `_validate_env_kv rejects missing = or bad key start` | - |
| `_validate_env_kv rejects embedded newline (YAML injection) (#687)` | - |
| `_validate_additional_context accepts <name>=<relative-path>` | - |
| `_validate_additional_context accepts BuildKit context schemes` | - |
| `_validate_additional_context accepts names with allowed punctuation` | - |
| `_validate_additional_context rejects empty / missing pieces` | - |
| `_validate_additional_context rejects invalid name shapes` | - |
| `_validate_project_name accepts compose-legal project names` | - |
| `_validate_project_name rejects what docker compose rejects` | - |
| `_validate_network_name accepts docker-compatible names` | - |
| `_validate_network_name rejects invalid leading chars / spaces` | - |
| `_validate_capability accepts ALL_CAPS names` | - |
| `_validate_capability rejects lowercase / mixed case` | - |
| `_validate_capability rejects digits / empty` | - |
| `_validate_target_arch accepts empty (auto-detect)` | - |
| `_validate_target_arch accepts BuildKit-known arches` | - |
| `_validate_target_arch rejects unknown arches and aliases` | - |
| `_validate_build_network accepts empty (docker default)` | - |
| `_validate_build_network accepts docker-known network modes` | - |
| `_validate_build_network accepts auto / off (issue #102)` | - |
| `_validate_build_network rejects unknown values` | - |
| `_validate_runtime accepts empty (treated as off)` | - |
| `_validate_runtime accepts auto / nvidia / off` | - |
| `_validate_runtime rejects unknown values` | - |
| `_validate_log_driver accepts registered + plugin-shaped names (#328)` | - |
| `_validate_log_driver rejects empty / whitespace / leading-digit (#328)` | - |
| `_validate_log_max_size accepts <num><unit> in b/k/m/g (#328)` | - |
| `_validate_log_max_size rejects malformed values (#328)` | - |
| `_validate_log_max_file accepts positive integers (#328)` | - |
| `_validate_log_max_file rejects zero/negative/non-numeric (#328)` | - |
| `_validate_log_compress accepts true/false; rejects others (#328)` | - |
| `_validate_log_local_path accepts relative / absolute / tilde paths (#328)` | - |
| `_validate_log_local_path rejects empty / whitespace / newline (#328)` | - |
| `_warn_if_lang_rejected opens a msgbox when given a bad input` | - |
| `_warn_if_lang_rejected is a no-op on empty input` | - |
| `_validate_gpu_count accepts 'all'` | - |
| `_validate_gpu_count accepts positive integer` | - |
| `_validate_gpu_count rejects zero` | - |
| `_validate_gpu_count rejects negative` | - |
| `_validate_gpu_count rejects non-numeric` | - |
| `_validate_gpu_count rejects empty` | - |
| `_validate_enum accepts matching option` | - |
| `_validate_enum rejects non-matching value` | - |
| `_validate_enum rejects empty value` | - |
| `_mount_host_path extracts plain host path` | - |
| `_mount_host_path extracts host path with mode` | - |
| `_mount_host_path extracts host path with env var` | - |
| `_mount_container_path extracts plain container path` | - |
| `_mount_container_path extracts container path with mode` | - |
| `_mount_container_path extracts container path with env var` | - |
| `_mount_container_path empty when input has no colon` | - |
| `_load_setup_conf_full reads all sections preserving order` | - |
| `_load_setup_conf_full reads key/value pairs` | - |
| `_write_setup_conf preserves template comments and section order` | - |
| `_write_setup_conf keeps template value when key not in overrides` | - |
| `_write_setup_conf: dst == tpl (same file) keeps content non-empty (#187 regression)` | - |
| `_write_setup_conf round-trips via _load_setup_conf_full` | - |
| `_upsert_conf_value updates existing key value` | - |
| `_write_setup_conf removed_keys drops matching lines` | - |
| `_write_setup_conf appends unknown override keys to their section` | - |
| `_upsert_conf_value leaves other sections untouched` | - |
| `_upsert_conf_value creates section + key when section absent` | - |
| `_upsert_conf_value appends key at EOF when section is the last one without target key` | - |
| `_write_setup_conf flushes unknown override keys that belong to the final template section` | - |
| `_write_setup_conf removed_keys + final-section flush interplay` | - |
| `_upsert_conf_value replaces a value carrying an inline ' #' instead of appending a duplicate key (#955)` | - |
| `_write_setup_conf keeps a logging.<svc> override out of the parent [logging] section (#955)` | - |
| `_write_setup_conf appends a brand-new [logging.<svc>] section rather than folding it into [logging] (#955)` | - |
| `_edit_list_section: an unknown list has no label row, and fails rather than drawing a blank screen (base#994)` | The labels stopped being call-site arguments and became a table, and the failure mode moved with them: a missing row can no longer be a wrong argument, it is a screen with no words on it. This is the case that keeps that from rendering -- an unknown (section, prefix) pair fails loudly instead of drawing a menu whose title, Add and Back rows are empty strings, which is the silent-failure shape invariant 2 exists to refuse. |
| `_edit_list_section: every list editor the TUI ships has a complete label row (base#994)` | The complement, and the reason the guard is not vacuous: every list the TUI actually ships has a complete row, so the failure above can only ever be a typo or an editor somebody added without a screen. The population is DERIVED from setup_tui.sh's own `_edit_list_section` call sites, because the editor this case exists to catch is the twelfth one -- added with no `_TUI_LIST_LABELS` row, which a hand-written list of eleven pairs would not know to ask about. The floor below is the only remembered number, and it is there so a derivation that silently matched nothing cannot pass over an empty set. |
| `_edit_list_section shows mount_1 when value is non-empty` | - |
| `_edit_list_section add reuses empty mount_1 slot instead of leapfrogging` | - |
| `_edit_list_section add uses max+1 when no empty slots exist` | - |
| `_edit_list_section skips empty value from menu display` | - |
| `_detect_mig returns 0 when nvidia-smi reports Enabled` | - |
| `_detect_mig returns 1 when nvidia-smi reports Disabled` | - |
| `_detect_mig returns 1 when nvidia-smi is missing` | - |
| `_detect_mig returns 1 when nvidia-smi output has no mode line` | - |
| `_detect_mig: an early-closing reader cannot turn MIG Enabled into disabled (#905)` | - |
| `_list_gpu_instances returns nvidia-smi -L output` | - |
| `_edit_section_deploy shows MIG msgbox when host has MIG enabled` | - |
| `_edit_section_deploy skips MIG msgbox when MIG disabled` | - |
| `_edit_image_rule add of duplicate @basename drops old slot` | - |
| `_edit_image_rule add of NEW rule string leaves existing slots untouched` | - |
| `_edit_image_rule different prefix values are NOT treated as duplicates` | - |
| `_validate_cgroup_rule accepts canonical examples` | - |
| `_validate_cgroup_rule rejects bad format` | - |
| `_swap_image_rule swaps two populated slots` | - |
| `_swap_image_rule moving down from empty neighbour relocates the entry` | - |
| `_swap_image_rule target < 1 is a no-op (already at top)` | - |
| `_edit_image_rule __remove first rule shifts later rules down` | - |
| `_edit_image_rule __remove middle rule shifts higher rules down` | - |
| `_edit_image_rule __remove last rule needs no shift` | - |
| `_edit_image_rule __remove sole rule just removes` | - |
| `_load_setup_conf_full reads [stage:NAME] sections with namespaced keys` | - |
| `_write_setup_conf appends new [stage:NAME] section when not present in template` | - |
| `_write_setup_conf supports multiple new [stage:*] sections in one write` | - |
| `_write_setup_conf round-trips [stage:NAME] via _load_setup_conf_full` | - |
| `_write_setup_conf preserves existing [stage:NAME] when re-saving` | - |
| `_edit_section_lifecycle writes a simple policy (always)` | - |
| `_edit_section_lifecycle writes the default no policy` | - |
| `_edit_section_lifecycle on-failure with N assembles on-failure:N` | - |
| `_edit_section_lifecycle on-failure with empty N falls back to bare on-failure` | - |
| `_edit_section_lifecycle on-failure re-prompts on invalid N then accepts` | - |
| `_edit_section_deploy suggests migration when legacy [deploy] runtime present (no silent rewrite) (#517)` | - |
| `_edit_section_deploy: no migration suggestion when gpu_runtime already used (#517)` | - |
| `_show_runtime_env_info shows an info msgbox about .env and writes nothing (#497)` | - |
| `_edit_section_deploy writes the canonical gpu_runtime key (#517)` | - |

### test/bats/unit/upgrade_spec.bats (48)

Unit tests for `upgrade.sh` helpers. Uses the sed-range pattern to extract
one function at a time into a minimal harness (with `_log` / `_error`
stubs), so each helper runs in a sandboxed git repo without needing to
source the full `upgrade.sh` (which would trigger its top-level `cd
REPO_ROOT`).

Covers: `_warn_config_drift` (silent / fires on drift / diff hint), the
three safety guards added after the v0.9.7 Jetson incident
(`_require_git_identity`, `_require_clean_merge_state`,
`_verify_subtree_intact` with rollback), structural invariants that pin
call-ordering in `_upgrade` (identity check runs before subtree pull,
integrity verification runs after, pre-pull HEAD is snapshotted for
rollback), the R1+ rewrite of `_verify_subtree_intact` (#477) that replaces
the hard-coded marker list with a path-agnostic structural invariant +
target-version match (catches destructive fast-forward, empty subtree,
malformed `.version`, and wrong-tag pulls), and the SemVer §11-aware
`_semver_cmp` + `_check` behavior added for issue #156 (prerelease ahead of
latest stable must not be reported as "needing downgrade"), and
`_migrate_lifecycle_restart_default`, which retires the stale devel-scoped
`[lifecycle] restart = no` the old template seeded into every downstream
repo (gated on the pre-pull vendored template, so a deliberately chosen
policy is never rewritten).

| Test | Description |
|------|-------------|
| `_warn_config_drift silent when no .base/dist/config in HEAD` | - |
| `_warn_config_drift silent when pre and post hashes match` | No drift |
| `_warn_config_drift prints WARNING + diff hint when hashes differ` | Drift reported |
| `upgrade.sh defines _warn_config_drift` | Helper present |
| `upgrade.sh invokes _warn_config_drift after subtree pull` | Call site present |
| `upgrade.sh captures pre-pull <subtree-prefix>/config tree hash` | - |
| `_require_git_identity succeeds when name + email are set` | Happy path |
| `_require_git_identity fails when user.email is unset` | Email guard |
| `_require_git_identity fails when user.name is unset` | Name guard |
| `_require_clean_merge_state succeeds in clean repo` | Happy path |
| `_require_clean_merge_state fails when MERGE_HEAD exists` | Mid-merge guard |
| `_require_clean_merge_state fails when rebase-merge dir exists` | Mid-rebase guard |
| `_verify_subtree_intact succeeds when subtree dir + version match target (#477 happy path)` | R1+ happy path |
| `_verify_subtree_intact rolls back when .base/.version is missing` | - |
| `_verify_subtree_intact rolls back when .base/ dir is missing (#477 destructive-FF detector)` | - |
| `_verify_subtree_intact rolls back when .base/ dir is empty (#477)` | - |
| `_verify_subtree_intact rolls back when .version content is not semver (#477)` | R1+ semver-shape guard |
| `_verify_subtree_intact rolls back when .version does not match target (#477 wrong-tag detector)` | R1+ wrong-tag detector |
| `_rollback_subtree_pull surfaces a failed reset instead of falsely reporting 'restored' (#700)` | Failed-reset escalation (no false 'restored' message) |
| `upgrade.sh calls _require_git_identity before subtree pull` | Pre-flight ordering |
| `upgrade.sh calls _verify_subtree_intact after subtree pull with target version (#477)` | Post-flight ordering + R1+ caller integration |
| `upgrade.sh snapshots pre-pull HEAD for rollback` | Rollback anchor |
| `upgrade.sh sources lib/template_guard.sh` | - |
| `upgrade.sh calls _assert_not_template_source with the resolved subtree root` | - |
| `_semver_cmp: equal versions return 0` | Equality |
| `_semver_cmp: lower core returns 1` | Behind core |
| `_semver_cmp: higher core returns 2` | Ahead core |
| `_semver_cmp: pre-release < final at same core (rc1 < 0.12.0)` | SemVer §11 a |
| `_semver_cmp: final > pre-release at same core (0.12.0 > rc1)` | SemVer §11 b |
| `_semver_cmp: rc1 < rc2 (lex pre-release ordering)` | Pre-release order |
| `_semver_cmp: rc2 > rc1` | Pre-release order |
| `_semver_cmp: pre-release of newer beats older final (0.12.0-rc1 > 0.11.0)` | Cross-core |
| `_semver_cmp: older final < pre-release of newer (0.11.0 < 0.12.0-rc1)` | Cross-core |
| `_check: equal versions report up-to-date and exit 0` | Happy equal |
| `_check: behind latest reports update available and exits 1` | Behind |
| `_check: prerelease ahead of latest stable exits 0 (issue #156 case)` | Regression #156 |
| `_check: stable later than latest stable exits 0 (defensive)` | Local-only tag |
| `_check: prerelease behind latest stable proposes upgrade (rc1 →0.12.0)` | Leave prerelease |
| `_get_latest_version: returns 0 with an empty result when the remote is unreachable` | - |
| `_get_latest_version: an early-closing reader cannot empty the tag scan (#905)` | - |
| `_get_latest_version: empty result feeds _check's 'Could not fetch' guard` | Empty result still surfaces real fetch failures |
| `_upgrade refuses to downgrade from a newer local version` | Implicit-downgrade guard |
| `_migrate_lifecycle_restart_default rewrites the stale template default, loudly` | - |
| `_migrate_lifecycle_restart_default leaves a deliberately chosen policy alone` | - |
| `_migrate_lifecycle_restart_default is inert once the vendored template ships the new default` | - |
| `_migrate_lifecycle_restart_default ignores a restart key outside [lifecycle]` | - |
| `_migrate_lifecycle_restart_default is a no-op without a repo .setup.conf` | - |
| `_migrate_lifecycle_restart_default is a no-op without a vendored template baseline` | - |

### test/bats/unit/upstream_spec.bats (9)

| Test | Description |
|------|-------------|
| `upstream.sh: defines the slug and derives the clone URL from it (#895)` | - |
| `upstream.sh: sourcing it twice is inert (#895)` | - |
| `upstream.sh: reads nothing from the environment (#895)` | - |
| `exactly one shipped file names the upstream in code (#895)` | - |
| `upgrade.sh defaults TEMPLATE_REMOTE to the shared constant (#895)` | - |
| `init.sh defaults its version query to the shared constant (#895)` | - |
| `check-base-version.sh defaults BASE_REPO to the shared constant (#895)` | - |
| `check-base-version.sh still resolves its default with no override set (#895)` | - |
| `a caller's TEMPLATE_REMOTE still wins over the shared default (#895)` | - |

### test/bats/unit/watchdog_spec.bats (18)

Pure-logic (kcov-safe) unit tests for
`dist/script/docker/runtime/watchdog.sh` (#797), the generic single-service
watchdog sourced from a repo entrypoint (sibling of `logging.sh`). Covers
the master off switch (no-op when `WATCHDOG_CHECK` unset), config load
defaults + clamping, the pluggable health-check runner (pass / fail /
timeout), the shared `_watchdog_evaluate` decision seam (healthy reset /
under-threshold / act), the `_watchdog_grace` bounded stop window,
`_watchdog_pgid_of` / `_watchdog_child_alive` liveness helpers, the
`WATCHDOG_NOTIFY` give-up hook, and the `watchdog.log` per-start file +
symlink under a `watchdog/` subdir (reusing `logrotate.sh`). The
process-level supervision loops + signal paths live in
`watchdog_supervision_spec.bats`.

| Test | Description |
|------|-------------|
| `watchdog is a no-op when WATCHDOG_CHECK is unset (default off) (#797)` | - |
| `_watchdog_enabled is false when check empty, true when set (#797)` | - |
| `_watchdog_load_config applies defaults when knobs unset (#797)` | - |
| `_watchdog_load_config clamps a non-positive interval back to default (#797)` | - |
| `_watchdog_load_config accepts start_period 0 but clamps non-numeric (#797)` | - |
| `_watchdog_load_config honors restart-service, defaults bogus ON_FAIL to restart-container (#797)` | - |
| `_watchdog_run_check returns the check command's status (#797)` | - |
| `_watchdog_run_check times out a hung check as unhealthy (#797)` | - |
| `_watchdog_evaluate resets the counter on a healthy check (#797)` | - |
| `_watchdog_evaluate returns 1 (under threshold) then 2 (threshold reached) (#797)` | - |
| `_watchdog_should_give_up fires only at the MAX_RESTARTS ceiling (#797)` | - |
| `_watchdog_grace reuses WATCHDOG_TIMEOUT with a positive floor (#797)` | - |
| `_watchdog_pgid_of returns a numeric pgid for a live pid, falls back for a bogus one (#797)` | - |
| `_watchdog_child_alive is false for a dead pid, true for a live one (#797)` | - |
| `_watchdog_give_up runs WATCHDOG_NOTIFY when set + logs loudly (#797)` | - |
| `_watchdog_notify is a no-op when WATCHDOG_NOTIFY is unset (#797)` | - |
| `watchdog log setup writes a per-start file + stable symlink under watchdog/ (#797, #805)` | - |
| `watchdog log is stderr-only (no file) when no log dir is configured (#797)` | - |

### test/bats/unit/watchdog_supervision_spec.bats (16)

Process-level supervision tests for the watchdog (#797): the
`restart-container` monitor loop, the `restart-service` supervisor, and the
real signal / process-group teardown paths -- bounded SIGTERM → grace →
SIGKILL (a SIGTERM-ignoring service is killed within the grace, no
unbounded-`wait` hang), whole-subtree kill via `setsid` (no orphaned
grandchild leaks per restart), give-up against a wedged service still
reaching container-exit, and the `docker stop` SIGTERM forward to the
service group. Every wait is event-driven (poll for the pid file, the ready
marker, the process going away) rather than a fixed `sleep`, and every case
starts its processes through ONE harness, `_run_bounded`, so a failure costs
what its ceiling says it costs. Two things are needed for that and each was
measured alone: the harness hands the body a log file instead of the case's
own output descriptor (a setsid'd service inherits that descriptor and holds
`run` waiting for EOF for its whole lifetime -- 45s against a 30s ceiling,
and 326s on the readiness path), and the ceiling ends in SIGKILL
(`--kill-after`), because the product installs its own SIGTERM handler and
unwinds into an unbounded `wait` against a service that ignores signals --
300s against a stated `timeout 45` (#965). The process groups the fixtures
record are torn down in `teardown` rather than from a trap inside the
harness, which is where it was first put and where it did not run, and ONLY
ever as a process group -- a bare-pid fallback could hit a stranger in
another job, and the case that says so settles its verdict on the child's
exit status through `wait` rather than on `kill -0`, which answers "alive"
both for a process sent SIGKILL and not yet scheduled to die and for one
dead and not yet reaped (measured: three false greens in fifteen full-file
runs against a harness that DID signal the bare pid; zero in fifteen with
the rendezvous). The same glance was in `_await_gone`, which every subtree
case settles its verdict with, and it cost a full gate run on this branch:
the group SIGKILL takes the grandchild's parent too, so nobody is left to
wait for it, and the case reported ORPHAN_ALIVE against a correct product.
It now reads the process state, so an exited unreaped pid counts as gone --
the answer the product already gives in `_watchdog_child_alive`.

The `docker stop` forward case is the one this issue reported as NO_SIGNAL,
and the last of it was not a test defect at all. `setsid cmd &` returns at
the fork, so the supervisor sampled the child's process group before
setsid() had run and a lost race left it signalling the bare pid -- 3 of 40
starts on a deliberately loaded machine. A service whose shell sits in a
foreground command then never runs its SIGTERM trap (bash holds a trap until
the foreground command returns, and it returns because the group signal
reached it too), the grace expires, and a correct service is SIGKILLed. The
product now waits briefly for the group to appear, the fixture waits on a
BACKGROUNDED sleep so a signal reaches it in one hop rather than three, and
the harness's two numbers are derived from the interval rather than guessed.
Measured: 0 failures in 30 loaded runs against 3 in 8 before.

The net for the file as a whole is the bound guard in `teardown`, which
measures every case against the ceiling its own harness declared: it holds
for a sibling written in a spelling nothing anticipated, and a
continuation-line `bash -c` sibling that walks past the structural scan is
caught there at 45s against a declared 0. The structural case is the
narrower claim on top of it -- exactly one place in the file starts a shell,
inside `_run_bounded` -- and its job is to say WHICH LINE drifted at the
moment it is written, not to be the thing that catches the drift. These
drive real background processes / sleeps / signals, so the file is
**kcov-fragile** (each test carries the `[ "${COVERAGE:-0}" = 1 ] && skip`
guard; it runs plain under `bats-fragile`, ADR-00000008 / #613 / #677).

| Test | Description |
|------|-------------|
| `restart-container monitor DEFERS checks during the start period (#797)` | - |
| `restart-container monitor EXITS the container after consecutive failures (#797)` | - |
| `_watchdog_start_service group-signals even when the pgid is read before setsid takes (#797)` | - |
| `restart-service supervisor restarts in place then GIVES UP loudly at MAX_RESTARTS (#797)` | - |
| `_watchdog_stop_service SIGKILLs a SIGTERM-ignoring service within the bounded grace (no hang) (#797)` | - |
| `_watchdog_stop_service kills the whole service subtree (no orphaned grandchild) (#797)` | - |
| `restart-service give-up against a wedged (SIGTERM-ignoring) service still exits the container (#797)` | - |
| `restart-service supervisor forwards SIGTERM PROMPTLY on docker stop, not deferred until the interval (#797)` | - |
| `the readiness wait's own failure path returns within its bound, it does not hang (#965)` | - |
| `a service the case gives up on cannot hold the case open past its bound (#965)` | - |
| `a harness that swallows its own ceiling's signal is still bounded (#965)` | - |
| `_kill_case_groups: never signals a bare pid, only a process GROUP (#965)` | - |
| `_await_gone: a killed process nobody has reaped is GONE, not still alive (#965)` | - |
| `_reap_child: a killed child and a completed one report DIFFERENT statuses (#965)` | - |
| `_within_case_bound: answers no exactly when a case outran its own ceiling (#965)` | - |
| `every SHELL this file starts is started inside the one bounded harness (#965)` | - |

### test/bats/unit/worker_preflight_yaml_spec.bats (12)

Structural assertions that `build-worker.yaml` and `release-worker.yaml`
wire in the caller-contract preflight: a `preflight` job that the real build
/ release job gates on (its `needs:` list includes it), fetching the
validator + manifest from base at the worker's own ref
(`github.job_workflow_sha`, so the validator can never drift from the worker
it guards), then calling `preflight.sh` with the per-worker manifest and the
real inputs exported into the env vars the manifest names (plus a GHCR-login
probe feeding the packages-permission check on the build side). #801 adds
the build side's `cache_backend` export into the manifest guard env and a
REAL packages: write probe (a GHCR blob-upload scope check, not a bare
login) for the registry backend.

| Test | Description |
|------|-------------|
| `build-worker.yaml: declares a preflight job (#800)` | - |
| `build-worker.yaml: build job gates on preflight (#800)` | - |
| `build-worker.yaml: preflight fetches the validator at the worker's own ref (job_workflow_sha, no drift) (#800)` | - |
| `build-worker.yaml: preflight runs preflight.sh with the build manifest (#800)` | - |
| `build-worker.yaml: preflight exports image_name into the manifest env var (#800)` | - |
| `build-worker.yaml: preflight probes GHCR login for the packages permission (#800)` | - |
| `build-worker.yaml: preflight exports cache_backend into the manifest guard env (#801)` | - |
| `build-worker.yaml: preflight verifies a REAL packages:write, not just login, for the registry backend (#801)` | - |
| `release-worker.yaml: declares a preflight job (#800)` | - |
| `release-worker.yaml: release job gates on preflight (#800)` | - |
| `release-worker.yaml: preflight runs preflight.sh with the release manifest (#800)` | - |
| `release-worker.yaml: preflight exports archive_name_prefix into the manifest env var (#800)` | - |

### test/bats/unit/workflow_unchecked_producer_spec.bats (6)

`while ... done < <(cmd)` hands the loop cmd's OUTPUT and never cmd's
STATUS: a loop's exit status is its own. `set -e` cannot see the failure,
and `pipefail` does not reach it either -- a process substitution is no
pipeline. A producer that fails therefore delivers ZERO LINES, and zero
lines is a plausible answer to nearly every question a CI step asks: no
paths changed, no stages declared, no artifacts to reclaim. The step then
does less work than it was asked to and reports success for it.

This is not a hypothetical shape. build-worker.yaml's doc-only classifier
read `git diff --name-only base...head` exactly this way, so a force-pushed
base or a shallow clone missing the base commit read as "no code changed"
and took the REQUIRED docker-build check green having built nothing. Nothing
in the tree could have caught it: shellcheck never sees a workflow `run:`
block (it is not a shell FILE), and every behavioural test of such a step
asserts what it does when the producer WORKED.

The rule: capture the producer's output and check its status, then read the
loop from the variable. An unreadable answer is not an empty one.

Scope is the `run:` blocks of .github/workflows only. Shell under script/
and dist/ is a different case -- there strict mode is at file scope, the
early-close-reader lint already owns the pipeline half of this family, and
shellcheck reads the file. A workflow step is where none of that reaches.

The population is DERIVED from the directory, so a workflow added tomorrow
is scanned the day it lands, and the last two cases assert the scan actually
walked something -- an empty scan passes a "nothing found" assertion for the
wrong reason.

| Test | Description |
|------|-------------|
| `workflow run blocks: a loop fed by a process substitution is reported` | The rule bites, demonstrated over a fixture rather than the live tree -- the only occurrence in this repo was removed by the fix this spec accompanies, so without a fixture the scan would be asserting nothing and could not go red if it stopped matching. |
| `workflow run blocks: capturing the producer and checking it is clean` | The other half of a usable rule: the prescribed fix has to pass, or the lint tells authors what to stop doing without telling them what to write instead, and the first false positive is on the corrected code. |
| `workflow run blocks: a comment naming the shape is not the shape` | This repo's own fix explains itself by quoting the construct it replaced, so a scan that cannot tell prose from code would make the explanation unwritable and push authors to delete the reasoning to get the lint green. |
| `workflow run blocks: a job with no steps is scanned, not an error` | A pure `uses:` caller job contributes no run blocks, and this repo has several. If one aborted the walk the scan would report clean for the rest of the directory, which is the fail-open this whole spec exists to refuse. |
| `every workflow in this repo reads its producers checked` | The rule applied to the live tree, over a population derived from the directory rather than listed here -- which is what makes a workflow added tomorrow scanned the day it lands instead of the day somebody remembers to add it. |
| `the scan really walked this repo's workflows, so a clean result means something` | The non-vacuity case, and the one that keeps the live-tree case honest: an empty result satisfies "nothing found" whether the scan read every workflow or none of them, so the population and the run blocks it read are asserted rather than assumed. |

### test/bats/unit/wrapper_lib_lookup_spec.bats (5)

Locks how the wrappers locate `_lib.sh` (#282): `--help` paths source it
from `.base/` when present, and the lookup errors clearly when neither
`.base/` nor a sibling `_lib.sh` exists.

| Test | Description |
|------|-------------|
| `build.sh --help: sources _lib.sh from .base/ (#282)` | build resolves lib from subtree |
| `run.sh --help: sources _lib.sh from .base/ (#282)` | run resolves lib from subtree |
| `exec.sh --help: sources _lib.sh from .base/ (#282)` | exec resolves lib from subtree |
| `stop.sh --help: sources _lib.sh from .base/ (#282)` | stop resolves lib from subtree |
| `build.sh: errors clearly when neither .base/ nor sibling _lib.sh exists (#282)` | Missing-lib hard fail |

### test/bats/unit/wrapper_lib_spec.bats (29)

Unit tests for the wrapper-runtime module `lib/wrapper.sh` (#565), which
hoists the cross-cutting surfaces the 5 docker wrappers (build / run / exec
/ stop / prune) used to duplicate: the `_msg` dispatcher, the `--lang`
pre-pass, and the build/run setup/drift orchestration. Each helper is
sourced directly (not through a wrapper) so the branches run in isolation; a
minimal sandbox with a mock `setup.sh` drives the orchestration end-to-end
without docker.

Covers (with the "called from each of the 5 wrappers" parameterisation):

| Test | Description |
|------|-------------|
| `_msg dispatches <category> <key> to _msg_<category> (#565)` | - |
| `_msg reads the global _LANG for locale selection (#565)` | - |
| `_msg errors when category is missing (#565)` | - |
| `_msg errors when key is missing (#565)` | - |
| `_wrapper_lang_prepass sets _LANG from --lang (#565, #222)` | - |
| `_wrapper_lang_prepass finds --lang even when it is not first (#565, #222)` | - |
| `_wrapper_lang_prepass leaves _LANG untouched when no --lang given (#565)` | - |
| `_wrapper_lang_prepass falls back to 'en' on an unsupported --lang value (#565)` | - |
| `_wrapper_lang_prepass requires a verb argument (#565)` | - |
| `_wrapper_lang_prepass threads each wrapper's verb into the warning (#565)` | - |
| `_wrapper_setup_sync bootstraps via setup.sh when .env is missing (#565)` | - |
| `_wrapper_setup_sync RUN_SETUP=true forces an interactive setup run (#565)` | - |
| `_wrapper_setup_sync drift-check clean path does NOT re-apply (#565)` | - |
| `_wrapper_setup_sync regenerates on drift (check-drift non-zero) (#565)` | - |
| `_wrapper_setup_sync exits 1 with no_env error when setup leaves no .env (#565)` | - |
| `_wrapper_setup_sync tags log events with the caller's verb (#565)` | - |
| `_wrapper_setup_sync requires a verb argument (#565)` | - |
| `_wrapper_setup_sync degrades to empty forward-args when SETUP_FORWARD_ARGS is unset (#565)` | - |
| `a deferred rename is adopted by the first run that finds the project empty (#920)` | - |
| `adopting a rename takes the deferral block out whole and nothing else (#920)` | - |
| `a deferred rename stays deferred while the old project is still up (#920)` | - |
| `a rename is NOT adopted while the old project still holds named volumes (#920)` | - |
| `a project holding BOTH containers and volumes is reported as containers (#920)` | - |
| `a volume query the daemon cannot answer leaves the rename deferred (#920)` | - |
| `an unanswerable daemon leaves the rename deferred and says why (#920)` | - |
| `no pending rename touches nothing and asks the daemon nothing (#920)` | - |
| `_wrapper_service_running answers per project, not per host (#920)` | - |
| `a FAILING service probe is reported, not silently read as not-running (#920)` | - |
| `a service probe that answers cleanly stays quiet (#920)` | - |

### test/bats/unit/yaml_permission_surface_spec.bats (36)

Unit tests for the DERIVED job and permission surfaces in
`test/bats/unit/test_helper.bash` (`yaml_job_names` /
`yaml_job_permission_entries` / `yaml_permission_surface` /
`reusable_workflow_files`) and for the boundary `yaml_job_text` draws
between two jobs.

Every least-privilege guard in this repo is a scan over one of those
derivations, and every one of them asserts the scan came back EMPTY -- so a
derivation that stops seeing part of the file reports exactly what a clean
file reports. The derivations therefore need tests whose fixtures CONTAIN
the elevation and which fail when it is not reported.

The four shapes pinned here are all legal GitHub workflow, and each made a
whole job or a whole grant invisible to the hand-rolled awk these helpers
used to be: a trailing comment on a job key (the key pattern was anchored at
end of line, so the job was not a job); a trailing comment or a quoted level
on a permission entry (an entry the pattern rejected ENDED the block,
dropping it and everything after it, so whether an elevation was seen
depended on where in the block it sat); a job id that does not begin with a
lowercase letter (`Sign:`, `_pub:` did not terminate the job above them,
which then reported their grants as its own); and `"on":` or a flow-style
`on:` mapping (the reusable-worker derivation matched `^on:` as text, so a
worker written either way was scanned by nothing). The helpers now query a
YAML parser (`yq`, added to `dockerfile/Dockerfile.test-tools` as Alpine's
`yq-go`), which also fails CLOSED: a file it cannot parse is a `BUG:` line
and a non-zero status, where the awk simply produced a shorter answer.

A fifth derivation joins them: `spec_permission_surface_subjects`, which
answers "which workflow file is this spec's surface call applied TO". The
class-level guard used to answer that with two independent substring
questions of the same file -- does it contain the string
`yaml_permission_surface`, and does it contain the worker's path -- so any
spec answering both certified a worker whose surface it never reads.
Appending one call about worker A to a spec that merely MENTIONS worker B
certified B. The derivation resolves the call's own ARGUMENT (a literal, or
a variable with exactly one unambiguous literal assignment in the same
file), and everything it cannot resolve is reported as `UNRESOLVED:` or as
`BUG:` rather than assumed either way.

Which occurrences ARE call sites is decided by a lexer over the shell text,
not by matching the name: an occurrence inside quotes, inside a heredoc BODY
or after a word-initial `#` is text. The heredoc half is where that reading
either holds or fails open, so it follows bash exactly -- a terminator may
be bare, `\`-escaped or quoted with either character and is read literally;
a body ends at a line that is EXACTLY the terminator (`<<-` strips leading
TABS, nothing else does); `<<<` opens nothing and `<<` inside `$(( ))` is a
shift; and a `<<` whose terminator this cannot read opens a heredoc no line
closes, spending the rest of the file rather than handing a fixture body
back as code.

Fixtures are written to a scratch directory, never to the checkout: these
are tests OF the extractor, so they need shapes the real workflows do not
have. The fixtures' own `@test` headers are indented one space, because the
doc count generator counts a spec's tests with `grep -c '^@test'`.

| Test | Description |
|------|-------------|
| `yaml_job_names: a trailing comment on the job key does not hide the job (#957)` | `sign-artifacts: # signs the images` is a job. The old key pattern was anchored at end of line, so it was not one -- and its `packages: write` was scanned by nothing |
| `yaml_permission_surface: a job whose key carries a trailing comment reports its grants (#957)` | The same shape end to end: an elevation on a job the derivation cannot see is an elevation no assertion over the surface can fail on |
| `yaml_job_names: a job id that does not start with a lowercase letter is a job (#957)` | `Sign` and `_pub` are legal GitHub job ids and must appear in the derived list |
| `yaml_permission_surface: an uppercase-initial job does not lend its grants to the job above it (#957)` | The mis-attribution is worse than a miss: the job with NO block of its own reported the next job's grants, so it looked bounded while it was the one running on the caller's whole token |
| `yaml_job_text: stops at a job key that does not start with a lowercase letter (#957)` | The boundary underneath that mis-attribution: the terminator is any two-space-indented key, not a lowercase-initial one (a two-space comment line still does not terminate) |
| `yaml_job_names: a file with no jobs: mapping fails loudly rather than returning nothing (#957)` | An empty derivation satisfies every "the scan came back empty" assertion in the repo, so it may never be a silent success |
| `yaml_job_permission_entries: a trailing comment on an entry does not truncate the block (#957)` | `packages: write # cache push` is an entry. The old scanner read a line it could not match as the END of the block, dropping that entry and every one after it |
| `yaml_job_permission_entries: a quoted level is still an entry (#957)` | `packages: "write"` is the same grant written differently; a text match on the level missed it |
| `yaml_job_permission_entries: an elevation is reported wherever it sits in the block (#957)` | Order-dependence is the tell of a scanner that ends its block on the first line it cannot read: the same entry was reported when it came last and swallowed the whole block when it came first |
| `yaml_job_permission_entries: an unreadable file fails loudly instead of reporting a short block (#957)` | The fail-open direction as its own property: a file the extractor cannot parse must not reach a caller as a clean, under-reported grant set |
| `yaml_job_permission_entries: a job that is not in the file fails loudly (#957)` | A spec naming a job that was renamed is a defect, not an absence -- it must not return an empty entry set |
| `yaml_permission_surface: an inline permissions scalar surfaces as no entries (#957)` | `permissions: read-all` / `permissions: {}` name no scope, so they bound nothing: the job has to be VISIBLE as unbounded rather than absent from the listing |
| `reusable_workflow_files: a worker spelling the trigger "on": is still a worker (#957)` | Quoting `on` is the standard workaround for YAML 1.1 reading it as a boolean, and what several formatters emit; the old `^on:` text anchor exempted such a worker from every least-privilege scan |
| `reusable_workflow_files: a flow-style on mapping is still read (#957)` | `on: {workflow_call: null}` is the same declaration in flow style |
| `reusable_workflow_files: a workflow that is not callable is not listed (#957)` | The other direction: a `push`-only workflow runs on its own repo's token and is not part of this population |
| `workflow_files: lists .yaml and .yml, and nothing else (#957)` | One reading of which files a workflow directory holds, so a third extension cannot reach the derivation and miss the cross-check that re-reads the same directory raw |
| `reusable_workflow_files: draws its candidates from workflow_files (#957)` | The consequence of the shared reading: a worker written with the other extension is derived, because one place says which extensions a workflow file may carry |
| `reusable_workflow_files: an unreadable workflow is reported, not skipped (#957)` | A worker the derivation cannot parse is a worker nothing downstream scans, so it joins the listing as a `BUG:` line |
| `spec_permission_surface_subjects: a mentioned path is not a subject (#957)` | The defect the class-level guard shipped with: a spec that MENTIONS a worker and separately calls the surface on another one certified both. The subject is resolved from the call's own argument |
| `spec_permission_surface_subjects: a literal argument resolves to itself (#957)` | A call site that names the workflow inline needs no resolution |
| `spec_permission_surface_subjects: reads a call inside a process substitution (#957)` | The shape the scanning specs use: the argument carries the substitution's closing paren and the line continues after it |
| `spec_permission_surface_subjects: a path named only in a comment is not a subject (#957)` | A prose paragraph naming a worker is not a pin -- the same reason every structural assertion here reads code lines |
| `spec_permission_surface_subjects: an argument it cannot resolve says so (#957)` | A generated fixture path is a legitimate subject that is no tracked workflow; it reads as UNRESOLVED, never as one of the paths the file happens to mention and never as nothing |
| `spec_permission_surface_subjects: an ambiguous variable is not resolved (#957)` | Two assignments and two literals: which one the call site saw is not decidable from the text, and guessing would certify a worker on a coin flip |
| `spec_permission_surface_subjects: a call with no argument is a BUG line (#957)` | A call whose argument cannot be seen must not be dropped -- dropping it is how a spec that pins a worker stops counting as its pin |
| `spec_permission_surface_subjects: a spec that never calls it prints nothing and exits 1 (#957)` | The status splits "read, no call site" from "not read", so a caller cannot count an unreadable spec as one that pins nothing |
| `spec_permission_surface_subjects: a spec it cannot read is a BUG line, not silence (#957)` | The other half of that split, and the one that would otherwise shrink the certified population silently |
| `spec_permission_surface_subjects: a path inside a double-quoted string is not a subject (#957)` | A quoted occurrence is text, not a call -- and a path in a message string certified a worker nothing reads |
| `spec_permission_surface_subjects: a path inside a single-quoted string is not a subject (#957)` | The other spelling of the same shape, so a resolver that learns only about double quotes cannot pass |
| `spec_permission_surface_subjects: a call inside a heredoc body is not a subject (#957)` | A heredoc body is data the spec writes, not code it runs; this tree's own fixtures carry that exact call shape |
| `spec_permission_surface_subjects: a path after a trailing # is not a subject (#957)` | `code_lines` drops comment-ONLY lines by design, so a trailing comment reaches the derivation and the shell's word-initial `#` rule decides it |
| `spec_permission_surface_subjects: a call inside a command substitution IS a subject (#957)` | The over-strict failure is the same defect with the sign flipped: `$( )` opened inside a double-quoted assignment is build_worker_yaml_spec's own shape |
| `spec_permission_surface_subjects: a backslash-quoted heredoc body is not code (#957)` | bash quotes a terminator three ways and `<<\INNER` is the third. Reading no terminator opened no heredoc and emitted the body as code, so a worker named only in a fixture the spec WRITES was certified |
| `spec_permission_surface_subjects: an indented terminator does not end a heredoc (#957)` | A body ends at a line that is EXACTLY the terminator (`<<-` strips leading TABS, never spaces). Trimming the line first ended the body at the fixture's own indented mention of it and read the rest as code |
| `spec_permission_surface_subjects: a terminator it cannot read opens an unmatchable heredoc (#957)` | The unreadable case stated as a direction: a `<<` this cannot finish reading still opens a heredoc, one no line closes. It spends the rest of the file, which fails loudly, rather than handing a fixture body back as code |
| `spec_permission_surface_subjects: an arithmetic left shift is not a heredoc (#957)` | `$(( 1 << 2 ))` and `(( n <<= 1 ))` are shifts. Read as openers they made every later line data, so a spec that DOES pin its worker reported pinning nothing |

<!-- /generated -->
