# docker_template

[![Self Test](https://github.com/ycpss91255-docker/docker_template/actions/workflows/self-test.yaml/badge.svg)](https://github.com/ycpss91255-docker/docker_template/actions/workflows/self-test.yaml)

Shared template for Docker container repos in the [ycpss91255-docker](https://github.com/ycpss91255-docker) organization.

[繁體中文](doc/readme/README.zh-TW.md) | [简体中文](doc/readme/README.zh-CN.md) | [日本語](doc/readme/README.ja.md)

## Overview

This repo consolidates shared scripts, tests, and CI workflows used across all Docker container repos. Instead of maintaining identical files in 15+ repos, each repo pulls this template as a **git subtree** and uses symlinks.

### What's included

| File | Description |
|------|-------------|
| `build.sh` | Build containers (calls `setup.sh` for `.env` generation) |
| `run.sh` | Run containers (X11/Wayland support) |
| `exec.sh` | Exec into running containers |
| `stop.sh` | Stop and remove containers |
| `setup.sh` | Auto-detect system parameters and generate `.env` |
| `config/` | Shell configs (bashrc, tmux, terminator, pip) |
| `smoke_test/` | Shared smoke tests for consumer repos |
| `.hadolint.yaml` | Shared Hadolint rules |
| `.github/workflows/build-worker.yaml` | Reusable CI build workflow |
| `.github/workflows/release-worker.yaml` | Reusable CI release workflow |

### What stays in each repo (not shared)

- `Dockerfile`
- `compose.yaml`
- `.env.example`
- `script/entrypoint.sh`
- `doc/` and `README.md`
- Repo-specific smoke tests

## Quick Start

### Adding to a new repo

```bash
# 1. Add subtree
git subtree add --prefix=docker_template \
    git@github.com:ycpss91255-docker/docker_template.git main --squash

# 2. Initialize symlinks (one command)
./docker_template/scripts/init.sh
```

### Updating the subtree

```bash
git subtree pull --prefix=docker_template \
    git@github.com:ycpss91255-docker/docker_template.git main --squash \
    -m "chore: update docker_template subtree"
```

Update `.docker_template_version` to the latest tag.

## CI Reusable Workflows

Consumer repos replace local `build-worker.yaml` / `release-worker.yaml` with calls to this repo's reusable workflows:

```yaml
# .github/workflows/main.yaml
jobs:
  call-docker-build:
    uses: ycpss91255-docker/docker_template/.github/workflows/build-worker.yaml@v1
    with:
      image_name: ros_noetic
      build_args: |
        ROS_DISTRO=noetic
        ROS_TAG=ros-base
        UBUNTU_CODENAME=focal

  call-release:
    needs: call-docker-build
    if: startsWith(github.ref, 'refs/tags/')
    uses: ycpss91255-docker/docker_template/.github/workflows/release-worker.yaml@v1
    with:
      archive_name_prefix: ros_noetic
```

### build-worker.yaml inputs

| Input | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `image_name` | string | yes | - | Container image name |
| `build_args` | string | no | `""` | Multi-line KEY=VALUE build args |
| `build_runtime` | boolean | no | `true` | Whether to build runtime stage |

### release-worker.yaml inputs

| Input | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `archive_name_prefix` | string | yes | - | Archive name prefix |
| `extra_files` | string | no | `""` | Space-separated extra files |

## Running Tests Locally

```bash
make test        # Full CI (ShellCheck + Bats + Kcov) via docker compose
make lint        # ShellCheck only
make clean       # Remove coverage reports
make help        # Show all available targets
```

Or directly:
```bash
./scripts/ci.sh          # Full CI via docker compose
./scripts/ci.sh --ci     # Run inside container (used by compose)
```

## Tests

- **124** template self-tests (`test/unit/`)
- **22** shared smoke tests (`test/smoke_test/`) for consumer repos

See [TEST.md](doc/test/TEST.md) for full test list.

## Changelog

See [CHANGELOG.md](doc/changelog/CHANGELOG.md).

## Directory Structure

```
docker_template/
├── build.sh                          # Shared build script
├── run.sh                            # Shared run script (X11/Wayland)
├── exec.sh                           # Shared exec script
├── stop.sh                           # Shared stop script
├── setup.sh                          # .env generator
├── config/                           # Shell/tool configs
│   ├── pip/
│   └── shell/
│       ├── bashrc
│       ├── terminator/
│       └── tmux/
├── test/
│   ├── smoke_test/                   # Shared tests for consumer repos
│   │   ├── test_helper.bash
│   │   ├── script_help.bats
│   │   └── display_env.bats
│   └── unit/                         # Template self-tests (124 tests)
├── Makefile                          # Unified command entry (make test/lint/...)
├── compose.yaml                      # Docker CI runner
├── .hadolint.yaml                    # Shared Hadolint rules
├── scripts/                          # Template management tools
│   ├── init.sh                       # Consumer repo symlink setup
│   ├── ci.sh                         # CI pipeline (local + remote)
│   └── migrate.sh                    # Batch repo migration
├── .github/workflows/
│   ├── self-test.yaml                # Template CI (calls scripts/ci.sh)
│   ├── build-worker.yaml             # Reusable build workflow
│   └── release-worker.yaml           # Reusable release workflow
├── doc/
│   ├── readme/                       # README translations
│   ├── test/                         # TEST.md + translations
│   └── changelog/                    # CHANGELOG.md + translations
├── .codecov.yaml
├── .gitignore
├── LICENSE
└── README.md
```
