# Socktainer 🚢

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

- **macOS on Apple Silicon (arm64)** Apple’s container APIs only work on arm64 Macs 🍏💻  
  [Apple container requirements](https://github.com/apple/container/blob/main/README.md#requirements) 

---

## Installation 🛠️

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

## License 📄

See the `LICENSE` file in the repository root.

---

## Acknowledgements 🙏

- Built using **Apple containerization libraries** 🍏  
- Enables Docker CLI and other Docker clients to interact with local macOS containers 🐳💻
