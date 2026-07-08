import ContainerAPIClient
import ContainerResource

@testable import socktainer

/// A `ClientContainerProtocol` mock that always returns the same fixed snapshot for
/// `list`/`getContainer` and no-ops every mutating call except `start`, which clears any
/// stale exit code so a test's own `ContainerExitCodeStore.shared.set(...)` starts fresh.
actor StaticSnapshotClientMock: ClientContainerProtocol {
    private let snapshot: ContainerSnapshot

    init(snapshot: ContainerSnapshot) {
        self.snapshot = snapshot
    }

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [snapshot] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
    nonisolated func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {
        await ContainerExitCodeStore.shared.remove(id: id)
    }
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
