#!/usr/bin/env bats
#
# config_gen_gates_spec.bats -- the Go gates of the config generator and the
# two scripts that run them (base#1462).
#
# why: ADR-00000039 makes the config generator one typed Go program, and S1b
# lands its skeleton. Nothing runs Go gates anywhere before this slice:
# `just test go` is not a recipe, no Dockerfile builds the module and no CI
# job calls it. This spec pins the pieces that make one command, `just test
# go`, run the same gates in every environment:
#
#   dockerfile/Dockerfile.config-gen  build, test and final (scratch) stages;
#                                     the test stage runs fmt, vet, lint,
#                                     race and coverage, one RUN each, in
#                                     that order.
#   script/test/config_gen_gates.sh   the runner: steps seam, named build
#                                     contexts, the docker build, the gate id
#                                     re-emitted, and the binary contract.
#   script/test/config_gen_redpath.sh one planted defect per gate plus an
#                                     unmodified control, each run through
#                                     the runner on a scratch copy.
#   `go` recipe in justfile.test      the runner, then the redpath.
#
# docker, just and the runner are stubbed here; the real `just test go` is
# the end-to-end proof that the planted defects go red.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  RUNNER="/source/script/test/config_gen_gates.sh"
  REDPATH="/source/script/test/config_gen_redpath.sh"
  DOCKERFILE="/source/dockerfile/Dockerfile.config-gen"
  S="${BATS_TEST_TMPDIR}"
  mkdir -p "${S}/bin"
}

# ── fixtures ────────────────────────────────────────────────────────────────

# _root -- a minimal --root tree for the runner at ${S}/root: the Dockerfile
# path it checks, the module context and an empty steps directory.
_root() {
  mkdir -p "${S}/root/dockerfile/config-gen" "${S}/root/script/test/config_gen_steps"
  printf 'FROM scratch\n' > "${S}/root/dockerfile/Dockerfile.config-gen"
}

# _gate_log <gate>... -- the plain-progress lines a test-stage build prints
# when each named gate passed.
_gate_log() {
  local _g _n=7
  for _g in "$@"; do
    printf '#%s [test %s/6] RUN echo\n#%s 0.41 gate=%s ok\n' "${_n}" "${_n}" "${_n}" "${_g}"
    _n=$(( _n + 1 ))
  done
}

