#!/usr/bin/env bats
#
# Tests for the per-service compose emitter and its shared leaf-emitter
# sub-seams, extracted to top level from generate_compose_yaml (#566).
#
# Before #566 these emitters were nested closures inside
# generate_compose_yaml, only reachable by running the whole ~900-line
# function and grepping its YAML output. Hoisting them to top level lets
# each one be exercised in isolation: build the inputs, call the emitter,
# assert on the small fragment it returns.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  # shellcheck disable=SC1091
  source /source/script/docker/wrapper/setup.sh
}

# ════════════════════════════════════════════════════════════════════
# _emit_gpu_deploy_block <gui> <count> <caps_yaml>
# ════════════════════════════════════════════════════════════════════

@test "_emit_gpu_deploy_block: gui=false emits nothing" {
  run _emit_gpu_deploy_block false 1 "[gpu]"
  assert_success
  assert_output ""
}

@test "_emit_gpu_deploy_block: gui=true emits deploy reservation with count + caps" {
  run _emit_gpu_deploy_block true 2 "[gpu, compute]"
  assert_line --partial "deploy:"
  assert_line --partial "count: 2"
  assert_line --partial "capabilities: [gpu, compute]"
  assert_line --partial "driver: nvidia"
}

# ════════════════════════════════════════════════════════════════════
# _emit_caps_block <cap_add> <cap_drop> <sec_opt>
# ════════════════════════════════════════════════════════════════════

@test "_emit_caps_block: all empty emits nothing" {
  run _emit_caps_block "" "" ""
  assert_success
  assert_output ""
}

@test "_emit_caps_block: cap_add list emits cap_add block" {
  run _emit_caps_block $'SYS_PTRACE\nNET_ADMIN' "" ""
  assert_line "    cap_add:"
  assert_line "      - SYS_PTRACE"
  assert_line "      - NET_ADMIN"
  refute_line "    cap_drop:"
}

@test "_emit_caps_block: cap_drop + security_opt emit their blocks" {
  run _emit_caps_block "" $'MKNOD' $'no-new-privileges:true'
  assert_line "    cap_drop:"
  assert_line "      - MKNOD"
  assert_line "    security_opt:"
  assert_line "      - no-new-privileges:true"
}

# ════════════════════════════════════════════════════════════════════
# _emit_env_file_block  (constant)
# ════════════════════════════════════════════════════════════════════

@test "_emit_env_file_block: emits the .env workload overlay block" {
  run _emit_env_file_block
  assert_line "    env_file:"
  assert_line "      - .env"
}

# ════════════════════════════════════════════════════════════════════
# Single-value line/block emitters
# ════════════════════════════════════════════════════════════════════

@test "_emit_target_arch_line: empty omits the line; set emits literal TARGET_ARCH ref" {
  run _emit_target_arch_line ""
  assert_output ""
  run _emit_target_arch_line "arm64"
  assert_output '        TARGETARCH: ${TARGET_ARCH}'
}

@test "_emit_build_network_line: empty omits; set emits network line" {
  run _emit_build_network_line ""
  assert_output ""
  run _emit_build_network_line "host"
  assert_output "      network: host"
}

@test "_emit_runtime_line: empty omits; set emits runtime line" {
  run _emit_runtime_line ""
  assert_output ""
  run _emit_runtime_line "nvidia"
  assert_output "    runtime: nvidia"
}

@test "_emit_restart_line: 'no' omits; plain value plain; on-failure:N quoted" {
  run _emit_restart_line "no"
  assert_output ""
  run _emit_restart_line "always"
  assert_output "    restart: always"
  run _emit_restart_line "on-failure:5"
  assert_output '    restart: "on-failure:5"'
}

@test "_emit_additional_contexts_block: empty omits; entries emit block" {
  run _emit_additional_contexts_block ""
  assert_output ""
  run _emit_additional_contexts_block $'base=../base\nlib=./lib'
  assert_line "      additional_contexts:"
  assert_line "        base: ../base"
  assert_line "        lib: ./lib"
}

@test "_emit_cgroup_rules_block: empty omits; entries emit quoted rules" {
  run _emit_cgroup_rules_block ""
  assert_output ""
  run _emit_cgroup_rules_block $'c 81:* rmw'
  assert_line "    device_cgroup_rules:"
  assert_line '      - "c 81:* rmw"'
}

@test "_emit_tmpfs_block: empty omits; entries emit tmpfs list" {
  run _emit_tmpfs_block ""
  assert_output ""
  run _emit_tmpfs_block $'/run\n/tmp:size=64m'
  assert_line "    tmpfs:"
  assert_line "      - /run"
  assert_line "      - /tmp:size=64m"
}

@test "_emit_group_add_block: gated on gui AND non-empty groups; emits quoted gids" {
  run _emit_group_add_block false "44 video"
  assert_output ""
  run _emit_group_add_block true ""
  assert_output ""
  run _emit_group_add_block true "44 video"
  assert_line "    group_add:"
  assert_line '      - "44"'
  assert_line '      - "video"'
}

@test "_emit_user_build_args: empty omits; entries emit KEY: \${KEY} pairs" {
  run _emit_user_build_args ""
  assert_output ""
  run _emit_user_build_args $'FOO=1\nBAR=two'
  assert_line '        FOO: ${FOO}'
  assert_line '        BAR: ${BAR}'
}
