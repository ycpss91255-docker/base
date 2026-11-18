#!/usr/bin/env bats
#
# config_gen_spec.bats -- config_gen_resolve, the host-side provisioning of
# the config generator image (base#1466, ADR-00000039).
#
# why: the config generator ships as a Go module under dockerfile/config-gen
# with dockerfile/Dockerfile.config-gen, and nothing on a consumer host
# builds it. config_gen_resolve names the image by a content digest of the
# Dockerfile and the module (the build context is dockerfile/config-gen, not
# the Dockerfile's own directory), provisions it once per shell, and refuses
# by name when it cannot. It shares the resolve/ensure/build path with the
# TOML bridge through lib/tool_image.sh (tool_image_spec.bats).
#
# docker is a mock that records its argv; the subtree is a scratch copy so
# the whole derivation runs inside the fixture. Unit level (ADR-00000018).

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  ROOT=/source
  unset CONFIG_GEN_IMAGE TOML_BRIDGE_IMAGE
  export TOML_BRIDGE_FORCE_DOCKER=1
}

teardown() {
  cleanup_mock_dir || true
}

# _seed_cg_subtree
#   A vendored subtree (prefix `vendored`, not `.base`: the prefix is the
#   consumer's to name) with its own lib copy, the config generator's build
#   inputs and the bridge's, and the `.version` + `dist/` markers.
_seed_cg_subtree() {
  SUB="${BATS_TEST_TMPDIR}/consumer/vendored"
  mkdir -p "${SUB}/dist/script/docker" "${SUB}/dockerfile"
  cp -a "${ROOT}/dist/script/docker/lib" "${SUB}/dist/script/docker/lib"
  cp -a "${ROOT}/dockerfile/Dockerfile.config-gen" "${SUB}/dockerfile/"
  cp -a "${ROOT}/dockerfile/config-gen" "${SUB}/dockerfile/config-gen"
  cp -a "${ROOT}/dockerfile/Dockerfile.toml-bridge" "${SUB}/dockerfile/"
  cp -a "${ROOT}/dockerfile/toml_bridge.py" "${SUB}/dockerfile/"
  printf 'v0.0.0-test\n' > "${SUB}/.version"
  LIB="${SUB}/dist/script/docker/lib"
  CG="${LIB}/config_gen.sh"
  TB="${LIB}/toml_bridge.sh"
  CG_DF="${SUB}/dockerfile/Dockerfile.config-gen"
  CG_CTX="${SUB}/dockerfile/config-gen"
  export DOCKER_LOG="${BATS_TEST_TMPDIR}/docker.log"
  : > "${DOCKER_LOG}"
}

