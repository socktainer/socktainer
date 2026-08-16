#!/bin/sh

set -eu

installer_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
temporary_directory=$(mktemp -d)
cleanup() {
    rm -rf "${temporary_directory}"
}
trap cleanup EXIT INT TERM

mkdir -p "${temporary_directory}/vmm" "${temporary_directory}/guest"
printf 'int main(void) { return 0; }\n' \
    | /usr/bin/clang -arch arm64 -x c - -o "${temporary_directory}/fixture-binary"
cp "${temporary_directory}/fixture-binary" "${temporary_directory}/glassdock"
cp "${temporary_directory}/fixture-binary" "${temporary_directory}/vmm/glassdock-vmm"
cp "${temporary_directory}/fixture-binary" "${temporary_directory}/vmm/libkrun.1.dylib"
cp "${temporary_directory}/fixture-binary" "${temporary_directory}/vmm/gvproxy"
printf 'kernel fixture\n' > "${temporary_directory}/guest/glassdock-vmlinux"
printf 'root disk fixture\n' > "${temporary_directory}/guest/glassdock-root.ext4"

make -C "${installer_root}" clean
make -C "${installer_root}" \
    BUILD_VERSION=9.8.7 \
    SOURCE_DATE_EPOCH=0 \
    INSTALL_PREFIX=/opt/glassdock-package-test \
    PACKAGE_IDENTIFIER=io.github.glassdock.pkg.test \
    PATHS_D_NAME=glassdock-package-test \
    DAEMON_SOURCE="${temporary_directory}/glassdock" \
    VMM_SOURCE_DIR="${temporary_directory}/vmm" \
    GUEST_SOURCE_DIR="${temporary_directory}/guest" \
    checksums

"${installer_root}/../scripts/release/verify-artifacts.sh" \
    "${installer_root}/out/glassdock-9.8.7-macos-arm64.pkg" \
    "${installer_root}/out/glassdock-9.8.7-macos-arm64.tar.gz" \
    "${installer_root}/out/SHA256SUMS"

cp -X "${installer_root}/out/glassdock-9.8.7-macos-arm64.tar.gz" \
    "${temporary_directory}/first-runtime.tar.gz"
make -C "${installer_root}" \
    BUILD_VERSION=9.8.7 \
    SOURCE_DATE_EPOCH=0 \
    INSTALL_PREFIX=/opt/glassdock-package-test \
    PACKAGE_IDENTIFIER=io.github.glassdock.pkg.test \
    PATHS_D_NAME=glassdock-package-test \
    DAEMON_SOURCE="${temporary_directory}/glassdock" \
    VMM_SOURCE_DIR="${temporary_directory}/vmm" \
    GUEST_SOURCE_DIR="${temporary_directory}/guest" \
    archive
cmp "${temporary_directory}/first-runtime.tar.gz" \
    "${installer_root}/out/glassdock-9.8.7-macos-arm64.tar.gz"

manual_root="${temporary_directory}/manual"
mkdir -p "${manual_root}"
tar -xzf "${installer_root}/out/glassdock-9.8.7-macos-arm64.tar.gz" -C "${manual_root}"
manual_controller=$(find "${manual_root}" -type f -path '*/bin/glassdock' -print -quit)
if "${manual_controller}" uninstall --dry-run >/dev/null 2>&1; then
    echo "an unversioned archive allowed package uninstall" >&2
    exit 1
fi

expanded="${temporary_directory}/expanded"
pkgutil --expand-full "${installer_root}/out/glassdock-9.8.7-macos-arm64.pkg" "${expanded}"
test -x "${expanded}/glassdock.pkg/Payload/opt/glassdock-package-test/versions/9.8.7/libexec/glassdock/glassdock"
grep -q 'glassdock enable' "${expanded}/glassdock.pkg/Scripts/postinstall"
