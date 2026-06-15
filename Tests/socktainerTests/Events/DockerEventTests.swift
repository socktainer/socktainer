import Foundation
import Testing

@testable import socktainer

@Suite("DockerEvent — label forwarding in Actor.Attributes")
struct DockerEventTests {

    @Test("simpleEvent includes user labels in Attributes")
    func simpleEventIncludesLabels() {
        let event = DockerEvent.simpleEvent(
            id: "ctr-1",
            type: "container",
            status: "start",
            image: "alpine:latest",
            name: "my-container",
            labels: ["app": "myapp", "version": "2.0"]
        )

        #expect(event.Actor.Attributes["app"] == "myapp")
        #expect(event.Actor.Attributes["version"] == "2.0")
    }

    @Test("simpleEvent merges image and name into Attributes")
    func simpleEventMergesImageAndName() {
        let event = DockerEvent.simpleEvent(
            id: "ctr-1",
            type: "container",
            status: "start",
            image: "alpine:latest",
            name: "my-container",
            labels: [:]
        )

        #expect(event.Actor.Attributes["image"] == "alpine:latest")
        #expect(event.Actor.Attributes["name"] == "my-container")
        #expect(event.from == "alpine:latest")
    }

    @Test("simpleEvent falls back to id for name when name is empty")
    func simpleEventFallsBackToId() {
        let event = DockerEvent.simpleEvent(
            id: "ctr-abc",
            type: "container",
            status: "start"
        )

        #expect(event.Actor.Attributes["name"] == "ctr-abc")
        #expect(event.Actor.Attributes["image"] == "")
    }

    @Test("simpleEvent with no labels produces only image and name in Attributes")
    func simpleEventNoLabelsHasOnlyStandardKeys() {
        let event = DockerEvent.simpleEvent(
            id: "ctr-1",
            type: "container",
            status: "stop",
            image: "postgres:17",
            name: "db"
        )

        #expect(event.Actor.Attributes.keys.sorted() == ["image", "name"])
    }

    @Test("simpleEvent Attributes contain labels plus image and name")
    func simpleEventAttributeKeySet() {
        let event = DockerEvent.simpleEvent(
            id: "ctr-1",
            type: "container",
            status: "start",
            image: "alpine",
            name: "test",
            labels: ["app": "x", "env": "prod"]
        )

        #expect(event.Actor.Attributes.keys.sorted() == ["app", "env", "image", "name"])
    }

    @Test("Attributes encodes as flat JSON dictionary")
    func attributesEncodesAsFlat() throws {
        let event = DockerEvent.simpleEvent(
            id: "ctr-1",
            type: "container",
            status: "start",
            image: "alpine",
            name: "test",
            labels: ["app": "myapp"]
        )

        let json = try JSONEncoder().encode(event)
        let obj = try JSONDecoder().decode([String: AnyDecodable].self, from: json)
        let actor = obj["Actor"]?.value as? [String: Any]
        let attributes = actor?["Attributes"] as? [String: String]

        #expect(attributes?["app"] == "myapp")
        #expect(attributes?["image"] == "alpine")
        #expect(attributes?["name"] == "test")
    }
}

// Minimal helper for decoding arbitrary JSON values in tests.
private struct AnyDecodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let dict = try? container.decode([String: AnyDecodable].self) {
            value = dict.mapValues { $0.value }
        } else if let array = try? container.decode([AnyDecodable].self) {
            value = array.map { $0.value }
        } else {
            value = ()
        }
    }
}
