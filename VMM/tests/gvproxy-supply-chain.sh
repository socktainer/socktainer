#!/bin/sh
set -eu

vmm_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
lock=${vmm_root}/gvproxy/source.lock

grep -qx 'version=v0.8.9' "${lock}"
grep -qx 'commit=9cfc86f66679ef0feed0f20ba1df558fe2bef5c6' "${lock}"
grep -qx 'license=Apache-2.0' "${lock}"
grep -q 'go mod verify' "${vmm_root}/gvproxy/build.sh"
grep -q 'GOSUMDB=sum.golang.org' "${vmm_root}/gvproxy/build.sh"
