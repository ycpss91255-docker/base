#!/usr/bin/env bats
#
# build_worker_yaml_spec.bats — structural assertions for the
# `.github/workflows/build-worker.yaml` reusable workflow.
#
# Reusable workflows can't be unit-tested by exec'ing them, but their
# structural invariants (which inputs exist, which `with:` keys
# forward into docker/build-push-action) are still grep-able. These
# tests lock the changes — `context_path` / `dockerfile_path`
# inputs and the corresponding `context:` / `file:` lines in the 3
# build steps — so a future refactor that drops one of them lights up
# CI red instead of silently breaking nested-Dockerfile downstreams.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WF="/source/.github/workflows/build-worker.yaml"
  assert_spec_subject "${WF}" \
      "the reusable build worker this spec pins"
}

# ── Inputs declared ────────────────────────────────────────────

@test "build-worker.yaml: declares context_path input with default '.'" {
  run code_grep -A 3 '^      context_path:' "${WF}"
  assert_success
  assert_output --partial 'required: false'
  assert_output --partial 'type: string'
  assert_output --partial 'default: "."'
}

@test "build-worker.yaml: declares dockerfile_path input with empty default" {
  run code_grep -A 3 '^      dockerfile_path:' "${WF}"
  assert_success
  assert_output --partial 'required: false'
  assert_output --partial 'type: string'
  assert_output --partial 'default: ""'
}

# ── Build steps forward both inputs ────────────────────────────

@test "build-worker.yaml: 4 build steps all reference inputs.context_path (#243 added runtime-test)" {
  # Four `docker/build-push-action` calls after
  # devel-test / devel / runtime-test / runtime stages. Each must read
  # context from the new input; `context: .` would silently work for
  # repo-root-Dockerfile callers but break the nested-Dockerfile use
  # case the issue body documented.
  run code_grep -c 'context: ${{ inputs.context_path }}' "${WF}"
  assert_success
  assert_output "4"
}

@test "build-worker.yaml: 4 build steps all forward inputs.dockerfile_path with format() fallback" {
  # The `||` short-circuit means an empty dockerfile_path falls back
  # to `<context_path>/Dockerfile`, matching docker/build-push-action's
  # implicit default. Override path lets callers pin a non-standard
  # filename.
  run code_grep -c "file: \${{ inputs.dockerfile_path || format('{0}/Dockerfile', inputs.context_path) }}" "${WF}"
  assert_success
  assert_output "4"
}

@test "build-worker.yaml: no leftover hardcoded 'context: .' lines" {
  # Catches partial-refactor regressions where one of the 3 stages
  # gets reverted by accident. The file should have ZERO
  # `context: .` literals — every reference reads from the input.
  run code_grep -c '^          context: \.$' "${WF}"
  [ "${status}" -ne 0 ] || [ "${output}" = "0" ]
}

@test "build-worker.yaml: no hardcoded Dockerfile path bypassing the input" {
  # Belt-and-braces against someone hard-coding `file: ./Dockerfile`
  # in one stage and forgetting that callers expect the input to flow
  # through.
  run code_grep -E '^[[:space:]]+file: \./Dockerfile$' "${WF}"
  [ "${status}" -ne 0 ] || [ -z "${output}" ]
}

# ── Backwards compatibility ──────────────────────────────────────────

@test "build-worker.yaml: defaults preserve repo-root-Dockerfile behavior" {
  # Both inputs default such that an existing caller passing only
  # `image_name:` still resolves to context=. and file=./Dockerfile —
  # what every downstream main.yaml expects. Asserts the
  # combination, not just each default in isolation.
  local _ctx _df
  _ctx="$(code_grep -A 3 '^      context_path:' "${WF}" | grep 'default:' | head -1)"
  _df="$(code_grep -A 3 '^      dockerfile_path:' "${WF}" | grep 'default:' | head -1)"
  [[ "${_ctx}" == *'"."'* ]]
  [[ "${_df}" == *'""'* ]]
}

# ── User build-args alignment with Dockerfile.example ──────────

@test "build-worker.yaml: 4 build steps pass USER_NAME=ci (long form, matching Dockerfile.example sys stage)" {
  # the workflow passed `USER=ci` (short form) which the
  # Dockerfile only sees in the devel stage; the sys-stage useradd
  # reads USER_NAME and stuck on the default "user". The container
  # then USER-switched to "ci" with no /etc/passwd entry, exploding
  # any RUN that resolved the username.
  run code_grep -c '^            USER_NAME=ci$' "${WF}"
  assert_success
  assert_output "4"
}

@test "build-worker.yaml: 4 build steps pass USER_GROUP=ci (long form)" {
  run code_grep -c '^            USER_GROUP=ci$' "${WF}"
  assert_success
  assert_output "4"
}

@test "build-worker.yaml: 4 build steps pass USER_UID=1000 (long form)" {
  run code_grep -c '^            USER_UID=1000$' "${WF}"
  assert_success
  assert_output "4"
}

@test "build-worker.yaml: 4 build steps pass USER_GID=1000 (long form)" {
  run code_grep -c '^            USER_GID=1000$' "${WF}"
  assert_success
  assert_output "4"
}

