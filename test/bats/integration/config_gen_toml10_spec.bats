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
# The stub records each call's argv as ${S}/docker.<n>.argv. For `docker
# run` it saves stdin as ${S}/in.tar and answers `<rel>\taccept` for every
# regular file in that tar, so a step that hands over the right files sees
# one verdict per file. When ${S}/answers exists the stub prints that file
# instead, byte for byte. When ${S}/run.rc exists, `docker run` then exits
# with the status it holds.

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
  cat > "${S}/bin/docker" <<EOF
#!$(command -v bash)
n=\$(( \$(cat "${S}/docker.n" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "\${n}" > "${S}/docker.n"
printf '%s\n' "\$@" > "${S}/docker.\${n}.argv"
case "\${1:-}" in
  run)
    cat > "${S}/in.tar"
    if [[ -f "${S}/answers" ]]; then
      cat "${S}/answers"
    else
      tar -tf "${S}/in.tar" | sed -e 's|^\./||' -e '/\/\$/d' -e 's|\$|\taccept|'
    fi
    [[ -f "${S}/run.rc" ]] && exit "\$(cat "${S}/run.rc")"
    ;;
esac
exit 0
EOF
  chmod +x "${S}/bin/docker"
}

# _plant <rel>... -- an empty TOML file at each <rel> under the gate's testdata.
_plant() {
  local _f
  for _f in "$@"; do
    mkdir -p "$(dirname -- "${G}/${_f}")"
    printf 'a = 1\n' > "${G}/${_f}"
  done
}

# _oracle -- the step on the scratch root, docker stubbed, JSON logs.
_oracle() {
  run --separate-stderr env PATH="${S}/bin:${PATH}" LOG_FORMAT=json \
      CONFIG_GEN_CTX="${S}/ctx" bash "${STEP}"
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
