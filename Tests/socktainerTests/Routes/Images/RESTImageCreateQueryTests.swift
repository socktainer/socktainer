import Testing
import Vapor

@testable import socktainer

/// Docker sends `--change` as repeated flat `changes=` query keys
/// (`?changes=CMD+x&changes=ENV+y`), never as a JSON array or bracketed form.
/// This proves Vapor's `URLEncodedFormDecoder` accumulates those into `[String]`
/// before `ImageCreateRoute` relies on it for real requests.
@Suite("RESTImageCreateQuery decoding")
struct RESTImageCreateQueryTests {

    @Test("repeated changes= query keys decode into an array, in order")
    func repeatedChangesKeysDecodeAsArray() throws {
        let query = "fromSrc=-&repo=myrepo&tag=latest&changes=CMD%20%2Fapp&changes=ENV%20FOO%3Dbar"
        let decoded = try URLEncodedFormDecoder().decode(RESTImageCreateQuery.self, from: query)

        #expect(decoded.fromSrc == "-")
        #expect(decoded.repo == "myrepo")
        #expect(decoded.tag == "latest")
        #expect(decoded.changes == ["CMD /app", "ENV FOO=bar"])
    }

    @Test("a single changes= query key decodes into a one-element array")
    func singleChangesKeyDecodesAsArray() throws {
        let query = "fromSrc=-&changes=CMD%20%2Fapp"
        let decoded = try URLEncodedFormDecoder().decode(RESTImageCreateQuery.self, from: query)

        #expect(decoded.changes == ["CMD /app"])
    }

    @Test("no changes= query key decodes to nil")
    func absentChangesKeyDecodesToNil() throws {
        let query = "fromSrc=-"
        let decoded = try URLEncodedFormDecoder().decode(RESTImageCreateQuery.self, from: query)

        #expect(decoded.changes == nil)
    }
}
