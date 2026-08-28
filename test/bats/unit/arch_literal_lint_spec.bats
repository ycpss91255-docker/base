#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/arch_literal.sh -- the "no bare
# architecture literal in a shipped Dockerfile" lint.
#
# buildx builds one Dockerfile once per `--platform` and injects TARGETARCH
# into any stage that declares `ARG TARGETARCH`. A stage that instead writes
# the architecture into a string produces the SAME artifact for every
# platform, so an amd64 binary lands inside the arm64 image and only fails at
# run time. The literal is the defect; TARGETARCH is the expression.
#
# The lint cannot simply refuse every architecture token, because the
# CORRECT implementation of the rule contains two spellings by construction:
# TARGETARCH speaks Docker's ("amd64" / "arm64") and upstream release assets
# speak their own ("linux.x86_64" / "Linux-arm64"), so a `case` mapping the
# one onto the other is exactly what the lint asks for. That mapping opts out
# explicitly, with a stated reason -- a lint that fires on the correct answer
# is a lint that gets muted.
#
# Detection runs against a controlled temp REPO_ROOT so the spec is
# independent of the live tree's contents; a final case drives the REAL
# shipped Dockerfiles to prove they pass today. Shape mirrors
# home_literal_lint_spec.bats.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the function runs against a controlled scratch tree.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/arch_literal.sh

  SCRATCH="$(mktemp -d)"
  REPO_ROOT="${SCRATCH}"

  # Every scan root must hold at least one Dockerfile or the lint refuses to
  # pass vacuously, so seed both roots clean. Individual cases overwrite the
  # file they are about.
  _write "dist/dockerfile/Dockerfile" 'FROM ubuntu:24.04 AS sys'
  _write "dockerfile/Dockerfile.test-tools" 'FROM alpine:3.21'
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _write <relative-path> <line>... -- create a shipped-tree fixture file.
_write() {
  local _rel="${1}"; shift
  mkdir -p "$(dirname "${SCRATCH}/${_rel}")"
  printf '%s\n' "$@" > "${SCRATCH}/${_rel}"
}

# ════════════════════════════════════════════════════════════════════
# _run_arch_literal: violations
# ════════════════════════════════════════════════════════════════════

@test "_run_arch_literal: FAILS on a bare Docker architecture literal, naming file and line (#939)" {
  _write "dist/dockerfile/Dockerfile" \
    'FROM ubuntu:24.04' \
    'RUN curl -fsSL "https://example.invalid/tool-linux-amd64" -o /usr/local/bin/tool'
  run _run_arch_literal
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/dockerfile/Dockerfile:2"* ]]
}

@test "_run_arch_literal: FAILS on the uname spelling of the same assumption (#939)" {
  # x86_64 / aarch64 are the same leaked assumption wearing another spelling;
  # a lint that knew only Docker's two words would miss the commonest form.
  _write "dist/dockerfile/Dockerfile" \
    'FROM ubuntu:24.04' \
    'RUN curl -fsSL "https://example.invalid/tool.linux.x86_64.tar.xz" | tar -xJ'
  run _run_arch_literal
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/dockerfile/Dockerfile:2"* ]]
}

@test "_run_arch_literal: FAILS on a mixed-case release-asset spelling (#939)" {
  # hadolint publishes Linux-x86_64 / Linux-arm64; the capital is not a
  # different rule.
  _write "dist/dockerfile/Dockerfile" \
    'FROM ubuntu:24.04' \
    'RUN curl -fsSL -o /usr/local/bin/hadolint "https://example.invalid/hadolint-Linux-arm64"'
  run _run_arch_literal
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/dockerfile/Dockerfile:2"* ]]
}

@test "_run_arch_literal: FAILS on a platform pair literal (#939)" {
  # `linux/amd64` in a Dockerfile pins the stage regardless of what buildx
  # was asked to build.
  _write "dist/dockerfile/Dockerfile" \
    '# hadolint ignore=DL3006' \
    'FROM --platform=linux/amd64 ubuntu:24.04 AS sys'
  run _run_arch_literal
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/dockerfile/Dockerfile:2"* ]]
}

@test "_run_arch_literal: FAILS on a literal inside a comment too (#939)" {
  # The template Dockerfile's comments are copied into every downstream repo;
  # a literal there teaches the exact anti-pattern the lint exists to stop.
  _write "dist/dockerfile/Dockerfile" \
    'FROM ubuntu:24.04' \
    '# only ever built for amd64 anyway'
  run _run_arch_literal
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/dockerfile/Dockerfile:2"* ]]
}

@test "_run_arch_literal: names the offending literal and points at TARGETARCH (#939)" {
  # The message has to carry the fix, not just the finding.
  _write "dist/dockerfile/Dockerfile" \
    'RUN echo aarch64'
  run _run_arch_literal
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"aarch64"* ]]
  [[ "${output}" == *"TARGETARCH"* ]]
}

@test "_run_arch_literal: FAILS on a literal AFTER an allow-end (region does not leak) (#939)" {
  _write "dist/dockerfile/Dockerfile" \
    '# arch-literal-lint: allow-begin -- upstream asset spellings' \
    '#   amd64 -> x86_64' \
    '# arch-literal-lint: allow-end' \
    'RUN curl -fsSL "https://example.invalid/tool-arm64" -o /tool'
  run _run_arch_literal
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/dockerfile/Dockerfile:4"* ]]
  [[ "${output}" != *"dist/dockerfile/Dockerfile:2"* ]]
}

