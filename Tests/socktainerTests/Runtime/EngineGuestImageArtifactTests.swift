import Foundation
import Testing

@testable import socktainer

@Suite("Engine guest image discovery")
struct EngineGuestImageArtifactTests {
    @Test("uses an explicit guest image")
    func explicitArtifact() throws {
        let artifact = try EngineGuestImageArtifact.locate(environment: [
            "SOCKTAINER_GUEST_IMAGE": #filePath
        ])
        #expect(artifact.url.path == #filePath)
    }

    @Test("reports every attempted path")
    func missingArtifact() {
        let missing = "/definitely/missing/socktainer-guest.oci.tar"
        do {
            _ = try EngineGuestImageArtifact.locate(environment: ["SOCKTAINER_GUEST_IMAGE": missing])
        } catch let error as EngineMachineProvisioningError {
            guard case .guestImageNotFound(let paths) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(paths.contains(missing))
        } catch {
            Issue.record(error)
        }
    }
}
