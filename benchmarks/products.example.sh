#!/usr/bin/env bash

# shellcheck disable=SC2034,SC2016

# Copy this file outside the repository, edit every declared resource value and
# reset policy, and pass it with --config. The benchmark sources this trusted
# local shell file because product lifecycle commands are shell commands.
#
# Do not enable all blocks without review. Docker Desktop stable and Docker VMM
# use the same app, context, socket, and data. Run them as separate campaigns
# after you select the applicable VMM in Settings > General.

# Dory 0.4.x. Dory does not publish a full-reset command. This example retains
# its image store and removes only containers that the harness labels.
DORY_DOCKER_HOST="unix://$HOME/.dory/dory.sock"
DORY_START_CMD='dory engine wake'
DORY_START_MODE=oneshot
DORY_STOP_CMD='dory engine sleep'
DORY_STOPPED_CMD='test "$(dory engine status --json | jq -r .state)" = sleeping'
DORY_RESET_CMD=true
DORY_RESET_POLICY='benchmark-labelled containers only; Dory persistent image cache retained'
DORY_IMAGE_CACHE_POLICY=retained
DORY_PID_PATTERNS='Dory.app,dory-hv,doryd'
DORY_STORAGE_PATHS="$HOME/Library/Application Support/Dory/Dory.dorydrive:$HOME/.dory"
DORY_STORAGE_SCOPE='Dory mutable drive and runtime state; use storage deltas for comparisons'
DORY_CPU_COUNT=6
DORY_VM_MEMORY_BYTES=$((4 * 1024 * 1024 * 1024))
DORY_VM_ALLOCATED_MEMORY_BYTES=$DORY_VM_MEMORY_BYTES
DORY_VERSION_CMD='printf "app="; defaults read /Applications/Dory.app/Contents/Info.plist CFBundleShortVersionString; printf "cli="; dory version'
DORY_RUNTIME_CMD='DOCKER_HOST="$DORY_DOCKER_HOST" docker version --format "engine={{.Server.Version}}"'
DORY_CONFIG_CMD='printf "operator_declared_cpu=%s; operator_declared_memory_bytes=%s; mode=" "$DORY_CPU_COUNT" "$DORY_VM_MEMORY_BYTES"; dory mode show'
DORY_VARIANT='hypervisor-framework'

# Docker Desktop. Use the product name docker-stable or docker-vmm and set the
# matching uppercase variables. The VMM selection has no supported automation
# command. The harness therefore records the operator declaration.
DOCKER_STABLE_DOCKER_HOST="unix://$HOME/.docker/run/docker.sock"
DOCKER_STABLE_START_CMD='docker desktop start'
DOCKER_STABLE_START_MODE=oneshot
DOCKER_STABLE_STOP_CMD='docker desktop stop'
DOCKER_STABLE_RESET_CMD=true
DOCKER_STABLE_RESET_POLICY='benchmark-labelled containers only; Docker Desktop image cache retained'
DOCKER_STABLE_IMAGE_CACHE_POLICY=retained
DOCKER_STABLE_PID_PATTERNS='Docker.app,com.docker.backend,com.docker.virtualization'
DOCKER_STABLE_STORAGE_PATHS="$HOME/Library/Containers/com.docker.docker:$HOME/Library/Group Containers/group.com.docker"
DOCKER_STABLE_STORAGE_SCOPE='Docker Desktop mutable container and group data; use storage deltas for comparisons'
DOCKER_STABLE_CPU_COUNT=4
DOCKER_STABLE_VM_MEMORY_BYTES=$((4 * 1024 * 1024 * 1024))
DOCKER_STABLE_VM_ALLOCATED_MEMORY_BYTES=$DOCKER_STABLE_VM_MEMORY_BYTES
DOCKER_STABLE_VERSION_CMD='printf "app="; defaults read /Applications/Docker.app/Contents/Info.plist CFBundleShortVersionString; docker desktop version'
DOCKER_STABLE_RUNTIME_CMD='DOCKER_HOST="$DOCKER_STABLE_DOCKER_HOST" docker version --format "engine={{.Server.Version}}"'
DOCKER_STABLE_CONFIG_CMD='shasum -a 256 "$HOME/Library/Group Containers/group.com.docker/settings-store.json"'
DOCKER_STABLE_VARIANT='apple-virtualization'

