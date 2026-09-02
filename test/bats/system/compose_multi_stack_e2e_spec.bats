#!/usr/bin/env bats
#
# System-level end-to-end: two stacks of ONE repo, co-hosted (ISTQB System
# level, ADR-00000018). Drives the emitted compose.yaml against a real
# daemon under two distinct project names and asserts that both come up,
# and that `--scale` gives a service more than one container.
#
# Reading the emitted file cannot answer either question. Compose is what
# refuses a duplicate container name, and compose is what refuses to scale
# a service that has one -- so "no container_name in the output" is a
# proxy, and the thing it stands for is only observable by running. That is
# the acceptance criterion this file exists for.
#
# The fixture is a real repo run through `setup apply`, not a hand-written
# compose file: the emitter is the subject, so anything hand-authored here
# would test the fixture instead. It is deliberately tiny (alpine + sleep)
# and needs NO bind mounts -- with gui/gpu off the emitted devel service
# carries no volumes, so nothing has to resolve a host path, and the build
# context is streamed by the client.
#
# Requires the ci-system compose service (mounts host /var/run/docker.sock
# + the docker compose plugin in the test-tools image). Auto-skips when the
# socket / plugin is absent so accidental invocation via the default `ci`
# service is harmless. Run it with `just test system`.
#
# Plain-bash assertions only (status / output), matching the sibling
# runtime_test_smoke_spec.bats / deploy_bundle_e2e_spec.bats: the system
# bats environment ships no bats-assert / bats-support.

