import ContainerAPIClient
import ContainerBuild
import ContainerPersistence
import ContainerResource
import ContainerizationError
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// `docker compose build` with the classic builder streams a build-context tar
/// whose final entry is not padded to a 512-byte block and which omits the
/// end-of-archive marker. The Docker daemon's Go tar reader tolerates this, but
/// libarchive (used by `ArchiveUtility.extract`) treats the short final block as
/// a truncated archive and aborts. `BuildRoute.appendTarTerminator` repairs such
/// a context by appending a zero-filled terminator before extraction.
@Suite("Build context tar terminator")
struct BuildContextTarTests {

    /// Build a tar of a single file, then strip the trailing zero bytes so the
    /// last entry's block is unpadded and the end-of-archive marker is gone —
    /// reproducing the classic-builder context tar that libarchive rejects.
    private func makeUnpaddedTar() throws -> (tar: URL, cleanup: () -> Void) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let cleanup: () -> Void = { try? FileManager.default.removeItem(at: tmp) }

        let source = tmp.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("hello".utf8).write(
            to: source.appendingPathComponent("file.txt")
        )

        let fullTar = tmp.appendingPathComponent("full.tar")
        try ArchiveUtility.create(tarPath: fullTar, from: source)

        var bytes = try Data(contentsOf: fullTar)
        while bytes.last == 0 {
            bytes.removeLast()
        }
        let unpadded = tmp.appendingPathComponent("context.tar")
        try bytes.write(to: unpadded)
        return (unpadded, cleanup)
    }

    @Test("A plain tar missing its trailing padding fails to extract until terminated")
    func plainTarTerminator() throws {
        let (tar, cleanup) = try makeUnpaddedTar()
        defer { cleanup() }

        let destBefore = tar.deletingLastPathComponent().appendingPathComponent("before")
        #expect(throws: (any Error).self) {
            try ArchiveUtility.extract(tarPath: tar, to: destBefore)
        }

        try BuildRoute.appendTarTerminator(to: tar)

        let destAfter = tar.deletingLastPathComponent().appendingPathComponent("after")
        try ArchiveUtility.extract(tarPath: tar, to: destAfter)
        let extracted = try String(contentsOf: destAfter.appendingPathComponent("file.txt"), encoding: .utf8)
        #expect(extracted == "hello")
    }

    @Test("A gzip-compressed tar missing its trailing padding fails to extract until terminated")
    func gzipTarTerminator() throws {
        let (plainTar, cleanup) = try makeUnpaddedTar()
        defer { cleanup() }

        // Compress the unpadded tar so the missing end-of-archive marker is
        // inside the gzip stream, matching what `docker compose build` sends
        // (Content-Type: application/x-tar, gzip payload).
        let gzTar = plainTar.deletingLastPathComponent().appendingPathComponent("context.tar.gz")
        FileManager.default.createFile(atPath: gzTar.path, contents: nil)
        let out = try FileHandle(forWritingTo: gzTar)
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        gzip.arguments = ["gzip", "-c", plainTar.path]
        gzip.standardOutput = out
        try gzip.run()
        gzip.waitUntilExit()
        try out.close()
        #expect(gzip.terminationStatus == 0)

        let destBefore = gzTar.deletingLastPathComponent().appendingPathComponent("gzbefore")
        #expect(throws: (any Error).self) {
            try ArchiveUtility.extract(tarPath: gzTar, to: destBefore)
        }

        try BuildRoute.appendTarTerminator(to: gzTar)

        let destAfter = gzTar.deletingLastPathComponent().appendingPathComponent("gzafter")
        try ArchiveUtility.extract(tarPath: gzTar, to: destAfter)
        let extracted = try String(contentsOf: destAfter.appendingPathComponent("file.txt"), encoding: .utf8)
        #expect(extracted == "hello")
    }

    @Test("Terminating an already well-formed tar leaves it extractable")
    func wellFormedTarStaysValid() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let source = tmp.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "world".data(using: .utf8)!.write(to: source.appendingPathComponent("file.txt"))

        let tar = tmp.appendingPathComponent("context.tar")
        try ArchiveUtility.create(tarPath: tar, from: source)

        // Appending to a complete archive is a no-op for readers: trailing zeros
        // after the end-of-archive marker are ignored.
        try BuildRoute.appendTarTerminator(to: tar)

        let dest = tmp.appendingPathComponent("out")
        try ArchiveUtility.extract(tarPath: tar, to: dest)
        let extracted = try String(contentsOf: dest.appendingPathComponent("file.txt"), encoding: .utf8)
        #expect(extracted == "world")
    }

    @Test("classic build staging is private, bounded, and repairs a short tar")
    func buildContextStaging() async throws {
        let (tar, cleanup) = try makeUnpaddedTar()
        defer { cleanup() }
        let parent = tar.deletingLastPathComponent()
            .appendingPathComponent("staging", isDirectory: true)
        let bytes = try Data(contentsOf: tar)
        let stream = AsyncStream<ByteBuffer> { continuation in
            let midpoint = bytes.count / 2
            continuation.yield(
                ByteBuffer(data: bytes.prefix(midpoint))
            )
            continuation.yield(
                ByteBuffer(data: bytes.suffix(from: midpoint))
            )
            continuation.finish()
        }

        let staged = try await BuildRoute.stageBuildContext(
            stream,
            in: parent,
            maxBodyBytes: bytes.count,
            extractionLimits: .init(
                maxExpandedBytes: 1024 * 1024,
                maxEntries: 100
            )
        )
        defer {
            try? FileManager.default.removeItem(at: staged.rootDirectory)
        }

        let rootPermissions =
            try FileManager.default.attributesOfItem(
                atPath: staged.rootDirectory.path
            )[.posixPermissions] as? NSNumber
        let tarPermissions =
            try FileManager.default.attributesOfItem(
                atPath: staged.rootDirectory.appendingPathComponent("context.tar").path
            )[.posixPermissions] as? NSNumber
        #expect(rootPermissions?.intValue == 0o700)
        #expect(tarPermissions?.intValue == 0o600)
        #expect(staged.bodyBytes == bytes.count)
        #expect(
            try String(
                contentsOf: staged.contextDirectory.appendingPathComponent(
                    "file.txt"
                ),
                encoding: .utf8
            ) == "hello"
        )
    }

    @Test("classic build staging removes partial state when the body cap fails")
    func buildContextBodyCapCleansUp() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let stream = AsyncStream<ByteBuffer> { continuation in
            continuation.yield(ByteBuffer(string: "12345"))
            continuation.finish()
        }

        do {
            _ = try await BuildRoute.stageBuildContext(
                stream,
                in: parent,
                maxBodyBytes: 4,
                extractionLimits: .init(
                    maxExpandedBytes: 1024,
                    maxEntries: 10
                )
            )
            Issue.record("expected build context body quota failure")
        } catch let abort as Abort {
            #expect(abort.status == .payloadTooLarge)
            #expect(abort.reason == "build context exceeds the 4-byte limit")
        }
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: parent.path
            ).isEmpty
        )
    }

    @Test("classic build staging rejects and cleans an empty streamed body")
    func emptyBuildContextCleansUp() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let stream = AsyncStream<ByteBuffer> { continuation in
            continuation.finish()
        }

        do {
            _ = try await BuildRoute.stageBuildContext(
                stream,
                in: parent,
                maxBodyBytes: 1024,
                extractionLimits: .init(
                    maxExpandedBytes: 1024,
                    maxEntries: 10
                )
            )
            Issue.record("expected empty build context rejection")
        } catch let abort as Abort {
            #expect(abort.status == .badRequest)
            #expect(abort.reason == "build context body is required")
        }
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: parent.path
            ).isEmpty
        )
    }

    @Test("Dockerfile lookup permits a nested regular file")
    func nestedDockerfileIsRead() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = root.appendingPathComponent("docker", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("FROM scratch\n".utf8).write(
            to: nested.appendingPathComponent("Dockerfile")
        )

        let data = try BuildRoute.readDockerfile(
            named: "docker/./Dockerfile",
            in: root.path
        )
        #expect(data == Data("FROM scratch\n".utf8))
    }

    @Test("Dockerfile dot-dot traversal is rejected")
    func dockerfileDotDotIsRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: ContainerizationError.self) {
            _ = try BuildRoute.readDockerfile(
                named: "../Dockerfile",
                in: root.path
            )
        }
    }

    @Test("Dockerfile final symlink cannot leave the staged context")
    func dockerfileSymlinkIsRejected() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = parent.appendingPathComponent("context", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        let outside = parent.appendingPathComponent("outside.Dockerfile")
        try Data("FROM malicious\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Dockerfile"),
            withDestinationURL: outside
        )

        #expect(throws: ContainerizationError.self) {
            _ = try BuildRoute.readDockerfile(
                named: "Dockerfile",
                in: root.path
            )
        }
    }

    @Test("Dockerfile intermediate symlink cannot leave the staged context")
    func dockerfileIntermediateSymlinkIsRejected() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = parent.appendingPathComponent("context", isDirectory: true)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        try Data("FROM malicious\n".utf8).write(
            to: outside.appendingPathComponent("Dockerfile")
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("docker"),
            withDestinationURL: outside
        )

        #expect(throws: ContainerizationError.self) {
            _ = try BuildRoute.readDockerfile(
                named: "docker/Dockerfile",
                in: root.path
            )
        }
    }

    @Test("missing build body is rejected before builder reachability")
    func missingBuildBodyDoesNotInvokeBuilder() async throws {
        let builder = BuildRouteInvocationProbe()
        try await withBuildRoute(builder: builder) { app in
            try await app.testing().test(
                .POST,
                "/v1.51/build"
            ) { response async in
                #expect(response.status == .badRequest)
            }
        }
        #expect(await builder.invocationCounts() == [0, 0])
    }

    @Test("zero-byte streamed build body is rejected before builder reachability")
    func zeroByteBuildBodyDoesNotInvokeBuilder() async throws {
        let builder = BuildRouteInvocationProbe()
        try await withBuildRoute(builder: builder) { app in
            try await app.testing().test(
                .POST,
                "/v1.51/build",
                headers: ["Transfer-Encoding": "chunked"],
                body: ByteBuffer()
            ) { response async in
                #expect(response.status == .badRequest)
            }
        }
        #expect(await builder.invocationCounts() == [0, 0])
    }

    @Test(
        "client disconnect cancels build and releases every owned resource",
        .timeLimit(.minutes(1))
    )
    func clientDisconnectCancelsBuildAndCleansUp() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stagingRoot = parent.appendingPathComponent(
            "staging",
            isDirectory: true
        )
        let exportRoot = parent.appendingPathComponent(
            "export",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: exportRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }

        let enteredMutation = BuildRouteCancellationGate()
        let writer = BuildRouteDisconnectingWriter(
            disconnectAfter: enteredMutation
        )
        let session = BuildRouteBlockingSession()
        let coordinator = ImageMutationCoordinator()

        do {
            try await BuildRoute.produceBuildResponse(
                stagingRoot: stagingRoot,
                writer: writer,
                logger: Logger(label: "socktainer.build-disconnect-test"),
                heartbeatInterval: .milliseconds(1)
            ) { _ in
                defer { try? FileManager.default.removeItem(at: exportRoot) }
                try await BuilderSessionLifecycle.withSession(session) { _ in
                    try await coordinator.withMutationExcluded {
                        await enteredMutation.open()
                        // This continuation deliberately ignores cooperative
                        // cancellation. Only closing the builder session can
                        // release it, matching a blocked BuildKit transport.
                        await session.waitUntilClosed()
                        try Task.checkCancellation()
                    }
                }
            }
            Issue.record("expected the disconnected writer to cancel the build")
        } catch is CancellationError {
            // Expected: disconnect is request cancellation, not a build frame.
        }

        #expect(await session.closeCount == 1)
        #expect(!FileManager.default.fileExists(atPath: stagingRoot.path))
        #expect(!FileManager.default.fileExists(atPath: exportRoot.path))

        // Returning from the producer is not enough: the exclusion must have
        // actually unwound so a subsequent image mutation can enter.
        let lockWasReleased = try await coordinator.withMutationExcluded {
            true
        }
        #expect(lockWasReleased)
    }
}