@test "build-worker.yaml: no short-form USER=/GROUP=/UID=/GID= build-args (regression #198)" {
  # The Generate-.env step at the top of the workflow uses long-form
  # writes via `printf 'USER_NAME=...'`; only build-args lines (8-space
  # indent inside the build steps) are at risk. Anchor on that
  # indentation to avoid false positives from the env-file write.
  run code_grep -E '^            (USER|GROUP|UID|GID)=' "${WF}"
  [ "${status}" -ne 0 ] || [ -z "${output}" ]
}

# ── build_contexts input forwards to docker/build-push-action ──

@test "build-worker.yaml: declares build_contexts input with empty default" {
  # added compose's `additional_contexts:` for local builds, but
  # CI invokes `docker/build-push-action` directly (bypassing compose),
  # so the named contexts never reached BuildKit. adds the input
  # the workflow needs to forward them to the action's `build-contexts:`
  # field. Default is empty so existing callers see zero diff.
  run code_grep -A 3 '^      build_contexts:' "${WF}"
  assert_success
  assert_output --partial 'required: false'
  assert_output --partial 'type: string'
  assert_output --partial 'default: ""'
}

@test "build-worker.yaml: 4 build steps forward inputs.build_contexts to docker/build-push-action build-contexts:" {
  # Four docker/build-push-action calls after (devel-test / devel
  # / runtime-test / runtime). Each must forward the input so named
  # contexts work end-to-end in CI.
  run code_grep -c '^          build-contexts: \${{ inputs.build_contexts }}$' "${WF}"
  assert_success
  assert_output "4"
}

# ──stage rename + runtime-test smoke step ──────────────────────

@test "build-worker.yaml: devel-test build step uses target: devel-test (renamed from target: test)" {
  # the test stage was named `test`; renamed to `devel-test`
  # for symmetry with the new `runtime-test` stage. The literal target
  # line must reflect the new name.
  run code_grep -E '^          target: devel-test$' "${WF}"
  assert_success
}

@test "build-worker.yaml: no leftover target: test (the renamed stage)" {
  # If we forget to update one of the build steps, this catches it.
  run code_grep -E '^          target: test$' "${WF}"
  [ "${status}" -ne 0 ] || [ -z "${output}" ]
}

@test "build-worker.yaml: runtime-test build step exists and uses target: runtime-test" {
  run code_grep -E '^          target: runtime-test$' "${WF}"
  assert_success
}

@test "build-worker.yaml: runtime-test build step is gated on the resolved runtime answer" {
  # Same gate as the runtime stage build, so a repo whose Dockerfile
  # declares no runtime split skips both cleanly. The gate used to read
  # `inputs.build_runtime` directly, the disagreement the resolver removed;
  # it now reads the resolver step, asserted twice below (runtime-test and
  # runtime).
  run code_grep -c "^        if: \${{ steps.runtime.outputs.build_runtime == 'true' }}\$" "${WF}"
  assert_success
  [[ "${output}" -ge 2 ]] || { echo "expected >=2 runtime gates, got ${output}"; return 1; }
}

@test "build-worker.yaml: resolves the runtime gate from the caller's Dockerfile (#925)" {
  # The Dockerfile is the single source of truth for whether a runtime
  # stage exists. The worker asks the resolver, version-matched via the
  # .worker-base checkout, instead of trusting a second declaration in the
  # caller's main.yaml that nothing kept in agreement.
  run code_grep -c 'bash .worker-base/script/ci/build_worker/runtime_stages.sh' "${WF}"
  assert_success
  assert_output "1"
}

@test "build-worker.yaml: the resolver step exports build_runtime to GITHUB_OUTPUT (#925)" {
  run code_grep -E 'echo "build_runtime=\$\{effective\}" >> "\$\{GITHUB_OUTPUT\}"' "${WF}"
  assert_success
}

@test "build-worker.yaml: runtime + runtime-test build steps gate on the resolved value, not the raw input (#925)" {
  # Two gates, both reading the resolver's output. A raw
  # `if: ${{ inputs.build_runtime }}` is what shipped a runtime-test build
  # against a Dockerfile that declares no such stage.
  run code_grep -c "^        if: \${{ steps.runtime.outputs.build_runtime == 'true' }}\$" "${WF}"
  assert_success
  assert_output "2"
}

@test "build-worker.yaml: no build step gates on inputs.build_runtime directly (#925)" {
  run grep -n '^        if: ${{ inputs.build_runtime }}$' "${WF}"
  [ "${status}" -ne 0 ] || { echo "raw input gate still present: ${output}"; return 1; }
}

@test "build-worker.yaml: build_contexts default preserves zero-diff for existing callers (#207)" {
  # The combined safety net: with empty default + per-step plumbing,
  # callers that don't pass build_contexts get an empty action input,
  # which docker/build-push-action treats as "no extra contexts" — the
  # exact behaviour.
  local _bc
  _bc="$(code_grep -A 3 '^      build_contexts:' "${WF}" | grep 'default:' | head -1)"
  [[ "${_bc}" == *'""'* ]]
}

# ──GHA buildx cache (per-(repo, variant, arch)) ────────────────

@test "build-worker.yaml: declares cache_variant input with empty default (#272)" {
  # New optional input for repos that call build-worker.yaml multiple
  # times with the same image_name but different build_args (the
  # env/ros{,2}_distro pattern). Default empty so existing single-call
  # callers see no scope-key shape change.
  run code_grep -A 3 '^      cache_variant:' "${WF}"
  assert_success
  assert_output --partial 'required: false'
  assert_output --partial 'type: string'
  assert_output --partial 'default: ""'
}

