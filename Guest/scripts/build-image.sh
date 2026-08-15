#!/bin/sh
set -eu

guest_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
output_dir=${OUTPUT_DIR:-"${guest_root}/out"}
tag=${IMAGE_TAG:-local/glassdock-guest:dev}

OUTPUT_DIR="${output_dir}" "${guest_root}/scripts/build-agent.sh"
cp "${output_dir}/glassdock-guest-agent" "${guest_root}/image/glassdock-guest-agent"
trap 'rm -f "${guest_root}/image/glassdock-guest-agent"' EXIT

command -v container >/dev/null 2>&1 || {
    echo "Apple container is required to build the guest root filesystem" >&2
    exit 1
}
container build --arch arm64 --tag "${tag}" "${guest_root}/image"
OUTPUT_DIR="${output_dir}" IMAGE_TAG="${tag}" "${guest_root}/scripts/build-vmm-artifacts.sh"
