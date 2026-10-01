import ContainerResource
import Foundation
import Logging
import Testing

@testable import socktainer

@Suite("Anonymous volume lifecycle")
struct ContainerAnonymousVolumesTests {
    @Test("ownership survives serialization without depending on an in-memory cache")
    func persistedOwnership() throws {
        let labels = [ContainerAnonymousVolumes.label: try ContainerAnonymousVolumes.encode(["anonymous-b", "anonymous-a"])]
        let restored = try JSONDecoder().decode([String: String].self, from: JSONEncoder().encode(labels))
        #expect(ContainerAnonymousVolumes.names(labels: restored) == ["anonymous-a", "anonymous-b"])
        #expect(ContainerAnonymousVolumes.names(labels: [:]).isEmpty)
        #expect(ContainerAnonymousVolumes.names(labels: [ContainerAnonymousVolumes.label: "invalid"]).isEmpty)
    }

    @Test("cleanup only visits owned names and continues after an already-missing volume")
    func cleanup() async {
        let calls = VolumeCalls()
        await ContainerAnonymousVolumes.remove(names: ["a", "b", "a"], logger: Logger(label: "test")) { name in
            await calls.add(name)
            if name == "a" { throw VolumeError.volumeNotFound(name) }
        }
        #expect(await calls.names == ["a", "b"])
    }

    @Test("auto-remove cleans owned volumes using cached or fallback labels", arguments: [true, false])
    func autoRemoveUsesPersistedOwnership(cached: Bool) async throws {
        let id = "volume-cleanup-\(UUID().uuidString)"
        let labels = [ContainerAnonymousVolumes.label: try ContainerAnonymousVolumes.encode(["owned-volume"])]
        if cached {
            await ContainerInfoCache.shared.set(hexId: id, nativeId: id, image: "alpine", labels: labels)
        }
        let calls = VolumeCalls()
        await ContainerAutoRemoveCleanup.perform(
            hexId: id, nativeId: id, fallbackImage: "alpine", fallbackLabels: cached ? [:] : labels,
            dnsServer: nil, broadcaster: nil,
            removeVolumes: { names in
                for name in names { await calls.add(name) }
            })
        #expect(await calls.names == ["owned-volume"])
        #expect(await ContainerInfoCache.shared.get(id: id) == nil)
    }

    @Test("auto-remove retries while the runtime is still releasing mounts")
    func teardownRace() async {
        let calls = VolumeCalls()
        await ContainerAnonymousVolumes.remove(
            names: ["a"], logger: Logger(label: "test"), retries: 2, retryDelayNanoseconds: 0
        ) { name in
            await calls.add(name)
            if await calls.names.count == 1 { throw VolumeError.volumeInUse(name) }
        }
        #expect(await calls.names == ["a", "a"])
    }

    @Test("a volume still shared after retries is retained; other cleanup proceeds")
    func sharedVolume() async {
        let calls = VolumeCalls()
        await ContainerAnonymousVolumes.remove(
            names: ["a", "b"], logger: Logger(label: "test"), retries: 1, retryDelayNanoseconds: 0
        ) { name in
            await calls.add(name)
            if name == "a" { throw VolumeError.volumeInUse(name) }
        }
        #expect(await calls.names == ["a", "a", "b"])
    }
}

private actor VolumeCalls {
    var names: [String] = []
    func add(_ name: String) { names.append(name) }
}
