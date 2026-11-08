# Logging output to host

Part of the [base README](../../README.md). The README keeps a short summary of this topic and links here.

Set `[logging] local_path` to tee container stdout/stderr to a host-side
file, in addition to the docker daemon's json-file log:

```toml
[logging]
local_path = "./log/"   # repo-relative; or /abs/, or ~/dir/
container_log_keep = 20  # keep at most N most-recent per-start files
container_log_days = 14  # AND drop files older than D days (stricter wins)
```

Re-run any wrapper to regenerate `compose.yaml`. On each container start
the tee writes a per-start file `<local_path>/<svc>_<ts>.log` and repoints
a stable symlink `<local_path>/<svc>.log` at it (glog-style): `tail
<svc>.log` always shows the current run, while earlier runs stay on disk.
Old per-start files are pruned by `container_log_keep` most-recent AND
`container_log_days` age (stricter wins), never the symlink. `docker logs
<ct>` is unaffected (json-file keeps rolling history).

Setting `[logging] local_path` is the only step for any repo running
base's `ENTRYPOINT` orchestrator, which sources the helper for you. A repo
still running its own `/entrypoint.sh` as the `ENTRYPOINT` should take the
one-time migration in [entrypoint.md](entrypoint.md).

## Wrapper transcripts

Separate from the container-app logging above, each non-interactive
container-ops verb (`just docker build` / `setup` / `stop` / `prune` /
`upgrade`) tees its own combined output to a plaintext transcript for
debugging:

```
log/<verb>/<UTC-ts>-<traceid8>.log    # ANSI stripped; terminal keeps colour
log/<verb>/latest.log                 # symlink to the most recent run
```

The terminal output is unchanged (stdout and stderr stay separate); the
transcript is a faithful copy with ANSI escapes removed, ending in a
`transcript_complete exit_code=… duration=…s` line. Retention keeps the
most recent `wrapper_transcript_keep` (20) per verb and drops anything
older than `wrapper_transcript_days` (14), stricter wins. Turn it off
with `[logging] wrapper_transcript = false`. Interactive verbs
(`run` attached / `exec` / `setup-tui`) capture only the orchestration
phase and then detach before the interactive session (`run -d` is
non-interactive and is captured in full). `log/` is git- and
docker-ignored automatically.

```toml
[logging]
wrapper_transcript = true   # kill switch (default true)
wrapper_transcript_keep = 20
wrapper_transcript_days = 14
```

The `WRAPPER_TRANSCRIPT` environment variable **outranks that conf key**,
in both directions, for one invocation:

```bash
WRAPPER_TRANSCRIPT=false just docker build   # no transcript, conf untouched
WRAPPER_TRANSCRIPT=true  just docker build   # transcript even if the conf says false
```

It exists so a CI job or a test run can switch capture off without editing
a file that is committed and shared (base's own suite exports it, which is
why its specs never leave a `log/` tree in the checkout). Because it wins
over a setting you configured and can read back in `setup.sh show`, only
`true` and `false` are accepted: any other value **aborts the verb** naming
the variable, rather than quietly handing the decision back to the conf
key. Unset (or empty) means "no override".

To browse a transcript in [lnav](https://lnav.org) with timestamp
ordering and level highlighting, load the bundled regex format once:

```bash
lnav -i .base/dist/script/docker/lib/transcript.lnav-format.json   # one-time install
lnav log/build/latest.log
```

It recognizes the `<ISO ts> [service] LEVEL: msg` lines (DEBUG / INFO /
WARN / ERROR / FATAL); raw docker output falls through as body. It
coexists with `log.lnav-format.json` (the JSON `*.jsonl` format).
