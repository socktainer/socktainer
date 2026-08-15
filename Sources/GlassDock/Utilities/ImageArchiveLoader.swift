import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import Containerization
import Foundation

struct ImageArchiveLoadResult: Sendable {
    let images: [ClientImage]
    let rejectedMembers: [String]
}

/// Localizes the Apple Container write boundary used by Docker load/import.
/// Production goes through the image service's XPC serializer. Tests can inject
/// an isolated ImageStore so crafted fixtures never reach the user's live store.
protocol ImageArchiveLoading: Sendable {
    func load(
        ociLayoutPath: URL,
        archivePath: URL
    ) async throws -> ImageArchiveLoadResult
}

struct LiveImageArchiveLoader: ImageArchiveLoading {
    func load(
        ociLayoutPath: URL,
        archivePath: URL
    ) async throws -> ImageArchiveLoadResult {
        let result = try await ClientImage.load(from: archivePath.path)
        return ImageArchiveLoadResult(
            images: result.images,
            rejectedMembers: result.rejectedMembers
        )
    }
}

/// Test/local-store adapter. Keep this explicit rather than selecting a backend
/// from a path heuristic: production must never fall back to an independent
/// direct ImageStore writer for Apple's shared store.
struct LocalImageArchiveStore: ImageArchiveLoading, ImageReferenceStore {
    private let imageStore: ImageStore

    init(path: URL) throws {
        imageStore = try ImageStore(path: path)
    }

    func load(
        ociLayoutPath: URL,
        archivePath: URL
    ) async throws -> ImageArchiveLoadResult {
        let images = try await imageStore.load(from: ociLayoutPath)
        return ImageArchiveLoadResult(
            images: images.map(Self.clientImage),
            rejectedMembers: []
        )
    }

    func list() async throws -> [ClientImage] {
        try await imageStore.list().map(Self.clientImage)
    }

    func tag(existing: String, new: String) async throws -> ClientImage {
        Self.clientImage(try await imageStore.tag(existing: existing, new: new))
    }

    func delete(reference: String) async throws {
        try await imageStore.delete(reference: reference, performCleanup: false)
    }

    func cleanUpOrphanedBlobs() async throws -> UInt64 {
        let (_, freed) = try await imageStore.cleanUpOrphanedBlobs()
        return freed
    }

    private static func clientImage(_ image: Containerization.Image) -> ClientImage {
        ClientImage(
            description: ImageDescription(
                reference: image.reference,
                descriptor: image.descriptor
            )
        )
    }
}
