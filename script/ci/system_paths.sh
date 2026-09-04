#!/usr/bin/env bash
#
# system_paths.sh -- which paths can change what the SYSTEM specs observe.
#
# `system_relevant` in self-test.yaml's classify job decides whether the
# docker.sock-mounted system job runs at all. It used to be decided by a
# list of seventeen paths written into the workflow, and a list written by
# hand names what somebody remembered: it carried
# `dist/script/docker/wrapper/setup.sh` and not `setup_tui.sh`, base's own
# `script/entrypoint.sh` and not the one that ships, every wrapper `.sh`
# and none of the justfiles that dispatch them -- in a repo whose stated
# position is that `just` is the only control surface. It did not carry
# `dockerfile/Dockerfile.smoke`, which is the file the only spec that
# builds it names in the line that builds it. Editing any of those alone
# skipped the one job that exercises them.
#
# So the list is not extended here, it is REPLACED by the answer to the
# question `system_relevant` is named for. The system under test is:
#
#   dist/**            the template AS SHIPPED. Its Dockerfile is what the
#                      system specs build, its smoke specs are what that
#                      build RUNs, its runtime is what runs inside the
#                      container they start, its wrappers and justfiles
#                      are how anything reaches any of it, and its config
#                      and deploy payloads are what the field-deploy
#                      end-to-end spec assembles. Every path the audit
#                      named is inside it, and so is the next one.
#
#   script/**          base's own harness: the runner the system job
#                      invokes, the CI scripts that decide WHICH IMAGE it
#                      runs in, and base's self-use justfiles. Wider than
#                      the `script/ci/**` the previous list carried, for
#                      the same reason that one was: the directory is
#                      listed rather than each file, which is what keeps
#                      the next script from landing outside the gate by
#                      omission.
#
#   dockerfile/**      the images the specs build directly -- Dockerfile
#                      .smoke and Dockerfile.test-tools.
#
#   test/bats/system/** the specs themselves, and test/fixtures/** the
#                      trees they build.
#
#   compose.yaml, justfile, init.sh, .dockerignore
#                      base's own top-level surface: the compose file the
#                      system job runs through, base's root `just` entry,
#                      the installer a scaffolded consumer runs, and the
#                      file that decides what reaches a build context at
#                      all.
#
#   .github/workflows/** the workflows that run them.
#
# What is deliberately OUTSIDE, because that is what the output is for:
# `doc/**`, `README.md`, `CONTEXT.md`, `LICENSE`, `.claude/**` and the
# unit / integration / acceptance spec trees. A PR touching only those
# skips a docker.sock-mounted compose run it cannot affect.
#
# Both directions are asserted in test/bats/unit/system_paths_spec.bats:
# every subject a system spec names must be selected by a line below, and
# every line below must select something that exists.
#
# Output: one git pathspec per line on stdout. The consumer is
# self-test.yaml's classify step, which fails OPEN -- an unreadable or
# empty list classifies the PR as system-relevant, because "cannot tell"
# must not mean "skip the job".
#
# Style: Google Shell Style Guide.

set -euo pipefail

main() {
  cat <<'PATHS'
dist/**
script/**
dockerfile/**
test/bats/system/**
test/fixtures/**
.github/workflows/**
compose.yaml
justfile
init.sh
.dockerignore
PATHS
}

main "$@"
