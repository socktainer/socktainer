import ContainerClient
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
    func create(request: RESTVolumeCreate) async throws -> Volume {
        let existingVolumes = try await ClientVolume.list()
        let existingVolume = existingVolumes.first { $0.name == request.Name }

        let result: ContainerClient.Volume
        if let existing = existingVolume {
            // Volume exists, use it
            result = existing
        } else {
            result = try await ClientVolume.create(
                name: request.Name,
                driver: request.Driver,
                driverOpts: request.Options,
                labels: request.Labels ?? [:]
            )
        }
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
        if let filters = filters, !filters.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, filters.trimmingCharacters(in: .whitespacesAndNewlines) != "{}" {
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
        if parsedFilters.isEmpty {
            return volumes
        }
        // Filtering logic
        let filteredVolumes = volumes.filter { volume in
            var matches = true
            if let names = parsedFilters["name"], !names.isEmpty {
                matches = matches && names.contains(where: { volume.Name.contains($0) })
            }
            if let drivers = parsedFilters["driver"], !drivers.isEmpty {
                matches = matches && drivers.contains(volume.Driver)
            }
            if let labels = parsedFilters["label"], !labels.isEmpty, let volumeLabels = volume.Labels {
                let labelMatches = labels.contains { labelFilter in
                    guard let eqIdx = labelFilter.firstIndex(of: "=") else {
                        return volumeLabels.keys.contains(labelFilter)
                    }
                    let key = String(labelFilter[..<eqIdx])
                    let value = String(labelFilter[labelFilter.index(after: eqIdx)...])
                    return volumeLabels[key] == value
                }
                matches = matches && labelMatches
            }
            if let labelDict = labelDictFilter, let volumeLabels = volume.Labels {
                let labelMatches = labelDict.allSatisfy { (key, value) in
                    if let volumeValue = volumeLabels[key] {
                        // Compare as string
                        return String(describing: volumeValue) == String(describing: value)
                    }
                    return false
                }
                matches = matches && labelMatches
            }
            // NOTE: we currently have no mechanism to correlate volumes
            //       to containers.
            // Filter by dangling (not referenced by any container)
            // if let dangling = parsedFilters["dangling"], !dangling.isEmpty {
            // }
            return matches
        }
        return filteredVolumes
    }

    func inspect(name: String) async throws -> Volume {
        let result = try await ClientVolume.inspect(name)
        return Self.convert(result)
    }

    private static func convert(_ v: ContainerClient.Volume) -> Volume {
        Volume(
            Name: v.name,
            Driver: v.driver,
            Mountpoint: v.source,
            CreatedAt: ISO8601DateFormatter().string(from: v.createdAt),
            Status: nil,  // we have no mechanism to report status for the time being
            Labels: v.labels,
            Scope: "local",  // Assuming local for now
            ClusterVolume: nil,
            Options: v.options,
            UsageData: VolumeUsageData()
        )
    }
}
