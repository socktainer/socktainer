import ContainerizationError
import Foundation
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

    @Test("podman's JSON array of key=value strings is accepted too")
    func podmanLabelArray() {
        #expect(BuildRoute.parseBuildQueryParam(#"["a=1","b=2"]"#) == ["a=1", "b=2"])
        #expect(BuildRoute.parseBuildQueryParam("[]").isEmpty)
        #expect(BuildRoute.parseBuildQueryParam("not json").isEmpty)
    }

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

/// Regression tests for issue #386: a failed `RUN` step surfaced to the client as a
/// generic "The operation couldn't be completed. (GRPCCore.RPCError error 1.)"
/// instead of the real failure — because `.localizedDescription` on a plain
/// Swift-native error (BuildKit's own `RPCError` isn't `LocalizedError`/`NSError`)
/// falls back to that templated string, discarding whatever the error's own
/// `description` actually says. Also covers the follow-up gap in the first fix: a
/// type that conforms *only* to `LocalizedError` (not `CustomStringConvertible`)
/// interpolates to a bare, useless default instead of its `errorDescription`.
@Suite("BuildRoute.errorMessage")
struct BuildRouteErrorMessageTests {

    /// A type conforming only to `LocalizedError` — no `CustomStringConvertible` —
    /// mirroring any error that carries its message solely through `errorDescription`.
    private struct FakeLocalizedOnlyError: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Mirrors the exact shape of the real bug: a custom, non-`LocalizedError`
    /// Swift error (like `GRPCCore.RPCError`) whose own `description` carries the
    /// real reason, but whose `.localizedDescription` would fall back to Foundation's
    /// generic "The operation couldn't be completed. (Type error N.)" template.
    private struct FakeRPCLikeError: Error, CustomStringConvertible {
        let message: String
        var description: String { "RPCError(message: \"\(message)\")" }
    }

    @Test("preserves the real message from a custom (non-LocalizedError) error's description")
    func preservesCustomErrorDescription() {
        let error = FakeRPCLikeError(message: "process \"/bin/sh -c false\" did not complete successfully: exit code: 1")
        let result = BuildRoute.errorMessage(for: error)
        #expect(result.contains("did not complete successfully"))
        #expect(result.contains("exit code: 1"))
    }

    @Test("does not fall back to the generic Foundation template .localizedDescription would produce")
    func doesNotProduceGenericFallback() {
        let error = FakeRPCLikeError(message: "boom")
        let result = BuildRoute.errorMessage(for: error)
        // The exact failure mode from #386: .localizedDescription on a plain custom
        // error produces this templated string regardless of what actually failed.
        #expect(!result.contains("couldn't be completed"))
        #expect(result != error.localizedDescription)
    }

    @Test("still surfaces a ContainerizationError's message, matching prior behavior")
    func stillHandlesContainerizationError() {
        let error = ContainerizationError(.invalidArgument, message: "Dockerfile does not exist at path: /tmp/missing/Dockerfile")
        let result = BuildRoute.errorMessage(for: error)
        #expect(result.contains("Dockerfile does not exist at path"))
        // ContainerizationError conforms to both CustomStringConvertible and
        // LocalizedError; its .description includes the error code, its
        // .errorDescription does not. Must still prefer .description (interpolation),
        // not silently lose the code by checking LocalizedError first.
        #expect(result.contains("invalidArgument"))
    }

    @Test("falls back to errorDescription for a type that is LocalizedError but not CustomStringConvertible")
    func fallsBackToErrorDescriptionWhenNotCustomStringConvertible() {
        let error = FakeLocalizedOnlyError(reason: "real message")
        let result = BuildRoute.errorMessage(for: error)
        // Plain interpolation on this type would produce its bare Mirror-based
        // default (e.g. "FakeLocalizedOnlyError(reason: \"real message\")" only by
        // accident of having a single stored property named the same as the message —
        // the point is it must be exactly the errorDescription, not whatever Swift's
        // default description happens to contain).
        #expect(result == "real message")
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
    func malformedJson() throws {
        do {
            _ = try BuildRoute.parseDockerfileQueryParam("[not valid json")
            Issue.record("expected parseDockerfileQueryParam to throw")
        } catch let abort as Abort {
            #expect(abort.status == .badRequest)
        }
    }

    @Test("An absolute dockerfile path is rejected with a client error, not silently substituted")
    func absolutePathIsRejected() throws {
        do {
            _ = try BuildRoute.parseDockerfileQueryParam("/etc/passwd")
            Issue.record("expected parseDockerfileQueryParam to throw")
        } catch let abort as Abort {
            #expect(abort.status == .badRequest)
        }
    }

    @Test("A dockerfile path containing '..' traversal is rejected with a client error")
    func traversalPathIsRejected() throws {
        do {
            _ = try BuildRoute.parseDockerfileQueryParam("../../etc/passwd")
            Issue.record("expected parseDockerfileQueryParam to throw")
        } catch let abort as Abort {
            #expect(abort.status == .badRequest)
        }
    }

    @Test("A JSON-array-encoded escaping path is also rejected")
    func jsonArrayEscapingPathIsRejected() throws {
        do {
            _ = try BuildRoute.parseDockerfileQueryParam(#"["/etc/passwd"]"#)
            Issue.record("expected parseDockerfileQueryParam to throw")
        } catch let abort as Abort {
            #expect(abort.status == .badRequest)
        }
    }

    @Test("An empty scalar dockerfile value falls back to the default Dockerfile name, matching an omitted param")
    func emptyScalarFallsBackToDefault() throws {
        #expect(try BuildRoute.parseDockerfileQueryParam("") == "Dockerfile")
    }

    @Test("A JSON array whose first element is empty is also rejected")
    func jsonArrayEmptyFirstElementIsRejected() throws {
        do {
            _ = try BuildRoute.parseDockerfileQueryParam(#"[""]"#)
            Issue.record("expected parseDockerfileQueryParam to throw")
        } catch let abort as Abort {
            #expect(abort.status == .badRequest)
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
        #expect(BuildRoute.resolvedTargetImageName("myimage:latest") == "myimage:latest")
    }

    @Test("An empty-string tag (real podman's 'no tag given' form) is untagged")
    func emptyStringTag() {
        #expect(BuildRoute.resolvedTargetImageName("") == nil)
    }

    @Test("A nil tag is untagged")
    func nilTag() {
        #expect(BuildRoute.resolvedTargetImageName(nil) == nil)
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

    @Test("A '+' in a value decodes to a space, matching Vapor's own form-encoded query decoding")
    func plusDecodesToSpace() {
        #expect(allQueryValues(named: "message", from: "message=hello+world") == ["hello world"])
    }

    @Test("A malformed percent escape is used as-is instead of trapping")
    func malformedPercentEscapeIsUsedAsIs() {
        #expect(allQueryValues(named: "platform", from: "platform=%ZZ") == ["%ZZ"])
    }

    @Test("A matching key with no '=' returns an empty string, not nil or dropped")
    func keyWithNoEqualsReturnsEmptyString() {
        #expect(allQueryValues(named: "amend", from: "amend") == [""])
    }
}
