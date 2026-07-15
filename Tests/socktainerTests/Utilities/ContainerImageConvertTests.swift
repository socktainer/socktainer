import CryptoKit
import Foundation
import Logging
import Testing

@testable import socktainer

@Suite("convertDockerTarToOCI — digest integrity")
struct ContainerImageConvertTests {

    @Test("a config whose content does not match its claimed filename digest is referenced by its real digest")
    func configDigestMismatchIsReferencedByRealDigest() async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }

        let realConfigDigest = try fixture.writeConfigWithClaimedDigest(String(repeating: "a", count: 64))
        let layerDigest = try fixture.writeLayer()
        try fixture.writeManifest(configDigest: String(repeating: "a", count: 64), layerDigest: layerDigest, tag: "crafted:latest")

        _ = try await ContainerImageUtility.convertDockerTarToOCI(
            dockerFormatPath: fixture.dockerFormatDir, ociLayoutPath: fixture.ociLayoutDir, logger: Logger(label: "test"))

        let configDigest = try fixture.onlyManifest().config.digest
        #expect(configDigest == "sha256:\(realConfigDigest)")
        #expect(fixture.blobExists(configDigest))
    }

    @Test("a layer whose content does not match its claimed digest is referenced by its real digest")
    func layerDigestMismatchIsReferencedByRealDigest() async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }

        _ = try fixture.writeConfigWithClaimedDigest(String(repeating: "a", count: 64))
        let realLayerDigest = try fixture.writeLayerWithClaimedDigest(String(repeating: "b", count: 64))
        try fixture.writeManifest(configDigest: String(repeating: "a", count: 64), layerDigest: String(repeating: "b", count: 64), tag: "crafted:latest")

        _ = try await ContainerImageUtility.convertDockerTarToOCI(
            dockerFormatPath: fixture.dockerFormatDir, ociLayoutPath: fixture.ociLayoutDir, logger: Logger(label: "test"))

        let layerDigest = try fixture.onlyManifest().layers[0].digest
        #expect(layerDigest == "sha256:\(realLayerDigest)")
        #expect(fixture.blobExists(layerDigest))
    }

    @Test("two tags sharing a config with a mismatched digest both resolve to the real digest without failing")
    func sharedMismatchedConfigDedupes() async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }

        let claimed = String(repeating: "a", count: 64)
        let realConfigDigest = try fixture.writeConfigWithClaimedDigest(claimed)
        let layerDigest = try fixture.writeLayer()
        try fixture.writeManifests([
            (config: claimed, layer: layerDigest, tag: "one:latest"),
            (config: claimed, layer: layerDigest, tag: "two:latest"),
        ])

        _ = try await ContainerImageUtility.convertDockerTarToOCI(
            dockerFormatPath: fixture.dockerFormatDir, ociLayoutPath: fixture.ociLayoutDir, logger: Logger(label: "test"))

        let configDigests = try fixture.allManifests().map(\.config.digest)
        #expect(configDigests == ["sha256:\(realConfigDigest)", "sha256:\(realConfigDigest)"])
        #expect(fixture.blobExists("sha256:\(realConfigDigest)"))
        #expect(!fixture.blobExists("sha256:\(claimed)"))
    }

    @Test("a tag whose config file is missing from the archive is not reported as loaded")
    func missingConfigTagIsNotReported() async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }

        let layerDigest = try fixture.writeLayer()
        try fixture.writeManifest(configDigest: String(repeating: "c", count: 64), layerDigest: layerDigest, tag: "phantom:latest")

        let loaded = try await ContainerImageUtility.convertDockerTarToOCI(
            dockerFormatPath: fixture.dockerFormatDir, ociLayoutPath: fixture.ociLayoutDir, logger: Logger(label: "test"))

        #expect(loaded.isEmpty)
        #expect(try fixture.allManifests().isEmpty)
    }

    @Test("an entry with a missing config does not suppress reporting of the valid entries")
    func missingConfigOnlySkipsItsOwnTag() async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }

        let configDigest = try fixture.writeConfig()
        let layerDigest = try fixture.writeLayer()
        try fixture.writeManifests([
            (config: configDigest, layer: layerDigest, tag: "kept:latest"),
            (config: String(repeating: "c", count: 64), layer: layerDigest, tag: "phantom:latest"),
        ])

        let loaded = try await ContainerImageUtility.convertDockerTarToOCI(
            dockerFormatPath: fixture.dockerFormatDir, ociLayoutPath: fixture.ociLayoutDir, logger: Logger(label: "test"))

        #expect(loaded == ["kept:latest"])
        #expect(try fixture.allManifests().count == 1)
    }

    @Test("a layer larger than the streaming-hash chunk is hashed correctly across chunk boundaries")
    func largeLayerHashesAcrossChunks() async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }

        let configDigest = try fixture.writeConfig()
        let content = Data(repeating: 0xAB, count: 2_500_000)
        let layerDigest = try fixture.writeLayer(content: content)
        try fixture.writeManifest(configDigest: configDigest, layerDigest: layerDigest, tag: "big:latest")

        _ = try await ContainerImageUtility.convertDockerTarToOCI(
            dockerFormatPath: fixture.dockerFormatDir, ociLayoutPath: fixture.ociLayoutDir, logger: Logger(label: "test"))

        let layer = try fixture.onlyManifest().layers[0]
        #expect(layer.digest == "sha256:\(content.sha256Hex())")
        #expect(layer.size == content.count)
    }
}

