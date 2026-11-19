#!/usr/bin/env bats
#
# config_gen_toml10_spec.bats -- the config-gen step that asks the pinned
# tomllib for its verdict on every TOML file the gate is held to
# (base#1851).
#
# why: internal/gate's differential test compares gate + BurntSushi with
# tomllib file by file. tomllib's verdicts are not committed; the step
# script/test/config_gen_steps/10-toml-oracle.sh takes them live from the
# pinned toml-bridge image on every `just test go`, and hands them to the
# build as the `toml-oracle` context. These cases test the step's plumbing.
# docker is stubbed here (there is no socket in the test-tools container);
# `just test go` runs the real image.
#
# The stub records each call's argv as ${S}/docker.<n>.argv. `docker
# image inspect` exits with ${S}/inspect.rc and `docker build` with
# ${S}/build.rc when those exist, 0 otherwise. For `docker run` it saves
# stdin as ${S}/in.tar and then runs the step's own container script (the
# argument after `-c`) on that tar with a stand-in python3 first on PATH,
# so the container's loops are the step's, not the stub's. The stand-in
# answers by a planted file's content: `refuse` is refused by the oracle
# program and by the bridge, `bridge-refuse` only by the bridge, `die`
# kills the oracle program's interpreter and `bridge-die` the bridge's;
# anything else is accepted. When ${S}/answers exists the stub prints that
# file instead, byte for byte. When ${S}/run.rc exists, `docker run` then
# exits with the status it holds.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  STEP_SRC=/source/script/test/config_gen_steps/10-toml-oracle.sh
  S="${BATS_TEST_TMPDIR}"
  R="${S}/root"
  G="${R}/dockerfile/config-gen/internal/gate/testdata"
  mkdir -p "${S}/bin" "${S}/ctx" "${R}/script/test" "${R}/dist/script/docker" \
           "${R}/dockerfile/config-gen"
  cp /source/.version "${R}/"
  cp -a /source/script/test/config_gen_steps "${R}/script/test/"
  cp -a /source/dist/script/docker/lib "${R}/dist/script/docker/"
  cp /source/dockerfile/Dockerfile.toml-bridge /source/dockerfile/toml_bridge.py "${R}/dockerfile/"
  STEP="${R}/script/test/config_gen_steps/10-toml-oracle.sh"
  mkdir -p "${S}/py"
  cat > "${S}/py/python3" <<EOF
#!$(command -v bash)
# python3 -I -c <oracle program> | python3 -I <bridge> --tables
c="\$(cat)"
if [[ "\${2:-}" == -c ]]; then
  case "\${c}" in
    die) kill -9 \$\$ ;;
    refuse) printf 'refuse\n' ;;
    *) printf 'accept\n' ;;
  esac
  exit 0
fi
case "\${c}" in
  bridge-die) kill -9 \$\$ ;;
  refuse | bridge-refuse) exit 1 ;;
esac
exit 0
EOF
  chmod +x "${S}/py/python3"
  cat > "${S}/bin/docker" <<EOF
#!$(command -v bash)
n=\$(( \$(cat "${S}/docker.n" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "\${n}" > "${S}/docker.n"
printf '%s\n' "\$@" > "${S}/docker.\${n}.argv"
case "\${1:-}" in
  image)
    [[ -f "${S}/inspect.rc" ]] && exit "\$(cat "${S}/inspect.rc")"
    ;;
  build)
    [[ -f "${S}/build.rc" ]] && exit "\$(cat "${S}/build.rc")"
    ;;
  run)
    cat > "${S}/in.tar"
    rc=0
    if [[ -f "${S}/answers" ]]; then
      cat "${S}/answers"
    else
      script='' prev=''
      for a in "\$@"; do
        [[ "\${prev}" == -c ]] && script="\${a}"
        prev="\${a}"
      done
      PATH="${S}/py:\${PATH}" sh -c "\${script}" < "${S}/in.tar" || rc=\$?
    fi
    [[ -f "${S}/run.rc" ]] && exit "\$(cat "${S}/run.rc")"
    exit "\${rc}"
    ;;
esac
exit 0
EOF
  chmod +x "${S}/bin/docker"
}

# _plant <rel>... -- a TOML file `a = 1` at each <rel> under the gate's
# testdata.
_plant() {
  local _f
  for _f in "$@"; do
    _plant_as 'a = 1' "${_f}"
  done
}

# _plant_as <content> <rel> -- a file holding <content> at <rel> under the
# gate's testdata; the stand-in python3 answers by that content.
_plant_as() {
  mkdir -p "$(dirname -- "${G}/${2}")"
  printf '%s\n' "${1}" > "${G}/${2}"
}

