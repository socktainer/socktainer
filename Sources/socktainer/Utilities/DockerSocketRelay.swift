import Foundation

/// Docker.sock can't be virtiofs-shared into an Apple Container VM, so a bind mount
/// to it is normally dropped and the guest sees "Socket not found" (hit by tools like
/// Supabase's `vector`, which reads container logs over that socket). Apple's runtime
/// already vsock-relays any mount whose host source is a real Unix socket into the
/// guest (the same mechanism `container run --ssh` uses); redirecting the mount's
/// source to socktainer's own control socket makes that relay hand the guest a working
/// Docker API instead.
///
/// Detection keys on the guest *destination*, not the host source: docker-context-aware
/// clients (e.g. supabase-cli) resolve the active context and bind-mount that socket's
/// own path as the source, expecting it to land at `/var/run/docker.sock` in the guest —
/// the source is never the literal string `/var/run/docker.sock` in that case. Only the
/// destination is invariant, so the source is always replaced with socktainer's control
/// socket regardless of what was requested.
enum DockerSocketRelay {
    static let hostDockerSocketPath = "/var/run/docker.sock"

    struct Match: Equatable {
        let guestPath: String
    }

    /// Exact match: this always checks the *guest* destination, and the guest is a Linux
    /// container where paths are case-sensitive — an app inside it looks up the literal
    /// lowercase `/var/run/docker.sock`, so a differently-cased request would relay a mount
    /// no consumer can actually find. (macOS APFS's host-side case-insensitivity is irrelevant
    /// here since this never compares against a host path.)
    static func isDockerSocketPath(_ path: String) -> Bool {
        path == hostDockerSocketPath
    }

    static func detect(candidates: [(source: String, target: String)]) -> Match? {
        candidates.first { isDockerSocketPath($0.target) }.map { Match(guestPath: $0.target) }
    }

    /// Splits a Docker `Binds` entry (`source:target[:mode]`) into its source and target.
    static func bindComponents(_ bind: String) -> (source: String, target: String)? {
        let parts = bind.split(separator: ":").map(String.init)
        guard parts.count >= 2 else { return nil }
        return (source: parts[0], target: parts[1])
    }

    /// Mirrors the path `SocketUtility.prepareUnixSocket` binds the server to.
    static func controlSocketPath(homeDirectory: String?) -> String? {
        guard let homeDirectory else { return nil }
        return "\(homeDirectory)/.socktainer/container.sock"
    }
}
