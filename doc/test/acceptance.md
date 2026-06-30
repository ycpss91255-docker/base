# Acceptance Tests (reserved)

Acceptance specs under `test/bats/acceptance/`: **0 tests**.

> **Reserved** ISTQB level (ADR-00000018). The **Acceptance** level
> verifies what the downstream consumer receives -- the scaffolded
> framework and its UX (the `just` commands, help, completion, and the
> generated layout) from the consumer's chair (UAT + OAT).

The directory ships empty (`.gitkeep`) so the full level x type grid is
visible in the tree without reading the ADR. Content lands in S5 (#785),
which formalizes the current `integration-e2e` scaffold-downstream + UX
checks as the Acceptance level and adds a real `just template new`
end-to-end test. Until then the count is 0 and this catalog is a
placeholder; `sync-doc-counts.sh` tolerates the empty dir.
