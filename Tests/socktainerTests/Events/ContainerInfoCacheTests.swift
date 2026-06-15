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
}
