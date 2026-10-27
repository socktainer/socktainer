# Podman CLI (remote socket) API coverage audit

Scope: what the `podman` CLI needs from a remote unix socket (`CONTAINER_HOST` set,
no podman machine involved — that layer is entirely client-side VM provisioning
and never touches the wire once a socket connection exists). Paths verified
against `github.com/podman-container-tools/podman` `pkg/api/server/register_*.go`
(canonical route registration) where fetched; the rest match the long-stable
libpod API v4/v5 convention (`/libpod/<resource>/...`).

## What "✅" means here

A ✅ means the route is registered **and** a real `podman` 6.1.4 client (`CONTAINER_HOST` set,
`podman --remote`) completed the command against a running socktainer with real data present — an
empty store is not enough, since most decode failures only show once a list has an entry. The
libpod API reuses Docker-compat's semantics but not its wire shapes (prune and delete answer
report arrays, `wait` a bare integer, lists drop Docker's envelopes, create takes podman's whole
`SpecGenerator`, and some parameters are renamed), so each route runs the Docker-compat handler and
translates the request and response in `Routes/Libpod/LibpodAdapter.swift` / `LibpodSchema.swift`.
Routes that only wrap a Docker-compat route which is itself unimplemented say so in their row.

Verified on macOS 26.6.2 with Apple Container 1.6.0 (matching this build) and `podman` 6.1.4:
about 230 `podman` commands across handshake, images, volumes, networks, containers (lifecycle,
exec, logs, stats, cp, filters, formats, error mapping, ~40 `run` flags), `build` (single and
multi-platform, Rosetta and QEMU builders), push to a local registry, and manifest lists.

