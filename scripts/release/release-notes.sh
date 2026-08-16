#!/bin/sh

set -eu

version=${1:?release version is required}
changelog=${2:-CHANGELOG.md}

"$(dirname "$0")/validate-version.sh" "${version}"

awk -v heading="## [${version}]" '
    $0 == heading { found = 1; next }
    found && /^## \[/ { exit }
    found { print }
    END {
        if (!found) {
            print "missing changelog section: " heading > "/dev/stderr"
            exit 1
        }
    }
' "${changelog}"
