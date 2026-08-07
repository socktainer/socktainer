import ContainerAPIClient
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation

/// Narrow Apple Container boundary used by create reconciliation tests. A
/// successful server-side create can be followed by an interrupted XPC reply;
/// callers must query a fresh client before deciding that pre-created rootfs
/// state is safe to remove.
protocol NativeContainerCreating: Sendable {
    func create(
        configuration: ContainerConfiguration,
        options: ContainerCreateOptions,
        kernel: Kernel
    ) async throws

    func get(id: String) async throws -> ContainerSnapshot
}

struct LiveNativeContainerCreator: NativeContainerCreating {
    func create(
        configuration: ContainerConfiguration,
        options: ContainerCreateOptions,
        kernel: Kernel
    ) async throws {
        try await ContainerClient().create(
            configuration: configuration,
            options: options,
            kernel: kernel
        )
    }

    func get(id: String) async throws -> ContainerSnapshot {
        try await ContainerClient().get(id: id)
    }
}

enum NativeContainerCreateReconciliation: Sendable {
    case committed(ContainerSnapshot)
    case absent
    case conflicting(ContainerSnapshot)
    case unavailable
}

enum NativeContainerCreateCommitResult: Sendable {
    case committed(ContainerSnapshot)
    case definitivelyFailed(any Error)
    case indeterminate(any Error)
    case conflicting(ContainerSnapshot, any Error)
}

/// One-shot convergence guard installed immediately after a create reservation
/// is acquired. Both explicit success/failure paths and the handler's defer may
/// call `converge()`; exactly one call reaches the atomic lease reconciler.
/// Ambiguous native create hands ownership to its detached state-reconciliation
/// loop, preventing the handler defer from releasing the reservation early.
actor ContainerCreateLeaseConvergence {
    private enum State {
        case active
        case converging
        case converged
        case handedOff
    }

    private var state = State.active
    private let rootDescriptor: Descriptor
    private let reservation: ContainerImageLeaseReservation
    private let reconciler: any ContainerImageLeaseReconciling

    init(
        rootDescriptor: Descriptor,
        reservation: ContainerImageLeaseReservation,
        reconciler: any ContainerImageLeaseReconciling
    ) {
        self.rootDescriptor = rootDescriptor
        self.reservation = reservation
        self.reconciler = reconciler
    }

    func converge() async {
        guard case .active = state else { return }
        state = .converging
        await reconciler.reconcile(
            rootDescriptor: rootDescriptor,
            releasing: reservation
        )
        state = .converged
    }

    func handOff() {
        guard case .active = state else { return }
        state = .handedOff
    }
}

struct NativeContainerCreateCommitter: Sendable {
    let client: any NativeContainerCreating
    let mutationCoordinator: ImageMutationCoordinator
    let leaseManager: any ContainerImageLeasing
    let reconciliationAttempts: Int
    let reconciliationDelay: Duration

    init(
        client: any NativeContainerCreating = LiveNativeContainerCreator(),
        mutationCoordinator: ImageMutationCoordinator,
        leaseManager: any ContainerImageLeasing,
        reconciliationAttempts: Int = 3,
        reconciliationDelay: Duration = .milliseconds(50)
    ) {
        self.client = client
        self.mutationCoordinator = mutationCoordinator
        self.leaseManager = leaseManager
        self.reconciliationAttempts = max(1, reconciliationAttempts)
        self.reconciliationDelay = reconciliationDelay
    }

    /// Commits create while the immutable image lease is protected from image
    /// mutation. On an error, a detached fresh-client lookup distinguishes a
    /// committed server operation from a definitive pre-commit failure.
    func commit(
        configuration: ContainerConfiguration,
        options: ContainerCreateOptions,
        kernel: Kernel,
        lease: ContainerImageLease
    ) async -> NativeContainerCreateCommitResult {
        do {
            try await mutationCoordinator.withMutationExcluded {
                try await leaseManager.verify(lease)
                try await client.create(
                    configuration: configuration,
                    options: options,
                    kernel: kernel
                )
            }

            // The server acknowledged create after persisting the configuration
            // and publishing its in-memory snapshot. Avoid a second XPC call in
            // the success path; Docker create only needs the immutable snapshot.
            return .committed(
                ContainerSnapshot(
                    configuration: configuration,
                    status: .stopped,
                    networks: []
                )
            )
        } catch {
            let originalError = error
            let reconciliation = await Self.reconcile(
                expected: configuration,
                using: client,
                attempts: reconciliationAttempts,
                delay: reconciliationDelay
            )
            switch reconciliation {
            case .committed(let snapshot):
                return .committed(snapshot)
            case .conflicting(let snapshot):
                return .conflicting(snapshot, originalError)
            case .absent:
                if Self.isAmbiguousTransportFailure(originalError) {
                    // A cancelled/interrupted request may still be executing in
                    // Apple's service after its unlocked list reports absent.
                    return .indeterminate(originalError)
                }
                return .definitivelyFailed(originalError)
            case .unavailable:
                return .indeterminate(originalError)
            }
        }
    }

    static func reconcile(
        expected: ContainerConfiguration,
        using client: any NativeContainerCreating,
        attempts: Int = 3,
        delay: Duration = .milliseconds(50)
    ) async -> NativeContainerCreateReconciliation {
        let attemptCount = max(1, attempts)
        return await Task.detached(priority: .utility) {
            var everyAttemptConfirmedAbsent = true
            for attempt in 0..<attemptCount {
                do {
                    let snapshot = try await client.get(id: expected.id)
                    if Self.configurationsExactlyMatch(
                        snapshot.configuration,
                        expected
                    ) {
                        return .committed(snapshot)
                    }
                    return .conflicting(snapshot)
                } catch {
                    if !Self.isNotFound(error) {
                        everyAttemptConfirmedAbsent = false
                    }
                }

                if attempt + 1 < attemptCount {
                    try? await Task.sleep(for: delay)
                }
            }
            return everyAttemptConfirmedAbsent ? .absent : .unavailable
        }.value
    }

    static func configurationsExactlyMatch(
        _ left: ContainerConfiguration,
        _ right: ContainerConfiguration
    ) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard
            let leftData = try? encoder.encode(left),
            let rightData = try? encoder.encode(right)
        else {
            return false
        }
        return leftData == rightData
    }

    static func isAmbiguousTransportFailure(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        guard let containerError = error as? ContainerizationError else {
            return false
        }
        if containerError.code == .cancelled
            || containerError.code == .interrupted
            || containerError.code == .timeout
        {
            return true
        }
        guard let cause = containerError.cause else { return false }
        return isAmbiguousTransportFailure(cause)
    }

    static func isNotFound(_ error: any Error) -> Bool {
        guard let containerError = error as? ContainerizationError else {
            return false
        }
        if containerError.code == .notFound { return true }
        guard let cause = containerError.cause else { return false }
        return isNotFound(cause)
    }
}
