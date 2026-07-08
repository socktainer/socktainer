import Testing

@testable import socktainer

@Suite("ContainerInfoCache")
struct ContainerInfoCacheTests {

    @Test("get returns nil for unknown id")
    func getUnknownId() async {
        let cache = ContainerInfoCache()
        let result = await cache.get(id: "unknown")
        #expect(result == nil)
    }

    @Test("set stores info retrievable by both hex and native id")
    func setStoredByBothIds() async {
        let cache = ContainerInfoCache()
        await cache.set(hexId: "hex123", nativeId: "native-name", image: "alpine", labels: ["app": "test"])

        let byHex = await cache.get(id: "hex123")
        let byNative = await cache.get(id: "native-name")

        #expect(byHex?.image == "alpine")
        #expect(byHex?.labels["app"] == "test")
        #expect(byNative?.image == "alpine")
        #expect(byNative?.nativeId == "native-name")
    }

    @Test("remove clears both hex and native entries")
    func removeCleansBothKeys() async {
        let cache = ContainerInfoCache()
        await cache.set(hexId: "hex123", nativeId: "native-name", image: "alpine", labels: [:])

        await cache.remove(id: "hex123")

        #expect(await cache.get(id: "hex123") == nil)
        #expect(await cache.get(id: "native-name") == nil)
    }

    @Test("remove by native id also clears hex entry")
    func removeByNativeIdClearsHex() async {
        let cache = ContainerInfoCache()
        await cache.set(hexId: "hex123", nativeId: "native-name", image: "alpine", labels: [:])

        await cache.remove(id: "native-name")

        #expect(await cache.get(id: "hex123") == nil)
        #expect(await cache.get(id: "native-name") == nil)
    }

    @Test("remove unknown id is a no-op")
    func removeUnknownIdIsNoOp() async {
        let cache = ContainerInfoCache()
        await cache.set(hexId: "hex123", nativeId: "native-name", image: "alpine", labels: [:])
        await cache.remove(id: "other-id")

        #expect(await cache.get(id: "hex123") != nil)
    }

    // --rm destroy gate + dedup: exactly one of the foreground attach path and the detached
    // die observer may emit the destroy event for an auto-removed container.

    @Test("consumeAutoRemove returns false for a container not marked --rm")
    func consumeNotMarked() async {
        let cache = ContainerInfoCache()
        #expect(await cache.consumeAutoRemove(id: "hex123") == false)
    }

    @Test("consumeAutoRemove returns true exactly once, then false (dedup)")
    func consumeOnce() async {
        let cache = ContainerInfoCache()
        await cache.set(hexId: "hex123", nativeId: "native-name", image: "alpine", labels: [:])
        await cache.markAutoRemove(hexId: "hex123", nativeId: "native-name")

        #expect(await cache.consumeAutoRemove(id: "hex123") == true)
        // Second claim — by EITHER id — must be false so only one destroy fires.
        #expect(await cache.consumeAutoRemove(id: "hex123") == false)
        #expect(await cache.consumeAutoRemove(id: "native-name") == false)
    }

    @Test("consumeAutoRemove via native id clears the hex claim too")
    func consumeByNativeClearsHex() async {
        let cache = ContainerInfoCache()
        await cache.set(hexId: "hex123", nativeId: "native-name", image: "alpine", labels: [:])
        await cache.markAutoRemove(hexId: "hex123", nativeId: "native-name")

        // The detached die observer claims by native id; the foreground attach path (hex) must
        // then see it already consumed.
        #expect(await cache.consumeAutoRemove(id: "native-name") == true)
        #expect(await cache.consumeAutoRemove(id: "hex123") == false)
    }

    @Test("remove clears a pending --rm mark so a stale observer can't fire a second destroy")
    func removeClearsAutoRemoveMark() async {
        let cache = ContainerInfoCache()
        await cache.set(hexId: "hex123", nativeId: "native-name", image: "alpine", labels: [:])
        await cache.markAutoRemove(hexId: "hex123", nativeId: "native-name")

        // ContainerDeleteRoute (or an earlier consumer) removes the container before a stale
        // die observer gets to consumeAutoRemove — that observer must not find the mark.
        await cache.remove(id: "hex123")

        #expect(await cache.consumeAutoRemove(id: "hex123") == false)
        #expect(await cache.consumeAutoRemove(id: "native-name") == false)
    }
}
