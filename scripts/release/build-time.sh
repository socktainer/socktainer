#!/bin/sh

set -eu

epoch=${1:?source date epoch is required}

case "${epoch}" in
    *[!0-9]* | '')
        echo "invalid source date epoch: ${epoch}" >&2
        exit 1
        ;;
esac

if date -u -r "${epoch}" '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
    date -u -r "${epoch}" '+%Y-%m-%dT%H:%M:%SZ'
else
    date -u -d "@${epoch}" '+%Y-%m-%dT%H:%M:%SZ'
fi
