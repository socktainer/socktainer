import ContainerAPIClient
import ContainerPersistence
import Containerization
import ContainerizationError
import ContainerizationOCI
import Crypto
import Foundation
import Logging

enum ClientManifestError: Error {
    case notFound(name: String)
    case alreadyExists(name: String)
}

struct RetagState: Sendable {
    let reference: String
    let priorDescriptor: Descriptor?
}

/// Backs the `podman manifest` command family, `podman build --manifest`, and manifest-aware
/// push (`podman push <image> <destination>` / `podman manifest push`). Routes depend on this
/// protocol rather than `ClientManifestService` directly so tests can inject a mock instead of a
/// real `ImageStore`/XPC-backed instance — see the `Mock...` types alongside each route's tests.
protocol ClientManifestServiceProtocol: Sendable {
    func exists(name: String) async throws -> Bool
    func digest(for name: String) async throws -> String
    func inspect(name: String) async throws -> Index
    @discardableResult
    func create(name: String, images: [String], logger: Logger, amend: Bool) async throws -> String
    @discardableResult
    func mergeAndTag(name: String, images: [String], logger: Logger) async throws -> String
    @discardableResult
    func add(name: String, images: [String], logger: Logger) async throws -> String
    @discardableResult
    func removeDigest(name: String, digest: String) async throws -> String
    @discardableResult
    func removeDigests(name: String, digests: [String]) async throws -> String
    @discardableResult
    func addBuiltImage(name: String, builtReference: String, logger: Logger) async throws -> String
    func delete(name: String) async throws
    func retagForPush(name: String, destination: String) async throws -> (reference: String, priorState: RetagState?)
    func untagPushDestination(_ state: RetagState) async throws
}

/// Backs the `podman manifest` command family and `podman build --manifest`.
///
/// A manifest list is modeled as an ordinary tagged reference whose descriptor
/// points at an OCI image index blob — there is no separate bookkeeping layer.
/// "The current members of `name`" is always just "decode whatever index `name`
/// currently points at" (`image.index().manifests`); create/add/remove all work
/// by writing a new index blob and re-pointing the tag at it.
///
/// This reuses the same two framework entry points `ClientImageService.load`
/// already relies on for `docker load`/`import`: a fresh `ImageStore(path:)` over
/// the daemon's own Application Support directory, and a `LocalContentStore` at
/// its `content` subdirectory for writing new blobs. Both are just files on disk
/// under a path convention the framework itself uses internally, so a second,
/// independent instance of each sees exactly what the daemon's own copy does.
///
/// Known limitation: `ImageStore`'s reference table (`state.json`) is a plain
/// load-entire-map → mutate → overwrite-entire-map with no file lock, and no
/// in-process lock added here would close that — the real contention is with
/// the separate `container-apiserver` process writing the same file, not with
/// concurrent requests inside this daemon. This is the same risk profile the
/// existing `load`/`import` code already accepts; a real fix needs an flock on
/// `state.json`, which the framework does not expose. The ingest-then-create
/// pair below is kept back-to-back (no other `await` in between) to narrow, not
/// close, the window where a freshly-written index blob is momentarily
/// unreferenced and could theoretically be swept by a concurrent
/// `cleanUpOrphanedBlobs()` (fired elsewhere in this codebase after every image
/// delete).
struct ClientManifestService: ClientManifestServiceProtocol {
    let appSupportURL: URL
    let containerSystemConfig: ContainerSystemConfig

    private static let leafManifestMediaTypes: Set<String> = [
        MediaTypes.imageManifest,
        MediaTypes.dockerManifest,
    ]

    private func imageStore() throws -> ImageStore {
        try ImageStore(path: appSupportURL)
    }

    private func contentStore() throws -> LocalContentStore {
        try LocalContentStore(path: appSupportURL.appendingPathComponent("content"))
    }

    func exists(name: String) async throws -> Bool {
        do {
            // See `leafDescriptors`: pass the raw name so `ClientImage.get`'s own
            // raw/normalized fallback isn't collapsed into two identical attempts.
            let image = try await ClientImage.get(reference: name, containerSystemConfig: containerSystemConfig)
            return image.descriptor.mediaType == MediaTypes.index || image.descriptor.mediaType == MediaTypes.dockerManifestList
        } catch let error as ContainerizationError where error.code == .notFound {
            return false
        }
    }

