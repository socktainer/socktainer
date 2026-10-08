import ContainerAPIClient
import ContainerPersistence
import ContainerizationOCI

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

    struct Candidate {
        let digest: String
        let configs: [(platform: Platform, digest: String)]
    }

    struct Match: Equatable {
        let digest: String
        /// The platform whose config digest matched; nil when the index digest matched.
        let platform: Platform?
    }

    /// The single image `hex` identifies, or nil when no image or more than one distinct
    /// image matches (Docker rejects an ambiguous prefix).
    static func uniqueMatch(_ hex: String, in candidates: [Candidate]) -> Match? {
        var found: [String: Match] = [:]
        for candidate in candidates {
            if matches(hex, digest: candidate.digest) {
                found[candidate.digest] = Match(digest: candidate.digest, platform: nil)
            } else if let config = candidate.configs.first(where: { matches(hex, digest: $0.digest) }) {
                found[candidate.digest] = Match(digest: candidate.digest, platform: config.platform)
            }
        }
        return found.count == 1 ? found.values.first : nil
    }

    struct Resolved {
        let image: ClientImage
        /// Set when the ID was a platform's config digest, so callers can show that variant.
        let platform: Platform?
        /// True when `refOrId` was resolved as an image ID rather than a reference.
        let byID: Bool
    }

    static func get(_ refOrId: String, containerSystemConfig: ContainerSystemConfig) async throws -> ClientImage {
        try await resolve(refOrId, containerSystemConfig: containerSystemConfig).image
    }

    /// Tries `refOrId` as a reference first, then as an image ID matched against every
    /// image's index digest and per-platform config digests. Rethrows the reference
    /// lookup error when no single image matches.
    static func resolve(_ refOrId: String, containerSystemConfig: ContainerSystemConfig) async throws -> Resolved {
        do {
            let image = try await ClientImage.get(reference: refOrId, containerSystemConfig: containerSystemConfig)
            return Resolved(image: image, platform: nil, byID: false)
        } catch {
            guard let hex = candidateID(refOrId) else { throw error }
            let images = try await ClientImage.list()
            var candidates: [Candidate] = []
            var seen: Set<String> = []
            for image in images where seen.insert(image.digest).inserted {
                var configs: [(platform: Platform, digest: String)] = []
                for descriptor in (try? await image.index().manifests) ?? [] {
                    guard let platform = descriptor.platform,
                        let manifest = try? await image.manifest(for: platform)
                    else { continue }
                    configs.append((platform, manifest.config.digest))
                }
                candidates.append(Candidate(digest: image.digest, configs: configs))
            }
            guard let match = uniqueMatch(hex, in: candidates),
                let image = images.first(where: { $0.digest == match.digest })
            else { throw error }
            return Resolved(image: image, platform: match.platform, byID: true)
        }
    }
}
