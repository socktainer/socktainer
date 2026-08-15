#!/bin/bash

set -euo pipefail

configuration="${1:-debug}"
version="${2:-0.0.0-dev}"
build_number="${3:-1}"
signing_identity="${4:--}"
bundle_version="${version#v}"
bundle_version="${bundle_version%%-*}"
if [[ ! "$bundle_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    bundle_version="0.0.0"
fi
if [[ ! "$build_number" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "Error: build number must contain one to three numeric components." >&2
    exit 1
fi
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="$root_dir/.build/$configuration/GlassDock.app"

swift build --package-path "$root_dir" -c "$configuration" --product GlassDockMenu
binary_path="$(swift build --package-path "$root_dir" -c "$configuration" --show-bin-path)/GlassDockMenu"

rm -rf "$output_dir"
mkdir -p "$output_dir/Contents/MacOS" "$output_dir/Contents/Resources"
cp "$root_dir/Apps/GlassDockMenu/Info.plist" "$output_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $bundle_version" "$output_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$output_dir/Contents/Info.plist"
cp "$binary_path" "$output_dir/Contents/MacOS/GlassDockMenu"
bash "$root_dir/scripts/generate-app-icon.sh" "$output_dir/Contents/Resources/AppIcon.icns" >/dev/null
cp "$root_dir/Apps/GlassDockMenu/PrivacyInfo.xcprivacy" "$output_dir/Contents/Resources/PrivacyInfo.xcprivacy"
xattr -cr "$output_dir"

if [[ "$signing_identity" == "-" ]]; then
    codesign --force --sign - "$output_dir"
else
    codesign --force --timestamp --options runtime \
        --entitlements "$root_dir/Apps/GlassDockMenu/GlassDockMenu.entitlements" \
        --sign "$signing_identity" "$output_dir"
fi
codesign --verify --deep --strict "$output_dir"

echo "$output_dir"
