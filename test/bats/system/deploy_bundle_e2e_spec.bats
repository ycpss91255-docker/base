#!/usr/bin/env bats
#
# System-level end-to-end: a REAL field deploy (ISTQB System level,
# ADR-00000018; ADR-00000023). Exercises the full orchestration for real --
# generate the bundle (real docker build + docker save | xz), docker-load
# the image, run the generated deploy.sh up (real docker compose up -d),
# assert the container is Up, then assert the tunable-config override applies
# at the mounted container path (edit the bundle config/, re-up, read it back
# in the container), and tear down with deploy.sh down.
#
# Minimal + fast on purpose: a tiny alpine `runtime` stage that runs a
# long-lived `sleep` and bakes one tunable config file. The point is the
# orchestration (build -> save -> load -> compose up -> mount-wins override
# -> down), not a heavy image.
#
# Requires the ci-system compose service (mounts host /var/run/docker.sock +
# the docker compose plugin + xz in the test-tools image). Auto-skips when
# the socket / plugin / xz is absent so accidental invocation via the default
# `ci` service is harmless. Run it with `just test system`.
#
# Plain-bash assertions only (status / output), matching the sibling
# runtime_test_smoke_spec.bats: the system bats environment ships no
# bats-assert / bats-support and loads no test_helper.

setup_file() {
  if [[ ! -S /var/run/docker.sock ]]; then
    skip "system test: /var/run/docker.sock not mounted (run via 'just test system')"
  fi
  if ! command -v docker >/dev/null 2>&1; then
    skip "system test: docker CLI not present"
  fi
  if ! docker compose version >/dev/null 2>&1; then
    skip "system test: docker compose plugin not present"
  fi
  if ! command -v xz >/dev/null 2>&1; then
    skip "system test: xz not present"
  fi

  export LOG_FORMAT=text
  # shellcheck disable=SC1091
  source /source/dist/script/docker/wrapper/setup.sh

  # Fixture repo: the dir basename becomes the image name (detect_image_name
  # @basename rule). A tiny runtime stage that bakes one tunable config file
  # and runs a long-lived process.
  #
  # Build the bundle under the SAME-PATH host mount (see compose.yaml
  # ci-system): the generated deploy.sh runs `docker compose up`, whose
  # bind-mount sources the HOST daemon resolves -- a bundle in this
  # container's private /tmp is invisible to that daemon. Placing it at a
  # path mounted identically on host + container makes the config bind
  # resolve. Outside ci-system (a plain local daemon) it is just a temp dir.
  local _align="/tmp/base-deploy-e2e"
  mkdir -p "${_align}"
  TMP_ROOT="$(mktemp -d "${_align}/e2e-XXXXXX")"
  REPO="${TMP_ROOT}/deploydemo"
  mkdir -p "${REPO}/config/app_cfg"

  printf '%s\n' \
    "[deploy]" "gpu_mode = off" "dri_groups = off" \
    "[gui]" "mode = off" \
    > "${REPO}/.setup.conf"

  cat > "${REPO}/Dockerfile" <<'DOCK'
FROM alpine:3.20 AS sys
FROM sys AS runtime
RUN mkdir -p /etc/app && printf 'baked-default\n' > /etc/app/host.yaml
CMD ["sleep", "infinity"]
DOCK

  # Tunable-config manifest: one operator-tunable path baked in the image.
  printf '%s\n' "[runtime]" "/etc/app/host.yaml" \
    > "${REPO}/config/app_cfg/deploy.manifest"

  VERSION="$(_resolve_deploy_version "${REPO}")"
  BUNDLE="${REPO}/deploy/deploydemo-runtime-${VERSION}"
  CNAME="deploydemo-runtime"
  IMAGE="deploydemo:runtime-${VERSION}"
  export TMP_ROOT REPO BUNDLE CNAME IMAGE VERSION

  # Generate the bundle for real (docker build + save | xz + config extract).
  # A failure here is a genuine deploy bug (the socket/plugin/xz are present),
  # so fail loudly with the captured output rather than skipping.
  local _gen_out=""
  if ! _gen_out="$(_setup_deploy --base-path "${REPO}" --stage runtime -y -q 2>&1)"; then
    printf 'bundle generation FAILED:\n%s\n' "${_gen_out}" >&2
    return 1
  fi
}

teardown_file() {
  if [[ -n "${BUNDLE:-}" && -f "${BUNDLE}/deploy.sh" ]]; then
    "${BUNDLE}/deploy.sh" down >/dev/null 2>&1 || true
  fi
  [[ -n "${IMAGE:-}" ]] && docker rmi -f "${IMAGE}" >/dev/null 2>&1 || true
  [[ -n "${TMP_ROOT:-}" ]] && rm -rf "${TMP_ROOT}"
}

@test "field-deploy e2e: the generator produced a self-contained bundle folder" {
  [ -d "${BUNDLE}" ]
  [ -f "${BUNDLE}/image.tar.xz" ]
  [ -x "${BUNDLE}/deploy.sh" ]
  [ -f "${BUNDLE}/config/host.yaml" ]

  run cat "${BUNDLE}/compose.yaml"
  [ "${status}" -eq 0 ]
  # Fully resolved -- no compose variable interpolation survives.
  [[ "${output}" != *'${'* ]]
  [[ "${output}" == *"image: ${IMAGE}"* ]]
  [[ "${output}" == *"restart: unless-stopped"* ]]
  [[ "${output}" == *"- ./config/host.yaml:/etc/app/host.yaml"* ]]
}

@test "field-deploy e2e: deploy.sh up loads the image, runs the container, and the tunable override applies" {
  # Real load + compose up. Echo output on failure so a genuine deploy bug
  # is debuggable in the CI log rather than a bare non-zero status.
  run "${BUNDLE}/deploy.sh" up
  [ "${status}" -eq 0 ] || { echo "deploy.sh up failed (status=${status}):"; echo "${output}"; false; }

  # The container is actually running.
  run docker ps --filter "name=${CNAME}" --filter "status=running" --format '{{.Names}}'
  [[ "${output}" == *"${CNAME}"* ]] || { echo "container not running; docker ps: ${output}"; false; }

  # The mounted editable copy carries the image's baked default.
  run docker exec "${CNAME}" cat /etc/app/host.yaml
  [ "${status}" -eq 0 ] || { echo "exec failed: ${output}"; false; }
  [[ "${output}" == *"baked-default"* ]]

  # Edit the bundle config in the "field" and re-up: the mount wins over the
  # baked default, so the container now sees the edited value (no rebuild).
  printf 'edited-in-field\n' > "${BUNDLE}/config/host.yaml"
  run "${BUNDLE}/deploy.sh" up
  [ "${status}" -eq 0 ] || { echo "deploy.sh re-up failed (status=${status}):"; echo "${output}"; false; }
  run docker exec "${CNAME}" cat /etc/app/host.yaml
  [ "${status}" -eq 0 ] || { echo "exec after override failed: ${output}"; false; }
  [[ "${output}" == *"edited-in-field"* ]] || { echo "override not applied; got: ${output}"; false; }

  # deploy.sh down stops it.
  run "${BUNDLE}/deploy.sh" down
  [ "${status}" -eq 0 ] || { echo "deploy.sh down failed: ${output}"; false; }
  run docker ps --filter "name=${CNAME}" --filter "status=running" --format '{{.Names}}'
  [[ "${output}" != *"${CNAME}"* ]]
}
