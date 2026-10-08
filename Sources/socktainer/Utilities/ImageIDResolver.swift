import ContainerAPIClient
import ContainerPersistence

/// Resolves an image the way Docker does: by reference, or by (short) image ID.
///
/// `ClientImage.get(reference:)` only understands references, so a bare `sha256:…` or a
/// short hex ID, as reported by `GET /images/json` (index digest) or
/// `GET /images/{name}/json` (config digest), would never match.
enum ImageIDResolver {
    /// The bare lowercase hex of `value` if it looks like an image ID
    /// (`sha256:` optional, 12–64 hex chars), otherwise nil.
    static func candidateID(_ value: String) -> String? {
        let hex = value.hasPrefix("sha256:") ? String(value.dropFirst("sha256:".count)) : value
        guard (12...64).contains(hex.count), hex.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            return nil
        }
        return hex
    }

    static func matches(_ hex: String, digest: String) -> Bool {
        digest.hasPrefix("sha256:") && digest.dropFirst("sha256:".count).hasPrefix(hex)
    }

    // Linear scan over every image; on an ambiguous short prefix the first match wins
    // (Docker rejects it instead).
    static func get(_ refOrId: String, containerSystemConfig: ContainerSystemConfig) async throws -> ClientImage {
        do {
            return try await ClientImage.get(reference: refOrId, containerSystemConfig: containerSystemConfig)
        } catch {
            guard let hex = candidateID(refOrId) else { throw error }
            let images = try await ClientImage.list()
            if let image = images.first(where: { matches(hex, digest: $0.digest) }) {
                return image
            }
            for image in images {
                guard let manifests = try? await image.index().manifests else { continue }
                for descriptor in manifests {
                    guard let platform = descriptor.platform,
                        let manifest = try? await image.manifest(for: platform)
                    else { continue }
                    if matches(hex, digest: manifest.config.digest) {
                        return image
                    }
                }
            }
            throw error
        }
    }
}
