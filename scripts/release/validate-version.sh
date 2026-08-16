#!/bin/sh

set -eu

version=${1:-}

if ! printf '%s\n' "${version}" \
    | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'; then
    echo "invalid release version: ${version:-<empty>}" >&2
    echo "expected SemVer without a leading v, for example 1.2.3 or 1.2.3-rc.1" >&2
    exit 1
fi

case "${version}" in
    *-*)
        prerelease=${version#*-}
        old_ifs=${IFS}
        IFS=.
        for identifier in ${prerelease}; do
            case "${identifier}" in
                0 | *[!0-9]*) ;;
                0*)
                    echo "invalid numeric prerelease identifier: ${identifier}" >&2
                    exit 1
                    ;;
            esac
        done
        IFS=${old_ifs}
        ;;
esac