# _cg_mock_docker <body>
#   The only installer of a docker stub in this spec. The stub starts with
#   one recorder: each call's argv, NUL-joined, goes to ${CG_CALLS}/call.<n>
#   (n = 1, 2, ... in call order), and the `$*` line is appended to
#   DOCKER_LOG (read by _count_inspects and the resolve rows). The call
#   `docker __cg_probe` is recorded and answered with exit 0 and nothing
#   else; every other call then runs <body>. Whether a call is recorded no
#   longer depends on which stub a row installs (base#1470).
_cg_mock_docker() {
  export CG_CALLS="${BATS_TEST_TMPDIR}/calls"
  mkdir -p "${CG_CALLS}"
  create_mock_dir
  mock_cmd "docker" \
    '_cg_n=1
     while [[ -e "${CG_CALLS}/call.${_cg_n}" ]]; do _cg_n=$((_cg_n + 1)); done
     printf "%s\0" "$@" > "${CG_CALLS}/call.${_cg_n}"
     [[ $# -eq 1 && "$1" == __cg_probe ]] && exit 0
     printf "%s\n" "$*" >> "${DOCKER_LOG}"
     '"$1"
}

# _cg_reset_calls -- forget every recorded call and empty DOCKER_LOG, so a
#   loop iteration's assertions read only that iteration's calls.
_cg_reset_calls() {
  rm -f -- "${CG_CALLS}"/call.*
  : > "${DOCKER_LOG}"
}

# _cg_call_files -- the recorded call files, one per line, in call order.
_cg_call_files() {
  local _n=1
  while [[ -e "${CG_CALLS}/call.${_n}" ]]; do
    printf '%s\n' "${CG_CALLS}/call.${_n}"
    _n=$((_n + 1))
  done
}

# _cg_assert_recording
#   A behavioural positive control: `docker __cg_probe`, run on the PATH
#   the shim runs on, must leave exactly one new call file whose bytes are
#   `__cg_probe` NUL; it is then removed. A stub that does not record, or a
#   PATH that no longer reaches the recording stub, fails here, so an
#   assertion about what was called cannot pass on a mute recorder.
_cg_assert_recording() {
  [[ -n "${CG_CALLS:-}" ]] || fail "no docker stub installed by _cg_mock_docker"
  local -a _before _after
  mapfile -t _before < <(_cg_call_files)
  docker __cg_probe || fail "docker __cg_probe exited $?"
  mapfile -t _after < <(_cg_call_files)
  ((${#_after[@]} == ${#_before[@]} + 1)) \
    || fail "docker __cg_probe left $((${#_after[@]} - ${#_before[@]})) call files, not 1: the stub does not record"
  local _last="${_after[${#_after[@]} - 1]}"
  cmp -s -- "${_last}" <(printf '%s\0' __cg_probe) \
    || fail "the probe's call file does not hold __cg_probe NUL"
  rm -f -- "${_last}"
}

# assert_cg_calls [<verb>...]
#   After _cg_assert_recording, argv[0] of every recorded call, in order,
#   equals the given list: exact and complete, so no verbs means no docker
#   call of any kind.
assert_cg_calls() {
  _cg_assert_recording
  local -a _seen=() _files
  local _f _v
  mapfile -t _files < <(_cg_call_files)
  for _f in "${_files[@]}"; do
    IFS= read -r -d '' _v < "${_f}" || true
    _seen+=("${_v}")
  done
  [[ "${_seen[*]}" == "$*" && ${#_seen[@]} -eq $# ]] \
    || fail "docker calls: [${_seen[*]}], expected [$*]"
}

# assert_cg_run_argv <word>...
#   After _cg_assert_recording, exactly one recorded call has argv[0]
#   `run`, and its bytes equal the given words NUL-joined: every word and
#   every word boundary.
assert_cg_run_argv() {
  _cg_assert_recording
  local -a _files _runs=()
  local _f _v
  mapfile -t _files < <(_cg_call_files)
  for _f in "${_files[@]}"; do
    IFS= read -r -d '' _v < "${_f}" || true
    [[ "${_v}" != run ]] || _runs+=("${_f}")
  done
  ((${#_runs[@]} == 1)) || fail "${#_runs[@]} docker run calls, not 1"
  cmp -s -- "${_runs[0]}" <(printf '%s\0' "$@") \
    || fail "docker run argv: [$(tr '\0' '|' < "${_runs[0]}")], expected [$(printf '%s|' "$@")]"
}

# _mock_docker [present|absent|fail]
#   docker records its argv. `image inspect` answers present (0) or absent
#   (1); `build` succeeds, or with `fail` prints two lines and exits 125.
_mock_docker() {
  local _mode="${1:-absent}"
  _cg_mock_docker \
    'case "$1" in
       image) [[ "'"${_mode}"'" == present ]] && exit 0; exit 1 ;;
       build)
         if [[ "'"${_mode}"'" == fail ]]; then
           echo "first-line of builder" >&2
           echo "second-line of builder" >&2
           exit 125
         fi
         exit 0 ;;
       *) exit 1 ;;
     esac'
}

# _derive -- the tag config_gen derives, printed. Runs in its own shell.
_derive() {
  bash -c "source '${CG}' && tool_image_derive config_gen"
}

# _expected_tag -- `config-gen:` + the first 12 hex of the digest over the
#   Dockerfile and the context dir, computed here from project_reclaim.sh.
_expected_tag() {
  local _h
  _h="$(bash -c "source '${LIB}/log.sh' && source '${LIB}/project_reclaim.sh' \
    && _reclaim_tool_dockerfile_hash '${CG_DF}' '${CG_CTX}'")"
  printf 'config-gen:%s\n' "${_h:0:12}"
}

_count_inspects() {
  grep -c '^image inspect' "${DOCKER_LOG}" || true
}

# why: the identity rule shared with the bridge and the tooling tag
#      (base#1169): one digest function, twelve hex, over the Dockerfile
#      AND its build context dockerfile/config-gen.
@test "config-gen: the tag is config-gen:<12 hex> of the Dockerfile and its context" {
  _seed_cg_subtree
  run _derive
  assert_success
  assert_output --regexp '^config-gen:[0-9a-f]{12}$'
  assert_output "$(_expected_tag)"
}

# why: a tag keyed only on the Dockerfile, or only on the module's top
#      level, would keep the old name after a Go edit: the build is skipped
#      as already present and the run uses a stale generator. Both files
#      exist before the baseline and only their BYTES change, so a tag keyed
#      on file names alone keeps its old value and fails here.
@test "config-gen: the tag follows a content edit of a nested internal/**.go and of go.sum" {
  _seed_cg_subtree
  mkdir -p "${CG_CTX}/internal/a/b"
  printf 'package b\n' > "${CG_CTX}/internal/a/b/x.go"
  printf 'example.com/m v1.0.0 h1:abc=\n' > "${CG_CTX}/go.sum"
  run _derive
  assert_success
  assert_output "$(_expected_tag)"
  local _t0="${output}"

  printf 'package b\n\nconst X = 1\n' > "${CG_CTX}/internal/a/b/x.go"
  run _derive
  assert_success
  assert_output --regexp '^config-gen:[0-9a-f]{12}$'
  assert_output "$(_expected_tag)"
  refute_output "${_t0}"
  local _t1="${output}"

  printf 'example.com/m v1.0.0 h1:xyz=\n' > "${CG_CTX}/go.sum"
  run _derive
  assert_success
  assert_output --regexp '^config-gen:[0-9a-f]{12}$'
  assert_output "$(_expected_tag)"
  refute_output "${_t0}"
  refute_output "${_t1}"
}

# why: the default context of _reclaim_tool_dockerfile_hash is the
#      Dockerfile's directory, dockerfile/, which would key the tag on every
#      sibling tool's inputs (measured: an edit of Dockerfile.toml-bridge
#      moved it). The context is dockerfile/config-gen only.
@test "config-gen: the tag does not follow an edit outside dockerfile/config-gen" {
  _seed_cg_subtree
  run _derive
  assert_success
  local _t0="${output}"

  printf '\n# unrelated revision\n' >> "${SUB}/dockerfile/Dockerfile.toml-bridge"
  run _derive
  assert_success
  assert_output "${_t0}"
}

# why: the memo has to live in the caller's shell. A resolve that prints
#      its answer is read through $(...), where no memo survives and each
#      read inspects (and maybe builds) again.
@test "config-gen: resolve memoises in the caller's shell: one inspect for three resolves" {
  _seed_cg_subtree
  _mock_docker absent

  run --separate-stderr bash -c "source '${CG}'
config_gen_resolve || exit 7
p=\"\${_CONFIG_GEN_RESOLVED}\"
config_gen_resolve || exit 8
s=\"\$(config_gen_resolve; echo \"\${_CONFIG_GEN_RESOLVED}\")\"
printf 'parent=%s\n' \"\${p}\"
printf 'sub=%s\n' \"\${s}\""
  assert_success
  local _tag
  _tag="$(_expected_tag)"
  assert_line "parent=${_tag}"
  assert_line "sub=${_tag}"
  assert_equal "$(_count_inspects)" 1
}

# why: config_gen_resolve answers through the global, never on stdout, and
#      sourcing the file again keeps the memo.
@test "config-gen: resolve publishes _CONFIG_GEN_RESOLVED, prints nothing, survives a re-source" {
  _seed_cg_subtree
  _mock_docker present

  run --separate-stderr bash -c "source '${CG}'
out=\"\$(config_gen_resolve)\"
printf 'printed=[%s]\n' \"\${out}\"
config_gen_resolve
source '${CG}'
printf 'memo=%s\n' \"\${_CONFIG_GEN_RESOLVED}\""
  assert_success
  assert_line "printed=[]"
  assert_line "memo=$(_expected_tag)"
}

# why: CONFIG_GEN_IMAGE pins an image (CI, a published tag). Building or
#      even inspecting over what the caller asked for is the mistake
#      _ensure_test_tools_image declines to make.
@test "config-gen: CONFIG_GEN_IMAGE is used verbatim with no inspect and no build" {
  _seed_cg_subtree
  _mock_docker absent

  run --separate-stderr bash -c "export CONFIG_GEN_IMAGE=pinned/cg:v1
source '${CG}'
config_gen_resolve || exit 7
printf '%s\n' \"\${_CONFIG_GEN_RESOLVED}\""
  assert_success
  assert_output "pinned/cg:v1"
  run cat "${DOCKER_LOG}"
  assert_output ""
}

# why: set-but-empty follows TOML_BRIDGE_IMAGE: it counts as unset, so the
#      tag is derived and inspected.
@test "config-gen: CONFIG_GEN_IMAGE set but empty derives and inspects" {
  _seed_cg_subtree
  _mock_docker present

  run --separate-stderr bash -c "export CONFIG_GEN_IMAGE=
source '${CG}'
config_gen_resolve || exit 7
printf '%s\n' \"\${_CONFIG_GEN_RESOLVED}\""
  assert_success
  assert_output "$(_expected_tag)"
  run cat "${DOCKER_LOG}"
  assert_line "image inspect $(_expected_tag)"
}

# why: the build context is dockerfile/config-gen (the Dockerfile's
#      `COPY . .`), the shipped stage is `final`, and the build record goes
#      to stderr: stdout is a caller's to read.
@test "config-gen: an absent image is built from dockerfile/config-gen at --target final" {
  _seed_cg_subtree
  _mock_docker absent

  LOG_FORMAT=json run --separate-stderr bash -c "source '${CG}'; config_gen_resolve"
  assert_success
  assert_output ""
  assert_log_event config_gen_building "${stderr}"
  local _tag
  _tag="$(_expected_tag)"
  run cat "${DOCKER_LOG}"
  assert_line "image inspect ${_tag}"
  assert_line "build -t ${_tag} -f ${CG_DF} --target final ${CG_CTX}"
}

# why: a failed build is a named refusal carrying the builder's output on
#      one line, rc 1 -- and a return, not an exit, so the caller decides.
@test "config-gen: a failed build refuses with config_gen_build_failed" {
  _seed_cg_subtree
  _mock_docker fail

  LOG_FORMAT=json run --separate-stderr bash -c "source '${CG}'; config_gen_resolve"
  assert_refusal 1 config_gen_build_failed "path=${CG_DF}" "status=125" \
    "first-line of builder second-line of builder"
}

# why: an exit would end the caller's shell along with the resolve; the
#      line after the failed resolve still runs and owns stdout.
@test "config-gen: a failed build does not exit the caller" {
  _seed_cg_subtree
  _mock_docker fail

  LOG_FORMAT=json run --separate-stderr bash -c "source '${CG}'
config_gen_resolve
echo alive"
  assert_success
  assert_output "alive"
  assert_log_event config_gen_build_failed "${stderr}"
}

# why: with no subtree root above the lib there is nothing to build from;
#      that is a refusal, never a fallback to a literal tag.
@test "config-gen: no subtree root refuses with config_gen_unprovisionable" {
  local _loose="${BATS_TEST_TMPDIR}/loose"
  mkdir -p "${_loose}"
  cp -a "${ROOT}/dist/script/docker/lib" "${_loose}/lib"
  local _lib
  _lib="$(cd "${_loose}/lib" && pwd -P)"
  export DOCKER_LOG="${BATS_TEST_TMPDIR}/docker.log"
  : > "${DOCKER_LOG}"
  _mock_docker present

  LOG_FORMAT=json run --separate-stderr bash -c "source '${_lib}/config_gen.sh'; config_gen_resolve"
  assert_refusal 1 config_gen_unprovisionable "lib=${_lib}"
}

# why: with no Dockerfile there is no digest to name the image by, and a
#      build would fail later with a less useful message.
@test "config-gen: a missing Dockerfile refuses with config_gen_unprovisionable" {
  _seed_cg_subtree
  _mock_docker present
  rm -f "${CG_DF}"

  LOG_FORMAT=json run --separate-stderr bash -c "source '${CG}'; config_gen_resolve"
  assert_refusal 1 config_gen_unprovisionable "path=${CG_DF}"
}

# why: the context is half of the digest and the whole of the build
#      input; a missing one is refused before either is attempted.
@test "config-gen: a missing build context refuses with config_gen_unprovisionable" {
  _seed_cg_subtree
  _mock_docker present
  rm -rf "${CG_CTX}"

  LOG_FORMAT=json run --separate-stderr bash -c "source '${CG}'; config_gen_resolve"
  assert_refusal 1 config_gen_unprovisionable "${CG_CTX}"
}

# why: a digest that fails, or that answers nothing, names no image; a
#      tag built from it would be `config-gen:` with no identity. Both are
#      refusals, never a literal or empty tag. The digest function is
#      replaced in the resolving shell, so the guard is judged alone. The
#      failing stub still prints a well-formed digest: a pipeline under
#      pipefail can emit one and answer non-zero, so the refusal must come
#      from the status, not from the output being empty.
@test "config-gen: a failed digest refuses with config_gen_unprovisionable" {
  _seed_cg_subtree
  _mock_docker present

  LOG_FORMAT=json run --separate-stderr bash -c "source '${CG}'
_reclaim_tool_dockerfile_hash() { printf '%s\\n' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef; return 1; }
config_gen_resolve"
  assert_refusal 1 config_gen_unprovisionable "path=${CG_DF}"
  assert_equal "$(_count_inspects)" "0"
}

# why: a digest that exits 0 with no output is the second way to have no
#      identity; it must refuse the same as a failed one.
@test "config-gen: an empty digest refuses with config_gen_unprovisionable" {
  _seed_cg_subtree
  _mock_docker present

  LOG_FORMAT=json run --separate-stderr bash -c "source '${CG}'
_reclaim_tool_dockerfile_hash() { return 0; }
config_gen_resolve"
  assert_refusal 1 config_gen_unprovisionable "path=${CG_DF}"
  assert_equal "$(_count_inspects)" "0"
}

# why: without docker the bridge path logs a build and then a build failure
#      whose output is "command not found" -- nothing names the cause.
#      config_gen_resolve names it.
@test "config-gen: docker missing from PATH refuses with config_gen_docker_missing" {
  _seed_cg_subtree
  local _bin="${BATS_TEST_TMPDIR}/nodocker" _d _f
  mkdir -p "${_bin}"
  local -a _dirs
  IFS=: read -r -a _dirs <<< "${PATH}"
  for _d in "${_dirs[@]}"; do
    [[ -d "${_d}" ]] || continue
    for _f in "${_d}"/*; do
      [[ -x "${_f}" && ! -d "${_f}" ]] || continue
      [[ "${_f##*/}" == docker ]] && continue
      [[ -e "${_bin}/${_f##*/}" ]] || ln -s "${_f}" "${_bin}/${_f##*/}"
    done
  done

  run --separate-stderr env LOG_FORMAT=json PATH="${_bin}" \
    "${_bin}/bash" -c "source '${CG}'; config_gen_resolve"
  assert_refusal 1 config_gen_docker_missing
  refute_stderr_contains config_gen_build_failed config_gen_building
}

# why: the two shims share one helper; their profiles and memos must not.
@test "config-gen: toml_bridge.sh and config_gen.sh in one shell keep separate tags and memos" {
  _seed_cg_subtree
  _mock_docker present

  run --separate-stderr bash -c "source '${TB}'; source '${CG}'"
  assert_success
  assert_equal "${stderr}" ""

  run --separate-stderr bash -c "source '${TB}'; source '${CG}'
_toml_bridge_resolve_image || exit 7
config_gen_resolve || exit 8
printf 'tb=%s\n' \"\${_TOML_BRIDGE_RESOLVED}\"
printf 'cg=%s\n' \"\${_CONFIG_GEN_RESOLVED}\""
  assert_success
  assert_line --regexp '^tb=toml-bridge:[0-9a-f]{12}$'
  assert_line "cg=$(_expected_tag)"
  assert_equal "$(_count_inspects)" 2
}

# ── config_gen_tables (base#1470) ────────────────────────────────────────────

# _run_cg_tables <wd> <name>
#   `run` config_gen_tables <name> out from <wd> in a fresh shell with JSON
#   logs and stderr kept apart; out is preset to `stale`, so a value that
#   survives a refusal shows. _cg_tables_seen prints out's final value in
#   brackets.
_run_cg_tables() {
  CGT_NAME="$2" LOG_FORMAT=json run --separate-stderr timeout 10 bash -c "cd '$1' || exit 9
source '${CG}'
out=stale
config_gen_tables \"\${CGT_NAME}\" out
rc=\$?
printf '[%s]' \"\${out}\" > '${BATS_TEST_TMPDIR}/out.seen'
exit \"\${rc}\""
}

_cg_tables_seen() {
  cat -- "${BATS_TEST_TMPDIR}/out.seen"
}

# assert_cg_tables_run <src> <name>
#   assert_cg_run_argv for the run config_gen_tables makes: <src> mounted
#   read-only at /in/f, the caller's uid:gid, the image _expected_tag
#   names, and <name> as the binary's label.
assert_cg_tables_run() {
  assert_cg_run_argv run --rm --user "$(id -u):$(id -g)" \
    --mount "type=bind,src=$1,dst=/in/f,readonly" \
    "$(_expected_tag)" tables --name "$2" /in/f
}

# _mock_docker_tables_output_failed
#   docker records its argv; `image inspect` answers present. `run` is the
#   binary failing to write its answer (tables.go, exitOutput): a valid
#   prefix of the table list on stdout, then one 8-field NUL frame
#   `config_gen_output_failed` on stderr, exit 4.
_mock_docker_tables_output_failed() {
  _cg_mock_docker \
    'case "$1" in
       image) exit 0 ;;
       run)
         printf "a\nb\n"
         printf "D\0error\0config_gen_output_failed\0layer.toml\0\0\0\0write /dev/stdout: broken pipe\0" >&2
         exit 4 ;;
       *) exit 1 ;;
     esac'
}

# why: the binary can write a valid prefix of its answer and then fail
#      (rc 4). A shim that publishes whatever stdout carried would hand the
#      caller a truncated table list as if it were complete. The outvar is
#      cleared on entry (a stale value does not survive) and set only on
#      rc 0; the refusal is the binary's own frame re-emitted.
@test "config-gen: tables publishes nothing when the binary fails after a valid prefix (rc 4)" {
  _seed_cg_subtree
  _mock_docker_tables_output_failed
  local _wd="${BATS_TEST_TMPDIR}/wd"
  mkdir -p "${_wd}"
  printf '[a]\n[b]\n' > "${_wd}/layer.toml"

  _run_cg_tables "${_wd}" layer.toml
  assert_refusal 4 config_gen_output_failed "file=layer.toml"
  assert_equal "$(_cg_tables_seen)" "[]"
}

# _mock_docker_tables_exec
#   docker records its argv; `image inspect` answers present. `run` stands
#   in for the container: it takes the bind mount's src, maps dst=/in/f to
#   it, and execs the real binary (CONFIG_GEN_BIN, provisioned by
#   script/test/test.sh) on the argv after the image, so the answer is the
#   binary's own. CGT_SWAP=fifo|dir replaces src with a FIFO or a
#   directory after the host's checks and before the binary opens it (the
#   race a host-side check cannot close); CGT_DROP_NAME=1 drops `--name
#   <label>`, so the binary itself sees a malformed call; CGT_AS_USER=<u>
#   runs the binary as user <u> (su), standing in for --user when the
#   suite runs as root, whom a mode-000 file does not stop.
_mock_docker_tables_exec() {
  if [[ -z "${CONFIG_GEN_BIN:-}" || ! -x "${CONFIG_GEN_BIN}" ]]; then
    fail "ci_config_gen_unprovisioned: CONFIG_GEN_BIN='${CONFIG_GEN_BIN:-}' is not an executable config-gen binary; script/test/test.sh _prepare_config_gen_bin must provision it (base#1469)"
  fi
  export CONFIG_GEN_BIN
  _cg_mock_docker \
    'case "$1" in
       image) exit 0 ;;
       run)
         shift
         src=""
         while (($#)); do
           case "$1" in
             --rm) shift ;;
             --user) shift 2 ;;
             --mount) m="${2#*src=}"; src="${m%%,dst=/in/f,readonly}"; shift 2 ;;
             *) shift; break ;;
           esac
         done
         case "${CGT_SWAP:-}" in
           fifo) rm -f -- "${src}"; mkfifo -- "${src}" ;;
           dir) rm -f -- "${src}"; mkdir -- "${src}" ;;
         esac
         args=()
         while (($#)); do
           if [[ "${CGT_DROP_NAME:-}" == 1 && "$1" == --name ]]; then
             shift 2
             continue
           fi
           a="$1"
           [[ "${a}" == /in/f ]] && a="${src}"
           args+=("${a}")
           shift
         done
         if [[ -n "${CGT_AS_USER:-}" ]]; then
           exec su -s /bin/sh -c '"'"'exec "$0" "$@"'"'"' -- \
             "${CGT_AS_USER}" "${CONFIG_GEN_BIN}" "${args[@]}"
         fi
         exec "${CONFIG_GEN_BIN}" "${args[@]}" ;;
       *) exit 1 ;;
     esac'
}