# _oracle [<VAR=value>...] -- the step on the scratch root, docker
# stubbed, JSON logs, with each <VAR=value> added to its environment.
_oracle() {
  run --separate-stderr env PATH="${S}/bin:${PATH}" LOG_FORMAT=json \
      CONFIG_GEN_CTX="${S}/ctx" "$@" bash "${STEP}"
}

# _run_calls -- how many docker calls were `docker run`.
_run_calls() {
  local _a _n=0
  for _a in "${S}"/docker.*.argv; do
    [[ -f "${_a}" ]] || continue
    [[ "$(head -n1 "${_a}")" == run ]] && _n=$(( _n + 1 ))
  done
  printf '%s\n' "${_n}"
}

# why: The differential test can only compare the files tomllib saw. The
# step must hand the container every forms file, every vendored toml-test
# file, at any depth, and every shared corpus file the module's
# testdata/corpus/s*/ holds (the files testcorpus.Glob reads), and nothing
# else -- a LICENSE, SOURCE or golden file is not TOML, and a TOML file
# outside corpus/s*/ is not corpus. The order is the C locale's, so an
# upper-case name sorts before a lower-case one whatever the caller's
# locale is. The expected list is written out, not re-derived.
@test "10-toml-oracle.sh: the container receives exactly the forms, toml-test and shared corpus TOML files, in C-locale order (base#1851)" {
  assert_spec_subject "${STEP_SRC}" "the tomllib oracle step (base#1851)"
  _plant forms/b.toml forms/Z.toml forms/sub/a.toml \
         toml-test/valid/x.toml toml-test/invalid/datetime/y.toml
  printf 'MIT\n' > "${G}/toml-test/LICENSE"
  printf 'tag v2.2.0\n' > "${G}/toml-test/SOURCE"
  printf 'not toml\n' > "${G}/forms/notes.txt"
  local _c="${R}/dockerfile/config-gen/testdata"
  mkdir -p "${_c}/corpus/s1" "${_c}/corpus/s9" "${_c}/golden/s1" "${_c}/other"
  printf 'a = 1\n' > "${_c}/corpus/s1/seed.toml"
  printf 'a = 1\n' > "${_c}/corpus/s9/x.toml"
  printf 'a = 1\n' > "${_c}/golden/s1/seed.golden"
  printf 'a = 1\n' > "${_c}/other/stray.toml"
  _oracle
  assert_success
  assert_equal "$(_run_calls)" 1
  local _want _got
  _want="$(printf '%s\n' \
    internal/gate/testdata/forms/Z.toml \
    internal/gate/testdata/forms/b.toml \
    internal/gate/testdata/forms/sub/a.toml \
    internal/gate/testdata/toml-test/invalid/datetime/y.toml \
    internal/gate/testdata/toml-test/valid/x.toml \
    testdata/corpus/s1/seed.toml \
    testdata/corpus/s9/x.toml)"
  _got="$(tar -tf "${S}/in.tar" | sed -e 's|^\./||' -e '/\/$/d')"
  assert_equal "${_got}" "${_want}"
}

# why: The differential test reads verdicts.tsv as tomllib's answer, so
# what the container answered must reach the build as it was, neither
# re-sorted nor rewritten, and its calibration lines left out. Here the
# container's own loop runs with a stand-in interpreter that refuses two
# of the four files, one under forms and one under toml-test, so a step
# that writes `accept` for every file, or drops the refused rows, gives a
# different file. The expected TSV is written out (review round 1,
# base#1851).
@test "10-toml-oracle.sh: verdicts.tsv is the container's mixed accept and refuse answer byte for byte, calibration lines left out (base#1851)" {
  _plant forms/a.toml toml-test/valid/d.toml
  _plant_as refuse forms/b.toml
  _plant_as refuse toml-test/invalid/c.toml
  _oracle
  assert_success
  assert_output ''
  printf '%s\t%s\n' \
    internal/gate/testdata/forms/a.toml accept \
    internal/gate/testdata/forms/b.toml refuse \
    internal/gate/testdata/toml-test/invalid/c.toml refuse \
    internal/gate/testdata/toml-test/valid/d.toml accept \
    > "${S}/want.tsv"
  cmp -- "${S}/want.tsv" "${S}/ctx/toml-oracle/verdicts.tsv" \
    || fail "verdicts.tsv: $(cat -A -- "${S}/ctx/toml-oracle/verdicts.tsv")"
}

