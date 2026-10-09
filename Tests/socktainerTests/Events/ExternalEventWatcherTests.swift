import ContainerResource
import Foundation
import Testing

@testable import socktainer

@Suite("External event watcher")
struct ExternalEventWatcherTests {

    private func snapshot(_ id: String, _ status: RuntimeStatus) throws -> ContainerSnapshot {
        try makeContainerSnapshot(nativeId: id, ip: "192.168.65.2", network: "default", labels: [:], status: status)
    }

    private func actions(_ previous: [String: ContainerSnapshot], _ current: [String: ContainerSnapshot]) -> [String] {
        ExternalEventWatcher.containerTransitions(previous: previous, current: current).map { "\($0.Actor.Attributes["name"] ?? ""):\($0.Action)" }.sorted()
    }

    private func imageActions(_ previous: [String: String], _ current: [String: String]) -> [String] {
        ExternalEventWatcher.imageTransitions(previous: previous, current: current).map { "\($0.Action) \($0.Actor.ID) \($0.Actor.Attributes["name"] ?? "")" }.sorted()
    }

    @Test("new running container emits create and start")
    func newRunningContainer() throws {
        #expect(actions([:], ["a": try snapshot("web", .running)]) == ["web:create", "web:start"])
    }

    @Test("new stopped container emits create only")
    func newStoppedContainer() throws {
        #expect(actions([:], ["a": try snapshot("web", .stopped)]) == ["web:create"])
    }

    @Test("stopped to running emits start, running to stopped emits die")
    func statusChanges() throws {
        #expect(actions(["a": try snapshot("web", .stopped)], ["a": try snapshot("web", .running)]) == ["web:start"])
        #expect(actions(["a": try snapshot("web", .running)], ["a": try snapshot("web", .stopped)]) == ["web:die"])
    }

    @Test("removed container emits destroy")
    func removedContainer() throws {
        #expect(actions(["a": try snapshot("web", .stopped)], [:]) == ["web:destroy"])
    }

    @Test("unchanged containers emit nothing")
    func unchanged() throws {
        let state = ["a": try snapshot("web", .running)]
        #expect(actions(state, state).isEmpty)
    }

    @Test("new image emits pull with the repository as name")
    func imagePull() {
        #expect(imageActions([:], ["docker.io/library/nginx:latest": "sha256:a"]) == ["pull docker.io/library/nginx:latest docker.io/library/nginx"])
    }

    @Test("new reference to a known digest emits tag")
    func imageTag() {
        #expect(imageActions(["alpine:latest": "sha256:a"], ["alpine:latest": "sha256:a", "foo:1": "sha256:a"]) == ["tag sha256:a foo:1"])
    }

    @Test("removing one of two references emits untag only")
    func imageUntag() {
        #expect(imageActions(["alpine:latest": "sha256:a", "foo:1": "sha256:a"], ["alpine:latest": "sha256:a"]) == ["untag sha256:a foo:1"])
    }

    @Test("removing the last reference emits untag and delete")
    func imageDelete() {
        #expect(imageActions(["alpine:latest": "sha256:a"], [:]) == ["delete sha256:a sha256:a", "untag sha256:a alpine:latest"])
    }

    @Test("re-pull to a new digest emits pull and deletes the old digest")
    func imageRepull() {
        #expect(imageActions(["alpine:latest": "sha256:a"], ["alpine:latest": "sha256:b"]) == ["delete sha256:a sha256:a", "pull alpine:latest alpine"])
    }

    @Test("dangling references emit no tag events")
    func imageDangling() {
        #expect(imageActions([:], ["untagged@sha256:a": "sha256:a"]).isEmpty)
        #expect(imageActions(["untagged@sha256:a": "sha256:a", "x:1": "sha256:a"], ["untagged@sha256:a": "sha256:a"]) == ["untag sha256:a x:1"])
    }

    @Test("repository name drops tag and digest but keeps registry port")
    func repositoryName() {
        #expect(ExternalEventWatcher.repositoryName("localhost:5000/app:1") == "localhost:5000/app")
        #expect(ExternalEventWatcher.repositoryName("localhost:5000/app") == "localhost:5000/app")
        #expect(ExternalEventWatcher.repositoryName("app@sha256:abc") == "app")
    }

    @Test("pull dedup also matches the short Docker Hub reference")
    func dedupIDs() {
        let pull = DockerEvent.make(type: "image", action: "pull", actorID: "docker.io/library/alpine:latest", attributes: [:])
        #expect(ExternalEventWatcher.dedupIDs(pull) == ["docker.io/library/alpine:latest", "alpine:latest"])
        let userPull = DockerEvent.make(type: "image", action: "pull", actorID: "docker.io/foo/bar:1", attributes: [:])
        #expect(ExternalEventWatcher.dedupIDs(userPull) == ["docker.io/foo/bar:1", "foo/bar:1"])
        let tag = DockerEvent.make(type: "image", action: "tag", actorID: "sha256:a", attributes: [:])
        #expect(ExternalEventWatcher.dedupIDs(tag) == ["sha256:a"])
    }

    @Test("broadcaster remembers recent container and image events")
    func emittedRecently() async {
        let broadcaster = EventBroadcaster()
        await broadcaster.broadcast(DockerEvent.simpleEvent(id: "abc", type: "container", status: "start"))
        await broadcaster.broadcast(DockerEvent.make(type: "image", action: "pull", actorID: "alpine:latest", attributes: [:]))
        #expect(await broadcaster.emittedRecently(id: "abc", action: "start", within: 10))
        #expect(await broadcaster.emittedRecently(id: "alpine:latest", action: "pull", within: 10))
        #expect(await !broadcaster.emittedRecently(id: "abc", action: "die", within: 10))
        #expect(await !broadcaster.emittedRecently(id: "other", action: "start", within: 10))
    }
}