    /// Resolves `name`'s current index digest — used as the `Id` of the final completion
    /// frame `manifest push` writes; real podman's client requires seeing one before it
    /// accepts a clean stream close as success (see `DockerProgressFrame.manifestPushId`).
    func digest(for name: String) async throws -> String {
        do {
            return try await ClientImage.get(reference: name, containerSystemConfig: containerSystemConfig).digest
        } catch let error as ContainerizationError where error.code == .notFound {
            throw ClientManifestError.notFound(name: name)
        }
    }

    func inspect(name: String) async throws -> Index {
        let image: ClientImage
        do {
            image = try await ClientImage.get(reference: name, containerSystemConfig: containerSystemConfig)
        } catch let error as ContainerizationError where error.code == .notFound {
            throw ClientManifestError.notFound(name: name)
        }
        return try await image.index()
    }

    /// `podman manifest create <name> [images...]`. Real podman errors on a duplicate `name`
    /// unless `--amend` is given (confirmed against `ManifestCreate` in
    /// `pkg/domain/infra/abi/manifest.go`: `CreateManifestList` returning
    /// `storage.ErrDuplicateName` is only tolerated when `opts.Amend` is set) — `--amend` then
    /// looks up the existing list and adds to it, it does not replace its contents. This
    /// previously always overwrote unconditionally regardless of `amend`, which matched
    /// neither of real podman's two actual behaviors.
    @discardableResult
    func create(name: String, images: [String], logger: Logger, amend: Bool) async throws -> String {
        if try await referenceExists(name: name) {
            guard amend else {
                throw ClientManifestError.alreadyExists(name: name)
            }
            // `add` would happily append new members to ANY index-rooted reference, but
            // `--amend` specifically means "update this existing MANIFEST LIST" — silently
            // amending an ordinary single-platform image (which also happens to be
            // index-rooted, per this framework's own tagging convention) would convert it
            // into a multi-platform list the caller never asked for.
            guard try await exists(name: name) else {
                throw ContainerizationError(.invalidArgument, message: "\(name) exists but is not a manifest list")
            }
            return try await add(name: name, images: images, logger: logger)
        }
        return try await mergeAndTag(name: name, images: images, logger: logger)
    }

    /// Broader than `exists(name:)` (which is specifically "is `name` a manifest list," for
    /// `podman manifest exists`) — this is `create`'s own duplicate-name check, which must
    /// also catch an ORDINARY single-platform image already tagged `name`: real podman's
    /// underlying storage layer rejects a duplicate name regardless of what kind of content
    /// it already holds, and `exists(name:)` alone would miss that case (a non-index
    /// descriptor doesn't match its media-type check), letting `mergeAndTag` silently
    /// overwrite an unrelated existing image.
    private func referenceExists(name: String) async throws -> Bool {
        do {
            _ = try await ClientImage.get(reference: name, containerSystemConfig: containerSystemConfig)
            return true
        } catch let error as ContainerizationError where error.code == .notFound {
            return false
        }
    }

    /// Builds a fresh index from `images`' leaf manifests and tags `name` to point at it,
    /// unconditionally — no existing-name check, unlike `create`. Used internally by
    /// `BuildRoute`'s Rosetta/QEMU split build to merge the two partial builds' output into
    /// the originally-requested tag: that's "replace whatever this tag pointed at," the same
    /// semantics as an ordinary `docker build -t foo` re-using an existing tag, not
    /// `podman manifest create`'s duplicate-name handling.
    @discardableResult
    func mergeAndTag(name: String, images: [String], logger: Logger) async throws -> String {
        var manifests: [Descriptor] = []
        var seenDigests = Set<String>()
        for ref in images {
            for descriptor in try await leafDescriptors(for: ref, logger: logger) where seenDigests.insert(descriptor.digest).inserted {
                manifests.append(descriptor)
            }
        }
        return try await writeIndexAndTag(name: name, manifests: manifests)
    }