@test "build-worker.yaml: Compute cache scope step emits id: cache with base key in GITHUB_OUTPUT (#272 + #378 + #802)" {
  # The step computes the per-(repo, variant, arch) base
  # `${image_name}[-${cache_variant}]-${hardware}` once; per-target
  # suffix (`-devel-test-cache`, `-devel-cache`, `-runtime-test-cache`,
  # `-runtime-cache`) is appended at the use site. See the b1 mitigation
  # of for why the shape changed from a single shared `<base>-cache`
  # scope to 4 per-target scopes. The derivation is now delegated to
  # cache_scope.sh; the step keeps `id: cache` + a `key=` GITHUB_OUTPUT.
  run code_grep -E '^        id: cache$' "${WF}"
  assert_success
  run code_grep -E '^          echo "key=\$\{key\}" >> "\$\{GITHUB_OUTPUT\}"$' "${WF}"
  assert_success
}

@test "build-worker.yaml: 4 build steps use per-target gha cache scopes in the default branch (#378 b1, #801 ternary)" {
  # all 4 build steps shared `${steps.cache.outputs.key}` so a
  # late-stage COPY in devel cascaded the manifest pointer in the
  # shared scope, invalidating runtime / runtime-test caches on the
  # next PR. each target has its own scope; one scope's manifest update
  # no longer affects the others.
  #
  # The cache_backend option made cache-from / cache-to a
  # `cache_backend`-selected ternary; the default (gha) branch is a
  # `format()` that emits the SAME `type=gha,scope=<key>-<target>-cache`
  # string as before, so gha callers are byte-for-byte unchanged at runtime.
  for _target in devel-test devel runtime-test runtime; do
    run code_grep -F "format('type=gha,scope={0}-${_target}-cache', steps.cache.outputs.key)" "${WF}"
    assert_success
    run code_grep -F "format('type=gha,scope={0}-${_target}-cache,mode=max', steps.cache.outputs.key)" "${WF}"
    assert_success
  done
}

@test "build-worker.yaml: 4 build steps emit a type=registry GHCR buildcache ref when cache_backend is registry (#801)" {
  # The registry branch of the ternary stores/reads the buildx cache in
  # GHCR (no 10 GB GHA ceiling): type=registry,ref=ghcr.io/<repo>/buildcache
  # tagged per target, with mode=max on cache-to.
  for _target in devel-test devel runtime-test runtime; do
    run code_grep -F "format('type=registry,ref=ghcr.io/{0}/buildcache:{1}-${_target}-cache', github.repository, steps.cache.outputs.key)" "${WF}"
    assert_success
    run code_grep -F "format('type=registry,ref=ghcr.io/{0}/buildcache:{1}-${_target}-cache,mode=max', github.repository, steps.cache.outputs.key)" "${WF}"
    assert_success
  done
}

@test "build-worker.yaml: extra_stages loop honors cache_backend for both backends (#801)" {
  # A caller using cache_backend: registry AND extra_stages must not get
  # those stages silently gha-cached. The extra_stages buildx loop receives
  # the backend + repo via env and selects the cache ref in shell with the
  # same registry/gha shapes as the four standard steps (registry ref with
  # mode=max on cache-to; gha branch byte-for-byte unchanged).
  run code_grep -F 'CACHE_BACKEND: ${{ inputs.cache_backend }}' "${WF}"
  assert_success
  run code_grep -F 'REPO: ${{ github.repository }}' "${WF}"
  assert_success
  # Shell selection helpers emit the registry ref (unique %s printf form,
  # distinct from the four steps' format() {0}/{1}) and the unchanged gha form.
  run code_grep -F 'type=registry,ref=ghcr.io/%s/buildcache:%s' "${WF}"
  assert_success
  run code_grep -F 'type=registry,ref=ghcr.io/%s/buildcache:%s,mode=max' "${WF}"
  assert_success
  run code_grep -F 'type=gha,scope=%s' "${WF}"
  assert_success
  # The loop no longer hardwires a gha cache ref on the buildx invocations.
  run code_grep -F '"type=gha,scope=${CACHE_KEY}' "${WF}"
  [ "${status}" -ne 0 ] || [ -z "${output}" ]
  # Both buildx invocations (test-stage + stage) call the selection helpers.
  run code_grep -cF -e '--cache-from "$(cache_from_for ' "${WF}"
  assert_success
  assert_output "2"
  run code_grep -cF -e '--cache-to "$(cache_to_for ' "${WF}"
  assert_success
  assert_output "2"
}

@test "build-worker.yaml: cache lines select the backend on inputs.cache_backend (#801)" {
  # Both cache-from and cache-to (8 lines total) gate on the input so the
  # backend is chosen per call, defaulting to gha.
  run code_grep -cE "^          cache-(from|to): \\\$\{\{ inputs\.cache_backend == 'registry'" "${WF}"
  assert_success
  assert_output "8"
}

@test "build-worker.yaml: 4 distinct cache scopes exist, no shared scope leftover (#378 b1)" {
  # Negative regression: ensure no legacy `cache-from:`/`cache-to:` line
  # still references the bare base key (which would mean a build step
  # was missed in the per-target migration).
  run code_grep -cE '^          cache-(from|to): type=gha,scope=\$\{\{ steps\.cache\.outputs\.key \}\}(,|$)' "${WF}"
  [ "${status}" -ne 0 ] || [ "${output}" = "0" ]
}

