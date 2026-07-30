import ContainerResource
import Testing

@Suite("Container name validation")
struct ContainerNameValidationTests {

    // MARK: - Character set validation

    @Test("Accepts alphanumeric-only name")
    func alphanumericName() throws {
        #expect(ManagedContainer.nameValid("mycontainer1"))
    }

    @Test("Accepts name with allowed special characters (underscore, dot, hyphen)")
    func allowedSpecialCharacters() throws {
        #expect(ManagedContainer.nameValid("my_container.name-1"))
    }

    @Test("Rejects name starting with special character")
    func rejectsLeadingSpecialCharacter() {
        #expect(!ManagedContainer.nameValid("-badname"))
        #expect(!ManagedContainer.nameValid("_badname"))
        #expect(!ManagedContainer.nameValid(".badname"))
    }

    @Test("Rejects name with disallowed characters")
    func rejectsDisallowedCharacters() {
        #expect(!ManagedContainer.nameValid("bad name"))
        #expect(!ManagedContainer.nameValid("bad/name"))
        #expect(!ManagedContainer.nameValid("bad@name"))
    }

    @Test("Rejects single-character name (regex requires at least 2 chars)")
    func rejectsSingleCharName() {
        #expect(!ManagedContainer.nameValid("a"))
    }

    // MARK: - Length boundary tests

    @Test("Accepts 63-character name")
    func accepts63CharName() throws {
        let name = "a" + String(repeating: "b", count: 62)
        #expect(name.count == 63)
        #expect(ManagedContainer.nameValid(name))
    }

    @Test("Rejects 64-character name (exceeds DNS label limit)")
    func rejects64CharName() throws {
        let name = "a" + String(repeating: "b", count: 63)
        #expect(name.count == 64)
        #expect(!ManagedContainer.nameValid(name))
    }
}
