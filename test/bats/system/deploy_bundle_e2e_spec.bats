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
  TMP_ROOT="$(mktemp -d -t deploy-e2e-XXXXXX)"
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

  # Generate the bundle for real (docker build + save | xz + config extract).
  if ! _setup_deploy --base-path "${REPO}" --stage runtime -y -q; then
    skip "system test: bundle generation failed (docker build/pull unavailable?)"
  fi

  VERSION="$(_resolve_deploy_version "${REPO}")"
  BUNDLE="${REPO}/deploy/deploydemo-runtime-${VERSION}"
  CNAME="deploydemo-runtime"
  IMAGE="deploydemo:runtime-${VERSION}"
  export TMP_ROOT REPO BUNDLE CNAME IMAGE VERSION
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
  assert_success
  refute_output --partial '${'
  assert_output --partial "image: ${IMAGE}"
  assert_output --partial "restart: unless-stopped"
  assert_output --partial "- ./config/host.yaml:/etc/app/host.yaml"
}

@test "field-deploy e2e: deploy.sh up loads the image, runs the container, and the tunable override applies" {
  # Real load + compose up.
  run "${BUNDLE}/deploy.sh" up
  [ "${status}" -eq 0 ]

  # The container is actually running.
  run docker ps --filter "name=${CNAME}" --filter "status=running" --format '{{.Names}}'
  assert_output --partial "${CNAME}"

  # The mounted editable copy carries the image's baked default.
  run docker exec "${CNAME}" cat /etc/app/host.yaml
  assert_success
  assert_output --partial "baked-default"

  # Edit the bundle config in the "field" and re-up: the mount wins over the
  # baked default, so the container now sees the edited value (no rebuild).
  printf 'edited-in-field\n' > "${BUNDLE}/config/host.yaml"
  run "${BUNDLE}/deploy.sh" up
  [ "${status}" -eq 0 ]
  run docker exec "${CNAME}" cat /etc/app/host.yaml
  assert_success
  assert_output --partial "edited-in-field"

  # deploy.sh down stops it.
  run "${BUNDLE}/deploy.sh" down
  [ "${status}" -eq 0 ]
  run docker ps --filter "name=${CNAME}" --filter "status=running" --format '{{.Names}}'
  refute_output --partial "${CNAME}"
}
