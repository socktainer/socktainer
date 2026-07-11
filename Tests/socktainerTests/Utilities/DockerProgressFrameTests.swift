import Foundation
import Testing

@testable import socktainer

@Suite("DockerProgressFrame")
struct DockerProgressFrameTests {

    private func decode(_ frame: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(frame.utf8))
        return object as? [String: Any] ?? [:]
    }

    @Test("status frames carry the message and end with a newline")
    func statusFrame() throws {
        let frame = DockerProgressFrame.status("Pushing layer 3/5")
        #expect(frame.hasSuffix("\n"))
        let json = try decode(frame)
        #expect(json["status"] as? String == "Pushing layer 3/5")
    }

    @Test("error frames use moby's errorDetail shape")
    func errorFrame() throws {
        let frame = DockerProgressFrame.error("no credentials found for host registry-1.docker.io")
        let json = try decode(frame)
        #expect(json["error"] as? String == "no credentials found for host registry-1.docker.io")
        let detail = json["errorDetail"] as? [String: Any]
        #expect(detail?["message"] as? String == "no credentials found for host registry-1.docker.io")
    }

    @Test("progress-bar frames carry status, id and aggregate byte counts")
    func progressBarFrame() throws {
        let frame = DockerProgressFrame.progress(status: "Downloading", id: "alpine:3.21", current: 1_048_576, total: 4_194_304)
        let json = try decode(frame)
        #expect(json["status"] as? String == "Downloading")
        #expect(json["id"] as? String == "alpine:3.21")
        let detail = json["progressDetail"] as? [String: Any]
        #expect(detail?["current"] as? Int == 1_048_576)
        #expect(detail?["total"] as? Int == 4_194_304)
    }

    @Test("messages with quotes, newlines and backslashes stay valid JSON")
    func escaping() throws {
        let hostile = "HTTP request failed:\n response: 401 \"Unauthorized\" \\ raw"
        let statusJson = try decode(DockerProgressFrame.status(hostile))
        #expect(statusJson["status"] as? String == hostile)
        let errorJson = try decode(DockerProgressFrame.error(hostile))
        #expect(errorJson["error"] as? String == hostile)
    }
}
