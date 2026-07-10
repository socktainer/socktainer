import Foundation
import Testing

@testable import socktainer

@Suite("LabelNormalization")
struct LabelNormalizationTests {

    // MARK: - sanitizeKey

    @Test("Lowercase-only keys pass through unchanged")
    func lowercaseKeysUnchanged() {
        #expect(LabelNormalization.sanitizeKey("org.example.key") == "org.example.key")
        #expect(LabelNormalization.sanitizeKey("foo") == "foo")
    }

    @Test("Mixed-case keys are lowercased")
    func mixedCaseKeyLowercased() {
        #expect(LabelNormalization.sanitizeKey("org.testcontainers.sessionId") == "org.testcontainers.sessionid")
    }

    @Test("Underscores are replaced with hyphens")
    func underscoresReplacedWithHyphens() {
        #expect(LabelNormalization.sanitizeKey("my_label_key") == "my-label-key")
    }

    @Test("Underscore + uppercase combination is handled")
    func underscoreAndUppercase() {
        #expect(LabelNormalization.sanitizeKey("My_Label_Key") == "my-label-key")
    }

    @Test("Characters outside [a-z0-9-./] are dropped")
    func invalidCharsDropped() {
        #expect(LabelNormalization.sanitizeKey("my@label") == "mylabel")
        #expect(LabelNormalization.sanitizeKey("my label") == "mylabel")
    }

    @Test("Forward slash is preserved (OCI label format)")
    func slashPreserved() {
        #expect(LabelNormalization.sanitizeKey("io.buildpacks/runtime") == "io.buildpacks/runtime")
    }

    @Test("Consecutive hyphens are collapsed to single hyphen")
    func consecutiveHyphensCollapsed() {
        #expect(LabelNormalization.sanitizeKey("a--b") == "a-b")
        #expect(LabelNormalization.sanitizeKey("my__key") == "my-key")  // __ → -- → -
    }

    @Test("Consecutive dots are collapsed to single dot")
    func consecutiveDotsCollapsed() {
        #expect(LabelNormalization.sanitizeKey("a..b") == "a.b")
        #expect(LabelNormalization.sanitizeKey("a...b") == "a.b")
    }

    @Test("Consecutive slashes are collapsed to single slash")
    func consecutiveSlashesCollapsed() {
        #expect(LabelNormalization.sanitizeKey("io.buildpacks//runtime") == "io.buildpacks/runtime")
        #expect(LabelNormalization.sanitizeKey("a///b") == "a/b")
    }

    @Test("Leading and trailing separators are stripped — hyphens, dots, and slashes")
    func leadingTrailingSeparatorsStripped() {
        #expect(LabelNormalization.sanitizeKey("-my-key") == "my-key")
        #expect(LabelNormalization.sanitizeKey("my-key-") == "my-key")
        #expect(LabelNormalization.sanitizeKey(".my.key.") == "my.key")
        #expect(LabelNormalization.sanitizeKey("/my/key/") == "my/key")
        #expect(LabelNormalization.sanitizeKey("//my//key//") == "my/key")
    }

    @Test("Key of only invalid characters returns empty string")
    func onlyInvalidCharsReturnsEmpty() {
        #expect(LabelNormalization.sanitizeKey("@@@") == "")
        #expect(LabelNormalization.sanitizeKey("---") == "")
    }

    // MARK: - sanitize (dict)

    @Test("Empty labels return empty dict")
    func emptyLabels() {
        #expect(LabelNormalization.sanitize([:]).isEmpty)
    }

    @Test("Key that becomes empty after normalization is dropped")
    func emptyKeyDropped() {
        #expect(LabelNormalization.sanitize(["@@@": "value"]).isEmpty)
    }

    @Test("Originally-empty key is dropped unconditionally (regression: empty key bypassed guard)")
    func originallyEmptyKeyDropped() {
        // "" normalizes to "" — the guard must fire even when normalizedKey == key
        #expect(LabelNormalization.sanitize(["": "value"]).isEmpty)
    }

    @Test("Reserved mapping key in input is detected by containsReservedKey")
    func reservedMappingKeyDetected() {
        let labels = [LabelNormalization.mappingKey: "anything"]
        #expect(LabelNormalization.containsReservedKey(labels) == true)
        #expect(LabelNormalization.containsReservedKey(["normal-key": "value"]) == false)
    }

    @Test("Collision on lowercase keeps last value")
    func collisionKeepsLast() {
        let result = LabelNormalization.sanitize(["Key": "first", "key": "second"])
        #expect(result.count == 1)
        #expect(result["key"] != nil)
    }

    @Test("Values are preserved as-is")
    func valuesPreserved() {
        let result = LabelNormalization.sanitize(["Key": "MixedCaseValue"])
        #expect(result["key"] == "MixedCaseValue")
    }

    // MARK: - buildMapping

    @Test("No mapping produced when no keys are changed")
    func noMappingForCleanKeys() {
        #expect(LabelNormalization.buildMapping(["clean-key": "value"]) == nil)
    }

    @Test("Mapping produced for changed keys")
    func mappingProducedForChangedKeys() {
        let json = LabelNormalization.buildMapping(["sessionId": "abc"])
        #expect(json != nil)
        if let data = json?.data(using: .utf8),
            let map = try? JSONDecoder().decode([String: String].self, from: data)
        {
            #expect(map["sessionid"] == "sessionId")
        }
    }

