import CryptoKit
import Foundation
import Logging

/// Creates (or updates) a Docker context named "socktainer" pointing at the
/// local Unix socket, so users can run `docker context use socktainer` instead
/// of exporting DOCKER_HOST on every session.
///
/// Docker stores contexts under ~/.docker/contexts/meta/<sha256(name)>/meta.json.
/// The TLS directory must also exist (empty) for Docker CLI to accept the context.
enum DockerContextSetup {
    static let contextName = "socktainer"
    /// SHA256 hex digest of `contextName` — the directory name Docker uses for context storage.
    static let contextDirName: String = {
        let hash = SHA256.hash(data: Data(contextName.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }()
    private static let log = Logger(label: "socktainer.context")

    static func install(homeDirectory: String) {
        let socketPath = "\(homeDirectory)/.socktainer/container.sock"
        let dirName = contextDirName

        let metaDir = "\(homeDirectory)/.docker/contexts/meta/\(dirName)"
        let tlsDir = "\(homeDirectory)/.docker/contexts/tls/\(dirName)/docker"
        let metaFile = "\(metaDir)/meta.json"

        let payload: [String: Any] = [
            "Name": contextName,
            "Metadata": ["Description": "Socktainer — Docker API over Apple Container"],
            "Endpoints": [
                "docker": [
                    "Host": "unix://\(socketPath)",
                    "SkipTLSVerify": false,
                ]
            ],
        ]

        do {
            let fm = FileManager.default
            try fm.createDirectory(atPath: metaDir, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: tlsDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: metaFile))
            log.info("Docker context '\(contextName)' ready — run: docker context use \(contextName)")
        } catch {
            log.warning("Could not install Docker context '\(contextName)': \(error)")
        }
    }
}
