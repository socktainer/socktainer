#!/bin/bash

set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
version=""
build_number=""
signing_identity="${SOCKTAINER_SIGNING_IDENTITY:-}"

usage() {
    echo "Usage: $0 --version VERSION --build BUILD [--identity SHA1_OR_NAME]" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            version="${2:-}"
            shift 2
            ;;
        --build)
            build_number="${2:-}"
            shift 2
            ;;
        --identity)
            signing_identity="${2:-}"
            shift 2
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "Error: version must be a stable numeric version such as 1.0.0." >&2
    exit 1
fi
if [[ ! "$build_number" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "Error: build must contain one to three numeric components." >&2
    exit 1
fi

if [[ -z "$signing_identity" ]]; then
    signing_identity="$(security find-identity -v -p codesigning | awk '/"Developer ID Application:/{print $2}')"
    identity_count="$(printf '%s\n' "$signing_identity" | awk 'NF { count++ } END { print count + 0 }')"
    if [[ "$identity_count" -ne 1 ]]; then
        echo "Error: specify one Developer ID Application identity with --identity." >&2
        exit 1
    fi
fi

app_path="$root_dir/.build/release/GlassDock.app"
distribution_dir="$root_dir/.build/release-distribution"
archive_path="$distribution_dir/GlassDock-$version-macOS-arm64.zip"

bash "$root_dir/scripts/build-menu-app.sh" release "$version" "$build_number" "$signing_identity"
mkdir -p "$distribution_dir"

codesign --verify --deep --strict --verbose=2 "$app_path"
if codesign --display --entitlements :- "$app_path" 2>/dev/null | plutil -extract com.apple.security.get-task-allow raw - 2>/dev/null | grep -qx true; then
    echo "Error: release app contains com.apple.security.get-task-allow." >&2
    exit 1
fi

ditto -c -k --keepParent "$app_path" "$archive_path"
unzip -tq "$archive_path" >/dev/null

if spctl --assess --type execute --verbose=2 "$app_path" >/dev/null 2>&1; then
    echo "Gatekeeper accepted the pre-notarization app."
else
    echo "Gatekeeper did not accept the pre-notarization app. This result is expected before notarization."
fi

echo "Prepared signed archive without submitting it:"
echo "$archive_path"
shasum -a 256 "$archive_path"
