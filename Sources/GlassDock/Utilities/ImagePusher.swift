import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import TerminalProgress

/// Localizes the registry side effect used by Docker push. Besides keeping the
/// service testable, this boundary makes the reference passed to Apple's exact-
/// key image store explicit: it must be the canonical, host-qualified key that
/// Glass Dock reconciled before starting the push.
protocol ImagePushing: Sendable {
    func push(
        image: ClientImage,
        platform: Platform?,
        scheme: RequestScheme,
        containerSystemConfig: ContainerSystemConfig,
        progressUpdate: ProgressUpdateHandler?
    ) async throws
}

struct LiveImagePusher: ImagePushing {
    func push(
        image: ClientImage,
        platform: Platform?,
        scheme: RequestScheme,
        containerSystemConfig: ContainerSystemConfig,
        progressUpdate: ProgressUpdateHandler?
    ) async throws {
        try await image.push(
            platform: platform,
            scheme: scheme,
            containerSystemConfig: containerSystemConfig,
            progressUpdate: progressUpdate
        )
    }
}
