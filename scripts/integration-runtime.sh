#!/usr/bin/env bash

set -euo pipefail

readonly DEFAULT_IMAGE='docker.io/library/nginx@sha256:5616878291a2eed594aee8db4dade5878cf7edcb475e59193904b198d9b830de'
readonly DEFAULT_BASE_IMAGE='docker.io/library/alpine@sha256:2c9d26f410d032d5b1525aa8a873e238b05b90c4ae8618743d4311f0cc827e37'
IMAGE=${INTEGRATION_IMAGE:-$DEFAULT_IMAGE}
BASE_IMAGE=${INTEGRATION_BASE_IMAGE:-$DEFAULT_BASE_IMAGE}
BIND_ROOT=${INTEGRATION_BIND_ROOT:-$HOME}
RUN_ID="glassdock-integration-$$"
LABEL="glassdock.integration.run=$RUN_ID"

usage() {
    cat <<'EOF'
Usage: scripts/integration-runtime.sh [--preflight]

Runs a live Docker API lifecycle test against DOCKER_HOST. The test pulls a
pinned arm64 nginx image by default. Override it with INTEGRATION_IMAGE.

Required: DOCKER_HOST, docker, curl, jq

Set INTEGRATION_BIND_ROOT to a directory that the product shares with its VM.
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
        [[ $(docker_api inspect --format '{{ index .Config.Labels "glassdock.integration.run" }}' "$id" 2>/dev/null) == "$RUN_ID" ]] || continue
        docker_api rm -f "$id" >/dev/null 2>&1 || true
    done < <(docker_api ps -aq --filter "label=$LABEL" 2>/dev/null || true)
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

preflight() {
    [[ -n ${DOCKER_HOST:-} ]] || die "DOCKER_HOST is required"
    [[ $DOCKER_HOST == unix://* ]] || die "DOCKER_HOST must use unix:// for this test"
    [[ -d $BIND_ROOT && -w $BIND_ROOT ]] || die "INTEGRATION_BIND_ROOT must be a writable directory"
    [[ $IMAGE == *@sha256:* ]] || die "INTEGRATION_IMAGE must be pinned by digest"
    for tool in docker curl jq python3; do
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
docker_api pull "$BASE_IMAGE" >/dev/null

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
exec_failures=$(mktemp -t glassdock-integration-exec.XXXXXX)
for index in $(seq 1 32); do
    (
        output=$(docker_api exec "$runner" /bin/sh -c "printf exec-$index")
        [[ $output == "exec-$index" ]] || echo "$index" >> "$exec_failures"
    ) &
done
wait
[[ ! -s $exec_failures ]] || die "concurrent exec stress failed"
rm -f "$exec_failures"
docker_api stop -t 2 "$runner" >/dev/null
[[ $(docker_api wait "$runner") == 0 ]] || die "stopped container returned a nonzero exit code"
docker_api rm "$runner" >/dev/null

autoremove_output=$(docker_api run --rm --label "$LABEL" "$IMAGE" /bin/sh -c 'printf autoremove-ok')
[[ $autoremove_output == autoremove-ok ]] || die "docker run --rm output did not match"

web="$RUN_ID-port"
docker_api run -d --name "$web" --label "$LABEL" -p 127.0.0.1::80 "$IMAGE" >/dev/null
web_port=$(docker_api port "$web" 80/tcp | awk -F: 'END {print $NF}')
curl --silent --show-error --fail "http://127.0.0.1:$web_port/" >/dev/null \
    || die "published TCP port failed"
conflict="$RUN_ID-port-conflict"
if docker_api run -d --name "$conflict" --label "$LABEL" -p "127.0.0.1:$web_port:80" "$IMAGE" >/dev/null 2>&1; then
    die "conflicting TCP publication succeeded"
fi
docker_api rm -f "$conflict" >/dev/null

udp="$RUN_ID-udp"
docker_api run -d --name "$udp" --label "$LABEL" -p 127.0.0.1::5353/udp \
    "$BASE_IMAGE" /bin/sh -c 'exec nc -u -l -p 5353 -e cat' >/dev/null
udp_port=$(docker_api port "$udp" 5353/udp | awk -F: 'END {print $NF}')
python3 - "$udp_port" <<'PY'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
messages = (b"udp-one", b"udp-two")
for message in messages:
    s.sendto(message, ("127.0.0.1", int(sys.argv[1])))
responses = {s.recvfrom(1024)[0] for _ in messages}
if responses != set(messages):
    raise SystemExit(f"UDP echo responses did not match: {responses!r}")
PY

half_close="$RUN_ID-half-close"
docker_api run -d --name "$half_close" --label "$LABEL" -p 127.0.0.1::8080 \
    "$BASE_IMAGE" /bin/sh -c 'while :; do nc -l -p 8080 -e cat; done' >/dev/null
half_close_port=$(docker_api port "$half_close" 8080/tcp | awk -F: 'END {print $NF}')
python3 - "$half_close_port" <<'PY'
import socket, sys

client = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=3)
client.sendall(b"half-close-ok")
client.shutdown(socket.SHUT_WR)
response = b""
while True:
    chunk = client.recv(1024)
    if not chunk:
        break
    response += chunk
client.close()
if response != b"half-close-ok":
    raise SystemExit(f"TCP half-close response did not match: {response!r}")
PY

bind_dir=$(mktemp -d "$BIND_ROOT/.glassdock-integration-bind.XXXXXX")
bind="$RUN_ID-bind"
docker_api run -d --name "$bind" --label "$LABEL" -v "$bind_dir:/bind" \
    "$BASE_IMAGE" /bin/sh -c 'while :; do sleep 1; done' >/dev/null
docker_api exec "$bind" /bin/sh -c 'printf coherent > /bind/new && sync && mv /bind/new /bind/value'
[[ $(cat "$bind_dir/value") == coherent ]] || die "guest atomic bind write was not coherent on the host"
for index in $(seq 1 16); do
    printf 'host-%s' "$index" > "$bind_dir/host-$index" &
    docker_api exec "$bind" /bin/sh -c "printf guest-$index > /bind/guest-$index && sync" &
done
wait
for index in $(seq 1 16); do
    for _ in $(seq 1 100); do
        guest_value=$(docker_api exec "$bind" /bin/cat "/bind/host-$index" 2>/dev/null || true)
        [[ $guest_value == "host-$index" ]] && break
        sleep 0.01
    done
    [[ $guest_value == "host-$index" ]] || die "host-to-guest bind coherence failed at $index"
    [[ $(cat "$bind_dir/guest-$index") == "guest-$index" ]] \
        || die "guest-to-host bind coherence failed at $index"
done
rm -f "$bind_dir/value"
rm -f "$bind_dir"/host-* "$bind_dir"/guest-*
rmdir "$bind_dir"
docker_api rm -f "$web" "$udp" "$half_close" "$bind" >/dev/null

volume="$RUN_ID-volume"
docker_api volume create --label "$LABEL" "$volume" >/dev/null
docker_api run --rm --label "$LABEL" -v "$volume:/data" "$BASE_IMAGE" \
    /bin/sh -c 'printf durable >/data/value && sync' >/dev/null
docker_api run --rm --label "$LABEL" -v "$volume:/data" "$BASE_IMAGE" \
    /bin/sh -c 'test "$(cat /data/value)" = durable'
docker_api volume rm "$volume" >/dev/null

stress_failures=$(mktemp -t glassdock-integration-stress.XXXXXX)
for batch in $(seq 1 7); do
    start=$(((batch - 1) * 16 + 1))
    end=$((batch * 16))
    ((end > 100)) && end=100
    for index in $(seq "$start" "$end"); do
        (
            output=$(docker_api run --rm --label "$LABEL" "$BASE_IMAGE" /bin/sh -c 'printf stress-ok')
            [[ $output == stress-ok ]] || echo "$index" >> "$stress_failures"
        ) &
    done
    wait
    ((end == 100)) && break
done
[[ ! -s $stress_failures ]] || die "concurrent lifecycle stress failed"
rm -f "$stress_failures"

if docker_api ps -aq --filter "label=$LABEL" | grep -q .; then
    die "lifecycle test leaked a container"
fi

echo "integration: passed lifecycle, attach, exec, TCP/UDP publication and half-close, bind coherence, named volumes, and 100 runs at concurrency 16"
