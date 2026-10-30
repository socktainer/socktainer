import Testing

@testable import socktainer

@Suite("LibpodSupport")
struct LibpodSupportTests {
    @Test("enabled by default")
    func enabledByDefault() {
        #expect(LibpodSupport.isEnabled(environment: [:]))
    }

    @Test("truthy SOCKTAINER_DISABLE_LIBPOD values disable libpod", arguments: ["1", "true", "TRUE", "yes", "on", " 1 "])
    func truthyDisables(value: String) {
        #expect(!LibpodSupport.isEnabled(environment: [LibpodSupport.disableEnvironmentVariable: value]))
    }

    @Test("falsy or unrecognized values leave libpod enabled", arguments: ["0", "false", "no", "off", "", "maybe"])
    func falsyKeepsEnabled(value: String) {
        #expect(LibpodSupport.isEnabled(environment: [LibpodSupport.disableEnvironmentVariable: value]))
    }
}
