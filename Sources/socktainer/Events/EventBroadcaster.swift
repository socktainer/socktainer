import Vapor

struct EventBroadcasterKey: StorageKey {
    typealias Value = EventBroadcaster
}

struct DockerActor: Codable {
    let ID: String
    let Attributes: [String: String]
}

struct DockerEvent: Codable {
    let status: String
    let id: String
    let from: String
    let `Type`: String
    let Action: String
    let Actor: DockerActor
    let scope: String
    let time: Int
    let timeNano: UInt64
}

extension DockerEvent {
    /// General constructor mirroring moby's `EventsService.Log(action, type, Actor{ID, Attributes})`.
    /// The deprecated top-level fields are derived exactly as moby does for backward compatibility:
    /// `id` = Actor.ID, `status` = action, `from` = Attributes["image"] (empty when absent).
    /// Use this for image/network/volume/prune events, whose attribute sets differ from containers
    /// (e.g. no forced `image`/`name` keys).
    static func make(
        type: String,
        action: String,
        actorID: String,
        attributes: [String: String]
    ) -> DockerEvent {
        let now = Date()
        let timeSeconds = Int(now.timeIntervalSince1970)
        let timeNano = UInt64(now.timeIntervalSince1970 * 1_000_000_000)

        return DockerEvent(
            status: action,
            id: actorID,
            from: attributes["image"] ?? "",
            Type: type,
            Action: action,
            Actor: DockerActor(ID: actorID, Attributes: attributes),
            scope: "local",
            time: timeSeconds,
            timeNano: timeNano
        )
    }

    /// Container-shaped event: moby's `LogContainerEventWithAttributes` always injects
    /// `image` and `name` attributes alongside the container labels. Keep using this for
    /// `Type: "container"` events only. `extraAttributes` carries action-specific keys moby
    /// adds on top (e.g. `signal` on `kill`, `exitCode` on `die`/`exec_die`); they override
    /// any same-named label.
    static func simpleEvent(
        id: String,
        type: String,
        status: String,
        image: String = "",
        name: String = "",
        labels: [String: String] = [:],
        extraAttributes: [String: String] = [:]
    ) -> DockerEvent {
        var attributes = labels
        attributes["image"] = image
        attributes["name"] = name.isEmpty ? id : name
        for (key, value) in extraAttributes { attributes[key] = value }
        return make(type: type, action: status, actorID: id, attributes: attributes)
    }
}

actor EventBroadcaster {
    private var continuations: [UUID: AsyncStream<DockerEvent>.Continuation] = [:]

    func stream() -> AsyncStream<DockerEvent> {
        let id = UUID()

        // Register the continuation synchronously, before returning the stream. The
        // previous implementation deferred registration to `Task { addContinuation }`,
        // leaving a window where the stream existed but was not yet in `continuations`
        // — any event broadcast in that window was silently dropped for this listener
        // (e.g. a container's start event firing right after `docker events` connects).
        // `makeStream` lets us register inside the actor-isolated method with no race.
        let (stream, continuation) = AsyncStream.makeStream(of: DockerEvent.self)
        continuations[id] = continuation
        continuation.onTermination = { @Sendable _ in
            Task { await self.removeContinuation(id: id) }
        }
        return stream
    }

    func broadcast(_ event: DockerEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
