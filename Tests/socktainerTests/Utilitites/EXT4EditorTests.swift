import ContainerizationEXT4
import Foundation
import SystemPackage
import Testing

@testable import socktainer

/// Tests for EXT4Editor in-place filesystem modification
struct EXT4EditorTests {
    /// Path to temporary directory for test filesystems
    let tempDir: URL

    init() {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ext4-editor-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    /// Create a test ext4 filesystem with some initial content
    func createTestFilesystem(name: String = "test.ext4") throws -> URL {
        let fsPath = tempDir.appendingPathComponent(name)

        // Use Apple's Formatter to create a valid ext4 filesystem
        let formatter = try EXT4.Formatter(
            FilePath(fsPath.path),
            blockSize: 4096,
            minDiskSize: 10 * 1024 * 1024  // 10MB - enough for testing
        )

        // Create some initial directories and files
        try formatter.create(
            path: FilePath("/testdir"),
            mode: EXT4.Inode.Mode(.S_IFDIR, 0o755)
        )

        try formatter.create(
            path: FilePath("/testdir/subdir"),
            mode: EXT4.Inode.Mode(.S_IFDIR, 0o755)
        )

        // Create a file with content
        let initialContent = "Initial file content\n"
        let contentData = Data(initialContent.utf8)
        let inputStream = InputStream(data: contentData)
        inputStream.open()
        defer { inputStream.close() }

        try formatter.create(
            path: FilePath("/testdir/existing.txt"),
            mode: EXT4.Inode.Mode(.S_IFREG, 0o644),
            buf: inputStream
        )

        try formatter.close()

        return fsPath
    }

    /// Clean up test filesystem
    func cleanup(fsPath: URL) {
        try? FileManager.default.removeItem(at: fsPath)
    }

    /// Verify file exists and has expected content using Apple's Reader
    func verifyFileContent(fsPath: URL, path: String, expectedContent: String) throws -> Bool {
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(fsPath.path))
        let data = try reader.readFile(at: FilePath(path))
        let content = String(data: data, encoding: .utf8)
        return content == expectedContent
    }

