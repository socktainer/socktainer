import ContainerAPIClient
import ContainerXPC
import Foundation
import XPC

/// Attaches a waiter to an existing init process without bootstrapping its VM again.
enum ContainerInitExitWaiter {
    enum InvalidResponse: Error {
        case missingExitCode
        case invalidExitCode
    }

    static func wait(nativeId: String) async throws -> Int32 {
        let connection = XPCClient(service: "com.apple.container.apiserver")
        defer { connection.close() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let request = XPCMessage(route: .containerWait)
            request.set(key: .id, value: nativeId)
            request.set(key: .processIdentifier, value: nativeId)
            let response = try await connection.send(request)
            try Task.checkCancellation()
            return try exitCode(from: response)
        } onCancel: {
            // XPCClient.send uses a continuation, so task cancellation alone cannot
            // release a request waiting for a still-running process.
            connection.close()
        }
    }

    static func exitCode(from response: XPCMessage) throws -> Int32 {
        guard let value = xpc_dictionary_get_value(response.underlying, XPCKeys.exitCode.rawValue) else {
            throw InvalidResponse.missingExitCode
        }
        guard xpc_get_type(value) == XPC_TYPE_INT64,
            let code = Int32(exactly: xpc_int64_get_value(value)), code >= 0
        else {
            throw InvalidResponse.invalidExitCode
        }
        return code
    }
}