@test "build-worker.yaml: 4 build steps all set mode=max on cache-to for both backends (#272 preserved, #801)" {
  # mode=max exports all intermediate stage layers (including the heavy
  # builder / source-build stages). Both ternary branches (gha default +
  # registry) carry mode=max on cache-to; 4 cache-to lines * both
  # branches = 4 gha + 4 registry mode=max occurrences.
  # gha default branch is the `|| format(...)` fallback, so its cache-to
  # format() ends the whole `${{ ... }}` expression ( `) }}` ).
  run code_grep -cF ",mode=max', steps.cache.outputs.key) }}" "${WF}"
  assert_success
  assert_output "4"
  # registry branch is the `&& format(...)` arm, so its cache-to format()
  # is followed by the `||` fallback ( `) ||` ).
  run code_grep -cF ",mode=max', github.repository, steps.cache.outputs.key) ||" "${WF}"
  assert_success
  assert_output "4"
}

@test "build-worker.yaml: declares cache_backend input with default gha (#801)" {
  # Opt-in registry cache backend; default gha keeps every existing
  # caller byte-for-byte unchanged (no 10 GB GHA ceiling escape unless
  # asked for).
  run code_grep -A 3 '^      cache_backend:' "${WF}"
  assert_success
  assert_output --partial 'required: false'
  assert_output --partial 'type: string'
  assert_output --partial 'default: "gha"'
}

@test "build-worker.yaml: cache_backend default preserves the gha backend for existing callers (#801)" {
  local _cb
  _cb="$(code_grep -A 3 '^      cache_backend:' "${WF}" | grep 'default:' | head -1)"
  [[ "${_cb}" == *'"gha"'* ]]
}

@test "build-worker.yaml: GHCR login step is gated on cache_backend == registry (#801)" {
  # The registry backend pushes cache to ghcr.io/<repo>/buildcache and
  # needs an authenticated buildx session; the default gha path adds no
  # login. Assert both the docker/login-action use and its cache_backend
  # gate are present.
  run code_grep -E '^[[:space:]]+uses: docker/login-action@' "${WF}"
  assert_success
  run code_grep -F "if: \${{ inputs.cache_backend == 'registry' }}" "${WF}"
  assert_success
}

@test "build-worker.yaml: cache_variant default preserves zero-diff for single-call callers (#272)" {
  # Single-distro repos (agent/* + ros1_bridge-${distro} pattern) leave
  # cache_variant unset; the scope key reduces to
  # ${image_name}-${hardware}-<target>-cache (b1), which is still
  # per-(repo, arch) and now also per-target.
  local _cv
  _cv="$(code_grep -A 3 '^      cache_variant:' "${WF}" | grep 'default:' | head -1)"
  [[ "${_cv}" == *'""'* ]]
}

# ── Phase 1: doc-only PR fast-pass ────────────────────────────────

@test "build-worker.yaml: declares path-filter job (#273)" {
  # New job runs the doc-only classifier; outputs code_changed
  # consumed by compute-matrix / build / docker-build downstream.
  run code_grep -E '^  path-filter:$' "${WF}"
  assert_success
}

@test "build-worker.yaml: path-filter classifier is pure shell (#273 Phase 2: no dorny/paths-filter)" {
  # Phase 2 — dorny/paths-filter@v3 dependency dropped; classification
  # is now `git diff --name-only base...head` + `case` glob in inline
  # shell. Asserts the `uses:` import is gone (comments mentioning
  # `dorny` for historical context are still fine) AND the shell
  # driver is present.
  run code_grep -E '^\s+uses:\s+dorny/paths-filter' "${WF}"
  [ "${status}" -ne 0 ] || [ -z "${output}" ]
  run code_grep -F 'git diff --name-only "${BASE_SHA}...${HEAD_SHA}"' "${WF}"
  assert_success
}

@test "build-worker.yaml: classifier reads EVENT_NAME / BASE_SHA / HEAD_SHA from env (#273 Phase 2)" {
  # Template tokens pre-expand into env vars so the shell case body
  # stays portable to non-GitHub CI hosts — only the YAML env: keys
  # bind to GitHub context.
  run code_grep -F 'EVENT_NAME: ${{ github.event_name }}' "${WF}"
  assert_success
  run code_grep -F 'BASE_SHA: ${{ github.event.pull_request.base.sha }}' "${WF}"
  assert_success
  run code_grep -F 'HEAD_SHA: ${{ github.event.pull_request.head.sha }}' "${WF}"
  assert_success
}

@test "build-worker.yaml: non-pull_request event short-circuits to code_changed=true before git diff (#273 Phase 2)" {
  # Push / tag / workflow_dispatch never run the classifier loop —
  # the early `[ ... != pull_request ] && exit 0` arm is essential
  # because BASE_SHA / HEAD_SHA are empty on non-PR events.
  run code_grep -E '\[ "\$\{EVENT_NAME\}" != "pull_request" \]' "${WF}"
  assert_success
}

@test "build-worker.yaml: doc-only allowlist case-glob covers all 6 documented paths (#273)" {
  # **/*.md, doc/**, LICENSE, .gitignore, .github/CODEOWNERS,
  # .github/dependabot.yml — match the issue body / design comment.
  # Phase 2 expresses them as a single `case` arm with `|`-joined
  # patterns; one grep checks the whole arm at once.
  run code_grep -F '*.md|doc/*|LICENSE|.gitignore|.github/CODEOWNERS|.github/dependabot.yml' "${WF}"
  assert_success
}

