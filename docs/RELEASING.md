# Release Glass Dock

Glass Dock releases one complete Apple Silicon runtime. The signed and notarized
`.pkg` is the user installation. The `.tar.gz` is for advanced use and future
package-manager formulas. Every release also contains `SHA256SUMS` and a GitHub
artifact attestation.

## Distribution decisions

- Use a GitHub release package now. It can install all runtime assets, a launch
  agent, service controls, and uninstall behavior as one transaction.
- Do not publish the current standalone binary. It cannot run without its sibling
  VMM and guest assets.
- Do not use npm. Glass Dock is not a JavaScript tool, and an npm lifecycle script
  would only add another installer and trust boundary.
- Do not submit a Homebrew Core formula until the project has a stable release
  cadence and the formula installs the complete runtime. A project tap can use the
  complete archive first. Package-manager publication stays outside this workflow.
- Do not add a DMG. It adds no value for a command-line package. A future menu-bar
  app should use a signed app bundle and an app-owned per-user service.

## Service and future app model

The current package installs program files as root but does not start a root
service. Each user explicitly runs `glassdock enable`. This command copies a
LaunchAgent to that user's library and starts the daemon in the user's GUI domain.
The daemon owns one user socket, one Docker context, and one engine state directory.
An update changes the `current` link but does not replace a running process. The user
restarts the service when ready.

A future menu-bar product must replace this loose LaunchAgent with one app-owned
service registered through `SMAppService`. Put the daemon and runtime assets inside
the signed app bundle. The app must show service state, required file permissions,
update progress, and failures. It must keep one owner for the existing user socket
and engine state. At that point, use a notarized app distribution, a Homebrew cask,
and an app-aware update framework. Do not install both service models at the same
time.

## Release preparation

1. Move the entries from `Unreleased` in `CHANGELOG.md` to a new section named
   `## [<version>]`.
2. Run the local checks:

   ```bash
   make fmt
   make test
   make release-tools-test
   make installer-test
   ```

3. Commit the release preparation with DCO sign-off.
4. Create and push a signed or annotated `v<version>` tag from the reviewed commit.

The release workflow validates the existing tag and changelog section. It does not
create a tag. It builds on the trusted Apple Silicon runner, signs and notarizes the
runtime package, creates checksums, tests the artifacts, and creates a draft GitHub
release. It does not publish the draft.

## First-release gates

Do not publish the first release until both gates are complete:

- Fix the live smoke-test failure where `docker run --rm` exits successfully but
  does not return the attached standard output.
- Configure and validate the protected signing environment and Apple credentials
  described below. The unsigned local build does not validate signing or
  notarization.

## Reproducibility scope

The release uses a reviewed tag, fixed Xcode and Go versions, a repository Rust
toolchain, locked dependencies, fixed Linux sysroot package digests, and the tagged
commit time as `SOURCE_DATE_EPOCH`. The package smoke test builds the complete
unsigned runtime archive twice and requires identical bytes. The release build also
creates the guest root disk and kernel twice and requires identical bytes.
`BUILD-METADATA.txt` records the source commit, tool versions, artifact sizes, and
hashes.

Developer ID timestamps and Apple notarization tickets are external signed data.
They make the final signed package different from an unsigned local package. Verify
the final package with its checksum, Apple ticket, GitHub attestation, and recorded
source commit. Do not describe the notarized package as a bit-for-bit reproducible
artifact.

## GitHub environment and secrets

Create a protected GitHub Actions environment named `release-signing`. Restrict it
to release tags and require a reviewer. Store these secrets in that environment:

- `DEVELOPER_ID_APPLICATION_P12_BASE64`
- `DEVELOPER_ID_INSTALLER_P12_BASE64`
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `DEVELOPER_ID_APPLICATION`
- `DEVELOPER_ID_INSTALLER`
- `APP_STORE_CONNECT_KEY_P8_BASE64`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`

Use a dedicated App Store Connect API key with the minimum access that the Apple
notary service accepts. The workflow writes credentials only to its temporary
directory and a temporary keychain. Its cleanup step deletes both. The build job
has read-only repository access. Only the separate draft-release job has
`contents: write`; that job does not receive Apple credentials.

## Publish

After the workflow succeeds:

1. Verify the package signature, notarization ticket, checksums, attestation, and
   draft release notes.
2. Install the package on a clean supported Mac and run the Docker API smoke test.
3. Approve and publish the GitHub draft release.
4. Update a project Homebrew tap only after the GitHub release is public. Submit to
   Homebrew Core only as a separate, explicit project decision.

Publishing a release, changing GitHub settings, adding environment secrets, using
external signing credentials, and making a package-manager submission require
explicit maintainer approval.
