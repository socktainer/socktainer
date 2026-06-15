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
                        // Race native wait against ContainerExitCodeStore polling.
                        // Pipe-bootstrapped containers (docker run) may not surface
                        // their exit through client.wait(), so we poll the store in
                        // parallel and take whichever resolves first.
                        result = await withTaskGroup(of: RESTContainerWait?.self) { group in
                            group.addTask {
                                try? await client.wait(id: containerId, condition: condition)
                            }
                            group.addTask {
                                let pollIntervalNs: UInt64 = 100_000_000
                                let maxPolls = Int(30_000_000_000 / pollIntervalNs)
                                for _ in 0..<maxPolls {
                                    if let code = await ContainerExitCodeStore.shared.get(id: containerId) {
                                        return RESTContainerWait(statusCode: Int64(code))
                                    }
                                    try? await Task.sleep(nanoseconds: pollIntervalNs)
                                }
                                return nil
                            }
                            for await waitResult in group {
                                if let waitResult {
                                    group.cancelAll()
                                    return waitResult
                                }
                            }
                            return RESTContainerWait(statusCode: 0)
                        }
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
