import ContainerizationError
import Foundation
import Testing

@testable import socktainer

@Suite("Apple Container version check")
struct AppleContainerVersionCheckTests {

    @Test("interrupted connections report the Apple Container service as unavailable")
    func interruptedConnection() async {
        let error = await capturedError {
            throw ContainerizationError(.interrupted, message: "XPC connection error: Connection invalid")
        }

        #expect(error == .appleContainerUnavailable)
        #expect(error?.localizedDescription.contains("container system status") == true)
        #expect(error?.localizedDescription.contains("container system start") == true)
        #expect(error?.localizedDescription.contains("incompatible") == false)
    }

    @Test("XPC response timeouts report the Apple Container service as unavailable")
    func xpcResponseTimeout() async {
        let error = await capturedError {
            throw ContainerizationError(
                .internalError,
                message: "XPC timeout for request to com.apple.container.apiserver/Ping"
            )
        }

        #expect(error == .appleContainerUnavailable)
    }

    @Test("typed timeouts report the Apple Container service as unavailable")
    func typedTimeout() async {
        let error = await capturedError {
            throw ContainerizationError(.timeout, message: "Connection timed out")
        }

        #expect(error == .appleContainerUnavailable)
    }

    @Test("other internal errors remain version detection failures")
    func otherInternalError() async {
        let underlyingError = ContainerizationError(
            .internalError,
            message: "failed to decode apiServerVersion in health check"
        )
        let error = await capturedError {
            throw underlyingError
        }

        #expect(error == .versionDetectionFailed(underlyingError.localizedDescription))
    }

    @Test("a reachable service with the wrong version reports the version mismatch")
    func incompatibleVersion() async {
        let error = await capturedError {
            "apiserver version 99.0.0"
        }

        #expect(
            error
                == .incompatibleVersion(
                    detected: "99.0.0",
                    expected: getAppleContainerVersion()
                )
        )
    }

    @Test("error message text does not determine the failure classification")
    func doesNotClassifyLocalizedDescription() async {
        let underlyingError = NSError(
            domain: "AppleContainerVersionCheckTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "XPC connection interrupted"]
        )
        let error = await capturedError {
            throw underlyingError
        }

        #expect(error == .versionDetectionFailed("XPC connection interrupted"))
    }

    private func capturedError(
        fetchAPIServerVersion: @escaping @Sendable () async throws -> String
    ) async -> AppleContainerVersionCheck.VersionCheckError? {
        do {
            try await AppleContainerVersionCheck.checkCompatibility(
                fetchAPIServerVersion: fetchAPIServerVersion
            )
            Issue.record("Expected compatibility check to fail")
            return nil
        } catch let error as AppleContainerVersionCheck.VersionCheckError {
            return error
        } catch {
            Issue.record("Unexpected error: \(error)")
            return nil
        }
    }
}

@Suite("Apple Container compatibility action")
struct AppleContainerCompatibilityActionTests {

    @Test("a version mismatch warns and does not abort")
    func versionMismatchWarnsAndContinues() {
        let error = AppleContainerVersionCheck.VersionCheckError.incompatibleVersion(
            detected: "1.2.2",
            expected: "1.2.0"
        )

        let action = AppleContainerVersionCheck.compatibilityAction(for: error)

        guard case .proceedWithWarning(let message) = action else {
            Issue.record("Expected .proceedWithWarning, got \(action)")
            return
        }
        #expect(message.contains("1.2.2"))
        #expect(message.contains("1.2.0"))
    }

    @Test("an unreachable Apple Container service still aborts")
    func unavailableServiceStillAborts() {
        let action = AppleContainerVersionCheck.compatibilityAction(for: .appleContainerUnavailable)

        guard case .abort = action else {
            Issue.record("Expected .abort, got \(action)")
            return
        }
    }

    @Test("a version detection failure still aborts")
    func detectionFailureStillAborts() {
        let action = AppleContainerVersionCheck.compatibilityAction(
            for: .versionDetectionFailed("boom")
        )

        guard case .abort = action else {
            Issue.record("Expected .abort, got \(action)")
            return
        }
    }
}