# why: on rc 0 the outvar carries the binary's answer, byte for byte: the
#      table list of the mounted file, `[a]` and `[b.c]` giving a, b and
#      b.c (the binary's own output for that input, observed by running it
#      on the file). The run mounts the file read-only by its absolute path
#      as the caller's uid:gid and names it to the binary by the caller's
#      text, so the host never opens it.
@test "config-gen: tables publishes the binary's table list on rc 0" {
  _seed_cg_subtree
  _mock_docker_tables_exec
  local _wd="${BATS_TEST_TMPDIR}/wd"
  mkdir -p "${_wd}"
  printf '[a]\n[b.c]\n' > "${_wd}/layer.toml"

  _run_cg_tables "${_wd}" layer.toml
  assert_success
  assert_output ""
  assert_equal "$(_cg_tables_seen)" "$(printf '[a\nb\nb.c\n]')"
  local _wdp
  _wdp="$(cd "${_wd}" && pwd -P)"
  # The image is the tag project_reclaim.sh's digest names (_expected_tag,
  # pinned to base#1169 by the tag row), not one read back from the shim.
  assert_cg_run_argv run --rm --user "$(id -u):$(id -g)" \
    --mount "type=bind,src=${_wdp}/layer.toml,dst=/in/f,readonly" \
    "$(_expected_tag)" tables --name layer.toml /in/f
  assert_cg_calls image run
}

