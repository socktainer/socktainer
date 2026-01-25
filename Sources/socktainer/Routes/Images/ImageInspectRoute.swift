import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Vapor

struct ImageInspectRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/images/{name:.*}/json", use: ImageInspectRoute.handler(client: client))
    }
}

extension ImageInspectRoute {
    /// Checks if an image name matches the requested name, considering Docker Hub prefixes and digest hashes
    private static func imageMatches(imageName: String, imageDigest: String, refOrId: String) -> Bool {
        // Check if refOrId is a digest hash (sha256:, sha512:, etc.)
        if refOrId.contains(":") && refOrId.split(separator: ":").count == 2 {
            let parts = refOrId.split(separator: ":")
            let algorithm = String(parts[0])
            let hash = String(parts[1])

            // Check if it looks like a hash algorithm (common ones: sha256, sha512, sha1, md5, etc.)
            if algorithm.lowercased().matches(of: /^(sha|md)\d*$/).count > 0 && hash.allSatisfy({ $0.isHexDigit }) {
                return imageDigest == refOrId
            }
        }

        // Exact match
        if imageName == refOrId {
            return true
        }

        // Extract the base name without tag from both names
        let imageBaseName = imageName.components(separatedBy: ":").first ?? imageName
        let requestedBaseName = refOrId.components(separatedBy: ":").first ?? refOrId

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
            guard let refOrId = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Missing image name parameter")
            }

            let images = try await client.list()

            // Find the specific image by name
            for image in images {
                let details: ImageDetail = try await image.details()

                // Check if this is the image we're looking for using improved matching
                if imageMatches(imageName: details.name, imageDigest: image.digest, refOrId: refOrId) {
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
                        guard formattedDate != nil else {
                            continue  // or return, depending on context
                        }
                        let size = descriptor.size + manifest.config.size + manifest.layers.reduce(0, { (l, r) in l + r.size })

                        let imageConfig: ImageConfig? = config.config.map { ociConfig in
                            ImageConfig(
                                User: ociConfig.user,
                                ExposedPorts: nil,  // Not available in OCI config
                                Env: ociConfig.env,
                                Cmd: ociConfig.cmd,
                                Healthcheck: nil,  // Not available in OCI config
                                ArgsEscaped: nil,
                                Volumes: nil,  // Not available in OCI config
                                WorkingDir: ociConfig.workingDir,
                                Entrypoint: ociConfig.entrypoint,
                                OnBuild: nil,  // Not available in OCI config
                                Labels: ociConfig.labels,
                                StopSignal: ociConfig.stopSignal,
                                Shell: nil  // Not available in OCI config
                            )
                        }

                        // Build RootFS from manifest layers
                        let rootFS = RootFS(
                            rootfsType: config.rootfs.type,
                            Layers: config.rootfs.diffIDs
                        )

                        let summary = RESTImageInspect(
                            Id: image.digest,
                            Descriptor: nil,  // Not readily available
                            Manifests: nil,  // Not readily available
                            RepoTags: [details.name],
                            RepoDigests: [],  // Would need registry information
                            Parent: nil,  // Not available from OCI format
                            Comment: nil,  // Not available from OCI format
                            Created: config.created,
                            DockerVersion: nil,  // Not available from OCI format
                            Author: config.author,
                            Config: imageConfig,
                            Architecture: config.architecture,
                            Variant: config.variant,
                            Os: config.os,
                            OsVersion: config.osVersion,
                            Size: size,
                            VirtualSize: size,  // Same as Size for compatibility
                            GraphDriver: nil,  // Storage driver info not available
                            RootFS: rootFS,
                            Metadata: nil  // Local metadata not available
                        )

                        return summary
                    }
                }
            }

            // If we get here, the image was not found
            throw Abort(.notFound, reason: "Image '\(refOrId)' not found")
        }
    }
}
