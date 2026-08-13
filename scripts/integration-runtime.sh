#!/usr/bin/env bash

set -euo pipefail

readonly DEFAULT_IMAGE='docker.io/library/nginx@sha256:5616878291a2eed594aee8db4dade5878cf7edcb475e59193904b198d9b830de'
IMAGE=${INTEGRATION_IMAGE:-$DEFAULT_IMAGE}
RUN_ID="socktainer-integration-$$"
LABEL="socktainer.integration.run=$RUN_ID"

usage() {
    cat <<'EOF'
Usage: scripts/integration-runtime.sh [--preflight]

Runs a live Docker API lifecycle test against DOCKER_HOST. The test pulls a
pinned arm64 nginx image by default. Override it with INTEGRATION_IMAGE.

Required: DOCKER_HOST, docker, curl, jq
EOF
}

die() {
    echo "integration: $*" >&2
    exit 1
}

docker_api() {
    DOCKER_HOST="$DOCKER_HOST" docker "$@"
}

cleanup() {
    local id
    while IFS= read -r id; do
        [[ -n $id ]] || continue
        docker_api rm -f "$id" >/dev/null 2>&1 || true
    done < <(docker_api ps -aq --filter "label=$LABEL" 2>/dev/null || true)
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

preflight() {
    [[ -n ${DOCKER_HOST:-} ]] || die "DOCKER_HOST is required"
    [[ $DOCKER_HOST == unix://* ]] || die "DOCKER_HOST must use unix:// for this test"
    [[ $IMAGE == *@sha256:* ]] || die "INTEGRATION_IMAGE must be pinned by digest"
    for tool in docker curl jq; do
        command -v "$tool" >/dev/null || die "required tool is not installed: $tool"
    done
    local socket=${DOCKER_HOST#unix://}
    [[ -S $socket ]] || die "Docker socket does not exist: $socket"
    curl --silent --show-error --fail --unix-socket "$socket" http://localhost/_ping \
        | grep -qx OK || die "Docker API ping failed"
    echo "integration preflight: ok ($DOCKER_HOST, $IMAGE)"
}

if [[ ${1:-} == --help ]]; then
    usage
    exit 0
fi

preflight
if [[ ${1:-} == --preflight ]]; then
    exit 0
fi
[[ $# -eq 0 ]] || die "unknown argument: $1"

echo "integration: pulling pinned fixture"
docker_api pull "$IMAGE" >/dev/null

name="$RUN_ID-lifecycle"
docker_api create --name "$name" --label "$LABEL" "$IMAGE" /bin/sh -c 'printf lifecycle-ok' >/dev/null
docker_api start "$name" >/dev/null
[[ $(docker_api wait "$name") == 0 ]] || die "container returned a nonzero exit code"
[[ $(docker_api logs "$name") == lifecycle-ok ]] || die "container output did not match"
docker_api rm "$name" >/dev/null

runner="$RUN_ID-runner"
docker_api run -d --name "$runner" --label "$LABEL" "$IMAGE" \
    /bin/sh -c 'trap "exit 0" TERM INT; while :; do sleep 1; done' >/dev/null
docker_api exec "$runner" /bin/true
[[ $(docker_api exec "$runner" /bin/sh -c 'printf exec-ok') == exec-ok ]] \
    || die "docker exec output did not match"
docker_api stop -t 2 "$runner" >/dev/null
[[ $(docker_api wait "$runner") == 0 ]] || die "stopped container returned a nonzero exit code"
docker_api rm "$runner" >/dev/null

autoremove_output=$(docker_api run --rm --label "$LABEL" "$IMAGE" /bin/sh -c 'printf autoremove-ok')
[[ $autoremove_output == autoremove-ok ]] || die "docker run --rm output did not match"

if docker_api ps -aq --filter "label=$LABEL" | grep -q .; then
    die "lifecycle test leaked a container"
fi

echo "integration: passed create, start, wait, logs, exec, stop, remove, attach, and auto-remove"
