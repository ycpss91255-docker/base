#!/usr/bin/env bash
# build.sh - Build Docker container images

set -euo pipefail

# Shared wrapper preamble (sub-task A): resolve FILE_PATH across the
# symlink / script-subfolder / direct / /lint layouts, honor -C/--chdir,
# and source _lib.sh -- all in lib/bootstrap.sh. Locate it from this
# wrapper's real path (readlink -f follows the consumer-repo symlink),
# trying the canonical ../lib/ split then the flat /lint lib/ sibling.
_bootstrap_self="$(readlink -f -- "${BASH_SOURCE[0]:-$0}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]:-$0}")"
for _bootstrap_cand in \
  "$(dirname -- "${_bootstrap_self}")/../lib/bootstrap.sh" \
  "$(dirname -- "${_bootstrap_self}")/lib/bootstrap.sh" \
  "$(dirname -- "${_bootstrap_self}")/.base/dist/script/docker/lib/bootstrap.sh"; do
  if [[ -f "${_bootstrap_cand}" ]]; then
    # shellcheck source=dist/script/docker/lib/bootstrap.sh
    source "${_bootstrap_cand}"
    break
  fi
done
unset _bootstrap_self _bootstrap_cand
if ! declare -F _bootstrap >/dev/null 2>&1; then
  printf '[build] ERROR: cannot find lib/bootstrap.sh (which sources _lib.sh) -- broken install?\n' >&2
  exit 1
fi
# _bootstrap also sources the wrapper runtime (lib/wrapper.sh) after
# _lib.sh, so _msg / _wrapper_lang_prepass / _wrapper_setup_sync are in
# scope below.
_bootstrap "$@"

# i18n message tables — split by semantic category (PR-2).
# Each _msg_<category> returns plain i18n body only; tag + LEVEL keyword
# are added by the _log_* caller (English-only; level keyword no longer
# translated —).
_msg_bootstrap() {
  case "${_LANG}:${1:?}" in
    zh-TW:info)  echo "首次執行 — 初始化中..." ;;
    zh-CN:info)  echo "首次运行 — 初始化中..." ;;
    ja:info)     echo "初回実行 — ブートストラップ中..." ;;
    *:info)      echo "First run — bootstrapping..." ;;
  esac
}

_msg_drift() {
  case "${_LANG}:${1:?}" in
    zh-TW:regen)  echo "重新產生 .env.generated / compose.yaml（setup.conf 已變更）" ;;
    zh-CN:regen)  echo "重新生成 .env.generated / compose.yaml（setup.conf 已变更）" ;;
    ja:regen)     echo ".env.generated / compose.yaml を再生成中（setup.conf が変更されました）" ;;
    *:regen)      echo "regenerating .env.generated / compose.yaml (setup.conf drifted)" ;;
  esac
}

_msg_errors() {
  case "${_LANG}:${1:?}" in
    zh-TW:no_env)       echo "setup 未產生 .env.generated。" ;;
    zh-CN:no_env)       echo "setup 未生成 .env.generated。" ;;
    ja:no_env)          echo "setup が .env.generated を生成しませんでした。" ;;
    *:no_env)           echo "setup did not produce .env.generated." ;;
    zh-TW:rerun_setup)  echo "請改以 './build.sh --setup' 重新執行以開啟編輯器。" ;;
    zh-CN:rerun_setup)  echo "请改以 './build.sh --setup' 重新运行以打开编辑器。" ;;
    ja:rerun_setup)     echo "'./build.sh --setup' で再実行してエディタを開いてください。" ;;
    *:rerun_setup)      echo "Re-run with './build.sh --setup' to open the editor." ;;
  esac
}

# _msg dispatcher provided by lib/wrapper.sh.

usage() {
  case "${_LANG}" in
    zh-TW)
      cat >&2 <<'EOF'
用法: ./build.sh [-h] [-C|--chdir DIR] [-s|--setup] [--reset-conf] [-y|--yes] [--no-cache] [--no-prune] [--clean-tools] [--dry-run] [-v|--verbose] [-vv|--very-verbose] [--lang <en|zh-TW|zh-CN|ja>] [-t|--target TARGET] [TARGET]

