#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: SOCKTAINER_MEMBENCH_ALLOW_RUNTIME=1 \
  SOCKTAINER_BINARY=.build/debug/socktainer \
  scripts/benchmark-networking-memory.sh --run

The benchmark owns only resources whose names start with its generated prefix.
It requires an explicit allow flag because it creates disposable networks and
containers in the shared Apple Container service. It never stops or restarts
that service; it only restarts the isolated Socktainer daemon process.
EOF
}

if [[ "${1:-}" != "--run" ]]; then
    usage
    exit 64
fi
if [[ "${SOCKTAINER_MEMBENCH_ALLOW_RUNTIME:-}" != "1" ]]; then
    echo "Refusing runtime mutation: set SOCKTAINER_MEMBENCH_ALLOW_RUNTIME=1" >&2
    exit 64
fi
if [[ ! -x /usr/bin/footprint ]]; then
    echo "This benchmark requires /usr/bin/footprint on macOS" >&2
    exit 69
fi
command -v docker >/dev/null || { echo "docker is required" >&2; exit 69; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 69; }

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_id="${SOCKTAINER_MEMBENCH_ID:-$timestamp-$$}"
run_id="${run_id//[^a-zA-Z0-9-]/-}"
run_id="$(printf '%s' "$run_id" | tr '[:upper:]' '[:lower:]')"
prefix="socktainer-membench-${run_id}"
output="${SOCKTAINER_MEMBENCH_OUTPUT:-${TMPDIR:-/tmp}/${prefix}}"
mkdir -p "$output"
home="$output/home"
metadata="$output/metadata"
mkdir -p "$home" "$metadata"

socket="$home/.socktainer/container.sock"
daemon_pid=""
network_a="${prefix}-net-a"
network_b="${prefix}-net-b"
dns_a="socktainer-dns-${network_a}"
dns_b="socktainer-dns-${network_b}"
workload_a="${prefix}-workload-a"
workload_b="${prefix}-workload-b"
workload_a_peer="${prefix}-workload-a-peer"
workload_b_peer="${prefix}-workload-b-peer"
volume_a="${prefix}-volume-a"
volume_a_peer="${prefix}-volume-a-peer"
volume_b="${prefix}-volume-b"
volume_b_peer="${prefix}-volume-b-peer"
image="${SOCKTAINER_MEMBENCH_IMAGE:-postgres:17}"
docker_host="unix://${socket}"
docker_args=(--host "$docker_host")
native_ids_file="$output/native-containers.txt"
helper_ids_file="$output/dns-helpers.txt"
include_system="${SOCKTAINER_MEMBENCH_INCLUDE_SYSTEM:-0}"
dns_port="${SOCKTAINER_MEMBENCH_DNS_PORT:-$((20000 + $$ % 20000))}"

cleanup() {
    set +e
    command docker "${docker_args[@]}" rm -f \
        "$workload_a" "$workload_b" "$workload_a_peer" "$workload_b_peer" \
        >/dev/null 2>&1
    command docker "${docker_args[@]}" volume rm \
        "$volume_a" "$volume_b" "$volume_a_peer" "$volume_b_peer" >/dev/null 2>&1
    command docker "${docker_args[@]}" network rm "$network_a" "$network_b" >/dev/null 2>&1
    stop_daemon
}
trap cleanup EXIT

export HOME="$home"
export SOCKTAINER_METADATA_DIRECTORY="$metadata"
export SOCKTAINER_CONTAINER_RECOVERY_SCOPE=metadata
export SOCKTAINER_DNS_PORT="$dns_port"

binary="${SOCKTAINER_BINARY:-.build/debug/socktainer}"
if [[ ! -x "$binary" ]]; then
    echo "Socktainer binary is not executable: $binary" >&2
    exit 69
fi

start_daemon() {
    "$binary" --no-check-compatibility --no-docker-context >>"$output/socktainer.log" 2>&1 &
    daemon_pid=$!

    # curl supplies bounded connection retries without a sleep-and-grep readiness loop.
    curl --fail --silent --show-error \
        --unix-socket "$socket" \
        --retry 30 --retry-delay 1 --retry-connrefused --retry-all-errors \
        --connect-timeout 2 --max-time 60 \
        http://localhost/_ping >/dev/null
}

stop_daemon() {
    if [[ -n "$daemon_pid" ]]; then
        kill "$daemon_pid" 2>/dev/null
        wait "$daemon_pid" 2>/dev/null
        daemon_pid=""
    fi
}

start_daemon

