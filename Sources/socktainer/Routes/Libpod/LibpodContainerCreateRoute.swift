import ContainerPersistence
import Foundation
import Vapor

struct LibpodContainerCreateRoute: RouteCollection {
    let client: ClientContainerProtocol
    let systemConfig: ContainerSystemConfig

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/containers/create", use: LibpodContainerCreateRoute.handler(client: client, systemConfig: systemConfig))
    }

    static func handler(client: ClientContainerProtocol, systemConfig: ContainerSystemConfig) -> @Sendable (Request) async throws -> Response {
        { req in
            let bodyData: ByteBuffer?
            do {
                bodyData = try await req.body.collect().get()
            } catch {
                throw Abort(.internalServerError, reason: "Failed to read request body: \(error)")
            }
            guard let bodyData, bodyData.readableBytes > 0 else {
                throw Abort(.badRequest, reason: "Missing request body")
            }
            let libpodBody: LibpodContainerCreateRequest
            do {
                libpodBody = try JSONDecoder().decode(
                    LibpodContainerCreateRequest.self,
                    from: bodyData.getData(at: 0, length: bodyData.readableBytes)!
                )
            } catch {
                throw Abort(.badRequest, reason: "Invalid request body: \(error)")
            }

            let dockerBody = CreateContainerRequest(
                Image: libpodBody.image,
                Hostname: nil,
                Domainname: nil,
                User: nil,
                AttachStdin: nil,
                AttachStdout: nil,
                AttachStderr: nil,
                PortSpecs: nil,
                Tty: nil,
                OpenStdin: nil,
                StdinOnce: nil,
                Env: nil,
                Cmd: libpodBody.command,
                Healthcheck: nil,
                ArgsEscaped: nil,
                Entrypoint: nil,
                Volumes: nil,
                WorkingDir: nil,
                MacAddress: nil,
                OnBuild: nil,
                NetworkDisabled: nil,
                ExposedPorts: nil,
                StopSignal: nil,
                StopTimeout: nil,
                HostConfig: nil,
                Labels: nil,
                Shell: nil,
                NetworkingConfig: nil
            )

            let containerName: String? = libpodBody.name ?? req.query["name"]

            var path = "/containers/create"
            if let name = containerName {
                // URLComponents/URLQueryItem percent-encodes a query VALUE correctly
                // (&, =, + included) — .urlQueryAllowed alone leaves those raw since
                // it's meant for encoding an already-structured query string, not a
                // single item's value, so a name containing them would inject a
                // second bogus query parameter.
                var components = URLComponents()
                components.queryItems = [URLQueryItem(name: "name", value: name)]
                path += "?" + (components.percentEncodedQuery ?? "")
            }
            req.url = URI(string: path)

            try req.content.encode(dockerBody, as: .json)

            let dockerHandler = ContainerCreateRoute.handler(client: client, systemConfig: systemConfig)
            return try await dockerHandler(req)
        }
    }
}
