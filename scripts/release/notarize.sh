#!/bin/sh

set -eu

artifact=${1:?artifact path is required}

[ -f "${artifact}" ] || {
    echo "notarization artifact does not exist: ${artifact}" >&2
    exit 1
}

if [ -n "${NOTARYTOOL_PROFILE:-}" ]; then
    xcrun notarytool submit "${artifact}" \
        --keychain-profile "${NOTARYTOOL_PROFILE}" \
        --wait
elif [ -n "${APPLE_API_KEY_PATH:-}" ] && [ -n "${APPLE_API_KEY_ID:-}" ] && [ -n "${APPLE_API_ISSUER_ID:-}" ]; then
    xcrun notarytool submit "${artifact}" \
        --key "${APPLE_API_KEY_PATH}" \
        --key-id "${APPLE_API_KEY_ID}" \
        --issuer "${APPLE_API_ISSUER_ID}" \
        --wait
else
    echo "notarization requires NOTARYTOOL_PROFILE or App Store Connect API key variables" >&2
    exit 1
fi

xcrun stapler staple "${artifact}"
xcrun stapler validate "${artifact}"
