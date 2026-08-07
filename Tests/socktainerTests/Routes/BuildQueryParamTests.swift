import ContainerizationOCI
import Testing
import Vapor

@testable import socktainer

/// The Docker Engine API sends `buildargs` and `labels` as JSON-encoded
/// dictionaries in the query string, e.g.:
///   ?buildargs={"FOO":"bar","BAZ":"qux"}
///   ?labels={"com.example.team":"platform"}
///
/// BuildKit expects them as ["KEY=VALUE", ...] strings.
/// The old code did `string.split(separator: ",")` which breaks on any JSON
/// with multiple keys — the comma inside the JSON object is not a delimiter.
@Suite("BuildRoute query param parsing")
struct BuildQueryParamTests {

    // MARK: - buildargs

    @Test("Single build arg is parsed correctly")
    func singleBuildArg() {
        let result = BuildRoute.parseBuildQueryParam(#"{"FOO":"bar"}"#)
        #expect(result == ["FOO=bar"])
    }

    @Test("Multiple build args produce KEY=VALUE entries, not a broken comma-split")
    func multipleBuildArgs() {
        // Old comma-split would produce: ["{\"FOO\":\"bar\"", "\"BAZ\":\"qux\"}"]
        // Correct result: ["FOO=bar", "BAZ=qux"]
        let result = BuildRoute.parseBuildQueryParam(#"{"FOO":"bar","BAZ":"qux"}"#)
        #expect(result.count == 2)
        #expect(result.contains("FOO=bar"))
        #expect(result.contains("BAZ=qux"))
    }

    @Test("Build arg value containing a comma is preserved intact")
    func buildArgValueWithComma() {
        // A value like "a,b" would be destroyed by comma-splitting
        let result = BuildRoute.parseBuildQueryParam(#"{"LIST":"a,b,c"}"#)
        #expect(result == ["LIST=a,b,c"])
    }

    @Test("Nil input returns empty array")
    func nilInput() {
        let result = BuildRoute.parseBuildQueryParam(nil)
        #expect(result == [])
    }

    @Test("Empty JSON object returns empty array")
    func emptyObject() {
        let result = BuildRoute.parseBuildQueryParam("{}")
        #expect(result == [])
    }

    @Test("Invalid JSON returns empty array (graceful degradation)")
    func invalidJson() {
        let result = BuildRoute.parseBuildQueryParam("not-json")
        #expect(result == [])
    }

    @Test("Malformed platform is a Docker bad request, not a process trap")
    func malformedPlatformIsRejected() {
        do {
            _ = try BuildRoute.parseBuildPlatforms("linux/not-a-real-arch/extra/bits")
            Issue.record("expected invalid platform rejection")
        } catch let abort as Abort {
            #expect(abort.status == .badRequest)
            #expect(
                abort.reason
                    == "invalid platform: linux/not-a-real-arch/extra/bits"
            )
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("Empty platform selects the native Linux architecture")
    func emptyPlatformUsesNativeLinux() throws {
        let platforms = try BuildRoute.parseBuildPlatforms("")
        #expect(platforms.count == 1)
        #expect(platforms.first?.os == "linux")
        #expect(platforms.first?.architecture == Platform.current.architecture)
    }

    @Test("classic build reports the identity captured by its load")
    func classicBuildUsesAtomicLoadIdentity() {
        let imported = "sha256:" + String(repeating: "a", count: 64)
        let later = "sha256:" + String(repeating: "b", count: 64)
        let reference = "docker.io/library/example:latest"

        #expect(
            BuildRoute.builtImageID(
                loadedReferences: [reference],
                capturedActorIDs: [imported],
                identities: [reference: later],
                fallback: reference
            ) == imported
        )
    }
}
