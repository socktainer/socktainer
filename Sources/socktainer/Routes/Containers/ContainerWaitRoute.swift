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

            // `docker run` reads the /wait response HEAD before it sends /start,
            // then reads the body once the container exits. If we withhold the
            // head until the body is ready (the default when returning a Content
            // value), /start is never sent and the run deadlocks. So flush the
            // head immediately with an empty write, then stream the exit-code
            // JSON once client.wait() resolves (it blocks until the init process
            // actually exits and its real code is recorded).
            let body = Response.Body { writer in
                Task.detached {
                    defer { _ = writer.write(.end) }

                    _ = writer.write(.buffer(sharedAllocator.buffer(capacity: 0)))

                    let result: RESTContainerWait
                    do {
                        if condition == .healthy {
                            // Poll HealthCheckManager until the container becomes healthy
                            // or stops running (in which case it can never reach healthy).
                            var statusCode: Int64 = 0
                            if let manager = req.application.storage[HealthCheckManagerKey.self] {
                                while true {
                                    let health = await manager.currentHealth(for: containerId)
                                    if health?.Status == "healthy" { break }
                                    // health==nil means no probe loop was registered for this container.
                                    // HealthCheckManager.start() is called by ContainerStartRoute after
                                    // container.start() returns, so there is a brief window where the
                                    // container is running but health is still nil. We break here because
                                    // by the next poll (500ms later) start() would have run; if it's still
                                    // nil then, it means no HEALTHCHECK was configured and the container
                                    // can never become healthy.
                                    if health == nil {
                                        statusCode = 1
                                        break
                                    }
                                    // Container stopped — return its real exit code
                                    guard let c = try? await client.getContainer(id: containerId),
                                        c.status == .running
                                    else {
                                        let code = await ContainerExitCodeStore.shared.get(id: containerId) ?? 1
                                        statusCode = Int64(code)
                                        break
                                    }
                                    try await Task.sleep(nanoseconds: ContainerWaitCondition.healthyPollIntervalNs)
                                }
                            } else {
                                // HealthCheckManager unavailable — healthchecks not supported
                                statusCode = 1
                            }
                            result = RESTContainerWait(statusCode: statusCode)
                        } else {
                            result = try await client.wait(id: containerId, condition: condition)
                        }
                    } catch {
                        // Emit a 0-status body so the client unblocks rather than
                        // hanging on a half-open stream.
                        result = RESTContainerWait(statusCode: 0)
                    }

                    if let data = try? JSONEncoder().encode(result) {
                        var buf = sharedAllocator.buffer(capacity: data.count)
                        buf.writeBytes(data)
                        _ = writer.write(.buffer(buf))
                    }
                }
            }

            return Response(status: .ok, headers: headers, body: body)
        }
    }
}