# why: the image resolves in the caller's shell, so the run names what
#      resolve published there. With CONFIG_GEN_IMAGE pinned in the
#      caller's shell, the run carries that literal and nothing is
#      inspected; a resolve run in a subshell publishes nothing to the
#      caller and the run would name an empty image.
@test "config-gen: tables runs the image CONFIG_GEN_IMAGE pins in the caller's shell" {
  _seed_cg_subtree
  _mock_docker_tables_exec
  local _wd="${BATS_TEST_TMPDIR}/wd"
  mkdir -p "${_wd}"
  printf '[a]\n[b.c]\n' > "${_wd}/layer.toml"

  CONFIG_GEN_IMAGE=config-gen:pinned-1470 _run_cg_tables "${_wd}" layer.toml
  assert_success
  assert_equal "$(_cg_tables_seen)" "$(printf '[a\nb\nb.c\n]')"
  local _wdp
  _wdp="$(cd "${_wd}" && pwd -P)"
  assert_cg_run_argv run --rm --user "$(id -u):$(id -g)" \
    --mount "type=bind,src=${_wdp}/layer.toml,dst=/in/f,readonly" \
    config-gen:pinned-1470 tables --name layer.toml /in/f
  assert_cg_calls run
}

# why: a name that does not exist is refused on the host by a stat alone
#      (the host never opens the path), before any container starts: a
#      `docker run` for it would bind-mount a src that is not there. The
#      refusal is no_such_file naming the caller's text, and the outvar
#      stays cleared.
@test "config-gen: tables refuses a missing file with no_such_file and starts no container" {
  _seed_cg_subtree
  _mock_docker_tables_exec
  local _wd="${BATS_TEST_TMPDIR}/wd"
  mkdir -p "${_wd}"

  _run_cg_tables "${_wd}" missing.toml
  assert_refusal 1 no_such_file "file=missing.toml"
  assert_equal "$(_cg_tables_seen)" "[]"
  assert_cg_calls image
}

