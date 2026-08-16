# Glass Dock control clients

Glass Dock has two local control clients:

- `GlassDockMenu` is a native SwiftUI menu-bar app.
- `raycast/` is a TypeScript and React extension that uses Raycast UI.

Both clients use the `GlassDockControl` module. Raycast uses the module through
the versioned JSON output of `glassdockctl`. The clients do not build shell
commands. They do not call `launchctl` or the Docker socket directly.

The native app has the same macOS 26 and Apple Silicon requirement as the
Glass Dock daemon.

## Architecture decision

Use SwiftUI for the macOS content. Use an AppKit `NSStatusItem` and a transient
`NSPopover` for presentation. This combination keeps the complete product
anchored to the status item and gives explicit control of dismissal, focus, and
test-only presentation. Do not use React Native, Electron, or another web
runtime for the macOS app.

| Stack | Native integration | Distribution and lifecycle | Runtime cost | Maintenance | Decision |
| --- | --- | --- | --- | --- | --- |
| SwiftUI with a small AppKit adapter | Native controls in an anchored `NSPopover`, accessibility, Swift concurrency, Service Management, and macOS materials | Uses Apple signing, entitlements, launch agents, and notarization without a bridge | Small; no added runtime | One language for the daemon and app | Use |
| React Native | Requires native modules for launchd, signing-sensitive helpers, Unix sockets, and app-bundle resources | Still needs a Swift or Objective-C helper and Apple build tools | Adds JavaScript and a bridge | Two language stacks and bridge contracts | Do not use |
| Electron or Tauri | Weak fit for a small menu extra; platform work still needs a native helper | Adds a second application and helper distribution problem | Electron is large; Tauri is smaller but still adds a web layer | More build systems and more update surfaces | Do not use |
| AppKit only | Full native control | Same good distribution fit as SwiftUI | Small | More state and view code for no current benefit | Keep as an escape hatch |

