#!/usr/bin/env bats
#
# worker_preflight_yaml_spec.bats -- structural assertions that the
# reusable workers wire in the caller-contract preflight.
#
# The preflight LOGIC is unit-tested in ci_preflight_spec.bats and
# integration-tested in ci_preflight_contract_spec.bats. These tests lock
# the thin GHA wiring: a preflight job that (a) runs before the real work
# gates on it, (b) fetches the validator + manifest from base at the SAME
# ref as the worker (github.job_workflow_sha, so the validator can never
# drift from the worker it guards), and (c) calls preflight.sh with the
# per-worker manifest and the real inputs exported into the env vars the
# manifest names.
#
# why: Structural assertions that `build-worker.yaml` and
# `release-worker.yaml` wire in the caller-contract preflight: a `preflight`
# job that the real build / release job gates on (its `needs:` list includes
# it), fetching the validator + manifest from base at the worker's own ref
# (`github.job_workflow_sha`, so the validator can never drift from the
# worker it guards), then calling `preflight.sh` with the per-worker
# manifest and the real inputs exported into the env vars the manifest names
# (plus a GHCR-login probe feeding the packages-permission check on the
# build side). #801 adds the build side's `cache_backend` export into the
# manifest guard env and a REAL packages: write probe (a GHCR blob-upload
# scope check, not a bare login) for the registry backend.

bats_require_minimum_version 1.5.0

BUILD_WF="/source/.github/workflows/build-worker.yaml"
RELEASE_WF="/source/.github/workflows/release-worker.yaml"

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  assert_spec_subject "${BUILD_WF}" \
      "the reusable build worker this spec pins"
  assert_spec_subject "${RELEASE_WF}" \
      "the reusable release worker this spec pins"
}

# ── build-worker.yaml ─────────────────────────────────────────────────

@test "build-worker.yaml: declares a preflight job (#800)" {
  run code_grep -E '^  preflight:$' "${BUILD_WF}"
  assert_success
}

@test "build-worker.yaml: build job gates on preflight (#800)" {
  # The heavy build must not start unless preflight passed. Assert the
  # build job's needs: list includes preflight.
  run code_grep -E '^    needs: \[.*preflight.*\]$' "${BUILD_WF}"
  assert_success
}

@test "build-worker.yaml: preflight fetches the validator at the worker's own ref (job_workflow_sha, no drift) (#800)" {
  run code_grep -F 'ref: ${{ github.job_workflow_sha }}' "${BUILD_WF}"
  assert_success
  run code_grep -F 'repository: ycpss91255-docker/base' "${BUILD_WF}"
  assert_success
}

@test "build-worker.yaml: preflight runs preflight.sh with the build manifest (#800)" {
  run code_grep -F 'script/ci/preflight.sh' "${BUILD_WF}"
  assert_success
  run code_grep -F 'script/ci/preflight/build.manifest' "${BUILD_WF}"
  assert_success
}

@test "build-worker.yaml: preflight exports image_name into the manifest env var (#800)" {
  run code_grep -F 'PREFLIGHT_INPUT_IMAGE_NAME: ${{ inputs.image_name }}' "${BUILD_WF}"
  assert_success
}

# ── the manifest a worker guards itself with ──────────────────────────

# _worker_manifest_pairs
#   Every `<worker-file>|<manifest-file>` pair the TREE declares: each
#   reusable worker, and the preflight manifest its own `run:` lines name.
#   Both halves are derived -- the worker list from `on: workflow_call`, the
#   manifest from the path the worker actually passes to preflight.sh -- so a
#   worker added tomorrow, or a manifest renamed, is read here rather than
#   remembered.
_worker_manifest_pairs() {
    local _wf _m _one _status
    while IFS= read -r _wf; do
        [[ -n "${_wf}" ]] || continue
        case "${_wf}" in BUG:*) printf '%s\n' "${_wf}" ; continue ;; esac
        _status=0
        _m="$(yaml_run_blocks "${_wf}" \
            | grep -oE 'preflight/[A-Za-z0-9_.-]+\.manifest' \
            | sort -u)" || _status=$?
        case "${_status}" in
            0) ;;
            1) continue ;;
            *) printf 'BUG: grep exited %s reading %s\n' "${_status}" "${_wf}"
               continue ;;
        esac
        while IFS= read -r _one; do
            [[ -n "${_one}" ]] || continue
            printf '%s|/source/script/ci/%s\n' "${_wf}" "${_one}"
        done <<< "${_m}"
    done < <(reusable_workflow_files)
}

