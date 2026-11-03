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
# It runs from the mutation context, where 01-admit installs it from the
# host checkout: a copy inside the module would be a module file no mapping
# rule of the mutation gate covers, so every change to it, and every run
# from an empty base, would be refused as unmapped (base#1467).
@test "Dockerfile.config-gen: the coverage RUN runs the coverage.sh 01-admit installs in the mutation context (base#1467)" {
  assert_spec_subject "${DOCKERFILE}" "the config generator's build/test/final Dockerfile (base#1462)"
  _df_instructions > "${S}/df"
  run awk -F'\t' '$1 == "test" && $2 ~ /^RUN / && /gate=coverage ok/' "${S}/df"
  assert_success
  [[ -n "${output}" ]] || fail "no test-stage RUN prints gate=coverage ok"
  assert_output --partial 'bash /mutation/coverage.sh --measure'
  run grep -cxF 'install -m 0644 "${_root}/script/test/config_gen_coverage.sh" "${_dst}/coverage.sh"' \
    /source/script/test/config_gen_steps/01-admit.sh
  assert_success
  assert_output 1
}

# why: The shipped stage holds only the binary; the runner's binary contract
# runs that stage, so a final stage built on the toolchain would let the
# contract pass on a binary nobody ships.
@test "Dockerfile.config-gen: declares build, test and a final stage FROM scratch (base#1462)" {
  assert_spec_subject "${DOCKERFILE}" "the config generator's build/test/final Dockerfile (base#1462)"
  _df_instructions > "${S}/df"
  run awk -F'\t' '$2 ~ /^FROM / {print $2}' "${S}/df"
  assert_success
  assert_line --regexp '^FROM goenv (AS|as) build$'
  assert_line --regexp '^FROM goenv (AS|as) test$'
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
  _argv_with --no-cache-filter admit,test >/dev/null || fail "the test build does not pass --no-cache-filter admit,test"
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

# why: The runner's stdout is its verdict: the ok lines it re-prints, which
# the redpath compares byte for byte (an unchanged rerun must print exactly
# the six ok lines, a refusal nothing at all; base#1465). A step's own
# report (20-gomod-oracle prints `gomod-oracle: <n> fixture(s) agree ...`,
# base#1463) is a log line, so it goes to stderr with the build log.
@test "config_gen_gates.sh: a step's stdout goes to stderr, so stdout holds only the ok lines (base#1465)" {
  assert_spec_subject "${RUNNER}" "the config-gen gates runner (base#1462)"
  _root
  _stub_docker
  printf 'echo step-report\n' > "${S}/root/script/test/config_gen_steps/10-a.sh"
  _run_runner
  assert_success
  assert_equal "${output}" "$(printf 'gate=%s ok\n' fmt vet lint race coverage)"
  assert_stderr_contains step-report
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

# why: A coverage RUN that never got the corpus root record refuses with
# reason=corpus_root_missing and an empty pkg (base#1468). The runner must
# name the coverage gate from that printed refusal line, not from the RUN
# line BuildKit echoes, whose command text names coverage.sh too: the
# echoed line alone is a build that failed before any gate.
@test "config_gen_gates.sh: a coverage refusal for a missing corpus root names the coverage gate, the echoed RUN line alone does not (base#1468)" {
  assert_spec_subject "${RUNNER}" "the config-gen gates runner (base#1462)"
  _root
  _stub_docker
  { _gate_log fmt vet lint race
    printf '#12 [test 5/6] RUN bash /mutation/coverage.sh /tmp/config-gen-corpus-root\n'
    printf '#12 0.52 config_gen_gate_coverage_failed reason=corpus_root_missing pkg=\n'; } > "${S}/build_test.err"
  printf '1\n' > "${S}/build_test.rc"
  _run_runner
  assert_equal "${status}" 1
  assert_logged_event config_gen_gate_coverage_failed gate=coverage
  { _gate_log fmt vet lint race
    printf '#12 [test 5/6] RUN bash /mutation/coverage.sh /tmp/config-gen-corpus-root\n'; } > "${S}/build_test.err"
  _run_runner
  assert_equal "${status}" 1
  assert_logged_event config_gen_build_failed status=1
  grep -qF '"body":"config_gen_gate_coverage_failed"' <<<"${stderr}" \
    && fail "the echoed RUN line was read as the coverage gate's refusal: ${stderr}"
  true
}

# why: The coverage ratchet prints one cg_event line per refusal, and one
# red build can carry several (a dropped fragment leaves a dropped and a
# missing package); each must reach the runner's records, in log order,
# before the gate's own, and an id outside the allowlist or a word outside
# file|reason|pkg|other|line|floor|measured|base must not, so the build log
# can never put an arbitrary body or attribute into them (base#1465).
@test "config_gen_gates.sh: a red build re-emits every allowlisted cg_event line in log order with only its allowed words, then the gate id (base#1465)" {
  assert_spec_subject "${RUNNER}" "the config-gen gates runner (base#1462)"
  _root
  _stub_docker
  { _gate_log admission fmt vet lint race
    printf '#12 [test 8/8] RUN g=coverage; bash /mutation/coverage.sh --measure /tmp/measured\n'
    printf '#12 1.069 cg_event config_gen_coverage_floor_dropped pkg=internal/testcorpus x=1\n'
    printf '#12 1.069 cg_event config_gen_coverage_floor_missing pkg=a%%20b\n'
    printf '#12 1.069 cg_event config_gen_coverage_floor_bogus pkg=z\n'
    printf '#12 1.069 cg_event config_gen_coverage_floor_below pkg=c measured=90.0 floor=95.0 display=spoof\n'
    printf '#12 1.069 config_gen_gate_coverage_failed\n'; } > "${S}/build_test.err"
  printf '1\n' > "${S}/build_test.rc"
  _run_runner
  assert_equal "${status}" 1
  [[ "${stderr}" != *"unregistered log body"* ]] || fail "unregistered log body: ${stderr}"
  assert_equal "$(jq -rR 'fromjson? | select(.attributes."service.name" == "config-gen")
    | [.body, (.attributes | del(."service.name", ."service.lang", ."code.filepath", ."code.lineno",
      ."thread.id", .display, .status) | to_entries | map(.key + "=" + .value) | join(" "))] | join(" ")' <<<"${stderr}")" \
    "$(printf '%s\n' 'config_gen_coverage_floor_dropped pkg=internal/testcorpus' \
      'config_gen_coverage_floor_missing pkg=a%20b' \
      'config_gen_coverage_floor_below pkg=c measured=90.0 floor=95.0' \
      'config_gen_gate_coverage_failed gate=coverage')"
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

# _redpath_rows -- every case the redpath is required to run, one
# `<kind>|<case>|<want>` line each in the order it runs them (gate,
# refusal, stale, green, coverage). Written out here, not read from the
# redpath's own tables: a case dropped from the redpath must still get its
# canned answer and its expected runner call, so the full run below fails
# on it (base#1465). <want> is the gate, the event id, `<file>|<reason>`,
# empty, or `<event>|<pkg>|<file>` (file empty when the event names none).
_redpath_rows() {
  cat <<'EOF'
gate|fmt|fmt
gate|vet|vet
gate|lint|lint
gate|race|race
gate|race-fuzz|race
gate|coverage|coverage
gate|fmt-parse|fmt
gate|corpus-join|race
gate|corpus-helper|race
gate|corpus-var|race
refusal|no-context|config_gen_manifest_missing
stale|stale-edit|dockerfile/config-gen/cmd/config-gen/main.go|sha_mismatch
stale|stale-edit-locale|dockerfile/config-gen/cmd/config-gen/main.go|sha_mismatch
stale|stale-new-pkg|dockerfile/config-gen/internal/zznew/zznew.go|unlisted
stale|stale-delete|dockerfile/config-gen/cmd/config-gen/main_test.go|missing
stale|stale-symlink|dockerfile/config-gen/cmd/config-gen/zz.go|unlisted
stale|stale-dangling|dockerfile/config-gen/zz-dangling|not_regular
stale|stale-gomod|dockerfile/config-gen/go.mod|sha_mismatch
stale|stale-checker|dockerfile/config-gen/internal/buildgate/zz.go|unlisted
stale|stale-names|dockerfile/config-gen/zznames/a%20b.txt|sha_mismatch
stale|stale-header|manifest|header
stale|no-checker|admit.sh|absent
stale|no-lib|config_gen_mutation_lang.sh|absent
stale|tamper-r-garbage|manifest|record
stale|tamper-r999|manifest|record
stale|tamper-r101|manifest|record
stale|tamper-copy|manifest|record
stale|tamper-arity|manifest|record
stale|tamper-rename-self|manifest|presence
stale|tamper-ghost|manifest|presence
stale|tamper-delete-listed|manifest|presence
stale|tamper-add-twice|manifest|duplicate
stale|tamper-src-twice|manifest|presence
stale|tamper-modify-over-src|manifest|presence
stale|tamper-header-mixed|manifest|header
stale|tamper-header-dirty|manifest|header
stale|tamper-header-context|manifest|header
stale|tamper-marker-twice|manifest|none_marker
stale|tamper-header-only|manifest|body_empty
stale|tamper-manifest-unterminated|manifest|malformed
stale|tamper-visible-unterminated|visible.sha256|malformed
stale|tamper-ignored-unterminated|ignored.sha256|malformed
stale|tamper-crlf|manifest|header
stale|tamper-dotdot|manifest|path
stale|tamper-outside|manifest|path
stale|tamper-visible-dup|visible.sha256|duplicate
stale|tamper-dual|ignored.sha256|dual
green|names|
green|rename-recreate|
green|untrack|
green|rename-move|
green|untrack-ignored|
green|copies|
green|typechange|
coverage|cov-drop|config_gen_coverage_floor_below|cmd/config-gen|
coverage|cov-lowered|config_gen_coverage_floor_lowered|internal/buildgate|
coverage|cov-stale|config_gen_coverage_floor_stale|internal/buildgate|
coverage|cov-missing|config_gen_coverage_floor_missing|internal/zzmiss|
coverage|cov-duplicate|config_gen_coverage_floor_duplicate|internal/testcorpus|s1g.txt
coverage|cov-dropped|config_gen_coverage_floor_dropped|internal/testcorpus|
EOF
}

# _redpath_sequence -- the case each runner call of one full redpath run
# is told, in call order: every row, rerun twice, the control last.
_redpath_sequence() {
  _redpath_rows | cut -d'|' -f2
  printf '%s\n' rerun rerun control
}

# _ran_cases -- the case each runner call was told, in call order.
_ran_cases() {
  local _n
  for (( _n = 1; _n <= $(cat "${S}/runner.n" 2>/dev/null || echo 0); _n++ )); do
    cat "${S}/runner.${_n}.case"
  done
}

# _redpath_call <case> -- the 1-based runner call that ran <case> (its
# first, for rerun), read from the stub's records after a run.
_redpath_call() {
  local _f
  for _f in "${S}"/runner.*.case; do
    [[ "$(cat "${_f}")" == "${1}" ]] || continue
    _f="${_f#"${S}/runner."}"
    echo "${_f%.case}"
    return 0
  done
  echo "_redpath_call: no call ran ${1}" >&2
  return 1
}

# _redpath_repo -- a scratch copy of what the redpath reads, at ${S}/repo,
# with a recording stub in place of the runner. Call <n> of the stub
# writes its argv to ${S}/runner.<n>.argv and its CONFIG_GEN_REDPATH_CASE
# to ${S}/runner.<n>.case, records whether its --root held a config-gen
# tree and the LOG_FORMAT it was handed (${S}/runner.formats), and answers
# from ${S}/canned/<case>.<k>.{out,err,rc} for the k-th call of that case
# when one exists, else ${S}/canned/<case>.{out,err,rc}.
_redpath_repo() {
  local _r="${S}/repo"
  mkdir -p "${_r}/script/test" "${_r}/dist/script/docker"
  cp -a /source/dockerfile "${_r}/"
  cp -a /source/dist/script/docker/lib "${_r}/dist/script/docker/"
  cp -a /source/script/test/. "${_r}/script/test/"
  cp -a /source/script/watch "${_r}/script/"
  mkdir -p "${_r}/test/fixtures"
  cp -a /source/test/fixtures/gomod "${_r}/test/fixtures/"
  cat > "${_r}/script/test/config_gen_gates.sh" <<EOF
#!$(command -v bash)
n=\$(( \$(cat "${S}/runner.n" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "\${n}" > "${S}/runner.n"
printf '%s\n' "\$@" > "${S}/runner.\${n}.argv"
c="\${CONFIG_GEN_REDPATH_CASE:-unset}"
printf '%s\n' "\${c}" > "${S}/runner.\${n}.case"
k=\$(( \$(cat "${S}/calls.\${c}" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "\${k}" > "${S}/calls.\${c}"
root=""; prev=""
for a in "\$@"; do [[ "\${prev}" == --root ]] && root="\${a}"; prev="\${a}"; done
[[ -f "\${root}/dockerfile/Dockerfile.config-gen" ]] && echo tree >> "${S}/runner.trees"
printf '%s\n' "\${LOG_FORMAT:-unset}" >> "${S}/runner.formats"
printf '%s|%s\n' "\${LC_ALL-unset}" "\${LOCPATH-unset}" > "${S}/runner.\${n}.locale"
for p in script/watch/lib.sh dist/script/docker/lib/log.sh test/fixtures/gomod; do
  [[ -e "\${root}/\${p}" ]] && printf '%s\n' "\${p}" >> "${S}/runner.\${n}.copied"
done
printf 'ctx=%s base=%s\n' "\${CONFIG_GEN_MUTATION_CONTEXT-unset}" "\${CONFIG_GEN_MUTATION_BASE+set}" >> "${S}/runner.mutenv"
git -C "\${root}" rev-parse --verify -q 'refs/remotes/origin/main^{commit}' >> "${S}/runner.git" 2>/dev/null || echo nogit >> "${S}/runner.git"
[[ -d "\${root}/dockerfile/config-gen" ]] && cp -a "\${root}/dockerfile/config-gen" "${S}/runner.\${n}.mod"
[[ -d "\${root}/script/test/config_gen_steps" ]] && cp -a "\${root}/script/test/config_gen_steps" "${S}/runner.\${n}.steps"
a="${S}/canned/\${c}"
[[ -e "\${a}.\${k}.rc" ]] && a="\${a}.\${k}"
cat "\${a}.out" 2>/dev/null
cat "\${a}.err" >&2 2>/dev/null
exit "\$(cat "\${a}.rc" 2>/dev/null || echo 9)"
EOF
  chmod +x "${_r}/script/test/config_gen_gates.sh"
  # A just or docker reached from the redpath would be a nested run.
  printf '#!%s\necho "$0 $*" >> "%s/nested"\nexit 0\n' "$(command -v bash)" "${S}" > "${S}/bin/just"
  cp "${S}/bin/just" "${S}/bin/docker"
  chmod +x "${S}/bin/just" "${S}/bin/docker"
  # A fixed wall-clock `timeout N` around a redpath call expires under
  # parallel probes before the per-test bound the drivers scale does, and
  # test 18 went red with status 124 (base#1527). The per-test bound is the
  # only bound: a redpath call wrapped in a PATH `timeout`, whatever its
  # literal, answers as an expired timeout and says why.
  printf '#!%s\necho "timeout $*" >> "%s/bounded"\necho "a fixed timeout wrapped the redpath (base#1527): timeout $*" >&2\nexit 124\n' \
    "$(command -v bash)" "${S}" > "${S}/bin/timeout"
  chmod +x "${S}/bin/timeout"
  _canned_correct
}

# _gate_record <id> [attr=value...] -- the JSON log record the real runner
# writes on stderr for <id>, made by the real logger.
_gate_record() {
  LOG_FORMAT=json bash -c 'source "$1"; shift; _log_err config-gen "$@"' _ \
    /source/dist/script/docker/lib/log.sh "$@" 2>&1
}

# _ok_lines <gate> -- the ok lines of every gate before <gate> (all six
# when <gate> is empty), admission first.
_ok_lines() {
  local _g
  for _g in admission fmt vet lint race coverage; do
    [[ "${_g}" == "${1}" ]] && break
    printf 'gate=%s ok\n' "${_g}"
  done
}

# _canned_correct -- the runner answers each case as a correct build
# would: a gate case is every earlier gate ok, the build log line naming
# the case's gate, the runner's record of that gate id, rc 1; a refusal
# case (base#1465) is an empty stdout, the runner's record of its event and
# rc 1; a stale case is an empty stdout, the runner's records of
# config_gen_manifest_stale (the row's file and reason) and
# config_gen_gate_admission_failed, rc 1; a green case, both rerun calls
# and the control are the six ok lines and rc 0; a coverage case is the
# five pre-coverage ok lines, the runner's records of the row's event
# (naming the row's pkg, and its file when it has one) and
# config_gen_gate_coverage_failed, rc 1.
_canned_correct() {
  local _kind _case _want _file _reason _extra _c
  mkdir -p "${S}/canned"
  while IFS='|' read -r _kind _case _want _reason _extra; do
    _c="${S}/canned/${_case}"
    case "${_kind}" in
      gate)
        _ok_lines "${_want}" > "${_c}.out"
        printf '#9 0.31 config_gen_gate_%s_failed\n' "${_want}" > "${_c}.err"
        _gate_record "config_gen_gate_${_want}_failed" "gate=${_want}" status=1 \
          "display=config-gen gate ${_want} failed (docker exited 1)" >> "${_c}.err"
        ;;
      refusal)
        : > "${_c}.out"
        # Made from a registered id, so the logger writes a record and not
        # its unregistered-body notice; only the body is the refusal's.
        _gate_record config_gen_build_failed status=1 "display=refused" \
          | sed "s/\"body\":\"config_gen_build_failed\"/\"body\":\"${_want}\"/" > "${_c}.err"
        ;;
      stale)
        _file="${_want}"
        : > "${_c}.out"
        { _gate_record config_gen_manifest_stale "file=${_file}" "reason=${_reason}" status=1 "display=stale"
          _gate_record config_gen_gate_admission_failed gate=admission status=1 "display=admission"
        } > "${_c}.err"
        ;;
      green)
        _ok_lines "" > "${_c}.out"
        : > "${_c}.err"
        printf '0\n' > "${_c}.rc"
        continue
        ;;
      coverage)
        _ok_lines coverage > "${_c}.out"
        { _gate_record "${_want}" "pkg=${_reason}" ${_extra:+"file=${_extra}"} status=1 "display=coverage event"
          _gate_record config_gen_gate_coverage_failed gate=coverage status=1 "display=coverage"
        } > "${_c}.err"
        ;;
    esac
    printf '1\n' > "${_c}.rc"
  done < <(_redpath_rows)
  for _c in rerun control; do
    _ok_lines "" > "${S}/canned/${_c}.out"
    : > "${S}/canned/${_c}.err"
    printf '0\n' > "${S}/canned/${_c}.rc"
  done
}

# _redpath_exec [VAR=value...] -- run the scratch redpath once, as bats
# `run --separate-stderr`, with the stubs first on PATH, LOG_FORMAT=json,
# no inherited CONFIG_GEN_REDPATH_ACTIVE or CONFIG_GEN_REDPATH_ONLY, and the
# given VAR=value words on top. Every redpath call in this spec goes through
# here, and none carries its own `timeout N`: the bats per-test bound, which
# every driver scales, is the only bound, and a fixed literal inside it
# expired first under parallel probes (base#1527). The `timeout` stub in
# _redpath_repo turns any such wrapper red.
_redpath_exec() {
  run --separate-stderr env -u CONFIG_GEN_REDPATH_ACTIVE -u CONFIG_GEN_REDPATH_ONLY \
      PATH="${S}/bin:${PATH}" LOG_FORMAT=json "$@" \
      bash "${S}/repo/script/test/config_gen_redpath.sh"
}

# _run_redpath [VAR=value...] <case>... -- the scratch redpath run on only
# the named cases (CONFIG_GEN_REDPATH_ONLY) and the control, then held to
# exactly that: the runner was told each named case once (rerun twice) and
# the control, and nothing else. A whole redpath per test overran the
# per-test bound under parallel mutation probes; `just test go` and the one
# full run below keep every case (base#1465). Leading VAR=value words go to
# the redpath's environment. RERUN_CALLS (default 2) is how many rerun
# calls the test expects: 1 when its first call is the one that fails.
_run_redpath() {
  local -a _env=()
  while [[ "${1:-}" =~ ^[A-Z_]+= ]]; do _env+=("${1}"); shift; done
  (( $# > 0 )) || fail "_run_redpath: name the case(s) this test asserts"
  _redpath_exec "${_env[@]}" CONFIG_GEN_REDPATH_ONLY="$*"
  local _want _got
  _want="$( { printf '%s\n' "$@" control; [[ " $* " == *" rerun "* && "${RERUN_CALLS:-2}" == 2 ]] && echo rerun; } | LC_ALL=C sort)"
  _got="$(_ran_cases | LC_ALL=C sort)"
  [[ "${_got}" == "${_want}" ]] \
    || fail "_run_redpath $*: the runner was told $(paste -sd' ' <<<"${_got}"), not $(paste -sd' ' <<<"${_want}")"
}

# _run_redpath_all [VAR=value...] -- the scratch redpath on every case, as
# `just test go` runs it, bounded only by the per-test bound (base#1527).
_run_redpath_all() {
  _redpath_exec "$@"
}

# _case_failures -- every config_gen_redpath_case_failed record in
# ${stderr} as `<case>|<reason>`, one per line.
_case_failures() {
  jq -rR 'fromjson? | select(.body == "config_gen_redpath_case_failed")
    | .attributes.case + "|" + .attributes.reason' <<<"${stderr}"
}

# why: Sourced, the redpath only defines its tables and functions (the case
# tables are read that way); a caller that sources it must not come back
# with nounset or errexit turned on, the #869 contract (base#1465).
@test "config_gen_redpath.sh: sourced, it leaves its caller's nounset, errexit and pipefail as they were (base#1465)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  run bash -c 'source "$1"
    case $- in *u*) printf "nounset " ;; esac
    case $- in *e*) printf "errexit " ;; esac
    case :${SHELLOPTS}: in *:pipefail:*) printf "pipefail " ;; esac
    printf "END\n"' _ "${REDPATH}"
  assert_success
  assert_output END
}

# One case of each kind, the rerun among them: what a copy-level property
# (each scratch root's contents, its git state, its environment) is checked
# on. Every kind reaches the runner through the same _rp_copy and
# _rp_gates.
_ONE_PER_KIND='vet no-context stale-edit rename-move cov-lowered rerun'

# why: The redpath proves each gate CAN fail; calling `just test go` from it
# would recurse into itself, and reusing one scratch tree would let one
# case's defect leak into the next. The control proves the reds come from
# the defects and not from the copy. Each call is told its case. The case
# list is this spec's own, so a case dropped from the redpath's tables is
# a missing call here, and the canned answers (built from this spec's
# wants) pass only when the redpath judges each case by the same want
# (base#1465).
@test "config_gen_redpath.sh: runs the runner once per case and once for the control, each on its own copy (base#1462)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  _redpath_repo
  _run_redpath_all
  assert_success
  assert_equal "$(_ran_cases)" "$(_redpath_sequence)"
  assert_equal "$(grep -c . "${S}/runner.trees")" "$(_redpath_sequence | grep -c .)"
  local _roots
  _roots="$(for _f in "${S}"/runner.*.argv; do awk 'p == "--root" {print} {p=$0}' "${_f}"; done)"
  # The two rerun calls share one copy; every other call has its own.
  assert_equal "$(sort -u <<<"${_roots}" | grep -c .)" "$(( $(_redpath_sequence | grep -c .) - 1 ))"
  run grep -Fx "${S}/repo" <<<"${_roots}"
  assert_failure
  [[ ! -s "${S}/nested" ]] || fail "the redpath reached just or docker itself: $(cat "${S}/nested")"
}

# why: Each redpath test runs only the cases it asserts, so the spec stays
# inside the per-test bound under parallel mutation probes (base#1465).
# CONFIG_GEN_REDPATH_ONLY is what scopes a run: the named cases in the
# redpath's own order, whatever order they are named in, then the control,
# and no other call.
@test "config_gen_redpath.sh: CONFIG_GEN_REDPATH_ONLY runs only the named cases, in run order, then the control (base#1465)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  _redpath_repo
  _redpath_exec CONFIG_GEN_REDPATH_ONLY='rerun cov-lowered stale-edit lint'
  assert_success
  assert_equal "$(_ran_cases | paste -sd' ')" 'lint stale-edit cov-lowered rerun rerun control'
}

