import Foundation
import Testing

@testable import socktainer

@Suite("ClientArchiveService guest reads for mounted paths")
struct ClientArchiveServiceGuestReadTests {

    private let service = ClientArchiveService(appSupportPath: FileManager.default.temporaryDirectory)

    // MARK: - Which reader answers

    @Test("a mount point is read through the guest even though the rootfs has the empty directory")
    func mountPointReadsThroughGuest() {
        #expect(
            service.readsThroughGuest(path: "/data", isRunning: true, mountDestinations: ["/data"], existsInRootfs: true),
            "the rootfs only has the empty mount-point directory; the volume is what the container sees")
    }

    @Test("a path under a mount is read through the guest even when the rootfs has a file there")
    func shadowedPathReadsThroughGuest() {
        #expect(
            service.readsThroughGuest(
                path: "/var/run/act/workflow/0", isRunning: true, mountDestinations: ["/var/run/act"], existsInRootfs: true),
            "a file left in the rootfs beneath the mount is hidden from the container")
    }

    @Test("a sibling that only shares a name prefix with a mount stays on the rootfs reader")
    func namePrefixIsNotAMount() {
        #expect(
            !service.readsThroughGuest(path: "/database/x", isRunning: true, mountDestinations: ["/data"], existsInRootfs: true))
    }

    @Test("a mount destination written with a trailing slash still covers its subtree")
    func trailingSlashMount() {
        #expect(
            service.readsThroughGuest(path: "/data/x", isRunning: true, mountDestinations: ["/data/"], existsInRootfs: true))
    }

    @Test("a stopped container is always read from the rootfs")
    func stoppedContainerUsesRootfs() {
        #expect(
            !service.readsThroughGuest(path: "/data", isRunning: false, mountDestinations: ["/data"], existsInRootfs: true))
    }

    @Test("a path missing from the rootfs and outside mounts still falls back to the guest (/dev, /proc, tmpfs)")
    func missingPathFallsBackToGuest() {
        #expect(
            service.readsThroughGuest(path: "/dev/null", isRunning: true, mountDestinations: [], existsInRootfs: false))
    }

    // MARK: - How a guest path is read

    /// st_mode values as `stat -c %f` prints them (type bits + permissions).
    private static let characterDevice: UInt32 = 0x21b6  // /dev/zero, crw-rw-rw-
    private static let blockDevice: UInt32 = 0x61b0
    private static let fifo: UInt32 = 0x11a4
    private static let socket: UInt32 = 0xc1ed

    @Test(
        "a device, FIFO or socket is never read for its contents",
        arguments: [characterDevice, blockDevice, fifo, socket])
    func specialFilesAreNotRead(rawMode: UInt32) {
        #expect(
            service.guestReadKind(rawMode: rawMode) != .regular,
            "cat on /dev/zero never ends and cat on a FIFO blocks; Docker archives these as header-only entries")
    }

    @Test("regular files, directories and symlinks keep their read kinds")
    func ordinaryKinds() {
        #expect(service.guestReadKind(rawMode: 0x81a4) == .regular)
        #expect(service.guestReadKind(rawMode: 0x41ed) == .directory)
        #expect(service.guestReadKind(rawMode: 0xa1ff) == .symlink)
    }

    // MARK: - Regular file reads

    @Test("a regular file is read no further than the size the probe reported")
    func regularFileReadIsBounded() {
        let command = service.guestRegularFileReadCommand(path: "/var/log/app.log", size: 4096)
        #expect(
            command == "head -c 4096 '/var/log/app.log'",
            "a file still being written must not stream past the size in the tar header: \(command)")
    }

    // MARK: - Directory archives

    @Test("a mounted directory is archived under its own name, like the rootfs reader and Docker do")
    func directoryArchiveKeepsItsBasename() {
        let command = service.guestDirectoryArchiveCommand(path: "/var/run/act/workflow")
        #expect(
            command.hasSuffix("tar -cf - -C '/var/run/act' 'workflow'"),
            "docker cp rebases entries on the source basename; `-C <dir> .` drops it: \(command)")
    }

    @Test("the root directory is archived as `.`")
    func rootDirectoryArchive() {
        #expect(service.guestDirectoryArchiveCommand(path: "/").hasSuffix("tar -cf - -C '/' ."))
    }

    // MARK: - The stat probe

    @Test(
        "an image whose shell cannot run the probe reports the path as missing, not as a server error",
        arguments: [Int32(126), Int32(127)])
    func probeThatCannotRunIsMissing(exitCode: Int32) {
        #expect(
            service.guestProbeStatus(exitCode: exitCode) == .missing,
            "distroless and scratch images have no /bin/sh; before the guest fallback these paths returned 404")
    }

    @Test("the probe asks stat for the owner")
    func probeAsksForOwner() {
        #expect(
            service.guestStatScript(path: "/data/f").contains("stat -c '%f %s %Y %u %g'"),
            "without %u %g every file read through the guest is archived as root-owned")
    }

    @Test("the parsed probe keeps the file's owner and group")
    func parsedProbeKeepsOwner() throws {
        let probe = try #require(service.parseGuestStat("81a4 5 1700000000 1000 1001\n"))
        #expect(probe.uid == 1000, "docker cp -a must keep the owner")
        #expect(probe.gid == 1001)
        #expect(probe.size == 5)
        #expect(probe.rawMode == 0x81a4)
    }

    @Test("a symlink probe keeps its target after the stat line")
    func parsedSymlinkProbe() throws {
        let probe = try #require(service.parseGuestStat("a1ff 7 1700000000 0 0\n/target\n"))
        #expect(probe.linkTarget == "/target")
    }

    @Test("the probe's own exit codes keep their meaning")
    func probeExitCodes() {
        #expect(service.guestProbeStatus(exitCode: 0) == .found)
        #expect(service.guestProbeStatus(exitCode: 40) == .missing)
        #expect(service.guestProbeStatus(exitCode: 41) == .failed)
    }

    @Test("a path on the rootfs and outside mounts stays on the rootfs reader")
    func plainRootfsPath() {
        #expect(
            !service.readsThroughGuest(path: "/etc/hostname", isRunning: true, mountDestinations: ["/data"], existsInRootfs: true))
    }
}
