import ContainerizationOCI
import Foundation
import Testing

@testable import socktainer

@Suite("Apple container resolvers digest validation")
struct AppleContainerResolverDigestTests {
    static let root = URL(fileURLWithPath: "/nonexistent")
    static let bad = "sha256:../../etc"

    @Test("malformed digests yield no data instead of a path")
    func rejectsMalformedDigest() {
        let descriptor = Descriptor(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: Self.bad, size: 0)
        #expect(AppleContainerSnapshotResolver.unpackedSize(appSupportURL: Self.root, descriptor: descriptor) == 0)
        #expect(AppleContainerImageStoreResolver.graphDriver(appSupportURL: Self.root, descriptor: descriptor) == nil)
        #expect(AppleContainerImageStoreResolver.descriptorExtras(appSupportURL: Self.root, parentDigest: Self.bad, childDigest: Self.bad) == nil)
    }
}