選項:
  -h, --help     顯示此說明
  -C, --chdir DIR
                 對 DIR 下的 repo 執行（不改變呼叫者 cwd），類似 git -C。
                 須在其他選項與 TARGET 之前指定。
  -s, --setup    強制重跑 setup.sh（互動式 TTY 開 TUI，否則非互動式 apply）。
                 預設（無此旗標）：當 setup.conf / Dockerfile stages / GPU /
                 GUI / USER_UID 漂移時，.env / .env.generated / compose.yaml 自動重新生成 (#88)。
  --reset-conf   用 template 預設值覆蓋 setup.conf（先備份到 .setup.conf.bak
                 + .env.bak；需確認，可用 -y 跳過）。之後會自動重跑 setup。
  -y, --yes      略過 --reset-conf 的互動確認
  --no-cache     強制不使用 cache 重建
  --no-prune     關閉成功 build 後自動清掉被取代的舊 image (#387)。預設行為:
                 若新 build 更新了同名 tag 且舊 ID 沒被其他 tag 引用,會 docker
                 rmi 它，避免 dangling <none>:<none> 累積。--no-prune 保留舊
                 image 供 rollback / debug。Buildx cache 不受影響（要清用
                 prune.sh --builder）。
  --clean-tools  build 結束後移除本地 test-tools image（預設保留以加速下次 build）
  --dry-run      只印出將執行的 docker 指令，不實際執行
  -v, --verbose  詳細 docker 輸出（BUILDKIT_PROGRESS=plain）。build 卡住時用 —
                 即時顯示每個 RUN 步驟的 stdout/stderr，不再收斂成單行進度條。
  -vv, --very-verbose
                 -v 再加 wrapper 本身的 bash trace（set -x），用於除錯 wrapper
                 邏輯（少用；通常 -v 就夠了）。
  --lang LANG    設定訊息語言（預設: en）
  -t, --target TARGET
                 指定建置目標（等同於位置參數 [TARGET]，與 run.sh -t 對齊）。
                 兩種寫法同時存在時最後一個生效。

目標:
  devel    開發環境（預設）
  test     執行 smoke test
  runtime  最小化 runtime 映像

驗證回報（test / <stage>-test / smoke 等驗證目標）:
  這些目標的檢查是 build layer，cache 命中會重現結果但一步都沒跑。build
  後會回報驗證 stage 本次執行了哪些步驟、哪些是 CACHED，所以「什麼都沒
  驗證」的 build 不會看起來像通過。回報的是該 stage 自己的步驟，不論它跑
  的是 bats、pytest、Playwright 還是 heredoc script。這些目標會把
  BUILDKIT_PROGRESS 固定為 plain（回報所讀的格式）；若輸出完全沒有進度步
  驟、或某步驟狀態始終沒出現，會以非零結束，而不是報成通過。

環境變數:
  QUIET=1  關閉 build 前印出的組態摘要（適合 piped / CI log）。與
           setup.sh 的 -q/--quiet 不同：那個管的是別的輸出。
EOF
      ;;
    zh-CN)
      cat >&2 <<'EOF'
用法: ./build.sh [-h] [-C|--chdir DIR] [-s|--setup] [--reset-conf] [-y|--yes] [--no-cache] [--no-prune] [--clean-tools] [--dry-run] [-v|--verbose] [-vv|--very-verbose] [--lang <en|zh-TW|zh-CN|ja>] [-t|--target TARGET] [TARGET]

选项:
  -h, --help     显示此说明
  -C, --chdir DIR
                 对 DIR 下的 repo 执行（不改变调用者 cwd），类似 git -C。
                 须在其他选项与 TARGET 之前指定。
  -s, --setup    强制重跑 setup.sh（交互式 TTY 开 TUI，否则非交互式 apply）。
                 默认（无此旗标）：当 setup.conf / Dockerfile stages / GPU /
                 GUI / USER_UID 漂移时，.env / .env.generated / compose.yaml 自动重新生成 (#88)。
  --reset-conf   用 template 默认值覆盖 setup.conf（先备份到 .setup.conf.bak
                 + .env.bak；需确认，可用 -y 跳过）。之后会自动重跑 setup。
  -y, --yes      跳过 --reset-conf 的交互确认
  --no-cache     强制不使用 cache 重建
  --no-prune     关闭成功 build 后自动清掉被取代的旧 image (#387)。默认行为:
                 若新 build 更新了同名 tag 且旧 ID 没被其他 tag 引用,会 docker
                 rmi 它，避免 dangling <none>:<none> 累积。--no-prune 保留旧
                 image 供 rollback / debug。Buildx cache 不受影响（要清用
                 prune.sh --builder）。
  --clean-tools  build 结束后移除本地 test-tools image（默认保留以加速下次 build）
  --dry-run      只打印将执行的 docker 命令，不实际执行
  -v, --verbose  详细 docker 输出（BUILDKIT_PROGRESS=plain）。build 卡住时用 —
                 实时显示每个 RUN 步骤的 stdout/stderr，不再收敛成单行进度条。
  -vv, --very-verbose
                 -v 再加 wrapper 本身的 bash trace（set -x），用于调试 wrapper
                 逻辑（少用；通常 -v 就够了）。
  --lang LANG    设置消息语言（默认: en）
  -t, --target TARGET
                 指定构建目标（等同于位置参数 [TARGET]，与 run.sh -t 对齐）。
                 两种写法同时存在时最后一个生效。

目标:
  devel    开发环境（默认）
  test     运行 smoke test
  runtime  最小化 runtime 镜像

验证回报（test / <stage>-test / smoke 等验证目标）:
  这些目标的检查是 build layer，cache 命中会重现结果但一步都没跑。build
  后会回报验证 stage 本次执行了哪些步骤、哪些是 CACHED，所以「什么都没
  验证」的 build 不会看起来像通过。回报的是该 stage 自己的步骤，不论它跑
  的是 bats、pytest、Playwright 还是 heredoc script。这些目标会把
  BUILDKIT_PROGRESS 固定为 plain（回报所读的格式）；若输出完全没有进度步
  骤、或某步骤状态始终没出现，会以非零结束，而不是报成通过。

环境变量:
  QUIET=1  关闭 build 前打印的配置摘要（适合 piped / CI log）。与
           setup.sh 的 -q/--quiet 不同：那个管的是别的输出。
EOF
      ;;
    ja)
      cat >&2 <<'EOF'
使用法: ./build.sh [-h] [-C|--chdir DIR] [-s|--setup] [--reset-conf] [-y|--yes] [--no-cache] [--no-prune] [--clean-tools] [--dry-run] [-v|--verbose] [-vv|--very-verbose] [--lang <en|zh-TW|zh-CN|ja>] [-t|--target TARGET] [TARGET]

オプション:
  -h, --help     このヘルプを表示
  -C, --chdir DIR
                 DIR 配下の repo に対して実行（呼び出し側の cwd は変えない）。
                 git -C と同様。他のオプションや TARGET より前に指定。
  -s, --setup    setup.sh を強制実行（インタラクティブ TTY なら TUI、それ以外は
                 非インタラクティブ apply）。デフォルト（フラグ無し）：setup.conf
                 / Dockerfile stages / GPU / GUI / USER_UID が drift した時、
                 .env / .env.generated / compose.yaml が自動再生成されます (#88)。
  --reset-conf   setup.conf をテンプレのデフォルトで上書き（.setup.conf.bak
                 + .env.bak にバックアップ；確認プロンプト、-y でスキップ）。
                 その後 setup を再実行。
  -y, --yes      --reset-conf の確認プロンプトをスキップ
  --no-cache     キャッシュを使わず強制リビルド
  --no-prune     ビルド成功後の自動 prune-predecessor を無効化 (#387)。デフォル
                 ト動作: 新しいビルドが同一タグの ID を更新し、旧 ID を他のタグ
                 が参照していない場合に `docker rmi` で削除 — dangling
                 `<none>:<none>` の累積を防ぎます。--no-prune は旧 image を残
                 し、ロールバック / 比較デバッグに使えます。Buildx cache は触れ
                 ません（`prune.sh --builder` を使用）。
  --clean-tools  build 終了後にローカル test-tools image を削除（デフォルトは保持）
  --dry-run      実行される docker コマンドを表示するのみ（実行はしない）
  -v, --verbose  docker の詳細出力（BUILDKIT_PROGRESS=plain）。build がハング
                 した時に使用 — 各 RUN ステップの stdout/stderr をリアルタイム
                 表示し、単一行プログレスバーに畳まれません。
  -vv, --very-verbose
                 -v に加え wrapper 自体の bash trace（set -x）。wrapper ロジック
                 のデバッグ用（稀；通常は -v で十分）。
  --lang LANG    メッセージ言語を設定（デフォルト: en）
  -t, --target TARGET
                 ビルドターゲットを指定（位置引数 [TARGET] と同義、run.sh -t と整合）。
                 両方の形式が指定された場合は最後に指定したものが有効。

ターゲット:
  devel    開発環境（デフォルト）
  test     smoke test を実行
  runtime  最小化ランタイムイメージ

検証レポート（test / <stage>-test / smoke などの検証ターゲット）:
  これらのターゲットのチェックは build layer なので、キャッシュヒットは
  結果を再現するだけで 1 ステップも実行しません。ビルド後に、検証ステー
  ジのどのステップが今回実行され、どれが CACHED だったかを報告します —
  何も検証していないビルドが合格に見えないように。報告対象はそのステージ
  自身のステップで、bats / pytest / Playwright / heredoc スクリプトのいず
  れであっても変わりません。これらのターゲットでは BUILDKIT_PROGRESS を
  plain に固定します（レポートが読む形式）。進捗ステップが 1 つもない出力
  や、状態が届かないステップは、合格として報告せず非ゼロで終了します。

環境変数:
  QUIET=1  ビルド前に表示される設定サマリーを抑止（piped / CI ログ向け）。
           setup.sh の -q/--quiet とは別物で、対象が異なります。
EOF
      ;;
    *)
      cat >&2 <<'EOF'
Usage: ./build.sh [-h] [-C|--chdir DIR] [-s|--setup] [--reset-conf] [-y|--yes] [--no-cache] [--no-prune] [--clean-tools] [--dry-run] [-v|--verbose] [-vv|--very-verbose] [--lang <en|zh-TW|zh-CN|ja>] [-t|--target TARGET] [TARGET]

Options:
  -h, --help     Show this help
  -C, --chdir DIR
                 Operate on the repo at DIR without changing the caller's cwd.
                 Mirrors git -C. Must come before other options and
                 the TARGET.
  -s, --setup    Force rerun setup.sh (opens the TUI on an interactive TTY,
                 otherwise non-interactive apply). Default (no flag):
                 auto-regenerate .env / .env.generated / compose.yaml when setup.conf /
                 Dockerfile stages / GPU / GUI / USER_UID drift (#88).
  --reset-conf   Overwrite setup.conf with template defaults (backs up the
                 existing setup.conf → .setup.conf.bak and .env → .env.bak
                 first). Prompts for confirmation; pass -y to skip. Triggers
                 a setup.sh rerun afterward so .env / .env.generated / compose.yaml follow
                 the fresh conf.
  -y, --yes      Skip the --reset-conf confirmation prompt
  --no-cache     Force rebuild without cache
  --no-prune     Disable post-build auto-prune of the displaced predecessor
                 image (#387). By default, if a successful build moves the
                 tag's image ID and the old ID is no longer referenced by
                 any other tag, build.sh runs `docker rmi <old-id>` so
                 dangling <none>:<none> images do not accumulate. Pass
                 --no-prune to keep the previous image for rollback /
                 diff-debug. Buildx cache is never touched (use
                 `prune.sh --builder` for that).
  --clean-tools  Remove the local test-tools image after build (default: keep for faster next build)
  --dry-run      Print the docker commands that would run, but do not execute
  -v, --verbose  Verbose docker output (BUILDKIT_PROGRESS=plain). Use when a
                 build appears hung — surfaces every RUN step's real-time
                 stdout/stderr instead of the collapsed single-line progress
                 UI.
  -vv, --very-verbose
                 -v plus bash trace (set -x) on the wrapper itself. For
                 debugging the wrapper's own logic (rare; -v is usually
                 enough).
  --lang LANG    Set message language (default: en)
  -t, --target TARGET
                 Build target (alias for the positional [TARGET], mirrors
                 run.sh -t). When both forms are given, last wins.

Targets:
  devel    Development environment (default)
  test     Run smoke tests
  runtime  Minimal runtime image

Verification report (test / <stage>-test / smoke targets):
  Those targets assert by RUNning their checks as build layers, so a cache
  hit reproduces the result without executing a single one. After the
  build they report which steps of the verification stage THIS run
  executed and which were CACHED, so a build that verified nothing cannot
  be read as a passing one. The stage's OWN steps are what is reported,
  whatever they run -- bats, pytest, a Playwright gate, a heredoc script.
  BUILDKIT_PROGRESS is pinned to `plain` for them (the format the report
  is read from); a build output carrying no progress steps, or a step
  whose state never arrives, exits non-zero instead of reporting a pass.
  Re-run with --no-cache to force the checks to execute.

Environment:
  QUIET=1  Mute the configuration summary printed before the build (for
           piped / CI logs). Distinct from setup.sh's -q/--quiet, which
           silences a different surface.
EOF
      ;;
  esac
  exit 0
}

main() {
  _transcript_begin  # capture this run's output (no-op if disabled)
  # shared --lang pre-pass so usage renders in the requested
  # locale even when --help precedes --lang. The main parse loop
  # below still handles --lang itself on the canonical path.
  _wrapper_lang_prepass build "$@"

  # RUN_SETUP is set here but read by _wrapper_setup_sync (lib/wrapper.sh,).
  # To the consumer devel-test stage's per-file `shellcheck -S warning` (no -x)
  # it looks unused; mark it exported (local -x) so shellcheck treats it as
  # used-externally (silences SC2034 across versions / assignment sites), while
  # the in-process sourced runtime still reads it.
  local -x RUN_SETUP=false
  local RESET_CONF=false
  local ASSUME_YES=false
  local NO_CACHE=false
  local NO_PRUNE=false
  local -a SETUP_FORWARD_ARGS=()
  local CLEAN_TOOLS=false
  local TARGET="devel"
  DRY_RUN=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        ;;
      -C|--chdir)
        # Already consumed by the file-scope pre-pass that overrides
        # FILE_PATH; skip flag + value here. The pre-pass already
        # validated DIR exists and "-C" has a value, so we can shift
        # blindly.
        shift 2
        ;;
      -s|--setup)
        RUN_SETUP=true
        shift
        ;;
      --reset-conf)
        RESET_CONF=true
        shift
        ;;
      --gui)
        # per-invocation [gui] mode override. Forwarded into
        # setup.sh apply so the resolution short-circuits before
        # _resolve_gui consumes setup.conf.
        SETUP_FORWARD_ARGS+=(--gui "${2:?--gui requires a value (auto|force|off)}")
        RUN_SETUP=true
        shift 2
        ;;
      --gui=*)
        SETUP_FORWARD_ARGS+=(--gui "${1#--gui=}")
        RUN_SETUP=true
        shift
        ;;
      --no-x11-cookie)
        # debug knob — skip SSH X11 cookie rewrite. Forces a
        # setup rerun so the resolved .env reflects the override.
        SETUP_FORWARD_ARGS+=(--no-x11-cookie)
        RUN_SETUP=true
        shift
        ;;
      -y|--yes)
        ASSUME_YES=true
        shift
        ;;
      --no-cache)
        NO_CACHE=true
        shift
        ;;
      --no-prune)
        # opt out of post-build auto-prune of the displaced
        # predecessor image. Default ON; this flag keeps the previous
        # image around for rollback / debug diffing. Never touches the
        # buildx cache (see prune.sh --builder for that).
        NO_PRUNE=true
        shift
        ;;
      --clean-tools)
        CLEAN_TOOLS=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -v|--verbose)
        # Surface every RUN step's real-time stdout/stderr in docker
        # build, instead of the collapsed BuildKit progress UI.
        # https://docs.docker.com/build/building/variables/#progress
        # Use when a build appears hung to distinguish "still doing
        # work" from "waiting on network / something else".
        export BUILDKIT_PROGRESS=plain
        shift
        ;;
      -vv|--very-verbose)
        # -v plus bash trace on the wrapper itself. For debugging the
        # wrapper's own option parsing / branching (rare; -v is enough
        # for diagnosing a hung docker build).
        export BUILDKIT_PROGRESS=plain
        set -x
        shift
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "build"
        shift 2
        ;;
      -t|--target)
        # Alias for the positional [TARGET], matching run.sh's -t.
        # When both forms are passed, last wins — same semantics as
        # repeating either form alone.
        TARGET="${2:?"-t/--target requires a value (e.g. devel, test, runtime)"}"
        shift 2
        ;;
      *)
        TARGET="$1"
        shift
        ;;
    esac
  done
  export DRY_RUN

  # --reset-conf: delegate to init.sh --gen-conf --force. Confirms unless
  # -y/--yes is passed. Backs up the existing setup.conf + .env to
  # *.bak siblings (git-ignored) before overwriting, so the reset is
  # recoverable. Runs before the normal bootstrap/drift flow below so
  # subsequent setup.sh invocation regenerates .env / .env.generated / compose.yaml from
  # the fresh conf.
  if [[ "${RESET_CONF}" == true ]]; then
    local _conf="${FILE_PATH}/.setup.conf"
    local _env="${FILE_PATH}/.env.generated"
    if [[ -f "${_conf}" || -f "${_env}" ]]; then
      if [[ "${ASSUME_YES}" != true && "${DRY_RUN}" != true ]]; then
        printf "[build] --reset-conf will overwrite:\n" >&2
        [[ -f "${_conf}" ]] && printf "  %s (backup → %s.bak)\n" "${_conf}" "${_conf}" >&2
        [[ -f "${_env}"  ]] && printf "  %s (backup → %s.bak)\n" "${_env}" "${_env}" >&2
        printf "[build] proceed? [y/N] " >&2
        local _reply
        # `read` returns non-zero on EOF (closed/non-tty stdin without
        # -y). Under `set -e` a bare `read` would abort the script HERE,
        # before the case below can map an empty reply to abort -- a
        # piped/CI invocation would die with no '[build] aborted.'
        # diagnostic. Map EOF to an empty reply so the default case
        # treats it as an explicit (safe) abort.
        read -r _reply || _reply=""
        case "${_reply}" in
          y|Y|yes|YES) ;;
          *) printf "[build] aborted.\n" >&2; exit 1 ;;
        esac
      fi
    fi
    _dry_run_cmd bash "${FILE_PATH}/.base/dist/script/base/init.sh" --gen-conf --force
    # Force a fresh setup.sh run so .env / .env.generated / compose.yaml follow.
    RUN_SETUP=true
  fi

  # shared setup/drift orchestration (build + run). Decides
  # bootstrap vs drift-regen vs interactive setup, runs setup.sh as a
  # subprocess (avoids the _msg shadow), and exits 1 if no .env was
  # produced. Reads RUN_SETUP / SETUP_FORWARD_ARGS / FILE_PATH / _LANG.
  _wrapper_setup_sync build

  # Load .env for project name. Absent in a self-managed repo (base
  # self-use): nothing to load -- the hand-authored compose.yaml
  # carries its own config and _compute_project_name falls back to defaults.
  _load_env_optional "${FILE_PATH}/.env.generated"
  _compute_project_name ""

  # Pre-build snapshot so first-time users see which files drove this
  # run and the effective image/network/GPU/GUI/TZ before docker takes
  # over the terminal. --dry-run keeps it (still useful); can be muted
  # with QUIET=1 if someone pipes this into their own CI log -- which is
  # documented in `--help` (all four locales), not only here.
  [[ "${QUIET:-0}" != "1" ]] && _print_config_summary build

  # Build test-tools image if Dockerfile exists AND caller hasn't
  # signalled it has its own test-tools provisioning via TEST_TOOLS_IMAGE.
  #
  # The downstream Dockerfile.example consumes TEST_TOOLS_IMAGE as a
  # build-arg and `FROM ${TEST_TOOLS_IMAGE}` for its lint/test stage. If
  # the caller pre-builds or pulls the image outside build.sh (CI
  # workflows do this for cache-share / rolling-tag reasons, P2), the
  # internal `docker build` here is wasted work — skip it. The caller is
  # responsible for ensuring the value of TEST_TOOLS_IMAGE resolves to a
  # runnable image (either a locally tagged tag or a registry-addressable
  # tag the docker daemon can pull on demand).
  #
  # The LOCAL tag is version-scoped by the pinned base subtree version
  # (.base/.version), mirroring the version-scoped GHCR tag CI uses
  # (ghcr.io/ycpss91255-docker/test-tools:<version>) minus the registry
  # prefix. Two base versions (or two downstream repos pinning different
  # versions) on one host therefore get two distinct tags instead of
  # silently clobbering a single, version-agnostic `test-tools:local`.
  local _tools_dockerfile="${FILE_PATH}/.base/dockerfile/Dockerfile.test-tools"
  local _tools_version_file="${FILE_PATH}/.base/.version"
  local _tools_args=()
  [[ "${NO_CACHE}" == true ]] && _tools_args+=(--no-cache)
  # Forward user's TARGETARCH override when set. Empty = leave unset so
  # BuildKit auto-fills from host/--platform (no --build-arg passed).
  if [[ -n "${TARGET_ARCH:-}" ]]; then
    _tools_args+=(--build-arg "TARGETARCH=${TARGET_ARCH}")
  fi
  # Forward [build] network when set. Empty = docker default (bridge).
  # Needed on hosts whose bridge NAT is unusable (Jetson L4T without
  # iptable_raw, daemon.json with iptables: false, firewall-locked CI).
  if [[ -n "${BUILD_NETWORK:-}" ]]; then
    _tools_args+=(--network "${BUILD_NETWORK}")
  fi
  # Resolve the effective test-tools image. Caller-pinned value wins
  # (CI passes the version-scoped GHCR tag); otherwise derive the local
  # version-scoped tag and build it.
  local _test_tools_image="${TEST_TOOLS_IMAGE:-}"
  if [[ -z "${_test_tools_image}" ]] && [[ -f "${_tools_dockerfile}" ]]; then
    local _tt_ver=""
    [[ -f "${_tools_version_file}" ]] && \
      _tt_ver="$(tr -d '[:space:]' < "${_tools_version_file}")"
    # Fail loud rather than silently falling back to a bare, version-
    # agnostic tag that could reuse another version's stale image.
    if [[ -z "${_tt_ver}" ]]; then
      _log_err build build_test_tools_version_missing \
        "display=cannot resolve base version for the local test-tools tag -- '${_tools_version_file}' missing or empty (no bare test-tools:local fallback)." \
        "file=${_tools_version_file}"
      exit 1
    fi
    _test_tools_image="test-tools:${_tt_ver}"
    if [[ "${DRY_RUN}" == true ]]; then
      printf '[dry-run] docker build'
      printf ' %q' "${_tools_args[@]}" -t "${_test_tools_image}" \
        -f "${_tools_dockerfile}" "${FILE_PATH}" -q
      printf '\n'
    else
      docker build "${_tools_args[@]}" \
        -t "${_test_tools_image}" \
        -f "${_tools_dockerfile}" \
        "${FILE_PATH}" -q >/dev/null
    fi
  fi

  # Self-managed repo (no `.base/` subtree, ADR-00000011 sec.4): there is
  # no pinned base version to scope a local tools tag by, and the repo owns
  # its tooling image itself -- its hand-authored compose.yaml declares the
  # build-only service and names the image `${TEST_TOOLS_IMAGE}` with no
  # default to fall back on. Ask THAT repo's own resolver for the tag
  # instead of deriving a second one here: the tag this build writes must
  # BE the tag its test entry runs, and two derivations that agree only by
  # luck is the failure this closes. Consumers always carry a `.base/`
  # subtree, so this never fires for them.
  local _self_resolver="${FILE_PATH}/script/test/test.sh"
  if [[ -z "${_test_tools_image}" ]] \
      && [[ ! -d "${FILE_PATH}/.base" ]] \
      && [[ -x "${_self_resolver}" ]]; then
    _test_tools_image="$("${_self_resolver}" --test-tools-image)"
  fi

  if [[ "${CLEAN_TOOLS}" == true ]]; then
    # Bake the resolved tag into a global so the atexit handler (which
    # fires after main() returns, when locals are gone) can reference it.
    _CLEAN_TOOLS_IMAGE="${_test_tools_image}"
    _cleanup() {
      [[ -n "${_CLEAN_TOOLS_IMAGE:-}" ]] || return 0
      docker rmi "${_CLEAN_TOOLS_IMAGE}" 2>/dev/null || true
    }
    # register via the transcript-owned atexit registry instead of
    # `trap ... EXIT`, which would clobber the transcript finalize.
    _atexit _cleanup
  fi

  local _compose_args=()
  [[ "${NO_CACHE}" == true ]] && _compose_args+=(--no-cache)
  # Forward the resolved test-tools image on both channels a repo can read
  # it through, because neither has a default to silently fall back on:
  #   build-arg      a consumer Dockerfile's `FROM ${TEST_TOOLS_IMAGE}`
  #   environment    a self-managed compose.yaml's `image: ${TEST_TOOLS_IMAGE}`,
  #                  which compose resolves by INTERPOLATION, where a
  #                  --build-arg never reaches
  # Empty only when the repo ships no tooling Dockerfile at all.
  if [[ -n "${_test_tools_image}" ]]; then
    _compose_args+=(--build-arg "TEST_TOOLS_IMAGE=${_test_tools_image}")
    export TEST_TOOLS_IMAGE="${_test_tools_image}"
  fi

  # snapshot the existing tag's image ID before the build, so a
  # successful rebuild that displaces the tag (`old_id != new_id`) can
  # surgically `docker rmi` the displaced layer set. The check is
  # guarded by:
  #   - first build (tag absent) → `old_id` is empty → skip
  #   - cache-hit no-op (`old_id == new_id`) → skip
  #   - `old_id` still tagged by another reference → `docker rmi` would
  #     refuse without `-f`; we detect this and skip
  #   - build failure → `set -e` aborts main before the prune block runs
  #   - `--dry-run` / `--no-prune` → print or skip
  # The buildx cache is intentionally untouched (use `prune.sh --builder`
  # for that). Tag shape mirrors run.sh's `_full_tag`.
  local _full_tag="${DOCKER_HUB_USER:-local}/${IMAGE_NAME:-local}:${TARGET}"
  local _pre_build_id=""
  if [[ "${NO_PRUNE}" != true && "${DRY_RUN}" != true ]]; then
    _pre_build_id="$(docker image inspect --format '{{.Id}}' \
      "${_full_tag}" 2>/dev/null || true)"
  fi

  # pre-build hook fires after env prep, before docker build.
  # Skipped under --dry-run.
  _run_pre_hook build "$@" || exit $?

  # A verification target's checks are BUILD LAYERS, so a cache hit
  # reproduces their result without running them -- and used to print
  # exactly what a real run printed. Capture the build output for those
  # targets and report which of the stage's steps actually executed; see
  # _report_verification_run below for why the report can fail the build,
  # and for why "which steps" is answered by the STAGE rather than by
  # guessing at what a check command looks like.
  # --dry-run runs no build, so there is nothing to report on.
  if _is_verification_target "${TARGET}" && [[ "${DRY_RUN}" != true ]]; then
    _VERIFY_LOG="$(mktemp 2>/dev/null || true)"
    if [[ -z "${_VERIFY_LOG}" || ! -f "${_VERIFY_LOG}" ]]; then
      _log_err build build_verify_capture_failed \
        "display=cannot capture the build output for target '${TARGET}': mktemp produced no file. Refusing to build without being able to report whether the checks ran." \
        "target=${TARGET}"
      exit 1
    fi
    _atexit _verify_log_cleanup
    # Pin the progress printer the report is parsed from. BuildKit's
    # `plain` mode is the one whose per-step `#<id> CACHED` / `#<id> DONE`
    # shape this wrapper reads; `auto`/`tty` renders a live display that
    # carries no such lines. Exported (not passed per-command) because it
    # has to reach the buildx invoked by compose. It also un-collapses the
    # bats output, which the default UI hides even on a real run.
    export BUILDKIT_PROGRESS=plain
    local _build_rc=0
    _compose_project build "${_compose_args[@]}" "${TARGET}" 2>&1 \
      | tee -- "${_VERIFY_LOG}" || _build_rc=$?
    [[ "${_build_rc}" -eq 0 ]] || exit "${_build_rc}"
    _report_verification_run "${TARGET}" "${_VERIFY_LOG}" || exit 1
  else
    _compose_project build "${_compose_args[@]}" "${TARGET}"
  fi

  if [[ "${NO_PRUNE}" != true && "${DRY_RUN}" != true \
      && -n "${_pre_build_id}" ]]; then
    _prune_predecessor "${_full_tag}" "${_pre_build_id}"
  elif [[ "${NO_PRUNE}" != true && "${DRY_RUN}" == true ]]; then
    # Surface the planned action under --dry-run so the user can see
    # the prune step would have fired. Tag-only message (no real IDs
    # available without a daemon round-trip).
    printf '[dry-run] docker rmi <old-id-of %s if displaced>\n' "${_full_tag}"
  fi

  # post-build hook fires at end of successful build path.
  _run_post_hook build "$@"
}

