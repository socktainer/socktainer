import CRelayImage
import Foundation

enum SocktainerRelayImage {
    static let reference = "socktainer-port-relay:embedded"
    static let artifactSHA256 = "d0be9d3c58c182e2b6a2dea62f29fb693bb5eed868834b1b775038b83c0e29a2"
    static let rootDigest = "sha256:a1363bcc0d70bdd857bd26e88857c91d1fd89ded35ed18eab6c2123cacb78160"

    static var archiveData: Data {
        Data(
            bytes: socktainer_relay_image_bytes(),
            count: Int(socktainer_relay_image_len())
        )
    }
}
