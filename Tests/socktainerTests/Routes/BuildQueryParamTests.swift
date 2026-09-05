import ContainerizationError
import Foundation
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
