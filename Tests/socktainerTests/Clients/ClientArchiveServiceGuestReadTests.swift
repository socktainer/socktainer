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

    @Test("a path on the rootfs and outside mounts stays on the rootfs reader")
    func plainRootfsPath() {
        #expect(
            !service.readsThroughGuest(path: "/etc/hostname", isRunning: true, mountDestinations: ["/data"], existsInRootfs: true))
    }
}
