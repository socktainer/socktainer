#!/usr/bin/env bash

set -uo pipefail

debug_tag="[DEBUG-swift-hang-a4f2]"
silence_seconds="${CI_SWIFT_SILENCE_SECONDS:-300}"
poll_seconds="${CI_SWIFT_POLL_SECONDS:-15}"
diagnostics_dir="${CI_SWIFT_DIAGNOSTICS_DIR:-.ci-diagnostics/swift}"

if [ "$#" -eq 0 ]; then
    echo "$debug_tag usage: $0 command [argument ...]" >&2
    exit 64
fi

mkdir -p "$diagnostics_dir"
command_log="$diagnostics_dir/command.log"
: >"$command_log"

descendants() {
    local parent="$1"
    local child

    for child in $(pgrep -P "$parent" 2>/dev/null || true); do
        echo "$child"
        descendants "$child"
    done
}

capture_diagnostics() {
    local command_pid="$1"
    local captured_at
    local pid
    local process_name
    local process_ids

    shift

    captured_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    process_ids="$command_pid $(descendants "$command_pid")"

    {
        echo "$debug_tag capture time: $captured_at"
        echo "$debug_tag command PID: $command_pid"
        echo "$debug_tag command: $*"
        echo "$debug_tag process tree"
        for pid in $process_ids; do
            ps -p "$pid" -o pid=,ppid=,%cpu=,%mem=,rss=,vsz=,etime=,state=,command= 2>/dev/null || true
        done
        echo "$debug_tag virtual memory"
        vm_stat 2>&1 || true
        echo "$debug_tag memory pressure"
        memory_pressure 2>&1 || true
        echo "$debug_tag disk usage"
        df -h 2>&1 || true
    } >"$diagnostics_dir/system.txt"

    for pid in $process_ids; do
        process_name="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
        case "$process_name" in
            *swift-frontend* | *swift-driver* | */swift | *clang* | *ld)
                echo "$debug_tag sampling PID $pid ($process_name)"
                sample "$pid" 5 10 -mayDie -file "$diagnostics_dir/sample-$pid.txt" \
                    >"$diagnostics_dir/sample-$pid.stdout.txt" 2>&1 || true
                ;;
        esac
    done
}

terminate_tree() {
    local command_pid="$1"
    local pid
    local process_ids

    process_ids="$(descendants "$command_pid") $command_pid"
    for pid in $process_ids; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 2
    for pid in $process_ids; do
        kill -KILL "$pid" 2>/dev/null || true
    done
}

echo "$debug_tag starting command: $*"
"$@" > >(tee -a "$command_log") 2>&1 &
command_pid=$!
last_reported=0

while kill -0 "$command_pid" 2>/dev/null; do
    now="$(date +%s)"
    modified="$(stat -f %m "$command_log")"
    silent_for=$((now - modified))

    if [ "$silent_for" -ge "$silence_seconds" ]; then
        echo "$debug_tag no command output for ${silent_for}s; capturing diagnostics"
        capture_diagnostics "$command_pid" "$@"
        terminate_tree "$command_pid"
        wait "$command_pid" 2>/dev/null || true
        echo "$debug_tag diagnostic capture complete: $diagnostics_dir"
        exit 124
    fi

    if [ $((now - last_reported)) -ge 60 ]; then
        echo "$debug_tag command is active; last output was ${silent_for}s ago"
        last_reported="$now"
    fi
    sleep "$poll_seconds"
done

wait "$command_pid"
