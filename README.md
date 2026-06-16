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
    - [Volume sync mode](#volume-sync-mode)
    - [VM memory](#vm-memory)
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

Socktainer automatically registers a `socktainer` Docker context on startup.
Activate it once:

```bash
docker context use socktainer
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
socktainer --no-docker-context
```

Note: this flag skips **creating** the context but does not remove one that was
already created. To remove it: `docker context rm socktainer`.

</details>

<details>
<summary>Alternative: set DOCKER_HOST manually</summary>

```bash
export DOCKER_HOST=unix://$HOME/.socktainer/container.sock
docker ps
docker images
```

Or inline without exporting:

```bash
DOCKER_HOST=unix://$HOME/.socktainer/container.sock docker ps
DOCKER_HOST=unix://$HOME/.socktainer/container.sock docker images
```

</details>

---

## Key Features ✨

- Built on **Apple’s Container Framework** 🍏
- Provides **Docker REST API compatibility** 🔄 (partial)
- Listens on a Unix domain socket `$HOME/.socktainer/container.sock` and auto-registers a `socktainer` Docker context
- Supports container lifecycle operations: inspect, stop, remove 🛠️
- Supports image listing, pulling, deletion, logs, health checks, container stats. Exec without interactive mode 📄
- `docker stats` reports memory against the Apple Container VM limit (configurable via `--memory`, default 1 GiB per container), not the host RAM
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

### Volume sync mode

Named volumes default to `nosync` — guest `fsync()` calls are not flushed to the
host disk on demand, matching Colima's behavior and giving ~1.5× speedup for
write-heavy workloads (postgres WAL, Kafka, Redis AOF).

**Tradeoff:** data written to a volume since the last OS page-cache flush could be
lost if the **host** (Mac) crashes or loses power. In a dev environment this is
acceptable; data is safe across normal `docker stop` / host restarts.

**Override globally** — apply the same mode to all named volumes (bind mounts and anonymous volumes are not affected):

```bash
socktainer --volume-sync=fsync   # honor guest fsyncs (durable)
socktainer --volume-sync=full    # fully synchronous writes (slowest)
socktainer --volume-sync=nosync  # default
```

**Override per volume** — `docker volume create -o sync=<mode>` persists the
choice for that volume regardless of the global flag:

```bash
docker volume create -o sync=fsync my-pgdata
docker run -v my-pgdata:/var/lib/postgresql/data postgres
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

### VM memory

Each container runs in its own Apple Container VM with a fixed memory allocation.
Socktainer honors Docker's `--memory` flag and `mem_limit:` / `deploy.resources.limits.memory:` in Compose files.

```bash
docker run --memory 2g postgres          # 2 GiB VM
docker run --memory 512m redis           # 512 MiB VM
docker run postgres                      # 1 GiB VM (Apple Container default)
```

> **Note:** Apple Container allocates VM RAM at creation time — this is not a cgroup
> soft limit. Setting `--memory` too low will cause the process to OOM inside the VM.
>
> There is no "unlimited" mode: Docker's `--memory 0` (no limit) maps to the Apple
> Container default of **1 GiB**, not host RAM. To give a container more than 1 GiB,
> always pass an explicit `--memory` value.

In Docker Compose:

```yaml
services:
  kafka:
    image: confluentinc/cp-kafka
    mem_limit: 2g
  redis:
    image: redis:alpine
    mem_limit: 256m
```

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
- Private registry auth currently depends on Apple `container` behavior. If login succeeds but private pulls/builds still fail, a manual workaround may be required. See [apple/container#816 comment 3534438608](https://github.com/apple/container/issues/816#issuecomment-3534438608) and [comment 3503618765](https://github.com/apple/container/issues/816#issuecomment-3503618765).

### Docker Compose — inter-service DNS

Socktainer registers service names in its DNS server so Compose services can
reach each other by name. Two aliases are created per service:

| Alias | Example | Description |
|---|---|---|
| `service` | `db` | Short form — works within a single project |
| `service.project` | `db.myapp` | Project-qualified — unique across concurrent projects |

Set the project name explicitly via `name:` at the top of your Compose file
(otherwise Docker Compose derives it from the directory name):

```yaml
name: myapp   # sets com.docker.compose.project=myapp

services:
  web:
    image: nginx:alpine
    # can reach the database as 'db' or 'db.myapp'
  db:
    image: postgres:17
    environment:
      POSTGRES_PASSWORD: secret
```

> **Note:** Apple Container uses a single global hostname namespace. Two
> Compose projects running simultaneously with identically-named services
> (e.g. both have a `db` service) will share the short-form alias — last
> started wins. Use the qualified form (`db.myapp`) to resolve unambiguously.

### Label key normalization

Apple Container only accepts lowercase label keys matching `[a-z0-9](?:[a-z0-9\-\.\/]*[a-z0-9])?`. Docker allows mixed-case, underscores, and other characters. Socktainer automatically normalizes label keys at create time:

- Uppercase → lowercase (`sessionId` → `sessionid`)
- Underscores → hyphens (`my_key` → `my-key`)
- Other invalid characters are dropped
- An `INFO` log is emitted for every key that is changed
- A `WARNING` is logged when a key becomes empty after normalization (dropped) or when two keys normalize to the same string (collision, last value wins)

Original keys are preserved via an internal mapping label (`socktainer.label-original-keys`) that is stored alongside the normalized keys and stripped from all API responses. As a result, `docker inspect`, filter lookups, and Go-template label access all return and match the original key exactly:

```bash
# Works — original key is restored transparently
docker inspect --format '{{index .Config.Labels "MyApp"}}' <container>
docker ps --filter label=MyApp=value
```

The one edge case: if two keys normalize to the same string (e.g. `MyKey` and `mykey`), the last one wins — a `WARNING` is logged so the loss is visible in Socktainer's output.

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
