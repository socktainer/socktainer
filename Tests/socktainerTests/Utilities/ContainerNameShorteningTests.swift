import ContainerAPIClient
import Testing

@testable import socktainer

@Suite("Container name shortening")
struct ContainerNameShorteningTests {

    @Test("Short name is returned unchanged")
    func shortNamePassthrough() {
        let name = "my-container"
        #expect(ContainerNameUtility.sanitize(name) == name)
    }

    @Test("64-character name is returned unchanged")
    func exactly64CharPassthrough() {
        let name = "a" + String(repeating: "b", count: 63)
        #expect(name.count == 64)
        #expect(ContainerNameUtility.sanitize(name) == name)
    }

    @Test("65-character name is shortened to exactly 64 characters")
    func shortens65CharName() {
        let name = "a" + String(repeating: "b", count: 64)
        #expect(name.count == 65)
        let result = ContainerNameUtility.sanitize(name)
        #expect(result.count == 64)
    }

    @Test("Name longer than 100 characters is shortened to exactly 64 characters")
    func shortensVeryLongName() {
        let name = "act-Build-and-Test-on-Multiple-Platforms-build-ubuntu-latest-some-extra-suffix-here"
        #expect(name.count > 64)
        let result = ContainerNameUtility.sanitize(name)
        #expect(result.count == 64)
    }

    @Test("Shortening is deterministic")
    func deterministic() {
        let name = "act-" + String(repeating: "x", count: 70)
        #expect(ContainerNameUtility.sanitize(name) == ContainerNameUtility.sanitize(name))
    }

    @Test("Two different long names produce different short names")
    func collisionSafety() {
        let base = "act-Build-and-Test-on-Multiple-Platforms-build-ubuntu-latest-"
        let name1 = base + "job-alpha"
        let name2 = base + "job-beta"
        #expect(name1.count > 64)
        #expect(name2.count > 64)
        #expect(ContainerNameUtility.sanitize(name1) != ContainerNameUtility.sanitize(name2))
    }

    @Test("Shortened name passes validEntityName")
    func shortenedNamePassesValidation() throws {
        let name = "act-" + String(repeating: "valid-name-segment", count: 5)
        #expect(name.count > 64)
        let result = ContainerNameUtility.sanitize(name)
        try Utility.validEntityName(result)
    }

    @Test("Shortened name preserves readable prefix")
    func preservesPrefix() {
        let name = "act-my-workflow-job-name-" + String(repeating: "x", count: 50)
        let result = ContainerNameUtility.sanitize(name)
        #expect(result.hasPrefix("act-my-workflow-job-name-"))
    }
}
