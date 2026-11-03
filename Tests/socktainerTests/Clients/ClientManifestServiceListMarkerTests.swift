import ContainerizationError
import ContainerizationOCI
import Foundation
import Testing

@testable import socktainer

/// Apple's image store roots ordinary single-platform images at an OCI index too, so
/// `exists(name:)` can't use the root media type to tell a manifest list from a plain image —
/// it reads the marker `writeIndexAndTag` puts on every list it writes.
@Suite("ClientManifestService manifest-list marker")
struct ClientManifestServiceListMarkerTests {
    private let member = Descriptor(
        mediaType: MediaTypes.imageManifest, digest: "sha256:\(String(repeating: "a", count: 64))", size: 100)

    @Test("an index written by the manifest service is a manifest list, also after a JSON round trip")
    func writtenIndexIsManifestList() throws {
        let index = ClientManifestService.manifestListIndex(manifests: [member])
        #expect(ClientManifestService.isManifestList(index))

        let decoded = try JSONDecoder().decode(Index.self, from: JSONEncoder().encode(index))
        #expect(ClientManifestService.isManifestList(decoded))
        #expect(decoded.manifests.map(\.digest) == [member.digest])
    }

    @Test("an empty list from 'manifest create' with no images is still a manifest list")
    func emptyWrittenIndexIsManifestList() {
        #expect(ClientManifestService.isManifestList(ClientManifestService.manifestListIndex(manifests: [])))
    }

    @Test("an ordinary image's index is not a manifest list")
    func ordinaryImageIndexIsNotManifestList() {
        #expect(!ClientManifestService.isManifestList(Index(manifests: [member])))
        #expect(!ClientManifestService.isManifestList(Index(manifests: [member], annotations: ["org.opencontainers.image.ref.name": "latest"])))
        #expect(!ClientManifestService.isManifestList(Index(manifests: [member], annotations: [ClientManifestService.manifestListAnnotation: "false"])))
    }

    @Test("write paths get a manifest list's members")
    func manifestListMembersOfList() throws {
        let index = ClientManifestService.manifestListIndex(manifests: [member])
        #expect(try ClientManifestService.manifestListMembers(of: index, name: "mylist").map(\.digest) == [member.digest])
    }

    @Test("write paths refuse an ordinary image instead of turning it into a manifest list")
    func manifestListMembersRejectsOrdinaryImage() {
        let error = #expect(throws: ContainerizationError.self) {
            try ClientManifestService.manifestListMembers(of: Index(manifests: [member]), name: "alpine:latest")
        }
        #expect(error?.code == .invalidArgument)
        #expect(error?.message.contains("not a manifest list") == true)
    }
}
