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

    let keychainEntryId = Constants.keychainID

    // (workaround) normalize server address to match `container` CLI behavior
    private func normalizeServerAddress(_ serverAddress: String) -> String {
        if serverAddress == "https://index.docker.io/v1/" {
            return "registry-1.docker.io"
        }
        return serverAddress
    }

    private func discoverContainerCLIPath() -> String? {
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        for directory in pathDirectories {
            let candidatePath = URL(fileURLWithPath: directory).appendingPathComponent("container").path
            guard FileManager.default.isExecutableFile(atPath: candidatePath) else {
                continue
            }

            return URL(fileURLWithPath: candidatePath).resolvingSymlinksInPath().path
        }

        return nil
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

        do {
            // Work around apple/container private-registry auth issues by delegating persistence
            // to the Apple CLI instead of maintaining Socktainer-owned keychain items here.
            // Manual intervention may still be required for affected users; see:
            // https://github.com/apple/container/issues/816#issuecomment-3534438608
            // https://github.com/apple/container/issues/816#issuecomment-3503618765
            try runContainerRegistryLogin(serverAddress: normalizedServer, username: username, password: password)
            logger.info("Credentials stored successfully using container registry login for \(normalizedServer)")
        } catch {
            logger.error("Failed to store credentials using container registry login: \(error)")
            throw ClientRegistryError.storageError("Failed to store credentials: \(error.localizedDescription)")
        }
    }

    func retrieveCredentials(serverAddress: String, logger: Logger) async throws -> Authentication? {
        let normalizedServer = normalizeServerAddress(serverAddress)
        logger.debug("Retrieving credentials for registry: \(normalizedServer)")

        let keychainHelper = KeychainHelper(securityDomain: keychainEntryId)

        do {
            let auth = try keychainHelper.lookup(hostname: normalizedServer)
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

    func login(serverAddress: String, username: String, password: String, logger: Logger) async throws -> String {
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

    private func runContainerRegistryLogin(serverAddress: String, username: String, password: String) throws {
        guard let containerCLIPath = discoverContainerCLIPath() else {
            throw ClientRegistryError.storageError("Unable to find `container` executable in PATH")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: containerCLIPath)
        process.arguments = [
            "registry", "login",
            "--username", username,
            "--password-stdin",
            serverAddress,
        ]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        if let passwordData = "\(password)\n".data(using: .utf8) {
            try stdinPipe.fileHandleForWriting.write(contentsOf: passwordData)
        }
        try stdinPipe.fileHandleForWriting.close()

        process.waitUntilExit()

        let stdout =
            String(data: try stdoutPipe.fileHandleForReading.readToEnd() ?? Data(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr =
            String(data: try stderrPipe.fileHandleForReading.readToEnd() ?? Data(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw ClientRegistryError.storageError(
                "container registry login failed with exit code \(process.terminationStatus). stdout: \(stdout). stderr: \(stderr)"
            )
        }
    }
}
