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
# setup() plants a valid baseline, one `a = 1` file in each input root
# (forms/a.toml, toml-test/valid/a.toml and the shared corpus's
# s1/a.toml), so every test starts from inputs the step accepts; a test
# that needs a root gone takes it away with _unplant (base#1851).
#
# The stub records each call's argv as ${S}/docker.<n>.argv. `docker
# image inspect` exits with ${S}/inspect.rc and `docker build` with
# ${S}/build.rc when those exist, 0 otherwise. For `docker run` it saves
# stdin as ${S}/in.tar and, for `--entrypoint python3`, the only shape the
# step runs, runs the python3 first on PATH (this container's real one,
# unless a test plants another in ${S}/bin) as `python3 -I -c <program>`,
# the argument after `-c`, on that tar, so the verdicts are tomllib's.
# Any other entrypoint fails with status 125. When ${S}/answers exists the
# stub prints that file instead, byte for byte. When ${S}/run.rc exists,
# `docker run` then exits with the status it holds.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  STEP_SRC=/source/script/test/config_gen_steps/10-toml-oracle.sh
  S="${BATS_TEST_TMPDIR}"
  R="${S}/root"
  M="${R}/dockerfile/config-gen"
  G="${M}/internal/gate/testdata"
  mkdir -p "${S}/bin" "${S}/ctx" "${R}/script/test" "${R}/dist/script/docker" \
           "${R}/dockerfile/config-gen"
  cp /source/.version "${R}/"
  cp -a /source/script/test/config_gen_steps "${R}/script/test/"
  cp -a /source/dist/script/docker/lib "${R}/dist/script/docker/"
  cp /source/dockerfile/Dockerfile.toml-bridge /source/dockerfile/toml_bridge.py "${R}/dockerfile/"
  STEP="${R}/script/test/config_gen_steps/10-toml-oracle.sh"
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
      ep='' script='' prev=''
      for a in "\$@"; do
        [[ "\${prev}" == --entrypoint ]] && ep="\${a}"
        [[ "\${prev}" == -c ]] && script="\${a}"
        prev="\${a}"
      done
      case "\${ep}" in
        python3) python3 -I -c "\${script}" < "${S}/in.tar" || rc=\$? ;;
        *) printf 'docker stub: no shape for --entrypoint %s\n' "\${ep}" >&2; rc=125 ;;
      esac
    fi
    [[ -f "${S}/run.rc" ]] && exit "\$(cat "${S}/run.rc")"
    exit "\${rc}"
    ;;
esac
exit 0
EOF
  chmod +x "${S}/bin/docker"
  : > "${S}/planted"
  _plant forms/a.toml toml-test/valid/a.toml
  _put 'a = 1' testdata/corpus/s1/a.toml
}

# _put <content> <module-rel> -- a file holding <content> at <module-rel>
# under dockerfile/config-gen, recorded in the ledger ${S}/planted as
# `<module-rel>\t<content>`. A path planted again replaces its entry, so
# the ledger describes the final tree.
_put() {
  mkdir -p "$(dirname -- "${M}/${2}")"
  printf '%s\n' "${1}" > "${M}/${2}"
  awk -F'\t' -v rel="${2}" '$1 != rel' "${S}/planted" > "${S}/planted.new"
  printf '%s\t%s\n' "${2}" "${1}" >> "${S}/planted.new"
  mv -- "${S}/planted.new" "${S}/planted"
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
# gate's testdata; _answer's verdict is read from that content.
_plant_as() {
  _put "${1}" "internal/gate/testdata/${2}"
}

# _unplant <module-rel> -- remove the file or directory at <module-rel>
# and drop the ledger's entries at or under it.
_unplant() {
  rm -rf -- "${M:?}/${1}"
  awk -F'\t' -v rel="${1}" '$1 != rel && index($1, rel "/") != 1' \
    "${S}/planted" > "${S}/planted.new"
  mv -- "${S}/planted.new" "${S}/planted"
}

# _answer -- the full valid answer for what the ledger says is planted:
# one `<module-rel>\t<verdict>\t<sha256>` row per file, in C order. The
# verdict comes from the planted content (`a = 1` is accept, `refuse` is
# refuse) and the digest is sha256sum's of the planted bytes. It reads the
# ledger, never the tree, so it does not recompute the step's own `find`.
# A malformed answer is _answer through one named edit.
_answer() {
  local _rel _content _verdict _d
  while IFS=$'\t' read -r _rel _content; do
    case "${_content}" in
      'a = 1') _verdict=accept ;;
      refuse) _verdict=refuse ;;
      *) fail "_answer: no verdict for the content planted at ${_rel}" ;;
    esac
    _d="$(sha256sum < "${M}/${_rel}")"
    printf '%s\t%s\t%s\n' "${_rel}" "${_verdict}" "${_d%% *}"
  done < <(LC_ALL=C sort -t$'\t' -k1,1 -- "${S}/planted")
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
# locale is. The expected list is written out, not re-derived; it holds
# setup()'s three baseline files too.
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
    internal/gate/testdata/forms/a.toml \
    internal/gate/testdata/forms/b.toml \
    internal/gate/testdata/forms/sub/a.toml \
    internal/gate/testdata/toml-test/invalid/datetime/y.toml \
    internal/gate/testdata/toml-test/valid/a.toml \
    internal/gate/testdata/toml-test/valid/x.toml \
    testdata/corpus/s1/a.toml \
    testdata/corpus/s1/seed.toml \
    testdata/corpus/s9/x.toml)"
  _got="$(tar -tf "${S}/in.tar" | sed -e 's|^\./||' -e '/\/$/d')"
  assert_equal "${_got}" "${_want}"
}