# ── verification-run reporting ────────────────────────────────────────
#
# The problem: a `-test` stage asserts by RUNning shellcheck / hadolint /
# bats as build layers. Identical inputs are a cache hit, which is
# CORRECT -- and which reproduces the stage without executing a single
# check. The wrapper printed the same thing either way, so an operator
# running the change checklist's mandatory build could read a run that
# verified nothing as a passing suite. The failure is asymmetric: it
# always reports success.
#
# What is reported is per-STEP, read from the build's own progress
# output. Two cheaper-looking mechanisms were rejected:
#
#   Comparing the tag's image ID before and after the build (the data
#   _prune_predecessor already collects) needs no parsing, but it is
#   UNSOUND for this question: with the local image absent and the buildx
#   cache warm, a fully-CACHED build produces an image where there was
#   none, which is indistinguishable from a fresh one. It also cannot see
#   a partial hit -- a re-run `bats` over a cached `shellcheck` moves the
#   ID and says nothing about the linter.
#
#   A cache-busting build ARG guarantees execution but throws the cache
#   away on every build, including the ones where nothing changed, and it
#   needs the consumer's Dockerfile to declare the ARG -- an interface an
#   already-released consumer does not have, so it would silently no-op
#   exactly where it is needed.
#
# ── What counts as a check, and who gets to say ──────────────────────
#
# The first cut of this defined a check as a RUN whose command contained
# `bats`, `hadolint` or `shellcheck`, and failed the build when a
# verification target produced none. Both halves were wrong, in opposite
# directions.
#
# Too narrow to fail on. base emits every non-blocklisted `<stage>-test`
# in a CONSUMER's Dockerfile as a compose service, so `just docker build
# e2e-test` is a supported call on a stage base has never seen. Live
# examples in this org run a Playwright suite and a CLI probe; the
# template's own documented style (a) for a `-test` stage is `RUN bash -c
# "${RUNTIME_SMOKE_CMD}"`, an ldd install-check that names none of the
# three. A heredoc `RUN <<EOF` names nothing at all -- BuildKit's vertex
# is the header line and the body never appears as a step. Every one of
# those exited 1 on a build that succeeded. base names the stage suffix
# it emits services from; it does not own what a consumer's check looks
# like, and a gate that fails an unfamiliar check is asserting that it
# does.
#
# Too broad to trust. The same scan matched the tool name wherever it
# appeared, so `apt-get install -y shellcheck` and `apk add --no-cache
# bats` read as checks that RAN. A toolchain side stage feeding the -test
# stage by `COPY --from` can re-run while every real check stays cached,
# which is exactly the "something executed" the report must not claim.
#
# So the two questions are separated. WHICH steps the report is about is
# answered by the STAGE (parsed from the progress line and previously
# discarded): a step belongs to the verification stage, or it does not.
# WHETHER they ran is answered by CACHED vs DONE, which needs no
# knowledge of the command. The tool list survives only as a hedge for a
# check sitting in a stage whose name says nothing, and as the source of
# a nicer label -- never as the definition of a check.
#
# What that gives up: base no longer fails a `-test` stage whose steps do
# nothing useful. It cannot tell the difference between a Playwright gate
# and a no-op without owning the vocabulary, so it reports what it can
# prove and says so in words. The one thing still worth a non-zero exit
# is the mechanism itself failing -- a captured output with no BuildKit
# progress in it, or a step whose state never arrived -- because silence
# there is base's own bug, not a consumer's stage.