DOCKER_VMM_DOCKER_HOST=$DOCKER_STABLE_DOCKER_HOST
DOCKER_VMM_START_CMD=$DOCKER_STABLE_START_CMD
DOCKER_VMM_START_MODE=$DOCKER_STABLE_START_MODE
DOCKER_VMM_STOP_CMD=$DOCKER_STABLE_STOP_CMD
DOCKER_VMM_RESET_CMD=$DOCKER_STABLE_RESET_CMD
DOCKER_VMM_RESET_POLICY=$DOCKER_STABLE_RESET_POLICY
DOCKER_VMM_IMAGE_CACHE_POLICY=$DOCKER_STABLE_IMAGE_CACHE_POLICY
DOCKER_VMM_PID_PATTERNS=$DOCKER_STABLE_PID_PATTERNS
DOCKER_VMM_STORAGE_PATHS=$DOCKER_STABLE_STORAGE_PATHS
DOCKER_VMM_STORAGE_SCOPE=$DOCKER_STABLE_STORAGE_SCOPE
DOCKER_VMM_CPU_COUNT=$DOCKER_STABLE_CPU_COUNT
DOCKER_VMM_VM_MEMORY_BYTES=$DOCKER_STABLE_VM_MEMORY_BYTES
DOCKER_VMM_VM_ALLOCATED_MEMORY_BYTES=$DOCKER_STABLE_VM_ALLOCATED_MEMORY_BYTES
DOCKER_VMM_VERSION_CMD=$DOCKER_STABLE_VERSION_CMD
DOCKER_VMM_RUNTIME_CMD=$DOCKER_STABLE_RUNTIME_CMD
DOCKER_VMM_CONFIG_CMD=$DOCKER_STABLE_CONFIG_CMD
DOCKER_VMM_VARIANT='docker-vmm'

# OrbStack. This example retains the shared image cache. Confirm the configured
# CPU and memory values with `orb config` before a comparative campaign.
ORBSTACK_DOCKER_HOST="$(docker context inspect orbstack --format '{{ .Endpoints.docker.Host }}' 2>/dev/null || true)"
ORBSTACK_START_CMD='orb start'
ORBSTACK_START_MODE=oneshot
ORBSTACK_STOP_CMD='orb stop'
ORBSTACK_RESET_CMD=true
ORBSTACK_RESET_POLICY='benchmark-labelled containers only; OrbStack image cache retained'
ORBSTACK_IMAGE_CACHE_POLICY=retained
ORBSTACK_PID_PATTERNS='OrbStack.app,OrbStack Helper,orbstack'
ORBSTACK_STORAGE_PATHS="$HOME/.orbstack:$HOME/Library/Group Containers/HUAQ24HBR6.dev.orbstack"
ORBSTACK_STORAGE_SCOPE='OrbStack mutable user and group data; use storage deltas for comparisons'
ORBSTACK_CPU_COUNT=6
ORBSTACK_VM_MEMORY_BYTES=$((4 * 1024 * 1024 * 1024))
ORBSTACK_VM_ALLOCATED_MEMORY_BYTES=$ORBSTACK_VM_MEMORY_BYTES
ORBSTACK_VERSION_CMD='printf "app="; defaults read /Applications/OrbStack.app/Contents/Info.plist CFBundleShortVersionString; orb version'
ORBSTACK_RUNTIME_CMD='DOCKER_HOST="$ORBSTACK_DOCKER_HOST" docker version --format "engine={{.Server.Version}}"'
ORBSTACK_CONFIG_CMD='orb config'
ORBSTACK_VARIANT='orbstack'