# _stub_docker -- a `docker` first on PATH. Each call writes its argv one
# argument per line to ${S}/docker.<n>.argv. `build --target test` prints
# ${S}/build_test.err on stderr (BuildKit plain progress goes there) and
# exits ${S}/build_test.rc. Any other build writes the image id to an
# --iidfile and, under -q, prints it. `run` prints ${S}/run.out with no
# newline and exits ${S}/run.rc.
_stub_docker() {
  _gate_log fmt vet lint race coverage > "${S}/build_test.err"
  printf '0\n' > "${S}/build_test.rc"
  printf '' > "${S}/run.out"
  printf '2\n' > "${S}/run.rc"
  cat > "${S}/bin/docker" <<EOF
#!$(command -v bash)
n=\$(( \$(cat "${S}/docker.n" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "\${n}" > "${S}/docker.n"
printf '%s\n' "\$@" > "${S}/docker.\${n}.argv"
case "\${1:-}" in
  build)
    target="" iid="" quiet=0 prev=""
    for a in "\$@"; do
      [[ "\${prev}" == --target ]] && target="\${a}"
      [[ "\${prev}" == --iidfile ]] && iid="\${a}"
      [[ "\${a}" == --target=* ]] && target="\${a#--target=}"
      [[ "\${a}" == --iidfile=* ]] && iid="\${a#--iidfile=}"
      [[ "\${a}" == -q || "\${a}" == --quiet ]] && quiet=1
      prev="\${a}"
    done
    if [[ "\${target}" == test ]]; then
      cat "${S}/build_test.err" >&2
      exit "\$(cat "${S}/build_test.rc")"
    fi
    [[ -n "\${iid}" ]] && printf 'sha256:stubiid' > "\${iid}"
    [[ "\${quiet}" -eq 1 ]] && printf 'sha256:stubiid\n'
    exit 0 ;;
  run)
    printf '%s' "\$(cat "${S}/run.out")"
    exit "\$(cat "${S}/run.rc")" ;;
esac
exit 0
EOF
  chmod +x "${S}/bin/docker"
}

# _docker_calls -- how many times the docker stub ran.
_docker_calls() {
  cat "${S}/docker.n" 2>/dev/null || echo 0
}

# _argv_with <a> <b> -- the docker.<n>.argv file in which argument <a> is
# directly followed by <b>; nothing when no call had that pair.
_argv_with() {
  local _f
  for _f in "${S}"/docker.*.argv; do
    [[ -f "${_f}" ]] || continue
    awk -v a="${1}" -v b="${2}" 'p == a && $0 == b {f=1} {p=$0} END {exit !f}' "${_f}" \
      && { printf '%s\n' "${_f}"; return 0; }
  done
  return 1
}

# _run_runner [args...] -- the runner against ${S}/root with the stubs first
# on PATH, JSON logging, stdout and stderr judged apart.
_run_runner() {
  run --separate-stderr env PATH="${S}/bin:${PATH}" LOG_FORMAT=json \
      bash "${RUNNER}" --root "${S}/root" "$@"
}

# ── the Dockerfile ──────────────────────────────────────────────────────────

# _df_instructions -- the Dockerfile's instructions, continuation lines
# joined, comments dropped, one per line, each prefixed with the stage it
# sits in ("<stage>\t<instruction>").
_df_instructions() {
  awk '
    /^[[:space:]]*#/ {next}
    {
      line = line $0
      if (line ~ /\\$/) { sub(/\\$/, " ", line); next }
      if (line ~ /^[[:space:]]*$/) { line = ""; next }
      if (line ~ /^FROM /) {
        n = split(line, w, /[[:space:]]+/)
        stage = (n >= 4 && tolower(w[n-1]) == "as") ? w[n] : ""
      }
      print stage "\t" line
      line = ""
    }' "${DOCKERFILE}"
}

# why: Each gate is its own RUN so a red names its gate: one RUN running all
# five would leave the first id as the only record and stop the later gates
# from reading as "never reached" rather than "passed". The order is the one
# the redpath's earlier_gate_missing check reads.
@test "Dockerfile.config-gen: the test stage runs fmt, vet, lint, race, coverage, one RUN each, in that order (base#1462)" {
  assert_spec_subject "${DOCKERFILE}" "the config generator's build/test/final Dockerfile (base#1462)"
  local _gates
  _gates="$(_df_instructions | awk -F'\t' '$1 == "test" && $2 ~ /^RUN / {print $2}' \
      | grep -oE 'gate=[a-z]+ ok' | sed -E 's/^gate=([a-z]+) ok$/\1/' | paste -sd' ')"
  assert_equal "${_gates}" "fmt vet lint race coverage"
  # One gate per RUN: no test-stage RUN carries two ok lines.
  _df_instructions > "${S}/df"
  run awk -F'\t' '$1 == "test" && $2 ~ /^RUN / { n = gsub(/gate=[a-z]+ ok/, "&"); if (n > 1) print }' "${S}/df"
  assert_success
  assert_output ""
}

# why: The coverage gate is a script so the >= 90% rule and its refusals can
# be tested on the host with a stub go; an inline awk in the RUN could not be.
@test "Dockerfile.config-gen: the coverage RUN runs gates/coverage.sh (base#1462)" {
  assert_spec_subject "${DOCKERFILE}" "the config generator's build/test/final Dockerfile (base#1462)"
  _df_instructions > "${S}/df"
  run awk -F'\t' '$1 == "test" && $2 ~ /^RUN / && /gate=coverage ok/' "${S}/df"
  assert_success
  [[ -n "${output}" ]] || fail "no test-stage RUN prints gate=coverage ok"
  assert_output --partial 'gates/coverage.sh'
}

# why: The shipped stage holds only the binary; the runner's binary contract
# runs that stage, so a final stage built on the toolchain would let the
# contract pass on a binary nobody ships.
@test "Dockerfile.config-gen: declares build, test and a final stage FROM scratch (base#1462)" {
  assert_spec_subject "${DOCKERFILE}" "the config generator's build/test/final Dockerfile (base#1462)"
  _df_instructions > "${S}/df"
  run awk -F'\t' '$2 ~ /^FROM / {print $2}' "${S}/df"
  assert_success
  assert_line --regexp '^FROM .* (AS|as) build$'
  assert_line --regexp '^FROM build (AS|as) test$'
  assert_line --regexp '^FROM scratch (AS|as) final$'
}

# why: The pin-coverage lint and the tool-pin watch read the marker on the
# line above each version ARG; a pin with no marker is a version nothing
# watches. The race gate needs cgo and gcc, which the trixie image carries
# and alpine does not.
@test "Dockerfile.config-gen: the golang trixie image and golangci-lint are tool-pin marked ARGs (base#1462)" {
  assert_spec_subject "${DOCKERFILE}" "the config generator's build/test/final Dockerfile (base#1462)"
  run awk '
    /^ARG GO[A-Z_]*=golang:[^ ]*-trixie/ { if (p ~ /^# tool-pin: .*library\/golang/) go = 1 }
    /^ARG GOLANGCI_LINT_VERSION=[^ ]+/ { if (p ~ /^# tool-pin: .*golangci\/golangci-lint/) lint = 1 }
    {p = $0}
    END { if (!go) print "golang"; if (!lint) print "golangci-lint" }' "${DOCKERFILE}"
  assert_success
  assert_output ""
}

# ── the runner ──────────────────────────────────────────────────────────────

# why: The runner is the one command every environment calls; its whole
# green path is the test-stage build with the gates uncached, the final
# build and the binary contract, with each gate's ok line handed back.
@test "config_gen_gates.sh: a green run builds test then final, re-prints every gate ok and passes the binary contract (base#1462)" {
  assert_spec_subject "${RUNNER}" "the config-gen gates runner (base#1462)"
  _root
  _stub_docker
  _run_runner
  assert_success
  run grep -E '^gate=[a-z]+ ok$' <<<"${output}"
  assert_output "$(printf 'gate=%s ok\n' fmt vet lint race coverage)"
  # f. argv is read as an array: the gates run uncached, on the test target,
  # from the config-gen Dockerfile and module context under --root.
  local _test
  _test="$(_argv_with --target test)" || fail "no docker call built --target test"
  _argv_with --no-cache-filter test >/dev/null || fail "the test build does not pass --no-cache-filter test"
  run cat "${_test}"
  assert_line 'build'
  assert_line '--progress=plain'
  assert_line "${S}/root/dockerfile/config-gen"
  awk -v d="${S}/root/dockerfile/Dockerfile.config-gen" 'p == "-f" && $0 == d {f=1} {p=$0} END {exit !f}' "${_test}" \
    || fail "the test build does not read -f ${S}/root/dockerfile/Dockerfile.config-gen: $(cat "${_test}")"
  _argv_with --target final >/dev/null || fail "no docker call built --target final"
  # The binary run is of the final image, removed after.
  run grep -lx 'sha256:stubiid' "${S}"/docker.*.argv
  assert_success
  run cat "${output}"
  assert_line 'run'
  assert_line '--rm'
}

# why: Without this a later slice's inputs would need a runner edit; the
# steps seam and named contexts are what keep the runner closed to them.
@test "config_gen_gates.sh: a step's context directory becomes a named build context, and none without one (base#1462)" {
  assert_spec_subject "${RUNNER}" "the config-gen gates runner (base#1462)"
  _root
  _stub_docker
  _run_runner
  assert_success
  run grep -lx -- '--build-context' "${S}"/docker.*.argv
  assert_failure
  rm -f "${S}"/docker.*
  printf 'printf "%%s" "${CONFIG_GEN_CTX}" > "%s/ctx"\nmkdir -p "${CONFIG_GEN_CTX}/corpus"\n' "${S}" \
    > "${S}/root/script/test/config_gen_steps/10-a.sh"
  _run_runner
  assert_success
  _argv_with --build-context "$(cat "${S}/ctx")/corpus" >/dev/null && fail "the context was passed without its name"
  _argv_with --build-context "corpus=$(cat "${S}/ctx")/corpus" >/dev/null \
    || fail "no build passed --build-context corpus=<ctx>/corpus: $(cat "${S}"/docker.*.argv)"
}

# why: A step that failed and was carried past would build an image from
# inputs that were never prepared, and report its gates as if they were.
@test "config_gen_gates.sh: a failing step stops the run with its status before docker, in lexical order (base#1462)" {
  assert_spec_subject "${RUNNER}" "the config-gen gates runner (base#1462)"
  _root
  _stub_docker
  local _d="${S}/root/script/test/config_gen_steps"
  # Created out of lexical order: the run must not follow creation order.
  printf 'echo 30-c >> "%s/steps"\n' "${S}" > "${_d}/30-c.sh"
  printf 'echo 20-b >> "%s/steps"\nexit 3\n' "${S}" > "${_d}/20-b.sh"
  printf 'echo 10-a >> "%s/steps"\n' "${S}" > "${_d}/10-a.sh"
  _run_runner
  assert_refusal 3 config_gen_step_failed step=20-b status=3
  assert_equal "$(paste -sd' ' "${S}/steps")" "10-a 20-b"
  assert_equal "$(_docker_calls)" 0
}

# why: A context name is spliced into `--build-context <name>=<path>`; a name
# carrying `=` or a path separator would name another context or path.
@test "config_gen_gates.sh: a context name outside [a-z0-9-] is refused before docker (base#1462)" {
  assert_spec_subject "${RUNNER}" "the config-gen gates runner (base#1462)"
  _root
  _stub_docker
  printf 'mkdir -p "${CONFIG_GEN_CTX}/a=b"\n' > "${S}/root/script/test/config_gen_steps/10-a.sh"
  _run_runner
  assert_refusal 1 config_gen_context_invalid context=a=b
  assert_equal "$(_docker_calls)" 0
}

# why: A --root that is not a config-gen tree would build whatever sits
# there, or nothing, and still read as a verdict on the generator.
@test "config_gen_gates.sh: a --root that is missing or holds no Dockerfile.config-gen is refused (base#1462)" {
  assert_spec_subject "${RUNNER}" "the config-gen gates runner (base#1462)"
  _stub_docker
  run --separate-stderr env PATH="${S}/bin:${PATH}" LOG_FORMAT=json \
      bash "${RUNNER}" --root "${S}/nope"
  assert_refusal 2 config_gen_root_invalid "root=${S}/nope"
  mkdir -p "${S}/empty"
  run --separate-stderr env PATH="${S}/bin:${PATH}" LOG_FORMAT=json \
      bash "${RUNNER}" --root "${S}/empty"
  assert_refusal 2 config_gen_root_invalid "root=${S}/empty"
  assert_equal "$(_docker_calls)" 0
}

# why: A --root with no directory after it, or an argument the runner does
# not know, would otherwise run the gates on a tree the caller did not name
# and report that verdict as theirs. Each is a usage refusal: status 2,
# nothing on stdout, the argument named, and docker never reached.
@test "config_gen_gates.sh: --root without a directory is refused as usage before docker (base#1462)" {
  assert_spec_subject "${RUNNER}" "the config-gen gates runner (base#1462)"
  _root
  _stub_docker
  run --separate-stderr env PATH="${S}/bin:${PATH}" LOG_FORMAT=json \
      bash "${RUNNER}" --root
  assert_refusal 2 config_gen_usage_invalid arg=--root
  assert_equal "$(_docker_calls)" 0
}

# why: The catch-all branch is the one a typo reaches; a runner that
# ignored an unknown flag would report on the default tree as if the
# caller had asked for that run.
@test "config_gen_gates.sh: an unknown argument is refused as usage before docker (base#1462)" {
  assert_spec_subject "${RUNNER}" "the config-gen gates runner (base#1462)"
  _root
  _stub_docker
  _run_runner --bogus
  assert_refusal 2 config_gen_usage_invalid arg=--bogus
  assert_equal "$(_docker_calls)" 0
}

# why: The build's own log is long and plain; without the id re-emitted as
# an event the redpath, CI and a reader all have to scrape BuildKit output to
# learn which gate went red, and docker's status is the run's verdict.
@test "config_gen_gates.sh: a red gate propagates docker's status and re-emits the gate's id (base#1462)" {
  assert_spec_subject "${RUNNER}" "the config-gen gates runner (base#1462)"
  _root
  _stub_docker
  { _gate_log fmt; printf '#8 0.52 config_gen_gate_vet_failed\n'; } > "${S}/build_test.err"
  printf '7\n' > "${S}/build_test.rc"
  _run_runner
  assert_equal "${status}" 7
  assert_logged_event config_gen_gate_vet_failed gate=vet
  assert_line 'gate=fmt ok'
  refute_line 'gate=vet ok'
  _argv_with --target final >/dev/null && fail "the final stage was built after a red gate"
  true
}

# why: The final image is what ships. A binary that exits 0 with no
# arguments, or writes usage to stdout, breaks the rc 2 / empty stdout
# contract callers rely on, whatever the gates said.
@test "config_gen_gates.sh: the built binary must exit 2 with empty stdout on no arguments (base#1462)" {
  assert_spec_subject "${RUNNER}" "the config-gen gates runner (base#1462)"
  _root
  _stub_docker
  printf '0\n' > "${S}/run.rc"
  _run_runner
  assert_equal "${status}" 1
  assert_logged_event config_gen_binary_contract_failed status=0 stdout_bytes=0
  printf '2\n' > "${S}/run.rc"
  printf 'x' > "${S}/run.out"
  _run_runner
  assert_equal "${status}" 1
  assert_logged_event config_gen_binary_contract_failed status=2 stdout_bytes=1
  printf '' > "${S}/run.out"
  _run_runner
  assert_success
}

# ── the redpath ─────────────────────────────────────────────────────────────

# The cases the redpath plants, in the order it runs them, each with the
# gate whose id it must produce; the unmodified control comes last.
REDPATH_CASES="fmt:fmt vet:vet lint:lint race:race race-fuzz:race coverage:coverage fmt-parse:fmt"

# _redpath_repo -- a scratch copy of what the redpath reads, at ${S}/repo,
# with a recording stub in place of the runner. Call <n> of the stub writes
# its argv to ${S}/runner.<n>.argv, records whether its --root held a
# config-gen tree and the LOG_FORMAT it was handed (${S}/runner.formats),
# prints ${S}/canned/<n>.out on stdout and .err on stderr, and exits .rc.
_redpath_repo() {
  local _r="${S}/repo"
  mkdir -p "${_r}/script/test" "${_r}/dist/script/docker"
  cp -a /source/dockerfile "${_r}/"
  cp -a /source/dist/script/docker/lib "${_r}/dist/script/docker/"
  cp -a /source/script/test/. "${_r}/script/test/"
  cat > "${_r}/script/test/config_gen_gates.sh" <<EOF
#!$(command -v bash)
n=\$(( \$(cat "${S}/runner.n" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "\${n}" > "${S}/runner.n"
printf '%s\n' "\$@" > "${S}/runner.\${n}.argv"
root=""; prev=""
for a in "\$@"; do [[ "\${prev}" == --root ]] && root="\${a}"; prev="\${a}"; done
[[ -f "\${root}/dockerfile/Dockerfile.config-gen" ]] && echo tree >> "${S}/runner.trees"
printf '%s\n' "\${LOG_FORMAT:-unset}" >> "${S}/runner.formats"
[[ -d "\${root}/dockerfile/config-gen" ]] && cp -a "\${root}/dockerfile/config-gen" "${S}/runner.\${n}.mod"
cat "${S}/canned/\${n}.out" 2>/dev/null
cat "${S}/canned/\${n}.err" >&2 2>/dev/null
exit "\$(cat "${S}/canned/\${n}.rc" 2>/dev/null || echo 9)"
EOF
  chmod +x "${_r}/script/test/config_gen_gates.sh"
  # A just or docker reached from the redpath would be a nested run.
  printf '#!%s\necho "$0 $*" >> "%s/nested"\nexit 0\n' "$(command -v bash)" "${S}" > "${S}/bin/just"
  cp "${S}/bin/just" "${S}/bin/docker"
  chmod +x "${S}/bin/just" "${S}/bin/docker"
  _canned_correct
}

# _gate_record <id> [attr=value...] -- the JSON log record the real runner
# writes on stderr for <id>, made by the real logger.
_gate_record() {
  LOG_FORMAT=json bash -c 'source "$1"; shift; _log_err config-gen "$@"' _ \
    /source/dist/script/docker/lib/log.sh "$@" 2>&1
}

# _canned_correct -- the runner answers each case as a correct gate would:
# every earlier gate ok, the build log line naming the case's gate, then
# the runner's own record of that gate id, and rc 1; the control is all
# five ok and rc 0.
_canned_correct() {
  local _all=(fmt vet lint race coverage) _case _gate _n=0 _g
  mkdir -p "${S}/canned"
  for _case in ${REDPATH_CASES}; do
    _n=$(( _n + 1 ))
    _gate="${_case#*:}"
    : > "${S}/canned/${_n}.out"
    for _g in "${_all[@]}"; do
      [[ "${_g}" == "${_gate}" ]] && break
      printf 'gate=%s ok\n' "${_g}" >> "${S}/canned/${_n}.out"
    done
    printf '#9 0.31 config_gen_gate_%s_failed\n' "${_gate}" > "${S}/canned/${_n}.err"
    _gate_record "config_gen_gate_${_gate}_failed" "gate=${_gate}" status=1 \
      "display=config-gen gate ${_gate} failed (docker exited 1)" >> "${S}/canned/${_n}.err"
    printf '1\n' > "${S}/canned/${_n}.rc"
  done
  _n=$(( _n + 1 ))
  printf 'gate=%s ok\n' "${_all[@]}" > "${S}/canned/${_n}.out"
  : > "${S}/canned/${_n}.err"
  printf '0\n' > "${S}/canned/${_n}.rc"
}

# _run_redpath -- the scratch redpath with the stubs first on PATH.
_run_redpath() {
  run --separate-stderr env -u CONFIG_GEN_REDPATH_ACTIVE PATH="${S}/bin:${PATH}" \
      LOG_FORMAT=json timeout 60 bash "${S}/repo/script/test/config_gen_redpath.sh"
}

# why: The redpath proves each gate CAN fail; calling `just test go` from it
# would recurse into itself, and reusing one scratch tree would let one
# case's defect leak into the next. The control proves the reds come from
# the defects and not from the copy.
@test "config_gen_redpath.sh: runs the runner once per case and once for the control, each on its own copy (base#1462)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  _redpath_repo
  _run_redpath
  assert_success
  assert_equal "$(cat "${S}/runner.n")" 8
  assert_equal "$(grep -c . "${S}/runner.trees")" 8
  local _roots
  _roots="$(for _f in "${S}"/runner.*.argv; do awk 'p == "--root" {print} {p=$0}' "${_f}"; done)"
  assert_equal "$(sort -u <<<"${_roots}" | grep -c .)" 8
  run grep -Fx "${S}/repo" <<<"${_roots}"
  assert_failure
  [[ ! -s "${S}/nested" ]] || fail "the redpath reached just or docker itself: $(cat "${S}/nested")"
}

# why: A gate that never goes red is indistinguishable from a working one on
# a clean tree; each verdict below is a way a broken gate would otherwise
# pass the redpath. Every case is reported before the run fails.
@test "config_gen_redpath.sh: a case whose runner exited 0 fails with reason rc_zero, and the rest still run (base#1462)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  _redpath_repo
  printf '0\n' > "${S}/canned/2.rc"
  _run_redpath
  assert_equal "${status}" 1
  assert_logged_event config_gen_redpath_case_failed case=vet reason=rc_zero gate=vet
  assert_equal "$(cat "${S}/runner.n")" 8
}

@test "config_gen_redpath.sh: a case that went red on another gate's id fails with reason wrong_id (base#1462)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  _redpath_repo
  _gate_record config_gen_gate_vet_failed gate=vet status=1 display=vet > "${S}/canned/3.err"
  _run_redpath
  assert_equal "${status}" 1
  assert_logged_event config_gen_redpath_case_failed case=lint reason=wrong_id gate=lint
}

# why: The id a case must produce is the runner's own record of the gate
# that went red. A substring scan over stderr would also accept the id
# quoted inside unrelated text, a longer id that starts with it, or the
# build log line the runner streams ahead of its verdict; each of those is
# a run that did not report the planted gate.
@test "config_gen_redpath.sh: the id only quoted in text or in the build log, with no record, is wrong_id (base#1462)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  _redpath_repo
  printf 'unrelated: config_gen_gate_fmt_failed_extra\n#9 0.31 config_gen_gate_fmt_failed\n' > "${S}/canned/1.err"
  printf 'unrelated: config_gen_gate_vet_failed\n' > "${S}/canned/2.err"
  _run_redpath
  assert_equal "${status}" 1
  assert_logged_event config_gen_redpath_case_failed case=fmt reason=wrong_id gate=fmt
  grep -F '"body":"config_gen_redpath_case_failed"' <<<"${stderr}" | grep -F '"case":"vet"' | grep -qF '"reason":"wrong_id"' \
    || fail "case vet passed on an id quoted in text: ${stderr}"
}

# why: Even among JSON records only the body names the gate that went red;
# a match on a body prefix, or on display text, would let an unrelated
# event or a longer id stand in for the planted gate's record.
@test "config_gen_redpath.sh: a record whose body is a longer id, or another event naming the id, is wrong_id (base#1462)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  _redpath_repo
  _gate_record config_gen_gate_fmt_failed gate=fmt status=1 display=fmt \
    | sed 's/"body":"config_gen_gate_fmt_failed"/"body":"config_gen_gate_fmt_failed_extra"/' > "${S}/canned/1.err"
  grep -qF '"body":"config_gen_gate_fmt_failed_extra"' "${S}/canned/1.err" || fail "fixture: no suffixed body"
  _gate_record config_gen_build_failed status=1 "display=not config_gen_gate_vet_failed" > "${S}/canned/2.err"
  _run_redpath
  assert_equal "${status}" 1
  assert_logged_event config_gen_redpath_case_failed case=fmt reason=wrong_id gate=fmt
  grep -F '"body":"config_gen_redpath_case_failed"' <<<"${stderr}" | grep -F '"case":"vet"' | grep -qF '"reason":"wrong_id"' \
    || fail "case vet passed on another event naming its id: ${stderr}"
}

# why: The verdict reads JSON records; a caller exporting LOG_FORMAT=text
# would otherwise turn every case into wrong_id, or (with a looser parse)
# into a scrape of display text.
@test "config_gen_redpath.sh: runs the runner with JSON logging whatever the caller's LOG_FORMAT (base#1462)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  _redpath_repo
  run --separate-stderr env -u CONFIG_GEN_REDPATH_ACTIVE PATH="${S}/bin:${PATH}" \
      LOG_FORMAT=text timeout 60 bash "${S}/repo/script/test/config_gen_redpath.sh"
  assert_success
  assert_equal "$(sort -u "${S}/runner.formats")" json
}

@test "config_gen_redpath.sh: a case whose earlier gate printed no ok fails with reason earlier_gate_missing (base#1462)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  _redpath_repo
  printf 'gate=fmt ok\ngate=vet ok\n' > "${S}/canned/4.out"
  _run_redpath
  assert_equal "${status}" 1
  assert_logged_event config_gen_redpath_case_failed case=race reason=earlier_gate_missing gate=race
}

@test "config_gen_redpath.sh: the race-fuzz case must produce the race gate's id (base#1462)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  _redpath_repo
  _gate_record config_gen_gate_coverage_failed gate=coverage status=1 display=coverage > "${S}/canned/5.err"
  _run_redpath
  assert_equal "${status}" 1
  assert_logged_event config_gen_redpath_case_failed case=race-fuzz reason=wrong_id gate=race
}

