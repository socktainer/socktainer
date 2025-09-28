import ContainerClient
import Containerization
import ContainerizationOCI
import Foundation
import Logging
import TerminalProgress

protocol ClientImageProtocol: Sendable {
    func list() async throws -> [ClientImage]
    func delete(id: String) async throws
    func pull(image: String, tag: String?, platform: Platform, registryAuth: AuthConfig?, logger: Logger) async throws -> AsyncThrowingStream<String, Error>
}

enum ClientImageError: Error {
    case notFound(id: String)
}

struct ClientImageService: ClientImageProtocol {

    func list() async throws -> [ClientImage] {
        let allImages = try await ClientImage.list()
        // filter out infra images
        // also filter images based on digests
        let filteredImages = allImages.filter { img in
            let ref = img.reference.trimmingCharacters(in: .whitespacesAndNewlines)
            let isDigest = ref.contains("@sha256:")
            let isInfra = Utility.isInfraImage(name: ref)
            return isDigest || !isInfra
        }
        return filteredImages
    }

    func delete(id: String) async throws {
        do {
            _ = try await ClientImage.get(reference: id)
        } catch {
            // Handle specific error if needed
            throw ClientImageError.notFound(id: id)
        }
        try await ClientImage.delete(reference: id, garbageCollect: false)
    }

    func pull(image: String, tag: String?, platform: Platform, registryAuth: AuthConfig?, logger: Logger) async throws -> AsyncThrowingStream<String, Error> {
        let normalizedImage = RegistryUtility.normalizeImageReference(image)
        let reference: String
        if let tag = tag, !tag.isEmpty {
            if tag.starts(with: "sha256:") {
                reference = "\(normalizedImage)@\(tag)"
            } else {
                reference = "\(normalizedImage):\(tag)"
            }
        } else {
            reference = normalizedImage
        }

        logger.info("Pulling image reference: \(reference)")

        // Create authentication from X-Registry-Auth header if provided
        let authentication: Authentication? = {
            guard let auth = registryAuth else {
                logger.debug("No registry authentication provided")
                return nil
            }

            guard let username = auth.username, let password = auth.password else {
                logger.debug("Registry auth missing username or password")
                return nil
            }

            logger.debug("Creating BasicAuthentication for user: \(username)")
            return BasicAuthentication(username: username, password: password)
        }()

        return AsyncThrowingStream { continuation in
            logger.info("Starting to pull image \(reference) for platform \(platform.description)")
            continuation.yield("Trying to pull \(reference)")
            Task {
                do {
                    // Use the same ImageStore path as the daemon to ensure images are registered properly
                    let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    let daemonRoot = appSupportDir.appendingPathComponent("com.apple.container")
                    let imageStore = try ImageStore(path: daemonRoot)

                    // Use ImageStore.pull directly with authentication
                    let image = try await imageStore.pull(
                        reference: reference,
                        platform: platform,
                        insecure: false,  //Should be revisited later
                        auth: authentication,
                        progress: { progressEvents in
                            for event in progressEvents {
                                switch event.event {
                                case "add-total-size":
                                    if let size = event.value as? UInt64 {
                                        let humanReadableSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                                        let message = "Downloaded \(humanReadableSize)"
                                        continuation.yield(message)
                                    } else if let size = event.value as? Int64 {
                                        let humanReadableSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                                        let message = "Downloaded \(humanReadableSize)"
                                        continuation.yield(message)
                                    }
                                case "add-total-items":
                                    if let items = event.value as? Int {
                                        let message = "Processing \(items) layer\(items == 1 ? "" : "s")"
                                        continuation.yield(message)
                                    }
                                default:
                                    logger.debug("Progress event: \(event.event) = \(event.value)")
                                }
                            }
                        }
                    )
                    logger.info("Successfully pulled image \(reference) for platform \(platform.description)")
                    continuation.yield("Image digest: \(image.digest)")
                    continuation.finish()
                } catch {
                    logger.error("Failed to pull image \(reference): \(error)")
                    continuation.yield(String(describing: error))
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
