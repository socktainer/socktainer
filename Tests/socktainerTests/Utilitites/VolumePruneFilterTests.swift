import Logging
import Testing

@testable import socktainer

@Suite("Volume prune — negative label filter")
struct VolumePruneFilterTests {

    private let logger = Logger(label: "test")

    // MARK: - parsePruneFilters: label! accepted

    @Test("label! key is accepted and preserved in parsed filters")
    func labelBangKeyAccepted() throws {
        let json = #"{"label!": ["env=prod"]}"#
        let filters = try DockerVolumeFilterUtility.parsePruneFilters(filtersParam: json, logger: logger)
        #expect(filters["label!"] == ["env=prod"])
    }

    @Test("label! and label keys can coexist")
    func labelBangAndLabelCoexist() throws {
        let json = #"{"label": ["tier=web"], "label!": ["env=dev"]}"#
        let filters = try DockerVolumeFilterUtility.parsePruneFilters(filtersParam: json, logger: logger)
        #expect(filters["label"] == ["tier=web"])
        #expect(filters["label!"] == ["env=dev"])
    }

    @Test("unknown filter key still rejected")
    func unknownKeyRejected() throws {
        let json = #"{"unknown": ["value"]}"#
        #expect(throws: (any Error).self) {
            try DockerVolumeFilterUtility.parsePruneFilters(filtersParam: json, logger: logger)
        }
    }

    // MARK: - Negative label matching via ClientVolumeService.applyFilters

    @Test("label!=key=value: volume matching the negated label is excluded")
    func volumeMatchingNegLabelExcluded() {
        let volumes = [
            makeVolume(name: "vol-prod", labels: ["env": "prod"]),
            makeVolume(name: "vol-dev", labels: ["env": "dev"]),
            makeVolume(name: "vol-unlabeled"),
        ]
        let result = ClientVolumeService.applyFilters(volumes, parsedFilters: ["label!": ["env=prod"]])
        let names = result.map(\.Name).sorted()
        #expect(names == ["vol-dev", "vol-unlabeled"])
        #expect(!names.contains("vol-prod"))
    }

    @Test("label!=key=value: volume not matching the negated label is included")
    func volumeNotMatchingNegLabelIncluded() {
        let volumes = [makeVolume(name: "vol-dev", labels: ["env": "dev"])]
        let result = ClientVolumeService.applyFilters(volumes, parsedFilters: ["label!": ["env=prod"]])
        #expect(result.map(\.Name) == ["vol-dev"])
    }

    @Test("label!=key=value: unlabeled volume is included")
    func unlabeledVolumeIncluded() {
        let volumes = [makeVolume(name: "vol-none")]
        let result = ClientVolumeService.applyFilters(volumes, parsedFilters: ["label!": ["env=prod"]])
        #expect(result.map(\.Name) == ["vol-none"])
    }

    @Test("label!=key (key-only): volume without key is included")
    func volumeWithoutKeyIncluded() {
        let volumes = [makeVolume(name: "vol-other", labels: ["tier": "web"])]
        let result = ClientVolumeService.applyFilters(volumes, parsedFilters: ["label!": ["env"]])
        #expect(result.map(\.Name) == ["vol-other"])
    }

    @Test("label!=key (key-only): volume with key is excluded")
    func volumeWithKeyExcluded() {
        let volumes = [makeVolume(name: "vol-env", labels: ["env": "anything"])]
        let result = ClientVolumeService.applyFilters(volumes, parsedFilters: ["label!": ["env"]])
        #expect(result.isEmpty)
    }

    // MARK: - Positive label matching is AND across multiple filters

    @Test("multiple label filters are ANDed: only a volume matching every label is kept")
    func multipleLabelFiltersAreAnded() {
        let volumes = [
            makeVolume(name: "vol-both", labels: ["env": "dev", "team": "a"]),
            makeVolume(name: "vol-env-only", labels: ["env": "dev", "team": "b"]),
            makeVolume(name: "vol-team-only", labels: ["env": "prod", "team": "a"]),
        ]
        let result = ClientVolumeService.applyFilters(
            volumes, parsedFilters: ["label": ["env=dev", "team=a"]])
        // Docker semantics: env=dev AND team=a → only vol-both, not vol-env-only (OR would keep all three).
        #expect(result.map(\.Name) == ["vol-both"])
    }

    @Test("single label filter still matches as before")
    func singleLabelFilterMatches() {
        let volumes = [
            makeVolume(name: "vol-dev", labels: ["env": "dev"]),
            makeVolume(name: "vol-prod", labels: ["env": "prod"]),
        ]
        let result = ClientVolumeService.applyFilters(volumes, parsedFilters: ["label": ["env=dev"]])
        #expect(result.map(\.Name) == ["vol-dev"])
    }
}

// MARK: - Helpers

private func makeVolume(name: String, labels: [String: String]? = nil) -> Volume {
    Volume(
        Name: name,
        Driver: "local",
        Mountpoint: "/var/lib/docker/volumes/\(name)/_data",
        CreatedAt: nil,
        Status: nil,
        Labels: labels,
        Scope: "local",
        ClusterVolume: nil,
        Options: [:],
        UsageData: nil
    )
}