Apple documents `NSStatusItem` as the system status-bar primitive and
`NSPopover` as the transient, anchored presentation primitive. The app uses
SwiftUI inside that popover. Apple supplies `SMAppService` for app-bundled login
items and launch agents. See [NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem),
[NSPopover](https://developer.apple.com/documentation/appkit/nspopover),
[transient popover behavior](https://developer.apple.com/documentation/appkit/nspopover/behavior-swift.enum/transient),
and [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice).

The near-term distribution must use Developer ID outside the Mac App Store.
The current daemon and runtime artifacts are not a self-contained sandboxed Mac
App Store product. Apple requires Mac App Store apps to use App Sandbox and
limits installed or downloaded executable code. See [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox),
[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/),
[Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac),
and [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Existing daemon model

The daemon is a foreground Swift and Vapor process. It:

- locks one engine state at `/private/var/tmp/glassdock-<uid>/engine`;
- creates `$HOME/.glassdock/container.sock`;
- optionally creates the `glassdock` Docker context;
- starts one persistent Linux VM and guest runtime;
- writes logs to its standard output and standard error;
- stops the runtime when the process stops.

Its command options are `--version`, `--[no-]docker-context`, and
`--volume-sync`. The volume sync values are `fsync`, `full`, and `nosync`.
`GLASSDOCK_ENGINE_STATE_DIRECTORY` can replace the engine state location.
`GLASSDOCK_HOST_HOME_DIRECTORY` can replace the exported host home.
`GLASSDOCK_VOLUME_DIRECTORY` can replace the volume location. The managed
LaunchAgent uses the defaults and lets the daemon create the Docker context.

The package installer puts the daemon and helpers in `/opt/glassdock`. Homebrew
installs the command-line package. Before this control foundation, neither model
installed or owned a background process.

## Shared control contract

`GlassDockControl` is the deep module at the control seam. Its small interface
is:

```swift
let snapshot = await ControlClient().snapshot()
let support = await ControlClient().supportReport()
let result = try await ControlClient().perform(.startDaemon)
let logs = try await ControlClient().daemonLogs()
```

The implementation hides these details:

- fixed daemon discovery;
- per-user LaunchAgent property-list creation and `launchctl` arguments;
- Unix-domain HTTP framing and timeouts;
- Docker response decoding and error mapping;
- Docker multiplexed log-frame decoding;
- managed log locations;
- safe daemon action checks.

Socket responses are limited to 4 MiB. Daemon diagnostics read at most 128,000
bytes from each log by default. These limits prevent a client from loading an
unbounded log into a menu or Raycast view.

The module uses a per-user LaunchAgent named `io.github.glassdock.daemon`.
`start` installs this agent if necessary. `stop` and `restart` only control an
instance that this agent owns. They fail when containers are running. This rule
prevents an unexpected container shutdown. A manually started daemon stays
healthy but is shown as unmanaged.

The machine interface is stable, versioned JSON:

```console
glassdockctl status --json
glassdockctl support-report --json
glassdockctl daemon start --json
glassdockctl daemon stop --json
glassdockctl daemon restart --json
glassdockctl containers list --json
glassdockctl containers start CONTAINER --json
glassdockctl containers stop CONTAINER --json
glassdockctl logs daemon --json
glassdockctl logs container CONTAINER --json
```

`status` returns `schemaVersion: 2`, one daemon status, container summaries,
socket connectivity, installation and control ownership, relevant paths, and a
disk-space signal when macOS supplies reliable volume capacity. The optional VM
health field is empty because the current daemon does not report VM readiness.
`support-report` returns the same snapshot, bounded managed log tails, and
copy-ready text. Change the schema version when a client must change how it
reads existing fields.

The menu app has no desktop window and no Dock item. Its transient status-item
popover opens with a searchable container list. An in-place System destination
contains status and diagnostics. Container logs also replace the popover body
in place and return to the list. Raycast exposes one **Glass Dock** command with
status and diagnostics navigation plus searchable container items.

The Docker server does not implement an atomic container restart route. The
control contract therefore does not expose container restart. A client must not
compose stop and start because a failed start leaves the container stopped.

## Build and test

Build all Swift products:

```console
make build
```

Build only the control command:

```console
make control
```

Build a local ad-hoc-signed application bundle:

```console
make menu-app
open .build/debug/GlassDock.app
```

Run the process-level status-item popover check:

```console
scripts/test-menu-popover.sh .build/debug/GlassDock.app/Contents/MacOS/GlassDockMenu
```

The `--show-popover` executable option exists only for local interaction tests.
The app stays an `LSUIElement` accessory application and does not create a Dock
item or an independent app window.

Prepare a Developer ID-signed archive without notarization or submission:

```console
make menu-release APP_RELEASE_VERSION=1.3.0 APP_BUILD_NUMBER=1
make publishing-validate APP_RELEASE_VERSION=1.3.0
```

The release target finds one Developer ID Application identity in the login
keychain. If more than one identity exists, pass its SHA-1 value with
`GLASSDOCK_SIGNING_IDENTITY`. The target enables Hardened Runtime, requests a
secure timestamp, verifies the signature, creates a ZIP with `ditto`, and
checks the archive. It does not contact Apple's notary service.

Install and build the Raycast extension:

```console
make raycast-install
make raycast-build
cd raycast && npm run dev
```

For a source build, set the Raycast `glassdockctl Executable` preference to the
absolute path of `.build/debug/glassdockctl`. An installed package is found at
`/opt/glassdock/bin/glassdockctl`, `/opt/homebrew/bin/glassdockctl`, or
`/usr/local/bin/glassdockctl`.

Raycast requires Raycast 1.26 or later, Node 22.14 or later, and npm 7 or later.
Its official extension lifecycle does not permit a command to be the daemon
owner. The extension therefore calls `glassdockctl` with an executable path and
an argument array. It never uses a shell. See Raycast [Getting Started](https://developers.raycast.com/basics/getting-started),
[Security](https://developers.raycast.com/information/security),
[Background Refresh](https://developers.raycast.com/information/lifecycle/background-refresh),
[Manifest](https://developers.raycast.com/information/manifest), and
[useExec](https://developers.raycast.com/utilities/react-hooks/useexec).

Run all Swift tests and format checks:

```console
make fmt
make test
```

## Distribution preparation

The repository has a production icon source, a privacy manifest, minimal menu
app entitlements, a Developer ID release builder, a notarization script, and
Raycast Store metadata. See [publishing preparation](PUBLISHING_PREPARATION.md).

The notarization script requires both `GLASSDOCK_RELEASE_APPROVED=YES` and the
literal `--approval FINAL-APPROVAL` argument. Do not supply these values until
the user gives separate final approval.

The larger self-contained product still needs:

1. Put the daemon, VMM artifacts, `glassdockctl`, and launch-agent property list
   in a signed `GlassDock.app` bundle.
2. Replace direct LaunchAgent installation from the menu app with an
   `SMAppService.agent(plistName:)` adapter. Keep the current adapter for the
   Homebrew and package distributions.
3. Sign each nested executable with the smallest required entitlement set. The
   process that starts the VM keeps the virtualization or Hypervisor entitlement.
4. After final approval, submit the signed app archive with `notarytool`, staple
   the accepted ticket, and create the final archive.
5. Test launch-agent approval, upgrade, removal, first launch, and crash recovery
   on a clean macOS account.
6. Capture reviewed Raycast Store screenshots, authenticate the Raycast CLI,
   and, after final approval, use Raycast's publish command. Publishing
   authenticates with GitHub and creates a pull request to the Raycast
   extensions repository. See [Prepare an Extension for Store](https://developers.raycast.com/basics/prepare-an-extension-for-store)
   and [Publish an Extension](https://developers.raycast.com/basics/publish-an-extension).

Raycast currently requires `MIT` in an extension Store manifest. The
`raycast/` subtree now has a separate MIT license. The main GlassDock
repository stays under Apache-2.0.

Do not publish either client until the user reviews both local experiences and
gives separate final approval.
