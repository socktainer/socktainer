#!/bin/sh
set -eu

guest_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=Guest/vmm-artifacts.lock
. "${guest_root}/vmm-artifacts.lock"
output_dir=${OUTPUT_DIR:-"${guest_root}/out"}
tag=${IMAGE_TAG:-local/glassdock-guest:dev}
tools_tag=${ARTIFACT_TOOLS_TAG:-local/glassdock-artifact-tools:dev}
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
container build --arch arm64 --tag "${tools_tag}" "${guest_root}/artifacts" >/dev/null
container create --name "${artifact_container}" --entrypoint /bin/sleep "${tag}" 3600 >/dev/null
container start "${artifact_container}" >/dev/null
container export --output "${temporary_directory}/rootfs.tar" "${artifact_container}"
container stop "${artifact_container}" >/dev/null
container delete "${artifact_container}" >/dev/null

# The single-quoted program runs inside the artifact-tools container.
# shellcheck disable=SC2016
container run --remove --entrypoint /bin/sh \
    --mount "type=bind,source=${temporary_directory},target=/work" \
    "${tools_tag}" -c '
        set -eu
        mkdir /rootfs
        tar -xf /work/rootfs.tar -C /rootfs
        printf "glassdock\n" > /rootfs/etc/hostname
        printf "127.0.0.1 localhost\n127.0.1.1 glassdock\n" > /rootfs/etc/hosts
        : > /rootfs/etc/resolv.conf
        find /rootfs -exec touch -h -d @0 {} +
        (cd /rootfs && find . -mindepth 1 -print | LC_ALL=C sort > /work/rootfs-files)
        tar -C /rootfs --no-recursion -cf /work/rootfs-normalized.tar -T /work/rootfs-files
        rm -rf /rootfs
        mkdir /rootfs
        tar -xf /work/rootfs-normalized.tar -C /rootfs
        truncate -s 256M /work/rootfs.ext4
        E2FSPROGS_FAKE_TIME=1 mke2fs -q -t ext4 -L glassdock-root \
            -U 8b64853e-3fca-4ad2-95a8-3232f2797988 -m 0 \
            -E lazy_itable_init=0,lazy_journal_init=0,hash_seed=8b64853e-3fca-4ad2-95a8-3232f2797988 \
            -d /rootfs /work/rootfs.ext4
        {
            find /rootfs -print | LC_ALL=C sort | while IFS= read -r source; do
                path=${source#/rootfs}
                [ -n "${path}" ] || path=/
                for field in atime ctime mtime crtime; do
                    printf "set_inode_field \"%s\" %s @1\n" "${path}" "${field}"
                done
            done
        } > /work/debugfs.commands
        E2FSPROGS_FAKE_TIME=1 debugfs -w -f /work/debugfs.commands \
            /work/rootfs.ext4 >/dev/null 2>&1
    '

cp "${kernel_source}" "${temporary_directory}/vmlinux"
chmod 0644 "${temporary_directory}/rootfs.ext4" "${temporary_directory}/vmlinux"
mv "${temporary_directory}/rootfs.ext4" "${output_dir}/glassdock-root.ext4"
mv "${temporary_directory}/vmlinux" "${output_dir}/glassdock-vmlinux"
sha256sum "${output_dir}/glassdock-root.ext4" "${output_dir}/glassdock-vmlinux"
