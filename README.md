# Socktainer 🚢

> [!IMPORTANT]
> Both `socktainer` and [Apple container](https://github.com/apple/container) are still under heavy development!

> [!NOTE]
> `socktainer` maintains to be compatible with [Docker Engine API v1.51](https://github.com/moby/moby/blob/v28.5.2/api/swagger.yaml).
>
> Progress is tracked in [#14](https://github.com/socktainer/socktainer/issues/14) and [#90](https://github.com/socktainer/socktainer/issues/90).

<!--toc:start-->

- [Socktainer 🚢](#socktainer-🚢)
  - [Quick Start ⚡](#quick-start)
    - [Launch socktainer 🏁](#launch-socktainer-🏁)
    - [Using Docker CLI 🐳](#using-docker-cli-🐳)
  - [Key Features ✨](#key-features)
  - [Requirements 📋](#requirements-📋)
  - [Installation 🛠️](#installation-🛠️)
    - [Homebrew](#homebrew)
      - [Stable Release](#stable-release)
      - [Pre Release](#pre-release)
    - [GitHub Releases](#github-releases)
  - [Usage 🚀](#usage-🚀)
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

Socktainer is a CLI/daemon that exposes a **Docker-compatible REST API** on top of Apple's containerization libraries 🍏📦.

It allows common Docker clients (like the Docker CLI) to interact with local containers on macOS using the Docker API surface 🐳💻.

[**Podman Desktop Apple Container extension**](https://github.com/benoitf/extension-apple-container) uses socktainer to visualize Apple containers/images in [Podman Desktop](https://podman-desktop.io/).

---

## Quick Start ⚡

Get started with socktainer CLI in just a few commands:

### Launch socktainer 🏁

```bash
./socktainer
FolderWatcher] Started watching $HOME/Library/Application Support/com.apple.container
[ NOTICE ] Server started on http+unix: $HOME/.socktainer/container.sock
...
```

### Using Docker CLI 🐳

Export the socket path as `DOCKER_HOST`:

```bash
export DOCKER_HOST=unix://$HOME/.socktainer/container.sock
docker ps        # List running containers
docker ps -a     # List all containers
docker images    # List available images
```

Or inline without exporting:

```bash
DOCKER_HOST=unix://$HOME/.socktainer/container.sock docker ps
DOCKER_HOST=unix://$HOME/.socktainer/container.sock docker images
```

---

## Key Features ✨

- Built on **Apple’s Container Framework** 🍏
- Provides **Docker REST API compatibility** 🔄 (partial)
- Listens on a Unix domain socket `$HOME/.socktainer/container.sock`
- Supports container lifecycle operations: inspect, stop, remove 🛠️
- Supports image listing, pulling, deletion, logs, health checks. Exec without interactive mode 📄
- Broadcasts container events for client liveness monitoring 📡

---

## Requirements 📋

- **macOS 26 (Tahoe) on Apple Silicon (arm64)** Apple’s container APIs only work on arm64 Macs 🍏💻
- **Apple Container 0.6.0**

---

## Installation 🛠️

### Homebrew

`socktainer` is shipped via a homebrew tap:

```shell
brew tap socktainer/tap
```

#### Stable Release

Install the official release:

```shell
brew install socktainer
```

#### Pre Release

Install development release:

```shell
brew install socktainer-next
```

### GitHub Releases

Download from socktainer [releases](https://github.com/socktainer/socktainer/releases) page the zip or binary. Ensure the binary has execute permissions (`+x`) before running it.

---

## Usage 🚀

Refer to **Quick Start** above for immediate usage examples.

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

2. (Optional) Format the code:

```bash
make fmt
```

3. Run the debug binary:

```bash
.build/arm64-apple-macosx/debug/socktainer
```

> The server will create the socket at `$HOME/.socktainer/container.sock`.

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
3. Add or update tests for new behavior (see `Tests/socktainerTests`) ✔️
4. Keep changes small and focused. Document API or behavioral changes in the PR description 📚

### Developer Notes 🧑‍💻

- Code organization under `Sources/socktainer/`:
  - `Routes/` — Route handlers 🛣️
  - `Clients/` — Client integrations 🔌
  - `Utilities/` — Helper utilities 🧰
- Document any public API or CLI changes in this README 📝

---

## Security & Limitations ⚠️

- Intended for **local development and experimentation** 🏠
- Running third-party container workloads carries inherent risks. Review sandboxing and container configurations 🔒
- Docker API compatibility is **partial**, focused on commonly used endpoints. See `Sources/socktainer/Routes/` for implemented routes

---

## Community 💬

Join the Socktainer community to ask questions, share ideas, or get help:

- **Discord**: [discord.gg/Pw9VWKcUEt](https://discord.gg/Pw9VWKcUEt) – chat in real time with contributors and users
- **GitHub Discussions**: [socktainer/discussions](https://github.com/socktainer/socktainer/discussions) – ask questions or propose features
- **GitHub Issues**: [socktainer/issues](https://github.com/socktainer/socktainer/issues) – report bugs or request features

## License 📄

See the `LICENSE` file in the repository root.

---

## Acknowledgements 🙏

- Built using **Apple containerization libraries** 🍏
- Enables Docker CLI and other Docker clients to interact with local macOS containers 🐳💻
