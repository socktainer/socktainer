#!/bin/sh
set -eu

helper=$1
temporary_directory=$(mktemp -d)
trap 'rm -rf "${temporary_directory}"' EXIT

expect_status() {
    expected=$1
    shift
    set +e
    "$@" >"${temporary_directory}/stdout" 2>"${temporary_directory}/stderr"
    actual=$?
    set -e
    if [ "${actual}" -ne "${expected}" ]; then
        printf 'expected status %s, got %s: %s\n' "${expected}" "${actual}" "$*" >&2
        cat "${temporary_directory}/stderr" >&2
        exit 1
    fi
}

expect_status 2 "${helper}" --help
grep -q 'usage:' "${temporary_directory}/stderr" || {
    echo 'helper did not explain the invalid command line' >&2
    exit 1
}
expect_status 2 "${helper}" --memory-mib 95
expect_status 2 "${helper}" --cpus 0
expect_status 2 "${helper}" --proxy-socket /proxy
grep -q 'unrecognized option' "${temporary_directory}/stderr" || {
    echo 'removed proxy socket was not rejected' >&2
    exit 1
}
expect_status 2 "${helper}" \
    --kernel relative \
    --root-disk /root \
    --data-disk /data \
    --bind-source /bind \
    --excluded-bind-source /bind/state \
    --control-socket /control \
    --console-log /console
