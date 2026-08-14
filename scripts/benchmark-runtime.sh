#!/usr/bin/env bash

set -euo pipefail

readonly DEFAULT_BASE_IMAGE='docker.io/library/alpine@sha256:2c9d26f410d032d5b1525aa8a873e238b05b90c4ae8618743d4311f0cc827e37'
readonly DEFAULT_NGINX_IMAGE='docker.io/library/nginx@sha256:5616878291a2eed594aee8db4dade5878cf7edcb475e59193904b198d9b830de'
BASE_IMAGE=${BENCH_BASE_IMAGE:-$DEFAULT_BASE_IMAGE}
NGINX_IMAGE=${BENCH_NGINX_IMAGE:-$DEFAULT_NGINX_IMAGE}
PRODUCTS=${BENCH_PRODUCTS:-socktainer}
SAMPLES=${BENCH_SAMPLES:-12}
AB_REQUESTS=${BENCH_AB_REQUESTS:-10000}
AB_CONCURRENCY=${BENCH_AB_CONCURRENCY:-32}
BIND_MIB=${BENCH_BIND_MIB:-512}
OUTPUT=${BENCH_OUTPUT:-}
MODE=run
RUN_ID="socktainer-benchmark-$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUNS_DIRECTORY=
RUN_DIRECTORY=
RESULTS_FILE=
PROCESS_FILE=
STORAGE_FILE=
ENGINE_STATE_DIR=
BIND_STATE_DIR=
CURRENT_HOST=
CURRENT_PRODUCT=
CURRENT_SAMPLE=0
CURRENT_POSITION=0
CURRENT_METRIC=initialization
BENCHMARK_COMPLETE=false
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
readonly DD_RESULT_PARSER="$REPO_ROOT/scripts/parse-busybox-dd.awk"

usage() {
    cat <<'EOF'
Usage: scripts/benchmark-runtime.sh [options]

Options:
  --preflight          Validate tools and product configuration only.
  --dry-run            Print the Williams-design order and commands.
  --products LIST      Comma-separated product names (default: socktainer).
  --samples N          Sample count (default: 12; must be divisible by product count).
  --output FILE        JSON result file.

For each product NAME, set these uppercase environment variables:
  NAME_DOCKER_HOST     Required unix:// Docker API socket.
  NAME_START_CMD       Required engine start command.
  NAME_START_MODE      foreground (harness-owned PID) or oneshot (default).
  NAME_STOP_CMD        Stop command. Optional in foreground mode.
  NAME_RESET_CMD       Required command that resets mutable engine state.
  NAME_OWNED_PIDS_CMD  Optional command that prints additional owned root PIDs.
  NAME_PID_PATTERNS    Optional fallback comma-separated process regexes.
  NAME_HELPER_PATTERNS Optional helper regexes; only processes born after launch count.
  NAME_STORAGE_PATHS   Required colon-separated paths owned by the product.
  NAME_VM_MEMORY_BYTES Configured VM memory limit. Use 0 only when there is no VM.
  NAME_VM_ALLOCATED_MEMORY_BYTES Memory allocated to the VM by product settings.
  NAME_VERSION_CMD     Required command that prints the product version.
  NAME_RUNTIME_CMD     Optional command that prints runtime component versions.

Socktainer defaults to the repository release binary, pinned guest artifact,
standard Docker socket, foreground ownership, and its engine storage paths.

Example:
  SOCKTAINER_DOCKER_HOST=unix:///tmp/socktainer.sock \
  SOCKTAINER_START_CMD='/path/to/socktainer --no-docker-context' \
  SOCKTAINER_START_MODE=foreground \
  SOCKTAINER_STORAGE_PATHS="$HOME/.socktainer:/path/to/guest-artifacts" \
  BENCH_PRODUCTS=socktainer scripts/benchmark-runtime.sh

Image references must include @sha256. Override BENCH_BASE_IMAGE and
BENCH_NGINX_IMAGE to use other pinned arm64 fixtures. Results are JSON. Console
output is a concise progress summary. Foreground commands are logged, measured
as an owned process tree, and stopped after each sample. Oneshot launchers need
a stop command and an owned PID command or precise PID patterns.
EOF
}

die() {
    echo "benchmark: $*" >&2
    exit 1
}

upper_name() {
    printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_'
}

product_value() {
    local prefix variable value product=$1 field=$2
    prefix=$(upper_name "$1")
    variable="${prefix}_$field"
    value=${!variable:-}
    if [[ -n $value || $product != socktainer ]]; then
        printf '%s' "$value"
        return
    fi
    case $field in
        DOCKER_HOST) printf 'unix://%s/socktainer-home/.socktainer/container.sock' "$ENGINE_STATE_DIR" ;;
        START_CMD) printf 'env SOCKTAINER_HOST_HOME_DIRECTORY=%q SOCKTAINER_ENGINE_STATE_DIRECTORY=%q %q --no-docker-context' \
            "$ENGINE_STATE_DIR/socktainer-home" "$ENGINE_STATE_DIR/socktainer-state" \
            "$REPO_ROOT/.build/release/socktainer" ;;
        RESET_CMD) printf 'rm -rf %q %q && mkdir -p %q %q' \
            "$ENGINE_STATE_DIR/socktainer-home" "$ENGINE_STATE_DIR/socktainer-state" \
            "$ENGINE_STATE_DIR/socktainer-home" "$ENGINE_STATE_DIR/socktainer-state" ;;
        START_MODE) printf 'foreground' ;;
        VERSION_CMD) printf '%q --version' "$REPO_ROOT/.build/release/socktainer" ;;
        RUNTIME_CMD) printf "printf 'Docker API v1.51; containerd 2.1.5; runc 1.3.4-r1'" ;;
        HELPER_PATTERNS) printf 'socktainer-vmm,gvproxy' ;;
        BIND_ROOT) printf '%s' "$ENGINE_STATE_DIR/socktainer-home" ;;
        STORAGE_PATHS) printf '%s:%s:%s:%s:%s:%s:%s' "$REPO_ROOT/.build/release/socktainer" \
            "$REPO_ROOT/VMM/out/socktainer-vmm" "$REPO_ROOT/VMM/out/libkrun.1.dylib" \
            "$REPO_ROOT/VMM/out/gvproxy" "$REPO_ROOT/Guest/out/socktainer-vmlinux" \
            "$REPO_ROOT/Guest/out/socktainer-root.ext4" \
            "$ENGINE_STATE_DIR/socktainer-state" ;;
        VM_MEMORY_BYTES) printf '%s' "$((1024 * 1024 * 1024))" ;;
        VM_ALLOCATED_MEMORY_BYTES) printf '%s' "$((1024 * 1024 * 1024))" ;;
    esac
}

docker_api() {
    DOCKER_HOST="$CURRENT_HOST" docker "$@"
}

