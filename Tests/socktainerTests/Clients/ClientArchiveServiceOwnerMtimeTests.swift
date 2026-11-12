import ContainerizationArchive
import Foundation
import Testing

@testable import socktainer

@Suite("ClientArchiveService keeps each entry's owner and mtime for a running container")
struct ClientArchiveServiceOwnerMtimeTests {

    private let service = ClientArchiveService(appSupportPath: FileManager.default.temporaryDirectory)

    @Test("parsing records each entry's uid, gid and mtime")
    func parseRecordsOwnerAndMtime() throws {
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("owner-mtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let tarPath = workDir.appendingPathComponent("a.tar")

        let writer = try ArchiveWriter(format: .paxRestricted, filter: .none, file: tarPath)
        let directory = WriteEntry(writer)
        directory.path = "app"
        directory.fileType = .directory
        directory.permissions = 0o750
        directory.owner = 33
        directory.group = 34
        directory.modificationDate = Date(timeIntervalSince1970: 1_767_294_000)
        try writer.writeEntry(entry: directory, data: nil as UnsafeRawBufferPointer?)

        let file = WriteEntry(writer)
        let data = Data("hello\n".utf8)
        file.path = "app/f1"
        file.fileType = .regular
        file.permissions = 0o640
        file.owner = 1000
        file.group = 1001
        file.modificationDate = Date(timeIntervalSince1970: 1_767_294_001)
        file.size = Int64(data.count)
        try writer.writeEntry(entry: file, data: data)
        try writer.finishEncoding()

        let plan = try service.parseArchiveEntries(tarPath: tarPath, destinationPath: "/tmp")

        let dirEntry = try #require(
            plan.first {
                guard case .directory = $0.kind else { return false }
                return true
            })
        #expect(dirEntry.uid == 33)
        #expect(dirEntry.gid == 34)
        #expect(dirEntry.mtime == 1_767_294_000)
        let fileEntry = try #require(plan.first { $0.guestPath == "/tmp/app/f1" })
        #expect(fileEntry.uid == 1000)
        #expect(fileEntry.gid == 1001)
        #expect(fileEntry.mtime == 1_767_294_001)
        #expect(fileEntry.mode == 0o640)
    }

    @Test("the file write applies owner before mode, then mtime")
    func fileWriteCommandAppliesOwnerModeMtime() {
        let entry = ClientArchiveService.ArchiveEntryPlan(
            relativePath: "f1", guestPath: "/tmp/it's here", kind: .file, mode: 0o4755,
            uid: 33, gid: 33, mtime: 1_767_294_001)

        #expect(
            service.fileWriteCommand(for: entry)
                == "cat > '/tmp/it'\\''s here' && chown 33:33 '/tmp/it'\\''s here' && chmod 4755 '/tmp/it'\\''s here' && touch -c -d @1767294001 '/tmp/it'\\''s here'"
        )
    }

    @Test("an entry without owner or mtime only sets the mode")
    func fileWriteCommandWithoutOwnerOrMtime() {
        let entry = ClientArchiveService.ArchiveEntryPlan(
            relativePath: "f1", guestPath: "/tmp/f1", kind: .file, mode: 0o644)

        #expect(service.fileWriteCommand(for: entry) == "cat > '/tmp/f1' && chmod 0644 '/tmp/f1'")
    }

    @Test("a directory the preparation script creates gets the archived owner")
    func preparationScriptChownsCreatedDirectory() {
        let entry = ClientArchiveService.ArchiveEntryPlan(
            relativePath: "app", guestPath: "/tmp/app", kind: .directory, mode: 0o750,
            uid: 33, gid: 34, mtime: nil)

        let script = service.buildPreparationScript(entries: [entry], noOverwriteDirNonDir: false)

        #expect(script.contains("if [ ! -d '/tmp/app' ]; then mkdir -p '/tmp' && mkdir -m 750 '/tmp/app' && chown 33:34 '/tmp/app' ||"))
    }
}
