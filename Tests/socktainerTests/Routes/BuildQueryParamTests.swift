import Testing

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
}
