#!/usr/bin/env bash
# Tee container stdout/stderr to a host file when [logging] local_path
# is set in setup.conf. No-op when local_path is unset (default), so
# default-sourcing has zero side effect on stock repos. Helper is
# COPY'd into the image at /usr/local/lib/base/ by Dockerfile.example's
# devel stage (+).
# shellcheck disable=SC1091
. /usr/local/lib/base/logging.sh
# Generic single-service watchdog. No-op when [lifecycle]
# watchdog_check is unset (WATCHDOG_CHECK empty), so this source line is
# safe unconditionally. When ON_FAIL=restart-service the watchdog
# supervises the service itself and this script does not reach `exec`.
# shellcheck disable=SC1091
. /usr/local/lib/base/watchdog.sh

exec "${@}"
