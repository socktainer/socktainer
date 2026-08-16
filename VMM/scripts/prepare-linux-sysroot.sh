#!/bin/sh

set -eu

vmm_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
lock_file=${LOCK_FILE:-"${vmm_root}/linux-sysroot.lock"}
output_directory=${OUTPUT_DIR:-"${vmm_root}/build/linux-sysroot"}
download_directory="${output_directory}/.downloads"

mkdir -p "${download_directory}"

while read -r expected_sha256 repository_path; do
    case "${expected_sha256}" in '' | \#*) continue ;; esac
    printf '%s\n' "${expected_sha256}" | grep -Eq '^[0-9a-f]{64}$' || {
        echo "invalid sysroot digest: ${expected_sha256}" >&2
        exit 1
    }
    case "${repository_path}" in
        pool/*.deb) ;;
        *) echo "invalid Debian package path: ${repository_path}" >&2; exit 1 ;;
    esac

    package="${download_directory}/$(basename -- "${repository_path}")"
    if [ ! -f "${package}" ] \
        || ! printf '%s  %s\n' "${expected_sha256}" "${package}" | shasum -a 256 -c - >/dev/null 2>&1; then
        temporary_package="${package}.partial"
        curl --fail --location --silent --show-error \
            "https://deb.debian.org/debian/${repository_path}" \
            --output "${temporary_package}"
        printf '%s  %s\n' "${expected_sha256}" "${temporary_package}" | shasum -a 256 -c -
        mv "${temporary_package}" "${package}"
    fi

    data_member=$(ar t "${package}" | sed -n '/^data\.tar\./{p;q;}')
    [ -n "${data_member}" ] || {
        echo "Debian package has no data archive: ${package}" >&2
        exit 1
    }
    ar p "${package}" "${data_member}" | tar -xf - -C "${output_directory}"
done < "${lock_file}"

touch "${output_directory}/.sysroot_ready"