@test "build-worker.yaml: compute-matrix and build are gated on code_changed (#273)" {
  # Both heavy jobs need needs.path-filter.outputs.code_changed == 'true'.
  # Asserted per job rather than by counting the `if:` line: `build`'s gate
  # is now a block scalar that ANDs the same-repo guard beside it, so a
  # whole-file count of the single-line form reads 1 and says nothing about
  # WHICH job lost its gate. Per-job is the claim that was meant.
  run yaml_job_lines "${WF}" compute-matrix
  assert_success
  assert_output --partial "needs.path-filter.outputs.code_changed == 'true'"

  run yaml_job_lines "${WF}" build
  assert_success
  assert_output --partial "needs.path-filter.outputs.code_changed == 'true'"
}

@test "build-worker.yaml: docker-build aggregator short-circuits to success on doc-only (#273)" {
  # The aggregator must report success when code_changed == 'false'
  # so branch protection's required check still resolves green even
  # though the matrix was skipped.
  run code_grep -F 'needs.path-filter.outputs.code_changed }}" = "false"' "${WF}"
  assert_success
  # And it still needs both path-filter + build so the conditional
  # has both data sources.
  run code_grep -E '^    needs: \[path-filter, build\]$' "${WF}"
  assert_success
}

@test "build-worker.yaml: non-pull_request event resolves code_changed=true (#273)" {
  # Push to main / tag / workflow_dispatch must always run the full
  # matrix — the doc-only fast-pass is PR-only.
  run code_grep -F 'echo "code_changed=true"' "${WF}"
  assert_success
}

# ──opt-in free_disk_space for large BASE_IMAGE repos ───────────

@test "build-worker.yaml: declares free_disk_space input as boolean default false (#470)" {
  # Opt-in step that pre-clears ~30 GB of pre-installed runner tooling
  # (Android SDK, .NET, GHC, ...) so repos whose BASE_IMAGE doesn't fit
  # in ubuntu-latest's ~14 GB (Isaac Sim ~15 GB extracted) stop hitting
  # `no space left on device` during BuildKit COPY. Default false so
  # the ~30 s cleanup overhead doesn't tax existing small-image callers.
  run code_grep -A 3 '^      free_disk_space:' "${WF}"
  assert_success
  assert_output --partial 'required: false'
  assert_output --partial 'type: boolean'
  assert_output --partial 'default: false'
}

@test "build-worker.yaml: Free disk space step gated on inputs.free_disk_space (#470)" {
  # The step is opt-in; without the gate every existing caller would
  # pay the cleanup time even when they don't need it.
  run code_grep -E "^[[:space:]]+if: \\\$\{\{ inputs\\.free_disk_space \\}\}$" "${WF}"
  assert_success
}

@test "build-worker.yaml: Free disk space step uses jlumbroso/free-disk-space (#470)" {
  # The community action removes Android SDK / .NET / GHC / tool-cache
  # without touching docker daemon state, which is what we need before
  # buildx starts pulling the BASE_IMAGE.
  run code_grep -E '^[[:space:]]+uses: jlumbroso/free-disk-space@' "${WF}"
  assert_success
}

@test "build-worker.yaml: Free disk space step runs before Set up Docker Buildx (#470)" {
  # Order matters — buildx allocates its overlayfs snapshot dir before
  # the first COPY, so disk must be freed earlier in the job.
  local _free _buildx
  _free="$(grep -n '^      - name: Free disk space$' "${WF}" | cut -d: -f1)"
  _buildx="$(grep -n '^      - name: Set up Docker Buildx$' "${WF}" | cut -d: -f1)"
  [[ -n "${_free}" ]] || { echo "Free disk space step missing"; return 1; }
  [[ -n "${_buildx}" ]] || { echo "Set up Docker Buildx step missing"; return 1; }
  [[ "${_free}" -lt "${_buildx}" ]] || {
    echo "expected Free disk space (line ${_free}) before Set up Docker Buildx (line ${_buildx})"
    return 1
  }
}

# ── worker logic pushed down to host-testable shell scripts ────────────

@test "build-worker.yaml: compute-matrix delegates to the extracted compute_matrix.sh (#802)" {
  # The platform -> matrix logic (the "a matrix condition that produces no
  # jobs" semantic break) is pushed down into a pure-shell, host-testable
  # script covered by build_worker_compute_matrix_spec.bats. The YAML step
  # must call the script and keep only the GITHUB_OUTPUT plumbing -- the old
  # inline `case linux/amd64)` fan-out logic must be gone from the YAML.
  run code_grep -F 'bash .worker-base/script/ci/build_worker/compute_matrix.sh' "${WF}"
  assert_success
  run code_grep -F 'echo "matrix=${matrix}" >> "${GITHUB_OUTPUT}"' "${WF}"
  assert_success
  # No leftover inline platform fan-out (would mean the extraction was
  # half-done and the untested inline copy could drift).
  run code_grep -F '{"platform":"linux/amd64","runner":"ubuntu-latest","hardware":"x86_64"}' "${WF}"
  [ "${status}" -ne 0 ] || [ -z "${output}" ]
}

