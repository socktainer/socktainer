import Foundation
import Testing

@testable import GlassDock

@Suite("Container filesystem operation lock")
struct ContainerFilesystemOperationLockTests {
    actor Events {
        var values: [String] = []
        func append(_ value: String) { values.append(value) }
    }

    @Test("serializes the same container while allowing distinct containers")
    func keyedSerialization() async throws {
        let lock = ContainerFilesystemOperationLock()
        let events = Events()

        async let first: Void = lock.withLock(containerID: "one") {
            await events.append("first-start")
            try await Task.sleep(for: .milliseconds(50))
            await events.append("first-end")
        }
        try await Task.sleep(for: .milliseconds(5))
        async let second: Void = lock.withLock(containerID: "one") {
            await events.append("second")
        }
        async let other: Void = lock.withLock(containerID: "two") {
            await events.append("other")
        }

        _ = try await (first, second, other)
        let values = await events.values
        #expect(values.firstIndex(of: "first-end")! < values.firstIndex(of: "second")!)
        #expect(values.contains("other"))
    }
}
