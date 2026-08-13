import Foundation
import Testing

@testable import socktainer

@Suite("Socktainer directories")
struct SocktainerDirectoriesTests {
    @Test("host home uses the task-specific override without changing HOME")
    func hostHomeOverride() {
        let fallback = URL(fileURLWithPath: "/fallback", isDirectory: true)
        #expect(
            SocktainerDirectories.hostHome(
                environment: ["HOME": "/do-not-use", "SOCKTAINER_HOST_HOME_DIRECTORY": "/isolated"],
                fallback: fallback
            ).path == "/isolated"
        )
        #expect(SocktainerDirectories.hostHome(environment: [:], fallback: fallback) == fallback)
    }
}