# why: a quoted TOML key may hold U+0000. For `["a\u0000b"]` then `[c]`
#      the binary exits 0 and writes `a`, NUL, `b`, newline, `c`, newline
#      (observed by running it on that file). A bash variable cannot hold
#      a NUL, so publishing would silently truncate the list to `a`. The
#      shim refuses it as config_gen_output_nul and leaves the outvar
#      cleared.
@test "config-gen: tables refuses a table list holding a NUL with config_gen_output_nul" {
  _seed_cg_subtree
  _mock_docker_tables_exec
  local _wd="${BATS_TEST_TMPDIR}/wd"
  mkdir -p "${_wd}"
  printf '["a\\u0000b"]\nx = 1\n[c]\ny = 2\n' > "${_wd}/layer.toml"

  _run_cg_tables "${_wd}" layer.toml
  assert_refusal 1 config_gen_output_nul "file=layer.toml"
  assert_equal "$(_cg_tables_seen)" "[]"
}

# why: docker's --mount value is a comma-separated list, so a src holding
#      `,` is read as more options (or refused by docker), and a newline
#      cannot be carried in it at all. A name whose mount src would hold
#      either is refused on the host as config_gen_path_unmountable before
#      any container starts: a `,` in the basename, a `,` in the parent
#      directory, a newline ending the parent directory's name, and a
#      symlinked parent `cl -> c,d` whose name carries no `,` but whose
#      physical path does. The name itself is held to the same rule, so
#      `p,q/../layer.toml` is refused although its physical path carries no
#      comma. The refusal names the caller's text and the outvar stays
#      cleared.
@test "config-gen: tables refuses a name whose mount src would hold a comma or newline" {
  _seed_cg_subtree
  _mock_docker_tables_exec
  local _wd="${BATS_TEST_TMPDIR}/wd"
  mkdir -p "${_wd}/p,q" "${_wd}/rv-d"$'\n' "${_wd}/c,d"
  printf '[a]\n' > "${_wd}/a,b.toml"
  printf '[a]\n' > "${_wd}/p,q/layer.toml"
  printf '[a]\n' > "${_wd}/rv-d"$'\n'"/layer.toml"
  printf '[a]\n' > "${_wd}/c,d/layer.toml"
  ln -s 'c,d' "${_wd}/cl"
  local _name
  printf '[a]\n' > "${_wd}/layer.toml"
  for _name in 'a,b.toml' 'p,q/layer.toml' 'p,q/../layer.toml' "rv-d"$'\n'"/layer.toml" 'cl/layer.toml'; do
    _cg_reset_calls
    _run_cg_tables "${_wd}" "${_name}"
    assert_refusal 1 config_gen_path_unmountable "file=${_name}"
    assert_equal "$(_cg_tables_seen)" "[]"
    assert_cg_calls image
  done
}

# _mock_docker_tables_run_fails <status>
#   docker records its argv; `image inspect` answers present. `run` is
#   docker itself failing before the binary speaks (125 daemon/option
#   error, 126 not executable, 127 not found): a plain-text message on
#   stderr, no NUL frame, exit <status>.
_mock_docker_tables_run_fails() {
  _cg_mock_docker \
    'case "$1" in
       image) exit 0 ;;
       run)
         printf "docker: Error response from daemon: run failed.\n" >&2
         exit '"$1"' ;;
       *) exit 1 ;;
     esac'
}

# why: when docker itself fails (rc 125/126/127) the binary never ran, so
#      no frame names the refusal; a shim that only re-emits frames would
#      return that status with no record of why. Such a run is refused as
#      config_gen_run_failed carrying docker's status, docker's own message
#      is forwarded once as config_gen_stray_stderr (it is the only account
#      of the cause), the status is the answer, and the outvar stays
#      cleared.
@test "config-gen: tables refuses a docker failure with no frame as config_gen_run_failed" {
  _seed_cg_subtree
  local _wd="${BATS_TEST_TMPDIR}/wd"
  mkdir -p "${_wd}"
  printf '[a]\n' > "${_wd}/layer.toml"
  local _rc
  for _rc in 125 126 127; do
    cleanup_mock_dir || true
    _mock_docker_tables_run_fails "${_rc}"
    _run_cg_tables "${_wd}" layer.toml
    assert_refusal "${_rc}" config_gen_run_failed "file=layer.toml" "status=${_rc}"
    assert_logged_event config_gen_stray_stderr "file=layer.toml" \
      "docker: Error response from daemon: run failed."
    assert_equal "$(log_event_ids "${stderr}" | grep -cx config_gen_stray_stderr)" 1
    assert_equal "$(_cg_tables_seen)" "[]"
  done
}

# why: unframed text can also follow the last frame (docker reporting the
#      container's exit after the binary spoke). Read with `read -d ''`,
#      those bytes carry no NUL, so the read fails at EOF and the loop
#      never sees them; dropped, docker's message vanishes. They are
#      forwarded once as config_gen_stray_stderr, the frame before them is
#      re-emitted as its own event, and nothing is called malformed.
@test "config-gen: tables forwards unframed stderr after the last frame once as config_gen_stray_stderr" {
  _seed_cg_subtree
  local _wd="${BATS_TEST_TMPDIR}/wd"
  mkdir -p "${_wd}"
  printf '[a]\n' > "${_wd}/layer.toml"
  local _err="${BATS_TEST_TMPDIR}/frame.err"
  printf 'D\0error\0conf_toml_parse_failed\0layer.toml\0003\0007\0\0dup key\0trailing docker text\n' > "${_err}"
  _mock_docker_tables_stderr "${_err}" 1

  _run_cg_tables "${_wd}" layer.toml
  assert_refusal 1 conf_toml_parse_failed "file=layer.toml" "line=3" "col=7"
  assert_logged_event config_gen_stray_stderr "file=layer.toml" "trailing docker text"
  assert_equal "$(log_event_ids "${stderr}" | grep -cx config_gen_stray_stderr)" 1
  assert_equal "$(log_event_ids "${stderr}" | grep -cx config_gen_diag_malformed)" 0
  assert_equal "$(_cg_tables_seen)" "[]"
}

# _mock_docker_tables_stderr <errfile> <status>
#   docker records its argv; `image inspect` answers present. `run` writes
#   the bytes of <errfile> to stderr verbatim, nothing to stdout, and
#   exits <status>: a scripted diagnostic stream.
_mock_docker_tables_stderr() {
  _cg_mock_docker \
    'case "$1" in
       image) exit 0 ;;
       run)
         cat -- '"'$1'"' >&2
         exit '"$2"' ;;
       *) exit 1 ;;
     esac'
}

# why: the binary's diagnostics are 8-field NUL frames (tag D, severity,
#      event, file, line, col, key, text; tables.go). A stream that is
#      not such a frame -- 7 fields, an 8th field cut off before its NUL,
#      a tag other than D, an event id the registry does not know -- is
#      not a diagnostic the shim can re-emit: dropping it would leave the
#      refusal unexplained, and re-emitting an unknown id makes the logger
#      refuse the body. Each one is refused as config_gen_diag_malformed
#      naming the caller's text, docker's status stays the answer, and
#      the outvar stays cleared.
@test "config-gen: tables refuses a malformed diagnostic frame with config_gen_diag_malformed" {
  _seed_cg_subtree
  local _wd="${BATS_TEST_TMPDIR}/wd"
  mkdir -p "${_wd}"
  printf '[a]\n' > "${_wd}/layer.toml"
  local _err="${BATS_TEST_TMPDIR}/frame.err"
  local _shape
  for _shape in seven truncated tag unregistered; do
    case "${_shape}" in
      seven) printf 'D\0error\0conf_toml_parse_failed\0layer.toml\0003\0007\0dup\0' > "${_err}" ;;
      truncated) printf 'D\0error\0conf_toml_parse_failed\0layer.toml\0003\0007\0\0dup key' > "${_err}" ;;
      tag) printf 'X\0error\0conf_toml_parse_failed\0layer.toml\0003\0007\0\0dup key\0' > "${_err}" ;;
      unregistered) printf 'D\0error\0config_gen_no_such_event_1470\0layer.toml\0003\0007\0\0dup key\0' > "${_err}" ;;
    esac
    cleanup_mock_dir || true
    _mock_docker_tables_stderr "${_err}" 1
    _run_cg_tables "${_wd}" layer.toml
    assert_refusal 1 config_gen_diag_malformed "file=layer.toml"
    assert_equal "$(_cg_tables_seen)" "[]"
  done
}

