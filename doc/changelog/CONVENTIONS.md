# Writing a changelog entry

Part of the [changelog index](CHANGELOG.md).

An entry answers two questions: **what changed**, and **does it affect me**.
Not why, not what was rejected -- the PR body is this repo's canonical
decision record, the entry already links to it by number, and prose pasted
into both places leaves the argument living twice with the changelog copy the
unreadable one.

```markdown
- **One sentence on what changed** (#NNN) -- who is affected, and whether it
  breaks anything.
```

## Categories

An entry goes under exactly one of these headings, and no other. The lint
refuses anything else in `[Unreleased]`; released sections keep whatever
they shipped with, because rewriting a shipped heading falsifies the record.

<!-- changelog-categories: begin -- generated-by-hand mirror of script/release/changelog_categories.sh; the changelog-entry lint compares the two -->

- `BREAKING`
- `Added`
- `Changed`
- `Deprecated`
- `Removed`
- `Fixed`
- `Security`

<!-- changelog-categories: end -->

`BREAKING` sorts first and is first-class because this project's dominant
risk is breaking the downstream repos that carry `.base/`. **Migration
instructions belong inside the BREAKING entry they serve**, not in a
parallel `Migration` section a reader can miss.

Conventional-commit types (`feat` / `fix` / `test` / `chore` / `refactor`)
were considered and rejected as the axis. They answer *what kind of work was
this* -- the author's view -- where a changelog answers *what changed for me*
-- the reader's. Filing by commit type institutionalises putting `test:` /
`chore:` / `refactor:` work into the changelog, which is part of how this
file passed 680 KiB. A refactor a reader must know about, such as a new
lint that can fail their CI, is `Added`; one they need not know about is
not an entry at all.

The roster is defined once, in `script/release/changelog_categories.sh`. The
lint and the release-notes assembler source it; the list above is a
rendering of it, and the lint fails if the two stop agreeing.

**An `[Unreleased]` entry is capped at 700 characters**, enforced by the
`changelog-entry` lint (`just test lint --changelog-entry`). Two things about
how it measures, because they decide what you can and cannot do about a
failure:

- The unit is the **whole entry** -- the lead bullet plus every continuation
  line and sub-bullet, up to the next top-level bullet or heading. Rewrapping
  the prose or splitting it into a nested list does not reduce the count.
- **Whitespace is collapsed first**, so wrapping at 79 columns and indenting a
  sub-list cost nothing. A short lead plus a four-item migration sub-list
  measures about 450 and fits comfortably.
- The count is in **characters**, the same number on every machine -- quoting
  a path or a heading from the ja / zh-TW / zh-CN guides costs one per
  character, not three.

An entry opens with a `- ` bullet **at column 0**. `*`, `+` and an indented
`-` render the same but are refused by name, because a line that opens no
entry is a line the cap never applies to. Inside a fenced code block nothing
is structure, so an example may safely show a heading or a bullet.

The cap is not the median of past entries; it is set above what a complete
entry actually needs. Ten entries written in this style for the v0.42.0 cycle's
real changes -- including two BREAKING migrations -- measured 210-543. If an
entry does not fit, the part that does not fit is almost always the reasoning,
and it belongs in the PR.

Inside one release block an entry may not repeat another entry's lead bullet,
and a `### <category>` heading may not open twice. That pair is what a serial
merge leaves behind: two branches that both append to `[Unreleased]` do not
conflict, so git keeps both sides and nothing prompts a human. Either one is
refused naming BOTH lines; fold the second copy into the first.

Released sections are **never** checked: they are a historical record, and
rewriting a shipped entry falsifies it. A genuinely exceptional entry opts out
by bracketing it with `<!-- changelog-entry-lint: allow-begin -- <why> -->` and
`<!-- changelog-entry-lint: allow-end -->`.

## The paragraph above the first category

A section may open with prose before its first `### ` heading. For the tag
being released that paragraph is **published as written**, at the top of the
GitHub release page above the merged entries, so write what a reader of that
page needs -- what the release is for, what to do before their next build --
or write nothing.

Do not write it to point at the RC sections. A promoted final's notes are the
union of its own section and every `-rcN` section under it
(`script/release/release_notes.sh`), so "the entries stay under the RC
headings that introduced them" is a sentence about this directory's layout,
printed on a page that already carries those entries. The assembler cannot
tell it from a release summary -- both are prose under a section with no
categories of its own -- and it publishes rather than guesses, because the
alternative deletes the summary too.

An `-rcN` section's own lead is dropped unless it carries a `- ` entry: it
says which candidate this is, which the reader of the final tag is not being
told. A bullet under no heading is an entry that happens to sit above the
first category, and travels to the page with the sentence introducing it.
