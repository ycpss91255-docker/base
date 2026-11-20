## Linked issue

Closes #
<!-- Use `Closes #NNN` to close the issue on merge, or `Relates to #NNN`
     when the issue stays open. In prose, write `base#NNN`. -->

## Single concern and atomic commits

- [ ] This PR solves one core problem only, with no unrelated refactor or dependent change mixed in.
- [ ] If the work has several logical steps, they are tidied into clean atomic commits.

## Control flow

- [ ] New or changed code nests control flow at most 3 levels deep.
- [ ] Preconditions and error handling use guard clauses (early return) to flatten the code, not arrow-shaped nesting.

## Test and build

- [ ] The image builds (Docker build and syntax checks pass).
- [ ] The existing test matrix (Bats and unit tests) is all green.

## Security and boundaries

- [ ] The container keeps its non-privileged user boundary, and no host-specific absolute path is hardcoded.