# why: A _test.go file is outside `go build`, so a syntax error there
# passes the build stage and reaches the fmt gate first. gofmt then exits
# non-zero instead of listing a file; a fmt RUN that let that status kill
# it before printing its own id would report the case as a build failure,
# and the fmt gate would be green on a file it never read (base#1462).
@test "config_gen_redpath.sh: the fmt-parse case plants a _test.go file gofmt cannot parse and must produce the fmt gate's id (base#1462)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  _redpath_repo
  _run_redpath
  assert_success
  local _new
  _new="$(cd "${S}/runner.7.mod" && find . -type f | sort | comm -23 - <(cd /source/dockerfile/config-gen && find . -type f | sort))"
  assert_equal "${_new}" "./cmd/config-gen/zz_parse_test.go"
  # Unbalanced braces: no Go parser accepts the file.
  local _open _close
  _open="$(tr -cd '{' < "${S}/runner.7.mod/cmd/config-gen/zz_parse_test.go" | wc -c)"
  _close="$(tr -cd '}' < "${S}/runner.7.mod/cmd/config-gen/zz_parse_test.go" | wc -c)"
  (( _open != _close )) || fail "zz_parse_test.go balances its braces: $(cat "${S}/runner.7.mod/cmd/config-gen/zz_parse_test.go")"
  # A build-failure record in place of the fmt id fails the case.
  rm -rf "${S}"/runner.*
  _gate_record config_gen_build_failed status=1 display=build > "${S}/canned/7.err"
  _run_redpath
  assert_equal "${status}" 1
  assert_logged_event config_gen_redpath_case_failed case=fmt-parse reason=wrong_id gate=fmt
}