    /// `podman manifest add <name> <image>` / the "update" operation of `PUT /libpod/manifests/{name}`.
    @discardableResult
    func add(name: String, images: [String], logger: Logger) async throws -> String {
        var manifests = try await existingManifestsOrEmpty(name: name)
        var seenDigests = Set(manifests.map(\.digest))
        for ref in images {
            for descriptor in try await leafDescriptors(for: ref, logger: logger) where seenDigests.insert(descriptor.digest).inserted {
                manifests.append(descriptor)
            }
        }
        return try await writeIndexAndTag(name: name, manifests: manifests)
    }

    /// `podman manifest remove <name> <digest>` / the "remove" operation of `PUT /libpod/manifests/{name}`.
    @discardableResult
    func removeDigest(name: String, digest: String) async throws -> String {
        var manifests = try await inspect(name: name).manifests
        // A bare hex digest (no algorithm prefix) is assumed sha256, matching real podman's
        // own convention — but a digest already carrying a DIFFERENT algorithm's prefix
        // (e.g. `sha512:...`) must not be blindly re-prefixed into `sha256:sha512:...`, a
        // malformed digest that could never match a real member and would silently succeed as
        // "not found" instead of surfacing the actual problem (an unsupported algorithm).
        let normalizedDigest: String
        if digest.hasPrefix("sha256:") {
            normalizedDigest = digest
        } else if digest.contains(":") {
            throw ContainerizationError(.invalidArgument, message: "\(digest) is not a supported digest (only sha256 is)")
        } else {
            normalizedDigest = "sha256:\(digest)"
        }
        let countBefore = manifests.count
        manifests.removeAll { $0.digest == normalizedDigest }
        guard manifests.count < countBefore else {
            throw ContainerizationError(.invalidArgument, message: "\(normalizedDigest) is not a member of \(name)")
        }
        return try await writeIndexAndTag(name: name, manifests: manifests)
    }

    /// The "remove" operation of `PUT /libpod/manifests/{name}` when it carries more than one
    /// digest — removes every requested digest via a SINGLE read-modify-write instead of one
    /// `removeDigest` call per digest, which would re-`inspect`/re-tag `name` once per digest
    /// and leave a window between each pair of removals where a concurrent request could see
    /// (or race against) a partially-modified list.
    @discardableResult
    func removeDigests(name: String, digests: [String]) async throws -> String {
        var manifests = try await inspect(name: name).manifests
        let currentDigests = Set(manifests.map(\.digest))
        let digestSet = Set(digests)
        guard digestSet.isSubset(of: currentDigests) else {
            let missing = digestSet.subtracting(currentDigests)
            throw ContainerizationError(.invalidArgument, message: "\(missing.sorted().joined(separator: ", ")) not a member of \(name)")
        }
        manifests.removeAll { digestSet.contains($0.digest) }
        return try await writeIndexAndTag(name: name, manifests: manifests)
    }

    /// Called from `build --manifest <name>` after a multi-platform build has already produced and
    /// tagged its own index at `builtReference`. Merges into `name`'s existing index if present
    /// (union by digest, matching real podman's "creates a manifest list if it does not exist"
    /// semantics for the build flag), otherwise just tags the freshly-built index directly.
    @discardableResult
    func addBuiltImage(name: String, builtReference: String, logger: Logger) async throws -> String {
        var manifests = try await existingManifestsOrEmpty(name: name)
        var seenDigests = Set(manifests.map(\.digest))
        let newDescriptors = try await leafDescriptors(for: builtReference, logger: logger)
        manifests.append(contentsOf: newDescriptors.filter { seenDigests.insert($0.digest).inserted })
        return try await writeIndexAndTag(name: name, manifests: manifests)
    }

    /// Shared by `add`/`addBuiltImage`: an absent manifest list starts from an empty index (matching
    /// real podman's "creates a manifest list if it does not exist" semantics), but any other
    /// failure (a corrupt/undecodable existing index, a storage I/O error, etc.) must propagate —
    /// silently treating those the same as "doesn't exist yet" would let a transient read failure
    /// clobber a real, valid manifest list with a fresh, near-empty one.
    private func existingManifestsOrEmpty(name: String) async throws -> [Descriptor] {
        do {
            return try await inspect(name: name).manifests
        } catch ClientManifestError.notFound {
            return []
        }
    }

