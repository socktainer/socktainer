import Foundation
import Vapor

public enum ContainerWaitCondition: String, CaseIterable, Codable, Sendable {
    case notRunning = "not-running"
    case nextExit = "next-exit"
    case removed = "removed"
    case healthy = "healthy"

    public static let `default`: ContainerWaitCondition = .notRunning
    /// Poll interval when waiting for condition=healthy.
    static let healthyPollIntervalNs: UInt64 = 500_000_000  // 500 ms
}

struct ContainerWaitRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/wait", use: ContainerWaitRoute.handler(client: client))
    }

    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let containerId = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let conditionString = req.query["condition"] as String?
            let condition: ContainerWaitCondition
            if let conditionString = conditionString {
                condition = ContainerWaitCondition(rawValue: conditionString) ?? ContainerWaitCondition.default
            } else {
                condition = ContainerWaitCondition.default
            }

            // Preflight before flushing headers so a missing container returns a
            // real 404 instead of a streamed `200 {"StatusCode":0}` — the latter
            // would make "no such container" indistinguishable from a clean exit.
            do {
                guard try await client.getContainer(id: containerId) != nil else {
                    throw Abort(.notFound, reason: "No such container: \(containerId)")
                }
            } catch ClientContainerError.ambiguousId(let reference, let matches) {
                let matchList = matches.joined(separator: ", ")
                throw Abort(.badRequest, reason: "ambiguous container reference \(reference): matches \(matchList)")
            }

            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")

            // Flush the response head before the body so docker run can issue /start
            // without waiting for the container to exit first.
            let body = Response.Body(asyncStream: { writer in
                _ = try? await writer.write(.buffer(sharedAllocator.buffer(capacity: 0)))

                let result: RESTContainerWait
                do {
                    if condition == .healthy {
                        var statusCode: Int64 = 0
                        if let manager = req.application.storage[HealthCheckManagerKey.self] {
                            while true {
                                let health = await manager.currentHealth(for: containerId)
                                if health?.Status == "healthy" { break }
                                if health == nil {
                                    statusCode = 1
                                    break
                                }
                                guard let container = try? await client.getContainer(id: containerId),
                                    container.status == .running
                                else {
                                    let code = await ContainerExitCodeStore.shared.get(id: containerId) ?? 1
                                    statusCode = Int64(code)
                                    break
                                }
                                try await Task.sleep(nanoseconds: ContainerWaitCondition.healthyPollIntervalNs)
                            }
                        } else {
                            statusCode = 1
                        }
                        result = RESTContainerWait(statusCode: statusCode)
                    } else if condition == .removed {
                        result = try await client.wait(id: containerId, condition: condition)
                    } else {
                        // Subscribe before returning so a die event fired during the wait is
                        // never missed by this listener.
                        let events = await req.application.storage[EventBroadcasterKey.self]?.stream()
                        result = await resolveNotRunning(
                            containerId: containerId,
                            client: client,
                            condition: condition,
                            events: events
                        )
                    }
                } catch {
                    result = RESTContainerWait(statusCode: 0)
                }

                if let data = try? JSONEncoder().encode(result) {
                    var buf = sharedAllocator.buffer(capacity: data.count)
                    buf.writeBytes(data)
                    _ = try? await writer.write(.buffer(buf))
                }
                _ = try? await writer.write(.end)
            })

            return Response(status: .ok, headers: headers, body: body)
        }
    }
}

extension ContainerWaitRoute {
    /// Poll interval shared by the exit-code and stopped-state watchers.
    static let waitPollIntervalNs: UInt64 = 100_000_000
    /// How long the stopped-state watcher gives the recorder to publish an exit code.
    static let stoppedGraceNs: UInt64 = 750_000_000