@test "build-worker.yaml: compute-matrix version-matches the script via job_workflow_sha (#802)" {
  # The script is fetched from base at the SAME ref as this workflow, so the
  # resolver can never drift from the worker it feeds -- the exact
  # version-match pattern the caller-contract preflight uses. Assert the compute-matrix
  # job checks out ycpss91255-docker/base at github.job_workflow_sha into
  # the .worker-base path the delegating call reads from.
  run yaml_job_lines "${WF}" compute-matrix
  assert_success
  assert_output --partial 'repository: ycpss91255-docker/base'
  assert_output --partial 'ref: ${{ github.job_workflow_sha }}'
  assert_output --partial 'path: .worker-base'
}

@test "build-worker.yaml: Compute cache scope delegates to the extracted cache_scope.sh (#802)" {
  # The base-key derivation (with its per-target cache-scope bug history) is pushed
  # down into a pure-shell, host-testable script covered by
  # build_worker_cache_scope_spec.bats. The step must call the script,
  # feed it IMAGE_NAME / CACHE_VARIANT / HARDWARE via env, and keep only
  # the GITHUB_OUTPUT plumbing; the old inline `base="..."` derivation must
  # be gone.
  run code_grep -F 'bash .worker-base/script/ci/build_worker/cache_scope.sh' "${WF}"
  assert_success
  run code_grep -F 'echo "key=${key}" >> "${GITHUB_OUTPUT}"' "${WF}"
  assert_success
  run code_grep -F 'IMAGE_NAME: ${{ inputs.image_name }}' "${WF}"
  assert_success
  run code_grep -F 'CACHE_VARIANT: ${{ inputs.cache_variant }}' "${WF}"
  assert_success
  # No leftover inline scope derivation (would mean an untested copy could
  # drift from the tested script).
  run code_grep -F 'base="${{ inputs.image_name }}"' "${WF}"
  [ "${status}" -ne 0 ] || [ -z "${output}" ]
}

@test "build-worker.yaml: build job checks out base worker source at job_workflow_sha into .worker-base (#802)" {
  # The cache-scope script the build job runs is fetched at the worker's own
  # ref, isolated in .worker-base so it never collides with the caller
  # checkout at the workspace root.
  run yaml_job_lines "${WF}" build
  assert_success
  assert_output --partial 'repository: ycpss91255-docker/base'
  assert_output --partial 'ref: ${{ github.job_workflow_sha }}'
  assert_output --partial 'path: .worker-base'
}

# ── Run-scoped names + cleanup, downstream half ────────────────

@test "build-worker.yaml: the workspace path it writes is keyed to the run (#900)" {
  # This is the downstream half of the same rule: every name CI creates
  # must differ between two runs that share a host. The worker builds with
  # `push: false` and no `tags:`, so it produces no NAMED docker artifact
  # today -- but it does write a fixed host path into the .env it
  # generates, and `runs-on: ${{ matrix.runner }}` is exactly the knob a
  # self-hosted migration turns.
  run code_grep -c 'WS_PATH=/tmp/workspace-ci-${{ github.run_id }}-${{ github.run_attempt }}' "${WF}"
  assert_success
  assert_output '1'
  run code_grep -E 'WS_PATH=/tmp/workspace$' "${WF}"
  assert_failure
}

@test "build-worker.yaml: the build job reclaims its own leftovers on if: always() (#900)" {
  # Reached through the SAME .worker-base checkout the cache-scope script
  # uses, so the collector is version-matched to the worker rather than
  # copied into every caller repo.
  run yaml_job_lines "${WF}" build
  assert_success
  assert_output --partial 'bash .worker-base/script/ci/reclaim.sh'
  assert_output --partial 'if: always()'
}

@test "build-worker.yaml: downstream cleanup is ownership-scoped too (#900)" {
  # A downstream self-hosted host is shared with every other repo in the
  # org. A blanket prune there is worse, not better. Asserted over the
  # code lines -- the rationale for a prohibition names the command it
  # rules out.
  run code_grep -E 'docker system prune|image prune -a|docker volume prune' "${WF}"
  assert_failure
}

# ── Same-repository guard on the self-hosted-eligible build job ────────

@test "build-worker.yaml: the build job carries the same-repo guard AND-ed with its code_changed gate (#766)" {
  # `runs-on: ${{ matrix.runner }}` over a `fromJSON` matrix: the label
  # set is computed at runtime, so nothing static can prove this job stays
  # on a GitHub-hosted machine -- and the org registers an org-level
  # self-hosted runner that public repos may use. The guard must not
  # REPLACE the existing gate, or a doc-only PR would start paying for a
  # full build; both conditions have to survive.
  run yaml_job_lines "${WF}" build
  assert_success
  assert_output --partial "needs.path-filter.outputs.code_changed == 'true' &&"
  assert_output --partial "(github.event_name != 'pull_request' ||"
  assert_output --partial 'github.event.pull_request.head.repo.full_name == github.repository)'
}

@test "build-worker.yaml: the guard tests the FORK, not the PR (#766)" {
  # A condition that skipped on every pull_request would disable the
  # worker for the same-repo PRs that are its entire PR-time workload.
  # The first disjunct is what lets a same-repo PR -- and a tag push, a
  # schedule, a workflow_dispatch -- through.
  run yaml_job_lines "${WF}" build
  assert_success
  assert_output --partial "github.event_name != 'pull_request'"
  # The negated form would invert the meaning: only fork PRs would run.
  refute_output --partial "github.event.pull_request.head.repo.full_name != github.repository"
}