# why: docker writes its own unframed text to the same stderr as the
#      binary's frames (a platform WARNING line before the binary starts).
#      Read as a frame, that text swallows the frame's tag and the real
#      refusal is lost; dropped, docker's message vanishes. The unframed
#      bytes are forwarded once as config_gen_stray_stderr naming the
#      caller's text, the frame that follows is re-emitted as its own
#      event (conf_toml_parse_failed at line 3 col 7), no frame is called
#      malformed, docker's status stays the answer, and the outvar stays
#      cleared.
@test "config-gen: tables forwards unframed stderr once as config_gen_stray_stderr beside the frame" {
  _seed_cg_subtree
  local _wd="${BATS_TEST_TMPDIR}/wd"
  mkdir -p "${_wd}"
  printf '[a]\n' > "${_wd}/layer.toml"
  local _err="${BATS_TEST_TMPDIR}/frame.err"
  printf 'WARNING: The requested image platform does not match the host\nD\0error\0conf_toml_parse_failed\0layer.toml\0003\0007\0\0dup key\0' > "${_err}"
  _mock_docker_tables_stderr "${_err}" 1

  _run_cg_tables "${_wd}" layer.toml
  assert_refusal 1 conf_toml_parse_failed "file=layer.toml" "line=3" "col=7"
  assert_logged_event config_gen_stray_stderr "file=layer.toml" "WARNING: The requested image platform does not match the host"
  assert_equal "$(log_event_ids "${stderr}" | grep -cx config_gen_stray_stderr)" 1
  assert_equal "$(log_event_ids "${stderr}" | grep -cx config_gen_diag_malformed)" 0
  assert_equal "$(_cg_tables_seen)" "[]"
}

# why: a frame's file, line, col, key and text fields each land in the
#      record attribute of that name. Every field here is distinct and
#      non-empty (key `a.b`, text `dup key`), so a dropped key= or a key=
#      fed from another field shows as a missing or wrong attribute.
@test "config-gen: tables re-emits each frame field as its own attribute" {
  _seed_cg_subtree
  local _wd="${BATS_TEST_TMPDIR}/wd"
  mkdir -p "${_wd}"
  printf '[a]\n' > "${_wd}/layer.toml"
  local _err="${BATS_TEST_TMPDIR}/frame.err"
  printf 'D\0error\0conf_toml_parse_failed\0layer.toml\0003\0007\0a.b\0dup key\0' > "${_err}"
  _mock_docker_tables_stderr "${_err}" 1

  _run_cg_tables "${_wd}" layer.toml
  assert_refusal 1 conf_toml_parse_failed "file=layer.toml" "line=3" \
    "col=7" "key=a.b" "text=dup key"
  assert_equal "$(_cg_tables_seen)" "[]"
}

# why: config_gen_tables takes exactly <file> and <outvar>, and <outvar> is
#      the name of a shell variable it assigns through a nameref. A call
#      with one argument, three arguments, or an outvar that is not a bash
#      identifier (`1bad`, `a-b`) is the caller's mistake: running the
#      generator for it would assign the answer nowhere, or to a name the
#      caller did not mean. Each is refused as config_gen_usage_invalid with
#      rc 2 (the binary's own usage status, tables.go) before any docker
#      call -- no image inspect, no run.
@test "config-gen: tables refuses a malformed call with config_gen_usage_invalid and calls no docker" {
  _seed_cg_subtree
  _mock_docker_tables_exec
  local _wd="${BATS_TEST_TMPDIR}/wd"
  mkdir -p "${_wd}"
  printf '[a]\n' > "${_wd}/layer.toml"
  local _call
  for _call in 'layer.toml' 'layer.toml out extra' 'layer.toml 1bad' 'layer.toml a-b'; do
    _cg_reset_calls
    LOG_FORMAT=json run --separate-stderr bash -c "cd '${_wd}' || exit 9
source '${CG}'
config_gen_tables ${_call}"
    assert_refusal 2 config_gen_usage_invalid
    assert_cg_calls
  done
}

# why: <outvar> is bound by a nameref, and a nameref resolves to the
#      nearest variable of that name: one of config_gen_tables' own locals
#      before the caller's. An outvar named like a local (`_list`, `_tmp`,
#      `_rc`, `_abs`, `_dir`) would take the answer into the local and the
#      caller's variable would stay empty on rc 0. Every local of the
#      function carries the reserved prefix `_cgt_`, so no other name can
#      collide, and an outvar under that prefix (`_cgt_out` is the nameref
#      itself, a circular reference) is refused as config_gen_usage_invalid
#      with rc 2 before any docker call.
@test "config-gen: tables sets an outvar named like a local and refuses the reserved _cgt_ prefix" {
  _seed_cg_subtree
  _mock_docker_tables_exec
  local _wd="${BATS_TEST_TMPDIR}/wd"
  mkdir -p "${_wd}"
  printf '[a]\n[b.c]\n' > "${_wd}/layer.toml"
  local _name
  for _name in _list _tmp _rc _abs _dir; do
    LOG_FORMAT=json run --separate-stderr bash -c "cd '${_wd}' || exit 9
source '${CG}'
${_name}=stale
config_gen_tables layer.toml ${_name}
rc=\$?
printf '[%s]' \"\${${_name}}\"
exit \"\${rc}\""
    assert_success
    assert_equal "${output}" "$(printf '[a\nb\nb.c\n]')"
  done
  for _name in _cgt_out _cgt_list; do
    _cg_reset_calls
    LOG_FORMAT=json run --separate-stderr bash -c "cd '${_wd}' || exit 9
source '${CG}'
config_gen_tables layer.toml ${_name}"
    assert_refusal 2 config_gen_usage_invalid
    assert_cg_calls
  done
  # Every local the function declares is under the reserved prefix, so the
  # refusal above covers every name a nameref could resolve to a local.
  run bash -c "source '${CG}'; declare -f config_gen_tables"
  assert_success
  local _locals
  _locals="$(sed -nE 's/^[[:space:]]*local[[:space:]]+(-[a-z]+[[:space:]]+)*//p' <<< "${output}" \
    | tr ' ;' '\n\n' | sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)(=.*)?$/\1/p')"
  [[ -n "${_locals}" ]] || fail "no local found in config_gen_tables: ${output}"
  run grep -v '^_cgt_' <<< "${_locals}"
  assert_output ""
}