cleanup_host() {
    local host=$1 id
    [[ -n $host ]] || return 0
    while IFS= read -r id; do
        [[ -n $id ]] || continue
        [[ $(DOCKER_HOST="$host" docker inspect --format '{{ index .Config.Labels "socktainer.benchmark.run" }}' "$id" 2>/dev/null) == "$RUN_ID" ]] || continue
        DOCKER_HOST="$host" docker rm -f "$id" >/dev/null 2>&1 || true
    done < <(DOCKER_HOST="$host" docker ps -aq \
        --filter "label=socktainer.benchmark.run=$RUN_ID" 2>/dev/null || true)
}

cleanup() {
    local exit_code=$? product host
    if [[ -d $RUN_DIRECTORY && $BENCHMARK_COMPLETE != true ]]; then
        [[ -f $RESULTS_FILE ]] && cp "$RESULTS_FILE" "$RUN_DIRECTORY/results.ndjson" 2>/dev/null || true
        [[ -f $PROCESS_FILE ]] && cp "$PROCESS_FILE" "$RUN_DIRECTORY/processes.ndjson" 2>/dev/null || true
        [[ -f $STORAGE_FILE ]] && cp "$STORAGE_FILE" "$RUN_DIRECTORY/storage.ndjson" 2>/dev/null || true
        jq -cn --arg runId "$RUN_ID" --argjson exitCode "$exit_code" \
            --arg product "$CURRENT_PRODUCT" --argjson sample "$CURRENT_SAMPLE" \
            --argjson position "$CURRENT_POSITION" --arg metric "$CURRENT_METRIC" \
            --arg endedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{status:"incomplete",runId:$runId,exitCode:$exitCode,endedAt:$endedAt,
              activeCell:{product:$product,sample:$sample,position:$position,metric:$metric}}' \
            > "$RUN_DIRECTORY/status.json.tmp" 2>/dev/null || true
        mv "$RUN_DIRECTORY/status.json.tmp" "$RUN_DIRECTORY/status.json" 2>/dev/null || true
    fi
    IFS=',' read -r -a product_list <<< "$PRODUCTS"
    for product in "${product_list[@]}"; do
        host=$(product_value "$product" DOCKER_HOST)
        cleanup_host "$host"
        stop_product "$product" || true
    done
    [[ -n $RESULTS_FILE ]] && rm -f "$RESULTS_FILE"
    [[ -n $PROCESS_FILE ]] && rm -f "$PROCESS_FILE"
    [[ -n $STORAGE_FILE ]] && rm -f "$STORAGE_FILE"
    [[ -n $ENGINE_STATE_DIR ]] && rm -rf "$ENGINE_STATE_DIR"
    [[ -n $BIND_STATE_DIR ]] && rm -rf "$BIND_STATE_DIR"
}
trap cleanup EXIT
record_failure() {
    local exit_code=$? line=${1:-unknown}
    if [[ -d $RUN_DIRECTORY ]]; then
        [[ -f $RESULTS_FILE ]] && cp "$RESULTS_FILE" "$RUN_DIRECTORY/results.ndjson" 2>/dev/null || true
        [[ -f $PROCESS_FILE ]] && cp "$PROCESS_FILE" "$RUN_DIRECTORY/processes.ndjson" 2>/dev/null || true
        [[ -f $STORAGE_FILE ]] && cp "$STORAGE_FILE" "$RUN_DIRECTORY/storage.ndjson" 2>/dev/null || true
        jq -cn --arg runId "$RUN_ID" --argjson exitCode "$exit_code" --arg line "$line" \
            --arg product "$CURRENT_PRODUCT" --argjson sample "$CURRENT_SAMPLE" \
            --argjson position "$CURRENT_POSITION" --arg metric "$CURRENT_METRIC" \
            --arg endedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{status:"incomplete",runId:$runId,exitCode:$exitCode,line:$line,endedAt:$endedAt,
              activeCell:{product:$product,sample:$sample,position:$position,metric:$metric}}' \
            > "$RUN_DIRECTORY/status.json.tmp" 2>/dev/null || true
        mv "$RUN_DIRECTORY/status.json.tmp" "$RUN_DIRECTORY/status.json" 2>/dev/null || true
    fi
    return "$exit_code"
}
trap 'record_failure "$LINENO"' ERR
trap 'exit 130' INT
trap 'exit 143' TERM

