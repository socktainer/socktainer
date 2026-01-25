import ContainerAPIClient
import ContainerizationOCI
import Foundation
import Logging

protocol ClientRegistryProtocol: Sendable {
    func validateCredentials(serverAddress: String, username: String, password: String) async throws -> Bool
    func storeCredentials(serverAddress: String, username: String, password: String, logger: Logger) async throws
    func retrieveCredentials(serverAddress: String, logger: Logger) async throws -> Authentication?
    func login(serverAddress: String, username: String, password: String, logger: Logger) async throws -> String
}

enum ClientRegistryError: Error {
    case invalidServerAddress
    case invalidCredentials
    case storageError(String)
}

// WARN: There is no option to remove entry from keychain when client logs out.
struct ClientRegistryService: ClientRegistryProtocol {

    // WARN: Socktainer doesn't integrate with container's keychain items.
    //       This is kept as a placeholder for the time being.
    //       See: https://github.com/socktainer/socktainer/issues/96#issuecomment-3344370243
    let keychainEntryId = "io.github.socktainer"

    // (workaround) normalize server address to match `container` CLI behavior
    private func normalizeServerAddress(_ serverAddress: String) -> String {
        if serverAddress == "https://index.docker.io/v1/" {
            return "registry-1.docker.io"
        }
        return serverAddress
    }

    func validateCredentials(serverAddress: String, username: String, password: String) async throws -> Bool {
        guard !serverAddress.isEmpty else {
            throw ClientRegistryError.invalidServerAddress
        }

        guard !username.isEmpty, !password.isEmpty else {
            throw ClientRegistryError.invalidCredentials
        }

        do {
            _ = try await testRegistryWithAppleContainer(serverAddress: serverAddress, username: username, password: password)
            return true
        } catch {
            throw ClientRegistryError.invalidCredentials
        }
    }

    private func testRegistryWithAppleContainer(serverAddress: String, username: String, password: String) async throws -> String {
        let auth = BasicAuthentication(username: username, password: password)

        let registryHost: String
        if serverAddress.hasPrefix("http://") || serverAddress.hasPrefix("https://") {
            guard let url = URL(string: serverAddress) else {
                throw ClientRegistryError.invalidServerAddress
            }
            registryHost = url.host ?? serverAddress
        } else {
            registryHost = serverAddress
        }

        let registryClient = RegistryClient(host: registryHost, authentication: auth)

        try await registryClient.ping()

        // TODO: Revisit this. Understand if socktainer should return a token, or let the
        //       client handle this mechanism
        return ""
    }

    func storeCredentials(serverAddress: String, username: String, password: String, logger: Logger) async throws {
        let normalizedServer = normalizeServerAddress(serverAddress)
        let keychainHelper = KeychainHelper(id: keychainEntryId)

        do {
            try keychainHelper.save(domain: normalizedServer, username: username, password: password)
            logger.debug("Credentials stored successfully in keychain for \(normalizedServer)")
        } catch {
            logger.error("Failed to store credentials in keychain: \(error)")
            throw ClientRegistryError.storageError("Failed to store credentials: \(error.localizedDescription)")
        }
    }

    func retrieveCredentials(serverAddress: String, logger: Logger) async throws -> Authentication? {
        let normalizedServer = normalizeServerAddress(serverAddress)
        logger.debug("Retrieving credentials for registry: \(normalizedServer)")

        let keychainHelper = KeychainHelper(id: keychainEntryId)

        do {
            let auth = try keychainHelper.lookup(domain: normalizedServer)
            logger.debug("Credentials found for \(normalizedServer)")
            return auth
        } catch KeychainHelper.Error.keyNotFound {
            logger.debug("No credentials found for \(normalizedServer)")
            return nil
        } catch {
            logger.error("Failed to retrieve credentials from keychain: \(error)")
            throw ClientRegistryError.storageError("Failed to retrieve credentials: \(error.localizedDescription)")
        }
    }

    private func hasStoredCredentials(serverAddress: String, logger: Logger) async -> Bool {
        do {
            let credentials = try await retrieveCredentials(serverAddress: serverAddress, logger: logger)
            return credentials != nil
        } catch {
            logger.debug("Error checking stored credentials: \(error)")
            return false
        }
    }

    func login(serverAddress: String, username: String, password: String, logger: Logger) async throws -> String {
        // TODO: In the future, validate stored credentials are still valid and refresh if needed
        //       Check if credentials already exist for this server
        if await hasStoredCredentials(serverAddress: serverAddress, logger: logger) {
            logger.debug("Credentials already exist for \(serverAddress), skipping login")
            return ""
        }

        let identityToken: String
        do {
            identityToken = try await testRegistryWithAppleContainer(serverAddress: serverAddress, username: username, password: password)
        } catch {
            logger.error("Login failed: Invalid credentials for \(serverAddress)")
            throw ClientRegistryError.invalidCredentials
        }

        try await storeCredentials(serverAddress: serverAddress, username: username, password: password, logger: logger)

        logger.info("Successfully logged in to registry: \(serverAddress)")
        return identityToken
    }
}