# why: The runner's attribute filter matched no file= or reason= word
# under en_US.UTF-8 on a glibc host until _cg_attr_ok pinned LC_ALL=C
# (base#1465); a host whose own locale is C never runs that filter under
# any other. stale-edit-locale is the case that does: its runner call, and
# only its, runs under LC_ALL=en_US.UTF-8 whatever the redpath inherited.
# The test-tools image is musl, the one libc let through on the name as it
# is, so it goes through with no LOCPATH.
@test "config_gen_redpath.sh: stale-edit-locale runs the runner under LC_ALL=en_US.UTF-8, stale-edit under the caller's locale (base#1465)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  _redpath_repo
  _run_redpath LC_ALL=C stale-edit stale-edit-locale
  assert_success
  local _n _got=""
  for (( _n = 1; _n <= $(cat "${S}/runner.n"); _n++ )); do
    _got+="$(cat "${S}/runner.${_n}.case") $(cat "${S}/runner.${_n}.locale")"$'\n'
  done
  assert_equal "${_got%$'\n'}" "stale-edit C|unset
stale-edit-locale en_US.UTF-8|unset
control C|unset"
}

# _glibc_getconf -- put a getconf on ${S}/bin that answers
# GNU_LIBC_VERSION as glibc 2.35 does and hands every other query to the
# real one, so the redpath takes this host for glibc (base#1465).
_glibc_getconf() {
  local real
  real="$(command -v getconf || echo false)"
  printf '#!%s\n[[ "${1:-}" == GNU_LIBC_VERSION ]] && { echo "glibc 2.35"; exit 0; }\nexec %s "$@"\n' \
    "$(command -v bash)" "${real}" > "${S}/bin/getconf"
  chmod +x "${S}/bin/getconf"
}

