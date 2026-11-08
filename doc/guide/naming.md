# Naming scheme: three namespaces, two user identities

Part of the [base README](../../README.md). The README keeps a short summary of this topic and links here.

`setup.sh` emits two names in `.env` / `compose.yaml`, and compose
derives the third. They look similar on a single-user dev machine, but
they live in **three different namespaces** and pick their user prefix
from **two different identities**. Sysadmins running shared hosts need
to know the difference; solo developers can treat the two identities as
the same and move on.

| Name | Format | Namespace | User prefix |
|---|---|---|---|
| `image:` | `${DOCKER_HUB_USER:-local}/<repo>:<tag>` | **Registry** (Docker Hub) | `DOCKER_HUB_USER` |
| compose project name | `${DOCKER_HUB_USER}-<repo>` | **Host daemon** (scopes containers / default network / volume labels) | `DOCKER_HUB_USER` (detected as the OS user when there is no login) |
| container name | `<project>-<service>-<n>`, derived by compose | **Host daemon** (flat global) | inherited from the project |

- `DOCKER_HUB_USER` — your Docker Hub account, used to namespace
  images on the registry side. Image tags are addressable as
  `<DOCKER_HUB_USER>/<repo>:<tag>` whether or not you actually push.
  On a machine with no Docker Hub login, `setup.sh` detects it as your
  **OS user** (`${USER}`, else `id -un`) rather than leaving it empty.
- `USER_NAME` — the OS user (from `id -un`), passed in as a build arg so
  the container user and its home directory match yours. It prefixes no
  name in the table above.

The two identities are deliberately separate. Image names use the
Docker Hub identity because images are addressable on the registry,
and forcing per-OS-user image tags would shatter buildx cache reuse
and Docker Hub layer sharing. The project name uses that same identity,
so on a single-user machine the two line up — and on a shared host it
differs per OS user with nothing configured and no second rule, because
the detection above already falls back to the OS user. The one thing
that identity cannot separate is two OS users sharing a single Docker
Hub login; see the worked example below.

**The dev stack emits no `container_name:`; the field-deploy bundle
(`just docker setup deploy`) is the one exemption, which
does bake a `container_name:`.** A container name is namespaced by the daemon rather
than by the project, so a fixed one pins the service to a single instance
per host: a second stack of the same repo fails to start with `name ... is
already in use` however it is named, and compose refuses `--scale` while
the directive is present. Letting compose derive `<project>-<service>-<n>`
makes the name unique by construction, which is what puts per-host
isolation entirely in the project name. The deploy bundle is a fully
resolved, self-contained single-device artifact -- one stack per device,
never co-located, no overlay expanding it -- and the operator running it
wants one stable name to `docker logs`. Two emitters, two rules; the
co-location argument applies to the dev stack.

```
COMPOSE_PROJECT_NAME=isaac-ci      docker compose up -d stream  # isaac-ci-stream-1
COMPOSE_PROJECT_NAME=isaac-manual  docker compose up -d stream  # isaac-manual-stream-1
```

Nothing you type changes: `just docker exec -t <target>` takes a compose
**service** name (it always did — it is passed straight to `compose
exec`), and `just docker run` / `just docker stop` are project-scoped already. What
does change is that `docker exec <fixed-name>` by hand no longer has a
fixed name to use; ask compose (`just docker exec`) instead.

base's own control surface stays **single-instance** (#600): one project
per repo, resolved once by `setup apply`. Running the same repo as N
parallel stacks is the compose layer's job, mirroring how `docker` has
no project concept and `docker compose` owns `-p`.

Two *checkouts* of the same repo are a different question, and base
does answer that one: give each checkout its own project name with
`[project] name` in `setup.local.toml` — see [Running two worktrees
at once](lifecycle.md#running-two-worktrees-at-once).

Worked example. OS user `alice`, Docker Hub user `alice-hub`, repo
`claude_code`:

```
image:          alice-hub/claude_code:devel
project name:   alice-hub-claude_code
container:      alice-hub-claude_code-devel-1   (derived by compose)
```

A second OS user `bob` on the same host, with no Docker Hub account
configured:

```
image:          bob/claude_code:devel           (hub user detected as the OS user)
project name:   bob-claude_code                 (same prefix, no configuration)
container:      bob-claude_code-devel-1         (derived by compose)
```

If `alice` and `bob` share `DOCKER_HUB_USER` (e.g. a shared CI
service account) they also share a project name, and that is the case
to set `[project] name` for — the setting exists, and with no
`container_name` baked over it, it now reaches the containers too.