# why: The verdicts are tomllib's only when they come from the pinned
# bridge image, the one named by the content-digest tag of dockerfile/
# Dockerfile.toml-bridge and the files it COPYs, never from a floating tag
# or from whatever TOML_BRIDGE_IMAGE names. So the one `docker run` must
# name the image tool_image_derive gives for this checkout, a
# `toml-bridge:<12 hex>` tag, and a TOML_BRIDGE_IMAGE in the environment
# must not reach the run (review round 1, base#1851).
@test "10-toml-oracle.sh: the container is the pinned toml-bridge image tool_image_derive names, whatever TOML_BRIDGE_IMAGE says (base#1851)" {
  _plant forms/a.toml
  local _want
  _want="$(source "${R}/dist/script/docker/lib/toml_bridge.sh" && tool_image_derive toml_bridge)"
  [[ "${_want}" =~ ^toml-bridge:[0-9a-f]{12}$ ]] \
    || fail "tool_image_derive toml_bridge = ${_want}, want toml-bridge:<12 hex>"
  _oracle TOML_BRIDGE_IMAGE=toml-bridge:floating
  assert_success
  assert_equal "$(_run_calls)" 1
  local _a _argv=''
  for _a in "${S}"/docker.*.argv; do
    [[ "$(head -n1 "${_a}")" == run ]] && _argv="${_a}"
  done
  run grep -cFx -- "${_want}" "${_argv}"
  assert_output 1
  run grep -cF -- 'toml-bridge:floating' "${_argv}"
  assert_output 0
}

# why: When the pinned image cannot answer -- the container exits non-zero
# -- whatever it printed is not tomllib's verdict on the input set. The
# step must refuse under the five-point refusal test: status 1, nothing on
# stdout, config_gen_toml_oracle_failed reason=image, and no toml-oracle/
# directory left for the build to read as an answer.
@test "10-toml-oracle.sh: a container that exits non-zero is config_gen_toml_oracle_failed reason=image, no toml-oracle/ left (base#1851)" {
  _plant forms/a.toml
  printf '1\n' > "${S}/run.rc"
  _oracle
  assert_refusal 1 config_gen_toml_oracle_failed reason=image
  [[ ! -e "${S}/ctx/toml-oracle" ]] \
    || fail "a refused oracle run left ${S}/ctx/toml-oracle behind"
}

# why: When the pinned image is absent and cannot be built, there is no
# tomllib to ask, and the step must say so as its own refusal, not leave
# the build helper's event as the last word. The stub's `docker image
# inspect` and `docker build` both fail. The step must refuse under the
# five-point refusal test: status 1, nothing on stdout,
# config_gen_toml_oracle_failed reason=image, no `docker run`, and no
# toml-oracle/ directory (review round 1, base#1851).
@test "10-toml-oracle.sh: an image that cannot be provisioned is config_gen_toml_oracle_failed reason=image, no docker run, no toml-oracle/ left (base#1851)" {
  _plant forms/a.toml
  printf '1\n' > "${S}/inspect.rc"
  printf '1\n' > "${S}/build.rc"
  _oracle
  assert_refusal 1 config_gen_toml_oracle_failed reason=image
  assert_equal "$(_run_calls)" 0
  [[ ! -e "${S}/ctx/toml-oracle" ]] \
    || fail "a refused oracle run left ${S}/ctx/toml-oracle behind"
}

# why: Inside the container, a file's verdict is what the interpreter
# printed after tomllib answered. An interpreter killed on a file -- here
# the oracle program's on forms/b.toml, then, in a second run, the real
# bridge's on the calibration pass -- said nothing about that file, and
# its exit status must not be read as `refuse`. The container must fail,
# and the step must refuse under the five-point refusal test: status 1,
# nothing on stdout, config_gen_toml_oracle_failed reason=image, and no
# toml-oracle/ directory (review round 1, base#1851).
@test "10-toml-oracle.sh: an interpreter killed inside the container is config_gen_toml_oracle_failed reason=image, never a refuse verdict (base#1851)" {
  _plant forms/a.toml
  _plant_as die forms/b.toml
  _oracle
  assert_refusal 1 config_gen_toml_oracle_failed reason=image
  [[ ! -e "${S}/ctx/toml-oracle" ]] \
    || fail "a refused oracle run left ${S}/ctx/toml-oracle behind"
  _plant_as bridge-die forms/b.toml
  _oracle
  assert_refusal 1 config_gen_toml_oracle_failed reason=image
  [[ ! -e "${S}/ctx/toml-oracle" ]] \
    || fail "a refused oracle run left ${S}/ctx/toml-oracle behind"
}

