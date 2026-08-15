import Foundation
import Testing

@testable import GlassDock

@Suite("Engine state lock")
struct EngineStateLockTests {
    @Test("default engine state is outside the exported host home")
    func defaultStateIsOutsideHome() {
        let directory = GlassDockDirectories.engineStateDirectory(environment: [:])
        #expect(!directory.path.hasPrefix(GlassDockDirectories.hostHome.path + "/"))
    }

    @Test("engine state can be isolated from the exported host directory")
    func isolatedStateDirectory() {
        let directory = GlassDockDirectories.engineStateDirectory(
            environment: [
                "GLASSDOCK_HOST_HOME_DIRECTORY": "/exported",
                "GLASSDOCK_ENGINE_STATE_DIRECTORY": "/private/engine",
            ]
        )
        #expect(directory.path == "/private/engine")
    }

    @Test("only one daemon can own an engine state directory")
    func excludesSecondOwner() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try EngineStateLock.acquire(directory: directory)
        #expect(throws: EngineStateLockError.alreadyRunning) {
            _ = try EngineStateLock.acquire(directory: directory)
        }
        withExtendedLifetime(first) {}
    }

    @Test("releases ownership when its lifetime ends")
    func releasesOwnership() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try EngineStateLock.acquire(directory: directory)
        }
        _ = try EngineStateLock.acquire(directory: directory)
    }
}
