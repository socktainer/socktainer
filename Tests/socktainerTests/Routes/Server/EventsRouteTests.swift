import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

private struct MockHealthCheckClient: ClientHealthCheckProtocol {
    func ping() async throws {}
}

/// `GET /events` has to send its response headers as soon as the subscription
/// is open, as Docker does, rather than holding them back until the first
/// event: clients wait on them (`docker stats` with no arguments blocks until
/// its events subscription is established). In-process testing only returns a
/// response once its body ends, which an event stream never does, so these
/// tests run a real server and read from a socket.
@Suite("EventsRoute")
struct EventsRouteTests {

    @Test("Response headers arrive before the first event, and events still stream after them")
    func headersFlushedBeforeFirstEvent() async throws {
        let broadcaster = EventBroadcaster()

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: EventsRoute(client: MockHealthCheckClient()))

            // An event stream never finishes on its own, so don't let shutdown
            // wait the default 10s for it before closing the connection.
            app.http.server.configuration.shutdownTimeout = .milliseconds(100)
            try await app.server.start(address: .hostname("127.0.0.1", port: 0))

            var connection: RawHTTPConnection?
            let outcome: Result<Void, any Error>
            do {
                let port = try #require(app.http.server.shared.localAddress?.port)
                let conn = try RawHTTPConnection(port: port)
                connection = conn
                try conn.send("GET /v1.51/events HTTP/1.1\r\nHost: localhost\r\n\r\n")

                // No event has been broadcast yet.
                let head = try await Task.detached { try conn.read(until: "\r\n\r\n", timeout: 3) }.value
                #expect(head.hasPrefix("HTTP/1.1 200"))
                #expect(head.lowercased().contains("content-type: application/json"))

                // The early flush must not have ended the stream.
                await broadcaster.broadcast(Self.event("start"))
                let body = try await Task.detached { try conn.read(until: "}\n", timeout: 3) }.value
                #expect(body.contains(#""Action":"start""#))
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }

            // Tear down whether or not the checks passed: a server left running
            // traps when the app deinitializes, taking the whole run with it.
            // The handler only notices the disconnect when a write fails, so
            // keep sending it events until it ends the response and drops its
            // subscription, while the server is still up to fail those writes.
            connection?.close()
            let handlerEnded = await Self.eventually {
                await broadcaster.broadcast(Self.event("stop"))
                return await broadcaster.subscriberCount == 0
            }
            await app.server.shutdown()
            #expect(handlerEnded)
            try outcome.get()
        }
    }

    private static func eventually(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while await !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private static func event(_ action: String) -> DockerEvent {
        .make(type: "container", action: action, actorID: "web", attributes: ["name": "web"])
    }
}

/// A blocking TCP client, so the test sees exactly what reaches the socket and
/// when, without an HTTP client waiting for a body that never ends.
private final class RawHTTPConnection: @unchecked Sendable {
    struct Failure: Error { let call: String }

    private let fd: Int32
    private var buffered = Data()

    init(port: Int) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(call: "socket") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            throw Failure(call: "connect")
        }
    }

    func send(_ text: String) throws {
        let bytes = Array(text.utf8)
        guard Darwin.send(fd, bytes, bytes.count, 0) == bytes.count else { throw Failure(call: "send") }
    }

    /// Reads until `marker` has arrived and returns everything up to and
    /// including it, keeping the rest for the next read. Throws if it hasn't
    /// arrived within `timeout` seconds.
    func read(until marker: String, timeout: Int) throws -> String {
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let markerData = Data(marker.utf8)
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let range = buffered.range(of: markerData) {
                let result = buffered[..<range.upperBound]
                buffered.removeSubrange(..<range.upperBound)
                return String(decoding: result, as: UTF8.self)
            }
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0 else { throw Failure(call: n == 0 ? "recv (closed)" : "recv (timed out)") }
            buffered.append(contentsOf: chunk[..<n])
        }
    }

    func close() {
        Darwin.close(fd)
    }
}
