#!/bin/sh
set -eu

guest_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir=${OUTPUT_DIR:-"${guest_root}/out"}
tag=${IMAGE_TAG:-local/socktainer-guest:dev}
archive="${output_dir}/socktainer-guest.oci.tar"
raw_archive="${output_dir}/socktainer-guest.raw.oci.tar"

OUTPUT_DIR="${output_dir}" "${guest_root}/scripts/build-agent.sh"
cp "${output_dir}/socktainer-guest-agent" "${guest_root}/image/socktainer-guest-agent"
normalize_dir=$(mktemp -d)
trap 'rm -f "${guest_root}/image/socktainer-guest-agent" "${raw_archive}"; rm -rf "${normalize_dir}"' EXIT

if command -v container >/dev/null 2>&1; then
    container build --arch arm64 --tag "${tag}" "${guest_root}/image"
    container image save --output "${raw_archive}" "${tag}"
elif command -v docker >/dev/null 2>&1; then
    docker buildx build --platform linux/arm64 --output "type=oci,dest=${raw_archive}" --tag "${tag}" "${guest_root}/image"
else
    echo "container or docker with buildx is required" >&2
    exit 1
fi

# OCI content is reproducible, but exporters use the current time for the outer
# tar metadata. Normalize that metadata so the packaged artifact is also stable.
tar -xf "${raw_archive}" -C "${normalize_dir}"
(
    cd "${normalize_dir}"
    TZ=UTC; export TZ
    find . -type f -exec touch -t 197001010000 {} +
    find . -type f ! -name files.list | LC_ALL=C sort > files.list
    tar -cf "${archive}" --uid 0 --gid 0 --numeric-owner -T files.list
)
sha256sum "${archive}"
