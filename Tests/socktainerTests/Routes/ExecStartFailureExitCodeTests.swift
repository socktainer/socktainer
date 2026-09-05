import ContainerizationError
import Testing

@testable import socktainer

/// Unit tests for `ExecRoute.execStartFailureExitCode`, which classifies a
/// `process.start()` failure into the exit code Docker clients expect.
///
/// Without this, every `process.start()` failure — including a missing
/// executable — is recorded as exit code -1 (255 as Docker's CLI displays
/// it), instead of the POSIX/Docker "command not found" convention of 127
/// (see issue #383, and testcontainers-go's wait strategy which branches on
/// the exact exit code).
@Suite("ExecRoute.execStartFailureExitCode")
struct ExecStartFailureExitCodeTests {

    @Test("missing executable maps to 127")
    func missingExecutableMapsTo127() {
        let error = ContainerizationError(.internalError, message: "failed to find target executable foo")
        #expect(ExecRoute.execStartFailureExitCode(error) == 127)
    }

    @Test("unrelated failure falls back to -1")
    func unrelatedFailureFallsBackToNegativeOne() {
        let error = ContainerizationError(.internalError, message: "some other startup failure")
        #expect(ExecRoute.execStartFailureExitCode(error) == -1)
    }
}
