#!/bin/bash
# Live regression: an attach-only start must register DNS and remove it on exit.
# Requires a running Socktainer + Apple Container, docker, curl, and dig.
# Usage: bash scripts/test-attach-dns.sh /path/to/container.sock [DNS-port]
# Use the actual DNS port from Socktainer's "[dns] listening" log (default 2054).
set -euo pipefail
socket=${1:?Pass the Socktainer Unix socket path}
port=${2:-2054}
name="attach-dns-$$"
service="database-$name"
network="${name}_default"
docker=(docker --host "unix://$socket")
output=$(mktemp)
attach_pid=
cleanup() {
    if [ -n "$attach_pid" ]; then
        kill "$attach_pid" 2>/dev/null || true
        wait "$attach_pid" 2>/dev/null || true
    fi
    "${docker[@]}" rm -f "$name" >/dev/null 2>&1 || true
    "${docker[@]}" network rm "$network" >/dev/null 2>&1 || true
    rm -f "$output"
}
trap cleanup EXIT
query() { dig @127.0.0.1 -p "$port" "$1" A +time=1 +tries=1 +noall +comments +answer; }
wait_for() {
    for ((i=0; i<60; i++)); do
        if "$@"; then return 0; fi
        sleep 1
    done
    echo "Timed out: $*" >&2
    cat "$output" >&2
    return 1
}
has_address() { query "$1" | awk '{print $5}' | grep -Fxq "$ip"; }
is_absent() { query "$1" | grep -q 'status: NXDOMAIN'; }
is_running() { [ "$("${docker[@]}" inspect -f '{{.State.Running}}' "$name")" = true ]; }

"${docker[@]}" network create "$network" >/dev/null
"${docker[@]}" create --name "$name" --network "$network" --memory 256m \
    --label "com.docker.compose.service=$service" --label "com.docker.compose.project=$name" \
    alpine:3.21 sh -c 'while [ ! -f /tmp/exit-probe ]; do sleep 1; done' >/dev/null
[ "$("${docker[@]}" inspect -f '{{.State.Running}}' "$name")" = false ]
is_absent "$service"
# Deliberately never POST /start: this must exercise the stopped-container attach route.
curl --fail --silent --show-error --max-time 180 --unix-socket "$socket" -X POST \
    "http://localhost/v1.51/containers/$name/attach?stream=1&stdout=1&stderr=1" >"$output" 2>&1 &
attach_pid=$!
wait_for is_running
ip=$("${docker[@]}" inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name")
[ -n "$ip" ]
for alias in "$name" "$service" "$service.$name"; do
    wait_for has_address "$alias"
done
echo "PASS: attach registered container and Compose aliases -> $ip"
# Let the init process exit naturally: stop/delete routes must not perform the cleanup.
"${docker[@]}" exec "$name" touch /tmp/exit-probe
for alias in "$name" "$service" "$service.$name"; do
    wait_for is_absent "$alias"
done
echo 'PASS: process exit removed container and Compose aliases'
