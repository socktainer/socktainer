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

/// Real podman (`pkg/bindings/images/build.go`) sends `dockerfile` JSON-array-encoded
/// (buildah supports multiple Containerfiles), e.g. `?dockerfile=["Dockerfile"]`. Using that
/// literal string as a filesystem path (instead of decoding it) breaks every real podman
/// build with a "Dockerfile does not exist at path: [...]" error.
@Suite("BuildRoute dockerfile query param parsing")
struct BuildDockerfileQueryParamTests {
    @Test("Plain path (Docker-compat clients) is returned as-is")
    func plainPath() throws {
        #expect(try BuildRoute.parseDockerfileQueryParam("Dockerfile") == "Dockerfile")
    }

    @Test("Real podman's JSON-array encoding resolves to its first element")
    func jsonArraySingleElement() throws {
        #expect(try BuildRoute.parseDockerfileQueryParam(#"["Dockerfile"]"#) == "Dockerfile")
    }

    @Test("Only the first element of a multi-Containerfile array is used")
    func jsonArrayMultipleElements() throws {
        #expect(try BuildRoute.parseDockerfileQueryParam(#"["Containerfile","Containerfile.other"]"#) == "Containerfile")
    }

    @Test("A successfully-decoded but empty array falls back to the default Dockerfile name, not the literal '[]'")
    func jsonArrayEmpty() throws {
        #expect(try BuildRoute.parseDockerfileQueryParam("[]") == "Dockerfile")
    }

    @Test("Malformed JSON starting with '[' is rejected rather than used verbatim as a literal path")
    func malformedJson() {
        #expect(throws: (any Error).self) {
            try BuildRoute.parseDockerfileQueryParam("[not valid json")
        }
    }

    @Test("An absolute dockerfile path is rejected with a client error, not silently substituted")
    func absolutePathIsRejected() {
        #expect(throws: (any Error).self) {
            try BuildRoute.parseDockerfileQueryParam("/etc/passwd")
        }
    }

    @Test("A dockerfile path containing '..' traversal is rejected with a client error")
    func traversalPathIsRejected() {
        #expect(throws: (any Error).self) {
            try BuildRoute.parseDockerfileQueryParam("../../etc/passwd")
        }
    }

    @Test("A JSON-array-encoded escaping path is also rejected")
    func jsonArrayEscapingPathIsRejected() {
        #expect(throws: (any Error).self) {
            try BuildRoute.parseDockerfileQueryParam(#"["/etc/passwd"]"#)
        }
    }

    @Test("An empty scalar dockerfile value falls back to the default Dockerfile name, matching an omitted param")
    func emptyScalarFallsBackToDefault() throws {
        #expect(try BuildRoute.parseDockerfileQueryParam("") == "Dockerfile")
    }

    @Test("A JSON array whose first element is empty is also rejected")
    func jsonArrayEmptyFirstElementIsRejected() {
        #expect(throws: (any Error).self) {
            try BuildRoute.parseDockerfileQueryParam(#"[""]"#)
        }
    }
}

/// Real podman sends `t=` (present, but an empty string) when no tag is given for a build —
/// treating that as a real tag (instead of "no tag given") would try to reference/tag the
/// image as the empty string.
@Suite("BuildRoute target image name resolution")
struct BuildTargetImageNameTests {
    @Test("A non-empty tag is used as given")
    func nonEmptyTag() {
        #expect(BuildRoute.resolvedTargetImageName("myimage:latest", fallback: "fallback") == "myimage:latest")
    }

    @Test("An empty-string tag (real podman's 'no tag given' form) falls back")
    func emptyStringTag() {
        #expect(BuildRoute.resolvedTargetImageName("", fallback: "fallback") == "fallback")
    }

    @Test("A nil tag falls back")
    func nilTag() {
        #expect(BuildRoute.resolvedTargetImageName(nil, fallback: "fallback") == "fallback")
    }
}

/// Real podman sends `--platform a,b` as the SAME query key repeated once per platform
/// (`platform=linux/arm64&platform=linux/amd64`), not one comma-joined value — decoding a
/// repeated key into a scalar field silently keeps only the last occurrence, dropping every
/// platform but one from a multi-platform build.
@Suite("Repeated query parameter recovery")
struct RepeatedQueryParamTests {
    @Test("A single occurrence is recovered")
    func singleValue() {
        #expect(allQueryValues(named: "platform", from: "platform=linux%2Farm64") == ["linux/arm64"])
    }

    @Test("Multiple occurrences of the same key are all recovered, in order")
    func multipleValues() {
        let query = "platform=linux%2Farm64&platform=linux%2Famd64"
        #expect(allQueryValues(named: "platform", from: query) == ["linux/arm64", "linux/amd64"])
    }

    @Test("Other query keys are ignored")
    func ignoresOtherKeys() {
        let query = "dockerfile=Dockerfile&platform=linux%2Farm64&t=myimage"
        #expect(allQueryValues(named: "platform", from: query) == ["linux/arm64"])
    }

    @Test("A nil or empty query string returns no values")
    func emptyQuery() {
        #expect(allQueryValues(named: "platform", from: nil) == [])
        #expect(allQueryValues(named: "platform", from: "") == [])
    }

    @Test("A query with no matching key returns no values")
    func noMatchingKey() {
        #expect(allQueryValues(named: "platform", from: "dockerfile=Dockerfile") == [])
    }
}
