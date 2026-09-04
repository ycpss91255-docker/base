#!/usr/bin/env bats
#
# Static checks for base's self-use of the `docker` namespace
# (ADR-00000011 sec.2/4): base is the template SOURCE, so it has no `.base/`
# subtree -- it wires the docker namespace into its own root justfile and
# ships the wrapper symlinks pointing directly at dist/ (no `.base/`
# prefix), mirroring what init.sh produces for a consumer. `just` is not
# installed in the test-tools image, so these are content / symlink
# assertions, not execution (execution parity is a consumer/local concern).
#
# why: base's self-use of the `docker` namespace (#713, ADR-00000011
# sec.2/4/5): root justfile `mod? docker`, the committed
# `script/docker/justfile.docker` + flat `script/<verb>.sh` symlinks
# resolving into `dist/` (no `.base/` hop), the `test-tools` compose service
# building `Dockerfile.test-tools`, and `just test system` building it via
# the docker namespace. Also pins the naming-isolation shape (#891): the
# build-only `test-tools` service reads the same `TEST_TOOLS_IMAGE` its
# consumers read instead of a fixed `test-tools:local` literal, and the
# `system` recipe derives that tag from the tooling Dockerfile's content
# instead of hardcoding it, and names the compose project instead of
# inheriting the checkout directory's basename. Tightened by #896: EVERY
# `image:` line must name that variable and NONE may carry a `:-` default,
# since two different defaults are what let the build write one tag while
# the run read another.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  ROOT=/source
}

@test "base root justfile mods the docker namespace (#713)" {
  run grep -E "^mod\?? docker 'script/docker/justfile.docker'" "${ROOT}/justfile"
  assert_success
}

@test "base ships script/docker/justfile.docker as a symlink into dist/ (no .base/)" {
  assert [ -L "${ROOT}/script/docker/justfile.docker" ]
  # Resolves to a real file under dist/script/docker (not via a .base/ hop).
  local _t
  _t="$(readlink -- "${ROOT}/script/docker/justfile.docker")"
  assert [ -f "${ROOT}/script/docker/justfile.docker" ]
  [[ "${_t}" != *".base/"* ]]
  [[ "${_t}" == *"dist/script/docker/justfile.docker" ]]
}

@test "base ships flat wrapper symlinks resolving into dist/script/docker/wrapper" {
  local _w
  for _w in build run exec stop prune setup setup_tui; do
    assert [ -L "${ROOT}/script/${_w}.sh" ]
    assert [ -f "${ROOT}/script/${_w}.sh" ]
    local _t
    _t="$(readlink -- "${ROOT}/script/${_w}.sh")"
    [[ "${_t}" != *".base/"* ]]
    [[ "${_t}" == *"dist/script/docker/wrapper/${_w}.sh" ]]
  done
}

@test "base compose.yaml declares a test-tools service building Dockerfile.test-tools" {
  run grep -nE '^\s{2}test-tools:' "${ROOT}/compose.yaml"
  assert_success
  # The service builds from the standalone tooling Dockerfile.
  run grep -nE 'dockerfile:\s*dockerfile/Dockerfile.test-tools' "${ROOT}/compose.yaml"
  assert_success
}

@test "just test system builds test-tools via the docker namespace, not a raw docker build (#713, ADR-00000011 sec.5)" {
  run grep -nE 'just docker build --target test-tools' "${ROOT}/script/test/justfile.test"
  assert_success
  # The raw `docker build -t test-tools:local -f dockerfile/Dockerfile.test-tools`
  # one-liner is gone -- the test runner invokes the docker namespace instead.
  run grep -nE 'docker build -t test-tools:local -f' "${ROOT}/script/test/justfile.test"
  assert_failure
}

