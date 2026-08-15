# Glass Dock 🚢

> [!IMPORTANT]
> Both `glassdock` and [Apple container](https://github.com/apple/container) are still under heavy development!

> [!NOTE]
> `glassdock` maintains to be compatible with [Docker Engine API v1.51](https://github.com/moby/moby/blob/v28.5.2/api/swagger.yaml).
>
> Progress is tracked in [#14](https://github.com/socktainer/socktainer/issues/14) and [#90](https://github.com/socktainer/socktainer/issues/90).

<!--toc:start-->

- [Glass Dock 🚢](#glass-dock-🚢)
  - [Quick Start ⚡](#quick-start)
    - [Launch Glass Dock 🏁](#launch-glass-dock-🏁)
    - [Using Docker CLI 🐳](#using-docker-cli-🐳)
  - [Key Features ✨](#key-features)
  - [Requirements 📋](#requirements-📋)
  - [Installation 🛠️](#installation-🛠️)
    - [Homebrew](#homebrew)
      - [Stable Release](#stable-release)
      - [Pre Release](#pre-release)
    - [GitHub Releases](#github-releases)
  - [Usage 🚀](#usage-🚀)
    - [Docker builds and Buildx](#docker-builds-and-buildx)
    - [Image names, IDs, and repeated builds](#image-names-ids-and-repeated-builds)
    - [Runtime and published-port recovery](#runtime-and-published-port-recovery)
    - [Volume sync mode](#volume-sync-mode)
    - [Engine resources](#engine-resources)
  - [Building from Source 🏗️](#building-from-source-🏗️)
    - [Prerequisites](#prerequisites)
    - [Build & Run](#build-run)
    - [Testing ✅](#testing)
  - [Contributing 🤝](#contributing-🤝)
    - [Workflow](#workflow)
    - [Developer Notes 🧑‍💻](#developer-notes-🧑‍💻)
  - [Security & Limitations ⚠️](#security-limitations-️)
  - [Community 💬](#community-💬)
  - [License 📄](#license-📄)
  - [Acknowledgements 🙏](#acknowledgements-🙏)
  <!--toc:end-->

Glass Dock is a CLI/daemon that exposes a **Docker-compatible REST API** through one persistent Linux VM on Apple Silicon 🍏📦.

It allows common Docker clients (like the Docker CLI) to interact with local containers on macOS using the Docker API surface 🐳💻.

[**Podman Desktop Apple Container extension**](https://github.com/podman-desktop/extension-apple-container) uses Glass Dock to visualize Apple containers/images in [Podman Desktop](https://podman-desktop.io/).

---

## Quick Start ⚡

Get started with the Glass Dock CLI in a few commands:

### Launch Glass Dock 🏁

```bash
./glassdock
FolderWatcher] Started watching $HOME/Library/Application Support/com.apple.container
[ NOTICE ] Server started on http+unix: $HOME/.glassdock/container.sock
...
```

### Using Docker CLI 🐳

Glass Dock automatically registers a `glassdock` Docker context on startup.
Activate it once:

```bash
docker context use glassdock
```

Then use Docker normally — no `DOCKER_HOST` needed:

```bash
docker ps        # List running containers
docker ps -a     # List all containers
docker images    # List available images
```

Switch back to another runtime at any time:

```bash
docker context use colima    # or "default", etc.
```

<details>
<summary>Opt out of automatic context creation</summary>

Pass `--no-docker-context` to skip writing the context file on startup — useful
in CI or when managing Docker contexts manually:

```bash
glassdock --no-docker-context
```

Note: this flag skips **creating** the context but does not remove one that was
already created. To remove it: `docker context rm glassdock`.

</details>

<details>
<summary>Alternative: set DOCKER_HOST manually</summary>

```bash
export DOCKER_HOST=unix://$HOME/.glassdock/container.sock
docker ps
docker images
```

Or inline without exporting:

```bash
DOCKER_HOST=unix://$HOME/.glassdock/container.sock docker ps
DOCKER_HOST=unix://$HOME/.glassdock/container.sock docker images
```

</details>

---

## Key Features ✨

- Runs one persistent Linux VM with a custom Hypervisor.framework VMM 🍏
- Provides **Docker REST API compatibility** 🔄 (partial)
- Listens on a Unix domain socket `$HOME/.glassdock/container.sock` and auto-registers a `glassdock` Docker context
- Uses containerd, overlayfs, runc, and Linux namespaces for containers
- Supports create, start, stop, wait, remove, inspect, list, logs, and noninteractive exec
- Supports containerd-backed image pull, list, inspect, tag, delete, and prune operations

---

## Requirements 📋

- **macOS 26 (Tahoe) on Apple Silicon (arm64)**
- The installer package, which includes the VMM, guest kernel, root disk, libkrun,
  and gvproxy runtime artifacts

---

## Installation 🛠️

### Homebrew

After the `glassdock` formula is published to Homebrew, install it with:

```shell
brew install glassdock
```

To install the latest source revision after the formula is published, use:

```shell
brew install glassdock --HEAD
```

### GitHub Releases

Download Glass Dock from the current [releases page](https://github.com/socktainer/socktainer/releases). Ensure the binary has execute permissions (`+x`) before running it.

---

## Usage 🚀

Refer to **Quick Start** above for immediate usage examples.

### Docker builds and Buildx

Docker builds are not available in this alpha. The old build service started a
second Apple VM, so the single-VM runtime does not register the Docker build
endpoints. BuildKit integration must run inside the persistent engine VM before
Glass Dock can support Buildx.

### Image names, IDs, and repeated builds

containerd owns image content and tags. Glass Dock normalizes familiar image names
before it sends them to the guest. Image list, inspect, pull, tag, delete, and prune
operations use this one content store.

### Runtime and published-port recovery

Glass Dock runs one persistent Linux VM through its custom VMM. The host Docker API maps
container operations through one multiplexed vsock connection to a guest agent.
The guest uses containerd, overlayfs, runc, and Linux namespaces for all ordinary
containers. Glass Dock does not start one VM per container or use relay sidecar
VMs.

Published TCP and UDP ports use one supervised gvproxy process for each VM
generation. The VMM connects gvproxy to the guest virtio-net device. The guest
applies DNAT from the engine ingress port to the container's private network
namespace. The guest stores Docker names, labels, commands, and port mappings in
containerd metadata. Glass Dock restores this state and the gvproxy forwarding
rules after a daemon restart.

This alpha runtime does not import containers, images, networks, or transient
state from the removed per-container-VM architecture. The first start creates a
new persistent engine data disk. Keep or remove old state separately until you
confirm that you no longer need it.

### Volume sync mode

Named volumes default to `fsync`, so guest `fsync()` calls are flushed to the host
disk. This is the safe default for databases, write-ahead logs, and other durable
state.

`nosync` remains available as an explicit performance opt-in. It can be faster for
write-heavy disposable workloads, but data since the last host page-cache flush can
be lost if the Mac crashes or loses power. Do not use `nosync` for durable database
volumes.

**Override globally** — apply the same mode to all named volumes (bind mounts and anonymous volumes are not affected):

```bash
glassdock --volume-sync=fsync   # default: honor guest fsyncs (durable)
glassdock --volume-sync=full    # fully synchronous writes (slowest)
glassdock --volume-sync=nosync  # explicit unsafe performance mode
```

**Override per volume** — `docker volume create -o sync=<mode>` persists the
choice for that volume regardless of the global flag:

```bash
docker volume create -o sync=fsync my-pgdata
docker run -v my-pgdata:/var/lib/postgresql/data postgres
docker volume inspect my-pgdata --format '{{index .Options "sync"}}' # fsync
```

Or using Docker Compose with `driver_opts`:

```yaml
services:
  postgres:
    image: postgres:latest
    volumes:
      - pgdata:/var/lib/postgresql/data

volumes:
  pgdata:
    driver: local
    driver_opts:
      sync: fsync
```

Valid modes: `nosync` · `fsync` · `full`

`docker compose down` preserves named volumes; `docker compose down -v`
intentionally deletes them.

### Engine resources

All containers share the persistent engine VM. The defaults are 6 virtual CPUs
and a 1 GiB configured memory ceiling. Use `--cpus <count>` and
`--memory-mib <MiB>` to set the VM resources when you start Socktainer. The VMM
reclaims guest pages through the virtio balloon device, so configured memory
and physical footprint are separate measurements. Docker per-container CPU and
memory limits are not implemented.

---

## Building from Source 🏗️

### Prerequisites

- **Swift 6.2** (requirements from Apple container)
- **Xcode 26** (select the correct toolchain if installed in a custom location)

```bash
sudo xcode-select --switch /Applications/Xcode_26.0.0.app/Contents/Developer
# or
sudo xcode-select -s /Applications/Xcode-26.app/Contents/Developer
```

### Build & Run

1. Build the project:

```bash
make
```

Build the Linux/arm64 guest agent and its deterministic OCI image after a guest
runtime change:

```bash
make -C Guest image
cd Guest && go test -race ./... && go vet ./...
```

2. (Optional) Format the code:

```bash
make fmt
```

3. Run the debug binary:

```bash
.build/arm64-apple-macosx/debug/glassdock
```

> The server will create the socket at `$HOME/.glassdock/container.sock`.

### Testing ✅

Run unit tests:

```bash
make test
```

---

## Contributing 🤝

We welcome contributions!

### Workflow

1. Fork the repository and create a feature branch 🌿
2. Open a PR against `main` with a clear description 📝
3. Add or update tests for new behavior (see `Tests/GlassDockTests`) ✔️
4. Keep changes small and focused. Document API or behavioral changes in the PR description 📚

### Developer Notes 🧑‍💻

- Code organization under `Sources/GlassDock/`:
  - `Routes/` — Route handlers 🛣️
  - `Clients/` — Client integrations 🔌
  - `Utilities/` — Helper utilities 🧰
- Document any public API or CLI changes in this README 📝

#### Piping I/O to container processes

When passing I/O to `ContainerClient.createProcess(stdio:)` or `ContainerClient.bootstrap(id:stdio:)`, **do not use Foundation's `Pipe()`**. Use `StdioPipes` from `Sources/GlassDock/Utilities/DockerConnectionUtility.swift` instead.

**Background**: on Unix, every open file/socket/pipe is identified by a small integer called a *file descriptor* (fd). Apple's APIs dup the fds you pass into the container and then **immediately close your originals**. Foundation's `Pipe` doesn't know this happened — when it's eventually garbage-collected, it tries to `close()` the same fd number again. By then, that number may have been recycled for a NIO HTTP socket, so the double-close silently kills an active connection, corrupting the event loop and causing hard-to-reproduce crashes under concurrent load (issue [#107](https://github.com/socktainer/socktainer/issues/107)).

`StdioPipes` centralises allocation, EMFILE validation, and cleanup:

```swift
guard let pipes = StdioPipes.make([.stdin, .stdout, .stderr]) else { // or make(.all)
    throw Abort(.internalServerError, reason: "Failed to create I/O pipes")
}
let process: ClientProcess
do {
    process = try await ContainerClient().createProcess(..., stdio: pipes.stdioArray)
} catch {
    pipes.closeAll()          // Apple never received the fds — close all 6
    throw error
}
do {
    try await process.start()
} catch {
    pipes.closeAfterHandoff() // Apple owns stdin.read, stdout.write, stderr.write
    throw error
}
// Use pipes.stdout?.read, pipes.stderr?.read, pipes.stdin?.write in tasks
```

Ownership rules:
- **stdout/stderr**: Apple closes `.write`. You close `.read` when the reader task ends.
- **stdin**: Apple closes `.read`. You close `.write` when done sending input.
- `StdioPipes.make()` closes any partial pipes on EMFILE and returns `nil` — always `guard let`.

`make test` includes a `lint-pipes` check that fails if `= Pipe()` appears in application source.

---

## Runtime benchmarks

Use the local benchmark harness to compare a changed Socktainer build with
other Docker-compatible engines on the same Apple Silicon Mac:

```bash
make benchmark-discover
make benchmark-preflight
make benchmark
```

The [benchmark guide](benchmarks/README.md) specifies the warm-up, order,
correctness, cleanup, raw-data, statistics, and external-product configuration
rules. Do not compare result values from different machines.

---

## Security & Limitations ⚠️

- Intended for **local development and experimentation** 🏠
- Running third-party container workloads carries inherent risks. Review sandboxing and container configurations 🔒
- Docker API compatibility is **partial**, focused on commonly used endpoints. See `Sources/GlassDock/Routes/` for implemented routes
- Pull authentication from Docker's `X-Registry-Auth` header is forwarded only
  to the registry named by the image reference.
- Privileged containers are not yet implemented.
- Per-container CPU and memory limits are not yet implemented. All ordinary
  containers share the engine VM allocation.
- Bind-mounting the Docker socket into a container is not implemented.
- The VMM exports the host home directory to the trusted guest so it can serve
  arbitrary Docker bind requests. Containers receive only their requested bind
  paths. Glass Dock rejects binds that overlap its engine state, and the
  virtio-fs server confines all file operations beneath the exported root.
- Restart policies are not implemented.
- `docker update` does not yet change container resources.
- Image load, save, history, and push are not connected to the guest content store.
- Pause, unpause, network connect, and network disconnect are not implemented.
- Docker network-management endpoints are explicit `501` responses in this
  alpha. Each container uses the persistent engine's private bridge.
- Static container IP requests are not yet implemented.
- Other unimplemented operations include commit, diff, search, top, archive,
  export, stats, resize, rename, restart, and resource update.
- Known unsupported Docker endpoints return an explicit `501 Not Implemented`
  Docker error instead of an accidental router `404`.
- Glass Dock replaces a readable data disk only when it identifies the previous
  unjournaled alpha format. It preserves that disk as
  `data.ext4.incompatible-<UUID>`. An unreadable or corrupt disk stops startup
  and remains unchanged.

---

## Community 💬

Join the Glass Dock community to ask questions, share ideas, or get help:

- **Discord**: [discord.gg/Pw9VWKcUEt](https://discord.gg/Pw9VWKcUEt) – chat in real time with contributors and users
- **GitHub Discussions**: [current repository discussions](https://github.com/socktainer/socktainer/discussions) – ask questions or propose features
- **GitHub Issues**: [current repository issues](https://github.com/socktainer/socktainer/issues) – report bugs or request features

## License 📄

See the `LICENSE` file in the repository root.

---

## Acknowledgements 🙏

- Glass Dock is derived from Socktainer and retains its Apache License 2.0
  license terms, copyright notices, and Git history.
- Built with **Hypervisor.framework, libkrun, and gvproxy** 🍏
- Enables Docker CLI and other Docker clients to interact with local macOS containers 🐳💻
