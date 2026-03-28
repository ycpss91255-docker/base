# docker_template

[![Self Test](https://github.com/ycpss91255-docker/docker_template/actions/workflows/self-test.yaml/badge.svg)](https://github.com/ycpss91255-docker/docker_template/actions/workflows/self-test.yaml)

[ycpss91255-docker](https://github.com/ycpss91255-docker) 組織下所有 Docker 容器 repo 的共用模板。

[English](../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md)

## 概述

此 repo 集中管理所有 Docker 容器 repo 共用的腳本、測試和 CI workflow。各 repo 透過 **git subtree** 拉入此模板，並使用 symlink 引用共用檔案。

### Architecture

```mermaid
graph TB
    subgraph docker_template["docker_template (shared repo)"]
        scripts["build.sh / run.sh / exec.sh / stop.sh<br/>setup.sh / .hadolint.yaml"]
        smoke["test/smoke_test/<br/>script_help.bats<br/>display_env.bats"]
        config["config/<br/>bashrc / tmux / terminator / pip"]
        mgmt["scripts/<br/>init.sh / upgrade.sh / ci.sh / migrate.sh"]
        workflows["Reusable Workflows<br/>build-worker.yaml<br/>release-worker.yaml"]
    end

    subgraph consumer["Consumer Repo (e.g. ros_noetic)"]
        symlinks["build.sh → docker_template/build.sh<br/>run.sh → docker_template/run.sh<br/>exec.sh / stop.sh / .hadolint.yaml"]
        dockerfile["Dockerfile<br/>compose.yaml<br/>.env.example<br/>script/entrypoint.sh"]
        repo_test["test/smoke_test/<br/>ros_env.bats (repo-specific)"]
        main_yaml["main.yaml<br/>→ calls reusable workflows"]
    end

    docker_template -- "git subtree" --> consumer
    scripts -. symlink .-> symlinks
    smoke -. "Dockerfile COPY" .-> repo_test
    workflows -. "@tag reference" .-> main_yaml
```

### CI/CD Flow

```mermaid
flowchart LR
    subgraph local["Local"]
        build_test["./build.sh test"]
        make_test["make test"]
    end

    subgraph ci_container["CI Container (kcov/kcov)"]
        shellcheck["ShellCheck"]
        hadolint["Hadolint"]
        bats["Bats smoke tests"]
    end

    subgraph github["GitHub Actions"]
        build_worker["build-worker.yaml<br/>(from docker_template)"]
        release_worker["release-worker.yaml<br/>(from docker_template)"]
    end

    build_test --> ci_container
    make_test -->|"scripts/ci.sh"| ci_container
    shellcheck --> hadolint --> bats

    push["git push / PR"] --> build_worker
    build_worker -->|"docker build test"| ci_container
    tag["git tag v*"] --> release_worker
    release_worker -->|"tar.gz + zip"| release["GitHub Release"]
```

### 包含內容

| 檔案 | 說明 |
|------|------|
| `build.sh` | 建置容器（呼叫 `setup.sh` 產生 `.env`） |
| `run.sh` | 執行容器（支援 X11/Wayland） |
| `exec.sh` | 進入執行中的容器 |
| `stop.sh` | 停止並移除容器 |
| `setup.sh` | 自動偵測系統參數並產生 `.env` |
| `config/` | Shell 設定檔（bashrc、tmux、terminator、pip） |
| `test/smoke_test/` | 給各 consumer repo 使用的共用測試 |
| `.hadolint.yaml` | 共用 Hadolint 規則 |
| `.github/workflows/build-worker.yaml` | 可重用的 CI 建置 workflow |
| `.github/workflows/release-worker.yaml` | 可重用的 CI 發布 workflow |

### 各 repo 自行維護的檔案（不共用）

- `Dockerfile`
- `compose.yaml`
- `.env.example`
- `script/entrypoint.sh`
- `doc/` 和 `README.md`
- Repo 專屬的 smoke test

## 快速開始

### 加入新 repo

```bash
git subtree add --prefix=docker_template \
    git@github.com:ycpss91255-docker/docker_template.git main --squash

```

### 建立 symlinks

```bash
# 根目錄腳本
# 2. Initialize symlinks (one command)
./docker_template/scripts/init.sh
```
```

### 更新 subtree

```bash
