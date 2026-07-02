import Foundation

/// Translates the Docker idiom for SSH agent forwarding into Apple Container's
/// native SSH agent relay.
///
/// On Linux, `docker run -v $SSH_AUTH_SOCK:/ssh-agent -e SSH_AUTH_SOCK=/ssh-agent`
/// bind-mounts the agent socket directly — host and containers share one kernel.
/// Apple Container runs each container in its own VM, so a Unix socket cannot
/// cross that boundary as a shared file; it must be relayed. Apple Container
/// ships exactly such a relay (`container run --ssh`): setting
/// `ContainerConfiguration.ssh = true` makes the runtime relay the host socket
/// named by the `SSH_AUTH_SOCK` entry of the bootstrap `dynamicEnv` to a fixed
/// guest path, and point every process's `SSH_AUTH_SOCK` at that path.
///
/// Detection is deliberately narrow so that unrelated Unix-socket mounts
/// (gpg-agent, docker.sock, ...) never trigger the SSH relay. A bind mount is
/// treated as SSH agent forwarding only when:
/// 1. the container environment declares `SSH_AUTH_SOCK=<mount target>` —
///    the standard Docker recipe, or
/// 2. the mount source is the host's own `$SSH_AUTH_SOCK` socket, or
/// 3. the mount source is Docker Desktop's well-known in-VM relay path,
///    accepted for compatibility with configurations written for Docker
///    Desktop on macOS (that path never exists on the host itself).
enum SSHAgentForwarding {
    /// Guest path used by Apple Container's SSH relay (RuntimeService).
    static let guestSocketPath = "/var/host-services/ssh-auth.sock"

    /// Docker Desktop's in-VM relay path. Never exists on the macOS host, so
    /// mounting it unambiguously means "forward my SSH agent".
    static let dockerDesktopSocketPath = "/run/host-services/ssh-auth.sock"

    /// Label carrying the host socket path from create to start, where it is
    /// passed to bootstrap as the relay source via `dynamicEnv`.
    static let hostPathLabel = "socktainer.ssh-auth-sock.host-path"

    static let environmentVariable = "SSH_AUTH_SOCK"

    struct Match: Equatable {
        /// Host socket the runtime should relay into the guest.
        let hostPath: String
        /// Mount source string as it appeared in the request, used to exclude
        /// the mount from filesystem processing.
        let source: String
        /// The env-declared target to rewrite to `guestSocketPath`, if any.
        let declaredTarget: String?
    }

    static func isUnixSocket(_ path: String) -> Bool {
        var status = stat()
        guard stat(path, &status) == 0 else { return false }
        return (status.st_mode & S_IFMT) == S_IFSOCK
    }

    /// The value of `SSH_AUTH_SOCK` declared in a `KEY=VALUE` environment list.
    static func declaredSocketPath(env: [String]) -> String? {
        let prefix = environmentVariable + "="
        return env.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    /// Scans bind-mount candidates for the SSH agent forwarding idiom.
    /// `candidates` are (source, target) pairs from `HostConfig.Binds` and
    /// bind-type `HostConfig.Mounts`.
    static func detect(
        candidates: [(source: String, target: String)],
        containerEnv: [String],
        hostEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Match? {
        let declared = declaredSocketPath(env: containerEnv)
        let hostAgent = hostEnvironment[environmentVariable]

        for candidate in candidates {
            if candidate.source == dockerDesktopSocketPath {
                guard let hostAgent, isUnixSocket(hostAgent) else { continue }
                return Match(
                    hostPath: hostAgent,
                    source: candidate.source,
                    declaredTarget: declared == candidate.target ? declared : nil
                )
            }
            if let declared, declared == candidate.target, isUnixSocket(candidate.source) {
                return Match(hostPath: candidate.source, source: candidate.source, declaredTarget: declared)
            }
            if let hostAgent, candidate.source == hostAgent, isUnixSocket(candidate.source) {
                return Match(
                    hostPath: candidate.source,
                    source: candidate.source,
                    declaredTarget: declared == candidate.target ? declared : nil
                )
            }
        }
        return nil
    }

    /// Rewrites a declared `SSH_AUTH_SOCK=<target>` entry to the fixed guest
    /// relay path, so the standard Docker recipe works unchanged even though
    /// the relay socket lands at `guestSocketPath` rather than the requested
    /// target.
    static func rewriteEnv(_ env: [String], declaredTarget: String) -> [String] {
        let declaredEntry = "\(environmentVariable)=\(declaredTarget)"
        let guestEntry = "\(environmentVariable)=\(guestSocketPath)"
        return env.map { $0 == declaredEntry ? guestEntry : $0 }
    }

    /// The `dynamicEnv` to pass to bootstrap for a container created with SSH
    /// forwarding: the runtime reads the relay's host socket path from the
    /// `SSH_AUTH_SOCK` entry (RuntimeService.sshAuthSocketHostUrl).
    static func bootstrapDynamicEnv(labels: [String: String]) -> [String: String] {
        guard let hostPath = labels[hostPathLabel] else { return [:] }
        return [environmentVariable: hostPath]
    }
}
