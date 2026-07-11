#!/bin/bash
# Crafts minimal OCI image tarballs shaped like real `docker save` output,
# without needing Docker or a running container:
#   baseline.tar   single manifest, complete blobs
#   sparse.tar     multi-platform index shipping only one platform's blobs
#                  (docker save v25+ of a multi-platform image)
#   multi-tag.tar  two tags referencing the same manifest blob
#                  (docker save tag1 tag2)
set -euo pipefail

OUT_DIR="${1:-.}"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT
mkdir -p "${OUT_DIR}"
OUT_DIR=$(cd "${OUT_DIR}" && pwd)
cd "${WORK_DIR}"
mkdir -p layout/blobs/sha256 rootfs

echo "hello from crafted image" > rootfs/hello.txt
tar -cf layer.tar -C rootfs hello.txt
DIFF_ID=$(shasum -a 256 layer.tar | cut -d' ' -f1)
gzip -n -c layer.tar > layer.tar.gz
LAYER_DIGEST=$(shasum -a 256 layer.tar.gz | cut -d' ' -f1)
LAYER_SIZE=$(stat -f%z layer.tar.gz 2>/dev/null || stat -c%s layer.tar.gz)
cp layer.tar.gz "layout/blobs/sha256/${LAYER_DIGEST}"

printf '{"architecture":"arm64","os":"linux","config":{},"rootfs":{"type":"layers","diff_ids":["sha256:%s"]}}' "${DIFF_ID}" > config.json
CONFIG_DIGEST=$(shasum -a 256 config.json | cut -d' ' -f1)
CONFIG_SIZE=$(stat -f%z config.json 2>/dev/null || stat -c%s config.json)
cp config.json "layout/blobs/sha256/${CONFIG_DIGEST}"

printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:%s","size":%s},"layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar+gzip","digest":"sha256:%s","size":%s}]}' \
    "${CONFIG_DIGEST}" "${CONFIG_SIZE}" "${LAYER_DIGEST}" "${LAYER_SIZE}" > manifest.json
MANIFEST_DIGEST=$(shasum -a 256 manifest.json | cut -d' ' -f1)
MANIFEST_SIZE=$(stat -f%z manifest.json 2>/dev/null || stat -c%s manifest.json)
cp manifest.json "layout/blobs/sha256/${MANIFEST_DIGEST}"

echo '{"imageLayoutVersion":"1.0.0"}' > layout/oci-layout

descriptor() {
    local digest="$1" size="$2" arch="$3" ref="$4"
    printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:%s","size":%s,"platform":{"architecture":"%s","os":"linux"},"annotations":{"io.containerd.image.name":"docker.io/library/%s","org.opencontainers.image.ref.name":"%s"}}' \
        "${digest}" "${size}" "${arch}" "${ref}" "${ref}"
}

emit_tarball() {
    local name="$1" manifests="$2"
    printf '{"schemaVersion":2,"manifests":[%s]}' "${manifests}" > layout/index.json
    tar -cf "${OUT_DIR}/${name}" -C layout oci-layout index.json blobs
}

emit_tarball baseline.tar \
    "$(descriptor "${MANIFEST_DIGEST}" "${MANIFEST_SIZE}" arm64 "crafted-baseline:latest")"

MISSING_DIGEST=$(echo "blobs not shipped in the tarball" | shasum -a 256 | cut -d' ' -f1)
emit_tarball sparse.tar \
    "$(descriptor "${MANIFEST_DIGEST}" "${MANIFEST_SIZE}" arm64 "crafted-sparse:latest"),$(descriptor "${MISSING_DIGEST}" 999 amd64 "crafted-sparse:latest")"

emit_tarball multi-tag.tar \
    "$(descriptor "${MANIFEST_DIGEST}" "${MANIFEST_SIZE}" arm64 "crafted-one:latest"),$(descriptor "${MANIFEST_DIGEST}" "${MANIFEST_SIZE}" arm64 "crafted-two:latest")"

echo "crafted in ${OUT_DIR}: baseline.tar sparse.tar multi-tag.tar"
