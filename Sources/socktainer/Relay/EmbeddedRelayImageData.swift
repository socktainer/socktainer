import CRelayImage
import Foundation

enum SocktainerRelayImage {
    static let reference = "socktainer-port-relay:embedded"
    static let artifactSHA256 = "706ea8e3b48885c643d359080f97df33b4f399b43bc68b4981c424fc481a7958"
    static let rootDigest = "sha256:883341a21539574c78c16fcfbcda14b1d7e25640be9ea2aa55ef841c51e147dc"

    static var archiveData: Data {
        Data(
            bytes: socktainer_relay_image_bytes(),
            count: Int(socktainer_relay_image_len())
        )
    }
}