command docker "${docker_args[@]}" network create --label "socktainer.membench=$run_id" "$network_a" >/dev/null
command docker "${docker_args[@]}" network create --label "socktainer.membench=$run_id" "$network_b" >/dev/null
command docker "${docker_args[@]}" volume create --label "socktainer.membench=$run_id" "$volume_a" >/dev/null
command docker "${docker_args[@]}" volume create --label "socktainer.membench=$run_id" "$volume_a_peer" >/dev/null
command docker "${docker_args[@]}" volume create --label "socktainer.membench=$run_id" "$volume_b" >/dev/null
command docker "${docker_args[@]}" volume create --label "socktainer.membench=$run_id" "$volume_b_peer" >/dev/null

record_processes() {
    jq -r 'keys[]' "$metadata/socktainer/docker-containers.json" \
        >"$native_ids_file" 2>/dev/null || : >"$native_ids_file"
    ps -axo pid=,ppid=,rss=,vsz=,command= >"$output/processes-$1.txt"
}

record_helper_ids() {
    local network_id digest prefix sanitized
    : >"$helper_ids_file"
    for network_id in "$network_a" "$network_b"; do
        if (( ${#network_id} <= 48 )); then
            sanitized="socktainer-dns-${network_id}"
        else
            digest="$(printf '%s' "socktainer-dns-${network_id}" | shasum -a 256 | awk '{print $1}')"
            prefix="socktainer-dns-${network_id}"
            sanitized="${prefix:0:50}-${digest:0:12}"
        fi
        printf '%s\n' "$sanitized" >>"$helper_ids_file"
    done
}

footprint_one() {
    local phase="$1" category="$2" pid="$3"
    local bytes
    bytes="$(/usr/bin/footprint -p "$pid" -f bytes --noCategories 2>/dev/null \
        | awk '/phys_footprint:/ {print $2; exit}')"
    printf '%s,%s,%s,%s,%s\n' "$(date -u +%FT%TZ)" "$phase" "$category" "$pid" "${bytes:-}" \
        >>"$output/footprint.csv"
}

measure() {
    local phase="$1"
    record_processes "$phase"
    footprint_one "$phase" socktainer "$daemon_pid"

    while read -r pid ppid rss vsz command_line; do
        [[ "$pid" == "$daemon_pid" ]] && continue
        if [[ "$command_line" == *container-apiserver* || "$command_line" == *container.apiserver* ]]; then
            footprint_one "$phase" container-apiserver "$pid"
        elif [[ "$command_line" == *Virtualization.VirtualMachine* ]]; then
            # Apple launches the runtime-linux process and its Virtualization XPC
            # process as siblings under launchd. The nearest preceding runtime
            # PID is the VM owner; allowing a small PID gap covers launchd races.
            runtime_line="$(awk -v current="$pid" '$1 < current && current - $1 <= 10 && $5 ~ /container-runtime-linux/ {for (i=1; i<=4; i++) $i=""; sub(/^[[:space:]]+/, ""); line=$0} END {print line}' \
                "$output/processes-$phase.txt")"
            parent_line="$runtime_line"
            if [[ -z "$parent_line" ]]; then
                parent_line="$(awk -v wanted="$ppid" '$1 == wanted {for (i=1; i<=4; i++) $i=""; sub(/^[[:space:]]+/, ""); print; exit}' \
                "$output/processes-$phase.txt")"
            fi
            native_id="${parent_line##*--uuid }"
            native_id="${native_id%% *}"
            if grep -Fqx "$native_id" "$helper_ids_file"; then
                footprint_one "$phase" helper-vm "$pid"
            elif grep -Fqx "$native_id" "$native_ids_file"; then
                footprint_one "$phase" workload-vm "$pid"
            fi
        fi
    done < <(awk '{pid=$1; ppid=$2; rss=$3; vsz=$4; for (i=1; i<=4; i++) $i=""; sub(/^[[:space:]]+/, ""); print pid, ppid, rss, vsz, $0}' \
        "$output/processes-$phase.txt")

    if [[ "$include_system" == "1" ]]; then
        /usr/bin/footprint --sysFootprint -f bytes >"$output/system-$phase.footprint.txt" 2>&1 || true
        vm_stat >"$output/system-$phase.vm_stat.txt"
        memory_pressure -Q >"$output/system-$phase.memory_pressure.txt" 2>&1 || true
        sysctl vm.swapusage >"$output/system-$phase.swapusage.txt" 2>&1 || true
    else
        printf 'system sampling skipped; set SOCKTAINER_MEMBENCH_INCLUDE_SYSTEM=1 only on a host without live workloads\n' \
            >"$output/system-$phase.skipped.txt"
    fi
    command docker "${docker_args[@]}" stats --no-stream \
        "$workload_a" "$workload_a_peer" "$workload_b" "$workload_b_peer" \
        --format '{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}}' \
        >"$output/guest-$phase.stats.csv" 2>&1 || true
}

printf 'timestamp,phase,category,pid,phys_footprint_bytes\n' >"$output/footprint.csv"
command docker "${docker_args[@]}" run -d --name "$workload_a" --network "$network_a" \
    --network-alias db-a --publish 127.0.0.1::5432 \
    --volume "$volume_a:/var/lib/postgresql/data" \
    --env POSTGRES_HOST_AUTH_METHOD=trust \
    --label "socktainer.membench=$run_id" "$image" >/dev/null
command docker "${docker_args[@]}" run -d --name "$workload_a_peer" --network "$network_a" \
    --network-alias db-a-peer --volume "$volume_a_peer:/var/lib/postgresql/data" \
    --env POSTGRES_HOST_AUTH_METHOD=trust \
    --label "socktainer.membench=$run_id" "$image" >/dev/null
command docker "${docker_args[@]}" run -d --name "$workload_b" --network "$network_b" \
    --publish '[::1]::5432' \
    --network-alias db-b --volume "$volume_b:/var/lib/postgresql/data" \
    --env POSTGRES_HOST_AUTH_METHOD=trust \
    --label "socktainer.membench=$run_id" "$image" >/dev/null
command docker "${docker_args[@]}" run -d --name "$workload_b_peer" --network "$network_b" \
    --network-alias db-b-peer --volume "$volume_b_peer:/var/lib/postgresql/data" \
    --env POSTGRES_HOST_AUTH_METHOD=trust \
    --label "socktainer.membench=$run_id" "$image" >/dev/null

record_helper_ids

for phase in idle-1 idle-2 idle-3; do measure "$phase"; done

# Exercise same-network DNS in both isolated networks. The exit status is kept
# in the ledger because the benchmark must not silently turn a DNS failure into
# a memory-only result.
set +e
command docker "${docker_args[@]}" exec "$workload_a" getent hosts db-a-peer >"$output/dns-a.txt" 2>&1
dns_a_status=$?
command docker "${docker_args[@]}" exec "$workload_b" getent hosts db-b-peer >"$output/dns-b.txt" 2>&1
dns_b_status=$?
set -e
printf 'dns_network_a_status=%s\ndns_network_b_status=%s\n' "$dns_a_status" "$dns_b_status" \
    >>"$output/ledger.txt"
for phase in dns-1 dns-2 dns-3; do measure "$phase"; done

# Exercise a published TCP port. Apple owns this listener; the benchmark only
# records the host endpoint and tests it without starting a relay process.
port="$(command docker "${docker_args[@]}" port "$workload_a" 5432/tcp 2>/dev/null | awk -F: 'NR==1 {print $NF}')"
port_v6="$(command docker "${docker_args[@]}" port "$workload_b" 5432/tcp 2>/dev/null | awk -F: 'NR==1 {print $NF}')"
port_status=69
port_v6_status=69
if [[ -n "$port" ]]; then
    set +e
    nc -z 127.0.0.1 "$port" >>"$output/port.txt" 2>&1
    port_status=$?
    set -e
fi
if [[ -n "$port_v6" ]]; then
    set +e
    nc -6 -z ::1 "$port_v6" >>"$output/port-v6.txt" 2>&1
    port_v6_status=$?
    set -e
fi
printf 'published_port_ipv4=%s\npublished_port_ipv4_status=%s\npublished_port_ipv6=%s\npublished_port_ipv6_status=%s\n' \
    "$port" "$port_status" "$port_v6" "$port_v6_status" >>"$output/ledger.txt"
for phase in ports-1 ports-2 ports-3; do measure "$phase"; done

# Verify daemon restart recovery while all disposable workloads and networks
# remain alive. The metadata scope prevents discovery of unrelated resources.
stop_daemon
start_daemon
printf 'daemon_restart_status=0\n' >>"$output/ledger.txt"
for phase in daemon-restart-1 daemon-restart-2 daemon-restart-3; do measure "$phase"; done

# Repeat a bounded lifecycle on disposable objects. Existing workloads are
# never selected by this loop because every name is generated from the prefix.
for cycle in 1 2 3; do
    cycle_name="${prefix}-cycle-${cycle}"
    command docker "${docker_args[@]}" run -d --name "$cycle_name" --network "$network_a" \
        --tmpfs /var/lib/postgresql/data \
        --env POSTGRES_HOST_AUTH_METHOD=trust \
        --label "socktainer.membench=$run_id" "$image" >/dev/null
    command docker "${docker_args[@]}" restart "$cycle_name" >/dev/null
    command docker "${docker_args[@]}" rm -f "$cycle_name" >/dev/null
    measure "lifecycle-${cycle}"
done

printf 'output=%s\n' "$output"
printf 'resources=%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$network_a" "$network_b" "$workload_a" "$workload_a_peer" "$workload_b" "$workload_b_peer" \
    "$volume_a" "$volume_a_peer" "$volume_b" "$volume_b_peer"
printf 'complete=true\n'
