//===----------------------------------------------------------------------===//
// Copyright © 2026 the socktainer authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerizationError
import Foundation
import Testing

@testable import socktainer

@Suite("ReconnectingContainerClient")
struct ReconnectingContainerClientTests {

    /// Stands in for a `ContainerClient` connection. Each value made by `makeClient`
    /// carries the next `generation`, so tests can tell whether an operation ran
    /// against the original client or a freshly reconnected one.
    struct FakeConnection: Sendable {
        let generation: Int
    }

    @Test("Reconnects once and recovers when the client reports a stale XPC connection")
    func retryRecoversOnceOnStaleConnection() async throws {
        let generations = Counter()
        let client = ReconnectingContainerClient<FakeConnection>(makeClient: {
            FakeConnection(generation: generations.nextSync())
        })

        let attempts = Counter()
        let result = try await client.withClient { connection -> Int in
            let attempt = attempts.nextSync()
            if attempt == 1 {
                // Mirrors apple/container's XPCClient.parseReply mapping
                // XPC_ERROR_CONNECTION_INVALID to ContainerizationError(.interrupted, ...).
                throw ContainerizationError(.interrupted, message: "XPC connection error: Connection invalid")
            }
            return connection.generation
        }

        #expect(result == 2, "the retried call should observe the freshly reconnected client (generation 2)")
        let reconnectCount = await client.reconnectCount
        #expect(reconnectCount == 1)
    }

    @Test("Does not retry or reconnect for a non-stale error")
    func nonStaleErrorNotRetried() async throws {
        let generations = Counter()
        let client = ReconnectingContainerClient<FakeConnection>(makeClient: {
            FakeConnection(generation: generations.nextSync())
        })

        let attempts = Counter()
        await #expect(throws: ContainerizationError.self) {
            try await client.withClient { _ -> Int in
                attempts.nextSync()
                throw ContainerizationError(.notFound, message: "container not found")
            }
        }

        #expect(attempts.countSync() == 1, "a non-stale error must not be retried")
        let reconnectCount = await client.reconnectCount
        #expect(reconnectCount == 0)
    }
}

/// A tiny thread-safe counter used to observe call/reconnect counts from
/// synchronous, non-isolated closures (e.g. the `makeClient` factory).
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    @discardableResult
    func nextSync() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    func countSync() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
