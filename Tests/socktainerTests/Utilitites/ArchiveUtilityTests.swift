import Foundation
import Testing

@testable import socktainer

struct ArchiveUtilityTests {

    // MARK: - destinationPath

    @Test("nil entry returns nil")
    func nilEntryReturnsNil() {
        #expect(ArchiveUtility.destinationPath(for: nil, under: "/target") == nil)
    }

    @Test("'.' entry maps to destination itself")
    func dotEntryMapsToDestination() {
        #expect(ArchiveUtility.destinationPath(for: ".", under: "/var/run/act") == "/var/run/act")
    }

    @Test("'/' entry maps to destination itself")
    func slashEntryMapsToDestination() {
        #expect(ArchiveUtility.destinationPath(for: "/", under: "/var/run/act") == "/var/run/act")
    }

    @Test("'./file.txt' is placed directly under destination")
    func dotSlashFileUnderDestination() {
        #expect(
            ArchiveUtility.destinationPath(for: "./file.txt", under: "/var/run/act")
                == "/var/run/act/file.txt"
        )
    }

    @Test("bare 'file.txt' is placed directly under destination")
    func bareFileUnderDestination() {
        #expect(
            ArchiveUtility.destinationPath(for: "file.txt", under: "/var/run/act")
                == "/var/run/act/file.txt"
        )
    }

    @Test("nested './sub/dir/file.txt' preserves hierarchy under destination")
    func nestedEntryPreservesHierarchy() {
        #expect(
            ArchiveUtility.destinationPath(for: "./sub/dir/file.txt", under: "/target")
                == "/target/sub/dir/file.txt"
        )
    }

    @Test("destination '/' returns entry path directly")
    func rootDestinationReturnsEntryPath() {
        #expect(ArchiveUtility.destinationPath(for: "./file.txt", under: "/") == "/file.txt")
    }

    @Test("absolute entry path is placed under destination")
    func absoluteEntryUnderDestination() {
        #expect(
            ArchiveUtility.destinationPath(for: "/file.txt", under: "/target")
                == "/target/file.txt"
        )
    }
}
