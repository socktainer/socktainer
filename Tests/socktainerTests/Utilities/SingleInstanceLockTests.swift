import Foundation
import Testing

@testable import socktainer

@Suite("SingleInstanceLock")
struct SingleInstanceLockTests {

    // MARK: - Helpers

    /// Returns a fresh temp directory and cleans it up after the test.
    private func withTempHome(_ body: (String) throws -> Void) throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("socktainer-lock-test-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try body(tmp)
    }

    // MARK: - Tests

    @Test("missing home directory is rejected")
    func missingHomeDirectory() {
        #expect(throws: SingleInstanceError.missingHomeDirectory) {
            try acquireSingleInstanceLock(homeDirectory: nil)
        }
    }

    @Test("first caller acquires the lock")
    func firstCallerAcquires() throws {
        try withTempHome { home in
            let lock = try acquireSingleInstanceLock(homeDirectory: home)
            withExtendedLifetime(lock) {}
        }
    }

    @Test("a second daemon against the same home directory is refused, not allowed to steal the socket")
    func secondCallerIsRefused() throws {
        try withTempHome { home in
            let firstLock = try acquireSingleInstanceLock(homeDirectory: home)

            #expect(throws: (any Error).self) {
                try acquireSingleInstanceLock(homeDirectory: home)
            }

            withExtendedLifetime(firstLock) {}
        }
    }

    @Test("releasing the lock (process exit equivalent) lets a new instance start")
    func lockIsReleasedWhenHandleDeallocates() throws {
        try withTempHome { home in
            do {
                let firstLock = try acquireSingleInstanceLock(homeDirectory: home)
                withExtendedLifetime(firstLock) {}
            }
            // `firstLock` has gone out of scope and deinitialized here, closing its fd and
            // releasing the flock — a fresh instance must now be able to acquire it.
            let secondLock = try acquireSingleInstanceLock(homeDirectory: home)
            withExtendedLifetime(secondLock) {}
        }
    }
}
