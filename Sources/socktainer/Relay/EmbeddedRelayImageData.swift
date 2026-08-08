import CRelayImage
import Foundation

enum SocktainerRelayImage {
    static let reference = "socktainer-port-relay:embedded"
    static let artifactSHA256 = "fecfe7bc19b94c55dad79952bf5c648bf2415741c63318ec932852020bbcd910"

    static var archiveData: Data {
        Data(
            bytes: socktainer_relay_image_bytes(),
            count: Int(socktainer_relay_image_len())
        )
    }
}
