# Publishing preparation research

This document describes local preparation. It does not authorize an upload,
submission, Store publication, or release.

## Distribution paths

The Glass Dock menu-bar app is a direct-distribution macOS app. It must use a `Developer ID
Application` certificate. A signed installer package must use a separate
`Developer ID Installer` certificate. Do not use an Apple Distribution or
development certificate for this path. Apple describes these certificate types
in [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
and [Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/).

Raycast Store distribution is separate from Apple distribution. It uses the
Raycast account and review process. It does not use an Apple certificate,
notarization credential, or App Store Connect record.

## Apple preparation

### Signing

Before a release build, verify that the login keychain has the required
identity. Apple documents `security find-identity -p codesigning -v` for this
check. Sign every distributed executable, from nested code to its containing
bundle, with a Developer ID Application identity, a secure timestamp, and the
Hardened Runtime. The release script must use `--timestamp` and `--options
runtime`; it must not use `sudo`. See [Apple's signing instructions](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/).

The current menu app needs no restricted entitlement. Keep its release
entitlements minimal: do not add `get-task-allow` or a privacy-protected
capability unless the app implementation requires it. Do not add App Sandbox
until its effect on the user's Glass Dock Unix socket is tested. App Sandbox is
required for the Mac App Store and recommended, but not required, for Developer
ID distribution. See [Distributing software on macOS](https://developer.apple.com/macos/distribution/).

For notarization, Apple requires valid Developer ID signatures on every
executable, Hardened Runtime, a secure timestamp, a macOS 10.9 or later SDK,
and no true `com.apple.security.get-task-allow` entitlement. See
[Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Use local checks before any upload:

```sh
security find-identity -p codesigning -v
codesign --verify --deep --strict --verbose=4 GlassDock.app
codesign --display --verbose=4 --entitlements :- GlassDock.app
spctl --assess --type execute --verbose=4 GlassDock.app
```

The `spctl` check can reject a valid pre-notarization app. Treat that result as
expected until notarization is complete; do not use it to bypass Gatekeeper.

Before release, set a stable unique bundle ID, an increasing build string, a
human-readable copyright value, and a production app icon. Apple lists these
as distribution information for macOS apps. See [Preparing your app for
distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution).

### Packages and notarization

Apple accepts ZIP archives, signed flat installer packages, and UDIF disk
images for notarization. An `.app` bundle is not uploaded directly. For a ZIP,
Apple shows `ditto -c -k --keepParent`. For a custom installer, notarize and
staple its payload before it is put in the installer, then notarize the signed
installer. See [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
and [Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).

Use `xcrun notarytool`, not `altool`. After Apple accepts an upload, use
`xcrun stapler staple <path>` and `xcrun stapler validate <path>`. Apple states
that `altool` is no longer accepted, and documents `notarytool` and `stapler`
in [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

There is no Apple notarization dry run. `notarytool submit`, including one
that waits for a result, submits the archive to Apple. Local package, signature,
and lint checks are the only permitted dry-run checks before the final user
approval.

### Credentials and App Store Connect

Do not use the App Store Connect CLI to create or manage a Developer ID
certificate. Apple states that Developer ID certificates are created through
the Apple Developer website or Xcode, not the App Store Connect API. See
[Certificates](https://developer.apple.com/documentation/appstoreconnectapi/certificates).

`notarytool` can use either an app-specific Apple ID password or a Keychain
profile backed by an App Store Connect API key. For API keys, use a Team key;
Apple states that Individual keys cannot use `notaryTool`. Store credentials in
the Keychain with `notarytool store-credentials`; do not put a `.p8` key,
password, issuer ID, or key ID in the repository, command history, script
arguments, or build log. See [Creating API Keys for App Store Connect API](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)
and [Submitting software for notarization over the web](https://developer.apple.com/documentation/notaryapi/submitting-software-for-notarization-over-the-web).

An App Store Connect privacy label, policy URL, and Store metadata are for an
App Store Connect submission. They are not direct Developer ID notarization
requirements. If Glass Dock later uses App Store Connect, it must provide
accurate privacy details. See [App privacy details](https://developer.apple.com/app-store/app-privacy-details/).

For a future App Store Connect build, add a valid `PrivacyInfo.xcprivacy` only
when the app or an included SDK declares collected data or a required-reason
API. Apple requires valid manifests for some listed third-party SDKs in App
Store Connect submissions. For macOS, the file location is
`Contents/Resources/PrivacyInfo.xcprivacy`. See [Adding a privacy manifest](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk).

## Raycast preparation

The Raycast manifest must have Store metadata that matches the implementation:
title, description, extension icon, author, platforms, at least one title-case
category, commands, and useful keywords. The author must be the Raycast account
user name. The Store requires the MIT license and the current Raycast API. Use
npm and keep `package-lock.json`. See [the manifest reference](https://developers.raycast.com/information/manifest)
and [Prepare an extension for the Store](https://developers.raycast.com/basics/prepare-an-extension-for-store).

Use a 512 by 512 PNG extension icon that works with light and dark appearance.
The existing Raycast icon needs this check. Assets referenced at runtime belong
in `assets/`; remove unused assets. Optional Store screenshots are 2000 by
1250 PNG files. See [Prepare an extension for the Store](https://developers.raycast.com/basics/prepare-an-extension-for-store)
and [File structure](https://developers.raycast.com/information/file-structure).

Run these local-only checks:

```sh
cd raycast
npm ci
npm run lint
npm run build
ray develop
```

`ray develop` loads the extension locally and watches for changes. `npm run
build` validates and creates the distribution build. Neither action publishes.
Do not run `ray publish`, `npm run publish`, or `npx @raycast/api publish`
until the user gives final approval. Raycast documents the CLI in
[Developer tools](https://developers.raycast.com/information/developer-tools/cli)
and the review and publication process in
[Publish an extension](https://developers.raycast.com/basics/publish-an-extension).

Before review, add a Raycast-specific README that gives setup steps, describes
the local `glassdockctl` requirement, and states the data behavior. Confirm
that the user accepts MIT licensing for the `raycast/` subtree. The repository
root license is Apache-2.0, so the license boundary must be clear before Store
review.

## Actions that need final approval

The following actions change external state. Do not run them during
preparation:

* Create, revoke, or export an Apple certificate or provisioning profile.
* Store, validate, or use notarization credentials.
* Run `notarytool submit`, get a notary log, staple a ticket, or distribute an
  archive.
* Run a Raycast login or publish command, create a Store draft, or request
  review.

## Local review workflow

Prepare and validate the menu app without submission:

```sh
make menu-release APP_RELEASE_VERSION=1.3.0 APP_BUILD_NUMBER=1
make publishing-validate APP_RELEASE_VERSION=1.3.0
open .build/release/GlassDock.app
```

The signed ZIP is in `.build/release-distribution/`. Gatekeeper can reject this
pre-notarization build. Do not bypass Gatekeeper. The release script reports
this result without treating it as a signature failure.

Start Raycast development mode:

```sh
make control
cd raycast
npm ci
npm run dev
```

For Store screenshots, create or use Raycast's **Capture Window** hotkey. Open
each Glass Dock command, capture the window, select **Save to Metadata**, and
save at least three 2000 by 1250 PNG files in `raycast/metadata/`. Review each
image for user names, paths, container names, log text, tokens, and unrelated
apps before it is included.

The current Raycast CLI must be authenticated before publication so it can
verify that `naaiyy` matches the Store account. Authentication is not required
for `lint`, `build`, or `develop`, and it was not performed during this
preparation.
