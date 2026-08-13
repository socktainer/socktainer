#!/usr/bin/env bash

set -euo pipefail

readonly DEFAULT_BASE_IMAGE='docker.io/library/alpine@sha256:2c9d26f410d032d5b1525aa8a873e238b05b90c4ae8618743d4311f0cc827e37'
readonly DEFAULT_NGINX_IMAGE='docker.io/library/nginx@sha256:5616878291a2eed594aee8db4dade5878cf7edcb475e59193904b198d9b830de'
BASE_IMAGE=${BENCH_BASE_IMAGE:-$DEFAULT_BASE_IMAGE}
NGINX_IMAGE=${BENCH_NGINX_IMAGE:-$DEFAULT_NGINX_IMAGE}
PRODUCTS=${BENCH_PRODUCTS:-socktainer}
SAMPLES=${BENCH_SAMPLES:-9}
AB_REQUESTS=${BENCH_AB_REQUESTS:-10000}
AB_CONCURRENCY=${BENCH_AB_CONCURRENCY:-32}
BIND_MIB=${BENCH_BIND_MIB:-512}
OUTPUT=${BENCH_OUTPUT:-runtime-benchmark.json}
MODE=run
RUN_ID="socktainer-benchmark-$(date -u +%Y%m%dT%H%M%SZ)-$$"
RESULTS_FILE=$(mktemp -t socktainer-benchmark-results.XXXXXX)
PROCESS_FILE=$(mktemp -t socktainer-benchmark-processes.XXXXXX)
ENGINE_STATE_DIR=$(mktemp -d /tmp/socktainer-benchmark-engines.XXXXXX)
BIND_STATE_DIR=$(mktemp -d "$HOME/.socktainer-benchmark-bind.XXXXXX")
CURRENT_HOST=
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
readonly DD_RESULT_PARSER="$REPO_ROOT/scripts/parse-busybox-dd.awk"

usage() {
    cat <<'EOF'
Usage: scripts/benchmark-runtime.sh [options]

Options:
  --preflight          Validate tools and product configuration only.
  --dry-run            Print the nine-sample Latin rotation and commands.
  --products LIST      Comma-separated product names (default: socktainer).
  --samples N          Sample count (default: 9).
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
  NAME_VERSION_CMD     Required command that prints the product version.
  NAME_RUNTIME_CMD     Optional command that prints runtime component versions.

Socktainer defaults to the repository release binary, pinned guest artifact,
standard Docker socket, foreground ownership, and its engine storage paths.

Example:
  SOCKTAINER_DOCKER_HOST=unix:///tmp/socktainer.sock \
  SOCKTAINER_START_CMD='/path/to/socktainer --no-check-compatibility --no-docker-context' \
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
        START_CMD) printf 'env SOCKTAINER_HOST_HOME_DIRECTORY=%q SOCKTAINER_ENGINE_STATE_DIRECTORY=%q SOCKTAINER_GUEST_IMAGE=%q %q --no-check-compatibility --no-docker-context' \
            "$ENGINE_STATE_DIR/socktainer-home" "$ENGINE_STATE_DIR/socktainer-state" \
            "$REPO_ROOT/Guest/out/socktainer-guest.oci.tar" "$REPO_ROOT/.build/release/socktainer" ;;
        RESET_CMD) printf 'rm -rf %q %q && mkdir -p %q %q' \
            "$ENGINE_STATE_DIR/socktainer-home" "$ENGINE_STATE_DIR/socktainer-state" \
            "$ENGINE_STATE_DIR/socktainer-home" "$ENGINE_STATE_DIR/socktainer-state" ;;
        START_MODE) printf 'foreground' ;;
        VERSION_CMD) printf '%q --version' "$REPO_ROOT/.build/release/socktainer" ;;
        RUNTIME_CMD) printf "printf 'Docker API v1.51; containerd 2.1.5; runc 1.3.4-r1'" ;;
        HELPER_PATTERNS) printf 'com.apple.Virtualization.VirtualMachine' ;;
        STORAGE_PATHS) printf '%s:%s:%s' "$REPO_ROOT/.build/release/socktainer" \
            "$REPO_ROOT/Guest/out/socktainer-guest.oci.tar" \
            "$ENGINE_STATE_DIR/socktainer-state" ;;
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
    local product host
    IFS=',' read -r -a product_list <<< "$PRODUCTS"
    for product in "${product_list[@]}"; do
        host=$(product_value "$product" DOCKER_HOST)
        cleanup_host "$host"
        stop_product "$product" || true
    done
    rm -f "$RESULTS_FILE" "$PROCESS_FILE"
    rm -rf "$ENGINE_STATE_DIR"
    rm -rf "$BIND_STATE_DIR"
}
trap cleanup EXIT
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

