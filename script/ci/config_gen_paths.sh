#!/usr/bin/env bash
#
# config_gen_paths.sh -- the config-gen DENY list, base#1584.
#
# Prints one exact repo-relative path per line, with no globs. A pull
# request whose every changed path is a docs path, a spec leaf or one of
# these drops the config-gen job (script/ci/check_selection.sh, row 3).
# Any path not listed here, a new, renamed or moved one included, runs it.
#
# An entry must satisfy all four rules, and
# test/bats/unit/config_gen_paths_spec.bats checks each one:
#   (a) it is a tracked regular file (`git ls-files -s` mode 100644 or
#       100755), never a symlink;
#   (b) it is under dist/ or script/, or it is init.sh or upgrade.sh, and
#       it is never under script/test/, script/ci/, script/watch/ or
#       dist/script/docker/lib/, never dist/script/base/just-version.sh
#       and never a justfile;
#   (c) it is in neither the logical nor the physical reader set
#       script/ci/config_gen_readers.sh prints;
#   (d) no config-gen input text names it: the config-gen job's `run:`
#       blocks, dockerfile/Dockerfile.config-gen and script/test/config_gen*.
# The list below is every tracked path the four rules admit, derived at
# the commit that added this file: the traced run of config_gen_readers.sh
# saw only script/test/config_gen*, script/watch/{lib,pins}.sh,
# script/ci/test-tools-pins.sh, dist/script/base/just-version.sh and
# dist/script/docker/lib/log.sh, all of which rule (b) already excludes.
#
# A path may be added only when the four rules admit it, and the spec
# fails otherwise. A change here is judged by the base side's copy of the
# map, which reads this file under script/ci/ as a row 5 path, so it runs
# every job, the spec included.

set -euo pipefail

cat <<'PATHS'
dist/.hadolint.yaml
dist/.setup.conf
dist/config/shell/bashrc
dist/config/shell/bashrc.d/.gitkeep
dist/config/shell/bashrc.d/30-name-host-groups.sh
dist/config/shell/terminator/config
dist/config/shell/terminator/setup.sh
dist/config/shell/tmux/README.adoc
dist/config/shell/tmux/setup.sh
dist/config/shell/tmux/tmux.conf
dist/deploy/README
dist/deploy/cd-guard.sh
dist/dockerfile/Dockerfile
dist/dockerfile/entrypoint.sh
dist/env.toml
dist/script/base/check-base-version.sh
dist/script/base/completions.sh
dist/script/base/init.sh
dist/script/base/upgrade.sh
dist/script/base/upstream.sh
dist/script/docker/runtime/entrypoint.sh
dist/script/docker/runtime/logging.sh
dist/script/docker/runtime/logrotate.sh
dist/script/docker/runtime/watchdog.sh
dist/script/docker/wrapper/build.sh
dist/script/docker/wrapper/exec.sh
dist/script/docker/wrapper/prune.sh
dist/script/docker/wrapper/run.sh
dist/script/docker/wrapper/setup.sh
dist/script/docker/wrapper/setup_tui.sh
dist/script/docker/wrapper/stop.sh
dist/script/template/new.sh
dist/script/template/skel/skel.sh
dist/setup.toml
dist/test/bats/smoke/devel-test/display_env.bats
dist/test/bats/smoke/devel-test/script_help.bats
dist/test/bats/smoke/runtime-test/.gitkeep
dist/test/bats/smoke/shared/entrypoint.bats
dist/test/bats/smoke/shared/reproducibility.bats
dist/test/bats/smoke/shared/test_helper.bash
dist/test/bats/smoke/smoke.sh
init.sh
script/release/changelog_categories.sh
script/release/changelog_index.sh
script/release/coverage_badge.sh
script/release/release_notes.sh
upgrade.sh
PATHS
