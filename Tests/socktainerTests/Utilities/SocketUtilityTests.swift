import Foundation
import Testing
import Vapor

@testable import socktainer

@Suite class SocketUtilityTests {
    private var app: Application

    init() async throws {
        app = try await Application.make(.testing)
    }

    @Test
    func testPrepareUnixSocketThrowsWhenHomeIsMissing() async throws {
        do {
            try prepareUnixSocket(for: app, homeDirectory: nil)
            Issue.record("Expected prepareUnixSocket to throw when homeDirectory is nil")
        } catch {
            // Expected error, test passes
        }

        // Explicitly shutdown at the end of the test
        try await app.asyncShutdown()
    }

    @Test
    func testPrepareUnixSocketCreatesDirectoryAndRemovesOldSocket() async throws {
        let fileManager = FileManager.default
        let tempHome = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let socketDir = tempHome.appendingPathComponent(".socktainer")
        let socketPath = socketDir.appendingPathComponent("container.sock")

        try fileManager.createDirectory(at: socketDir, withIntermediateDirectories: true)
        fileManager.createFile(atPath: socketPath.path, contents: Data())

        try prepareUnixSocket(for: app, homeDirectory: tempHome.path)

        #expect(fileManager.fileExists(atPath: socketDir.path))
        #expect(!fileManager.fileExists(atPath: socketPath.path))
        #expect(app.http.server.configuration.address == .unixDomainSocket(path: socketPath.path))

        try? fileManager.removeItem(at: tempHome)

        // Explicitly shutdown at the end of the test
        try await app.asyncShutdown()

    }
}

@Suite("SocketUtility permissions")
struct SocketUtilityPermissionsTests {

    private func makeShortTempDirectory() -> String {
        "/tmp/skt-\(UUID().uuidString.prefix(8))"
    }

    private func posixPermissions(of path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test("A missing socket directory is created owner-only (0700)")
    func createsMissingDirectoryOwnerOnly() throws {
        let directory = makeShortTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        try restrictDirectoryToOwner(at: directory)

        #expect(try posixPermissions(of: directory) == 0o700)
    }

    @Test("An existing socket directory with loose permissions is corrected to 0700")
    func correctsExistingDirectoryToOwnerOnly() throws {
        let directory = makeShortTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

        try restrictDirectoryToOwner(at: directory)

        #expect(try posixPermissions(of: directory) == 0o700)
    }

    @Test("A bound unix socket is opened to all users (0666)")
    func opensBoundSocketToAllUsers() throws {
        let directory = makeShortTempDirectory()
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let socketPath = "\(directory)/container.sock"

        let fd = try boundUnixSocket(at: socketPath)
        defer { close(fd) }

        try openSocketToAllUsers(at: socketPath)

        #expect(try posixPermissions(of: socketPath) == 0o666)
    }

    private func boundUnixSocket(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        try #require(pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: source.prefix(destination.count)))
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindResult != 0 {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fd
    }
}