# why: A localedef that yields no en_US.UTF-8 in which [!-~] drops the
# word leaves the case with a locale that proves nothing; it must fail as
# locale_not_affected, before any runner call, not pass on the C behaviour
# it falls back to (base#1465). In the musl test-tools image bash matches
# the word under every locale, so a glibc getconf and a stub localedef
# that writes nothing are that host.
@test "config_gen_redpath.sh: stale-edit-locale fails as locale_not_affected when localedef makes no locale that drops the word (base#1465)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  _redpath_repo
  _glibc_getconf
  printf '#!%s\nexit 0\n' "$(command -v bash)" > "${S}/bin/localedef"
  chmod +x "${S}/bin/localedef"
  _redpath_exec CONFIG_GEN_REDPATH_ONLY='stale-edit-locale'
  assert_failure 1
  assert_equal "$(_case_failures)" "stale-edit-locale|locale_not_affected"
  assert_equal "$(_ran_cases | paste -sd' ')" control
}

# why: A glibc host with no localedef and no en_US.UTF-8 installed falls
# back to C behaviour under LC_ALL=en_US.UTF-8, so the case would pass with
# _cg_attr_ok's LC_ALL=C taken out and prove nothing (base#1465, review
# round 2). A missing localedef is no reason to run the case: only a musl
# libc is let through under the name as it is. The musl test-tools image
# has no localedef; a glibc getconf makes it that glibc host.
@test "config_gen_redpath.sh: stale-edit-locale fails as locale_not_affected on a glibc host with no localedef and no affected locale (base#1465)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  _redpath_repo
  _glibc_getconf
  assert_equal "$(PATH="${S}/bin:${PATH}" command -v localedef || echo none)" none
  _redpath_exec CONFIG_GEN_REDPATH_ONLY='stale-edit-locale'
  assert_failure 1
  assert_equal "$(_case_failures)" "stale-edit-locale|locale_not_affected"
  assert_equal "$(_ran_cases | paste -sd' ')" control
}

