#!/bin/sh

set -eu

guest_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
temporary_directory=$(mktemp -d)
cleanup() {
    rm -rf "${temporary_directory}"
}
trap cleanup EXIT INT TERM

for output in first second; do
    OUTPUT_DIR="${temporary_directory}/${output}" \
        IMAGE_TAG="${IMAGE_TAG:-local/glassdock-guest:dev}" \
        "${guest_root}/scripts/build-vmm-artifacts.sh"
done

for artifact in glassdock-root.ext4 glassdock-vmlinux; do
    cmp "${temporary_directory}/first/${artifact}" \
        "${temporary_directory}/second/${artifact}" || {
        echo "guest artifact is not reproducible: ${artifact}" >&2
        exit 1
    }
done
