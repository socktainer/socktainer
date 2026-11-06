import ContainerAPIClient
import ContainerResource
import Foundation

public enum MobyContainerStatus {
    public static func toMobyState(_ appleStatus: RuntimeStatus) -> String {
        switch appleStatus {
        case .running:
            return "running"
        case .stopped:
            return "exited"
        case .stopping:
            return "exited"
        case .unknown:
            return "created"
        }
    }
}

/// Extension to RuntimeStatus to add Moby-compliant properties
extension RuntimeStatus {
    public var mobyState: String {
        MobyContainerStatus.toMobyState(self)
    }
}

extension ContainerSnapshot {
    /// True for a container that was created but has never booted.
    ///
    /// `RuntimeStatus` has no `created` case, so this has to be derived, and
    /// neither signal suffices alone: `startedDate` lives in the apiserver's
    /// memory and is lost across `container system stop`, while `rootfs.ext4`
    /// is provisioned at start and outlives the stop but can be removed
    /// out-of-band. Requiring both keeps a container that ran before a daemon
    /// restart out of the `created` bucket. Same check `rename` admits on.
    public var hasNeverStarted: Bool {
        guard status == .stopped, startedDate == nil else { return false }
        let rootfs = AppleContainerTimestampResolver.appSupportURL
            .appendingPathComponent("containers").appendingPathComponent(id)
            .appendingPathComponent("rootfs.ext4")
        return !FileManager.default.fileExists(atPath: rootfs.path)
    }

    /// Docker's `State.Status` for this container.
    ///
    /// Prefer this over `status.mobyState`: `RuntimeStatus` alone cannot tell a
    /// never-started container from a stopped one and reports both as `exited`.
    public var mobyState: String {
        hasNeverStarted ? "created" : status.mobyState
    }
}