# ── Per-job least privilege ────────────────────────────────────

# Print the name of every job in the worker that declares no permission
# ENTRY of its own -- no `permissions:` block, or an inline one
# (`permissions: read-all`, `permissions: {}`) that names no scope. Both
# leave the job running on a grant base does not control.
#
# Read off the shared `yaml_permission_surface`, which asks a YAML parser.
# This used to be a private awk that matched job keys as
# `^  [A-Za-z0-9_-]+:[ \t]*$` and permission blocks as text: a job key
# carrying a trailing comment (`sign-artifacts: # signs the images`) was
# not a job to it, so the job -- and its grants -- was invisible to a
# guard whose whole assertion is that nothing came back.
_jobs_without_permissions() {
  local _line
  while IFS= read -r _line; do
    case "${_line}" in
      'BUG:'*)          printf '%s\n' "${_line}" ;;
      *": <no entries>") printf '%s\n' "${_line%%:*}" ;;
    esac
  done < <(yaml_permission_surface "${WF}")
}

# The jobs this spec's least-privilege assertions run over: derived from the
# workflow file by the shared `yaml_job_names`, never listed here.
# `_assert_worker_job_population` is what every one of them calls FIRST,
# because
# an empty scan and a clean scan are the same output otherwise -- an
# extractor that stopped matching, or a file that moved, would report "no
# job grants too much" from zero jobs.
#
# The five names below are a FLOOR, not a roster: they are the jobs the
# worker ships today, and the assertions themselves run over whatever
# `yaml_job_names` returns, so a sixth job is scanned the day it lands
# without this spec being edited.
_assert_worker_job_population() {
  local _derived _count _job _status=0
  _derived="$(yaml_job_names "${WF}")" || _status=$?
  [[ "${_status}" -eq 0 ]] || fail \
      "the job derivation could not read ${WF}: ${_derived}"
  _count="$(printf '%s\n' "${_derived}" | awk 'NF { n++ } END { print n + 0 }')"
  [[ "${_count}" -ge 5 ]] || fail \
      "expected at least the 5 jobs build-worker.yaml ships, derived ${_count} from ${WF} -- the scan below would have passed over an empty population"
  # Every derived name must also appear as a two-space key in the file's own
  # code lines. This is a CONFIRMATION that the parser read this file, not a
  # second opinion about how many jobs it holds: a re-implementation of the
  # same regex over the same input cannot disagree with the derivation about
  # anything, which is what the previous "independent extraction" here
  # actually was.
  local _name _seen
  while IFS= read -r _name; do
    [[ -n "${_name}" ]] || continue
    _seen=0
    code_grep -E "^  \"?${_name}\"?:" "${WF}" >/dev/null || _seen=$?
    [[ "${_seen}" -eq 0 ]] || fail \
        "derived job '${_name}' has no '  ${_name}:' key in the code lines of ${WF} (grep exited ${_seen}) -- the derivation is not reading the file this spec is about"
  done <<< "${_derived}"
  for _job in preflight path-filter compute-matrix build docker-build; do
    printf '%s\n' "${_derived}" | grep -x -- "${_job}" >/dev/null || fail \
        "job '${_job}' is missing from the derived job list of ${WF}: either it was renamed (update this floor) or the extractor stopped seeing the file"
  done
}

# Print every `<job>: <entry>` in the worker whose grant is not exactly
# `contents: read` -- which includes the `<no entries>` placeholder
# `yaml_permission_surface` emits for a job with no block at all. The job
# list comes from the FILE, so this names the job added tomorrow.
#
# grep's status is pinned: 0 means it found elevations and prints them, 1
# means every line was `<job>: contents: read`, and anything else is a
# grep that could not read its input -- reported as a BUG line so it fails
# the caller's `assert_output ''` instead of passing as "no match".
_worker_jobs_granting_more_than_contents_read() {
  local _out _status=0
  _out="$(yaml_permission_surface "${WF}" \
      | grep -vxE '[A-Za-z0-9_-]+: contents: read')" || _status=$?
  case "${_status}" in
    0) printf '%s\n' "${_out}" ;;
    1) ;;
    *) printf 'BUG: grep exited %s scanning the permission surface\n' \
           "${_status}" ;;
  esac
}

@test "build-worker.yaml: every job declares its own permissions block (#957)" {
  # This is a REUSABLE workflow. A job with no `permissions:` inherits the
  # CALLER's grant -- a downstream repo's token, not base's -- so a caller
  # that legitimately grants `contents: write` or `packages: write`
  # workflow-wide hands that write to jobs which only ever read. A job
  # that declares a block gets exactly that block instead (capped by the
  # caller, which it may narrow but never widen), which is the only place
  # base can bound a permission it does not own.
  _assert_worker_job_population
  run _jobs_without_permissions
  assert_success
  assert_output ''
}

