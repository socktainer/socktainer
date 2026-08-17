import Testing
import Vapor

@testable import socktainer

/// GET /system/df must reject an unknown `type` value with a 400, matching
/// moby's getDiskUsage (its type switch returns invalidRequestError for
/// anything other than container/image/volume/build-cache). The previous
/// implementation silently ignored unknown types and returned an all-null
/// document with 200.
@Suite("SystemDFRoute — type validation")
struct SystemDFTypeValidationTests {

    @Test("Valid types and an empty set pass validation")
    func validTypesPass() throws {
        try SystemDFRoute.validateTypes([])
        try SystemDFRoute.validateTypes(["image"])
        try SystemDFRoute.validateTypes(["container", "image", "volume", "build-cache"])
    }

    @Test("An unknown type throws a 400 naming the offending value")
    func unknownTypeThrows() {
        let error = #expect(throws: Abort.self) {
            try SystemDFRoute.validateTypes(["bogus"])
        }
        #expect(error?.status == .badRequest)
        #expect(error?.reason.contains("unknown object type: bogus") == true)
    }

    @Test("A mix of valid and invalid types still rejects")
    func mixedTypesReject() {
        #expect(throws: Abort.self) {
            try SystemDFRoute.validateTypes(["image", "nope"])
        }
    }

    @Test("With several unknown types, the first in query order is reported (like moby)")
    func firstUnknownInQueryOrderReported() {
        // Verified live against real Docker: `type=zzz&type=aaa` reports `zzz`,
        // i.e. the first unknown as iterated, not the alphabetically-first one.
        let error = #expect(throws: Abort.self) {
            try SystemDFRoute.validateTypes(["zzz", "aaa"])
        }
        #expect(error?.reason == "unknown object type: zzz")
    }

    @Test("A valid type before an unknown one still reports the unknown")
    func unknownAfterValidReported() {
        let error = #expect(throws: Abort.self) {
            try SystemDFRoute.validateTypes(["container", "bogus"])
        }
        #expect(error?.reason == "unknown object type: bogus")
    }

    @Test("An empty type value is unknown, reported verbatim (like moby)")
    func emptyTypeValueRejected() {
        // Real Docker 400s `type=` with `unknown object type: ` (empty value).
        let error = #expect(throws: Abort.self) {
            try SystemDFRoute.validateTypes([""])
        }
        #expect(error?.reason == "unknown object type: ")
    }
}
