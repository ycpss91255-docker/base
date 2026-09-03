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