# Print `<job>: packages: write` for every job that names that scope in its
# own permissions block. Read off the DERIVED permission surface, so the
# caller-facing example inside the `cache_backend` input description --
# which is instructing the CALLER to grant it, and is correct -- is outside
# the jobs section and never reaches this, and a rationale comment quoting
# the scope is stripped before matching. grep's status is pinned: 1 is "no
# job asks for it", anything above that is a scan that failed and is
# reported rather than read as a pass.
_jobs_requesting_packages_write() {
  local _out _status=0
  _out="$(yaml_permission_surface "${WF}" \
      | grep -E ': packages:[ \t]*write$')" || _status=$?
  case "${_status}" in
    0) printf '%s\n' "${_out}" ;;
    1) ;;
    *) printf 'BUG: grep exited %s scanning the permission surface\n' \
           "${_status}" ;;
  esac
}

@test "build-worker.yaml: no job requests packages: write (#957)" {
  # A job in a CALLED workflow may only NARROW the calling job's grant,
  # never widen it. Declaring any `permissions:` key sets every unnamed
  # scope to `none`, so every current caller -- base's own worker-selftest,
  # the seeded main.yaml, ros_distro / ros2_distro, and the ROS repos
  # routed through multi-distro-build-worker.yaml -- reaches this workflow
  # with `packages: none`. A job here naming `packages: write` is an
  # ELEVATION, and GitHub rejects the whole run before it starts:
  #   The nested job 'build' is requesting 'contents: read, packages:
  #   write', but is only allowed 'contents: read, packages: none'.
  # The `cache_backend: registry` write therefore stays a CALLER-side
  # grant, which is what the input description already asks callers for;
  # the worker may not declare it on their behalf.
  _assert_worker_job_population
  run _jobs_requesting_packages_write
  assert_success
  assert_output ''
}

@test "build-worker.yaml: the build job asks for contents: read alone (#957)" {
  # The job builds but never pushes an image (`push: false`, no `tags:`),
  # so on the default `cache_backend: gha` a checkout grant is all it
  # needs. `permissions:` accepts no expression, so one static set has to
  # serve both backends, and the only set every caller can satisfy is the
  # read-only one (see the elevation test above).
  #
  # "alone" is asserted as an EXACT entry set, not as presence: `packages:
  # write` is only the scope this issue happened to find, and any other
  # scope the caller did not grant (`id-token: write`, `attestations:
  # write`, ...) fails a caller's run in exactly the same way.
  run yaml_job_permission_entries "${WF}" build
  assert_success
  assert_output 'contents: read'
}

@test "build-worker.yaml: no job in the worker grants more than contents: read (#957)" {
  # The whole permission surface, job list DERIVED from the file. Nothing
  # here loops over known job names: the previous shape did, and a
  # `sign-artifacts` job appended to the workflow with `contents: write`,
  # `id-token: write` and `packages: read` left all 61 specs green.
  # path-filter checks out and diffs; compute-matrix and docker-build only
  # read `needs` / the repo; preflight probes with a token it deliberately
  # keeps read-only. None touches a package, so none may inherit a caller's
  # `packages: write`.
  #
  # The assertion is a PROPERTY over the derived set, not a pin of today's
  # listing: a sixth job asking `contents: read` like its siblings passes
  # untouched, and a sixth job asking anything else is named here on the
  # day it lands. A job that declares no block at all surfaces as
  # `<job>: <no entries>` and fails the same way.
  _assert_worker_job_population
  run _worker_jobs_granting_more_than_contents_read
  assert_success
  assert_output ''
}

# Print every comment PARAGRAPH inside the build job (a run of adjacent
# `#` lines, joined) that cites the preflight while talking about a
# package permission. Paragraph granularity matters: the claim is a
# sentence, and a sentence wraps across comment lines.
#
# Both greps have their status pinned rather than `|| true`-ed: 1 is "no
# paragraph says that", and 2 -- a grep that could not read its input, or a
# build job that vanished -- must not arrive at the caller as an empty,
# passing scan.
_build_comments_citing_preflight_for_a_grant() {
  local _out _status=0
  _out="$(_build_comment_paragraphs \
      | grep -i 'preflight' | grep -Ei 'packages|permission|grant')" \
      || _status=$?
  case "${_status}" in
    0) printf '%s\n' "${_out}" ;;
    1) ;;
    *) printf 'BUG: grep exited %s scanning the build job comments\n' \
           "${_status}" ;;
  esac
}

# Every comment paragraph of the build job, one per line. Split out so the
# test can assert the POPULATION it is scanning before reading anything
# into an empty result.
_build_comment_paragraphs() {
  yaml_job_text "${WF}" build | awk '
    /^[[:space:]]*#/ {
      line = $0
      sub(/^[[:space:]]*#[[:space:]]?/, "", line)
      para = para " " line
      next
    }
    { if (para != "") { print para; para = "" } }
    END { if (para != "") { print para } }
  '
}

@test "build-worker.yaml: the build job never cites the preflight as proof of a package grant (#957)" {
  # The preflight job declares `permissions: contents: read`, so its own
  # token carries `packages: none` no matter what the caller granted, and
  # its write-scope probe cannot come back 202. Nothing in the build job
  # may reason from that probe about a caller holding `packages: write`
  # -- the probe is the thing that is broken, not the evidence that
  # anything works. Tracked separately from this issue.
  local _paragraphs
  _paragraphs="$(_build_comment_paragraphs | awk 'END { print NR }')"
  [[ "${_paragraphs}" -ge 10 ]] || fail \
      "expected the build job to carry its explanatory comment paragraphs, extracted ${_paragraphs} -- the scan below would have read an empty job as a clean one"
  run _build_comments_citing_preflight_for_a_grant
  assert_success
  assert_output ''
}
