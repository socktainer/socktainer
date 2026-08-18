import Testing

@testable import socktainer

/// `AppleContainerBootstrap.ensureRunning()` itself needs a live Apple Container service
/// (or the lack of one) to exercise meaningfully, so — like
/// `AppleContainerVersionCheck.checkCompatibility()` — it isn't unit tested directly. What
/// is tested here is the pure decision logic pulled out of it: given the shape of what
/// happened (already running / start succeeded / start failed / start "succeeded" but the
/// service still doesn't answer), what should be printed.
@Suite("AppleContainerBootstrap.Outcome")
struct AppleContainerBootstrapOutcomeTests {

    @Test("already running produces no message")
    func alreadyRunningIsSilent() {
        #expect(AppleContainerBootstrap.Outcome.alreadyRunning.message == "")
    }

    @Test("started reports success")
    func startedReportsSuccess() {
        let message = AppleContainerBootstrap.Outcome.started.message
        #expect(message.contains("started"))
        #expect(!message.contains("WARN"))
    }

    @Test("startFailed tells the user to run the command manually")
    func startFailedTellsUserToRunManually() {
        let message = AppleContainerBootstrap.Outcome.startFailed.message
        #expect(message.contains("WARN"))
        #expect(message.contains("container system start"))
    }

    @Test("startedButUnresponsive is distinct from a clean failure")
    func startedButUnresponsiveIsDistinctMessage() {
        let message = AppleContainerBootstrap.Outcome.startedButUnresponsive.message
        #expect(message.contains("WARN"))
        #expect(message != AppleContainerBootstrap.Outcome.startFailed.message)
        #expect(message.contains("exited successfully"))
    }

    @Test("every non-silent outcome message is distinct")
    func messagesAreDistinct() {
        let messages: [String] = [
            AppleContainerBootstrap.Outcome.started.message,
            AppleContainerBootstrap.Outcome.startFailed.message,
            AppleContainerBootstrap.Outcome.startedButUnresponsive.message,
        ]
        #expect(Set(messages).count == messages.count)
    }
}