Limits that Docker-compat shares (libpod mirrors Docker-compat's support, it does not go beyond it):

- **Attach never closes the connection.** For a stopped container with output-only attach (what
  `podman run` without `-i` uses) the route answers `101` with a body stream and leaves the TCP
  connection open after the container exits. The Docker CLI tolerates that; `podman run` (attached)
  and `podman start -a` wait for EOF and do not return. `podman run -d`, `start`, `exec`, `logs`,
  `wait` and `stop` all work. Fixing it means closing the upgraded channel in
  `ContainerAttachRoute.attachStoppedOutputOnly`.
- `podman events --since/--until`: Docker-compat's events route ignores both, so `--until` never ends.
- `podman build -q` hangs (the Docker-compat `?q=1` build hangs the same way).
- A never-started container reports `exited` (not `created`), so `ps --filter status=created` is empty.
- `network rm` of a missing network answers 500 instead of 404.
- `podman logs --since/--until`: Docker-compat's logs route ignores both.
- `podman stop`/`restart` without `--time` waits 5 seconds (podman and Docker default to 10).
- Container inspect `Image` carries the image reference, not the image ID.
- `container prune --filter label!=x` is rejected with 400 (the Docker-compat prune has no negative
  label filter).
- `network rm -f` and `volume rm -f` do not remove the containers using them; Docker-compat's force
  has no such cleanup.
- `podman update --env/--unset-env` and `podman volume create --uid/--gid` are refused (400): the
  backend has no way to apply them.
- `top`, `commit`, `diff`, `pause`/`unpause` and `manifest annotate` are not implemented (Docker-compat
  has no implementation either); `rename` only works before the first start.
- `podman save` fails with "ContentStore missing blob data", an Apple Container image-store limitation.
- `podman cp` out of a container to a host path under `/tmp` fails inside the podman client on macOS
  (`/tmp` is a symlink to `/private/tmp`); copying to a real directory works.

Currently registered in this repo: `Sources/socktainer/configure.swift`
("Podman libpod routes" section) + `Sources/socktainer/Routes/Libpod/*.swift`.

## Ping / handshake (critical path — CLI probes this before anything else)

| Path | Method | Implemented |
|---|---|---|
| `/libpod/_ping` | GET, HEAD | ✅ `LibpodPingRoute` |
| `/libpod/version` | GET | ✅ `LibpodVersionRoute` |
| `/libpod/info` | GET | ✅ `LibpodInfoRoute` |

## Containers

| Command | Method + Path | Implemented |
|---|---|---|
| `podman ps` / `ps -a` | GET `/libpod/containers/json` | ✅ |
| `podman create` | POST `/libpod/containers/create` | ✅ |
| `podman start` | POST `/libpod/containers/{id}/start` | ✅ |
| `podman stop` | POST `/libpod/containers/{id}/stop` | ✅ |
| `podman kill` | POST `/libpod/containers/{id}/kill` | ✅ |
| `podman restart` | POST `/libpod/containers/{id}/restart` | ✅ |
| `podman rm` | DELETE `/libpod/containers/{id}` | ✅ |
| `podman inspect` (container) | GET `/libpod/containers/{id}/json` | ✅ |
| `podman logs` | GET `/libpod/containers/{id}/logs` | ✅ |
| `podman top` | GET `/libpod/containers/{id}/top` | ✅ (wraps `ContainerTopRoute`, which itself returns "not implemented") |
| `podman rename` | POST `/libpod/containers/{id}/rename` | ✅ (only containers that have never been started, as Docker-compat) |
| `podman wait` | POST `/libpod/containers/{id}/wait` | ✅ |
| `podman attach` | POST `/libpod/containers/{id}/attach` | ✅ |
| `podman exec` (create+start) | POST `/libpod/containers/{id}/exec`, `/libpod/exec/{id}/start`, GET `/libpod/exec/{id}/json`, POST `/libpod/exec/{id}/remove` | ✅ |
| `podman stats` | GET `/libpod/containers/stats` (batch, what the CLI calls) and `/libpod/containers/{name}/stats` | ✅ |
| `podman pause` | POST `/libpod/containers/{name}/pause` | ✅ (wraps `ContainerPauseRoute`, which itself returns "not supported" — Apple Container has no pause primitive) |
| `podman unpause` | POST `/libpod/containers/{name}/unpause` | ✅ (same caveat as pause) |
| `podman container prune` | POST `/libpod/containers/prune` | ✅ |
| `podman update` | POST `/libpod/containers/{name}/update` | ✅ |
| `podman commit` | POST `/libpod/commit` | ✅ (wraps `CommitRoute`, which itself returns "not implemented") |
| `podman export` | GET `/libpod/containers/{name}/export` | ✅ |
| `podman diff` | GET `/libpod/containers/{name}/changes` | ✅ (wraps `ContainerChangesRoute`, which itself returns "not implemented") |
| `podman healthcheck run` | GET `/libpod/containers/{name}/healthcheck` (libpod-only, no Docker-compat equivalent) | ❌ still missing (no Docker-side route to wrap) |
| `podman cp` | GET/HEAD/PUT `/libpod/containers/{name}/archive` | ✅ |

## Images

| Command | Method + Path | Implemented |
|---|---|---|
| `podman images` | GET `/libpod/images/json` | ✅ |
| `podman pull` | POST `/libpod/images/pull` | ✅ |
| `podman rmi` | DELETE `/libpod/images/remove?images=…` (batch) and `/libpod/images/{name}` | ✅ |
| `podman inspect` (image) | GET `/libpod/images/{name}/json` | ✅ |
| `podman tag` | POST `/libpod/images/{name}/tag` | ✅ |
| `podman build` | POST `/libpod/build` | ✅ |
| `podman push` | POST `/libpod/images/{name}/push` | ✅ |
| `podman search` | GET `/libpod/images/search` | ✅ |
| `podman history` | GET `/libpod/images/{name}/history` | ✅ |
| `podman image prune` | POST `/libpod/images/prune` (confirmed in podman source) | ✅ |
| `podman save` | GET `/libpod/images/{name}/get` (single) or `/libpod/images/export?references=...` (multi) | ⚠️ route registered; real `podman save` currently fails with "ContentStore missing blob data" (see limits above) |
| `podman load` | POST `/libpod/local/images/load` (confirmed in podman source — note: NOT `/libpod/images/load`) | ✅ |
| `podman import` | POST `/libpod/images/import` (confirmed in podman source: query params are `reference`/`message`/`changes`/`url`, not Docker's `repo`/`tag`/`fromSrc`) | ✅ (decodes `reference` and calls the image client's import directly, answering with podman's single `{"Id": <digest>}` object instead of Docker's progress stream; `url`-based remote import still rejected, same limitation as the Docker-side route) |

## Volumes

| Command | Method + Path | Implemented |
|---|---|---|
| `podman volume ls` | GET `/libpod/volumes/json` | ✅ |
| `podman volume create` | POST `/libpod/volumes/create` | ✅ |
| `podman volume rm` | DELETE `/libpod/volumes/{name}` | ✅ |
| `podman volume inspect` | GET `/libpod/volumes/{name}/json` | ✅ |
| `podman volume prune` | POST `/libpod/volumes/prune` | ✅ |

## Networks

| Command | Method + Path | Implemented |
|---|---|---|
| `podman network ls` | GET `/libpod/networks/json` | ✅ |
| `podman network create` | POST `/libpod/networks/create` | ✅ |
| `podman network rm` | DELETE `/libpod/networks/{name}` | ✅ |
| `podman network inspect` | GET `/libpod/networks/{name}/json` | ✅ |
| `podman network prune` | POST `/libpod/networks/prune` | ✅ |
| `podman network connect` | POST `/libpod/networks/{name}/connect` | ✅ (no-op parity response, same as Docker-side route) |
| `podman network disconnect` | POST `/libpod/networks/{name}/disconnect` | ✅ (no-op parity response, same as Docker-side route) |

## System

| Command | Method + Path | Implemented |
|---|---|---|
| `podman system df` | GET `/libpod/system/df` | ✅ |
| `podman events` | GET `/libpod/events` | ✅ |
| `podman login` (auth check) | POST `/libpod/auth` | ✅ |

## Manifest lists (multi-arch)

Real podman's actual multi-arch **build** workflow (confirmed against
[podman-container-tools/podman#27211](https://github.com/podman-container-tools/podman/issues/27211)):
invoked bare (no `--manifest` flag), `podman build --platform a,b,c -t foo .`
only builds a **single** architecture regardless of how many comma-separated
`--platform` values are passed — the client never asks the server for a
multi-arch result unless `--manifest <name>` is given. The only real
multi-arch path for the `build` command specifically is `--platform a,b
--manifest name`; `podman manifest create`/`add` are a separate, always-multi-
arch-capable path that doesn't go through `build` at all. A Docker-compat
client hitting `/build?platform=a,b,c` directly is a separate case: that
endpoint does assemble a multi-platform manifest list from a comma-separated
`platform` value, matching Docker's own API contract rather than podman's.

Implemented as a `ClientManifestService` modeling a manifest list as an
ordinary tagged reference whose descriptor points at an OCI image index blob
— no separate bookkeeping layer; "the current members of `name`" is always
just "decode whatever index `name` currently points at." Built on two
existing Apple Containerization framework primitives this codebase's own
`load`/`import` code already relies on: a second `ImageStore(path:)` instance
over the daemon's own Application Support directory, and `ContentStore.ingest`
to write new index blobs (via `ContentWriter.write`, which computes the
correct SHA256 filename — `completeIngestSession` trusts the filename
verbatim with no hashing of its own, so getting this right matters).

`resolvedPushPlatform`'s single-available-platform narrowing (used by
ordinary image push) would silently defeat an explicit "push the whole list"
request, so manifest-list push goes through a dedicated `pushManifestList`
that always pushes `platform: nil` instead. Pushing to a different
destination reference needs a re-tag first, since the framework's push always
pushes to the same reference it resolves from (`retagForPush`).

Known limitation: `ImageStore`'s reference table (`state.json`) is a plain
load-entire-map → overwrite-entire-map with no file lock, shared with the
separate `container-apiserver` process — the real contention is cross-process,
which no in-process lock added here would fix. This is the same risk profile
the existing `load`/`import` code already accepts; ingest and create are kept
back-to-back to narrow, not close, the window.

| Command | Method + Path | Implemented |
|---|---|---|
| `podman manifest create` | POST `/libpod/manifests/{name}` | ✅ |
| `podman manifest inspect` | GET `/libpod/manifests/{name}/json` | ✅ |
| `podman manifest exists` | GET `/libpod/manifests/{name}/exists` | ✅ (only lists made by `manifest create`/`add` or `build --manifest` count; an ordinary image is not a manifest list, as in podman) |
| `podman manifest add` | PUT `/libpod/manifests/{name}` (`operation: "update"`) | ✅ |
| `podman manifest remove` | PUT `/libpod/manifests/{name}` (`operation: "remove"`) | ✅ |
| `podman manifest rm` | DELETE `/libpod/manifests/{name}` | ✅ |
| `podman manifest annotate` | PUT `/libpod/manifests/{name}` (`operation: "annotate"`) | ❌ not implemented (index-level annotations only, rarely used) |
| `podman manifest push` | POST `/libpod/manifests/{name}/registry/{destination}` (v4+) and legacy POST `/libpod/manifests/{name}/push?destination=` | ✅ (both forms) |
| `podman build --manifest <name>` | server-side: build all requested platforms and register the result under a named, addressable manifest list | ✅ |

## Not applicable / intentionally out of scope

- `podman pod *`, `podman generate kube`, `podman play kube` — Apple Container
  has no pod primitive; skip unless a future need surfaces.
- `podman machine *` — client-side only, never reaches the socket. Confirmed
  out of scope per the ask.
- `podman unshare`, `podman system connection *`, `podman completion` — purely
  client-side (namespace tricks / connection-list bookkeeping / shell
  completions), never hit the socket at all.
- checkpoint/restore — niche, CRIU-based, not applicable to the Apple
  Container VM backend.
- `podman secret *` — Swarm-style secret store; low value without a broader
  secrets/Swarm story, and no evidence it's used against a non-Swarm-mode
  daemon.

## Minor / low-priority gaps

- `{resource}/exists` endpoints: `/libpod/containers/{name}/exists`,
  `/libpod/images/{name}/exists`, `/libpod/volumes/{name}/exists`,
  `/libpod/networks/{name}/exists` all return 204 (exists) or 404 (not found).
- `podman untag` — likely handled by the same `/libpod/images/{name}/tag`
  machinery in reverse or a dedicated untag call; low priority, rarely used.
- `podman generate systemd` — out of scope (systemd unit generation is a
  Linux-host concept, not meaningful under Apple Container).
- `/libpod/containers/stats` reports `UpTime` as 0: each sample comes from the
  Docker-compat stats handler, which carries no container uptime. The other
  fields (`CPU`, `MemPerc`, ...) are computed from those samples the way
  podman's client does.

## Top gaps worth implementing next (priority order)

1. **`podman healthcheck run`** — the one genuine blocker. Unlike
   every other gap in this doc, there is no existing Docker-side route to
   delegate to: real `podman healthcheck run <container>` executes the
   container's configured healthcheck test command right now and reports
   the result, whereas `HealthCheckManager` (`Sources/socktainer/Utilities/HealthCheckManager.swift`)
   only exposes `start`/`stop`/`currentHealth(for:)` — a background poll loop
   and its last cached result, not an on-demand single run. Implementing
   this properly needs new exec-based invocation logic (parse the
   container's `HealthcheckConfig.test`, run it via the container-exec path
   with the configured timeout, map the exit code to Healthy/Unhealthy, and
   shape the response per libpod's `HealthcheckRunResult` schema) — real
   feature work, not a route wrapper. Flagging rather than half-implementing
   it as "just return `currentHealth`", which would silently diverge from
   what `podman healthcheck run` actually means (a fresh probe, not a cached
   status read).
2. Remaining low priority: `podman untag`, `podman manifest annotate`.
