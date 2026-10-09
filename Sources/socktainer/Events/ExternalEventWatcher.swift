import ContainerAPIClient
import ContainerResource
import Foundation
import Logging

/// Emits container and image events for changes made outside socktainer (e.g. `container run`,
/// `container image pull`).
///
/// Apple's `container` CLI talks to the apiserver directly and apple/container exposes no event
/// stream, so socktainer polls the container and image lists and diffs them. A detected event is
/// held for one tick and dropped if socktainer's own routes broadcast the same action meanwhile, so
/// objects driven through the Docker API don't get duplicate events.
actor ExternalEventWatcher {
    static let pollInterval: TimeInterval = 5

    private let broadcaster: EventBroadcaster
    private let imageClient: ClientImageProtocol
    private let logger: Logger

    init(broadcaster: EventBroadcaster, imageClient: ClientImageProtocol, logger: Logger) {
        self.broadcaster = broadcaster
        self.imageClient = imageClient
        self.logger = logger
    }

    func run() async {
        var previousContainers: [String: ContainerSnapshot]?
        var previousImages: [String: String]?
        var pending: [DockerEvent] = []
        while !Task.isCancelled {
            pending: for event in pending {
                for id in Self.dedupIDs(event) where await broadcaster.emittedRecently(id: id, action: event.Action, within: 2 * Self.pollInterval + 2) {
                    continue pending
                }
                await broadcaster.broadcast(event)
            }
            pending = []

            do {
                let snapshots = ClientContainerService.withoutDNSSidecars(try await ContainerClient().list())
                let current = Dictionary(snapshots.map { (DockerContainerID.hexId(for: $0), $0) }, uniquingKeysWith: { first, _ in first })
                if let previousContainers {
                    pending += Self.containerTransitions(previous: previousContainers, current: current)
                }
                previousContainers = current
            } catch {
                logger.debug("External container event poll failed: \(error)")
            }

            do {
                let images = try await imageClient.list(includeSystemImages: false)
                let current = Dictionary(images.map { ($0.reference, $0.digest) }, uniquingKeysWith: { first, _ in first })
                if let previousImages {
                    pending += Self.imageTransitions(previous: previousImages, current: current)
                }
                previousImages = current
            } catch {
                logger.debug("External image event poll failed: \(error)")
            }

            try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
        }
    }

    /// Container lifecycle events between two polls, keyed by Docker container id.
    static func containerTransitions(previous: [String: ContainerSnapshot], current: [String: ContainerSnapshot]) -> [DockerEvent] {
        var result: [DockerEvent] = []
        for (id, container) in current {
            let isRunning = container.status == .running
            guard let before = previous[id] else {
                result.append(.containerEvent("create", container: container))
                if isRunning { result.append(.containerEvent("start", container: container)) }
                continue
            }
            let wasRunning = before.status == .running
            if isRunning && !wasRunning {
                result.append(.containerEvent("start", container: container))
            } else if !isRunning && wasRunning {
                result.append(.containerEvent("die", container: container))
            }
        }
        for (id, container) in previous where current[id] == nil {
            result.append(.containerEvent("destroy", container: container))
        }
        return result
    }

    /// Image events between two polls of `[reference: digest]`, shaped like the image routes' events.
    /// Dangling references are not tags, but their digests still count as present.
    static func imageTransitions(previous: [String: String], current: [String: String]) -> [DockerEvent] {
        func isDangling(_ ref: String) -> Bool { ref.hasPrefix("untagged@") || ref.contains("<none>") }
        let previousDigests = Set(previous.values)
        let currentDigests = Set(current.values)
        var result: [DockerEvent] = []
        for (ref, digest) in current where !isDangling(ref) && previous[ref] != digest {
            if previous[ref] == nil && previousDigests.contains(digest) {
                result.append(.make(type: "image", action: "tag", actorID: digest, attributes: ["name": ref]))
            } else {
                result.append(.make(type: "image", action: "pull", actorID: ref, attributes: ["name": repositoryName(ref)]))
            }
        }
        for (ref, digest) in previous where !isDangling(ref) && current[ref] == nil {
            result.append(.make(type: "image", action: "untag", actorID: digest, attributes: ["name": ref]))
        }
        for digest in previousDigests.subtracting(currentDigests) {
            result.append(.make(type: "image", action: "delete", actorID: digest, attributes: ["name": digest]))
        }
        return result
    }

    /// Actor IDs the routes may have used for the same event. Apple stores fully-qualified
    /// references, while `docker pull alpine` broadcasts its `pull` as `alpine:latest`.
    static func dedupIDs(_ event: DockerEvent) -> [String] {
        let id = event.Actor.ID
        guard event.Type == "image", event.Action == "pull" else { return [id] }
        for prefix in ["docker.io/library/", "docker.io/"] where id.hasPrefix(prefix) {
            return [id, String(id.dropFirst(prefix.count))]
        }
        return [id]
    }

    /// `docker.io/library/nginx:latest` → `docker.io/library/nginx` (drops tag or digest).
    static func repositoryName(_ ref: String) -> String {
        if let at = ref.firstIndex(of: "@") { return String(ref[..<at]) }
        if let colon = ref.lastIndex(of: ":"), !ref[colon...].contains("/") { return String(ref[..<colon]) }
        return ref
    }
}
