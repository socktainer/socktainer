import ContainerAPIClient
import ContainerResource
import Foundation
import Logging
import Testing

@testable import socktainer

@Suite("Image-declared volumes")
struct ImageVolumeConfigurationTests {
    @Test("inspect preserves declarations when the raw config is readable")
    func readableInspectVolumes() async {
        let volumes = await ImageVolumeConfiguration.readForInspect(logger: Logger(label: "test")) {
            ["/var/log": [:]]
        }
        #expect(volumes == ["/var/log": [:]])
    }

    @Test("an optional volume metadata failure does not fail all of image inspect")
    func unreadableInspectVolumes() async {
        let volumes = await ImageVolumeConfiguration.readForInspect(logger: Logger(label: "test")) {
            try JSONDecoder().decode(ImageVolumeConfiguration.self, from: Data("not json".utf8)).config?.Volumes
        }
        #expect(volumes == nil)
    }

    @Test("raw Docker image config preserves all k3s volume declarations")
    func k3sVolumes() throws {
        let raw = Data(#"{"config":{"Volumes":{"/var/lib/cni":{},"/var/lib/kubelet":{},"/var/lib/rancher/k3s":{},"/var/log":{}}}}"#.utf8)
        let config = try JSONDecoder().decode(ImageVolumeConfiguration.self, from: raw)
        let paths = try #require(config.config?.Volumes).keys.sorted()
        #expect(paths == ["/var/lib/cni", "/var/lib/kubelet", "/var/lib/rancher/k3s", "/var/log"])
        let mounts = try ImageVolumeConfiguration.mounts(imagePaths: paths, requestPaths: [], explicit: [])
        #expect(mounts.count == 4)
        var names: Set<String> = []
        for mount in mounts {
            guard case .volume(let volume) = mount else {
                Issue.record("image declarations must allocate volumes")
                continue
            }
            #expect(volume.isAnonymous)
            #expect(paths.contains(volume.destination))
            #expect(names.insert(volume.name).inserted)
        }
        // Image inspect must encode empty objects, not arrays or null entries.
        let encoded = try JSONEncoder().encode(config.config?.Volumes)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: [String: String]])
        #expect(json["/var/log"] == [:])
    }

    @Test(
        "missing and null declarations do not allocate volumes",
        arguments: [
            #"{}"#, #"{"config":null}"#, #"{"config":{}}"#, #"{"config":{"Volumes":null}}"#,
        ])
    func missingDeclarations(json: String) throws {
        let config = try JSONDecoder().decode(ImageVolumeConfiguration.self, from: Data(json.utf8))
        #expect(config.config?.Volumes == nil)
        #expect(try ImageVolumeConfiguration.mounts(imagePaths: [], requestPaths: [], explicit: []).isEmpty)
    }

    @Test("bind, named volume and tmpfs mounts override the same normalized destination")
    func explicitOverrides() throws {
        let explicit: [VolumeOrFilesystem] = [
            .filesystem(.virtiofs(source: "/tmp/bind", destination: "/var/log/", options: [])),
            .volume(ParsedVolume(name: "data", destination: "/data")),
            .filesystem(.tmpfs(destination: "/cache", options: [])),
        ]
        let mounts = try ImageVolumeConfiguration.mounts(
            imagePaths: ["/var/log", "/data/.", "/cache"], requestPaths: ["/data"], explicit: explicit)
        #expect(mounts.isEmpty)
    }

    @Test("image and request declarations are unioned and duplicates allocate only once")
    func requestUnion() throws {
        let mounts = try ImageVolumeConfiguration.mounts(
            imagePaths: ["/data", "/data/", "/var/log"], requestPaths: ["/data", "/extra"], explicit: [])
        let paths = mounts.compactMap { item -> String? in
            if case .volume(let volume) = item { return volume.destination }
            return nil
        }
        #expect(paths == ["/data", "/extra", "/var/log"])
    }

    @Test("parent mounts do not suppress nested declarations")
    func nestedVolume() throws {
        let mounts = try ImageVolumeConfiguration.mounts(
            imagePaths: ["/var/log"], requestPaths: [],
            explicit: [.filesystem(.virtiofs(source: "/tmp/parent", destination: "/var", options: []))])
        #expect(mounts.count == 1)
    }

    @Test("invalid declarations fail before allocating storage", arguments: ["", "relative", "/", "/data/..", "/bad\0path"])
    func invalidDestination(path: String) {
        #expect(throws: (any Error).self) {
            try ImageVolumeConfiguration.mounts(imagePaths: [path], requestPaths: [], explicit: [])
        }
    }
}
