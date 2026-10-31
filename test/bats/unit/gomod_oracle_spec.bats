#!/usr/bin/env bats
#
# gomod_oracle_spec.bats -- the config-gen step that holds the go.mod scanner
# to Go itself (base#1463).
#
# why: _pin_go_mod_scan (script/watch/lib.sh) is a bash port of Go's modfile
# lexer. A port drifts silently, so script/test/config_gen_steps/
# 20-gomod-oracle.sh runs `go mod edit -json` in the pinned golang image over
# every test/fixtures/gomod/*.mod and compares Go's verdict with the
# scanner's and with the class the fixture's first line declares:
#
#   // class: supported                      Go rc 0, scanner rc 0, and both
#                                            yield <name>.requires;
#   // class: policy-refused <event> <reason> Go rc 0, scanner refuses with
#                                            exactly that event and reason;
#   // class: go-invalid [<event> <reason>]  Go rc != 0, scanner refuses.
#
# A missing header (or a `# class:` one) is go_mod_fixture_unclassified; a
# disagreement is go_mod_oracle_mismatch (file= class=); a Dockerfile with
# no golang pin is go_mod_oracle_pin_missing, before docker runs.
#
# The step reads its repo root from its own location, as every config-gen
# step does when the redpath runs it on a scratch copy. docker is stubbed
# here; `just test go` runs the real image. The stub's `docker run` prints
# ${S}/run.out and exits ${S}/run.rc. run.out is the container's answer in
# the step's protocol: per fixture, one line
#
#   fixture<TAB><name>.mod<TAB><go-rc>
#
# followed by one `require<TAB><path><TAB><version><TAB><indirect>` line per
# requirement Go read (the gomod-oracle helper's output for that file).

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  STEP_SRC=/source/script/test/config_gen_steps/20-gomod-oracle.sh
  S="${BATS_TEST_TMPDIR}"
  R="${S}/root"
  mkdir -p "${S}/bin" "${S}/ctx" "${R}/script/test" "${R}/dist/script/docker" \
           "${R}/dockerfile" "${R}/test/fixtures/gomod"
  cp -a /source/script/test/config_gen_steps "${R}/script/test/"
  cp -a /source/script/watch "${R}/script/"
  cp -a /source/dist/script/docker/lib "${R}/dist/script/docker/"
  cp /source/dockerfile/Dockerfile.config-gen "${R}/dockerfile/"
  STEP="${R}/script/test/config_gen_steps/20-gomod-oracle.sh"
  GO_IMAGE_WANT="$(awk '/^# tool-pin: golang /{getline; sub(/^ARG GO_IMAGE=/, ""); print; exit}' \
    /source/dockerfile/Dockerfile.config-gen)"
  : > "${S}/run.out"
  printf '0\n' > "${S}/run.rc"
  cat > "${S}/bin/docker" <<EOF
