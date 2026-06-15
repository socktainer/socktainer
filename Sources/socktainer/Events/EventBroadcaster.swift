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
    static func simpleEvent(
        id: String,
        type: String,
        status: String,
        image: String = "",
        name: String = "",
        labels: [String: String] = [:]
    ) -> DockerEvent {
        let now = Date()
        let timeSeconds = Int(now.timeIntervalSince1970)
        let timeNano = UInt64(now.timeIntervalSince1970 * 1_000_000_000)

        var attributes = labels
        attributes["image"] = image
        attributes["name"] = name.isEmpty ? id : name

        let actor = DockerActor(ID: id, Attributes: attributes)

        return DockerEvent(
            status: status,
            id: id,
            from: image,
            Type: type,
            Action: status,
            Actor: actor,
            scope: "local",
            time: timeSeconds,
            timeNano: timeNano
        )
    }
}

actor EventBroadcaster {
    private var continuations: [UUID: AsyncStream<DockerEvent>.Continuation] = [:]

    func stream() -> AsyncStream<DockerEvent> {
        let id = UUID()

        return AsyncStream { continuation in
            // Safely register continuation inside the actor
            Task {
                self.addContinuation(id: id, continuation)
            }

            // Handle termination safely via actor
            continuation.onTermination = { @Sendable _ in
                Task {
                    await self.removeContinuation(id: id)
                }
            }
        }
    }

    func broadcast(_ event: DockerEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func addContinuation(id: UUID, _ continuation: AsyncStream<DockerEvent>.Continuation) {
        continuations[id] = continuation
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