@test "base compose.yaml names every image with TEST_TOOLS_IMAGE and gives it no default (#891, #896)" {
  # A hardcoded `image: test-tools:local` makes every checkout on the host
  # write one tag, so a sibling build silently displaces the image a live
  # run is using. A DEFAULT is worse still: two different ones let the
  # build-only service write one tag while the ci / ci-system / coverage
  # consumers read another, and one shared default would only hide that
  # while still building or pulling something behind the operator's back.
  local _total
  _total="$(grep -cE '^ {4}image: ' "${ROOT}/compose.yaml")"
  run grep -cE '^ {4}image: \$\{TEST_TOOLS_IMAGE(\}|:\?)' "${ROOT}/compose.yaml"
  assert_success
  assert_output "${_total}"
  run grep -nE '^ {4}image: \$\{TEST_TOOLS_IMAGE:-' "${ROOT}/compose.yaml"
  assert_failure
  run grep -nE '^ {4}image: test-tools:local *$' "${ROOT}/compose.yaml"
  assert_failure
}

@test "just test system derives the local test-tools tag instead of hardcoding it (#891)" {
  run grep -nE 'TEST_TOOLS_IMAGE=test-tools:local' "${ROOT}/script/test/justfile.test"
  assert_failure
  run grep -nE 'test\.sh --test-tools-image' "${ROOT}/script/test/justfile.test"
  assert_success
}

@test "base compose.yaml carries no fallback identity for the mounted checkout (#895)" {
  # The behavioural half (what compose RESOLVES) lives in
  # compose_host_identity_spec, which needs the compose plugin in the
  # tooling image. This half needs nothing and cannot rot: a `:-` default
  # on either variable is the silent 'files owned by uid 1000' defect
  # regardless of which value it names.
  run grep -nE '^ +- HOST_(UID|GID)=\$\{HOST_(UID|GID):-' "${ROOT}/compose.yaml"
  assert_failure
  run grep -cE '^ +- HOST_(UID|GID)=\$\{HOST_(UID|GID):\?' "${ROOT}/compose.yaml"
  assert_success
  assert_output "6"
}

@test "base root justfile exports the host identity every compose read needs (#895)" {
  # compose interpolates the WHOLE compose.yaml whatever service is named,
  # so dropping the HOST_UID / HOST_GID defaults made them required of
  # every `just` recipe that reaches compose -- including
  # `just docker build --target test-tools`, base's documented self-use of
  # the docker namespace, which touches no service that reads them. One
  # export at the root entry covers every namespace (`just` propagates a
  # root export into module recipes), so raw `docker compose` stays the
  # only refused path -- which is the point of refusing.
  run grep -nE '^export HOST_UID := `id -u`$' "${ROOT}/justfile"
  assert_success
  run grep -nE '^export HOST_GID := `id -g`$' "${ROOT}/justfile"
  assert_success
}

@test "just test system supplies the host identity its bare compose run needs (#895)" {
  # The bare `docker compose run --rm ci-system` here is the one `just test`
  # path that does not go through test.sh's _run_via_compose, so it is the
  # one that has to export HOST_UID / HOST_GID itself. Without them the
  # containers wrote the mounted checkout as whatever compose defaulted to.
  run grep -nE '^ +export HOST_UID HOST_GID$' "${ROOT}/script/test/justfile.test"
  assert_success
  run grep -nE 'HOST_UID="\$\(id -u\)"' "${ROOT}/script/test/justfile.test"
  assert_success
  run grep -nE 'HOST_GID="\$\(id -g\)"' "${ROOT}/script/test/justfile.test"
  assert_success
}

@test "just test system names the compose project instead of inheriting the basename (#891)" {
  # Its `docker compose run --rm ci-system` is a second call site with the
  # same defect test.sh had: no -p and no COMPOSE_PROJECT_NAME means compose
  # falls back to the checkout directory's basename.
  run grep -nE 'test\.sh --compose-project-name' "${ROOT}/script/test/justfile.test"
  assert_success
  run grep -nE '^ +export COMPOSE_PROJECT_NAME$' "${ROOT}/script/test/justfile.test"
  assert_success
}