#!$(command -v bash)
n=\$(( \$(cat "${S}/docker.n" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "\${n}" > "${S}/docker.n"
printf '%s\n' "\$@" > "${S}/docker.\${n}.argv"
case "\${1:-}" in
  run) cat "${S}/run.out"; exit "\$(cat "${S}/run.rc")" ;;
esac
exit 0
EOF
  chmod +x "${S}/bin/docker"
}

# _fixture <name> <line>... -- test/fixtures/gomod/<name>.mod in the root.
_fixture() {
  local _n="${1}"; shift
  printf '%s\n' "$@" > "${R}/test/fixtures/gomod/${_n}.mod"
}

# _requires <name> <path>\t<version>... -- <name>.requires in the root.
_requires() {
  local _n="${1}"; shift
  printf '%s\n' "$@" > "${R}/test/fixtures/gomod/${_n}.requires"
}

# _go <name> <rc> [<path> <version>]... -- append Go's answer for <name>.mod.
_go() {
  local _n="${1}" _rc="${2}"; shift 2
  printf 'fixture\t%s.mod\t%s\n' "${_n}" "${_rc}" >> "${S}/run.out"
  while (( $# >= 2 )); do
    printf 'require\t%s\t%s\tfalse\n' "${1}" "${2}" >> "${S}/run.out"
    shift 2
  done
}

# _oracle -- the step on the scratch root, docker stubbed, JSON logs.
_oracle() {
  run --separate-stderr env PATH="${S}/bin:${PATH}" LOG_FORMAT=json \
      CONFIG_GEN_CTX="${S}/ctx" bash "${STEP}"
}

# _docker_calls -- how many times the docker stub ran.
_docker_calls() {
  cat "${S}/docker.n" 2>/dev/null || echo 0
}

# _green_set -- one fixture of each class, all agreeing with Go.
_green_set() {
  _fixture ok '// class: supported' 'module example.com/m' 'require a v1.0.0'
  _requires ok $'a\tv1.0.0'
  _fixture rep '// class: policy-refused go_mod_unsupported_syntax replace' \
    'module example.com/m' 'require a v1.0.0' 'replace a => ./a'
  _fixture bad '// class: go-invalid go_mod_unsupported_syntax exclude' \
    'module example.com/m' 'require a v1.0.0' 'exclude a'
  _go bad 1
  _go ok 0 a v1.0.0
  _go rep 0 a v1.0.0
}

# why: The agreeing case: one docker run, offline, in the pinned image, with
# Go's toolchain switching off, and a green step.
@test "20-gomod-oracle.sh: fixtures that agree with Go pass, in one offline run of the pinned golang image (base#1463)" {
  assert_spec_subject "${STEP_SRC}" "the go.mod oracle step (base#1463)"
  [[ -n "${GO_IMAGE_WANT}" ]] || fail "no ARG GO_IMAGE under '# tool-pin: golang' in Dockerfile.config-gen"
  _green_set
  _oracle
  assert_success
  assert_equal "$(_docker_calls)" 1
  local _argv="${S}/docker.1.argv"
  assert_equal "$(head -n1 "${_argv}")" run
  grep -qxF -- "${GO_IMAGE_WANT}" "${_argv}" \
    || fail "docker run did not use the pinned image ${GO_IMAGE_WANT}: $(tr '\n' ' ' < "${_argv}")"
  awk 'p == "--network" && $0 == "none" {f=1} $0 == "--network=none" {f=1} {p=$0} END {exit !f}' "${_argv}" \
    || fail "docker run is not --network none: $(tr '\n' ' ' < "${_argv}")"
  grep -qx 'GOTOOLCHAIN=local' "${_argv}" \
    || fail "docker run does not set GOTOOLCHAIN=local: $(tr '\n' ' ' < "${_argv}")"
}

# why: A fixture with no class header carries no verdict to hold either side
# to, and a loop that skipped it would shrink the oracle silently.
@test "20-gomod-oracle.sh: a fixture with no class header is go_mod_fixture_unclassified (base#1463)" {
  assert_spec_subject "${STEP_SRC}" "the go.mod oracle step (base#1463)"
  _green_set
  _fixture noclass 'module example.com/m' 'require a v1.0.0'
  _go noclass 0 a v1.0.0
  _oracle
  assert_equal "${status}" 1
  assert_logged_event go_mod_fixture_unclassified "noclass.mod"
}

# why: `#` is not a go.mod comment; a `# class:` header is a typo, not a class.
@test "20-gomod-oracle.sh: a '# class:' header is go_mod_fixture_unclassified (base#1463)" {
  assert_spec_subject "${STEP_SRC}" "the go.mod oracle step (base#1463)"
  _green_set
  _fixture hash '# class: supported' 'module example.com/m' 'require a v1.0.0'
  _go hash 1
  _oracle
  assert_equal "${status}" 1
  assert_logged_event go_mod_fixture_unclassified "hash.mod"
}

# why: Go canonicalises; a supported fixture whose records differ from Go's
# is exactly the drift the oracle exists to catch.
@test "20-gomod-oracle.sh: a supported fixture whose requires differ from Go's is go_mod_oracle_mismatch (base#1463)" {
  assert_spec_subject "${STEP_SRC}" "the go.mod oracle step (base#1463)"
  _fixture ok '// class: supported' 'module example.com/m' 'require a v1.0.0'
  _requires ok $'a\tv1.0.0'
  _go ok 0 a v1.2.0
  _oracle
  assert_equal "${status}" 1
  assert_logged_event go_mod_oracle_mismatch "ok.mod" class=supported
}

# why: policy-refused means Go reads the file; a fixture Go rejects is
# misclassified and would hide a go-invalid case.
@test "20-gomod-oracle.sh: a policy-refused fixture Go rejects is go_mod_oracle_mismatch (base#1463)" {
  assert_spec_subject "${STEP_SRC}" "the go.mod oracle step (base#1463)"
  _fixture rep '// class: policy-refused go_mod_unsupported_syntax replace' \
    'module example.com/m' 'require a v1.0.0' 'replace a => ./a'
  _go rep 1
  _oracle
  assert_equal "${status}" 1
  assert_logged_event go_mod_oracle_mismatch "rep.mod" class=policy-refused
}

# why: The blocking point of the review: a file Go rejects must be one the
# scanner refuses. A go-invalid fixture the scanner reads is a mismatch,
# whatever the require lists say -- an oracle that only compared require
# lists would pass it.
@test "20-gomod-oracle.sh: a go-invalid fixture the scanner accepts is go_mod_oracle_mismatch (base#1463)" {
  assert_spec_subject "${STEP_SRC}" "the go.mod oracle step (base#1463)"
  _fixture acc '// class: go-invalid' 'module example.com/m' 'require a v1.0.0'
  _go acc 1
  _oracle
  assert_equal "${status}" 1
  assert_logged_event go_mod_oracle_mismatch "acc.mod" class=go-invalid
}

# why: A policy refusal is pinned by its reason; refusing for another reason
# means the named guard is not the one doing the work.
@test "20-gomod-oracle.sh: a policy-refused fixture refused for another reason is go_mod_oracle_mismatch (base#1463)" {
  assert_spec_subject "${STEP_SRC}" "the go.mod oracle step (base#1463)"
  _fixture rep '// class: policy-refused go_mod_unsupported_syntax tool' \
    'module example.com/m' 'require a v1.0.0' 'replace a => ./a'
  _go rep 0 a v1.0.0
  _oracle
  assert_equal "${status}" 1
  assert_logged_event go_mod_oracle_mismatch "rep.mod" class=policy-refused
}

# why: The image is read from the golang pin, never hard-coded; with no pin
# there is no image to trust, so docker must not run.
@test "20-gomod-oracle.sh: a Dockerfile with no golang pin is go_mod_oracle_pin_missing and runs no docker (base#1463)" {
  assert_spec_subject "${STEP_SRC}" "the go.mod oracle step (base#1463)"
  _green_set
  sed -i '/^# tool-pin: golang /d' "${R}/dockerfile/Dockerfile.config-gen"
  _oracle
  assert_equal "${status}" 1
  assert_logged_event go_mod_oracle_pin_missing
  assert_equal "$(_docker_calls)" 0
}