    /// Verify file exists using Apple's Reader
    func verifyFileExists(fsPath: URL, path: String) throws -> Bool {
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(fsPath.path))
        return reader.exists(FilePath(path))
    }

    /// List directory contents using Apple's Reader
    func listDirectory(fsPath: URL, path: String) throws -> [String] {
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(fsPath.path))
        return try reader.listDirectory(FilePath(path))
    }


    @Test("Open existing filesystem")
    func testOpenFilesystem() throws {
        let fsPath = try createTestFilesystem()
        defer { cleanup(fsPath: fsPath) }

        // Should open without error
        let editor = try EXT4Editor(devicePath: FilePath(fsPath.path))

        // Verify existing content is still readable
        #expect(try verifyFileExists(fsPath: fsPath, path: "/testdir"))
        #expect(try verifyFileExists(fsPath: fsPath, path: "/testdir/existing.txt"))

        try editor.sync()
    }

    @Test("Add file to root directory")
    func testAddFileToRoot() throws {
        let fsPath = try createTestFilesystem()
        defer { cleanup(fsPath: fsPath) }

        let editor = try EXT4Editor(devicePath: FilePath(fsPath.path))

        // Add a new file
        let content = "Hello from EXT4Editor!\n"
        try editor.addFile(path: "/newfile.txt", data: Data(content.utf8))
        try editor.sync()

        // Verify with Apple's Reader
        #expect(try verifyFileExists(fsPath: fsPath, path: "/newfile.txt"))
        #expect(try verifyFileContent(fsPath: fsPath, path: "/newfile.txt", expectedContent: content))
    }

    @Test("Add file to subdirectory")
    func testAddFileToSubdirectory() throws {
        let fsPath = try createTestFilesystem()
        defer { cleanup(fsPath: fsPath) }

        let editor = try EXT4Editor(devicePath: FilePath(fsPath.path))

        // Add a new file in subdirectory
        let content = "File in subdirectory\n"
        try editor.addFile(path: "/testdir/subdir/deep.txt", data: Data(content.utf8))
        try editor.sync()

        // Verify
        #expect(try verifyFileExists(fsPath: fsPath, path: "/testdir/subdir/deep.txt"))
        #expect(try verifyFileContent(fsPath: fsPath, path: "/testdir/subdir/deep.txt", expectedContent: content))
    }

    @Test("Add multiple files")
    func testAddMultipleFiles() throws {
        let fsPath = try createTestFilesystem()
        defer { cleanup(fsPath: fsPath) }

        let editor = try EXT4Editor(devicePath: FilePath(fsPath.path))

        // Add multiple files
        for i in 1...5 {
            let content = "File number \(i)\n"
            try editor.addFile(path: "/testdir/file\(i).txt", data: Data(content.utf8))
        }
        try editor.sync()

        // Verify all files
        for i in 1...5 {
            let path = "/testdir/file\(i).txt"
            let expectedContent = "File number \(i)\n"
            #expect(try verifyFileExists(fsPath: fsPath, path: path))
            #expect(try verifyFileContent(fsPath: fsPath, path: path, expectedContent: expectedContent))
        }
    }

    @Test("Add larger file")
    func testAddLargerFile() throws {
        let fsPath = try createTestFilesystem()
        defer { cleanup(fsPath: fsPath) }

        let editor = try EXT4Editor(devicePath: FilePath(fsPath.path))

        // Create a file larger than one block (4KB)
        var content = ""
        for i in 0..<1000 {
            content += "Line \(i): This is some content to make the file larger.\n"
        }

        try editor.addFile(path: "/largefile.txt", data: Data(content.utf8))
        try editor.sync()

        // Verify
        #expect(try verifyFileExists(fsPath: fsPath, path: "/largefile.txt"))
        #expect(try verifyFileContent(fsPath: fsPath, path: "/largefile.txt", expectedContent: content))
    }

    @Test("Add empty file")
    func testAddEmptyFile() throws {
        let fsPath = try createTestFilesystem()
        defer { cleanup(fsPath: fsPath) }

        let editor = try EXT4Editor(devicePath: FilePath(fsPath.path))

        try editor.addFile(path: "/empty.txt", data: Data())
        try editor.sync()

        #expect(try verifyFileExists(fsPath: fsPath, path: "/empty.txt"))
        #expect(try verifyFileContent(fsPath: fsPath, path: "/empty.txt", expectedContent: ""))
    }

    @Test("Add file with custom permissions")
    func testAddFileWithPermissions() throws {
        let fsPath = try createTestFilesystem()
        defer { cleanup(fsPath: fsPath) }

        let editor = try EXT4Editor(devicePath: FilePath(fsPath.path))

        let content = "Executable script\n"
        try editor.addFile(path: "/script.sh", data: Data(content.utf8), mode: 0o755)
        try editor.sync()

        #expect(try verifyFileExists(fsPath: fsPath, path: "/script.sh"))

        // Verify content
        #expect(try verifyFileContent(fsPath: fsPath, path: "/script.sh", expectedContent: content))
    }

    @Test("Add symlink")
    func testAddSymlink() throws {
        let fsPath = try createTestFilesystem()
        defer { cleanup(fsPath: fsPath) }

        let editor = try EXT4Editor(devicePath: FilePath(fsPath.path))

        try editor.addSymlink(path: "/link", target: "/testdir/existing.txt")
        try editor.sync()

        #expect(try verifyFileExists(fsPath: fsPath, path: "/link"))
    }

    @Test("Create directory")
    func testCreateDirectory() throws {
        let fsPath = try createTestFilesystem()
        defer { cleanup(fsPath: fsPath) }

        let editor = try EXT4Editor(devicePath: FilePath(fsPath.path))

        try editor.createDirectory(path: "/newdir")
        try editor.sync()

        #expect(try verifyFileExists(fsPath: fsPath, path: "/newdir"))

        // Add a file to the new directory
        let content = "File in new directory\n"
        try editor.addFile(path: "/newdir/file.txt", data: Data(content.utf8))
        try editor.sync()

        #expect(try verifyFileExists(fsPath: fsPath, path: "/newdir/file.txt"))
        #expect(try verifyFileContent(fsPath: fsPath, path: "/newdir/file.txt", expectedContent: content))
    }

    @Test("Exists check")
    func testExists() throws {
        let fsPath = try createTestFilesystem()
        defer { cleanup(fsPath: fsPath) }

        let editor = try EXT4Editor(devicePath: FilePath(fsPath.path))

        // Check existing paths
        #expect(editor.exists(path: "/"))
        #expect(editor.exists(path: "/testdir"))
        #expect(editor.exists(path: "/testdir/existing.txt"))

        // Check non-existing paths
        #expect(!editor.exists(path: "/nonexistent"))
        #expect(!editor.exists(path: "/testdir/nonexistent.txt"))
    }

    @Test("Error: file already exists")
    func testFileAlreadyExists() throws {
        let fsPath = try createTestFilesystem()
        defer { cleanup(fsPath: fsPath) }

        let editor = try EXT4Editor(devicePath: FilePath(fsPath.path))

        // Try to add file that already exists
        #expect(throws: EXT4EditorError.self) {
            try editor.addFile(path: "/testdir/existing.txt", data: Data("new content".utf8))
        }
    }

    @Test("Error: parent not found")
    func testParentNotFound() throws {
        let fsPath = try createTestFilesystem()
        defer { cleanup(fsPath: fsPath) }

        let editor = try EXT4Editor(devicePath: FilePath(fsPath.path))

        // Try to add file in non-existent directory
        #expect(throws: EXT4EditorError.self) {
            try editor.addFile(path: "/nonexistent/file.txt", data: Data("content".utf8))
        }
    }

    @Test("Existing content preserved after modification")
    func testExistingContentPreserved() throws {
        let fsPath = try createTestFilesystem()
        defer { cleanup(fsPath: fsPath) }

        // Verify initial content
        let initialContent = "Initial file content\n"
        #expect(try verifyFileContent(fsPath: fsPath, path: "/testdir/existing.txt", expectedContent: initialContent))

        // Modify filesystem
        let editor = try EXT4Editor(devicePath: FilePath(fsPath.path))
        try editor.addFile(path: "/newfile.txt", data: Data("new content".utf8))
        try editor.sync()

        // Verify original content is still intact
        #expect(try verifyFileContent(fsPath: fsPath, path: "/testdir/existing.txt", expectedContent: initialContent))

        // Verify directory structure preserved
        let rootContents = try listDirectory(fsPath: fsPath, path: "/")
        #expect(rootContents.contains("testdir"))
        #expect(rootContents.contains("newfile.txt"))
    }

    @Test("Binary file content")
    func testBinaryFileContent() throws {
        let fsPath = try createTestFilesystem()
        defer { cleanup(fsPath: fsPath) }

        let editor = try EXT4Editor(devicePath: FilePath(fsPath.path))

        // Create binary content with all byte values
        var binaryData = Data()
        for i: UInt8 in 0...255 {
            binaryData.append(i)
        }

        try editor.addFile(path: "/binary.bin", data: binaryData)
        try editor.sync()

        // Verify with Apple's Reader
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(fsPath.path))
        let readData = try reader.readFile(at: FilePath("/binary.bin"))
        #expect(readData == binaryData)
    }
}
