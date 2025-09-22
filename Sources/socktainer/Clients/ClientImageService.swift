import ContainerClient
import Foundation
import Logging
import TerminalProgress

protocol ClientImageProtocol: Sendable {
    func list() async throws -> [ClientImage]
    func delete(id: String) async throws
    func pull(image: String, tag: String?, platform: Platform, logger: Logger) async throws -> AsyncThrowingStream<String, Error>
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
            try await ClientImage.get(reference: id)
        } catch {
            // Handle specific error if needed
            throw ClientImageError.notFound(id: id)
        }
        try await ClientImage.delete(reference: id, garbageCollect: false)
    }

    func pull(image: String, tag: String?, platform: Platform, logger: Logger) async throws -> AsyncThrowingStream<String, Error> {
        let reference: String
        if let tag = tag, !tag.isEmpty {
            if tag.starts(with: "sha256:") {
                reference = "\(image)@\(tag)"
            } else {
                reference = "\(image):\(tag)"
            }
        } else {
            reference = image
        }
        return AsyncThrowingStream { continuation in
            logger.info("Starting to pull image \(reference) for platform \(platform.description)")
            continuation.yield("Trying to pull \(reference)")
            Task {
                do {
                    let handler: ProgressUpdateHandler = { events in
                        for event in events {
                            // NOTE: for the time being, the only valuable human readable
                            //       event is the size of the blob
                            switch event {
                            case .addSize(let size), .setSize(let size):
                                let message = "Pulled \(size) bytes"
                                logger.debug("\(message)")
                                continuation.yield(message)
                            default:
                                logger.debug("Image pull event: \(event)")
                            }
                        }
                    }

                    let image = try await ClientImage.fetch(reference: reference, platform: platform, progressUpdate: handler)
                    logger.info("Finished pulling image \(reference) for platform \(platform.description)")
                    continuation.yield(image.digest)
                    continuation.finish()
                } catch {
                    logger.warning("\(error)")
                    continuation.yield(String(describing: error))
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
