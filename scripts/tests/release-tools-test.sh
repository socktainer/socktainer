#!/bin/sh

set -eu

repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
temporary_directory=$(mktemp -d)
cleanup() {
    rm -rf "${temporary_directory}"
}
trap cleanup EXIT INT TERM

validate="${repository_root}/scripts/release/validate-version.sh"
notes="${repository_root}/scripts/release/release-notes.sh"

"${validate}" 1.2.3
"${validate}" 1.2.3-rc.1
"${validate}" 1.2.3-alpha-beta
if "${validate}" v1.2.3 >/dev/null 2>&1; then
    echo "version validation accepted a leading v" >&2
    exit 1
fi
if "${validate}" '1.2.3;touch /tmp/no' >/dev/null 2>&1; then
    echo "version validation accepted unsafe input" >&2
    exit 1
fi
if "${validate}" 01.2.3 >/dev/null 2>&1; then
    echo "version validation accepted a leading zero" >&2
    exit 1
fi
if "${validate}" 1.2.3-01 >/dev/null 2>&1; then
    echo "version validation accepted a leading prerelease zero" >&2
    exit 1
fi

cat > "${temporary_directory}/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

- Pending.

## [1.2.3]

### Added

- A release path.

## [1.2.2]

- Older work.
EOF

output=$("${notes}" 1.2.3 "${temporary_directory}/CHANGELOG.md")
printf '%s\n' "${output}" | grep -q 'A release path.'
if "${notes}" 9.9.9 "${temporary_directory}/CHANGELOG.md" >/dev/null 2>&1; then
    echo "release notes accepted a missing changelog section" >&2
    exit 1
fi
