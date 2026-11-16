import ContainerAPIClient
import ContainerPersistence
import ContainerizationOCI
import Logging

/// Resolves an image the way Docker does: by reference, by `repository@sha256:<digest>`, or by (short) image ID.
///
/// `ClientImage.get(reference:)` only understands references, so a bare `sha256:…` or a
/// short hex ID, as reported by `GET /images/json` (index digest) or
/// `GET /images/{name}/json` (config digest), would never match.
enum ImageIDResolver {
    private static let log = Logger(label: "socktainer.imageid")

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

    /// Splits a `repository@sha256:<64 hex>` reference. Returns nil for anything else
    /// (plain references, tags, bare IDs, malformed or non-sha256 digests).
    static func parseDigestReference(_ value: String) -> (repository: String, digest: String)? {
        guard let at = value.lastIndex(of: "@") else { return nil }
        let repository = String(value[..<at])
        let digest = String(value[value.index(after: at)...])
        guard !repository.isEmpty, digest.hasPrefix("sha256:") else { return nil }
        let hex = digest.dropFirst("sha256:".count)
        guard hex.count == 64, hex.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return nil }
        return (repository, digest)
    }

    /// `reference` without its digest and tag.
    static func repositoryWithoutTag(_ reference: String) -> String {
        var name = reference
        if let at = name.firstIndex(of: "@") { name = String(name[..<at]) }
        // A ':' after the last '/' is a tag; one before it is a registry port.
        if let colon = name.lastIndex(of: ":"), !(name[colon...].contains("/")) { name = String(name[..<colon]) }
        return name
    }

    /// The repository part of a reference, normalized the way Docker does for comparison:
    /// no tag, no digest, and without the implicit `docker.io/` and `library/` defaults.
    static func normalizedRepository(_ reference: String) -> String {
        var name = repositoryWithoutTag(reference)
        for prefix in ["index.docker.io/", "registry-1.docker.io/", "docker.io/"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        if name.hasPrefix("library/") { name = String(name.dropFirst("library/".count)) }
        return name
    }

    static func repositoryMatches(_ lhs: String, _ rhs: String) -> Bool {
        normalizedRepository(lhs) == normalizedRepository(rhs)
    }

    /// The repository of a `repository@sha256:<digest>` reference, qualified the way
    /// `ClientImage.get` qualifies a reference: with the configured default registry unless it
    /// already names one. Falls back to the repository as given when it cannot be normalized.
    static func qualifiedRepository(_ repository: String, containerSystemConfig: ContainerSystemConfig) -> String {
        // normalizeReference also appends the default tag, which is not part of the repository.
        repositoryWithoutTag((try? ClientImage.normalizeReference(repository, containerSystemConfig: containerSystemConfig)) ?? repository)
    }

    enum DigestMatch: Equatable {
        /// The digest is the image's index digest.
        case index
        /// The digest is a per-platform manifest digest (platform is nil when the descriptor has none).
        case manifest(Platform?)
    }

    /// How `digest` relates to an image: its index digest, or one of its per-platform manifest
    /// digests, or neither.
    ///
    /// Both are accepted because `RepoDigests` reports the manifest digest of the selected
    /// platform, while `docker pull` prints the index digest.
    static func digestMatch(
        _ digest: String,
        indexDigest: String,
        manifests: [(digest: String, platform: Platform?)]
    ) -> DigestMatch? {
        if digest == indexDigest { return .index }
        if let hit = manifests.first(where: { $0.digest == digest }) { return .manifest(hit.platform) }
        return nil
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
            if let parsed = parseDigestReference(refOrId) {
                // Qualify the repository the way ClientImage.get does, so the configured default
                // registry applies and the same digest under another registry never matches.
                let repository = qualifiedRepository(parsed.repository, containerSystemConfig: containerSystemConfig)
                for image in try await ClientImage.list() where repositoryMatches(repository, image.reference) {
                    // Only images of the requested repository get their index read.
                    if image.digest == parsed.digest {
                        return Resolved(image: image, platform: nil, byID: true)
                    }
                    var manifests: [(digest: String, platform: Platform?)] = []
                    do {
                        manifests = try await image.index().manifests.map { (digest: $0.digest, platform: $0.platform) }
                    } catch {
                        // Skipped rather than failed: the caller still gets the original "not found".
                        log.debug("could not read the index of \(image.reference) while resolving \(refOrId): \(error)")
                    }
                    switch digestMatch(parsed.digest, indexDigest: image.digest, manifests: manifests) {
                    case .manifest(let platform)?:
                        return Resolved(image: image, platform: platform, byID: true)
                    case .index?, nil:
                        continue
                    }
                }
                throw error
            }
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
