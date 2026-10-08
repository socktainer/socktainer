import ContainerAPIClient
import ContainerNetworkClient
import ContainerResource
import Foundation

/// Apple Container writes the guest's `/etc/hosts` itself and has no way to add entries
/// (apple/container#1563), so `HostConfig.ExtraHosts` would be dropped. As Docker and
/// Podman do, socktainer generates the file on the host and bind-mounts it over
/// `/etc/hosts`. The container's own `<ip> <hostname>` line is only known once the
/// network is attached, so the file is rewritten after bootstrap, before the init
/// process starts and the mount is applied.
enum ExtraHostsFile {
    static let label = "socktainer.extra-hosts"
    static let guestPath = "/etc/hosts"
    static let hostGateway = "host-gateway"

    static let root = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/com.apple.container/socktainer-hosts")

    /// Same rules as moby's `ParseExtraHost`: `host=ip`, or the legacy `host:ip` split on
    /// the first colon (so `host:::1` is IPv6). Brackets around an IPv6 address are dropped.
    /// Returns nil unless the address is an IP or `host-gateway` and the host has no
    /// whitespace or control characters, which would inject extra lines into the file,
    /// and no colon, which moby rejects too.
    static func parse(_ entry: String) -> (host: String, ip: String)? {
        let separator: Character = entry.contains("=") ? "=" : ":"
        guard let index = entry.firstIndex(of: separator) else { return nil }
        let host = String(entry[..<index])
        var ip = String(entry[entry.index(after: index)...])
        if ip.hasPrefix("[") && ip.hasSuffix("]") {
            ip = String(ip.dropFirst().dropLast())
        }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: ":"))
        guard !host.isEmpty, host.unicodeScalars.allSatisfy({ !forbidden.contains($0) }),
            ip == hostGateway || isIPAddress(ip)
        else { return nil }
        return (host, ip)
    }

    /// Entries `parse` rejects; a create carrying any of them is refused.
    static func invalidEntries(_ extraHosts: [String]) -> [String] {
        extraHosts.filter { parse($0) == nil }
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, value, &v4) == 1 || inet_pton(AF_INET6, value, &v6) == 1
    }

    static func render(extraHosts: [String], ip: String?, hostname: String, gateway: String?) -> String {
        var lines = [
            "127.0.0.1\tlocalhost",
            "::1\tlocalhost ip6-localhost ip6-loopback",
            "fe00::0\tip6-localnet",
            "ff00::0\tip6-mcastprefix",
            "ff02::1\tip6-allnodes",
            "ff02::2\tip6-allrouters",
        ]
        for entry in extraHosts {
            guard let (host, address) = parse(entry) else { continue }
            if address == hostGateway {
                guard let gateway else { continue }
                lines.append("\(gateway)\t\(host)")
            } else {
                lines.append("\(address)\t\(host)")
            }
        }
        if let ip {
            lines.append("\(ip)\t\(hostname)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the initial file for a container being created. Returns the mount to add and
    /// the value for `label`: the file's directory, a fresh UUID so a create that collides
    /// with an existing name never touches that container's file.
    static func create(extraHosts: [String], hostname: String) throws -> (mount: Filesystem, label: String) {
        let name = UUID().uuidString.lowercased()
        let directory = root.appendingPathComponent(name)
        let file = directory.appendingPathComponent("hosts")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(extraHosts).write(to: directory.appendingPathComponent("extra-hosts.json"))
            try render(extraHosts: extraHosts, ip: nil, hostname: hostname, gateway: nil)
                .write(to: file, atomically: false, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return (.virtiofs(source: file.path, destination: guestPath, options: []), name)
    }

    private static func directory(labels: [String: String]) -> URL? {
        guard let name = labels[label], !name.isEmpty, !name.contains("/"), name != "..", name != "." else { return nil }
        return root.appendingPathComponent(name)
    }

    /// Call after `bootstrap`, before `process.start()`: adds the container's own address
    /// and resolves `host-gateway` now that the network is attached. Throws so the caller
    /// does not start a container whose `/etc/hosts` lacks the requested entries.
    static func refresh(containerId: String) async throws {
        let snapshot = try await ContainerClient().get(id: containerId)
        let configuration = snapshot.configuration
        guard let directory = directory(labels: configuration.labels) else { return }
        let extraHosts = try JSONDecoder().decode(
            [String].self, from: Data(contentsOf: directory.appendingPathComponent("extra-hosts.json")))
        let hostname = configuration.networks.first?.options.hostname ?? configuration.id
        var attachment = snapshot.networks.first
        if attachment == nil {
            attachment = try await allocatedAttachment(configuration)
        }
        let content = render(
            extraHosts: extraHosts,
            ip: stripSubnetFromIP(attachment.map { String(describing: $0.ipv4Address) }),
            hostname: hostname,
            gateway: attachment.map { String(describing: $0.ipv4Gateway) })
        try content.write(to: directory.appendingPathComponent("hosts"), atomically: false, encoding: .utf8)
    }

    /// A booted container reports no networks until its init process runs, but the
    /// network plugin already holds the address it allocated at bootstrap.
    private static func allocatedAttachment(_ configuration: ContainerConfiguration) async throws -> Attachment? {
        guard let network = configuration.networks.first else { return nil }
        let plugin = try await ContainerAPIClient.NetworkClient().get(id: network.network).configuration.plugin
        return try await ContainerNetworkClient.NetworkClient(id: network.network, plugin: plugin)
            .lookup(hostname: network.options.hostname)
    }

    static func remove(labels: [String: String]) {
        if let directory = directory(labels: labels) {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
