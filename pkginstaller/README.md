# Glass Dock macOS release package

This directory builds a complete Apple Silicon runtime. The package installs
versioned releases under `/opt/glassdock/versions` and selects the active release
through `/opt/glassdock/current`.

From the repository root, build and verify all unsigned local artifacts:

```bash
make release-artifacts-local BUILD_VERSION=0.0.0-dev
```

The package contains:

- the public `glassdock` service controller;
- the private `glassdock` daemon, VMM, `libkrun`, and `gvproxy`;
- the guest kernel and root disk;
- a per-user LaunchAgent definition;
- an uninstaller that preserves workload data by default.

The installer does not start background software or write to a user home. After
installation, the user runs `glassdock enable` to install the LaunchAgent in that
user's `~/Library/LaunchAgents` directory and enable launch-on-login.

## Distribution build

Use Developer ID Application and Developer ID Installer identities, plus a
`notarytool` keychain profile or App Store Connect API key:

```bash
make release-artifacts BUILD_VERSION=1.3.0 \
  CODESIGN_IDENTITY='Developer ID Application: Example (TEAMID)' \
  INSTALLER_SIGNING_IDENTITY='Developer ID Installer: Example (TEAMID)' \
  NOTARYTOOL_PROFILE=glassdock-notary
```

The output directory contains:

- `glassdock-<version>-macos-arm64.pkg`;
- `glassdock-<version>-macos-arm64.tar.gz`;
- `SHA256SUMS`;
- `BUILD-METADATA.txt`.

The complete archive is for advanced use and future package-manager integration.
The notarized package is the supported user installation.

Run `make installer-test` from the repository root to build fixture artifacts and
inspect their payload without installing them.
