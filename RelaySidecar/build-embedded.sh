#!/bin/sh
set -eu

image_ref="socktainer-port-relay:embedded"
relay_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$relay_root/.." && pwd)
archive="$relay_root/artifacts/socktainer-port-relay.tar"
c_source="$repository_root/Sources/CRelayImage/embedded_relay_image.c"
mkdir -p "$relay_root/artifacts"

container build --platform linux/arm64 -t "$image_ref" "$relay_root"
container image save --platform linux/arm64 --output "$archive" "$image_ref"
root_digest=$(tar -xOf "$archive" index.json | jq -er '
  if (.manifests | length) == 1 then .manifests[0].digest else error("unexpected manifest count") end
')
printf 'embedded relay root digest: %s\n' "$root_digest"
gzip -n -9 -f "$archive"
xxd -i -n socktainer_relay_image_archive "$archive.gz" > "$c_source"
perl -pi -e 's/^unsigned char socktainer_relay_image_archive\[\]/static const unsigned char socktainer_relay_image_archive[]/; s/^unsigned int socktainer_relay_image_archive_len/static const unsigned int socktainer_relay_image_archive_len/' "$c_source"
printf '%s\n' '#include "CRelayImage.h"' >> "$c_source"
printf '%s\n' 'const unsigned char *socktainer_relay_image_bytes(void) { return socktainer_relay_image_archive; }' >> "$c_source"
printf '%s\n' 'unsigned int socktainer_relay_image_len(void) { return socktainer_relay_image_archive_len; }' >> "$c_source"
shasum -a 256 "$archive.gz"
