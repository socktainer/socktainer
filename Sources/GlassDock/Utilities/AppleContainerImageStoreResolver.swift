import ContainerResource
import ContainerizationOCI
import Foundation

struct AppleContainerImageStoreResolver {
    struct DescriptorExtras {
        let data: String?
        let artifactType: String?
    }

    static func descriptorExtras(
        appSupportURL: URL,
        parentDigest: String,
        childDigest: String
    ) -> DescriptorExtras? {
        // Docker's descriptor schema allows `data` and `artifactType`, but Apple's typed
        // Descriptor model does not expose either field. Recover them from the raw OCI blob
        // only when the underlying content actually contains them.
        guard
            let document = jsonObject(
                at: blobURL(appSupportURL: appSupportURL, digest: parentDigest)
            ),
            let descriptor = findDescriptor(in: document, childDigest: childDigest)
        else {
            return nil
        }

        return DescriptorExtras(
            data: descriptor["data"] as? String,
            artifactType: descriptor["artifactType"] as? String
        )
    }

    static func graphDriver(
        appSupportURL: URL,
        descriptor: Descriptor
    ) -> DriverData? {
        // Docker exposes GraphDriver details on inspect. Apple does not model an image graph
        // driver directly, but unpacked snapshots persist `snapshot-info`, which is the closest
        // host-side source we can map without inventing values.
        let infoURL =
            appSupportURL
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(descriptor.digest.trimmingDigestPrefix, isDirectory: true)
            .appendingPathComponent("snapshot-info", isDirectory: false)

        guard
            let data = try? Data(contentsOf: infoURL),
            let filesystem = try? JSONDecoder().decode(Filesystem.self, from: data)
        else {
            return nil
        }

        let name: String
        var driverData: [String: String] = [
            "Source": filesystem.source,
            "Destination": filesystem.destination,
        ]

        if !filesystem.options.isEmpty {
            driverData["Options"] = filesystem.options.joined(separator: ",")
        }

        switch filesystem.type {
        case .block(let format, let cache, let sync):
            name = format
            driverData["Cache"] = String(describing: cache)
            driverData["Sync"] = String(describing: sync)
        case .volume(let volumeName, let format, let cache, let sync):
            name = format
            driverData["Volume"] = volumeName
            driverData["Cache"] = String(describing: cache)
            driverData["Sync"] = String(describing: sync)
        case .virtiofs:
            name = "virtiofs"
        case .tmpfs:
            name = "tmpfs"
        }

        return DriverData(Name: name, Data: driverData)
    }

    private static func blobURL(appSupportURL: URL, digest: String) -> URL {
        appSupportURL
            .appendingPathComponent("content", isDirectory: true)
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent("sha256", isDirectory: true)
            .appendingPathComponent(digest.trimmingDigestPrefix, isDirectory: false)
    }

    private static func jsonObject(at url: URL) -> Any? {
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return nil
        }
        return object
    }

    private static func findDescriptor(in object: Any, childDigest: String) -> [String: Any]? {
        if let dictionary = object as? [String: Any] {
            if dictionary["digest"] as? String == childDigest {
                return dictionary
            }

            for value in dictionary.values {
                if let match = findDescriptor(in: value, childDigest: childDigest) {
                    return match
                }
            }
        }

        if let array = object as? [Any] {
            for value in array {
                if let match = findDescriptor(in: value, childDigest: childDigest) {
                    return match
                }
            }
        }

        return nil
    }
}