# _unsatisfiable_manifest_permissions
#   One line per permission requirement a manifest declares that NO job of
#   the worker consuming it can ever hold. A `permission|<scope>|...` line is
#   a promise to the caller that granting <scope> makes the worker work; a
#   called job gets exactly the block it declares and a caller's grant never
#   widens it, so the promise is only true when some job of that worker
#   declares the scope at `write`.
_unsatisfiable_manifest_permissions() {
    local _pair _wf _mf _scope _surface _status
    while IFS= read -r _pair; do
        [[ -n "${_pair}" ]] || continue
        case "${_pair}" in BUG:*) printf '%s\n' "${_pair}" ; continue ;; esac
        _wf="${_pair%%|*}"
        _mf="${_pair#*|}"
        [[ -f "${_mf}" ]] || {
            printf 'BUG: %s names %s, which is not a file\n' "${_wf}" "${_mf}"
            continue
        }
        _status=0
        _surface="$(yaml_permission_surface "${_wf}")" || _status=$?
        if [[ "${_status}" -ne 0 ]]; then
            printf '%s\n' "${_surface}"
            continue
        fi
        while IFS='|' read -r _kind _scope _rest; do
            [[ "${_kind}" == "permission" ]] || continue
            _status=0
            printf '%s\n' "${_surface}" \
                | grep -E ": ${_scope}:[[:space:]]*write\$" >/dev/null \
                || _status=$?
            case "${_status}" in
                0) ;;
                1) printf '%s requires %s: write, but no job of %s declares it\n' \
                       "${_mf}" "${_scope}" "${_wf}" ;;
                *) printf 'BUG: grep exited %s scanning the surface of %s\n' \
                       "${_status}" "${_wf}" ;;
            esac
        done < <(grep -v '^#' "${_mf}")
    done < <(_worker_manifest_pairs)
}

# why: A preflight requirement the worker itself makes unsatisfiable is
# worse than no preflight: it fails every caller that follows its
# instructions, and the instructions cannot be followed. `cache_backend:
# registry` shipped in exactly that state for two releases (#980) -- the
# manifest told the caller to grant `packages: write`, and every job of the
# worker declared a block without it, so the probe could not come back 202
# whatever the caller did. Derived on both sides: the worker roster from `on:
# workflow_call`, the manifest from the path the worker passes to
# preflight.sh, the grant from the parsed permission surface.
@test "reusable workers: no preflight manifest demands a permission its worker cannot hold (#980)" {
  local _pairs
  _pairs="$(_worker_manifest_pairs | awk 'END { print NR }')"
  [[ "${_pairs}" -ge 2 ]] || fail \
      "expected at least the build + release worker/manifest pairs, derived ${_pairs} -- the scan below would have read an empty pairing as a clean one"
  run _unsatisfiable_manifest_permissions
  assert_success
  assert_output ''
}

# ── release-worker.yaml ───────────────────────────────────────────────

@test "release-worker.yaml: declares a preflight job (#800)" {
  run code_grep -E '^  preflight:$' "${RELEASE_WF}"
  assert_success
}

@test "release-worker.yaml: release job gates on preflight (#800)" {
  run code_grep -E '^    needs: \[.*preflight.*\]$' "${RELEASE_WF}"
  assert_success
}

@test "release-worker.yaml: preflight runs preflight.sh with the release manifest (#800)" {
  run code_grep -F 'script/ci/preflight/release.manifest' "${RELEASE_WF}"
  assert_success
}

@test "release-worker.yaml: preflight exports archive_name_prefix into the manifest env var (#800)" {
  run code_grep -F 'PREFLIGHT_INPUT_ARCHIVE_NAME_PREFIX: ${{ inputs.archive_name_prefix }}' "${RELEASE_WF}"
  assert_success
}
