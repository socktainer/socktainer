import Foundation
import Testing

@testable import socktainer

@Suite("ExecManager.waitForExitCode")
struct ExecExitCodeWaitTests {

    private func makeStartedExec() async -> String {
        let execId = await ExecManager.shared.create(
            config: ExecManager.ExecConfig(
                containerId: "devcontainer-lifecycle",
                cmd: ["sh", "-c", "exit 42"],
                attachStdin: false,
                attachStdout: true,
                attachStderr: true,
                tty: false,
                detach: false,
                env: [],
                user: nil,
                workingDir: nil
            )
        )
        _ = await ExecManager.shared.markStarted(id: execId)
        return execId
    }

    @Test("returns immediately when the exit code is already recorded")
    func alreadyRecorded() async {
        let execId = await makeStartedExec()
        await ExecManager.shared.setExitCode(id: execId, code: 42)

        let code = await ExecManager.shared.waitForExitCode(id: execId)

        #expect(code == 42)
        await ExecManager.shared.remove(id: execId)
    }

    @Test("blocks until a late exit code lands instead of returning nil at pipe EOF")
    func waitsForLateExitCode() async throws {
        let execId = await makeStartedExec()

        Task {
            try await Task.sleep(nanoseconds: 100_000_000)
            await ExecManager.shared.setExitCode(id: execId, code: 42)
        }

        let code = await ExecManager.shared.waitForExitCode(id: execId)

        #expect(code == 42)
        await ExecManager.shared.remove(id: execId)
    }

    @Test("gives up after the timeout when no exit code is ever recorded")
    func timesOutWhenNeverRecorded() async {
        let execId = await makeStartedExec()

        let code = await ExecManager.shared.waitForExitCode(id: execId, timeoutNanoseconds: 100_000_000)

        #expect(code == nil)
        await ExecManager.shared.remove(id: execId)
    }
}
