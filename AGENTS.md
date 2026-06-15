# Agent Instructions

This file is the primary instruction surface for agents contributing to Socktainer. It is injected into your context on every interaction.

## Project Identity

Socktainer is a Swift CLI/daemon that exposes a **Docker-compatible REST API** on top of Apple's containerization libraries. It allows Docker CLI clients to interact with local containers on macOS using the Docker API surface.

- **Target platform**: macOS on Apple Silicon (arm64) only
- **API compatibility**: [Docker Engine API v1.51](https://github.com/moby/moby/blob/v28.5.2/api/swagger.yaml)
- **Repository**: <https://github.com/socktainer/socktainer>
- **License**: Apache 2.0

## Skills

Agent skills live in `.agents/skills/`. Each skill has a `SKILL.md` file describing its purpose and usage.

| Skill | Purpose |
|---|---|
| `create-github-issue` | Create GitHub issues using the `gh` CLI |
| `create-github-pr` | Create GitHub pull requests using the `gh` CLI |

## Architecture Overview

| Path | Component | Purpose |
|---|---|---|
| `Sources/socktainer/main.swift` | Entry point | CLI argument parsing, Vapor app setup, Unix socket binding |
| `Sources/socktainer/configure.swift` | Configuration | Registers route collections and initializes services |
| `Sources/socktainer/Routes/Containers/` | Container routes | Docker container lifecycle API endpoints |
| `Sources/socktainer/Routes/Images/` | Image routes | Docker image management API endpoints |
| `Sources/socktainer/Routes/Networks/` | Network routes | Docker network API endpoints |
| `Sources/socktainer/Routes/Volumes/` | Volume routes | Docker volume API endpoints |
| `Sources/socktainer/Routes/Server/` | Server routes | Health check, info, version, events, system endpoints |
| `Sources/socktainer/Routes/Swarm/` | Swarm stubs | Stub responses for Docker Swarm API compatibility |
| `Sources/socktainer/Routes/Plugins/` | Plugin stubs | Stub responses for Docker plugin API compatibility |
| `Sources/socktainer/Routes/Registry/` | Registry routes | Auth and distribution endpoints |
| `Sources/socktainer/Clients/` | Service layer | Business logic wrapping Apple Container/Containerization frameworks |
| `Sources/socktainer/Models/` | REST models | Request/response DTOs matching Docker Engine API |
| `Sources/socktainer/DNS/` | DNS service | Inter-container DNS resolution |
| `Sources/socktainer/Events/` | Event system | Container event broadcasting for client liveness monitoring |
| `Sources/socktainer/Utilities/` | Utilities | Shared helpers (ID generation, label normalization, etc.) |
| `Sources/BuildInfo/` | Build metadata | C target exposing build version, git commit, API versions to Swift |
| `Tests/socktainerTests/` | Test suite | Unit tests organized by feature area |
| `Package.swift` | SPM manifest | Dependencies: apple/container, apple/containerization, Vapor, swift-log, swift-argument-parser |

## Commits

- Always use [Conventional Commits](https://www.conventionalcommits.org/) format: `<type>(<scope>): <description>` (scope is optional).
- Common types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `ci`, `perf`, `deps`, `build`.
- Common scopes: `routes`, `containers`, `images`, `healthcheck`, `dns`, `build`, `volumes`, `labels`, `stats`, `context`, `attach`, `app`, `archive`, `builder`.
- **DCO sign-off is required.** Use `git commit --signoff` (or `-s`) on every commit. The [DCO Probot app](https://probot.github.io/apps/dco/) enforces this on pull requests.
- Scope changes to the issue at hand. Do not make unrelated changes in the same branch.

## Code Formatting

- The project uses `swift-format` with configuration in `.swift-format`.
- Run `make fmt` before committing.
- CI checks for formatting drift: `make fmt` followed by `git diff --exit-code`.

## Testing

| Command | Purpose |
|---|---|
| `make build` | Build the project (debug mode) |
| `make fmt` | Format Swift source code |
| `make test` | Run the unit test suite |
| `make release` | Build in release mode |

Tests are in `Tests/socktainerTests/`. The PR CI (`pr-check.yaml`) runs: format check, unit tests, release build, installer build, and integration tests.

### Unit Test Requirements

- **Bug fixes must include a unit test** that reproduces the bug and verifies the fix. The test should fail without the fix and pass with it.
- **New features must include unit tests** covering the main behavior and relevant edge cases.
- Place tests in `Tests/socktainerTests/` following the existing directory structure (e.g., `Routes/`, `Utilities/`, `DNS/`, `Network/`).
- When modifying existing behavior, update the corresponding tests to reflect the change.
- Run `make test` before committing to ensure all tests pass.

## GitHub Labels

| Label | Use for |
|---|---|
| `bug` | Confirmed bugs |
| `enhancement` | Feature requests and improvements |
| `documentation` | Documentation-only changes |
| `good first issue` | Issues suitable for newcomers |
| `help wanted` | Issues where community help is welcome |
| `question` | Questions about the project |
| `duplicate` | Duplicate of an existing issue |
| `invalid` | Not a valid issue |
| `wontfix` | Issues that will not be addressed |

## Issue and PR Conventions

- Bug reports should include: description (actual vs expected behavior), reproduction steps, environment info, and relevant logs. See the issue templates in `.github/ISSUE_TEMPLATE/`.
- Feature requests should include a problem statement and proposed design.
- PRs must follow the conventional commit format for titles, include a summary and testing info. See `.github/PULL_REQUEST_TEMPLATE.md`.
- Skills that create issues or PRs (`create-github-issue`, `create-github-pr`) produce output conforming to these templates.

## Security

- Never commit secrets, API keys, or credentials. Do not stage files that look like they contain secrets (`.env`, `credentials.json`, etc.).
- Do not run destructive operations (force push, hard reset) without explicit human confirmation.
- Security vulnerabilities should be reported responsibly, not as public GitHub issues.
- Socktainer listens on a Unix domain socket and is intended for local development use only.
