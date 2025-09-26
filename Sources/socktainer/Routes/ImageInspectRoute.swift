import ContainerClient
import ContainerizationOCI
import Vapor

struct ImageInspectRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/images/{name:.*}/json", use: ImageInspectRoute.handler(client: client))
    }
}

extension ImageInspectRoute {
    /// Checks if an image name matches the requested name, considering Docker Hub prefixes
    private static func imageMatches(imageName: String, requestedName: String) -> Bool {
        // Exact match
        if imageName == requestedName {
            return true
        }

        // Extract the base name without tag from both names
        let imageBaseName = imageName.components(separatedBy: ":").first ?? imageName
        let requestedBaseName = requestedName.components(separatedBy: ":").first ?? requestedName

        // If requested name contains no registry/namespace, check if image has docker.io/library prefix
        if !requestedBaseName.contains("/") {
            // Check if image has docker.io/library/ prefix
            if imageBaseName == "docker.io/library/\(requestedBaseName)" || imageBaseName == "docker.io/\(requestedBaseName)" {
                return true
            }
        }

        // Check if image base name ends with the requested name (for partial matches)
        if imageBaseName.hasSuffix("/\(requestedBaseName)") {
            return true
        }

        return false
    }

    static func handler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> RESTImageInspect {
        { req in
            guard let imageName = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Missing image name parameter")
            }

            let images = try await client.list()

            // Find the specific image by name
            for image in images {
                let details: ImageDetail = try await image.details()

                // Check if this is the image we're looking for using improved matching
                if imageMatches(imageName: details.name, requestedName: imageName) {
                    let manifests = try await image.index().manifests

                    for descriptor in manifests {
                        // skip these manifests
                        if let referenceType = descriptor.annotations?["vnd.docker.reference.type"],
                            referenceType == "attestation-manifest"
                        {
                            continue
                        }

                        guard let platform = descriptor.platform else {
                            continue
                        }

                        var config: ContainerizationOCI.Image
                        var manifest: ContainerizationOCI.Manifest

                        // try to get the config and manifest for the platform
                        do {
                            config = try await image.config(for: platform)
                            manifest = try await image.manifest(for: platform)
                        } catch {
                            // ignore failure
                            continue
                        }

                        // created is a String value like Optional("2025-05-14T11:03:12.497281595Z"
                        // need to convert it to a Unix timestamp (number of seconds since EPOCH).
                        let createdIso8601 = config.created ?? "1970-01-01T00:00:00Z"  // Default to epoch if not available

                        let iso8601Formatter = ISO8601DateFormatter()
                        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        var formattedDate = iso8601Formatter.date(from: createdIso8601)

                        if formattedDate == nil {
                            // Try without fractional seconds
                            iso8601Formatter.formatOptions = [.withInternetDateTime]
                            formattedDate = iso8601Formatter.date(from: createdIso8601)
                        }

                        // Use guard to ensure we now have a valid date
                        guard let date = formattedDate else {
                            continue  // or return, depending on context
                        }
                        let size = descriptor.size + manifest.config.size + manifest.layers.reduce(0, { (l, r) in l + r.size })

                        let summary = RESTImageInspect(
                            Id: image.digest,
                            RepoTags: [details.name],
                            RepoDigests: [],
                            Created: iso8601Formatter.string(from: date),
                            Size: size, )

                        return summary
                    }
                }
            }

            // If we get here, the image was not found
            throw Abort(.notFound, reason: "Image '\(imageName)' not found")
        }
    }
}
