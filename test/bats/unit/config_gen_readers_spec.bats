#!/usr/bin/env bats
#
# config_gen_readers_spec.bats -- "the config-gen reader tracer sees every
# file a host step sources, however the path is built", base#1584.
#
# why: script/ci/config_gen_readers.sh is the reader side of the config-gen
# deny list (config_gen_paths_spec.bats). A sourced file it misses could
# stay a deny entry while config-gen reads it, so its channels are proven
# on planted steps: a path built at runtime (no text names it), a sourced
# file that only defines functions (the DEBUG channel never sees it, r7
# probe), one that does not parse, and a read through a symlink.
#
# The planted copy is traced once per file and shared by every case.

bats_require_minimum_version 1.5.0

setup_file() {
  local _v="${BATS_FILE_TMPDIR}/variant" _rc=0
  mkdir -p "${_v}"
  cp -R /source/. "${_v}/"
  rm -rf "${_v}/.git"
  local _steps="${_v}/script/test/config_gen_steps"
  # (a) a runtime-built path to a file that runs commands;
  # (b) one to a file that only defines a function nobody calls;
  # (c) one to a file that does not parse.
  printf 'defs_only() { :; }\n' >"${_v}/dist/script/base/upgrade.sh"
  printf 'broken() {\n  echo never\n' >"${_v}/dist/script/base/upstream.sh"
  # (d) a tracked relative symlink to a file under real/.
  mkdir -p "${_v}/script/release/real"
  printf 'x_def() { :; }\n' >"${_v}/script/release/real/x.sh"
  ln -s real/x.sh "${_v}/script/release/lnk.sh"
  cat >"${_steps}/90-planted-base1584.sh" <<'EOF'
#!/usr/bin/env bash
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
d=base
for n in init upgrade upstream; do
  source "${root}/dist/script/${d}/${n}.sh" || true
done
source "${root}/script/release/lnk.sh" || true
EOF
  bash /source/script/ci/config_gen_readers.sh --root "${_v}" --by-channel \
    >"${BATS_FILE_TMPDIR}/readers.tsv" 2>"${BATS_FILE_TMPDIR}/readers.err" || _rc=$?
  printf '%s\n' "${_rc}" >"${BATS_FILE_TMPDIR}/readers.rc"
}

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  READERS_SH=/source/script/ci/config_gen_readers.sh
  READERS="${BATS_FILE_TMPDIR}/readers.tsv"
}

_require_readers() {
  local _rc
  _rc="$(cat "${BATS_FILE_TMPDIR}/readers.rc")"
  [[ "${_rc}" == 0 && -s "${READERS}" ]] \
    || fail "config_gen_readers.sh exited ${_rc}: $(head -c 2000 "${BATS_FILE_TMPDIR}/readers.err")"
}

# _seen <channel|any> <path> -- succeeds when the traced run holds <path>.
_seen() {
  if [[ "$1" == any ]]; then
    awk -F'\t' -v p="$2" '$1 != "rp" && $2 == p {f = 1} END {exit !f}' "${READERS}"
  else
    grep -qxF -- "$1"$'\t'"$2" "${READERS}"
  fi
}

# why: cycle 13 (a). A step sources dist/script/base/init.sh through
# `${d}` set at runtime, so no text names the path and shellcheck passes
# the line; the trace must still hold it, so the deny entry fails
# config_gen_paths_spec.
@test "config_gen_readers: a source through a runtime-built path is a reader (base#1584)" {
  _require_readers
  _seen any dist/script/base/init.sh || fail "init.sh is not in the reader set"
}

# why: cycle 13 (b) (RR6-F3). A sourced file that only defines a function
# never runs a command, so the DEBUG channel alone misses it (r7 probe:
# defs.sh absent from the DEBUG log). The xtrace channel logs the source.
@test "config_gen_readers: a sourced file that only defines functions is a reader (base#1584)" {
  _require_readers
  _seen xtrace dist/script/base/upgrade.sh || fail "the xtrace channel missed upgrade.sh"
}

# why: cycle 13 (c). A sourced file that does not parse runs nothing
# either; the source command is still logged before it fails.
@test "config_gen_readers: a sourced file that does not parse is a reader (base#1584)" {
  _require_readers
  _seen xtrace dist/script/base/upstream.sh || fail "the xtrace channel missed upstream.sh"
}

# why: cycle 14 (RR4-F2). A read through a symlink names both the link and
# its target, so a deny entry for either fails.
@test "config_gen_readers: a read through a symlink names the link and its target (base#1584)" {
  _require_readers
  _seen any script/release/lnk.sh || fail "the link is not in the reader set"
  _seen any script/release/real/x.sh || fail "the link's target is not in the reader set"
}

# why: cycle 30 (RR6-F4). The readers script runs `just --show test::go`'s
# body, so it must read each line's command and environment as the recipe
# states them: config_gen_gates.sh with an unchanged environment, and
# config_gen_redpath.sh with CONFIG_GEN_REDPATH_ONLY unset.
@test "config_gen_readers: the recipe parser reads test::go's commands and environment (base#1584)" {
  local _show
  _show="$(cd /source && just --show test::go)"
  run bash -c "bash '${READERS_SH}' --parse-recipe <<<\"\$1\"" _ "${_show}"
  assert_success
  assert_output "./script/test/config_gen_gates.sh"$'\t\t'"
./script/test/config_gen_redpath.sh"$'\t'"CONFIG_GEN_REDPATH_ONLY"$'\t'
}

# why: cycle 30. Any other line shape -- a pipe or `&&`, a variable -- is
# a command this parser would have to guess at, so it refuses.
@test "config_gen_readers: the recipe parser refuses a line it cannot run as one ./ command (base#1584)" {
  local _line
  for _line in '    foo && ./x.sh' '    "${X}"/y.sh' '    other-recipe'; do
    run bash -c "printf 'go:\n%s\n' \"\$1\" | bash '${READERS_SH}' --parse-recipe" _ "${_line}"
    assert_failure
  done
}
