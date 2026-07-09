import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation

/// Builds a minimal `ContainerSnapshot` for lifecycle/DNS tests, attached to each of
/// `networks` in order. Callers supply the labels that make their scenario distinct
/// (restart policy, Compose service, etc.) — everything else is fixed test scaffolding.
func makeContainerSnapshot(
    nativeId: String,
    networks: [(network: String, ip: String)],
    labels: [String: String],
    status: RuntimeStatus = .stopped
) throws -> ContainerSnapshot {
    let proc = ProcessConfiguration(
        executable: "/bin/sh", arguments: [], environment: [],
        workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0)
    )
    let img = ImageDescription(
        reference: "alpine:latest",
        descriptor: Descriptor(
            mediaType: "application/vnd.oci.image.index.v1+json",
            digest: "sha256:abc", size: 0
        )
    )
    var config = ContainerConfiguration(id: nativeId, image: img, process: proc)
    config.labels = labels

    // Attachment is Codable — use JSON to avoid depending on internal CIDRv4/IPv4Address inits.
    let attachments = try networks.map { entry -> Attachment in
        let attachmentJSON = """
            {
                "network": "\(entry.network)",
                "hostname": "\(nativeId)",
                "ipv4Address": "\(entry.ip)/24",
                "ipv4Gateway": "192.168.65.1",
                "ipv6Address": null,
                "macAddress": null
            }
            """.data(using: .utf8)!
        return try JSONDecoder().decode(Attachment.self, from: attachmentJSON)
    }

    return ContainerSnapshot(configuration: config, status: status, networks: attachments)
}

/// Single-network convenience for the common case — see `makeContainerSnapshot(nativeId:networks:labels:status:)`.
func makeContainerSnapshot(
    nativeId: String,
    ip: String,
    network: String,
    labels: [String: String],
    status: RuntimeStatus = .stopped
) throws -> ContainerSnapshot {
    try makeContainerSnapshot(nativeId: nativeId, networks: [(network: network, ip: ip)], labels: labels, status: status)
}