# why: Go's automatic toolchain selection downloads and runs a compiler
# other than the pinned image's when go.mod asks for a newer one;
# ADR-00000039 requires GOTOOLCHAIN=local so every gate runs the pinned
# toolchain or fails. The test stage is FROM build, so one ENV in build,
# ahead of its first RUN, covers every go command in both (base#1462).
@test "Dockerfile.config-gen: the build stage sets GOTOOLCHAIN=local before its first RUN, and nothing overrides it (base#1462)" {
  assert_spec_subject "${DOCKERFILE}" "the config generator's build/test/final Dockerfile (base#1462)"
  _df_instructions > "${S}/df"
  run awk -F'\t' '$1 == "build" && $2 ~ /^(ENV|RUN) / {print $2; exit}' "${S}/df"
  assert_success
  assert_output 'ENV GOTOOLCHAIN=local'
  run awk -F'\t' '/GOTOOLCHAIN/ && $2 != "ENV GOTOOLCHAIN=local" {print}' "${S}/df"
  assert_success
  assert_output ""
  run awk -F'\t' '$2 ~ /^FROM / {print $2}' "${S}/df"
  assert_line --regexp '^FROM build (AS|as) test$'
}

@test "config_gen_redpath.sh: a red control fails the run with the control's status (base#1462)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  _redpath_repo
  printf '1\n' > "${S}/canned/8.rc"
  _run_redpath
  assert_equal "${status}" 1
  assert_logged_event config_gen_redpath_control_failed status=1
}

