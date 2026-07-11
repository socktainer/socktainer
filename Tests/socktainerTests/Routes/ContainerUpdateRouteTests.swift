import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

private struct UpdateMock: ClientContainerProtocol {
    let snapshot: ContainerSnapshot
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [snapshot] }
    func getContainer(id: String) async throws -> ContainerSnapshot? {
        id == snapshot.id ? snapshot : nil
    }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}

private struct UpdateResponseBody: Vapor.Content { let Warnings: [String] }
private struct UpdateErrorBody: Vapor.Content { let reason: String }

private func makeSnapshot(id: String, labels: [String: String] = [:]) -> ContainerSnapshot {
    let proc = ProcessConfiguration(
        executable: "/bin/sh", arguments: [], environment: [],
        workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0)
    )
    let img = ImageDescription(
        reference: "alpine:latest",
        descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0)
    )
    var config = ContainerConfiguration(id: id, image: img, process: proc)
    config.labels = labels
    return ContainerSnapshot(configuration: config, status: .running, networks: [])
}

private func withUpdateApp(_ snapshot: ContainerSnapshot, run: (Application) async throws -> Void) async throws {
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.middleware.use(ErrorMiddleware.default(environment: app.environment))
        try app.register(collection: ContainerUpdateRoute(client: UpdateMock(snapshot: snapshot)))
        try await run(app)
    }
}

@Suite("ContainerUpdateRoute", .serialized)
struct ContainerUpdateRouteTests {

    @Test("updating the restart policy stores an override and answers the Moby shape")
    func updateRestartPolicy() async throws {
        let id = "update-ctr-\(UUID().uuidString.prefix(8))"
        let snapshot = makeSnapshot(id: id)
        try await withUpdateApp(snapshot) { app in
            try await app.testing().test(
                .POST, "/v1.51/containers/\(id)/update",
                beforeRequest: { req in
                    try req.content.encode(["RestartPolicy": RestartPolicy(Name: "no", MaximumRetryCount: 0)])
                }
            ) { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(UpdateResponseBody.self)
                #expect(body.Warnings.isEmpty)
            }
        }
        let stored = await RestartPolicyOverrideStore.shared.get(id: DockerContainerID.hexId(for: snapshot))
        #expect(stored?.Name == "no")
        await RestartPolicyOverrideStore.shared.remove(id: DockerContainerID.hexId(for: snapshot))
    }