@test "_run_arch_literal: FAILS on an unterminated allow-begin region (#939)" {
  _write "dist/dockerfile/Dockerfile" \
    '# arch-literal-lint: allow-begin -- upstream asset spellings' \
    '#   amd64 -> x86_64'
  run _run_arch_literal
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unterminated"* ]]
}

@test "_run_arch_literal: FAILS on an allow-end with no matching allow-begin (#939)" {
  _write "dist/dockerfile/Dockerfile" \
    'FROM ubuntu:24.04' \
    '# arch-literal-lint: allow-end'
  run _run_arch_literal
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unmatched"* ]]
}

@test "_run_arch_literal: FAILS on an allow-begin carrying no stated reason (#939)" {
  # An opt-out without a reason is an off switch. The region still has to say
  # why the literal below it is the legitimate kind.
  _write "dist/dockerfile/Dockerfile" \
    '# arch-literal-lint: allow-begin' \
    '#   amd64 -> x86_64' \
    '# arch-literal-lint: allow-end'
  run _run_arch_literal
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"reason"* ]]
}

@test "_run_arch_literal: FAILS on a per-line allow carrying no stated reason (#939)" {
  _write "dist/dockerfile/Dockerfile" \
    'ARG TOOL_ARCH="x86_64"  # arch-literal-lint: allow'
  run _run_arch_literal
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"reason"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_arch_literal: accepted forms
# ════════════════════════════════════════════════════════════════════

@test "_run_arch_literal: PASSES a Dockerfile that expresses architecture via TARGETARCH (#939)" {
  _write "dist/dockerfile/Dockerfile" \
    'FROM ubuntu:24.04' \
    'ARG TARGETARCH' \
    'RUN curl -fsSL "https://example.invalid/tool-${TARGETARCH}" -o /tool'
  run _run_arch_literal
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_arch_literal: PASSES a two-spelling mapping table inside an allow region (#939)" {
  # THE case the lint must not break: TARGETARCH speaks amd64 / arm64 and the
  # upstream assets speak x86_64 / aarch64, so the correct implementation of
  # the rule legitimately contains both spellings.
  _write "dist/dockerfile/Dockerfile" \
    'FROM alpine:3.21 AS lint-tools' \
    'ARG TARGETARCH' \
    '# arch-literal-lint: allow-begin -- maps TARGETARCH onto upstream release-asset spellings' \
    'RUN case "${TARGETARCH}" in \' \
    '      amd64)  sc_arch="x86_64";  hd_arch="x86_64" ;; \' \
    '      arm64)  sc_arch="aarch64"; hd_arch="arm64"  ;; \' \
    '      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \' \
    '    esac && \' \
    '    curl -fsSL "https://example.invalid/shellcheck.linux.${sc_arch}.tar.xz" | tar -xJ' \
    '# arch-literal-lint: allow-end'
  run _run_arch_literal
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_arch_literal: PASSES a single line carrying a per-line allow with a reason (#939)" {
  # The narrow opt-out, for the one line that needs it: a region would over-
  # scope, and the reason travels on the line itself.
  _write "dist/dockerfile/Dockerfile" \
    'ARG SC_ARCH="x86_64"  # arch-literal-lint: allow -- upstream asset name for amd64'
  run _run_arch_literal
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_arch_literal: PASSES a Dockerfile that names no architecture at all (#939)" {
  _write "dist/dockerfile/Dockerfile" \
    'FROM ubuntu:24.04' \
    'RUN apt-get update && apt-get install -y --no-install-recommends curl'
  run _run_arch_literal
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_arch_literal: ignores non-Dockerfile files under the scan roots (#939)" {
  # TARGETARCH is a Dockerfile mechanism. A wrapper script naming a buildx
  # platform list, or a doc narrating the failure, is not the defect this
  # lint is about -- scanning them is the strict direction that gets a lint
  # muted.
  _write "dist/script/docker/lib/build.sh" \
    'readonly _PLATFORMS="linux/amd64,linux/arm64"'
  run _run_arch_literal
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_arch_literal: scans the repo-root dockerfile/ tree too (#939)" {
  _write "dockerfile/Dockerfile.test-tools" \
    'FROM alpine:3.21' \
    'RUN curl -fsSL "https://example.invalid/hadolint-Linux-x86_64" -o /hadolint'
  run _run_arch_literal
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dockerfile/Dockerfile.test-tools:2"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_arch_literal: non-vacuity guards
# ════════════════════════════════════════════════════════════════════

@test "_run_arch_literal: FAILS when a scan root is missing (#939)" {
  # An absent root makes the scan pass vacuously, silently disabling the lint
  # if the shipped tree is ever relocated.
  rm -rf "${SCRATCH}/dist"
  run _run_arch_literal
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist"* ]]
}

@test "_run_arch_literal: FAILS when a scan root holds no Dockerfile (#939)" {
  # The root exists but the filter matched nothing -- same vacuous pass, one
  # step further in. Renaming the template out from under the lint has to be
  # loud.
  rm -f "${SCRATCH}/dist/dockerfile/Dockerfile"
  run _run_arch_literal
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_arch_literal: real tree guard
# ════════════════════════════════════════════════════════════════════

@test "_run_arch_literal: the REAL shipped Dockerfiles pass today (#939)" {
  REPO_ROOT="/source"
  run _run_arch_literal
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}
