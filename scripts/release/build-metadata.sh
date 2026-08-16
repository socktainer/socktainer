#!/bin/sh

set -eu

version=${1:?version is required}
commit=${2:?commit is required}
output=${3:?output path is required}
shift 3

"$(dirname "$0")/validate-version.sh" "${version}"

{
    printf 'version=%s\n' "${version}"
    printf 'commit=%s\n' "${commit}"
    printf 'source_date_epoch=%s\n' "${SOURCE_DATE_EPOCH:-unknown}"
    printf 'architecture=%s\n' "$(uname -m)"
    printf 'macos=%s\n' "$(sw_vers -productVersion)"
    printf 'xcode=%s\n' "$(xcodebuild -version | tr '\n' ' ')"
    printf 'swift=%s\n' "$(swift --version | head -1)"
    printf 'go=%s\n' "$(go version 2>/dev/null || echo unavailable)"
    printf 'rustc=%s\n' "$(rustc --version 2>/dev/null || echo unavailable)"
    for artifact in "$@"; do
        [ -f "${artifact}" ] || {
            echo "metadata artifact does not exist: ${artifact}" >&2
            exit 1
        }
        printf 'artifact=%s size=%s sha256=%s\n' \
            "$(basename -- "${artifact}")" \
            "$(stat -f %z "${artifact}")" \
            "$(shasum -a 256 "${artifact}" | awk '{print $1}')"
    done
} > "${output}"
