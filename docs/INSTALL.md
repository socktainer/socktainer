# Install Glass Dock

Glass Dock requires macOS 26 or later on Apple Silicon. Install the complete
runtime package. A standalone `glassdock` binary cannot start the engine because
it does not contain the VMM, network helper, kernel, or guest root disk.

## Install

1. Download `glassdock-<version>-macos-arm64.pkg` and `SHA256SUMS` from the same
   [GitHub release](https://github.com/naaiyy/glassdock/releases).
2. Verify the download:

   ```bash
   shasum -a 256 -c SHA256SUMS
   ```

3. Open the package, or install it from a terminal:

   ```bash
   sudo installer -pkg glassdock-<version>-macos-arm64.pkg -target /
   ```

The package installs each version under `/opt/glassdock/versions`, selects it
through `/opt/glassdock/current`, and adds the current `bin` directory to the
shell path. It does not start background software or write to a user home.

Open a new terminal after the first installation, then run:

```bash
glassdock enable
glassdock status
docker context use glassdock
docker ps
```

The `enable` command registers a per-user LaunchAgent. Glass Dock then starts when
that user signs in. It creates `$HOME/.glassdock/container.sock` and the
`glassdock` Docker context. Persistent engine state is stored in
`/Users/Shared/.glassdock-<user-id>`. This location is outside the user home that
Glass Dock exports to the engine VM.

Use `glassdock start`, `stop`, or `restart` to control the daemon for the current
user. Run `glassdock version` to inspect the installed build. To run the daemon in
the foreground for troubleshooting, stop the service and run `glassdock run`.

The package uses administrator access only to install versioned program files. The
daemon and VM run as the signed-in user. Glass Dock does not install a root daemon,
system extension, or network extension. macOS privacy controls can deny background
access to protected user folders. Keep bind-mounted project files in locations that
the LaunchAgent can read. Glass Dock does not request broad file access for you.

## Update

Download and install the newer package. The installer adds the new version without
removing engine data and changes the `current` link. It does not change user
processes. Run `glassdock restart` after the install. The installer keeps the
prior installed version for local rollback. Glass Dock does not download or
install updates by itself.

## Roll back

List installed versions:

```bash
glassdock versions
```

Select an installed version and restart the service:

```bash
sudo /opt/glassdock/current/bin/glassdock rollback <version>
```

Rollback changes program files only. Engine data stays in place. Because this is
alpha software, a new release can change the engine data format. Read the release
notes before you roll back. You can also reinstall an older package from its
GitHub release.

## Uninstall

Remove program files and keep user engine data:

```bash
sudo /opt/glassdock/current/bin/glassdock-uninstall
```

Add `--purge-data` to remove the current console user's Glass Dock socket, engine
state, and Docker context. This operation permanently deletes local containers,
images, and volumes:

```bash
sudo /opt/glassdock/current/bin/glassdock-uninstall --purge-data
```

## Source and archive installations

The release also includes a complete `.tar.gz` runtime for package-manager work
and advanced manual installations. It has the same `bin` and `share/glassdock`
layout, but it does not install the launch agent or an uninstaller. The package is
the supported user installation.

For source builds, install Xcode 26, Swift 6.2 or later, Go as specified in
`Guest/go.mod`, Rust, and Apple `container`. Then run:

```bash
make release-artifacts-local BUILD_VERSION=0.0.0-dev
```

This command builds the host daemon, guest image, VMM, unsigned local package,
complete archive, metadata, and checksums. Developer ID credentials are required
only for distributable signed packages.
