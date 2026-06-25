# TEST.md

Template self-tests: **2062 tests** total (1977 unit + 85 integration).

> Counted scope is the `just test` self-test suite —
> what runs in the `Self Test` CI job. The 36 shared smoke tests under
> `test/smoke/` are a separate suite that runs at Dockerfile `test`-stage
> build time (via `./build.sh test`) inside both this repo and every
> downstream repo, and are documented in [Smoke Tests](#smoke-tests)
> below. They are **not** included in the 1080 figure because they are
> build-time assertions, not self-tests.

## Test Files

### test/bats/unit/lib_spec.bats (45)

| Test | Description |
|------|-------------|
| `_resolve_lang sets 'en' when LANG is unset (#568)` | Default language |
| `_resolve_lang sets 'zh-TW' for zh_TW.UTF-8 (#568)` | Traditional Chinese |
| `_resolve_lang sets 'zh-CN' for zh_CN.UTF-8 (#568)` | Simplified Chinese |
| `_resolve_lang sets 'zh-CN' for zh_SG (Singapore) (#568)` | Singapore variant |
| `_resolve_lang sets 'ja' for ja_JP.UTF-8 (#568)` | Japanese |
| `_resolve_lang honors SETUP_LANG override (#568)` | Env override |
| `_lib.sh does NOT set _LANG at source time (#568 Part B)` | Load-time side-effect removed |
| `conf_logging.sh self-sources its conf.sh dependency in isolation (#568)` | Self-sourcing (load order not load-bearing) |
| `_lib.sh is idempotent when sourced twice` | Double-source guard |
| `_load_env exports variables from a .env file` | Env loader works |
| `_load_env round-trips shell-hostile values verbatim (no exec, no split) (#689)` | %q-quoted hostile value loads literally (no command-sub / word-split) |
| `_load_env aborts under set -euo pipefail when the file does not exist (#689)` | Missing-file error path (no `[[ -f ]]` guard) |
| `_load_env errors when no path is given` | Required arg check |
| `_compute_project_name produces clean PROJECT_NAME (single-instance #600)` | Project name (single-instance) |
| `_compose with DRY_RUN=true prints command instead of running` | DRY_RUN path |
| `_compose without DRY_RUN tries to invoke docker compose (sanity)` | Real-call branch |
| `_compose_project pre-fills -p / -f / --env-file from PROJECT_NAME and FILE_PATH` | Project wrapper |
| `_sanitize_lang accepts en / zh-TW / zh-CN / ja unchanged` | Lang validator pass-through |
| `_sanitize_lang warns and falls back to 'en' for unsupported values` | Unknown lang fallback |
| `_sanitize_lang warns for the old bare 'zh' code (post zh→zh-TW rename)` | Legacy lang rejection |
| `_dump_conf_section extracts keys from the named section` | INI section dump |
| `_dump_conf_section stops at the next section header` | Section boundary |
| `_dump_conf_section returns silent empty for missing file` | Missing file |
| `_dump_conf_section returns silent empty for unknown section` | Missing section |
| `_print_config_summary prints files, identity, all populated sections, resolved` | Full config dump |
| `_print_config_summary prints Variables block mapping setup.conf placeholders to detected values` | Variables block populated |
| `_print_config_summary Variables block falls back to '-' for unset values` | Variables fallback |
| `_print_config_summary hides sections that are empty in setup.conf` | Empty-section skip |
| `_print_config_summary warns when setup.conf is missing` | Missing-conf hint |
| `_print_config_summary warns when setup.conf exists but has no [section] headers` | #157 empty-conf hint on build/run summary |
| `_print_config_summary wraps dividers + section headers in ANSI when FORCE_COLOR=1 (#309)` | Color migration via _log_plain |
| `_print_config_summary omits ANSI when NO_COLOR=1 overrides FORCE_COLOR=1 (#309)` | NO_COLOR precedence on summary |

### test/bats/unit/log_spec.bats (69)

OTel-aligned logger (#423, #438). Single-sink tty-detect dispatch,
`LOG_FORMAT=auto|text|json` override, strict body enforcement (unregistered
body = fatal), `display=` attribute for i18n text in text mode, UTC
microsecond timestamps, `_log_plain` removed.

| Category | Tests |
|----------|-------|
| Text output format (`LOG_FORMAT=text`): timestamp + aligned level + tag, multi-token join, attr=val skip, `display=` override | 10 |
| Timestamp: UTC with microsecond precision in both text and JSON | 2 |
| Stream routing: stdout for INFO/DEBUG, stderr for WARN/ERROR/FATAL | 2 |
| Single-sink tty-detect dispatch (#438): non-TTY auto JSON, `LOG_FORMAT=text` force, `LOG_FORMAT=json` force, `LOG_FORMAT=auto` equiv | 5 |
| Startup TTY cache `_LOG_IS_TTY` (#605): helper defined + cached-0/cached-nonzero/unset-fallback; auto-format honours cache + unset-identity; explicit `LOG_FORMAT` bypasses cache; `_log_color_enabled` cache read + NO_COLOR/FORCE_COLOR precedence over cache | 12 |
| JSON escaping (`_log_json_escape`, #691): quote / lone-backslash double / newline+tab+CR / substitution order; live `_log_info` attr value with quote+backslash+tab stays well-formed | 5 |
| JSON output: OTel fields, custom attributes, severity numbers, per-line structure | 4 |
| TRACEPARENT in JSON: trace_id/span_id present/absent | 2 |
| Strict body enforcement (#438): unregistered fatal, registered OK, empty OK, error names body + file | 4 |
| Missing service rejected, `_log_fatal` does not auto-exit | 3 |
| Scoped wrappers: `_log_with_trace` save/restore, `_log_with_span` trace_id | 4 |
| `_log_plain` removed (#438) | 1 |
| `_log_color_enabled`: TTY detect, FORCE_COLOR, NO_COLOR precedence | 3 |
| FORCE_COLOR text: red bold ERROR, yellow WARN, NO_COLOR strips | 3 |
| Event registry: registered/unregistered/comment detection | 3 |
| lnav format file | 2 |

### test/bats/unit/transcript_spec.bats (31)

Wrapper transcript capture (#606) + interactive orchestration capture
(#608): tees a verb's combined output to `log/<verb>/<ts>-<traceid8>.log`
(ANSI stripped) with a per-verb `latest.log` symlink, an
exit-code+duration closing line, retention, and an `_atexit` registry
that owns the single EXIT trap. Interactive verbs (run / exec / setup_tui)
capture the orchestration phase then `_transcript_detach` before the
session. Pure helpers are unit-tested; the tee + EXIT-finalize + detach
are exercised end-to-end by running a tiny harness in a subshell.
Activation is execution-only (`_transcript_begin` in each verb's
`main()`), never at source time.

| Category | Tests |
|----------|-------|
| `_transcript_is_full_verb`: 5 captured verbs / interactive + unknown not | 2 |
| `_transcript_is_interactive_verb` + `_transcript_is_capture_verb` classification (#608) | 2 |
| `_transcript_filename` path shape; `_transcript_meta_line` lnav-parseable format | 2 |
| `_transcript_resolve_traceid`: inherits TRACEPARENT trace_id / generates 32-hex | 2 |
| `_transcript_enabled`: default true / `wrapper_transcript=false` kill switch; `WRAPPER_TRANSCRIPT` env override wins over conf both ways (#622) | 4 |
| `_atexit`: registered callbacks run LIFO on exit | 1 |
| `_transcript_prune`: keep-N-most-recent + drop-older-than-D-days | 2 |
| `_transcript_prune` keep=0 wipes all + read-side guard rejects hand-edited `wrapper_transcript_keep=0` (falls back to 20) (#691) | 2 |
| Degrade-to-no-op failure branches (#691): mkdir-fail / raw-file-unwritable / tee-missing each WARN + return 0, wrapper continues | 3 |
| Non-zero wrapper exit recorded (`transcript_complete exit_code=7`) AND propagated to caller (#691) | 1 |
| End-to-end: file produced with combined content; ANSI stripped in file (colour on terminal); exit-code+duration line; `latest.log` symlink; `wrapper_transcript=false` no-op | 5 |
| `_transcript_detach` (#608): no-detach full-captures (run -d path); detach captures orchestration only (`transcript_detached`, not the session); no-op when never begun | 3 |
| Wiring guards: 5 full verbs call `_transcript_begin`; run/exec/setup_tui call begin + detach | 2 |

### test/bats/unit/transcript_lnav_spec.bats (8)

Regex-type lnav format for the plain-text wrapper transcript
(`transcript.lnav-format.json`, #609): parses `<ISO ts> [service] LEVEL:
msg` lines, coexisting with the JSON `log.lnav-format.json` (`*.jsonl`).
The CI image has no jq/lnav, so it is checked structurally (grep) +
functionally (the embedded regex, extracted and JSON-unescaped, must
match real transcript lines and the 5 levels via `grep -P`).

| Category | Tests |
|----------|-------|
| Declares the lnav schema + format key; is a regex format (not json) | 2 |
| Maps all 5 levels; timestamp/level/body fields + `log/` file-pattern wired | 2 |
| Regex matches real transcript lines incl. all 5 levels; raw docker line does NOT match | 2 |
| Every declared sample matches the pattern | 1 |
| `log.lnav-format.json` (JSON) still coexists unchanged | 1 |

### test/bats/unit/schema_spec.bats (26)

Covers the setup.conf validation registry (`lib/schema.sh`, #560): the
single `_schema_validate <section> <key> <value>` gate that both
setup.sh (`set` / `add`) and the TUI route through. Verifies registry
dispatch (scalar exact-match + numbered-list prefix normalisation),
per-service `[logging.<svc>]` section normalisation, the empty-value
policy (default allow / clear; `deploy.gpu_count` rejects empty), and
the full union of validated keys -- including the keys that were
historically free-form in setup.sh (`build.network` / `build.arg_` /
`deploy.gpu_runtime` + `runtime` alias / `network.network_name` /
`devices.device_` / `security.cap_add_` / `cap_drop_`). Phase 2 (#561)
adds the section-list single source: `SCHEMA_SECTIONS` (ordered list),
`_schema_is_section` (membership), `_schema_section_keys` (a section's
registered keys derived from `SCHEMA_VALIDATOR`).

| Test | Description |
|------|-------------|
| `routes network.port_N to _validate_port_mapping (accept/reject)` | list prefix dispatch |
| `routes deploy.gpu_count to _validate_gpu_count (accept/reject)` | scalar dispatch |
| `rejects empty deploy.gpu_count (empty policy = validate)` | empty exception |
| `routes logging.driver to _validate_log_driver (accept/reject)` | logging scalar |
| `allows empty logging.driver (empty policy = allow)` | empty default |
| `normalises logging.<svc> to the logging key set (accept/reject)` | per-service section |
| `accepts every registered key's valid sample` | union coverage (accept) |
| `rejects every registered key's invalid sample` | union coverage (reject) |
| `allows empty (clear) for every list + clearable scalar key` | clear-key semantics |
| `accepts free-form (unregistered) keys` | default-accept |
| `SCHEMA_SECTIONS lists every setup.conf section in file order` | ordered section list (#561) |
| `_schema_is_section accepts a registered section with typed keys` | membership accept (#561) |
| `_schema_is_section accepts a free-form-only section (image)` | membership accept, no keys (#561) |
| `_schema_is_section rejects an unknown section` | membership reject (#561) |
| `_schema_is_section rejects a per-service logging variant` | logging.<svc> not a base section (#561) |
| `_schema_is_section tracks SCHEMA_SECTIONS additions` | single source (#561) |
| `_schema_section_keys returns scalar+list keys for build` | keys by prefix (#561) |
| `_schema_section_keys returns all logging keys` | keys by prefix (#561) |
| `_schema_section_keys returns deploy keys incl. legacy alias` | keys incl. runtime alias (#561) |
| `_schema_section_keys is empty for a free-form-only section (image)` | empty for no-validator section (#561) |

### test/bats/unit/schema_coverage_spec.bats (8)

Registry drift guards (#562, schema epic #559 phase 3): the registry
must stay internally consistent and in sync with the `setup.conf`
template, so drift fails CI. The deferred i18n coverage now lands via the
`SCHEMA_I18N` index column (#591): every registered key maps to a TUI
message key (or an explicit `""` opt-out for keys with no editor), and
every mapped key is present in all four locale tables (en / zh-TW /
zh-CN / ja) -- a missing translation in any locale fails CI.

| Test | Description |
|------|-------------|
| `every SCHEMA_VALIDATOR validator name resolves to a defined function` | no ghost validators (#562) |
| `SCHEMA_SECTIONS matches the setup.conf template headers in file order` | registry/template drift (#562) |
| `every SCHEMA_EMPTY key is a registered SCHEMA_VALIDATOR key` | no dead empty-policy entries (#562) |
| `every registered key is reachable via SCHEMA_SECTIONS` | no key stranded under an unlisted section (#562) |
| `every SCHEMA_VALIDATOR key has a SCHEMA_I18N index entry` | i18n-index is complete (#591) |
| `every SCHEMA_I18N key is a registered SCHEMA_VALIDATOR key` | no orphan index rows (#591) |
| `every SCHEMA_I18N message key exists in all four locale tables` | no missing translation in any locale (#591) |
| `_schema_i18n_key resolves scalar + list keys, falls back when free-form` | accessor the TUI routes through (#591) |

### setup.sh unit specs (378, split by concern)

The setup.sh unit suite was split from a single 371-test
`setup_spec.bats` into five cohesive `*_spec.bats` files (refs #377,
#677) so the CI bats-unit + coverage round-robin — which shards BY FILE
— can balance the per-shard floor. All five share one
`setup_spec_helper.bash` (common `setup()` / `teardown()`); behaviour
and total test count are unchanged.

#### test/bats/unit/setup_spec.bats (146)

Core detection (user / hardware / docker / GPU / GUI), SSH X11
forwarding (`_is_ssh_x11` / `_setup_ssh_x11_cookie`, #321), the INI
parser (`_parse_ini_section` + shared core `_ini_tokenize`), setup.conf
merging (`_load_setup_conf` replace strategy), `_get_conf_value` /
`_get_conf_list_sorted`, resolvers (`_resolve_gpu` / `_resolve_gui` /
`_resolve_runtime` / `_resolve_build_network`), `detect_image_name`
rule engine, `detect_ws_path`, `_compute_conf_hash`, `write_env`,
`_check_setup_drift`, the `main --lang` / error paths, plus the
template-shipped defaults for `[lifecycle]` restart (#478), `[deploy]`
`dri_groups` (#496) and `gpu_runtime` alias (#481),
`[additional_contexts]` (#199), `[logging]` CLI (#328),
`_setup_known_section` / `SCHEMA_SECTIONS` (#561), and `[security]`
opt-in (#466).

#### test/bats/unit/setup_subcommand_spec.bats (65)

The git-style subcommand dispatcher and its mutating verbs (#49):
dispatch (Phase B-1), `set` / `show` / `list` (Phase B-2), `add` /
`remove` (Phase B-3), and `reset` + BREAKING no-arg → help (Phase B-4)
— round-trips, validators, no-`.env`-regen, comment preservation, and
end-to-end subprocess cases.

#### test/bats/unit/setup_emit_spec.bats (78)

`apply`-time emit and CLI-flag behaviour: `.env.generated` cache + `.env`
workload overlay (#502), `_generate_runtime_dockerfile` ENV-bake (#503),
`config/app/` dev bind-mount (#504), `_rule_basename` /
`detect_image_name` sanitization, i18n (`_msg` / `_detect_lang`),
`[build]` `arg_N`, `_get_conf_list_sorted` empty-skip, workspace
writeback, `--quiet` confirmation lines (#285), `--gui` /
`--no-x11-cookie` / `--print-resolved` apply flags (#338), `#450`
propagation + duplicate-target guards, S7 `runtime.env` retirement
(#507), and `_reconcile_workspace_path` (#569).

#### test/bats/unit/setup_section_validate_spec.bats (38)

Per-section setup.conf parameter end-to-end coverage (#202): one key per
test asserted through to `compose.yaml` / `.env`, across `[deploy]`,
`[gui]`, `[network]`, `[resources]`, `[environment]`, `[tmpfs]`,
`[devices]`, `[volumes] mount_2..N`, and `[security]` privileged, with
companion negatives for cleared keys.

#### test/bats/unit/setup_stage_override_spec.bats (58)

The per-stage override engine: `_validate_stage_name` (#215),
`_parse_dockerfile_stages`, `_compute_dockerfile_hash`, `main apply`
auto-emit of non-baseline stages (#215), and per-stage overrides #220
(`_parse_stage_sections` / `_load_stage_overrides` /
`_validate_stage_override_key` / `_resolve_stage_scalar` /
`_resolve_stage_list` + compose-emit integration, incl. #493
`devel-test` override surface).

### test/bats/unit/tui_spec.bats (131)

Pure-logic unit tests for the TUI support libraries (`_tui_conf.sh`).
No dialog/whiptail invocations here — strictly validators, mount-string
parsers, and setup.conf round-trip.

| Category | Tests |
|----------|-------|
| `_validate_mount` (valid forms, env-var expansion, reject missing/extra colons, invalid mode) | 8 |
| `_validate_gpu_count` ('all', positive int, reject 0/negative/non-numeric/empty) | 6 |
| `_validate_enum` (match, non-match, empty) | 3 |
| `_mount_host_path` (plain, with mode, with env-var host) | 3 |
| `_load_setup_conf_full` + `_write_setup_conf` (section order, kv, comment preservation, untouched keys, round-trip, dst==tpl regression #187) | 6 |
| `_upsert_conf_value` (updates existing, leaves other sections untouched) | 2 |
| `_edit_image_rule __remove` index compaction (#177) — first / middle / last / sole rule | 4 |
| `_validate_additional_context` (#199: relative paths, BuildKit schemes, name punctuation, reject empty / missing pieces, reject invalid name shapes) | 5 |
| Per-stage `[stage:NAME]` round-trip (#220: namespaced load, append new section, multi-section append, round-trip, in-place update of existing section) | 5 |
| `_validate_log_*` (#328: driver name shape, max_size num+unit, max_file positive int, compress boolean; covers happy paths + rejection of empty / whitespace / wrong unit / decimals / case mismatches) | 7 |
| `_edit_section_lifecycle` (#514: restart radiolist writes simple policy + default no; on-failure:N assembly; empty-N -> bare on-failure; invalid-N re-prompt then accept) | 5 |
| `_edit_section_deploy` legacy runtime->gpu_runtime migration (#517: suggest msgbox when legacy [deploy] runtime present; silent when gpu_runtime already used; writes canonical gpu_runtime key) | 3 |
| `_show_runtime_env_info` (#497: info-only msgbox points at the .env overlay; writes no override) | 1 |

### test/bats/unit/tui_backend_spec.bats (28)

Backend detection and wrapper-level arg forwarding. Uses a stub
`dialog` / `whiptail` binary installed on PATH that logs argv and echoes
a canned response; exercised with `TUI_STUB_RESPONSE` / `TUI_STUB_EXIT`.

| Category | Tests |
|----------|-------|
| `_backend_detect` (prefers dialog, falls back to whiptail, prints install hint when neither) | 3 |
| `_tui_guard` (rejects empty backend) | 1 |
| `_tui_inputbox` (forwards title/prompt/initial, returns canned response, propagates non-zero on cancel) | 2 |
| `_tui_menu` (computes item count, forwards tag/label pairs; `TUI_EXTRA_LABEL` no-op after #178; `--no-tags`, `--ok-label`) | 1 |
| `_tui_radiolist` (forwards tag/label/state triples) | 1 |
| `_tui_checklist` (passes `--separate-output`) | 1 |
| `_tui_msgbox` / `_tui_yesno` (correct flags, propagates exit code) | 2 |
| whiptail flag-spelling translation (#136: `--ok-button` / `--cancel-button` instead of `--*-label`, no `--extra-button`) + Save-button unification (#178: dialog also drops `--extra-button`) | 6 |

### test/bats/unit/tui_flow.bats (105)

Interactive-flow tests for `setup_tui.sh` (#189). Sources `setup_tui.sh`
directly and overrides `_tui_menu` / `_tui_select` / `_tui_inputbox` /
`_tui_yesno` / `_tui_msgbox` / `_tui_radiolist` / `_tui_checklist` with
file-backed stubs (queue lines popped via `head -n 1` + `sed -i 1d` so
state survives the `$(...)` subshell calls). Each case scripts the
user's click path, calls one section editor, and asserts on the
resulting `_TUI_OVR_*` / `_TUI_REMOVED` / `_TUI_CURRENT` arrays — no
real `dialog` / `whiptail` ever launches. Lifts `setup_tui.sh`
per-file coverage from 18% to 83% by exercising the 5 high-value
target areas the issue body called out.

| Category | Tests |
|----------|-------|
| `_load_current` (repo-conf wins; falls back to template; both missing → silent return 0) | 3 |
| `_render_main_menu` / `_render_advanced_menu` (#178 Save & Exit unification, Cancel/Esc returns 1, navigation into section editor) | 5 |
| `_edit_image_rule` (#177 site: add string/prefix/suffix/basename/default, Cancel from radiolist or inputbox, `__remove`/`__move_up`/`__move_down`, dedupe drops duplicate slot) | 11 |
| `_compact_image_rules_after_remove` (mid-list shift down, last drop, empty no-op, sparse-slot collapse) | 4 |
| `_swap_image_rule` (both occupied / target empty / source empty / both empty / m<1) | 5 |
| `_edit_list_section` via `_edit_section_environment` (env_ add/edit/remove, invalid → msgbox+retry, max+1 indexing, Cancel/Esc) | 7 |
| `_edit_section_image` top-level dispatch (add max+1, click rule_N, Back) | 3 |
| `_edit_section_network` (host+host+pid no shm prompt, bridge prompts name+ports, ipc=private prompts shm, empty network_name allowed) | 4 |
| `_edit_section_deploy` (off short-circuits — only writes gpu_mode) | 1 |
| Multi-section dispatch from main menu (network → host → save) | 1 |
| Per-stage UI #220 (`_list_dockerfile_stages_available` from-Dockerfile + baseline filter, `_count_stage_overrides` OVR+CURRENT dedup + empty skip, `_edit_stage_gui` mode + __inherit, `_edit_stage_scalar` write + empty-clears, `_edit_stage_list` inherit toggle + add) | 10 |
| Menu restructure #221 (i18n keys for main.runtime/mounts/features × 4 langs; `_render_runtime_menu` / `_render_mounts_menu` / `_render_features_menu` function existence; main-menu dispatch for image/build/runtime/mounts/features + bare network/deploy/gui/volumes/environment no longer dispatch from main; Runtime sub-menu dispatch for network/deploy/gui/environment + __back/Cancel; Mounts sub-menu dispatch for volumes/devices/tmpfs + __back/Cancel; Features sub-menu __back, per_stage enabled enters editor, per_stage hidden shows msgbox without entering editor; Advanced sub-menu image/build/devices/tmpfs entries removed, security still dispatches) | 31 |
| #328 logging menu dispatch (Runtime menu's `logging` entry calls `_edit_section_logging`; `_edit_section_logging`'s top-level menu routes `global` to `_edit_logging_keys logging` and `devel` / `test` / `runtime` to `_edit_logging_keys logging.<svc>`) | 5 |
| #561 `_tui_known_subcommand` derives CLI direct-jump subcommands from `SCHEMA_SECTIONS` (accepts every section + `ports` pseudo-section, rejects unknown args, tracks `SCHEMA_SECTIONS` additions) | 4 |

### test/bats/unit/build_worker_yaml_spec.bats (37)

Structural assertions for `.github/workflows/build-worker.yaml` (#195
+ #243 + #272 + #273 + #378 b1). Reusable workflows are not exec'd by
these tests; instead grep patterns lock the YAML invariants —
`context_path` / `dockerfile_path` inputs declared with the right
defaults, all 4 `docker/build-push-action` steps (devel-test / devel /
runtime-test / runtime after #243) forwarding those inputs, no
leftover `context: .` / `file: ./Dockerfile` literals, the GHA-cache
plumbing (#272: `cache_variant` input, `Compute cache scope` step;
#378 b1: per-target scope suffix so a late-stage COPY change in one
target no longer cascades into siblings' manifests), and the #273
doc-only PR fast-pass (`path-filter` job; Phase 2 classifier is pure
shell via `git diff --name-only base...head` + `case` glob, no
`dorny/paths-filter` dependency; 6-path allowlist; compute-matrix +
build gated on `code_changed`; docker-build aggregator short-circuits
on doc-only PRs).

| Category | Tests |
|----------|-------|
| `inputs.context_path` declared with `default: "."` | 1 |
| `inputs.dockerfile_path` declared with `default: ""` | 1 |
| 4 build steps reference `inputs.context_path` (#243 added runtime-test) | 1 |
| 4 build steps reference `inputs.dockerfile_path` with `format()` fallback | 1 |
| No leftover `context: .` literals | 1 |
| No leftover `file: ./Dockerfile` literals | 1 |
| Default values together preserve repo-root-Dockerfile callers | 1 |
| User build-args use long form matching Dockerfile.example sys stage (#198: USER_NAME / USER_GROUP / USER_UID / USER_GID across 4 build steps + no short-form regression) | 5 |
| `build_contexts` input forwards to docker/build-push-action `build-contexts:` (#207: input declared with empty default, 4 build steps forward, default preserves zero-diff) | 3 |
| #243 stage rename + runtime-test smoke: `target: devel-test` (renamed from `test`), no leftover `target: test`, `target: runtime-test` exists, runtime-test gated on `inputs.build_runtime` (>=2 occurrences shared with runtime gate) | 4 |
| #272 + #378 b1 GHA buildx cache: `cache_variant` input declared with empty default, `Compute cache scope` step emits `id: cache` + base key (no `-cache` suffix; per-target suffix appended at use site), 4 build steps use per-target `<base>-<target>-cache` scopes (cache-from + cache-to per target), no legacy shared-scope leftover (negative regression), 4 build steps preserve `mode=max`, default preserves zero-diff for single-call callers | 6 |
| #273 doc-only PR fast-pass (Phase 1 + Phase 2 shell rewrite): `path-filter` job declared, classifier is pure shell (`git diff --name-only base...head` + `case` glob; no `dorny/paths-filter` dependency), reads EVENT_NAME / BASE_SHA / HEAD_SHA from env: keys so the case body stays portable, non-PR event short-circuits before git diff (BASE_SHA / HEAD_SHA empty on push / tag / workflow_dispatch), 6-path allowlist (`**/*.md`, `doc/**`, `LICENSE`, `.gitignore`, `.github/CODEOWNERS`, `.github/dependabot.yml`) in a single `case` arm, `compute-matrix` + `build` jobs gated on `code_changed == 'true'` (2 occurrences), `docker-build` aggregator handles `code_changed == 'false'` short-circuit + `needs: [path-filter, build]`, non-PR triggers always set `code_changed=true` | 8 |
| #470 opt-in `free_disk_space` for large BASE_IMAGE repos: input declared `type: boolean` default `false`, step gated on `inputs.free_disk_space`, uses `jlumbroso/free-disk-space@...`, positioned before `Set up Docker Buildx` so the overlayfs snapshot dir has room | 4 |

### test/bats/unit/self_test_yaml_spec.bats (58)

Structural assertions for `.github/workflows/self-test.yaml`. Locks
eleven cumulative invariants:

1. **#305 actionlint gate** — `actionlint` job declared, runs
   `rhysd/actionlint` via Docker pinned to an explicit version
   (`x.y.z`); downstream jobs (`test`, `integration-e2e`,
   `behavioural`) need it so the workflow-validator class of
   regression that wedged v0.26.0-rc1 (refs #297) is caught early.

2. **#317 P1 classifier + buildx GHA cache** — a `classify` job
   emits `code_changed` + `behavioural_relevant` outputs from PR
   diff against the doc-only allow-list (`doc/**` + `README.md` +
   `LICENSE`) and behavioural block-list (entrypoint.sh + compose
   + Dockerfile.example/.test-tools + wrappers + init/upgrade +
   `test/bats/behavioural/**` + `.github/workflows/**`); the `test` job
   always runs (required check) but short-circuits to SUCCESS on
   doc-only PRs; `integration-e2e` and `behavioural` gate via
   job-level `if:`; all three test-tools image builds use
   `docker/build-push-action` with shared `scope=test-tools` GHA
   cache.

3. **#317 P1 follow-up classifier hardening** — `classify` job is
   fail-open: `set -uo pipefail` (no `-e`) so transient diff/fetch
   errors don't crash the job and wedge every PR via the Q4
   fail-closed chain. Explicit `git fetch origin` of the base ref
   with `--depth=200` before diff so fork PRs (where
   `actions/checkout@v6 fetch-depth: 0` only fetches the head
   branch) don't trip on missing `origin/<base>`.

4. **#317 P2 Obtain step + rolling tag fallback** — each of the 3
   downstream jobs (`test`, `integration-e2e`, `behavioural`)
   precedes its test-tools provisioning with an `Obtain` step
   implementing the 3-layer fallback: PR touched
   `dockerfile/Dockerfile.test-tools` -> rebuild local; else
   `docker pull ghcr.io/ycpss91255-docker/test-tools:main` and
   re-tag; else fall back to a from-source rebuild. For `test` +
   `behavioural` (which `docker compose run` test-tools), the
   buildx Build step gates on `steps.obtain.outputs.build_local
   == 'true'` so the hot path skips it and the cold path reuses
   P1's GHA cache. For `integration-e2e` (which `docker compose
   build`, whose `FROM ${TEST_TOOLS_IMAGE}` resolves against the
   host docker daemon), the buildx `driver: docker` override is
   preserved and the rebuild fallback is inlined as plain
   `docker build` — GHA cache is not available on this driver,
   accepted because the hot path is `docker pull :main` and cold
   path matches pre-P2 cost. `integration-e2e` additionally
   passes `TEST_TOOLS_IMAGE: test-tools:local` to `./build.sh
   test` so the wrapper script skips its own internal test-tools
   build, reusing the image populated by the Obtain step.

5. **#317 P3 behavioural conditional + block-list expansion** —
   `behavioural` job's job-level `if:` tightens from
   `code_changed == 'true'` (P1) to `behavioural_relevant ==
   'true'` (the narrower output P1 already emitted but didn't
   consume). PRs that change pure lint / unit-test paths
   covered by `test` now skip the docker.sock-mounted compose
   run, saving ~3-5 min per such PR. The behavioural block-list
   in `classify` is extended with `script/docker/setup.sh` +
   `script/docker/i18n.sh` + `script/docker/lib/**` +
   `script/docker/prune.sh` (gotcha-5): each affects `.env` /
   `compose.yaml` generation or wrapper behaviour that the
   compose service exercises end-to-end, so they must invalidate
   the behavioural-skip optimization.

6. **#337 `ci-rollup` aggregator** — a single always-running
   (`if: always()`) `ci-rollup` job sits downstream of every PR
   check and collapses their results into one pass/fail signal that
   branch protection can require. The verifier shell step consumes
   every `${{ needs.<job>.result }}` and applies a 2-tier rule:
   `actionlint` / `classify` must be `success`;
   conditionally-gated jobs (`shellcheck` / `hadolint` / `bats-unit` /
   `bats-integration` / `coverage` / `integration-e2e` / `behavioural`)
   may be `success` or `skipped` (their job-level `if:` legitimately
   skips on doc-only / non-behavioural PRs per #317 P1/P3, #376, #377,
   #615). Adding sub-jobs (#377)
   to the rollup's `needs:` list becomes a workflow-internal
   change with no branch-protection update required.

7. **#376 ShellCheck + Hadolint dedicated jobs** — `shellcheck` runs
   on plain ubuntu-latest with the pre-installed binary (no buildx,
   no test-tools image, ~30s feedback on a regression) via
   `test.sh --shellcheck-only`. `hadolint` uses
   `hadolint/hadolint-action@v3.1.0` to lint
   `dockerfile/Dockerfile.example` + `dockerfile/Dockerfile.test-tools`
   (both template-owned; downstream Dockerfile.example consumers
   inherit the lint pass). Both gate on
   `needs.classify.outputs.code_changed == 'true'` so doc-only PRs
   SKIP them. Both join `ci-rollup`'s `needs:` list, and `release`
   also gates on them so a tag with a lint regression doesn't publish
   a Release.

8. **#377 Bats unit/integration split + Kcov coverage move** — the
   pre-#377 monolithic `test` job is fully removed and replaced by
   three sibling jobs:
   - `bats-unit` (matrix `shard: ['1/2', '2/2']`, `fail-fast: false`):
     each shard runs a round-robin partition of `test/bats/unit/*_spec.bats`
     via `test.sh --bats-unit-shard ${{ matrix.shard }}`. Parallel
     execution drops PR wall-time from ~5min to ~2min.
   - `bats-integration`: runs `test/bats/integration/` via
     `test.sh --bats-integration`. Pulled out of the unit serial path
     so each unit shard sees only its share.
   - `coverage`: #377 gated it to main pushes only and kept it out of
     `ci-rollup`'s `needs:` (a non-gating metric). **Superseded by #615
     (invariant 11): coverage is now a sharded kcov PR gate in the
     rollup.** The #377-era posture (main-only `if:`, "NOT in ci-rollup
     needs") is no longer asserted here.

9. **#579 integration-e2e runnability gate** — the e2e job drives
   build / run / exec / stop through the documented `just` entry points
   (not raw `script/*.sh`, so a broken container-ops justfile is
   caught) and ASSERTS the runnability contract instead of only running
   the steps: the in-container user equals the configured `USER_NAME`
   (catches the v0.41.0 user-args `initial` bug), the detached container
   is still running (catches the entrypoint `set -u` insta-exit class),
   the wired ENTRYPOINT is `/entrypoint.sh`, the `~/work` mount is
   present and writable, and `just stop` removes both the container and
   the compose project network. `just` is installed via the
   `extractions/setup-just` action.

   `ci-rollup needs:` is `[actionlint, classify, shellcheck,
   hadolint, bats-unit, bats-integration, coverage, integration-e2e,
   behavioural]` (9 jobs post-#615) — every PR-check job. `release needs:`
   updates from `[shellcheck, hadolint, test, integration-e2e,
   behavioural]` → `[shellcheck, hadolint, bats-unit, bats-integration,
   integration-e2e, behavioural]`. Post-#377 only `actionlint` +
   `classify` are hard-mandatory in `ci-rollup`'s verifier (the
   always-running `test` job no longer exists).

10. **#603 native arm64 e2e matrix** — `integration-e2e` runs as a
    static 2-entry `strategy.matrix` (`linux/amd64` -> `ubuntu-latest`,
    `linux/arm64` -> `ubuntu-24.04-arm`) with `fail-fast: false`, so the
    #579 runnability contract is verified on both arches via native
    runners (no QEMU), mirroring the platform->runner convention of
    build-worker / publish-worker / release-test-tools (#587). The job
    `runs-on: ${{ matrix.runner }}` and the Obtain step pulls
    `test-tools:main` for `${{ matrix.platform }}` (multi-arch post-#587)
    so the arm64 shard gets the arm64 variant. `ci-rollup` aggregates
    through `needs.integration-e2e.result` unchanged.

11. **#615 sharded kcov + coverage as an enforced PR gate (amends #377,
    ADR-00000008)** — `coverage` is no longer the #377 main-only metric.
    It now (a) runs as a kcov `strategy.matrix` (`shard: ['1/4', '2/4',
    '3/4', '4/4']`, `fail-fast: false`) MIRRORING the `bats-unit` matrix
    via `test.sh --coverage-shard ${{ matrix.shard }}` — each shard kcov's
    the same round-robin unit slice the unit-test matrix runs (integration
    on the last shard) and uploads its partial report under a per-shard
    `flags: coverage-shard-<index>` so Codecov merges the uploads into one
    project figure; (b) gates on `needs.classify.outputs.code_changed ==
    'true'` so it runs on PRs (not just main push); and (c) joins
    `ci-rollup`'s `needs:` (now 9 jobs) + the verifier consumes
    `needs.coverage.result` (SKIPPED-as-pass for doc-only PRs), so a kcov
    failure blocks PR merge. A coverage regression below the
    `.codecov.yaml` `project` threshold is enforced as a required
    `codecov/project` branch-protection status. The old `if: push && ref
    == refs/heads/main` and the "NOT in ci-rollup needs" posture are gone.

| Category | Tests |
|----------|-------|
| `actionlint` job declared | 1 |
| `actionlint` step uses `rhysd/actionlint:<pinned-version>` Docker image | 1 |
| `classify` job declared with `code_changed` + `behavioural_relevant` outputs | 3 |
| `classify` doc-only allow-list + behavioural block-list + non-PR default | 3 |
| `bats-unit`/`bats-integration`/`integration-e2e`/`behavioural` declare `needs: [actionlint, classify]` | 4 |
| `bats-unit`/`bats-integration` job-level `if: code_changed == 'true'` + no remaining monolithic `test:` job (#377) | 3 |
| `integration-e2e` job-level `if: code_changed == 'true'` + `behavioural` job-level `if: behavioural_relevant == 'true'` (#317 P3 tightens) | 2 |
| `bats-unit`/`bats-integration`/`behavioural` use `docker/build-push-action@v6` with `scope=test-tools` GHA cache | 3 |
| `classify` fail-open (`set -uo pipefail`) + pre-fetch base ref (#317 gotcha-1/2) | 2 |
| `bats-unit` Obtain step pulls `:main` with 3-layer fallback + Build step gated on `build_local` (#317 P2 + #377) | 2 |
| `bats-integration` Obtain step + 3-layer fallback (#317 P2 + #377) | 1 |
| `integration-e2e` Obtain step + `TEST_TOOLS_IMAGE` env passthrough + no `driver: docker` pin (#317 P2) | 2 |
| `integration-e2e` native arm64 matrix (#603): amd64+arm64 native-runner matrix with `fail-fast: false`; shards `runs-on: ${{ matrix.runner }}`; Obtain pulls the matrix platform | 3 |
| `behavioural` Obtain step with 3-layer fallback (#317 P2) | 1 |
| Obtain steps pre-fetch base ref (5 occurrences post-#377: classify + 4 jobs, #317 P2 reuses P1 gotcha-2 fix) | 1 |
| `classify` behavioural block-list extends to `setup.sh` + `i18n.sh` + `lib/**` + `prune.sh` (#317 P3 gotcha-5) | 1 |
| `ci-rollup` declared + `needs: [actionlint, classify, shellcheck, hadolint, bats-unit, bats-integration, coverage, integration-e2e, behavioural]` + `if: always()` (#337 + #376 + #377 + #615) | 3 |
| `ci-rollup` DOES need `coverage` now (#615 amends #377) | 1 |
| `ci-rollup` verify step consumes every `needs.<job>.result` incl `coverage` + SKIPPED treated as pass for conditional jobs + `success` required for hard-mandatory jobs (#337 + #376 + #377 + #615) | 3 |
| `shellcheck` job declared + `needs: [actionlint, classify]` + `if: code_changed == 'true'` + runs `test.sh --shellcheck-only` on plain ubuntu-latest with no buildx (#376) | 3 |
| `hadolint` job declared + `needs: [actionlint, classify]` + `if: code_changed == 'true'` + lints both template-owned Dockerfiles via `hadolint-action` (#376) | 3 |
| `bats-unit` declared + `strategy.matrix.shard: ['1/2', '2/2']` + `fail-fast: false` + invokes `test.sh --bats-unit-shard ${{ matrix.shard }}` (#377) | 3 |
| `bats-integration` declared + invokes `test.sh --bats-integration` (#377) | 2 |
| `coverage` declared (#377) + runs on PRs via `if: code_changed == 'true'` (not main-only) + kcov `matrix.shard: ['1/4'..'4/4']` mirroring bats-unit + invokes `test.sh --coverage-shard ${{ matrix.shard }}` + per-shard `flags:` Codecov upload (#615) | 4 |
| `release` job needs `[shellcheck, hadolint, bats-unit, bats-integration, integration-e2e, behavioural]` before publishing a tag (#376 + #377) | 1 |

### test/bats/unit/release_test_tools_yaml_spec.bats (14)

Structural assertions for `.github/workflows/release-test-tools.yaml`.
Locks the publish surface that downstream Dockerfile.example's `FROM
${TEST_TOOLS_IMAGE} AS test-tools-stage` depends on. The workflow has
three publish modes:

1. **Tag push (`v*`)** — multi-arch `:<version>` + `:latest`. Cuts the
   release downstream consumers pin via `inputs.test_tools_version`.
2. **Main push** (#317 P2) — multi-arch `:main` rolling tag. Used by
   self-test.yaml's Obtain step to skip from-source rebuilds. Paths
   filter (gotcha 3) restricts to commits that touched
   `dockerfile/Dockerfile.test-tools` or this workflow.
3. **workflow_dispatch** — manual `:latest` republish, kept unfiltered
   for bootstrap.

Smoke step uses `steps.tags.outputs.smoke` so it always pulls the tag
the current trigger produced (rather than statically pulling `:latest`,
which would leave a freshly-pushed `:main` unverified).

| Category | Tests |
|----------|-------|
| Triggers on `v*` tag push (existing) | 1 |
| Triggers on main push (#317 P2) | 1 |
| Main push trigger has `paths:` filter limiting to Dockerfile.test-tools + workflow self (#317 P2 gotcha-3) | 1 |
| Triggers on `workflow_dispatch` (existing) | 1 |
| Resolve tags step: 3 publish modes (`v*` + `main` + dispatch) emit correct tag sets and `smoke` output | 3 |
| Smoke step pulls trigger's tag via `steps.tags.outputs.smoke` (#317 P2) | 1 |
| Native-runner matrix (#587): drops `setup-qemu-action`; `compute-matrix` maps platforms to native runners; build shards run on `matrix.runner`; build per-platform + push by digest; `merge` job creates the manifest via `imagetools` | 5 |
| Declares `packages: write` permission | 1 |

### test/bats/unit/release_worker_yaml_spec.bats (2)

Structural assertions for `.github/workflows/release-worker.yaml`'s
archive step. The user-facing wrappers moved out of the repo root into
`script/` (symlinks into `.base/`); the archive `cp -r` still listed the
root names (`build.sh` / `run.sh` / `exec.sh` / `stop.sh` /
`setup_tui.sh`) as operands, and `cp -r` aborts non-zero on a missing
operand -- failing the first `v*` tag push of every standard-layout
downstream. These tests lock the removal (wrappers ship via `script/`).

| Category | Tests |
|----------|-------|
| Archive cp list names no removed root wrapper operand (#558) | 1 |
| Archive cp list keeps the paths that still ship (no over-prune) | 1 |

### test/bats/unit/publish_worker_yaml_spec.bats (11)

Structural assertions for the `.github/workflows/publish-worker.yaml`
reusable `call-publish` workflow (foundational image repos push their
Dockerfile target stage to a registry on tag push; downstream app repos
consume via `FROM ${registry}/${owner}/<image>`). #602: the original
`publish` job had every matrix shard push the SAME computed tag(s) via
`push: true` + `tags:`, leaving a last-shard-wins single-arch tag on a
multi-platform call (no manifest merge). The fix mirrors the #587
release-test-tools pattern — each shard pushes by digest, uploads its
digest, and a `merge` job assembles the tagged manifest list via
`docker buildx imagetools create`. These guards lock that contract.

| Category | Tests |
|----------|-------|
| Stays a reusable `workflow_call` workflow; preserves the registry-parameterised inputs | 2 |
| Native-runner matrix: `compute-matrix` maps platforms to native runners; build shards run on `matrix.runner` | 2 |
| Push-by-digest per shard (#602): build pushes by digest; no shared same-tag-per-shard push (regression guard); digest exported + uploaded as artifact | 3 |
| Merge job (#602): downloads digests + creates the manifest via `imagetools`; resolves tags from inputs once; login uses the parameterised registry | 3 |
| Declares `packages: write` on both push jobs | 1 |

### test/bats/unit/multi_distro_build_worker_yaml_spec.bats (16)

Structural assertions for `.github/workflows/multi-distro-build-worker.yaml`
(#325 B-1 dispatcher, extended to N-D matrix-mode via #344 in v0.32.0).
The dispatcher fans a per-event `include`-shape matrix across
`build-worker.yaml` matrix shards so multi-distro / multi-variant
caller `main.yaml`s (`env/ros_distro`, `env/ros2_distro`,
`app/ros1_bridge`) stop copy-pasting a
`${{ github.event_name == 'pull_request' && ... || ... }}`
expression. Three jobs:

1. **`resolve-matrix`** — pure-shell selector emitting a `matrix`
   JSON-array output (`include`-shape, each entry has `name` +
   `build_args` plus arbitrary additional fields). `pull_request` ->
   `pr_matrix` (subset); anything else (tag push, main push,
   `workflow_dispatch`) -> `tag_matrix` (release validation matrix).

2. **`call-build`** — strategy.matrix job invoking the local
   `build-worker.yaml` per matrix cell. Derives per-shard
   `image_name` as `<image_name>-<matrix.name>`, forwards
   `matrix.build_args` verbatim as `build_args`, and shards buildx
   GHA cache by name via `cache_variant: ${{ matrix.name }}`
   (reuses #272's per-variant scope contract). `fail-fast: false`
   so one shard's failure doesn't cancel siblings.

3. **`ci-passed`** — rollup gate for branch protection. Matches the
   existing `ci-passed` rollup naming used by env/ros_distro /
   env/ros2_distro per CLAUDE.md's status-check table, so
   downstream branch-protection contexts don't change on adoption.

**BREAKING since v0.32.0 (#344)**: legacy 1D inputs `pr_distros` /
`tag_distros` / `distro_input_name` / `extra_build_args` were removed;
the 14 v0.29-era tests covering those inputs are replaced by 16 tests
covering the new matrix-mode shape (incl. a negative assertion that
the 1D inputs are gone).

| Category | Tests |
|----------|-------|
| Declares `workflow_call` | 1 |
| Required inputs: `pr_matrix`, `tag_matrix`, `image_name` | 1 |
| Legacy 1D inputs gone (no `pr_distros` / `tag_distros` / `distro_input_name` / `extra_build_args`) | 1 |
| `pr_matrix` description documents required `name` + `build_args` fields | 1 |
| `tag_matrix` description documents required `name` + `build_args` fields | 1 |
| Passthrough inputs mirror build-worker (build_runtime / test_tools_version / platforms / context_path / dockerfile_path / build_contexts) | 1 |
| `resolve-matrix` emits `matrix` output (include-shape) | 1 |
| `resolve-matrix` branches on `github.event_name == 'pull_request'` | 1 |
| `call-build` `uses: ./.github/workflows/build-worker.yaml` | 1 |
| `call-build` matrix `include: fromJSON(needs.resolve-matrix.outputs.matrix)` | 1 |
| `call-build` per-shard `image_name: <image_name>-<matrix.name>` (hyphen) | 1 |
| `call-build` forwards `build_args: ${{ matrix.build_args }}` verbatim | 1 |
| `call-build` `cache_variant: ${{ matrix.name }}` (per-cell cache scope) | 1 |
| `call-build` `fail-fast: false` | 1 |
| `ci-passed` rollup depends on `call-build`, runs with `if: always()` | 1 |
| `ci-passed` declares `name: ci-passed` to satisfy branch protection contract | 1 |

### test/bats/unit/wrapper_lib_spec.bats (18)

Unit tests for the wrapper-runtime module `lib/wrapper.sh` (#565), which
hoists the cross-cutting surfaces the 5 docker wrappers (build / run /
exec / stop / prune) used to duplicate: the `_msg` dispatcher, the
`--lang` pre-pass, and the build/run setup/drift orchestration. Each
helper is sourced directly (not through a wrapper) so the branches run in
isolation; a minimal sandbox with a mock `setup.sh` drives the
orchestration end-to-end without docker.

Covers (with the "called from each of the 5 wrappers" parameterisation):

| Group | Cases |
| --- | --- |
| `_msg` dispatcher: routes `<category> <key>` to `_msg_<category>`, reads global `_LANG`, errors on missing category / key | 4 |
| `_wrapper_lang_prepass`: sets `_LANG` from `--lang` (anywhere in argv), leaves it untouched without `--lang`, unsupported-value fallback to `en`, requires a verb, threads each of the 5 verbs into the `_sanitize_lang` warning tag | 6 |
| `_wrapper_setup_sync`: bootstrap on missing `.env`, `RUN_SETUP=true` forced run, clean drift-check skips re-apply, regen on drift, exit-1 `no_env` error path, per-verb `[<verb>]` log tag (build + run), requires a verb, degrades to empty forward-args when `SETUP_FORWARD_ARGS` is unset (lib defensive-unset convention) | 8 |

### test/bats/unit/dockerfile_migrate_spec.bats (33)

Unit tests for the declarative Dockerfile-migration list
`lib/dockerfile_migrate.sh` (#567, folds #579 facet B). The lib exposes a
small interface — `apply_migrations <dockerfile>` — over an ordered,
data-driven `_MIGRATIONS` table of `{detect, transform}` units, each
healing one v0.41.0-fanout Dockerfile/entrypoint breakage. upgrade.sh
Step 5 sources the lib and calls the dispatcher (replacing the old one-off
seds). Each migration is driven in isolation via before/after fixtures
plus the dispatcher's apply / skip / idempotency contract: a detected
shape auto-applies idempotently, a missing/ambiguous shape is skipped
(warn, never force-rewrite).

| Test | Description |
|------|-------------|
| `apply_migrations is the public dispatcher entry (#567)` | Small interface exists |
| `apply_migrations skips cleanly when path does not exist (#567)` | No-Dockerfile skip |
| `_MIGRATIONS is a non-empty ordered list (#567)` | Data-driven table is seeded |
| migration 1 (wrapper-copy): shape A `COPY *.sh /lint/`, shape B `COPY .base/script/docker/*.sh /lint/` -> `wrapper/*.sh`, idempotent, detect-false | 4 |
| migration 2 (pip-helper): drop retired `${CONFIG_DIR}/pip/requirements.txt` install line + comment, detect-false | 2 |
| migration 3 (explicit-copy): drop single-line + backslash-continued explicit top-level `.sh` lint COPYs, detect-false on lib/wrapper dir COPYs | 3 |
| migration 4 (logging-rename): rewrite Dockerfile COPY + sibling entrypoint source `_entrypoint_logging.sh` -> `runtime/logging.sh`, detect-false on new name, heal a stale entrypoint when the Dockerfile is already migrated (#692) | 4 |
| migration 5 (hadolint): DL3007 pin tags, DL3046 `useradd -l`, DL3003 `WORKDIR /lint`, DL3042 `--no-cache-dir`, DL4006 alpine SHELL pipefail, DL3006 inline ignore (+idempotent), detect-false on clean | 8 |
| migration 6 (sc1090): broaden entrypoint `SC1091` -> `SC1090,SC1091`, idempotent, detect-false without entrypoint | 3 |
| migration 7 (arg-user, #579): `ARG USER` -> `ARG USER="${USER_NAME}"`, idempotent, leaves unrelated ARGs | 3 |
| migration 8 (nounset-source, #579): bracket entrypoint ROS `setup.bash` source with `set +u`/`set -u`, idempotent, detect-false without `set -u` | 3 |

### test/bats/unit/build_sh_spec.bats (52)

Unit tests for `build.sh` argument handling and control flow. Uses a
sandbox tree mirroring the expected layout (build.sh + `template/` subtree
with real `_lib.sh` / `i18n.sh`, mock `setup.sh`). `docker` is PATH-shimmed
so the stub captures argv; `build.sh` is symlinked (not copied) so kcov
attributes coverage to the real source file.

Covers: `--help` (en/zh/zh-CN/ja), `--setup`/`-s`, auto-bootstrap on
missing `.env` / `setup.conf` / `compose.yaml`, drift-check path when
all three are present, bootstrap staying non-interactive (setup.sh
direct, not `setup_tui.sh`), defensive guard when setup produces no
`.env`, TARGETARCH build-arg forwarding, `--no-cache`, `--clean-tools`,
positional `TARGET`, **`-t` / `--target TARGET` alias** (#280: short +
long form, last-wins resolution against positional `[TARGET]` in both
orderings, `-t` value-required guard, usage help mention), `--lang`
argument validation, fallback `_detect_lang` branches (zh_TW/zh_CN/ja),
real (non-dry-run) docker build invocation, **runtime log-line i18n**
(bootstrap / drift-regen / err_no_env messages translate in all four
languages via the local `_msg()` table; English remains the default),
and **`-C` / `--chdir` flag** (docker_harness#53: pre-pass overrides
FILE_PATH to redirect the wrapper to a different repo, both short and
long form, value-required and directory-existence guards, usage help
mention), and **`-v` / `--verbose` / `-vv` / `--very-verbose` flag**
(#311: exports `BUILDKIT_PROGRESS=plain` so a hung `docker build`'s RUN
step output is visible; `-vv` adds `set -x` on the wrapper itself;
usage help mentions all four spellings), and **#690 pre-build hook
abort** (a failing `script/hooks/pre/build.sh` makes the wrapper exit
the hook's rc via `_run_pre_hook build "$@" || exit $?` AND `docker
compose build` never runs).

### test/bats/unit/build_sh_prune_spec.bats (7)

Unit tests for `build.sh`'s #387 post-build prune-predecessor logic.
Separate spec so the docker stub can be tailored to image-inspect /
images-filter / rmi semantics without bloating the default
build_sh_spec stub (which only logs argv). Smart docker stub branches
on `image inspect` (returns `DOCKER_INSPECT_PRE_ID` on the first call,
`DOCKER_INSPECT_POST_ID` on the second — defaults to PRE_ID for the
cache-hit case), `images --filter reference=<id>` (emits the
`<none>:<none>` self-entry plus `DOCKER_IMAGES_OUTPUT` lines so the
multi-tag-still-references case can be simulated), and `rmi` (appends
the id to `DOCKER_RMI_LOG` so tests assert presence/absence).

Covers: first-build path (`docker image inspect` exits 1 → no
`_pre_build_id` → prune skipped, no rmi), cache-hit rebuild
(`pre == post` → cache-hit guard returns early), successful displaced
rebuild (`pre != post`, old id has no other tag → `docker rmi
<old-id>` fires), multi-tag guard (old id still referenced elsewhere
→ "skip prune: predecessor still tagged" log + no rmi), `--no-prune`
opt-out (no inspect calls + no rmi even when ids would have moved),
`--dry-run` (planned-action line `[dry-run] docker rmi <old-id-of ...
if displaced>` visible + zero real rmi), and `--help` mentions the
`--no-prune` flag.

### test/bats/unit/run_sh_spec.bats (65)

Unit tests for `run.sh`. Mirrors the build_sh_spec.bats harness;
`docker ps` reads from a controllable stub file so tests can simulate
"container already running" scenarios.

Covers: `--help` (en/zh/zh-CN/ja), `--setup`/`-s`, bootstrap on
missing `.env` / `setup.conf` / `compose.yaml`, drift-check path,
bootstrap staying non-interactive (setup.sh, not TUI), defensive guard
when setup produces no `.env`, `--detach`, devel vs non-devel TARGET
routing, already-running guard, Wayland xhost path,
`--lang` argument validation, fallback `_detect_lang`
branches, **runtime log-line i18n** (bootstrap + already-running
error translate in all four languages via the local `_msg()` table),
**#216/#429 auto-build gate** (image present → silent + no build,
image absent → auto-delegates to `./build.sh TARGET`, non-devel target
forwarded, build failure aborts run, per-target image inspect, `--build`
invokes `./build.sh test` before compose up, `--build` after
check-drift), and **`-C` / `--chdir`
flag** (docker_harness#53: redirect FILE_PATH, short + long form,
value-required and directory guards, usage help mention), and **`-v`
/ `--verbose` / `-vv` / `--very-verbose` flag** (#311: same export +
trace pattern as build.sh, parity across wrappers), and **#386
foreground exit auto compose-down** (default-on for devel + one-shot
non-devel targets, `--no-rm` opts out, `-d` suppresses the trap; the
trap fires `down --remove-orphans` to mirror stop.sh and close the
worktree-removed-before-stop network leak), and **#448 `--` CMD
separator** (`--` stops flag parsing so CMD flags like `--target`
don't collide; positional CMD also stops parsing; usage documents
`--`), and **#580 interactive exit-code normalization**
(`_normalize_interactive_rc` maps clean-exit codes 0 and 130 to 0 on
the no-CMD foreground paths -- devel attached shell and one-shot stage
`compose up` -- so a Ctrl-C-cleared line carried out on exit isn't a
recipe failure, while a genuine non-clean code like 127 still
propagates and command mode `just run <cmd>` keeps the real exit code),
and **#679 non-`devel` CMD-override dispatch** (a non-`devel` one-shot
target WITH a CMD dispatches `compose run --rm <SERVICE> <CMD…>` so the
ENTRYPOINT runs and the override replaces the default CMD — NOT the
pre-#679 `up -d` + `exec` pair that bypassed the ENTRYPOINT and
double-launched the default CMD; the #679 repro shape `-t runtime ros2
launch …` is asserted; `devel` + CMD still uses `up -d` + `exec`; the
no-CMD paths are unchanged; #580 exit-code propagation rides the `run`
path for non-`devel` command mode), and **#690 pre-run hook abort +
foreground post-run hook exit override** (a failing
`script/hooks/pre/run.sh` aborts the wrapper with the hook's rc before
the build delegate / `compose up`; in the foreground path a failing
`script/hooks/post/run.sh` makes `_app_cleanup` override the wrapper
exit with the hook's rc while `compose down --remove-orphans` still
runs).

### test/bats/unit/exec_sh_spec.bats (57)

Unit tests for `exec.sh` argument parsing, the container-running
precheck, and i18n. Sandbox tree mirrors build_sh_spec.bats;
`docker ps` reads from a controllable stub file so tests can toggle
"container running" state without a real docker daemon. `.env` is
pre-seeded so `_load_env` / `_compute_project_name` succeed without a
bootstrap step.

Covers: `--help` (en/zh/zh-CN/ja), `--lang` / `--target`
value validation, English-default not-running error, Chinese /
Simplified Chinese / Japanese not-running error text, the `./run.sh`
start hint (en + zh-TW), `--dry-run` bypassing the guard, compose exec
routing when container is running, **`--` flag/CMD separator** (#289:
standalone `--` consumed before CMD flows through to `docker compose
exec`, lets a dash-leading CMD pass through, works after `-t TARGET`
for run.sh parity, no-`--` positional path stays backward-compatible,
`-h` usage mentions `--`), fallback `_detect_lang` branches when
`template/` is absent, **`-C` / `--chdir` flag**
(docker_harness#53: redirect FILE_PATH so .env / project name come
from the alt repo, short + long form, value-required and directory
guards, usage help mention), **`-v` / `--verbose` / `-vv` /
`--very-verbose` flag** (#311: symmetry-only for exec since
`docker exec` itself does not build, but flag is accepted and `-vv`
enables wrapper trace), and **`-T` / `--no-tty` + `-i` / `--tty`
TTY-mode flags + auto-detect of `bash|sh|dash|zsh|ash|ksh -c '...'`**
(#382 Option 1+2: 17 assertions covering the no-CMD default (TTY),
interactive binary default (TTY), 4 shell flavours with `-c` auto-add
`-T`, `bash hello.sh` (no `-c`) keeps TTY, explicit `-T`/`--no-tty`
forces no-TTY, explicit `-i`/`--tty` overrides heuristic, last-wins
precedence between `-T` and `-i` in both orders, `-T` + `-t TARGET`
attaches to the right service, `-T` + `--` separator round-trip,
`--help` mentions both flag pairs), and **#690 exit-code forwarding +
pre/post hook error paths** (the container command's exit code is
forwarded unchanged via `return "${_exec_rc}"` — 42 / 0 / 7 cases; a
failing post-exec hook overrides the forwarded rc via `|| exit $?`; a
failing pre-exec hook aborts before `compose exec` runs).

### test/bats/unit/stop_sh_spec.bats (27)

Unit tests for `stop.sh` argument parsing, the single-project teardown,
and i18n. `docker ps -a` output is PATH-shimmed via `${DOCKER_PS_A_FILE}`
so tests can seed the project container list for the verbose listing.

Covers: `--help` (en/zh/zh-CN/ja), `--lang` value validation, teardown
via `docker compose down` (base is single-instance, #600), fallback
`_detect_lang` branches, **`-C` / `--chdir` flag**
(docker_harness#53: redirect FILE_PATH so .env / project name come
from the alt repo, short + long form, value-required and directory
guards, usage help mention), and **`-v` / `--verbose` / `-vv` /
`--very-verbose` flag** (#311: parity across wrappers; flag is a no-op
for `docker compose down` but `-vv` still enables wrapper trace; the
verbose path lists the project containers before tearing them down),
and **`--prune` flag** (#319: opt-in lightweight cleanup after compose
down — `docker network prune --filter until=10m` + `docker image prune
--filter until=24h`; usage help mentions `--prune` with the two grace
windows; the plain `stop.sh --dry-run` path emits no `docker prune`
commands), and **#690 pre-stop hook abort** (a failing
`script/hooks/pre/stop.sh` aborts with the hook's rc before
`compose down` runs).

### test/bats/unit/prune_sh_spec.bats (40)

Unit tests for the new `script/docker/prune.sh` wrapper (#319) — atomic
docker garbage cleanup with conservative per-target `--filter until=`
defaults (network=10m, image=24h, builder=24h, volume=no filter). Sandbox
+ PATH-shimmed `docker` stub mirrors the build/run/exec/stop spec
strategy; `docker compose` is never invoked here so no `.env` seeding is
required beyond the sandbox layout.

Covers: `--help` (en/zh-TW/zh-CN/ja), no-target exit-2 hint (English +
zh-TW), `--until` / `--lang` value-required guards, unknown-flag
exit-2, individual `--networks` / `--images` / `--builder` /
`--volumes` dry-run output (each with its own default grace; volume
output omits `--filter`), **`--all` aggregator** (network + image +
builder; volumes intentionally excluded), **`--until <dur>` override**
across all selected targets, **volume confirmation prompt** (`n`
aborts with exit-1 + i18n "aborted" message; `-y` skips the prompt;
zh-TW prompt body asserts), `-C` / `--chdir` parity (accepted but
no-op for daemon-wide prune; value-required + directory guards),
usage help mentions every flag family, and **#388 `--worktree-orphans`
mode** (13 cases): per-test smart docker stub keyed on
`DOCKER_IMAGES_OUTPUT` / `DOCKER_RMI_LOG` mocks `docker images` + `rmi`;
fixtures construct real `<workspace>/worktree/<name>/` dirs so the
existence check has something to consult. Cases cover empty-list
no-op, owner-match + missing worktree → rmi, owner-match + worktree
alive → keep, main-checkout pattern (no hyphen) → keep, **two safety
gates**: bare-name image → skip ("Skipping N bare-name image" log),
other-owner image → skip ("Skipping N image(s) owned by another user"
log). Plus `--repo` filter, `--dry-run` plan-only output, `-y` skip
prompt, missing `--workspace` + empty `.env` → exit 2, `--workspace`
flag wins over `.env` `WS_PATH`, `--owner` flag wins over `.env`
`DOCKER_HUB_USER`, and `--help` mentions all four new flags.

Plus the **`--worktree-orphans` interactive confirmation gate (#699)**
— the destructive `docker rmi` loop only reaches its prompt when
neither `-y` nor `--dry-run` is given, a branch the cases above never
exercised. Three cases mirror the `--volumes` prompt pair for the more
destructive image removal: piped `y` confirms and the candidate lands
in `DOCKER_RMI_LOG`; piped `n` aborts with exit-1 + "aborted by user"
and an empty `DOCKER_RMI_LOG`; closed stdin (`</dev/null`, no `-y`)
aborts cleanly with the same diagnostic instead of dying on a `set -e`
`read` EOF — prune.sh maps `read` EOF to an empty reply
(`read -r _reply || _reply=""`) so the default case treats it as an
explicit abort.

Regression guard for **issue #282** — the four user-facing wrappers
(`build.sh` / `run.sh` / `exec.sh` / `stop.sh`) must resolve `_lib.sh`
through the post-#263 `.base/` subtree prefix on a fresh clone of any
downstream repo. Pre-fix the wrappers hard-coded `template/` and a
freshly cloned downstream repo (where the subtree now lives under
`.base/`) failed at the `_lib.sh` source step with "cannot find _lib.sh".

Covers: `--help` succeeds for each wrapper when `.base/script/docker/_lib.sh`
exists alongside the wrapper symlink; the documented "cannot find _lib.sh"
error path still fires (with the new `.base/...` path in the diagnostic)
when neither `.base/` nor the sibling fallback is present.

### test/bats/unit/justfile_user_spec.bats (18)

Executable tests for the user-facing layered entry + namespaces (#546 /
ADR-00000005; ADR-00000011: docker is a namespace, `just docker build`).
Parity with the removed `makefile_user_spec`: sandboxes a repo with the
entry + module symlink chain at root + stub `script/*.sh` recorders, and
RUNS `just <ns> <verb>` to assert 1:1 forwarding with `{{args}}`
passthrough. Skips when `just` is not yet in the test-tools image
(pre-release GHCR pull -- see template_spec for the `apk add ... just`
guard + the release smoke check).

| Test | Description |
|------|-------------|
| `just docker build forwards positional args` | `just docker build test` -> build.sh test |
| `just docker build passes flags through verbatim` | no `--` separator needed |
| `just docker exec passes = -bearing Kit-style args` | no EXEC_ARGS shim (#469) |
| `just docker run / stop / prune / setup forward` | wrapper dispatch |
| `just docker setup-tui forwards to setup_tui.sh` | hyphenated recipe |
| `just base upgrade forwards to .base/upgrade.sh` | #652 -- base ns upgrade dispatch |
| `just base update runs upgrade.sh --check` | #652 -- apt-aligned check |
| `just base init forwards to .base/init.sh` | #653 -- base ns init dispatch |
| `just base completions forwards to script/base/completions.sh` | #653 -- opt-in completions installer dispatch |
| `bare just lists namespaces` | replaces `make help`; lists `docker`/`base`/... |
| `bare just docker lists the docker verbs` | #655 -- namespace help via module default (source_file() --list) |
| `bare just base lists the base verbs` | #655 -- namespace help via module default |
| `just docker build --help forwards --help to the backing script` | #655 -- recipe `--help` reaches the script as an arg |
| `just docker build --lang ja forwards --lang to the backing script` | #655 -- recipe `--lang` forwarded |
| `just base completions --lang forwards --lang to completions.sh` | #655 -- base ns recipe `--lang` forwarded |
| `repo-local group via script/local/justfile.local resolves as a top-level namespace` | #632 `import?` registry + `mod?` group |
| `just template new <name> scaffolds a working repo-local group` | #633 / closes #594 -- scaffold + immediately usable |
| `bare just template prints help` | #633 -- module default recipe |

### test/bats/unit/template_new_spec.bats (7)

Unit tests for the repo-local command-group scaffolder
`downstream/script/template/new.sh` (#633, closes #594). Runs `new.sh`
directly (no `just` needed): it creates `script/local/<name>/justfile.<name>`
+ `<name>.sh` from `skel/` and registers the group in
`script/local/justfile.local`.

| Test | Description |
|------|-------------|
| `new.sh scaffolds script/local/<name>/{justfile.<name>,<name>.sh} from skel` | files created + executable |
| `new.sh substitutes __NAME__ in the scaffolded files` | placeholder replaced |
| `new.sh registers the group in script/local/justfile.local (mod? line)` | registry append |
| `new.sh refuses to clobber an existing group` | safe no-overwrite |
| `new.sh does not duplicate the registry line on a second distinct group` | one mod? per group |
| `new.sh rejects an invalid group name` | name validation |
| `new.sh errors with usage when no name given` | arg guard |

### test/bats/unit/justfile_spec.bats (11)

Static content checks for the layered just entry (ADR-00000005 / #545,
ADR-00000010; ADR-00000011: docker + base are `mod?` namespaces, not a
top-level import). The entry `downstream/script/justfile` mods the docker
+ base modules; docker verbs forward 1:1 to `./script/<name>.sh` via
`{{args}}`, base verbs to `./.base/upgrade.sh`. Asserted by grep, not
execution -- `just` is not in the test-tools image; downstream installs it.

| Test | Description |
|------|-------------|
| `layered entry + docker module exist` | both files present |
| `docker module declares args-passthrough recipes for every wrapper verb` | build/run/exec/stop/prune/setup/setup-tui `*args` |
| `docker module no longer carries upgrade/upgrade-check (moved to base ns)` | #652 -- upgrade is a .base op |
| `docker module recipes forward to ./script/<wrapper>.sh with {{args}}` | forwarding bodies |
| `base module declares upgrade + update (apt-aligned) forwarding to .base/upgrade.sh` | #652 / ADR-00000011 |
| `base module declares init + completions recipes` | #653 -- init -> .base/init.sh, completions -> script/base/completions.sh |
| `docker module owns a default recipe + pins cwd to repo root` | #652 -- mod default + `set working-directory := '../..'` |
| `entry mods the docker namespace + default recipe lists recipes` | #652 -- `mod? docker` + `default: @just --list` |
| `entry mods the base namespace` | #652 -- `mod? base` |
| `test / release namespaces own a default recipe (bare-namespace help)` | #655 -- bare `just test` / `just release` |
| `test / release namespaces are English-only -- no --lang plumbing` | #655 -- ADR-00000011 i18n scope (machine/CI namespaces) |

### test/bats/unit/help_lang_spec.bats (19)

--help / --lang coverage across the recipe-backing scripts (#655,
ADR-00000011 §6). Runs each script directly (no `just`): asserts the
English-baseline usage on `-h`/`--help` (exit 0); the human-facing base /
template scripts (init / upgrade / completions / new) accept `--lang <code>`
and honor `SETUP_LANG`/`$LANG` via i18n.sh (validated, non-fatal fallback on a
bad value); and the machine/CI `test` namespace stays English-only (rejects
`--lang`). Namespace-level bare help + the `just`-driven forwarding live in
justfile_user_spec.bats.

| Test | Description |
|------|-------------|
| `test.sh --help exits 0 and prints usage` | English baseline usage |
| `test.sh -h exits 0 and prints usage` | short flag |
| `init.sh --help exits 0 and prints usage` | base ns usage |
| `upgrade.sh --help exits 0 and prints usage` | base ns usage |
| `completions.sh --help exits 0 and prints usage` | base ns usage |
| `completions.sh -h exits 0 and prints usage` | short flag |
| `new.sh --help exits 0 and prints usage` | #655 -- new.sh gained -h/--help |
| `new.sh -h exits 0 and prints usage` | short flag |
| `init.sh --help advertises --lang` | i18n namespace |
| `upgrade.sh --help advertises --lang` | i18n namespace |
| `completions.sh --help advertises --lang` | i18n namespace |
| `new.sh --help advertises --lang` | i18n namespace |
| `init.sh accepts a valid --lang without error` | flag stripped before dispatch |
| `upgrade.sh accepts a valid --lang without error` | flag stripped before dispatch |
| `completions.sh accepts a valid --lang without error` | flag accepted |
| `new.sh accepts a valid --lang and still scaffolds` | flag + positional name |
| `init.sh --lang bogus warns and falls back to en (non-fatal)` | _sanitize_lang fallback |
| `completions.sh --lang bogus warns and falls back to en (non-fatal)` | _sanitize_lang fallback |
| `test.sh rejects --lang (test namespace is English-only)` | machine/CI namespace, no i18n |

### test/bats/unit/completions_spec.bats (13)

Unit tests for the opt-in shell tab-completion installer
`downstream/script/base/completions.sh` (#653, ADR-00000011), reached as
`just base completions install|uninstall [--shell ...]`. Sandboxes HOME + the
XDG dirs to a temp tree and stubs `just` on PATH so `JUST_COMPLETE=<shell> just`
emits a per-shell marker; asserts the DYNAMIC loader is written to each shell's
standard auto-load dir (no rc edits), idempotency, the zsh fpath hint, default
`$SHELL` detection, and uninstall.

| Test | Description |
|------|-------------|
| `install bash writes the dynamic eval-loader file` | exact `eval "$(JUST_COMPLETE=bash just)"` content |
| `install fish writes the file with the dynamic completer output` | captures `JUST_COMPLETE=fish just` |
| `install zsh writes _just + prints the fpath hint when dir not on fpath` | `_just` + stdout fpath hint |
| `uninstall removes the installed file` | removes the loader |
| `uninstall is idempotent when the file is absent (no error)` | safe no-op |
| `install --shell all installs all three shells` | bash + fish + zsh |
| `uninstall --shell all removes all three shells` | bash + fish + zsh removed |
| `default --shell detects bash from $SHELL basename` | `$SHELL`-driven detection |
| `default --shell detection errors on an unknown shell` | unknown -> error asking for --shell |
| `unknown argument is a usage error (exit 2), distinct from detection error (#692)` | exit 2 vs exit 1 |
| `missing action is a usage error (exit 2) (#692)` | missing install/uninstall -> exit 2 |
| `-h / --help exits 0 with usage` | help text |
| `install is idempotent: a re-run overwrites cleanly` | overwrite-on-reinstall |

### test/bats/unit/compose_emitter_spec.bats (27)

Covers the per-service compose emitter (`_emit_stage_service`) and its
shared leaf-emitter sub-seams, hoisted out of `generate_compose_yaml`
(#566). Each emitter is exercised in isolation -- build the inputs, call
the emitter, assert on the small fragment it returns -- instead of
running the whole ~900-line generator and grepping its YAML output.

| Test | Description |
|------|-------------|
| `_emit_gpu_deploy_block: gui=false emits nothing` | GPU off |
| `_emit_gpu_deploy_block: gui=true emits deploy reservation with count + caps` | GPU on |
| `_emit_caps_block: all empty emits nothing` | caps off |
| `_emit_caps_block: cap_add list emits cap_add block` | cap_add |
| `_emit_caps_block: cap_drop + security_opt emit their blocks` | cap_drop/sec_opt |
| `_emit_env_file_block: emits the .env workload overlay block` | #502 env_file |
| `_emit_target_arch_line: empty omits; set emits literal TARGET_ARCH ref` | TARGETARCH |
| `_emit_build_network_line: empty omits; set emits network line` | build.network |
| `_emit_runtime_line: empty omits; set emits runtime line` | runtime |
| `_emit_restart_line: 'no' omits; plain value plain; on-failure:N quoted` | #478 restart |
| `_emit_additional_contexts_block: empty omits; entries emit block` | additional_contexts |
| `_emit_cgroup_rules_block: empty omits; entries emit quoted rules` | cgroup rules |
| `_emit_tmpfs_block: empty omits; entries emit tmpfs list` | tmpfs |
| `_emit_group_add_block: gated on gui AND non-empty groups; emits quoted gids` | #496 group_add |
| `_emit_user_build_args: empty omits; entries emit KEY: ${KEY} pairs` | build args |
| `_logging_svc_kv: seeds from global then overlays per-service` | logging merge |
| `_logging_svc_kv: a different service does not pick up another svc overlay` | svc keying |
| `_emit_logging_block: empty global + per-svc emits nothing` | logging off |
| `_emit_logging_block: driver + rotation maps to compose options block` | logging opts |
| `_emit_logging_block: keys off the service name for per-svc overrides` | per-svc |
| `_logging_svc_local_path_mount: empty local_path yields empty mount` | #328 off |
| `_logging_svc_local_path_mount: relative path resolves against base` | rel path |
| `_logging_svc_local_path_mount: absolute path passed verbatim` | abs path |
| `_emit_stage_service: zero-diff stage emits the extends:devel shape` | #215 zero-diff |
| `_emit_stage_service: zero-diff stage with per-svc logging override emits logging block` | zero-diff logging |
| `_emit_stage_service: stage with overrides emits a standalone block (no extends)` | #220 standalone |
| `_emit_stage_service: override stage GPU resolution emits deploy reservation` | standalone GPU |

### test/bats/unit/compose_gen_spec.bats (87)

Covers `generate_compose_yaml` conditional output: AUTO-GENERATED
header, baseline workspace volume, network/ipc/privileged env-var
references, conditional pid emission (only for `host`; omitted for
`private` since Docker rejects the literal), `test` service presence,
image name threading, and conditional GPU deploy block + GUI
env/volumes + extra volumes from `[volumes]` section.

| Test | Description |
|------|-------------|
| `outputs AUTO-GENERATED header` | Header check |
| `always emits workspace volume` | Baseline |
| `emits network_mode/ipc/privileged via env var` | env-var baked |
| `omits pid when default private` | pid omit |
| `emits pid env-var ref when host` | pid host |
| `emits test service with profiles: [test]` | test service |
| `image field contains repo name` | Image name |
| `does NOT emit /dev:/dev by default (not in baseline)` | Baseline scope |
| `GPU enabled => deploy block present` | GPU on |
| `GPU disabled => no deploy block` | GPU off |
| `GPU with specific count and capabilities` | GPU args |
| `GUI enabled => DISPLAY env + X11 volumes present` | GUI on |
| `GUI: xauth mounts at fixed neutral target, not host abs path` | #582 mount target |
| `GUI: container XAUTHORITY points at the fixed mount target` | #582 env sync |
| `GUI disabled => no DISPLAY env + no X11 volumes` | GUI off |
| `extra volumes appended after baseline` | volumes list |
| `empty extras => no extra mount lines` | empty list |
| `with GUI+GPU+extras => all sections present` | fully loaded |
| `emits runtime service when Dockerfile has AS runtime` | #108 auto-emit |
| `skips runtime service when Dockerfile lacks AS runtime` | opt-out by absence |
| `skips runtime service when Dockerfile is absent` | no-Dockerfile guard |
| `runtime service extends devel and overrides target/image/tty/profile` | compose extends shape |
| `runtime service appears between devel and test blocks` | ordering |
| `runtime detection is robust against weird whitespace` | regex tolerance |
| `runtime detection ignores non-runtime stage names` | strict match |
| `environment env_N expands ${VAR} cross-reference to earlier sibling (refs #236)` | basic cross-ref |
| `environment env_N forward reference is left literal (refs #236)` | order-sensitive |
| `environment env_N unknown ${VAR} is left literal (refs #236)` | unknown stays literal |
| `environment env_N supports multiple cross-references in one value (refs #236)` | multi-ref |
| `environment env_N transitive cross-reference resolves through chain (refs #236)` | transitive |
| `_resolve_docker_flags: no overrides => inherits all parent values (#505)` | inherit baseline |
| `_resolve_docker_flags: gui.mode=off overrides parent gui=true (#505)` | gui force-off |
| `_resolve_docker_flags: gui.mode=force overrides parent gui=false (#505)` | gui force-on |
| `_resolve_docker_flags: deploy.gpu_mode=off overrides parent gpu=true (#505)` | gpu force-off |
| `_resolve_docker_flags: deploy.gpu_count + gpu_capabilities overrides win (#505)` | gpu scalars |
| `_resolve_docker_flags: deploy.gpu_runtime override wins (#505/#481)` | runtime override |
| `_resolve_docker_flags: legacy deploy.runtime alias used when gpu_runtime absent (#505/#481)` | runtime legacy alias |
| `_resolve_docker_flags: legacy deploy.runtime overrides gpu_runtime at per-stage scope (resolved last, #505/#481)` | runtime per-stage precedence |
| `_resolve_docker_flags: network scalars + privileged override (#505)` | net + privileged |
| `_resolve_docker_flags: list fields append to top by default (#505)` | list append |
| `_resolve_docker_flags: list *_inherit=false switches to replace mode (#505)` | list replace |
| `generate_compose_yaml per-stage emit is byte-identical via _resolve_docker_flags (#505 golden master)` | byte-identical golden |
| `_resolve_docker_flags: security cap_add / cap_drop / security_opt append to top by default (#526)` | per-stage caps append |
| `generate_compose_yaml per-stage security.cap_add_inherit=false clears inherited caps for that stage only (#526)` | per-stage caps clear |
| `generate_compose_yaml per-stage security.cap_add_N appends to inherited caps (#526)` | per-stage caps append emit |

### test/bats/unit/deploy_spec.bats (49)

Covers the S6 (#506) deploy-generator primitive `_emit_docker_run_flags`:
the pure mapping from a resolved docker-flag record to a `docker run`
argv fragment for the self-contained `deploy.sh` field launcher. Asserts
each flag mapping plus the conditional gates that mirror the compose
emit (shm only when ipc != host, ports only under bridge, gpu `all` vs
`count=N,capabilities`, device propagation -> `-v`, runtime off/auto
skipped, ipc `private` skipped) and the deliberate omissions
(`[environment]` baked, gui dev-only).

| Test | Description |
|------|-------------|
| `privileged=true emits --privileged` | privileged |
| `gpu count=0 emits --gpus all` | gpu all |
| `gpu count>0 emits count+capabilities spec` | gpu partition |
| `gpu=false emits no --gpus` | gpu off |
| `runtime=nvidia emits --runtime=nvidia` | runtime on |
| `runtime off/auto/empty emits no --runtime` | runtime skip |
| `net host emits --network=host` | net host |
| `net bridge + name emits --network=<name>` | net named bridge |
| `net bridge without name emits no --network` | default bridge |
| `ipc host emits --ipc=host; private is skipped` | ipc gate |
| `pid host emits --pid=host` | pid host |
| `shm_size emitted only when ipc != host` | shm gate |
| `restart emitted only when set and != no` | restart gate |
| `volumes each emit -v` | volumes |
| `ports emit -p only under bridge` | ports gate |
| `plain device -> --device, propagation device -> -v` | device split |
| `caps + security_opt map to docker run flags` | caps/secopt |
| `dri_groups (space-sep) each map to --group-add` | group-add |
| `cgroup_rules map to --device-cgroup-rule` | cgroup rules |
| `environment and gui are NOT mapped (baked / dev-only)` | omissions |
| `empty record emits nothing` | empty no-op |
| `_resolve_deploy_context: resolves scalars + list strings from setup.conf` | full resolution |
| `_resolve_deploy_context: applies effective defaults for a minimal repo conf` | template-merged defaults |
| `_resolve_deploy_context: legacy [deploy] runtime alias resolves gpu_runtime_mode` | legacy alias |
| `_resolve_deploy_context: dri_groups auto detects host GIDs via SETUP_DETECT_DRI_GROUPS` | dri auto |
| `_resolve_deploy_context: dri_groups off yields empty` | dri off |
| `_generate_deploy_sh: writes an executable launcher with the expected skeleton` | launcher skeleton |
| `_generate_deploy_sh: inlines global [security] privileged + caps + devices` | global security/devices |
| `_generate_deploy_sh: gpu force inlines --gpus count + capabilities + runtime` | gpu inline |
| `_generate_deploy_sh: network host inlines --network=host` | network inline |
| `_generate_deploy_sh: omits -e (env baked) and -v (no dev binds)` | env/volume omission |
| `_generate_deploy_sh: [lifecycle] restart inlines --restart` | restart inline |
| `_generate_deploy_sh: per-stage [stage:runtime] override is applied` | per-stage override |
| `_generate_deploy_sh: per-stage security.cap_add_inherit=false clears inherited caps (#526)` | per-stage caps clear |
| `_generate_deploy_sh: per-stage security.cap_add_N appends to inherited caps (#526)` | per-stage caps append |
| `_generate_deploy_sh: consumes a passed pre-resolved ctx instead of re-resolving (#563)` | resolve-once seam |
| `_generate_deploy_sh: generated launcher is ShellCheck-clean` | shellcheck-clean output |
| `_bake_config_copy: splices COPY config/app into the target stage` | config COPY bake |
| `_bake_config_copy: handles src == out in place` | in-place bake |
| `_generate_deploy_bundle: dry-run plans build --target + save + tar.xz` | bundle plan |
| `_generate_deploy_bundle: dry-run builds from the baked Dockerfile when [environment] is set` | env-bake build |
| `_generate_deploy_bundle: dry-run builds from the plain Dockerfile when no runtime bake applies` | plain build |
| `_setup_deploy: --dry-run previews the launcher + prints the build plan` | deploy dry-run |
| `_setup_deploy: refuses in a non-interactive shell without -y` | non-tty refuse |
| `_setup_deploy: errors when the repo has no Dockerfile` | no-Dockerfile guard |
| `_setup_deploy: rejects an unknown flag` | arg validation |
| `_setup_deploy: --stage selects the target stage` | stage select |
| `main deploy routes to _setup_deploy` | dispatch wiring |

### test/bats/unit/compose_logging_spec.bats (17)

Covers `[logging]` + `[logging.<svc>]` support in
`generate_compose_yaml` (#310). Tests the global emission on every
service (devel / test / auto-emitted stage), back-compat for repos
not yet declaring `[logging]`, per-service override key-level merge
behaviour, and the two new setup.sh helpers `_parse_logging_svc_sections`
+ `_collect_logging`.

| Test | Description |
|------|-------------|
| `omits logging: block when both inputs empty (back-compat)` | Empty inputs no-op |
| `emits logging: block on devel from global [logging]` | Global → devel |
| `test service inherits global logging via extends:devel (#493)` | Global logging emitted once on devel; test inherits via extends |
| `driver-only [logging] omits options: block` | No rotation keys |
| `partial options emits only set keys` | Sparse override |
| `per-svc [logging.<svc>] overrides global key on that svc` | Override semantics |
| `per-svc [logging.<svc>] inherits keys absent in override` | Key-level merge |
| `_parse_logging_svc_sections enumerates services in file order` | Parser order |
| `_parse_logging_svc_sections ignores plain [logging] section` | Section discrimination |
| `_parse_logging_svc_sections returns empty when file does not exist` | Missing-file guard |
| `_collect_logging reads global [logging] from per-repo setup.conf` | Per-repo source |
| `_collect_logging reads per-service [logging.<svc>] sections` | Per-svc source |
| `_collect_logging returns empty when no [logging] sections anywhere` | Total absence |
| `local_path on global emits volumes mount + LOG_FILE_PATH env for devel (#328)` | Mount + env on devel |
| `local_path empty omits mount + env (back-compat) (#328)` | Empty fallback |
| `local_path on per-svc [logging.<svc>] emits LOG_FILE_PATH for that svc only (#328)` | Per-service emit |
| `local_path absolute path is passed through verbatim (#328)` | Absolute path |
| `local_path is NOT emitted as a logging.options key (driver-only options) (#328)` | local_path NOT a docker option |
| `local_path on test service emits standalone volumes block + env (#328)` | test service |
| `_sync_logging_local_paths_gitignore appends relative local_path to .gitignore (#328)` | gitignore append |
| `_sync_logging_local_paths_gitignore skips absolute paths (#328)` | Absolute skip |
| `_sync_logging_local_paths_gitignore skips ~ paths (#328)` | Tilde skip |
| `_sync_logging_local_paths_gitignore is idempotent (#328)` | Re-run no-op |
| `_sync_logging_local_paths_gitignore collects from both global + per-svc (#328)` | Multi-source |
| `_sync_logging_local_paths_gitignore is no-op when no local_path keys (#328)` | Empty no-op |
| `_sync_logging_local_paths_gitignore prunes stale managed entries on value change (#390)` | Rename prune |
| `_sync_logging_local_paths_gitignore drops marker + entries when candidates become empty (#390)` | Feature-off cleanup |
| `_sync_logging_local_paths_gitignore preserves user entries outside managed block (#390)` | User-owned untouched |
| `setup.conf [logging] comment block references in-image helper path (/usr/local/lib/base/, #368)` | Documented adoption path matches in-image COPY |
| `generate_compose_yaml emits per-stage LOG_FILE_PATH on extends:devel stage when [logging] local_path is set (#367)` | Per-svc LOG_FILE_PATH on auto-emitted extends-only stage |
| `generate_compose_yaml emits per-stage volume mount on extends:devel stage when [logging] local_path is set (#367)` | Per-svc volume mount on auto-emitted extends-only stage |
| `generate_compose_yaml does NOT emit LOG_FILE_PATH on extends:devel stage when [logging] local_path is unset (#367 back-compat)` | Zero-diff back-compat when feature unset |

### test/bats/unit/entrypoint_logging_spec.bats (8)

Behaviour of `script/docker/_entrypoint_logging.sh` — the helper
downstream repos source from their `script/entrypoint.sh` so
container stdout/stderr is tee'd to the host bind-mounted log file
when `[logging] local_path` is set (#328). Tests source the helper
under controlled `LOG_FILE_PATH` env in subshells and assert both
the host file content and the inherited stdout (preserving
`docker logs` parity).

| Test | Description |
|------|-------------|
| `entrypoint_logging is no-op when LOG_FILE_PATH unset (#328)` | Back-compat: do nothing |
| `entrypoint_logging tees stdout to LOG_FILE_PATH when set (#328)` | Happy path |
| `entrypoint_logging truncates LOG_FILE_PATH on each run (#328)` | Fresh container = fresh log |
| `entrypoint_logging creates parent dir if missing (#328)` | mkdir -p safety net |
| `entrypoint_logging warns + continues when target is a directory (#328)` | Failure-mode fallback (truncate-fail branch) |
| `entrypoint_logging warns 'cannot create' + continues when parent dir is unmakeable (#691)` | mkdir-fail branch (parent is a regular file) |
| `entrypoint_logging warns 'tee binary missing' + continues when tee absent (#691)` | tee-missing branch (stub PATH) |
| `entrypoint_logging captures stderr along with stdout (#328)` | 2>&1 redirect |

### test/bats/unit/template_spec.bats (145)

| Test | Description |
|------|-------------|
| `build.sh exists and is executable` | File check |
| `run.sh exists and is executable` | File check |
| `exec.sh exists and is executable` | File check |
| `stop.sh exists and is executable` | File check |
| `setup.sh exists and is executable` | File check |
| `test.sh exists and is executable` | File check |
| `test.sh uses set -euo pipefail` | Shell convention |
| `justfile.test exists (template CI gate)` | File check |
| `Makefile.ci no longer exists (retired for justfile.test)` | File absence (single runner) |
| `justfile.test default recipe runs the suite (bare just test)` | just recipe |
| `justfile.test has lint recipe` | just recipe |
| `justfile.test lint recipe forwards args + runs all linters by default (#650)` | `lint *args` forwards --shellcheck/--hadolint |
| `justfile.test has coverage recipe` | just recipe |
| `justfile.test upgrade recipe forwards {{args}} to ./upgrade.sh` | args passthrough |
| `justfile.test upgrade-check tolerates upgrade.sh exit 1 (update available)` | Regression #175: wrap on justfile.test |
| `Dockerfile.test-tools no longer installs make into the final image (single runner: just)` | dead make dependency stays out of final image |
| `test/smoke/test_helper.bash exists` | Directory structure |
| `test/smoke/script_help.bats exists` | Directory structure |
| `test/smoke/display_env.bats exists` | Directory structure |
| `test/bats/unit/ directory exists` | Directory structure |
| `doc/readme/ directory exists` | Directory structure |
| `doc/test/ directory exists` | Directory structure |
| `doc/changelog/ directory exists` | Directory structure |
| `build.sh references template/script/docker/setup.sh` | Path reference |
| `run.sh references template/script/docker/setup.sh` | Path reference |
| `build.sh uses set -euo pipefail` | Shell convention |
| `build.sh supports --no-cache flag` | Force rebuild flag |
| `build.sh passes --no-cache to docker compose build when set` | NO_CACHE forwarded |
| `build.sh keeps test-tools image by default (cleanup gated by CLEAN_TOOLS)` | Default keep tools |
| `build.sh supports --clean-tools flag` | Clean tools flag |
| `build.sh removes test-tools image when --clean-tools is set` | CLEAN_TOOLS forwarded |
| `run.sh uses set -euo pipefail` | Shell convention |
| `exec.sh uses set -euo pipefail` | Shell convention |
| `stop.sh uses set -euo pipefail` | Shell convention |
| `_lib.sh derives PROJECT_NAME from DOCKER_HUB_USER and IMAGE_NAME` | Shared derivation |
| `_lib.sh _compose_project wraps -p with PROJECT_NAME` | Shared compose wrapper |
| `_lib.sh defines _load_env helper` | Shared env loader |
| `_lib.sh defines _compute_project_name helper` | Shared helper |
| `_lib.sh defines _compose wrapper` | Shared compose wrapper |
| `build.sh routes compose call through _compose_project` | Uses shared lib |
| `run.sh routes compose calls through _compose_project` | Uses shared lib |
| `exec.sh routes compose call through _compose_project` | Uses shared lib |
| `stop.sh routes compose call through _compose_project` | Uses shared lib |
| `exec.sh loads .env via _load_env helper` | Uses shared lib |
| `stop.sh loads .env via _load_env helper` | Uses shared lib |
| `stop.sh no longer needs orphan cleanup (run.sh devel uses up not run)` | No more orphan |
| `run.sh devel target uses compose up -d (not compose run --name)` | up + exec model |
| `run.sh devel branch uses compose exec to enter shell` | up + exec model |
| `run.sh devel branch installs trap to auto-down on exit` | Auto cleanup |
| `run.sh _devel_cleanup uses short timeout to avoid 10s grace period` | Fast exit |
| `run.sh non-devel TARGET: foreground 'up', CMD-override 'run --rm' (#458/#679)` | One-shot stages: no-CMD up, CMD run --rm |
| `run.sh devel branch does not use 'compose run --name'` | Old pattern gone |
| `run.sh refuses when the default container is already running` | collision |
| `base is single-instance: no --instance flag remains (#600)` | single-instance (no flag) |
| `base is single-instance: no INSTANCE_SUFFIX remains (#600)` | single-instance (no suffix) |
| `build.sh supports --dry-run flag` | --dry-run |
| `run.sh supports --dry-run flag` | --dry-run |
| `exec.sh supports --dry-run flag` | --dry-run |
| `stop.sh supports --dry-run flag` | --dry-run |
| `build.sh -h shows --dry-run in help` | --dry-run help |
| `run.sh -h shows --dry-run in help` | --dry-run help |
| `exec.sh -h shows --dry-run in help` | --dry-run help |
| `stop.sh -h shows --dry-run in help` | --dry-run help |
| `exec.sh checks container is running before exec` | precheck |
| `exec.sh precheck error mentions run.sh hint` | friendly hint |
| `exec.sh exits non-zero with friendly hint when container not running` | precheck e2e |
| `exec.sh --dry-run skips precheck and prints compose command` | dry-run e2e |
| `script/docker/i18n.sh exists` | i18n module exists |
| `Dockerfile.test-tools includes bats-mock` | bats-mock available in test image |
| `Dockerfile.test-tools source-builds kcov in a builder stage (#686)` | kcov compiled from source (not in alpine repos) |
| `Dockerfile.test-tools COPYs the kcov binary into the final image (#686)` | kcov binary present in final image |
| `Dockerfile.test-tools installs kcov's runtime shared libs in the final stage (#686)` | kcov runtime libs (libstdc++/libcurl/libdw/...) present |
| `Dockerfile.test-tools ARG TARGETARCH has no default value (must not shadow BuildKit auto-inject)` | multi-arch build regression |
| `i18n.sh defines _detect_lang function` | _detect_lang in i18n.sh |
| `build.sh sources _lib.sh` | build.sh uses shared lib |
| `run.sh sources _lib.sh` | run.sh uses shared lib |
| `exec.sh sources _lib.sh` | exec.sh uses shared lib |
| `stop.sh sources _lib.sh` | stop.sh uses shared lib |
| `_lib.sh sources i18n.sh (delegates language detection)` | _lib delegates i18n |
| `setup.sh sources i18n.sh` | setup.sh uses shared i18n |
| `build.sh -h works when i18n.sh is missing (consumer Dockerfile /lint scenario)` | i18n fallback |
| `run.sh -h works when i18n.sh is missing` | i18n fallback |
| `exec.sh -h works when i18n.sh is missing` | i18n fallback |
| `stop.sh -h works when i18n.sh is missing` | i18n fallback |
| `setup.sh does not redefine _detect_lang` | No duplication |
| `.version file exists in template root` | Version file check |
| `upgrade.sh reads version from template/.version` | .version path |
| `upgrade.sh does not reference legacy VERSION or .template_version` | Legacy refs purged |
| `upgrade.sh runs init.sh after subtree pull` | Sync symlinks |
| `upgrade.sh supports --gen-conf flag` | Flag exists |
| `upgrade.sh --gen-conf delegates to init.sh --gen-conf` | Delegation |
| `upgrade.sh --help mentions --gen-conf` | Help text |
| `upgrade.sh updates main.yaml @tag without clobbering release-worker.yaml` | sed regression |
| `upgrade.sh main.yaml sed handles semver pre-release tags (RC → RC)` | `-rcN-rcN` regression |
| `upgrade.sh main.yaml sed handles stable → stable + RC → stable transitions` | RC → stable cleanup |
| `build-worker.yaml: no legacy in-job test-tools build step` | v0.9.13 GHCR migration |
| `build-worker.yaml: declares test_tools_version input` | v0.10.1 input replaces GITHUB_WORKFLOW_REF parse |
| `build-worker.yaml: does not resurrect the GITHUB_WORKFLOW_REF parse step` | regression guard |
| `build-worker.yaml: test build passes TEST_TOOLS_IMAGE from inputs` | build-arg wiring |
| `build-worker.yaml: runtime-test build forwards TEST_TOOLS_IMAGE (#647 prerequisite)` | runtime-test COPY --from=test-tools-stage needs the pinned image too |
| `Dockerfile.example has ARG TEST_TOOLS_IMAGE with test-tools:local default` | ARG default |
| `Dockerfile.example FROM ${TEST_TOOLS_IMAGE} AS test-tools-stage` | named stage alias |
| `Dockerfile.example test stage copies from test-tools-stage, not test-tools:local` | stage rename migration |
| `Dockerfile.example runtime-test shows commented Bats COPY from test-tools-stage (#647)` | generalized -test toolchain (style (b) Bats smoke) |
| `Dockerfile.example documents -test stages stay FROM the real stage + heavier-is-fine (#647)` | anti-pattern guard + consumer-owns-flavour-tools |
| `Dockerfile.example declares ENV TZ (matches downstream fleet, #210)` | runtime $TZ alignment |
| `Dockerfile.example declares ENV LANGUAGE=en_US:en (matches downstream fleet, #210)` | runtime $LANGUAGE alignment |
| `Dockerfile.example runtime documents 3-process-kinds env rationale (#657)` | PID 1 / interactive / non-interactive complementary mechanisms |
| `Dockerfile.example runtime shows commented /etc/bash.bashrc source example (#657)` | opt-in interactive-exec env source, consumer supplies ROS line |
| `Dockerfile.example runtime does NOT bake ROS env into ENV (#657 fragility guard)` | no ENV LD_LIBRARY_PATH / PYTHONPATH baked |
| `release-test-tools.yaml exists and pushes to ghcr.io/ycpss91255-docker/test-tools` | GHCR publisher |
| `release-test-tools.yaml declares packages:write permission` | ghcr auth scope |
| `release-test-tools.yaml builds multi-arch (amd64 + arm64)` | arch coverage |
| `release-test-tools.yaml uses template-repo-local Dockerfile path` | no subtree path confusion |
| `release-worker.yaml does not cp compose.yaml into the release archive` | v0.10.1 cp-list regression |
| `release-worker.yaml cp-list still includes Dockerfile + scripts` | positive cp-list guard |
| `build.sh does not source setup.sh (#49 Phase B-1)` | structural guard for #101 class |
| `run.sh does not source setup.sh (#49 Phase B-1)` | structural guard for #101 class |
| `build.sh uses subprocess check-drift (#49 Phase B-1)` | drift via subcommand |
| `run.sh uses subprocess check-drift (#49 Phase B-1)` | drift via subcommand |
| `run.sh contains XDG_SESSION_TYPE check` | X11/Wayland branch |
| `run.sh contains xhost +SI:localuser for wayland` | Wayland xhost |
| `run.sh contains xhost +local: for X11` | X11 xhost |
| `setup.sh default _base_path uses /..` | Path resolution |
| `setup.sh default _base_path uses double parent traversal` | Repo root traversal |
| `Dockerfile.example copies _entrypoint_logging.sh to /usr/local/lib/base/ in devel stage (#368)` | In-image helper COPY + devel-stage placement |
| `Dockerfile.example commented runtime stage shows _entrypoint_logging.sh COPY example (#368)` | Runtime opt-in scaffold |
| `_entrypoint_logging.sh header documents in-image source-line (no $USER, no work/.base) (#368)` | Helper Usage docstring positive + negative regression guards |

### test/bats/unit/bashrc_spec.bats (15)

| Test | Description |
|------|-------------|
| `defines alias_func` | Function definition |
| `defines color_git_branch` | Function definition |
| `defines ebc alias` | Alias definition |
| `defines sbc alias` | Alias definition |
| `alias_func is called` | Function call |
| `color_git_branch is called` | Function call |
| `color_git_branch sets PS1` | PS1 setting |
| bashrc.d bootstrap loop (sources `~/.bashrc.d/*.sh`, dir guard, `.gitkeep` present) | drop-in loader (3) |
| `host-group drop-in exists` | #589 drop-in shipped |
| `host-group drop-in defines name_host_groups and invokes it only when interactive` | #589 structure |
| `host-group drop-in uses getent + sudo groupadd` | #589 mechanism |
| `name_host_groups: a nameless gid triggers sudo groupadd hostgrp<gid>` | #589 behaviour (mocked) |
| `name_host_groups: a named gid does not trigger groupadd` | #589 idempotent skip (mocked) |

### test/bats/unit/ci_spec.bats (46)

| Test | Description |
|------|-------------|
| `_run_shellcheck: invokes shellcheck against every expected script` | Wired-file regression guard |
| `_run_shellcheck: picks up every .sh file in script/docker/` | `find` covers new scripts |
| `_run_shellcheck: exits non-zero when shellcheck fails on any script` | Strict-mode propagation |
| `_run_via_compose: routes default mode to the ci service with COVERAGE=0` | Service routing — fast path |
| `_run_via_compose: routes coverage mode to the coverage service with COVERAGE=1` | Service routing — coverage path |
| `_run_tests: passes --jobs N when parallel is on PATH` | Parallel-present branch |
| `_run_tests: omits --jobs when parallel is absent (graceful fallback)` | Parallel-missing branch |
| `main: dispatches no-flag default to the ci service` | End-to-end default dispatch |
| `main: dispatches --coverage to the coverage service` | End-to-end --coverage dispatch |
| `main --bats-path: dispatches a single spec to the ci service with BATS_FILE + BATS_ONLY=1` | #523 single-file dispatch |
| `main --bats-path: accepts a directory` | #523 directory path |
| `main --bats-path: non-existent path dies with ci_bats_path_not_found` | #523 missing-path guard |
| `main --bats-path: test/bats/behavioural/ path dies with a clear hint` | #523 behavioural guard |
| `main --bats-path + --coverage is rejected (ci_bats_path_coverage)` | #523 coverage-combo guard |
| `main --filter: dispatches with BATS_FILTER + BATS_ONLY=1 and no BATS_FILE` | #523 filter-only dispatch |
| `main: unknown option dies with ci_unknown_option (#692)` | #692 unknown-flag guard |
| `main: --hadolint without --lint dies (narrowing flag, not standalone) (#692)` | #692 narrowing-flag typo guard |
| `main --ci: unknown LINT_TOOL dies with ci_unknown_lint_tool (#692)` | #692 LINT_TOOL validation |
| `_run_bats_path: BATS_FILE runs bats on that path; BATS_FILTER appends -f` | #523 single-path runner |
| `_run_bats_path: filter-only runs bats across unit + integration` | #523 filter-only runner |
| `drivers: bats.sh, shellcheck.sh and hadolint.sh driver files exist` | #650 driver files present (incl. hadolint) |
| `drivers: test.sh sources all per-tool drivers` | #650 dispatcher sources every driver |
| `drivers: the bats runners live in drivers/bats.sh, not test.sh` | #650 bats runners moved out |
| `drivers: _run_shellcheck lives in drivers/shellcheck.sh, not test.sh` | #650 shellcheck moved out |
| `drivers: _run_hadolint lives in drivers/hadolint.sh, not test.sh (#650)` | #650 hadolint in its driver |
| `drivers: are sourced libraries (no top-level main invocation)` | #650 driver is a library |
| `drivers: _run_shellcheck also lints the driver files themselves` | #650 driver self-shellcheck |
| `_run_hadolint: lints both template-owned Dockerfiles with the shared config` | #650 single-source Dockerfile list + config |
| `_run_hadolint: invokes hadolint once per Dockerfile (no extra targets)` | #650 exactly two invocations |
| `_run_hadolint: dies with a clear message when hadolint is absent` | #650 host-missing-binary guard |
| `_run_hadolint: exits non-zero when hadolint fails on any Dockerfile` | #650 propagates lint failure |
| `_shard_unit_files: same shard index selects the same slice as _run_unit_shard's partition (#615)` | #615 coverage matrix mirrors unit matrix |
| `_shard_unit_files: partition is exhaustive + disjoint across all shards of T (#615)` | #615 round-robin invariant (each slice runs once) |
| `_shard_unit_files: rejects an out-of-range shard spec (#615, #692)` | #615 shard-spec validation (asserts message) |
| `_shard_unit_files: rejects a no-slash shard spec (#692)` | #692 missing-slash format guard |
| `_shard_unit_files: rejects a non-numeric shard spec (#692)` | #692 non-numeric guard |
| `_shard_unit_files: dies ci_empty_shard when a valid shard matches no files (#692)` | #692 empty-slice guard |
| `_run_coverage: shard N/T kcov's only that unit slice, not the whole tree (#615)` | #615 sharded kcov targets |
| `_run_coverage: last shard also kcov's the integration suite (#615)` | #615 integration on last shard |
| `_run_coverage: non-last shard does NOT kcov the integration suite (#615)` | #615 no integration duplication |
| `_run_coverage: no argument keeps the full-suite path (unit + integration) (#615)` | #615 local full-coverage path |
| `main --coverage-shard: routes to the coverage service with COVERAGE_SHARD set (#615)` | #615 shard env plumbing |
| `main --ci with COVERAGE=1 skips the lint phase (lint is a separate matrix concern) (#615)` | #615 coverage path skips lint |
| `main --coverage-shard + --bats-path is rejected (coverage mode guard) (#615)` | #615 single-path/coverage combo guard |
| `_behavioural_setup: dies ci_no_docker_socket when /var/run/docker.sock is absent (#692)` | #692 behavioural socket guard |
| `_behavioural_setup: dies ci_no_docker_cli when docker is not on PATH (#692)` | #692 behavioural docker-CLI guard |

### test/bats/unit/issueref_lint_spec.bats (17)

| Test | Description |
|------|-------------|
| `_run_issueref: flags a bare #NNN in a leading comment` | Leading comment ref detected |
| `_run_issueref: flags a bare #NNN in a trailing comment` | Trailing comment ref detected |
| `_run_issueref: flags the (#NNN) paren form in a comment` | Parenthesised ref detected |
| `_run_issueref: flags a bare 2-digit ref (lower accept boundary) (#692)` | #692 2-digit lower bound flagged |
| `_run_issueref: flags a bare 4-digit ref (upper accept boundary) (#692)` | #692 4-digit upper bound flagged |
| `_run_issueref: flags refs in .bats helper comments (not @test names)` | Helper comment flagged, @test name kept |
| `_run_issueref: passes clean on a tree with no comment refs` | Clean tree passes |
| `_run_issueref: does NOT flag a #NNN inside a string literal` | String-literal ref kept |
| `_run_issueref: does NOT flag ADR-0000xxxx references` | ADR refs kept |
| `_run_issueref: does NOT flag DL/SC directive codes or version tags` | DL/SC/version tokens kept |
| `_run_issueref: does NOT flag word-prefixed cross-repo refs` | Cross-repo refs kept |
| `_run_issueref: does NOT flag single-digit or 5+-digit numbers` | Out-of-range numbers kept |
| `_run_issueref: does NOT treat a ${#arr[@]} expansion as a comment` | Parameter expansion kept |
| `_run_issueref: does NOT flag a #NNN opener in heredoc usage prose` | Heredoc usage prose kept |
| `_ISSUEREF_AWK: flags a 3-digit ref identically under every awk engine` | Detection parity across busybox-awk / mawk / gawk |
| `_ISSUEREF_AWK: flags the 2-digit and 4-digit accept boundaries under every awk engine (#692)` | #692 boundary parity across engines |
| `_ISSUEREF_AWK: keeps the must-keep cases clean under every awk engine` | Exemption parity across busybox-awk / mawk / gawk |

### test/bats/unit/lint_bare_stderr_spec.bats (5)

Unit tests for `script/test/lint_bare_stderr.sh` (#692), the "all stderr
goes through lib/log.sh helpers" lint. The lint takes the repo root as
`$1`, so the spec drives it against synthesized fixture trees laid out
like the real repo (sources under `downstream/script/docker/**`, tests
under `script/test/**`). A real-repo-root clean-tree case guards against
the path-drift bug (an empty find root passing vacuously) by proving the
scan actually walks the populated `downstream/script/docker` tree.

| Test | Description |
|------|-------------|
| `flags a bare 'printf ... >&2' under downstream/script/docker (#692)` | exit 1 + violation line on the correct tree |
| `exits 0 on a clean tree (no bare stderr) (#692)` | clean fixture passes silently |
| `does NOT flag an allowlisted _log_* line (#692)` | `_log_*` line exempt |
| `does NOT flag an allowlisted getopts / [y/N] prompt line (#692)` | getopts / prompt lines exempt |
| `the real repo tree (default root) is clean (#692)` | live-tree guard against path drift |

### test/bats/unit/init_spec.bats (40)

Unit coverage for `init.sh` helpers that previous rounds exercised only
through the Level-1 integration test. Complements
`test/bats/integration/init_new_repo_spec.bats` by locking edge cases that
are hard to trigger from a real `bash template/init.sh` invocation
(network-down version detection, main.yaml `@ref` fallback,
`_create_version_file` with no argument).

| Test | Description |
|------|-------------|
| `_detect_template_version: parses newest vX.Y.Z tag from git ls-remote` | Happy path + head -1 |
| `_detect_template_version: returns empty when git ls-remote fails` | Network-down fallback |
| `_detect_template_version: returns empty when no v*.*.* tags exist` | Nothing to match |
| `_detect_template_version: ignores non-semver tags (e.g. rc suffixes)` | Regex filters rc / pre-release |
| `_detect_template_version: reads .version file when present (no network)` | .version file priority |
| `_detect_template_version: .version file takes priority over git ls-remote` | Local-first resolution |
| `_create_new_repo: main.yaml uses given ref in workflow @ref` | Ref threading |
| `_create_new_repo: main.yaml falls back to @main when ref arg omitted` | Default ref |
| `_create_new_repo: main.yaml falls back to @main when ref arg is empty` | Empty-string → `@main` |
| `_create_new_repo: does NOT generate .env.example (image name via setup.conf)` | setup.conf rules drive IMAGE_NAME |
| `_create_symlinks: places 7 wrapper symlinks under script/ (#330)` | 7 wrappers under script/ with ../ targets; justfile at root, no Makefile |
| `_create_symlinks: places justfile at root with the direct .base/ target (#545)` | root justfile -> .base/script/docker/justfile |
| `_create_symlinks: does NOT symlink Makefile and cleans a stale root Makefile symlink (#546)` | Makefile retired; stale symlink dropped on upgrade |
| `_create_symlinks: replaces a stale file at the new symlink path under script/ (#330)` | Re-init over stale file at script/build.sh |
| `_create_symlinks: removes stale root *.sh symlinks left by pre-#330 init (#330 migration loop)` | Migration: plant 7 root symlinks, re-run, all gone + script/ created |
| `_create_symlinks: keeps custom .hadolint.yaml when it differs` | Custom-hadolint preservation |
| `_preflight_just: warns and exits 0 when just is absent (#607)` | Missing runner -> non-fatal WARN |
| `_preflight_just: emits the init_just_missing event under LOG_FORMAT=json (#607)` | Structured event wired through |
| `_preflight_just: install hint points at the documented methods (#607)` | Warning carries install pointer |
| `_preflight_just: silent and exits 0 when just is present (#607)` | Runner present -> no warning |
| `_bootstrap_just: no-op when just is already on PATH (#607)` | Opt-in bootstrap skips when installed |
| `_bootstrap_just: runs the official installer into ~/.local/bin when absent (#607)` | Opt-in installer pipeline to ~/.local/bin |
| `_bootstrap_just: aborts with a clear error when the installer pipeline fails (#692)` | #692 installer-failure _error path |
| `_call_setup: warns but returns 0 when setup.sh exits non-zero (#692)` | #692 warn-on-failure degrade |
| `_call_setup: skips with a notice when setup.sh is absent (#692)` | #692 skip-when-absent branch |
| `_call_setup: returns 0 on a setup.sh that succeeds (#692)` | #692 happy path no-noise |
| `_gen_setup_conf errors when the template setup.conf is absent (#692)` | #692 missing-template _error |

### test/bats/unit/smoke_helper_spec.bats (19)

Exercises the runtime assertion helpers shipped in
`test/smoke/test_helper.bash` (used by downstream-repo smoke specs via
`load "${BATS_TEST_DIRNAME}/test_helper"`).

| Test | Description |
|------|-------------|
| `assert_cmd_installed passes when cmd is on PATH` | Happy path |
| `assert_cmd_installed fails with descriptive message when cmd missing` | Missing cmd |
| `assert_cmd_installed errors when cmd arg missing` | Required arg check |
| `assert_cmd_runs passes when cmd exits 0` | Happy path |
| `assert_cmd_runs uses custom version flag when given` | Custom flag |
| `assert_cmd_runs fails when cmd exits non-zero` | Broken binary |
| `assert_cmd_runs fails when cmd is not installed` | Missing cmd |
| `assert_file_exists passes when file is a regular file` | Happy path |
| `assert_file_exists fails when path is missing` | Missing path |
| `assert_file_exists fails when path is a directory` | Type check |
| `assert_dir_exists passes when path is a directory` | Happy path |
| `assert_dir_exists fails when path is missing` | Missing path |
| `assert_dir_exists fails when path is a file` | Type check |
| `assert_file_owned_by passes when owner matches` | Happy path |
| `assert_file_owned_by fails with owner diff when user mismatches` | Owner mismatch |
| `assert_file_owned_by fails when path missing` | Missing path |
| `assert_pip_pkg passes when pip show returns 0` | Package installed |
| `assert_pip_pkg fails when pip show returns non-zero` | Package missing |
| `assert_pip_pkg fails when pip is not installed` | pip itself missing |

### test/bats/unit/terminator_config_spec.bats (10)

| Test | Description |
|------|-------------|
| `has [global_config] section` | Config section |
| `has [keybindings] section` | Config section |
| `has [profiles] section` | Config section |
| `has [layouts] section` | Config section |
| `has [plugins] section` | Config section |
| `profiles has [[default]]` | Default profile |
| `default profile disables system font` | Font setting |
| `default profile has infinite scrollback` | Scrollback setting |
| `layouts has Window type` | Window layout |
| `layouts has Terminal type` | Terminal layout |

### test/bats/unit/terminator_setup_spec.bats (8)

| Test | Description |
|------|-------------|
| `check_deps returns 0 when terminator is installed` | Dependency check |
| `check_deps fails when terminator is not installed` | Missing dep |
| `_entry_point calls main when deps pass` | Entry point |
| `_entry_point fails when deps missing` | Entry point fail |
| `main creates terminator config directory` | Config dir |
| `main copies terminator config file` | Config copy |
| `main calls chown with correct user and group` | Permissions |
| `script runs entry_point when executed directly` | Direct-run guard |

### test/bats/unit/tmux_conf_spec.bats (12)

| Test | Description |
|------|-------------|
| `defines prefix key` | tmux prefix |
| `sets default shell to bash` | Shell setting |
| `sets default terminal` | Terminal setting |
| `enables mouse support` | Mouse |
| `enables vi status-keys` | vi mode |
| `enables vi mode-keys` | vi mode |
| `defines split-window bindings` | Split bindings |
| `defines reload config binding` | Reload binding |
| `enables status bar` | Status bar |
| `sets status bar position` | Status bar position |
| `declares tpm plugin` | tpm plugin |
| `initializes tpm at end of file` | tpm init |

### test/bats/unit/tmux_setup_spec.bats (9)

| Test | Description |
|------|-------------|
| `check_deps returns 0 when tmux and git are installed` | Dependency check |
| `check_deps fails when tmux is not installed` | Missing tmux |
| `check_deps fails when git is not installed` | Missing git |
| `_entry_point calls main when deps pass` | Entry point |
| `_entry_point fails when deps missing` | Entry point fail |
| `main clones tpm repository` | tpm clone |
| `main creates tmux config directory` | Config dir |
| `main copies tmux.conf to config directory` | Config copy |
| `script runs entry_point when executed directly` | Direct-run guard |

### test/bats/unit/upgrade_spec.bats (39)

Unit tests for `upgrade.sh` helpers. Uses the sed-range pattern to extract
one function at a time into a minimal harness (with `_log` / `_error`
stubs), so each helper runs in a sandboxed git repo without needing to
source the full `upgrade.sh` (which would trigger its top-level
`cd REPO_ROOT`).

Covers: `_warn_config_drift` (silent / fires on drift / diff hint),
the three safety guards added after the v0.9.7 Jetson incident
(`_require_git_identity`, `_require_clean_merge_state`,
`_verify_subtree_intact` with rollback), structural invariants that
pin call-ordering in `_upgrade` (identity check runs before subtree
pull, integrity verification runs after, pre-pull HEAD is snapshotted
for rollback), the R1+ rewrite of `_verify_subtree_intact` (#477)
that replaces the hard-coded marker list with a path-agnostic
structural invariant + target-version match (catches destructive
fast-forward, empty subtree, malformed `.version`, and wrong-tag
pulls), and the SemVer §11-aware `_semver_cmp` + `_check`
behavior added for issue #156 (prerelease ahead of latest stable
must not be reported as "needing downgrade").

| Test | Description |
|------|-------------|
| `_warn_config_drift silent when no template/config in HEAD` | Initial setup |
| `_warn_config_drift silent when pre and post hashes match` | No drift |
| `_warn_config_drift prints WARNING + diff hint when hashes differ` | Drift reported |
| `upgrade.sh defines _warn_config_drift` | Helper present |
| `upgrade.sh invokes _warn_config_drift after subtree pull` | Call site present |
| `upgrade.sh captures pre-pull template/config tree hash` | Snapshot taken |
| `_require_git_identity succeeds when name + email are set` | Happy path |
| `_require_git_identity fails when user.email is unset` | Email guard |
| `_require_git_identity fails when user.name is unset` | Name guard |
| `_require_clean_merge_state succeeds in clean repo` | Happy path |
| `_require_clean_merge_state fails when MERGE_HEAD exists` | Mid-merge guard |
| `_require_clean_merge_state fails when rebase-merge dir exists` | Mid-rebase guard |
| `_verify_subtree_intact succeeds when subtree dir + version match target (#477 happy path)` | R1+ happy path |
| `_verify_subtree_intact rolls back when template/.version is missing` | Destructive-FF rollback |
| `_verify_subtree_intact rolls back when template/ dir is missing (#477 destructive-FF detector)` | R1+ dir-missing rollback |
| `_verify_subtree_intact rolls back when template/ dir is empty (#477)` | R1+ empty-dir rollback |
| `_verify_subtree_intact rolls back when .version content is not semver (#477)` | R1+ semver-shape guard |
| `_verify_subtree_intact rolls back when .version does not match target (#477 wrong-tag detector)` | R1+ wrong-tag detector |
| `_rollback_subtree_pull surfaces a failed reset instead of falsely reporting 'restored' (#700)` | Failed-reset escalation (no false 'restored' message) |
| `upgrade.sh calls _require_git_identity before subtree pull` | Pre-flight ordering |
| `upgrade.sh calls _verify_subtree_intact after subtree pull with target version (#477)` | Post-flight ordering + R1+ caller integration |
| `upgrade.sh snapshots pre-pull HEAD for rollback` | Rollback anchor |
| `_semver_cmp: equal versions return 0` | Equality |
| `_semver_cmp: lower core returns 1` | Behind core |
| `_semver_cmp: higher core returns 2` | Ahead core |
| `_semver_cmp: pre-release < final at same core (rc1 < 0.12.0)` | SemVer §11 a |
| `_semver_cmp: final > pre-release at same core (0.12.0 > rc1)` | SemVer §11 b |
| `_semver_cmp: rc1 < rc2 (lex pre-release ordering)` | Pre-release order |
| `_semver_cmp: rc2 > rc1` | Pre-release order |
| `_semver_cmp: pre-release of newer beats older final (0.12.0-rc1 > 0.11.0)` | Cross-core |
| `_semver_cmp: older final < pre-release of newer (0.11.0 < 0.12.0-rc1)` | Cross-core |
| `_check: equal versions report up-to-date and exit 0` | Happy equal |
| `_check: behind latest reports update available and exits 1` | Behind |
| `_check: prerelease ahead of latest stable exits 0 (issue #156 case)` | Regression #156 |
| `_check: stable later than latest stable exits 0 (defensive)` | Local-only tag |
| `_check: prerelease behind latest stable proposes upgrade (rc1 → 0.12.0)` | Leave prerelease |
| `_get_latest_version: returns 0 even when internal pipe fails (bash 5.3 set-e safety)` | Alpine bash 5.3 errexit-from-cmdsub workaround (lock the `\|\| true` guard) |
| `_get_latest_version: empty result feeds _check's 'Could not fetch' guard` | Empty result still surfaces real fetch failures |
| `_upgrade refuses to downgrade from a newer local version` | Implicit-downgrade guard |

### test/bats/unit/conf_accessor_spec.bats (13)

Unit tests for the `conf.sh` opaque accessor interface (#564 / #563): `_conf_load`
loads a file into a named handle, `_conf_get` reads a value by (section, key)
with an optional default, `_conf_sections` lists section names, `_conf_list`
lists a section's keys, `_conf_load_merged` loads a template+repo section-replace
merge into a handle, and `_conf_list_sorted` returns `prefix_N` values in numeric
order (skipping empties) -- all without callers touching the internal
parallel-array representation or the `<section>.<key>` namespacing rule.

Dirty-input + error-path coverage (#689) pins the parser/accessor
contracts on hand-edited / malformed setup.conf:

| Test | Description |
|------|-------------|
| `_conf_get: duplicate key within a section -- last occurrence wins (#689)` | Override semantics (merge + re-save) |
| `_conf_list: a section reopened later in the file keeps entries from both occurrences (#689)` | Reopened section appends; header deduped |
| `_conf_get: inline '#' comment text is KEPT in the value (no inline-comment support) (#689)` | Trailing `# ...` is literal (only leading-# stripped) |
| `_conf_sections: section header with internal whitespace is NOT trimmed ([ deploy ] != deploy) (#689)` | Interior spaces kept in captured name |
| `_conf_load: an unterminated section header ([deploy without ]) drops its keys (#689)` | No header match -> keys lost, no crash |
| `_conf_list_sorted skips non-numeric list suffixes (mount_x / mount_ / mount_2b) (#689)` | Numeric-suffix guard reject path |
| `_upsert_conf_value leaves the original file intact when mktemp fails (#700)` | Guarded mktemp -> no clobber/truncate on temp-create failure |
| `_write_setup_conf leaves the destination intact when its temp file cannot be created (#700)` | Temp+atomic-mv -> no in-place truncate data-loss window |

### test/bats/unit/gitignore_spec.bats (29)

Unit tests for `template/script/docker/lib/gitignore.sh` — the canonical
`.gitignore` set + sync/untrack helpers introduced for issue #172.

| Test | Description |
|------|-------------|
| `_canonical_gitignore_entries: emits exactly the 7 canonical lines` | Single source of truth |
| `_canonical_gitignore_entries: list is stable order` | Deterministic output |
| `_sync_gitignore: creates the file when missing, with marker block + all entries` | Greenfield |
| `_sync_gitignore: empty file gets marker block + all entries appended` | Empty file |
| `_sync_gitignore: file with all entries already present is a no-op` | Already-synced |
| `_sync_gitignore: appends only missing entries when subset already present` | Drift fill-in |
| `_sync_gitignore: preserves user-defined lines (bridge.yaml, .env.gpg, .claude/)` | User-line preservation |
| `_sync_gitignore: idempotent — second invocation produces no further changes` | Idempotency |
| `_sync_gitignore: no duplicate canonical lines after re-run` | No-dup invariant |
| `_sync_gitignore: ends with newline so future appends start on their own line` | Trailing-newline guarantee |
| `_sync_gitignore: documented constraint -- CRLF entries are not matched (LF-only) (#692)` | #692 LF-only presence-match constraint |
| `_sync_logging_gitignore: documented constraint -- a '..' traversal is wrapped verbatim (#692)` | #692 `..` path wrapped as-is |
| `_sync_logging_gitignore: documented constraint -- a space-bearing path is wrapped verbatim (#692)` | #692 space path wrapped as-is |
| `_untrack_canonical_in_repo: git rm --cached for tracked compose.yaml` | 15-repo drift fix |
| `_untrack_canonical_in_repo: leaves untracked files alone` | Scope guard |
| `_untrack_canonical_in_repo: no-op when no canonical files tracked` | Healthy-repo no-op |
| `_untrack_canonical_in_repo: handles tracked coverage/ directory` | Directory entry |
| `_untrack_canonical_in_repo: idempotent — second run succeeds without error` | Re-run safety |
| `_untrack_canonical_in_repo: untracks all canonical entries that match` | Multi-entry sweep |

### test/bats/unit/dockerignore_spec.bats (11)

Unit tests for the `.dockerignore` canonical-sync helpers in
`script/docker/lib/gitignore.sh` (#604). `_canonical_dockerignore_entries`
delegates to `_canonical_gitignore_entries` (a derived artifact not worth
committing is not worth shipping in the build context, so the two share a
single source and never drift); `_sync_dockerignore` + `_sync_gitignore`
are thin wrappers over the shared `_sync_managed_entries` mechanism.

| Test | Description |
|------|-------------|
| `_canonical_dockerignore_entries: emits the derived-artifact set` | Membership |
| `_canonical_dockerignore_entries: shares the single canonical source with gitignore (no drift)` | Anti-drift invariant |
| `_canonical_dockerignore_entries: list is stable order` | Deterministic output |
| `_canonical_dockerignore_entries: does NOT include log/ (owned by #606)` | Scope guard |
| `_sync_dockerignore: creates the file when missing, with marker + all entries` | Greenfield |
| `_sync_dockerignore: file with all entries already present is a no-op` | Already-synced |
| `_sync_dockerignore: appends only missing entries when subset present` | Drift fill-in |
| `_sync_dockerignore: preserves hand-maintained build-context lines` | User-line preservation |
| `_sync_dockerignore: idempotent — second run leaves the file unchanged` | Idempotency |
| `_sync_dockerignore: marker added only once across re-syncs` | Single-marker invariant |
| `_sync_dockerignore: file without trailing newline gets one before append` | Trailing-newline guard |

### test/bats/integration/init_new_repo_spec.bats (50)

End-to-end verification that `init.sh` produces a complete repo skeleton in
an empty directory. **Level 1** (file generation only, no Docker). The
**Level 2** equivalent (real `build.sh` / `run.sh` / `exec.sh` / `stop.sh`)
runs as the `integration-e2e` job in `.github/workflows/self-test.yaml`,
which has access to a Docker daemon on the host runner.

| Test | Description |
|------|-------------|
| `init.sh detects empty dir and creates new repo skeleton` | Smoke |
| `new repo: Dockerfile is copied from template` | Dockerfile gen |
| `new repo: compose.yaml exists and references the repo name` | compose gen |
| `new repo: .env.example is NOT generated (image name via setup.conf rules)` | setup.conf rules drive IMAGE_NAME |
| `new repo: script/entrypoint.sh exists and is executable` | entrypoint gen |
| `new repo: script/entrypoint.sh sources [logging] helper by default (refs #364)` | default in-image helper source line + comment present; ${USER} / /home/ absent (regression guards) |
| `new repo: smoke test skeleton exists for the repo` | smoke skeleton |
| `new repo: .github/workflows/main.yaml exists with reusable workflow ref` | CI gen |
| `new repo: main.yaml grants permissions: contents: write` | #62 release perms |
| `new repo: .gitignore exists` | gitignore |
| `new repo: doc/ tree exists with README translations` | i18n docs |
| `new repo: doc/test/TEST.md exists` | TEST.md gen |
| `new repo: doc/changelog/CHANGELOG.md exists` | CHANGELOG gen |
| `new repo: build.sh symlink lives under script/, not root (#330)` | symlink target moved to script/build.sh |
| `new repo: 7 wrapper symlinks under script/, justfile at root (#330, #546)` | symlink set: 7 wrappers + justfile root, no Makefile |
| `new repo: config/ is an empty placeholder (template#254 layered override)` | config placeholder |
| `new repo: init.sh preserves pre-existing config/ directory (no clobber)` | config preservation |
| `new repo: init.sh drops stale config symlink before creating placeholder` | config-symlink drop |
| `Dockerfile.example references CONFIG_SRC="config" (not .base/config)` | CONFIG_SRC default |
| `Dockerfile.example has layered config COPY chain (template#254)` | layered COPY order |
| `Dockerfile.example declares ENV HOME before WORKDIR ${HOME}/work (#334)` | HOME env directive |
| `Dockerfile.example sets up bashrc.d drop-in directory (template#254)` | bashrc.d setup |
| `new repo: Dockerfile contains _entrypoint_logging.sh in-image COPY (#368)` | End-to-end check on init.sh-generated repo |
| `new repo: .base/.version exists (no legacy VERSION / .template_version)` | version file |
| `new repo: re-running init.sh on the result is idempotent` | idempotent |
| `new repo: init.sh creates setup_tui.sh symlink under script/ (not legacy tui.sh)` | setup_tui under script/ |
| `new repo: init.sh removes stale tui.sh symlink from earlier versions (#330 stale-removal loop)` | upgrade cleanup |
| `new repo: init.sh removes stale root *.sh symlinks (#330 migration)` | migrate 7 root symlinks to script/ |
| `new repo: build.sh -h works against the generated symlink` | smoke script/build.sh |
| `new repo: run.sh -h works against the generated symlink` | smoke script/run.sh |
| `new repo: exec.sh -h works against the generated symlink` | smoke script/exec.sh |
| `new repo: stop.sh -h works against the generated symlink` | smoke script/stop.sh |
| `new repo: setup.sh symlink under script/ → ../.base/script/docker/setup.sh` | setup.sh under script/ |
| `new repo: setup.sh -h works against the generated symlink` | smoke script/setup.sh |
| `init.sh --gen-conf copies setup.conf to repo root` | setup.conf gen |
| `init.sh --gen-conf refuses to overwrite existing setup.conf` | overwrite safety |
| `new repo: .gitignore contains compose.yaml (derived artifact)` | gitignore compose.yaml |
| `new repo: .gitignore contains .env (derived artifact)` | gitignore .env |
| `new repo: compose.yaml has AUTO-GENERATED header (produced by setup.sh)` | setup.sh generated compose.yaml |
| `new repo: compose.yaml ships devices: /dev:/dev by default` | default device mount |
| `new repo: setup.conf mount_1 is NOT empty after first init` | workspace writeback non-empty |
| `new repo: per-repo setup.conf auto-created on first init (workspace writeback)` | #201 — bootstrap writes WS_PATH back |
| `new repo: script/local/justfile.local seeded (repo-local command-group registry)` | #632 — repo-owned registry seeded |
| `new repo: init.sh preserves a pre-existing script/local/justfile.local (no clobber)` | #632 — never clobbers repo registrations |
| `new repo: script/template/ symlinks wired for the template namespace` | #633 — justfile.template + new.sh + skel symlinked |
| `new repo: script/base/ symlink wired for the base namespace` | #652, #653 — justfile.base + completions.sh symlinked; entry mods base |
| `new repo: init warns + exits 0 + still creates symlinks when just is absent (#607)` | Missing runner -> non-fatal WARN, symlinks still laid down |
| `new repo: init is silent about just when the runner is present (#607)` | Runner present -> no warning |

### test/bats/integration/fresh_clone_portability_spec.bats (2)

End-to-end verification for the fresh-clone-on-a-different-machine scenario:
the consumer repo's `setup.conf` has already been committed by another
contributor and carries either a stale absolute `mount_1` path (the Jetson
bug) or the portable `${WS_PATH}` form. Runs the real `build.sh` +
`setup.sh` (no mocks) and asserts the auto-migration / per-machine detection
pipeline lands a valid `.env` + `compose.yaml`. **Level 1** (no Docker
invocation — `build.sh --dry-run`).

| Test | Description |
|------|-------------|
| `fresh clone with stale absolute mount_1: build.sh auto-migrates + generates local .env` | Stale-path auto-migrate |
| `fresh clone with portable ${WS_PATH} mount_1: no warning, .env gets local path` | Happy path round-trip |

### test/bats/integration/wrapper_compose_dispatch_spec.bats (6)

Behavioural assertion (#490) that every wrapper routes its `docker compose`
calls through the `-p`-injecting dispatcher. Reuses the
`fresh_clone_portability_spec.bats` fixture pattern (cp `/source` -> `.base/`,
symlink the wrappers from the repo root, materialize `.env` + `compose.yaml`
via `build.sh --dry-run`), then runs each wrapper with `--dry-run` and
inspects the planned `[dry-run] docker compose -p <project> <verb>` line.
Immune to internal renames (replaces the old name-coupled `_compose_project` /
`_app_cleanup` greps in `template_spec.bats`) and catches a raw-`docker
compose` bypass (a missing `-p`). **Level 1** (no Docker invocation).

| Test | Description |
|------|-------------|
| `build.sh --dry-run dispatches compose build with -p project flag` | build dispatch |
| `run.sh --dry-run (default devel) dispatches compose up + exec with -p` | run devel up+exec |
| `exec.sh --dry-run dispatches compose exec with -p` | exec dispatch |
| `stop.sh --dry-run dispatches compose down with -p` | stop dispatch |
| `run.sh foreground --dry-run installs cleanup that downs with --remove-orphans` | EXIT-trap cleanup |
| `no wrapper dispatches compose without -p (bypass regression)` | bypass catcher |

### test/bats/integration/upgrade_spec.bats (14)

End-to-end verification for `upgrade.sh` driving a real subtree update
against a fake template remote (bare repo with `v0.9.5` / `v0.9.7` tags
on a minimal subtree layout) attached to a sandbox downstream repo.
**Level 1** (no Docker). Exercises the happy path, the pre-flight
guards, the destructive-FF rollback path added after the Jetson v0.9.7
incident (stubs `git-subtree pull` via `GIT_EXEC_PATH` to simulate the
bug and asserts the repo is restored), and Step 5's declarative
Dockerfile/entrypoint migration pass (#567 / #579) — sourcing
`lib/dockerfile_migrate.sh` and running `apply_migrations` over the
repo-root Dockerfile + sibling `script/entrypoint.sh` (the per-migration
{detect, transform} units are unit-tested in `dockerfile_migrate_spec.bats`).

| Test | Description |
|------|-------------|
| `upgrade.sh v0.9.7: bumps template/.version, pulls new content, updates main.yaml` | Happy path |
| `upgrade.sh Step 5 announces the migration pass (#567)` | Step 5 runs the declarative migration dispatcher |
| `upgrade.sh heals a legacy wrapper-COPY Dockerfile via the migration list (#567 m1)` | End-to-end wrapper-copy heal + staged into the upgrade commit |
| `upgrade.sh nounset-guards a sibling entrypoint ROS source (#567 m8 / #579)` | End-to-end entrypoint nounset guard around the ROS setup.bash source |
| `upgrade.sh Step 5 continues cleanly when no Dockerfile at repo root (#567)` | Subtree-only repos (no consumer Dockerfile) skip silently |
| `upgrade.sh migrations are idempotent — already-migrated Dockerfile unchanged (#567)` | A second upgrade is a no-op on an already-migrated Dockerfile |
| `upgrade.sh v0.9.7 is idempotent on a second run` | Re-run is no-op |
| `upgrade.sh --check reports update available from v0.9.5 → v0.9.7` | --check flag |
| `just base update (downstream entry): exit 0 when update available (#175, #546, #652)` | Regression #175: recipe wraps exit 1 (skips w/o just) |
| `just base update (downstream entry): exit 0 when up-to-date (#546)` | Up-to-date path stays green (skips w/o just) |
| `upgrade.sh fails fast when git identity is missing` | Pre-flight identity guard |
| `upgrade.sh fails fast when MERGE_HEAD is present` | Pre-flight merge-state guard |
| `upgrade.sh rolls back when git-subtree does a destructive fast-forward` | Destructive-FF rollback |
| `upgrade.sh (#654 relocated): git subtree pull uses --prefix=.base, not --prefix=base` | Walk-up self-location resolves the subtree prefix to `.base` after the deep relocation; real subtree pull lands with no stray `base/` dir |

### test/bats/integration/gitignore_sync_spec.bats (13)

End-to-end coverage that wires `lib/gitignore.sh` through `init.sh`'s
new-repo + existing-repo paths and `upgrade.sh`'s commit step. Standalone
fixture (independent of `upgrade_spec.bats`'s stub-init fixture) because
gitignore sync requires the **real** `init.sh` to run during Step 3 of
`upgrade.sh`. Issue #172.

| Test | Description |
|------|-------------|
| `init.sh new-repo: .gitignore contains all 7 canonical entries` | New-repo path uses lib |
| `init.sh new-repo: .gitignore has the 'managed by template' marker` | Marker comment present |
| `init.sh existing-repo: appends missing canonical entries to user .gitignore` | Drift fill-in |
| `init.sh existing-repo: untracks compose.yaml that was committed` | 15-repo drift heal |
| `init.sh existing-repo: setup.conf stays committed across init runs (#201)` | 2-file model: setup.conf is user override |
| `init.sh existing-repo: idempotent — second run produces no .gitignore changes` | Re-run no-op |
| `upgrade.sh end-to-end: synced .gitignore + untracked compose.yaml in single commit` | One-shot upgrade |
| `upgrade.sh end-to-end: idempotent on a second run — no extra commits` | Re-upgrade clean |

## Behavioural Tests (opt-in)

Specs that drive `docker buildx build --target runtime-test` against
synthesized fixtures so the runtime smoke gate in `Dockerfile.example`
is genuinely exercised end-to-end — not just static-grep asserted
in `template_spec.bats`. Issue #249.

Excluded from the `1080` self-test total because they require host
docker access (mounted via the `ci-behavioural` compose service)
which the default `ci` service does NOT provide. Run with `just
test behavioural` locally, or via the dedicated
`Behavioural Test` job in `self-test.yaml` on CI. Each test
invokes one `docker buildx build` (~5-15s amd64, ~30-60s arm64
QEMU); the dedicated `template-behavioural` buildx builder
(created/pruned per test.sh run) isolates the cache from the host's
default context.

### test/bats/behavioural/runtime_test_smoke_spec.bats (5)

| Test | Description |
|------|-------------|
| `runtime-test build succeeds with default smoke command` | Baseline `whoami && bash --version` ARG default works |
| `runtime-test build succeeds with && chain override (#243 word-split regression)` | Wrapper preserves shell operators |
| `runtime-test build succeeds with bash parameter expansion override (#249 dash-source regression)` | `${var:offset:length}` works (would fail under `sh -c`) |
| `runtime-test build succeeds with bash [[ test operator override (#249)` | `[[` works (sister bash-only regression guard) |
| `runtime-test build FAILS when smoke command exits non-zero (gate-fires assertion)` | Negative case: the gate actually gates |

## Smoke Tests

Shared specs that ship with `template/test/smoke/` and run at Dockerfile
`test`-stage build time (i.e. during `./build.sh test`) inside both this
repo and every downstream repo that consumes the template. They assert
the integrity of the generated `compose.yaml` + the wrapper scripts'
`-h` / `--help` paths. **Not** part of the 935-test self-test count
(those run via `just test` and never enter the build
graph).

How they reach downstream repos: each `Dockerfile`'s `test` stage does

```dockerfile
COPY template/test/smoke/ /smoke_test/
COPY test/smoke/ /smoke_test/
RUN bats /smoke_test/
```

so the shared specs and any per-repo `test/smoke/` overlay execute
together. `display_env.bats` self-skips on headless repos by detecting
the absence of GUI lines in the generated `compose.yaml`.

### downstream/test/smoke/script_help.bats (27)

Locks the `-h` / `--help` invariants on the four wrapper scripts
(`build.sh` / `run.sh` / `exec.sh` / `stop.sh`) plus the `_LANG`
auto-detection rules in `build.sh` (`LANG=zh_TW.UTF-8` → zh, `ja_JP`
→ ja, `en_US` → en, `SETUP_LANG` overrides `LANG`) plus #222
`--help` / `--lang` order independence (pre-pass scans for `--lang`
before main parse so `<script> --help --lang zh-TW` produces zh-TW
usage, not English).

| Test | Description |
|------|-------------|
| `build.sh -h exits 0` | Wrapper smoke |
| `build.sh --help exits 0` | Long flag |
| `build.sh -h prints usage` | Output sanity |
| `build.sh -h describes auto-apply default (no stale 'warn on drift', #365)` | Help text describes auto-apply, not stale warn-on-drift |
| `run.sh -h exits 0` | Wrapper smoke |
| `run.sh --help exits 0` | Long flag |
| `run.sh -h prints usage` | Output sanity |
| `run.sh -h describes auto-apply default (no stale 'warn on drift', #365)` | Help text describes auto-apply, not stale warn-on-drift |
| `exec.sh -h exits 0` | Wrapper smoke |
| `exec.sh --help exits 0` | Long flag |
| `exec.sh -h prints usage` | Output sanity |
| `stop.sh -h exits 0` | Wrapper smoke |
| `stop.sh --help exits 0` | Long flag |
| `stop.sh -h prints usage` | Output sanity |
| `build.sh detects zh from LANG=zh_TW.UTF-8` | i18n detect — zh-TW |
| `build.sh detects ja from LANG=ja_JP.UTF-8` | i18n detect — ja |
| `build.sh defaults to en for LANG=en_US.UTF-8` | i18n detect — en default |
| `build.sh SETUP_LANG overrides LANG` | i18n env override |

### downstream/test/smoke/display_env.bats (11)

Asserts the generated `compose.yaml` carries the X11 / Wayland env
+ volume block expected by GUI containers, and that `run.sh` runs the
right `xhost` command per session type. Auto-skipped when the repo's
`compose.yaml` has no GUI block (headless repos like `multi_run`).

| Test | Description |
|------|-------------|
| `compose.yaml contains WAYLAND_DISPLAY env` | Wayland env line |
| `compose.yaml contains XDG_RUNTIME_DIR env` | Wayland session dir env |
| `compose.yaml contains XAUTHORITY env` | X11 auth env |
| `compose.yaml mounts XDG_RUNTIME_DIR as rw` | Wayland socket mount |
| `compose.yaml mounts XAUTHORITY volume` | X11 auth mount |
| `compose.yaml has no consecutive duplicate keys` | YAML hygiene |
| `compose.yaml mounts X11-unix volume` | X11 socket mount |
| `run.sh contains XDG_SESSION_TYPE check` | Session-type branch |
| `run.sh calls xhost +SI:localuser on wayland` | Wayland xhost path |
| `run.sh calls xhost +local: on X11` | X11 xhost path |
| `run.sh defaults to X11 xhost when XDG_SESSION_TYPE unset` | Fallback path |

### downstream/test/smoke/test_helper.bash

Not a spec — runtime helper (`assert_compose_has` / `skip_if_headless`
etc.) loaded by every smoke spec via `load "${BATS_TEST_DIRNAME}/test_helper"`.
Asserts in this file are exercised via `test/bats/unit/smoke_helper_spec.bats`
(which IS in the 935 self-test count).
