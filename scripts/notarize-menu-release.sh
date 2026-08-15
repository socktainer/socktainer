#!/bin/bash

set -euo pipefail

archive_path=""
app_path=""
keychain_profile=""
approval=""

usage() {
    echo "Usage: $0 --archive ZIP --app APP --keychain-profile PROFILE --approval FINAL-APPROVAL" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --archive)
            archive_path="${2:-}"
            shift 2
            ;;
        --app)
            app_path="${2:-}"
            shift 2
            ;;
        --keychain-profile)
            keychain_profile="${2:-}"
            shift 2
            ;;
        --approval)
            approval="${2:-}"
            shift 2
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

if [[ "$approval" != "FINAL-APPROVAL" || "${SOCKTAINER_RELEASE_APPROVED:-}" != "YES" ]]; then
    echo "Error: notarization needs separate final approval." >&2
    echo "After approval, set SOCKTAINER_RELEASE_APPROVED=YES and pass --approval FINAL-APPROVAL." >&2
    exit 1
fi
if [[ ! -f "$archive_path" || ! -d "$app_path" || -z "$keychain_profile" ]]; then
    usage
    exit 2
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
xcrun notarytool submit "$archive_path" --keychain-profile "$keychain_profile" --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"

notarized_archive="${archive_path%.zip}-notarized.zip"
ditto -c -k --keepParent "$app_path" "$notarized_archive"
echo "Prepared notarized archive:"
echo "$notarized_archive"
shasum -a 256 "$notarized_archive"
