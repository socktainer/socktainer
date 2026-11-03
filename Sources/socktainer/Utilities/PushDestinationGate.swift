import Foundation

/// Serializes the retag → push → restore cycle on a push destination.
///
/// A push to a destination other than the source's own reference works by pointing the
/// destination tag at the source image, pushing, then restoring what the tag held before. Two
/// overlapping cycles on the same destination would each see the other's temporary tag as the
/// "prior" state and could leave the wrong image behind (or push the wrong source), so a cycle
/// holds the destination's gate for its whole duration.
///
/// The gate is a lease: if a holder never releases (e.g. the client vanished before the response
/// stream that restores the tag ever ran) the next caller proceeds once the lease expires, rather
/// than waiting forever.
actor PushDestinationGate {
    static let shared = PushDestinationGate()

    private struct Lease {
        let token: UUID
        let expires: Date
    }

    private var leases: [String: Lease] = [:]
    private let leaseDuration: TimeInterval
    private let pollInterval: Duration

    init(leaseDuration: TimeInterval = 15 * 60, pollInterval: Duration = .milliseconds(100)) {
        self.leaseDuration = leaseDuration
        self.pollInterval = pollInterval
    }

    /// Waits until no unexpired lease is held on `destination`, then takes it. The returned token
    /// identifies this holder to `release`. Throws `CancellationError` if the waiting task is
    /// cancelled; a cancelled waiter holds no lease.
    func acquire(_ destination: String) async throws -> UUID {
        while let lease = leases[destination], lease.expires > Date() {
            try await Task.sleep(for: pollInterval)
        }
        let token = UUID()
        leases[destination] = Lease(token: token, expires: Date().addingTimeInterval(leaseDuration))
        return token
    }

    /// Releases `destination` if `token` still owns it (an expired holder must not release a
    /// lease that has since passed to someone else).
    func release(_ destination: String, token: UUID?) {
        guard let token, leases[destination]?.token == token else { return }
        leases[destination] = nil
    }
}