private actor BuildRouteCancellationGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private struct BuildRouteDisconnectingWriter: AsyncBodyStreamWriter {
    let disconnectAfter: BuildRouteCancellationGate

    func write(_ result: BodyStreamResult) async throws {
        await disconnectAfter.wait()
        throw BuildRouteTestError.disconnected
    }
}

private actor BuildRouteBlockingSession: BuilderBuildSession {
    private(set) var closeCount = 0
    private var closed = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    func build(_ configuration: Builder.BuildConfig) async throws {
        throw BuildRouteTestError.unexpectedBuildInvocation
    }

    func waitUntilClosed() async {
        guard !closed else { return }
        await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
        }
    }

    func close() {
        closeCount += 1
        guard !closed else { return }
        closed = true
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private enum BuildRouteTestError: Error {
    case disconnected
    case unexpectedBuildInvocation
}

private enum BuildRouteProbeError: Error {
    case unexpectedInvocation
}

private actor BuildRouteInvocationProbe: ClientBuilderProtocol {
    private var ensureReachableCalls = 0
    private var connectCalls = 0

    func ensureReachable(
        timeout: Duration,
        retryInterval: Duration,
        logger: Logger
    ) async throws {
        ensureReachableCalls += 1
        throw BuildRouteProbeError.unexpectedInvocation
    }

    func connect(
        timeout: Duration,
        retryInterval: Duration,
        logger: Logger
    ) async throws -> any BuilderBuildSession {
        connectCalls += 1
        throw BuildRouteProbeError.unexpectedInvocation
    }

    func prune(
        _ request: BuilderPruneRequest,
        logger: Logger
    ) async throws -> BuilderPruneResult {
        throw BuildRouteProbeError.unexpectedInvocation
    }

    func diskUsage(logger: Logger) async throws -> [BuilderCacheRecord] {
        throw BuildRouteProbeError.unexpectedInvocation
    }

    func invocationCounts() -> [Int] {
        [ensureReachableCalls, connectCalls]
    }
}

private struct BuildRouteNoopContainerClient: ClientContainerProtocol {
    func list(
        showAll: Bool,
        filters: [String: [String]]
    ) async throws -> [ContainerSnapshot] { [] }

    func getContainer(id: String) async throws -> ContainerSnapshot? { nil }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(
        id: String,
        condition: ContainerWaitCondition
    ) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(
        filters: [String: [String]]
    ) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}

private func withBuildRoute(
    builder: BuildRouteInvocationProbe,
    test: @escaping (Application) async throws -> Void
) async throws {
    let appSupport = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: appSupport,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: appSupport) }

    try await withApp(
        configure: { app in
            app.middleware.use(
                ErrorMiddleware.default(environment: app.environment)
            )
        },
        { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(
                collection: BuildRoute(
                    client: BuildRouteNoopContainerClient(),
                    builderClient: builder,
                    systemConfig: ContainerSystemConfig(),
                    appleContainerAppSupportURL: appSupport
                )
            )
            try await test(app)
        }
    )
}
