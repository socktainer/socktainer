import ContainerAPIClient
import ContainerPersistence
import ContainerizationOCI
import Foundation
import Vapor

struct RESTDistributionInspect: Vapor.Content {
    struct RESTDescriptor: Vapor.Content {
        let mediaType: String
        let digest: String
        let size: Int64
    }

    struct RESTPlatform: Vapor.Content {
        let architecture: String
        let os: String
        let variant: String?
    }

    let Descriptor: RESTDescriptor
    let Platforms: [RESTPlatform]
}

protocol DistributionInspectProviding: Sendable {
    func inspect(reference: String, authentication: Authentication?) async throws -> RESTDistributionInspect
}

struct RegistryDistributionProvider: DistributionInspectProviding {
    let containerSystemConfig: ContainerSystemConfig

    func inspect(reference: String, authentication: Authentication?) async throws -> RESTDistributionInspect {
        let parsed: Reference
        do {
            let normalized = try ClientImage.normalizeReference(reference, containerSystemConfig: containerSystemConfig)
            parsed = try Reference.parse(normalized)
            parsed.normalize()
        } catch {
            throw Abort(.badRequest, reason: "invalid reference: \(reference)")
        }
        guard let server = parsed.resolvedDomain else {
            throw Abort(.badRequest, reason: "invalid reference: \(reference)")
        }
        let auth = authentication ?? keychainAuthentication(host: server) ?? parsed.domain.flatMap(keychainAuthentication)
        let client = try registryClient(server: server, authentication: auth)

        let name = parsed.path
        let descriptor = try await client.resolve(name: name, tag: parsed.digest ?? parsed.tag ?? "latest")
        let platforms = try await platforms(of: descriptor, name: name, client: client)

        return RESTDistributionInspect(
            Descriptor: .init(mediaType: descriptor.mediaType, digest: descriptor.digest, size: descriptor.size),
            Platforms: platforms
        )
    }

    private func registryClient(server: String, authentication: Authentication?) throws -> RegistryClient {
        let scheme = try RequestScheme.auto.schemeFor(host: server, internalDnsDomain: containerSystemConfig.dns.domain)
        guard let url = URL(string: "\(scheme.rawValue)://\(server)"), let host = url.host else {
            throw Abort(.badRequest, reason: "invalid registry host: \(server)")
        }
        return RegistryClient(host: host, scheme: scheme.rawValue, port: url.port, authentication: authentication)
    }

    private func keychainAuthentication(host: String) -> Authentication? {
        try? KeychainHelper(securityDomain: Constants.keychainID).lookup(hostname: host)
    }

    private func platforms(of descriptor: Descriptor, name: String, client: RegistryClient) async throws -> [RESTDistributionInspect.RESTPlatform] {
        switch descriptor.mediaType {
        case MediaTypes.index, MediaTypes.dockerManifestList:
            let index: Index = try await client.fetch(name: name, descriptor: descriptor)
            return index.manifests
                .compactMap(\.platform)
                .filter { $0.os != "unknown" && $0.architecture != "unknown" }
                .map { RESTDistributionInspect.RESTPlatform(architecture: $0.architecture, os: $0.os, variant: $0.variant) }
        case MediaTypes.imageManifest, MediaTypes.dockerManifest:
            let manifest: Manifest = try await client.fetch(name: name, descriptor: descriptor)
            let config: Image = try await client.fetch(name: name, descriptor: manifest.config)
            return [RESTDistributionInspect.RESTPlatform(architecture: config.architecture, os: config.os, variant: config.variant)]
        default:
            return []
        }
    }
}

struct DistributionJsonRoute: RouteCollection {
    let inspectProvider: DistributionInspectProviding

    init(inspectProvider: DistributionInspectProviding) {
        self.inspectProvider = inspectProvider
    }

    init(systemConfig: ContainerSystemConfig) {
        self.inspectProvider = RegistryDistributionProvider(containerSystemConfig: systemConfig)
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/distribution/{name:.*}/json", use: DistributionJsonRoute.handler(inspectProvider: inspectProvider))
    }

    static func handler(inspectProvider: DistributionInspectProviding) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let name = req.parameters.get("name"), !name.isEmpty else {
                throw Abort(.badRequest, reason: "Missing image reference")
            }
            do {
                let inspect = try await inspectProvider.inspect(reference: name, authentication: registryAuth(from: req))
                return try await inspect.encodeResponse(status: .ok, for: req)
            } catch let error as RegistryClient.Error {
                throw abort(for: error, reference: name)
            } catch let abort as Abort {
                throw abort
            } catch {
                throw Abort(.internalServerError, reason: "distribution inspect of \(name) failed: \(error)")
            }
        }
    }

    /// moby's X-Registry-Auth header: base64url JSON credentials sent by
    /// docker clients that logged in via `docker login`.
    static func registryAuth(from req: Request) -> Authentication? {
        guard let header = req.headers.first(name: "X-Registry-Auth"), !header.isEmpty else { return nil }
        guard let credentials = decodeRegistryAuth(header), !credentials.username.isEmpty else { return nil }
        return BasicAuthentication(username: credentials.username, password: credentials.password)
    }

    static func decodeRegistryAuth(_ header: String) -> (username: String, password: String)? {
        var base64 = header.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        struct AuthConfig: Decodable {
            let username: String?
            let password: String?
        }
        guard let data = Data(base64Encoded: base64),
            let config = try? JSONDecoder().decode(AuthConfig.self, from: data)
        else { return nil }
        guard let username = config.username, let password = config.password else { return nil }
        return (username, password)
    }

    static func abort(for error: RegistryClient.Error, reference: String) -> Abort {
        switch error {
        case .invalidStatus(_, let status, let reason):
            switch status.code {
            case 404:
                return Abort(.notFound, reason: "manifest unknown: \(reference)")
            case 401, 403:
                return Abort(.unauthorized, reason: "access to \(reference) is denied: \(reason ?? "authentication required")")
            default:
                return Abort(.internalServerError, reason: String(describing: error))
            }
        }
    }
}