# Check binaries base knows by name. NOT the definition of a check (see
# above): a hedge for one that lives in a stage whose name does not say
# `-test`, and the label a report line prefers when it applies.
readonly _VERIFY_TOOLS=("bats" "hadolint" "shellcheck")

# Names whose build IS a verification run. Used for two things: the
# TARGET (`./build.sh test` / `just docker build e2e-test`), and the
# STAGE label a progress line carries, which is what decides whether a
# step is one of the steps being reported on.
#
# Covers the shipped `test` / `runtime-test` stages, any `<stage>-test` a
# consumer adds, and base's own `smoke` harness
# (dockerfile/Dockerfile.smoke, whose `RUN bats` is the whole test).
# `test-tools` is deliberately NOT one -- it builds the tooling image
# `just test` and `just test smoke` both need first, and it runs no
# checks at all.
_is_verification_target() {
  case "${1-}" in
    test|smoke|*-test) return 0 ;;
  esac
  return 1
}

# _command_words_of <run-command>
#
# Prints the COMMAND word of every segment of a RUN command, one per
# line: the first word after any `VAR=x` / RUN-flag preamble and any
# `sudo`-style wrapper, with its directory prefix and a leading quote
# stripped. A word that is not plain-word-shaped (a heredoc redirect, a
# subshell opener) is skipped rather than reported.
#
# Command POSITION is the whole point. `bats` in `apk add --no-cache
# bats`, `pip install bats` and `ln -sf /opt/bats/bin/bats
# /usr/local/bin/bats` is an argument -- a package being installed, a
# path being linked -- and every one of those was read as bats running.
# Only the command word tells "runs bats" from "installs bats".
_command_words_of() {
  local _cmd="${1-}"
  # Each of these opens a new command, so what follows one is a command
  # position. Order matters: `||` has to go before the bare `|`.
  _cmd="${_cmd//&&/$'\n'}"
  _cmd="${_cmd//||/$'\n'}"
  _cmd="${_cmd//|/$'\n'}"
  _cmd="${_cmd//;/$'\n'}"
  local _seg _word _i
  local -a _words=()
  while IFS= read -r _seg; do
    # `read -a` word-splits without globbing; `set --` would expand a
    # `*.sh` argument against the wrapper's own cwd.
    read -r -a _words <<< "${_seg}"
    _i=0
    while [[ "${_i}" -lt "${#_words[@]}" ]]; do
      case "${_words[_i]}" in
        # An env assignment or a `RUN --mount=...` flag, neither of which
        # is the command; then the wrappers that take one as an argument.
        *=*|sudo|env|time|nice|command|exec) _i=$(( _i + 1 )) ;;
        *) break ;;
      esac
    done
    [[ "${_i}" -lt "${#_words[@]}" ]] || continue
    _word="${_words[_i]}"
    _word="${_word#[\"\']}"
    _word="${_word##*/}"
    [[ "${_word}" =~ ^[A-Za-z0-9_.+-]+$ ]] || continue
    printf '%s\n' "${_word}"
  done <<< "${_cmd}"
}

