import ContainerResource
import ContainerizationOCI
import Foundation
import Testing

@testable import socktainer

@Suite("Docker container ID derivation and resolution")
struct DockerContainerIDTests {
    private let created = Date(timeIntervalSince1970: 1_765_500_000)

    private func entries(_ ids: [String]) -> [(nativeId: String, hexId: String)] {
        ids.map { ($0, DockerContainerID.hexId(nativeId: $0, createdAt: created)) }
    }

    // MARK: - hexId

    @Test("Derived ID is 64 lowercase hex characters")
    func hexIdShape() {
        let id = DockerContainerID.hexId(nativeId: "exampleproject-web-1", createdAt: created)
        #expect(id.count == 64)
        #expect(id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test("Derivation is deterministic and distinct per native ID")
    func hexIdDeterministic() {
        #expect(
            DockerContainerID.hexId(nativeId: "a", createdAt: created) == DockerContainerID.hexId(nativeId: "a", createdAt: created)
        )
        #expect(
            DockerContainerID.hexId(nativeId: "a", createdAt: created) != DockerContainerID.hexId(nativeId: "b", createdAt: created)
        )
    }

    @Test("A renamed container keeps the ID it was created with")
    func renameKeepsId() {
        func snapshot(id: String, labels: [String: String]) -> ContainerSnapshot {
            let process = ProcessConfiguration(
                executable: "/bin/sh", arguments: [], environment: [],
                workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0))
            let image = ImageDescription(
                reference: "alpine:latest",
                descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0))
            var configuration = ContainerConfiguration(id: id, image: image, process: process)
            configuration.labels = labels
            return ContainerSnapshot(configuration: configuration, status: .stopped, networks: [])
        }
        let timestamp = [AppleContainerTimestampResolver.legacyCreationTimestampLabel: "1765500000"]
        let original = snapshot(id: "abc_web-1", labels: timestamp)
        var renamedLabels = timestamp
        renamedLabels[DockerContainerID.idSeedLabel] = "abc_web-1"
        let renamed = snapshot(id: "web-1", labels: renamedLabels)

        #expect(DockerContainerID.hexId(for: renamed) == DockerContainerID.hexId(for: original))
        #expect(DockerContainerID.hexId(for: renamed) != DockerContainerID.hexId(for: snapshot(id: "web-1", labels: timestamp)))
    }

    @Test("Recreating a container under the same name yields a new ID")
    func recreationChangesId() {
        let recreated = created.addingTimeInterval(42)
        #expect(
            DockerContainerID.hexId(nativeId: "web-1", createdAt: created) != DockerContainerID.hexId(nativeId: "web-1", createdAt: recreated)
        )
    }

    @Test("Missing creation date still derives a stable ID")
    func missingCreationDate() {
        let id = DockerContainerID.hexId(nativeId: "web-1", createdAt: nil)
        #expect(id.count == 64)
        #expect(id == DockerContainerID.hexId(nativeId: "web-1", createdAt: nil))
    }

    // MARK: - resolve

    @Test("Resolves an exact native ID")
    func resolvesNativeId() {
        let result = DockerContainerID.resolve(
            reference: "exampleproject-web-1",
            entries: entries(["exampleproject-web-1", "exampleproject-db-1"])
        )
        #expect(result == .match("exampleproject-web-1"))
    }

    @Test("Resolves a full hex ID")
    func resolvesFullHexId() {
        let hex = DockerContainerID.hexId(nativeId: "exampleproject-web-1", createdAt: created)
        let result = DockerContainerID.resolve(
            reference: hex,
            entries: entries(["exampleproject-web-1", "exampleproject-db-1"])
        )
        #expect(result == .match("exampleproject-web-1"))
    }

    @Test("Resolves a truncated 12-character hex ID as docker ps emits it")
    func resolvesTruncatedHexId() {
        let truncated = String(DockerContainerID.hexId(nativeId: "exampleproject-web-1", createdAt: created).prefix(12))
        let result = DockerContainerID.resolve(
            reference: truncated,
            entries: entries(["exampleproject-web-1", "exampleproject-db-1"])
        )
        #expect(result == .match("exampleproject-web-1"))
    }

    @Test("Rejects a prefix matching more than one container")
    func rejectsAmbiguousPrefix() {
        // Find two native IDs whose derived hex IDs share the first
        // character, so a one-character reference is genuinely ambiguous.
        let first = "container-0"
        let firstChar = DockerContainerID.hexId(nativeId: first, createdAt: created).prefix(1)
        var other: String?
        for index in 1...1000 {
            let candidate = "container-\(index)"
            if DockerContainerID.hexId(nativeId: candidate, createdAt: created).prefix(1) == firstChar {
                other = candidate
                break
            }
        }
        guard let second = other else {
            Issue.record("No colliding first hex character found in 1000 candidates")
            return
        }

        let result = DockerContainerID.resolve(reference: String(firstChar), entries: entries([first, second]))
        guard case .ambiguous(let matches) = result else {
            Issue.record("Expected .ambiguous, got \(result)")
            return
        }
        #expect(Set(matches) == Set([first, second]))
    }

    @Test("Resolves an uppercase hex prefix case-insensitively")
    func resolvesUppercaseHexId() {
        let truncated = String(DockerContainerID.hexId(nativeId: "exampleproject-web-1", createdAt: created).prefix(12)).uppercased()
        let result = DockerContainerID.resolve(
            reference: truncated,
            entries: entries(["exampleproject-web-1", "exampleproject-db-1"])
        )
        #expect(result == .match("exampleproject-web-1"))
    }

    @Test("Non-hex references never resolve as ID prefixes")
    func nonHexReference() {
        // A truncated *name* (the bug this type exists to prevent) contains
        // non-hex characters and must not accidentally prefix-match.
        let result = DockerContainerID.resolve(
            reference: "zed_dc_test-",
            entries: entries(["zed_dc_test-app-1", "zed_dc_test-db-1"])
        )
        #expect(result == .none)
    }

    @Test("Empty and unknown references resolve to none")
    func emptyAndUnknown() {
        #expect(DockerContainerID.resolve(reference: "", entries: entries(["a"])) == .none)
        #expect(DockerContainerID.resolve(reference: "deadbeef", entries: entries(["a"])) == .none)
    }

    @Test("Sanitized 64-char hex ID fails resolution (the bug from #344)")
    func sanitizedHexIdFailsResolution() {
        let hex = DockerContainerID.hexId(nativeId: "my-container", createdAt: created)
        #expect(hex.count == 64)

        let sanitized = ContainerNameUtility.sanitize(hex)
        #expect(sanitized != hex)
        #expect(sanitized.contains("-"))

        let result = DockerContainerID.resolve(
            reference: sanitized,
            entries: entries(["my-container"])
        )
        #expect(result == .none)
    }

    @Test("Raw 64-char hex ID resolves correctly (#344)")
    func rawHexIdResolvesCorrectly() {
        let hex = DockerContainerID.hexId(nativeId: "my-container", createdAt: created)
        #expect(hex.count == 64)

        let result = DockerContainerID.resolve(
            reference: hex,
            entries: entries(["my-container"])
        )
        #expect(result == .match("my-container"))
    }
}
