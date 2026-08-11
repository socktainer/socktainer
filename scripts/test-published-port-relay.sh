#!/bin/sh
set -eu

suffix="$$"
network="socktainer-relay-integration-$suffix"
target="socktainer-relay-target-$suffix"
blocker="socktainer-relay-blocker-$suffix"
host_port=""

remove_container() {
    name="$1"
    if docker inspect "$name" >/dev/null 2>&1; then
        docker stop "$name" >/dev/null 2>&1 || true
        docker rm "$name" >/dev/null 2>&1 || true
    fi
}

cleanup() {
    remove_container "$target"
    remove_container "$blocker"
    docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

wait_for_target() {
    for _ in $(seq 1 30); do
        if nc -z -w 1 127.0.0.1 "$host_port" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

start_target() {
    published_port="$1"
    docker run --detach \
        --name "$target" \
        --network "$network" \
        --publish "127.0.0.1:$published_port:8080" \
        alpine:3.22 \
        busybox httpd -f -p 8080 \
        >/dev/null
}

docker pull alpine:3.22 >/dev/null
docker network create "$network" >/dev/null
start_target ""
host_port="$(docker port "$target" 8080/tcp | sed -E 's/.*:([0-9]+)$/\1/')"
initial_ip="$(docker inspect "$target" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')"
wait_for_target

docker stop "$target" >/dev/null
if nc -z -w 1 127.0.0.1 "$host_port" >/dev/null 2>&1; then
    echo "published listener remained usable after container stop" >&2
    exit 1
fi
docker start "$target" >/dev/null
wait_for_target
docker restart "$target" >/dev/null
wait_for_target

remove_container "$target"
docker run --detach --name "$blocker" --network "$network" alpine:3.22 sleep 300 >/dev/null
start_target "$host_port"
changed_ip="$(docker inspect "$target" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')"
if [ "$initial_ip" = "$changed_ip" ]; then
    echo "target IP did not change during lifecycle integration test" >&2
    exit 1
fi
wait_for_target

remove_container "$target"
ruby -rsocket -e "server = TCPServer.new('127.0.0.1', $host_port); server.close"
remove_container "$blocker"
docker network rm "$network" >/dev/null
trap - EXIT INT TERM

echo "published-port relay integration passed ($initial_ip -> $changed_ip, host port $host_port)"
