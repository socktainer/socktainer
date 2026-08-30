import ContainerResource
import Foundation
import Logging

/// A staged upload could not be read back or recorded.
///
/// Reported rather than absorbed: a manifest that cannot be read means the
/// container is about to start without files a client was told it had, and an
/// empty list is indistinguishable from having staged nothing.
enum PreStartInjectionError: Error, CustomStringConvertible {
    case unreadableManifest(containerId: String, underlying: Error)
    case unrecordedCreateOptions(underlying: Error)

    var description: String {
        switch self {
        case .unreadableManifest(let id, let underlying):
            return "Staged files for container \(id) could not be read: \(underlying)"
        case .unrecordedCreateOptions(let underlying):
            return "Container create options could not be recorded: \(underlying)"
        }
    }
}

/// Files copied into a container that had never been started.
///
/// The runtime builds a container's filesystem at start, not at create
/// (apple/container#1398, closed as intentional), so `docker cp` before start
/// has nothing to write into. The files are held here and mounted into place
/// when the container is started, one mount per file: mounting the parent
/// directory instead would hide whatever the image put there.
actor PreStartInjectionStore {
    static let shared = PreStartInjectionStore()

    struct StagedFile: Codable, Sendable {
        let guestPath: String
        let hostPath: String
    }

    private var stagingRoot: URL?
    private var autoRemove: [String: Bool] = [:]
    private var autoRemoveURL: URL?

    func configure(storageDirectory: URL, logger: Logger) {
        stagingRoot = storageDirectory.appendingPathComponent("socktainer-prestart")
        let url = storageDirectory.appendingPathComponent("socktainer-prestart-create-options.json")
        autoRemoveURL = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            autoRemove = try JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: url))
        } catch {
            // Startup continues: the options only affect containers rebuilt later,
            // and refusing to serve at all would be a worse answer than losing them.
            logger.error("Recorded container create options are unusable: \(error)")
        }
    }

    /// Remember what the container was created with, so a container rebuilt to
    /// carry these files is rebuilt the same way.
    func rememberCreateOptions(containerId: String, autoRemove remove: Bool) throws {
        autoRemove[containerId] = remove
        try persistCreateOptions()
    }

    func createOptions(containerId: String) -> ContainerCreateOptions {
        ContainerCreateOptions(autoRemove: autoRemove[containerId] ?? false)
    }

    private func persistCreateOptions() throws {
        guard let autoRemoveURL else { return }
        do {
            try JSONEncoder().encode(autoRemove).write(to: autoRemoveURL)
        } catch {
            throw PreStartInjectionError.unrecordedCreateOptions(underlying: error)
        }
    }

    private func containerRoot(_ id: String) -> URL? {
        stagingRoot?.appendingPathComponent(id)
    }

    private func manifestURL(_ id: String) -> URL? {
        containerRoot(id)?.appendingPathComponent("manifest.json")
    }

    func pending(containerId: String) throws -> [StagedFile] {
        guard let url = manifestURL(containerId), FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        do {
            return try JSONDecoder().decode([StagedFile].self, from: Data(contentsOf: url))
        } catch {
            throw PreStartInjectionError.unreadableManifest(containerId: containerId, underlying: error)
        }
    }

    /// The staged files as mounts, ready to be added to a container's configuration.
    func mounts(containerId: String) throws -> [Filesystem] {
        try pending(containerId: containerId).map {
            .virtiofs(source: $0.hostPath, destination: $0.guestPath, options: [])
        }
    }

    /// Hold one uploaded file until the container is started. The staged copy
    /// mirrors the guest path, so two files never collide.
    func stage(containerId: String, guestPath: String, source: URL, mode: UInt32) throws {
        guard let root = containerRoot(containerId) else { return }
        let relative = guestPath.hasPrefix("/") ? String(guestPath.dropFirst()) : guestPath
        let destination = root.appendingPathComponent("files").appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Staged into place only once the copy is on disk: removing the previous
        // file first would lose an upload the container had already accepted if
        // the copy then failed.
        let incoming = destination.appendingPathExtension("incoming-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: incoming)
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: mode & 0o777)], ofItemAtPath: incoming.path)
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: incoming)
        } catch {
            try? FileManager.default.removeItem(at: incoming)
            throw error
        }

        var files = try pending(containerId: containerId).filter { $0.guestPath != guestPath }
        files.append(StagedFile(guestPath: guestPath, hostPath: destination.path))
        if let manifest = manifestURL(containerId) {
            try JSONEncoder().encode(files).write(to: manifest)
        }
    }

    func clear(containerId: String) throws {
        if let root = containerRoot(containerId) {
            // Cleanup only: a staging directory that outlives its container is
            // reclaimed on the next stage, and refusing the delete over it would
            // strand the container instead.
            try? FileManager.default.removeItem(at: root)
        }
        if autoRemove.removeValue(forKey: containerId) != nil {
            try persistCreateOptions()
        }
    }
}
