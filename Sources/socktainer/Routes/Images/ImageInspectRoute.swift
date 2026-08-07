import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationOCI
import Vapor

struct RESTImageInspectQuery: Vapor.Content {
    let manifests: Bool?
    let platform: String?
}

struct ImageInspectRoute: RouteCollection {
    let systemConfig: ContainerSystemConfig
    let identityResolver: ImageIdentityResolver
    let runnableImageSelector: RunnableImageSelector

    init(
        systemConfig: ContainerSystemConfig,
        identityResolver: ImageIdentityResolver? = nil,
        runnableImageSelector: RunnableImageSelector = RunnableImageSelector()
    ) {
        self.systemConfig = systemConfig
        self.identityResolver = identityResolver ?? ImageIdentityResolver(systemConfig: systemConfig)
        self.runnableImageSelector = runnableImageSelector
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .GET,
            pattern: "/images/{name:.*}/json",
            use: ImageInspectRoute.handler(
                systemConfig: systemConfig,
                identityResolver: identityResolver,
                runnableImageSelector: runnableImageSelector
            )
        )
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
            artifactType: extras?.artifactType ?? descriptor.artifactType
        )
    }

    private static func inspectPlatformOrThrow(_ platformString: String?) throws -> Platform? {
        guard let platformString, !platformString.isEmpty else {
            return nil
        }

        return try platformOrThrow(platformString)
    }

    static func handler(
        systemConfig: ContainerSystemConfig,
        identityResolver: ImageIdentityResolver? = nil,
        runnableImageSelector: RunnableImageSelector = RunnableImageSelector()
    ) -> @Sendable (Request) async throws -> RESTImageInspect {
        let resolver = identityResolver ?? ImageIdentityResolver(systemConfig: systemConfig)
        return { req in
            guard let refOrId = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Missing image name parameter")
            }
            let query = try req.query.decode(RESTImageInspectQuery.self)
            let explicitlyRequestedPlatform = try inspectPlatformOrThrow(query.platform)
            guard let appleContainerAppSupportUrl = req.application.storage[AppleContainerAppSupportUrlKey.self] else {
                throw Abort(.internalServerError, reason: "Apple Container application support URL is not configured")
            }

            let resolved: ResolvedImageIdentity
            do {
                resolved = try await resolver.resolve(refOrId)
            } catch let error as ImageIdentityResolutionError {
                // Docker phrasing ("No such image: <ref>") is load-bearing: docker-py
                // only maps a 404 to ImageNotFound when the message contains
                // "no such image"; otherwise callers' `except ImageNotFound` (which
                // triggers an auto-pull, e.g. MiniStack's Lambda RIE image) is skipped.
                if case .ambiguous = error {
                    throw Abort(.conflict, reason: "conflict: \(refOrId) is an ambiguous image ID")
                }
                throw Abort(.notFound, reason: "No such image: \(refOrId)")
            }
            let image = resolved.image
            if let explicit = explicitlyRequestedPlatform,
                let implied = resolved.impliedPlatform,
                explicit != implied
            {
                throw Abort(.notFound, reason: "Image '\(refOrId)' does not provide platform '\(explicit.description)'")
            }
            let requestedPlatform = explicitlyRequestedPlatform ?? resolved.impliedPlatform
            let includeManifests = (query.manifests ?? false) && requestedPlatform == nil

            let containers = includeManifests ? try await ContainerClient().list() : []
            let resolvedDescriptors =
                try await runnableImageSelector
                .descriptors(for: image)
            var manifestSummaries: [ImageManifestSummary] = []
            for resolvedDescriptor
                in runnableImageSelector
                .descriptorsInDeterministicPreferenceOrder(
                    resolvedDescriptors
                )
            {
                let descriptor = resolvedDescriptor.descriptor
                let kind =
                    resolvedDescriptor.kind == .artifact
                    ? "attestation" : "image"
                let platform = descriptor.platform
                let available =
                    resolvedDescriptor.kind == .artifact
                    ? resolvedDescriptor.documentAvailable
                    : resolvedDescriptor.runnableVariant != nil
                let contentSize = resolvedDescriptor.contentSize
                let totalSize = resolvedDescriptor.totalSize

                if includeManifests {
                    let containerIDs =
                        resolvedDescriptor.runnableVariant.map {
                            variant in
                            containers.filter {
                                ContainerImageIdentity.matches(
                                    $0,
                                    rootDigests: resolved.rootDigests,
                                    configDigest: variant.manifest.config.digest
                                )
                            }.map(\.id)
                        } ?? []
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
                                parentDigest: image.descriptor.digest
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
                                    For: resolvedDescriptor
                                        .artifactSubjectDigest ?? ""
                                ) : nil
                        )
                    )
                }
            }

            let selectedVariant = runnableImageSelector.selectVariant(
                from: resolvedDescriptors,
                requestedPlatform: requestedPlatform,
                identityConstraint: resolved.variantConstraint
            )

            if let selectedVariant {
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

                let rootFS = RootFS(
                    rootfsType: selectedVariant.config.rootfs.type,
                    Layers: selectedVariant.config.rootfs.diffIDs
                )

                let summary = RESTImageInspect(
                    Id: selectedVariant.manifest.config.digest,
                    Descriptor: makeOCIDescriptor(
                        from: image.descriptor,
                        appSupportURL: appleContainerAppSupportUrl
                    ),
                    Manifests: includeManifests ? manifestSummaries : nil,
                    RepoTags: resolved.references,
                    RepoDigests: resolved.repositoryDigests,
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
                    Size: selectedVariant.totalSize,
                    GraphDriver: AppleContainerImageStoreResolver.graphDriver(
                        appSupportURL: appleContainerAppSupportUrl,
                        descriptor: selectedVariant.descriptor
                    ),
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

            throw Abort(.notFound, reason: "No such image: \(refOrId)")
        }
    }
}
