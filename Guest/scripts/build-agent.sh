#!/bin/sh
set -eu

guest_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir=${OUTPUT_DIR:-"${guest_root}/out"}
version=${VERSION:-dev}

mkdir -p "${output_dir}"
cd "${guest_root}"
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build \
    -trimpath \
    -buildvcs=false \
    -ldflags "-s -w -buildid= -X main.version=${version}" \
    -o "${output_dir}/socktainer-guest-agent" \
    ./cmd/socktainer-guest-agent
chmod 0755 "${output_dir}/socktainer-guest-agent"
sha256sum "${output_dir}/socktainer-guest-agent"