    /// `podman manifest rm <name>` — deletes the whole tag, not a single member.
    func delete(name: String) async throws {
        // See `leafDescriptors`/`exists`/`retagForPush`: resolve via `ClientImage.get` (its
        // raw/normalized fallback search) first rather than deleting a re-normalized guess.
        // `imageStore().delete`'s own reference lookup is an exact string match against
        // however the reference was ACTUALLY stored, which for a bare-tagged reference
        // (e.g. a locally-built image, or a build-split scratch tag with no registry/library
        // prefix) differs from its normalized form — deleting the normalized guess silently
        // no-ops instead of removing the real entry.
        let image: ClientImage
        do {
            image = try await ClientImage.get(reference: name, containerSystemConfig: containerSystemConfig)
        } catch let error as ContainerizationError where error.code == .notFound {
            throw ClientManifestError.notFound(name: name)
        }
        // `performCleanup: false` explicitly (its own default, but stated here the same way
        // `LiveImageDeletionStore` does for `ClientImage.delete`) — this reference's blobs may
        // still be referenced by another tag (e.g. after a `mergeAndTag` merge), so this must
        // never sweep content, only remove the tag itself.
        try await imageStore().delete(reference: image.reference, performCleanup: false)
    }

    /// `podman manifest push <name> <destination>`. Apple's `ImageStore.push`/`ClientImage.push`
    /// always push to the same reference they resolve from — there is no separate
    /// local-name-vs-remote-destination split in that primitive. When `destination` differs from
    /// `name`, re-tag the local index under `destination` first (a fast, local, metadata-only
    /// operation) so the subsequent network push — which must go through the real daemon's
    /// `ImagesService` via `ClientImage.push`, since only it implements registry communication —
    /// resolves and pushes the right content.
    ///
    /// Returns the reference to push and, when a tag change actually happened, what `destination`
    /// pointed at beforehand (`nil` if it didn't exist). The caller MUST restore that prior state
    /// once the push finishes (success or failure) via `untagPushDestination` — otherwise a
    /// pre-existing `destination` tag gets permanently clobbered, or (if it didn't exist before) a
    /// stray tag leaks into image listings and outlives the single push it existed for.
    /// `performCleanup` stays `false` throughout since the underlying index blob is still
    /// referenced by `name`'s own tag.
    func retagForPush(name: String, destination: String) async throws -> (reference: String, priorState: RetagState?) {
        // Resolve to the reference as ACTUALLY stored: `ImageStore.tag`'s own lookup
        // (`ReferenceManager.get`) is an exact string match against the stored reference,
        // with none of `ClientImage.get`'s `_search` raw/normalized fallback — reconstructing
        // a normalized guess here instead of resolving first would silently fail to match an
        // image tagged bare by the builder/loader (`<name>:latest`, no registry/library prefix).
        let existingImage: ClientImage
        do {
            existingImage = try await ClientImage.get(reference: name, containerSystemConfig: containerSystemConfig)
        } catch let error as ContainerizationError where error.code == .notFound {
            throw ClientImageError.notFound(id: name)
        }
        let storedName = existingImage.reference
        let normalizedDestination = try ClientImage.normalizeReference(destination, containerSystemConfig: containerSystemConfig)
        guard normalizedDestination != storedName else {
            return (storedName, nil)
        }

        let priorDescriptor: Descriptor?
        do {
            // Same reasoning as `leafDescriptors`/`exists`: raw, not pre-normalized. But
            // `_search`'s raw-or-normalized fallback means this can resolve to some OTHER
            // stored reference than `normalizedDestination` (e.g. an unrelated image
            // already tagged bare under the same raw string) — that isn't what
            // `imageStore().tag` below is about to overwrite, so it isn't real "prior
            // state" for `normalizedDestination` and must not be captured for restore.
            let existing = try await ClientImage.get(reference: destination, containerSystemConfig: containerSystemConfig)
            priorDescriptor = existing.reference == normalizedDestination ? existing.descriptor : nil
        } catch let error as ContainerizationError where error.code == .notFound {
            priorDescriptor = nil
        }

        _ = try await imageStore().tag(existing: storedName, new: normalizedDestination)
        return (normalizedDestination, RetagState(reference: normalizedDestination, priorDescriptor: priorDescriptor))
    }

