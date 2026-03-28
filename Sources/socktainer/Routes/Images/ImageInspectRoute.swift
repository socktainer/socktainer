import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Vapor

struct RESTImageInspectQuery: Vapor.Content {
    let manifests: Bool?
    let platform: String?
}

struct ImageInspectRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/images/{name:.*}/json", use: ImageInspectRoute.handler(client: client))
    }
}

extension ImageInspectRoute {
    private static func makeOCIDescriptor(
        from descriptor: Descriptor,
        appSupportURL: URL? = nil,
        parentDigest: String? = nil
    ) -> OCIDescriptor {
        let platform = descriptor.platform.map {
            OCIDescriptor.OCIPlatform(
                architecture: $0.architecture,
                os: $0.os,
                osVersion: $0.osVersion,
                osFeatures: $0.osFeatures,
                variant: $0.variant
            )
        }

        let extras: AppleContainerImageStoreResolver.DescriptorExtras? =
            if let appSupportURL, let parentDigest {
                AppleContainerImageStoreResolver.descriptorExtras(
                    appSupportURL: appSupportURL,
                    parentDigest: parentDigest,
                    childDigest: descriptor.digest
                )
            } else {
                nil
            }

        return OCIDescriptor(
            mediaType: descriptor.mediaType,
            digest: descriptor.digest,
            size: descriptor.size,
            urls: descriptor.urls,
            annotations: descriptor.annotations,
            data: extras?.data,
            platform: platform,
            artifactType: extras?.artifactType
        )
    }

    private static func prioritizedManifests(_ manifests: [Descriptor]) -> [Descriptor] {
        let primaryPlatform = requestedOrDefaultPlatform(nil)

        return manifests.enumerated().sorted { leftManifest, rightManifest in
            let leftPlatform = leftManifest.element.platform
            let rightPlatform = rightManifest.element.platform

            if preferredPlatformMatches(
                leftPlatform,
                over: rightPlatform,
                preferredPlatform: primaryPlatform
            ) {
                return true
            }

            return leftManifest.offset < rightManifest.offset
        }.map(\.element)
    }

    private static func repoDigestReference(name: String, digest: String?) -> String? {
        guard let digest, !digest.isEmpty, !name.isEmpty else {
            return nil
        }

        if let reference = try? Reference.parse(name) {
            return "\(reference.name)@\(digest)"
        }

        if let atIndex = name.firstIndex(of: "@") {
            return "\(name[..<atIndex])@\(digest)"
        }

        return "\(name)@\(digest)"
    }

    private static func prioritizeVariants(_ variants: [ImageDetail.Variants]) -> [ImageDetail.Variants] {
        let hostPlatform = requestedOrDefaultPlatform(nil)

        return variants.enumerated().sorted { leftVariant, rightVariant in
            let leftPlatform = leftVariant.element.platform
            let rightPlatform = rightVariant.element.platform

            if preferredPlatformMatches(
                leftPlatform,
                over: rightPlatform,
                preferredPlatform: hostPlatform
            ) {
                return true
            }

            return leftVariant.offset < rightVariant.offset
        }.map(\.element)
    }

    private static func inspectPlatformOrThrow(_ platformString: String?) throws -> Platform? {
        guard let platformString, !platformString.isEmpty else {
            return nil
        }

        return try platformOrThrow(platformString)
    }

