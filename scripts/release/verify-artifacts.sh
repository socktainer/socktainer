#!/bin/sh

set -eu

require_signature=0
require_notarization=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --require-signature) require_signature=1 ;;
        --require-notarization) require_notarization=1 ;;
        --) shift; break ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) break ;;
    esac
    shift
done

package=${1:?package path is required}
archive=${2:?archive path is required}
checksums=${3:?checksum path is required}

for artifact in "${package}" "${archive}" "${checksums}"; do
    [ -s "${artifact}" ] || {
        echo "missing or empty release artifact: ${artifact}" >&2
        exit 1
    }
done

case "$(uname -m)" in
    arm64) ;;
    *) echo "release artifacts must be verified on arm64" >&2; exit 1 ;;
esac

checksum_directory=$(CDPATH='' cd -- "$(dirname -- "${checksums}")" && pwd)
(
    cd "${checksum_directory}"
    shasum -a 256 -c "$(basename -- "${checksums}")"
)

expanded=$(mktemp -d)
archive_root=$(mktemp -d)
cleanup() {
    rm -rf "${expanded}" "${archive_root}"
}
trap cleanup EXIT INT TERM

pkgutil --expand-full "${package}" "${expanded}/package"
tar -xzf "${archive}" -C "${archive_root}"

for root in "${expanded}/package" "${archive_root}"; do
    binary=$(find "${root}" -type f -path '*/libexec/glassdock/glassdock' -print -quit)
    [ -n "${binary}" ] || {
        echo "glassdock is missing from ${root}" >&2
        exit 1
    }
    [ "$(file -b "${binary}")" != "" ]
done

for relative in \
    bin/glassdock \
    bin/glassdock-uninstall \
    libexec/glassdock/glassdock \
    libexec/glassdock/glassdock-vmm \
    libexec/glassdock/libkrun.1.dylib \
    libexec/glassdock/gvproxy \
    share/glassdock/glassdock-vmlinux \
    share/glassdock/glassdock-root.ext4; do
    package_candidate=$(find "${expanded}/package" -type f -path "*/${relative}" -print -quit)
    archive_candidate=$(find "${archive_root}" -type f -path "*/${relative}" -print -quit)
    [ -n "${package_candidate}" ] || {
        echo "package is missing ${relative}" >&2
        exit 1
    }
    [ -n "${archive_candidate}" ] || {
        echo "archive is missing ${relative}" >&2
        exit 1
    }
    cmp "${package_candidate}" "${archive_candidate}" || {
        echo "package and archive differ at ${relative}" >&2
        exit 1
    }
done

for name in glassdock glassdock-vmm libkrun.1.dylib gvproxy; do
    package_binary=$(find "${expanded}/package" -type f \
        -path "*/libexec/glassdock/${name}" -print -quit)
    description=$(file -b "${package_binary}")
    printf '%s\n' "${description}" | grep -q arm64 || {
        echo "package code is not arm64: ${name}: ${description}" >&2
        exit 1
    }
    if printf '%s\n' "${description}" | grep -q x86_64; then
        echo "package code is not arm64-only: ${name}: ${description}" >&2
        exit 1
    fi
done

if [ "${require_signature}" -eq 1 ]; then
    pkgutil --check-signature "${package}"
    for name in glassdock glassdock-vmm libkrun.1.dylib gvproxy; do
        candidate=$(find "${expanded}/package" -type f -path "*/libexec/glassdock/${name}" -print -quit)
        codesign --verify --strict --verbose=2 "${candidate}"
    done
fi

if [ "${require_notarization}" -eq 1 ]; then
    xcrun stapler validate "${package}"
    spctl --assess --type install --verbose=2 "${package}"
fi
