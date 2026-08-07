import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationOCI
import Vapor

struct RESTImageHistoryQuery: Vapor.Content {
    let platform: String?
}

struct ImageHistoryRoute: RouteCollection {
    let systemConfig: ContainerSystemConfig
    let identityResolver: ImageIdentityResolver

    init(systemConfig: ContainerSystemConfig, identityResolver: ImageIdentityResolver? = nil) {
        self.systemConfig = systemConfig
        self.identityResolver = identityResolver ?? ImageIdentityResolver(systemConfig: systemConfig)
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .GET,
            pattern: "/images/{name:.*}/history",
            use: ImageHistoryRoute.handler(systemConfig: systemConfig, identityResolver: identityResolver)
        )
    }
}

extension ImageHistoryRoute {
    static func selectedPlatform(
        explicit: Platform?,
        implied: Platform?,
        requestedName: String
    ) throws -> Platform? {
        if let explicit, let implied, explicit != implied {
            throw Abort(
                .notFound,
                reason: "Image '\(requestedName)' does not provide platform '\(explicit.description)'"
            )
        }

        return explicit ?? implied
    }

    private static func prioritizedManifests(_ manifests: [Descriptor], preferredPlatform: Platform?) -> [Descriptor] {
        let primaryPlatform = requestedOrDefaultPlatform(preferredPlatform)

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

    private static func historyResponseItems(
        for image: ClientImage,
        requestedName: String,
        preferredPlatform: Platform?
    ) async throws -> [RESTImageHistoryResponseItem] {
        let imageIndex = try await image.index()
        let manifests = prioritizedManifests(imageIndex.manifests, preferredPlatform: preferredPlatform)

        for descriptor in manifests {
            if let referenceType = descriptor.annotations?["vnd.docker.reference.type"],
                referenceType == "attestation-manifest"
            {
                continue
            }

            guard let platform = descriptor.platform else {
                continue
            }

            let config: ContainerizationOCI.Image
            let manifest: ContainerizationOCI.Manifest
            do {
                config = try await image.config(for: platform)
                manifest = try await image.manifest(for: platform)
            } catch {
                continue
            }

            let history = config.history ?? []
            var layerIndex = 0
            var items: [RESTImageHistoryResponseItem] = []

            for (index, entry) in history.enumerated() {
                let isEmptyLayer = entry.emptyLayer ?? false
                let itemId: String
                let itemSize: Int64

                if isEmptyLayer {
                    itemId = "<missing>"
                    itemSize = 0
                } else if layerIndex < manifest.layers.count {
                    let layer = manifest.layers[layerIndex]
                    itemId = layer.digest
                    itemSize = layer.size
                    layerIndex += 1
                } else {
                    itemId = "<missing>"
                    itemSize = 0
                }

                let tags = index == history.index(before: history.endIndex) ? [image.reference] : []

                items.append(
                    RESTImageHistoryResponseItem(
                        Id: itemId,
                        Created: AppleContainerTimestampResolver.unixTimestampSeconds(entry.created ?? config.created),
                        CreatedBy: entry.createdBy ?? "",
                        Tags: tags,
                        Size: itemSize,
                        Comment: entry.comment ?? ""
                    )
                )
            }

            if !items.isEmpty {
                return items.reversed()
            }

            return [
                RESTImageHistoryResponseItem(
                    Id: image.digest,
                    Created: AppleContainerTimestampResolver.unixTimestampSeconds(config.created),
                    CreatedBy: "",
                    Tags: [image.reference],
                    Size: manifest.layers.reduce(0) { $0 + $1.size },
                    Comment: ""
                )
            ]
        }

        throw Abort(.notFound, reason: "Image '\(requestedName)' not found")
    }

    static func handler(
        systemConfig: ContainerSystemConfig,
        identityResolver: ImageIdentityResolver? = nil
    ) -> @Sendable (Request) async throws -> [RESTImageHistoryResponseItem] {
        let resolver = identityResolver ?? ImageIdentityResolver(systemConfig: systemConfig)
        return { req in
            guard let refOrId = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Missing image name parameter")
            }

            let query = try req.query.decode(RESTImageHistoryQuery.self)
            let explicitlyRequestedPlatform: Platform?
            if let platformString = query.platform, !platformString.isEmpty {
                explicitlyRequestedPlatform = try platformOrThrow(platformString)
            } else {
                explicitlyRequestedPlatform = nil
            }

            let resolved: ResolvedImageIdentity
            do {
                resolved = try await resolver.resolve(refOrId)
            } catch let error as ImageIdentityResolutionError {
                if case .ambiguous = error {
                    throw Abort(.conflict, reason: "conflict: \(refOrId) is an ambiguous image ID")
                }
                throw Abort(.notFound, reason: "Image '\(refOrId)' not found")
            }

            let preferredPlatform = try selectedPlatform(
                explicit: explicitlyRequestedPlatform,
                implied: resolved.impliedPlatform,
                requestedName: refOrId
            )

            return try await historyResponseItems(
                for: resolved.image,
                requestedName: refOrId,
                preferredPlatform: preferredPlatform
            )
        }
    }
}