# _verification_tool_of <run-command>
#
# Prints the check binary a RUN step INVOKES, or returns 1. The hedge
# described above: it recognises a check whatever stage it sits in.
_verification_tool_of() {
  local _word _tool
  while IFS= read -r _word; do
    for _tool in "${_VERIFY_TOOLS[@]}"; do
      if [[ "${_word}" == "${_tool}" ]]; then
        printf '%s\n' "${_tool}"
        return 0
      fi
    done
  done < <(_command_words_of "${1-}")
  return 1
}

# _step_stage_of <progress-label>
#
# The stage a `#<id> [<label>] RUN ...` line belongs to. The label is
# `devel-test  8/16`, or `linux/arm64 devel-test 8/16` on a
# multi-platform build, so the stage is the token in front of the step
# counter.
_step_stage_of() {
  local _label="${1-}"
  if [[ "${_label}" =~ ^(.*[[:space:]])?([^[:space:]]+)[[:space:]]+[0-9]+/[0-9]+[[:space:]]*$ ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
    return 0
  fi
  # No counter (BuildKit does not print one for every vertex shape).
  printf '%s\n' "${_label##* }"
}

# _is_check_step <stage> <run-command>
#
# Whether a RUN step is one of the steps this report is about: it belongs
# to a verification stage, or it invokes a check binary wherever it sits.
# Everything else -- the base image's own installs, a toolchain side
# stage feeding the -test stage by `COPY --from` -- is out of scope, and
# keeping it out is what stops an unrelated re-run reading as "a check
# executed".
_is_check_step() {
  if _is_verification_target "${1-}"; then
    return 0
  fi
  if _verification_tool_of "${2-}" > /dev/null; then
    return 0
  fi
  return 1
}

# _step_label_of <stage> <run-command>
#
# What a report line calls this step: the command it invokes (`bats`,
# `pytest`, `npm`, and yes `apt-get` when that is what the stage runs),
# falling back to the stage name when the command has no plain command
# word -- a heredoc RUN, whose body BuildKit never shows. Naming the
# command word rather than a classification is what makes the line
# checkable against the Dockerfile by eye.
_step_label_of() {
  local _word=""
  read -r _word < <(_command_words_of "${2-}") || true
  printf '%s\n' "${_word:-${1:-step}}"
}

# _scan_verification_steps <log> <cached-outvar> <ran-outvar> <pending-outvar>
#
# Classifies every verification step in a captured BuildKit `plain`
# progress log into three name lists. The shapes read are:
#
#   #7 [devel-test 16/16] RUN bats /smoke_test/      <- the step
#   #7 CACHED                                        <- reused
#   #7 DONE 3.1s                                     <- executed
#
# (the leading number is BuildKit's step id, kept single-digit here so
# the example does not read as a transient issue ref, ADR-00000013)
#
# A step announced but never resolved lands in <pending>, which the
# caller treats as an error: neither "cached" nor "ran" is provable, so
# neither is claimed.
_scan_verification_steps() {
  local _log="${1:?_scan_verification_steps requires <log>}"
  local -n _svs_cached="${2:?_scan_verification_steps requires <cached-outvar>}"
  local -n _svs_ran="${3:?_scan_verification_steps requires <ran-outvar>}"
  local -n _svs_pending="${4:?_scan_verification_steps requires <pending-outvar>}"
  _svs_cached=()
  _svs_ran=()
  _svs_pending=()

  local -A _cmd=()
  local -A _stage=()
  local -A _state=()
  local _line _id _rest _label
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    [[ "${_line}" =~ ^[[:space:]]*#([0-9]+)[[:space:]](.*)$ ]] || continue
    _id="${BASH_REMATCH[1]}"
    _rest="${BASH_REMATCH[2]}"
    if [[ "${_rest}" =~ ^\[([^]]*)\][[:space:]]+RUN[[:space:]]+(.*)$ ]]; then
      # Both captures read before anything else can touch BASH_REMATCH.
      _label="${BASH_REMATCH[1]}"
      _cmd["${_id}"]="${BASH_REMATCH[2]}"
      _stage["${_id}"]="$(_step_stage_of "${_label}")"
    elif [[ "${_rest}" == "CACHED" ]]; then
      _state["${_id}"]="cached"
    elif [[ "${_rest}" == DONE\ * ]]; then
      _state["${_id}"]="ran"
    fi
  done < "${_log}"

  # Sorted by step id so the report reads in Dockerfile order and two
  # runs of the same build produce the same text (bash iterates an
  # associative array in hash order, which is neither).
  local _name
  while IFS= read -r _id; do
    [[ -n "${_id}" ]] || continue
    _is_check_step "${_stage[${_id}]:-}" "${_cmd[${_id}]}" || continue
    _name="$(_step_label_of "${_stage[${_id}]:-}" "${_cmd[${_id}]}")"
    case "${_state[${_id}]:-}" in
      cached) _svs_cached+=("${_name}") ;;
      ran)    _svs_ran+=("${_name}") ;;
      *)      _svs_pending+=("${_name}") ;;
    esac
  done < <(printf '%s\n' "${!_cmd[@]}" | sort -n)
}