    /// Resolves `condition=not-running` from whichever source answers first.
    ///
    /// No single source is reliable:
    /// - the native wait is authoritative while the runtime client is attached;
    /// - `ContainerExitCodeStore` is populated by the attach paths' exit monitor;
    /// - the `die` event fires for every container, including ones that exit before the
    ///   wait was issued;
    /// - the container's own state is the last resort.
    ///
    /// The state watcher only reports a result after it has seen the container `running`.
    /// `docker compose up` issues `POST /wait` before `POST /start`, so a created container
    /// is *not* running yet — reporting that as a clean exit would tell Compose the service
    /// finished successfully before it ever started.
    static func resolveNotRunning(
        containerId: String,
        client: ClientContainerProtocol,
        condition: ContainerWaitCondition = .notRunning,
        events: AsyncStream<DockerEvent>? = nil,
        storeTimeoutNs: UInt64 = 30_000_000_000
    ) async -> RESTContainerWait {
        await withTaskGroup(of: RESTContainerWait?.self) { group in
            group.addTask {
                try? await client.wait(id: containerId, condition: condition)
            }
            group.addTask {
                let maxPolls = Int(storeTimeoutNs / waitPollIntervalNs)
                for _ in 0..<maxPolls {
                    if let code = await ContainerExitCodeStore.shared.get(id: containerId) {
                        return RESTContainerWait(statusCode: Int64(code))
                    }
                    // Cancellation must end this loop: swallowing it would keep polling for the
                    // rest of the timeout after a sibling source already answered.
                    guard await sleepUnlessCancelled(waitPollIntervalNs) else { return nil }
                }
                return nil
            }
            group.addTask {
                await dieEventResult(containerId: containerId, events: events)
            }
            group.addTask {
                await stoppedStateResult(
                    containerId: containerId,
                    client: client,
                    storeTimeoutNs: storeTimeoutNs
                )
            }

            for await waitResult in group {
                if let waitResult {
                    group.cancelAll()
                    return waitResult
                }
            }
            // Every source gave up without observing a stop. Reporting `StatusCode: 0` here
            // would claim a clean exit: Compose would treat a service that never ran as a
            // successful one. Docker carries the failure alongside the status, so clients
            // surface the message instead of trusting the code.
            return RESTContainerWait(
                statusCode: -1,
                error: ContainerWaitExitError(
                    Message: "no exit observed for container \(containerId)"
                )
            )
        }
    }

    /// Returns false when the surrounding task was cancelled, so a polling loop can stop
    /// instead of running out its full budget after a sibling already produced a result.
    private static func sleepUnlessCancelled(_ nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return true
        } catch {
            return false
        }
    }

    /// The `die` event carries the authoritative exit code and fires even when the container
    /// exits before this wait was issued.
    private static func dieEventResult(
        containerId: String,
        events: AsyncStream<DockerEvent>?
    ) async -> RESTContainerWait? {
        guard let events else { return nil }

        for await event in events {
            guard event.Type == "container", event.Action == "die" else { continue }
            guard event.Actor.ID == containerId
                || event.Actor.ID.hasPrefix(containerId)
                || event.Actor.Attributes["name"] == containerId
            else { continue }

            if let exitCode = event.Actor.Attributes["exitCode"], let code = Int64(exitCode) {
                return RESTContainerWait(statusCode: code)
            }
            let recorded = await ContainerExitCodeStore.shared.get(id: containerId)
            return RESTContainerWait(statusCode: Int64(recorded ?? 0))
        }
        return nil
    }

    /// Last-resort watcher: only terminal once the container has been observed running, so a
    /// created-but-not-started container is never mistaken for a finished one.
    private static func stoppedStateResult(
        containerId: String,
        client: ClientContainerProtocol,
        storeTimeoutNs: UInt64
    ) async -> RESTContainerWait? {
        var sawRunning = false
        let maxPolls = Int(storeTimeoutNs / waitPollIntervalNs)

        for _ in 0..<maxPolls {
            if Task.isCancelled { return nil }
            let container = try? await client.getContainer(id: containerId)
            if container?.status == .running {
                sawRunning = true
            } else if sawRunning {
                // The container ran and is no longer running: give the recorder a moment to
                // publish the real code before falling back to a clean exit.
                guard await sleepUnlessCancelled(stoppedGraceNs) else { return nil }
                let code = await ContainerExitCodeStore.shared.get(id: containerId) ?? 0
                return RESTContainerWait(statusCode: Int64(code))
            }
            guard await sleepUnlessCancelled(waitPollIntervalNs) else { return nil }
        }
        return nil
    }
}