# why: The differential test reads verdicts.tsv as tomllib's answer, so
# what the container answered must reach the build as it was, neither
# re-sorted nor rewritten. Each row carries the SHA-256 of the bytes the
# oracle program read, which the differential test checks against the
# file (review round 2, base#1851). Here the real oracle program runs on
# this container's tomllib behind the docker stub, and two of the files,
# one under forms and one under toml-test, hold `refuse`, which tomllib
# refuses, so a step that writes `accept` for every file, or drops the
# refused rows, gives a different file. The expected TSV is _answer's,
# built from what was planted and sha256sum's digests of it, not from the
# step's output.
@test "10-toml-oracle.sh: verdicts.tsv is the container's mixed accept and refuse answer byte for byte (base#1851)" {
  _plant toml-test/valid/d.toml
  _plant_as refuse forms/b.toml
  _plant_as refuse toml-test/invalid/c.toml
  _oracle
  assert_success
  assert_output ''
  _answer > "${S}/want.tsv"
  cmp -- "${S}/want.tsv" "${S}/ctx/toml-oracle/verdicts.tsv" \
    || fail "verdicts.tsv: $(cat -A -- "${S}/ctx/toml-oracle/verdicts.tsv")"
}

# why: A verdict is tomllib's only when the real oracle program gave it,
# run as the container's `python3 -I -c` on the tar, never a stand-in.
# tomllib.loads takes text, and a TOML file is UTF-8, so the program must
# decode the file's bytes strictly: forms/ff.toml is `a = 1` with a 0xFF
# byte in its comment, and decoded with errors=replace it parses (checked
# here with this container's tomllib), so only strict decoding refuses it.
# Each row's digest must be of the bytes as planted, not of decoded text.
# The expected rows are written out: the verdicts by hand, the digests
# sha256sum's of the planted files (base#1851).
@test "10-toml-oracle.sh: through the real oracle program, a = 1 is accept, a 0xFF byte in a comment is refuse, and each digest is sha256sum's of the planted bytes (base#1851)" {
  _put $'a = 1 # \xff' internal/gate/testdata/forms/ff.toml
  run python3 -I -c 'import sys, tomllib
tomllib.loads(open(sys.argv[1], "rb").read().decode(errors="replace"))' \
    "${G}/forms/ff.toml"
  assert_success
  _oracle
  assert_success
  local _rel _v _d
  : > "${S}/want.tsv"
  while read -r _rel _v; do
    _d="$(sha256sum < "${M}/${_rel}")"
    printf '%s\t%s\t%s\n' "${_rel}" "${_v}" "${_d%% *}" >> "${S}/want.tsv"
  done <<'ROWS'
internal/gate/testdata/forms/a.toml accept
internal/gate/testdata/forms/ff.toml refuse
internal/gate/testdata/toml-test/valid/a.toml accept
testdata/corpus/s1/a.toml accept
ROWS
  cmp -- "${S}/want.tsv" "${S}/ctx/toml-oracle/verdicts.tsv" \
    || fail "verdicts.tsv: $(cat -A -- "${S}/ctx/toml-oracle/verdicts.tsv")"
}

