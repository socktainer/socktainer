import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// `docker logs --tail N` must return only the last N lines of the backlog.
/// Apple Container's log API is a forward byte stream, so socktainer slices the
/// tail itself via `lastLines`. `parseTail` maps moby's `tail` query value to a
/// line count (or nil for "all").
@Suite("ContainerLogsRoute — tail")
struct ContainerLogsTailTests {

    private func lastLines(_ s: String, _ count: Int) -> String {
        String(decoding: ContainerLogsRoute.lastLines(Data(s.utf8), count: count), as: UTF8.self)
    }

    @Test("tail keeps only the last N newline-terminated lines")
    func keepsLastN() {
        #expect(lastLines("a\nb\nc\nd\n", 2) == "c\nd\n")
        #expect(lastLines("a\nb\nc\nd\n", 1) == "d\n")
        #expect(lastLines("a\nb\nc\nd\n", 3) == "b\nc\nd\n")
    }

    @Test("A trailing line without a newline still counts as a line")
    func trailingPartialLineCounts() {
        #expect(lastLines("a\nb\nc", 2) == "b\nc")
        #expect(lastLines("a\nb\nc", 1) == "c")
    }

    @Test("Asking for more lines than exist returns everything")
    func moreThanAvailable() {
        #expect(lastLines("a\nb\n", 10) == "a\nb\n")
        #expect(lastLines("only-one-line", 5) == "only-one-line")
    }

    @Test("tail=0 yields no output; empty input stays empty")
    func zeroAndEmpty() {
        #expect(lastLines("a\nb\nc\n", 0) == "")
        #expect(lastLines("", 3) == "")
    }

    @Test("parseTail maps the moby query value to a line count or nil for all")
    func parseTailValues() {
        #expect(ContainerLogsRoute.parseTail(nil) == nil)
        #expect(ContainerLogsRoute.parseTail("all") == nil)
        #expect(ContainerLogsRoute.parseTail("ALL") == nil)
        #expect(ContainerLogsRoute.parseTail("garbage") == nil)
        #expect(ContainerLogsRoute.parseTail("-1") == nil)
        #expect(ContainerLogsRoute.parseTail("5") == 5)
        #expect(ContainerLogsRoute.parseTail("0") == 0)
    }

    @Test(
        "Attaching to neither stdout nor stderr is a 400",
        arguments: ["stdout=0&stderr=0", "stdout=false&stderr=false"])
    func neitherStreamIs400(query: String) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: ContainerLogsRoute(client: LogsContainerMock()))

            try await app.testing().test(.GET, "/v1.51/containers/ctr/logs?\(query)") { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("Bad parameters: you must choose at least one stream"))
            }
        }
    }
}

/// Mock whose getContainer returns a running snapshot so the logs route reaches
/// the stdout/stderr validation before touching Apple Container.
private struct LogsContainerMock: ClientContainerProtocol {
    private var snapshot: ContainerSnapshot {
        let proc = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [],
            workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0))
        let img = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0))
        let config = ContainerConfiguration(id: "ctr", image: img, process: proc)
        return ContainerSnapshot(configuration: config, status: .running, networks: [])
    }
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [snapshot] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}
