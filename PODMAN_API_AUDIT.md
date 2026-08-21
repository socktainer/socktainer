# Podman CLI (remote socket) API coverage audit

Scope: what the `podman` CLI needs from a remote unix socket (`CONTAINER_HOST` set,
no podman machine involved — that layer is entirely client-side VM provisioning
and never touches the wire once a socket connection exists). Paths verified
against `github.com/containers/podman` `pkg/api/server/register_*.go`
(canonical route registration) where fetched; the rest match the long-stable
libpod API v4/v5 convention (`/libpod/<resource>/...`).

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
| `podman top` | GET `/libpod/containers/{id}/top` | ✅ |
| `podman rename` | POST `/libpod/containers/{id}/rename` | ✅ |
| `podman wait` | POST `/libpod/containers/{id}/wait` | ✅ |
| `podman attach` | POST `/libpod/containers/{id}/attach` | ✅ |
| `podman exec` (create+start) | POST `/libpod/containers/{id}/exec`, `/libpod/exec/{id}/start`, GET `/libpod/exec/{id}/json` | ✅ |
| `podman stats` | GET `/libpod/containers/{name}/stats` (per-container) | ✅ (all-container `/libpod/containers/stats` variant still missing) |
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
| `podman rmi` | DELETE `/libpod/images/{name}` | ✅ |
| `podman inspect` (image) | GET `/libpod/images/{name}/json` | ✅ |
| `podman tag` | POST `/libpod/images/{name}/tag` | ✅ |
| `podman build` | POST `/libpod/build` | ✅ |
| `podman push` | POST `/libpod/images/{name}/push` | ✅ |
| `podman search` | GET `/libpod/images/search` | ✅ |
| `podman history` | GET `/libpod/images/{name}/history` | ✅ |
| `podman image prune` | POST `/libpod/images/prune` (confirmed in podman source) | ✅ |
| `podman save` | GET `/libpod/images/{name}/get` (single) or `/libpod/images/get?names=...` (multi) | ✅ |
| `podman load` | POST `/libpod/local/images/load` (confirmed in podman source — note: NOT `/libpod/images/load`) | ✅ |
| `podman import` | POST `/libpod/images/import` (confirmed in podman source: query params are `reference`/`message`/`changes`/`url`, not Docker's `repo`/`tag`/`fromSrc`) | ✅ (translates libpod's `reference` query param into Docker's `repo`/`tag`/`fromSrc=-` shape, then delegates; `url`-based remote import still rejected, same limitation as the Docker-side route) |

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

Real podman's actual multi-arch workflow (confirmed against
[containers/podman#27211](https://github.com/containers/podman/issues/27211)):
invoked bare (no `--manifest` flag), `podman build --platform a,b,c -t foo .`
only builds a **single** architecture regardless of how many comma-separated
`--platform` values are passed — the client never asks the server for a
multi-arch result unless `--manifest <name>` is given. The only real
multi-arch path in podman is `--platform a,b --manifest name`. A Docker-compat
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
| `podman manifest exists` | GET `/libpod/manifests/{name}/exists` | ✅ |
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
- All-container `/libpod/containers/stats` (no name): the per-container
  `/libpod/containers/{name}/stats` above is real podman server behavior
  (confirmed: podman's own route registration uses the Docker-compat handler
  for that deprecated per-container path). The all-container variant is
  genuinely different — it uses libpod's own `ContainerStats` schema
  (`CPU`/`MemPerc`/`UpTime` as pre-computed values, not raw counters podman
  computes percentages from) which needs host-CPU-time accounting and
  container start-time tracking this codebase doesn't currently have.
  Deliberately not implemented with fabricated/approximated values for those
  fields — flagging as a real gap rather than shipping a wrong-looking-right
  response.

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
2. Remaining low priority: `podman untag`, `podman manifest annotate`,
   all-container `/libpod/containers/stats`.
