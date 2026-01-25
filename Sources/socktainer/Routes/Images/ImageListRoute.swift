import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Vapor

struct ImageListRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/images/json", use: ImageListRoute.handler(client: client))
    }
}

struct CustomImageDetail: Decodable {
    public let name: String
}

extension ImageListRoute {
    static func handler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> [RESTImageSummary] {
        { req in

            let images = try await client.list()

            var imagesSummaries: [RESTImageSummary] = []

            // for each images, grab the details and print
            for image in images {
                let details: ImageDetail = try await image.details()

                //
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
                    let unixTimestamp = date.timeIntervalSince1970
                    let created = Int(unixTimestamp)
                    let size = descriptor.size + manifest.config.size + manifest.layers.reduce(0, { (l, r) in l + r.size })

                    let name = details.name

                    let repoTags = name.isEmpty ? [] : [name]
                    let repoDigests = image.reference.contains("@sha256:") ? [image.reference] : []
                    let summary = RESTImageSummary(
                        Id: image.digest,
                        RepoTags: repoTags,
                        RepoDigests: repoDigests,
                        Created: created,
                        Size: size,
                        Labels: [:],
                    )

                    imagesSummaries.append(summary)

                }

            }

            return imagesSummaries
        }
    }
}
