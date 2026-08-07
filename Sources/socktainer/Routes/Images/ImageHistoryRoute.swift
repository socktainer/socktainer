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
            pattern: "/images/{name:.*}/history",
            use: ImageHistoryRoute.handler(
                systemConfig: systemConfig,
                identityResolver: identityResolver,
                runnableImageSelector: runnableImageSelector
            )
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

    static func historyResponseItems(
        for image: ClientImage,
        requestedName: String,
        tags: [String],
        preferredPlatform: Platform?,
        identityConstraint: RunnableImageIdentityConstraint = .unconstrained,
        runnableImageSelector: RunnableImageSelector = RunnableImageSelector()
    ) async throws -> [RESTImageHistoryResponseItem] {
        let resolvedDescriptors = try await runnableImageSelector.descriptors(
            for: image
        )
        guard
            let selectedVariant = runnableImageSelector.selectVariant(
                from: resolvedDescriptors,
                requestedPlatform: preferredPlatform,
                identityConstraint: identityConstraint
            )
        else {
            if let preferredPlatform {
                throw Abort(
                    .notFound,
                    reason:
                        "Image '\(requestedName)' does not provide platform '\(preferredPlatform.description)'"
                )
            }
            throw Abort(.notFound, reason: "Image '\(requestedName)' not found")
        }

        let config = selectedVariant.config
        let manifest = selectedVariant.manifest
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

            let tags =
                index == history.index(before: history.endIndex)
                ? tags : []

            items.append(
                RESTImageHistoryResponseItem(
                    Id: itemId,
                    Created:
                        AppleContainerTimestampResolver
                        .unixTimestampSeconds(entry.created ?? config.created),
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
                Id: manifest.config.digest,
                Created:
                    AppleContainerTimestampResolver
                    .unixTimestampSeconds(config.created),
                CreatedBy: "",
                Tags: tags,
                Size: manifest.layers.reduce(0) { $0 + $1.size },
                Comment: ""
            )
        ]
    }

    static func handler(
        systemConfig: ContainerSystemConfig,
        identityResolver: ImageIdentityResolver? = nil,
        runnableImageSelector: RunnableImageSelector = RunnableImageSelector()
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
                tags: resolved.references.sorted(),
                preferredPlatform: preferredPlatform,
                identityConstraint: resolved.variantConstraint,
                runnableImageSelector: runnableImageSelector
            )
        }
    }
}
