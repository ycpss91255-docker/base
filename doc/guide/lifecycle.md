# Container lifecycle: worktrees, network, restart, init, watchdog

Part of the [base README](../../README.md). The README keeps a short summary of this topic and links here.

## Running two worktrees at once

Each checkout runs under a compose project name, and everything it creates
-- containers, networks, volumes -- is namespaced by it. Two checkouts that
resolve the same name collide: the second `run` reuses the first's
containers.

`[project] name` is that name. It ships **empty**, meaning "derive
`<DOCKER_HUB_USER>-<IMAGE_NAME>`, as before", so nothing changes until you
set it. Set it in the *local* layer, because a per-worktree name is yours
rather than the repo's:

```bash
cd ~/work/myrepo-wt2
just docker setup set --local project.name myrepo-wt2
just docker build     # regenerates; both worktrees now run side by side
```

The value is resolved once into `.env.generated` as `PROJECT_NAME`, and
both consumers read it from there: the wrapper's `docker compose -p`, and
the generated `compose.yaml`'s `name: ${PROJECT_NAME}` (so `lazydocker`,
`docker compose ps` and IDE panels agree with the wrapper). Rule for the
value: lowercase letters, digits, `-` and `_`, beginning with a letter or a
digit -- docker compose's own rule.

Changing it does **not** move the image tag. That is `[image]` /
`DOCKER_HUB_USER`, a deliberately separate axis: which containers a run
owns and which image it built are different questions.

