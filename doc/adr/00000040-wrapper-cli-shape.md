# Wrapper CLI shape: positional plus -t on build.sh, project-wide stop.sh, subcommand-first setup.sh

> Serves: PRD invariant 3 (composable by construction) -- one consistent
> argument shape across the user-facing wrappers, so a downstream README
> can link the cheat sheet instead of restating it.

- **Date:** 2026-11-08
- **Status:** Accepted
- **Relates to:** #291 (the wrapper UX cheat sheet), #280 (`-t` on
  `build.sh`)

## Context

The README's "Wrapper UX cheat sheet (#291)" is the one reference for what
each user-facing script accepts. Three cells of that table are decisions
rather than facts, and they were recorded as a "Design decisions locked by
#291" list inside the README itself. The README is a user page and was
trimmed in #1545; a decision record does not belong in it, and a reader
asking why `stop.sh` has no `-t` needs the reason, which only an ADR keeps.

## Decision

1. **Q1, `build.sh` positional vs flag.** Keep the positional TARGET and add
   `-t` / `--target` as a backwards-compatible alias.
   `./script/build.sh runtime` and `./script/build.sh -t runtime` both
   work; downstream READMEs may use either, but should prefer the flag form
   for parity with `run.sh` / `exec.sh`.
2. **Q2, `stop.sh -t`.** Not adopted. `stop.sh` stays project-wide (`docker
   compose down`), because per-service stop has different docker-side
   semantics (`docker compose stop <service>`) and would conflate two
   cleanup verbs under one flag. A user wanting per-service control calls
   `docker compose stop <service>` directly.
3. **Q3, `setup.sh` positional.** Subcommand-first, verb-style
   (`./script/setup.sh set <key> <value>`), unchanged. It is a different
   mental model from the wrapper trio's TARGET / CMD and matches the `git`
   / `docker` CLI convention.

## Consequences

- The cheat sheet's `-t` row reads "Q2: stays project-wide" for `stop.sh`;
  that note now points here.
- A downstream script written against the positional `build.sh` form keeps
  working, and new prose uses the flag.
- `setup.sh` never grows a TARGET positional; per-stage configuration goes
  through `[stage:<name>]` tables instead.

## Alternatives

- **Flag-only `build.sh`.** Rejected: it breaks every downstream script and
  README that passes the stage positionally, for no gain over the alias.
- **`stop.sh -t` as `docker compose stop <service>`.** Rejected for the
  conflation above: `down` removes containers and networks, `stop` only
  stops one service, and one verb should not mean both.
- **Positional TARGET on `setup.sh`.** Rejected: its first positional is
  already the subcommand, and mixing the two would make `setup.sh runtime`
  ambiguous.
