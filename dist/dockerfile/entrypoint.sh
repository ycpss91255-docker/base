#!/usr/bin/env bash
#
# <repo> container bringup -- the repo-owned half of the entrypoint.
#
# THIS FILE IS NOT THE CONTAINER ENTRYPOINT. base's orchestrator is, at
# /usr/local/lib/base/entrypoint.sh (see the Dockerfile's ENTRYPOINT), and
# it SOURCES this file -- which the Dockerfile installs at /entrypoint.sh --
# between opening the host log tee and arming the watchdog:
#
#   logging.sh  ->  THIS FILE  ->  watchdog.sh  ->  exec "$@"
#
# Two rules follow from being sourced rather than executed:
#
#   1. NO exec. The orchestrator owns the final `exec "$@"`. Taking over
#      the process here replaces the shell mid-source, so the watchdog
#      never arms and the container loses its lifecycle supervision.
#   2. NO base plumbing. Sourcing /usr/local/lib/base/logging.sh or
#      /usr/local/lib/base/watchdog.sh is the orchestrator's job. The
#      orchestrator ships from .base/ and updates with every subtree pull;
#      THIS file is seeded once and is yours from then on, so plumbing
#      written here freezes at the day it was written. That asymmetry is
#      why the two halves are separate files.
#
# What belongs here is the repo's own bringup: whatever the workload needs
# in its environment. It runs with the workload still in "$@", and anything
# it exports reaches both the watchdog's health check and the workload.
# Everything base needs is already wired -- [logging] local_path tees the
# host log and [lifecycle] watchdog_check arms the watchdog with this file
# empty.
#
# Examples (uncomment and adapt):
#
#   # A ROS overlay. `set +u` brackets the source because ROS's setup.bash
#   # chain dereferences unbound vars and the orchestrator runs under
#   # `set -u`; the trailing `--` stops catkin's _setup_util.py from
#   # consuming the workload's own arguments.
#   set +u
#   # shellcheck disable=SC1090,SC1091
#   source "/opt/ros/${ROS_DISTRO}/setup.bash" --
#   set -u
#
#   # Plain environment for the workload.
#   export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"
#
#   # A one-time bringup step (create a runtime dir, wait on a device).
#   mkdir -p "${HOME}/.cache/myapp"