# _log_has_progress <log>
#
# Whether the captured output contains BuildKit progress steps at all.
# This is what separates "the stage's steps are all accounted for and
# none of them is a check" -- a fact about the consumer's Dockerfile,
# which base reports and does not judge -- from "the format this report
# is read from is not there", which is base's own mechanism failing.
_log_has_progress() {
  grep -Eq '^[[:space:]]*#[0-9]+[[:space:]]' -- "${1:?_log_has_progress requires <log>}"
}

# _join_tools <name>...
#
# Renders a step-name list for the human-readable half of a report line.
# The `<key>=` attributes keep the raw space-separated form; only the
# prose is punctuated.
#
# Repeats are collapsed to `<name> x<n>`. A stage that runs the same
# command twice, or two heredoc steps that both fall back to the stage
# name, would otherwise render as `field-test, field-test`, which reads
# as a bug in the report rather than as two steps.
_join_tools() {
  local -A _seen=()
  local -a _order=()
  local _out="" _name
  for _name in "$@"; do
    if [[ -z "${_seen[${_name}]:-}" ]]; then
      _order+=("${_name}")
      _seen["${_name}"]=0
    fi
    _seen["${_name}"]=$(( _seen["${_name}"] + 1 ))
  done
  for _name in ${_order[@]+"${_order[@]}"}; do
    if [[ "${_seen[${_name}]}" -gt 1 ]]; then
      _out+="${_out:+, }${_name} x${_seen[${_name}]}"
    else
      _out+="${_out:+, }${_name}"
    fi
  done
  printf '%s\n' "${_out}"
}

