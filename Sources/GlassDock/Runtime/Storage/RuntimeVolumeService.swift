import ContainerResource
import Foundation
import Vapor

/// Persistent local volumes for the single guest runtime. Volume data stays in
/// a host directory that the custom VMM shares through its virtio-fs device.
actor RuntimeVolumeService: ClientVolumeProtocol {
    private struct Metadata: Codable {
        let name: String
        let driver: String
        let options: [String: String]
        let labels: [String: String]
        let createdAt: Date
        var referencedContainers: Set<String> = []

        private enum CodingKeys: String, CodingKey {
            case name, driver, options, labels, createdAt, referencedContainers
        }

        init(
            name: String, driver: String, options: [String: String], labels: [String: String],
            createdAt: Date, referencedContainers: Set<String>
        ) {
            self.name = name
            self.driver = driver
            self.options = options
            self.labels = labels
            self.createdAt = createdAt
            self.referencedContainers = referencedContainers
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            name = try values.decode(String.self, forKey: .name)
            driver = try values.decode(String.self, forKey: .driver)
            options = try values.decode([String: String].self, forKey: .options)
            labels = try values.decode([String: String].self, forKey: .labels)
            createdAt = try values.decode(Date.self, forKey: .createdAt)
            referencedContainers =
                try values.decodeIfPresent(Set<String>.self, forKey: .referencedContainers) ?? []
        }
    }

    private let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var referenceValidator: (@Sendable (String) async -> Bool)?

    init(root: URL? = nil) {
        self.root =
            root
            ?? ProcessInfo.processInfo.environment["GLASSDOCK_VOLUME_DIRECTORY"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            ?? GlassDockDirectories.hostHome
            .appendingPathComponent("Library/Application Support/Glass Dock/volumes", isDirectory: true)
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func create(request: RESTVolumeCreate) throws -> Volume {
        let name = request.Name.isEmpty ? UUID().uuidString.lowercased() : request.Name
        try Self.validate(name)
        let driver = request.Driver.isEmpty ? "local" : request.Driver
        guard driver == "local" else {
            throw Abort(.notImplemented, reason: "Only the local volume driver is supported")
        }
        try prepareRoot()
        let directory = volumeDirectory(name)
        let metadataURL = directory.appendingPathComponent("metadata.json", isDirectory: false)
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            return try volume(from: readMetadata(at: metadataURL))
        }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("data", isDirectory: true),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let metadata = Metadata(
            name: name,
            driver: driver,
            options: request.Options,
            labels: request.Labels ?? [:],
            createdAt: Date(),
            referencedContainers: []
        )
        try write(metadata)
        return try volume(from: metadata)
    }

    func delete(name: String) throws {
        try Self.validate(name)
        let directory = volumeDirectory(name)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw Abort(.notFound, reason: "No such volume: \(name)")
        }
        try FileManager.default.removeItem(at: directory)
    }

    func deleteIfUnused(name: String) async throws {
        try Self.validate(name)
        var metadata = try readMetadata(
            at: volumeDirectory(name).appendingPathComponent("metadata.json", isDirectory: false)
        )
        if let referenceValidator {
            var live: Set<String> = []
            for id in metadata.referencedContainers where await referenceValidator(id) {
                live.insert(id)
            }
            if live != metadata.referencedContainers {
                metadata.referencedContainers = live
                try write(metadata)
            }
        }
        guard metadata.referencedContainers.isEmpty else {
            throw Abort(.conflict, reason: "Volume \(name) is in use")
        }
        try delete(name: name)
    }

    func setReferenceValidator(_ validator: @escaping @Sendable (String) async -> Bool) {
        referenceValidator = validator
    }

    func retain(names: Set<String>, containerID: String) throws {
        for name in names {
            var metadata = try readMetadata(
                at: volumeDirectory(name).appendingPathComponent("metadata.json", isDirectory: false)
            )
            metadata.referencedContainers.insert(containerID)
            try write(metadata)
        }
    }

    func release(containerID: String) throws {
        for entry in try metadataEntries() {
            var metadata = try readMetadata(at: entry)
            if metadata.referencedContainers.remove(containerID) != nil {
                try write(metadata)
            }
        }
    }

    func list(filters: String?, logger: Logger) throws -> [Volume] {
        try prepareRoot()
        let volumes = try metadataEntries().map { entry in
            try volume(from: readMetadata(at: entry))
        }
        return ClientVolumeService.applyFilters(
            volumes,
            parsedFilters: Self.filters(filters),
            labelDictFilter: nil
        )
    }

    func inspect(name: String) throws -> Volume {
        try Self.validate(name)
        let metadataURL = volumeDirectory(name).appendingPathComponent(
            "metadata.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw Abort(.notFound, reason: "No such volume: \(name)")
        }
        return try volume(from: readMetadata(at: metadataURL))
    }

    private func prepareRoot() throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func volumeDirectory(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    private func readMetadata(at url: URL) throws -> Metadata {
        try decoder.decode(Metadata.self, from: Data(contentsOf: url))
    }

    private func write(_ metadata: Metadata) throws {
        let url = volumeDirectory(metadata.name).appendingPathComponent("metadata.json", isDirectory: false)
        try encoder.encode(metadata).write(to: url, options: .atomic)
    }

    private func metadataEntries() throws -> [URL] {
        try prepareRoot()
        return try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ).compactMap { entry in
            guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                values.isDirectory == true, values.isSymbolicLink != true
            else { return nil }
            return entry.appendingPathComponent("metadata.json", isDirectory: false)
        }
    }

    private func volume(from metadata: Metadata) throws -> Volume {
        let data = volumeDirectory(metadata.name).appendingPathComponent("data", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: data.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw Abort(.internalServerError, reason: "Volume data is missing: \(metadata.name)")
        }
        var labels = LabelNormalization.restore(metadata.labels)
        var options = metadata.options
        if let sync = labels.removeValue(forKey: Filesystem.SyncMode.glassdockLabel) {
            options["sync"] = sync
        }
        return Volume(
            Name: metadata.name,
            Driver: metadata.driver,
            Mountpoint: data.path,
            CreatedAt: ISO8601DateFormatter().string(from: metadata.createdAt),
            Status: nil,
            Labels: labels,
            Scope: "local",
            ClusterVolume: nil,
            Options: options,
            UsageData: VolumeUsageData()
        )
    }

    private static func validate(_ name: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))
        guard !name.isEmpty, name.count <= 255,
            name.unicodeScalars.allSatisfy(allowed.contains), name != ".", name != ".."
        else {
            throw Abort(.badRequest, reason: "Invalid volume name: \(name)")
        }
    }

    private static func filters(_ raw: String?) -> [String: [String]] {
        guard let raw, let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object.compactMapValues { value in
            if let values = value as? [String] { return values }
            if let values = value as? [String: Bool] {
                return values.compactMap { $0.value ? $0.key : nil }
            }
            return nil
        }
    }
}