# why: A verdict is tomllib's only when tomllib judged the file. A value
# nested past the interpreter's recursion limit -- forms/deep.toml is
# `a = ` and 100000 `[` -- makes tomllib raise RecursionError (checked
# here with this container's tomllib), not TOMLDecodeError: the parser
# ran out of stack and said nothing about whether the file is TOML. So
# that file must not become a `refuse` row. The oracle program must fail,
# and the step must refuse under the five-point refusal test: status 1,
# nothing on stdout, config_gen_toml_oracle_failed reason=image, and no
# toml-oracle/ directory (base#1851).
@test "10-toml-oracle.sh: a file tomllib cannot judge for RecursionError is config_gen_toml_oracle_failed reason=image, never a refuse verdict (base#1851)" {
  _put "a = $(head -c 100000 /dev/zero | tr '\0' '[')" \
    internal/gate/testdata/forms/deep.toml
  run python3 -I -c 'import sys, tomllib
try:
    tomllib.loads(open(sys.argv[1], encoding="utf-8").read())
except RecursionError:
    print("RecursionError")' "${G}/forms/deep.toml"
  assert_success
  assert_output RecursionError
  _oracle
  assert_refusal 1 config_gen_toml_oracle_failed reason=image
  [[ ! -e "${S}/ctx/toml-oracle" ]] \
    || fail "a refused oracle run left ${S}/ctx/toml-oracle behind"
}

# why: The verdicts are tomllib's only when they come from the pinned
# bridge image, the one named by the content-digest tag of dockerfile/
# Dockerfile.toml-bridge and the files it COPYs, never from a floating tag
# or from whatever TOML_BRIDGE_IMAGE names. The tag is a property of that
# content, so it is not taken from the derivation the step itself calls:
# the step runs three times, the second after toml_bridge.py (a file the
# Dockerfile COPYs) gains a comment line, the third after
# Dockerfile.toml-bridge alone gains one. Each run makes one `docker run`
# naming a `toml-bridge:<12 hex>` image, the three tags all differ, and
# TOML_BRIDGE_IMAGE=toml-bridge:floating reaches no run. A tag taken from
# toml_bridge.py alone would let a Python pin change in the Dockerfile
# reuse a warm runner's old image under the same tag (review rounds 1, 3
# and 4, base#1851).
@test "10-toml-oracle.sh: the container is the toml-bridge image tagged by the bridge sources' content, whatever TOML_BRIDGE_IMAGE says (base#1851)" {
  local -a _tags=()
  local _i _a _argv _tag
  for _i in 1 2 3; do
    rm -f -- "${S}"/docker.*.argv "${S}/docker.n"
    _oracle TOML_BRIDGE_IMAGE=toml-bridge:floating
    assert_success
    assert_equal "$(_run_calls)" 1
    _argv=''
    for _a in "${S}"/docker.*.argv; do
      [[ "$(head -n1 "${_a}")" == run ]] && _argv="${_a}"
    done
    run grep -cF -- 'toml-bridge:floating' "${_argv}"
    assert_output 0
    _tag="$(grep -E '^toml-bridge:' "${_argv}")" \
      || fail "run ${_i}: no toml-bridge:<tag> argument in the docker run argv"
    [[ "${_tag}" =~ ^toml-bridge:[0-9a-f]{12}$ ]] \
      || fail "run ${_i}: the docker run names ${_tag}, want toml-bridge:<12 hex>"
    _tags+=("${_tag}")
    case "${_i}" in
      1) printf '# base#1851: a bridge source edit\n' >> "${R}/dockerfile/toml_bridge.py" ;;
      2) printf '# base#1851: a bridge Dockerfile edit\n' >> "${R}/dockerfile/Dockerfile.toml-bridge" ;;
    esac
  done
  [[ "${_tags[0]}" != "${_tags[1]}" ]] \
    || fail "runs 1 and 2 name ${_tags[0]}; a toml_bridge.py edit must change the tag"
  [[ "${_tags[1]}" != "${_tags[2]}" ]] \
    || fail "runs 2 and 3 name ${_tags[1]}; a Dockerfile.toml-bridge edit must change the tag"
  [[ "${_tags[0]}" != "${_tags[2]}" ]] \
    || fail "runs 1 and 3 name ${_tags[0]}; the two edits must not cancel out"
}