# why: `just test go` runs the redpath, and the redpath runs the runner; a
# redpath that reached `just test go` again would recurse without bound. The
# guard refuses a nested entry and runs nothing.
@test "config_gen_redpath.sh: a nested entry is refused with config_gen_redpath_reentered and runs nothing (base#1462)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  _redpath_repo
  run --separate-stderr env CONFIG_GEN_REDPATH_ACTIVE=1 PATH="${S}/bin:${PATH}" \
      LOG_FORMAT=json timeout 10 bash "${S}/repo/script/test/config_gen_redpath.sh"
  assert_refusal 1 config_gen_redpath_reentered
  [[ ! -e "${S}/runner.n" ]] || fail "the guarded redpath still called the runner $(cat "${S}/runner.n") time(s)"
  [[ ! -s "${S}/nested" ]] || fail "the guarded redpath reached just or docker: $(cat "${S}/nested")"
}

# ── the recipe ──────────────────────────────────────────────────────────────

# _recipe_repo <gates-rc> -- a scratch copy of the two justfiles with
# recording stubs for the runner (exiting <gates-rc>) and the redpath.
_recipe_repo() {
  local _r="${S}/j"
  mkdir -p "${_r}/script/test"
  cp /source/justfile "${_r}/justfile"
  cp /source/script/test/justfile.test "${_r}/script/test/justfile.test"
  printf '#!%s\necho gates >> "%s/order"\nexit %s\n' "$(command -v bash)" "${S}" "${1}" \
    > "${_r}/script/test/config_gen_gates.sh"
  printf '#!%s\necho redpath >> "%s/order"\nexit 0\n' "$(command -v bash)" "${S}" \
    > "${_r}/script/test/config_gen_redpath.sh"
  chmod +x "${_r}/script/test/"config_gen_*.sh
}

# why: The one command all four environments run. The order matters: the
# redpath on a tree whose gates are already red proves nothing, and `;`
# would run it after a red runner and report the redpath's status instead.
@test "just test go: runs the runner, then the redpath, and stops at a red runner (base#1462)" {
  _recipe_repo 0
  run bash -c "cd '${S}/j' && just test go"
  assert_success
  assert_equal "$(paste -sd' ' "${S}/order")" "gates redpath"
  rm -f "${S}/order"
  _recipe_repo 1
  run bash -c "cd '${S}/j' && just test go"
  assert_failure
  assert_equal "$(paste -sd' ' "${S}/order")" "gates"
}
