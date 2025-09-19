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
        // filter out infra images
        let filteredImages = try await ClientImage.list().filter { img in
            !Utility.isInfraImage(name: img.reference)
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
            reference = "\(image):\(tag)"
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
                                logger.debug("[ImagePullEvent]: \(event)")
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