# ── base self-use has no .env.generated, and never will ──────────────────
#
# `.env.generated` is a CONFIGURED CONSUMER's interpolation cache, written
# by `setup apply` from a `.setup.conf`. base is the template SOURCE: it
# ships a hand-authored compose.yaml, has no `.setup.conf` and no `.base/`
# subtree, and _wrapper_setup_sync deliberately returns early for exactly
# that shape -- so nothing in a base checkout ever writes the file.
#
# build.sh and prune.sh already treated it as optional. stop / run / exec
# sourced it unconditionally and died on `No such file or directory`
# before reaching compose, which left `just docker build` in a base
# checkout minting a project that no `just` verb could end. Generating one
# to get a stop is not the answer either: it would write files into the
# tree that is under test.
#
# The assertion is behavioural, not a grep for the guard: what matters is
# that the wrapper REACHES compose, and only running it can say that.

# _base_shaped_checkout <dir>
#   A checkout with base's own layout: dist/ at the root, flat wrapper
#   symlinks under script/, its own test entry (the one producer of the
#   tooling tag its hand-authored compose.yaml interpolates) and the
#   tooling Dockerfile that tag is a content hash of; no .base/, no
#   .setup.conf, no .env.generated.
#
#   script/adr comes along because script/test needs it: test.sh sources
#   every lint driver at startup, whatever verb it was handed, and the
#   ADR-numbering driver sources script/adr/references.sh for the file set
#   it shares with the renumber verb. A checkout with one and not the
#   other is not base-shaped.
_base_shaped_checkout() {
  local _dir="${1:?_base_shaped_checkout requires a dir}"
  mkdir -p "${_dir}/dist/script/docker/lib" "${_dir}/dist/script/docker/wrapper" \
           "${_dir}/dockerfile" "${_dir}/script"
  cp /source/dist/script/docker/lib/* "${_dir}/dist/script/docker/lib/"
  cp /source/dist/script/docker/wrapper/*.sh "${_dir}/dist/script/docker/wrapper/"
  cp /source/compose.yaml "${_dir}/compose.yaml"
  cp /source/dockerfile/Dockerfile.test-tools "${_dir}/dockerfile/"
  cp -r /source/script/test "${_dir}/script/test"
  cp -r /source/script/adr "${_dir}/script/adr"
  local _w
  for _w in build run exec stop prune; do
    ln -s "../dist/script/docker/wrapper/${_w}.sh" "${_dir}/script/${_w}.sh"
  done
  assert [ ! -e "${_dir}/.base" ]
  assert [ ! -e "${_dir}/.setup.conf" ]
  assert [ ! -e "${_dir}/.env.generated" ]
}

# _recording_docker <dir>
#   Put a `docker` on PATH that records, per call, the value of
#   TEST_TOOLS_IMAGE it was handed and the argv it was given, then
#   succeeds. Every compose call a wrapper makes is a line in
#   ${DOCKER_CALLS_FILE}.
#
#   A stub, because the assertion is about what the WRAPPER exports before
#   it hands compose.yaml over -- not about what compose then does with it.
#   compose's own behaviour is not in question: the file names
#   `${TEST_TOOLS_IMAGE:?...}` with no default, so an unset value is an
#   interpolation error whatever verb follows.
_recording_docker() {
  local _dir="${1:?_recording_docker requires a dir}"
  mkdir -p "${_dir}/bin"
  DOCKER_CALLS_FILE="${_dir}/docker-calls.txt"
  export DOCKER_CALLS_FILE
  : > "${DOCKER_CALLS_FILE}"
  cat > "${_dir}/bin/docker" <<'EOS'
#!/usr/bin/env bash
printf 'TEST_TOOLS_IMAGE=%s argv=%s\n' \
  "${TEST_TOOLS_IMAGE-<unset>}" "$*" >> "${DOCKER_CALLS_FILE}"
exit 0
EOS
  chmod +x "${_dir}/bin/docker"
  export PATH="${_dir}/bin:${PATH}"
}

# why: the env-load half: base never writes an interpolation cache, so a stop that
# dies sourcing one is a flow `just docker build` can start and no verb can
# end. Says only that the wrapper gets as far as building a compose command
# -- `--dry-run` returns before compose is called, so it cannot speak for
# what compose is handed. That is the test below.
@test "just docker stop builds a compose command with no .env.generated (#1015)" {
  local _tmp
  _tmp="$(mktemp -d)"
  _base_shaped_checkout "${_tmp}"
  run bash "${_tmp}/script/stop.sh" --dry-run
  rm -rf "${_tmp}"
  assert_success
  assert_output --regexp '\[dry-run\] docker compose -p [a-zA-Z0-9._-]+ .* down'
}

# why: exec carried the same unconditional source as stop, so the whole
# build -> run -> exec -> stop flow was dead in a self-managed checkout, not
# just its last verb.
@test "just docker exec reaches compose in a checkout with no .env.generated (#1015)" {
  local _tmp
  _tmp="$(mktemp -d)"
  _base_shaped_checkout "${_tmp}"
  run bash "${_tmp}/script/exec.sh" --dry-run
  local _status="${status}" _output="${output}"
  rm -rf "${_tmp}"
  status="${_status}"; output="${_output}"
  refute_output --partial "No such file or directory"
}

# why: the third wrapper with the same defect. Fixing only the verb named in the
# report would have left the flow it belongs to still broken.
@test "just docker run reaches compose in a checkout with no .env.generated (#1015)" {
  local _tmp
  _tmp="$(mktemp -d)"
  _base_shaped_checkout "${_tmp}"
  run bash "${_tmp}/script/run.sh" --dry-run
  local _status="${status}" _output="${output}"
  rm -rf "${_tmp}"
  status="${_status}"; output="${_output}"
  refute_output --partial "No such file or directory"
}

# ── reaching compose is not the same as compose reading the file ─────────
#
# A self-managed checkout's hand-authored compose.yaml names every image
# `${TEST_TOOLS_IMAGE:?...}` with NO default, and compose interpolates the
# WHOLE file whatever verb it is handed -- `down` and `ps` included. So a
# wrapper that reaches compose without that value in its environment still
# tears nothing down: it dies at interpolation, naming five services,
# before the verb runs. `just docker build` resolves the tag because it
# BUILDS with it, which is why build works and the verbs that END a flow
# did not.
#
# These run the wrapper for real against a recording `docker`, because
# `--dry-run` cannot see it: dry-run never calls compose.

# why: the verb that ENDS the flow has to hand compose the one value its
# compose.yaml refuses to be read without, and it has to be the value the
# checkout's own resolver produces -- a second derivation would agree today
# and drift tomorrow.
@test "just docker stop hands compose the tooling tag its compose.yaml demands (#1015)" {
  local _tmp _expected
  _tmp="$(mktemp -d)"
  _base_shaped_checkout "${_tmp}"
  _recording_docker "${_tmp}"
  _expected="$("${_tmp}/script/test/test.sh" --test-tools-image)"
  assert [ -n "${_expected}" ]
  run bash "${_tmp}/script/stop.sh"
  run cat "${DOCKER_CALLS_FILE}"
  rm -rf "${_tmp}"
  assert_output --partial "TEST_TOOLS_IMAGE=${_expected}"
  refute_output --partial "TEST_TOOLS_IMAGE=<unset>"
}

# why: exec asks the same file the same way (its running-service precheck is a
# `compose ps`), so fixing only stop would leave the flow broken one verb
# earlier.
@test "just docker exec hands compose the tooling tag its compose.yaml demands (#1015)" {
  local _tmp _expected
  _tmp="$(mktemp -d)"
  _base_shaped_checkout "${_tmp}"
  _recording_docker "${_tmp}"
  _expected="$("${_tmp}/script/test/test.sh" --test-tools-image)"
  assert [ -n "${_expected}" ]
  run bash "${_tmp}/script/exec.sh" true
  run cat "${DOCKER_CALLS_FILE}"
  rm -rf "${_tmp}"
  assert_output --partial "TEST_TOOLS_IMAGE=${_expected}"
  refute_output --partial "TEST_TOOLS_IMAGE=<unset>"
}
