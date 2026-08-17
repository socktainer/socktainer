import Testing

@testable import socktainer

/// Regression tests for issue #359: `POST /images/create` never emitted a terminal
/// status docker-java's `PullImageResultCallback.checkDockerClientPullSuccessful`
/// recognizes ("Status: Downloaded newer image for …", "Status: Image is up to
/// date for …", or "Download complete"), so every pull under Testcontainers failed
/// even though the image was fetched correctly.
@Suite("ClientImageService.pulledStatusMessage")
struct ClientImageServicePullStatusTests {

    @Test("produces the exact phrase docker-java's terminal-status check accepts")
    func matchesDockerJavaAcceptedPhrase() {
        let message = ClientImageService.pulledStatusMessage(for: "docker.io/library/hello-world:latest")
        #expect(message == "Status: Downloaded newer image for docker.io/library/hello-world:latest")
        #expect(message.hasPrefix("Status: Downloaded newer image for "))
    }

    @Test("round-trips whatever reference string it's given, tag and all")
    func preservesReferenceVerbatim() {
        #expect(ClientImageService.pulledStatusMessage(for: "redis:7-alpine") == "Status: Downloaded newer image for redis:7-alpine")
    }
}