# why: The differential test compares a verdict for every file it was
# handed. An answer with fewer rows than the files in the tar -- here
# three files planted and the container answers for two -- leaves a file
# with no tomllib verdict, and a short TSV must not reach the build as if
# it were complete. The step must refuse under the five-point refusal
# test: status 1, nothing on stdout, config_gen_toml_oracle_failed
# reason=count, and no toml-oracle/ directory left behind.
@test "10-toml-oracle.sh: an answer missing a row is config_gen_toml_oracle_failed reason=count, no toml-oracle/ left (base#1851)" {
  _plant forms/a.toml forms/b.toml toml-test/invalid/c.toml
  printf '%s\t%s\n' \
    internal/gate/testdata/forms/a.toml accept \
    internal/gate/testdata/toml-test/invalid/c.toml refuse \
    > "${S}/answers"
  _oracle
  assert_refusal 1 config_gen_toml_oracle_failed reason=count
  [[ ! -e "${S}/ctx/toml-oracle" ]] \
    || fail "a refused oracle run left ${S}/ctx/toml-oracle behind"
}

# why: The differential test reads each row's second field as tomllib's
# verdict, and only `accept` and `refuse` are verdicts. An answer with the
# right number of rows whose middle row says `maybe` is not something
# tomllib said about that file, and it must not reach the build. The step
# must refuse under the five-point refusal test: status 1, nothing on
# stdout, config_gen_toml_oracle_failed reason=token, and no toml-oracle/
# directory left behind.
@test "10-toml-oracle.sh: an answer whose verdict is neither accept nor refuse is config_gen_toml_oracle_failed reason=token, no toml-oracle/ left (base#1851)" {
  _plant forms/a.toml forms/b.toml toml-test/invalid/c.toml
  printf '%s\t%s\n' \
    internal/gate/testdata/forms/a.toml accept \
    internal/gate/testdata/forms/b.toml maybe \
    internal/gate/testdata/toml-test/invalid/c.toml refuse \
    > "${S}/answers"
  _oracle
  assert_refusal 1 config_gen_toml_oracle_failed reason=token
  [[ ! -e "${S}/ctx/toml-oracle" ]] \
    || fail "a refused oracle run left ${S}/ctx/toml-oracle behind"
}

# why: The oracle program in the step stands in for the real toml-bridge,
# and the two give the same verdict only while they sit at the same
# Python call depth -- tomllib's depth refusals depend on it. So for every
# file under forms/ the container also asks the image's real
# `toml-bridge --tables` and answers it on a line of its own,
# `calibration\t<rel>\t<verdict>`, after the verdict rows. Here the
# stand-in oracle program accepts forms/x.toml while the bridge refuses
# it: the oracle no longer stands for the bridge, so none of its verdicts
# can be trusted. The step must refuse under the five-point refusal test:
# status 1, nothing on stdout, config_gen_toml_oracle_failed
# reason=calibration naming the file, and no toml-oracle/ directory left.
@test "10-toml-oracle.sh: a calibration answer that differs from the oracle's verdict is config_gen_toml_oracle_failed reason=calibration, no toml-oracle/ left (base#1851)" {
  _plant forms/a.toml toml-test/valid/b.toml
  _plant_as bridge-refuse forms/x.toml
  _oracle
  assert_refusal 1 config_gen_toml_oracle_failed reason=calibration \
    file=internal/gate/testdata/forms/x.toml
  [[ ! -e "${S}/ctx/toml-oracle" ]] \
    || fail "a refused oracle run left ${S}/ctx/toml-oracle behind"
}

# why: Calibration holds only if it ran. An answer with every verdict row
# but no calibration line for a forms file -- here the container answered
# none -- has compared nothing, and must not pass as calibrated. Nor may a
# run with no forms file at all, where there is nothing to calibrate
# with. Each is refused under the five-point refusal test: status 1,
# nothing on stdout, config_gen_toml_oracle_failed reason=calibration,
# and no toml-oracle/ directory left (review round 1, base#1851).
@test "10-toml-oracle.sh: an answer that calibrates fewer than every forms file, or none, is config_gen_toml_oracle_failed reason=calibration (base#1851)" {
  _plant forms/a.toml forms/b.toml
  printf '%s\t%s\n' \
    internal/gate/testdata/forms/a.toml accept \
    internal/gate/testdata/forms/b.toml accept \
    > "${S}/answers"
  printf 'calibration\t%s\t%s\n' \
    internal/gate/testdata/forms/a.toml accept \
    >> "${S}/answers"
  _oracle
  assert_refusal 1 config_gen_toml_oracle_failed reason=calibration
  [[ ! -e "${S}/ctx/toml-oracle" ]] \
    || fail "a refused oracle run left ${S}/ctx/toml-oracle behind"
  rm -rf -- "${G}/forms" "${S}/answers"
  _plant toml-test/valid/c.toml
  _oracle
  assert_refusal 1 config_gen_toml_oracle_failed reason=calibration
  [[ ! -e "${S}/ctx/toml-oracle" ]] \
    || fail "a refused oracle run left ${S}/ctx/toml-oracle behind"
}

