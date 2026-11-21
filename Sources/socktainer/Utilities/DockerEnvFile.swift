import ContainerResource
import Foundation

/// Docker puts an empty `/.dockerenv` in every container, and tools decide whether they
/// run in a container by checking for it, so a socktainer container without one is taken
/// for the host. socktainer file-mounts an empty `/.dockerenv` into every container it
/// creates, the way `ExtraHostsFile` provides `/etc/hosts`.
///
/// Podman's `/run/.containerenv` is deliberately not added: tools that read it report the
/// engine as Podman, and socktainer presents itself to clients as Docker.
///
/// The host file holds nothing specific to a container, so all containers share one,
/// mounted read-only so that no container can change it for the others. It is never
/// removed: a container's configuration keeps the mount, and a missing source would
/// stop the container from starting.
enum DockerEnvFile {
    static let guestPath = "/.dockerenv"
    static let fileName = "dockerenv"

    static let root = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/com.apple.container/socktainer-dockerenv")

    /// The mount to add to a container being created, given the mounts it already has.
    /// Returns nil when the request mounts something at `/.dockerenv` itself, which then
    /// replaces the marker.
    ///
    /// Also nil for a read-only root filesystem. The runtime must create an empty
    /// `/.dockerenv` in the root filesystem to mount over, and on a read-only one that
    /// fails and the container cannot start. Docker avoids this by writing the file into
    /// a layer of its own, which Apple Container does not have.
    static func mount(existing mounts: [Filesystem], readOnlyRootfs: Bool, root: URL = DockerEnvFile.root) throws -> Filesystem? {
        guard !readOnlyRootfs, !mounts.contains(where: { normalized($0.destination) == guestPath }) else { return nil }
        let file = try ensureFile(in: root)
        return .virtiofs(source: file.path, destination: guestPath, options: ["ro"])
    }

    /// Creates the shared empty file if it is missing and returns its location.
    static func ensureFile(in root: URL = DockerEnvFile.root) throws -> URL {
        let file = root.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: file.path) {
            return file
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Not atomic: concurrent creates all write the same empty content.
        try Data().write(to: file)
        return file
    }

    /// True for the mount `mount(existing:readOnlyRootfs:)` adds. Inspect and list hide it, as Docker
    /// does not report `/.dockerenv` as a mount. A mount the client asked for at the same
    /// path has a different source and is still reported.
    static func isMarker(_ mount: Filesystem, root: URL = DockerEnvFile.root) -> Bool {
        let source = URL(fileURLWithPath: mount.source).standardizedFileURL.path
        let hostFile = root.appendingPathComponent(fileName).standardizedFileURL.path
        return mount.isVirtiofs && normalized(mount.destination) == guestPath && source == hostFile
    }

    /// The mounts to report to Docker clients, without the marker.
    static func reported(_ mounts: [Filesystem]) -> [Filesystem] {
        mounts.filter { !isMarker($0) }
    }

    /// `mounts` without the marker when one of `staged`, the files copied in before the
    /// first start, targets `/.dockerenv`. In Docker the copy lands in the container's
    /// own layer, above the marker, so the copied file is what the container sees.
    static func yielding(_ mounts: [Filesystem], to staged: [Filesystem]) -> [Filesystem] {
        guard staged.contains(where: { normalized($0.destination) == guestPath }) else { return mounts }
        return mounts.filter { !isMarker($0) }
    }

    /// Collapses `.`, `..` and repeated or trailing slashes in a guest path. This is purely
    /// lexical: `NSString.standardizingPath` would resolve `..` through the host's
    /// symlinks, which say nothing about the guest's filesystem.
    static func normalized(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                _ = components.popLast()
            default:
                components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }
}
