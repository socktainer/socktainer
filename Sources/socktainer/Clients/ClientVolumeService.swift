import ContainerAPIClient
import ContainerResource
import Foundation
import Vapor

// Protocol for volume operations
protocol ClientVolumeProtocol: Sendable {
    func create(request: RESTVolumeCreate) async throws -> Volume
    func delete(name: String) async throws
    func list(filters: String?, logger: Logger) async throws -> [Volume]
    func inspect(name: String) async throws -> Volume
}

struct ClientVolumeService: ClientVolumeProtocol {
    /// moby's volume.AnonymousLabel — stamped on volumes auto-created without a
    /// user-supplied name so that volume prune (without all=true) targets only them.
    static let anonymousVolumeLabel = "com.docker.volume.anonymous"

    func create(request: RESTVolumeCreate) async throws -> Volume {
        let result = try await ClientVolume.create(
            name: request.Name,
            driver: request.Driver,
            driverOpts: request.Options,
            labels: request.Labels ?? [:]
        )
        return Self.convert(result)
    }

    func delete(name: String) async throws {
        try await ClientVolume.delete(name: name)
    }

    func list(filters: String?, logger: Logger) async throws -> [Volume] {
        let results = try await ClientVolume.list()
        let volumes = results.map { Self.convert($0) }
        var parsedFilters: [String: [String]] = [:]
        var labelDictFilter: [String: Any]? = nil
        if let filters = filters, !filters.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            filters.trimmingCharacters(in: .whitespacesAndNewlines) != "{}"
        {
            guard let data = filters.data(using: .utf8),
                let decoded = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
            else {
                return []
            }
            for (key, value) in decoded {
                if key == "label", let dict = value as? [String: Any] {
                    labelDictFilter = dict
                } else if let arr = value as? [String] {
                    parsedFilters[key] = arr
                } else if let dict = value as? [String: Any] {
                    let keys = dict.compactMap { (key, value) in
                        (value as? Bool == true) ? key : nil
                    }
                    if !keys.isEmpty {
                        parsedFilters[key] = keys
                    }
                }
            }
        }
        return Self.applyFilters(volumes, parsedFilters: parsedFilters, labelDictFilter: labelDictFilter)
    }

    /// Applies parsed volume filters to a list of volumes.
    static func applyFilters(
        _ volumes: [Volume],
        parsedFilters: [String: [String]],
        labelDictFilter: [String: Any]? = nil
    ) -> [Volume] {
        if parsedFilters.isEmpty && labelDictFilter == nil {
            return volumes
        }
        return volumes.filter { volume in
            var matches = true
            if let names = parsedFilters["name"], !names.isEmpty {
                matches = matches && names.contains(where: { volume.Name.contains($0) })
            }
            if let drivers = parsedFilters["driver"], !drivers.isEmpty {
                matches = matches && drivers.contains(volume.Driver)
            }
            if let labels = parsedFilters["label"], !labels.isEmpty {
                // Docker treats multiple `--filter label=...` as AND: a volume must
                // match every label filter, not just one. A volume with no labels
                // matches none of them, so treat a missing label set as empty —
                // consistent with the negative `label!` path below (without this,
                // an unlabeled volume would skip the block and wrongly pass).
                let volumeLabels = volume.Labels ?? [:]
                let labelMatches = labels.allSatisfy { labelFilter in
                    guard let eqIdx = labelFilter.firstIndex(of: "=") else {
                        return LabelNormalization.filterContainsKey(labelFilter, in: volumeLabels)
                    }
                    let key = String(labelFilter[..<eqIdx])
                    let value = String(labelFilter[labelFilter.index(after: eqIdx)...])
                    return LabelNormalization.filterValue(in: volumeLabels, forKey: key) == value
                }
                matches = matches && labelMatches
            }
            // label! key = negative label filter (docker volume prune --filter label!=key)
            if let negLabels = parsedFilters["label!"], !negLabels.isEmpty {
                let volumeLabels = volume.Labels ?? [:]
                let negMatches = negLabels.allSatisfy { labelFilter in
                    guard let eqIdx = labelFilter.firstIndex(of: "=") else {
                        return !LabelNormalization.filterContainsKey(labelFilter, in: volumeLabels)
                    }
                    let key = String(labelFilter[..<eqIdx])
                    let value = String(labelFilter[labelFilter.index(after: eqIdx)...])
                    return LabelNormalization.filterValue(in: volumeLabels, forKey: key) != value
                }
                matches = matches && negMatches
            }
            if let labelDict = labelDictFilter, let volumeLabels = volume.Labels {
                let labelMatches = labelDict.allSatisfy { (key, value) in
                    if let volumeValue = volumeLabels[key] {
                        return String(describing: volumeValue) == String(describing: value)
                    }
                    return false
                }
                matches = matches && labelMatches
            }
            // NOTE: we currently have no mechanism to correlate volumes to containers.
            // Filter by dangling (not referenced by any container)
            // if let dangling = parsedFilters["dangling"], !dangling.isEmpty { }
            return matches
        }
    }

    func inspect(name: String) async throws -> Volume {
        let result = try await ClientVolume.inspect(name)
        return Self.convert(result)
    }

    private static func convert(_ v: ContainerResource.VolumeConfiguration) -> Volume {
        Volume(
            Name: v.name,
            Driver: v.driver,
            Mountpoint: v.source,
            CreatedAt: ISO8601DateFormatter().string(from: v.creationDate),
            Status: nil,  // we have no mechanism to report status for the time being
            Labels: LabelNormalization.restore(v.labels),
            Scope: "local",  // Assuming local for now
            ClusterVolume: nil,
            Options: v.options,
            UsageData: VolumeUsageData()
        )
    }
}