# why: the binary can also write its whole answer and then refuse (rc 1
#      with a frame). A shim that publishes stdout unless the status is 4
#      would hand the caller a list the binary disowned. Only rc 0
#      publishes; the refusal is the binary's frame re-emitted.
@test "config-gen: tables publishes nothing when the binary writes a full list and exits 1" {
  _seed_cg_subtree
  local _wd="${BATS_TEST_TMPDIR}/wd"
  mkdir -p "${_wd}"
  printf '[a]\n[b]\n' > "${_wd}/layer.toml"
  _cg_mock_docker \
    'case "$1" in
       image) exit 0 ;;
       run)
         printf "a\nb\n"
         printf "D\0error\0conf_toml_parse_failed\0layer.toml\0003\0007\0\0dup key\0" >&2
         exit 1 ;;
       *) exit 1 ;;
     esac'

  _run_cg_tables "${_wd}" layer.toml
  assert_refusal 1 conf_toml_parse_failed "file=layer.toml" "line=3" "col=7"
  assert_equal "$(_cg_tables_seen)" "[]"
}

# why: a file the binary cannot parse -- a duplicate key, a syntax error,
#      bytes that are not UTF-8 -- is refused by the binary itself with
#      one conf_toml_parse_failed frame carrying the line and column it
#      reports. The shim re-emits it naming the caller's text, never the
#      in-container path /in/f, and the outvar stays cleared.
@test "config-gen: tables re-emits the binary's parse refusal naming the caller's file" {
  _seed_cg_subtree
  _mock_docker_tables_exec
  local _wd="${BATS_TEST_TMPDIR}/wd"
  mkdir -p "${_wd}"
  local _case _line _col
  for _case in dup:3:7 syntax:2:5 utf8:2:5; do
    IFS=: read -r _case _line _col <<< "${_case}"
    case "${_case}" in
      dup) printf '[a]\nx = 1\nx = 2\n' > "${_wd}/layer.toml" ;;
      syntax) printf '[a]\nx = \n' > "${_wd}/layer.toml" ;;
      utf8) printf '[a]\nx = "\xff"\n' > "${_wd}/layer.toml" ;;
    esac
    _run_cg_tables "${_wd}" layer.toml
    assert_refusal 1 conf_toml_parse_failed "file=layer.toml" "line=${_line}" "col=${_col}"
    [[ "${stderr}" != */in/f* ]] || fail "the log names the in-container path: ${stderr}"
    assert_equal "$(_cg_tables_seen)" "[]"
  done
}

# why: the caller's text reaches the binary as one argv word and comes
#      back in the frame's file field; a tab in it must survive the round
#      trip to the JSON log, not be split or dropped.
@test "config-gen: tables keeps a tab in the file name intact in the refusal" {
  _seed_cg_subtree
  _mock_docker_tables_exec
  local _wd="${BATS_TEST_TMPDIR}/wd"
  mkdir -p "${_wd}"
  printf '[a]\nx = 1\nx = 2\n' > "${_wd}/la"$'\t'"yer.toml"

  _run_cg_tables "${_wd}" "la"$'\t'"yer.toml"
  assert_refusal 1 conf_toml_parse_failed "file=la"$'\t'"yer.toml"
  assert_equal "$(_cg_tables_seen)" "[]"
  local _wdp
  _wdp="$(cd "${_wd}" && pwd -P)"
  assert_cg_tables_run "${_wdp}/la"$'\t'"yer.toml" "la"$'\t'"yer.toml"
  assert_cg_calls image run
}

# why: a name that exists but is not a regular file -- a directory, a FIFO
#      with no writer -- is the binary's to refuse, since the host never
#      opens it: the open is non-blocking, so a FIFO cannot hold the run
#      (the runner's timeout 10 turns a hang into rc 124). Each is
#      config_gen_input_not_regular naming the caller's text.
@test "config-gen: tables refuses a directory or a FIFO as config_gen_input_not_regular" {
  _seed_cg_subtree
  _mock_docker_tables_exec
  local _wd="${BATS_TEST_TMPDIR}/wd"
  mkdir -p "${_wd}/d.toml"
  mkfifo "${_wd}/f.toml"
  local _name
  for _name in d.toml f.toml; do
    _run_cg_tables "${_wd}" "${_name}"
    assert_refusal 1 config_gen_input_not_regular "file=${_name}"
    assert_equal "$(_cg_tables_seen)" "[]"
  done
}

# why: the host's stat runs before the container opens the file, so the
#      file can be swapped for a FIFO or a directory in between. The
#      binary's own check on the opened descriptor still refuses it as
#      config_gen_input_not_regular, within the runner's timeout 10.
@test "config-gen: tables refuses a file swapped for a FIFO or a directory before the binary opens it" {
  _seed_cg_subtree
  _mock_docker_tables_exec
  local _wd="${BATS_TEST_TMPDIR}/wd"
  mkdir -p "${_wd}"
  local _swap _wdp
  _wdp="$(cd "${_wd}" && pwd -P)"
  for _swap in fifo dir; do
    rm -rf -- "${_wd}/layer.toml"
    printf '[a]\n' > "${_wd}/layer.toml"
    _cg_reset_calls
    CGT_SWAP="${_swap}" _run_cg_tables "${_wd}" layer.toml
    assert_refusal 1 config_gen_input_not_regular "file=layer.toml"
    assert_equal "$(_cg_tables_seen)" "[]"
    assert_cg_tables_run "${_wdp}/layer.toml" layer.toml
    assert_cg_calls image run
  done
}

# why: a file the caller's uid cannot read is refused by the binary (it
#      runs as --user uid:gid) as config_gen_input_unreadable naming the
#      caller's text; the host never tries to read it.
@test "config-gen: tables refuses an unreadable file as config_gen_input_unreadable" {
  _seed_cg_subtree
  _mock_docker_tables_exec
  local _wd="${BATS_TEST_TMPDIR}/wd"
  mkdir -p "${_wd}"
  printf '[a]\n' > "${_wd}/layer.toml"
  chmod 000 "${_wd}/layer.toml"

  local _as=""
  (($(id -u) != 0)) || _as=nobody
  CGT_AS_USER="${_as}" _run_cg_tables "${_wd}" layer.toml
  chmod 600 "${_wd}/layer.toml"
  assert_refusal 1 config_gen_input_unreadable "file=layer.toml"
  assert_equal "$(_cg_tables_seen)" "[]"
  local _wdp
  _wdp="$(cd "${_wd}" && pwd -P)"
  assert_cg_tables_run "${_wdp}/layer.toml" layer.toml
  assert_cg_calls image run
}

# why: when the binary itself is called wrongly (here the run reaches it
#      as `tables /in/f`, no --name), it exits 2 with one
#      config_gen_usage_invalid frame; the shim keeps that status and
#      re-emits the frame rather than folding it into run_failed.
@test "config-gen: tables keeps the binary's own usage refusal and rc 2" {
  _seed_cg_subtree
  _mock_docker_tables_exec
  local _wd="${BATS_TEST_TMPDIR}/wd"
  mkdir -p "${_wd}"
  printf '[a]\n' > "${_wd}/layer.toml"

  CGT_DROP_NAME=1 _run_cg_tables "${_wd}" layer.toml
  assert_refusal 2 config_gen_usage_invalid
  assert_equal "$(log_event_ids "${stderr}" | grep -cx config_gen_run_failed)" 0
  assert_equal "$(_cg_tables_seen)" "[]"
  local _wdp
  _wdp="$(cd "${_wd}" && pwd -P)"
  assert_cg_tables_run "${_wdp}/layer.toml" layer.toml
  assert_cg_calls image run
}

