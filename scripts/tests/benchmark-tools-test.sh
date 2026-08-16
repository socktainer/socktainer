#!/bin/sh

set -eu

repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
script="${repository_root}/scripts/benchmark-tools.sh"

output=$(${script} --action install --products dory,orbstack)
printf '%s\n' "${output}" | grep -q '^brew install --cask dory '
printf '%s\n' "${output}" | grep -q '^brew install --cask orbstack '
printf '%s\n' "${output}" | grep -q 'Dry run only'

if ${script} --action uninstall --products unsupported >/dev/null 2>&1; then
    echo "unsupported product was accepted" >&2
    exit 1
fi

echo "benchmark tool lifecycle checks passed"
