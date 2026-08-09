import Foundation
import Logging
import Testing
import Vapor

@testable import socktainer

/// GET /images/json must honor moby's `reference` and `dangling` filters.
/// `reference` matches repo tags in familiar form with path.Match globbing;
/// `dangling` selects images with no repo tags. Different keys AND together.
@Suite("ImageListRoute — reference and dangling filters")
struct ImageListFilterTests {

    // MARK: - dangling

    @Test("isDangling is true only for images with no repo tags")
    func danglingDetection() {
        #expect(ImageListFilter.isDangling(repoTags: []))
        #expect(ImageListFilter.isDangling(repoTags: ["<none>:<none>"]))
        #expect(!ImageListFilter.isDangling(repoTags: ["docker.io/library/alpine:latest"]))
    }

    // MARK: - reference familiar-form matching

    @Test("A bare name matches any tag of that repo, in familiar form")
    func bareNameMatchesFamiliar() {
        let tags = ["docker.io/library/alpine:latest"]
        #expect(ImageListFilter.referenceMatches(patterns: ["alpine"], repoTags: tags))
        #expect(ImageListFilter.referenceMatches(patterns: ["alpine:latest"], repoTags: tags))
    }

    @Test("A fully-qualified reference does not match (moby matches only familiar forms)")
    func fullyQualifiedDoesNotMatch() {
        let tags = ["docker.io/library/alpine:latest"]
        #expect(!ImageListFilter.referenceMatches(patterns: ["docker.io/library/alpine:latest"], repoTags: tags))
        #expect(!ImageListFilter.referenceMatches(patterns: ["docker.io/library/alpine"], repoTags: tags))
    }

    @Test("A user-namespaced image is matched by its familiar name")
    func userNamespaced() {
        let tags = ["docker.io/myuser/app:1"]
        #expect(ImageListFilter.referenceMatches(patterns: ["myuser/app"], repoTags: tags))
        #expect(ImageListFilter.referenceMatches(patterns: ["myuser/app:1"], repoTags: tags))
    }

    @Test("A tag glob matches only the intended tags")
    func tagGlob() {
        #expect(ImageListFilter.referenceMatches(patterns: ["alpine:3.*"], repoTags: ["docker.io/library/alpine:3.18"]))
        #expect(!ImageListFilter.referenceMatches(patterns: ["alpine:3.*"], repoTags: ["docker.io/library/alpine:latest"]))
    }

    @Test("A star does not cross the path separator, like path.Match")
    func starDoesNotCrossSlash() {
        // `*` matches a single-segment familiar name but not `user/app`.
        #expect(ImageListFilter.referenceMatches(patterns: ["*"], repoTags: ["docker.io/library/alpine:latest"]))
        #expect(!ImageListFilter.referenceMatches(patterns: ["*"], repoTags: ["docker.io/myuser/app:1"]))
        #expect(ImageListFilter.referenceMatches(patterns: ["*/*"], repoTags: ["docker.io/myuser/app:1"]))
    }

    @Test("A digest-pinned reference still matches by its familiar name")
    func digestPinnedMatchesByName() {
        let tags = ["docker.io/library/alpine@sha256:abc123"]
        #expect(ImageListFilter.referenceMatches(patterns: ["alpine"], repoTags: tags))
    }

    @Test("A non-matching reference excludes the image")
    func nonMatch() {
        #expect(!ImageListFilter.referenceMatches(patterns: ["nginx"], repoTags: ["docker.io/library/alpine:latest"]))
        #expect(!ImageListFilter.referenceMatches(patterns: ["alpine"], repoTags: []))
    }

    @Test("Multiple reference patterns OR together")
    func multipleReferencesOr() {
        let tags = ["docker.io/library/redis:7"]
        #expect(ImageListFilter.referenceMatches(patterns: ["nginx", "redis"], repoTags: tags))
    }

    // MARK: - applyFilters composition

    @Test("dangling=true keeps only untagged images", arguments: ["true", "1"])
    func applyDangling(value: String) throws {
        let tagged = Self.summary(repoTags: ["docker.io/library/alpine:latest"])
        let untagged = Self.summary(repoTags: [])
        let kept = try ImageListRoute.applyFilters([tagged, untagged], filters: ["dangling": [value]])
        #expect(kept.map(\.RepoTags) == [[]])
    }

    @Test("dangling=false keeps only tagged images", arguments: ["false", "0"])
    func applyDanglingFalse(value: String) throws {
        let tagged = Self.summary(repoTags: ["docker.io/library/alpine:latest"])
        let untagged = Self.summary(repoTags: [])
        let kept = try ImageListRoute.applyFilters([tagged, untagged], filters: ["dangling": [value]])
        #expect(kept.map(\.RepoTags) == [["docker.io/library/alpine:latest"]])
    }

