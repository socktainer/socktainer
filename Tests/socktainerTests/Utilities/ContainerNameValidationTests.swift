import ContainerAPIClient
import Testing

@Suite("Container name validation")
struct ContainerNameValidationTests {

    // MARK: - Character set validation

    @Test("Accepts alphanumeric-only name")
    func alphanumericName() throws {
        try Utility.validEntityName("mycontainer1")
    }

    @Test("Accepts name with allowed special characters (underscore, dot, hyphen)")
    func allowedSpecialCharacters() throws {
        try Utility.validEntityName("my_container.name-1")
    }

    @Test("Rejects name starting with special character")
    func rejectsLeadingSpecialCharacter() {
        #expect(throws: Error.self) { try Utility.validEntityName("-badname") }
        #expect(throws: Error.self) { try Utility.validEntityName("_badname") }
        #expect(throws: Error.self) { try Utility.validEntityName(".badname") }
    }

    @Test("Rejects name with disallowed characters")
    func rejectsDisallowedCharacters() {
        #expect(throws: Error.self) { try Utility.validEntityName("bad name") }
        #expect(throws: Error.self) { try Utility.validEntityName("bad/name") }
        #expect(throws: Error.self) { try Utility.validEntityName("bad@name") }
    }

    @Test("Rejects single-character name (regex requires at least 2 chars)")
    func rejectsSingleCharName() {
        #expect(throws: Error.self) { try Utility.validEntityName("a") }
    }

    // MARK: - Length boundary tests
    //
    // validEntityName uses regex ^[a-zA-Z0-9][a-zA-Z0-9_.-]+$ with no explicit
    // length cap. If Apple Container daemon rejects names beyond 64 chars, this
    // layer won't catch it — these tests document current behaviour at the
    // validation layer only.

    @Test("Accepts 63-character name")
    func accepts63CharName() throws {
        let name = "a" + String(repeating: "b", count: 62)
        #expect(name.count == 63)
        try Utility.validEntityName(name)
    }

    @Test("Accepts 64-character name")
    func accepts64CharName() throws {
        let name = "a" + String(repeating: "b", count: 63)
        #expect(name.count == 64)
        try Utility.validEntityName(name)
    }

    @Test("Accepts 65-character name")
    func accepts65CharName() throws {
        let name = "a" + String(repeating: "b", count: 64)
        #expect(name.count == 65)
        try Utility.validEntityName(name)
    }

    @Test("Accepts 255-character name")
    func accepts255CharName() throws {
        let name = "a" + String(repeating: "b", count: 254)
        #expect(name.count == 255)
        try Utility.validEntityName(name)
    }
}
