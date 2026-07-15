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

/// Wraps a client whose underlying XPC connection can go stale.
///
/// `ContainerClient` holds a single `xpc_connection_t` for its lifetime. If the Apple
/// Container daemon (`com.apple.container.apiserver`) restarts — e.g. after an update or
/// a crash — that connection becomes permanently invalid and every call on it fails with
/// `ContainerizationError(.interrupted, message: "XPC connection error: Connection
/// invalid")` (see apple/container's `XPCClient.parseReply`, which maps
/// `XPC_ERROR_CONNECTION_INVALID`/`XPC_ERROR_CONNECTION_INTERRUPTED` to that code). A
/// long-running server process holding the stale struct would otherwise fail every
/// subsequent request until restarted.
///
/// `withClient` runs the operation against the current client and, on that specific
/// error code, replaces it with a freshly constructed one (a new XPC connection) and
/// retries exactly once. Any other error — a real "not found", a bad argument, etc. — is
/// rethrown immediately without reconnecting, since it isn't evidence of a stale
/// connection.
actor ReconnectingContainerClient<Client: Sendable> {
    private var client: Client
    private let makeClient: @Sendable () -> Client

    /// Number of times the underlying client has been recreated. Exposed for tests.
    private(set) var reconnectCount = 0

    init(makeClient: @escaping @Sendable () -> Client) {
        self.makeClient = makeClient
        self.client = makeClient()
    }

    func withClient<T>(_ operation: @Sendable (Client) async throws -> T) async throws -> T {
        let currentCount = reconnectCount
        let currentClient = client
        do {
            return try await operation(currentClient)
        } catch let error as ContainerizationError where error.code == .interrupted {
            // Guard against a reconnect storm: if many concurrent callers hit the same
            // stale connection, only the first to reach here (reconnectCount still
            // matches what it observed before the call) recreates the client — the
            // rest reuse the one that task already built.
            if reconnectCount == currentCount {
                reconnectCount += 1
                client = makeClient()
            }
            return try await operation(client)
        }
    }
}
