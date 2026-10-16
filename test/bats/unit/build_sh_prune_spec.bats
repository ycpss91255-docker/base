#!/usr/bin/env bats
#
# Unit tests for build.sh's post-build prune-predecessor logic.
# Separate spec so the docker stub can be tailored to image-inspect /
# images-filter / rmi semantics without bloating build_sh_spec.bats's
# default stub (which only logs args).
#
# Stub control env vars (read per-invocation by the smart docker stub):
#   DOCKER_INSPECT_PRE_ID    image ID the rebuilt tag points at BEFORE the
#                            build (empty → `docker image inspect <tag>`
#                            exits 1, simulating "no prior image")
#   DOCKER_INSPECT_POST_ID   image ID the rebuilt tag points at AFTER
#                            `_compose_project build` finishes. Defaults to
#                            DOCKER_INSPECT_PRE_ID if unset (cache-hit no-op).
#   DOCKER_PRE_ID_OTHER_TAGS newline-delimited tags that still point at the
#                            pre-build ID once the rebuilt tag has moved
#                            (e.g. a `bl-devel` alias). Empty → the old
#                            image is left untagged (`<none>:<none>`).
#   DOCKER_REBUILT_TAG       the tag build.sh rebuilds; defaults to
#                            mockuser/mockimg:devel (mock .env + TARGET).
#   DOCKER_RMI_LOG           file that captures every `docker rmi <id>`
#                            call so tests can assert the rmi did (or
#                            did not) fire.
#
# why: Unit tests for `build.sh`'s #387 post-build prune-predecessor logic.
# Separate spec so the docker stub can be tailored to image-inspect /
# images / rmi semantics without bloating the default build_sh_spec
# stub (which only logs argv). The smart docker stub models a small image
# store (rebuilt tag → pre/post ID, pre ID → its other tags) and answers
# `image inspect`, `images` and `rmi` from it, so a lookup that asks the
# wrong question -- e.g. `--filter reference=<image-id>`, which matches no
# repo:tag -- gets the empty answer a real daemon gives (base#1338).
#
# Covers: first-build path (`docker image inspect` exits 1 → no
# `_pre_build_id` → prune skipped, no rmi), cache-hit rebuild (`pre == post`
# → cache-hit guard returns early), successful displaced rebuild (`pre !=
# post`, old id has no other tag → `docker rmi <old-id>` fires), tagged
# guard (old id still carries one alias, or several → "skip prune:
# predecessor still tagged" log + no rmi, base#1338), `--no-prune` opt-out
# (no inspect calls + no rmi even when ids would have moved), `--dry-run`
# (planned-action line `[dry-run] docker rmi <old-id-of ... if displaced>`
# visible + zero real rmi), and `--help` mentions the `--no-prune` flag.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC2154
  TEMP_DIR="$(mktemp -d)"
  export TEMP_DIR

  SANDBOX="${TEMP_DIR}/repo"
  mkdir -p "${SANDBOX}/.base/dist/script/docker/lib" \
           "${SANDBOX}/.base/dist/script/docker/wrapper" \
           "${SANDBOX}/config/docker"

  cp /source/dist/script/docker/lib/_lib.sh  "${SANDBOX}/.base/dist/script/docker/lib/_lib.sh"
  cp /source/dist/script/docker/lib/i18n.sh  "${SANDBOX}/.base/dist/script/docker/lib/i18n.sh"
  cp /source/dist/script/docker/lib/* "${SANDBOX}/.base/dist/script/docker/lib/"
  ln -s /source/dist/script/docker/wrapper/build.sh "${SANDBOX}/build.sh"

  MOCK_SETUP_LOG="${TEMP_DIR}/setup.log"
  export MOCK_SETUP_LOG

  # Mock setup.sh — seeds .env so _load_env succeeds and DOCKER_HUB_USER
  # / IMAGE_NAME are present for the _full_tag computation in build.sh.
  cat > "${SANDBOX}/.base/dist/script/docker/wrapper/setup.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
_subcmd="apply"
case "${1:-}" in
  check-drift) _subcmd="check-drift"; shift ;;
  apply)       shift ;;
esac
_base=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-path) _base="$2"; shift 2 ;;
    --lang)      shift 2 ;;
    *)           shift ;;
  esac
done
case "${_subcmd}" in
  check-drift) exit 0 ;;
  apply)
    printf 'setup.sh invoked --base-path %s\n' "${_base}" >> "${MOCK_SETUP_LOG}"
    {
      echo "USER_NAME=tester"
      echo "IMAGE_NAME=mockimg"
      echo "DOCKER_HUB_USER=mockuser"
    } > "${_base}/.env.generated"
    echo "# mock compose" > "${_base}/compose.yaml"
    ;;
esac
EOS
  chmod +x "${SANDBOX}/.base/dist/script/docker/wrapper/setup.sh"

  BIN_DIR="${TEMP_DIR}/bin"
  mkdir -p "${BIN_DIR}"
  DOCKER_RMI_LOG="${TEMP_DIR}/rmi.log"
  export DOCKER_RMI_LOG
  : > "${DOCKER_RMI_LOG}"
  INSPECT_CALL_COUNTER="${TEMP_DIR}/inspect_calls"
  export INSPECT_CALL_COUNTER
  : > "${INSPECT_CALL_COUNTER}"

  # Smart docker stub. It models a two-image store rather than echoing
  # canned output, so a lookup that asks the wrong question gets the
  # answer real docker gives it (base#1338):
  #   - the rebuilt tag (DOCKER_REBUILT_TAG) points at DOCKER_INSPECT_PRE_ID
  #     before the build and at DOCKER_INSPECT_POST_ID after it;
  #   - the pre-build ID additionally carries every tag listed in
  #     DOCKER_PRE_ID_OTHER_TAGS.
  # Branches:
  #   image inspect <tag>  → first call answers with the pre-build ID,
  #     later calls with the post-build ID. Empty → exit 1 (tag absent).
  #   image inspect <id>   → that image's .Id / .RepoTags, per --format.
  #     Does NOT advance the pre/post counter.
  #   images / image ls    → one row per (repo, tag, id) in the store,
  #     rendered through --format ({{.Repository}} {{.Tag}} {{.ID}});
  #     --no-trunc gives full IDs. `--filter reference=<pattern>` keeps
  #     only rows whose repo:tag matches the pattern, so an image ID as
  #     the pattern matches nothing -- as on a real daemon.
  #   rmi → append the id to DOCKER_RMI_LOG.
  #   any other verb (compose build / build / ...) → no-op exit 0.
  cat > "${BIN_DIR}/docker" <<'EOS'
#!/usr/bin/env bash
set -uo pipefail
_pre="${DOCKER_INSPECT_PRE_ID:-}"
_post="${DOCKER_INSPECT_POST_ID:-${_pre}}"
_rebuilt="${DOCKER_REBUILT_TAG:-mockuser/mockimg:devel}"

# _rows prints "repo:tag<TAB>id" for every tagged image in the store, and
# "<none>:<none><TAB>id" for a stored image with no tag at all.
_rows() {
  local _t _pre_tagged=false
  if [[ -n "${_post}" ]]; then
    printf '%s\t%s\n' "${_rebuilt}" "${_post}"
    [[ "${_post}" == "${_pre}" ]] && _pre_tagged=true
  fi
  if [[ -n "${_pre}" ]]; then
    while IFS= read -r _t; do
      [[ -z "${_t}" ]] && continue
      printf '%s\t%s\n' "${_t}" "${_pre}"
      _pre_tagged=true
    done <<< "${DOCKER_PRE_ID_OTHER_TAGS:-}"
    [[ "${_pre_tagged}" == false ]] && printf '<none>:<none>\t%s\n' "${_pre}"
  fi
  return 0
}

# _tags_of <id> prints that image's tags, one per line.
_tags_of() {
  local _ref _id
  while IFS=$'\t' read -r _ref _id; do
    [[ "${_id}" == "$1" && "${_ref}" != "<none>:<none>" ]] && printf '%s\n' "${_ref}"
  done < <(_rows)
  return 0
}

# _resolve_id <ref> prints the full ID a reference or (short) ID names.
_resolve_id() {
  local _r="$1" _c
  for _c in "${_pre}" "${_post}"; do
    [[ -z "${_c}" ]] && continue
    if [[ "${_r}" == "${_c}" || "sha256:${_r}" == "${_c}" \
        || ( ${#_r} -ge 12 && "${_c#sha256:}" == "${_r#sha256:}"* ) ]]; then
      printf '%s\n' "${_c}"
      return 0
    fi
  done
  return 1
}

if [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
  shift 2
  _fmt=""
  _targets=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --format|-f) _fmt="$2"; shift 2 ;;
      --format=*)  _fmt="${1#--format=}"; shift ;;
      -*)          shift ;;
      *)           _targets+=("$1"); shift ;;
    esac
  done
  _rc=0
  for _target in "${_targets[@]}"; do
    if _id="$(_resolve_id "${_target}")"; then
      _tags=()
      while IFS= read -r _t; do _tags+=("${_t}"); done < <(_tags_of "${_id}")
      _json='['
      for _t in "${_tags[@]}"; do
        [[ "${_json}" != '[' ]] && _json+=','
        _json+="\"${_t}\""
      done
      _json+=']'
      case "${_fmt}" in
        '{{.Id}}'|'{{.ID}}') printf '%s\n' "${_id}" ;;
        *RepoTags*)
          if [[ "${_fmt}" == *json* ]]; then
            printf '%s\n' "${_json}"
          elif [[ "${_fmt}" == *range* ]]; then
            for _t in "${_tags[@]}"; do printf '%s\n' "${_t}"; done
          else
            printf '[%s]\n' "${_tags[*]}"
          fi
          ;;
        *) printf '[{"Id":"%s","RepoTags":%s}]\n' "${_id}" "${_json}" ;;
      esac
      continue
    fi
    # A tag: count which tag lookup this is (pre vs post build).
    _n="$(($(wc -l < "${INSPECT_CALL_COUNTER}") + 1))"
    printf '%s\n' "${_n}" >> "${INSPECT_CALL_COUNTER}"
    if [[ "${_n}" == "1" ]]; then
      _id="${_pre}"
    else
      _id="${_post}"
    fi
    if [[ -z "${_id}" ]]; then
      _rc=1
      continue
    fi
    printf '%s\n' "${_id}"
  done
  exit "${_rc}"
fi
if [[ "${1:-}" == "images" || ( "${1:-}" == "image" && ( "${2:-}" == "ls" || "${2:-}" == "list" ) ) ]]; then
  [[ "${1}" == "image" ]] && shift
  shift
  _fmt=""
  _filters=()
  _notrunc=false
  _quiet=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --format)    _fmt="$2"; shift 2 ;;
      --format=*)  _fmt="${1#--format=}"; shift ;;
      --filter|-f) _filters+=("$2"); shift 2 ;;
      --filter=*)  _filters+=("${1#--filter=}"); shift ;;
      --no-trunc)  _notrunc=true; shift ;;
      -q|--quiet)  _quiet=true; shift ;;
      *)           shift ;;
    esac
  done
  [[ -z "${_fmt}" && "${_quiet}" == false ]] \
    && printf 'REPOSITORY\tTAG\tIMAGE ID\tCREATED\tSIZE\n'
  while IFS=$'\t' read -r _ref _id; do
    _keep=true
    for _f in "${_filters[@]}"; do
      if [[ "${_f}" == reference=* ]]; then
        _pat="${_f#reference=}"
        # shellcheck disable=SC2053
        [[ "${_ref}" == ${_pat} || "${_ref%:*}" == ${_pat} ]] || _keep=false
      fi
    done
    [[ "${_keep}" == true ]] || continue
    _repo="${_ref%:*}"
    _tag="${_ref##*:}"
    if [[ "${_notrunc}" == true ]]; then
      _shown="${_id}"
    else
      _shown="${_id#sha256:}"
      _shown="${_shown:0:12}"
    fi
    if [[ "${_quiet}" == true ]]; then
      printf '%s\n' "${_shown}"
    elif [[ -z "${_fmt}" ]]; then
      printf '%s\t%s\t%s\t1 minute ago\t1GB\n' "${_repo}" "${_tag}" "${_shown}"
    else
      _line="${_fmt#table }"
      _line="${_line//'{{.Repository}}'/${_repo}}"
      _line="${_line//'{{.Tag}}'/${_tag}}"
      _line="${_line//'{{.ID}}'/${_shown}}"
      _line="${_line//'\t'/$'\t'}"
      printf '%s\n' "${_line}"
    fi
  done < <(_rows)
  exit 0
fi
if [[ "${1:-}" == "rmi" ]]; then
  shift
  printf '%s\n' "$*" >> "${DOCKER_RMI_LOG}"
  exit 0
fi
# compose / build / anything else: silent success.
exit 0
EOS
  chmod +x "${BIN_DIR}/docker"

  export PATH="${BIN_DIR}:${PATH}"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# ── prune-predecessor cases ──────────────────────────────────────────

@test "build.sh first build (no prior image) skips prune" {
  # Pre-build inspect returns exit 1 (tag absent) → _pre_build_id empty
  # → prune branch never enters _prune_predecessor.
  unset DOCKER_INSPECT_PRE_ID DOCKER_INSPECT_POST_ID DOCKER_PRE_ID_OTHER_TAGS
  run bash "${SANDBOX}/build.sh"
  assert_success
  run cat "${DOCKER_RMI_LOG}"
  assert_output ""
}

@test "build.sh cache-hit rebuild (same id) skips prune" {
  # Pre and post inspect return the SAME id → _prune_predecessor early
  # returns at the cache-hit guard.
  export DOCKER_INSPECT_PRE_ID="sha256:aaaa000000000000000000000000000000000000000000000000000000000000"
  # POST defaults to PRE when unset
  run bash "${SANDBOX}/build.sh"
  assert_success
  run cat "${DOCKER_RMI_LOG}"
  assert_output ""
}

@test "build.sh successful rebuild with displaced id rmi's old id" {
  # Pre = old id, post = new id, no other tag points at old → rmi fires.
  export DOCKER_INSPECT_PRE_ID="sha256:aaaa000000000000000000000000000000000000000000000000000000000000"
  export DOCKER_INSPECT_POST_ID="sha256:bbbb000000000000000000000000000000000000000000000000000000000000"
  export DOCKER_PRE_ID_OTHER_TAGS=""  # old image left as <none>:<none>
  run bash "${SANDBOX}/build.sh"
  assert_success
  run cat "${DOCKER_RMI_LOG}"
  assert_output --partial "sha256:aaaa"
}

@test "build.sh skips prune when old id keeps its one other tag (base#1338)" {
  # The rebuilt devel tag moves to the new id; the old id is still tagged
  # bl-devel. Removing it would untag bl-devel and delete the image → no rmi.
  export DOCKER_INSPECT_PRE_ID="sha256:aaaa000000000000000000000000000000000000000000000000000000000000"
  export DOCKER_INSPECT_POST_ID="sha256:bbbb000000000000000000000000000000000000000000000000000000000000"
  export DOCKER_PRE_ID_OTHER_TAGS="mockuser/mockimg:bl-devel"
  run bash "${SANDBOX}/build.sh"
  assert_success
  assert_output --partial "skip prune: predecessor still tagged"
  assert_output --partial "mockuser/mockimg:bl-devel"
  run cat "${DOCKER_RMI_LOG}"
  assert_output ""
}

@test "build.sh skips prune when old id still carries several other tags (base#1338)" {
  export DOCKER_INSPECT_PRE_ID="sha256:aaaa000000000000000000000000000000000000000000000000000000000000"
  export DOCKER_INSPECT_POST_ID="sha256:bbbb000000000000000000000000000000000000000000000000000000000000"
  export DOCKER_PRE_ID_OTHER_TAGS=$'mockuser/mockimg:legacy\nmockuser/mockimg:bl-devel'
  run bash "${SANDBOX}/build.sh"
  assert_success
  assert_output --partial "skip prune: predecessor still tagged"
  run cat "${DOCKER_RMI_LOG}"
  assert_output ""
}

@test "build.sh --no-prune skips prune even when id displaced" {
  # Same scenario as the rmi-fires case, but --no-prune short-circuits
  # before either inspect call runs.
  export DOCKER_INSPECT_PRE_ID="sha256:aaaa000000000000000000000000000000000000000000000000000000000000"
  export DOCKER_INSPECT_POST_ID="sha256:bbbb000000000000000000000000000000000000000000000000000000000000"
  run bash "${SANDBOX}/build.sh" --no-prune
  assert_success
  run cat "${DOCKER_RMI_LOG}"
  assert_output ""
}

@test "build.sh --dry-run prints planned prune step + does not rmi" {
  # Dry-run surfaces the planned prune line for visibility but does
  # not invoke docker rmi.
  export DOCKER_INSPECT_PRE_ID="sha256:aaaa000000000000000000000000000000000000000000000000000000000000"
  export DOCKER_INSPECT_POST_ID="sha256:bbbb000000000000000000000000000000000000000000000000000000000000"
  run bash "${SANDBOX}/build.sh" --dry-run
  assert_success
  assert_output --partial "[dry-run] docker rmi <old-id-of"
  run cat "${DOCKER_RMI_LOG}"
  assert_output ""
}

@test "build.sh --help mentions --no-prune (#387)" {
  run bash "${SANDBOX}/build.sh" --help
  assert_success
  assert_output --partial "--no-prune"
}
