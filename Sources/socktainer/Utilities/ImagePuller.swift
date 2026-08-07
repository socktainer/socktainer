import ContainerAPIClient
import ContainerPersistence
import ContainerizationOCI
import TerminalProgress

protocol ImagePulling: Sendable {
    func pullAndUnpack(
        reference: String,
        platform: Platform,
        containerSystemConfig: ContainerSystemConfig,
        downloadProgress: ProgressUpdateHandler?,
        unpackProgress: ProgressUpdateHandler?
    ) async throws -> ClientImage
}

struct LiveImagePuller: ImagePulling {
    func pullAndUnpack(
        reference: String,
        platform: Platform,
        containerSystemConfig: ContainerSystemConfig,
        downloadProgress: ProgressUpdateHandler?,
        unpackProgress: ProgressUpdateHandler?
    ) async throws -> ClientImage {
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
        return image
    }
}
