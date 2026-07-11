import Testing

@testable import socktainer

@Suite("MobyBool")
struct MobyBoolTests {

    @Test("filter values follow Go's strconv.ParseBool")
    func filterParsing() {
        for value in ["1", "t", "T", "TRUE", "true", "True"] {
            #expect(MobyBool.parse(value) == true, "\(value)")
        }
        for value in ["0", "f", "F", "FALSE", "false", "False"] {
            #expect(MobyBool.parse(value) == false, "\(value)")
        }
        for value in ["yes", "no", "tRuE", "", " true"] {
            #expect(MobyBool.parse(value) == nil, "\(value)")
        }
    }

    @Test("an absent query parameter keeps the endpoint default, a present one follows BoolValue")
    func queryDefaulting() {
        #expect(MobyBool.queryValue(nil, defaultingTo: true))
        #expect(!MobyBool.queryValue(nil, defaultingTo: false))
        #expect(!MobyBool.queryValue("", defaultingTo: true))
        #expect(!MobyBool.queryValue("0", defaultingTo: true))
        #expect(MobyBool.queryValue("1", defaultingTo: false))
    }

    @Test("query parameters follow moby's httputils.BoolValue: trimmed, only a few spellings are false")
    func queryParsing() {
        for value in [nil, "", "0", "no", "false", "FALSE", "none", "No", " false", " 0 "] as [String?] {
            #expect(!MobyBool.queryValue(value), "\(value ?? "nil")")
        }
        for value in ["1", "true", "t", "yes", "anything-else"] {
            #expect(MobyBool.queryValue(value), "\(value)")
        }
    }
}
