import Testing

@testable import socktainer

@Suite("Docker Engine API version build info")
struct BuildInfoApiVersionTests {

    @Test("min API version is a valid Docker version string even without Makefile env vars")
    func minApiVersionIsAlwaysValid() {
        #expect(getDockerEngineApiMinVersion().wholeMatch(of: /v\d+\.\d+/) != nil)
    }

    @Test("max API version is a valid Docker version string even without Makefile env vars")
    func maxApiVersionIsAlwaysValid() {
        #expect(getDockerEngineApiMaxVersion().wholeMatch(of: /v\d+\.\d+/) != nil)
    }
}