# why: When the pinned image cannot answer -- the container exits non-zero
# -- whatever it printed is not tomllib's verdict on the input set. The
# step must refuse under the five-point refusal test: status 1, nothing on
# stdout, config_gen_toml_oracle_failed reason=image, and no toml-oracle/
# directory left for the build to read as an answer.
@test "10-toml-oracle.sh: a container that exits non-zero is config_gen_toml_oracle_failed reason=image, no toml-oracle/ left (base#1851)" {
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
  printf '1\n' > "${S}/inspect.rc"
  printf '1\n' > "${S}/build.rc"
  _oracle
  assert_refusal 1 config_gen_toml_oracle_failed reason=image
  assert_equal "$(_run_calls)" 0
  [[ ! -e "${S}/ctx/toml-oracle" ]] \
    || fail "a refused oracle run left ${S}/ctx/toml-oracle behind"
}

# why: A file's verdict is what the oracle program printed after tomllib
# answered. An interpreter killed while it runs -- here a python3 first on
# the stub's PATH that sends itself SIGKILL -- said nothing about the
# files, and its exit status must not be read as `refuse`. The container
# must fail, and the step must refuse under the five-point refusal test:
# status 1, nothing on stdout, config_gen_toml_oracle_failed reason=image,
# and no toml-oracle/ directory (review round 1, base#1851).
@test "10-toml-oracle.sh: an interpreter killed inside the container is config_gen_toml_oracle_failed reason=image, never a refuse verdict (base#1851)" {
  printf '#!%s\nkill -9 $$\n' "$(command -v bash)" > "${S}/bin/python3"
  chmod +x "${S}/bin/python3"
  _oracle
  assert_refusal 1 config_gen_toml_oracle_failed reason=image
  [[ ! -e "${S}/ctx/toml-oracle" ]] \
    || fail "a refused oracle run left ${S}/ctx/toml-oracle behind"
}

# why: The differential test compares a verdict for every file it was
# handed. An answer with fewer rows than the files in the tar -- here
# _answer with its first row dropped -- leaves a file with no tomllib
# verdict, and a short TSV must not reach the build as if it were
# complete. The step must refuse under the five-point refusal test:
# status 1, nothing on stdout, config_gen_toml_oracle_failed reason=count,
# and no toml-oracle/ directory left behind.
@test "10-toml-oracle.sh: an answer missing a row is config_gen_toml_oracle_failed reason=count, no toml-oracle/ left (base#1851)" {
  _plant forms/b.toml
  _plant_as refuse toml-test/invalid/c.toml
  _answer | sed '1d' > "${S}/answers"
  _oracle
  assert_refusal 1 config_gen_toml_oracle_failed reason=count
  [[ ! -e "${S}/ctx/toml-oracle" ]] \
    || fail "a refused oracle run left ${S}/ctx/toml-oracle behind"
}

# why: The differential test reads each row's second field as tomllib's
# verdict, and only `accept` and `refuse` are verdicts. An answer with the
# right number of rows whose second row says `maybe` is not something
# tomllib said about that file, and it must not reach the build. Nor may a
# row whose third field is not a SHA-256 -- 63 hex digits, a capital hex
# digit, nothing at all, or a fourth field after it: the differential
# test binds each verdict to the file by that digest (review round 2,
# base#1851). Each is _answer with that one edit to its second row, and
# each is refused under the five-point refusal test: status 1, nothing on
# stdout, config_gen_toml_oracle_failed reason=token, and no toml-oracle/
# directory left behind.
@test "10-toml-oracle.sh: an answer whose verdict is neither accept nor refuse, or whose digest is not a SHA-256, is config_gen_toml_oracle_failed reason=token, no toml-oracle/ left (base#1851)" {
  _plant forms/b.toml
  _plant_as refuse toml-test/invalid/c.toml
  local _edit
  for _edit in 's/\t(accept|refuse)\t/\tmaybe\t/' \
               's/\t[0-9a-f]([0-9a-f]{63})$/\t\1/' \
               's/\t[0-9a-f]([0-9a-f]{63})$/\t\1A/' \
               's/\t[0-9a-f]{64}$//' \
               's/$/\textra/'; do
    _answer | sed -E "2${_edit}" > "${S}/answers"
    _oracle
    assert_refusal 1 config_gen_toml_oracle_failed reason=token
    [[ ! -e "${S}/ctx/toml-oracle" ]] \
      || fail "a refused oracle run left ${S}/ctx/toml-oracle behind (${_edit})"
  done
}