# why: Each verdict row is `<rel>\t<verdict>`, and the differential test
# keys it by path, so a path has to survive the tar, the container's
# shell loop and the TSV unchanged. A name outside [A-Za-z0-9._/-] -- here
# a space in forms/a b.toml -- is not one the step can promise that for,
# and the vendored and hand-written inputs never need one. The step must
# refuse it before asking the container, under the five-point refusal
# test: status 1, nothing on stdout, config_gen_toml_oracle_failed
# reason=name naming the file, no `docker run`, and no toml-oracle/
# directory left.
@test "10-toml-oracle.sh: a file name outside [A-Za-z0-9._/-] is config_gen_toml_oracle_failed reason=name before any docker run, no toml-oracle/ left (base#1851)" {
  _plant forms/a.toml 'forms/a b.toml'
  _oracle
  assert_refusal 1 config_gen_toml_oracle_failed reason=name \
    'file=internal/gate/testdata/forms/a b.toml'
  assert_equal "$(_run_calls)" 0
  [[ ! -e "${S}/ctx/toml-oracle" ]] \
    || fail "a refused oracle run left ${S}/ctx/toml-oracle behind"
}

# why: The differential test holds the gate to every toml-test case only
# if the vendored copy has every case. toml-test lists its cases in
# tests/files-toml-1.0.0 and tests/files-toml-1.1.0, vendored next to
# them; the *.toml files on disk must be exactly the union of the .toml
# lines in those two lists -- 746 paths at v2.2.0, a figure written out
# here from counting upstream's lists, not re-derived -- with none
# missing and none added by hand. SOURCE must name the tag and the full
# 40-hex commit, so the copy can be re-fetched and compared byte for byte.
# The MIT LICENSE the copy is redistributed under must be vendored too,
# and it and the two lists are upstream's bytes at that commit: their
# SHA-256 digests below are of toml-lang/toml-test's LICENSE,
# tests/files-toml-1.0.0 and tests/files-toml-1.1.0 at ce08da1, fetched
# from GitHub on 2026-11-20 (review round 1, base#1851).
@test "toml-test vendoring: the *.toml files are exactly the 746 in files-toml-1.0.0 and files-toml-1.1.0, LICENSE and both lists are upstream's bytes, and SOURCE names v2.2.0 and the 40-hex commit (base#1851)" {
  local _v=/source/dockerfile/config-gen/internal/gate/testdata/toml-test
  local _f _sum
  while read -r _sum _f; do
    [[ -f "${_v}/${_f}" ]] || fail "${_v}/${_f} is not vendored"
    assert_equal "$(sha256sum < "${_v}/${_f}" | cut -d' ' -f1)" "${_sum}"
  done <<'SUMS'
01ef58ee6449fa01a284c10808e27800d66bfea271bc29281125ff8e5642b86f LICENSE
32e4d8d36023dfe3b115dd95f847c5c989ac58ad7d4f1dbec51c4fc3006d483c files-toml-1.0.0
34561723ac15d445797bb54bd1ea67b360880fc326162772a59a051425b5629f files-toml-1.1.0
SUMS
  local _want _got
  _want="$(cat -- "${_v}/files-toml-1.0.0" "${_v}/files-toml-1.1.0" \
    | grep '\.toml$' | LC_ALL=C sort -u)"
  assert_equal "$(printf '%s\n' "${_want}" | wc -l)" 746
  _got="$(cd -- "${_v}" && find . -type f -name '*.toml' | sed 's|^\./||' | LC_ALL=C sort)"
  assert_equal "${_got}" "${_want}"
  run grep -cwF 'v2.2.0' "${_v}/SOURCE"
  assert_output 1
  run grep -cE '(^|[^0-9a-f])ce08da1[0-9a-f]{33}([^0-9a-f]|$)' "${_v}/SOURCE"
  assert_output 1
}