    /// Undoes a re-tag created by `retagForPush`: restores what `destination` pointed at before
    /// (if anything), or removes the tag entirely if it didn't exist beforehand. Caller's
    /// responsibility to call this once the push has finished, success or failure.
    func untagPushDestination(_ state: RetagState) async throws {
        if let priorDescriptor = state.priorDescriptor {
            try await imageStore().create(description: Image.Description(reference: state.reference, descriptor: priorDescriptor))
        } else {
            // `performCleanup: false` — see `delete(name:)`'s own comment on the same call.
            try await imageStore().delete(reference: state.reference, performCleanup: false)
        }
    }

    /// Resolves `ref` to the leaf (non-index) manifest descriptors it contributes. Adding a
    /// reference that is itself multi-platform expands to all of its platform members — this is
    /// also what keeps every stored member a leaf manifest rather than a nested index: nested
    /// indexes are invisible to `Image.referencedDigests()`'s GC accounting (it decodes each
    /// member as a `Manifest`, silently skipping anything that isn't one), so their own children
    /// would never be protected from `cleanUpOrphanedBlobs()`.
    private func leafDescriptors(for ref: String, logger: Logger) async throws -> [Descriptor] {
        // `ClientImage.get` (via `_search`) already tries both `ref` as given and its
        // normalized form against each stored image's reference — pre-normalizing here
        // and passing only that would collapse both attempts into the same string,
        // missing images tagged verbatim without a registry/library prefix (e.g. a
        // just-built image from `build --manifest`, which `ClientImage.load` tags as
        // `<uuid>:latest`, not `docker.io/library/<uuid>:latest`).
        let normalized = try ClientImage.normalizeReference(ref, containerSystemConfig: containerSystemConfig)
        let image: ClientImage
        do {
            image = try await ClientImage.get(reference: ref, containerSystemConfig: containerSystemConfig)
        } catch let error as ContainerizationError where error.code == .notFound {
            throw ClientImageError.notFound(id: normalized)
        }
        let index = try await image.index()
        let descriptors = index.manifests.filter { descriptor in
            guard descriptor.annotations?["vnd.docker.reference.type"] != "attestation-manifest" else { return false }
            guard Self.leafManifestMediaTypes.contains(descriptor.mediaType) else {
                logger.warning("Skipping non-leaf manifest member \(descriptor.digest) (mediaType \(descriptor.mediaType)) from \(normalized)")
                return false
            }
            return true
        }
        guard !descriptors.isEmpty else {
            throw ContainerizationError(.invalidArgument, message: "\(ref) has no leaf manifests to add")
        }
        return descriptors
    }

    /// Writes a new OCI index blob and (re)tags `name` to point at it. Ingest and create are kept
    /// adjacent (no other `await` in between) to minimize, not eliminate, the window described in
    /// this type's doc comment.
    @discardableResult
    private func writeIndexAndTag(name: String, manifests: [Descriptor]) async throws -> String {
        let normalized = try ClientImage.normalizeReference(name, containerSystemConfig: containerSystemConfig)
        let index = Index(manifests: manifests)
        let data = try JSONEncoder().encode(index)

        // Computed independently rather than captured from inside the ingest closure
        // (which is @Sendable — mutating a captured var across it isn't allowed).
        // Matches exactly what ContentWriter.write does internally, so the digest
        // here is the same one the file ends up named by.
        let digest = SHA256.hash(data: data)
        let descriptor = Descriptor(mediaType: MediaTypes.index, digest: digest.digestString, size: Int64(data.count))

        let store = try contentStore()
        _ = try await store.ingest { tempDir in
            let writer = try ContentWriter(for: tempDir)
            try writer.write(data)
        }

        // No await between ingest completing and create tagging it — this adjacency is the
        // entire GC-window mitigation described above. Between these two lines the blob is
        // written but unreferenced by any tag; a concurrent cleanUpOrphanedBlobs() elsewhere
        // in this codebase (fires after every image delete) could otherwise sweep it. Keep
        // any future addition here (logging, metrics, etc.) after `create`, not between.
        try await imageStore().create(description: Image.Description(reference: normalized, descriptor: descriptor))
        return descriptor.digest
    }
}
