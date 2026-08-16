# Changelog

Glass Dock records user-visible changes in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0]

### Added

- Add a signed and notarized macOS arm64 installer, runtime archive, checksums,
  and release verification tools.
- Add a native Glass Dock menu-bar app and a Raycast extension for service
  status, diagnostics, and container controls.
- Add a reproducible benchmark harness with isolated engine state and explicit
  dependency lifecycle commands.

### Changed

- Rename the project and distribution identity from Socktainer to Glass Dock.
- Improve persistent runtime and Docker-compatible API hot paths used by the
  benchmark suite.

## [Unreleased]

### Added

- Add a versioned macOS package, complete runtime archive, checksums, signing and
  notarization hooks, package smoke tests, and a draft GitHub release workflow.
- Add deterministic guest root-disk construction and reproducibility checks.
- Add a per-user launch agent, service controls, safe upgrade behavior, uninstall,
  and local rollback support for package installations.

### Changed

- Make the signed and notarized package the primary installation method.
- Store persistent engine state outside the user home that is exported to the
  engine VM.
- Require release tags and changelog entries to exist before release automation
  runs. Release automation no longer creates or publishes tags.

## [1.2.1]

This version predates the maintained changelog. See its GitHub release for details.
