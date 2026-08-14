# Socktainer macOS Package Installer

Builds a macOS `.pkg` installer that installs Socktainer, its custom VMM,
and its persistent containerd guest artifacts under `/opt/socktainer/`. It also
adds the binary directory to the system PATH.

## Quick Start

```bash
# From project root
make installer

# For signed distribution
make APPLE_APPLICATION_ID="Developer ID Application: Your Name" \
     APPLE_PRODUCT_ID="Developer ID Installer: Your Name" \
     NO_CODESIGN=0 installer-signed
```

## Prerequisites

- Run `make release guest-image vmm` first only when you invoke the `pkginstaller`
  subdirectory directly. The root `make installer` target does this automatically.
- Xcode Command Line Tools installed
- Developer certificates (for signed builds only)

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `BUILD_VERSION` | `0.0.0-dev` | Version for installer |
| `NO_CODESIGN` | `1` | Set to `0` to enable signing |
| `INSTALL_PREFIX` | `/opt/socktainer` | Installation directory (must be a safe child of `/opt`) |
| `PACKAGE_IDENTIFIER` | `io.github.socktainer` | Package receipt identifier |
| `PATHS_D_NAME` | `socktainer` | Name of the `/etc/paths.d` entry |
| `INSTALL_PATHS_D` | `1` | Set to `0` to leave the system PATH unchanged |

For an isolated validation package, use a unique prefix and receipt and disable the
PATH hook:

```bash
make INSTALL_PREFIX=/opt/socktainer-qa-123 \
     PACKAGE_IDENTIFIER=io.github.socktainer.qa.123 \
     INSTALL_PATHS_D=0 installer
```

Install and verify that isolated package with its full path:

```bash
sudo installer -pkg pkginstaller/out/socktainer-installer.pkg -target /
/opt/socktainer-qa-123/bin/socktainer --version
pkgutil --pkg-info io.github.socktainer.qa.123
```

Because the isolated package has its own prefix and receipt and does not change
`/etc/paths.d`, it leaves a Homebrew or existing default Socktainer installation
untouched. Roll it back with:

```bash
sudo rm -rf /opt/socktainer-qa-123
sudo pkgutil --forget io.github.socktainer.qa.123
```

An in-place installation at the default prefix replaces that prefix. Roll back an
in-place upgrade by reinstalling the previous package or Homebrew version.

## Output

Creates `out/socktainer-installer.pkg` that:
- Installs the daemon, VMM helper, libkrun, and gvproxy to `/opt/socktainer/bin/`
- Installs the guest kernel and read-only root disk to `/opt/socktainer/share/socktainer/`
- Adds `/opt/socktainer/bin` to system PATH
- Shows professional installer UI

## Uninstall

```bash
sudo rm -rf /opt/socktainer
sudo rm -f /etc/paths.d/socktainer
sudo pkgutil --forget io.github.socktainer
```