docker_elapsed_ms() {
    python3 - "$@" <<'PY'
import os, subprocess, sys, time
host, *arguments = sys.argv[1:]
environment = dict(os.environ, DOCKER_HOST=host)
start = time.perf_counter_ns()
result = subprocess.run(["docker", *arguments], env=environment,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
elapsed = (time.perf_counter_ns() - start) / 1_000_000
if result.returncode:
    raise SystemExit(result.returncode)
print(f"{elapsed:.6f}")
PY
}

api_ping_fresh_ms() {
    python3 - "$1" <<'PY'
import socket, statistics, sys, time

path = sys.argv[1]

def request():
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(2)
    start = time.perf_counter_ns()
    try:
        client.connect(path)
        client.sendall(b"GET /_ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        response = b""
        while True:
            chunk = client.recv(4096)
            if not chunk:
                break
            response += chunk
        headers, separator, body = response.partition(b"\r\n\r\n")
        if b"transfer-encoding: chunked" in headers.lower():
            decoded = b""
            while body:
                size_line, separator, body = body.partition(b"\r\n")
                if not separator:
                    raise RuntimeError("invalid chunk framing")
                size = int(size_line.split(b";", 1)[0], 16)
                if size == 0:
                    break
                decoded += body[:size]
                body = body[size + 2:]
            body = decoded
        if b" 200 " not in headers or body.strip() != b"OK":
            raise RuntimeError("invalid /_ping response")
    finally:
        client.close()
    return (time.perf_counter_ns() - start) / 1_000_000

for _ in range(50):
    request()
values = [request() for _ in range(500)]
print(f"{statistics.median(values):.6f}")
PY
}

live_wait_delivery_ms() {
    python3 - "$1" "$2" <<'PY'
import os, socket, subprocess, sys, threading, time

host, name = sys.argv[1:]
environment = dict(os.environ, DOCKER_HOST=host)
socket_path = host.removeprefix("unix://")
request_sent = threading.Event()
result = {}

def wait_for_next_exit():
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(30)
    try:
        client.connect(socket_path)
        request = (f"POST /v1.51/containers/{name}/wait?condition=next-exit HTTP/1.1\r\n"
                   "Host: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        client.sendall(request.encode())
        response = b""
        request_sent.set()
        while True:
            chunk = client.recv(4096)
            if not chunk:
                break
            response += chunk
        result["response"] = response
    except BaseException as error:
        result["error"] = error
    finally:
        client.close()

waiter = threading.Thread(target=wait_for_next_exit, daemon=True)
waiter.start()
if not request_sent.wait(timeout=2):
    raise SystemExit("wait request was not sent")
if not waiter.is_alive():
    raise SystemExit("next-exit wait returned while the container was still running")
time.sleep(0.010)
start = time.perf_counter_ns()
killer = subprocess.run(["docker", "kill", name], env=environment,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
if killer.returncode:
    raise SystemExit(killer.returncode)
waiter.join(timeout=30)
if waiter.is_alive():
    raise SystemExit("registered wait did not complete")
if "error" in result:
    raise result["error"]
response = result.get("response", b"")
headers, separator, body = response.partition(b"\r\n\r\n")
if not separator or b" 200 " not in headers or b'"StatusCode"' not in body:
    raise SystemExit(f"invalid wait response: {response[:200]!r}")
print(f"{(time.perf_counter_ns() - start) / 1_000_000:.6f}")
PY
}

socket_ready_ms() {
    python3 - "$1" "$2" <<'PY'
import socket, sys, time
socket_path, started_ns = sys.argv[1], int(sys.argv[2])
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(0.1)
    try:
        client.connect(socket_path)
        client.sendall(b"GET /_ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        response = b""
        while b"OK" not in response:
            chunk = client.recv(4096)
            if not chunk:
                break
            response += chunk
        if b" 200 " in response and response.rstrip().endswith(b"OK"):
            print(f"{(time.time_ns() - started_ns) / 1_000_000:.6f}")
            raise SystemExit(0)
    except OSError:
        pass
    finally:
        client.close()
    time.sleep(0.001)
raise SystemExit("engine did not answer /_ping within 30 seconds")
PY
}

now_ns() {
    perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000000000'
}

elapsed_since_ms() {
    python3 - "$1" <<'PY'
import sys, time
print(f"{(time.time_ns() - int(sys.argv[1])) / 1_000_000:.6f}")
PY
}

nginx_ready_ms() {
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import http.client, os, subprocess, sys, time
host, name, image, label = sys.argv[1:]
environment = dict(os.environ, DOCKER_HOST=host)
start = time.perf_counter_ns()
subprocess.run(["docker", "create", "--name", name, "--label", label,
                "-p", "127.0.0.1::80", image], env=environment,
               check=True, stdout=subprocess.DEVNULL)
subprocess.run(["docker", "start", name], env=environment,
               check=True, stdout=subprocess.DEVNULL)
port_output = subprocess.check_output(
    ["docker", "port", name, "80/tcp"], env=environment, text=True)
port = int(port_output.strip().splitlines()[-1].rsplit(":", 1)[-1])
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=0.1)
    try:
        connection.request("GET", "/")
        response = connection.getresponse()
        response.read()
        if 200 <= response.status < 400:
            print(f"{(time.perf_counter_ns() - start) / 1_000_000:.6f} {port}")
            raise SystemExit(0)
    except OSError:
        pass
    finally:
        connection.close()
    time.sleep(0.001)
raise SystemExit("nginx did not become ready within 30 seconds")
PY
}

append_result() {
    local product=$1 sample=$2 position=$3 cohort=$4 metric=$5 value=$6 unit=$7
    jq -cn \
        --arg product "$product" --argjson sample "$sample" \
        --argjson position "$position" --arg cohort "$cohort" --arg metric "$metric" \
        --argjson value "$value" --arg unit "$unit" \
        '{product:$product,sample:$sample,position:$position,cohort:$cohort,metric:$metric,value:$value,unit:$unit}' \
        >> "$RESULTS_FILE"
    printf '  %-26s %12s %s\n' "$metric" "$value" "$unit"
}

begin_metric() {
    CURRENT_METRIC=$1
}

finalize_json() {
    local tmp_output product product_info version version_cmd runtime runtime_cmd vm_memory vm_allocated_memory source_dirty harness_sha guest_sha binary_sha source_diff_sha
    tmp_output="$OUTPUT.tmp.$$"
    source_dirty=false
    git diff --quiet --ignore-submodules HEAD -- 2>/dev/null || source_dirty=true
    git diff --cached --quiet --ignore-submodules HEAD -- 2>/dev/null || source_dirty=true
    [[ -z $(git ls-files --others --exclude-standard 2>/dev/null) ]] || source_dirty=true
    harness_sha=$(shasum -a 256 "$REPO_ROOT/scripts/benchmark-runtime.sh" | awk '{print $1}')
    guest_sha=$(
        {
            shasum -a 256 "$REPO_ROOT/Guest/out/socktainer-vmlinux" 2>/dev/null
            shasum -a 256 "$REPO_ROOT/Guest/out/socktainer-root.ext4" 2>/dev/null
        } | shasum -a 256 | awk '{print $1}'
    )
    binary_sha=$(shasum -a 256 "$REPO_ROOT/.build/release/socktainer" 2>/dev/null | awk '{print $1}')
    source_diff_sha=$(
        {
            git diff --binary HEAD 2>/dev/null
            git ls-files --others --exclude-standard -z 2>/dev/null \
                | sort -z \
                | xargs -0 shasum -a 256
        } | shasum -a 256 | awk '{print $1}'
    )
    product_info='[]'
    for product in "${product_list[@]}"; do
        version_cmd=$(product_value "$product" VERSION_CMD)
        version=$(first_line "$version_cmd")
        runtime_cmd=$(product_value "$product" RUNTIME_CMD)
        runtime=''
        [[ -n $runtime_cmd ]] && runtime=$(first_line "$runtime_cmd")
        vm_memory=$(product_value "$product" VM_MEMORY_BYTES)
        vm_allocated_memory=$(product_value "$product" VM_ALLOCATED_MEMORY_BYTES)
        product_info=$(jq -cn \
            --argjson existing "$product_info" --arg name "$product" \
            --arg version "$version" --arg host "$(product_value "$product" DOCKER_HOST)" \
            --arg startMode "$(product_value "$product" START_MODE)" \
            --arg startCommand "$(product_value "$product" START_CMD)" \
            --arg stopCommand "$(product_value "$product" STOP_CMD)" \
            --arg resetCommand "$(product_value "$product" RESET_CMD)" \
            --arg ownedPIDsCommand "$(product_value "$product" OWNED_PIDS_CMD)" \
            --arg pidPatterns "$(product_value "$product" PID_PATTERNS)" \
            --arg versionCommand "$version_cmd" --arg runtime "$runtime" \
            --arg runtimeCommand "$runtime_cmd" \
            --arg storagePaths "$(product_value "$product" STORAGE_PATHS)" \
            --argjson configuredVMMemoryBytes "$vm_memory" \
            --argjson allocatedVMMemoryBytes "$vm_allocated_memory" \
            '$existing + [{name:$name,version:$version,runtime:$runtime,
              dockerHost:$host,startMode:$startMode,startCommand:$startCommand,
              stopCommand:$stopCommand,resetCommand:$resetCommand,ownedPIDsCommand:$ownedPIDsCommand,
              pidPatterns:$pidPatterns,versionCommand:$versionCommand,
              runtimeCommand:$runtimeCommand,storagePaths:($storagePaths|split(":")),
              configuredVMMemoryBytes:$configuredVMMemoryBytes,
              allocatedVMMemoryBytes:$allocatedVMMemoryBytes}]')
    done
    jq -s \
        --arg run_id "$RUN_ID" \
        --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg commit "$(git rev-parse HEAD 2>/dev/null || echo unknown)" \
        --argjson source_dirty "$source_dirty" \
        --arg harness_sha "$harness_sha" \
        --arg guest_sha "$guest_sha" \
        --arg binary_sha "$binary_sha" \
        --arg source_diff_sha "$source_diff_sha" \
        --arg os "$(sw_vers -productVersion)" \
        --arg arch "$(uname -m)" \
        --arg model "$(sysctl -n hw.model)" \
        --argjson cpu_count "$(sysctl -n hw.logicalcpu)" \
        --argjson memory_bytes "$(sysctl -n hw.memsize)" \
        --arg docker_client "$(docker --version)" \
        --arg base_image "$BASE_IMAGE" --arg nginx_image "$NGINX_IMAGE" \
        --argjson requested_samples "$SAMPLES" \
        --argjson ab_requests "$AB_REQUESTS" \
        --argjson ab_concurrency "$AB_CONCURRENCY" \
        --argjson bind_mib "$BIND_MIB" \
        --argjson product_count "${#product_list[@]}" \
        --argjson products "$product_info" --slurpfile process_samples "$PROCESS_FILE" \
        --slurpfile storage_samples "$STORAGE_FILE" \
        'def median: sort as $v | ($v|length) as $n |
            if $n == 0 then null
            elif ($n % 2) == 1 then $v[($n/2)|floor]
            else (($v[$n/2-1] + $v[$n/2]) / 2) end;
         . as $results |
         {schemaVersion:2,status:"complete",runId:$run_id,generatedAt:$generated_at,
          host:{os:$os,arch:$arch,model:$model,logicalCPUCount:$cpu_count,memoryBytes:$memory_bytes},
          gitCommit:$commit,sourceDirty:$source_dirty,dockerClient:$docker_client,
          provenance:{harnessSHA256:$harness_sha,guestImageSHA256:$guest_sha,
            socktainerBinarySHA256:$binary_sha,sourceDiffSHA256:$source_diff_sha},
          products:$products,processSamples:$process_samples,storageSamples:$storage_samples,
          configuration:{baseImage:$base_image,nginxImage:$nginx_image,
            samples:$requested_samples,abRequests:$ab_requests,
            abConcurrency:$ab_concurrency,bindMiB:$bind_mib,
            experimentalDesign:{name:(if $product_count == 4 then "four-treatment Williams design" else "cyclic position design" end),
              balance:(if $product_count == 4 then "Each four-sample block balances position and first-order carryover" else "Position balance only; first-order carryover is not claimed" end),
              orderRecordedPerResult:true},
            cohorts:{cold:"Engine state and image store reset before each product sample",
              warm:"Metrics after the first pinned common workload completes",
              bindCache:"One unmeasured read warms the same working set for every product"},
            timingBoundaries:{socketReady:"before engine launch through the first valid direct /_ping response",
              commonCapabilityReady:"before engine launch through pull of both pinned images and successful run --rm true",
              apiPing:"one fresh Unix-socket connection and direct HTTP request; Docker CLI is excluded",
              lifecycle:"Docker CLI process wall time",
              liveWait:"wait request sent while container is running; docker kill start through wait exit delivery",
              nginxReady:"before docker create through first successful HTTP response",
              bindIO:"BusyBox dd bytes divided by dd-reported in-container elapsed time; write includes conv=fsync; cached read follows one unmeasured warm read",
              reclaim:"Bind and nginx containers and bind file removed, followed by a fixed five-second free-page/balloon settlement interval"}},
          results:$results,
          summary: ($results | sort_by(.product,.metric) |
            group_by([.product,.metric]) | map(
              . as $group | (map(.value)|sort) as $values |
              {product:$group[0].product,metric:$group[0].metric,
               unit:$group[0].unit,count:($values|length),
               median:($values|median),min:$values[0],max:$values[-1],
               spread:($values[-1]-$values[0])}
            ))}' \
        "$RESULTS_FILE" > "$tmp_output"
    mv "$tmp_output" "$OUTPUT"
}

validate_results() {
    local expected_metrics=22 expected_rows
    expected_rows=$((SAMPLES * ${#product_list[@]} * expected_metrics))
    jq -es --argjson expected "$expected_rows" '
        length == $expected
        and (map([.product,.sample,.metric] | join("\u0000")) | unique | length) == $expected
        and all(.[]; (.value | type) == "number")
        and all(.[]; (.cohort == "cold" or .cohort == "warm" or .cohort == "bind_cache" or .cohort == "reclaim"))
    ' "$RESULTS_FILE" | grep -qx true \
        || die "result matrix is incomplete, duplicated, or non-numeric"
    jq -es --argjson expected "$((SAMPLES * ${#product_list[@]} * 4))" \
        'length == $expected and all(.[]; (.processes | type) == "array")' \
        "$PROCESS_FILE" | grep -qx true || die "process snapshot matrix is incomplete"
    jq -es --argjson expected "$((SAMPLES * ${#product_list[@]}))" \
        'length == $expected and all(.[];
          (.paths | type) == "array" and ([.paths[].allocatedBytes]|add) == .allocatedBytes
          and ([.paths[].logicalBytes]|add) == .logicalBytes)' \
        "$STORAGE_FILE" | grep -qx true || die "storage snapshot matrix is incomplete"
}

first_line() {
    local command=$1 output
    output=$(eval "$command" 2>&1)
    IFS=$'\n' read -r output _ <<< "$output"
    printf '%s' "$output"
}

owned_pids() {
    local product=$1 patterns helper_patterns pids_cmd roots='' extra_roots pid_file baseline_file baseline pids
    patterns=$(product_value "$product" PID_PATTERNS)
    helper_patterns=$(product_value "$product" HELPER_PATTERNS)
    pids_cmd=$(product_value "$product" OWNED_PIDS_CMD)
    pid_file="$ENGINE_STATE_DIR/$product.pid"
    baseline_file="$ENGINE_STATE_DIR/$product.helper-baseline"
    baseline=$([[ -f $baseline_file ]] && tr '\n' ' ' < "$baseline_file" || true)
    [[ -s $pid_file ]] && roots=$(tr '\n' ' ' < "$pid_file")
    if [[ -n $pids_cmd ]]; then
        extra_roots=$(eval "$pids_cmd" | tr '\n' ' ')
        roots+=" $extra_roots"
    fi
    pids=$(ps -axo pid=,ppid=,rss=,command= | awk -v roots="$roots" -v patterns="$patterns" \
        -v helperPatterns="$helper_patterns" -v baseline="$baseline" '
        BEGIN {
            rootCount=split(roots, root, " ")
            patternCount=split(patterns, pattern, ",")
            helperCount=split(helperPatterns, helperPattern, ",")
            baselineCount=split(baseline, baselinePID, " ")
            for (i=1; i<=rootCount; i++) if (root[i] ~ /^[0-9]+$/) owned[root[i]]=1
            for (i=1; i<=baselineCount; i++) if (baselinePID[i] ~ /^[0-9]+$/) existed[baselinePID[i]]=1
        }
        { pid[NR]=$1; ppid[NR]=$2; rss[NR]=$3; command[NR]=$0 }
        END {
            changed=1
            while (changed) {
                changed=0
                for (i=1; i<=NR; i++) if (!owned[pid[i]] && owned[ppid[i]]) {
                    owned[pid[i]]=1; changed=1
                }
            }
            for (i=1; i<=NR; i++) {
                matched=0
                if (patterns != "") for (j=1; j<=patternCount; j++) {
                    if (pattern[j] != "" && command[i] ~ pattern[j]) { matched=1; break }
                }
                if (!matched && !existed[pid[i]] && helperPatterns != "") {
                    for (j=1; j<=helperCount; j++) if (helperPattern[j] != "" && command[i] ~ helperPattern[j]) {
                        matched=1; break
                    }
                }
                if (owned[pid[i]] || matched) print pid[i]
            }
        }
    ' | sort -n -u | tr '\n' ' ')
    printf '%s\n' "$pids"
}

owned_memory_bytes() {
    local product=$1 pids
    local -a pid_list
    pids=$(owned_pids "$product")
    [[ -n $pids ]] || { echo 0; return; }
    read -r -a pid_list <<< "$pids"
    footprint -f bytes "${pid_list[@]}" 2>/dev/null \
        | awk '/^Summary Footprint:/ {summary=$3} /^[[:space:]]*phys_footprint:/ {single=$2; count++}
               END {if (summary != "") print summary; else if (count == 1) print single; else exit 1}'
}

record_process_snapshot() {
    local product=$1 sample=$2 phase=$3 pids
    pids=$(owned_pids "$product")
    ps -axo pid=,ppid=,rss=,command= | awk -v selected="$pids" '
        BEGIN { count=split(selected, values, " "); for (i=1; i<=count; i++) keep[values[i]]=1 }
        keep[$1] { print }
    ' | jq -Rsc --arg product "$product" --argjson sample "$sample" --arg phase "$phase" '
        split("\n") | map(select(length > 0) |
          capture("^\\s*(?<pid>[0-9]+)\\s+(?<ppid>[0-9]+)\\s+(?<rssKiB>[0-9]+)\\s+(?<command>.*)$") |
          {pid:(.pid|tonumber),ppid:(.ppid|tonumber),residentBytes:((.rssKiB|tonumber)*1024),command:.command,
           classification:(if (.command|test("socktainer-vmm|Virtualization\\.VirtualMachine|qemu-system";"i")) then "virtual-machine"
             elif (.command|test("gvproxy|vpnkit|slirp";"i")) then "network-helper"
             elif (.command|test("Docker\\.app|Dory\\.app";"i")) then "user-interface"
             else "daemon-or-helper" end)}) as $processes |
        {product:$product,sample:$sample,phase:$phase,processes:$processes}
    ' >> "$PROCESS_FILE"
}

launch_product() {
    local product=$1 command mode pid_file log_file helper_patterns baseline_file
    command=$(product_value "$product" START_CMD)
    mode=$(product_value "$product" START_MODE)
    mode=${mode:-oneshot}
    pid_file="$ENGINE_STATE_DIR/$product.pid"
    log_file="$ENGINE_STATE_DIR/$product.log"
    baseline_file="$ENGINE_STATE_DIR/$product.helper-baseline"
    helper_patterns=$(product_value "$product" HELPER_PATTERNS)
    rm -f "$pid_file"
    ps -axo pid=,command= | awk -v patterns="$helper_patterns" '
        BEGIN { count=split(patterns, pattern, ",") }
        patterns != "" { for (i=1; i<=count; i++) if (pattern[i] != "" && $0 ~ pattern[i]) { print $1; break } }
    ' > "$baseline_file"
    : > "$ENGINE_STATE_DIR/$product.started"
    if [[ $mode == foreground ]]; then
        /bin/bash -c "exec $command" >"$log_file" 2>&1 &
        printf '%s\n' "$!" > "$pid_file"
    else
        eval "$command"
    fi
}

stop_product() {
    local product=$1 force=${2:-} stop_cmd pid_file pid
    if [[ $force != force && ! -e $ENGINE_STATE_DIR/$product.started ]]; then
        return 0
    fi
    stop_cmd=$(product_value "$product" STOP_CMD)
    pid_file="$ENGINE_STATE_DIR/$product.pid"
    if [[ -n $stop_cmd ]]; then
        eval "$stop_cmd" >/dev/null 2>&1 || true
    elif [[ -s $pid_file ]]; then
        pid=$(head -1 "$pid_file")
        kill -TERM "$pid" >/dev/null 2>&1 || true
        for _ in {1..300}; do
            kill -0 "$pid" >/dev/null 2>&1 || break
            sleep 0.01
        done
        kill -KILL "$pid" >/dev/null 2>&1 || true
    fi
    rm -f "$pid_file" "$ENGINE_STATE_DIR/$product.started" "$ENGINE_STATE_DIR/$product.helper-baseline"
}

storage_bytes() {
    local paths=$1 mode=$2 path total=0 kib
    IFS=':' read -r -a path_list <<< "$paths"
    for path in "${path_list[@]}"; do
        [[ -e $path ]] || continue
        if [[ $mode == logical ]]; then
            kib=$(du -skA "$path" | awk '{print $1}')
        else
            kib=$(du -sk "$path" | awk '{print $1}')
        fi
        total=$((total + kib * 1024))
    done
    printf '%s\n' "$total"
}

record_storage_snapshot() {
    local product=$1 sample=$2 paths=$3 path allocated logical details='[]'
    IFS=':' read -r -a path_list <<< "$paths"
    for path in "${path_list[@]}"; do
        if [[ -e $path ]]; then
            allocated=$(storage_bytes "$path" allocated)
            logical=$(storage_bytes "$path" logical)
            details=$(jq -cn --argjson existing "$details" --arg path "$path" \
                --argjson allocated "$allocated" --argjson logical "$logical" \
                '$existing + [{path:$path,present:true,allocatedBytes:$allocated,logicalBytes:$logical}]')
        else
            details=$(jq -cn --argjson existing "$details" --arg path "$path" \
                '$existing + [{path:$path,present:false,allocatedBytes:0,logicalBytes:0}]')
        fi
    done
    jq -cn --arg product "$product" --argjson sample "$sample" --argjson paths "$details" \
        '{product:$product,sample:$sample,paths:$paths,
          allocatedBytes:($paths|map(.allocatedBytes)|add),
          logicalBytes:($paths|map(.logicalBytes)|add)}' >> "$STORAGE_FILE"
}

preflight_product() {
    local product=$1 host start_cmd start_mode stop_cmd reset_cmd patterns pids_cmd paths version_cmd vm_memory vm_allocated_memory socket
    host=$(product_value "$product" DOCKER_HOST)
    start_cmd=$(product_value "$product" START_CMD)
    start_mode=$(product_value "$product" START_MODE)
    start_mode=${start_mode:-oneshot}
    stop_cmd=$(product_value "$product" STOP_CMD)
    reset_cmd=$(product_value "$product" RESET_CMD)
    patterns=$(product_value "$product" PID_PATTERNS)
    pids_cmd=$(product_value "$product" OWNED_PIDS_CMD)
    paths=$(product_value "$product" STORAGE_PATHS)
    version_cmd=$(product_value "$product" VERSION_CMD)
    vm_memory=$(product_value "$product" VM_MEMORY_BYTES)
    vm_allocated_memory=$(product_value "$product" VM_ALLOCATED_MEMORY_BYTES)
    [[ $host == unix://* ]] || die "${product}: NAME_DOCKER_HOST must use unix://"
    [[ -n $start_cmd ]] || die "${product}: NAME_START_CMD is required"
    [[ $start_mode == foreground || $start_mode == oneshot ]] || die "${product}: NAME_START_MODE must be foreground or oneshot"
    if [[ $start_mode == oneshot ]]; then
        [[ -n $stop_cmd ]] || die "${product}: NAME_STOP_CMD is required in oneshot mode"
        [[ -n $patterns || -n $pids_cmd ]] || die "${product}: oneshot mode needs NAME_OWNED_PIDS_CMD or NAME_PID_PATTERNS"
    fi
    [[ -n $paths ]] || die "${product}: NAME_STORAGE_PATHS is required"
    [[ -n $reset_cmd ]] || die "${product}: NAME_RESET_CMD is required for independent samples"
    [[ -n $version_cmd ]] || die "${product}: NAME_VERSION_CMD is required"
    [[ $vm_memory =~ ^[0-9]+$ ]] || die "${product}: NAME_VM_MEMORY_BYTES must be a nonnegative integer"
    [[ $vm_allocated_memory =~ ^[0-9]+$ ]] || die "${product}: NAME_VM_ALLOCATED_MEMORY_BYTES must be a nonnegative integer"
    eval "$version_cmd" >/dev/null 2>&1 || die "${product}: NAME_VERSION_CMD failed"
    if [[ $product == socktainer && -z ${SOCKTAINER_START_CMD:-} ]]; then
        [[ -x $REPO_ROOT/.build/release/socktainer ]] || die "socktainer: run 'make release' first or set SOCKTAINER_START_CMD"
        for artifact in VMM/out/socktainer-vmm VMM/out/libkrun.1.dylib VMM/out/gvproxy \
            Guest/out/socktainer-vmlinux Guest/out/socktainer-root.ext4; do
            [[ -s $REPO_ROOT/$artifact ]] || die "socktainer: custom VMM artifact is missing: $artifact"
        done
    fi
    socket=${host#unix://}
    printf 'preflight: %-12s host=%s socket=%s\n' "$product" "$host" "$socket"
}

preflight() {
    local tool product seen_products=','
    for tool in docker curl jq python3 perl ab awk sed ps du mktemp sysctl footprint; do
        command -v "$tool" >/dev/null || die "required tool is not installed: $tool"
    done
    [[ $BASE_IMAGE == *@sha256:* ]] || die "BENCH_BASE_IMAGE must be pinned by digest"
    [[ $NGINX_IMAGE == *@sha256:* ]] || die "BENCH_NGINX_IMAGE must be pinned by digest"
    [[ $SAMPLES =~ ^[1-9][0-9]*$ ]] || die "samples must be a positive integer"
    [[ $AB_REQUESTS =~ ^[1-9][0-9]*$ ]] || die "BENCH_AB_REQUESTS must be a positive integer"
    [[ $AB_CONCURRENCY =~ ^[1-9][0-9]*$ ]] || die "BENCH_AB_CONCURRENCY must be a positive integer"
    [[ $BIND_MIB =~ ^[1-9][0-9]*$ ]] || die "BENCH_BIND_MIB must be a positive integer"
    IFS=',' read -r -a product_list <<< "$PRODUCTS"
    [[ ${#product_list[@]} -gt 0 ]] || die "at least one product is required"
    ((SAMPLES % ${#product_list[@]} == 0)) || die "samples must be divisible by the product count for position balance"
    for product in "${product_list[@]}"; do
        [[ $product =~ ^[a-zA-Z0-9_-]+$ ]] || die "invalid product name: $product"
        [[ $seen_products != *",$product,"* ]] || die "duplicate product name: $product"
        seen_products+="$product,"
        preflight_product "$product"
    done
    echo "preflight: ok"
}

rotation_for_sample() {
    local sample=$1 block_index sequence index
    if ((${#product_list[@]} == 4)); then
        block_index=$(((sample - 1) % 4))
        case $block_index in
            0) sequence='0 1 3 2' ;;
            1) sequence='1 2 0 3' ;;
            2) sequence='2 3 1 0' ;;
            3) sequence='3 0 2 1' ;;
        esac
        for index in $sequence; do printf '%s\n' "${product_list[$index]}"; done
        return
    fi
    for ((index = 0; index < ${#product_list[@]}; index++)); do
        printf '%s\n' "${product_list[$(((sample - 1 + index) % ${#product_list[@]}))]}"
    done
}

wait_for_engine_stop() {
    local socket=$1 deadline=$((SECONDS + 30))
    while ((SECONDS < deadline)); do
        if ! curl --silent --fail --unix-socket "$socket" http://localhost/_ping >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

benchmark_product() {
    local product=$1 sample=$2 position=$3
    local host paths socket start_ns value readiness
    local name runner nginx port ab_output failed complete non_2xx observed_concurrency rps bind_root bind_dir bind_runner dd_output
    host=$(product_value "$product" DOCKER_HOST)
    paths=$(product_value "$product" STORAGE_PATHS)
    socket=${host#unix://}
    CURRENT_HOST=$host
    CURRENT_PRODUCT=$product
    CURRENT_SAMPLE=$sample
    CURRENT_POSITION=$position
    begin_metric reset_and_launch
    cleanup_host "$host"
    printf '\nsample %d position %d: %s\n' "$sample" "$position" "$product"

    stop_product "$product" force
    wait_for_engine_stop "$socket" || die "$product stop command left the Docker API available"
    eval "$(product_value "$product" RESET_CMD)"
    start_ns=$(now_ns)
    launch_product "$product"
    begin_metric socket_ready
    if ! value=$(socket_ready_ms "$socket" "$start_ns"); then
        [[ -f $ENGINE_STATE_DIR/$product.log ]] && tail -50 "$ENGINE_STATE_DIR/$product.log" >&2
        die "$product did not answer /_ping"
    fi
    append_result "$product" "$sample" "$position" cold socket_ready "$value" ms

    begin_metric api_ping_fresh_connection
    value=$(api_ping_fresh_ms "$socket")
    append_result "$product" "$sample" "$position" cold api_ping_fresh_connection "$value" ms
    begin_metric cold_idle_physical_footprint
    record_process_snapshot "$product" "$sample" cold_idle
    append_result "$product" "$sample" "$position" cold cold_idle_physical_footprint "$(owned_memory_bytes "$product")" bytes

    begin_metric common_capability_ready
    docker_api pull "$BASE_IMAGE" >/dev/null
    [[ $NGINX_IMAGE == "$BASE_IMAGE" ]] || docker_api pull "$NGINX_IMAGE" >/dev/null

    docker_api run --rm --label "socktainer.benchmark.run=$RUN_ID" "$BASE_IMAGE" /bin/true >/dev/null
    value=$(elapsed_since_ms "$start_ns")
    append_result "$product" "$sample" "$position" cold common_capability_ready "$value" ms

    begin_metric container_create
    name="$RUN_ID-$sample-$product-create"
    value=$(docker_elapsed_ms "$host" create --name "$name" --label "socktainer.benchmark.run=$RUN_ID" "$BASE_IMAGE" /bin/true)
    append_result "$product" "$sample" "$position" warm container_create "$value" ms
    docker_api rm "$name" >/dev/null

    begin_metric container_start
    name="$RUN_ID-$sample-$product-start"
    docker_api create --name "$name" --label "socktainer.benchmark.run=$RUN_ID" "$BASE_IMAGE" /bin/true >/dev/null
    value=$(docker_elapsed_ms "$host" start "$name")
    append_result "$product" "$sample" "$position" warm container_start "$value" ms
    docker_api wait "$name" >/dev/null
    docker_api rm "$name" >/dev/null

    begin_metric completed_wait_lookup
    name="$RUN_ID-$sample-$product-wait"
    docker_api create --name "$name" --label "socktainer.benchmark.run=$RUN_ID" "$BASE_IMAGE" /bin/true >/dev/null
    docker_api start "$name" >/dev/null
    while [[ $(docker_api inspect --format '{{.State.Running}}' "$name") == true ]]; do sleep 0.005; done
    value=$(docker_elapsed_ms "$host" wait "$name")
    append_result "$product" "$sample" "$position" warm completed_wait_lookup "$value" ms
    docker_api rm "$name" >/dev/null

    begin_metric live_wait_kill_to_exit_delivery
    name="$RUN_ID-$sample-$product-live-wait"
    docker_api create --name "$name" --label "socktainer.benchmark.run=$RUN_ID" \
        "$BASE_IMAGE" /bin/sh -c 'trap "exit 0" TERM INT; while :; do sleep 1; done' >/dev/null
    docker_api start "$name" >/dev/null
    value=$(live_wait_delivery_ms "$host" "$name")
    append_result "$product" "$sample" "$position" warm live_wait_kill_to_exit_delivery "$value" ms
    docker_api rm "$name" >/dev/null

    begin_metric container_remove
    name="$RUN_ID-$sample-$product-remove"
    docker_api create --name "$name" --label "socktainer.benchmark.run=$RUN_ID" "$BASE_IMAGE" /bin/true >/dev/null
    value=$(docker_elapsed_ms "$host" rm "$name")
    append_result "$product" "$sample" "$position" warm container_remove "$value" ms

    begin_metric run_remove_true
    value=$(docker_elapsed_ms "$host" run --rm --label "socktainer.benchmark.run=$RUN_ID" "$BASE_IMAGE" /bin/true)
    append_result "$product" "$sample" "$position" warm run_remove_true "$value" ms

    begin_metric exec_true
    runner="$RUN_ID-$sample-$product-runner"
    docker_api create --name "$runner" --label "socktainer.benchmark.run=$RUN_ID" "$BASE_IMAGE" \
        /bin/sh -c 'trap "exit 0" TERM INT; while :; do sleep 1; done' >/dev/null
    docker_api start "$runner" >/dev/null
    value=$(docker_elapsed_ms "$host" exec "$runner" /bin/true)
    append_result "$product" "$sample" "$position" warm exec_true "$value" ms
    begin_metric sha256_1gib
    value=$(docker_elapsed_ms "$host" exec "$runner" /bin/sh -c 'head -c 1073741824 /dev/zero | sha256sum >/dev/null')
    value=$(awk -v milliseconds="$value" 'BEGIN {printf "%.6f", milliseconds/1000}')
    append_result "$product" "$sample" "$position" warm sha256_1gib "$value" seconds

    begin_metric four_idle_containers_physical_footprint
    for index in 1 2 3; do
        docker_api create --name "$runner-$index" --label "socktainer.benchmark.run=$RUN_ID" "$BASE_IMAGE" \
            /bin/sh -c 'trap "exit 0" TERM INT; while :; do sleep 1; done' >/dev/null
        docker_api start "$runner-$index" >/dev/null
    done
    sleep 1
    record_process_snapshot "$product" "$sample" four_containers
    append_result "$product" "$sample" "$position" warm four_idle_containers_physical_footprint "$(owned_memory_bytes "$product")" bytes

    begin_metric nginx_ready
    nginx="$RUN_ID-$sample-$product-nginx"
    readiness=$(nginx_ready_ms "$host" "$nginx" "$NGINX_IMAGE" "socktainer.benchmark.run=$RUN_ID")
    value=${readiness%% *}
    port=${readiness##* }
    append_result "$product" "$sample" "$position" warm nginx_ready "$value" ms
    begin_metric nginx_requests_per_second
    ab_output=$(ab -k -n "$AB_REQUESTS" -c "$AB_CONCURRENCY" "http://127.0.0.1:$port/")
    failed=$(awk '/Failed requests:/ {print $3}' <<< "$ab_output")
    complete=$(awk '/Complete requests:/ {print $3}' <<< "$ab_output")
    non_2xx=$(awk '/Non-2xx responses:/ {print $3}' <<< "$ab_output")
    observed_concurrency=$(awk '/Concurrency Level:/ {print $3}' <<< "$ab_output")
    [[ $complete == "$AB_REQUESTS" && $failed == 0 && ${non_2xx:-0} == 0 \
        && $observed_concurrency == "$AB_CONCURRENCY" ]] \
        || die "$product: ab invalid (complete=$complete failed=$failed non2xx=${non_2xx:-0} concurrency=${observed_concurrency:-missing})"
    rps=$(awk '/Requests per second:/ {print $4}' <<< "$ab_output")
    append_result "$product" "$sample" "$position" warm nginx_requests_per_second "$rps" requests_per_second
    append_result "$product" "$sample" "$position" warm nginx_failed_requests "$failed" count

    begin_metric bind_write
    bind_root=$(product_value "$product" BIND_ROOT)
    bind_root=${bind_root:-$BIND_STATE_DIR}
    bind_dir="$bind_root/$sample-$product"
    mkdir -p "$bind_dir"
    bind_runner="$RUN_ID-$sample-$product-bind"
    docker_api create --name "$bind_runner" --label "socktainer.benchmark.run=$RUN_ID" -v "$bind_dir:/bench" "$BASE_IMAGE" \
        /bin/sh -c 'trap "exit 0" TERM INT; while :; do sleep 1; done' >/dev/null
    docker_api start "$bind_runner" >/dev/null
    dd_output=$(docker_api exec "$bind_runner" /bin/sh -c \
        "LC_ALL=C dd if=/dev/zero of=/bench/data.bin bs=1048576 count=$BIND_MIB conv=fsync 2>&1")
    value=$(awk -f "$DD_RESULT_PARSER" <<< "$dd_output") || die "$product: could not parse bind write dd output"
    append_result "$product" "$sample" "$position" warm bind_write "$value" MiB_per_second
    begin_metric bind_cached_read
    docker_api exec "$bind_runner" /bin/sh -c \
        'LC_ALL=C dd if=/bench/data.bin of=/dev/null bs=1048576 >/dev/null 2>&1'
    dd_output=$(docker_api exec "$bind_runner" /bin/sh -c \
        'LC_ALL=C dd if=/bench/data.bin of=/dev/null bs=1048576 2>&1')
    value=$(awk -f "$DD_RESULT_PARSER" <<< "$dd_output") || die "$product: could not parse bind read dd output"
    append_result "$product" "$sample" "$position" bind_cache bind_cached_read "$value" MiB_per_second
    begin_metric post_bind_cache_physical_footprint
    record_process_snapshot "$product" "$sample" post_bind_cache
    append_result "$product" "$sample" "$position" bind_cache post_bind_cache_physical_footprint "$(owned_memory_bytes "$product")" bytes
    begin_metric post_bind_reclaim_physical_footprint
    docker_api rm -f "$bind_runner" "$nginx" >/dev/null
    rm -f "$bind_dir/data.bin"
    rmdir "$bind_dir"
    sleep 5
    record_process_snapshot "$product" "$sample" post_bind_reclaim
    append_result "$product" "$sample" "$position" reclaim post_bind_reclaim_physical_footprint "$(owned_memory_bytes "$product")" bytes

    begin_metric storage
    record_storage_snapshot "$product" "$sample" "$paths"
    append_result "$product" "$sample" "$position" warm storage_allocated "$(storage_bytes "$paths" allocated)" bytes
    append_result "$product" "$sample" "$position" warm storage_logical "$(storage_bytes "$paths" logical)" bytes
    cleanup_host "$host"
    stop_product "$product"
    wait_for_engine_stop "$socket" || die "$product did not stop after the sample"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --help) usage; exit 0 ;;
        --preflight) MODE=preflight; shift ;;
        --dry-run) MODE=dry-run; shift ;;
        --products) [[ $# -ge 2 ]] || die "--products needs a value"; PRODUCTS=$2; shift 2 ;;
        --samples) [[ $# -ge 2 ]] || die "--samples needs a value"; SAMPLES=$2; shift 2 ;;
        --output) [[ $# -ge 2 ]] || die "--output needs a value"; OUTPUT=$2; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done

if [[ -z $OUTPUT ]]; then
    OUTPUT="$PWD/runtime-benchmark-$RUN_ID.json"
fi
RUNS_DIRECTORY=${BENCH_RUNS_DIRECTORY:-"$(dirname "$OUTPUT")/runtime-benchmark-runs"}
RUN_DIRECTORY="$RUNS_DIRECTORY/$RUN_ID"
RESULTS_FILE=$(mktemp -t socktainer-benchmark-results.XXXXXX)
PROCESS_FILE=$(mktemp -t socktainer-benchmark-processes.XXXXXX)
STORAGE_FILE=$(mktemp -t socktainer-benchmark-storage.XXXXXX)
ENGINE_STATE_DIR=$(mktemp -d /tmp/socktainer-benchmark-engines.XXXXXX)
BIND_STATE_DIR=$(mktemp -d "$HOME/.socktainer-benchmark-bind.XXXXXX")

preflight
IFS=',' read -r -a product_list <<< "$PRODUCTS"

if [[ $MODE == preflight ]]; then
    exit 0
fi

if [[ $MODE == dry-run ]]; then
    for product in "${product_list[@]}"; do
        printf '%s:\n  host: %s\n  start: %s\n  start mode: %s\n  stop: %s\n  owned PIDs: %s\n  pid patterns: %s\n  storage paths: %s\n  version: %s\n' \
            "$product" "$(product_value "$product" DOCKER_HOST)" \
            "$(product_value "$product" START_CMD)" "$(product_value "$product" START_MODE)" \
            "$(product_value "$product" STOP_CMD)" "$(product_value "$product" OWNED_PIDS_CMD)" \
            "$(product_value "$product" PID_PATTERNS)" "$(product_value "$product" STORAGE_PATHS)" \
            "$(product_value "$product" VERSION_CMD)"
    done
    for ((sample = 1; sample <= SAMPLES; sample++)); do
        printf 'sample %d:' "$sample"
        while IFS= read -r product; do printf ' %s' "$product"; done < <(rotation_for_sample "$sample")
        printf '\n'
    done
    echo "dry-run: each product runs engine restart, fixture pull, all lifecycle/workload metrics, resource capture, storage capture, and scoped cleanup"
    exit 0
fi

[[ ! -e $OUTPUT ]] || die "output already exists; use a unique --output path: $OUTPUT"
mkdir -p "$RUN_DIRECTORY" "$(dirname "$OUTPUT")"
jq -cn --arg runId "$RUN_ID" --arg startedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{status:"incomplete",runId:$runId,startedAt:$startedAt}' > "$RUN_DIRECTORY/status.json"
for ((sample = 1; sample <= SAMPLES; sample++)); do
    position=0
    while IFS= read -r product; do
        position=$((position + 1))
        benchmark_product "$product" "$sample" "$position"
    done < <(rotation_for_sample "$sample")
done
validate_results
finalize_json
cp "$OUTPUT" "$RUN_DIRECTORY/complete.json.tmp"
mv "$RUN_DIRECTORY/complete.json.tmp" "$RUN_DIRECTORY/complete.json"
jq -cn --arg runId "$RUN_ID" --arg completedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{status:"complete",runId:$runId,completedAt:$completedAt}' > "$RUN_DIRECTORY/status.json.tmp"
mv "$RUN_DIRECTORY/status.json.tmp" "$RUN_DIRECTORY/status.json"
BENCHMARK_COMPLETE=true
echo "benchmark: wrote $OUTPUT"
jq -r '.summary[] | "summary: \(.product) \(.metric) median=\(.median) \(.unit) spread=\(.spread)"' "$OUTPUT"