engine_ready_ms() {
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
    local product=$1 sample=$2 position=$3 metric=$4 value=$5 unit=$6
    jq -cn \
        --arg product "$product" --argjson sample "$sample" \
        --argjson position "$position" --arg metric "$metric" \
        --argjson value "$value" --arg unit "$unit" \
        '{product:$product,sample:$sample,position:$position,metric:$metric,value:$value,unit:$unit}' \
        >> "$RESULTS_FILE"
    printf '  %-26s %12s %s\n' "$metric" "$value" "$unit"
}

finalize_json() {
    local tmp_output product product_info version version_cmd runtime runtime_cmd source_dirty harness_sha guest_sha binary_sha source_diff_sha
    tmp_output="$OUTPUT.tmp.$$"
    source_dirty=false
    git diff --quiet --ignore-submodules HEAD -- 2>/dev/null || source_dirty=true
    git diff --cached --quiet --ignore-submodules HEAD -- 2>/dev/null || source_dirty=true
    [[ -z $(git ls-files --others --exclude-standard 2>/dev/null) ]] || source_dirty=true
    harness_sha=$(shasum -a 256 "$REPO_ROOT/scripts/benchmark-runtime.sh" | awk '{print $1}')
    guest_sha=$(shasum -a 256 "$REPO_ROOT/Guest/out/socktainer-guest.oci.tar" 2>/dev/null | awk '{print $1}')
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
            '$existing + [{name:$name,version:$version,runtime:$runtime,
              dockerHost:$host,startMode:$startMode,startCommand:$startCommand,
              stopCommand:$stopCommand,resetCommand:$resetCommand,ownedPIDsCommand:$ownedPIDsCommand,
              pidPatterns:$pidPatterns,versionCommand:$versionCommand,
              runtimeCommand:$runtimeCommand,storagePaths:$storagePaths}]')
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
        --argjson products "$product_info" --slurpfile process_samples "$PROCESS_FILE" \
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
          products:$products,processSamples:$process_samples,
          configuration:{baseImage:$base_image,nginxImage:$nginx_image,
            samples:$requested_samples,abRequests:$ab_requests,
            abConcurrency:$ab_concurrency,bindMiB:$bind_mib,
            timingBoundaries:{lifecycle:"Docker CLI process wall time",
              nginxReady:"before docker create through first successful HTTP response",
              bindIO:"BusyBox dd bytes divided by dd-reported in-container elapsed time; write includes conv=fsync; cached read follows one unmeasured warm read"}},
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
    local expected_metrics=21 expected_rows
    expected_rows=$((SAMPLES * ${#product_list[@]} * expected_metrics))
    jq -es --argjson expected "$expected_rows" '
        length == $expected
        and (map([.product,.sample,.metric] | join("\u0000")) | unique | length) == $expected
        and all(.[]; (.value | type) == "number")
    ' "$RESULTS_FILE" | grep -qx true \
        || die "result matrix is incomplete, duplicated, or non-numeric"
    jq -es --argjson expected "$((SAMPLES * ${#product_list[@]} * 3))" \
        'length == $expected and all(.[]; (.processes | type) == "array")' \
        "$PROCESS_FILE" | grep -qx true || die "process snapshot matrix is incomplete"
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
    pids=$(owned_pids "$product")
    [[ -n $pids ]] || { echo 0; return; }
    footprint -f bytes $pids 2>/dev/null \
        | awk '/^[[:space:]]*phys_footprint:/ {sum += $2} END {print sum + 0}'
}

record_process_snapshot() {
    local product=$1 sample=$2 phase=$3 pids
    pids=$(owned_pids "$product")
    ps -axo pid=,ppid=,command= | awk -v selected="$pids" '
        BEGIN { count=split(selected, values, " "); for (i=1; i<=count; i++) keep[values[i]]=1 }
        keep[$1] { print }
    ' | jq -Rsc --arg product "$product" --argjson sample "$sample" --arg phase "$phase" '
        split("\n") | map(select(length > 0) | capture("^\\s*(?<pid>[0-9]+)\\s+(?<ppid>[0-9]+)\\s+(?<command>.*)$") |
          {pid:(.pid|tonumber),ppid:(.ppid|tonumber),command:.command}) as $processes |
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

preflight_product() {
    local product=$1 host start_cmd start_mode stop_cmd reset_cmd patterns pids_cmd paths version_cmd socket
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
    eval "$version_cmd" >/dev/null 2>&1 || die "${product}: NAME_VERSION_CMD failed"
    if [[ $product == socktainer && -z ${SOCKTAINER_START_CMD:-} ]]; then
        [[ -x $REPO_ROOT/.build/release/socktainer ]] || die "socktainer: run 'make release' first or set SOCKTAINER_START_CMD"
        [[ -s $REPO_ROOT/Guest/out/socktainer-guest.oci.tar ]] || die "socktainer: guest artifact is missing; build it or set SOCKTAINER_START_CMD"
    fi
    socket=${host#unix://}
    printf 'preflight: %-12s host=%s socket=%s\n' "$product" "$host" "$socket"
}

preflight() {
    local tool product
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
        preflight_product "$product"
    done
    echo "preflight: ok"
}

rotation_for_sample() {
    local sample=$1 count=${#product_list[@]} offset index
    offset=$(((sample - 1) % count))
    for ((index = 0; index < count; index++)); do
        printf '%s\n' "${product_list[$(((offset + index) % count))]}"
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
    local name runner nginx port ab_output failed rps bind_dir bind_runner dd_output
    host=$(product_value "$product" DOCKER_HOST)
    paths=$(product_value "$product" STORAGE_PATHS)
    socket=${host#unix://}
    CURRENT_HOST=$host
    cleanup_host "$host"
    printf '\nsample %d position %d: %s\n' "$sample" "$position" "$product"

    stop_product "$product" force
    wait_for_engine_stop "$socket" || die "$product stop command left the Docker API available"
    eval "$(product_value "$product" RESET_CMD)"
    start_ns=$(now_ns)
    launch_product "$product"
    if ! value=$(engine_ready_ms "$socket" "$start_ns"); then
        [[ -f $ENGINE_STATE_DIR/$product.log ]] && tail -50 "$ENGINE_STATE_DIR/$product.log" >&2
        die "$product did not answer /_ping"
    fi
    append_result "$product" "$sample" "$position" engine_ready "$value" ms

    docker_api pull "$BASE_IMAGE" >/dev/null
    [[ $NGINX_IMAGE == "$BASE_IMAGE" ]] || docker_api pull "$NGINX_IMAGE" >/dev/null

    value=$(docker_elapsed_ms "$host" run --rm --label "socktainer.benchmark.run=$RUN_ID" "$BASE_IMAGE" /bin/true)
    append_result "$product" "$sample" "$position" capability_ready "$value" ms

    value=$(curl --silent --output /dev/null --write-out '%{time_total}' --unix-socket "$socket" http://localhost/_ping)
    value=$(awk -v seconds="$value" 'BEGIN {printf "%.6f", seconds*1000}')
    append_result "$product" "$sample" "$position" api_ping "$value" ms
    record_process_snapshot "$product" "$sample" idle
    append_result "$product" "$sample" "$position" idle_engine_physical_footprint "$(owned_memory_bytes "$product")" bytes

    name="$RUN_ID-$sample-$product-create"
    value=$(docker_elapsed_ms "$host" create --name "$name" --label "socktainer.benchmark.run=$RUN_ID" "$BASE_IMAGE" /bin/true)
    append_result "$product" "$sample" "$position" container_create "$value" ms
    docker_api rm "$name" >/dev/null

    name="$RUN_ID-$sample-$product-start"
    docker_api create --name "$name" --label "socktainer.benchmark.run=$RUN_ID" "$BASE_IMAGE" /bin/true >/dev/null
    value=$(docker_elapsed_ms "$host" start "$name")
    append_result "$product" "$sample" "$position" container_start "$value" ms
    docker_api wait "$name" >/dev/null
    docker_api rm "$name" >/dev/null

    name="$RUN_ID-$sample-$product-wait"
    docker_api create --name "$name" --label "socktainer.benchmark.run=$RUN_ID" "$BASE_IMAGE" /bin/true >/dev/null
    docker_api start "$name" >/dev/null
    while [[ $(docker_api inspect --format '{{.State.Running}}' "$name") == true ]]; do sleep 0.005; done
    value=$(docker_elapsed_ms "$host" wait "$name")
    append_result "$product" "$sample" "$position" completed_wait_lookup "$value" ms
    docker_api rm "$name" >/dev/null

    name="$RUN_ID-$sample-$product-live-wait"
    docker_api create --name "$name" --label "socktainer.benchmark.run=$RUN_ID" \
        "$BASE_IMAGE" /bin/sh -c 'sleep 0.2' >/dev/null
    docker_api start "$name" >/dev/null
    value=$(docker_elapsed_ms "$host" wait "$name")
    append_result "$product" "$sample" "$position" live_wait_to_exit "$value" ms
    docker_api rm "$name" >/dev/null

    name="$RUN_ID-$sample-$product-remove"
    docker_api create --name "$name" --label "socktainer.benchmark.run=$RUN_ID" "$BASE_IMAGE" /bin/true >/dev/null
    value=$(docker_elapsed_ms "$host" rm "$name")
    append_result "$product" "$sample" "$position" container_remove "$value" ms

    value=$(docker_elapsed_ms "$host" run --rm --label "socktainer.benchmark.run=$RUN_ID" "$BASE_IMAGE" /bin/true)
    append_result "$product" "$sample" "$position" run_remove_true "$value" ms

    runner="$RUN_ID-$sample-$product-runner"
    docker_api create --name "$runner" --label "socktainer.benchmark.run=$RUN_ID" "$BASE_IMAGE" \
        /bin/sh -c 'trap "exit 0" TERM INT; while :; do sleep 1; done' >/dev/null
    docker_api start "$runner" >/dev/null
    value=$(docker_elapsed_ms "$host" exec "$runner" /bin/true)
    append_result "$product" "$sample" "$position" exec_true "$value" ms
    value=$(docker_elapsed_ms "$host" exec "$runner" /bin/sh -c 'head -c 1073741824 /dev/zero | sha256sum >/dev/null')
    value=$(awk -v milliseconds="$value" 'BEGIN {printf "%.6f", milliseconds/1000}')
    append_result "$product" "$sample" "$position" sha256_1gib "$value" seconds

    for index in 1 2 3; do
        docker_api create --name "$runner-$index" --label "socktainer.benchmark.run=$RUN_ID" "$BASE_IMAGE" \
            /bin/sh -c 'trap "exit 0" TERM INT; while :; do sleep 1; done' >/dev/null
        docker_api start "$runner-$index" >/dev/null
    done
    sleep 1
    record_process_snapshot "$product" "$sample" four_containers
    append_result "$product" "$sample" "$position" four_idle_containers_physical_footprint "$(owned_memory_bytes "$product")" bytes

    nginx="$RUN_ID-$sample-$product-nginx"
    readiness=$(nginx_ready_ms "$host" "$nginx" "$NGINX_IMAGE" "socktainer.benchmark.run=$RUN_ID")
    value=${readiness%% *}
    port=${readiness##* }
    append_result "$product" "$sample" "$position" nginx_ready "$value" ms
    ab_output=$(ab -k -n "$AB_REQUESTS" -c "$AB_CONCURRENCY" "http://127.0.0.1:$port/")
    failed=$(awk '/Failed requests:/ {print $3}' <<< "$ab_output")
    complete=$(awk '/Complete requests:/ {print $3}' <<< "$ab_output")
    non_2xx=$(awk '/Non-2xx responses:/ {print $3}' <<< "$ab_output")
    [[ $complete == "$AB_REQUESTS" && $failed == 0 && ${non_2xx:-0} == 0 ]] \
        || die "$product: ab did not complete cleanly (complete=$complete failed=$failed non2xx=${non_2xx:-0})"
    rps=$(awk '/Requests per second:/ {print $4}' <<< "$ab_output")
    append_result "$product" "$sample" "$position" nginx_requests_per_second "$rps" requests_per_second
    append_result "$product" "$sample" "$position" nginx_failed_requests "$failed" count

    bind_dir="$BIND_STATE_DIR/$sample-$product"
    mkdir -p "$bind_dir"
    bind_runner="$RUN_ID-$sample-$product-bind"
    docker_api create --name "$bind_runner" --label "socktainer.benchmark.run=$RUN_ID" -v "$bind_dir:/bench" "$BASE_IMAGE" \
        /bin/sh -c 'trap "exit 0" TERM INT; while :; do sleep 1; done' >/dev/null
    docker_api start "$bind_runner" >/dev/null
    dd_output=$(docker_api exec "$bind_runner" /bin/sh -c \
        "LC_ALL=C dd if=/dev/zero of=/bench/data.bin bs=1048576 count=$BIND_MIB conv=fsync 2>&1")
    value=$(awk -f "$DD_RESULT_PARSER" <<< "$dd_output") || die "$product: could not parse bind write dd output"
    append_result "$product" "$sample" "$position" bind_write "$value" MiB_per_second
    docker_api exec "$bind_runner" /bin/sh -c \
        'LC_ALL=C dd if=/bench/data.bin of=/dev/null bs=1048576 >/dev/null 2>&1'
    dd_output=$(docker_api exec "$bind_runner" /bin/sh -c \
        'LC_ALL=C dd if=/bench/data.bin of=/dev/null bs=1048576 2>&1')
    value=$(awk -f "$DD_RESULT_PARSER" <<< "$dd_output") || die "$product: could not parse bind read dd output"
    append_result "$product" "$sample" "$position" bind_cached_read "$value" MiB_per_second
    record_process_snapshot "$product" "$sample" post_bind_cache
    append_result "$product" "$sample" "$position" post_bind_cache_physical_footprint "$(owned_memory_bytes "$product")" bytes
    rm -f "$bind_dir/data.bin"
    rmdir "$bind_dir"

    append_result "$product" "$sample" "$position" storage_allocated "$(storage_bytes "$paths" allocated)" bytes
    append_result "$product" "$sample" "$position" storage_logical "$(storage_bytes "$paths" logical)" bytes
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

rm -f "$OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
for ((sample = 1; sample <= SAMPLES; sample++)); do
    position=0
    while IFS= read -r product; do
        position=$((position + 1))
        benchmark_product "$product" "$sample" "$position"
    done < <(rotation_for_sample "$sample")
done
validate_results
finalize_json
echo "benchmark: wrote $OUTPUT"
jq -r '.summary[] | "summary: \(.product) \(.metric) median=\(.median) \(.unit) spread=\(.spread)"' "$OUTPUT"
