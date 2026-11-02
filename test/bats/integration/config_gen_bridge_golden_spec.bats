#!/usr/bin/env bats
#
# config_gen_bridge_golden_spec.bats -- the s1 corpus of `config-gen tables`
# against the bridge's `--tables` goldens (base#1469, slice S1i of base#1395).
#
# why: Every fixture under dockerfile/config-gen/testdata/corpus/s1 carries
# one explicit expectation class in testdata/golden/s1/EXPECT, one row per
# fixture, `<fixture>\t<class>`:
#
#   parity                      bridge and config-gen print the golden
#   parity-refused              both sides give rc 1
#   bridge-refused-go-accepted  config-gen gives rc 0 and its golden, the
#                               bridge gives rc 1; only toml11_* fixtures
#                               may carry it (today's known divergence,
#                               not a parity claim)
#
# A fixture with no row, a row with no fixture, or the divergent class on
# any other name fails the spec, so a new fixture can never be read without
# a stated expectation and a stale row can never stand for a deleted one.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  TESTDATA="/source/dockerfile/config-gen/testdata"
  S="${BATS_TEST_TMPDIR}"
}

# ── the partition check ─────────────────────────────────────────────────────

# _expect_partition <corpus-dir> <expect-file> -- succeed only when every
# <corpus-dir>/*.toml stem has exactly one well-formed EXPECT row, every row
# names an existing fixture, and bridge-refused-go-accepted sits only on a
# toml11_* name. Prints one line per violation; returns 1 on any.
_expect_partition() {
  local _corpus="${1}" _expect="${2}" _line _name _class _f _stem _bad=0
  local _re=$'^([^\t]+)\t(parity|parity-refused|bridge-refused-go-accepted)$'
  local -A _row=()
  if [[ ! -f "${_expect}" ]]; then
    printf 'EXPECT file missing: %s\n' "${_expect}"
    return 1
  fi
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    if [[ ! "${_line}" =~ ${_re} ]]; then
      printf 'EXPECT row malformed: %q\n' "${_line}"
      _bad=1
      continue
    fi
    _name="${BASH_REMATCH[1]}"
    _class="${BASH_REMATCH[2]}"
    if [[ -n "${_row["${_name}"]+set}" ]]; then
      printf 'EXPECT row repeated: %s\n' "${_name}"
      _bad=1
    fi
    _row["${_name}"]="${_class}"
    if [[ ! -f "${_corpus}/${_name}.toml" ]]; then
      printf 'EXPECT row with no fixture: %s\n' "${_name}"
      _bad=1
    fi
    if [[ "${_class}" == bridge-refused-go-accepted && "${_name}" != toml11_* ]]; then
      printf 'bridge-refused-go-accepted on a non-toml11_* fixture: %s\n' "${_name}"
      _bad=1
    fi
  done < "${_expect}"
  for _f in "${_corpus}"/*.toml; do
    [[ -e "${_f}" ]] || continue
    _stem="$(basename -- "${_f}" .toml)"
    if [[ -z "${_row["${_stem}"]+set}" ]]; then
      printf 'fixture with no EXPECT row: %s\n' "${_stem}"
      _bad=1
    fi
  done
  return "${_bad}"
}

# _mini <name>... -- a scratch corpus ${S}/c holding <name>.toml for each
# name, for the partition check's own rows.
_mini() {
  local _n
  mkdir -p "${S}/c"
  for _n in "$@"; do
    printf 'x = 1\n' > "${S}/c/${_n}.toml"
  done
}

# why: a fixture read with no stated expectation would be judged by
# whatever class a default picked; the partition check must name it.
@test "partition: a fixture with no EXPECT row fails" {
  _mini a b
  printf 'a\tparity\n' > "${S}/EXPECT"
  run _expect_partition "${S}/c" "${S}/EXPECT"
  assert_failure
  assert_output --partial "fixture with no EXPECT row: b"
}

# why: a stale row for a deleted fixture would stand for a case nothing
# runs any more; the partition check must name it.
@test "partition: an EXPECT row with no fixture fails" {
  _mini a
  printf 'a\tparity\nghost\tparity-refused\n' > "${S}/EXPECT"
  run _expect_partition "${S}/c" "${S}/EXPECT"
  assert_failure
  assert_output --partial "EXPECT row with no fixture: ghost"
}

# why: the divergent class is today's known TOML 1.1 gap and nothing
# else; on any other name it would excuse a real parity break. Exactly the
# offending row is reported, the toml11_* one is not.
@test "partition: bridge-refused-go-accepted on a non-toml11_* fixture fails" {
  _mini a toml11_ok
  printf 'a\tbridge-refused-go-accepted\ntoml11_ok\tbridge-refused-go-accepted\n' > "${S}/EXPECT"
  run _expect_partition "${S}/c" "${S}/EXPECT"
  assert_failure
  assert_output "bridge-refused-go-accepted on a non-toml11_* fixture: a"
}

# why: the control for the three refusals above: every class on a
# matching fixture set passes silently, so their failures are the rule
# firing and not a check that refuses everything.
@test "partition: one well-formed row per fixture passes" {
  _mini a b toml11_ok
  printf 'a\tparity\nb\tparity-refused\ntoml11_ok\tbridge-refused-go-accepted\n' > "${S}/EXPECT"
  run _expect_partition "${S}/c" "${S}/EXPECT"
  assert_success
  assert_output ""
}

# why: the same check over the real corpus and EXPECT, so a fixture added
# or deleted without its row fails here before any per-class comparison.
@test "the s1 corpus is partitioned by golden/s1/EXPECT, one row per fixture" {
  run _expect_partition "${TESTDATA}/corpus/s1" "${TESTDATA}/golden/s1/EXPECT"
  assert_success
  assert_output ""
}

# ── per class: bridge and binary each against the golden ────────────────────

# why: the golden is the bridge's own `--tables` answer captured once; this
# re-runs BOTH sides over every s1 fixture and compares each one's bytes to
# that file with cmp, never through $(...), which would drop trailing LFs
# and hide a missing or extra final newline. The binary is the built
# config-gen that script/test/test.sh provisions as CONFIG_GEN_BIN; an
# unprovisioned binary fails the spec (ci_config_gen_unprovisioned), it is
# never skipped, so a run without it can not pass by testing nothing.
@test "per EXPECT class, the bridge and the config-gen binary each match golden/s1" {
  local _bridge="/source/dockerfile/toml_bridge.py"
  local _row _name _class _in _gold _rc _bad=0
  if [[ -z "${CONFIG_GEN_BIN:-}" || ! -x "${CONFIG_GEN_BIN}" ]]; then
    fail "ci_config_gen_unprovisioned: CONFIG_GEN_BIN='${CONFIG_GEN_BIN:-}' is not an executable config-gen binary; script/test/test.sh _prepare_config_gen_bin must provision it (base#1469)"
  fi
  while IFS= read -r _row || [[ -n "${_row}" ]]; do
    _name="${_row%%$'\t'*}"
    _class="${_row#*$'\t'}"
    _in="${TESTDATA}/corpus/s1/${_name}.toml"
    _gold="${TESTDATA}/golden/s1/${_name}.golden"

    _rc=0
    python3 "${_bridge}" --tables < "${_in}" > "${S}/bridge.out" 2> "${S}/bridge.err" || _rc=$?
    case "${_class}" in
      parity | parity-refused)
        if [[ "${_class}" == parity ]]; then
          if (( _rc != 0 )) || ! cmp -s "${_gold}" "${S}/bridge.out"; then
            printf '%s: bridge rc=%d or stdout differs from golden\n' "${_name}" "${_rc}"
            _bad=1
          fi
        elif (( _rc != 1 )); then
          printf '%s: bridge rc=%d, want 1\n' "${_name}" "${_rc}"
          _bad=1
        fi
        ;;
      bridge-refused-go-accepted)
        if (( _rc != 1 )); then
          printf '%s: bridge rc=%d, want 1\n' "${_name}" "${_rc}"
          _bad=1
        fi
        ;;
    esac

    _rc=0
    "${CONFIG_GEN_BIN}" tables --name "${_name}" "${_in}" > "${S}/bin.out" 2> "${S}/bin.err" || _rc=$?
    if [[ "${_class}" == parity-refused ]]; then
      if (( _rc != 1 )) || [[ -s "${S}/bin.out" ]]; then
        printf '%s: config-gen rc=%d (want 1) or stdout not empty\n' "${_name}" "${_rc}"
        _bad=1
      fi
    elif (( _rc != 0 )) || [[ -s "${S}/bin.err" ]] || ! cmp -s "${_gold}" "${S}/bin.out"; then
      printf '%s: config-gen rc=%d, stderr bytes=%d, or stdout differs from golden\n' \
        "${_name}" "${_rc}" "$(wc -c < "${S}/bin.err")"
      _bad=1
    fi
  done < "${TESTDATA}/golden/s1/EXPECT"
  (( _bad == 0 ))
}

# ── every frame's event id is registered ────────────────────────────────────

# why: log-events.txt is the registered body enum; an unregistered body is
# fatal once the shell re-emits a frame through _log_* (#438), so an event
# id the binary frames but the registry lacks would turn a refusal into a
# crash of its caller. This drives the built binary down each refusal it
# can reach -- wrong argv, a parse error, a missing path, a directory, a
# mode-000 file opened by uid 65534, and a stdout on /dev/full -- and
# requires of each the exit status and event id the I/O contract names
# for it (usage 2, output failure 4, every other refusal 1), exactly one
# 8-field frame, and that event id being a line of the registry
# (base#1469 I/O contract; files: log-events.txt). Pinning the exact pair
# per case keeps a refusal that took the wrong path -- a write failure
# reported as rc 1 with some other registered id -- from passing.
@test "every event id the config-gen binary frames is registered in log-events.txt" {
  local _reg="/source/dist/script/docker/lib/log-events.txt"
  local _ok="${TESTDATA}/corpus/s1/implicit_parent_order.toml"
  local _case _rc _cmd _shared _want_rc _want_ev _bad=0
  local -a _f=()
  local -A _want=(
    [usage]="2 config_gen_usage_invalid"
    [parse]="1 conf_toml_parse_failed"
    [missing]="1 no_such_file"
    [dir]="1 config_gen_input_not_regular"
    [unreadable]="1 config_gen_input_unreadable"
    [full]="4 config_gen_output_failed"
  )
  if [[ -z "${CONFIG_GEN_BIN:-}" || ! -x "${CONFIG_GEN_BIN}" ]]; then
    fail "ci_config_gen_unprovisioned: CONFIG_GEN_BIN='${CONFIG_GEN_BIN:-}' is not an executable config-gen binary; script/test/test.sh _prepare_config_gen_bin must provision it (base#1469)"
  fi
  # toml-fixture-lint: allow the parse refusal is the case under test
  printf '[a]\nk = = 1\n' > "${S}/bad.toml"
  mkdir -p "${S}/dir.toml"
  # uid 65534 must reach the binary and the locked file, and the bats
  # tmpdir's parents are not traversable by it: a world-traversable dir of
  # its own holds a copy of the binary and the mode-000 file.
  _shared="$(mktemp -d /tmp/cg-registry.XXXXXX)"
  chmod 755 "${_shared}"
  cp "${CONFIG_GEN_BIN}" "${_shared}/config-gen"
  chmod 755 "${_shared}/config-gen"
  printf '[a]\n' > "${_shared}/f.toml"
  chmod 000 "${_shared}/f.toml"
  printf -v _cmd '%q tables --name l %q > /dev/null' \
    "${_shared}/config-gen" "${_shared}/f.toml"

  for _case in usage parse missing dir unreadable full; do
    _rc=0
    case "${_case}" in
      usage) "${CONFIG_GEN_BIN}" tables "${_ok}" > /dev/null 2> "${S}/err" || _rc=$? ;;
      parse) "${CONFIG_GEN_BIN}" tables --name l "${S}/bad.toml" > /dev/null 2> "${S}/err" || _rc=$? ;;
      missing) "${CONFIG_GEN_BIN}" tables --name l "${S}/absent.toml" > /dev/null 2> "${S}/err" || _rc=$? ;;
      dir) timeout 10 "${CONFIG_GEN_BIN}" tables --name l "${S}/dir.toml" > /dev/null 2> "${S}/err" || _rc=$? ;;
      unreadable)
        if (( $(id -u) == 0 )); then
          su -s /bin/sh nobody -c "${_cmd}" 2> "${S}/err" || _rc=$?
        else
          "${_shared}/config-gen" tables --name l "${_shared}/f.toml" > /dev/null 2> "${S}/err" || _rc=$?
        fi
        ;;
      full) "${CONFIG_GEN_BIN}" tables --name l "${_ok}" > /dev/full 2> "${S}/err" || _rc=$? ;;
    esac
    read -r _want_rc _want_ev <<<"${_want[${_case}]}"
    _f=()
    mapfile -d '' -t _f < "${S}/err"
    if (( _rc != _want_rc || ${#_f[@]} != 8 )) || [[ "${_f[0]:-}" != D || "${_f[2]:-}" != "${_want_ev}" ]]; then
      printf '%s: rc=%d, %d NUL fields, event %s; want rc %d and one 8-field frame with event %s\n' \
        "${_case}" "${_rc}" "${#_f[@]}" "${_f[2]:-}" "${_want_rc}" "${_want_ev}"
      _bad=1
      continue
    fi
    if ! grep -qxF -- "${_f[2]}" "${_reg}"; then
      printf '%s: event id %s is not registered in log-events.txt\n' "${_case}" "${_f[2]}"
      _bad=1
    fi
  done
  rm -rf -- "${_shared}"
  (( _bad == 0 ))
}

# ── non-regular input on the built binary ──────────────────────────────────

# why: the Go test drives the same four types in-process; this repeats them
# on the built binary, each under `timeout 10`, so an open that waits for a
# FIFO writer, or a read that blocks on a socket or a device, ends as rc
# 124 and fails here instead of hanging the suite. Every type -- a
# directory, a FIFO with no writer, the character device /dev/null and a
# unix socket -- must give rc 1, empty stdout and exactly one
# `config_gen_input_not_regular` frame whose file field is the --name
# label (base#1469 Input: open O_RDONLY|O_NONBLOCK, fstat on the fd). The
# socket lives in a short /tmp directory of its own: sun_path holds 108
# bytes, which the bats tmpdir can exceed.
@test "config-gen binary refuses a directory, FIFO, char device and socket under timeout 10" {
  local _case _path _rc _sockdir _bad=0
  local -a _f=()
  if [[ -z "${CONFIG_GEN_BIN:-}" || ! -x "${CONFIG_GEN_BIN}" ]]; then
    fail "ci_config_gen_unprovisioned: CONFIG_GEN_BIN='${CONFIG_GEN_BIN:-}' is not an executable config-gen binary; script/test/test.sh _prepare_config_gen_bin must provision it (base#1469)"
  fi
  mkdir -p "${S}/dir.toml"
  mkfifo "${S}/fifo.toml"
  _sockdir="$(mktemp -d /tmp/cg-sock.XXXXXX)"
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' \
    "${_sockdir}/s.toml"
  [[ -S "${_sockdir}/s.toml" ]] || fail "no unix socket at ${_sockdir}/s.toml"
  [[ -c /dev/null ]] || fail "/dev/null is not a character device"

  for _case in dir fifo chardev socket; do
    case "${_case}" in
      dir) _path="${S}/dir.toml" ;;
      fifo) _path="${S}/fifo.toml" ;;
      chardev) _path=/dev/null ;;
      socket) _path="${_sockdir}/s.toml" ;;
    esac
    _rc=0
    timeout 10 "${CONFIG_GEN_BIN}" tables --name l.toml "${_path}" \
      > "${S}/out" 2> "${S}/err" || _rc=$?
    _f=()
    mapfile -d '' -t _f < "${S}/err"
    if (( _rc != 1 || ${#_f[@]} != 8 )) || [[ -s "${S}/out" ]] \
        || [[ "${_f[0]:-}" != D || "${_f[2]:-}" != config_gen_input_not_regular || "${_f[3]:-}" != l.toml ]]; then
      printf '%s: rc=%d (124 is the timeout), stdout bytes=%d, %d NUL fields, event %s, file %s; want rc 1, empty stdout, one config_gen_input_not_regular frame for l.toml\n' \
        "${_case}" "${_rc}" "$(wc -c < "${S}/out")" "${#_f[@]}" "${_f[2]:-}" "${_f[3]:-}"
      _bad=1
    fi
  done
  rm -rf -- "${_sockdir}"
  (( _bad == 0 ))
}

# ── output failure on a real sink ───────────────────────────────────────────

# why: the Go fault writer covers a write that fails at byte N in-process;
# this is the same contract on the built binary against a real file whose
# size limit (RLIMIT_FSIZE via prlimit) lets it take some bytes and then
# refuse with EFBIG, which /dev/full (0 bytes, ENOSPC) can not show. The
# answer is exit 4, exactly one `config_gen_output_failed` frame, and a
# non-empty stdout that is a strict prefix of the bridge golden (base#1469
# I/O contract). SIGXFSZ is ignored so the write returns EFBIG instead of
# killing the process. prlimit must be on PATH in every environment the
# spec runs in (test-tools installs util-linux-misc); a missing prlimit
# fails here, it is never skipped.
@test "config-gen binary on a size-limited stdout exits 4 with one frame and a golden prefix" {
  local _in="${TESTDATA}/corpus/s1/large_tables.toml"
  local _gold="${TESTDATA}/golden/s1/large_tables.golden"
  local _size _limit _rc _got
  local -a _f=()
  if [[ -z "${CONFIG_GEN_BIN:-}" || ! -x "${CONFIG_GEN_BIN}" ]]; then
    fail "ci_config_gen_unprovisioned: CONFIG_GEN_BIN='${CONFIG_GEN_BIN:-}' is not an executable config-gen binary; script/test/test.sh _prepare_config_gen_bin must provision it (base#1469)"
  fi
  run command -v prlimit
  if (( status != 0 )); then
    fail "prlimit is not on PATH; dockerfile/Dockerfile.test-tools must install util-linux-misc (it owns /usr/bin/prlimit) for this leg (base#1469)"
  fi

  _size="$(wc -c < "${_gold}")"
  (( _size >= 65536 )) || fail "golden ${_gold} is ${_size} bytes, want at least 64 KiB"
  _limit=$(( _size / 2 ))

  _rc=0
  (
    trap '' XFSZ
    exec prlimit --fsize="${_limit}" "${CONFIG_GEN_BIN}" tables \
      --name large_tables.toml "${_in}"
  ) > "${S}/cap" 2> "${S}/err" || _rc=$?

  (( _rc == 4 )) || fail "config-gen exited ${_rc}, want 4 (stderr: $(tr '\0' '|' < "${S}/err"))"
  mapfile -d '' -t _f < "${S}/err"
  (( ${#_f[@]} == 8 )) || fail "stderr holds ${#_f[@]} NUL fields, want exactly one 8-field frame"
  [[ "${_f[0]}" == D && "${_f[2]}" == config_gen_output_failed ]] \
    || fail "frame tag/event = ${_f[0]}/${_f[2]}, want D/config_gen_output_failed"
  _got="$(wc -c < "${S}/cap")"
  (( _got > 0 && _got < _size )) \
    || fail "stdout took ${_got} bytes, want a non-empty strict prefix of the ${_size}-byte golden"
  cmp -s -n "${_got}" "${S}/cap" "${_gold}" \
    || fail "stdout's ${_got} bytes are not a prefix of the golden"
}
