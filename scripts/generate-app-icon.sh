#!/bin/bash

set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_svg="$root_dir/Apps/GlassDockMenu/Assets/AppIcon.svg"
output_path="${1:-$root_dir/.build/generated/AppIcon.icns}"

command -v rsvg-convert >/dev/null || {
    echo "Error: rsvg-convert is required. Install librsvg with Homebrew." >&2
    exit 1
}

temporary_dir="$(mktemp -d)"
iconset_dir="$temporary_dir/AppIcon.iconset"
trap 'rm -rf "$temporary_dir"' EXIT
mkdir -p "$iconset_dir" "$(dirname "$output_path")"

render() {
    local pixels="$1"
    local filename="$2"
    rsvg-convert --width "$pixels" --height "$pixels" "$source_svg" >"$iconset_dir/$filename"
}

render 16 icon_16x16.png
render 32 icon_16x16@2x.png
render 32 icon_32x32.png
render 64 icon_32x32@2x.png
render 128 icon_128x128.png
render 256 icon_128x128@2x.png
render 256 icon_256x256.png
render 512 icon_256x256@2x.png
render 512 icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil --convert icns --output "$output_path" "$iconset_dir"
echo "$output_path"