# why: The go.mod oracle step (base#1463) runs the scanner from
# script/watch with the logger from dist/script/docker/lib over
# test/fixtures/gomod, all relative to its own root; a scratch copy without
# them turns every redpath case red on the step instead of on its gate.
@test "config_gen_redpath.sh: each scratch root carries script/watch, the log library and the go.mod fixtures (base#1463)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  _redpath_repo
  # shellcheck disable=SC2086 # one word per case
  _run_redpath ${_ONE_PER_KIND}
  assert_success
  local _n _want
  _want="$(printf '%s\n' script/watch/lib.sh dist/script/docker/lib/log.sh test/fixtures/gomod)"
  for (( _n = 1; _n <= $(cat "${S}/runner.n"); _n++ )); do
    assert_equal "${_n}:$(cat "${S}/runner.${_n}.copied" 2>/dev/null)" "${_n}:${_want}"
  done
}

# why: The redpath's copies run the real steps, and the 00-manifest step
# (base#1464) reads Git history: each copy must be a Git checkout with
# origin/main, and must run with context pr and no override whatever the
# caller inherited -- a CI main push exports main-push, and HEAD^1 does not
# exist in a one-commit copy.
@test "config_gen_redpath.sh: every copy is a Git checkout run with context pr and no base override (base#1464)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  _redpath_repo
  # shellcheck disable=SC2086 # one word per case
  _run_redpath CONFIG_GEN_MUTATION_CONTEXT=main-push CONFIG_GEN_MUTATION_BASE=deadbeef ${_ONE_PER_KIND}
  assert_success
  local _calls
  _calls="$(cat "${S}/runner.n")"
  assert_equal "$(grep -c . "${S}/runner.mutenv")" "${_calls}"
  assert_equal "$(grep -cvx 'ctx=pr base=' "${S}/runner.mutenv")" 0
  assert_equal "$(grep -c . "${S}/runner.git")" "${_calls}"
  assert_equal "$(grep -cEx '[0-9a-f]{40}' "${S}/runner.git")" "${_calls}"
}