**Privileges are opt-in** (#466): the template ships lean `[security]`
(`privileged = false`, no `cap_add` / `security_opt`) and `[devices]`
(no `/dev:/dev`) defaults, so lightweight repos and tooling stages stay
clean. Enable what a container needs via `just docker setup-tui` (security /
devices pages), `just docker setup add security.cap_add SYS_ADMIN`, or by
uncommenting the examples in the template.

## Network mode: host default, bridge opt-in (#794)

`[network] mode` ships as **`host`** and stays there by default. This is a
deliberate fail-safe for the ROS-plurality org, not a convenience:

> **Cross-machine ROS MUST stay on `host`.** Under `bridge` the container
> lives on the `172.17.x` docker network, which is **not routable off the
> box and cannot be made routable**. A multi-machine robot flipped to
> bridge will have its ROS 1 / ROS 2 peers — a safety scanner, a LiDAR —
> go **silently unreachable across machines while CI stays green**. That
> failure is silent, catastrophic, and safety-relevant, so the default
> fails safe toward it (host) and tightening is opt-in.

For a **confirmed single-machine** repo (app container, AI tooling — no
cross-machine ROS), you can tighten to bridge for least-privilege network
isolation:

```bash
just docker setup set network.mode bridge
just docker setup set network.ipc private   # optional: private IPC namespace too
just docker setup apply
```

Published ports (`[network] port_<N>`, e.g. `port_1 = 8080:80`) only take
effect once you are on bridge — compose ignores `ports:` under host
networking. The tool says so rather than dropping the value silently:
`setup.sh set` / `add` warns the moment a port is stored under a non-bridge
mode (and when `mode` is switched away from bridge with ports already
configured), and `apply` / `setup deploy` warn again when the emitter
leaves the `ports:` block out.

Local GUI keeps working under bridge: when the GUI is enabled **and**
`network.mode = bridge`, `setup.sh` pins the container's `hostname:` to the
host's name in the generated `compose.yaml`, so the local X11
MIT-MAGIC-COOKIE (which is keyed to the host's hostname) still matches.
Under `host` networking nothing is injected — the container already shares
the host's UTS namespace.

## Restart policy is deploy-scoped (#841)

`[lifecycle] restart` names the Docker restart policy
(`no` | `always` | `unless-stopped` | `on-failure` | `on-failure:N`). The
template ships **`unless-stopped`**, and the policy is emitted **only on a
deployable stage's service** -- a field service is meant to come back after a
host reboot, which is the whole reason it is not `no`.

"Deployable" is `_is_deployable_stage` (`dist/script/docker/lib/stage.sh`),
the one predicate both the compose emitter and `setup.sh deploy` share. It
rejects `devel` (the interactive shell -- the container lives exactly as long
as that shell, so an auto-restart fights you instead of helping), any
`*-test` stage (it exists to run, assert and **exit**, so a policy that reacts
to exit turns a green test run into a restart loop), and the build
intermediates `sys` / `devel-base`. For any of those the emitter clears the
policy, so:

- you do **not** set `unless-stopped` yourself -- it is the shipped default;
- setting it is **not** dangerous on `devel` or a `*-test` stage -- those
  services structurally cannot receive it, so the classic "always-restarting
  container that exits 0" footgun is prevented by construction rather than by
  your care;
- `devel` therefore carries **no** `restart:` line for an `extends: devel`
  stage to inherit. Each emitted stage gets its own verdict from the same
  predicate.

Override per repo:

```bash
just docker setup set lifecycle.restart on-failure:5
just docker setup apply                # regenerates compose.yaml
```

`lifecycle.*` keys are not per-stage overridable (see the per-stage
allowlist in [dockerfile-stages.md](dockerfile-stages.md)).

**On upgrade:** repos seeded from the old template carry a literal
`restart = no` that nobody chose. A named migration rewrites exactly that
value to `unless-stopped`, once, selected by the version range the upgrade
crosses -- see "What upgrade.sh rewrites in your repo" in the
[README](../../README.md#what-upgradesh-rewrites-in-your-repo).

## Container init: PID1 reaper (#792)

`[lifecycle] init` toggles Docker's `init: true` on every service, which
runs the daemon init (`docker-init` = tini) as **PID 1** — a zombie reaper
and signal forwarder. It **defaults ON**: a deliberate exception to
"lifecycle knobs default off", because init is transparent to a correct
single-service workload, while running as PID 1 *without* reaping / signal
forwarding is a footgun (`stop` hangs until SIGKILL; orphaned children pile
up as zombies). It applies on the next compose regeneration, so an existing
repo picks it up on `setup.sh apply`. Disable it with:

```bash
just docker setup set lifecycle.init false
just docker setup apply                # regenerates compose.yaml
```

**Caveat:** tini forwards signals only to its **direct child** (PID 2 = the
entrypoint). An entrypoint that itself supervises children must still
`trap` + forward signals to them — init does not reach grandchildren for
signalling. **Reaping, however, is comprehensive:** any orphaned process in
the container is reaped, so killed subtrees never accumulate as zombies.

## Watchdog: supervised restart (#797)

The third `[lifecycle]` capability base owns (sibling to restart and init)
is a **generic, health-check-driven watchdog** for the container's one
service. It is **generic** because the app supplies the health-check
*command*; base ships the supervision loop. **Every knob defaults OFF** —
with `watchdog_check` empty (the master switch) there is no watchdog and
no behavior change, and the orchestrator's
`. /usr/local/lib/base/watchdog.sh` line is a no-op. Enable it per repo:

```bash
just docker setup set lifecycle.watchdog_check 'curl -fsS localhost:8080/health'
just docker setup set lifecycle.watchdog_on_fail restart-service   # optional
just docker setup apply                # regenerates compose.yaml
```

Once `watchdog_check` is set, `setup.sh apply` emits the `WATCHDOG_*`
values into each service's `environment:`, and the sourced helper runs the
loop: after `watchdog_start_period`, it runs `watchdog_check` every
`watchdog_interval`s (each bounded by `watchdog_timeout`); after
`watchdog_failures` consecutive failures it takes the `watchdog_on_fail`
action.

| Knob | Default | Meaning |
|------|---------|---------|
| `watchdog_check` | *(empty)* | Health-check command; its exit status is the health signal (0 = healthy). **Empty disables the watchdog.** |
| `watchdog_interval` | `30` | Seconds between checks. |
| `watchdog_timeout` | `10` | Per-check timeout (seconds); a hung check counts as unhealthy. |
| `watchdog_start_period` | `0` | Startup grace window (seconds) before checks begin, so a still-initializing service is not killed. |
| `watchdog_failures` | `3` | Consecutive failures before acting. |
| `watchdog_on_fail` | `restart-container` | Failure action (see below). |
| `watchdog_max_restarts` | `5` | `restart-service` ceiling before giving up. |
| `watchdog_notify` | *(empty)* | Optional command run once, on give-up. |

**Two failure modes** (`watchdog_on_fail`):

- **`restart-container`** (default, Docker-native): the watchdog runs as a
  background monitor while the entrypoint `exec`s the service as PID 2; on
  the failure threshold it **exits the container** so Docker's restart
  policy (`[lifecycle] restart`) restarts the whole container. Docker's own
  backoff absorbs restart storms — there is no watchdog-side backoff. Pair
  it with a `restart` policy (e.g. `on-failure`) so the container actually
  comes back.
- **`restart-service`**: the watchdog **restarts only the in-container
  service in place** (the container stays up), for heavy-init containers
  where a full restart is expensive. It supervises the service as a
  **process-group leader** (via `setsid`) and stops/restarts it like
  `docker stop` (SIGTERM → bounded grace → SIGKILL) against the **whole
  group**, so the service *and every grandchild it spawned* die on each
  restart — no orphaned subtree leaks. (`init = true` reaps *dead*
  children but does not kill *live* orphans; it is this process-group kill,
  not init, that prevents the leak. Init is still recommended as the
  surviving PID 1, and the supervisor also traps SIGTERM so `docker stop`
  gracefully stops the service.) It counts restarts; on reaching
  `watchdog_max_restarts` it **gives up LOUDLY** (never silently churns),
  runs `watchdog_notify` (if set), then falls back to exiting the container
  (the Docker-native end state).

Both the health-check and the notify command are **pluggable** — base
ships the hook points, the app/operator fills in the definition of
"healthy" and the delivery of the give-up notification. Watchdog events
(restart, give-up) are **always logged loudly to stderr** (captured by
`docker logs`, never silent); when the [logging output to host](logging.md#logging-output-to-host)
feature is on, they are **also** written to a `watchdog.log` under the log
dir's `watchdog/` subdir (per-start file + stable symlink + retention,
reusing the same `logrotate.sh` primitives as the container logs).
