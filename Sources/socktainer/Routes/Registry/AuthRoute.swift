import Vapor

struct AuthRoute: RouteCollection {
    let client: ClientRegistryService
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/auth", use: AuthRoute.handler(client: client))
    }
}

extension AuthRoute {
    static func handler(client: ClientRegistryService) -> @Sendable (Request) async throws -> Response {
        { req in
            // Collect the body for large requests
            let collectedBuffer = try await req.body.collect().get()

            if let buffer = collectedBuffer {
                _ = buffer.getString(at: 0, length: buffer.readableBytes)

                if let data = buffer.getData(at: 0, length: buffer.readableBytes) {
                    do {
                        _ = try JSONDecoder().decode(AuthConfig.self, from: data)
                    } catch {
                        req.logger.error("Failed to decode content from buffer: \(error)")
                    }
                }
            }

            do {
                let authConfig = try req.content.decode(AuthConfig.self)

                guard let username = authConfig.username, !username.isEmpty,
                    let password = authConfig.password, !password.isEmpty,
                    let serverAddress = authConfig.serveraddress, !serverAddress.isEmpty
                else {
                    let response = Response(status: .unauthorized, body: .init(string: "{\"message\": \"Username, password, and server address are required\"}"))
                    response.headers.add(name: .contentType, value: "application/json")
                    return response
                }

                let logger = req.logger

                do {
                    // Perform complete login process (validation + storage)
                    let identityToken = try await client.login(
                        serverAddress: serverAddress,
                        username: username,
                        password: password,
                        logger: logger
                    )

                    let response = AuthResponse(
                        Status: "Login Succeeded",
                        IdentityToken: identityToken
                    )
                    return try await response.encodeResponse(status: .ok, for: req)

                } catch ClientRegistryError.invalidServerAddress {
                    let response = Response(status: .badRequest, body: .init(string: "{\"message\": \"Invalid server address\"}"))
                    response.headers.add(name: .contentType, value: "application/json")
                    return response

                } catch ClientRegistryError.invalidCredentials {
                    let response = Response(status: .badRequest, body: .init(string: "{\"message\": \"Invalid credentials format\"}"))
                    response.headers.add(name: .contentType, value: "application/json")
                    return response

                } catch ClientRegistryError.storageError(let message) {
                    logger.error("Failed to store credentials: \(message)")
                    let response = Response(status: .internalServerError, body: .init(string: "{\"message\": \"Failed to store credentials\"}"))
                    response.headers.add(name: .contentType, value: "application/json")
                    return response

                } catch {
                    logger.error("Unexpected registry error: \(error)")
                    let response = Response(status: .internalServerError, body: .init(string: "{\"message\": \"Internal server error\"}"))
                    response.headers.add(name: .contentType, value: "application/json")
                    return response
                }

            } catch let DecodingError.dataCorrupted(context) {
                let response = Response(status: .badRequest, body: .init(string: "{\"message\": \"Invalid JSON: \(context.debugDescription)\"}"))
                response.headers.add(name: .contentType, value: "application/json")
                return response
            } catch let DecodingError.keyNotFound(key, _) {
                let response = Response(status: .badRequest, body: .init(string: "{\"message\": \"Missing required field: \(key.stringValue)\"}"))
                response.headers.add(name: .contentType, value: "application/json")
                return response
            } catch {
                let response = Response(status: .internalServerError, body: .init(string: "{\"message\": \"Internal server error\"}"))
                response.headers.add(name: .contentType, value: "application/json")
                return response
            }
        }
    }
}
