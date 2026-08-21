import ContainerizationOCI
import Logging

@testable import socktainer

/// Records calls made through a `MockManifestClient` in registration order, so a test can
/// assert not just the return values but the sequence (e.g. retag happens before push, untag
/// happens after).
actor CallRecorder {
    private(set) var calls: [String] = []
    func record(_ call: String) { calls.append(call) }
}

/// A generic mutable box a `@Sendable` mock handler closure can write into and a test can read
/// back from after the request completes — a plain captured `var` isn't `Sendable` across the
/// mock's closures, which run in a different isolation context than the test body.
actor Box<Value: Sendable> {
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ value: Value) { self.value = value }
    func get() -> Value { value }
}

/// A `ClientManifestServiceProtocol` mock configured per-test via optional handler closures.
/// Any method invoked without a handler throws `Unconfigured` — this surfaces an unexpectedly
/// exercised code path as a test failure instead of a silent default.
struct MockManifestClient: ClientManifestServiceProtocol {
    struct Unconfigured: Error, CustomStringConvertible {
        let method: String
        var description: String { "MockManifestClient.\(method) was called without a handler configured" }
    }

    var recorder: CallRecorder?
    var existsHandler: (@Sendable (String) async throws -> Bool)?
    var digestHandler: (@Sendable (String) async throws -> String)?
    var inspectHandler: (@Sendable (String) async throws -> Index)?
    var createHandler: (@Sendable (String, [String], Bool) async throws -> String)?
    var mergeAndTagHandler: (@Sendable (String, [String]) async throws -> String)?
    var addHandler: (@Sendable (String, [String]) async throws -> String)?
    var removeDigestHandler: (@Sendable (String, String) async throws -> String)?
    var addBuiltImageHandler: (@Sendable (String, String) async throws -> String)?
    var deleteHandler: (@Sendable (String) async throws -> Void)?
    var retagForPushHandler: (@Sendable (String, String) async throws -> (reference: String, priorState: RetagState?))?
    var untagPushDestinationHandler: (@Sendable (RetagState) async throws -> Void)?

    func exists(name: String) async throws -> Bool {
        await recorder?.record("exists(\(name))")
        guard let existsHandler else { throw Unconfigured(method: "exists") }
        return try await existsHandler(name)
    }

    func digest(for name: String) async throws -> String {
        await recorder?.record("digest(\(name))")
        guard let digestHandler else { throw Unconfigured(method: "digest") }
        return try await digestHandler(name)
    }

    func inspect(name: String) async throws -> Index {
        await recorder?.record("inspect(\(name))")
        guard let inspectHandler else { throw Unconfigured(method: "inspect") }
        return try await inspectHandler(name)
    }

    func create(name: String, images: [String], logger: Logger, amend: Bool) async throws -> String {
        await recorder?.record("create(\(name), \(images), amend: \(amend))")
        guard let createHandler else { throw Unconfigured(method: "create") }
        return try await createHandler(name, images, amend)
    }

    func mergeAndTag(name: String, images: [String], logger: Logger) async throws -> String {
        await recorder?.record("mergeAndTag(\(name), \(images))")
        guard let mergeAndTagHandler else { throw Unconfigured(method: "mergeAndTag") }
        return try await mergeAndTagHandler(name, images)
    }

    func add(name: String, images: [String], logger: Logger) async throws -> String {
        await recorder?.record("add(\(name), \(images))")
        guard let addHandler else { throw Unconfigured(method: "add") }
        return try await addHandler(name, images)
    }

    func removeDigest(name: String, digest: String) async throws -> String {
        await recorder?.record("removeDigest(\(name), \(digest))")
        guard let removeDigestHandler else { throw Unconfigured(method: "removeDigest") }
        return try await removeDigestHandler(name, digest)
    }

    func addBuiltImage(name: String, builtReference: String, logger: Logger) async throws -> String {
        await recorder?.record("addBuiltImage(\(name), \(builtReference))")
        guard let addBuiltImageHandler else { throw Unconfigured(method: "addBuiltImage") }
        return try await addBuiltImageHandler(name, builtReference)
    }

    func delete(name: String) async throws {
        await recorder?.record("delete(\(name))")
        guard let deleteHandler else { throw Unconfigured(method: "delete") }
        try await deleteHandler(name)
    }

    func retagForPush(name: String, destination: String) async throws -> (reference: String, priorState: RetagState?) {
        await recorder?.record("retagForPush(\(name), \(destination))")
        guard let retagForPushHandler else { throw Unconfigured(method: "retagForPush") }
        return try await retagForPushHandler(name, destination)
    }

    func untagPushDestination(_ state: RetagState) async throws {
        await recorder?.record("untagPushDestination(\(state.reference))")
        guard let untagPushDestinationHandler else { throw Unconfigured(method: "untagPushDestination") }
        try await untagPushDestinationHandler(state)
    }
}
