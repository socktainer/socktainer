import ContainerAPIClient
import ContainerPersistence
import ContainerizationError
import ContainerizationOCI
import TerminalProgress

struct PulledImageResult: Sendable {
    let image: ClientImage
    /// The registry descriptor selected by the pull. Apple stores a
    /// single-manifest pull behind a synthetic indirect index, whose local
    /// digest is not a pullable distribution identity.
    let distributionDigest: String
}

protocol ImagePulling: Sendable {
    func pullAndUnpack(
        reference: String,
        platform: Platform,
        containerSystemConfig: ContainerSystemConfig,
        downloadProgress: ProgressUpdateHandler?,
        unpackProgress: ProgressUpdateHandler?
    ) async throws -> PulledImageResult
}

struct LiveImagePuller: ImagePulling {
    func pullAndUnpack(
        reference: String,
        platform: Platform,
        containerSystemConfig: ContainerSystemConfig,
        downloadProgress: ProgressUpdateHandler?,
        unpackProgress: ProgressUpdateHandler?
    ) async throws -> PulledImageResult {
        let image = try await ClientImage.pull(
            reference: reference,
            platform: platform,
            containerSystemConfig: containerSystemConfig,
            progressUpdate: downloadProgress
        )
        try await image.unpack(
            platform: platform,
            progressUpdate: unpackProgress
        )
        let index = try await image.index()
        let distributionDigest = try Self.distributionDigest(
            storedDigest: image.digest,
            index: index
        )
        return PulledImageResult(
            image: image,
            distributionDigest: distributionDigest
        )
    }

    static func distributionDigest(
        storedDigest: String,
        index: Index
    ) throws -> String {
        let indirect = index.annotations?[
            AnnotationKeys.containerizationIndexIndirect
        ]
        if let indirect, ["1", "true"].contains(indirect.lowercased()) {
            guard index.manifests.count == 1,
                let manifest = index.manifests.first
            else {
                throw ContainerizationError(
                    .internalError,
                    message:
                        "indirect image index \(storedDigest) does not contain exactly one manifest"
                )
            }
            return manifest.digest
        }
        return storedDigest
    }
}