# why: A gate that never goes red is indistinguishable from a working one on
# a clean tree; each verdict below is a way a broken gate would otherwise
# pass the redpath. Every case is reported before the run fails.
@test "config_gen_redpath.sh: a case whose runner exited 0 fails with reason rc_zero, and the rest still run (base#1462)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  _redpath_repo
  printf '0\n' > "${S}/canned/vet.rc"
  # lint runs after vet; _run_redpath fails the test unless it still ran.
  _run_redpath vet lint
  assert_equal "${status}" 1
  assert_logged_event config_gen_redpath_case_failed case=vet reason=rc_zero gate=vet
}

# why: A red gate's build ends the way every refusal does, exit 1; a runner
# that crashed with another status after logging the gate's id is not a gate
# that went red, and must not pass the redpath (base#1465).
@test "config_gen_redpath.sh: a gate case whose runner exited other than 1 fails with reason rc_not_one (base#1465)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  local _rc
  for _rc in 2 42; do
    rm -rf "${S}/repo" "${S}/canned" "${S}"/runner.* "${S}"/calls.* "${S}/nested"
    _redpath_repo
    printf '%s\n' "${_rc}" > "${S}/canned/vet.rc"
    _run_redpath vet
    assert_equal "${_rc}:${status}" "${_rc}:1"
    assert_equal "${_rc}:$(_case_failures)" "${_rc}:vet|rc_not_one"
  done
}

# why: A verdict RUN the build cache served prints no line, so a runner
# that excluded only `test` (or only `admit`) from the cache passes its
# first call and reports cache state on the next. The rerun case calls the
# runner twice on one unchanged copy and holds each call to the six ok
# lines exactly (base#1465).
@test "config_gen_redpath.sh: a second rerun call missing the admission line fails with reason stdout_mismatch (base#1465)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  _redpath_repo
  printf 'gate=%s ok\n' fmt vet lint race coverage > "${S}/canned/rerun.2.out"
  cp "${S}/canned/rerun.err" "${S}/canned/rerun.2.err"
  cp "${S}/canned/rerun.rc" "${S}/canned/rerun.2.rc"
  _run_redpath rerun
  assert_equal "${status}" 1
  assert_logged_event config_gen_redpath_case_failed case=rerun call=2 reason=stdout_mismatch
}

