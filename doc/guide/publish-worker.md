# publish-worker.yaml and source archives

Part of the [base README](../../README.md). The README keeps a short summary of this topic and links here.

## publish-worker.yaml inputs (opt-in, foundational image repos)

Pushes a Dockerfile target stage to a container registry on tag push.
Opt-in: only repos that consume this workflow publish images (default
template flow stays test-only). Typical use case: foundational image
repos that other repos consume via Docker `FROM`.

| Input | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `image_name` | string | yes | - | Image repo name on the registry (e.g. `my_image`); full ref becomes `${registry}/${owner}/${image_name}` |
| `tag_suffix` | string | no | `""` | Appended to both `:${version}` and `:latest` tags. Convention: `-<matrix-entry-name>` so each variant lands on its own tag |
| `is_latest` | boolean | no | `false` | When true, also pushes `:latest${tag_suffix}` alongside `:${version}${tag_suffix}`. Multi-variant repos set this only on the canonical default variant |
| `registry` | string | no | `"ghcr.io"` | Container registry hostname. GHCR uses GITHUB_TOKEN auth automatically |
| `target` | string | no | `"devel"` | Dockerfile target stage to publish. `devel` for app-base usage; `runtime` for production images |
| `build_args` | string | no | `""` | Multi-line KEY=VALUE build args (same shape as build-worker) |
| `platforms` | string | no | `"linux/amd64"` | Comma-separated target platforms; multi-arch publishes a single multi-arch manifest under each tag |
| `context_path` | string | no | `"."` | Build context (mirrors build-worker) |
| `dockerfile_path` | string | no | `""` | Optional explicit Dockerfile path |
| `build_contexts` | string | no | `""` | Optional newline-separated `<name>=<location>` build contexts |

The tooling image is derived here the same way build-worker derives it
(from the version-matched base checkout), and is not an input.

Caller example (foundational multi-variant repo):

```yaml
# .github/workflows/main.yaml
jobs:
  call-publish:
    needs: ci-passed
    if: startsWith(github.ref, 'refs/tags/')
    permissions:
      contents: read
      packages: write
    strategy:
      matrix:
        target:
          - { name: 'standard',  base: 'python:3.11-slim',     is_latest: true }
          - { name: 'minimal',   base: 'python:3.11-alpine',   is_latest: false }
    uses: ycpss91255-docker/base/.github/workflows/publish-worker.yaml@vX.Y.Z
    with:
      image_name: my_image
      tag_suffix: "-${{ matrix.target.name }}"
      is_latest: ${{ matrix.target.is_latest }}
      target: devel
      build_args: |
        BASE_IMAGE=${{ matrix.target.base }}
```

After a `v0.1.0` tag push, the matrix above yields:

```
ghcr.io/<org>/my_image:v0.1.0-standard
ghcr.io/<org>/my_image:latest-standard   # is_latest = true
ghcr.io/<org>/my_image:v0.1.0-minimal
```

Downstream app repos then `FROM ghcr.io/<org>/my_image:v0.1.0-standard` in their own Dockerfile, dropping the duplicated sys / base / devel layers.

## Source archives on a base release

A **base** release carries GitHub's own auto-generated source archives
(`tarball_url` / `zipball_url`) and no other asset. Those archives hold the
full tracked tree -- `.version`, the repo-root `init.sh`, `CONTEXT.md` and
the dotfiles included -- so there is nothing for the release job to
assemble.

Do not re-add a hand-built `.tar.gz` / `.zip` pair beside them. The one that
used to be there was a hardcoded `cp` operand list: a tracked file nobody
remembered to add to the list was simply missing from the archive with no
error to notice, and a listed path that went away failed the whole release
at tag push.

A **downstream** release is a different case: `release-worker.yaml`
assembles `<archive_name_prefix>-vX.Y.Z.tar.gz` / `.zip` from a declared
payload (`script/ci/release/archive.manifest`), because a consumer's archive
is a curated deliverable rather than a snapshot of the source.
