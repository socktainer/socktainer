#!/bin/sh
set -eu

guest_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=Guest/vmm-artifacts.lock
. "${guest_root}/vmm-artifacts.lock"
output_dir=${OUTPUT_DIR:-"${guest_root}/out"}
tag=${IMAGE_TAG:-local/glassdock-guest:dev}
kernel_source=${KERNEL_PATH:-"${HOME}/Library/Application Support/com.apple.container/kernels/default.kernel-arm64"}
artifact_container="glassdock-artifact-$$"
temporary_directory=$(mktemp -d)

cleanup() {
    container stop "${artifact_container}" >/dev/null 2>&1 || true
    container delete "${artifact_container}" >/dev/null 2>&1 || true
    rm -rf "${temporary_directory}"
}
trap cleanup EXIT INT TERM

[ -r "${kernel_source}" ] || {
    echo "guest kernel is not readable: ${kernel_source}" >&2
    exit 1
}
kernel_sha256=$(sha256sum "${kernel_source}" | awk '{print $1}')
[ "${kernel_sha256}" = "${GLASSDOCK_KERNEL_SHA256}" ] || {
    echo "guest kernel digest mismatch: got ${kernel_sha256}, want ${GLASSDOCK_KERNEL_SHA256}" >&2
    exit 1
}

mkdir -p "${output_dir}"
container create --name "${artifact_container}" --entrypoint /bin/sleep "${tag}" 3600 >/dev/null
container start "${artifact_container}" >/dev/null
container export --output "${temporary_directory}/rootfs.tar" "${artifact_container}"
container stop "${artifact_container}" >/dev/null
container delete "${artifact_container}" >/dev/null

container run --remove --entrypoint /bin/sh \
    --mount "type=bind,source=${temporary_directory},target=/work" \
    "${tag}" -c '
        set -eu
        mkdir /rootfs
        tar -xf /work/rootfs.tar -C /rootfs
        find /rootfs -exec touch -h -d @0 {} +
        truncate -s 256M /work/rootfs.ext4
        E2FSPROGS_FAKE_TIME=0 mke2fs -q -t ext4 -L glassdock-root \
            -U 8b64853e-3fca-4ad2-95a8-3232f2797988 -m 0 \
            -E lazy_itable_init=0,lazy_journal_init=0,hash_seed=8b64853e-3fca-4ad2-95a8-3232f2797988 \
            -d /rootfs /work/rootfs.ext4
    '

cp "${kernel_source}" "${temporary_directory}/vmlinux"
chmod 0644 "${temporary_directory}/rootfs.ext4" "${temporary_directory}/vmlinux"
mv "${temporary_directory}/rootfs.ext4" "${output_dir}/glassdock-root.ext4"
mv "${temporary_directory}/vmlinux" "${output_dir}/glassdock-vmlinux"
sha256sum "${output_dir}/glassdock-root.ext4" "${output_dir}/glassdock-vmlinux"