# why: A refusal or stale case passes only on the runner's own records of
# the refusal, after a run that ended the way every refusal must. Each row
# breaks exactly one part of a correct answer, and each part is a separate
# guard that would otherwise let a build that never refused (or that ran go
# on the unchecked snapshot first) pass the redpath (base#1465).
@test "config_gen_redpath.sh: a refusal, stale or rerun answer missing any part of its contract fails with that part's reason (base#1465)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  local _row _reason _case _st="${S}/canned/stale-edit"
  for _row in rc0 rc2 stdout unregistered goparse gostep nogate nostale detail ctxwrong rerunrc; do
    rm -rf "${S}/repo" "${S}/canned" "${S}"/runner.* "${S}"/calls.* "${S}/nested"
    _redpath_repo
    _case=stale-edit
    case "${_row}" in
      rc0) printf '0\n' > "${_st}.rc"; _reason=rc_zero ;;
      rc2) printf '2\n' > "${_st}.rc"; _reason=rc_not_one ;;
      stdout) printf 'gate=admission ok\n' > "${_st}.out"; _reason=stdout_not_empty ;;
      unregistered) printf 'FATAL: unregistered log body "x"\n' >> "${_st}.err"; _reason=unregistered_body ;;
      goparse) printf 'go: errors parsing go.mod:\n' >> "${_st}.err"; _reason=go_ran_before_admission ;;
      gostep) printf '#11 [test 5/9] RUN --mount=type=cache,target=/root/.cache/go-build     g=vet; go vet ./... || exit 1\n' \
          >> "${_st}.err"; _reason=go_ran_before_admission ;;
      nogate) sed -i '/"body":"config_gen_gate_admission_failed"/d' "${_st}.err"; _reason=gate_record_missing ;;
      nostale) sed -i '/"body":"config_gen_manifest_stale"/d' "${_st}.err"; _reason=stale_record_missing ;;
      detail) sed -i 's/"reason":"sha_mismatch"/"reason":"missing"/' "${_st}.err"; _reason=stale_detail_mismatch ;;
      ctxwrong) sed -i 's/"body":"config_gen_manifest_missing"/"body":"config_gen_build_failed"/' "${S}/canned/no-context.err"
        _case=no-context _reason=wrong_id ;;
      rerunrc) printf '1\n' > "${S}/canned/rerun.rc"; _case=rerun _reason=rc_not_zero ;;
    esac
    # A failing first rerun call ends the case before a second.
    RERUN_CALLS=1 _run_redpath "${_case}"
    assert_equal "${_row}:${status}" "${_row}:1"
    # Read with jq, not assert_logged_event: the unregistered row's planted
    # notice is streamed back with the case's log, which that helper refuses.
    assert_equal "${_row}:$(_case_failures)" "${_row}:${_case}|${_reason}"
  done
}

# why: A green case proves admission accepts a baseline the producer
# writes and every gate still runs after it; a call that exits non-zero,
# or that prints anything but the six ok lines, is a producer output
# admission refused or a gate that did not run (base#1465).
@test "config_gen_redpath.sh: a green case that exits non-zero or prints other than the six ok lines fails by reason (base#1465)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  local _row _reason
  for _row in rc stdout; do
    rm -rf "${S}/repo" "${S}/canned" "${S}"/runner.* "${S}"/calls.* "${S}/nested"
    _redpath_repo
    case "${_row}" in
      rc) printf '1\n' > "${S}/canned/rename-move.rc"; _reason=rc_not_zero ;;
      stdout) _ok_lines coverage > "${S}/canned/rename-move.out"; _reason=stdout_mismatch ;;
    esac
    _run_redpath rename-move
    assert_equal "${_row}:${status}" "${_row}:1"
    assert_equal "${_row}:$(_case_failures)" "${_row}:rename-move|${_reason}"
  done
}

# why: A coverage case passes only when the ratchet refused it: after
# exactly the five earlier gates, exiting exactly 1 like every refusal,
# with the coverage gate's record and the row's own event record naming the
# row's package (and file). Each row breaks one part, which would otherwise
# let a runner that crashed with another status, a ratchet that never fired,
# or one that fired the rule on another package or fragment pass (base#1465).
@test "config_gen_redpath.sh: a coverage case missing any part of its contract fails with that part's reason (base#1465)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  local _row _reason _case _c
  for _row in rc0 rc2 rc42 stdout unregistered gate event pkg nopkg file; do
    rm -rf "${S}/repo" "${S}/canned" "${S}"/runner.* "${S}"/calls.* "${S}/nested"
    _redpath_repo
    _case=cov-lowered _c="${S}/canned/cov-lowered"
    case "${_row}" in
      rc0) printf '0\n' > "${_c}.rc"; _reason=rc_zero ;;
      rc2) printf '2\n' > "${_c}.rc"; _reason=rc_not_one ;;
      rc42) printf '42\n' > "${_c}.rc"; _reason=rc_not_one ;;
      stdout) _ok_lines "" > "${_c}.out"; _reason=stdout_mismatch ;;
      unregistered) printf 'FATAL: unregistered log body "x"\n' >> "${_c}.err"; _reason=unregistered_body ;;
      gate) sed -i 's/"body":"config_gen_gate_coverage_failed"/"body":"config_gen_gate_race_failed"/' "${_c}.err"; _reason=wrong_id ;;
      event) sed -i 's/"body":"config_gen_coverage_floor_lowered"/"body":"config_gen_coverage_floor_stale"/' "${_c}.err"
        _reason=event_record_missing ;;
      pkg) sed -i '/"body":"config_gen_coverage_floor_lowered"/s#"pkg":"[^"]*"#"pkg":"internal/zz"#' "${_c}.err"
        _reason=event_detail_mismatch ;;
      nopkg) sed -i '/"body":"config_gen_coverage_floor_lowered"/s#"pkg":"[^"]*",##' "${_c}.err"
        _reason=event_detail_mismatch ;;
      file) _case=cov-duplicate _c="${S}/canned/cov-duplicate"
        sed -i '/"body":"config_gen_coverage_floor_duplicate"/s#"file":"[^"]*"#"file":"s1z.txt"#' "${_c}.err"
        _reason=event_detail_mismatch ;;
    esac
    # The planted change must have reached the canned event record.
    case "${_row}" in
      pkg) assert grep -q '"body":"config_gen_coverage_floor_lowered".*"pkg":"internal/zz"' "${_c}.err" ;;
      nopkg) refute grep -q '"body":"config_gen_coverage_floor_lowered".*"pkg"' "${_c}.err" ;;
      file) assert grep -q '"body":"config_gen_coverage_floor_duplicate".*"file":"s1z.txt"' "${_c}.err" ;;
    esac
    _run_redpath "${_case}"
    assert_equal "${_row}:${status}" "${_row}:1"
    assert_equal "${_row}:$(_case_failures)" "${_row}:${_case}|${_reason}"
  done
}

