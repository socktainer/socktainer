import ContainerAPIClient
import Containerization
import ContainerizationOCI
import Foundation
import Logging
import Testing
import Vapor

@testable import socktainer

@Suite("Image route disconnect-coupled streaming")
struct DisconnectCoupledImageRouteTests {
    @Test(
        "silent pull disconnect terminates its service stream and releases mutation",
        .timeLimit(.minutes(1))
    )
    func pullDisconnectCancelsServiceStream() async throws {
        let client = DisconnectBlockingImageClient()
        let progress = try await client.pull(
            image: "example.invalid/pull",
            tag: "latest",
            platform: .current,
            fallbackPolicy: .strict,
            logger: Logger(label: "pull-disconnect-test")
        )

        await #expect(throws: CancellationError.self) {
            try await ImageCreateRoute.producePullResponse(
                progress,
                progressID: "pull:latest",
                writer: DisconnectAfterGateWriter(
                    disconnectAfter: client.entered
                ),
                logger: Logger(label: "pull-disconnect-test"),
                heartbeatInterval: .milliseconds(1)
            )
        }

        await client.waitUntilTerminated()
        #expect(await client.mutationLockIsAvailable())
    }

    @Test(
        "silent push disconnect terminates its service stream and releases mutation",
        .timeLimit(.minutes(1))
    )
    func pushDisconnectCancelsServiceStream() async throws {
        let client = DisconnectBlockingImageClient()
        let progress = try await client.push(
            reference: "example.invalid/push:latest",
            platform: nil,
            logger: Logger(label: "push-disconnect-test")
        )

        await #expect(throws: CancellationError.self) {
            try await ImagePushRoute.producePushResponse(
                progress,
                writer: DisconnectAfterGateWriter(
                    disconnectAfter: client.entered
                ),
                logger: Logger(label: "push-disconnect-test"),
                heartbeatInterval: .milliseconds(1)
            )
        }

        await client.waitUntilTerminated()
        #expect(await client.mutationLockIsAvailable())
    }

    @Test(
        "silent import disconnect cancels mutation and removes request archive",
        .timeLimit(.minutes(1))
    )
    func importDisconnectCleansTemporaryArchive() async throws {
        let parent = try makeDisconnectTestDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let temporaryDirectory = parent.appendingPathComponent(
            "import-request",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        let tarPath = temporaryDirectory.appendingPathComponent("import.tar")
        try Data("disposable-import".utf8).write(to: tarPath)
        let client = DisconnectBlockingImageClient()

        await #expect(throws: CancellationError.self) {
            try await ImageCreateRoute.produceImportResponse(
                temporaryDirectory: temporaryDirectory,
                writer: DisconnectAfterGateWriter(
                    disconnectAfter: client.entered
                ),
                logger: Logger(label: "import-disconnect-test"),
                heartbeatInterval: .milliseconds(1)
            ) { _ in
                _ = try await client.importImage(
                    tarPath: tarPath,
                    repo: "example.invalid/import",
                    tag: "latest",
                    message: nil,
                    changes: [],
                    platform: .current,
                    appleContainerAppSupportUrl: parent,
                    logger: Logger(label: "import-disconnect-test")
                )
            }
        }

        await client.waitUntilTerminated()
        #expect(
            !FileManager.default.fileExists(
                atPath: temporaryDirectory.path
            )
        )
        #expect(await client.mutationLockIsAvailable())
    }

    @Test(
        "silent load disconnect cancels mutation and removes streamed archive",
        .timeLimit(.minutes(1))
    )
    func loadDisconnectCleansTemporaryArchive() async throws {
        let parent = try makeDisconnectTestDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let body = AsyncStream<ByteBuffer> { continuation in
            continuation.yield(ByteBuffer(string: "disposable-load"))
            continuation.finish()
        }
        let client = DisconnectBlockingImageClient()

        await #expect(throws: CancellationError.self) {
            try await ImagesLoadRoute.produceLoadResponse(
                body: body,
                quiet: true,
                platform: nil,
                appleContainerAppSupportURL: parent,
                client: client,
                broadcaster: nil,
                writer: DisconnectAfterGateWriter(
                    disconnectAfter: client.entered
                ),
                logger: Logger(label: "load-disconnect-test"),
                temporaryDirectoryParent: parent,
                heartbeatInterval: .milliseconds(1)
            )
        }

        await client.waitUntilTerminated()
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: parent.path
        )
        #expect(leftovers.isEmpty)
        #expect(await client.mutationLockIsAvailable())
    }
}

private struct DisconnectAfterGateWriter: AsyncBodyStreamWriter {
    let disconnectAfter: DisconnectLifecycleGate

    func write(_ result: BodyStreamResult) async throws {
        await disconnectAfter.wait()
        throw DisconnectLifecycleTestError.disconnected
    }
}

private actor DisconnectBlockingImageClient: ClientImageProtocol {
    nonisolated let entered = DisconnectLifecycleGate()
    private let terminated = DisconnectLifecycleGate()
    private let coordinator = ImageMutationCoordinator()

    func waitUntilTerminated() async {
        await terminated.wait()
    }

    func mutationLockIsAvailable() async -> Bool {
        do {
            return try await coordinator.withMutationExcluded { true }
        } catch {
            return false
        }
    }

    func list(includeSystemImages: Bool) async throws -> [ClientImage] { [] }

    func delete(id: String) async throws -> ImageDeletionResult {
        throw DisconnectLifecycleTestError.unexpectedOperation
    }

    func pull(
        image: String,
        tag: String?,
        platform: Platform,
        fallbackPolicy: PlatformFallbackPolicy,
        logger: Logger
    ) async throws -> AsyncThrowingStream<PullProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.blockUntilCancelled()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func push(
        reference: String,
        platform: Platform?,
        logger: Logger
    ) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.blockUntilCancelled()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func prune(
        filters: [String: [String]],
        logger: Logger
    ) async throws -> (
        results: [ImageDeletionResult], spaceReclaimed: Int64
    ) {
        throw DisconnectLifecycleTestError.unexpectedOperation
    }

    func load(
        tarballPath: URL,
        platform: Platform?,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> [String] {
        try await blockUntilCancelled()
        return []
    }

    func save(
        references: [String],
        platform: Platform?,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> URL {
        throw DisconnectLifecycleTestError.unexpectedOperation
    }

    func importImage(
        tarPath: URL,
        repo: String?,
        tag: String?,
        message: String?,
        changes: [String],
        platform: Platform,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> (reference: String?, digest: String) {
        try await blockUntilCancelled()
        throw DisconnectLifecycleTestError.unexpectedOperation
    }

    private func blockUntilCancelled() async throws {
        let coordinator = self.coordinator
        let entered = self.entered
        let terminated = self.terminated
        do {
            try await coordinator.withMutationExcluded {
                await entered.open()
                try await Task.sleep(for: .seconds(60))
            }
            await terminated.open()
        } catch {
            await terminated.open()
            throw error
        }
    }
}

private actor DisconnectLifecycleGate {
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

private enum DisconnectLifecycleTestError: Error {
    case disconnected
    case unexpectedOperation
}

private func makeDisconnectTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "socktainer-disconnect-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return directory
}
