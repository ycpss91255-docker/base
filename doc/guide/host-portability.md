# Host portability: GNU-specific call sites

Part of the [base PRD](../PRD.md). base's host tooling supports Linux only
today; cross-platform host support is a later goal (base#1644). This page
lists the host-side call sites that rely on a GNU form, so that effort starts
from a list and not from rediscovery. It is an inventory, not a port plan.

## How this list was made

It comes from `grep` over `dist/script/`, `init.sh` and `upgrade.sh` at the
commit that added this page, for these patterns: `grep -P`, `--reference`,
`stat -c`/`stat -f`, `date -d`, `sort -V`, `sed -i`, `readlink -f`, `xargs -r`,
`find -printf`, `cp --`, `mktemp --`, `realpath -`. It is not an exhaustive
audit, and no site was run on a macOS or BSD host: whether each form fails
there is not tested here. Re-run the greps before relying on a line number.

## Call sites

| Call | Sites | If the host tool lacks it |
|------|-------|---------------------------|
| `grep -oP` (PCRE) | `dist/script/docker/lib/drift.sh:38-42` (5 reads) | `-P` is a GNU grep option that needs a PCRE build. The reads end in `\|\| true`, so a grep without it leaves every stored value empty; each comparison is guarded by a non-empty test, so no drift is reported. Tracked as its own fix in base#1644. |
| `chmod --reference` | `dist/script/docker/lib/wrapper.sh:454`, `dist/script/docker/lib/dockerfile_migrate.sh:165`, `dist/script/docker/lib/conf.sh:1530`, `dist/script/docker/lib/gitignore.sh:182` | Copies the mode of an existing file onto its replacement temp file. `wrapper.sh:454` ignores a failure (`2>/dev/null \|\| true`); the others do not. |
| `stat -c` | `dist/script/docker/lib/resolve.sh:95` | Reads the group ids of `/dev/dri` nodes; stderr is discarded, so a failure yields an empty list. |
| `date -d` | `dist/script/docker/lib/project_reclaim.sh:635` | Parses a creation timestamp to epoch seconds; stderr is discarded and the call ends in `\|\| true`. |
| `sort -V` | `dist/script/base/upgrade.sh:576` | Version ordering in the upgrade comparison. |
| `sed -i` (no backup suffix) | `dist/script/base/upgrade.sh:814`, `dist/script/docker/lib/dockerfile_migrate.sh:148` | In-place edit with `-i` and no suffix argument. |
| `readlink -f` | `dist/script/docker/wrapper/{build,exec,run,stop,prune,setup,setup_tui}.sh`, `dist/script/docker/lib/help.sh:27`, `dist/script/base/completions.sh:28`, `dist/script/template/new.sh:21` and `:75`, `dist/script/docker/lib/deploy.sh:793` | Most of these fall back to the unresolved path with `\|\| printf`. `new.sh:75` and `deploy.sh:793` have no fallback. `deploy.sh:793` sits in the text of the generated field-deploy launcher, so it runs on the field host, not the build host. |

The sites inside the `grep -P` and `chmod --reference` rows are the ones the
base#1644 issue named; the `sort -V`, `sed -i` and `readlink -f` rows were
added by the grep above.

## Out of scope

Porting these calls, Windows hosts, and the target image platforms
(`linux/amd64`, `linux/arm64`), which are handled by the build worker's
`platforms` input.
