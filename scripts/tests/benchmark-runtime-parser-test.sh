#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
readonly REPO_ROOT
readonly PARSER="$REPO_ROOT/scripts/parse-busybox-dd.awk"
readonly FIXTURES="$REPO_ROOT/scripts/tests/fixtures"

assert_parse() {
    local fixture=$1 expected=$2 actual
    actual=$(awk -f "$PARSER" "$FIXTURES/$fixture")
    [[ $actual == "$expected" ]] || {
        echo "$fixture: expected $expected, got $actual" >&2
        return 1
    }
}

assert_parse busybox-dd-seconds.out 2048.000000
assert_parse busybox-dd-short-unit.out 8.000000
assert_parse busybox-dd-with-records.out 8192.000000

if printf '%s\n' 'not dd output' | awk -f "$PARSER" >/dev/null 2>&1; then
    echo "malformed output was accepted" >&2
    exit 1
fi

for product in a b c d; do
    prefix=$(printf '%s' "$product" | tr '[:lower:]' '[:upper:]')
    export "${prefix}_DOCKER_HOST=unix:///tmp/${product}-benchmark-test.sock"
    export "${prefix}_START_CMD=true"
    export "${prefix}_START_MODE=foreground"
    export "${prefix}_RESET_CMD=true"
    export "${prefix}_STORAGE_PATHS=/tmp"
    export "${prefix}_STORAGE_SCOPE=test"
    export "${prefix}_CPU_COUNT=1"
    export "${prefix}_VM_MEMORY_BYTES=1073741824"
    export "${prefix}_VM_ALLOCATED_MEMORY_BYTES=1073741824"
    export "${prefix}_VERSION_CMD=printf '${product}-test\\n'"
    export "${prefix}_CONFIG_CMD=true"
    export "${prefix}_VARIANT=test"
    export "${prefix}_RESET_POLICY=test"
    export "${prefix}_IMAGE_CACHE_POLICY=reset"
done

export A_STOPPED_CMD=true

dry_run=$(bash "$REPO_ROOT/scripts/benchmark-runtime.sh" \
    --dry-run --products a,b,c,d --samples 4 --seed 1 --suites startup)
grep -qx 'sample 1: b d c a' <<< "$dry_run"
grep -qx 'sample 2: a c d b' <<< "$dry_run"
grep -qx 'sample 3: d a b c' <<< "$dry_run"
grep -qx 'sample 4: c b a d' <<< "$dry_run"
grep -q 'stopped check: true' <<< "$dry_run"

if bash "$REPO_ROOT/scripts/benchmark-runtime.sh" \
    --dry-run --products a,b,c,d --samples 3 >/dev/null 2>&1; then
    echo "a non-position-balanced sample count was accepted" >&2
    exit 1
fi

if bash "$REPO_ROOT/scripts/benchmark-runtime.sh" \
    --dry-run --products a,a,b,b --samples 4 >/dev/null 2>&1; then
    echo "duplicate product names were accepted" >&2
    exit 1
fi

A_START_CMD=benchmark-command-that-does-not-exist
export A_START_CMD
if bash "$REPO_ROOT/scripts/benchmark-runtime.sh" \
    --preflight --products a --samples 1 --suites startup >/dev/null 2>&1; then
    echo "an unavailable lifecycle command was accepted" >&2
    exit 1
fi
A_START_CMD=true
export A_START_CMD

A_CONFIG_CMD=false
export A_CONFIG_CMD
if bash "$REPO_ROOT/scripts/benchmark-runtime.sh" \
    --preflight --products a --samples 1 --suites startup >/dev/null 2>&1; then
    echo "a failing configuration capture command was accepted" >&2
    exit 1
fi
A_CONFIG_CMD=true
export A_CONFIG_CMD

python3 -m unittest discover -s "$REPO_ROOT/benchmarks/tests" -v

echo "benchmark parser and design tests: ok"