    static func handler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> RESTImageInspect {
        { req in
            guard let refOrId = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Missing image name parameter")
            }
            let query = try req.query.decode(RESTImageInspectQuery.self)
            let requestedPlatform = try inspectPlatformOrThrow(query.platform)
            let includeManifests = (query.manifests ?? false) && requestedPlatform == nil
            guard let appleContainerAppSupportUrl = req.application.storage[AppleContainerAppSupportUrlKey.self] else {
                throw Abort(.internalServerError, reason: "Apple Container application support URL is not configured")
            }

            _ = client

            let image: ClientImage
            do {
                image = try await ClientImage.get(reference: refOrId)
            } catch {
                throw Abort(.notFound, reason: "Image '\(refOrId)' not found")
            }

            let containers = includeManifests ? try await ContainerClient().list() : []
            let details: ImageDetail = try await image.details()
            let imageIndex = try await image.index()
            let manifests = imageIndex.manifests
            let availablePlatforms = Set(details.variants.map(\.platform))
            var manifestSummaries: [ImageManifestSummary] = []
            let containerIDs =
                containers
                .filter { $0.configuration.image.reference == image.reference || $0.configuration.image.reference == details.name }
                .map(\.id)

            for descriptor in manifests {
                let kind: String
                if let referenceType = descriptor.annotations?["vnd.docker.reference.type"],
                    referenceType == "attestation-manifest"
                {
                    kind = "attestation"
                } else {
                    kind = "image"
                }

                let platform = descriptor.platform
                let manifest: ContainerizationOCI.Manifest?
                let available: Bool

                if let platform {
                    do {
                        manifest = try await image.manifest(for: platform)
                        available = availablePlatforms.contains(platform)
                    } catch {
                        manifest = nil
                        available = false
                    }
                } else {
                    manifest = nil
                    available = false
                }

                let contentSize = (manifest?.config.size ?? 0) + (manifest?.layers.reduce(0) { $0 + $1.size } ?? 0)
                let totalSize = descriptor.size + contentSize

                if includeManifests {
                    let unpackedSize =
                        kind == "image"
                        ? AppleContainerSnapshotResolver.unpackedSize(
                            appSupportURL: appleContainerAppSupportUrl,
                            descriptor: descriptor
                        ) : 0
                    let platformSummary = platform.map {
                        OCIDescriptor.OCIPlatform(
                            architecture: $0.architecture,
                            os: $0.os,
                            osVersion: $0.osVersion,
                            osFeatures: $0.osFeatures,
                            variant: $0.variant
                        )
                    }

                    manifestSummaries.append(
                        ImageManifestSummary(
                            ID: descriptor.digest,
                            Descriptor: makeOCIDescriptor(
                                from: descriptor,
                                appSupportURL: appleContainerAppSupportUrl,
                                parentDigest: details.index.digest
                            ),
                            Available: available,
                            Kind: kind,
                            Size: .init(Total: totalSize + unpackedSize, Content: contentSize),
                            ImageData: kind == "image"
                                ? .init(
                                    Platform: platformSummary,
                                    Containers: containerIDs,
                                    Size: .init(Unpacked: unpackedSize)
                                ) : nil,
                            AttestationData: kind == "attestation"
                                ? .init(
                                    For: descriptor.annotations?["vnd.docker.reference.digest"] ?? ""
                                ) : nil
                        )
                    )
                }
            }

            let selectedVariant =
                if let requestedPlatform {
                    details.variants.first(where: { $0.platform == requestedPlatform })
                } else {
                    prioritizeVariants(details.variants).first
                }

            if let selectedVariant {
                let selectedManifest = try? await image.manifest(for: selectedVariant.platform)
                let imageConfig: ImageConfig? = selectedVariant.config.config.map { ociConfig in
                    ImageConfig(
                        User: ociConfig.user,
                        ExposedPorts: nil,
                        Env: ociConfig.env,
                        Cmd: ociConfig.cmd,
                        Healthcheck: nil,
                        ArgsEscaped: nil,
                        Volumes: nil,
                        WorkingDir: ociConfig.workingDir,
                        Entrypoint: ociConfig.entrypoint,
                        OnBuild: nil,
                        Labels: ociConfig.labels,
                        StopSignal: ociConfig.stopSignal,
                        Shell: nil
                    )
                }

                let selectedDescriptor = manifests.first { descriptor in
                    descriptor.platform == selectedVariant.platform
                        && descriptor.annotations?["vnd.docker.reference.type"] != "attestation-manifest"
                }

                let rootFS = RootFS(
                    rootfsType: selectedVariant.config.rootfs.type,
                    Layers: selectedVariant.config.rootfs.diffIDs
                )

                let summary = RESTImageInspect(
                    Id: selectedManifest?.config.digest ?? image.digest,
                    Descriptor: makeOCIDescriptor(
                        from: details.index,
                        appSupportURL: appleContainerAppSupportUrl
                    ),
                    Manifests: includeManifests ? manifestSummaries : nil,
                    RepoTags: [details.name],
                    RepoDigests: repoDigestReference(name: details.name, digest: selectedDescriptor?.digest).map { [$0] } ?? [],
                    Parent: "",
                    Comment: selectedVariant.config.history?.last?.comment ?? "",
                    Created: selectedVariant.config.created,
                    DockerVersion: "",
                    Author: selectedVariant.config.author ?? "",
                    Config: imageConfig,
                    Architecture: selectedVariant.config.architecture,
                    Variant: selectedVariant.config.variant,
                    Os: selectedVariant.config.os,
                    OsVersion: selectedVariant.config.osVersion,
                    Size: selectedVariant.size,
                    GraphDriver: selectedDescriptor.map {
                        AppleContainerImageStoreResolver.graphDriver(
                            appSupportURL: appleContainerAppSupportUrl,
                            descriptor: $0
                        )
                    } ?? nil,
                    RootFS: rootFS,
                    // Docker's schema allows Metadata.LastTagTime, but Apple's image
                    // reference store only persists `reference -> descriptor` in state.json.
                    // There is no authoritative per-tag timestamp to surface here, so
                    // we emit `Metadata.LastTagTime` as null instead of inventing a value.
                    Metadata: .init(LastTagTime: nil)
                )

                return summary
            }

            if let requestedPlatform {
                throw Abort(.notFound, reason: "Image '\(refOrId)' does not provide platform '\(requestedPlatform.description)'")
            }

            throw Abort(.notFound, reason: "Image '\(refOrId)' not found")
        }
    }
}
