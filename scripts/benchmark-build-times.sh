#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 OUTPUT_DIRECTORY"
    exit 2
fi

repo_root=$(git rev-parse --show-toplevel)
output_root=$1

if [[ -e "$output_root" ]]; then
    echo "Refusing to reuse existing output directory: $output_root"
    exit 2
fi

mkdir -p "$output_root"
scratch_root="$output_root/scratch"
mkdir -p "$scratch_root"

build_commit=$(git rev-parse --short HEAD)
build_version=$(git describe --tags --exact-match HEAD 2>/dev/null || echo "0.0.0-dev")

run_timed() {
    local label=$1
    shift

    echo "== $label =="
    echo "+ $*"
    /usr/bin/time -p "$@" 2>&1 | tee "$output_root/$label.log"
}

metadata_time() {
    if [[ ${VOLATILE_METADATA:-0} == 1 || $1 == release ]]; then
        date -u +"%Y-%m-%dT%H:%M:%SZ"
    else
        echo "${BUILD_TIME:-development}"
    fi
}

run_build() {
    local label=$1
    local configuration=$2
    local build_time
    build_time=$(metadata_time "$configuration")

    run_timed "$label" env \
        BUILD_GIT_COMMIT="$build_commit" \
        BUILD_VERSION="$build_version" \
        BUILD_TIME="$build_time" \
        DOCKER_ENGINE_API_MIN_VERSION=v1.32 \
        DOCKER_ENGINE_API_MAX_VERSION=v1.51 \
        swift build -c "$configuration" --scratch-path "$scratch_root"
}

run_test_build() {
    local label=$1
    local build_time
    build_time=$(metadata_time debug)

    run_timed "$label" env \
        BUILD_GIT_COMMIT="$build_commit" \
        BUILD_VERSION="$build_version" \
        BUILD_TIME="$build_time" \
        DOCKER_ENGINE_API_MIN_VERSION=v1.32 \
        DOCKER_ENGINE_API_MAX_VERSION=v1.51 \
        swift build -c debug --build-tests --disable-index-store --scratch-path "$scratch_root"
}

run_timed resolution env \
    BUILD_GIT_COMMIT="$build_commit" \
    BUILD_VERSION="$build_version" \
    BUILD_TIME="$(metadata_time debug)" \
    DOCKER_ENGINE_API_MIN_VERSION=v1.32 \
    DOCKER_ENGINE_API_MAX_VERSION=v1.51 \
    swift package resolve --scratch-path "$scratch_root" --force-resolved-versions --skip-update

run_build clean-debug debug

for sample in 1 2 3; do
    run_build "warm-$sample" debug
done

for sample in 1 2 3; do
    touch "$repo_root/Sources/GlassDock/Routes/Volumes/VolumeListRoute.swift"
    run_build "leaf-edit-$sample" debug
done

for sample in 1 2 3; do
    touch "$repo_root/Sources/GlassDock/configure.swift"
    run_build "central-edit-$sample" debug
done

run_test_build test-seed

for sample in 1 2 3; do
    touch "$repo_root/Tests/GlassDockTests/Utilities/LabelUtilityTests.swift"
    run_test_build "test-only-edit-$sample"
done

run_build release release
