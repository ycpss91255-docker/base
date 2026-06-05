#!/usr/bin/env bats
#
# Tests for the S6 (#506) deploy-generator primitives in
# script/docker/wrapper/setup.sh. S6a delivers _emit_docker_run_flags:
# the pure mapping from a resolved docker-flag record (the
# _resolve_docker_flags S5 output, plus the top-level-only fields
# devices / caps / security_opt / shm_size / dri_groups / cgroup_rules /
# restart) to a `docker run` argv fragment for the field launcher.
#
# [environment] is intentionally NOT mapped (it is baked into the image
# as ENV by S3), and gui is out of scope (the field launcher targets
# headless run; gui / X11 is a dev-only compose concern).

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  # shellcheck disable=SC1091
  source /source/script/docker/wrapper/setup.sh
}

# Helper: join the emitted argv array into a single space-separated line
# so tests can assert on substrings without caring about element count.
_run_line() {
  printf '%s ' "${@}"
}

@test "_emit_docker_run_flags: privileged=true emits --privileged (#506)" {
  local -A _f=([privileged]="true")
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--privileged"
}

@test "_emit_docker_run_flags: gpu count=0 emits --gpus all (#506)" {
  local -A _f=([gpu]="true" [gpu_count]="0" [gpu_caps]="gpu")
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--gpus all"
}

@test "_emit_docker_run_flags: gpu count>0 emits count+capabilities spec (#506)" {
  local -A _f=([gpu]="true" [gpu_count]="2" [gpu_caps]="gpu compute")
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--gpus count=2,capabilities=gpu,compute"
}

@test "_emit_docker_run_flags: gpu=false emits no --gpus (#506)" {
  local -A _f=([gpu]="false" [gpu_count]="2")
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  refute_output --partial "--gpus"
}

@test "_emit_docker_run_flags: runtime=nvidia emits --runtime=nvidia (#506)" {
  local -A _f=([runtime]="nvidia")
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--runtime=nvidia"
}

@test "_emit_docker_run_flags: runtime off/auto/empty emits no --runtime (#506)" {
  local _m
  for _m in "off" "auto" ""; do
    local -A _f=([runtime]="${_m}")
    local -a _out=()
    _emit_docker_run_flags _f _out
    run _run_line "${_out[@]}"
    refute_output --partial "--runtime"
  done
}

@test "_emit_docker_run_flags: net host emits --network=host (#506)" {
  local -A _f=([net_mode]="host")
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--network=host"
}

@test "_emit_docker_run_flags: net bridge + name emits --network=<name> (#506)" {
  local -A _f=([net_mode]="bridge" [net_name]="mynet")
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--network=mynet"
}

@test "_emit_docker_run_flags: net bridge without name emits no --network (default bridge) (#506)" {
  local -A _f=([net_mode]="bridge")
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  refute_output --partial "--network"
}

@test "_emit_docker_run_flags: ipc host emits --ipc=host; private is skipped (#506)" {
  local -A _f=([ipc_mode]="host")
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--ipc=host"
  local -A _f2=([ipc_mode]="private")
  local -a _out2=()
  _emit_docker_run_flags _f2 _out2
  run _run_line "${_out2[@]}"
  refute_output --partial "--ipc"
}

@test "_emit_docker_run_flags: pid host emits --pid=host (#506)" {
  local -A _f=([pid_mode]="host")
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--pid=host"
}

@test "_emit_docker_run_flags: shm_size emitted only when ipc \!= host (#506)" {
  local -A _f=([shm_size]="256m" [ipc_mode]="private")
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--shm-size=256m"
  local -A _f2=([shm_size]="256m" [ipc_mode]="host")
  local -a _out2=()
  _emit_docker_run_flags _f2 _out2
  run _run_line "${_out2[@]}"
  refute_output --partial "--shm-size"
}

@test "_emit_docker_run_flags: restart emitted only when set and \!= no (#506)" {
  local -A _f=([restart]="on-failure")
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--restart=on-failure"
  local -A _f2=([restart]="no")
  local -a _out2=()
  _emit_docker_run_flags _f2 _out2
  run _run_line "${_out2[@]}"
  refute_output --partial "--restart"
}

@test "_emit_docker_run_flags: volumes each emit -v (#506)" {
  local -A _f=([volumes]=$'./a:/a\nstate:/srv/state')
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "-v ./a:/a"
  assert_output --partial "-v state:/srv/state"
}

@test "_emit_docker_run_flags: ports emit -p only under bridge (#506)" {
  local -A _f=([net_mode]="bridge" [ports]=$'8080:80')
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "-p 8080:80"
  local -A _f2=([net_mode]="host" [ports]=$'8080:80')
  local -a _out2=()
  _emit_docker_run_flags _f2 _out2
  run _run_line "${_out2[@]}"
  refute_output --partial "-p 8080:80"
}

@test "_emit_docker_run_flags: plain device -> --device, propagation device -> -v (#506)" {
  local -A _f=([devices]=$'/dev/ttyUSB0\n/dev:/dev:rslave')
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--device /dev/ttyUSB0"
  assert_output --partial "-v /dev:/dev:rslave"
  refute_output --partial "--device /dev:/dev:rslave"
}

@test "_emit_docker_run_flags: caps + security_opt map to docker run flags (#506)" {
  local -A _f=([cap_add]=$'SYS_ADMIN\nNET_ADMIN' [cap_drop]=$'MKNOD' [security_opt]=$'seccomp:unconfined')
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--cap-add SYS_ADMIN"
  assert_output --partial "--cap-add NET_ADMIN"
  assert_output --partial "--cap-drop MKNOD"
  assert_output --partial "--security-opt seccomp:unconfined"
}

@test "_emit_docker_run_flags: dri_groups (space-sep) each map to --group-add (#506)" {
  local -A _f=([dri_groups]="44 110")
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--group-add 44"
  assert_output --partial "--group-add 110"
}

@test "_emit_docker_run_flags: cgroup_rules map to --device-cgroup-rule (#506)" {
  local -A _f=([cgroup_rules]=$'c 81:* rmw')
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--device-cgroup-rule c 81:* rmw"
}

@test "_emit_docker_run_flags: environment and gui are NOT mapped (baked / dev-only) (#506)" {
  local -A _f=([gui]="true" [environment]=$'FOO=bar')
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  refute_output --partial "FOO=bar"
  refute_output --partial "DISPLAY"
  refute_output --partial "X11"
}

@test "_emit_docker_run_flags: empty record emits nothing (#506)" {
  local -A _f=()
  local -a _out=()
  _emit_docker_run_flags _f _out
  assert_equal "${#_out[@]}" "0"
}
