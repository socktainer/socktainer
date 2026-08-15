import Foundation
import Testing

@testable import GlassDock

@Suite("Glass Dock directories")
struct GlassDockDirectoriesTests {
    @Test("host home uses the task-specific override without changing HOME")
    func hostHomeOverride() {
        let fallback = URL(fileURLWithPath: "/fallback", isDirectory: true)
        #expect(
            GlassDockDirectories.hostHome(
                environment: ["HOME": "/do-not-use", "GLASSDOCK_HOST_HOME_DIRECTORY": "/isolated"],
                fallback: fallback
            ).path == "/isolated"
        )
        #expect(GlassDockDirectories.hostHome(environment: [:], fallback: fallback) == fallback)
    }
}
