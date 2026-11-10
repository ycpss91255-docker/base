#!/usr/bin/env bats
#
# build_worker_cache_export_warn_spec.bats -- unit tests for
# script/ci/build_worker/cache_export_warn.sh, the step that runs after a
# build whose cache-to carries ignore-error=true and turns a failed cache
# export into a `::warning::` annotation instead of a red build, base#1602.
#
# The script reads the build's metadata (BUILD_METADATA, the JSON
# docker/build-push-action emits as `outputs.metadata`) for
# `buildx.build.ref`, replays that build record with
# `docker buildx history logs --progress plain`, and checks how each cache
# export vertex ended. `docker` is a PATH stub that prints a recorded
# progress log, so each test pins one ending.
#
# why: With ignore-error=true a failed cache export no longer fails the
# build, so without this step it would also leave no trace. These specs pin
# that a good export stays silent and a failed one warns, without ever
# failing the job, base#1602.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  SCRIPT="/source/script/ci/build_worker/cache_export_warn.sh"
  assert_spec_subject "${SCRIPT}" \
      "the build-worker cache-export warning script under test"

  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${STUB_BIN}"
  RECORD="${BATS_TEST_TMPDIR}/record.log"
  export RECORD
  # docker stub: whatever it is asked, print the recorded progress log.
  cat > "${STUB_BIN}/docker" <<'EOS'
#!/usr/bin/env bash
cat "${RECORD}"
EOS
  chmod +x "${STUB_BIN}/docker"
  PATH="${STUB_BIN}:${PATH}"
  export PATH

  export BUILD_METADATA='{"buildx.build.ref":"builder-1/builder-10/pb63qejbo0000000000000000"}'
  export CACHE_EXPORT_LABEL="devel-test"
}

@test "cache_export_warn: an export vertex that ends in DONE prints nothing and exits 0 (base#1602)" {
  # The cache export vertex of a good build, copied from the progress log
  # of ycpss91255-docker/isaac run 42753553284 attempt 1 (vertex #63);
  # the middle of its writing-layer lines is cut, the ending is verbatim.
  cat > "${RECORD}" <<'EOS'
#62 [devel 9/9] RUN true
#62 DONE 0.1s

#63 exporting to GitHub Actions Cache
#63 preparing build cache for export
#63 preparing build cache for export 283.3s done
#63 sending cache export
#63 writing layer sha256:0961586389cedd4a925be061078d2592b548f7036cd63be81c42071f70d08b2c
#63 writing layer sha256:0961586389cedd4a925be061078d2592b548f7036cd63be81c42071f70d08b2c 0.6s done
#63 writing layer sha256:fe39618c520b709d1e61e2c7116f9b0efb22ea913767c950f50e141f938a7ae9
#63 writing layer sha256:fe39618c520b709d1e61e2c7116f9b0efb22ea913767c950f50e141f938a7ae9 0.3s done
#63 sending cache export 1773.6s done
#63 DONE 2056.9s
EOS
  run bash "${SCRIPT}"
  assert_success
  assert_output ""
}