# why: The verdicts file is tomllib's answer on the gate's whole input set
# only when the step found every root's files. A root that is not there
# (forms/, toml-test/ or the shared corpus removed), a root with no TOML
# file in it (the corpus's one s1/a.toml removed), or a `find` that fails
# after printing one real path, leaves a shorter list whose row count the
# answer would still match, and the step would publish a partial oracle
# (review round 2, base#1851). Each is one defect on setup()'s baseline,
# and each must be refused before the container is asked, under the
# five-point refusal test: status 1, nothing on stdout,
# config_gen_toml_oracle_failed reason=inputs, no `docker run`, and no
# toml-oracle/ directory.
@test "10-toml-oracle.sh: a missing or empty input root, or a failed find, is config_gen_toml_oracle_failed reason=inputs before any docker run, no toml-oracle/ left (base#1851)" {
  local _case
  for _case in forms toml-test corpus corpus-empty find; do
    rm -f -- "${S}"/docker.* "${S}/bin/find"
    _plant forms/a.toml toml-test/valid/a.toml
    _put 'a = 1' testdata/corpus/s1/a.toml
    case "${_case}" in
      forms) _unplant internal/gate/testdata/forms ;;
      toml-test) _unplant internal/gate/testdata/toml-test ;;
      corpus) _unplant testdata/corpus ;;
      corpus-empty) _unplant testdata/corpus/s1/a.toml ;;
      find) printf '#!%s\nprintf "%%s\\n" internal/gate/testdata/forms/a.toml\nexit 1\n' \
              "$(command -v bash)" > "${S}/bin/find"
            chmod +x "${S}/bin/find" ;;
    esac
    _oracle
    assert_refusal 1 config_gen_toml_oracle_failed reason=inputs
    assert_equal "${_case}:$(_run_calls)" "${_case}:0"
    [[ ! -e "${S}/ctx/toml-oracle" ]] \
      || fail "${_case}: a refused oracle run left ${S}/ctx/toml-oracle behind"
  done
}

# why: Each verdict row is `<rel>\t<verdict>\t<sha256>`, and the
# differential test keys it by path, so a path has to survive the tar,
# the container's shell loop and the TSV unchanged. A name outside [A-Za-z0-9._/-] -- here
# a space in forms/a b.toml -- is not one the step can promise that for,
# and the vendored and hand-written inputs never need one. The step must
# refuse it before asking the container, under the five-point refusal
# test: status 1, nothing on stdout, config_gen_toml_oracle_failed
# reason=name naming the file, no `docker run`, and no toml-oracle/
# directory left.
@test "10-toml-oracle.sh: a file name outside [A-Za-z0-9._/-] is config_gen_toml_oracle_failed reason=name before any docker run, no toml-oracle/ left (base#1851)" {
  _plant 'forms/a b.toml'
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
# from GitHub on 2026-11-20 (review round 1, base#1851). Every other
# vendored byte is pinned too: a case edited so that its verdict holds
# (valid/newline-crlf.toml rewritten with LF endings, say) keeps the
# manifest and the differential green and loses the upstream case. The
# whole-tree digest below is the SHA-256 of `sha256sum` run on every
# vendored file but SOURCE, in C order, and it was computed from
# toml-lang/toml-test's tarball at ce08da1 (codeload.github.com, fetched
# 2026-11-20), laid out as vendored here, not from this checkout (review
# round 1, base#1851). The suite is a third-party version this repo names,
# so the upstream-release watch must read it: the pin registry
# (script/watch/pins.sh) must give v2.2.0 for a `toml-test` pin, which a
# `tool-pin:` marker in SOURCE declares (base#1395 slice rules, review
# round 1, base#1851).
@test "toml-test vendoring: the *.toml files are exactly the 746 in files-toml-1.0.0 and files-toml-1.1.0, every vendored file is upstream's bytes, and SOURCE names v2.2.0 and the 40-hex commit and declares the toml-test pin (base#1851)" {
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
  local _tree
  _tree="$(cd -- "${_v}" && find . -type f ! -name SOURCE | sed 's|^\./||' \
    | LC_ALL=C sort | while read -r _f; do sha256sum -- "${_f}"; done)"
  assert_equal "$(printf '%s\n' "${_tree}" | sha256sum | cut -d' ' -f1)" \
    a96f3073e9eaa9fb027c664769e6ecbd38aa8903eff7d88c2cf806b28f025d5f
  run grep -cwF 'v2.2.0' "${_v}/SOURCE"
  assert_output 1
  run grep -cE '(^|[^0-9a-f])ce08da1[0-9a-f]{33}([^0-9a-f]|$)' "${_v}/SOURCE"
  assert_output 1
  run --separate-stderr /source/script/watch/pins.sh --value toml-test
  assert_success
  assert_output v2.2.0
}
