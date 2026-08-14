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
    export "${prefix}_VM_MEMORY_BYTES=1073741824"
    export "${prefix}_VM_ALLOCATED_MEMORY_BYTES=1073741824"
    export "${prefix}_VERSION_CMD=printf '${product}-test\\n'"
done

dry_run=$(bash "$REPO_ROOT/scripts/benchmark-runtime.sh" \
    --dry-run --products a,b,c,d --samples 4)
grep -qx 'sample 1: a b d c' <<< "$dry_run"
grep -qx 'sample 2: b c a d' <<< "$dry_run"
grep -qx 'sample 3: c d b a' <<< "$dry_run"
grep -qx 'sample 4: d a c b' <<< "$dry_run"

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

echo "benchmark parser and design tests: ok"