# why: the image resolves in the caller's shell before any run; when it
#      cannot (the build fails, or the subtree cannot name the image) the
#      shim answers 1 with resolve's own refusal and starts no container.
@test "config-gen: tables refuses with resolve's refusal and starts no container when the image cannot be provisioned" {
  _seed_cg_subtree
  local _wd="${BATS_TEST_TMPDIR}/wd"
  mkdir -p "${_wd}"
  printf '[a]\n' > "${_wd}/layer.toml"
  _mock_docker fail
  _run_cg_tables "${_wd}" layer.toml
  assert_refusal 1 config_gen_build_failed "path=${CG_DF}" "status=125"
  assert_equal "$(_cg_tables_seen)" "[]"
  assert_cg_calls image build

  # A fresh stub: _cg_assert_recording in assert_cg_calls proves it
  # records before its empty call list is read.
  cleanup_mock_dir || true
  _cg_reset_calls
  _mock_docker present
  rm -f "${CG_DF}"
  _run_cg_tables "${_wd}" layer.toml
  assert_refusal 1 config_gen_unprovisionable "path=${CG_DF}"
  assert_equal "$(_cg_tables_seen)" "[]"
  assert_cg_calls
}

# why: the mounted file must be the one the kernel opens for the caller's
#      name. With `lnk -> real/sub`, `lnk/../layer.toml` is real/layer.toml
#      to the kernel (each `..` applies to the physical directory), while a
#      lexical reading drops `lnk/..` and names ./layer.toml, another file.
#      The expected answer is the kernel's own walk (`cat` of the name in
#      this test), not the shim's resolve: the src is <pwd -P>/real/layer.toml
#      and the outvar holds that file's table list.
@test "config-gen: tables mounts the file the kernel opens for a name with .. after a symlink" {
  _seed_cg_subtree
  _mock_docker_tables_exec
  local _wd="${BATS_TEST_TMPDIR}/wd"
  mkdir -p "${_wd}/real/sub"
  ln -s real/sub "${_wd}/lnk"
  printf '[kernel]\n' > "${_wd}/real/layer.toml"
  printf '[lexical]\n' > "${_wd}/layer.toml"
  run cat -- "${_wd}/lnk/../layer.toml"
  assert_output "[kernel]"

  _run_cg_tables "${_wd}" lnk/../layer.toml
  assert_success
  assert_equal "$(_cg_tables_seen)" "$(printf '[kernel\n]')"
  local _wdp
  _wdp="$(cd "${_wd}" && pwd -P)"
  assert_cg_tables_run "${_wdp}/real/layer.toml" lnk/../layer.toml
  assert_cg_calls image run
}

# _mock_docker_tables_ok
#   docker records its argv; `image inspect` answers present. `run` prints
#   the table list `a` and exits 0: a scripted answer, so the row asserts
#   only what the shim hands docker.
_mock_docker_tables_ok() {
  _cg_mock_docker \
    'case "$1" in
       image) exit 0 ;;
       run) printf "a\n"; exit 0 ;;
       *) exit 1 ;;
     esac'
}

# why: a name directly under / (here /etc, present on every Linux host
#      the suite runs on) has an empty parent once the basename is cut.
#      The mount src is the name itself, /etc, written by hand here, not
#      derived the way the shim does: not a refusal as no_such_file (cd
#      to an empty dir fails) and not //etc (the root's `/` doubled).
@test "config-gen: tables mounts a name directly under / by that name" {
  _seed_cg_subtree
  _mock_docker_tables_ok
  local _wd="${BATS_TEST_TMPDIR}/wd"
  mkdir -p "${_wd}"

  _run_cg_tables "${_wd}" /etc
  assert_success
  assert_equal "$(_cg_tables_seen)" "$(printf '[a\n]')"
  assert_cg_tables_run /etc /etc
  assert_cg_calls image run
}

# why: the raw name lnk/layer.toml holds no comma or newline, but its
#      parent lnk is a symlink to a directory whose name ends in a
#      newline, so the file the kernel opens is <wd>/t<LF>/layer.toml.
#      That path cannot be written in a --mount; dropping the trailing
#      newline would mount <wd>/t/layer.toml, another file (here one that
#      exists, holding [other]). The name is refused as unmountable and no
#      container starts.
@test "config-gen: tables refuses a name whose symlinked parent ends in a newline" {
  _seed_cg_subtree
  _mock_docker_tables_exec
  local _wd="${BATS_TEST_TMPDIR}/wd"
  mkdir -p "${_wd}/t"$'\n' "${_wd}/t"
  printf '[a]\n' > "${_wd}/t"$'\n'"/layer.toml"
  printf '[other]\n' > "${_wd}/t/layer.toml"
  ln -s "t"$'\n' "${_wd}/lnk"
  run cat -- "${_wd}/lnk/layer.toml"
  assert_output "[a]"

  _run_cg_tables "${_wd}" lnk/layer.toml
  assert_refusal 1 config_gen_path_unmountable "file=lnk/layer.toml"
  assert_equal "$(_cg_tables_seen)" "[]"
  assert_cg_calls image
}

# why: the parent can vanish between the host's stat and its `cd -P`.
#      A failing cd prints nothing, and without the `&& ... printf x`
#      sentinel check the src would be `/<basename>`, a file at the root
#      the caller never named. Here the image is resolved first (its one
#      inspect is memoised), then cd fails for every directory (a function
#      in the caller's shell, which the `$(...)` inherits): the name is
#      refused as no_such_file before any run, and the outvar stays
#      cleared.
@test "config-gen: tables refuses a name whose parent cannot be entered and starts no container" {
  _seed_cg_subtree
  _mock_docker_tables_exec
  local _wd="${BATS_TEST_TMPDIR}/wd"
  mkdir -p "${_wd}/sub"
  printf '[a]\n' > "${_wd}/sub/layer.toml"

  LOG_FORMAT=json run --separate-stderr timeout 10 bash -c "cd '${_wd}' || exit 9
source '${CG}'
config_gen_resolve || exit 8
cd() { return 1; }
out=stale
config_gen_tables sub/layer.toml out
rc=\$?
printf '[%s]' \"\${out}\" > '${BATS_TEST_TMPDIR}/out.seen'
exit \"\${rc}\""
  assert_refusal 1 no_such_file "file=sub/layer.toml"
  assert_equal "$(_cg_tables_seen)" "[]"
  assert_cg_calls image
}

# why: config_gen_tables keeps the binary's stdout and stderr in a temp
#      directory; one left behind per call would fill TMPDIR over a long
#      shell. It is removed whether the run publishes or refuses.
@test "config-gen: tables removes its temp directory on success and on refusal" {
  _seed_cg_subtree
  _mock_docker_tables_exec
  local _wd="${BATS_TEST_TMPDIR}/wd" _tmpd="${BATS_TEST_TMPDIR}/tmpd"
  mkdir -p "${_wd}" "${_tmpd}"
  printf '[a]\n' > "${_wd}/good.toml"
  printf '[a]\nx = 1\nx = 2\n' > "${_wd}/bad.toml"
  local _name
  for _name in good.toml bad.toml; do
    TMPDIR="${_tmpd}" _run_cg_tables "${_wd}" "${_name}"
    run find "${_tmpd}" -mindepth 1
    assert_output ""
  done
}