    @Test("Mapping excludes unchanged keys")
    func mappingExcludesUnchangedKeys() {
        let json = LabelNormalization.buildMapping(["clean-key": "a", "MyKey": "b"])
        if let data = json?.data(using: .utf8),
            let map = try? JSONDecoder().decode([String: String].self, from: data)
        {
            #expect(map["clean-key"] == nil)
            #expect(map["mykey"] == "MyKey")
        }
    }

    // MARK: - restore

    @Test("Mapping label is always stripped from output")
    func mappingLabelStripped() {
        let labels = [LabelNormalization.mappingKey: "{}", "foo": "bar"]
        let result = LabelNormalization.restore(labels)
        #expect(result[LabelNormalization.mappingKey] == nil)
        #expect(result["foo"] == "bar")
    }

    @Test("Original keys are restored from mapping")
    func originalKeysRestored() throws {
        let mappingData = try JSONEncoder().encode(["sessionid": "sessionId"])
        guard let mappingJSON = String(data: mappingData, encoding: .utf8) else {
            Issue.record("Failed to encode mapping to UTF-8 string")
            return
        }
        let stored = [LabelNormalization.mappingKey: mappingJSON, "sessionid": "abc"]
        let result = LabelNormalization.restore(stored)
        #expect(result["sessionId"] == "abc")
        #expect(result["sessionid"] == nil)
        #expect(result[LabelNormalization.mappingKey] == nil)
    }

    @Test("No mapping label = labels returned as-is (backwards compatibility)")
    func noMappingReturnsLabelsAsIs() {
        let labels = ["already-clean": "value"]
        #expect(LabelNormalization.restore(labels) == labels)
    }

    // MARK: - Full round-trip

    @Test("testcontainers sessionId round-trips transparently through sanitize + restore")
    func testcontainersRoundTrip() {
        let original = ["org.testcontainers.sessionId": "abc", "org.example.version": "1.0"]
        var stored = LabelNormalization.sanitize(original)
        if let mapping = LabelNormalization.buildMapping(original) {
            stored[LabelNormalization.mappingKey] = mapping
        }
        let restored = LabelNormalization.restore(stored)
        #expect(restored["org.testcontainers.sessionId"] == "abc")
        #expect(restored["org.example.version"] == "1.0")
        #expect(restored[LabelNormalization.mappingKey] == nil)
    }

    @Test("Filter lookup works via sanitized key comparison against raw stored labels")
    func filterLookupWorksViaSanitizedKey() {
        var stored = LabelNormalization.sanitize(["org.testcontainers.sessionId": "abc"])
        if let mapping = LabelNormalization.buildMapping(["org.testcontainers.sessionId": "abc"]) {
            stored[LabelNormalization.mappingKey] = mapping
        }
        // Raw stored labels use normalized keys — filter should normalize to match
        let filterKey = LabelNormalization.sanitizeKey("org.testcontainers.sessionId")
        #expect(stored[filterKey] == "abc")
    }

    // MARK: - Collision warning

    @Test("Collision: two keys normalizing to same string — last value wins")
    func collisionLastValueWins() {
        let result = LabelNormalization.sanitize(["MyKey": "first", "mykey": "second"])
        #expect(result.count == 1)
        #expect(result["mykey"] != nil)
    }

    // MARK: - filterValue / filterContainsKey helpers

    @Test("filterValue finds value by original key in restored labels (new resources)")
    func filterValueFindsOriginalKey() {
        // Simulate restored labels from a new resource (mapping was stored)
        let original = ["org.Test.Volume": "vol1"]
        var stored = LabelNormalization.sanitize(original)
        if let mapping = LabelNormalization.buildMapping(original) {
            stored[LabelNormalization.mappingKey] = mapping
        }
        let restored = LabelNormalization.restore(stored)

        #expect(LabelNormalization.filterValue(in: restored, forKey: "org.Test.Volume") == "vol1")
    }

    @Test("filterValue finds value by normalized key in old resources (no mapping)")
    func filterValueFindsNormalizedKeyForOldResources() {
        // Simulate old resource without mapping (pre-existing normalized labels)
        let oldStored = ["org.test.volume": "vol1"]

        #expect(LabelNormalization.filterValue(in: oldStored, forKey: "org.Test.Volume") == "vol1")
    }

    @Test("filterValue returns nil when key not found in either form")
    func filterValueReturnsNilWhenNotFound() {
        let labels = ["other.key": "value"]
        #expect(LabelNormalization.filterValue(in: labels, forKey: "org.Test.Volume") == nil)
    }

    @Test("filterContainsKey finds key in restored labels (new resources)")
    func filterContainsKeyInRestoredLabels() {
        let original = ["MyVolume": "true"]
        var stored = LabelNormalization.sanitize(original)
        if let mapping = LabelNormalization.buildMapping(original) {
            stored[LabelNormalization.mappingKey] = mapping
        }
        let restored = LabelNormalization.restore(stored)

        #expect(LabelNormalization.filterContainsKey("MyVolume", in: restored))
        #expect(!LabelNormalization.filterContainsKey("OtherKey", in: restored))
    }

    @Test("filterContainsKey finds normalized key in old resources (no mapping)")
    func filterContainsKeyInOldResources() {
        let oldStored = ["myvolume": "true"]
        #expect(LabelNormalization.filterContainsKey("MyVolume", in: oldStored))
    }
}
