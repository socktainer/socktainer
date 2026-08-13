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

echo "benchmark dd parser tests: ok"
