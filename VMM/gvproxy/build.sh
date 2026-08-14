#!/bin/sh
set -eu

output_argument=${1:?output path is required}
output_directory=$(CDPATH='' cd -- "$(dirname -- "${output_argument}")" && pwd)
output=${output_directory}/$(basename -- "${output_argument}")
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=VMM/gvproxy/source.lock
. "${script_directory}/source.lock"

[ "${commit}" = "9cfc86f66679ef0feed0f20ba1df558fe2bef5c6" ] || {
    echo "unexpected gvproxy commit: ${commit}" >&2
    exit 1
}
[ "$(go env GOVERSION)" = "go1.26.5" ] || {
    echo "gvproxy requires Go 1.26.5" >&2
    exit 1
}

temporary_directory=$(mktemp -d)
trap 'rm -rf "${temporary_directory}"' EXIT INT TERM
archive="${temporary_directory}/source.tar.gz"
source_directory="${temporary_directory}/source"
mkdir -p "${source_directory}"
curl --fail --location --silent --show-error \
    "https://github.com/containers/gvisor-tap-vsock/archive/${commit}.tar.gz" \
    --output "${archive}"
printf '%s  %s\n' "${archive_sha256}" "${archive}" | shasum -a 256 -c -
tar -xzf "${archive}" --strip-components=1 -C "${source_directory}"
printf '%s  %s\n' "${go_mod_sha256}" "${source_directory}/go.mod" | shasum -a 256 -c -
printf '%s  %s\n' "${go_sum_sha256}" "${source_directory}/go.sum" | shasum -a 256 -c -

(
    cd "${source_directory}"
    env GOTOOLCHAIN=local GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org \
        go mod verify
    env CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 GOTOOLCHAIN=local \
        GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org \
        go test ./cmd/gvproxy ./pkg/...
    env CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 GOTOOLCHAIN=local \
        GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org \
        go build -trimpath -buildvcs=false -ldflags='-s -w -buildid=' \
        -o "${output}.tmp" ./cmd/gvproxy
)
chmod 0755 "${output}.tmp"
mv "${output}.tmp" "${output}"
