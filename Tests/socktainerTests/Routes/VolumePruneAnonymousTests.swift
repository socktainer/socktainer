import ContainerResource
import Foundation
import Logging
import Testing

@testable import socktainer

/// Docker Engine API v1.42+: POST /volumes/prune removes only anonymous
/// volumes unless the all=true filter is set. The previous implementation
/// deleted every filtered volume, so a plain `docker volume prune` destroyed
/// named volumes and their data.
@Suite("VolumePruneRoute — anonymous-only default")
struct VolumePruneAnonymousTests {

    @Test("Without all, only volumes carrying the anonymous label are pruned")
    func defaultPrunesOnlyAnonymous() {
        let volumes = [
            Self.volume(name: "pgdata"),
            Self.volume(name: "0f1e2d3c-anon", labels: [ClientVolumeService.anonymousVolumeLabel: ""]),
            Self.volume(name: "appcache", labels: ["team": "web"]),
        ]

        let selected = VolumePruneRoute.volumesToPrune(volumes, pruneAll: false)
        #expect(selected.map(\.Name) == ["0f1e2d3c-anon"])
    }

    @Test("With all=true, named volumes are pruned too")
    func allPrunesEverything() {
        let volumes = [
            Self.volume(name: "pgdata"),
            Self.volume(name: "0f1e2d3c-anon", labels: [ClientVolumeService.anonymousVolumeLabel: ""]),
        ]

        let selected = VolumePruneRoute.volumesToPrune(volumes, pruneAll: true)
        #expect(selected.map(\.Name) == ["pgdata", "0f1e2d3c-anon"])
    }

    @Test("Volumes carrying Apple's own anonymous label are pruned by default too")
    func appleAnonymousLabelCounts() {
        let volumes = [
            Self.volume(name: "pgdata"),
            Self.volume(name: "apple-anon", labels: [VolumeConfiguration.anonymousLabel: ""]),
        ]

        let selected = VolumePruneRoute.volumesToPrune(volumes, pruneAll: false)
        #expect(selected.map(\.Name) == ["apple-anon"])
    }

    @Test("The all filter key is parsed from the docker CLI's map form")
    func allFilterKeyParses() throws {
        let logger = Logger(label: "test")
        // docker volume prune -a sends filters={"all":{"true":true}}
        let parsed = try DockerVolumeFilterUtility.parsePruneFilters(filtersParam: #"{"all":{"true":true}}"#, logger: logger)
        #expect(parsed["all"] == ["true"])
    }

    @Test("all accepts moby's ParseBool forms and rejects garbage")
    func allValueParsing() throws {
        #expect(try VolumePruneRoute.parsePruneAll(nil) == false)
        #expect(try VolumePruneRoute.parsePruneAll(["true"]) == true)
        #expect(try VolumePruneRoute.parsePruneAll(["T"]) == true)
        #expect(try VolumePruneRoute.parsePruneAll(["0"]) == false)
        #expect(throws: (any Error).self) { try VolumePruneRoute.parsePruneAll(["bogus"]) }
        #expect(throws: (any Error).self) { try VolumePruneRoute.parsePruneAll(["true", "false"]) }
    }

    // MARK: - Helpers

    private static func volume(name: String, labels: [String: String]? = nil) -> Volume {
        Volume(
            Name: name, Driver: "local", Mountpoint: "/tmp/\(name)", CreatedAt: nil,
            Status: nil, Labels: labels, Scope: "local", ClusterVolume: nil,
            Options: [:], UsageData: nil)
    }
}