    @Test("An unrecognized or conflicting dangling value is a 400, like moby's GetBoolOrDefault")
    func applyDanglingInvalid() {
        let images = [Self.summary(repoTags: [])]
        for values in [["maybe"], ["true", "false"]] {
            #expect(throws: Abort.self) {
                try ImageListRoute.applyFilters(images, filters: ["dangling": values])
            }
        }
    }

    @Test("reference filters to matching images")
    func applyReference() throws {
        let alpine = Self.summary(repoTags: ["docker.io/library/alpine:latest"])
        let redis = Self.summary(repoTags: ["docker.io/library/redis:7"])
        let kept = try ImageListRoute.applyFilters([alpine, redis], filters: ["reference": ["alpine"]])
        #expect(kept.map(\.RepoTags) == [["docker.io/library/alpine:latest"]])
    }

    @Test("A present reference key with no values matches nothing, unlike an absent key")
    func applyReferenceEmptyMatchesNothing() throws {
        // {"reference":{}} and an all-false map both parse to an empty patterns
        // array, which must still be a real (if impossible-to-satisfy) filter —
        // verified live: real Docker returns no images for both.
        let alpine = Self.summary(repoTags: ["docker.io/library/alpine:latest"])
        let kept = try ImageListRoute.applyFilters([alpine], filters: ["reference": []])
        #expect(kept.isEmpty)
    }

    @Test("A boolean-map reference filter with false-only or mixed entries keeps only the true ones")
    func parseBooleanMapFalseAndMixedEntries() throws {
        let logger = Logger(label: "test")
        let falseOnly = try DockerImageFilterUtility.parseImageListFilters(
            filterParam: #"{"reference": {"alpine": false}}"#, logger: logger)
        #expect(falseOnly == ["reference": []], "an all-false map registers the key with zero values, not no filter")

        let mixed = try DockerImageFilterUtility.parseImageListFilters(
            filterParam: #"{"reference": {"alpine": true, "old": false}}"#, logger: logger)
        #expect(mixed == ["reference": ["alpine"]], "only the true-valued key survives")
    }

    @Test("reference and dangling AND together")
    func referenceAndDanglingAnd() throws {
        let alpine = Self.summary(repoTags: ["docker.io/library/alpine:latest"])
        let untagged = Self.summary(repoTags: [])
        // dangling=true excludes alpine, and reference=alpine excludes the untagged one → empty.
        let kept = try ImageListRoute.applyFilters([alpine, untagged], filters: ["dangling": ["true"], "reference": ["alpine"]])
        #expect(kept.isEmpty)
    }

    @Test("No filters returns everything unchanged")
    func noFilters() throws {
        let a = Self.summary(repoTags: ["docker.io/library/alpine:latest"])
        let b = Self.summary(repoTags: [])
        #expect(try ImageListRoute.applyFilters([a, b], filters: [:]).count == 2)
    }

    // MARK: - filters query parsing

    @Test("The three JSON filter shapes docker clients send all normalize to [key: [value]]")
    func parseFilterShapes() throws {
        let logger = Logger(label: "test")
        for shape in [#"{"reference": {"alpine:*": true}}"#, #"{"reference": ["alpine:*"]}"#, #"{"reference": "alpine:*"}"#] {
            let parsed = try DockerImageFilterUtility.parseImageListFilters(filterParam: shape, logger: logger)
            #expect(parsed == ["reference": ["alpine:*"]])
        }
    }

    @Test("An unknown filter key is a 400, like moby's filters.Validate")
    func parseUnknownKeyIs400() {
        let error = #expect(throws: Abort.self) {
            try DockerImageFilterUtility.parseImageListFilters(filterParam: #"{"bogus": ["x"]}"#, logger: Logger(label: "test"))
        }
        #expect(error?.status == .badRequest)
        #expect(error?.reason == "invalid filter 'bogus'")
    }

    @Test(
        "Malformed JSON, a non-object top level, and an unsupported value shape are all a 400, like real Docker",
        arguments: [
            "not-json",
            "[]",
            #"{"reference": 1}"#,
            #"{"reference": {"alpine": "yes"}}"#,
            #"{"reference": {"alpine": 1}}"#,
            #"{"reference": [1, 2]}"#,
        ])
    func parseInvalidShapeIs400(filterParam: String) {
        let error = #expect(throws: Abort.self) {
            try DockerImageFilterUtility.parseImageListFilters(filterParam: filterParam, logger: Logger(label: "test"))
        }
        #expect(error?.status == .badRequest, "filterParam: \(filterParam)")
    }

    @Test("An absent or empty filters param means no filter, not an error")
    func parseAbsentOrEmptyIsNoFilter() throws {
        let logger = Logger(label: "test")
        #expect(try DockerImageFilterUtility.parseImageListFilters(filterParam: nil, logger: logger).isEmpty)
        #expect(try DockerImageFilterUtility.parseImageListFilters(filterParam: "", logger: logger).isEmpty)
    }

    @Test("isJSONBool tells a real JSON boolean apart from a bridged NSNumber")
    func isJSONBoolDistinguishesFromNumber() throws {
        let data = #"{"a": true, "b": false, "c": 1, "d": 0, "e": "x"}"#.data(using: .utf8)!
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Expected a JSON object")
            return
        }
        #expect(DockerImageFilterUtility.isJSONBool(json["a"]!))
        #expect(DockerImageFilterUtility.isJSONBool(json["b"]!))
        #expect(!DockerImageFilterUtility.isJSONBool(json["c"]!), "a JSON 1 must not bridge to true")
        #expect(!DockerImageFilterUtility.isJSONBool(json["d"]!), "a JSON 0 must not bridge to false")
        #expect(!DockerImageFilterUtility.isJSONBool(json["e"]!))
    }

    // MARK: - Helpers

    private static func summary(repoTags: [String]) -> RESTImageSummary {
        RESTImageSummary(
            Id: "sha256:\(repoTags.first ?? "none")",
            ParentId: "",
            RepoTags: repoTags,
            RepoDigests: [],
            Created: 0,
            Size: 0,
            SharedSize: -1,
            Labels: [:],
            Containers: 0,
            Manifests: nil,
            Descriptor: nil)
    }
}
