import Foundation
import Testing

@testable import socktainer

@Suite("DockerContextSetup")
struct DockerContextSetupTests {

    // MARK: - Helpers

    /// Returns a fresh temp directory and cleans it up after the test.
    private func withTempHome(_ body: (String) throws -> Void) throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("socktainer-ctx-test-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try body(tmp)
    }

    private func metaJSON(homeDir: String) throws -> [String: Any] {
        let hash = DockerContextSetup.contextDirName
        let path = "\(homeDir)/.docker/contexts/meta/\(hash)/meta.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else {
            throw NSError(
                domain: "DockerContextSetupTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "meta.json root is not a JSON object — got \(type(of: obj))"])
        }
        return dict
    }

    // MARK: - Tests

    @Test("meta.json is created under the correct SHA256-named directory")
    func contextFileIsCreated() throws {
        try withTempHome { home in
            DockerContextSetup.install(homeDirectory: home)
            let hash = DockerContextSetup.contextDirName
            let metaPath = "\(home)/.docker/contexts/meta/\(hash)/meta.json"
            #expect(FileManager.default.fileExists(atPath: metaPath))
        }
    }

    @Test("Context Name field is 'socktainer'")
    func contextHasCorrectName() throws {
        try withTempHome { home in
            DockerContextSetup.install(homeDirectory: home)
            let json = try metaJSON(homeDir: home)
            #expect(json["Name"] as? String == DockerContextSetup.contextName)
        }
    }

    @Test("Endpoints.docker.Host points at the correct socket path")
    func contextHasCorrectSocketPath() throws {
        try withTempHome { home in
            DockerContextSetup.install(homeDirectory: home)
            let json = try metaJSON(homeDir: home)
            let endpoints = json["Endpoints"] as? [String: Any]
            let docker = endpoints?["docker"] as? [String: Any]
            let host = docker?["Host"] as? String
            #expect(host == "unix://\(home)/.socktainer/container.sock")
        }
    }

    @Test("TLS directory exists alongside meta directory")
    func tlsDirExists() throws {
        try withTempHome { home in
            DockerContextSetup.install(homeDirectory: home)
            let hash = DockerContextSetup.contextDirName
            let tlsDir = "\(home)/.docker/contexts/tls/\(hash)/docker"
            #expect(FileManager.default.fileExists(atPath: tlsDir))
        }
    }

    @Test("install() is idempotent — calling twice produces the same result")
    func contextIsIdempotent() throws {
        try withTempHome { home in
            DockerContextSetup.install(homeDirectory: home)
            DockerContextSetup.install(homeDirectory: home)
            let json = try metaJSON(homeDir: home)
            #expect(json["Name"] as? String == DockerContextSetup.contextName)
        }
    }

    @Test("Works when ~/.docker/contexts/ does not exist yet")
    func contextHandlesMissingDockerDir() throws {
        try withTempHome { home in
            // temp dir exists but has no .docker subdirectory
            DockerContextSetup.install(homeDirectory: home)
            let json = try metaJSON(homeDir: home)
            #expect(json["Name"] as? String == DockerContextSetup.contextName)
        }
    }

    @Test("Does not throw on an unwritable path — logs warning and returns")
    func contextHandlesUnwritablePath() throws {
        // Pass a path that cannot be created (root-owned directory)
        DockerContextSetup.install(homeDirectory: "/nonexistent/path/that/cannot/be/created")
        // If we reach here without crashing, the error was handled gracefully
    }
}