setup_file() {
  # Every test here drives ONE fixture repo and ONE image tag, so they must
  # not run concurrently with each other. The suite still parallelizes
  # across FILES.
  export BATS_NO_PARALLELIZE_WITHIN_FILE=true

  if [[ ! -S /var/run/docker.sock ]]; then
    skip "system test: /var/run/docker.sock not mounted (run via 'just test system')"
  fi
  if ! command -v docker >/dev/null 2>&1; then
    skip "system test: docker CLI not present"
  fi
  if ! docker compose version >/dev/null 2>&1; then
    skip "system test: docker compose plugin not present"
  fi

  export LOG_FORMAT=text
  # shellcheck disable=SC1091
  source /source/dist/script/docker/wrapper/setup.sh

  TMP_ROOT="$(mktemp -d -t base-multistack-XXXXXX)"
  # The repo basename becomes the image name (detect_image_name @basename
  # rule), so a run-unique, lowercase one keeps a crashed earlier run's
  # leftovers out of this run's assertions.
  local _uniq
  _uniq="$(printf '%s' "${TMP_ROOT##*-}" | tr '[:upper:]' '[:lower:]')"
  REPO="${TMP_ROOT}/multistack${_uniq}"
  mkdir -p "${REPO}"

  cat > "${REPO}/Dockerfile" <<'DOCK'
FROM alpine:3.20 AS sys
FROM sys AS devel-base
FROM devel-base AS devel
CMD ["sleep", "infinity"]
DOCK

  # gpu / gui off: the emitted devel service then carries no device
  # reservation and no X11 volumes, which is what keeps this fixture
  # host-independent.
  printf '%s\n' \
    "[deploy]" "gpu_mode = off" "dri_groups = off" \
    "[gui]" "mode = off" \
    > "${REPO}/.setup.conf"

  local _apply_out=""
  if ! _apply_out="$(main apply --base-path "${REPO}" 2>&1)"; then
    printf 'setup apply FAILED:\n%s\n' "${_apply_out}" >&2
    return 1
  fi

  # Two projects for the same repo -- the isolation a co-hosted CI stack
  # and a manual stack actually use -- plus a third for the scale case.
  PROJ_A="multistack${_uniq}-a"
  PROJ_B="multistack${_uniq}-b"
  PROJ_S="multistack${_uniq}-s"
  export TMP_ROOT REPO PROJ_A PROJ_B PROJ_S
}

teardown_file() {
  local _p
  for _p in "${PROJ_A:-}" "${PROJ_B:-}" "${PROJ_S:-}"; do
    [[ -n "${_p}" ]] || continue
    _stack "${_p}" down --remove-orphans >/dev/null 2>&1 || true
  done
  [[ -n "${TMP_ROOT:-}" ]] && rm -rf "${TMP_ROOT}"
}

# _stack <project> <compose args...> -- the emitted stack under one project
# name, exactly as the wrapper drives it (-p / -f / --env-file).
_stack() {
  local _project="$1"
  shift
  docker compose -p "${_project}" \
    -f "${REPO}/compose.yaml" \
    --env-file "${REPO}/.env.generated" \
    "$@"
}

@test "co-hosted stacks: two project names bring the SAME repo up twice (#920)" {
  # The bug: a baked container_name is namespaced by the daemon, not by the
  # project, so the second `up` died with `name ... is already in use`
  # however the project was named. Both `up`s succeeding IS the fix.
  run _stack "${PROJ_A}" up -d devel
  [ "${status}" -eq 0 ] || { echo "first up failed:"; echo "${output}"; false; }

  run _stack "${PROJ_B}" up -d devel
  [ "${status}" -eq 0 ] || { echo "second up failed (name collision?):"; echo "${output}"; false; }

  # Both are genuinely up, each inside its OWN project.
  local _a _b
  _a="$(_stack "${PROJ_A}" ps --status running -q devel)"
  _b="$(_stack "${PROJ_B}" ps --status running -q devel)"
  [ -n "${_a}" ] || { echo "project ${PROJ_A} has no running devel"; false; }
  [ -n "${_b}" ] || { echo "project ${PROJ_B} has no running devel"; false; }
  [ "${_a}" != "${_b}" ] || { echo "both projects resolved to one container"; false; }

  # The names compose derived are project-scoped, which is why they differ.
  local _na _nb
  _na="$(docker inspect -f '{{.Name}}' "${_a}")"
  _nb="$(docker inspect -f '{{.Name}}' "${_b}")"
  [[ "${_na}" == *"${PROJ_A}"* ]] || { echo "name not project-scoped: ${_na}"; false; }
  [[ "${_nb}" == *"${PROJ_B}"* ]] || { echo "name not project-scoped: ${_nb}"; false; }
}

@test "co-hosted stacks: tearing one down leaves the other running (#920)" {
  # Project-scoped teardown is only meaningful if the containers are
  # project-scoped too. Ordered after the bring-up above (bats runs a file
  # top to bottom, and this file is serialized).
  run _stack "${PROJ_A}" down --remove-orphans
  [ "${status}" -eq 0 ] || { echo "down failed:"; echo "${output}"; false; }

  local _a _b
  _a="$(_stack "${PROJ_A}" ps --status running -q devel)"
  _b="$(_stack "${PROJ_B}" ps --status running -q devel)"
  [ -z "${_a}" ] || { echo "torn-down project still has a container: ${_a}"; false; }
  [ -n "${_b}" ] || { echo "the OTHER project's container was reaped too"; false; }
}

@test "--scale: one service runs as more than one container (#920)" {
  # Compose refuses `--scale` outright while a service declares
  # container_name ("Compose does not scale a service beyond one container
  # if the Compose file specifies a container_name"), so this asserts the
  # emitted file no longer does -- by scaling.
  run _stack "${PROJ_S}" up -d --scale devel=2 devel
  [ "${status}" -eq 0 ] || { echo "scaled up failed:"; echo "${output}"; false; }

  local _ids _count
  _ids="$(_stack "${PROJ_S}" ps --status running -q devel)"
  _count="$(printf '%s\n' "${_ids}" | grep -c . || true)"
  [ "${_count}" -eq 2 ] || { echo "expected 2 containers, got ${_count}: ${_ids}"; false; }
}
