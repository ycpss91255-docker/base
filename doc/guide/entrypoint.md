# Container entrypoint: the orchestrator and your bringup

Part of the [base README](../../README.md). The README keeps a short summary of this topic and links here.

The container `ENTRYPOINT` is **base's**. Your `script/entrypoint.sh` is a
**bringup** that base's orchestrator *sources*:

| in the image | owner | ships from | role |
|---|---|---|---|
| `/usr/local/lib/base/entrypoint.sh` | base | `.base/dist/script/docker/runtime/` — the one directory `COPY` | the container `ENTRYPOINT` |
| `/entrypoint.sh` | the repo | `script/entrypoint.sh`, seeded once by `init.sh` | the repo's own bringup |

The orchestrator runs four steps, in this order:

```bash
. /usr/local/lib/base/logging.sh    # host log tee: wraps everything after it
. /entrypoint.sh                    # YOUR bringup -- sourced, not exec'd
. /usr/local/lib/base/watchdog.sh   # may take over and never return
exec "$@"                           # the workload (CMD / the command you passed)
```

Each step needs the one before it. Logging rebinds stdout/stderr, so it has
to open first. The bringup sets the environment both the watchdog's health
check and the workload read, so it has to run before either. The watchdog
arms last because with `watchdog_on_fail = restart-service` it supervises
the service itself and never comes back. All three sources are skipped if
the file is not there, so an image that opted into none of it still starts.

**What goes in your bringup:** whatever the workload needs in its
environment — a ROS overlay to source, an `export`, a directory to create.
It runs with the workload still in `"$@"`.

**What must not:** an `exec` (the orchestrator owns the final one; an exec
here fires mid-source and the watchdog never arms), and any
`. /usr/local/lib/base/...` line (the orchestrator already sources them —
a second source means a second per-start log file, or a second watchdog).

**Why two files.** The bringup is seeded once and is yours from then on:
no subtree pull replaces it, and the only edits an upgrade makes to it are
the named migrations of `apply_migrations` (see "What upgrade.sh rewrites
in your repo" in the [README](../../README.md#what-upgradesh-rewrites-in-your-repo)).
So anything base may need to change later cannot live there. It used to — the `logging.sh` / `watchdog.sh` source
lines and the `exec` were seeded into every repo, which meant base could
not change its own plumbing without an edit in every consumer. The helpers
themselves never had that problem (they arrive by the directory `COPY`),
and the orchestrator now arrives the same way.

**Migrating an existing repo.** Two edits, and they must land **together**:

```diff
  # Dockerfile
- ENTRYPOINT ["/entrypoint.sh"]
+ ENTRYPOINT ["/usr/local/lib/base/entrypoint.sh"]
```

```diff
  # script/entrypoint.sh -- keep your bringup, drop base's plumbing
- . /usr/local/lib/base/logging.sh
- . /usr/local/lib/base/watchdog.sh
+ set +u
  source "/opt/ros/${ROS_DISTRO}/setup.bash"
+ set -u
  export MY_APP_HOME=/opt/app
- exec "${@}"
```

**The `set +u` is not cosmetic** if your bringup sources anything that
dereferences unbound variables — a ROS overlay being that case in this org.
Your file used to be the `ENTRYPOINT`, running under whatever options it set
itself, and the file `init.sh` seeded before this release sets none. Sourced
by the orchestrator it now runs under `set -euo pipefail`, so the same line
aborts on ROS's unbound `AMENT_TRACE_SETUP_FILES` and the container dies
before your workload ever starts. Bracket it in the SAME commit as the other
two edits. `just base upgrade` writes the bracket too, but only on the
upgrade AFTER the flip — the flip commit itself has to carry it.

Flipping the `ENTRYPOINT` first breaks the container (the un-removed `exec`
pre-empts the watchdog); cleaning the bringup first is merely inert. Until
you do both, **nothing changes** — your repo keeps its own `ENTRYPOINT`,
runs exactly as before, and simply does not get base's later plumbing
changes. `just base upgrade` prints a one-line notice until it is
migrated, and never performs the `ENTRYPOINT` flip for you: only you can
tell your bringup from base's plumbing in a file you have been
hand-editing. Named migrations (`apply_migrations`) may still patch
base-owned lines in either file, as step 5 of the upgrade cycle says.