# _report_verification_run <target> <log>
#
# Says what happened, and returns non-zero when it cannot.
#
# The two failing branches are the mechanism refusing to speak for
# itself, and they are the only two. An output with no BuildKit progress
# in it, or a step whose state never arrived, is not evidence of
# anything, so it is an error rather than a quiet pass -- which is also
# what bounds the fragility of reading BuildKit's output: if the format
# moves, this stops the gate loudly instead of resuming the
# silent-success behaviour being fixed.
#
# The two branches that deliberately do NOT fail are where base would be
# judging a tree it does not own. A fully cached run is correct -- cache
# hits are the point of a cache, and failing them would break every
# warm-cache CI build -- so it is a WARNING that says in words that this
# build verified nothing. A readable build whose verification stage
# holds no RUN step is the same shape one level down: base can say that
# nothing was checked, and cannot say that the stage is worthless.
_report_verification_run() {
  local _target="${1:?_report_verification_run requires <target>}"
  local _log="${2:?_report_verification_run requires <log>}"
  local -a _cached=() _ran=() _pending=()
  _scan_verification_steps "${_log}" _cached _ran _pending
  local _cached_txt _ran_txt _pending_txt
  _cached_txt="$(_join_tools "${_cached[@]}")"
  _ran_txt="$(_join_tools "${_ran[@]}")"
  _pending_txt="$(_join_tools "${_pending[@]}")"

  local _total=$(( ${#_cached[@]} + ${#_ran[@]} + ${#_pending[@]} ))
  if [[ "${#_pending[@]}" -gt 0 ]]; then
    _log_err build build_verify_step_unresolved \
      "display=cannot tell whether target '${_target}' verified anything: ${#_pending[@]} of its verification stage's step(s) (${_pending_txt}) reported neither CACHED nor DONE. Refusing to report a pass on an unreadable build output -- re-run with -v and read it." \
      "target=${_target}" "pending=${_pending[*]}"
    return 1
  fi
  if [[ "${_total}" -eq 0 ]]; then
    if ! _log_has_progress "${_log}"; then
      _log_err build build_verify_capture_failed \
        "display=cannot tell whether target '${_target}' verified anything: the captured build output carries no BuildKit progress steps at all, so the format this report is read from has moved or the output never arrived. Refusing to report a pass on a build output that cannot be read -- re-run with -v and read it." \
        "target=${_target}"
      return 1
    fi
    _log_warn build build_verify_no_steps \
      "display=verification: target '${_target}' built with no step of its own -- its verification stage ran no RUN instruction, so this build is not evidence that anything was checked. If the stage does verify, it does so somewhere this report cannot see." \
      "target=${_target}"
    return 0
  fi
  if [[ "${#_ran[@]}" -eq 0 ]]; then
    _log_warn build build_verify_all_cached \
      "display=verification: all ${_total} step(s) of target '${_target}'s verification stage were CACHED (${_cached_txt}) -- nothing ran in this invocation, so this build is not evidence that the checks pass. Re-run with --no-cache to execute them." \
      "target=${_target}" "cached=${_cached[*]}"
    return 0
  fi
  if [[ "${#_cached[@]}" -gt 0 ]]; then
    _log_warn build build_verify_partly_cached \
      "display=verification: target '${_target}' executed ${#_ran[@]} of its verification stage's ${_total} step(s) (${_ran_txt}); cached: ${_cached_txt} -- this build is not evidence about the cached ones." \
      "target=${_target}" "ran=${_ran[*]}" "cached=${_cached[*]}"
    return 0
  fi
  _log_info build build_verify_all_ran \
    "display=verification: target '${_target}' executed all ${_total} step(s) of its verification stage (${_ran_txt})." \
    "target=${_target}" "ran=${_ran[*]}"
}

# Removes the captured build log. Registered with _atexit (not `trap ...
# EXIT`, which would clobber the transcript finalize) so a failed build
# does not leave one behind.
_verify_log_cleanup() {
  [[ -n "${_VERIFY_LOG:-}" ]] || return 0
  rm -f -- "${_VERIFY_LOG}"
}

# _prune_predecessor removes the displaced predecessor image after a
# successful build, IFF (a) the tag's ID actually moved AND (b) no other
# tag still references the old ID. Wrapped in `|| true` so a transient
# daemon error never bubbles up after a successful build.
#
# Args:
#   $1 _full_tag      the rebuilt tag (e.g. user/image:devel)
#   $2 _pre_build_id  the image ID this tag pointed at before the build
_prune_predecessor() {
  local _full_tag="${1:?_prune_predecessor requires _full_tag}"
  local _pre_build_id="${2:?_prune_predecessor requires _pre_build_id}"
  local _post_build_id
  _post_build_id="$(docker image inspect --format '{{.Id}}' \
    "${_full_tag}" 2>/dev/null || true)"
  # Build produced no image (compose `build` is a no-op when the
  # service has no Dockerfile, etc.) → nothing to compare against.
  [[ -z "${_post_build_id}" ]] && return 0
  # Cache-hit / no-op rebuild → same ID, nothing to prune.
  [[ "${_pre_build_id}" == "${_post_build_id}" ]] && return 0
  # If the pre-build ID still has any other tag pointing to it, leave
  # it alone — `docker rmi <id>` would refuse without -f, and a force
  # delete would unexpectedly untag the alias. Filter excludes the
  # `<none>:<none>` self-entry produced by docker images when the ID
  # has no tags besides ours.
  local _other_tags
  _other_tags="$(docker images --format '{{.Repository}}:{{.Tag}}' \
    --filter "reference=${_pre_build_id}" 2>/dev/null \
    | grep -v '^<none>:<none>$' || true)"
  if [[ -n "${_other_tags}" ]]; then
    _log_info build build_prune_skip_tagged "display=skip prune: predecessor still tagged (${_other_tags})" "tags=${_other_tags}"
    return 0
  fi
  _log_info build build_prune_displaced "display=pruning displaced predecessor ${_pre_build_id:7:12}" "image_id=${_pre_build_id:7:12}"
  docker rmi "${_pre_build_id}" >/dev/null 2>&1 || true
}

main "$@"
