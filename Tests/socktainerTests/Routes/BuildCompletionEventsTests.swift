import Foundation
import Testing

@testable import socktainer

/// docker-py's `images.build()` scans every `stream` event with
/// `(^Successfully built |sha256:)([0-9a-f]+)$` and raises `BuildError` when no event
/// carries a hex image ID, even after a successful build (#414).
@Suite("BuildRoute completion events")
struct BuildCompletionEventsTests {
    static let imageID = "sha256:83fc7ce1224f5ed3885f6aaec0bb001c0bbb2a308e3250d7408804a720c72a32"

    /// docker-py's pattern; its `$` matches before the trailing newline, so it is dropped here.
    static func dockerPyImageID(_ event: [String: Any]) -> String? {
        guard let stream = event["stream"] as? String,
            let match = stream.trimmingCharacters(in: .newlines).wholeMatch(of: /(?:Successfully built |.*sha256:)([0-9a-f]+)/)
        else { return nil }
        return String(match.1)
    }

    @Test("a known ID yields aux.ID, Successfully built <short id> and Successfully tagged")
    func withImageID() throws {
        let events = BuildRoute.completionEvents(imageID: Self.imageID, tag: "docker.io/library/probe:1")

        #expect(events.count == 3)
        #expect((events[0]["aux"] as? [String: String])?["ID"] == Self.imageID)
        #expect(events[1]["stream"] as? String == "Successfully built 83fc7ce1224f\n")
        #expect(Self.dockerPyImageID(events[1]) == "83fc7ce1224f")
        #expect(events[2]["stream"] as? String == "Successfully tagged docker.io/library/probe:1\n")
        for event in events {
            #expect(JSONSerialization.isValidJSONObject(event))
        }
    }

    @Test("an unknown ID yields only the tagged event")
    func withoutImageID() {
        let events = BuildRoute.completionEvents(imageID: nil, tag: "probe:1")

        #expect(events.count == 1)
        #expect(events[0]["stream"] as? String == "Successfully tagged probe:1\n")
        #expect(Self.dockerPyImageID(events[0]) == nil)
    }

    @Test("an untagged build yields no Successfully tagged event")
    func untaggedBuild() {
        let events = BuildRoute.completionEvents(imageID: Self.imageID, tag: nil)

        #expect(events.count == 2)
        #expect(events[1]["stream"] as? String == "Successfully built 83fc7ce1224f\n")
        #expect(BuildRoute.completionEvents(imageID: nil, tag: nil).isEmpty)
    }
}
