import ContainerizationOCI
import Vapor

protocol RegistryCredentialValidating: Sendable {
    func validate(serverAddress: String, username: String, password: String) async throws
}

struct ContainerRegistryCredentialValidator: RegistryCredentialValidating {
    func validate(serverAddress: String, username: String, password: String) async throws {
        let host: String
        if serverAddress.hasPrefix("http://") || serverAddress.hasPrefix("https://") {
            guard let parsed = URL(string: serverAddress), let parsedHost = parsed.host else {
                throw Abort(.badRequest, reason: "Invalid server address")
            }
            host = parsedHost
        } else {
            host = serverAddress
        }
        guard !host.isEmpty else {
            throw Abort(.badRequest, reason: "Invalid server address")
        }
        let authentication = BasicAuthentication(username: username, password: password)
        try await RegistryClient(host: host, authentication: authentication).ping()
    }
}

struct AuthRoute: RouteCollection {
    let validator: any RegistryCredentialValidating

    init(validator: any RegistryCredentialValidating = ContainerRegistryCredentialValidator()) {
        self.validator = validator
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/auth") { request in
            let config = try request.content.decode(AuthConfig.self)
            guard let username = config.username, !username.isEmpty,
                let password = config.password, !password.isEmpty,
                let serverAddress = config.serveraddress, !serverAddress.isEmpty
            else {
                throw Abort(
                    .unauthorized,
                    reason: "Username, password, and server address are required"
                )
            }
            do {
                try await validator.validate(
                    serverAddress: serverAddress,
                    username: username,
                    password: password
                )
            } catch let abort as Abort {
                throw abort
            } catch {
                throw Abort(.unauthorized, reason: "Registry authentication failed")
            }
            return AuthResponse(Status: "Login Succeeded", IdentityToken: "")
        }
    }
}