# why: A stale case's change must happen after 00-manifest wrote the
# baseline and 01-admit installed the checker, or the baseline already
# holds it and admission has nothing to refuse; a green case's change must
# reach 00-manifest as the git state it names. The steps and module each
# call ran with are what the real build would see (base#1465).
@test "config_gen_redpath.sh: a stale case changes the copy in a step after every real one, and a green case reaches the runner as its git state (base#1465)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  _redpath_repo
  _run_redpath stale-edit rename-move
  assert_success
  local _n _steps
  _n="$(_redpath_call stale-edit)"
  # The runner runs config_gen_steps/*.sh in C-locale glob order.
  _steps="$(cd "${S}/runner.${_n}.steps" && printf '%s\n' *.sh | LC_ALL=C sort | tail -n 1)"
  assert_equal "${_steps}" 99-zz-stale-edit.sh
  # The module the runner got is the unchanged one: the step edits it.
  run diff -r "${S}/runner.${_n}.mod" "${S}/repo/dockerfile/config-gen"
  assert_success
  _n="$(_redpath_call rename-move)"
  [[ -f "${S}/runner.${_n}.mod/zzg/a.txt" && -f "${S}/runner.${_n}.mod/zzg/d.txt" ]] \
    || fail "rename-move did not leave zzg/a.txt and zzg/d.txt"
  [[ ! -e "${S}/runner.${_n}.mod/zzg/c.txt" ]] || fail "rename-move left zzg/c.txt"
  assert_equal "$(cat "${S}/runner.${_n}.mod/zzg/a.txt")" c
}

@test "config_gen_redpath.sh: a case that went red on another gate's id fails with reason wrong_id (base#1462)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  _redpath_repo
  _gate_record config_gen_gate_vet_failed gate=vet status=1 display=vet > "${S}/canned/lint.err"
  _run_redpath lint
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
  printf 'unrelated: config_gen_gate_fmt_failed_extra\n#9 0.31 config_gen_gate_fmt_failed\n' > "${S}/canned/fmt.err"
  printf 'unrelated: config_gen_gate_vet_failed\n' > "${S}/canned/vet.err"
  _run_redpath fmt vet
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
    | sed 's/"body":"config_gen_gate_fmt_failed"/"body":"config_gen_gate_fmt_failed_extra"/' > "${S}/canned/fmt.err"
  grep -qF '"body":"config_gen_gate_fmt_failed_extra"' "${S}/canned/fmt.err" || fail "fixture: no suffixed body"
  _gate_record config_gen_build_failed status=1 "display=not config_gen_gate_vet_failed" > "${S}/canned/vet.err"
  _run_redpath fmt vet
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
  # shellcheck disable=SC2086 # one word per case
  _run_redpath LOG_FORMAT=text ${_ONE_PER_KIND}
  assert_success
  assert_equal "$(sort -u "${S}/runner.formats")" json
}

@test "config_gen_redpath.sh: a case whose earlier gate printed no ok fails with reason earlier_gate_missing (base#1462)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  _redpath_repo
  printf 'gate=admission ok\ngate=fmt ok\ngate=vet ok\n' > "${S}/canned/race.out"
  _run_redpath race
  assert_equal "${status}" 1
  assert_logged_event config_gen_redpath_case_failed case=race reason=earlier_gate_missing gate=race
}

@test "config_gen_redpath.sh: the race-fuzz case must produce the race gate's id (base#1462)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  _redpath_repo
  _gate_record config_gen_gate_coverage_failed gate=coverage status=1 display=coverage > "${S}/canned/race-fuzz.err"
  _run_redpath race-fuzz
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
  _run_redpath fmt-parse
  assert_success
  local _mod _new
  _mod="${S}/runner.$(_redpath_call fmt-parse).mod"
  _new="$(cd "${_mod}" && find . -type f | sort | comm -23 - <(cd /source/dockerfile/config-gen && find . -type f | sort))"
  assert_equal "${_new}" "./cmd/config-gen/zz_parse_test.go"
  # Unbalanced braces: no Go parser accepts the file.
  local _open _close
  _open="$(tr -cd '{' < "${_mod}/cmd/config-gen/zz_parse_test.go" | wc -c)"
  _close="$(tr -cd '}' < "${_mod}/cmd/config-gen/zz_parse_test.go" | wc -c)"
  (( _open != _close )) || fail "zz_parse_test.go balances its braces: $(cat "${_mod}/cmd/config-gen/zz_parse_test.go")"
  # A build-failure record in place of the fmt id fails the case.
  rm -rf "${S}"/runner.* "${S}"/calls.*
  _gate_record config_gen_build_failed status=1 display=build > "${S}/canned/fmt-parse.err"
  _run_redpath fmt-parse
  assert_equal "${status}" 1
  assert_logged_event config_gen_redpath_case_failed case=fmt-parse reason=wrong_id gate=fmt
}

# why: ADR-00000039 requires GOTOOLCHAIN=local so every gate runs the
# pinned toolchain or fails, never one go fetches for a newer go.mod. The
# golang image pinned today sets it itself, but a GO_IMAGE override or bump
# need not. admit, build and test are FROM goenv, so one ENV in goenv,
# ahead of its first RUN, covers every go command in all three (base#1462,
# base#1465).
@test "Dockerfile.config-gen: the goenv stage sets GOTOOLCHAIN=local before its first RUN, and nothing overrides it (base#1462)" {
  assert_spec_subject "${DOCKERFILE}" "the config generator's build/test/final Dockerfile (base#1462)"
  _df_instructions > "${S}/df"
  run awk -F'\t' '$1 == "goenv" && $2 ~ /^(ENV|RUN) / {print $2; exit}' "${S}/df"
  assert_success
  assert_output 'ENV GOTOOLCHAIN=local'
  run awk -F'\t' '/GOTOOLCHAIN/ && $2 != "ENV GOTOOLCHAIN=local" {print}' "${S}/df"
  assert_success
  assert_output ""
  run awk -F'\t' '$2 ~ /^FROM / {print $2}' "${S}/df"
  assert_line --regexp '^FROM goenv (AS|as) admit$'
  assert_line --regexp '^FROM goenv (AS|as) build$'
  assert_line --regexp '^FROM goenv (AS|as) test$'
}

