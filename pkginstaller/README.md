# Socktainer macOS Package Installer

Builds a macOS `.pkg` installer that installs socktainer to `/opt/socktainer/bin/` and adds it to the system PATH.

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

- Run `make release` in project root first
- Xcode Command Line Tools installed
- Developer certificates (for signed builds only)

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `BUILD_VERSION` | `0.0.0-dev` | Version for installer |
| `NO_CODESIGN` | `1` | Set to `0` to enable signing |
| `INSTALL_PREFIX` | `/opt/socktainer` | Installation directory |

## Output

Creates `out/socktainer-installer.pkg` that:
- Installs binary to `/opt/socktainer/bin/socktainer`
- Adds `/opt/socktainer/bin` to system PATH
- Shows professional installer UI

## Uninstall

```bash
sudo rm -rf /opt/socktainer
sudo rm -f /etc/paths.d/socktainer
sudo pkgutil --forget com.socktainer.socktainer
```