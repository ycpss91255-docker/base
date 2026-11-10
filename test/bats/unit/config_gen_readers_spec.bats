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

# _wf_root <dir> -- a checkout holding only a copy of self-test.yaml, for
# the cases that edit the workflow.
_wf_root() {
  mkdir -p "$1/.github/workflows"
  cp /source/.github/workflows/self-test.yaml "$1/.github/workflows/"
}

# why: cycle 30, review round 2. The traced commands are what the
# config-gen jobs run, so the job set comes from the workflow: every job
# whose `if:` reads classify's select_config_gen key. base#1547 split the
# one config-gen job into config-gen-gates and config-gen-redpath
# (d6dfdb08), and a reader keyed on the old name `config-gen` read no run
# block at all. The expected names are main's two jobs.
@test "config_gen_readers: the config-gen jobs are the jobs that gate on select_config_gen (base#1584)" {
  run bash "${READERS_SH}" --root /source --jobs
  assert_success
  assert_output "config-gen-gates
config-gen-redpath"
}

# why: cycle 30, review round 2. A workflow where no job gates on
# select_config_gen, or where a config-gen job has no `run:` step, gives
# the tracer nothing to run. That must fail the deny-list spec, never
# read as an empty reader set.
@test "config_gen_readers: no config-gen job, or one with no run step, is refused (base#1584)" {
  local _r="${BATS_TEST_TMPDIR}/r" _flag
  _wf_root "${_r}"
  yq -i 'del(.jobs."config-gen-gates") | del(.jobs."config-gen-redpath")' "${_r}/.github/workflows/self-test.yaml"
  for _flag in --jobs --run-blocks; do
    run bash "${READERS_SH}" --root "${_r}" "${_flag}"
    assert_failure
  done
  _wf_root "${_r}"
  yq -i '.jobs."config-gen-redpath".steps |= map(select(has("run") | not))' "${_r}/.github/workflows/self-test.yaml"
  run bash "${READERS_SH}" --root "${_r}" --run-blocks
  assert_failure
  assert_output --partial config-gen-redpath
}

# why: cycle 30, review round 2. Each run block runs as the job runs it,
# so a `${{ matrix.<key> }}` is expanded once per value of the job's
# matrix: config-gen-redpath runs `just test go-redpath <n>/5` for shards
# 1..5 (its matrix, which self_test_yaml_spec holds to the shard table),
# and together the five shards run every redpath case. Both jobs'
# just-pin blocks are there too.
@test "config_gen_readers: the run blocks are both config-gen jobs', each matrix value expanded (base#1584)" {
  local _n
  run bash "${READERS_SH}" --root /source --run-blocks
  assert_success
  assert_line 'just test go-gates'
  for _n in 1 2 3 4 5; do
    assert_line "just test go-redpath ${_n}/5"
  done
  [[ "$(grep -cF 'version="$(./dist/script/base/just-version.sh)"' <<<"${output}")" -eq 2 ]] \
    || fail "expected the just-pin block of both jobs"
  refute_output --partial '${{'
}

# why: cycle 30, review round 2. An expression other than one matrix key
# is a value this script would have to guess, so the block is refused
# rather than run with the expression left in or dropped.
@test "config_gen_readers: a run block with an expression it cannot evaluate is refused (base#1584)" {
  local _r="${BATS_TEST_TMPDIR}/r"
  _wf_root "${_r}"
  yq -i '(.jobs."config-gen-gates".steps[] | select(.run == "just test go-gates") | .run) = "just test go-gates ${{ github.sha }}"' \
    "${_r}/.github/workflows/self-test.yaml"
  grep -qF 'just test go-gates ${{ github.sha }}' "${_r}/.github/workflows/self-test.yaml"
  run bash "${READERS_SH}" --root "${_r}" --run-blocks
  assert_failure
  assert_output --partial 'github.sha'
}