# _admit_run <setup> -- run the admit stage's RUN as the build would,
# outside a build: the RUN text is taken from the Dockerfile (its flags
# parsed, not assumed), every bind --mount target and the file the test
# stage copies from admit are moved under ${S}/adm, and the body runs under
# the goenv SHELL with the module bind as its working directory; stdout,
# stderr and status as `run --separate-stderr` leaves them, and the moved
# admitted file in ${ADMITTED}. <setup> fills the mutation bind: sentinel
# (the placeholder's file beside a passing checker), none (empty), dir
# (admit.sh a directory), fail (a checker that prints a stale line and
# exits 1), pass (a checker that records its arguments and exits 0).
_admit_run() {
  local _a="${S}/adm" _run _body _word _t _copy _from _to
  rm -rf "${_a}"
  mkdir -p "${_a}/mutation" "${_a}/src" "${_a}/root"
  _df_instructions > "${S}/df"
  _run="$(awk -F'\t' '$1 == "admit" && $2 ~ /^RUN / {print $2}' "${S}/df")"
  [[ -n "${_run}" && "$(grep -c . <<<"${_run}")" == 1 ]] || fail "admit has not exactly one RUN: ${_run}"
  _body="${_run#RUN }"
  local -a _targets=()
  while [[ "${_body}" =~ ^[[:space:]]*(--[^[:space:]]+)[[:space:]]+(.*)$ ]]; do
    _word="${BASH_REMATCH[1]}" _body="${BASH_REMATCH[2]}"
    [[ "${_word}" == --mount=* && ",${_word#--mount=}," == *,type=bind,* ]] \
      || fail "an admit RUN flag is not a bind mount: ${_word}"
    _targets+=("$(tr ',' '\n' <<<"${_word#--mount=}" | sed -n 's/^target=//p')")
  done
  _copy="$(awk -F'\t' '$1 == "test" && $2 ~ /^COPY --from=admit / {print $2}' "${S}/df")"
  _from="${_copy#COPY --from=admit }"
  _from="${_from%% *}"
  [[ "${_from}" == /* ]] || fail "the test stage copies no absolute path from admit: ${_copy}"
  for _t in "${_targets[@]}" "${_from}"; do
    case "${_t}" in
      /mutation) _to="${_a}/mutation" ;;
      /src) _to="${_a}/src" ;;
      *) _to="${_a}/root${_t}" ;;
    esac
    _body="$(sed -E "s#${_t}([/ ;]|\$)#${_to}\\1#g" <<<"${_body}")"
  done
  ADMITTED="${_a}/root${_from}"
  printf 'package main\n' > "${_a}/src/main.go"
  local _m="${_a}/mutation"
  case "${1}" in
    sentinel) : > "${_m}/no-mutation-context"
      printf 'exit 0\n' > "${_m}/admit.sh" ;;
    none) ;;
    dir) mkdir "${_m}/admit.sh" ;;
    fail) printf 'echo "cg_event config_gen_manifest_stale file=x reason=missing"\nexit 1\n' > "${_m}/admit.sh" ;;
    pass) printf 'printf "%%s\\n" "$@" > "%s/args"\nexit 0\n' "${_a}" > "${_m}/admit.sh" ;;
  esac
  # The goenv SHELL's -euo pipefail is set inside _w, not on the bash
  # command line: under `just test coverage-path` a top-level
  # `bash -euo pipefail -c` printed "BASH_SOURCE: unbound variable" to
  # stderr before the RUN text ran (the same shape as the manifest
  # writer test in config_gen_mutation_targets_spec).
  run --separate-stderr bash -c \
    'cd "$1" && _w() { set -euo pipefail; eval "$2"; }; _w "$@"' _ "${_a}/src" "${_body}"
}

# why: The admit RUN is the build's admission barrier, reached only through
# a real build, which no bats tier runs; each of its guards is a
# required-kill row (base#1465), so each needs a test that runs the RUN's
# own text and dies with the guard. Each row breaks one guard: the sentinel
# refused before the checker runs, an absent or non-file checker refused as
# stale admit.sh, a red checker stopping the RUN with the gate's id and no
# ok line, and a green checker, run on the context and the module, leaving
# the ok line and the file the test stage copies.
@test "Dockerfile.config-gen: the admit RUN refuses the sentinel, an absent or non-file checker and a red checker, and admits a green one (base#1465)" {
  assert_spec_subject "${DOCKERFILE}" "the config generator's build/test/final Dockerfile (base#1462)"
  _admit_run sentinel
  assert_equal "sentinel:${status}" sentinel:1
  assert_equal "sentinel:${output}" sentinel:
  assert_equal "sentinel:${stderr}" "sentinel:cg_event config_gen_manifest_missing"
  [[ ! -e "${ADMITTED}" ]] || fail "sentinel: admitted"
  local _setup
  for _setup in none dir; do
    _admit_run "${_setup}"
    assert_equal "${_setup}:${status}" "${_setup}:1"
    assert_equal "${_setup}:${output}" "${_setup}:cg_event config_gen_manifest_stale file=admit.sh reason=absent"
    assert_equal "${_setup}:${stderr}" "${_setup}:config_gen_gate_admission_failed"
    [[ ! -e "${ADMITTED}" ]] || fail "${_setup}: admitted"
  done
  _admit_run fail
  assert_equal "fail:${status}" fail:1
  assert_equal "fail:${output}" "fail:cg_event config_gen_manifest_stale file=x reason=missing"
  assert_equal "fail:${stderr}" "fail:config_gen_gate_admission_failed"
  [[ ! -e "${ADMITTED}" ]] || fail "fail: admitted"
  _admit_run pass
  assert_equal "pass:${status}" pass:0
  assert_equal "pass:${output}" "pass:gate=admission ok"
  assert_equal "pass:${stderr}" pass:
  [[ -f "${ADMITTED}" ]] || fail "pass: ${ADMITTED} not written"
  assert_equal "$(cat "${S}/adm/args")" "$(printf '%s\n' "${S}/adm/mutation" "${S}/adm/src")"
}

# why: A control whose runner exited non-zero means the copy itself is red,
# so no case's red can be attributed to its defect.
@test "config_gen_redpath.sh: a red control fails the run with the control's status (base#1462)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  _redpath_repo
  printf '1\n' > "${S}/canned/control.rc"
  _run_redpath vet
  assert_equal "${status}" 1
  assert_logged_event config_gen_redpath_control_failed status=1
}

# why: `just test go` runs the redpath, and the redpath runs the runner; a
# redpath that reached `just test go` again would recurse without bound. The
# guard refuses a nested entry and runs nothing.
@test "config_gen_redpath.sh: a nested entry is refused with config_gen_redpath_reentered and runs nothing (base#1462)" {
  assert_spec_subject "${REDPATH}" "the config-gen redpath (base#1462)"
  _redpath_repo
  _redpath_exec CONFIG_GEN_REDPATH_ACTIVE=1
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
  printf '#!%s\necho "redpath only=${CONFIG_GEN_REDPATH_ONLY-unset}" >> "%s/order"\nexit 0\n' "$(command -v bash)" "${S}" \
    > "${_r}/script/test/config_gen_redpath.sh"
  chmod +x "${_r}/script/test/"config_gen_*.sh
}

# why: The one command all four environments run. The order matters: the
# redpath on a tree whose gates are already red proves nothing, and `;`
# would run it after a red runner and report the redpath's status instead.
# The redpath it runs is the whole one: a CONFIG_GEN_REDPATH_ONLY left in
# the caller's environment does not reach it (base#1465).
@test "just test go: runs the runner, then the redpath, and stops at a red runner (base#1462)" {
  _recipe_repo 0
  run env CONFIG_GEN_REDPATH_ONLY=vet bash -c "cd '${S}/j' && just test go"
  assert_success
  assert_equal "$(paste -sd' ' "${S}/order")" "gates redpath only=unset"
  rm -f "${S}/order"
  _recipe_repo 1
  run bash -c "cd '${S}/j' && just test go"
  assert_failure
  assert_equal "$(paste -sd' ' "${S}/order")" "gates"
}
