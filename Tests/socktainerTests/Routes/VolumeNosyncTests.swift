import ContainerResource
import Testing

@testable import socktainer

/// Verifies volume sync mode behaviour: nosync by default (global), overridable
/// per-volume via `docker volume create -o sync=fsync <name>`.
///
/// nosync skips per-write fsyncs to the host disk, matching Colima's effective
/// behavior and giving ~1.5x speedup for write-heavy workloads (postgres WAL,
/// kafka). Tradeoff: data in the host page cache since the last OS flush could be
/// lost on a host power cut — acceptable in dev environments.
@Suite("Volume sync mode")
struct VolumeNosyncTests {

    // MARK: - Filesystem.SyncMode parsing

    @Test("SyncMode parses nosync from string")
    func parsesNosync() {
        #expect(Filesystem.SyncMode(rawString: "nosync") == .nosync)
        #expect(Filesystem.SyncMode(rawString: "NOSYNC") == .nosync)
    }

    @Test("SyncMode parses fsync from string")
    func parsesFsync() {
        #expect(Filesystem.SyncMode(rawString: "fsync") == .fsync)
    }

    @Test("SyncMode parses full from string")
    func parsesFull() {
        #expect(Filesystem.SyncMode(rawString: "full") == .full)
    }

    @Test("SyncMode returns nil for unknown string")
    func parsesUnknownAsNil() {
        #expect(Filesystem.SyncMode(rawString: "invalid") == nil)
        #expect(Filesystem.SyncMode(rawString: "") == nil)
    }

    @Test("SyncMode rawString round-trips correctly")
    func rawStringRoundTrips() {
        #expect(Filesystem.SyncMode.nosync.rawString == "nosync")
        #expect(Filesystem.SyncMode.fsync.rawString == "fsync")
        #expect(Filesystem.SyncMode.full.rawString == "full")
    }

    // MARK: - Filesystem.volume API

    @Test("Filesystem.volume with nosync stores nosync in FSType")
    func filesystemVolumeNosyncMode() {
        let fs = Filesystem.volume(
            name: "my-volume",
            format: "ext4",
            source: "/tmp/vol",
            destination: "/data",
            options: [],
            sync: .nosync
        )
        guard case .volume(_, _, _, let syncMode) = fs.type else {
            Issue.record("Expected FSType.volume, got \(fs.type)")
            return
        }
        #expect(syncMode == .nosync)
    }

    @Test("Default Filesystem.volume sync mode is fsync (upstream default regression guard)")
    func filesystemVolumeDefaultIsFsync() {
        let fs = Filesystem.volume(
            name: "my-volume",
            format: "ext4",
            source: "/tmp/vol",
            destination: "/data",
            options: []
        )
        guard case .volume(_, _, _, let syncMode) = fs.type else {
            Issue.record("Expected FSType.volume, got \(fs.type)")
            return
        }
        // Documents the upstream default — if this fails, the default changed and
        // our nosync override may no longer be necessary.
        #expect(syncMode == .fsync)
    }

    @Test("nosync and fsync are distinct modes")
    func syncModesAreDistinct() {
        #expect(Filesystem.SyncMode.nosync != Filesystem.SyncMode.fsync)
        #expect(Filesystem.SyncMode.nosync != Filesystem.SyncMode.full)
    }

    // MARK: - CLI --volume-sync fallback (main.swift pattern)

    @Test("Valid --volume-sync values resolve to the correct mode")
    func validCliVolumeSyncValues() {
        let cases: [(String, Filesystem.SyncMode)] = [
            ("nosync", .nosync), ("fsync", .fsync), ("full", .full),
            ("NOSYNC", .nosync), ("FSYNC", .fsync),  // case-insensitive
        ]
        for (input, expected) in cases {
            let resolved = Filesystem.SyncMode(rawString: input) ?? .nosync
            #expect(resolved == expected, "'\(input)' should resolve to \(expected)")
        }
    }

    @Test("Invalid --volume-sync value falls back to nosync and emits warning")
    func invalidCliVolumeSyncFallsBackToNosync() {
        var warnings: [String] = []
        let resolved = Filesystem.SyncMode.resolve(from: "fsynk") { warnings.append($0) }
        #expect(resolved == .nosync)
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("fsynk") == true)
        #expect(warnings.first?.contains("nosync") == true)
    }

    @Test("Valid --volume-sync value does not emit warning")
    func validCliVolumeSyncNoWarning() {
        var warnings: [String] = []
        let resolved = Filesystem.SyncMode.resolve(from: "fsync") { warnings.append($0) }
        #expect(resolved == .fsync)
        #expect(warnings.isEmpty)
    }

    // MARK: - Per-volume label resolution

    @Test("socktainerLabel constant matches expected key")
    func syncLabelKey() {
        #expect(Filesystem.SyncMode.socktainerLabel == "socktainer.volume.sync")
    }

    @Test("Per-volume label takes priority over global default")
    func perVolumeLabelOverridesGlobal() {
        // Simulate: global = nosync, label = fsync → label wins
        let labelValue = "fsync"
        let globalDefault = Filesystem.SyncMode.nosync
        let resolved =
            Filesystem.SyncMode(rawString: labelValue)
            ?? globalDefault
        #expect(resolved == .fsync)
    }

    @Test("Invalid per-volume label falls back to global default")
    func invalidLabelFallsBackToGlobal() {
        let labelValue = "garbage"
        let globalDefault = Filesystem.SyncMode.nosync
        let resolved =
            Filesystem.SyncMode(rawString: labelValue)
            ?? globalDefault
        #expect(resolved == .nosync)
    }

    @Test("Missing label uses global default")
    func missingLabelUsesGlobal() {
        let labelValue: String? = nil
        let globalDefault = Filesystem.SyncMode.fsync
        let resolved =
            labelValue.flatMap { Filesystem.SyncMode(rawString: $0) }
            ?? globalDefault
        #expect(resolved == .fsync)
    }
}