private struct DockerArchiveFixture {
    let root: URL
    let dockerFormatDir: URL
    let ociLayoutDir: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("docker-archive-\(UUID().uuidString)")
        dockerFormatDir = root.appendingPathComponent("docker-format")
        ociLayoutDir = root.appendingPathComponent("oci-layout")
        try FileManager.default.createDirectory(at: dockerFormatDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ociLayoutDir, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private var configContent: Data { Data(#"{"architecture":"arm64","os":"linux","rootfs":{"type":"layers","diff_ids":[]}}"#.utf8) }

    func writeConfig() throws -> String {
        let digest = configContent.sha256Hex()
        try configContent.write(to: dockerFormatDir.appendingPathComponent("\(digest).json"))
        return digest
    }

    func writeConfigWithClaimedDigest(_ claimed: String) throws -> String {
        try configContent.write(to: dockerFormatDir.appendingPathComponent("\(claimed).json"))
        return configContent.sha256Hex()
    }

    func writeLayer(content: Data = Data("layer bytes".utf8)) throws -> String {
        let digest = content.sha256Hex()
        try writeLayerContent(content, under: digest)
        return digest
    }

    func writeLayerWithClaimedDigest(_ claimed: String) throws -> String {
        let content = Data("layer bytes".utf8)
        try writeLayerContent(content, under: claimed)
        return content.sha256Hex()
    }

    private func writeLayerContent(_ content: Data, under digest: String) throws {
        let layerDir = dockerFormatDir.appendingPathComponent(digest)
        try FileManager.default.createDirectory(at: layerDir, withIntermediateDirectories: true)
        try content.write(to: layerDir.appendingPathComponent("layer.tar"))
    }

    func writeManifest(configDigest: String, layerDigest: String, tag: String) throws {
        try writeManifests([(config: configDigest, layer: layerDigest, tag: tag)])
    }

    func writeManifests(_ entries: [(config: String, layer: String, tag: String)]) throws {
        let objects = entries.map {
            #"{"Config":"\#($0.config).json","RepoTags":["\#($0.tag)"],"Layers":["\#($0.layer)/layer.tar"]}"#
        }
        let manifest = "[\(objects.joined(separator: ","))]"
        try Data(manifest.utf8).write(to: dockerFormatDir.appendingPathComponent("manifest.json"))
    }

    func onlyManifest() throws -> OCILayoutManifest {
        try allManifests()[0]
    }

    func allManifests() throws -> [OCILayoutManifest] {
        let index = try JSONDecoder().decode(OCILayoutIndex.self, from: Data(contentsOf: ociLayoutDir.appendingPathComponent("index.json")))
        return try index.manifests.map {
            let manifestDigest = $0.digest.replacingOccurrences(of: "sha256:", with: "")
            return try JSONDecoder().decode(OCILayoutManifest.self, from: Data(contentsOf: blobURL(manifestDigest)))
        }
    }

    func blobExists(_ digest: String) -> Bool {
        FileManager.default.fileExists(atPath: blobURL(digest.replacingOccurrences(of: "sha256:", with: "")).path)
    }

    private func blobURL(_ hex: String) -> URL {
        ociLayoutDir.appendingPathComponent("blobs/sha256/\(hex)")
    }
}