    @Test("the override wins over the create-time label; a recreated instance gets a fresh key")
    func overridePrecedence() async throws {
        let labels = [RestartPolicyManager.label: #"{"Name":"always"}"#]
        let firstInstance = DockerContainerID.hexId(nativeId: "web", createdAt: Date(timeIntervalSince1970: 1_000))
        let recreatedInstance = DockerContainerID.hexId(nativeId: "web", createdAt: Date(timeIntervalSince1970: 2_000))

        let fromLabel = await RestartPolicyManager.effectivePolicy(hexId: firstInstance, labels: labels)
        #expect(fromLabel?.Name == "always")

        await RestartPolicyOverrideStore.shared.set(id: firstInstance, policy: RestartPolicy(Name: "no", MaximumRetryCount: nil))
        let overridden = await RestartPolicyManager.effectivePolicy(hexId: firstInstance, labels: labels)
        #expect(overridden?.Name == "no")

        let recreated = await RestartPolicyManager.effectivePolicy(hexId: recreatedInstance, labels: labels)
        #expect(recreated?.Name == "always")

        await RestartPolicyOverrideStore.shared.remove(id: firstInstance)
        let restored = await RestartPolicyManager.effectivePolicy(hexId: firstInstance, labels: labels)
        #expect(restored?.Name == "always")
    }

    @Test("an invalid policy name is rejected with 400")
    func invalidPolicyName() async throws {
        let id = "update-bad-\(UUID().uuidString.prefix(8))"
        let snapshot = makeSnapshot(id: id)
        try await withUpdateApp(snapshot) { app in
            try await app.testing().test(
                .POST, "/v1.51/containers/\(id)/update",
                beforeRequest: { req in
                    try req.content.encode(["RestartPolicy": RestartPolicy(Name: "sometimes", MaximumRetryCount: nil)])
                }
            ) { res async throws in
                #expect(res.status == .badRequest)
                let body = try res.content.decode(UpdateErrorBody.self)
                #expect(body.reason.contains("unknown policy"))
            }
        }
        let stored = await RestartPolicyOverrideStore.shared.get(id: DockerContainerID.hexId(for: snapshot))
        #expect(stored == nil)
    }

    @Test("resource-only updates are rejected: VM resources are fixed at create time")
    func resourceOnlyUpdateRejected() async throws {
        let id = "update-res-\(UUID().uuidString.prefix(8))"
        try await withUpdateApp(makeSnapshot(id: id)) { app in
            try await app.testing().test(
                .POST, "/v1.51/containers/\(id)/update",
                beforeRequest: { req in
                    try req.content.encode(["Memory": Int64(536_870_912)])
                }
            ) { res async throws in
                #expect(res.status == .badRequest)
                let body = try res.content.decode(UpdateErrorBody.self)
                #expect(body.reason.contains("Memory"))
                #expect(body.reason.contains("fixed at create time"))
            }
        }
    }

    @Test("a policy update alongside resource fields succeeds with a warning")
    func policyWithResourcesWarns() async throws {
        let id = "update-warn-\(UUID().uuidString.prefix(8))"
        let snapshot = makeSnapshot(id: id)
        struct Payload: Vapor.Content {
            let RestartPolicy: RestartPolicy
            let Memory: Int64
        }
        try await withUpdateApp(snapshot) { app in
            try await app.testing().test(
                .POST, "/v1.51/containers/\(id)/update",
                beforeRequest: { req in
                    try req.content.encode(Payload(RestartPolicy: RestartPolicy(Name: "on-failure", MaximumRetryCount: 3), Memory: 1024))
                }
            ) { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(UpdateResponseBody.self)
                #expect(body.Warnings.count == 1)
                #expect(body.Warnings[0].contains("Memory"))
            }
        }
        let stored = await RestartPolicyOverrideStore.shared.get(id: DockerContainerID.hexId(for: snapshot))
        #expect(stored?.Name == "on-failure")
        #expect(stored?.MaximumRetryCount == 3)
        await RestartPolicyOverrideStore.shared.remove(id: DockerContainerID.hexId(for: snapshot))
    }

    @Test("a policy update emits a container 'update' event with the canonical hex id")
    func updateEmitsEvent() async throws {
        let id = "update-evt-\(UUID().uuidString.prefix(8))"
        let snapshot = makeSnapshot(id: id)
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "update" { return event }
            return nil
        }

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: ContainerUpdateRoute(client: UpdateMock(snapshot: snapshot)))

            try await app.testing().test(
                .POST, "/v1.51/containers/\(id)/update",
                beforeRequest: { req in
                    try req.content.encode(["RestartPolicy": RestartPolicy(Name: "no", MaximumRetryCount: nil)])
                }
            ) { res async in
                #expect(res.status == .ok)
            }
        }

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            captureTask.cancel()
        }
        let event = await captureTask.value
        timeoutTask.cancel()

        #expect(event?.Type == "container")
        #expect(event?.Actor.ID == DockerContainerID.hexId(for: snapshot))
        #expect(event?.Actor.Attributes["name"] == id)
        await RestartPolicyOverrideStore.shared.remove(id: DockerContainerID.hexId(for: snapshot))
    }

    @Test("overrides survive a store reload from disk")
    func overridePersistence() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("override-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "update-persist-\(UUID().uuidString.prefix(8))"

        let store = RestartPolicyOverrideStore()
        await store.configure(storageDirectory: dir)
        await store.set(id: id, policy: RestartPolicy(Name: "unless-stopped", MaximumRetryCount: nil))

        let reloadedStore = RestartPolicyOverrideStore()
        await reloadedStore.configure(storageDirectory: dir)

        let reloaded = await reloadedStore.get(id: id)
        #expect(reloaded?.Name == "unless-stopped")
    }

    @Test("updating an unknown container answers 404")
    func unknownContainer() async throws {
        try await withUpdateApp(makeSnapshot(id: "exists")) { app in
            try await app.testing().test(
                .POST, "/v1.51/containers/ghost/update",
                beforeRequest: { req in
                    try req.content.encode(["RestartPolicy": RestartPolicy(Name: "no", MaximumRetryCount: nil)])
                }
            ) { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }
}
