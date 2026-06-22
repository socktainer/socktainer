#!/usr/bin/env bash
# Rejects Foundation's Pipe() in ContainerClient code paths — use StdioPipes instead.
# See AGENTS.md for the ownership contract and the reason this matters.
set -euo pipefail

PATTERN='(=[[:space:]]*|Foundation\.)Pipe\(\)'
EXCLUDE='ClientRegistryService.swift'

if grep -rEn "$PATTERN" Sources/socktainer/ \
        --include="*.swift" \
        --exclude="$EXCLUDE" \
    | grep -q .; then
    echo "ERROR: Pipe() found in a ContainerClient code path."
    echo "       Use StdioPipes (DockerConnectionUtility.swift) instead — see AGENTS.md."
    grep -rEn "$PATTERN" Sources/socktainer/ \
        --include="*.swift" \
        --exclude="$EXCLUDE"
    exit 1
fi
